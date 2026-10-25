#!/usr/bin/env python3
"""Trains the generator's candidate model (src/Data/GeneratorModel.json).

The generator measures every support gem for the main link, one calculation
each, at each pick. Most supports can't help a given skill (a minion support
for an attack, a projectile support for a melee strike...). From the
support decisions in decision logs (the user folder's GeneratorDecisions.jsonl,
or bench_case.lua with DECISION_LOG=file),
this learns, for each support, the chance that it helps a skill with given
gem tags: a logistic regression per support on the main skill's tags.
The generator then skips the supports whose chance is very low, and only once
the model has seen enough of them.

    python3 bench/train_model.py <decision log> [more logs...] [--gems gems.json] [--out src/Data/GeneratorModel.json]

--gems: the active gems' skill types (bench/export_gem_types.lua), added as
features ("t:Minion"...): minion and trigger skills are supported in ways
the gem tags alone don't show.

Validation: each skill is left out in turn, the model trained on the others,
and the supports it would skip for that skill are checked against what the
skill really gained from them ("missed": a skipped support that would have
been picked or nearly so).
"""
import json
import math
import sys
from collections import defaultdict

import numpy as np

HELPS = 0.002     # a gain above this counts as helping
MATTERS = 0.02    # a skipped support that would have gained more than this is a real miss
THRESHOLDS = [0.001, 0.002, 0.005, 0.01, 0.02]  # skip thresholds tried; the highest without real misses is kept
MIN_SEEN = 30      # a support is only skipped once seen this many times in training
GEMS = {}         # gem name -> { types, tags } (bench/export_gem_types.lua), for skill type features


def load(paths):
    """Support measurements from decision logs (GeneratorDecisions.jsonl, or
    bench_case.lua with DECISION_LOG=file): each "support" decision joined
    with its run line (the main skill and its tags)."""
    rows = []
    for path in paths:
        runs = {}
        contexts = {}
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                r = json.loads(line)
                if r.get("type") == "run":
                    runs[r["id"]] = r
                elif r.get("k") == "support_ctx":
                    contexts[(r.get("run"), r.get("cx"))] = r.get("f", [])
                elif r.get("k") == "support" and r.get("g") is not None:
                    run = runs.get(r.get("run"))
                    if run:
                        feats = list(run.get("tags", []))
                        for t in GEMS.get(run.get("skill"), {}).get("types", []):
                            feats.append("t:" + t)
                        # the build's situation at that choice (BuildGenerator:SupportContext)
                        for c in contexts.get((r.get("run"), r.get("cx")), []):
                            feats.append("c:" + c)
                        rows.append({"name": r["n"], "gain": r["g"], "skill": run.get("skill"), "tags": feats,
                                     "investment": run.get("investment"), "pick": r.get("pick")})
    return rows


def fit(rows, tags_index, l2=1.0, iters=300, lr=0.5):
    """Logistic regression (bias + tag weights) by gradient descent."""
    n, d = len(rows), len(tags_index) + 1
    X = np.zeros((n, d))
    y = np.zeros(n)
    for i, r in enumerate(rows):
        X[i, 0] = 1
        for t in r["tags"]:
            j = tags_index.get(t)
            if j is not None:
                X[i, j + 1] = 1
        y[i] = 1 if r["gain"] > HELPS else 0
    w = np.zeros(d)
    for _ in range(iters):
        p = 1 / (1 + np.exp(-X @ w))
        grad = X.T @ (p - y) / n + l2 * np.r_[0, w[1:]] / n
        w -= lr * grad
    return w


def train(rows):
    by_support = defaultdict(list)
    for r in rows:
        by_support[r["name"]].append(r)
    tags = sorted({t for r in rows for t in r["tags"]})
    tags_index = {t: i for i, t in enumerate(tags)}
    model = {}
    for name, rs in by_support.items():
        w = fit(rs, tags_index)
        weights = {t: round(float(w[i + 1]), 4) for t, i in tags_index.items() if abs(w[i + 1]) > 1e-3}
        model[name] = {"n": len(rs), "bias": round(float(w[0]), 4), "w": weights,
                       "helped": sum(1 for r in rs if r["gain"] > HELPS)}
    return model


def chance(entry, tags):
    z = entry["bias"] + sum(entry["w"].get(t, 0) for t in tags)
    return 1 / (1 + math.exp(-z))


def validate(rows):
    """Leave each skill out; per threshold: measurements skipped, real misses."""
    skills = sorted({r["skill"] for r in rows})
    stats = {t: {"skipped": 0, "missed": 0, "worst": []} for t in THRESHOLDS}
    total = 0
    for skill in skills:
        train_rows = [r for r in rows if r["skill"] != skill]
        test_rows = [r for r in rows if r["skill"] == skill]
        if not train_rows or not test_rows:
            continue
        model = train(train_rows)
        for r in test_rows:
            total += 1
            e = model.get(r["name"])
            if not e or e["n"] < MIN_SEEN:
                continue
            p = chance(e, r["tags"])
            for t in THRESHOLDS:
                if p < t:
                    stats[t]["skipped"] += 1
                    if r["gain"] > MATTERS:
                        stats[t]["missed"] += 1
                        stats[t]["worst"].append((r["gain"], skill, r["name"]))
    return stats, total


def main():
    args = sys.argv[1:]
    out = "src/Data/GeneratorModel.json"
    if "--gems" in args:
        i = args.index("--gems")
        GEMS.update(json.load(open(args[i + 1])))
        args = args[:i] + args[i + 2:]
    if "--out" in args:
        i = args.index("--out")
        out = args[i + 1]
        args = args[:i] + args[i + 2:]
    rows = load(args)
    skills = {r["skill"] for r in rows}
    print(f"{len(rows)} support measurements, {len(skills)} skills")
    stats, total = validate(rows)
    chosen = 0
    for t in THRESHOLDS:
        st = stats[t]
        print(f"skip below {t}: {st['skipped']} of {total} measurements skipped ({100 * st['skipped'] / max(total, 1):.0f}%), "
              f"{st['missed']} would have gained more than {MATTERS}")
        for gain, skill, name in sorted(st["worst"], reverse=True)[:5]:
            print(f"    missed {name} for {skill}: {gain:+.3f}")
        if st["missed"] == 0:
            chosen = t
    print(f"threshold kept: {chosen} (0 = the model skips nothing)")
    model = train(rows)
    with open(out, "w") as f:
        has_context = any(f.startswith("c:") for r in rows for f in r["tags"])
        json.dump({"version": 3, "helps": HELPS, "skipBelow": chosen, "minSeen": MIN_SEEN, "typeFeatures": bool(GEMS), "contextFeatures": has_context,
                   "skills": len(skills), "support": model}, f, indent=0, sort_keys=True)
    print(f"written {out}: {len(model)} supports")


if __name__ == "__main__":
    main()
