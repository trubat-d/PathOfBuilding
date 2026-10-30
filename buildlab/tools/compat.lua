-- Loaded before every buildlab LuaJIT run (LUA_INIT, set in env.sh).
-- PoB's files start with a "#@" line, which recent LuaJIT builds no longer skip.
function loadfile(name)
	local f, err = io.open(name)
	if not f then return nil, err end
	local text = f:read("*a"):gsub("^#[^\n]*", "")
	f:close()
	return loadstring(text, "@" .. name)
end
function dofile(name) return assert(loadfile(name))() end
