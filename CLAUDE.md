# POBIA - Path of Building with a build generator

This is a fork of Path of Building Community (PoE 1) with a build generator
(`src/Classes/BuildGenerator.lua`, `src/Modules/GeneratorSearch.lua`, `src/Classes/BuildScorer.lua`)
and tools for working on builds with agents (`buildlab/`).

## Working on builds
- Use the `build-concept` skill: it coordinates the agents in `.claude/agents/`
  (theorycrafter, mechanics-checker, pob-builder, economist, critic).
- Tools are in `buildlab/tools/` (see `buildlab/README.md`). Run them from the repository root.
  First time on a new machine: `buildlab/tools/setup.sh`.
- Build work goes in `buildlab/concepts/<slug>/`.

## Rules
- Path of Exile 1, patch 3.29. Verify mechanics (poewiki, poedb) before relying on them.
- Numbers come from `buildlab/tools/eval.sh`, never from memory.
- Prices from poe.ninja are the cheapest copy (a low roll); default budget 30 div at week-one prices.
- Be polite with poe.ninja / poewiki: no rapid-fire requests (a few seconds between calls).
