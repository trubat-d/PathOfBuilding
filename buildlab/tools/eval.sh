#!/bin/bash
# eval.sh <build.xml | code file | pobb.in URL> [more...]
# Scores builds with PoB + the generator's scorer. Env: BUDGET (30), PHASE (WEEK1: START, WEEK1, MID, LATE, NOW)
source "$(dirname "$0")/env.sh"
files=""
for a in "$@"; do
  if [[ "$a" == *.xml ]]; then files="$files $(cd "$(dirname "$a")" && pwd)/$(basename "$a")"
  else t=$(mktemp --suffix=.xml); python3 "$BUILDLAB_TOOLS/pobcode.py" decode "$a" "$t" && files="$files $t"; fi
done
cd "$REPO/src" && FILES="$files" "$LUAJIT" ../buildlab/tools/eval.lua 2>/dev/null | grep "^EVAL " | cut -c6-
