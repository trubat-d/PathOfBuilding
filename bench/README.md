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
cases files is `skill | ascendancy | investment | quick, full or auto | archetype`.
`auto` does what the app's automatic mode does: a quick build of every
archetype that fits the skill, then full builds of the best `--auto-top` (3)
ones; the best full build is marked `"auto": true`.
Results (`bench/results/*.jsonl`, not committed) hold score, DPS, lowest max
hit, EHP, sustain, penalties, keystones, supports and the generator log.

`--src` runs another copy of the `src` folder (a snapshot), so the code can be
edited while a long run is going. `META_DETAILS=<file.json>` gives
`bench_case.lua` saved poe.ninja top player details for offline runs.

## Comparing with top players

```
CODE=<file with a PoB code> luajit ../bench/eval_build.lua        # score a build with the generator's scorer
CODE=<file> luajit ../bench/ablate_build.lua                      # what each part of it is worth (removed one at a time)
OURS=<generated .xml> CODE=<file> luajit ../bench/transplant.lua  # each part of it put into a generated build
```

Run them from the `src` folder (with `LUA_PATH` as for the benchmark). Benchmark
runs save each generated build as `results/<label>/<case>.xml` for this.
`FOCUS=` and `TIER=uber|pinnacle` choose the scorer settings (default
`DPS_FLOOR`, `uber`). `cases_pro*.txt` hold endgame (and mirror tier) cases
for skills with saved top-player builds; `cases_pro_arch2.txt` uses the
archetypes the players use (impale, Hatred, crit).

## Other tools

* `profile_gen.lua "<Skill>" "<Ascendancy>" <investment> <quick|full>` (`ARCH=`): time per
  generator method and calculator runs.
* `stage_test.lua` (`OURS=`, `STEP=flasks|uniquejewels|uniquesweep|uniqueflasks|aurastack|metajewels|fillmain|finalrares|ascendancy|supports|refine|rares`):
  one generator step on a saved build (`CRAFTS=0`: rares without bench crafts).
* `worker_test.lua '<job json>'`: a generation the way a background thread runs
  it (`Modules/GeneratorWorker.lua`).
* `popup_test.lua` (`SKILL=`, `ASC=`, `INVEST=`, `WORKERS=`): the Generate
  Build window's automatic mode headless, background threads replaced by
  worker processes (`worker_proc.lua`).
