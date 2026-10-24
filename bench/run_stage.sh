#!/bin/sh
# Runs bench/stage_test.lua on a saved build from the src folder.
# Usage (from the repository root): sh bench/run_stage.sh <STEP> <build .xml> [log file]
cd "$(dirname "$0")/../src" || exit 1
export LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
export STEP="$1"
export OURS="$2"
if [ -n "$3" ]; then
	timeout 2400 luajit ../bench/stage_test.lua > "$3" 2>&1
else
	timeout 2400 luajit ../bench/stage_test.lua
fi
