#!/usr/bin/env python3
"""Self-tuning: tries generator settings on the benchmark and keeps the best.

Each setting (GEN_OPTS) builds every case; the builds are then scored by the
same reference scorer (the src folder's, with its default settings:
bench/rescore.lua), so settings that change how the generator scores during
the search can be compared fairly. Prints a table, best first.

  python3 bench/tune.py --cases bench/cases_tune.txt --jobs 2 \
      --try "" --try "lensWeight=0.5" --try "pastTarget=0.5,fightWeight=1"
"""
import argparse, json, os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))


def rescore(src, xml, focus):
    env = dict(os.environ, LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;", FILES=xml, FOCUS=focus)
    p = subprocess.run(["luajit", os.path.join(here, "rescore.lua")], cwd=src, env=env, capture_output=True, text=True)
    for line in p.stdout.splitlines():
        if line.startswith("RESCORE"):
            return float(line.split()[2])
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--src", default=os.path.join(here, "..", "src"))
    ap.add_argument("--focus", default="DPS_FLOOR")
    ap.add_argument("--try", dest="tries", action="append", default=[], help="GEN_OPTS of one setting (repeat)")
    ap.add_argument("--label", default="tune")
    args = ap.parse_args()
    rows = []
    for i, opts in enumerate(args.tries):
        label = "%s%d" % (args.label, i)
        env = dict(os.environ, GEN_OPTS=opts, FOCUS=args.focus)
        subprocess.run([sys.executable, os.path.join(here, "run_bench.py"), label, "--cases", args.cases, "--jobs", str(args.jobs), "--src", args.src],
                       env=env, capture_output=True, text=True)
        total, n, per = 0.0, 0, {}
        path = os.path.join(here, "results", label + ".jsonl")
        for line in open(path):
            d = json.loads(line)
            if d.get("xml"):
                s = rescore(args.src, d["xml"], args.focus)
                if s is not None:
                    total += s; n += 1; per[d["skill"]] = round(s, 2)
        rows.append((total, n, opts or "(defaults)", per))
        print("%-40s total %.2f over %d builds  %s" % (opts or "(defaults)", total, n, per), flush=True)
    rows.sort(key=lambda r: -r[0])
    print("\nbest first:")
    for total, n, opts, per in rows:
        print("  %-40s %.2f (%d builds)" % (opts, total, n))


if __name__ == "__main__":
    main()
