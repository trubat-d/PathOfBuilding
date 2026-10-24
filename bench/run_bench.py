"""Runs the benchmark cases and compares with the previous results.
    python3 bench/run_bench.py [label] [--cases bench/cases.txt] [--jobs 2] [--only text]
Each case is a headless generation (bench_case.lua); results go to
bench/results/<label>.jsonl, then compare.py prints the table.
Mode "auto" does what the app's automatic mode does: a quick build of every
archetype that fits the skill, then full builds of the best --auto-top ones
(the best full build is the case's result, marked "auto": true).
"""
import argparse
import datetime
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "src")
save_dir = ""  # generated builds are saved here (results/<label>/)


def read_cases(path, only):
    cases = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            while len(parts) < 5:
                parts.append("")
            if only and only.lower() not in line.lower():
                continue
            cases.append(parts[:5])
    return cases


def run_case(case):
    skill, asc, inv, mode, arch = case
    cmd = ["luajit", os.path.join(here, "bench_case.lua"), skill, asc, inv, mode or "quick"]
    if arch:
        cmd.append(arch)
    env = dict(os.environ, LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;", BENCH_SAVE=save_dir)
    proc = subprocess.run(cmd, cwd=src, env=env, capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        if line.startswith("BENCH "):
            return line[6:]
    err = (proc.stderr or proc.stdout).strip().splitlines()[-1:] or ["no output"]
    import json
    return json.dumps({"skill": skill, "ascendancy": asc, "investment": inv, "mode": mode or "quick",
                       "archetype": arch or None, "error": err[0][:300]})


def list_archetypes(case):
    skill, asc, inv, mode, arch = case
    cmd = ["luajit", os.path.join(here, "bench_case.lua"), skill, asc, inv, "quick", "LIST"]
    env = dict(os.environ, LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;")
    proc = subprocess.run(cmd, cwd=src, env=env, capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        if line.startswith("ARCHETYPES "):
            return [a for a in line[11:].split(",") if a]
    return []


def run_auto(case, pool, top):
    """Quick scan of every archetype, then full builds of the best ones."""
    import json
    skill, asc, inv, mode, arch = case
    quick_cases = [[skill, asc, inv, "quick", a] for a in list_archetypes(case)]
    quick = [json.loads(l) for l in pool.map(run_case, quick_cases)]
    ranked = sorted([q for q in quick if q.get("score") is not None], key=lambda q: -q["score"])
    full_cases = [[skill, asc, inv, "full", q["archetype"]] for q in ranked[:top]]
    full = [json.loads(l) for l in pool.map(run_case, full_cases)]
    best = max([f for f in full if f.get("score") is not None], key=lambda f: f["score"], default=None)
    lines = [json.dumps(dict(q, scan=True)) for q in quick] + [json.dumps(f) for f in full if f is not best]
    if best:
        lines.append(json.dumps(dict(best, auto=True)))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("label", nargs="?", default=datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    ap.add_argument("--cases", default=os.path.join(here, "cases.txt"))
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--only", default="")
    ap.add_argument("--src", default="", help="run another copy of the src folder (e.g. a snapshot)")
    ap.add_argument("--auto-top", type=int, default=2, help="auto mode: full builds of the best N archetypes")
    args = ap.parse_args()
    global src
    if args.src:
        src = args.src
    cases = read_cases(args.cases, args.only)
    os.makedirs(os.path.join(here, "results"), exist_ok=True)
    out = os.path.join(here, "results", args.label + ".jsonl")
    global save_dir
    save_dir = os.path.join(here, "results", args.label)
    os.makedirs(save_dir, exist_ok=True)
    with ThreadPoolExecutor(args.jobs) as pool, open(out, "w") as f:
        plain = [c for c in cases if c[3] != "auto"]
        for line in pool.map(run_case, plain):
            f.write(line + "\n")
            f.flush()
        for case in cases:
            if case[3] == "auto":
                for line in run_auto(case, pool, args.auto_top):
                    f.write(line + "\n")
                    f.flush()
    print("Results:", out)
    subprocess.run([sys.executable, os.path.join(here, "compare.py"), out])


if __name__ == "__main__":
    main()
