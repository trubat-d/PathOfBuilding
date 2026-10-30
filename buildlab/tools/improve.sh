#!/bin/bash
# improve.sh <build.xml | code file | pobb.in URL> <out.xml>
# Improves an existing build with the generator, keeping what it is built around
# (main skill, ascendancy, uniques the player chose): tree, rares, gems, flasks, budget.
# Env: BUDGET (30), INVEST (ENDGAME), SKILL (main skill gem, else the build's)
source "$(dirname "$0")/env.sh"
src="$1"; out="$(mkdir -p "$(dirname "$2")" && cd "$(dirname "$2")" && pwd)/$(basename "$2")"
if [[ "$src" != *.xml ]]; then t=$(mktemp --suffix=.xml); python3 "$BUILDLAB_TOOLS/pobcode.py" decode "$src" "$t"; src="$t"; else src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"; fi
cd "$REPO/src" && BUILD="$src" SAVE="$out" BUDGET="${BUDGET:-30}" INVEST="${INVEST:-ENDGAME}" "$LUAJIT" ../bench/upgrade_build.lua 2>/dev/null | tail -1
