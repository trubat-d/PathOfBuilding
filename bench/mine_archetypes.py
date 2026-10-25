#!/usr/bin/env python3
"""Mines each skill's top-player archetype from saved poe.ninja PoB codes
(one file per build, <Skill_Name>__<n>.txt): the keystones, gear uniques and
main-link supports most of that skill's top players share. Writes
src/Data/GeneratorPlayerArchetypes.json, which BuildArchetypes offers as one
more archetype for that skill ("PLAYERS"): the automatic mode builds it like
the others and keeps it only when its own score is the best. The generator's
design isn't replaced, the players' choices are one more candidate it tests.

    python3 bench/mine_archetypes.py <codes folder> [--tree src/TreeData/3_29/tree.lua]
        [--out src/Data/GeneratorPlayerArchetypes.json] [--keystone 0.5] [--unique 0.4] [--support 0.5]
"""
import argparse
import base64
import collections
import glob
import json
import os
import re
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import playable  # (showcase builds left out: bench/playable.py)

GEAR = ("Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Ring 2", "Belt", "Weapon 1", "Weapon 2")


def decode(path):
    code = open(path).read().strip().replace("-", "+").replace("_", "/")
    return zlib.decompress(base64.b64decode(code + "=" * (-len(code) % 4))).decode("utf-8", "replace")


def keystone_ids(tree_path):
    s = open(tree_path).read()
    out = {}
    for m in re.finditer(r'\[(\d+)\]=\s*\{\s*\["skill"\]=\s*\d+,\s*\["name"\]=\s*"([^"]+)",[^{}]*?\["isKeystone"\]=\s*true', s):
        out[m.group(1)] = m.group(2)
    return out


def parse(xml, skill, keystones):
    spec = re.search(r'<Spec [^>]*nodes="([^"]*)"', xml)
    nodes = set(spec.group(1).split(",")) if spec else set()
    ks = sorted({keystones[n] for n in nodes if n in keystones})
    items = {}
    for m in re.finditer(r'<Item id="(\d+)"[^>]*>(.*?)</Item>', xml, re.S):
        lines = [l.strip() for l in m.group(2).split("\n") if l.strip()]
        if any(l in ("Rarity: UNIQUE", "Rarity: RELIC") for l in lines):
            i = next(k for k, l in enumerate(lines) if l.startswith("Rarity:"))
            items[m.group(1)] = re.sub(r"^Foulborn ", "", lines[i + 1]).replace("&apos;", "'")
    uniques = {}
    for tag in re.findall(r"<Slot [^>]*>", xml):
        slot = (re.search(r'name="([^"]+)"', tag) or [None, ""])[1]
        item_id = (re.search(r'itemId="(\d+)"', tag) or [None, ""])[1]
        if slot in GEAR and item_id in items:
            uniques[items[item_id]] = slot
    supports = set()
    for group in re.findall(r"<Skill [^>]*>(.*?)</Skill>", xml, re.S):
        names = re.findall(r'<Gem [^>]*nameSpec="([^"]*)"[^>]*enabled="true"|<Gem [^>]*enabled="true"[^>]*nameSpec="([^"]*)"', group)
        names = [a or b for a, b in names]
        # (the skill's own group: Vaal and transfigured versions count as it)
        if any(n and skill in n for n in names):
            for n in names:
                if n and skill not in n:
                    supports.add(n)
            break
    return ks, uniques, supports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("codes")
    ap.add_argument("--tree", default="src/TreeData/3_29/tree.lua")
    ap.add_argument("--out", default="src/Data/GeneratorPlayerArchetypes.json")
    ap.add_argument("--keystone", type=float, default=0.5)
    ap.add_argument("--unique", type=float, default=0.4)
    ap.add_argument("--support", type=float, default=0.5)
    ap.add_argument("--keep-showcase", action="store_true", help="keep builds bench/playable.py flags as showcases")
    args = ap.parse_args()
    keystones = keystone_ids(args.tree)
    by_skill = collections.defaultdict(list)
    showcases = {} if args.keep_showcase else playable.showcase_set(args.codes)
    for path in sorted(glob.glob(os.path.join(args.codes, "*.txt"))):
        if os.path.basename(path) in showcases:
            continue
        skill = os.path.basename(path).rsplit("__", 1)[0].replace("_", " ")
        try:
            by_skill[skill].append(parse(decode(path), skill, keystones))
        except Exception:
            continue
    out = {}
    for skill, builds in sorted(by_skill.items()):
        n = len(builds)
        if n < 3:
            continue
        kc = collections.Counter(k for ks, _, _ in builds for k in ks)
        uc = collections.Counter(u for _, us, _ in builds for u in us)
        slots = {}
        for _, us, _ in builds:
            for u, slot in us.items():
                slots.setdefault(u, slot)
        sc = collections.Counter(s for _, _, ss in builds for s in ss)
        entry = {
            "builds": n,
            "keystones": [k for k, c in kc.most_common() if c / n >= args.keystone],
            "uniques": [u for u, c in uc.most_common() if c / n >= args.unique],
            "supports": [s for s, c in sc.most_common() if c / n >= args.support],
            "shares": {**{k: round(c / n, 2) for k, c in kc.items() if c / n >= args.keystone},
                       **{u: round(c / n, 2) for u, c in uc.items() if c / n >= args.unique}},
        }
        if entry["keystones"] or entry["uniques"]:
            out[skill] = entry
    with open(args.out, "w") as f:
        json.dump({"version": 1, "source": "poe.ninja top players", "skills": out}, f, indent=1, sort_keys=True)
    print(f"{len(out)} skills -> {args.out}")
    for skill in ("Righteous Fire", "Winter Orb", "Cyclone", "Ethereal Knives", "Boneshatter", "Tornado Shot"):
        if skill in out:
            e = out[skill]
            print(f"  {skill} ({e['builds']}): keystones {e['keystones']}, uniques {e['uniques']}, supports {e['supports']}")


if __name__ == "__main__":
    main()
