-- Path of Building
--
-- Class: Craft Advisor
-- How a generated rare can actually be made: for each of its mods, whether an
-- essence guarantees it, the crafting bench can add it, it needs an influence
-- (Conqueror's exalt / influenced base), or it has to be rolled. Gives a short
-- recipe per item and a rough difficulty, so a "Best Rare" is something you
-- can craft or search for, not a fantasy.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert

---@class CraftAdvisor
local CraftAdvisorClass = newClass("CraftAdvisor")

function CraftAdvisorClass:CraftAdvisor()
	return self
end

-- Item class names used by the essence and bench tables for a base type
local function itemClass(item)
	local base = item.base or { }
	return base.subType and (base.subType .. " " .. base.type) or base.type
end

-- modId -> essence name, for this item class (cached per class)
local essenceCache = { }
local function essencesFor(class, fallback)
	local key = class or fallback or ""
	if essenceCache[key] then return essenceCache[key] end
	local map = { }
	for _, essence in pairs(data.essences or { }) do
		local modId = essence.mods and (essence.mods[class] or essence.mods[fallback])
		if modId then
			-- keep the strongest essence that gives the mod
			if not map[modId] or (essence.tier or 0) > (map[modId].tier or 0) then
				map[modId] = { name = essence.name, tier = essence.tier }
			end
		end
	end
	essenceCache[key] = map
	return map
end

-- Mods the crafting bench can add to this item class
local benchCache = { }
local function benchGroups(class, fallback)
	local key = class or fallback or ""
	if benchCache[key] then return benchCache[key] end
	-- (by mod text: the bench only makes its own, lower tiers)
	local groups = { }
	for _, mod in ipairs(data.masterMods or { }) do
		if mod[1] and mod.types and (mod.types[class] or mod.types[fallback]) then
			groups[mod[1]] = mod
		end
	end
	benchCache[key] = groups
	return groups
end

-- Influence a mod needs, from its spawn weights ("gloves_shaper"...)
local influences = { "shaper", "elder", "crusader", "redeemer", "hunter", "warlord" }
local function influenceOf(mod)
	for i, key in ipairs(mod.weightKey or { }) do
		for _, inf in ipairs(influences) do
			if key:match("_" .. inf .. "$") and (mod.weightVal and (mod.weightVal[i] or 0) > 0) then return inf end
		end
	end
end

-- Describes a generated rare: { essence = { names }, bench = { lines }, influenced = { lines },
-- random = n, text = "..." }
function CraftAdvisorClass:Describe(item)
	local class = itemClass(item)
	local fallback = item.base and item.base.type
	local essences = essencesFor(class, fallback)
	local bench = benchGroups(class, fallback)
	local result = { essence = { }, bench = { }, influenced = { }, random = { } }
	local benchUsed = false
	local essenceUsed = false
	for _, list in ipairs({ item.prefixes or { }, item.suffixes or { } }) do
		for _, entry in ipairs(list) do
			local mod = entry.modId and (data.itemMods.Explicit[entry.modId] or data.itemMods.Item and data.itemMods.Item[entry.modId])
			if mod then
				local text = mod[1] or entry.modId
				local essence = essences[entry.modId]
				local inf = influenceOf(mod)
				if essence and not essenceUsed then
					essenceUsed = true
					t_insert(result.essence, string.format("%s (%s)", essence.name, text))
				elseif inf then
					t_insert(result.influenced, string.format("%s (%s)", text, inf:sub(1, 1):upper() .. inf:sub(2)))
				elseif bench[text] and not benchUsed then
					benchUsed = true
					t_insert(result.bench, text)
				else
					t_insert(result.random, text)
				end
			end
		end
	end
	-- the bench craft the generator chose (crafted lines on the item)
	local craftedLines = { }
	for _, modLine in ipairs(item.explicitModLines or { }) do
		if modLine.crafted then t_insert(craftedLines, modLine.line) end
	end
	if #craftedLines > 0 then
		-- (then a natural bench-craftable mod is rolled, not crafted)
		for _, text in ipairs(result.bench) do t_insert(result.random, text) end
		result.bench = { table.concat(craftedLines, ", ") }
	end
	local parts = { }
	if #result.essence > 0 then t_insert(parts, "essence: " .. table.concat(result.essence, ", ")) end
	if #result.influenced > 0 then t_insert(parts, "influence mods: " .. table.concat(result.influenced, ", ")) end
	if #result.bench > 0 then t_insert(parts, "bench craft: " .. table.concat(result.bench, ", ")) end
	local nRandom = #result.random
	local difficulty = nRandom <= 2 and "easy" or nRandom <= 3 and "medium" or nRandom <= 4 and "hard" or "very hard (buy it)"
	t_insert(parts, string.format("%d mod%s to roll (%s)", nRandom, nRandom == 1 and "" or "s", difficulty))
	result.text = table.concat(parts, "; ")
	result.difficulty = difficulty
	return result
end
