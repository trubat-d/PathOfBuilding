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
	local modTable = current.type == "Jewel" and data.itemMods.Jewel or nil
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
		local maxGemLevel = opts.maxGemLevelMods or 1
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
		while counts.Prefix + counts.Suffix < total do
			local natural = counts.Prefix + counts.Suffix - counts.crafted
			local best, bestPower, bestDeficit
			local order = { }
			for _, candidate in ipairs(shortlist) do
				local needMeta = candidate.crafted and counts.crafted >= 1 and not metaTaken
				local metaRoom = not needMeta or (counts.Suffix + (candidate.type == "Suffix" and 1 or 0) + 1 <= limits.Suffix
					and counts.Prefix + counts.Suffix + 2 <= total)
				if not usedGroups[candidate.group] and counts[candidate.type] < limits[candidate.type] and not (candidate.crafted and counts.crafted >= maxCrafts)
					and metaRoom and not (opts.maxAffixes and not candidate.crafted and natural >= opts.maxAffixes)
					and not (isInfluence(candidate) and counts.influence >= maxInfluence)
					and not (isGemLevel(candidate) and counts.gemLevel >= maxGemLevel) then
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
				end
			end
			-- Stop when nothing helps any more
			if not best or (bestPower <= currentPower and bestDeficit >= currentDeficit) then
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
	-- Highest available tier of each mod (base and each presence variant separately)
	local function candidates(kind)
		local best = { }
		for _, entry in ipairs(getEldritchMods()) do
			if entry.type == kind and entry.tier <= maxTier and allowed[entry.presence] and subject:GetModSpawnWeight(entry.mod) > 0 then
				local key = entry.name .. entry.presence
				if not best[key] or entry.tier > best[key].tier then
					best[key] = entry
				end
			end
		end
		local list = { }
		for _, entry in pairs(best) do t_insert(list, entry) end
		table.sort(list, function(a, b) return a.modId < b.modId end)
		return list
	end
	local labels = { }
	for _, kind in ipairs({ "Exarch", "Eater" }) do
		local flag = kind == "Exarch" and "exarch" or "eater"
		local best, bestPower, bestLabel = nil, measure(nil), nil
		for _, entry in ipairs(candidates(kind)) do
			local lines = linesFor(entry, flag)
			local power = measure(lines)
			if power > bestPower + math.abs(bestPower) * 0.002 then
				best, bestPower, bestLabel = lines, power, lines[1] and lines[1].line
			end
		end
		if best then
			for _, l in ipairs(best) do t_insert(chosen, l) end
			t_insert(labels, kind .. ": " .. bestLabel)
		end
	end
	if #chosen == 0 then
		return nil
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
			local key = (l.prefix and "P" or "S") .. table.concat(l.modTags or { }, ",")
			if not craftKinds[key] then
				craftKinds[key] = true
				crafts = crafts + 1
				if l.prefix then prefixes = prefixes + 1 else suffixes = suffixes + 1 end
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
