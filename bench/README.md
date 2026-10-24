# Build generator benchmark

Runs fixed generations headless and compares them with the previous run, so a
change to scoring or search can be measured instead of guessed.

```
python3 bench/run_bench.py <label>                         # quick builds (cases.txt), ~1 min each
python3 bench/run_bench.py <label> --cases bench/cases_full.txt   # full builds, ~5 min each
python3 bench/run_bench.py <label> --only "Ball Lightning" --jobs 2
python3 bench/compare.py bench/results/<label>.jsonl bench/results/<other>.jsonl
```

Needs `luajit` and Python 3; run from the repository root. Each line of the
cases files is `skill | ascendancy | investment | quick or full | archetype`.
Results (`bench/results/*.jsonl`, not committed) hold score, DPS, lowest max
hit, EHP, sustain, penalties, keystones, supports and the generator log.

`--src` runs another copy of the `src` folder (a snapshot), so the code can be
edited while a long run is going. `META_DETAILS=<file.json>` gives
`bench_case.lua` saved poe.ninja top player details for offline runs.
