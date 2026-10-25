#!/usr/bin/env python3
"""Mines the unique packages top players combine: sets of 2 to 5 gear uniques
where every pair is used together far more often than chance (lift) in
several builds, from saved poe.ninja PoB codes (one file per build,
<Skill_Name>__<n>.txt). Writes src/Data/GeneratorUniquePackages.json, which
the generator tries as candidate packages (BuildGenerator:PlayerPackagesMove):
each is placed, the build adapted around it, and kept only when the
generator's own score improves.

    python3 bench/mine_packages.py <codes folder> [--out src/Data/GeneratorUniquePackages.json]
        [--min-builds 3] [--min-lift 8]
"""
import argparse
import base64
import collections
import glob
import itertools
import json
import os
import re
import zlib

# items every kind of build uses (their pairs say nothing about a package)
COMMON = {"Mageblood", "Headhunter", "Watcher's Eye", "Forbidden Flame", "Forbidden Flesh", "Impossible Escape",
          "Thread of Hope", "Elegant Hubris", "Glorious Vanity", "Lethal Pride", "Militant Faith",
          "Brutal Restraint", "Unnatural Instinct", "The Light of Meaning", "Kalandra's Touch"}
GEAR = {"Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring", "Belt", "Weapon", "Shield", "Quiver"}


def decode(path):
    code = open(path).read().strip().replace("-", "+").replace("_", "/")
    return zlib.decompress(base64.b64decode(code + "=" * (-len(code) % 4))).decode("utf-8", "replace")


def gear_uniques(xml):
    """Unique gear items equipped in gear slots: { name }"""
    items = {}
    for m in re.finditer(r'<Item id="(\d+)"[^>]*>(.*?)</Item>', xml, re.S):
        lines = [l.strip() for l in m.group(2).split("\n") if l.strip()]
        if not any(l in ("Rarity: UNIQUE", "Rarity: RELIC") for l in lines):
            continue
        i = next(k for k, l in enumerate(lines) if l.startswith("Rarity:"))
        items[m.group(1)] = re.sub(r"^Foulborn ", "", lines[i + 1])
    out = set()
    for tag in re.findall(r"<Slot [^>]*>", xml):
        slot = (re.search(r'name="([^"]+)"', tag) or [None, ""])[1]
        item_id = (re.search(r'itemId="(\d+)"', tag) or [None, ""])[1]
        if "Swap" in slot or "Flask" in slot or "Jewel" in slot or "Abyssal" in slot:
            continue
        if item_id in items and items[item_id] not in COMMON:
            out.add(items[item_id].replace("&apos;", "'"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("codes")
    ap.add_argument("--out", default="src/Data/GeneratorUniquePackages.json")
    ap.add_argument("--min-builds", type=int, default=3)
    ap.add_argument("--min-lift", type=float, default=8.0)
    args = ap.parse_args()
    builds = []
    for path in sorted(glob.glob(os.path.join(args.codes, "*.txt"))):
        skill = os.path.basename(path).rsplit("__", 1)[0].replace("_", " ")
        try:
            builds.append((skill, gear_uniques(decode(path))))
        except Exception:
            continue
    n = len(builds)
    count = collections.Counter(u for _, us in builds for u in us)
    pairs = collections.Counter()
    for _, us in builds:
        for a, b in itertools.combinations(sorted(us), 2):
            pairs[(a, b)] += 1
    strong = set()
    for (a, b), k in pairs.items():
        if k >= args.min_builds and k * n / (count[a] * count[b]) >= args.min_lift:
            strong.add((a, b))
    neighbours = collections.defaultdict(set)
    for a, b in strong:
        neighbours[a].add(b)
        neighbours[b].add(a)
    # maximal cliques (Bron-Kerbosch), 2 to 5 items
    cliques = []
    def bk(r, p, x):
        if not p and not x:
            if 2 <= len(r) <= 5:
                cliques.append(sorted(r))
            return
        for v in list(p):
            bk(r | {v}, p & neighbours[v], x & neighbours[v])
            p = p - {v}
            x = x | {v}
    bk(set(), set(neighbours), set())
    packages = []
    for c in cliques:
        users = [skill for skill, us in builds if set(c) <= us]
        if len(users) < 2:
            continue
        packages.append({"uniques": c, "builds": len(users), "skills": dict(collections.Counter(users))})
    packages.sort(key=lambda p: (-p["builds"], -len(p["uniques"]), p["uniques"]))
    with open(args.out, "w") as f:
        json.dump({"version": 1, "source": "poe.ninja top players", "players": n, "packages": packages}, f, indent=1)
    print(f"{n} builds, {len(strong)} strong pairs, {len(packages)} packages -> {args.out}")
    for p in packages[:25]:
        print(f"  {p['builds']:2d} builds  {' + '.join(p['uniques'])}   {p['skills']}")


if __name__ == "__main__":
    main()
