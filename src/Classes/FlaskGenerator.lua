-- Path of Building
--
-- Class: Flask Generator
-- Picks the best magic utility flasks for the build: the flask types to use,
-- and the best prefix and suffix for each. Scored with BuildScorer, so flask
-- uptime counts: "increased effect, reduced duration" is a real cost on most
-- builds, and free when the flasks are permanent (Mageblood).
-- Life, mana and hybrid flasks the build already has are kept.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_min = math.min

---@class FlaskGenerator
local FlaskGeneratorClass = newClass("FlaskGenerator")

FlaskGeneratorClass.flaskSlots = { "Flask 1", "Flask 2", "Flask 3", "Flask 4", "Flask 5" }

---@param rareGenerator RareItemGenerator
---@param scorer BuildScorer
function FlaskGeneratorClass:FlaskGenerator(rareGenerator, scorer)
	self.rareGenerator = rareGenerator
	self.build = rareGenerator.build
	self.scorer = scorer
	return self
end

local function isUtilityBase(base)
	return base.type == "Flask" and base.flask and not (base.flask.life or base.flask.mana)
end

local function isRecoveryFlask(item)
	return item and item.base and item.base.flask and (item.base.flask.life or item.base.flask.mana)
end

-- A magic flask of the given base with the given prefix / suffix candidates
function FlaskGeneratorClass:MakeFlask(baseName, prefix, suffix, range)
	local tincture = data.itemBases[baseName] and data.itemBases[baseName].type == "Tincture"
	local lines = { "Rarity: MAGIC", baseName, "Crafted: true", tincture and "Quality: 0" or "Quality: 20" }
	if prefix then
		t_insert(lines, "Prefix: {range:" .. range .. "}" .. prefix.modId)
	end
	if suffix then
		t_insert(lines, "Suffix: {range:" .. range .. "}" .. suffix.modId)
	end
	-- a tincture's effect is its implicit
	local base = data.itemBases[baseName]
	if base and base.implicit then
		local implicits = { }
		for line in base.implicit:gmatch("[^\n]+") do t_insert(implicits, "{range:" .. (range or 1) .. "}" .. line) end
		t_insert(lines, "Implicits: " .. #implicits)
		for _, line in ipairs(implicits) do t_insert(lines, line) end
	end
	local item = new("Item"):Item(table.concat(lines, "\n"))
	item:NormaliseQuality()
	if prefix or suffix then
		item:Craft()
	end
	item:BuildModList()
	return item
end

-- Utility flask bases the character can use, plus the best mana flask for
-- builds that pay their skills with mana (the scorer counts what it restores)
-- Expedition flasks (the Iron Flask's ward) cost far more than the other
-- bases, early above all: only for a build made around ward (a ward pool of
-- its own, from its gear or passives), not for the bit of EHP 200 ward adds
local function isExpedition(base)
	return base and base.tags and base.tags.expedition_flask
end
function FlaskGeneratorClass:WardBuild()
	local output = self.build.calcsTab.mainOutput or { }
	local ward = output.Ward or 0
	-- (ward the flasks give doesn't make a ward build)
	for _, slotName in ipairs(self.flaskSlots or { }) do
		local slot = self.build.itemsTab.slots[slotName]
		local item = slot and self.build.itemsTab.items[slot.selItemId]
		if item and isExpedition(item.base) then ward = ward - 400 end
	end
	return ward >= 500
end
FlaskGeneratorClass.isExpedition = isExpedition

function FlaskGeneratorClass:GetBases(levelOnly)
	local list = { }
	local level = self.build.characterLevel
	local output = self.build.calcsTab.mainOutput or { }
	local bestMana, bestManaLevel
	local wardBuild = self:WardBuild()
	for name, base in pairs(data.itemBases) do
		local usable = not base.hidden and not (levelOnly and base.req and (base.req.level or 0) > level)
			and (wardBuild or not isExpedition(base))
		if usable and isUtilityBase(base) then
			t_insert(list, name)
		elseif usable and base.type == "Flask" and base.flask and base.flask.mana and not base.flask.life then
			local req = base.req and base.req.level or 0
			if not bestManaLevel or req > bestManaLevel then bestMana, bestManaLevel = name, req end
		end
	end
	if bestMana and (output.ManaPerSecondCost or 0) > 0 then
		t_insert(list, bestMana)
	end
	-- tinctures: only for melee weapon attacks (their mods apply to melee weapons)
	local env = self.build.calcsTab.mainEnv
	local skill = env and env.player and env.player.mainSkill
	local flags = skill and skill.skillFlags or { }
	if flags.melee and flags.attack and not flags.unarmed then
		for name, base in pairs(data.itemBases) do
			if base.type == "Tincture" and not base.hidden and not (levelOnly and base.req and (base.req.level or 0) > level) then
				t_insert(list, name)
			end
		end
	end
	t_sort(list)
	return list
end

-- Fills the flask slots. ctx: { calcFunc, override (base override), opts, tick }
-- Returns { slots = { [slotName] = item }, activeSlots = { [slotName] = true }, score }
function FlaskGeneratorClass:Generate(ctx)
	local opts = ctx.opts or { }
	local quality = opts.quality or self.rareGenerator.qualityList[self.rareGenerator.defaultQuality]
	local itemsTab = self.build.itemsTab
	local calcFunc = ctx.calcFunc
	local baseOverride = ctx.override or { }

	local wardBuild = self:WardBuild()
	-- Slots to fill: everything except life / mana / hybrid flasks
	local fillSlots = { }
	local existing = { }
	local repItems = { }
	for k, v in pairs(baseOverride.repItems or { }) do repItems[k] = v end
	if baseOverride.repSlotName then repItems[baseOverride.repSlotName] = baseOverride.repItem end
	for _, slotName in ipairs(self.flaskSlots) do
		local slot = itemsTab.slots[slotName]
		local current = repItems[slotName]
		if current == nil and slot then current = itemsTab.items[slot.selItemId] end
		if slot and not isRecoveryFlask(current) then
			t_insert(fillSlots, slotName)
			repItems[slotName] = false
			-- Flasks the build already uses stay available (e.g. unique flasks)
			if current and (wardBuild or not isExpedition(current.base)) then
				t_insert(existing, current)
			end
		end
	end
	local activeSlots = { }
	local function makeOverride()
		local o = { }
		for k, v in pairs(baseOverride) do o[k] = v end
		o.repSlotName, o.repItem = nil, nil
		o.repItems = repItems
		o.activeFlaskSlots = activeSlots
		return o
	end
	local function evaluate()
		local r = self.scorer:Evaluate(calcFunc, makeOverride())
		if ctx.tick then ctx.tick() end
		return r.score, r
	end
	local scorer = self.scorer
	-- Global flask stats (duration, charges) and Mageblood count, read once
	local _, env = scorer:GetFlaskUptimes(makeOverride())
	local modDB = env.player.modDB
	local permanentCount = modDB:Sum("BASE", nil, "LeftActiveMagicUtilityFlasks")
	local function isMagicUtility(item)
		return item and item.rarity == "MAGIC" and item.base and item.base.flask and not (item.base.flask.life or item.base.flask.mana)
	end
	-- Fast score of one flask in one slot: one calculation, with this flask's
	-- benefit counted for its uptime and the rest of the state held fixed
	local slotOff
	local function quickScore(slotName, item)
		repItems[slotName] = item
		local output = calcFunc(makeOverride())
		if ctx.tick then ctx.tick() end
		local uptime
		if permanentCount > 0 and isMagicUtility(item) then
			local index = 0
			for _, name in ipairs(self.flaskSlots) do
				local other = name == slotName and item or repItems[name]
				if other == nil and itemsTab.slots[name] then other = itemsTab.items[itemsTab.slots[name].selItemId] end
				if isMagicUtility(other) then index = index + 1 end
				if name == slotName then break end
			end
			uptime = index <= permanentCount and 1 or 0
		elseif item.type == "Tincture" then
			uptime = scorer:TinctureUptime(item, modDB, output)
		else
			uptime = scorer:FlaskUptime(item, modDB, output)
		end
		local dps = slotOff.dps + uptime * (scorer:GetDPS(output) - slotOff.rawDps)
		local ehp = slotOff.ehp + uptime * (scorer:GetEHP(output) - slotOff.rawEhp)
		local penalty = scorer:GetPenalties(output)
		return scorer:ScoreFromValues(dps, ehp, penalty, output)
	end

	local bases = self:GetBases(opts.levelOnly)
	local usedBases = { }
	local usedTincture = false -- one tincture at a time
	local currentScore = evaluate()
	local chosen = { }
	local chosenItems = { }
	for _, slotName in ipairs(fillSlots) do
		-- State without this slot, measured once with the full uptime model
		repItems[slotName] = false
		activeSlots[slotName] = nil
		slotOff = select(2, evaluate())
		activeSlots[slotName] = true
		-- 1. Rank the flask types without mods
		local ranked = { }
		for _, baseName in ipairs(bases) do
			local isTincture = data.itemBases[baseName].type == "Tincture"
			if not usedBases[baseName] and not (isTincture and usedTincture) then
				local score = quickScore(slotName, self:MakeFlask(baseName, nil, nil, quality.range))
				t_insert(ranked, { baseName = baseName, score = score })
			end
		end
		t_sort(ranked, function(a, b) return a.score > b.score end)
		-- 2. Best prefix and suffix on the top types
		local best
		for i = 1, m_min(opts.flaskBaseCount or 2, #ranked) do
			local baseName = ranked[i].baseName
			local blank = self:MakeFlask(baseName, nil, nil, quality.range)
			local candidates = self.rareGenerator:GetCandidates(blank, quality, opts.levelOnly, blank.type == "Tincture" and data.itemMods.Tincture or data.itemMods.Flask)
			local pick = { Prefix = nil, Suffix = nil }
			local pickScore = ranked[i].score
			for _, affixType in ipairs({ "Prefix", "Suffix" }) do
				for _, candidate in ipairs(candidates) do
					if candidate.type == affixType then
						local prefix = affixType == "Prefix" and candidate or pick.Prefix
						local suffix = affixType == "Suffix" and candidate or pick.Suffix
						local score = quickScore(slotName, self:MakeFlask(baseName, prefix, suffix, quality.range))
						if score > pickScore then
							pickScore = score
							pick[affixType] = candidate
						end
					end
				end
			end
			if not best or pickScore > best.score + 1e-9 then
				best = { baseName = baseName, prefix = pick.Prefix, suffix = pick.Suffix, score = pickScore }
			end
		end
		-- Compare with the flasks the build already had
		for _, item in ipairs(existing) do
			if not usedBases[item.baseName] and not chosenItems[item] and not (item.type == "Tincture" and usedTincture) then
				local score = quickScore(slotName, item)
				if not best or score > best.score + 1e-9 then
					best = { existing = item, baseName = item.baseName, score = score }
				end
			end
		end
		-- Keep the flask only if it helps (checked with the full model)
		local kept = false
		if best then
			local item = best.existing or self:MakeFlask(best.baseName, best.prefix, best.suffix, quality.range)
			repItems[slotName] = item
			local score = evaluate()
			-- every real build fills its flask slots: a flask that costs nothing
			-- stays even when its measured gain is small (e.g. few charges on a boss)
			if score > currentScore - 0.002 then
				chosenItems[item] = true
				if item.type == "Tincture" then usedTincture = true end
				usedBases[best.baseName] = true
				currentScore = math.max(currentScore, score)
				chosen[slotName] = item
				kept = true
			end
		end
		if kept then
		else
			repItems[slotName] = false
			activeSlots[slotName] = nil
		end
	end
	return { slots = chosen, activeSlots = activeSlots, score = currentScore, override = makeOverride() }
end
