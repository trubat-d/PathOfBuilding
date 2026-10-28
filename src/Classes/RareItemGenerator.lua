-- Path of Building
--
-- Class: Rare Item Generator
-- Builds the best rare item for a gear slot out of the mods that can roll on
-- the slot's current item base:
--   1. every mod is scored on its own (how much it improves the chosen stat)
--   2. the item is filled one mod at a time, recalculating after each pick, so
--      mods that stop mattering (e.g. resistance once capped) are skipped
-- Rules followed: at most 3 prefixes and 3 suffixes, one mod per mod group,
-- at most one crafting bench mod (it takes an affix slot), no fractured or
-- delve mods; influence and eldritch mods only when asked for.
-- Runs entirely locally using the build's own calculator.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort
local m_floor = math.floor
local m_max = math.max
local m_min = math.min

---@class RareItemGenerator
local RareItemGeneratorClass = newClass("RareItemGenerator")

-- Mod quality presets: which tier to use (1 = best) and how high it rolls (0 to 1)
RareItemGeneratorClass.qualityList = {
	{ label = "Tier 1, perfect rolls (theoretical max)", tier = 1, range = 1 },
	{ label = "Tier 2-3, average rolls (realistic)", tier = 2, range = 0.25 },
	{ label = "Tier 4 and below (cheap / league start)", tier = 4, range = 0.5 },
	{ label = "Tier 1, good rolls (endgame crafts)", tier = 1, range = 0.7 },
}
RareItemGeneratorClass.defaultQuality = 2

local elements = { "Fire", "Cold", "Lightning" }
local attributes = { "Str", "Dex", "Int" }

-- Slot types the generator supports
local supportedTypes = {
	["Helmet"] = true, ["Body Armour"] = true, ["Gloves"] = true, ["Boots"] = true,
	["Amulet"] = true, ["Ring"] = true, ["Belt"] = true, ["Shield"] = true, ["Quiver"] = true,
}

---@param finder BestItemFinder
function RareItemGeneratorClass:RareItemGenerator(finder)
	self.finder = finder
	self.itemsTab = finder.itemsTab
	self.build = finder.build
	return self
end

function RareItemGeneratorClass:IsSupported(item)
	if not item or not item.base then
		return false
	end
	if item.base.flask or item.type == "Jewel" or item.type == "Tincture" or item.type == "Graft" then
		return false
	end
	return supportedTypes[item.type] or item.base.weapon ~= nil
end

