#!/usr/bin/env python3
"""Trains a gradient boosted candidate model for support gems (LightGBM) and
adds it to the generator's model (src/Data/GeneratorModel.json, "boosted").

The logistic model (bench/train_model.py, Modules/GeneratorModelTrainer) adds
up one weight per feature, so "Lifetap helps when mana is short AND the skill
is fast" can only be learnt as two separate weights. Here one model for all
supports (the support gem as a category) learns those combinations: features
are the main skill's gem tags and skill types ("t:"), the skill ("s:"), the
build's situation at the choice ("c:"), and the support.

Validated like the logistic model: builds split in five groups (twice,
differently), each left out in turn, every left-out pick judged by a model
that never saw its build; a skip only costs something when the best support
it hid beats the best one still tried by more than MATTERS. The same history
rule applies (only supports that never helped that skill in two builds or
more are ever skipped). The threshold kept is the highest without such a
loss, less one step of margin; the result is compared with the logistic
model on the same splits.

    python3 bench/train_boosted.py <decision logs...> [--gems gems.json] [--model src/Data/GeneratorModel.json]
        [--trees 300] [--leaves 31] [--dry]
"""
import json
import math
import sys
from collections import defaultdict

import numpy as np
import lightgbm as lgb
from scipy import sparse

sys.path.insert(0, __import__("os").path.dirname(__file__))
import train_model as tm  # noqa: E402

THRESHOLDS = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2]
MIN_CHECKED = 500


def matrix(rows, feat_index, support_index):
    """Sparse binary features + the support's id as the last (categorical) column"""
    indptr, indices, data = [0], [], []
    for r in rows:
        cols = sorted({feat_index[t] for t in r["tags"] if t in feat_index})
        indices.extend(cols)
        data.extend([1.0] * len(cols))
        # the support column holds its id (+1: 0 would read as missing)
        indices.append(len(feat_index))
        data.append(float(support_index.get(r["name"], -1) + 1))
        indptr.append(len(indices))
    return sparse.csr_matrix((np.array(data, dtype=np.float32), indices, indptr), shape=(len(rows), len(feat_index) + 1))


def fit(rows, trees, leaves):
    feats = sorted({t for r in rows for t in r["tags"]})
    feat_index = {t: i for i, t in enumerate(feats)}
    supports = sorted({r["name"] for r in rows})
    support_index = {s: i for i, s in enumerate(supports)}
    X = matrix(rows, feat_index, support_index)
    y = np.array([1 if r["gain"] > tm.HELPS else 0 for r in rows])
    params = {"objective": "binary", "num_leaves": leaves, "learning_rate": 0.08, "min_data_in_leaf": 40,
              "feature_fraction": 0.9, "bagging_fraction": 0.8, "bagging_freq": 1, "lambda_l2": 1.0,
              "max_cat_to_onehot": 4, "cat_smooth": 10, "max_cat_threshold": 64, "verbose": -1, "num_threads": 2,
              "seed": 1}
    ds = lgb.Dataset(X, y, feature_name=[f"f{i}" for i in range(len(feats))] + ["support"],
                     categorical_feature=[len(feats)], free_raw_data=True)
    booster = lgb.train(params, ds, num_boost_round=trees)
    return {"booster": booster, "feat_index": feat_index, "support_index": support_index, "feats": feats, "supports": supports}


def predict(model, rows):
    X = matrix(rows, model["feat_index"], model["support_index"])
    return model["booster"].predict(X)


def validate(rows, trees, leaves, splits=2):
    """{threshold: {"skipped", "missed", "worst"}} for the boosted and the logistic model, and how many were checked"""
    run_ids = sorted({r["run"] for r in rows})
    out = {kind: {t: {"skipped": 0, "missed": 0, "worst": []} for t in THRESHOLDS} for kind in ("boosted", "logistic")}
    checked = 0
    has_context = any(f.startswith("c:") for r in rows for f in r["tags"])
    for split in range(splits):
        rng = np.random.RandomState(split)
        order = list(run_ids)
        rng.shuffle(order)
        fold_of = {rid: i % tm.FOLDS for i, rid in enumerate(order)}
        for k in range(tm.FOLDS):
            train_rows = [r for r in rows if fold_of[r["run"]] != k]
            test_rows = [r for r in rows if fold_of[r["run"]] == k
                         and (not has_context or any(f.startswith("c:") for f in r["tags"]))]
            if not train_rows or not test_rows:
                continue
            familiar = tm.familiar_skills(train_rows)
            useless = tm.useless_pairs(train_rows)
            seen = defaultdict(int)
            for r in train_rows:
                seen[r["name"]] += 1
            # (only rows the history rule lets through can be skipped at all)
            eligible = [r for r in test_rows if familiar.get(r["skill"], 0) >= tm.FAMILIAR_RUNS
                        and r["name"] in useless.get(r["skill"], ()) and seen[r["name"]] >= tm.MIN_SEEN]
            boosted = fit(train_rows, trees, leaves)
            pb = dict(zip(map(id, eligible), predict(boosted, eligible))) if eligible else {}
            logistic = tm.train(train_rows)
            pl = {}
            for r in eligible:
                e = logistic.get(r["name"])
                if e:
                    pl[id(r)] = tm.chance(e, r["tags"])
            steps = defaultdict(list)
            for r in test_rows:
                checked += 1
                key = (r["run"], r["cx"], r["pick"]) if r["cx"] is not None else id(r)
                steps[key].append(r)
            for kind, probs in (("boosted", pb), ("logistic", pl)):
                for step in steps.values():
                    for t in THRESHOLDS:
                        kept = [r["gain"] for r in step if probs.get(id(r), 1.0) >= t]
                        skipped = [r for r in step if probs.get(id(r), 1.0) < t]
                        st = out[kind][t]
                        st["skipped"] += len(skipped)
                        if skipped:
                            best = max(skipped, key=lambda r: r["gain"])
                            if best["gain"] - max([0.0] + kept) > tm.MATTERS:
                                st["missed"] += 1
                                st["worst"].append((round(best["gain"], 3), best["skill"], best["name"]))
            print(f"  split {split + 1} fold {k + 1}: {len(test_rows)} checked, {len(eligible)} eligible", flush=True)
            del boosted
    return out, checked


