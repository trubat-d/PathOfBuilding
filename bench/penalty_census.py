#!/usr/bin/env python3
"""Penalty census: which scorer penalties fire on the top players' builds.

Top players' builds work in the game, so a penalty that fires on many of
them is miscalibrated (or misses something the game has). Reads the JSON
results of bench/eval_build.lua (one file per build, as written by the
ninja evaluation runs) and prints, per penalty kind, how many builds it
fires on and its average size; then the boss hit ratio spread.

    python3 bench/penalty_census.py <folder with eval JSON files> [key]

key: which evaluation inside each file to read (default "normalized": the
generator's configuration; "own" for the player's).
"""
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else "."
    key = sys.argv[2] if len(sys.argv) > 2 else "normalized"
    count, total = Counter(), Counter()
    examples = defaultdict(list)
    ratios = []
    builds = 0
    for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
        with open(path) as f:
            entry = json.load(f).get(key)
        if not entry:
            continue
        builds += 1
        if entry.get("bossRatio"):
            ratios.append(entry["bossRatio"])
        for penalty in entry.get("penalties", []):
            m = re.match(r"(.*?)\s*\(([\d.]+)\)$", penalty)
            label = re.sub(r"[\d.]+%?", "#", m.group(1) if m else penalty)[:80]
            count[label] += 1
            total[label] += float(m.group(2)) if m else 0
            if len(examples[label]) < 3:
                examples[label].append(os.path.basename(path)[:-5])
    print(f"{builds} builds ({key})")
    for label, n in count.most_common():
        print(f"{n:4d} {100 * n / max(builds, 1):5.1f}%  avg {total[label] / n:5.2f}  {label}  e.g. {', '.join(examples[label])}")
    if ratios:
        ratios.sort()
        q = lambda p: ratios[min(len(ratios) - 1, int(p * len(ratios)))]
        print("boss hit ratio (share of the worst pinnacle / uber hit survived): "
              + ", ".join(f"p{int(p * 100)} {q(p):.2f}" for p in (0.1, 0.25, 0.5, 0.75, 0.9)))


if __name__ == "__main__":
    main()
