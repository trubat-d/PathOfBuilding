# buildlab (work in progress)

Tools for working on Path of Exile build concepts with Claude Code agents, on top of
this repository's headless Path of Building and build generator.

- `tools/setup.sh` - installs LuaJIT and lua-utf8 (Linux / WSL / cloud environment)
- `tools/eval.sh <build.xml | code file | pobb.in URL>` - PoB numbers, cost and scorer penalties
- `tools/generate.sh "<Skill>" <Ascendancy> <out dir>` - runs the generator (FORCE="Unique;..." to build around items)
- `tools/price.py <name>` - poe.ninja prices from `data/prices.json`
- `tools/pobcode.py decode|encode` - PoB codes <-> XML
- `tools/pobb.sh <build.xml>` - uploads to pobb.in

Agent roles (`.claude/agents/`) and the workflow skill come next.
