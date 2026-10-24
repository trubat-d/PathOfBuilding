-- Path of Building
--
-- Class: Build Meta Source
-- What the players of a skill actually use, from poe.ninja's build statistics
-- (current league): the uniques, keystones, anoints and support gems most
-- characters with that main skill have, as a share of those characters.
-- The build ideas search and the build generator use it to try the item and
-- keystone combinations that work in practice first.
--
-- poe.ninja serves these statistics as protobuf, with names in separate
-- dictionary files ("NDIC" format); both are decoded here. Results are cached
-- for 12 hours in BuildIdeasMetaCache.json next to the price cache.
--
local t_insert = table.insert
local t_sort = table.sort
local s_byte = string.byte
local dkjson = require "dkjson"

---@class BuildMetaSource
local BuildMetaSourceClass = newClass("BuildMetaSource")

local apiBase = "https://poe.ninja/poe1/api/"
local cacheHours = 12

------------------------------------------------------------------------------
-- Decoding (pure functions, also used by tests)
------------------------------------------------------------------------------

-- Protobuf varint at pos (1-based): value, next position
local function readVarint(s, pos)
	local value, mult = 0, 1
	while true do
		local b = s_byte(s, pos)
		if not b then return nil, pos end
		pos = pos + 1
		value = value + (b % 128) * mult
		if b < 128 then break end
		mult = mult * 128
	end
	return value, pos
end

-- Fields of a protobuf message: list of { field, wire, value } where value is
-- a number (varint) or a substring (length-delimited); fixed fields are skipped
local function decodeFields(s)
	local fields = { }
	local pos, len = 1, #s
	while pos <= len do
		local tag
		tag, pos = readVarint(s, pos)
		if not tag then break end
		local field, wire = math.floor(tag / 8), tag % 8
		if wire == 0 then
			local v
			v, pos = readVarint(s, pos)
			t_insert(fields, { field, 0, v })
		elseif wire == 2 then
			local l
			l, pos = readVarint(s, pos)
			if not l or pos + l - 1 > len then error("bad length") end
			t_insert(fields, { field, 2, s:sub(pos, pos + l - 1) })
			pos = pos + l
		elseif wire == 1 then
			pos = pos + 8
		elseif wire == 5 then
			pos = pos + 4
		else
			error("unsupported wire type " .. wire)
		end
	end
	return fields
end
BuildMetaSourceClass.DecodeFields = decodeFields

-- Search answer: { total, dims = { [id] = { dict = name, entries = { { key, count } } } }, dictHash = { [name] = hash } }
function BuildMetaSourceClass.ParseSearch(body)
	local root = decodeFields(body)
	local result
	for _, f in ipairs(root) do
		if f[1] == 1 and f[2] == 2 then result = f[3] break end
	end
	if not result then error("no search result") end
	local out = { total = 0, dims = { }, dictHash = { }, columns = { } }
	for _, f in ipairs(decodeFields(result)) do
		if f[1] == 1 and f[2] == 0 then
			out.total = f[3]
		elseif f[1] == 2 and f[2] == 2 then
			local id, dict, entries = nil, nil, { }
			for _, g in ipairs(decodeFields(f[3])) do
				if g[1] == 1 and g[2] == 2 then id = g[3]
				elseif g[1] == 2 and g[2] == 2 then dict = g[3]
				elseif g[1] == 3 and g[2] == 2 then
					local key, count = 0, 0
					for _, h in ipairs(decodeFields(g[3])) do
						if h[1] == 1 and h[2] == 0 then key = h[3] end
						if h[1] == 2 and h[2] == 0 then count = h[3] end
					end
					t_insert(entries, { key, count })
				end
			end
			if id then out.dims[id] = { dict = dict, entries = entries } end
		elseif f[1] == 12 and f[2] == 2 then
			-- table column: name, then one string per character row
			local name, values = nil, { }
			for _, g in ipairs(decodeFields(f[3])) do
				if g[1] == 1 and g[2] == 2 and not name then name = g[3]
				elseif g[1] == 7 and g[2] == 2 then t_insert(values, g[3]) end
			end
			if name then out.columns[name] = values end
		elseif f[1] == 6 and f[2] == 2 then
			local name, hash
			for _, g in ipairs(decodeFields(f[3])) do
				if g[1] == 1 and g[2] == 2 then name = g[3] end
				if g[1] == 2 and g[2] == 2 then hash = g[3] end
			end
			if name and hash and hash:match("^%x+$") then out.dictHash[name] = hash end
		end
	end
	return out
