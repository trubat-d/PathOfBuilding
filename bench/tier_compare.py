#!/usr/bin/env python3
"""Top players without the ultra high-end: a skill's saved player builds
scored like a generated build (eval_build.lua, COST=1), the showcases left out
(bench/playable.py), and the builds holding a chase item split off: a unique
priced over --max-unique divines, or one of CHASE (Mageblood, Headhunter, Pearl
of Tsoatha...). What is left is the mid-tier: the level a generated build is
compared with, at their median cost as its budget.

    python3 bench/tier_compare.py "Righteous Fire" [--max-unique 30] [--ours <xml> ...]

Run from the repository root (CODES: the saved poe.ninja codes folder).
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import playable

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODES = os.environ.get("CODES", "/home/claude/ninja/codes")
CHASE = {"Mageblood", "Headhunter", "Pearl of Tsoatha", "Original Sin", "Nimis", "Squire", "Progenesis",
         "Ashes of the Stars", "Voices", "Forbidden Flame", "Forbidden Flesh", "Watcher's Eye", "Kalandra's Touch",
         "Bottled Faith", "Dying Sun", "Militant Faith", "Glorious Vanity", "Lethal Pride", "Brutal Restraint", "Elegant Hubris"}


def lua_env():
    env = dict(os.environ)
    env["LUA_PATH"] = "../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
    return env


def evaluate(path, skill, timeout=900):
    env = dict(lua_env(), CODE=path, COST="1", SKILL=skill, FOCUS="DPS_FLOOR")
    p = subprocess.run(["luajit", os.path.join(ROOT, "bench", "eval_build.lua")], cwd=os.path.join(ROOT, "src"), env=env,
                       capture_output=True, text=True, timeout=timeout)
    for line in p.stdout.splitlines():
        if line.startswith("EVAL "):
            d = json.loads(line[5:])
            n = d.get("normalized") or d.get("own")
            cost = d.get("cost") or {}
            uniques = []
            for part in cost.get("parts") or []:
                m = re.match(r"^(\S+) (.*) ([\d.]+)( \(no price\))?$", part)
                if m and m.group(1) in ("gear", "jewel", "flask") and " rare " not in f" {m.group(2)} " and not m.group(2).split(" ", 2)[-1].startswith("rare "):
                    uniques.append((m.group(2), float(m.group(3))))
            return {"score": n["score"], "dps": n["dps"], "ehp": n["ehp"], "minHit": n["minHit"], "cost": cost.get("total"),
                    "class": d["summary"].get("class"), "uniques": d["summary"].get("uniques") or [], "priced": uniques}
    return {"error": (p.stderr or p.stdout)[-300:]}


def high_end(r, max_unique):
    why = []
    for u in r["uniques"]:
        title = u.split(": ", 1)[-1]
        if title.replace("Foulborn ", "") in CHASE:
            why.append(title)
    for label, price in r["priced"]:
        if price > max_unique:
            why.append(f"{label} {price:.0f} div")
    return why


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skill")
    ap.add_argument("--max-unique", type=float, default=30)
    ap.add_argument("--ours", nargs="*", default=[])
    args = ap.parse_args()
    prefix = args.skill.replace(" ", "_") + "__"
    files = sorted(f for f in os.listdir(CODES) if f.startswith(prefix) and f.endswith(".txt"))
    show = playable.showcase_set(CODES)
    rows = []
    for f in files:
        if f in show:
            print(f"{f}: showcase ({', '.join(show[f])})")
            continue
        r = evaluate(os.path.join(CODES, f), args.skill)
        if "error" in r:
            print(f"{f}: {r['error'][:120]}")
            continue
        r["file"] = f
        r["highEnd"] = high_end(r, args.max_unique)
        rows.append(r)
    fmt = lambda r: f"score {r['score']:.2f}  DPS {r['dps'] / 1e6:6.2f}M  EHP {r['ehp'] / 1e3:5.0f}k  max hit {r['minHit'] / 1e3:4.1f}k  cost {r['cost'] or 0:4.0f} div  {r['class']}"
    mid = [r for r in rows if not r["highEnd"]]
    print(f"\n{args.skill}: {len(mid)} mid-tier of {len(rows)} playable builds (no chase item, no unique over {args.max_unique:.0f} div)")
    for r in sorted(rows, key=lambda r: -r["score"]):
        tag = "high-end" if r["highEnd"] else "mid-tier"
        print(f"  {r['file']:<32} {tag:<9} {fmt(r)}" + (f"   ({', '.join(r['highEnd'][:4])})" if r["highEnd"] else ""))
    if mid:
        costs = [r["cost"] for r in mid if r.get("cost")]
        print(f"  mid-tier median: score {statistics.median(r['score'] for r in mid):.2f}  DPS {statistics.median(r['dps'] for r in mid) / 1e6:.2f}M  "
              f"cost {statistics.median(costs) if costs else 0:.0f} div (the budget to generate at)")
    for path in args.ours:
        r = evaluate(path, args.skill)
        if "error" not in r:
            print(f"  ours {os.path.basename(path)[:40]:<40} {fmt(r)}" + (f"   (uses {', '.join(high_end(r, args.max_unique)[:4])})" if high_end(r, args.max_unique) else ""))


if __name__ == "__main__":
    main()