-- Creates an empty rare on the same base as the current item. Enchants and
-- anoints are kept; implicits are kept unless the current item is a unique
-- (unique implicits are not part of the base).
function RareItemGeneratorClass:MakeBlankRare(current, influences)
	local item = new("Item"):Item()
	for _, key in ipairs(influences or { }) do
		item[key] = true
	end
	item.name = "Best Rare, " .. current.baseName
	item.title = "Best Rare"
	item.base = current.base
	item.baseName = current.baseName
	item.rarity = "RARE"
	item.crafted = true
	item.buffModLines = { }
	item.classRequirementModLines = { }
	item.scourgeModLines = { }
	item.crucibleModLines = { }
	item.explicitModLines = { }
	item.enchantModLines = copyTable(current.enchantModLines or { })
	item.implicitModLines = { }
	if current.rarity ~= "UNIQUE" and current.rarity ~= "RELIC" then
		item.implicitModLines = copyTable(current.implicitModLines or { })
		-- (an influenced item can't have Eldritch implicits: a rare that had
		-- them, made again with an influence, loses them)
		if influences and influences[1] then
			for i = #item.implicitModLines, 1, -1 do
				local l = item.implicitModLines[i]
				if l.exarch or l.eater then table.remove(item.implicitModLines, i) end
			end
		end
	end
	-- (the base's own implicits when the item has none: a rare made on a base
	-- the slot never had - a Void Sceptre without its "40% increased Elemental
	-- Damage" - or an influenced remake of an Eldritch item)
	if not item.implicitModLines[1] and current.base.implicit then
		local index = 1
		for line in current.base.implicit:gmatch("[^\n]+") do
			local modList, extra = modLib.parseMod(line)
			t_insert(item.implicitModLines, { line = line, extra = extra, modList = modList or { }, modTags = current.base.implicitModTypes and current.base.implicitModTypes[index] or { } })
			index = index + 1
		end
	end
	if current.sockets and #current.sockets > 0 then
		item.sockets = copyTable(current.sockets)
	end
	item.quality = current.quality
	item:NormaliseQuality()
	item:BuildAndParseRaw()
	return item
end

-- Groups the mods that can roll on this item into series (all tiers of one mod)
-- and picks the tier to use for each series. Returns a list of candidates:
-- { modId, mod, label, group, type }
function RareItemGeneratorClass:GetCandidates(item, quality, levelOnly, modTable)
	local charLevel = self.build.characterLevel
	local series = { }
	modTable = modTable or data.itemMods.Explicit
	for modId, mod in pairs(modTable) do
		local elevated = mod.affix and mod.affix:match("Elevated")
		if (mod.type == "Prefix" or mod.type == "Suffix") and item.affixes[modId] and not item:CheckIfModIsDelve(mod) and item:CanHaveMod(mod)
			and (self.allowElevated or not elevated) then
			local key = (mod.group or modId) .. "|" .. table.concat(mod.statOrder or { }, ",")
			series[key] = series[key] or { }
			t_insert(series[key], modId)
		end
	end
	local candidates = { }
	for _, list in pairs(series) do
		-- best tier first
		t_sort(list, function(a, b)
			local la, lb = modTable[a].level, modTable[b].level
			if la ~= lb then
				return la > lb
			end
			return a < b
		end)
		local index = m_min(quality.tier, #list)
		if levelOnly then
			-- skip tiers whose level requirement is above the character
			while index <= #list and m_floor(modTable[list[index]].level * 0.8) > charLevel do
				index = index + 1
			end
		end
		local modId = list[index]
		if modId then
			local mod = modTable[modId]
			local lines = { }
			for _, line in ipairs(mod) do
				t_insert(lines, (itemLib.applyRange(line, quality.range, 1, 1)))
			end
			t_insert(candidates, {
				modId = modId,
				mod = mod,
				group = mod.group or modId,
				type = mod.type,
				tier = index,
				lines = lines,
				label = table.concat(lines, ", "),
			})
		end
	end
	t_sort(candidates, function(a, b) return a.modId < b.modId end)
	return candidates
end

-- Crafting bench mods for this item (one per item, taking an affix slot like
-- the natural ones): the best tier the character's level allows per mod group.
-- Bench "meta" crafts (prefixes cannot be changed...) are left out.
local craftCache = { }
-- Prefix / Suffix of a bench craft from its line (nil when no bench mod has it)
local benchTypeOf
function RareItemGeneratorClass.BenchType(line)
	if not benchTypeOf then
		benchTypeOf = { }
		for _, mod in ipairs(data.masterMods or { }) do
			if (mod.type == "Prefix" or mod.type == "Suffix") then
				for _, l in ipairs(mod) do
					local shape = l:gsub("%(%-?[%d%.]+%-%-?[%d%.]+%)", "#"):gsub("%-?[%d%.]+", "#")
					benchTypeOf[shape] = benchTypeOf[shape] or mod.type
				end
			end
		end
	end
	local shape = (line or ""):gsub("%(%-?[%d%.]+%-%-?[%d%.]+%)", "#"):gsub("%-?[%d%.]+", "#")
	return benchTypeOf[shape]
end
function RareItemGeneratorClass:GetCraftCandidates(item, quality)
	local class = item.type
	local charLevel = self.build.characterLevel
	local key = tostring(class) .. "|" .. charLevel .. "|" .. tostring(quality.range)
	if craftCache[key] then return craftCache[key] end
	local best, indexOf = { }, { }
	for index, mod in ipairs(data.masterMods or { }) do
		if (mod.type == "Prefix" or mod.type == "Suffix") and mod.types and mod.types[class] and (mod.level or 1) <= charLevel and mod[1] then
			local usable = true
			for _, line in ipairs(mod) do
				local modList, extra = modLib.parseMod((itemLib.applyRange(line, quality.range, 1, 1)))
				if not modList or extra then usable = false break end
			end
			if usable then
				local k = (mod.group or "") .. "|" .. table.concat(mod.statOrder or { }, ",")
				if not best[k] or (mod.level or 0) > (best[k].level or 0) then best[k] = mod; indexOf[mod] = index end
			end
		end
	end
	local list = { }
	for _, mod in pairs(best) do
		local lines = { }
		for _, line in ipairs(mod) do t_insert(lines, (itemLib.applyRange(line, quality.range, 1, 1))) end
		t_insert(list, {
			modId = "craft" .. indexOf[mod], mod = mod, group = mod.group or ("craft" .. indexOf[mod]), type = mod.type,
			crafted = true, lines = lines, label = table.concat(lines, ", ") .. " (crafted)",
		})
	end
	t_sort(list, function(a, b) return a.modId < b.modId end)
	craftCache[key] = list
	return list
end

-- Mod families (Data/ModFamilies, from poewiki): a bench craft can't share
-- one with a mod already on the item - "+X to Strength and Intelligence" is
-- of the Strength and the Intelligence families
local modFamilies, familyById
local function familiesOf(mod, modId, crafted)
	modFamilies = modFamilies or LoadModule("Data/ModFamilies")
	familyById = familyById or LoadModule("Data/ModFamilyById")
	if not mod then return { } end
	if crafted then
		return modFamilies.craft[mod.group or ""] or { mod.group }
	end
	if modId and familyById[modId] then return familyById[modId] end
	local stem = modId and modId:gsub("%d*_*$", "")
	return (stem and modFamilies.natural[stem]) or { mod.group }
end
RareItemGeneratorClass.FamiliesOf = familiesOf

-- A bench craft the item refuses: it shares a family or a stat with one of
-- the item's natural prefixes / suffixes (poewiki Crafting Bench: "The item
-- cannot already have a mod of that type")
function RareItemGeneratorClass.CraftClashes(item, candidate)
	local stats, fams = { }, { }
	for _, so in ipairs(candidate.mod and candidate.mod.statOrder or { }) do stats[so] = true end
	for _, f in ipairs(familiesOf(candidate.mod, candidate.modId, true)) do fams[f] = true end
	for _, list in ipairs({ item.prefixes or { }, item.suffixes or { } }) do
		for _, affix in ipairs(list) do
			local mod = affix.modId and affix.modId ~= "None" and data.itemMods.Explicit[affix.modId]
			if mod then
				if candidate.mod and mod.group and mod.group == candidate.mod.group then return true end
				for _, so in ipairs(mod.statOrder or { }) do
					if stats[so] then return true end
				end
				for _, f in ipairs(familiesOf(mod, affix.modId, false)) do
					if fams[f] then return true end
				end
			end
		end
	end
	return false
end

-- Total amount by which the build's resistances / attributes are worse than the baseline
local function deficit(output, baseOutput, opts)
	local total = 0
	if opts.keepResists then
		for _, elem in ipairs(elements) do
			local key = "Missing" .. elem .. "Resist"
			total = total + m_max(0, (output[key] or 0) - (baseOutput[key] or 0))
		end
	end
	if opts.keepAttributes then
		for _, attr in ipairs(attributes) do
			local newMissing = m_max(0, (output["Req" .. attr] or 0) - (output[attr] or 0))
			local oldMissing = m_max(0, (baseOutput["Req" .. attr] or 0) - (baseOutput[attr] or 0))
			total = total + m_max(0, newMissing - oldMissing)
		end
	end
	if opts.keepLife then
		-- 20 life or energy shield counts as much as 1% resistance
		for _, key in ipairs({ "Life", "EnergyShield" }) do
			total = total + m_max(0, (baseOutput[key] or 0) - (output[key] or 0)) / 20
		end
	end
	return total
end

-- Generates the best rare for a slot.
-- ctx: { calcFunc, useFullDPS, stat, baseOutput, basePower, opts, tick = function() }
-- Returns result (or nil) and the per-mod score list
function RareItemGeneratorClass:GenerateForSlotWith(slotName, current, ctx, influences)
	local opts = ctx.opts
	local quality = opts.quality or self.qualityList[self.defaultQuality]
	local calcFunc, useFullDPS, stat = ctx.calcFunc, ctx.useFullDPS, ctx.stat

	local subject = self:MakeBlankRare(current, influences)
	local half = subject.affixLimit and subject.affixLimit > 0 and subject.affixLimit / 2 or 3
	local prefixLimit = subject.prefixes.limit or half
	local suffixLimit = subject.suffixes.limit or half
	-- jewels roll from their own mod pool (2 prefixes + 2 suffixes on rares)
	-- (abyss jewels from theirs: life, resistances, added damage...)
	local modTable = current.type == "Jewel" and (current.base and current.base.subType == "Abyss" and data.itemMods.JewelAbyss or data.itemMods.Jewel) or nil
	local candidates = self:GetCandidates(subject, quality, opts.levelOnly, modTable)
	if current.type ~= "Jewel" and opts.crafts ~= false then
		for _, craft in ipairs(self:GetCraftCandidates(subject, quality)) do t_insert(candidates, craft) end
	end

	-- Adds the parsed lines of a candidate to the test subject
	local function push(candidate)
		for _, line in ipairs(candidate.lines) do
			local modList, extra = modLib.parseMod(line)
			local modLine = { line = line, modList = modList or { }, extra = extra, modTags = candidate.mod.modTags or { } }
			modLine[candidate.type == "Prefix" and "prefix" or "suffix"] = true
			t_insert(subject.explicitModLines, modLine)
		end
	end
	local function pop(candidate)
		for _ = 1, #candidate.lines do
			t_remove(subject.explicitModLines)
		end
	end
	local function evaluate()
		subject:BuildModList()
		local output = calcFunc({ repSlotName = slotName, repItem = subject }, useFullDPS)
		ctx.tick()
		return output, ctx.measure(output)
	end

	-- 1. Score every mod on its own (the influence variants of a slot share
	-- the blank base: mods already scored for it are not scored again)
	local blankOutput, blankPower = evaluate()
	local blankDeficit = deficit(blankOutput, ctx.baseOutput, opts)
	local cache = ctx.gainCache
	local bestNew, newFix = nil, false
	for _, candidate in ipairs(candidates) do
		local cached = cache and cache[candidate.modId]
		if cached then
			candidate.gain, candidate.fix = cached.gain, cached.fix
		else
			push(candidate)
			local output, power = evaluate()
			pop(candidate)
			candidate.gain = power - blankPower
			candidate.fix = blankDeficit - deficit(output, ctx.baseOutput, opts)
			if cache then cache[candidate.modId] = { gain = candidate.gain, fix = candidate.fix } end
			if influences and influences[1] then
				if not bestNew or candidate.gain > bestNew then bestNew = candidate.gain end
				if candidate.fix > 0 then newFix = true end
			end
		end
	end
	-- an influence whose own mods are all weaker than every mod the plain item
	-- chose can't make a better item: skipped (the slowest part of rare generation)
	if influences and #influences == 1 and ctx.plainChosen and #ctx.plainChosen > 0 and not (newFix and blankDeficit > 0) then
		local weakest
		for _, c in ipairs(ctx.plainChosen) do
			if not weakest or (c.gain or 0) < weakest then weakest = c.gain or 0 end
		end
		if not bestNew or bestNew <= weakest then
			return nil, { }
		end
	end
	local scores = { }
	for _, candidate in ipairs(candidates) do
		if candidate.gain > 0 then
			t_insert(scores, candidate)
		end
	end
	-- (gains to 1e-9, then the mod id: the same order every run)
	t_sort(scores, function(a, b)
		local qa, qb = m_floor(a.gain * 1e9 + 0.5), m_floor(b.gain * 1e9 + 0.5)
		if qa ~= qb then return qa > qb end
		return a.modId < b.modId
	end)

	-- 2. Shortlist: the strongest mods, plus the ones that fix resistances / attributes
	local shortlist, inList = { }, { }
	local function addToShortlist(candidate)
		if not inList[candidate] then
			inList[candidate] = true
			t_insert(shortlist, candidate)
		end
	end
	for i = 1, m_min(opts.shortlistSize or 20, #scores) do
		addToShortlist(scores[i])
	end
	-- (and a few mods of each kind that cost nothing, to fill the affixes
	-- the strong ones leave: a rare is finished with six mods - a resistance
	-- already capped still goes on an exalted orb)
	do
		local spare = { Prefix = { }, Suffix = { } }
		for _, candidate in ipairs(candidates) do
			if not inList[candidate] and not candidate.crafted and (candidate.gain or 0) >= 0 and spare[candidate.type] then
				t_insert(spare[candidate.type], candidate)
			end
		end
		for _, list in pairs(spare) do
			t_sort(list, function(a, b)
				if (a.gain or 0) ~= (b.gain or 0) then return (a.gain or 0) > (b.gain or 0) end
				return a.modId < b.modId
			end)
			for i = 1, m_min(4, #list) do addToShortlist(list[i]) end
		end
	end
	if blankDeficit > 0 then
		local fixers = { }
		for _, candidate in ipairs(candidates) do
			if candidate.fix > 0 then
				t_insert(fixers, candidate)
			end
		end
		t_sort(fixers, function(a, b)
			if a.fix ~= b.fix then
				return a.fix > b.fix
			end
			return a.gain > b.gain
		end)
		for i = 1, m_min(12, #fixers) do
			addToShortlist(fixers[i])
		end
	end

	-- weapons: the best few mods of each kind of damage scaling are candidates
	-- too, even when they're weak alone (local physical damage on a base
	-- without flat physical damage yet)
	if slotName:match("^Weapon") then
		for _, tag in ipairs({ "physical", "elemental", "chaos", "speed", "critical" }) do
			local added = 0
			for _, candidate in ipairs(scores) do
				if added >= 3 then break end
				for _, t in ipairs(candidate.mod.modTags or { }) do
					if t == tag then
						addToShortlist(candidate)
						added = added + 1
						break
					end
				end
			end
		end
	end

	-- 3. Fill the item one mod at a time. While resistances or attributes are
	-- below where they were, the pick that fixes the most wins; otherwise the
	-- pick that improves the stat the most.
	-- (seed: a mod forced first. Weapons try a few: mods that only pay off
	-- together - local physical damage and flat physical damage - lose to a
	-- flat elemental mod one at a time)
	local function fill(seed)
		local chosen = { }
		local usedGroups = { }
		local counts = { Prefix = 0, Suffix = 0, crafted = 0, influence = 0, gemLevel = 0 }
		-- (influence mods: one per influence the item has - what a Conqueror's
		-- Exalted Orb or an Awakener's Orb merge gives; an item with three
		-- Warlord mods is a lottery, not a craft. opts.maxInfluenceMods overrides)
		local maxInfluence = opts.maxInfluenceMods or #(influences or { })
		-- ("+1 to Level of Socketed Lightning / Physical / all Gems": one on an
		-- item - two or three of them together is a lottery nobody crafts)
		-- (the crafting bench can't add a mod of a type the item already has,
		-- poewiki: "The item cannot already have a mod of that type" - a natural
		-- Movement Speed and a crafted one: one mod sharing a stat with another)
		-- (and a family: "+X to Strength and Intelligence" crafted next to a
		-- natural Intelligence mod is refused too - poewiki mod families)
		local usedStats, usedFamilies = { }, { }
		local function stats(candidate)
			return candidate.mod and candidate.mod.statOrder or { }
		end
		local function families(candidate)
			if candidate.meta then return { } end
			return familiesOf(candidate.mod, candidate.modId, candidate.crafted)
		end
		local function statClash(candidate)
			for _, so in ipairs(stats(candidate)) do
				local by = usedStats[so]
				if by and (by.crafted or candidate.crafted) then return true end
			end
			-- (two natural mods of one family can't be on an item either: the
			-- Shaper "Supported by Faster Attacks / increased Attack Speed" and
			-- the plain attack speed suffix both rolled on a 30 div claw)
			for _, f in ipairs(families(candidate)) do
				if usedFamilies[f] then return true end
			end
			return false
		end
		local function useStats(candidate)
			for _, so in ipairs(stats(candidate)) do usedStats[so] = usedStats[so] or candidate end
			for _, f in ipairs(families(candidate)) do usedFamilies[f] = usedFamilies[f] or candidate end
		end
		local maxGemLevel = opts.maxGemLevelMods or 1
		-- ("+1 to Level of all ... Gems": an amulet with three of them is next to
		-- impossible to make or find - one, two only at the top budgets)
		local maxAllGemLevel = opts.maxAllGemLevelMods or (opts.multiCraft and 2 or 1)
		local function isAllGemLevel(candidate)
			if candidate.allGemLevelMod == nil then
				candidate.allGemLevelMod = false
				local lines = candidate.lines or (candidate.mod and candidate.mod) or { }
				for _, line in ipairs(lines) do
					if type(line) == "string" and line:match("to Level of all .*Gems") then candidate.allGemLevelMod = true end
				end
			end
			return candidate.allGemLevelMod
		end
		local function isGemLevel(candidate)
			if candidate.gemLevelMod == nil then
				candidate.gemLevelMod = false
				for _, line in ipairs(candidate.lines or { }) do
					if line:match("to Level of Socketed") then candidate.gemLevelMod = true end
				end
				if not candidate.lines and candidate.mod then
					for _, line in ipairs(candidate.mod) do
						if type(line) == "string" and line:match("to Level of Socketed") then candidate.gemLevelMod = true end
					end
				end
			end
			return candidate.gemLevelMod
		end
		local function isInfluence(candidate)
			if candidate.influenceMod == nil then
				candidate.influenceMod = false
				for _, t in ipairs(candidate.mod and candidate.mod.modTags or { }) do
					if t == "influence_mod" then candidate.influenceMod = true end
				end
			end
			return candidate.influenceMod
		end
		-- (opts.multiCraft: "Can have up to 3 Crafted Modifiers", itself a
		-- crafted suffix, lets a second and third bench craft in)
		local maxCrafts = opts.multiCraft and 3 or 1
		local metaTaken = false
		local limits = { Prefix = prefixLimit, Suffix = suffixLimit }
		local currentPower = blankPower
		local currentDeficit = blankDeficit
		if seed then
			push(seed)
			t_insert(chosen, seed)
			usedGroups[seed.group] = true
			counts[seed.type] = counts[seed.type] + 1
			if seed.crafted then counts.crafted = counts.crafted + 1 end
			if isInfluence(seed) then counts.influence = counts.influence + 1 end
			if isGemLevel(seed) then counts.gemLevel = counts.gemLevel + 1 end
			if isAllGemLevel(seed) then counts.allGemLevel = (counts.allGemLevel or 0) + 1 end
			useStats(seed)
			local output, power = evaluate()
			currentPower, currentDeficit = power, deficit(output, ctx.baseOutput, opts)
		end
		-- lazy greedy: a mod's gain only shrinks as the item fills (the score
		-- is logarithmic: flat and increased damage add up, resistances cap), so
		-- candidates are measured best-last-gain first and the round stops once
		-- the next one's last gain can't beat the best found (all are measured
		-- while resistances / attributes are still short)
		local lastGain = { }
		for _, candidate in ipairs(shortlist) do lastGain[candidate] = candidate.gain or 0 end
		-- (opts.maxAffixes: the natural mods a rare of this budget realistically
		-- has at the quality chosen, plus the bench craft)
		local total = prefixLimit + suffixLimit
		if opts.maxAffixes then total = m_min(total, opts.maxAffixes + 1) end
		-- (rare jewels: the mods a jewel of the budget has - four useful mods
		-- on one jewel is a 30-100 divine "god" jewel; RareItemGenerator.jewelAffixCap
		-- is set from the investment level by the generator)
		local jewelCap = current.type == "Jewel" and not (current.base and current.base.subType) and not current.clusterJewel
			and (opts.jewelAffixes or RareItemGeneratorClass.jewelAffixCap)
		if jewelCap then total = m_min(total, jewelCap) end
		while counts.Prefix + counts.Suffix < total do
			local natural = counts.Prefix + counts.Suffix - counts.crafted
			local best, bestPower, bestDeficit
			local bestNatural, bestNaturalPower, bestNaturalDeficit
			local order = { }
			for _, candidate in ipairs(shortlist) do
				local needMeta = candidate.crafted and counts.crafted >= 1 and not metaTaken
				local metaRoom = not needMeta or (counts.Suffix + (candidate.type == "Suffix" and 1 or 0) + 1 <= limits.Suffix
					and counts.Prefix + counts.Suffix + 2 <= total)
				if not usedGroups[candidate.group] and counts[candidate.type] < limits[candidate.type] and not (candidate.crafted and counts.crafted >= maxCrafts)
					and metaRoom and not (opts.maxAffixes and not candidate.crafted and natural >= opts.maxAffixes)
					and not (isInfluence(candidate) and counts.influence >= maxInfluence)
					and not (isGemLevel(candidate) and counts.gemLevel >= maxGemLevel)
					and not (isAllGemLevel(candidate) and (counts.allGemLevel or 0) >= maxAllGemLevel)
					and not statClash(candidate) then
					t_insert(order, candidate)
				end
			end
			t_sort(order, function(a, b)
				if lastGain[a] ~= lastGain[b] then return lastGain[a] > lastGain[b] end
				return a.modId < b.modId
			end)
			local lazy = currentDeficit <= 0 and opts.lazyFill ~= false
			for index, candidate in ipairs(order) do
				if lazy and best and index > 5 and lastGain[candidate] <= (bestPower - currentPower) * 0.8 then break end
				do
					push(candidate)
					local output, power = evaluate()
					pop(candidate)
					lastGain[candidate] = power - currentPower
					local d = deficit(output, ctx.baseOutput, opts)
					local better
					if not best then
						better = true
					elseif currentDeficit > 0 and d ~= bestDeficit then
						better = d < bestDeficit
					else
						better = power > bestPower + 1e-9
					end
					if better then
						best, bestPower, bestDeficit = candidate, power, d
					end
					if not candidate.crafted and (not bestNatural or power > bestNaturalPower + 1e-9) then
						bestNatural, bestNaturalPower, bestNaturalDeficit = candidate, power, d
					end
				end
			end
			-- (a bench craft that adds nothing doesn't end the item: the best
			-- natural mod fills the affix instead; one that costs a hair - a
			-- requirement, a rounding - still does: six mods, as players make them)
			local tol = math.abs(currentPower) * 0.0005
			if best and best.crafted and bestPower <= currentPower and bestNatural and bestNaturalPower >= currentPower - tol then
				best, bestPower, bestDeficit = bestNatural, bestNaturalPower, bestNaturalDeficit
			end
			if best and bestPower < currentPower - 1e-9 and bestPower >= currentPower - tol and not best.crafted and bestDeficit <= currentDeficit then
				currentPower = bestPower
			end
			-- Stop when nothing is left to add, or the best makes it worse: a
			-- mod that adds nothing still fills its affix (an exalted orb on a
			-- rare is cheap at any budget - six mods, as players make them)
			if os.getenv("DEBUG_FILL") then
				ConPrintf("[fill] %s: %d/%d mods, best %s %+.5f (deficit %s -> %s), %d candidates",
					tostring(slotName), counts.Prefix + counts.Suffix, total, best and best.label or "none", best and (bestPower - currentPower) or 0, tostring(currentDeficit), tostring(bestDeficit), #order)
			end
			if not best or (bestPower < currentPower - 1e-9 and bestDeficit >= currentDeficit)
				or (bestPower <= currentPower and bestDeficit >= currentDeficit and best.crafted) then
				break
			end
			if best.crafted and counts.crafted >= 1 and not metaTaken then
				-- the multi-craft meta mod first (a crafted suffix of its own)
				local meta = { modId = "craftMeta", crafted = true, meta = true, type = "Suffix", group = "ItemGenerationCanHaveMultipleCraftedMods",
					lines = { "Can have up to 3 Crafted Modifiers" }, mod = { modTags = { } }, label = "Can have up to 3 Crafted Modifiers (crafted)" }
				push(meta)
				t_insert(chosen, meta)
				counts.Suffix = counts.Suffix + 1
				metaTaken = true
			end
			push(best)
			t_insert(chosen, best)
			usedGroups[best.group] = true
			counts[best.type] = counts[best.type] + 1
			if best.crafted then counts.crafted = counts.crafted + 1 end
			if isInfluence(best) then counts.influence = counts.influence + 1 end
			if isGemLevel(best) then counts.gemLevel = counts.gemLevel + 1 end
			if isAllGemLevel(best) then counts.allGemLevel = (counts.allGemLevel or 0) + 1 end
			useStats(best)
			currentPower, currentDeficit = bestPower, bestDeficit
		end
		-- take the mods off again: the caller builds the real item
		for i = #chosen, 1, -1 do pop(chosen[i]) end
		return chosen, currentPower, currentDeficit
	end
	local chosen, chosenPower, chosenDeficit = fill(nil)
	if slotName:match("^Weapon") and (opts.weaponSeeds or 3) > 0 then
		-- one seed per kind of damage scaling the greedy fill didn't open with
		local inChosen = { }
		for _, c in ipairs(chosen) do inChosen[c] = true end
		local seeds, seen = { }, { }
		for _, tag in ipairs({ "physical", "elemental", "chaos", "speed", "critical" }) do
			for _, candidate in ipairs(scores) do
				local tags = candidate.mod.modTags or { }
				local has = false
				for _, t in ipairs(tags) do if t == tag then has = true end end
				if has and inList[candidate] then
					if not inChosen[candidate] and not seen[candidate] then
						seen[candidate] = true
						t_insert(seeds, candidate)
					end
					break
				end
			end
		end
		for i = 1, m_min(#seeds, opts.weaponSeeds or 3) do
			local list, power, d = fill(seeds[i])
			if power > chosenPower and d <= chosenDeficit then
				chosen, chosenPower, chosenDeficit = list, power, d
			end
		end
	end
	-- 4. Build the real item from the chosen affixes and measure it
	local item = self:MakeBlankRare(current, influences)
	local p, s = 1, 1
	for _, candidate in ipairs(chosen) do
		local entry = { modId = candidate.modId, range = quality.range }
		if candidate.crafted then
			-- (kept by Craft, which only rebuilds the natural affixes)
			for _, line in ipairs(candidate.lines) do
				local modLine = { line = line, crafted = true, modTags = candidate.mod.modTags or { } }
				modLine[candidate.type == "Prefix" and "prefix" or "suffix"] = true
				t_insert(item.explicitModLines, modLine)
			end
		elseif candidate.type == "Prefix" then
			item.prefixes[p] = entry
			p = p + 1
		else
			item.suffixes[s] = entry
			s = s + 1
		end
	end
	item.title = "Best Rare (" .. slotName .. ")"
	item:Craft()
	-- (prefixes, then suffixes, then the crafted lines: build sites group the
	-- lines of an item by affix kind, and PoB's stat order mixed them)
	local ordered = { }
	for _, pass in ipairs({ "prefix", "suffix", "crafted" }) do
		for _, l in ipairs(item.explicitModLines) do
			local kind = l.crafted and "crafted" or (l.prefix and "prefix") or (l.suffix and "suffix") or "suffix"
			if kind == pass then t_insert(ordered, l) end
		end
	end
	if #ordered == #item.explicitModLines then
		for i, l in ipairs(ordered) do item.explicitModLines[i] = l end
	end
	-- an item can't be both influenced and have eldritch implicits
	local eldritch = not (influences and influences[1]) and self:AddEldritch(item, slotName, ctx, opts.eldritchTier, quality.range, opts.eldritchPresence) or nil
	item.name = item.title .. ", " .. item.baseName
	local output = calcFunc({ repSlotName = slotName, repItem = item }, useFullDPS)
	ctx.tick()
	local power = ctx.measure(output)
	local delta = power - ctx.basePower
	if delta <= 0 or not self.finder.PassesConstraints(output, ctx.baseOutput, opts) then
		return nil, scores
	end
	return {
		slotName = slotName,
		item = item,
		power = power,
		delta = delta,
		deltaPct = ctx.basePower ~= 0 and delta / math.abs(ctx.basePower) * 100 or nil,
		chosen = chosen,
		modScores = scores,
		generated = true,
		influences = influences,
		eldritch = eldritch,
	}, scores
end

-- Eldritch implicits (Searing Exarch and Eater of Worlds) for armour pieces.
-- An item has at most one Exarch and one Eater implicit. Each comes as a base
-- line or as a stronger "while a Unique / Pinnacle enemy is in your presence"
-- variant (separate mods; PoB applies the presence ones against bosses).
-- They replace the base's implicits and can't be on influenced items.
local eldritchSlots = { ["Helmet"] = true, ["Body Armour"] = true, ["Gloves"] = true, ["Boots"] = true }
local eldritchMods
local function getEldritchMods()
	if eldritchMods then return eldritchMods end
	eldritchMods = { }
	for modId, mod in pairs(data.itemMods.Eldritch or { }) do
		local name, presence, tier = modId:match("^(.-)EldritchImplicit(%a*)(%d+)$")
		tier = tonumber(tier)
		if name and tier and (mod.type == "Exarch" or mod.type == "Eater") then
			t_insert(eldritchMods, { modId = modId, mod = mod, name = name, presence = presence, tier = tier, type = mod.type })
		end
	end
	table.sort(eldritchMods, function(a, b) return a.modId < b.modId end)
	return eldritchMods
end

-- Adds the best Exarch and the best Eater implicit (tier up to maxTier) to a generated rare
-- presence: which conditional versions may be used - "none" (default: the
-- base lines only, a build mostly fights map monsters), "unique" (also "while
-- a Unique Enemy is in your Presence") or "pinnacle" (also the pinnacle boss
-- versions)
local presenceAllowed = {
	none = { [""] = true },
	unique = { [""] = true, UniquePresence = true },
	pinnacle = { [""] = true, UniquePresence = true, PinnaclePresence = true },
}
function RareItemGeneratorClass:AddEldritch(item, slotName, ctx, maxTier, range, presence)
	local allowed = presenceAllowed[presence or "none"] or presenceAllowed.none
	if not maxTier or maxTier <= 0 or not (item.base and eldritchSlots[item.base.type]) then
		return nil
	end
	local calcFunc, useFullDPS = ctx.calcFunc, ctx.useFullDPS
	local subject = new("Item"):Item(item:BuildRaw())
	wipeTable(subject.implicitModLines)
	subject:BuildModList()
	local chosen = { }
	local function linesFor(entry, kind)
		local lines = { }
		for _, line in ipairs(entry.mod) do
			local text = itemLib.applyRange(line, range or 0.5, 1, 1)
			local modList, extra = modLib.parseMod(text)
			t_insert(lines, { line = text, modList = modList or { }, extra = extra, modTags = entry.mod.modTags or { }, [kind] = true })
		end
		return lines
	end
	-- (Clearing + bossing: measured on the boss and while mapping, the
	-- mapping score counting at its weight - on-kill implicits stay useful)
	local blend = ctx.opts and ctx.opts.mappingBlend
	local function measure(lines)
		local saved = subject.implicitModLines
		subject.implicitModLines = { }
		for _, l in ipairs(chosen) do t_insert(subject.implicitModLines, l) end
		for _, l in ipairs(lines or { }) do t_insert(subject.implicitModLines, l) end
		subject:BuildModList()
		local output = calcFunc({ repSlotName = slotName, repItem = subject }, useFullDPS)
		local power = ctx.measure(output)
		if blend then
			blend.toggle(true)
			local mapping = ctx.measure(calcFunc({ repSlotName = slotName, repItem = subject }, useFullDPS))
			blend.toggle(false)
			power = power + blend.weight * mapping
		end
		ctx.tick()
		subject.implicitModLines = saved
		return power
	end
	-- Highest available tier of each mod (base and each presence variant
	-- separately), up to cap; with the mod's share of its kind's spawn weight
	-- on this base (an Ichor / Ember rolls one at random)
	local function candidates(kind, cap)
		local best = { }
		local total = 0
		for _, entry in ipairs(getEldritchMods()) do
			if entry.type == kind and entry.tier == 1 and entry.presence == "" then total = total + subject:GetModSpawnWeight(entry.mod) end
		end
		for _, entry in ipairs(getEldritchMods()) do
			if entry.type == kind and entry.tier <= cap and allowed[entry.presence] and subject:GetModSpawnWeight(entry.mod) > 0 then
				local key = entry.name .. entry.presence
				if not best[key] or entry.tier > best[key].tier then
					best[key] = entry
				end
			end
		end
		local list = { }
		for _, entry in pairs(best) do
			entry.share = total > 0 and subject:GetModSpawnWeight(entry.mod) / total or 0.05
			t_insert(list, entry)
		end
		table.sort(list, function(a, b) return a.modId < b.modId end)
		return list
	end
	-- Tiers (poewiki): Lesser, Greater, Grand, Exceptional come from Ichors and
	-- Embers, Exquisite and Perfect only from Orbs of Conflict. Up to the
	-- level's tier, Exceptional at most - Exquisite (level tier 5) only for an
	-- implicit the build really leans on (Strike skills hitting another
	-- target...), Perfect only at the no-limit level
	local normalCap = maxTier >= 6 and 6 or m_min(maxTier, 4)
	local function upgraded(entry)
		for _, e in ipairs(getEldritchMods()) do
			if e.name == entry.name and e.presence == entry.presence and e.type == entry.type and e.tier == 5 and subject:GetModSpawnWeight(e.mod) > 0 then return e end
		end
	end
	local labels = { }
	local bestOf = { }
	local function pick(kind, mustAdd)
		local flag = kind == "Exarch" and "exarch" or "eater"
		local base = measure(nil)
		local best, bestPower, bestLabel, bestEntry, bestValue
		for _, entry in ipairs(candidates(kind, normalCap)) do
			local lines = linesFor(entry, flag)
			local power = measure(lines)
			-- (a rare one costs more rolls: about 5% of the pool is the
			-- common share; one at 1.6% asks for three times the tries)
			local value = power - math.abs(base) * 0.002 * m_max(0, 0.053 / m_max(entry.share, 0.005) - 1)
			if not bestValue or value > bestValue then
				best, bestPower, bestLabel, bestEntry, bestValue = lines, power, lines[1] and lines[1].line, entry, value
			end
		end
		if os.getenv("DEBUG_ELDRITCH") then ConPrintf("[eldritch] %s %s: best %s %+.5f (base %.4f), %d candidates", tostring(slotName), kind, tostring(bestLabel), (bestValue or base) - base, base, #candidates(kind, normalCap)) end
		if not best then return nil end
		local threshold = mustAdd and -math.abs(base) * 0.0005 or math.abs(base) * 0.002
		if bestValue - base <= threshold then return nil end
		if maxTier == 5 then
			local top = upgraded(bestEntry)
			if top and top.tier > bestEntry.tier then
				local lines = linesFor(top, flag)
				local power = measure(lines)
				if power - bestPower > math.abs(base) * 0.015 then best, bestPower, bestLabel = lines, power, lines[1] and lines[1].line end
			end
		end
		for _, l in ipairs(best) do t_insert(chosen, l) end
		t_insert(labels, kind .. ": " .. bestLabel)
		return true
	end
	-- (both kinds, always, whenever not harmful: an Ichor and an Ember of the
	-- lower tiers are cheap and the armour piece has nothing in their place -
	-- a helmet left with no implicit at all is a half-made item)
	for _, kind in ipairs({ "Exarch", "Eater" }) do pick(kind, true) end
	if #chosen == 0 then
		return nil
	end
	-- (the base's own implicit is what they replace - Two-Toned Boots'
	-- resistances, a Bone Helmet's minion damage: kept when worth more)
	if item.implicitModLines and #item.implicitModLines > 0 then
		local own = { }
		for _, l in ipairs(item.implicitModLines) do
			local modList, extra = modLib.parseMod(l.line)
			t_insert(own, { line = l.line, modList = modList or { }, extra = extra, modTags = l.modTags or { } })
		end
		local saved = chosen
		chosen = { }
		local ownPower = measure(own)
		chosen = saved
		if ownPower >= measure(nil) then return nil end
	end
	item.implicitModLines = { }
	for _, l in ipairs(chosen) do
		t_insert(item.implicitModLines, { line = l.line, modTags = l.modTags, exarch = l.exarch, eater = l.eater })
	end
	item:BuildAndParseRaw()
	return labels
end

-- Influences a rare can have (Shaper, Elder and the four Conquerors)
RareItemGeneratorClass.influenceList = {
	{ key = "shaper", label = "Shaper" }, { key = "elder", label = "Elder" },
	{ key = "crusader", label = "Crusader" }, { key = "eyrie", label = "Redeemer" },
	{ key = "basilisk", label = "Hunter" }, { key = "adjudicator", label = "Warlord" },
}

-- Problems that make a rare impossible to craft: { "text" } (empty when legal)
--   more prefixes / suffixes than the base allows, more than one bench craft,
--   Eldritch implicits on an influenced item
function RareItemGeneratorClass.Validate(item)
	local problems = { }
	if not item or item.rarity ~= "RARE" then return problems end
	local prefixes, suffixes, crafts = 0, 0, 0
	for _, list in ipairs({ item.prefixes or { }, item.suffixes or { } }) do
		for _, affix in ipairs(list) do
			local mod = affix.modId and item.affixes and item.affixes[affix.modId]
			if mod then
				if mod.type == "Prefix" then prefixes = prefixes + 1 elseif mod.type == "Suffix" then suffixes = suffixes + 1 end
			end
		end
	end
	-- (crafted lines: one bench craft, several lines at most; counted by kind)
	local craftKinds = { }
	for _, l in ipairs(item.explicitModLines or { }) do
		if l.crafted then
			-- (a saved item's bench line carries no {prefix}/{suffix} tag: Item
			-- writes none on crafted items; its kind from the bench mod's data)
			local isPrefix = l.prefix or (not l.suffix and RareItemGeneratorClass.BenchType(l.line) == "Prefix")
			local key = (isPrefix and "P" or "S") .. table.concat(l.modTags or { }, ",")
			if not craftKinds[key] then
				craftKinds[key] = true
				crafts = crafts + 1
				if isPrefix then prefixes = prefixes + 1 else suffixes = suffixes + 1 end
			end
		end
	end
	local limitP = item.prefixes and item.prefixes.limit or 3
	local limitS = item.suffixes and item.suffixes.limit or 3
	if prefixes > limitP then t_insert(problems, string.format("%d prefixes (max %d)", prefixes, limitP)) end
	if suffixes > limitS then t_insert(problems, string.format("%d suffixes (max %d)", suffixes, limitS)) end
	local multi = false
	for _, l in ipairs(item.explicitModLines or { }) do
		if l.crafted and (l.line or ""):match("^Can have up to 3 Crafted Modifiers") then multi = true end
	end
	if crafts > (multi and 4 or 1) then t_insert(problems, string.format("%d bench crafts (max %s)", crafts, multi and "3 with the multi-mod craft" or "1 without the multi-mod craft")) end
	local allLevels = 0
	for _, l in ipairs(item.explicitModLines or { }) do
		if not l.crafted and (l.line or ""):match("to Level of all .*Gems") then allLevels = allLevels + 1 end
	end
	if allLevels > 2 then t_insert(problems, string.format("%d \"+1 to Level of all ... Gems\" mods (next to impossible to make or find)", allLevels)) end
	local influenced = false
	for _, key in ipairs({ "shaper", "elder", "adjudicator", "basilisk", "crusader", "eyrie" }) do if item[key] then influenced = true end end
	if influenced then
		for _, l in ipairs(item.implicitModLines or { }) do
			if l.exarch or l.eater then t_insert(problems, "Eldritch implicit on an influenced item") break end
		end
	end
	return problems
end

function RareItemGeneratorClass.InfluenceLabel(influences)
	local names = { }
	for _, key in ipairs(influences or { }) do
		for _, info in ipairs(RareItemGeneratorClass.influenceList) do
			if info.key == key then t_insert(names, info.label) end
		end
	end
	return table.concat(names, "/")
end

-- Best rare for a slot. With ctx.opts.influences = 1 each influence is tried,
-- with 2 the best two are also tried together (Awakener's Orb).
function RareItemGeneratorClass:GenerateForSlot(slotName, current, ctx)
	local opts = ctx.opts
	self.allowElevated = opts.elevated and true or false
	ctx.gainCache, ctx.plainChosen = { }, nil
	local best, bestScores = self:GenerateForSlotWith(slotName, current, ctx, nil)
	local maxInfluences = opts.influences or 0
	if maxInfluences <= 0 or not (current.base and current.base.influenceTags) then
		ctx.gainCache = nil
		return best, bestScores
	end
	ctx.plainChosen = best and best.chosen
	local singles = { }
	for _, info in ipairs(self.influenceList) do
		if current.base.influenceTags[info.key] then
			local result = self:GenerateForSlotWith(slotName, current, ctx, { info.key })
			if result then
				t_insert(singles, { key = info.key, result = result })
				if not best or result.power > best.power then
					best, bestScores = result, result.modScores
				end
			end
		end
	end
	if maxInfluences >= 2 and #singles >= 2 then
		t_sort(singles, function(a, b) return a.result.power > b.result.power end)
		local pairsToTry = { { singles[1].key, singles[2].key } }
		if singles[3] then t_insert(pairsToTry, { singles[1].key, singles[3].key }) end
		for _, pair in ipairs(pairsToTry) do
			local result = self:GenerateForSlotWith(slotName, current, ctx, pair)
			if result and (not best or result.power > best.power) then
				best, bestScores = result, result.modScores
			end
		end
	end
	ctx.gainCache, ctx.plainChosen = nil, nil
	return best, bestScores
end