end

local function u32(s, pos)
	local a, b, c, d = s_byte(s, pos, pos + 3)
	return a + b * 256 + c * 65536 + d * 16777216
end

-- Dictionary file: "NDIC", version, 0, count, 8-byte hash, stride, index count,
-- index entries (8 bytes each), one length byte per string, then the strings
function BuildMetaSourceClass.ParseDictionary(body)
	if body:sub(1, 4) ~= "NDIC" then error("not a dictionary") end
	local count = u32(body, 13)
	local indexCount = u32(body, 29)
	local lengthStart = 37 + indexCount * 8
	local pos = lengthStart + count
	local list = { }
	for i = 1, count do
		local l = s_byte(body, lengthStart + i - 1)
		list[i - 1] = body:sub(pos, pos + l - 1) -- keys are 0-based
		pos = pos + l
	end
	if pos - 1 ~= #body then error("dictionary size mismatch") end
	return list
end

------------------------------------------------------------------------------
-- Downloading
------------------------------------------------------------------------------

function BuildMetaSourceClass:BuildMetaSource()
	self.cache = { }
	self:LoadCache()
	return self
end

function BuildMetaSourceClass:CachePath()
	return main.userPath and (main.userPath .. "BuildIdeasMetaCache.json") or nil
end

function BuildMetaSourceClass:LoadCache()
	local path = self:CachePath()
	local file = path and io.open(path, "r")
	if not file then return end
	local text = file:read("*a")
	file:close()
	local ok, cache = pcall(dkjson.decode, text)
	if ok and type(cache) == "table" then self.cache = cache end
end

function BuildMetaSourceClass:SaveCache()
	local path = self:CachePath()
	local file = path and io.open(path, "w")
	if file then
		file:write(dkjson.encode(self.cache))
		file:close()
	end
end

-- Cached statistics for a skill, if fresh
function BuildMetaSourceClass:Get(skillName)
	local entry = self.cache[skillName]
	-- (entries cached by older versions have no player list: downloaded again)
	if entry and entry.time and os.time() - entry.time < cacheHours * 3600 and (entry.players or (entry.total or 0) == 0) then
		return entry
	end
end

