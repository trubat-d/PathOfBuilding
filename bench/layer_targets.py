#!/usr/bin/env python3
"""Per-skill layer targets for the build doctor: the median of each damage
layer (crit factor, speed, enemy multiplier, increased, more, DoT multiplier,
gem level, charges, pools) over the skill's top-player builds, from
bench/layer_profiles.lua output (PROFILE lines). Writes
src/Data/GeneratorLayerTargets.json; BuildDoctor plans for the layers where a
build is clearly below its skill's target.

    python3 bench/layer_targets.py <profile outputs...> [--out src/Data/GeneratorLayerTargets.json]
"""
import json
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import playable  # (showcase builds left out: bench/playable.py)
from collections import defaultdict, Counter

KEYS = ["crit", "speed", "enemy", "increased", "more", "dotMulti", "gemLevel", "power", "frenzy", "endurance", "life", "es", "mana", "dps"]


def main():
    args = sys.argv[1:]
    out = "src/Data/GeneratorLayerTargets.json"
    if "--out" in args:
        i = args.index("--out")
        out = args[i + 1]
        args = args[:i] + args[i + 2:]
    keep = "--keep-showcase" in args
    args = [a for a in args if a != "--keep-showcase"]
    showcases = {} if keep else playable.showcase_set(os.environ.get("CODES", "/home/claude/ninja/codes"))
    by_skill = defaultdict(list)
    for path in args:
        for line in open(path):
            if line.startswith("PROFILE "):
                p = json.loads(line[8:])
                if p.get("dps", 0) > 0 and p.get("file") not in showcases:
                    by_skill[p["skill"]].append(p)
    targets = {}
    for skill, rows in sorted(by_skill.items()):
        if len(rows) < 3:
            continue
        mode = Counter(r.get("mode") for r in rows).most_common(1)[0][0]
        rows = [r for r in rows if r.get("mode") == mode]
        t = {"builds": len(rows), "mode": mode, "element": Counter(r.get("element") for r in rows).most_common(1)[0][0]}
        for k in KEYS:
            vals = [r[k] for r in rows if isinstance(r.get(k), (int, float))]
            if vals:
                t[k] = round(statistics.median(vals), 4)
        targets[skill] = t
    with open(out, "w") as f:
        json.dump({"version": 1, "source": "poe.ninja top players (bench/layer_profiles.lua)", "skills": targets}, f, indent=1, sort_keys=True)
    print(f"{len(targets)} skills -> {out}")
    for s in ("Winter Orb", "Righteous Fire", "Cyclone", "Boneshatter", "Ethereal Knives"):
        if s in targets:
            print(" ", s, {k: targets[s].get(k) for k in ("mode", "crit", "speed", "enemy", "increased", "more", "dotMulti", "power", "life", "es", "dps")})


if __name__ == "__main__":
    main()