def chosen_threshold(stats, checked):
    if checked < MIN_CHECKED:
        return 0
    safe = 0
    for i, t in enumerate(THRESHOLDS):
        if stats[t]["missed"] == 0:
            safe = i + 1
        else:
            break
    return THRESHOLDS[max(0, safe - 2)] if safe else 0


def export(model):
    """Trees as plain arrays the generator evaluates (Modules/GeneratorModel):
    each node [feature, threshold or category list, left, right, default left],
    a child < 0 is leaf -child-1"""
    dump = model["booster"].dump_model()
    names = model["feats"] + ["support"]
    trees = []
    for t in dump["tree_info"]:
        nodes, leaves = [], []

        def walk(n):
            if "leaf_index" in n or "leaf_value" in n and "split_index" not in n:
                leaves.append(round(n["leaf_value"], 6))
                return -len(leaves)
            i = len(nodes)
            nodes.append(None)
            left, right = walk(n["left_child"]), walk(n["right_child"])
            f = names[n["split_feature"]]
            if n["decision_type"] == "==":
                # categories: support ids + 1 -> support names
                cats = [model["supports"][int(c) - 1] for c in str(n["threshold"]).split("||") if int(c) >= 1]
                nodes[i] = [f, cats, left, right]
            else:
                nodes[i] = [f, round(float(n["threshold"]), 6), left, right, bool(n.get("default_left", True))]
            return i

        root = walk(t["tree_structure"])
        trees.append({"nodes": nodes, "leaves": leaves, "root": root})
    return trees


def main():
    args = sys.argv[1:]
    opts = {"--gems": None, "--model": "src/Data/GeneratorModel.json", "--trees": "300", "--leaves": "31"}
    dry = "--dry" in args
    args = [a for a in args if a != "--dry"]
    for key in list(opts):
        if key in args:
            i = args.index(key)
            opts[key] = args[i + 1]
            args = args[:i] + args[i + 2:]
    if opts["--gems"]:
        tm.GEMS.update(json.load(open(opts["--gems"])))
    rows = tm.load(args)
    print(f"{len(rows)} support measurements, {len({r['skill'] for r in rows})} skills", flush=True)
    trees, leaves = int(opts["--trees"]), int(opts["--leaves"])
    stats, checked = validate(rows, trees, leaves)
    for kind in ("logistic", "boosted"):
        print(kind)
        for t in THRESHOLDS:
            st = stats[kind][t]
            print(f"  skip below {t}: {st['skipped']} of {checked} skipped ({100 * st['skipped'] / max(checked, 1):.1f}%), {st['missed']} real misses"
                  + "".join(f"\n      missed {n} for {s}: {g:+.3f}" for g, s, n in sorted(st["worst"], reverse=True)[:3]))
    chosen = chosen_threshold(stats["boosted"], checked)
    chosen_log = chosen_threshold(stats["logistic"], checked)
    gain_b = stats["boosted"][chosen]["skipped"] if chosen else 0
    gain_l = stats["logistic"][chosen_log]["skipped"] if chosen_log else 0
    print(f"threshold kept: boosted {chosen} ({gain_b} skipped), logistic {chosen_log} ({gain_l} skipped)")
    if dry:
        return
    if not chosen or gain_b <= gain_l:
        print("the boosted model skips no more than the logistic one safely: not added")
        return
    model = fit(rows, trees, leaves)
    with open(opts["--model"]) as f:
        shipped = json.load(f)
    shipped["boosted"] = {"skipBelow": chosen, "init": 0, "trees": export(model), "measurements": len(rows),
                          "validated": {"checked": checked, "skipped": gain_b, "logisticSkipped": gain_l}}
    with open(opts["--model"], "w") as f:
        json.dump(shipped, f, separators=(",", ":"), sort_keys=True)
    print(f"written {opts['--model']}: {len(shipped['boosted']['trees'])} trees")


if __name__ == "__main__":
    main()