-- Download with the body hex-encoded (binary-safe through the background thread)
local downloadScript = [[
	local url, header = ...
	local curl = require("lcurl.safe")
	local easy = curl.easy()
	local body = { }
	local lines = { }
	for s in header:gmatch("[^\r\n]+") do lines[#lines + 1] = s end
	easy:setopt(curl.OPT_HTTPHEADER, lines)
	easy:setopt_url(url)
	easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
	easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
	easy:setopt_writefunction(function(data) body[#body + 1] = data return true end)
	local _, err = easy:perform()
	local code = easy:getinfo(curl.INFO_RESPONSE_CODE)
	easy:close()
	if err then return nil, err:msg() end
	if code ~= 200 then return nil, "response code " .. tostring(code) end
	local text = table.concat(body)
	return (text:gsub(".", function(c) return string.format("%02x", c:byte()) end)), nil
]]

local function fromHex(hex)
	return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

local function urlEncode(text)
	return (tostring(text):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local userAgent = "Path of Building (build ideas; local, personal use)"

function BuildMetaSourceClass:Download(url, callback)
	if not (LaunchSubScript and launch and launch.subScripts) then
		return callback(nil, "downloads are not available here")
	end
	local header = "User-Agent: " .. userAgent .. "\r\nAccept: */*"
	local id = LaunchSubScript(downloadScript, "", "", url, header)
	if not id then return callback(nil, "could not start the download") end
	launch.subScripts[id] = { type = "CUSTOM", callback = function(hex, err)
		if not hex then return callback(nil, err or "download failed") end
		callback(fromHex(hex))
	end, errorCallback = function(err)
		callback(nil, err or "download failed")
	end }
end

-- Shares (0-1) of the top entries of a dimension, named through its dictionary
local function topShares(search, dimId, names, limit)
	local dim = search.dims[dimId]
	local list = { }
	if not dim or search.total <= 0 then return list end
	local entries = { }
	for _, e in ipairs(dim.entries) do t_insert(entries, e) end
	t_sort(entries, function(a, b) return a[2] > b[2] end)
	for i = 1, math.min(limit, #entries) do
		local name = names and names[entries[i][1]]
		if name and name ~= "" then
			t_insert(list, { name = name, share = entries[i][2] / search.total })
		end
	end
	return list
end

-- Downloads the statistics of a skill (current league). callback(entry or nil, error)
function BuildMetaSourceClass:Load(skillName, callback)
	local cached = self:Get(skillName)
	if cached then return callback(cached) end
	if self.loading then return callback(nil, "already loading") end
	self.loading = true
	local function done(entry, err)
		self.loading = false
		callback(entry, err)
	end
	self:Download(apiBase .. "data/index-state", function(body, err)
		if not body then return done(nil, err) end
		local ok, state = pcall(dkjson.decode, body)
		if not ok or type(state) ~= "table" then return done(nil, "unexpected index answer") end
		-- the league the prices come from, or the first challenge league
		local leagueName = GetPriceSource().league
		-- snapshots to try: the price league first, then the others in poe.ninja's
		-- order (before a new league has players - the first days, or before it
		-- starts - the previous league's builds are used instead)
		local snapshots = { }
		for _, s in ipairs(state.snapshotVersions or { }) do
			if s.type == "exp" then
				if leagueName and s.name == leagueName then t_insert(snapshots, 1, s) else t_insert(snapshots, s) end
			end
		end
		if not snapshots[1] then return done(nil, "no build snapshot") end
		local minPlayers = 50
		local function trySnapshot(index, fallback)
			local snapshot = snapshots[index]
			if not snapshot or index > 3 then
				-- none had enough players: the best one found
				if fallback then return fallback.retry() end
				return done(nil, "no build statistics")
			end
		local url = apiBase .. "builds/" .. snapshot.version .. "/search?overview=" .. snapshot.url .. "&type=exp&skills=" .. skillName:gsub(" ", "%%20")
		self:Download(url, function(sbody, serr)
			if not sbody then return done(nil, serr) end
			local okSearch, search = pcall(self.ParseSearch, sbody)
			if not okSearch then return done(nil, "could not read build statistics: " .. tostring(search)) end
			if search.total < minPlayers and not (fallback and fallback.final) then
				-- too few players in this league yet: try the next one, remembering this one
				local best = fallback
				if not best or search.total > best.total then
					best = { total = search.total, retry = function()
						minPlayers = 0
						snapshots = { snapshot }
						trySnapshot(1, { final = true })
					end }
				end
				return trySnapshot(index + 1, best)
			end
			if search.total == 0 then
				local entry = { time = os.time(), league = snapshot.name, total = 0, items = { }, keystones = { }, anoints = { }, supports = { } }
				self.cache[skillName] = entry
				self:SaveCache()
				return done(entry)
			end
			-- dictionaries needed: items, keystones, anoints, gems
			local wanted = { "item", "keypassive", "anointed", "gem" }
			local names = { }
			local function nextDict(i)
				local dictName = wanted[i]
				if not dictName then
					local supportDim
					for id in pairs(search.dims) do
						if id:match("^supportgems%-") then supportDim = id end
					end
					-- the characters listed (name, account, damage / EHP text)
					local players = { }
					local names, accounts = search.columns.name or { }, search.columns.account or { }
					local dpsColumn, ehpColumn
					for name, values in pairs(search.columns) do
						if name:match("^dps%-.*%.total$") then dpsColumn = values end
						if name == "ehp__str" then ehpColumn = values end
					end
					for i = 1, math.min(#names, #accounts) do
						t_insert(players, { name = names[i], account = accounts[i], dps = dpsColumn and dpsColumn[i], ehp = ehpColumn and ehpColumn[i] })
					end
					local entry = {
						time = os.time(), league = snapshot.name, total = search.total,
						players = players, snapshot = { version = snapshot.version, url = snapshot.url },
						items = topShares(search, "items", names.item, 60),
						keystones = topShares(search, "keypassives", names.keypassive, 25),
						anoints = topShares(search, "anointed", names.anointed, 10),
						supports = supportDim and topShares(search, supportDim, names.gem, 15) or { },
					}
					self.cache[skillName] = entry
					self:SaveCache()
					return done(entry)
				end
				local hash = search.dictHash[dictName]
				if not hash then return nextDict(i + 1) end
				self:Download(apiBase .. "builds/dictionary/" .. hash, function(dbody, derr)
					if dbody then
						local okDict, list = pcall(self.ParseDictionary, dbody)
						if okDict then names[dictName] = list end
					end
					nextDict(i + 1)
				end)
			end
			nextDict(1)
		end)
		end
		trySnapshot(1, nil)
	end)
end

------------------------------------------------------------------------------
-- Top players' builds: gem links, uniques, keystones, pantheon, max hits
------------------------------------------------------------------------------

local function median(list)
	if #list == 0 then return nil end
	t_sort(list)
	return list[math.floor((#list + 1) / 2)]
end

-- Parses "4.9M" / "61k" into numbers
local function parseShort(text)
	if not text then return nil end
	local n, unit = text:match("^([%d%.]+)%s*([kKmMbB]?)")
	n = tonumber(n)
	if not n then return nil end
	local mult = ({ k = 1e3, K = 1e3, m = 1e6, M = 1e6, b = 1e9, B = 1e9 })[unit] or 1
	return n * mult
end
BuildMetaSourceClass.ParseShort = parseShort

-- Aggregates character JSONs (poe.ninja character endpoint) for a skill
function BuildMetaSourceClass.AggregateCharacters(skillName, characters)
	local details = { count = 0, supportSets = { }, supports = { }, uniques = { }, uniquePairs = { }, keystones = { },
		pantheonMajor = { }, pantheonMinor = { }, bandit = { }, auras = { }, utility = { }, maxHit = { }, ehp = nil }
	local setCount, setGems = { }, { }
	local hits = { Physical = { }, Fire = { }, Cold = { }, Lightning = { }, Chaos = { } }
	local ehps = { }
	local function add(map, key) if key and key ~= "" then map[key] = (map[key] or 0) + 1 end end
	for _, char in ipairs(characters) do
		details.count = details.count + 1
		-- main link: the group with the skill; other groups: utility setups
		for _, group in ipairs(char.skills or { }) do
			local names, hasSkill = { }, false
			for _, gem in ipairs(group.allGems or group.gems or { }) do
				local name = gem.name or ""
				if name == skillName then
					hasSkill = true
				elseif name:match(" Support$") then
					-- (only supports: other active gems in the link are separate setups)
					t_insert(names, (name:gsub(" Support$", "")))
				end
			end
			if hasSkill then
				t_sort(names)
				local key = table.concat(names, "|")
				setCount[key] = (setCount[key] or 0) + 1
				setGems[key] = names
				for _, n in ipairs(names) do add(details.supports, n) end
			else
				local list = { }
				for _, gem in ipairs(group.allGems or group.gems or { }) do t_insert(list, ((gem.name or ""):gsub(" Support$", ""))) end
				if #list > 0 then add(details.utility, table.concat(list, " + ")) end
				for _, n in ipairs(list) do add(details.auras, n) end
			end
		end
		-- uniques (gear, jewels, flasks) and pairs of them
		local uniques = { }
		for _, listName in ipairs({ "items", "jewels", "flasks" }) do
			for _, it in ipairs(char[listName] or { }) do
				local d = it.itemData or { }
				if d.frameType == 3 and d.name and d.name ~= "" then
					local name = d.name:gsub("^Foulborn ", "")
					if not uniques[name] then
						uniques[name] = true
						add(details.uniques, name)
					end
				end
			end
		end
		local ulist = { }
		for name in pairs(uniques) do t_insert(ulist, name) end
		t_sort(ulist)
		for i = 1, #ulist do
			for j = i + 1, #ulist do add(details.uniquePairs, ulist[i] .. "|" .. ulist[j]) end
		end
		for _, k in ipairs(char.keyStones or { }) do add(details.keystones, k.name) end
		add(details.pantheonMajor, char.pantheonMajor)
		add(details.pantheonMinor, char.pantheonMinor)
		add(details.bandit, char.banditChoice)
		local def = char.defensiveStats or { }
		for damageType, list in pairs(hits) do
			local v = def[damageType:lower() .. "MaximumHitTaken"]
			if v then t_insert(list, v) end
		end
		if def.effectiveHealthPool then t_insert(ehps, def.effectiveHealthPool) end
	end
	-- most common exact support sets
	for key, count in pairs(setCount) do t_insert(details.supportSets, { gems = setGems[key], count = count }) end
	t_sort(details.supportSets, function(a, b) return a.count > b.count end)
	for damageType, list in pairs(hits) do details.maxHit[damageType] = median(list) end
	details.ehp = median(ehps)
	-- unique pairs used together more than chance (lift)
	local pairsList = { }
	local n = math.max(1, details.count)
	for key, count in pairs(details.uniquePairs) do
		local a, b = key:match("^(.-)|(.+)$")
		local pa, pb = (details.uniques[a] or 0) / n, (details.uniques[b] or 0) / n
		if count >= 2 and pa > 0 and pb > 0 then
			t_insert(pairsList, { a = a, b = b, count = count, lift = (count / n) / (pa * pb) })
		end
	end
	t_sort(pairsList, function(x, y) return x.count * x.lift > y.count * y.lift end)
	details.uniquePairs = pairsList
	return details
end

-- Downloads the builds of the top players of a skill (after Load) and adds
-- entry.details. callback(entry or nil, error)
function BuildMetaSourceClass:LoadPlayerDetails(skillName, maxPlayers, callback)
	local entry = self.cache[skillName]
	if not entry or not entry.players or not entry.snapshot then return callback(entry, "no player list") end
	if entry.details and entry.detailsTime and os.time() - entry.detailsTime < cacheHours * 3600 then return callback(entry) end
	local players = { }
	for i = 1, math.min(maxPlayers or 20, #entry.players) do t_insert(players, entry.players[i]) end
	local characters = { }
	local function finish()
		if #characters > 0 then
			entry.details = self.AggregateCharacters(skillName, characters)
			-- the strongest few builds themselves (PoB codes), for comparisons:
			-- damage and effective hit pool from the player list, sturdy ones first
			local top = { }
			for i, char in ipairs(characters) do
				local p = char.__player or { }
				if char.pathOfBuildingExport then
					local dps, ehp = self.ParseShort(p.dps and tostring(p.dps)) or 0, self.ParseShort(p.ehp and tostring(p.ehp)) or 0
					t_insert(top, { name = p.name, account = p.account, ascendancy = char.class, level = char.level,
						dps = dps, ehp = ehp, value = dps * math.sqrt(math.max(ehp, 1)) * (ehp >= 20000 and 1 or 0.1), code = char.pathOfBuildingExport })
				end
			end
			t_sort(top, function(a, b) return a.value > b.value end)
			for i = #top, 4, -1 do top[i] = nil end
			entry.details.topBuilds = top
			entry.detailsTime = os.time()
			self:SaveCache()
		end
		callback(entry)
	end
	local function nextPlayer(i)
		local p = players[i]
		if not p then return finish() end
		local url = apiBase .. "builds/" .. entry.snapshot.version .. "/character?account=" .. urlEncode(p.account)
			.. "&name=" .. urlEncode(p.name) .. "&overview=" .. entry.snapshot.url .. "&type=exp"
		self:Download(url, function(body)
			if body then
				local ok, char = pcall(dkjson.decode, body)
				if ok and type(char) == "table" then
					char.__player = p
					t_insert(characters, char)
				end
			end
			nextPlayer(i + 1)
		end)
	end
	nextPlayer(1)
end
