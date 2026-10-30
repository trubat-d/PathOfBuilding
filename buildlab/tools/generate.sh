#!/bin/bash
# generate.sh "<Skill gem>" <Ascendancy> <out dir> [mode]
# Runs the build generator (full mode by default, "quick" for a fast draft).
# Env: BUDGET (30), PHASE (WEEK1), FORCE="Unique A;Unique B" (uniques the build must use),
#      EXCLUDE="Unique C;...", ARCHETYPE (STANDARD), LEVEL (95),
#      GEN_OPTS="name=value,..." (generator options, e.g. engine=none, variant=2)
# Prints the result JSON line; the build XML is written to <out dir>.
source "$(dirname "$0")/env.sh"
skill="$1"; asc="$2"; out="$(mkdir -p "$3" && cd "$3" && pwd)"; mode="${4:-full}"
cd "$REPO/src" && BENCH_SAVE="$out" BUDGET="${BUDGET:-30}" PHASE="${PHASE:-WEEK1}" LEVEL="${LEVEL:-95}" \
  GEN_OPTS="${GEN_OPTS:-midTier=true}" "$LUAJIT" ../bench/bench_case.lua "$skill" "$asc" ENDGAME "$mode" "${ARCHETYPE:-STANDARD}" 2>/dev/null \
  | grep "^BENCH " | cut -c7- | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); d.pop('log',None); print(json.dumps(d))"
