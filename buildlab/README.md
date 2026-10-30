# buildlab - building Path of Exile builds with Claude Code agents

Five agents (in `.claude/agents/`) work on build concepts together, coordinated by the
`build-concept` skill, using this repo's headless Path of Building and build generator.

| Agent | Job |
|---|---|
| theorycrafter | build ideas: core mechanic, key items, scaling, defence plan |
| mechanics-checker | verifies interactions on poewiki / poedb, says whether PoB models them |
| pob-builder | assembles the build in Path of Building and reports its real numbers |
| economist | prices it at the budget and league phase, finds cheaper replacements |
| critic | reviews it like a player: what fails in game, PoB blind spots, nonsense |

## Start
1. Open this repository in Claude Code: the desktop app's Code tab or the CLI on Linux / macOS /
   WSL, or Claude Code on the web (claude.ai/code) with the GitHub repository.
   On native Windows the tools need LuaJIT: use WSL or the web version.
2. First time: ask Claude to run `buildlab/tools/setup.sh` (installs LuaJIT + lua-utf8).
3. Ask for a build, for example:
   - "Use the build-concept skill: a 30 div league starter for Toxic Rain."
   - "Use the build-concept skill on this idea: <pobb.in link>, budget 50 div at mid league."
   - "Have the critic review https://pobb.in/..."
   You can also call one agent directly: `@"critic (agent)" review buildlab/concepts/x/v2.xml`.
4. Claude Code asks before running each new kind of command; approving "always allow" for
   `buildlab/tools/*` and the poewiki / poedb / poe.ninja sites saves many prompts.

Optional, more autonomous: agent teams (experimental) let the agents message each other.
Set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (environment, or `env` in your Claude Code
settings) and ask for "an agent team with the theorycrafter, critic and pob-builder".
It uses much more of your usage.

## Usage on a Max plan
Each agent has its own context, so a full concept run uses a lot of your 5-hour allowance.
The checker, builder and economist run on Sonnet; the theorycrafter and critic use the
session's model. Use quick generator mode for drafts.

## Tools (run from the repository root)
- `tools/eval.sh <build.xml | code file | pobb.in URL>`: PoB numbers, cost, penalties (JSON).
  The cost is re-estimated from the build's items, so it can differ from the generator's own.
- `tools/generate.sh "<Skill>" <Ascendancy> <out dir> [quick|full]`: generator;
  `FORCE="Unique A;Unique B"`, `EXCLUDE=...`, `BUDGET=30`, `PHASE=WEEK1`.
  Quick ~2 min (a draft), full 25-40 min.
- `tools/improve.sh <build> <out.xml>`: keep a build's core, optimise the rest for `BUDGET`
  (`SKILL="<gem>"` if the main skill isn't picked).
- `tools/price.py <name>`: poe.ninja price (cheapest copy) from `data/prices.json`
- `tools/pobcode.py decode|encode`: PoB code <-> XML
- `tools/pobb.sh <build.xml>`: uploads to pobb.in (needs network access to pobb.in)

`data/prices.json` is a snapshot of poe.ninja prices (Allflame, end of October 2026); the
generator in Path of Building refreshes its own copy.
