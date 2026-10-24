-- Turns poe.ninja files saved by a browser (one JSON pack per skill:
-- { skill, league, snapshot, total, players, searchB64, characters }, plus
-- dicts.json { dicts = { name = { hash, b64 } } }) into what the generator
-- gets from BuildMetaSource:Load + LoadPlayerDetails: a meta cache file and
-- one details JSON per skill (for bench_case / stage_test META_DETAILS).
-- Run from src:
--   NINJA_DIR=<folder with the packs> OUT=<folder> luajit ../bench/ninja_import.lua
-- Needs LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
io.stdout:setvbuf("no")
local benchDir = arg[0]:match("^(.*)[/\\]") or "."
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
local dkjson = require "dkjson"
local inDir = assert(os.getenv("NINJA_DIR"), "NINJA_DIR")
local outDir = os.getenv("OUT") or inDir
local Meta = new("BuildMetaSource"):BuildMetaSource()

local function readJson(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return dkjson.decode(text)
end
local function b64(s) return common.base64.decode(s) end

local dictPack = assert(readJson(inDir .. "/dicts.json"), "dicts.json missing")
local names = { }
for name, d in pairs(dictPack.dicts) do
	local ok, list = pcall(Meta.ParseDictionary, b64(d.b64))
	if ok then names[name] = list else print("dictionary " .. name .. " not read: " .. tostring(list)) end
end

-- (same as BuildMetaSource's topShares)
local function topShares(search, dimId, list, limit)
	local dim = search.dims[dimId]
	local out = { }
	if not dim or search.total <= 0 then return out end
	local entries = { }
	for _, e in ipairs(dim.entries) do entries[#entries + 1] = e end
	table.sort(entries, function(a, b) return a[2] > b[2] end)
	for i = 1, math.min(limit, #entries) do
		local name = list and list[entries[i][1]]
		if name and name ~= "" then out[#out + 1] = { name = name, share = entries[i][2] / search.total } end
	end
	return out
end

-- packs: every *.json except dicts (a file can hold one pack or a list)
local packs = { }
local listing = io.popen('ls "' .. inDir .. '"/*.json')
for path in listing:lines() do
	if not path:match("dicts%.json$") then
		local data = readJson(path)
		if type(data) == "table" then
			local list = data.skill and { data } or data
			for _, p in ipairs(list) do
				if p.skill then
					-- (keep the pack with the most characters per skill)
					local old = packs[p.skill]
					if not old or #(p.characters or { }) > #(old.characters or { }) then packs[p.skill] = p end
				end
			end
		end
	end
end
listing:close()

local cache = { }
local skills = { }
for skill in pairs(packs) do skills[#skills + 1] = skill end
table.sort(skills)
for _, skill in ipairs(skills) do
	local p = packs[skill]
	local search = Meta.ParseSearch(b64(p.searchB64))
	local supportDim
	for id in pairs(search.dims) do if id:match("^supportgems%-") then supportDim = id end end
	local entry = {
		time = os.time(), league = p.league, total = search.total, players = p.players,
		snapshot = p.snapshot,
		items = topShares(search, "items", names.item, 60),
		keystones = topShares(search, "keypassives", names.keypassive, 25),
		anoints = topShares(search, "anointed", names.anointed, 10),
		supports = supportDim and topShares(search, supportDim, names.gem, 15) or { },
	}
	local chars = p.characters or { }
	if #chars > 0 then
		for _, c in ipairs(chars) do c.class = c.ascendancyClassName or c.class end
		entry.details = Meta.AggregateCharacters(skill, chars)
		local top = { }
		for _, char in ipairs(chars) do
			local pl = char.__player or { }
			if char.pathOfBuildingExport then
				local dps, ehp = Meta.ParseShort(pl.dps and tostring(pl.dps)) or 0, Meta.ParseShort(pl.ehp and tostring(pl.ehp)) or 0
				top[#top + 1] = { name = pl.name, account = pl.account, ascendancy = char.class, level = char.level,
					dps = dps, ehp = ehp, value = dps * math.sqrt(math.max(ehp, 1)) * (ehp >= 20000 and 1 or 0.1), code = char.pathOfBuildingExport }
			end
		end
		table.sort(top, function(a, b) return a.value > b.value end)
		-- (all of them kept here: the comparison scripts use every one)
		entry.details.topBuilds = top
		entry.detailsTime = os.time()
		local f = assert(io.open(outDir .. "/details_" .. skill:gsub("[^%w]+", "_") .. ".json", "w"))
		f:write(dkjson.encode(entry.details))
		f:close()
	end
	cache[skill] = entry
	print(string.format("%-40s players %6d  characters %2d", skill, search.total, #chars))
end
local f = assert(io.open(outDir .. "/BuildIdeasMetaCache.json", "w"))
f:write(dkjson.encode(cache))
f:close()
