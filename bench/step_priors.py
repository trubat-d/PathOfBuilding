#!/usr/bin/env python3
"""Builds src/Data/GeneratorStepPriors.json: what each late generator step
gained on test builds, by kind of build (budget | attack, spell or minion),
in the form of the user folder's GeneratorKnowledge.json "steps". The
generator counts these with the user's own builds when deciding to skip a
step that never helps builds of a kind (Modules/GeneratorKnowledge
ShouldSkip): a step that helped none of the test builds of a kind is judged
sooner, and one gain anywhere keeps it.

    python3 bench/step_priors.py <decision logs...> [--out src/Data/GeneratorStepPriors.json]

The logs are full generations with DECISION_LOG set ("step" lines: score
gain and seconds of each step).
"""
import json
import sys
from collections import defaultdict

KEPT = 0.005  # a gain above this counts as the step helping (as GeneratorKnowledge)

# Only steps that work the same on the test machine as for a player and cost
# time: the ones using downloaded player data (LearnFromTopBuilds,
# PopularPassivesMove, ChooseMetaUniques, ChooseArchetypeJewels...) or a
# player's own past builds can't help on a machine without them, which says
# nothing about a player's PoB
STEPS = {"PairAilments", "PermanentFlaskMove", "UniqueCombosMove", "SupremeOstentationMove",
         "ChooseTimelessJewel", "ChooseRadiusJewels", "CorruptionMove"}


def kind(tags):
    return "minion" if "minion" in tags else "attack" if "attack" in tags else "spell"


def main():
    args = sys.argv[1:]
    out = "src/Data/GeneratorStepPriors.json"
    if "--out" in args:
        i = args.index("--out")
        out = args[i + 1]
        args = args[:i] + args[i + 2:]
    steps = defaultdict(lambda: defaultdict(lambda: {"tries": 0, "kept": 0, "gain": 0.0, "seconds": 0.0}))
    builds = 0
    for path in args:
        runs, lines = {}, []
        with open(path) as f:
            for line in f:
                if '"type":"run"' in line:
                    r = json.loads(line)
                    runs[r["id"]] = r
                elif '"k":"step"' in line:
                    lines.append(json.loads(line))
        seen = set()
        for r in lines:
            run = runs.get(r.get("run"))
            if not run or r.get("skipped") or r.get("g") is None or r.get("n") not in STEPS:
                continue
            context = f'{run.get("investment", "?")}|{kind(run.get("tags", []))}'
            s = steps[context][r["n"]]
            s["tries"] += 1
            if r["g"] > KEPT:
                s["kept"] += 1
            s["gain"] = round(s["gain"] + max(0.0, r["g"]), 4)
            s["seconds"] = round(s["seconds"] + (r.get("sec") or 0), 1)
            seen.add(r["run"])
        builds += len(seen)
    with open(out, "w") as f:
        json.dump({"version": 1, "builds": builds, "steps": steps}, f, indent=0, sort_keys=True)
    print(f"{builds} builds, {sum(len(v) for v in steps.values())} step/context entries -> {out}")
    for context, by_step in sorted(steps.items()):
        never = [f'{n} ({s["tries"]})' for n, s in sorted(by_step.items()) if s["kept"] == 0 and s["tries"] >= 3]
        print(f"  {context}: never helped: {', '.join(never) or '-'}")


if __name__ == "__main__":
    main()
