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
-- rareAffixes: the good natural mods a rare of the budget realistically has
-- (plus the bench craft; nil = all six); rarePrice: rough price of one rare
-- piece of gear made at that level (rares aren't on poe.ninja); budgetUpTo:
-- the level a total budget up to that many divines uses
PriceSourceClass.levels = {
	{ id = "LEAGUE_START", label = "League start (items up to 1 divine)", rarePrice = 0.05, budgetUpTo = 3, rareAffixes = 3, maxUnique = 1, maxAnoint = 1, maxTattoo = 0.1, influences = 0, eldritchTier = 1, quality = 3, unknownAllowed = false,
		enlighten = nil, exceptionalGems = false, awakenedGems = false, timeless = false, scarce = false },
	{ id = "BUDGET", label = "Budget (items up to 5 divines)", rarePrice = 0.3, budgetUpTo = 15, rareAffixes = 4, maxUnique = 5, maxAnoint = 3, maxTattoo = 0.5, influences = 0, eldritchTier = 3, quality = 2, unknownAllowed = false,
		enlighten = nil, exceptionalGems = false, awakenedGems = false, timeless = true, scarce = false },
	{ id = "MID", label = "Mid investment (items up to 30 divines)", rarePrice = 1.5, budgetUpTo = 100, rareAffixes = 4, maxUnique = 30, maxAnoint = 10, maxTattoo = 2, influences = 1, maxInfluenced = 2, eldritchTier = 4, quality = 2, unknownAllowed = false,
		enlighten = nil, exceptionalGems = false, awakenedGems = false, timeless = true, scarce = false },
	{ id = "HIGH", label = "High investment (items up to 150 divines)", rarePrice = 8, budgetUpTo = 450, rareAffixes = 5, maxUnique = 150, maxAnoint = 50, maxTattoo = 10, influences = 2, maxInfluenced = 4, eldritchTier = 5, quality = 2, unknownAllowed = true,
		enlighten = { name = "Enlighten", level = 4 }, exceptionalGems = true, awakenedGems = true, timeless = true, corruptedMain = true },
	{ id = "ENDGAME", label = "Endgame investment (items up to 500 divines, Mageblood level)", rarePrice = 30, budgetUpTo = 2000, multiCraft = true, maxUnique = 500, maxAnoint = 150, maxTattoo = 30, influences = 2, maxInfluenced = 7, eldritchTier = 6, quality = 4, unknownAllowed = true,
		enlighten = { name = "Awakened Enlighten", level = 5 }, exceptionalGems = true, awakenedGems = true, timeless = true, corruptedMain = true, corruptedSupports = true },
	{ id = "MIRROR", label = "No limit (mirror tier)", rarePrice = 150, multiCraft = true, influences = 2, eldritchTier = 6, elevated = true, quality = 1, unknownAllowed = true,
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

-- The investment level for a total budget (divines for the whole build): the
-- level whose rares and features fit, with per-item caps from the total (one
-- item can't take more than half of it)
function PriceSourceClass.ForBudget(total)
	local chosen
	for _, level in ipairs(PriceSourceClass.levels) do
		chosen = level
		if level.budgetUpTo and total <= level.budgetUpTo then break end
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
function PriceSourceClass.Available(level, title)
	if not level or not title then return true end
	if level.scarce == false and PriceSourceClass.scarceUniques[title] then return false end
	return true
end

function PriceSourceClass:PriceSource()
	self.uniques, self.tattoos, self.oils, self.gems = { }, { }, { }, { }
	self.loaded = false
	self:LoadCache()
	return self
end

function PriceSourceClass:CachePath()
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
	file:write(dkjson.encode({ time = self.time, league = self.league, uniques = self.uniques, tattoos = self.tattoos, oils = self.oils, gems = self.gems }))
	file:close()
end

function PriceSourceClass:SetData(data)
	self.time = data.time
	self.league = data.league
	self.uniques = data.uniques or { }
	self.tattoos = data.tattoos or { }
	self.oils = data.oils or { }
	self.gems = data.gems or { }
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

function PriceSourceClass:UniquePrice(item)
	local title = item.title or (item.name and item.name:match("^([^,]+),")) or item.name
	return title and self.uniques[title]
end

-- Price of a gem at a level (the nearest listed level at or below it); nil = not listed
function PriceSourceClass:GemPrice(name, level)
	for l = level or 20, 1, -1 do
		local price = self.gems[name .. ":" .. l]
		if price then return price end
	end
	return nil
end

function PriceSourceClass:TattooPrice(name)
	return self.tattoos[name]
end

-- Anoint price: the three oils of the notable's recipe ("GoldenOil" -> "Golden Oil")
function PriceSourceClass:AnointPrice(node)
	if not node.recipe then return nil end
	local total = 0
	for _, oil in ipairs(node.recipe) do
		local price = self.oils[(oil:gsub("(%l)(%u)", "%1 %2"))]
		if not price then return nil end
		total = total + price
	end
	return total
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
