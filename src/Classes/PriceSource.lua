-- Path of Building
--
-- Class: Price Source
-- Unique item, tattoo and oil prices from poe.ninja's public economy API,
-- used to keep build ideas and generated builds within an investment level.
--   * only the supported economy endpoints are used (https://poe.ninja/docs/api)
--   * prices are cached on disk and refreshed at most every few hours
--   * requests carry a descriptive User-Agent, as poe.ninja asks
-- Prices are in divine orbs. Items poe.ninja doesn't list have no price.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local m_min = math.min
local dkjson = require "dkjson"

---@class PriceSource
local PriceSourceClass = newClass("PriceSource")

local apiBase = "https://poe.ninja/poe1/api/economy/"
local userAgent = "PathOfBuilding-BuildIdeas/1.0 (personal fork; https://github.com/trubat-d/PathOfBuilding)"
local cacheMaxAge = 6 * 3600
local itemTypes = { "UniqueWeapon", "UniqueArmour", "UniqueAccessory", "UniqueFlask", "UniqueJewel", "UniqueTincture" }
local exchangeTypes = { "Tattoo", "Oil" }

-- Investment levels: max price per item in divines (nil = no limit);
-- rareAffixes: the natural mods a rare of the budget has (plus the bench
-- craft; nil = all six: every budget fills its rares - an exalted orb on a
-- cheap rare is cheap; the tiers and rolls are what the budget limits); rarePrice: rough price of one rare
-- piece of gear made at that level (rares aren't on poe.ninja); budgetUpTo:
-- the level a total budget up to that many divines uses
PriceSourceClass.levels = {
	{ id = "LEAGUE_START", jewelAffixes = 2, label = "League start (items up to 1 divine)", rarePrice = 0.05, budgetUpTo = 3, maxUnique = 1, maxAnoint = 1, maxTattoo = 0.1, influences = 0, eldritchTier = 1, quality = 3, unknownAllowed = false,
		enlighten = nil, exceptionalGems = false, awakenedGems = false, timeless = false, scarce = false },
	{ id = "BUDGET", jewelAffixes = 2, label = "Budget (items up to 5 divines)", rarePrice = 0.3, budgetUpTo = 15, maxUnique = 5, maxAnoint = 3, maxTattoo = 0.5, influences = 0, eldritchTier = 2, quality = 2, unknownAllowed = false,
		enlighten = nil, exceptionalGems = false, awakenedGems = false, timeless = true, scarce = false },
	{ id = "MID", jewelAffixes = 3, label = "Mid investment (items up to 30 divines)", rarePrice = 1.5, budgetUpTo = 100, maxUnique = 30, maxAnoint = 10, maxTattoo = 2, influences = 1, maxInfluenced = 2, eldritchTier = 3, quality = 2, unknownAllowed = false,
		enlighten = nil, exceptionalGems = false, awakenedGems = false, timeless = true, scarce = false },
	{ id = "HIGH", jewelAffixes = 3, label = "High investment (items up to 150 divines)", rarePrice = 8, budgetUpTo = 450, maxUnique = 150, maxAnoint = 50, maxTattoo = 10, influences = 2, maxInfluenced = 4, eldritchTier = 4, quality = 2, unknownAllowed = true,
		enlighten = { name = "Enlighten", level = 4 }, exceptionalGems = true, awakenedGems = true, timeless = true, corruptedMain = true },
	{ id = "ENDGAME", jewelAffixes = 4, label = "Endgame investment (items up to 500 divines, Mageblood level)", rarePrice = 30, budgetUpTo = 2000, multiCraft = true, maxUnique = 500, maxAnoint = 150, maxTattoo = 30, influences = 2, maxInfluenced = 7, eldritchTier = 5, quality = 4, unknownAllowed = true,
		enlighten = { name = "Awakened Enlighten", level = 5 }, exceptionalGems = true, awakenedGems = true, timeless = true, corruptedMain = true, corruptedSupports = true },
	{ id = "MIRROR", jewelAffixes = 4, label = "No limit (mirror tier)", rarePrice = 150, multiCraft = true, influences = 2, eldritchTier = 6, elevated = true, quality = 1, unknownAllowed = true,
		enlighten = { name = "Awakened Enlighten", level = 5 }, exceptionalGems = true, awakenedGems = true, timeless = true, corruptedMain = true, corruptedSupports = true },
}
PriceSourceClass.defaultLevel = 3

-- Uniques found too rarely to count on below High investment, whatever their
-- price says (prices are low later in a league, but few drop early on).
-- Exceptional gems (Enlighten, Empower, Enhance) are held back the same way
-- by the levels' exceptionalGems.
PriceSourceClass.scarceUniques = {
	["Split Personality"] = true, ["Watcher's Eye"] = true, ["Cinderswallow Urn"] = true,
	["Bottled Faith"] = true, ["Dying Sun"] = true, ["Progenesis"] = true, ["The Squire"] = true,
	["Ashes of the Stars"] = true, ["Melding of the Flesh"] = true, ["Impossible Escape"] = true,
	["Forbidden Flame"] = true, ["Forbidden Flesh"] = true, ["Megalomaniac"] = true, ["Voices"] = true,
	["Aul's Uprising"] = true, ["Original Sin"] = true, ["Nimis"] = true, ["Mageblood"] = true,
	["Headhunter"] = true, ["Sublime Vision"] = true, ["Badge of the Brotherhood"] = true,
	["Thread of Hope"] = false,
}

-- The league's chase uniques: what makes a build "high-end" whatever one copy
-- costs (options.midTier leaves them out; bench/tier_compare.py splits the
-- players' builds by them). Timeless jewels aren't here: a random seed is
-- cheap, and the generator prices the seed it picks.
PriceSourceClass.chaseUniques = {
	["Mageblood"] = true, ["Headhunter"] = true, ["Pearl of Tsoatha"] = true, ["Original Sin"] = true,
	["Nimis"] = true, ["The Squire"] = true, ["Progenesis"] = true, ["Ashes of the Stars"] = true,
	["Voices"] = true, ["Forbidden Flame"] = true, ["Forbidden Flesh"] = true, ["Watcher's Eye"] = true,
	["Kalandra's Touch"] = true, ["Bottled Faith"] = true, ["Dying Sun"] = true, ["Melding of the Flesh"] = true,
	["Aul's Uprising"] = true, ["Sublime Vision"] = true, ["Badge of the Brotherhood"] = true,
	["Megalomaniac"] = true, ["Squire"] = true, ["Replica Dragonfang's Flight"] = true,
}

-- The investment level for a total budget (divines for the whole build): the
-- highest level whose rares fit about six times in it, with per-item caps from the total (one item
-- can't take more than half of it). The build is then fitted under the total
-- (BuildGenerator:FitTotalBudget), so the budget is spent where it scores
-- best rather than left over: by the old "budget up to" limits, 449 divines
-- made 8-divine rares and a 117-divine Cyclone next to players' 450-divine builds
-- (6: the level whose rares the total buys six times; the fit then trims the
-- parts worth the least per divine. With 12, 270 divines picked High and a
-- Winter Orb spent 83 of them: 16.73; with 6, Endgame fitted to 250: 17.07,
-- 3.1M -> 3.7M DPS, physical max hit 16k -> 21k)
local RARES_PER_BUILD = 6
function PriceSourceClass.ForBudget(total, raresPerBuild)
	local chosen
	for _, level in ipairs(PriceSourceClass.levels) do
		if chosen and (level.rarePrice or 0) * (raresPerBuild or RARES_PER_BUILD) > total then break end
		chosen = level
	end
	local level = copyTable(chosen, true)
	level.totalBudget = total
	level.baseId = chosen.id
	local function cap(value, share) return value and math.min(value, total * share) or total * share end
	level.maxUnique = cap(chosen.maxUnique, 0.5)
	level.maxAnoint = cap(chosen.maxAnoint, 0.25)
	level.maxTattoo = cap(chosen.maxTattoo, 0.05)
	level.label = string.format("Total budget %s (%s rares)", PriceSourceClass.FormatPrice(total), chosen.label:match("^([^%(]+)"):gsub("%s+$", ""))
	return level
end

-- Can a unique be counted on at an investment level (scarce ones from High)?
-- Uniques no longer obtainable (The Perandus Pact, legacy league uniques):
-- never offered, whichever finder asks
local unobtainable
local function isUnobtainable(title)
	if not unobtainable then
		if not (main and main.uniqueDB and main.uniqueDB.list and not main.uniqueDB.loading) then return false end
		unobtainable = { }
		local obtainable = { }
		for _, item in pairs(main.uniqueDB.list) do
			local name = item.title or item.name
			if name then
				if (item.source or "") == "No longer obtainable" or item.league == "Race Events" then
					unobtainable[name] = true
				else
					obtainable[name] = true
				end
			end
		end
		-- (a title with an obtainable version stays: replicas, reworked uniques)
		for name in pairs(obtainable) do unobtainable[name] = nil end
	end
	return unobtainable[title] or false
end
PriceSourceClass.IsUnobtainable = isUnobtainable

function PriceSourceClass.Available(level, title)
	if not title then return true end
	if isUnobtainable(title) then return false end
	-- (the player's excluded uniques and the mid-tier option's chase uniques:
	-- the jewel finders ask here, not through the item filter)
	local rules = GetGeneratorRules and GetGeneratorRules()
	if rules and rules.userExcluded and rules.userExcluded[title] then return false end
	if not level then return true end
	if level.scarce == false and PriceSourceClass.scarceUniques[title] then return false end
	-- (early in a league they aren't found at any budget; nor the uber
	-- pinnacle bosses' drops - Crystallised Omniscience from the Uber Searing
	-- Exarch was 0.02 div on poe.ninja at day 96, not in a first week)
	if main and main.priceSource and main.priceSource:PhaseScarce() and (PriceSourceClass.scarceUniques[title] or PriceSourceClass.IsUberDrop(title)) then return false end
	return true
end

-- Uniques only the uber pinnacle bosses drop (their source line)
local uberDrops
function PriceSourceClass.IsUberDrop(title)
	if not uberDrops then
		if not (main and main.uniqueDB and main.uniqueDB.list and not main.uniqueDB.loading) then return false end
		uberDrops = { }
		for _, item in pairs(main.uniqueDB.list) do
			local source = item.source or ""
			local name = item.title or item.name
			if name and (source:find("(Uber)", 1, true) or source:find("Uber Incarnation", 1, true)) then uberDrops[name] = true end
		end
	end
	return uberDrops[title] or false
end

function PriceSourceClass:PriceSource()
	self.uniques, self.tattoos, self.oils, self.gems = { }, { }, { }, { }
	self.loaded = false
	self:LoadCache()
	return self
end

function PriceSourceClass:CachePath()
	-- (POB_PRICE_CACHE: the cache file somewhere else, for headless runs)
	local override = os.getenv("POB_PRICE_CACHE")
	if override and override ~= "" then return override end
	return main.userPath and (main.userPath .. "BuildIdeasPriceCache.json") or nil
end

function PriceSourceClass:LoadCache()
	local path = self:CachePath()
	local file = path and io.open(path, "r")
	if not file then return end
	local text = file:read("*a")
	file:close()
	local ok, cache = pcall(dkjson.decode, text)
	if ok and type(cache) == "table" and cache.uniques then
		self:SetData(cache)
	end
end

function PriceSourceClass:SaveCache()
	local path = self:CachePath()
	local file = path and io.open(path, "w")
	if not file then return end
	file:write(dkjson.encode({ time = self.time, league = self.league, leagueStart = self.leagueStart, uniques = self.uniques, tattoos = self.tattoos, oils = self.oils, gems = self.gems }))
	file:close()
end

function PriceSourceClass:SetData(data)
	self.time = data.time
	self.league = data.league
	self.uniques = data.uniques or { }
	self.tattoos = data.tattoos or { }
	self.oils = data.oils or { }
	self.gems = data.gems or { }
	self.leagueStart = data.leagueStart
	local count = 0
	for _ in pairs(self.uniques) do count = count + 1 end
	self.uniqueCount = count
	self.loaded = count > 0
end

function PriceSourceClass:IsStale()
	return not self.loaded or not self.time or (os.time() - self.time) > cacheMaxAge
end

function PriceSourceClass:Status()
	if self.loading then
		return "^7Prices: downloading from poe.ninja..."
	elseif self.error then
		return colorCodes.NEGATIVE .. "Prices: " .. self.error
	elseif not self.loaded then
		return "^7Prices: not loaded, so items are not filtered by price"
	end
	local age = math.floor((os.time() - (self.time or os.time())) / 60)
	local ageText = age < 60 and (age .. " min") or (math.floor(age / 60) .. " h")
	return string.format("^7Prices: %s league, %d uniques, updated %s ago (poe.ninja)", self.league or "?", self.uniqueCount or 0, ageText)
end

-- Reads one stash item overview: lines with name, divineValue, variants, links
local function parseItems(json, into)
	for _, line in ipairs(json.lines or { }) do
		local name, value = line.name, tonumber(line.divineValue)
		-- 5 / 6 link versions are priced separately; keep the cheapest version
		if name and value and not (line.links and line.links >= 5) then
			into[name] = into[name] and m_min(into[name], value) or value
			-- (and each variant on its own: Impossible Escape's keystone,
			-- a timeless jewel's conqueror - the cheapest one is no price for
			-- the one a build needs)
			if type(line.variant) == "string" and line.variant ~= "" then
				local key = name .. "|" .. line.variant
				into[key] = into[key] and m_min(into[key], value) or value
			end
		end
	end
end

-- Reads the skill gem overview: the cheapest uncorrupted copy of each gem
-- at each level ("Awakened Added Fire Damage Support:5")
local function parseGems(json, into)
	for _, line in ipairs(json.lines or { }) do
		local name, value, level = line.name, tonumber(line.divineValue), tonumber(line.gemLevel)
		if name and value and level and not line.corrupted then
			local key = name .. ":" .. level
			into[key] = into[key] and m_min(into[key], value) or value
		end
	end
end
PriceSourceClass.ParseGems = parseGems

-- Reads one exchange overview: prices in chaos (primaryValue), names in items[]
local function parseExchange(json, into)
	local rate = json.core and json.core.rates and tonumber(json.core.rates.divine) or nil
	local names = { }
	for _, item in ipairs(json.items or { }) do
		names[item.id] = item.name
	end
	for _, line in ipairs(json.lines or { }) do
		local name = names[line.id]
		local chaos = tonumber(line.primaryValue)
		if name and chaos and rate then
			into[name] = chaos * rate
		end
	end
end
PriceSourceClass.ParseItems = parseItems
PriceSourceClass.ParseExchange = parseExchange

-- Downloads everything, one request at a time. callback(ok)
function PriceSourceClass:Refresh(callback, leagueOverride)
	if self.loading then return end
	-- Downloads run as a background script; without one (e.g. headless) they never answer
	local probeId = LaunchSubScript and launch and launch.DownloadPage and launch.subScripts and LaunchSubScript("return", "", "")
	if probeId then
		launch.subScripts[probeId] = { type = "CUSTOM" } -- finishes at once, nothing to do
	else
		self.error = "downloads are not available here"
		if callback then callback(false) end
		return
	end
	self.loading, self.error = true, nil
	local header = "User-Agent: " .. userAgent .. "\r\nAccept: application/json"
	local data = { uniques = { }, tattoos = { }, oils = { }, gems = { } }
	local queue = { }
	local function fail(msg)
		self.loading = false
		self.error = msg
		if callback then callback(false) end
	end
	local function nextRequest()
		local request = t_remove(queue, 1)
		if not request then
			data.time, data.league = os.time(), self.league
			-- (the gem list is optional and big: when it didn't come, the
			-- previous one is kept rather than every gem priced at nothing; the
			-- same for the league start poe.ninja doesn't always give)
			if next(data.gems) == nil and self.gems and next(self.gems) ~= nil then data.gems = self.gems end
			data.leagueStart = data.leagueStart or self.leagueStart
			self:SetData(data)
			self:SaveCache()
			self.loading = false
			if callback then callback(true) end
			return
		end
		launch:DownloadPage(request.url, function(response, errMsg)
			-- (optional lists, like gem prices, are skipped when they fail)
			if errMsg then
				if request.optional then return nextRequest() end
				return fail("download failed (" .. tostring(errMsg) .. ")")
			end
			local ok, json = pcall(dkjson.decode, response.body)
			if not ok or type(json) ~= "table" then
				if request.optional then return nextRequest() end
				return fail("unexpected answer from poe.ninja")
			end
			request.parse(json)
			nextRequest()
		end, { header = header })
	end
	-- 1. league: first entry is the current challenge league
	launch:DownloadPage(apiBase .. "leagues", function(response, errMsg)
		if errMsg then
			return fail("download failed (" .. tostring(errMsg) .. ")")
		end
		local ok, leagues = pcall(dkjson.decode, response.body)
		if not ok or type(leagues) ~= "table" then
			return fail("unexpected answer from poe.ninja")
		end
		local list = leagues[1] and leagues or leagues.leagues or { }
		self.league = leagueOverride or (list[1] and (list[1].id or list[1].name)) or "Standard"
		-- (when the league started, if poe.ninja says: how far into its economy we are)
		data.leagueStart = nil
		for _, key in ipairs({ "startAt", "startDate", "start_date", "start", "startTime" }) do
			local v = list[1] and list[1][key]
			local y, mo, d = type(v) == "string" and v:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
			if y then data.leagueStart = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 20 }) break end
		end
		local league = self.league:gsub(" ", "+")
		for _, itemType in ipairs(itemTypes) do
			t_insert(queue, { url = apiBase .. "stash/current/item/overview?league=" .. league .. "&type=" .. itemType, parse = function(json) parseItems(json, data.uniques) end })
		end
		t_insert(queue, { url = apiBase .. "stash/current/item/overview?league=" .. league .. "&type=SkillGem", optional = true, parse = function(json) parseGems(json, data.gems) end })
		t_insert(queue, { url = apiBase .. "exchange/current/overview?league=" .. league .. "&type=Tattoo", parse = function(json) parseExchange(json, data.tattoos) end })
		t_insert(queue, { url = apiBase .. "exchange/current/overview?league=" .. league .. "&type=Oil", parse = function(json) parseExchange(json, data.oils) end })
		t_insert(queue, { url = apiBase .. "exchange/current/overview?league=" .. league .. "&type=Runegraft", parse = function(json) parseExchange(json, data.tattoos) end })
		nextRequest()
	end, { header = header })
end

------------------------------------------------------------------------------
-- Lookups (prices in divines, nil = not listed)
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- League economy: prices move a lot over a league. poe.ninja's prices are
-- today's; the generator can price a build for another moment of the league
-- (options.leaguePhase). Prices relative to mid league, by kind of item, at
-- a few days into the league (in between: interpolated on the log of the
-- day); chase uniques are rare and costly early, everything bought with
-- crafting currency costs more while currency is scarce.
------------------------------------------------------------------------------

PriceSourceClass.phases = {
	{ id = "NOW", label = "Now (poe.ninja)" },
	{ id = "START", label = "League start", day = 2 },
	{ id = "WEEK1", label = "First week", day = 7 },
	{ id = "MID", label = "Mid league", day = 21 },
	{ id = "LATE", label = "Late league", day = 70 },
}
local phaseDays = { 2, 7, 21, 70 }
local phaseCurves = {
	chase = { 5, 2.5, 1, 0.7 },   -- uniques worth 20+ div at mid league
	unique = { 2.5, 1.6, 1, 0.8 }, -- 1 to 20 div
	cheap = { 1.5, 1.2, 1, 1 },    -- under 1 div
	rare = { 2, 1.5, 1, 0.8 },     -- crafted rares, anoints, gems, tattoos
}
local function curveAt(curve, day)
	day = math.max(phaseDays[1], math.min(phaseDays[#phaseDays], day))
	for i = 1, #phaseDays - 1 do
		if day <= phaseDays[i + 1] then
			local t = (math.log(day) - math.log(phaseDays[i])) / (math.log(phaseDays[i + 1]) - math.log(phaseDays[i]))
			return math.exp(math.log(curve[i]) * (1 - t) + math.log(curve[i + 1]) * t)
		end
	end
	return curve[#curve]
end

-- Days into the league of today's prices (mid league when unknown)
function PriceSourceClass:CurrentDay()
	if self.leagueStart and self.time then return math.max(1, (self.time - self.leagueStart) / 86400) end
	return 21
end

-- Factor from today's price to the chosen phase's, for a kind of item
-- ("rare", or a unique by its price today)
function PriceSourceClass:PhaseFactor(kind, priceNow)
	local phase = self.phase
	if not phase or phase == "NOW" then return 1 end
	local target
	for _, p in ipairs(self.phases) do if p.id == phase then target = p.day end end
	if not target then return 1 end
	local curve
	if kind == "rare" then
		curve = phaseCurves.rare
	else
		local now = curveAt(phaseCurves.unique, self:CurrentDay())
		local mid = (priceNow or 0) / now
		curve = mid >= 20 and phaseCurves.chase or mid >= 1 and phaseCurves.unique or phaseCurves.cheap
	end
	return curveAt(curve, target) / curveAt(curve, self:CurrentDay())
end

-- Early in a league the scarce uniques aren't found at any price
function PriceSourceClass:PhaseScarce()
	return self.phase == "START" or self.phase == "WEEK1"
end

function PriceSourceClass:UniquePrice(item)
	local title = item.title or (item.name and item.name:match("^([^,]+),")) or item.name
	local variantName = item.variant and item.variantList and item.variantList[item.variant]
	local price = title and variantName and self.uniques[title .. "|" .. variantName] or (title and self.uniques[title])
	if price and self.phase and self.phase ~= "NOW" then price = price * self:PhaseFactor("unique", price) end
	-- (uniques whose roll is the whole item: poe.ninja's cheapest copy is a
	-- low roll - The Adorned at 0.09 div - a high roll costs far more)
	-- (Admiral's Arrogance: +1 to +3 melee gem levels - the cheapest copy is +1)
	local rollPriced = { ["The Adorned"] = 20, ["Admiral's Arrogance"] = 25 }
	if price and title and rollPriced[title] then
		local range = 0.5
		for _, l in ipairs(item.explicitModLines or { }) do if l.range then range = l.range end end
		price = math.max(price, rollPriced[title] * range ^ 3)
	end
	-- (uniques bought for chosen mods: poe.ninja's cheapest copy is a random
	-- one - Forbidden Flame / Flesh at 0.12 div, Watcher's Eye at 0.15 - a
	-- copy with the build's notable or aura mods costs far more; rough floors)
	if price and title == "Watcher's Eye" then
		local mods = 0
		for _, v in ipairs({ item.variant, item.variantAlt, item.variantAlt2 }) do
			local name = item.variantList and item.variantList[v]
			if name and name ~= "None" then mods = mods + 1 end
		end
		price = math.max(price, ({ [1] = 3, [2] = 15, [3] = 60 })[mods] or 0)
	elseif price and (title == "Forbidden Flame" or title == "Forbidden Flesh") then
		price = math.max(price, 10)
	end
	return price
end

-- A rare's price (divines), estimated from what it has: the level's typical
-- rare, scaled by how many good mods it has against what the level expects,
-- influences, Eldritch implicits, extra bench crafts, the kind of slot
-- (weapons cost the most), and the league phase. A rough guide: poe.ninja
-- doesn't price rares.
-- How good a rare's explicit mods are, by tier: each mod matched to the
-- prefix / suffix of its group that can roll on the item's base (weight > 0
-- for the first of its tags the mod lists), ranked by item level; 1 = the best
-- tier, 0 = the worst. Returns the average, the number of mods matched, and
-- how many are in the top two tiers.
local tierIndex
local function buildTierIndex()
	tierIndex = { }
	for _, mod in pairs(data.itemMods.Item) do
		if (mod.type == "Prefix" or mod.type == "Suffix") and type(mod[1]) == "string" then
			local template = mod[1]:gsub("%(%-?[%d%.]+%-%-?[%d%.]+%)", "#"):gsub("%-?%d+%.?%d*", "#"):lower()
			local lo = tonumber(mod[1]:match("%((%-?[%d%.]+)%-") or mod[1]:match("(%-?[%d%.]+)"))
			if lo then
				tierIndex[template] = tierIndex[template] or { }
				t_insert(tierIndex[template], { mod = mod, lo = lo })
			end
		end
	end
end
local function canRoll(mod, tags)
	for i, key in ipairs(mod.weightKey or { }) do
		if tags[key] then return (mod.weightVal[i] or 0) > 0 end
	end
	return false
end
function PriceSourceClass.RareTierQuality(item)
	if not tierIndex then buildTierIndex() end
	local tags = { default = true }
	for tag in pairs(item.base and item.base.tags or { }) do tags[tag] = true end
	for _, key in ipairs({ "shaper", "elder", "adjudicator", "basilisk", "crusader", "eyrie" }) do
		if item[key] and item.base and item.base.influenceTags then
			for _, t in pairs(item.base.influenceTags) do tags[t] = true end
		end
	end
	local sum, count, top = 0, 0, 0
	for _, l in ipairs(item.explicitModLines or { }) do
		if not l.crafted and l.line then
			local value = tonumber(l.line:match("(%-?[%d%.]+)"))
			local template = l.line:gsub("%-?%d+%.?%d*", "#"):lower()
			local candidates = tierIndex[template]
			if value and candidates then
				local tiers = { }
				for _, c in ipairs(candidates) do
					if canRoll(c.mod, tags) then t_insert(tiers, c) end
				end
				if #tiers >= 2 then
					table.sort(tiers, function(a, b) return a.lo > b.lo end)
					local rank = #tiers
					for i, t in ipairs(tiers) do
						if value >= t.lo then rank = i break end
					end
					sum = sum + 1 - (rank - 1) / (#tiers - 1)
					count = count + 1
					if rank <= 2 then top = top + 1 end
				end
			end
		end
	end
	return count > 0 and sum / count or nil, count, top
end

-- (rare jewels by how many useful mods they have - every mod the generator
-- puts on one is wanted: 2 about half a divine, 3 a few, 4 a "god" jewel)
-- (counted by affixes, not lines: "Attacks have 4% chance to cause Bleeding"
-- + "13% increased Bleeding Duration" is one mod; by lines a 3 mod jewel was a
-- 4 mod "god" jewel - 74 divines at first-week prices in a 30 divines build;
-- 4 mods 10, a good 3 mod 2: poe.ninja-era trade prices for wanted mods)
local jewelModPrices = { [0] = 0.05, 0.1, 0.4, 2, 10 }
function PriceSourceClass:RarePrice(item, level)
	level = level or { }
	local base = level.rarePrice or 1
	if not item then return base end
	if item.type == "Jewel" and not item.clusterJewel and not (item.base and item.base.subType) then
		local n = 0
		local affixes = 0
		for _, list in ipairs({ item.prefixes or { }, item.suffixes or { } }) do
			for _, a in ipairs(list) do
				if a.modId and a.modId ~= "None" then affixes = affixes + 1 end
			end
		end
		if affixes > 0 then
			n = affixes
		else
			for _, l in ipairs(item.explicitModLines or { }) do if not l.crafted then n = n + 1 end end
		end
		return (jewelModPrices[math.min(4, n)] or 10) * self:PhaseFactor("rare")
	end
	local good, crafted = 0, 0
	for _, l in ipairs(item.explicitModLines or { }) do
		if l.crafted then crafted = crafted + 1 else good = good + 1 end
	end
	local expected = level.rareAffixes or 6
	local price = base * math.max(0.3, (good / math.max(1, expected))) ^ 2
	-- by the tiers of its mods when enough of them can be matched (not the level
	-- the item was made at): a perfect rare costs more than a mediocre one of
	-- the same level. Good mods = tier quality cubed (top tiers count, middling
	-- ones little; at most six: hybrid and influence lines are part of an
	-- affix), the unmatched lines counted at the matched average;
	-- six top tier mods ~ 46 divines before slot, influence and phase factors
	if self.tierPricing ~= false then
		local q, matched = PriceSourceClass.RareTierQuality(item)
		if q and matched >= 2 then
			price = 0.15 * 2.6 ^ (math.min(6, good) * q ^ 3)
		end
	end
	local influences = 0
	for _, key in ipairs({ "shaper", "elder", "adjudicator", "basilisk", "crusader", "eyrie", "cleansing", "tangle" }) do
		if item[key] then influences = influences + 1 end
	end
	price = price * (influences == 0 and 1 or influences == 1 and 1.5 or 3)
	local eldritch = 0
	for _, l in ipairs(item.implicitModLines or { }) do
		if l.line and (l.exarch or l.eater or l.line:match("Searing Exarch") or l.line:match("Eater of Worlds")) then eldritch = eldritch + 1 end
	end
	if eldritch > 0 then price = price * 1.3 end
	if crafted > 1 then price = price + 2 * (crafted - 1) end
	if item.base and item.base.weapon then price = price * 1.8 elseif item.type == "Body Armour" then price = price * 1.2 end
	return price * self:PhaseFactor("rare")
end

-- Price of a gem at a level (the nearest listed level at or below it); nil = not listed
-- A gem's price (divines): its level as listed on poe.ninja (keys
-- "name:level", "name:levelc" for corrupted copies). Above the gem's natural
-- maximum (21/20, Awakened 6, exceptional 4+) only a corrupted copy exists;
-- else the clean copy, else the nearest level below. (The cache had no gem
-- prices at all: an Awakened Enlighten 5 - 350 to 550 divines - counted 0 in
-- the budget, with 300 divines builds carrying one.)
function PriceSourceClass:GemPrice(name, level, maxLevel)
	local gems = self.gems or { }
	level = level or 20
	local factor = self:PhaseFactor("rare")
	if maxLevel and level > maxLevel then
		local price = gems[name .. ":" .. level .. "c"]
		if price then return price * factor end
	end
	for l = level, 1, -1 do
		local price = gems[name .. ":" .. l] or gems[name .. ":" .. l .. "c"]
		if price then return price * factor end
	end
	return nil
end

function PriceSourceClass:TattooPrice(name)
	local price = self.tattoos[name]
	return price and price * self:PhaseFactor("rare")
end

-- Anoint price: the three oils of the notable's recipe ("GoldenOil" -> "Golden Oil")
function PriceSourceClass:AnointPrice(node)
	if not node.recipe then return nil end
	local phase = self:PhaseFactor("rare")
	local total = 0
	for _, oil in ipairs(node.recipe) do
		local price = self.oils[(oil:gsub("(%l)(%u)", "%1 %2"))]
		if not price then return nil end
		total = total + price
	end
	return total * phase
end

-- Is a price within an investment level's cap? kind = "unique" / "anoint" / "tattoo"
function PriceSourceClass:Allows(level, kind, price)
	if not level or not self.loaded then
		return true -- no prices: nothing is filtered
	end
	local cap = kind == "anoint" and level.maxAnoint or kind == "tattoo" and level.maxTattoo or level.maxUnique
	if price == nil then
		return level.unknownAllowed or cap == nil
	end
	return cap == nil or price <= cap
end

function PriceSourceClass.FormatPrice(price)
	if not price then return "price unknown" end
	if price < 0.1 then return "<0.1 div" end
	if price < 10 then return string.format("%.1f div", price) end
	return string.format("%d div", math.floor(price + 0.5))
end
