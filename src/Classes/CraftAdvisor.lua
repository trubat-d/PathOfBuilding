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

------------------------------------------------------------------------------
-- A crafting process for a generated rare (poewiki: Crafting, Guide:Crafting)
------------------------------------------------------------------------------
-- The methods it picks from, cheapest first for what the item needs:
--   * the base: item level for the highest mod tiers; one influence on a
--     dropped base or a Conqueror's / Shaper's / Elder's Exalted Orb (one
--     influenced mod each), two through an Awakener's Orb (two items, one
--     influenced mod each, merged);
--   * Eldritch implicits (non-influenced armour): Eldritch Ember / Ichor,
--     Orb of Conflict to raise one of them;
--   * the core mods: an essence that guarantees one of them (Deafening /
--     Shrieking essences reforge rares); otherwise Harvest's "reforge with a
--     <tag> modifier" or a fossil for the tag most of the wanted mods share;
--     for one prefix and one suffix, alteration + augmentation on a magic
--     item, then Regal Orb;
--   * the rest: Exalted Orbs with the unwanted mod types blocked by bench
--     crafts, or "Prefixes / Suffixes Cannot Be Changed" + scour to retry one
--     side (2 divines each);
--   * last: the bench craft(s) ("Can have up to 3 Crafted Modifiers" for
--     more than one), quality, sockets and links, a Divine Orb for the values.

-- Harvest reforge tags and the fossil weighting the same mods
local tagMethods = {
	{ tag = "life", harvest = "Life", fossil = "Pristine" },
	{ tag = "fire", harvest = "Fire", fossil = "Scorched" },
	{ tag = "cold", harvest = "Cold", fossil = "Frigid" },
	{ tag = "lightning", harvest = "Lightning", fossil = "Metallic" },
	{ tag = "physical", harvest = "Physical", fossil = "Jagged" },
	{ tag = "chaos", harvest = "Chaos", fossil = "Aberrant" },
	{ tag = "defences", harvest = "Defence", fossil = "Dense" },
	{ tag = "caster", harvest = "Caster", fossil = "Aetheric" },
	{ tag = "attack", harvest = "Attack", fossil = "Serrated" },
	{ tag = "speed", harvest = "Speed", fossil = "Shuddering" },
	{ tag = "critical", harvest = "Critical" },
	{ tag = "elemental", fossil = "Prismatic" },
}
local influenceNames = {
	shaper = "Shaper", elder = "Elder", crusader = "Crusader", eyrie = "Redeemer", basilisk = "Hunter", adjudicator = "Warlord",
}
local influenceByName = { shaper = "shaper", elder = "elder", crusader = "crusader", redeemer = "eyrie", hunter = "basilisk", warlord = "adjudicator" }

local function modOf(entry)
	return entry and entry.modId and (data.itemMods.Explicit[entry.modId] or (data.itemMods.Item and data.itemMods.Item[entry.modId]))
end

