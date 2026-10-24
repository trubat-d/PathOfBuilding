#!/bin/sh
# Runs bench/stage_test.lua from this checkout's src folder:
#   sh bench/run_stage.sh <STEP> <build .xml> [extra VAR=value ...]
here=$(cd "$(dirname "$0")" && pwd)
step=$1
ours=$2
shift 2
cd "$here/../src" || exit 1
export LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
env STEP="$step" OURS="$ours" "$@" luajit ../bench/stage_test.lua
