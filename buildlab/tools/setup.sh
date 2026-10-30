#!/bin/bash
# setup.sh: installs what the tools need on Linux / WSL / a Claude Code cloud environment:
# LuaJIT 2.1 and the lua-utf8 module (built into buildlab/.local when not installed system-wide).
set -e
source "$(dirname "$0")/env.sh"
L="$REPO/buildlab/.local"; mkdir -p "$L/bin" "$L/lib"
if ! command -v luajit >/dev/null; then
  (command -v apt-get >/dev/null && (sudo -n apt-get install -y luajit libluajit-5.1-dev || apt-get install -y luajit libluajit-5.1-dev)) 2>/dev/null || true
fi
if ! command -v luajit >/dev/null && [ ! -x "$L/bin/luajit" ]; then
  git clone -q -b v2.1 https://github.com/LuaJIT/LuaJIT.git "$L/src-luajit"
  make -C "$L/src-luajit" -j2 PREFIX="$L" >/dev/null && make -C "$L/src-luajit" install PREFIX="$L" >/dev/null
fi
if ! "${LUAJIT}" -e 'require("lua-utf8")' 2>/dev/null && [ ! -f "$L/lib/lua-utf8.so" ]; then
  inc=$(ls -d /usr/include/luajit-2.1 "$L/include/luajit-2.1" 2>/dev/null | head -1)
  git clone -q --depth 1 https://github.com/starwing/luautf8.git "$L/src-utf8"
  gcc -O2 -shared -fPIC -I"$inc" "$L/src-utf8/lutf8lib.c" -o "$L/lib/lua-utf8.so"
fi
source "$(dirname "$0")/env.sh"
"$LUAJIT" -v && echo "buildlab tools ready"
