-- Re-parses the lines Data/ModCache.lua holds as unsupported (or partly
-- supported) with the current Modules/ModParser, so new parser lines take
-- effect without regenerating the whole cache, and lists what is still not
-- understood, grouped by form (numbers as #) with how many lines have it.
-- From the src folder: [WRITE=1] [LIST=N] [GREP=text] luajit ../bench/modcache_refresh.lua
--   WRITE=1  save the refreshed Data/ModCache.lua
--   LIST=N   print the N most common unsupported forms (default 60)
--   GREP=T   only forms containing T (lower case)
io.stdout:setvbuf("no")
dofile("HeadlessWrapper.lua")
local write = os.getenv("WRITE") == "1"
local listN = tonumber(os.getenv("LIST") or "") or 60
local filter = os.getenv("GREP") and os.getenv("GREP"):lower()
local cache = modLib.parseModCache
local lines = { }
for line, dat in pairs(cache) do
	if not dat[1] or dat[2] then lines[#lines + 1] = line end
end
table.sort(lines)
local fixed, partial = 0, 0
for _, line in ipairs(lines) do
	local old = cache[line]
	cache[line] = nil
	local ok, mods, extra = pcall(modLib.parseMod, line)
	if not ok then
		cache[line] = old
	else
		if mods and not extra and (not old[1] or old[2]) then fixed = fixed + 1
		elseif mods and extra and not old[1] then partial = partial + 1 end
	end
end
print(string.format("re-parsed %d lines: %d now fully understood, %d now partly", #lines, fixed, partial))
-- still unsupported, by form
local forms, count = { }, 0
for line, dat in pairs(cache) do
	if not dat[1] then
		local form = line:lower():gsub("[%+%-]?%d+%.?%d*", "#")
		if not filter or form:find(filter, 1, true) then
			forms[form] = (forms[form] or 0) + 1
			count = count + 1
		end
	end
end
local list = { }
for form, n in pairs(forms) do list[#list + 1] = { form = form, n = n } end
table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.form < b.form end)
print(string.format("still not understood: %d lines, %d forms", count, #list))
for k = 1, math.min(listN, #list) do print(string.format("%5d  %s", list[k].n, list[k].form)) end
if write then
	main:SaveModCache()
	print("Data/ModCache.lua written")
end
