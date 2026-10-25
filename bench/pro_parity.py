#!/usr/bin/env python3
"""Generated builds against top players' builds at the same budget.

For each skill: the saved top-player builds (poe.ninja codes, CODES folder)
are scored with the generator's scorer and priced like a generated build
(eval_build.lua COST=1); the most common ascendancy among them is kept, and a
full build is generated for that skill and ascendancy with the median price of
those players' builds as its total budget, without the players' data (no
META_DETAILS: the generator designs the build itself). The generated build is
then scored and priced the same way (eval_build.lua on its saved XML), so both
sides go through the same calculator, configuration and price list.

    python3 bench/pro_parity.py --label parity1 [--skills "Boneshatter,Tornado Shot"] [--pros 4] [--jobs 2] [--src <src snapshot>]

Run from the repository root. Writes bench/results/<label>.jsonl (one line per
skill) and prints a table. Prices: items whose worth is in their rolls
(Watcher's Eye, Forbidden Flame/Flesh, timeless jewel seeds) are priced at their
cheapest version on both sides, so player builds cost more in the game.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CODES = os.environ.get("CODES", "/home/claude/ninja/codes")
DEFAULT_SKILLS = ["Boneshatter", "Tornado Shot", "Righteous Fire", "Cyclone", "Toxic Rain", "Lightning Arrow",
                  "Ethereal Knives", "Winter Orb"]


def lua_env():
    return dict(os.environ, LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;")


def evaluate(src, path, skill, timeout=600):
    env = dict(lua_env(), CODE=path, COST="1", SKILL=skill, FOCUS="DPS_FLOOR")
    p = subprocess.run(["luajit", os.path.join(ROOT, "bench", "eval_build.lua")], cwd=src, env=env,
                       capture_output=True, text=True, timeout=timeout)
    for line in p.stdout.splitlines():
        if line.startswith("EVAL "):
            d = json.loads(line[5:])
            n = d.get("normalized") or d.get("own")
            return {"score": n["score"], "dps": n["dps"], "minHit": n["minHit"], "ehp": n["ehp"],
                    "cost": (d.get("cost") or {}).get("total"), "class": d["summary"].get("class"),
                    "uniques": d["summary"].get("uniques"), "keystones": d["summary"].get("keystones")}
    return {"error": (p.stderr or p.stdout)[-400:]}


def generate(src, skill, asc, budget, save_dir, timeout=3600):
    env = dict(lua_env(), BUDGET=str(round(budget, 1)), FOCUS="DPS_FLOOR", BENCH_SAVE=save_dir)
    p = subprocess.run(["luajit", os.path.join(ROOT, "bench", "bench_case.lua"), skill, asc, "ENDGAME", "full"],
                       cwd=src, env=env, capture_output=True, text=True, timeout=timeout)
    for line in p.stdout.splitlines()[::-1]:
        if line.startswith("BENCH "):
            r = json.loads(line[6:])
            r.pop("log", None)
            return r
    return {"error": (p.stderr or p.stdout)[-400:]}


def run_skill(args, skill):
    src = args.src
    files = sorted(f for f in os.listdir(CODES) if f.startswith(skill.replace(" ", "_") + "__") and f.endswith(".txt"))
    files = sorted(files, key=lambda f: int(f.rsplit("__", 1)[1][:-4]))[: args.pros * 2]
    pros = []
    for f in files:
        r = evaluate(src, os.path.join(CODES, f), skill)
        if "error" not in r:
            r["file"] = f
            pros.append(r)
    if not pros:
        return {"skill": skill, "error": "no player build could be evaluated"}
    asc = Counter(p["class"] for p in pros).most_common(1)[0][0]
    pros = [p for p in pros if p["class"] == asc][: args.pros]
    costs = [p["cost"] for p in pros if p.get("cost")]
    budget = statistics.median(costs) if costs else 100
    save_dir = os.path.join(ROOT, "bench", "results", args.label)
    os.makedirs(save_dir, exist_ok=True)
    gen = generate(src, skill, asc, budget, save_dir)
    ours = None
    if "error" not in gen and gen.get("xml"):
        ours = evaluate(src, gen["xml"], skill)
    row = {"skill": skill, "ascendancy": asc, "budget": budget, "pros": pros, "generated": gen, "ours": ours}
    with open(os.path.join(ROOT, "bench", "results", args.label + ".jsonl"), "a") as f:
        f.write(json.dumps(row) + "\n")
    print_row(row)
    return row


def fmt(x, unit=""):
    if x is None:
        return "-"
    if x >= 1e6:
        return f"{x / 1e6:.1f}M{unit}"
    if x >= 1e3:
        return f"{x / 1e3:.0f}k{unit}"
    return f"{x:.1f}{unit}"


def print_row(row):
    if "error" in row:
        print(f"{row['skill']}: {row['error']}")
        return
    pros, ours = row["pros"], row["ours"] or {}
    med = lambda k: statistics.median([p[k] for p in pros if p.get(k) is not None]) if pros else None
    best = max(pros, key=lambda p: p["score"])
    print(f"{row['skill']} ({row['ascendancy']}), budget {row['budget']:.0f} div:")
    print(f"   players (median of {len(pros)}): score {med('score'):.2f}  DPS {fmt(med('dps'))}  max hit {fmt(med('minHit'))}  EHP {fmt(med('ehp'))}  cost {med('cost'):.0f} div")
    print(f"   best player:              score {best['score']:.2f}  DPS {fmt(best['dps'])}  max hit {fmt(best['minHit'])}  EHP {fmt(best['ehp'])}  cost {best['cost'] or 0:.0f} div")
    if ours and "score" in ours:
        print(f"   generated:                score {ours['score']:.2f}  DPS {fmt(ours['dps'])}  max hit {fmt(ours['minHit'])}  EHP {fmt(ours['ehp'])}  cost {ours['cost'] or 0:.0f} div")
    else:
        print(f"   generated: failed ({(row['generated'] or {}).get('error', '')[:200]})")
    sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--skills", default=",".join(DEFAULT_SKILLS))
    ap.add_argument("--pros", type=int, default=3)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--src", default=os.path.join(ROOT, "src"))
    args = ap.parse_args()
    skills = [s.strip() for s in args.skills.split(",") if s.strip()]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(lambda s: run_skill(args, s), skills))


if __name__ == "__main__":
    main()
