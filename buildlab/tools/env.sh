# Sourced by the buildlab tools: paths and the Lua environment for headless PoB
BUILDLAB_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$BUILDLAB_TOOLS/../.." && pwd)"
export LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
# (lua-utf8 built by setup.sh, when the system has none)
[ -f "$REPO/buildlab/.local/lib/lua-utf8.so" ] && export LUA_CPATH="$REPO/buildlab/.local/lib/?.so;;"
export POB_PRICE_CACHE="${POB_PRICE_CACHE:-$REPO/buildlab/data/prices.json}"
LUAJIT="${LUAJIT:-$(command -v luajit || echo "$REPO/buildlab/.local/bin/luajit")}"
export LUA_INIT="@$BUILDLAB_TOOLS/compat.lua"