-- Steps to make the item: { "1. ...", "2. ..." } and a one-line summary
function CraftAdvisorClass:Plan(item)
	local class = itemClass(item)
	local fallback = item.base and item.base.type
	local essences = essencesFor(class, fallback)
	local steps = { }
	local function step(fmt, ...) t_insert(steps, string.format(fmt, ...)) end
	-- the mods it needs, natural ones
	local natural, maxLevel = { }, 1
	for _, list in ipairs({ item.prefixes or { }, item.suffixes or { } }) do
		for _, entry in ipairs(list) do
			local mod = modOf(entry)
			if mod then
				maxLevel = math.max(maxLevel, mod.level or 1)
				local inf = influenceOf(mod)
				t_insert(natural, { mod = mod, text = mod[1] or entry.modId, type = mod.type, influence = inf, essence = essences[entry.modId], tags = mod.modTags or { } })
			end
		end
	end
	local crafted = { }
	for _, modLine in ipairs(item.explicitModLines or { }) do
		if modLine.crafted then t_insert(crafted, modLine.line) end
	end
	-- 1. the base
	local itemInfluences = { }
	for key, name in pairs(influenceNames) do if item[key] then t_insert(itemInfluences, name) end end
	table.sort(itemInfluences)
	local ilvl = math.max(68, maxLevel)
	step("Base: %s, item level %d or more (the highest tier of its mods)", item.baseName or "?", ilvl)
	local influenced, plain = { }, { }
	for _, m in ipairs(natural) do
		if m.influence then t_insert(influenced, m) else t_insert(plain, m) end
	end
	-- 2. Eldritch implicits (before the explicits: they don't touch them)
	local eldritch = { }
	for _, l in ipairs(item.implicitModLines or { }) do
		if l.exarch then t_insert(eldritch, "Eldritch Ember (Exarch): " .. l.line) end
		if l.eater then t_insert(eldritch, "Eldritch Ichor (Eater): " .. l.line) end
	end
	if #eldritch > 0 then
		step("Implicits on the white base: %s; an Orb of Conflict raises one of them (and lowers the other)", table.concat(eldritch, "; "))
	end
	-- 3. the core mods
	local essence
	for _, m in ipairs(plain) do if m.essence and not essence then essence = m end end
	local rest = { }
	if essence then
		step("Reforge with %s until it rolls with the best other mods (guarantees: %s); Deafening / Shrieking essences reforge a rare again", essence.essence.name, essence.text)
		for _, m in ipairs(plain) do if m ~= essence then t_insert(rest, m) end end
	else
		-- (the tag most wanted mods share: one reforge method weights them all)
		local best, bestCount
		for _, tm in ipairs(tagMethods) do
			local count = 0
			for _, m in ipairs(plain) do
				for _, t in ipairs(m.tags) do if t == tm.tag then count = count + 1 break end end
			end
			if count > 0 and (not bestCount or count > bestCount) then best, bestCount = tm, count end
		end
		local prefixes, suffixes = { }, { }
		for _, m in ipairs(plain) do t_insert(m.type == "Prefix" and prefixes or suffixes, m) end
		if best and bestCount >= 2 then
			local how = { }
			if best.harvest then t_insert(how, "Harvest: reforge with a " .. best.harvest .. " modifier") end
			if best.fossil then t_insert(how, best.fossil .. " Fossil(s)") end
			local tagged = { }
			for _, m in ipairs(plain) do
				for _, t in ipairs(m.tags) do if t == best.tag then t_insert(tagged, m.text) break end end
			end
			step("Alchemy, then reforge (%s) until it has %s", table.concat(how, " or "), table.concat(tagged, ", "))
			for _, m in ipairs(plain) do
				local hit = false
				for _, t in ipairs(m.tags) do if t == best.tag then hit = true end end
				if not hit then t_insert(rest, m) end
			end
		elseif #plain > 0 then
			local a = prefixes[1]
			local b = suffixes[1]
			step("Transmutation, then Alteration + Augmentation until it has %s; Regal Orb (scour and start again if the regal mod is unwanted)",
				table.concat({ a and a.text or nil, b and b.text or nil }, " and "))
			for _, m in ipairs(plain) do if m ~= a and m ~= b then t_insert(rest, m) end end
		end
	end
	-- 4. the other natural mods
	if #rest > 0 then
		local names = { }
		for _, m in ipairs(rest) do t_insert(names, m.text) end
		step("Exalted Orbs for %s: block the mod types you don't want with bench crafts first; a bad roll is undone with an Orb of Annulment, or keep the good side with \"Prefixes / Suffixes Cannot Be Changed\" (bench, 2 divines) and scour the other",
			table.concat(names, ", "))
	end
	-- 5. influenced mods
	if #influenced > 0 then
		local names = { }
		for _, m in ipairs(influenced) do t_insert(names, string.format("%s (%s)", m.text, m.influence:sub(1, 1):upper() .. m.influence:sub(2))) end
		if #influenced == 1 then
			step("%s's Exalted Orb on the rare (non-influenced) for %s - or buy a %s base with it", influenced[1].influence:sub(1, 1):upper() .. influenced[1].influence:sub(2), names[1], influenced[1].influence)
		else
			step("Two influenced items of this base, one influenced mod each (%s), merged with an Awakener's Orb (keeps one influenced mod from each); then the rest as above", table.concat(names, ", "))
		end
	elseif #itemInfluences > 0 then
		step("Influence: %s (its mods aren't needed - a cheaper non-influenced base works too)", table.concat(itemInfluences, "/"))
	end
	-- 6. bench, finish
	if #crafted > 0 then
		local multi = false
		for _, l in ipairs(crafted) do if l:match("^Can have up to 3 Crafted Modifiers") then multi = true end end
		step("Bench: %s%s", table.concat(crafted, ", "), multi and " (\"Can have up to 3 Crafted Modifiers\" first)" or "")
	end
	local jewellery = item.base and (item.base.type == "Ring" or item.base.type == "Amulet" or item.base.type == "Belt")
	local finish = { jewellery and "catalysts for the main mod type (jewellery quality)" or "20% quality" }
	if item.base and (item.base.armour or item.base.weapon) then t_insert(finish, "sockets / links / colours (Jeweller's, Fusing, Chromatic; a 6-link with a Black Morrigan beast)") end
	t_insert(finish, "a Divine Orb if the values are low")
	step("Finish: %s", table.concat(finish, ", "))
	local numbered = { }
	for i, s in ipairs(steps) do numbered[i] = string.format("%d. %s", i, s) end
	return numbered
end
