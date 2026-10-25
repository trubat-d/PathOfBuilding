#!/usr/bin/env python3
"""Tunes the generator's search settings with Optuna (TPE).

Each trial generates quick builds of a few skills (bench/bench_case.lua,
the model off so a trial only measures the settings) with settings proposed
by Optuna, and is scored by their mean score, less a small charge per second
so a setting doesn't win by searching twice as long. Only search settings
are tuned (path lengths, refine rounds, tree solver bonuses...), never the
score's own weights: a tuned score would only be better at pleasing itself.

The study is kept in an SQLite file, so a run can stop and continue later;
--report prints the best settings and the parameter importances.

    python3 bench/tune.py --src src --trials 40 [--jobs 2] [--db bench/results/tune.db]
    python3 bench/tune.py --report [--db bench/results/tune.db]
"""
import argparse
import concurrent.futures as cf
import json
import os
import subprocess

import optuna

CASES = [("Boneshatter", "Juggernaut"), ("Cyclone", "Slayer"), ("Righteous Fire", "Chieftain"),
         ("Winter Orb", "Occultist"), ("Tornado Shot", "Deadeye"), ("Arc", "Inquisitor")]
SECOND_COST = 0.002   # score charged per second of generation (a minute: 0.12)


def run_case(src, skill, asc, opts, timeout=1500):
    env = dict(os.environ)
    env["LUA_PATH"] = "../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
    env["GEN_OPTS"] = ",".join(f"{k}={v}" for k, v in opts.items())
    try:
        out = subprocess.run(["luajit", os.path.abspath(os.path.join(os.path.dirname(__file__), "bench_case.lua")),
                              skill, asc, "ENDGAME", "quick"], cwd=src, env=env, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return None
    for line in out.splitlines():
        if line.startswith("BENCH "):
            d = json.loads(line[6:])
            return d.get("score"), d.get("seconds")
    return None


def settings(trial):
    stay_scale = trial.suggest_float("treeSolverStayScale", 0.25, 4.0, log=True)
    stays = "|".join(f"{s * stay_scale:.4f}" for s in (0, 0.002, 0.004, 0.008, 0.016, 0.03))
    r1 = trial.suggest_int("quickRefine1", 4, 16)
    r2 = trial.suggest_int("quickRefine2", 0, 20)
    return {
        "useModel": "false",
        "maxPathDistance": trial.suggest_int("maxPathDistance", 5, 12),
        "refineBatch": trial.suggest_int("refineBatch", 2, 8),
        "swapDistance": trial.suggest_int("swapDistance", 4, 10),
        "ascendancyTargets": trial.suggest_int("ascendancyTargets", 5, 14),
        "treeSolverRounds": trial.suggest_int("treeSolverRounds", 1, 5),
        "treeSolverStay": stays,
        "quickRefineRounds": f"{r1}|{r2}" if r2 > 0 else f"{r1}|0",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="src")
    ap.add_argument("--trials", type=int, default=30)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--cases", type=int, default=4, help="skills per trial (first N of CASES)")
    ap.add_argument("--db", default="bench/results/tune.db")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()
    storage = f"sqlite:///{os.path.abspath(args.db)}"
    study = optuna.create_study(study_name="generator", storage=storage, direction="maximize", load_if_exists=True,
                                sampler=optuna.samplers.TPESampler(seed=1, n_startup_trials=8))
    if args.report:
        done = [t for t in study.trials if t.state == optuna.trial.TrialState.COMPLETE]
        print(f"{len(done)} trials")
        if done:
            best = study.best_trial
            print(f"best {best.value:.4f} (trial {best.number}): {best.params}")
            print(f"  per skill: {best.user_attrs.get('scores')}")
            base = next((t for t in done if t.user_attrs.get("baseline")), None)
            if base:
                print(f"defaults {base.value:.4f}: per skill {base.user_attrs.get('scores')}")
            if len(done) >= 10:
                for k, v in optuna.importance.get_param_importances(study).items():
                    print(f"  importance {k}: {v:.2f}")
        return
    cases = CASES[:args.cases]

    def objective(trial):
        opts = settings(trial)
        with cf.ThreadPoolExecutor(args.jobs) as pool:
            results = list(pool.map(lambda c: run_case(args.src, c[0], c[1], opts), cases))
        if any(r is None for r in results):
            raise optuna.TrialPruned()
        scores = [r[0] for r in results]
        seconds = [r[1] for r in results]
        trial.set_user_attr("scores", [round(s, 3) for s in scores])
        trial.set_user_attr("seconds", seconds)
        value = sum(scores) / len(scores) - SECOND_COST * sum(seconds) / len(seconds)
        print(f"trial {trial.number}: {value:.4f} scores {[round(s, 3) for s in scores]} seconds {seconds} {trial.params}", flush=True)
        return value

    # the current defaults first, as the reference
    if not study.trials:
        study.enqueue_trial({"treeSolverStayScale": 1.0, "quickRefine1": 8, "quickRefine2": 12, "maxPathDistance": 8,
                             "refineBatch": 4, "swapDistance": 7, "ascendancyTargets": 9, "treeSolverRounds": 3},
                            user_attrs={"baseline": True})
    study.optimize(objective, n_trials=args.trials)


if __name__ == "__main__":
    main()
