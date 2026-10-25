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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import playable

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


def list_archetypes(src, skill, asc):
    p = subprocess.run(["luajit", os.path.join(ROOT, "bench", "bench_case.lua"), skill, asc, "ENDGAME", "quick", "LIST"],
                       cwd=src, env=lua_env(), capture_output=True, text=True, timeout=600)
    for line in p.stdout.splitlines():
        if line.startswith("ARCHETYPES "):
            return [a for a in line[11:].split(",") if a]
    return []


def run_bench(src, skill, asc, budget, mode, arch, save_dir, timeout=3600):
    env = dict(lua_env(), BUDGET=str(round(budget, 1)), FOCUS="DPS_FLOOR", BENCH_SAVE=save_dir)
    cmd = ["luajit", os.path.join(ROOT, "bench", "bench_case.lua"), skill, asc, "ENDGAME", mode] + ([arch] if arch else [])
    try:
        p = subprocess.run(cmd, cwd=src, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": "timeout"}
    for line in p.stdout.splitlines()[::-1]:
        if line.startswith("BENCH "):
            r = json.loads(line[6:])
            r.pop("log", None)
            return r
    return {"error": (p.stderr or p.stdout)[-400:]}


def generate_auto(src, skill, asc, budget, save_dir, top, jobs):
    """As the app's automatic mode: a quick build of every archetype that fits,
    then full builds of the best `top` by quick score plus the archetype's learnt
    full-build gain (src/Data/GeneratorPriors.json); the best full build kept."""
    archs = list_archetypes(src, skill, asc)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        quick = list(pool.map(lambda a: dict(run_bench(src, skill, asc, budget, "quick", a, save_dir), archetype=a), archs))
    try:
        priors = json.load(open(os.path.join(src, "Data", "GeneratorPriors.json")))
    except Exception:
        priors = {"globalUplift": 2.8, "archetypes": {}}
    def priority(q):
        pr = priors.get("archetypes", {}).get(q["archetype"], {"uplift": 0, "count": 0})
        return q["score"] + (pr.get("uplift", 0) * pr.get("count", 0) + priors.get("globalUplift", 2.8) * 2) / (pr.get("count", 0) + 2)
    ranked = sorted([q for q in quick if q.get("score") is not None], key=lambda q: -priority(q))
    picked = [q["archetype"] for q in ranked[:top]]
    # the build doctor's combinations of commitments (Classes/BuildDoctor:PredictCombos),
    # predicted on the best quick build: built fully too
    combos = []
    if ranked and os.environ.get("NO_COMBOS") != "1":
        xml = os.path.join(save_dir, f"{skill.replace(' ', '')}_{asc}_ENDGAME_quick_{ranked[0]['archetype']}.xml")
        if os.path.exists(xml):
            env = dict(lua_env(), OURS=xml, STEP="combos", INVEST="ENDGAME")
            if "playerKnowledge=false" in os.environ.get("GEN_OPTS", ""):
                env["PLAYER_KNOWLEDGE"] = "0"
            p = subprocess.run(["luajit", os.path.join(ROOT, "bench", "stage_test.lua")], cwd=src, env=env, capture_output=True, text=True, timeout=1800)
            for line in p.stdout.splitlines():
                if line.startswith("COMBO "):
                    combos.append(line.split()[1])
    for c in combos:
        if len([x for x in picked if "+" in x]) >= 2:
            break
        if "+" in c and c not in picked:
            picked.append(c)
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        full = list(pool.map(lambda a: dict(run_bench(src, skill, asc, budget, "full", a, save_dir), archetype=a), picked))
    best = max([f for f in full if f.get("score") is not None], key=lambda f: f["score"], default=None)
    if best:
        best["scan"] = [{"archetype": q["archetype"], "quick": q.get("score")} for q in ranked]
        best["fullTried"] = [{"archetype": f["archetype"], "score": f.get("score")} for f in full]
        best["combos"] = combos
    return best or {"error": "no full build"}


def run_skill(args, skill):
    src = args.src
    files = sorted(f for f in os.listdir(CODES) if f.startswith(skill.replace(" ", "_") + "__") and f.endswith(".txt"))
    # (showcase builds - a DPS number with no defences - aren't a target: bench/playable.py)
    if not getattr(args, "keep_showcase", False):
        bad = playable.showcase_set(CODES)
        for f in files:
            if f in bad:
                print(f"   {f} left out (showcase: {', '.join(bad[f])})")
        files = [f for f in files if f not in bad]
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
    gen = generate_auto(src, skill, asc, budget, save_dir, args.auto, args.jobs) if args.auto else generate(src, skill, asc, budget, save_dir)
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
        arch = (row['generated'] or {}).get('archetype')
        print(f"   generated{' (' + arch + ')' if arch else ''}:  score {ours['score']:.2f}  DPS {fmt(ours['dps'])}  max hit {fmt(ours['minHit'])}  EHP {fmt(ours['ehp'])}  cost {ours['cost'] or 0:.0f} div")
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
    ap.add_argument("--keep-showcase", action="store_true", help="keep builds bench/playable.py flags as showcases")
    ap.add_argument("--auto", type=int, default=0, help="as the app's automatic mode: scan every archetype, full builds of the best N")
    args = ap.parse_args()
    skills = [s.strip() for s in args.skills.split(",") if s.strip()]
    # (auto mode: one skill at a time, its archetypes in parallel)
    with ThreadPoolExecutor(max_workers=1 if args.auto else args.jobs) as pool:
        list(pool.map(lambda s: run_skill(args, s), skills))


if __name__ == "__main__":
    main()
