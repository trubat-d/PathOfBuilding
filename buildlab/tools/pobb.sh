#!/bin/bash
# pobb.sh <build.xml | code file>: uploads to pobb.in, prints the link (needs network access to pobb.in)
source "$(dirname "$0")/env.sh"
if [[ "$1" == *.xml ]]; then code=$(python3 "$BUILDLAB_TOOLS/pobcode.py" encode "$1"); else code=$(cat "$1"); fi
id=$(curl -sS -m 30 -X POST --data-binary "$code" https://pobb.in/pob/) && echo "https://pobb.in/$id"
