-- Path of Building
--
-- Class: Build Generator
-- Generates a complete build for a chosen skill and ascendancy, on an empty
-- build: support gems, auras, passive tree and ascendancy, item bases, rare
-- items, utility flasks, then unique items / keystones from the synergy
-- finder. Every step is scored with BuildScorer (damage x tankiness, with
-- realistic flask uptime and penalties for uncapped resistances, missing
-- attributes and over-reserved mana).
-- Runs entirely locally using PoB's calculator.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort
local m_min = math.min
local m_max = math.max
local m_floor = math.floor

---@class BuildGenerator
local BuildGeneratorClass = newClass("BuildGenerator")

-- Armour base tag for each class's attributes
local classArmour = {
	Marauder = "str_armour", Ranger = "dex_armour", Witch = "int_armour",
	Duelist = "str_dex_armour", Templar = "str_int_armour", Shadow = "dex_int_armour", Scion = "str_dex_int_armour",
}
local armourTags = { "str_armour", "dex_armour", "int_armour", "str_dex_armour", "str_int_armour", "dex_int_armour" }
local armourSlots = { ["Helmet"] = "Helmet", ["Body Armour"] = "Body Armour", ["Gloves"] = "Gloves", ["Boots"] = "Boots" }
-- Weapon types tried for skills without weapon restrictions (spells, minions...)
local casterWeapons = { "Wand", "Sceptre", "Dagger", "Staff" }

-- Supports that trigger the skill on being hit, stunned, killed... only work
-- under an assumption about how often that happens, so they are skipped
-- unless allowed
local assumptionTriggers = { "when Stunned", "when Damage Taken", "on Death", "when Hit", "Cast while Channelling", "on Melee Kill", "Cast on Kill" }
function BuildGeneratorClass.IsAssumptionTrigger(gem)
	for _, text in ipairs(assumptionTriggers) do
		if gem.name:find(text, 1, true) then
			return true
		end
	end
	return false
end

-- Gems that are versions of each other (awakened, greater...) share a family
function BuildGeneratorClass.GemFamily(gem)
	if not gem then return nil end
	return gem.grantedEffect and gem.grantedEffect.plusVersionOf or gem.grantedEffectId
end

-- Part of a multi-part skill used for scoring (index), or nil for the first
local realisticParts = {
	"All Bolts in Range", "Combined Average Projectiles", "Maximum Sustainable", "Average waves hitting configured size enemy",
	"Average explosions hitting", "Average Balls Hitting", "Total Weighted", "Average DPS", "Blade Hits Per Sec", "Maximum Stages",
	"2 Overlapping Waves", "Both Waves", "Both slashes", "Half Bolts Hitting", "Average # traps (good placement)", "Max Pulse per Brand",
}
function BuildGeneratorClass.RealisticSkillPart(effect)
	if not effect or not effect.parts or #effect.parts < 2 then return nil end
	for _, wanted in ipairs(realisticParts) do
		for index, part in ipairs(effect.parts) do
			if part.name and part.name:find(wanted, 1, true) then return index end
		end
	end
	return nil
end

-- Lists the active skill gems that can be the main skill of a generated build
function BuildGeneratorClass.SkillList()
	local list = { }
	for gemId, gem in pairs(data.gems) do
		local effect = gem.grantedEffect
		if effect and not effect.support and gem.tags and gem.tags.grants_active_skill and not gem.vaalGem and not effect.unsupported
			-- (movement skills are utility, except channelled attacks like Cyclone)
			and not (gem.tags.aura or gem.tags.herald or gem.tags.guard or ((gem.tags.movement or gem.tags.travel or gem.tags.blink) and not gem.tags.channelling) or gem.tags.warcry and not gem.tags.attack) then
			t_insert(list, { label = gem.name, gemId = gemId })
		end
	end
	t_sort(list, function(a, b) return a.label < b.label end)
	return list
end

-- Lists class / ascendancy pairs for the current tree
function BuildGeneratorClass.AscendancyList(tree)
	local list = { }
	for classId = 0, 6 do
		local class = tree.classes[classId]
		if class then
			for ascendId, ascend in pairs(class.classes) do
				if ascendId > 0 then
					t_insert(list, { label = ascend.name .. " (" .. class.name .. ")", classId = classId, ascendClassId = ascendId, className = class.name, ascendName = ascend.name })
				end
			end
		end
	end
	t_sort(list, function(a, b) return a.label < b.label end)
	return list
end

function BuildGeneratorClass:BuildGenerator(build, options)
	self.build = build
	self.itemsTab = build.itemsTab
	self.options = options or { }
	self.log = { }
	return self
end

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

function BuildGeneratorClass:Tick()
	local opts = self.options
	if opts.yieldEvery and GetTime() - (self.lastYield or 0) > opts.yieldEvery then
		if opts.onProgress then
			opts.onProgress(self.stage or "", self.stageIndex or 0, self.stageCount or 1)
		end
		coroutine.yield()
		self.lastYield = GetTime()
	end
end

function BuildGeneratorClass:Note(text)
	t_insert(self.log, text)
	if self.options.debugTiming then
		ConPrintf("[generator] %s", text)
	end
end

-- Gem level: the gem's maximum, +1 (a corrupted 21/20 gem, a few divines)
-- for the main skill from High investment and for its supports from Endgame
function BuildGeneratorClass:GemLevel(gem, isMain)
	local level = gem.naturalMaxLevel or 20
	local investment = self.options.investment or { }
	if (isMain and investment.corruptedMain) or (not isMain and investment.corruptedSupports) then
		level = level + 1
	end
	return level
end

-- Recalculate the build now (normally done at the next frame)
function BuildGeneratorClass:Recalculate()
	wipeGlobalCache()
	self.build.outputRevision = self.build.outputRevision + 1
	self.build.buildFlag = false
	self.build.skillsTab:UpdateSocketGroups()
	self.build.calcsTab:BuildOutput()
	self.calcFunc = self.build.calcsTab:GetMiscCalculator()
end

function BuildGeneratorClass:Score(override)
	local r = self.scorer:Evaluate(self.calcFunc, override or { }, { flasks = "ratio", ratio = self.ratio })
	self:Tick()
	return r.score, r
end

-- Skills whose part is a number of stacks the build must keep up (Blade
-- Vortex blades): the part follows what the build sustains, so supports and
-- passives that keep more blades up (cast speed, duration, Unleash...) count
local stackParts = {
	{ pattern = "^Blade Vortex", counts = { 0, 5, 10 }, sustain = function(output)
		-- one blade per cast, each lasting the skill duration
		return (output.Speed or 0) * (output.Duration or 4)
	end },
}
function BuildGeneratorClass:AdjustSkillPart()
	local gem = self.mainGem
	local first = self.mainGroup and self.mainGroup.gemList[1]
	if not gem or not first then return false end
	for _, rule in ipairs(stackParts) do
		if gem.name:match(rule.pattern) then
			local output = self.build.calcsTab.mainOutput or { }
			local sustained = rule.sustain(output)
			local part = 1
			for i, count in ipairs(rule.counts) do
				if sustained >= count then part = i end
			end
			if first.skillPart ~= part then
				first.skillPart, first.skillPartCalcs = part, part
				self.build.skillsTab:ProcessSocketGroup(self.mainGroup)
				self.sustainedStacks = sustained
				return true
			end
			return false
		end
	end
	return false
end

-- Skills whose damage on one target adds several of their parts: PoB shows
-- one part at a time (Kinetic Blast: the projectile, or one explosion)
local combinedParts = {
	["Kinetic Blast"] = { { part = 1, weight = 1 }, { part = 2, weight = 2 }, note = "the projectile and 2 of its 3 explosions hitting a boss" },
}

-- Hit damage of the combined parts relative to the part shown, kept on the
-- scorer (it adds that much more of the shown part's hit DPS)
function BuildGeneratorClass:UpdateCombinedParts()
	local gem = self.mainGem
	local rule = gem and combinedParts[gem.name]
	if not rule or not self.scorer then return end
	local first = self.mainGroup and self.mainGroup.gemList[1]
	if not first then return end
	local current = first.skillPartCalcs or first.skillPart or 1
	local total, shown = 0, nil
	for _, entry in ipairs(rule) do
		first.skillPart, first.skillPartCalcs = entry.part, entry.part
		self.build.skillsTab:ProcessSocketGroup(self.mainGroup)
		local output = self.calcFunc({ })
		local hit = output.TotalDPS or 0
		total = total + entry.weight * hit
		if entry.part == current then shown = hit end
	end
	first.skillPart, first.skillPartCalcs = current, current
	self.build.skillsTab:ProcessSocketGroup(self.mainGroup)
	self.scorer.hitScale = shown and shown > 0 and total / shown or nil
	if not self.combinedNoted then
		self.combinedNoted = true
		self:Note(string.format("%s damage counts %s", gem.name, rule.note))
	end
end

function BuildGeneratorClass:FullScore()
	self:Recalculate()
	if self:AdjustSkillPart() then self:Recalculate() end
	self:UpdateCombinedParts()
	local r = self.scorer:Evaluate(self.calcFunc, { })
	self.ratio = self.scorer.lastFlaskRatio
	return r.score, r
end

function BuildGeneratorClass:PointBudget()
	local extra = self.build.calcsTab.mainOutput and self.build.calcsTab.mainOutput.ExtraPoints or 0
	return (self.build.characterLevel - 1) + 23 + extra, 8
end

-- A normal (white) item of a base
local function makeBase(baseName)
	local base = data.itemBases[baseName]
	local item = new("Item"):Item("Rarity: NORMAL\n" .. baseName)
	item:NormaliseQuality()
	item:BuildModList()
	return item
end

-- Puts an item in a slot (added to the build)
function BuildGeneratorClass:Equip(item, slotName)
	local newItem = new("Item"):Item(item.raw)
	newItem:NormaliseQuality()
	self.itemsTab:AddItem(newItem, true)
	self.itemsTab.slots[slotName]:SetSelItemId(newItem.id)
	return newItem
end

-- Best bases of a type at the character's level
function BuildGeneratorClass:BasesOfType(filter)
	local list = { }
	for name, base in pairs(data.itemBases) do
		local tags = base.tags or { }
		local special = tags.not_for_sale or tags.experimental_base or tags.talisman or tags.demigods
		if not base.hidden and not (special and not self.options.allowSpecialBases) and (base.req and base.req.level or 0) <= self.build.characterLevel and filter(base, name) then
			t_insert(list, name)
		end
	end
	t_sort(list, function(a, b)
		local la, lb = data.itemBases[a].req.level or 0, data.itemBases[b].req.level or 0
		if la ~= lb then return la > lb end
		return a < b
	end)
	return list
end

------------------------------------------------------------------------------
-- Steps
------------------------------------------------------------------------------

function BuildGeneratorClass:Setup()
	local opts = self.options
	local build = self.build
	build.characterLevel = opts.level or 92
	build.characterLevelAutoMode = false
	if build.controls and build.controls.characterLevel then
		build.controls.characterLevel:SetText(build.characterLevel)
	end
	build.configTab:BuildModList()
	build.spec:SelectClass(opts.classId)
	build.spec:SelectAscendClass(opts.ascendClassId)
	self.className = build.spec.curClassName
	self.ascendName = build.spec.curAscendClassName

	-- Main skill in a 6-link body armour
	local gem = data.gems[opts.gemId]
	self.mainGem = gem
	local group = { label = "Main skill (generated)", enabled = true, slot = "Body Armour", gemList = {
		{ level = self:GemLevel(gem, true), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = opts.gemId },
	} }
	-- skills with several parts: the part that matches sustained use on a boss
	-- (e.g. Ball Lightning "All Bolts in Range", Tornado Shot "Combined Average
	-- Projectiles"); PoB's first part is often a single hit
	local part = self.RealisticSkillPart(gem.grantedEffect)
	if part then
		group.gemList[1].skillPart = part
		group.gemList[1].skillPartCalcs = part
	end
	t_insert(build.skillsTab.socketGroupList, group)
	build.skillsTab:ProcessSocketGroup(group)
	build.mainSocketGroup = #build.skillsTab.socketGroupList
	self.mainGroup = group
	local investment = opts.investment or { }
	if investment.corruptedMain then
		self:Note(string.format("Gem levels: %s level %d/20 (a corrupted gem)%s", gem.name, self:GemLevel(gem, true),
			investment.corruptedSupports and ", supports one level above their maximum (corrupted)" or ""))
	end

	-- Placeholder bases so every slot has something to build rares on
	local armourTag = classArmour[self.className] or "str_armour"
	self:EquipArmourType(armourTag)
	self:EquipDefaultJewellery()
	self:EquipDefaultWeapons()
	local lifeFlask = self:BasesOfType(function(base) return base.flask and base.flask.life and not base.flask.mana end)[1]
	if lifeFlask then
		self:Equip(makeBase(lifeFlask), "Flask 1")
	end
	self.itemsTab:PopulateSlots()
end

function BuildGeneratorClass:EquipArmourType(tag)
	for slotName, baseType in pairs(armourSlots) do
		local list = self:BasesOfType(function(base) return base.type == baseType and base.tags and base.tags[tag] and base.armour end)
		if list[1] then
			self:Equip(makeBase(list[1]), slotName)
		end
	end
	self.armourTag = tag
end

function BuildGeneratorClass:EquipDefaultJewellery()
	local defaults = { ["Amulet"] = "Onyx Amulet", ["Ring 1"] = "Two-Stone Ring", ["Ring 2"] = "Two-Stone Ring", ["Belt"] = "Leather Belt" }
	for slotName, baseName in pairs(defaults) do
		if data.itemBases[baseName] then
			self:Equip(makeBase(baseName), slotName)
		end
	end
end

-- Weapon options for the main skill: { { weapon1 = baseName, weapon2 = baseName or nil } }
function BuildGeneratorClass:WeaponOptions()
	local effect = self.mainGem.grantedEffect
	local options = { }
	local types = { }
	if effect.weaponTypes then
		for weaponType in pairs(effect.weaponTypes) do
			if weaponType ~= "Fishing Rod" and not weaponType:match("^None") then
				t_insert(types, weaponType)
			end
		end
	else
		types = casterWeapons
	end
	t_sort(types)
	local shield = self:BasesOfType(function(base) return base.type == "Shield" and base.tags and base.tags[self.armourTag or "str_armour"] end)[1]
		or self:BasesOfType(function(base) return base.type == "Shield" end)[1]
	local quiver = self:BasesOfType(function(base) return base.type == "Quiver" end)[1]
	for _, weaponType in ipairs(types) do
		local list = self:BasesOfType(function(base)
			if base.type ~= weaponType or not base.weapon then return false end
			return true
		end)
		-- best base: physical damage per second for attacks, highest level for casters
		if effect.weaponTypes then
			t_sort(list, function(a, b)
				local wa, wb = data.itemBases[a].weapon, data.itemBases[b].weapon
				return (wa.PhysicalMin + wa.PhysicalMax) * wa.AttackRateBase > (wb.PhysicalMin + wb.PhysicalMax) * wb.AttackRateBase
			end)
		end
		local baseName = list[1]
		if baseName then
			local info = data.weaponTypeInfo[weaponType] or { }
			if weaponType == "Bow" then
				t_insert(options, { weapon1 = baseName, weapon2 = quiver })
			elseif info.oneHand then
				t_insert(options, { weapon1 = baseName, weapon2 = shield })
				if effect.weaponTypes and not effect.skillTypes[SkillType.RequiresShield] then
					t_insert(options, { weapon1 = baseName, weapon2 = baseName, dual = true })
				end
			else
				t_insert(options, { weapon1 = baseName })
			end
		end
	end
	return options
end

function BuildGeneratorClass:EquipWeapons(option)
	self:Equip(makeBase(option.weapon1), "Weapon 1")
	if option.weapon2 then
		self:Equip(makeBase(option.weapon2), "Weapon 2")
	else
		self.itemsTab.slots["Weapon 2"]:SetSelItemId(0)
	end
end

function BuildGeneratorClass:EquipDefaultWeapons()
	self.weaponOptions = self:WeaponOptions()
	if self.weaponOptions[1] then
		self:EquipWeapons(self.weaponOptions[1])
	end
end

-- Greedily fills the main skill's link with the best support gems
-- Scores a support that generates charges (Endurance Charge on Melee Stun,
-- Power Charge on Critical...) with those charges counted: the configuration
-- only switches them on once the build has a source, so one-at-a-time picking
-- would never see what the support is for
function BuildGeneratorClass:WithChargesOf(gem, fn)
	local input = self.build.configTab.input
	local changed = { }
	-- only when the build can meet the gem's condition (Endurance Charge on
	-- Melee Stun needs a melee skill, Power Charge On Critical needs crits)
	local mainTypes = self.mainGem and self.mainGem.grantedEffect.skillTypes or { }
	if gem.name:find("Melee", 1, true) and not mainTypes[SkillType.Melee] then return fn() end
	if gem.name:find("Critical", 1, true) then
		local output = self.build.calcsTab.mainOutput or { }
		local crit = output.CritChance or (output.MainHand and output.MainHand.CritChance) or 0
		if crit < 20 then return fn() end
	end
	for _, kind in ipairs({ "Power", "Frenzy", "Endurance" }) do
		local var = "use" .. kind .. "Charges"
		if gem.name:find(kind .. " Charge", 1, true) and not input[var] then
			input[var] = true
			t_insert(changed, var)
		end
	end
	if #changed == 0 then return fn() end
	self.build.configTab:BuildModList()
	wipeGlobalCache()
	local a, b = fn()
	for _, var in ipairs(changed) do input[var] = nil end
	self.build.configTab:BuildModList()
	wipeGlobalCache()
	return a, b
end

function BuildGeneratorClass:ChooseSupports(maxSupports)
	local group = self.mainGroup
	-- (fewer sockets when the main skill left the body armour)
	maxSupports = m_min(maxSupports, self.mainLinkLimit or maxSupports)
	-- charges switched on for a support chosen last time: off again until a
	-- support (or the configuration's own check) brings them back
	for var in pairs(self.supportChargeVars or { }) do self.build.configTab.input[var] = nil end
	self.supportChargeVars = { }
	self.build.configTab:BuildModList()
	local supports = { }
	for gemId, gem in pairs(data.gems) do
		local investment = self.options.investment or { }
		local tags = gem.tags or { }
		local affordable = (investment.awakenedGems ~= false or not tags.awakened) and (investment.exceptionalGems ~= false or not tags.exceptional)
		if gem.grantedEffect and gem.grantedEffect.support and not gem.grantedEffect.unsupported and affordable
			-- (supports whose drawback PoB doesn't calculate: Modules/GeneratorRules)
			and not GetGeneratorRules().excludedSupports[gem.name]
			and (self.options.allowTriggerSupports or not self.IsAssumptionTrigger(gem)) then
			t_insert(supports, gemId)
		end
	end
	t_sort(supports)
	-- mines / traps / totems only when the archetype is that playstyle
	local archetype = self.options.archetype
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	local playstyle = archetype and archetype.playstyle
	for i = #supports, 1, -1 do
		if not archetypes.PlaystyleAllows(data.gems[supports[i]], playstyle) then t_remove(supports, i) end
	end
	-- supports the archetype commits to (that can support the skill), linked first
	local forced = { }
	for _, name in ipairs(archetype and archetype.supports or { }) do
		for _, gemId in ipairs(supports) do
			local gem = data.gems[gemId]
			if gem.name == name and archetypes.CanSupport(gem, self.mainGem) then t_insert(forced, gemId) break end
		end
	end
	local function inGroup(gemId)
		local family = self.GemFamily(data.gems[gemId])
		for _, g in ipairs(group.gemList) do
			-- awakened / greater / normal versions of the same support don't stack
			if g.gemId == gemId or (g.gemId and self.GemFamily(data.gems[g.gemId]) == family) then return true end
		end
		return false
	end
	-- Drop current supports, then add the best one at a time
	for i = #group.gemList, 2, -1 do
		t_remove(group.gemList, i)
	end
	local function addGem(gemId)
		local gem = data.gems[gemId]
		t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
	end
	-- the playstyle's best support (one mine / trap / totem support is required)
	if playstyle then
		local best, bestScore
		for _, gemId in ipairs(supports) do
			local gem = data.gems[gemId]
			local kind = archetypes.SupportPlaystyle(gem)
			if (kind == playstyle) and archetypes.CanSupport(gem, self.mainGem) then
				addGem(gemId)
				self.build.skillsTab:ProcessSocketGroup(group)
				local score = self:Score()
				t_remove(group.gemList)
				if not bestScore or score > bestScore then best, bestScore = gemId, score end
			end
		end
		if best then t_insert(forced, 1, best) end
	end
	for _, gemId in ipairs(forced) do
		if #group.gemList - 1 < maxSupports and not inGroup(gemId) then addGem(gemId) end
	end
	local forcedCount = #group.gemList - 1
	self.build.skillsTab:ProcessSocketGroup(group)
	local current = self:Score()
	for _ = 1, maxSupports - forcedCount do
		local best, bestScore
		for _, gemId in ipairs(supports) do
			if not inGroup(gemId) then
				local gem = data.gems[gemId]
				t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
				self.build.skillsTab:ProcessSocketGroup(group)
				local score = self:WithChargesOf(gem, function() return self:Score() end)
				t_remove(group.gemList)
				if not bestScore or score > bestScore then
					best, bestScore = gemId, score
				end
			end
		end
		if not best or bestScore <= current then
			break
		end
		local gem = data.gems[best]
		t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = best })
		current = bestScore
		-- a charge support: switch its charges on for the rest of the choice
		local mainTypes = self.mainGem and self.mainGem.grantedEffect.skillTypes or { }
		local usable = not (gem.name:find("Melee", 1, true) and not mainTypes[SkillType.Melee])
		for _, kind in ipairs(usable and { "Power", "Frenzy", "Endurance" } or { }) do
			local var = "use" .. kind .. "Charges"
			if gem.name:find(kind .. " Charge", 1, true) and not self.build.configTab.input[var] then
				self.build.configTab.input[var] = true
				self.supportChargeVars = self.supportChargeVars or { }
				self.supportChargeVars[var] = true
			end
		end
		self.build.configTab:BuildModList()
	end
	self.build.skillsTab:ProcessSocketGroup(group)
	-- The supports most players of this skill link (poe.ninja), tried as a set:
	-- some only work together (e.g. Lifetap gives Righteous Fire a duration,
	-- which Swift Affliction then shortens), so one-at-a-time picking misses them
	local meta = self.options.meta
	if meta and meta.supports and #meta.supports > 0 then
		local byName = { }
		for _, gemId in ipairs(supports) do byName[data.gems[gemId].name] = gemId end
		local metaSet = { }
		local inSet = { }
		for _, gemId in ipairs(forced) do
			if not inSet[gemId] and #metaSet < maxSupports then t_insert(metaSet, gemId) inSet[gemId] = true end
		end
		for _, e in ipairs(meta.supports) do
			local gemId = byName[e.name:gsub(" Support$", "")]
			if gemId and not inSet[gemId] and e.share >= 0.3 and #metaSet < maxSupports then t_insert(metaSet, gemId) inSet[gemId] = true end
		end
		if #metaSet - #forced >= 2 then
			local saved = { }
			for i = 2, #group.gemList do saved[i - 1] = group.gemList[i] end
			for i = #group.gemList, 2, -1 do t_remove(group.gemList, i) end
			for _, gemId in ipairs(metaSet) do
				local gem = data.gems[gemId]
				t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
			end
			self.build.skillsTab:ProcessSocketGroup(group)
			local metaScore = self:Score()
			if metaScore > current + 0.002 then
				current = metaScore
				self:Note(string.format("Supports: the set most %s players use (poe.ninja) beats picking one at a time", self.mainGem.name))
			else
				for i = #group.gemList, 2, -1 do t_remove(group.gemList, i) end
				for _, g in ipairs(saved) do t_insert(group.gemList, g) end
				self.build.skillsTab:ProcessSocketGroup(group)
			end
		end
	end
	self:TryTopPlayerSupports(supports, forced, maxSupports)
	local names = { }
	for i = 2, #group.gemList do t_insert(names, data.gems[group.gemList[i].gemId].name) end
	self:Note("Supports: " .. table.concat(names, ", "))
end

-- The exact main links the top players of the skill use (poe.ninja character
-- builds), tried as whole sets: kept if one beats the current link
function BuildGeneratorClass:TryTopPlayerSupports(supports, forced, maxSupports)
	local details = self.options.meta and self.options.meta.details
	if not details or not details.supportSets or #details.supportSets == 0 then return end
	local group = self.mainGroup
	local byName = { }
	for _, gemId in ipairs(supports) do byName[data.gems[gemId].name] = gemId end
	self.build.skillsTab:ProcessSocketGroup(group)
	local current = self:Score()
	local saved = { }
	for i = 2, #group.gemList do saved[i - 1] = group.gemList[i] end
	local best, bestScore, bestCount
	for i = 1, math.min(3, #details.supportSets) do
		local set = details.supportSets[i]
		local ids, ok = { }, true
		for _, name in ipairs(set.gems) do
			local id = byName[name]
			if id then t_insert(ids, id) end
		end
		for _, f in ipairs(forced or { }) do
			local found = false
			for _, id in ipairs(ids) do if id == f then found = true end end
			if not found then ok = false end
		end
		if ok and #ids >= 2 then
			for j = #group.gemList, 2, -1 do t_remove(group.gemList, j) end
			for j = 1, math.min(maxSupports, #ids) do
				local gem = data.gems[ids[j]]
				t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = ids[j] })
			end
			self.build.skillsTab:ProcessSocketGroup(group)
			local score = self:Score()
			if not bestScore or score > bestScore then best, bestScore, bestCount = ids, score, set.count end
		end
	end
	for j = #group.gemList, 2, -1 do t_remove(group.gemList, j) end
	if best and bestScore > current + 0.002 then
		for j = 1, math.min(maxSupports, #best) do
			local gem = data.gems[best[j]]
			t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = best[j] })
		end
		self:Note(string.format("Supports: the exact link %d of the top %d %s players use (poe.ninja) beats the others", bestCount, details.count, self.mainGem.name))
	else
		for _, g in ipairs(saved) do t_insert(group.gemList, g) end
	end
	self.build.skillsTab:ProcessSocketGroup(group)
end

-- Aura stacking as one move: more auras than the mana allows are chosen for
-- what they give (reservation ignored), then the passive tree is re-spent so
-- it can pick reservation efficiency (and the aura groups Arrogance), and the
-- auras still too expensive are dropped again. One aura at a time never gets
-- there: each one alone costs more in reservation than it gives until the
-- tree changes. Kept only if the build ends up better.
function BuildGeneratorClass:AuraStackMove()
	local spec = self.build.spec
	local skillsTab = self.build.skillsTab
	self:AutoConfigure()
	local before = self:FullScore()
	local treeUndo = spec:CreateUndoState()
	local savedGroups = { }
	for i, group in ipairs(skillsTab.socketGroupList) do
		local gems = { }
		for j, g in ipairs(group.gemList) do gems[j] = g end
		savedGroups[i] = { group = group, gems = gems }
	end
	local savedMain = self.build.mainSocketGroup
	local savedLog = { }
	for i, l in ipairs(self.log) do savedLog[i] = l end
	local function auraCount()
		local n = 0
		for _, group in ipairs(skillsTab.socketGroupList) do
			if (group.label or ""):match("^Auras") then
				for _, g in ipairs(group.gemList) do
					if g.gemId and not data.gems[g.gemId].grantedEffect.support then n = n + 1 end
				end
			end
		end
		return n
	end
	local beforeAuras = auraCount()
	self.scorer.ignoreReservation = true
	local ok, err = pcall(function()
		self:ChooseUtilityGems()
	end)
	self.scorer.ignoreReservation = false
	if ok and auraCount() > beforeAuras then
		self:AutoConfigure()
		self:RefineTree(16)
		self:RefineTree(10)
		-- auras the tree still can't pay for: drop the least useful one at a time
		for _ = 1, 4 do
			self:Recalculate()
			local o = self.build.calcsTab.mainOutput
			local over = (o.ManaUnreserved or 0) < 0 or (o.LifeUnreserved or 0) < 0 or ((o.ManaCost or 0) > 0 and (o.ManaUnreserved or 0) < (o.ManaCost or 0))
			if not over then break end
			local bestGroup, bestIndex, bestScore
			for _, group in ipairs(skillsTab.socketGroupList) do
				if (group.label or ""):match("^Auras") then
					for i = #group.gemList, 1, -1 do
						local g = group.gemList[i]
						if g.gemId and not data.gems[g.gemId].grantedEffect.support then
							t_remove(group.gemList, i)
							skillsTab:ProcessSocketGroup(group)
							local score = self:Score()
							t_insert(group.gemList, i, g)
							skillsTab:ProcessSocketGroup(group)
							if not bestScore or score > bestScore then bestGroup, bestIndex, bestScore = group, i, score end
						end
					end
				end
			end
			if not bestGroup then break end
			t_remove(bestGroup.gemList, bestIndex)
			skillsTab:ProcessSocketGroup(bestGroup)
		end
		-- the buffs note follows what is left
		for i = #self.log, 1, -1 do
			if self.log[i]:match("^Buffs:") then t_remove(self.log, i) end
		end
		local names = { }
		for _, group in ipairs(skillsTab.socketGroupList) do
			if (group.label or ""):match("^Auras") then
				local gems = { }
				for _, g in ipairs(group.gemList) do
					if g.gemId then t_insert(gems, data.gems[g.gemId].name) end
				end
				local hasAura = false
				for _, g in ipairs(group.gemList) do
					if g.gemId and not data.gems[g.gemId].grantedEffect.support then hasAura = true end
				end
				if hasAura then t_insert(names, table.concat(gems, " + ") .. " (" .. tostring(group.slot) .. ")") end
			end
		end
		if #names > 0 then self:Note("Buffs: " .. table.concat(names, "; ")) end
		self:AutoConfigure()
	end
	local after = ok and self:FullScore() or before
	if ok and after > before + 0.01 then
		self:Note(string.format("Aura stacking: %d auras with the tree re-spent for reservation, score %+.3f", auraCount(), after - before))
		return after - before
	end
	if not ok then ConPrintf("Aura stacking failed: %s", tostring(err)) end
	-- revert
	local list = skillsTab.socketGroupList
	for i = #list, 1, -1 do list[i] = nil end
	for i, entry in ipairs(savedGroups) do
		local group = entry.group
		for j = #group.gemList, 1, -1 do group.gemList[j] = nil end
		for j, g in ipairs(entry.gems) do group.gemList[j] = g end
		list[i] = group
		skillsTab:ProcessSocketGroup(group)
	end
	self.build.mainSocketGroup = savedMain
	spec:RestoreUndoState(treeUndo)
	spec:BuildAllDependsAndPaths()
	for i = #self.log, 1, -1 do self.log[i] = nil end
	for i, l in ipairs(savedLog) do self.log[i] = l end
	self:AutoConfigure()
	self:Recalculate()
	return 0
end

-- A full main link as one move: when the main skill has empty sockets (each
-- support alone costs more mana or life than the build can pay, so the greedy
-- choice stopped), the supports are chosen for their damage with costs
-- ignored, then the tree and the plain rares are redone so they can pay for
-- them (regeneration, leech, cost reduction). Kept only if the build is better.
function BuildGeneratorClass:FillMainLinkMove()
	local group = self.mainGroup
	if not group then return 0 end
	local supports = 0
	for _, g in ipairs(group.gemList) do
		local gd = g.gemId and data.gems[g.gemId]
		if gd and gd.grantedEffect.support then supports = supports + 1 end
	end
	if supports >= 5 then return 0 end
	local spec = self.build.spec
	self:AutoConfigure()
	local before = self:FullScore()
	local treeUndo = spec:CreateUndoState()
	local savedGems = { }
	for i, g in ipairs(group.gemList) do savedGems[i] = g end
	local savedItems = { }
	for _, slot in ipairs(self.itemsTab.orderedSlots) do savedItems[slot.slotName] = slot.selItemId end
	local savedLog = { }
	for i, l in ipairs(self.log) do savedLog[i] = l end
	self.scorer.ignoreCosts = true
	local ok, err = pcall(function() self:ChooseSupports(5) end)
	self.scorer.ignoreCosts = false
	if ok then
		self:AutoConfigure()
		self:RefineTree(16)
		self:RefineTree(10)
		self:FinalRares()
		self:AutoConfigure()
	end
	local after = ok and self:FullScore() or before
	local now = 0
	for _, g in ipairs(group.gemList) do
		local gd = g.gemId and data.gems[g.gemId]
		if gd and gd.grantedEffect.support then now = now + 1 end
	end
	if ok and now > supports and after > before + 0.01 then
		self:Note(string.format("Main link filled: %d supports instead of %d, tree and rares redone to pay for them, score %+.3f", now, supports, after - before))
		return after - before
	end
	if not ok then ConPrintf("Main link move failed: %s", tostring(err)) end
	for i = #group.gemList, 1, -1 do group.gemList[i] = nil end
	for i, g in ipairs(savedGems) do group.gemList[i] = g end
	self.build.skillsTab:ProcessSocketGroup(group)
	for slotName, id in pairs(savedItems) do
		if self.itemsTab.slots[slotName].selItemId ~= id then self.itemsTab.slots[slotName]:SetSelItemId(id) end
	end
	self.itemsTab:PopulateSlots()
	spec:RestoreUndoState(treeUndo)
	spec:BuildAllDependsAndPaths()
	for i = #self.log, 1, -1 do self.log[i] = nil end
	for i, l in ipairs(savedLog) do self.log[i] = l end
	self:AutoConfigure()
	self:Recalculate()
	return 0
end

-- Curse, aura, guard and movement setups linked like real builds, packed into gear sockets
function BuildGeneratorClass:ChooseUtilityGems(ignoreAttributes)
	-- drop the previous gem setup notes so the log shows the final one
	for i = #self.log, 1, -1 do
		local l = self.log[i]
		if l:match("^Curse setup") or l:match("^Buffs:") or l:match("^Guard setup") or l:match("^Movement setup") or l:match("^Blink setup") or l:match("^Blood Rage setup") or l:match("^Lifetap linked") or l:match("^Sockets used")
			or l:match("^Possible addition: Animate") or l:match("^Animate Guardian setup") or l:match("^Secondary bow skill setup")
			or l:match("^Empty sockets filled") then
			t_remove(self.log, i)
		end
	end
	local archetype = self.options.archetype
	local maxAuras = self.options.maxAuras or (archetype and archetype.maxAuras) or 4
	new("GemSetup"):GemSetup(self):Run(maxAuras + (self.scorer.ignoreReservation and 2 or 0), ignoreAttributes)
end

-- Passive tree: repeatedly allocate the path with the best score per point
function BuildGeneratorClass:AllocateTree(quiet, ascendancyOnly, warm)
	local spec = self.build.spec
	if not ascendancyOnly then self:AllocateArchetypeKeystones() end
	local budget, ascBudget = self:PointBudget()
	local maxDist = self.options.maxPathDistance or 8
	local current = self:Score()
	-- mastery effects already used elsewhere can't be picked again
	local function effectFree(effectId)
		for _, used in pairs(spec.masterySelections) do
			if used == effectId then return false end
		end
		return true
	end
	-- a temporary node carrying one mastery effect, as PoB's power report does
	local function effectNode(node, effect)
		local n = { id = node.id, type = node.type, name = node.name, dn = node.dn, sd = { } }
		for i, line in ipairs(effect.sd or { }) do n.sd[i] = line end
		spec.tree:ProcessStats(n)
		return n
	end
	local function candidates(ascendancy)
		local list = { }
		for _, node in pairs(spec.nodes) do
			if not node.alloc and node.path and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
				and node.type ~= "Socket" and not node.isProxy and not node.expansionJewel
				and not (self.forbiddenNodes and self.forbiddenNodes[node.id]) then
				if ascendancy then
					-- the ascendancy, and the bloodline if one is chosen (they share the points);
					-- multiple choice options (e.g. a bloodline's "Price" notables) are picked directly
					-- (bloodline nodes are named by the bloodline's internal id)
					local own = node.ascendancyName == spec.curAscendClassName
						or (spec.curSecondaryAscendClass and node.ascendancyName == spec.curSecondaryAscendClass.id)
					if own and not node.isMultipleChoice and node.type ~= "Mastery" then
						t_insert(list, { node = node })
					end
				elseif not node.ascendancyName then
					if node.type == "Mastery" then
						-- masteries: each available effect is its own 1 point candidate
						if #node.path == 1 and node.masteryEffects and self.options.masteries ~= false then
							for _, me in ipairs(node.masteryEffects) do
								local effect = spec.tree.masteryEffects[me.effect]
								if effect and effectFree(effect.id) then
									t_insert(list, { node = node, effect = effect })
								end
							end
						end
					elseif #node.path <= maxDist then
						t_insert(list, { node = node })
					end
				end
			end
		end
		return list
	end
	-- points a path costs (multiple choice options are free)
	local function pathCost(node)
		local cost = 0
		for _, n in ipairs(node.path) do
			if not n.isMultipleChoiceOption then cost = cost + 1 end
		end
		return m_max(1, cost)
	end
	local function ratio(entry)
		if entry.effect then
			if not effectFree(entry.effect.id) then return -math.huge end
			return self:Score({ addNodes = { [effectNode(entry.node, entry.effect)] = true } }) - current
		end
		local pathSet = { }
		for _, n in ipairs(entry.node.path) do pathSet[n] = true end
		local score = self:Score({ addNodes = pathSet })
		return (score - current) / pathCost(entry.node)
	end
	local function allocate(entry)
		local node = entry.node
		if entry.effect then
			-- same as choosing the effect in the Tree tab
			node.sd = entry.effect.sd
			node.allMasteryOptions = false
			spec.tree:ProcessStats(node)
			spec.masterySelections[node.id] = entry.effect.id
		end
		spec:AllocNode(node)
	end
	-- (values compared to 1e-9: the calculator's sums run in table order, which
	-- changes from run to run, so equal gains differ in the last bits; ties go
	-- to the lower node id, so the same build comes out every time)
	local function byValue(a, b)
		local va, vb = a.value, b.value
		local qa = va == -math.huge and va or m_floor(va * 1e9 + 0.5)
		local qb = vb == -math.huge and vb or m_floor(vb * 1e9 + 0.5)
		if qa ~= qb then return qa > qb end
		if a.node.id ~= b.node.id then return a.node.id < b.node.id end
		return (tonumber(a.effect and a.effect.id) or 0) < (tonumber(b.effect and b.effect.id) or 0)
	end
	local function run(ascendancy)
		local refreshEvery = 12
		local sinceRefresh = refreshEvery
		local queue = { }
		-- values from earlier refreshes: candidates far below the best ones keep
		-- their last value (only re-measured every third refresh, or when their
		-- path got shorter); the best few are re-checked before each pick anyway
		local prev = { }
		local refreshCount = 0
		-- (warm: a few points freed from a finished tree, as RefineTree does:
		-- the values from the last allocation are good estimates, so even the
		-- first refresh only re-measures the best candidates and new ones)
		if warm and not ascendancy and self.treePrev then
			prev = self.treePrev
			refreshCount = 1
		end
		while true do
			local used, ascUsed = spec:CountAllocNodes()
			local left = ascendancy and (ascBudget - ascUsed) or (budget - used)
			if left <= 0 then break end
			if sinceRefresh >= refreshEvery then
				queue = { }
				refreshCount = refreshCount + 1
				local full = refreshCount % 3 == 1 or self.options.fullTreeRefresh
				local threshold = -math.huge
				if not full then
					local values = { }
					for _, p in pairs(prev) do t_insert(values, p.value) end
					t_sort(values, function(a, b) return a > b end)
					local keep = m_max(60, m_floor(#values * 0.3))
					threshold = values[keep] or -math.huge
				end
				for _, entry in ipairs(candidates(ascendancy)) do
					if pathCost(entry.node) <= left then
						local key = entry.node.id .. (entry.effect and ("_" .. entry.effect.id) or "")
						local pathLen = pathCost(entry.node)
						local p = prev[key]
						-- (a shorter path: the same gain over fewer points at best)
						local estimate = p and (p.value > 0 and p.value * p.pathLen / pathLen or p.value)
						if full or not p or estimate >= threshold then
							entry.value = ratio(entry)
							self.treeStats = self.treeStats or { refresh = 0, skipped = 0, recheck = 0, picks = 0, refreshes = 0 }
							self.treeStats.refresh = self.treeStats.refresh + 1
						else
							self.treeStats.skipped = self.treeStats.skipped + 1
							entry.value = estimate
						end
						prev[key] = { value = entry.value, pathLen = pathLen }
						t_insert(queue, entry)
					end
				end
				sinceRefresh = 0
			end
			t_sort(queue, byValue)
			-- lazy greedy: re-check the best few against the current tree
			for i = 1, m_min(8, #queue) do
				local entry = queue[i]
				if entry.node.alloc or not entry.node.path or pathCost(entry.node) > left then
					entry.value = -math.huge
				else
					entry.value = ratio(entry)
					if self.treeStats then self.treeStats.recheck = self.treeStats.recheck + 1 end
				end
			end
			t_sort(queue, byValue)
			local picked = queue[1]
			if not picked or picked.value <= 0 or picked.value == -math.huge then
				if sinceRefresh > 0 then
					sinceRefresh = refreshEvery -- try a full refresh before stopping
					if warm then refreshCount = 0 end
				else
					break
				end
			else
				allocate(picked)
				if self.treeStats then self.treeStats.picks = self.treeStats.picks + 1 end
				t_remove(queue, 1)
				current = self:Score()
				sinceRefresh = sinceRefresh + 1
			end
		end
		if not ascendancy then self.treePrev = prev end
	end
	if not ascendancyOnly then
		self.stage = "Allocating passive tree"
		run(false)
	end
	self.stage = "Allocating ascendancy"
	self:SearchAscendancy()
	current = self:Score()
	run(true) -- spend any point left after the notables
	spec:AddUndoState()
	local used, ascUsed = spec:CountAllocNodes()
	local masteries = 0
	for _ in pairs(spec.masterySelections) do masteries = masteries + 1 end
	if not quiet then
		self:Note(string.format("Passive tree: %d points (%d masteries), ascendancy: %d points", used, masteries, ascUsed))
	end
end

-- Keystones the archetype commits to: allocated before anything else, and
-- never removed by trimming or tree adjustments
function BuildGeneratorClass:AllocateArchetypeKeystones()
	local archetype = self.options.archetype
	if not archetype then return end
	local spec = self.build.spec
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	self.protectedNodes = self.protectedNodes or { }
	local changed = false
	-- keystones that work against the archetype are never taken
	self.forbiddenNodes = self.forbiddenNodes or { }
	for _, name in ipairs(archetype.excludeKeystones or { }) do
		local node = archetypes.NodeByName(spec, name)
		if node then
			self.forbiddenNodes[node.id] = true
			if node.alloc then
				spec:DeallocNode(node)
				changed = true
			end
		end
	end
	for _, name in ipairs(archetype.keystones or { }) do
		local node = archetypes.NodeByName(spec, name)
		if node then
			self.protectedNodes[node.id] = true
			if not node.alloc and node.path then
				local used = spec:CountAllocNodes()
				local budget = self:PointBudget()
				if #node.path <= budget - used then
					spec:AllocNode(node)
					changed = true
				end
			end
		end
	end
	if changed then self:Recalculate() end
end

-- Ascendancy (and bloodline) notables chosen as a set: with only 8 points,
-- picking the best value per point one node at a time takes cheap small nodes
-- (attributes) and never reaches the notables. Every combination of the most
-- promising notables that fits the points is scored, the best one allocated.
function BuildGeneratorClass:SearchAscendancy()
	local spec = self.build.spec
	local _, ascBudget = self:PointBudget()
	local _, ascUsed = spec:CountAllocNodes()
	local left = ascBudget - ascUsed
	if left <= 0 then return end
	local function own(node)
		return node.ascendancyName == spec.curAscendClassName
			or (spec.curSecondaryAscendClass and node.ascendancyName == spec.curSecondaryAscendClass.id)
	end
	local current = self:Score()
	-- 1. notables (and multiple choice options) reachable with the points left
	local targets = { }
	for _, node in pairs(spec.nodes) do
		if own(node) and not node.alloc and node.path and not node.isMultipleChoice
			and (node.type == "Notable" or node.isMultipleChoiceOption) then
			local pathSet, cost = { }, 0
			for _, n in ipairs(node.path) do
				pathSet[n] = true
				if not n.isMultipleChoiceOption then cost = cost + 1 end
			end
			if cost <= left then
				local value = self:Score({ addNodes = pathSet }) - current
				t_insert(targets, { node = node, pathSet = pathSet, value = value, parent = node.isMultipleChoiceOption and node.linked[1] })
			end
		end
	end
	t_sort(targets, function(a, b) return a.value > b.value end)
	for i = #targets, (self.options.ascendancyTargets or 9) + 1, -1 do targets[i] = nil end
	if #targets == 0 then return end
	-- 2. every combination that fits (multiple choice siblings exclude each other)
	local best, bestScore = nil, current
	local chosen = { }
	local function cost(set)
		local n = 0
		for node in pairs(set) do
			if not node.isMultipleChoiceOption and not node.alloc then n = n + 1 end
		end
		return n
	end
	local function visit(start, set)
		for i = start, #targets do
			local t = targets[i]
			local clash = false
			for _, c in ipairs(chosen) do
				if t.parent and c.parent == t.parent then clash = true end
			end
			if not clash then
				local union = { }
				for n in pairs(set) do union[n] = true end
				for n in pairs(t.pathSet) do union[n] = true end
				if cost(union) <= left then
					t_insert(chosen, t)
					local score = self:Score({ addNodes = union })
					if score > bestScore then
						best, bestScore = { }, score
						for _, c in ipairs(chosen) do t_insert(best, c) end
					end
					visit(i + 1, union)
					chosen[#chosen] = nil
				end
			end
		end
	end
	visit(1, { })
	-- 3. allocate the winning set
	for _, t in ipairs(best or { }) do
		if not t.node.alloc and t.node.path then spec:AllocNode(t.node) end
	end
	self:Recalculate()
end

-- Removes the least useful end-of-path nodes until the tree fits the point budget
function BuildGeneratorClass:TrimTree()
	local spec = self.build.spec
	local budget, ascBudget = self:PointBudget()
	local removed = 0
	for _, ascendancy in ipairs({ false, true }) do
		while true do
			local used, ascUsed = spec:CountAllocNodes()
			local over = ascendancy and (ascUsed - ascBudget) or (used - budget)
			if over <= 0 then break end
			local current = self:Score()
			local best, bestLoss
			for _, node in pairs(spec.allocNodes) do
				local isAsc = node.ascendancyName ~= nil
				local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
				local protected = self.protectedNodes and self.protectedNodes[node.id]
				if isAsc == ascendancy and not holdsJewel and not protected and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.depends and #node.depends <= 1 then
					local loss = current - self:Score({ removeNodes = { [node] = true } })
					if not bestLoss or loss < bestLoss then best, bestLoss = node, loss end
				end
			end
			if not best then break end
			spec:DeallocNode(best)
			removed = removed + 1
		end
	end
	if removed > 0 then
		spec:AddUndoState()
		self:Note(string.format("Removed %d passive point%s to stay within the point budget", removed, removed == 1 and "" or "s"))
	end
end

function BuildGeneratorClass:ResetTree()
	local spec = self.build.spec
	spec:ResetNodes()
	spec:SelectClass(self.options.classId)
	spec:SelectAscendClass(self.options.ascendClassId)
	if spec.SelectSecondaryAscendClass and spec.tree.alternate_ascendancies then
		spec:SelectSecondaryAscendClass(self.bloodlineId or 0)
	end
end

-- The ascendancy (and bloodline) notables chosen again for the finished
-- build: they were picked before the gear, jewels and gems were final
function BuildGeneratorClass:AscendancyRecheck()
	local spec = self.build.spec
	self:Recalculate()
	local before = self:FullScore()
	local undo = spec:CreateUndoState()
	local function notables()
		local list = { }
		for _, node in pairs(spec.allocNodes) do
			if node.ascendancyName and (node.type == "Notable" or node.isMultipleChoiceOption) then t_insert(list, node.dn) end
		end
		t_sort(list)
		return table.concat(list, ", ")
	end
	local old = notables()
	self:ClearAscendancy()
	self:Recalculate()
	self:AllocateTree(true, true)
	local after = self:FullScore()
	if after > before + 0.005 and notables() ~= old then
		self:Note(string.format("Ascendancy chosen again for the finished build: %s (was %s), score %+.3f", notables(), old, after - before))
		return after - before
	end
	spec:RestoreUndoState(undo)
	spec:BuildAllDependsAndPaths()
	self:Recalculate()
	return 0
end

-- Removes every allocated ascendancy / bloodline passive (start nodes stay)
-- Main skill supports chosen again for the finished build (they were chosen
-- for the gear and tree of stage 6); kept if the build is better
function BuildGeneratorClass:FinalSupports()
	local group = self.mainGroup
	if not group then return 0 end
	self:Recalculate()
	local before = self:FullScore()
	local saved = { }
	for i, g in ipairs(group.gemList) do saved[i] = g end
	local savedLog = #self.log
	local function names()
		local list = { }
		for i = 2, #group.gemList do t_insert(list, data.gems[group.gemList[i].gemId].name) end
		return table.concat(list, ", ")
	end
	local old = names()
	self:ChooseSupports(5)
	for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
	self:AutoConfigure()
	self:Recalculate()
	local after = self:FullScore()
	if after > before + 0.005 and names() ~= old then
		self:Note(string.format("Supports chosen again for the finished build: %s (was %s), score %+.3f", names(), old, after - before))
		return after - before
	end
	for i = #group.gemList, 1, -1 do group.gemList[i] = nil end
	for i, g in ipairs(saved) do group.gemList[i] = g end
	self.build.skillsTab:ProcessSocketGroup(group)
	self:AutoConfigure()
	self:Recalculate()
	return 0
end

function BuildGeneratorClass:ClearAscendancy()
	local spec = self.build.spec
	local list = { }
	for _, node in pairs(spec.allocNodes) do
		if node.ascendancyName and node.type ~= "AscendClassStart" and not (spec.curSecondaryAscendClass and node.id == spec.curSecondaryAscendClass.startNodeId) then
			t_insert(list, node)
		end
	end
	for _, node in ipairs(list) do
		if node.alloc then
			node.alloc = false
			spec.allocNodes[node.id] = nil
		end
	end
	spec:BuildAllDependsAndPaths()
end

-- Bloodlines: secondary ascendancies that share the ascendancy points.
-- Each bloodline's notables are probed against the current build; the most
-- promising ones get a full ascendancy allocation, compared with no bloodline.
function BuildGeneratorClass:ChooseBloodline()
	local spec = self.build.spec
	local tree = spec.tree
	if self.options.bloodlines == false or not tree.alternate_ascendancies or not spec.SelectSecondaryAscendClass then return end
	self:Recalculate()
	local bestScore, bestId
	local original = spec:CreateUndoState()
	-- 1. quick estimate: value of each bloodline's two best notables on top of the build
	local estimates = { }
	local ids = { }
	for id in pairs(tree.alternate_ascendancies) do t_insert(ids, id) end
	t_sort(ids)
	for _, id in ipairs(ids) do
		local ascend = tree.alternate_ascendancies[id]
		spec:SelectSecondaryAscendClass(id)
		self:Recalculate()
		local current = self:Score()
		local values = { }
		for _, node in pairs(spec.nodes) do
			if node.ascendancyName == ascend.id and not node.alloc and node.path and (node.type == "Notable" or node.isMultipleChoiceOption) then
				local pathSet = { }
				for _, n in ipairs(node.path) do pathSet[n] = true end
				t_insert(values, self:Score({ addNodes = pathSet }) - current)
			end
		end
		t_sort(values, function(a, b) return a > b end)
		t_insert(estimates, { id = id, name = ascend.name, value = (values[1] or 0) + m_max(0, values[2] or 0) })
		spec:RestoreUndoState(original)
		spec:SelectSecondaryAscendClass(0) -- the undo state doesn't keep the bloodline
	end
	t_sort(estimates, function(a, b) return a.value > b.value end)
	-- 2. full ascendancy allocation for the best few, against a fresh allocation
	--    without a bloodline (so re-allocating alone doesn't count as a gain)
	local function allocateWith(id)
		self:ClearAscendancy()
		spec:SelectSecondaryAscendClass(id)
		self:Recalculate()
		self:AllocateTree(true, true)
		local notables = 0
		local ascend = tree.alternate_ascendancies[id]
		for _, node in pairs(spec.allocNodes) do
			if ascend and node.ascendancyName == ascend.id and (node.type == "Notable" or node.isMultipleChoiceOption) then notables = notables + 1 end
		end
		return self:FullScore(), notables
	end
	bestScore = allocateWith(0)
	bestId = 0
	for i = 1, m_min(self.options.bloodlinesTried or 3, #estimates) do
		local e = estimates[i]
		if e.value > 0 then
			local score, notables = allocateWith(e.id)
			if notables > 0 and score > bestScore + 0.002 then
				bestScore, bestId = score, e.id
			end
		end
	end
	-- keep the winner (PoB's tree undo state doesn't keep the bloodline)
	allocateWith(bestId)
	self.bloodlineId = bestId
	self:Recalculate()
	if bestId ~= 0 and tree.alternate_ascendancies[bestId] then
		local names = { }
		for _, node in pairs(spec.allocNodes) do
			if node.ascendancyName == tree.alternate_ascendancies[bestId].id and (node.type == "Notable" or node.isMultipleChoiceOption) then
				t_insert(names, node.dn)
			end
		end
		t_sort(names)
		self:Note(string.format("Bloodline: %s (%s)", tree.alternate_ascendancies[bestId].name, table.concat(names, ", ")))
	end
end

-- Picks armour type, jewellery bases and weapons by testing white bases
function BuildGeneratorClass:ChooseBases()
	-- armour type
	local bestTag, bestScore
	for _, tag in ipairs(armourTags) do
		self:EquipArmourType(tag)
		local score = self:FullScore()
		if not bestScore or score > bestScore then bestTag, bestScore = tag, score end
	end
	self:EquipArmourType(bestTag)
	self:Note("Armour type: " .. bestTag:gsub("_armour", ""):gsub("_", "/"))
	-- jewellery: try every base of the type
	for _, slot in ipairs({ { "Amulet", "Amulet" }, { "Ring 1", "Ring" }, { "Ring 2", "Ring" }, { "Belt", "Belt" } }) do
		local slotName, baseType = slot[1], slot[2]
		self:Recalculate()
		local best, bestS
		for _, baseName in ipairs(self:BasesOfType(function(base) return base.type == baseType end)) do
			local item = makeBase(baseName)
			local score = self:Score({ repSlotName = slotName, repItem = item })
			if not bestS or score > bestS then best, bestS = baseName, score end
		end
		if best then self:Equip(makeBase(best), slotName) end
	end
	-- weapons: white bases first, then the top two get rares
	self:Recalculate()
	local scored = { }
	for _, option in ipairs(self.weaponOptions or { }) do
		self:EquipWeapons(option)
		t_insert(scored, { option = option, score = (self:FullScore()) })
	end
	t_sort(scored, function(a, b) return a.score > b.score end)
	if scored[1] then
		self:EquipWeapons(scored[1].option)
		self.weaponFinalists = { scored[1].option, scored[2] and scored[2].option }
	end
	self.itemsTab:PopulateSlots()
	self:Recalculate()
end

-- Generated rares on every gear slot
-- Rare items for every slot, the slots shared out between background
-- threads when the app can run them (each worker loads the build and makes
-- the rares for its slots with the same scorer; the main thread waits).
-- The same report as BestItemFinder:RunRares; made in this thread when
-- background threads aren't available (headless runs, inside a worker).
function BuildGeneratorClass:RunRaresParallel(finder, options)
	local pgClass = new("ParallelGenerator"):ParallelGenerator()
	local slots = options.slots or finder:GetActiveSlots()
	local usable = { }
	for _, slotName in ipairs(slots) do
		local slot = self.itemsTab.slots[slotName]
		local current = slot and self.itemsTab.items[slot.selItemId]
		if current and finder.rareGenerator:IsSupported(current) then t_insert(usable, slotName) end
	end
	-- (each worker starts its own Path of Building and loads the build: worth
	-- it from three workers, i.e. six cores, or when asked for)
	local workers = m_min(#usable, pgClass.MaxWorkers())
	local minWorkers = self.options.parallelRares == true and 2 or 3
	if self.options.parallelRares == false or workers < minWorkers or not coroutine.running() or not pgClass.Available() then
		return finder:RunRares(options)
	end
	local dkjson = require "dkjson"
	local plain = { }
	for k, v in pairs(options) do
		if type(v) ~= "function" and k ~= "slots" then plain[k] = v end
	end
	local sc = self.scorer
	local scorerJob = {
		focusId = sc.focus and sc.focus.id, chargesPerSecond = sc.chargesPerSecond, ehpFloor = sc.ehpFloor, hitFloor = sc.hitFloor,
		bossTier = sc.bossTier, killsPerSecond = sc.killsPerSecond, flaskRealism = sc.flaskRealism,
		scenarioId = self.options.scenario and self.options.scenario.id,
		hitScale = sc.hitScale, resourceSustain = sc.resourceSustain, ignoreCosts = sc.ignoreCosts, ignoreAttributes = sc.ignoreAttributes,
		ignoreReservation = sc.ignoreReservation, useChecklist = sc.useChecklist,
	}
	local xml = self.build:SaveDB("code")
	-- weapons first (their seeded fills take longest), then round robin
	t_sort(usable, function(a, b)
		local wa, wb = a:match("^Weapon") and 0 or 1, b:match("^Weapon") and 0 or 1
		if wa ~= wb then return wa < wb end
		return a < b
	end)
	local jobs = { }
	for i = 1, workers do
		jobs[i] = { kind = "rares", build = xml, slots = { }, options = plain, ratio = self.ratio, scorer = scorerJob }
	end
	for i, slotName in ipairs(usable) do t_insert(jobs[(i - 1) % workers + 1].slots, slotName) end
	local results, failed, done = { }, nil, false
	local pg = pgClass
	pg:Run(jobs, {
		onDone = function(_, summary)
			for slotName, r in pairs(summary.slots or { }) do results[slotName] = r end
		end,
		onError = function(_, err) failed = failed or tostring(err) end,
		onAllDone = function() done = true end,
	})
	local savedStage = self.stage
	self.stage = (self.stage or "") .. string.format(" (%d threads)", workers)
	while not done do coroutine.yield() end
	self.stage = savedStage
	if failed then
		ConPrintf("Parallel rares failed (%s): made in this thread", failed)
		return finder:RunRares(options)
	end
	local report = { stat = finder.StatByName("FullDPS"), slots = { }, order = slots, options = options, rares = true }
	for _, slotName in ipairs(slots) do
		local r = results[slotName]
		local slotReport = { results = { } }
		if r and r.raw then
			local item = new("Item"):Item(r.raw)
			t_insert(slotReport.results, { slotName = slotName, item = item, power = r.power, delta = r.delta, generated = true })
		end
		report.slots[slotName] = slotReport
	end
	return report
end

function BuildGeneratorClass:MakeRares(withInfluences)
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local scorer, ratio = self.scorer, self.ratio
	local investment = self.options.investment
	local options = {
		quality = self.options.quality,
		levelOnly = true,
		keepResists = false, keepAttributes = false, keepLife = false, -- the score already weighs these
		scoreFunc = function(output) return scorer:ScoreOutput(output, ratio) end,
		influences = withInfluences and investment and investment.influences or 0,
		elevated = withInfluences and investment and investment.elevated or false,
		eldritchTier = withInfluences and investment and investment.eldritchTier or 0,
		weaponSeeds = self.options.weaponSeeds, crafts = self.options.crafts,
		yieldEvery = nil,
	}
	local function withSlots(slots)
		local copy = { }
		for k, v in pairs(options) do copy[k] = v end
		copy.slots = slots
		return copy
	end
	-- slots holding the archetype's uniques keep them
	local locked = self.lockedSlots or { }
	if next(locked) then
		local slots = { }
		for _, slotName in ipairs(finder:GetActiveSlots()) do
			if not locked[slotName] then t_insert(slots, slotName) end
		end
		options.slots = slots
	end
	-- weapons: compare the finalists with rares on them
	if self.weaponFinalists and self.weaponFinalists[2] and not locked["Weapon 1"] and not locked["Weapon 2"] then
		local best, bestScore
		for _, option in ipairs(self.weaponFinalists) do
			self:EquipWeapons(option)
			self:Recalculate()
			local report = finder:RunRares(withSlots({ "Weapon 1", "Weapon 2" }))
			finder:EquipAll(report)
			local score = self:FullScore()
			if not bestScore or score > bestScore then best, bestScore = option, score end
		end
		self:EquipWeapons(best)
		self:Recalculate()
	end
	-- two passes: the second one adapts to what the first one did elsewhere
	for pass = 1, (self.options.quick and 1 or 2) do
		self:Recalculate()
		local report = self:RunRaresParallel(finder, options)
		local count = finder:EquipAll(report)
		self:Tick()
		if count == 0 then break end
	end
	self:Recalculate()
	-- influenced crafting is expensive: below No limit, only the slots where an
	-- influence gains the most keep one; the others get a normal rare again
	local maxInfluenced = withInfluences and investment and investment.maxInfluenced
	if maxInfluenced then
		local influencedSlots = { }
		for _, slot in ipairs(self.itemsTab.orderedSlots) do
			local item = self.itemsTab.items[slot.selItemId]
			if item and item.rarity == "RARE" and not (self.lockedSlots and self.lockedSlots[slot.slotName]) then
				for _, info in ipairs(finder.rareGenerator.influenceList) do
					if item[info.key] then t_insert(influencedSlots, slot.slotName) break end
				end
			end
		end
		if #influencedSlots > maxInfluenced then
			-- value of each influenced item: the score lost without its influence mods
			-- (measured against a plain white base of the same type)
			local current = self:Score()
			local gains = { }
			for _, slotName in ipairs(influencedSlots) do
				local item = self.itemsTab.items[self.itemsTab.slots[slotName].selItemId]
				gains[slotName] = current - self:Score({ repSlotName = slotName, repItem = makeBase(item.baseName) })
			end
			t_sort(influencedSlots, function(a, b) return gains[a] > gains[b] end)
			local redo = { }
			for i = maxInfluenced + 1, #influencedSlots do t_insert(redo, influencedSlots[i]) end
			local plain = { }
			for k, v in pairs(options) do plain[k] = v end
			plain.influences, plain.elevated = 0, false
			plain.slots = redo
			-- (a white base first: the influenced rare would otherwise be kept as the better item)
			for _, slotName in ipairs(redo) do
				local item = self.itemsTab.items[self.itemsTab.slots[slotName].selItemId]
				self:Equip(makeBase(item.baseName), slotName)
			end
			self.itemsTab:PopulateSlots()
			for _ = 1, (self.options.quick and 1 or 2) do
				self:Recalculate()
				finder:EquipAll(finder:RunRares(plain))
			end
			self:Recalculate()
			self:Note(string.format("Influenced crafting kept on the %d slot%s where it gains the most (%s); influenced rares cost much more to craft or buy",
				maxInfluenced, maxInfluenced == 1 and "" or "s", table.concat({ unpack(influencedSlots, 1, maxInfluenced) }, ", ")))
		end
	end
	-- what influences the rares ended up with
	local influenced = { }
	for _, slot in ipairs(self.itemsTab.orderedSlots) do
		local item = self.itemsTab.items[slot.selItemId]
		if item and item.rarity == "RARE" then
			local names = { }
			for _, info in ipairs(finder.rareGenerator.influenceList) do
				if item[info.key] then t_insert(names, info.label) end
			end
			if #names > 0 then t_insert(influenced, slot.slotName .. " " .. table.concat(names, "/")) end
		end
	end
	self:Note("Rares generated for gear slots" .. (#influenced > 0 and (" (influenced: " .. table.concat(influenced, ", ") .. ")") or ""))
end

function BuildGeneratorClass:MakeFlasks()
	self:Recalculate()
	local gen = new("FlaskGenerator"):FlaskGenerator(new("BestItemFinder"):BestItemFinder(self.itemsTab).rareGenerator, self.scorer)
	local result = gen:Generate({ calcFunc = self.calcFunc, override = { }, opts = { quality = self.options.quality, levelOnly = true }, tick = function() self:Tick() end })
	local names = { }
	for slotName, item in pairs(result.slots) do
		self:Equip(item, slotName)
		self.itemsTab.slots[slotName].active = true
		if self.itemsTab.activeItemSet[slotName] then self.itemsTab.activeItemSet[slotName].active = true end
		t_insert(names, item.name)
	end
	self.itemsTab:PopulateSlots()
	self:Note("Flasks: " .. (#names > 0 and table.concat(names, ", ") or "none helped"))
end

-- Rares made again at the end, once the tree, jewels, flasks and gems are
-- final (they were made for the build as it was then): every rare slot,
-- influences and eldritch implicits included (the weapon bases and the
-- uniques stay); kept if the build is better
function BuildGeneratorClass:FinalRares()
	local saved, uniqueSlots = { }, { }
	local any = false
	for _, slot in ipairs(self.itemsTab.orderedSlots) do
		local item = self.itemsTab.items[slot.selItemId]
		if item and not slot.nodeId and not item.base.flask and item.type ~= "Jewel" then
			saved[slot.slotName] = slot.selItemId
			if item.rarity == "RARE" and not (self.lockedSlots and self.lockedSlots[slot.slotName]) then
				any = true
			else
				uniqueSlots[slot.slotName] = true
			end
		end
	end
	if not any then return 0 end
	self:Recalculate()
	local before = self:FullScore()
	local savedLocked, savedFinalists = self.lockedSlots, self.weaponFinalists
	local savedLog = #self.log
	local locked = { }
	for k, v in pairs(savedLocked or { }) do locked[k] = v end
	for k in pairs(uniqueSlots) do locked[k] = true end
	self.lockedSlots, self.weaponFinalists = locked, nil
	local ok, err = pcall(function() self:MakeRares(true) end)
	self.lockedSlots, self.weaponFinalists = savedLocked, savedFinalists
	for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
	self:Recalculate()
	local after = ok and self:FullScore() or before
	if ok and after > before + 0.005 then
		local count = 0
		for slotName, id in pairs(saved) do
			if self.itemsTab.slots[slotName].selItemId ~= id then count = count + 1 end
		end
		self:Note(string.format("Rares made again for the finished build: %d item%s improved, score %+.3f", count, count == 1 and "" or "s", after - before))
		return after - before
	end
	if not ok then ConPrintf("Final rares failed: %s", tostring(err)) end
	for slotName, id in pairs(saved) do self.itemsTab.slots[slotName]:SetSelItemId(id) end
	self.itemsTab:PopulateSlots()
	self:Recalculate()
	return 0
end

-- Rare jewels in passive tree sockets: one rare jewel is generated for the
-- build, then sockets are added one at a time; each one stays only if the
-- jewel is worth more than the passives trimmed to pay for the points.
function BuildGeneratorClass:AddJewels(maxJewels)
	local spec = self.build.spec
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local generator = finder.rareGenerator
	self:Recalculate()
	local sockets = { }
	for _, node in pairs(spec.nodes) do
		if node.type == "Socket" and not node.alloc and node.path and #node.path <= 5 and not node.expansionJewel and self.itemsTab.slots["Jewel " .. node.id] then
			t_insert(sockets, node)
		end
	end
	t_sort(sockets, function(a, b) return #a.path < #b.path end)
	if not sockets[1] then return end
	-- 1. the jewel: best rare on each jewel base, tested in the nearest socket
	local first = sockets[1]
	local pathSet = { }
	for _, n in ipairs(first.path) do pathSet[n] = true end
	local calcFunc = self.calcFunc
	local scorer, ratio = self.scorer, self.ratio
	local function socketCalc(override, useFullDPS)
		local o = { }
		for k, v in pairs(override) do o[k] = v end
		o.addNodes = pathSet
		return calcFunc(o, useFullDPS)
	end
	local measure = function(output) return scorer:ScoreOutput(output, ratio) end
	local baseOutput = socketCalc({ })
	local ctx = {
		calcFunc = socketCalc, useFullDPS = nil, stat = nil, baseOutput = baseOutput, basePower = measure(baseOutput),
		measure = measure, tick = function() self:Tick() end,
		opts = { quality = self.options.quality, levelOnly = true, keepResists = false, keepAttributes = false, keepLife = false },
	}
	local best
	for _, baseName in ipairs({ "Crimson Jewel", "Viridian Jewel", "Cobalt Jewel" }) do
		if data.itemBases[baseName] then
			local blank = new("Item"):Item("Rarity: NORMAL\n" .. baseName)
			blank:BuildModList()
			local result = generator:GenerateForSlotWith("Jewel " .. first.id, blank, ctx, nil)
			if result and (not best or result.power > best.power) then best = result end
		end
	end
	if not best then return end
	-- 2. sockets, kept only when they pay for their points
	local added = 0
	for _, node in ipairs(sockets) do
		if added >= (maxJewels or 4) then break end
		if not node.alloc and node.path then
			self:Recalculate()
			local before = self:FullScore()
			local treeState = spec:CreateUndoState()
			spec:AllocNode(node)
			local jewel = self:Equip(best.item, "Jewel " .. node.id)
			self.itemsTab:PopulateSlots()
			self:Recalculate()
			self:TrimTree()
			local after = self:FullScore()
			if after > before + 0.002 and node.alloc then
				added = added + 1
			else
				self.itemsTab.slots["Jewel " .. node.id]:SetSelItemId(0)
				self.itemsTab:DeleteItem(jewel, true)
				spec:RestoreUndoState(treeState)
				self.itemsTab:PopulateSlots()
				self:Recalculate()
			end
		end
	end
	if added > 0 then
		local mods = { }
		for _, l in ipairs(best.item.explicitModLines) do t_insert(mods, l.line) end
		self:Note(string.format("Rare jewels: %d socket%s (%s)", added, added == 1 and "" or "s", table.concat(mods, ", ")))
	end
end

-- Frees the least useful passives and lets the allocator spend them again
-- (after something changed what passives are worth, e.g. a timeless jewel)
function BuildGeneratorClass:RefineTree(count)
	local spec = self.build.spec
	self:Recalculate()
	local before = self:FullScore()
	local undo = spec:CreateUndoState()
	-- leaf passives measured once per batch, the cheapest few removed (each
	-- one checked to still be a leaf), then measured again: a quarter of the
	-- calculations of one measurement per removal
	local function removable(node)
		local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
		local protected = self.protectedNodes and self.protectedNodes[node.id]
		return node.alloc and not node.ascendancyName and not holdsJewel and not protected and node.type ~= "ClassStart" and node.type ~= "Mastery"
			and node.depends and #node.depends <= 1
	end
	local left = count or 8
	local batch = self.options.refineBatch or 4
	while left > 0 do
		local current = self:Score()
		local list = { }
		for _, node in pairs(spec.allocNodes) do
			if removable(node) then
				t_insert(list, { node = node, loss = current - self:Score({ removeNodes = { [node] = true } }) })
			end
		end
		if #list == 0 then break end
		t_sort(list, function(a, b)
			if a.loss ~= b.loss then return a.loss < b.loss end
			return a.node.id < b.node.id
		end)
		local removed = 0
		for _, entry in ipairs(list) do
			if removed >= m_min(batch, left) then break end
			if removable(entry.node) then
				spec:DeallocNode(entry.node)
				removed = removed + 1
			end
		end
		if removed == 0 then break end
		left = left - removed
	end
	self:Recalculate()
	self:AllocateTree(true, false, true)
	local after = self:FullScore()
	if after < before then
		spec:RestoreUndoState(undo)
		self:Recalculate()
		return 0
	end
	return after - before
end

-- Several rounds of tree adjustment: free the least useful passives (more each
-- round) and let the allocator spend them again; a round is kept only if the
-- build is better. Catches points spent early that later choices made useless.
function BuildGeneratorClass:OptimizeTree()
	local total = 0
	-- 1. re-choose and reconnect the targets with the fewest points
	if self.options.treeSearch ~= false then
		local ok, gain, swaps = pcall(function() return new("TreeOptimizer"):TreeOptimizer(self):Run() end)
		if ok and gain and gain > 0.001 then
			self:Note(string.format("Passive tree rebuilt with shorter paths%s: score %+.3f", (swaps or 0) > 0 and string.format(" and %d better target%s", swaps, swaps == 1 and "" or "s") or "", gain))
		elseif not ok then
			ConPrintf("Tree optimizer failed: %s", tostring(gain))
		end
	end
	-- 2. free the least useful passives and let the allocator spend them again
	for _, count in ipairs(self.options.treeRounds or { 6, 10, 16, 6 }) do
		total = total + self:RefineTree(count)
		self:Tick()
	end
	if total > 0.001 then
		self:Note(string.format("Passive tree adjusted in rounds: score %+.3f", total))
	end
end

-- Ailment pairs: passives like Cornered Prey ("against Bleeding Enemies") are
-- worth nothing until the build keeps the ailment up, and a small chance to
-- inflict it is worth nothing until such passives are taken, so the greedy tree
-- never finds the pair. For each ailment not up yet: take the cheapest passive
-- that adds a chance to inflict it, assume the ailment while re-spending some
-- points, then let the configuration check the real uptime. Kept only if the
-- build is better.
local ailmentPairs = {
	{ ailment = "Bleed", var = "conditionEnemyBleeding", target = "bleeding enem", source = { "chance to cause bleeding", "chance to inflict bleeding" } },
	{ ailment = "Poison", var = "conditionEnemyPoisoned", target = "poisoned enem", source = { "chance to poison" } },
	{ ailment = "Shock", var = "conditionEnemyShocked", target = "shocked enem", source = { "chance to shock" } },
	{ ailment = "Ignite", var = "conditionEnemyIgnited", target = "ignited enem", source = { "chance to ignite" } },
}
function BuildGeneratorClass:PairAilments()
	local spec = self.build.spec
	local input = self.build.configTab.input
	local function text(node)
		return table.concat(node.sd or { }, " "):lower()
	end
	for _, pair in ipairs(ailmentPairs) do
		if not input[pair.var] then
			self:Recalculate()
			local before = self:FullScore()
			-- 1. any passive worth taking if the ailment were up?
			input[pair.var] = true
			self:Recalculate()
			local current = self:Score()
			local bestRatio = 0
			for _, node in pairs(spec.nodes) do
				if not node.alloc and node.path and #node.path <= 8 and not node.ascendancyName and text(node):find(pair.target, 1, true) then
					local pathSet = { }
					for _, n in ipairs(node.path) do pathSet[n] = true end
					bestRatio = m_max(bestRatio, (self:Score({ addNodes = pathSet }) - current) / #node.path)
				end
			end
			-- 2. the cheapest passive that adds a chance to inflict it
			local source
			if bestRatio > 0.002 then
				for _, node in pairs(spec.nodes) do
					if not node.alloc and node.path and #node.path <= 5 and not node.ascendancyName and node.type ~= "Mastery" then
						local t = text(node)
						for _, pattern in ipairs(pair.source) do
							if t:find(pattern, 1, true) and (not source or #node.path < #source.path) then source = node end
						end
					end
				end
			end
			if not source then
				input[pair.var] = nil
				self:Recalculate()
			else
				local undo = spec:CreateUndoState()
				local savedInput = { }
				for k, v in pairs(input) do savedInput[k] = v end
				local savedLog = #self.log
				self.protectedNodes = self.protectedNodes or { }
				local wasProtected = self.protectedNodes[source.id]
				self.protectedNodes[source.id] = true
				spec:AllocNode(source)
				self:Recalculate()
				self:TrimTree()
				self:RefineTree(10)
				-- the real uptime decides
				self:AutoConfigure()
				local after = self:FullScore()
				if after > before + 0.003 and input[pair.var] then
					self:Note(string.format("%s pair: %s for a chance to inflict it, with passives that need it (score %+.3f)", pair.ailment, source.dn, after - before))
				else
					for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
					self.protectedNodes[source.id] = wasProtected
					spec:RestoreUndoState(undo)
					for k in pairs(input) do input[k] = nil end
					for k, v in pairs(savedInput) do input[k] = v end
					input[pair.var] = nil
					self.build.configTab:BuildModList()
					self:Recalculate()
				end
			end
			self:Tick()
		end
	end
end

-- Best timeless (Historic) jewel: type, seed, conqueror and socket
function BuildGeneratorClass:ChooseTimelessJewel()
	local investment = self.options.investment or { }
	if investment.timeless == false then return end
	local spec = self.build.spec
	self:Recalculate()
	local before = self:FullScore()
	local finder = new("TimelessJewelFinder"):TimelessJewelFinder({
		build = self.build,
		score = function(override) return (self:Score(override)) end,
		fullScore = function() return (self:FullScore()) end,
		quickScore = function() self:Recalculate() return (self:Score()) end,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	local result = finder:Run({ })
	if not result or result.gain <= 0.01 then return end
	local described = finder:Describe(result)
	-- a chosen seed and conqueror costs far more than the base price: below
	-- High investment the jewel is only noted as an upgrade
	if not investment.awakenedGems then
		self:Note(string.format("Possible upgrade (High investment): timeless jewel %s, about %+.0f%% score before re-spending passives", result.label, result.gain * 100))
		return
	end
	local undo = spec:CreateUndoState()
	local slot = self.itemsTab.slots["Jewel " .. result.socket.node.id]
	local previous = slot and slot.selItemId
	local jewel = finder:Apply(result)
	self:Recalculate()
	self:TrimTree()
	self:RefineTree(10)
	local after = self:FullScore()
	if after <= before + 0.005 then
		slot:SetSelItemId(previous or 0)
		self.itemsTab:DeleteItem(jewel, true)
		spec:RestoreUndoState(undo)
		self.itemsTab:PopulateSlots()
		self:Recalculate()
		return
	end
	local price = GetPriceSource():UniquePrice(result.item)
	self:Note(string.format("Timeless jewel: %s (%s base price; a chosen seed usually costs more)", result.label, GetPriceSource().FormatPrice(price)))
	for _, line in ipairs(described) do self:Note("    " .. line) end
	self.costs = self.costs or { }
	t_insert(self.costs, price or false)
end

-- The unique jewels most poe.ninja builds use: a Forbidden Flame / Flesh pair
-- (from Budget) and a Watcher's Eye for the build's auras (from Mid)
function BuildGeneratorClass:ChooseMetaJewels(onlyKinds)
	local investment = self.options.investment or { }
	if investment.timeless == false then return end
	local finder = new("MetaJewelFinder"):MetaJewelFinder({
		build = self.build,
		fullScore = function() return (self:FullScore()) end,
		quickScore = function() self:Recalculate() return (self:Score()) end,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	local prices = GetPriceSource()
	local kinds = { "forbidden" }
	if investment.exceptionalGems then t_insert(kinds, "watcher") end
	-- Split Personality (cheap, limited to 2): stronger the further its socket
	-- is from the class start, so long paths and cluster sockets are tried
	t_insert(kinds, "split")
	t_insert(kinds, "split")
	-- any other unique jewel within the budget (radius jewels, conditional ones...)
	t_insert(kinds, "unique")
	t_insert(kinds, "unique")
	if onlyKinds then
		local wanted = { }
		for _, k in ipairs(onlyKinds) do wanted[k] = true end
		for i = #kinds, 1, -1 do
			if not wanted[kinds[i]] then t_remove(kinds, i) end
		end
	end
	local function allowed(title)
		local price = prices.uniques[title]
		if price then return not investment.maxUnique or price <= investment.maxUnique end
		return investment.unknownAllowed ~= false
	end
	for _, kind in ipairs(kinds) do
		self:Recalculate()
		local base = self:FullScore()
		local result
		if kind == "forbidden" then
			result = finder:ForbiddenPair(base)
		elseif kind == "split" then
			result = finder:UniqueJewel(base, "Split Personality", nil, 2)
		elseif kind == "unique" then
			result = finder:BestUniqueJewel(base, allowed, function(override) return (self:Score(override)) end)
		else
			result = finder:WatchersEye(base, investment.awakenedGems and 3 or 2)
		end
		-- Forbidden pairs with a chosen notable are expensive: only for high-end
		-- budgets; below that they're noted as a possible upgrade
		if result and result.gain > 0.01 and kind == "forbidden" and not investment.awakenedGems then
			self:Note(string.format("Possible upgrade (High investment): %s, about %+.0f%% score", result.label, result.gain * 100))
			result = nil
		end
		if result and result.gain > 0.01 then
			finder:Apply(result)
			self:Recalculate()
			self:TrimTree()
			local price
			if kind == "forbidden" then
				local a, b = prices.uniques["Forbidden Flame"], prices.uniques["Forbidden Flesh"]
				price = a and b and (a + b) or nil
			elseif kind == "split" then
				price = prices.uniques["Split Personality"]
			elseif kind == "unique" then
				price = prices.uniques[result.title]
			else
				price = prices.uniques["Watcher's Eye"]
			end
			self:Note(string.format("%s (%s base price; these mods / this notable usually cost more)", result.label, prices.FormatPrice(price)))
			self.costs = self.costs or { }
			t_insert(self.costs, price or false)
		end
	end
end

-- Large Cluster Jewels in the outer sockets (from Budget investment)
function BuildGeneratorClass:ChooseClusterJewels(maxJewels)
	local investment = self.options.investment or { }
	if investment.timeless == false then return end
	local gen = new("ClusterJewelGenerator"):ClusterJewelGenerator({
		build = self.build,
		score = function(override) return (self:Score(override)) end,
		fullScore = function() return (self:FullScore()) end,
		quickScore = function() self:Recalculate() return (self:Score()) end,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	for _ = 1, maxJewels or 2 do
		self:Recalculate()
		local base = self:FullScore()
		gen.values = { } -- values change once a jewel is in
		local result = gen:Best(base, { maxPath = 6 })
		if not result or result.gain <= 0.01 then break end
		local spec = self.build.spec
		local undo = spec:CreateUndoState()
		local slot = self.itemsTab.slots["Jewel " .. result.socket.node.id]
		local _, points = gen:Apply(result)
		local jewel = self.itemsTab.items[slot.selItemId]
		self:Recalculate()
		self:TrimTree()
		self:AllocateTree(true)
		-- the points trimmed elsewhere can cost more than estimated: keep it only if the build is better
		if self:FullScore() <= base + 0.002 then
			slot:SetSelItemId(0)
			if jewel then self.itemsTab:DeleteItem(jewel, true) end
			spec:RestoreUndoState(undo)
			spec:BuildClusterJewelGraphs()
			self.itemsTab:PopulateSlots()
			self:Recalculate()
			break
		end
		self:Note(string.format("%s (%d passive points; a crafted / bought rare, price varies)", result.label, points))
	end
end

-- The archetype's uniques: the best (item, slot) pairs are equipped and their
-- slots kept. The first one is the archetype's commitment (kept unless it
-- ruins the build); more are added only while they help.
function BuildGeneratorClass:ApplyArchetypeUniques()
	local archetype = self.options.archetype
	if not archetype then return end
	local candidates = new("BuildArchetypes"):BuildArchetypes().UniqueCandidates(archetype)
	if #candidates == 0 then return end
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local allowed = { }
	for _, item in ipairs(candidates) do
		if finder:IsItemAllowed(item, filter) then t_insert(allowed, item) end
	end
	local slots = finder:GetActiveSlots()
	self.lockedSlots = self.lockedSlots or { }
	local used, kept = { }, { }
	for round = 1, archetype.maxUniques or 3 do
		self:Recalculate()
		local current = self:Score()
		local best
		for _, item in ipairs(allowed) do
			if not used[item] then
				for _, slotName in ipairs(slots) do
					if not self.lockedSlots[slotName] and self.itemsTab:IsItemValidForSlot(item, slotName) then
						local score = self:Score({ repSlotName = slotName, repItem = item })
						if not best or score > best.score then best = { item = item, slot = slotName, score = score } end
					end
				end
			end
		end
		local tolerance = round == 1 and 1.0 or -0.003
		if not best or best.score < current - tolerance then break end
		used[best.item] = true
		finder:Equip(best.item, best.slot, true)
		self.itemsTab:PopulateSlots()
		self.lockedSlots[best.slot] = true
		if best.slot:match("^Weapon") then self.weaponFinalists = nil end
		local price = GetPriceSource():UniquePrice(best.item)
		t_insert(kept, string.format("%s in %s (%s)", best.item.title or best.item.name, best.slot, GetPriceSource().FormatPrice(price)))
		self.costs = self.costs or { }
		t_insert(self.costs, price or false)
	end
	self:Recalculate()
	if #kept > 0 then
		self:Note("Archetype uniques: " .. table.concat(kept, ", "))
	end
end

-- The archetype's unique jewels (Split Personality, Healthy Mind...), kept if they help
function BuildGeneratorClass:ChooseArchetypeJewels()
	local archetype = self.options.archetype
	if not archetype or not archetype.jewels then return end
	local finder = new("MetaJewelFinder"):MetaJewelFinder({
		build = self.build,
		fullScore = function() return (self:FullScore()) end,
		quickScore = function() self:Recalculate() return (self:Score()) end,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	for _, title in ipairs(archetype.jewels) do
		self:Recalculate()
		local base = self:FullScore()
		local result = finder:UniqueJewel(base, title, archetype.jewelStat)
		if result and result.gain > 0.003 then
			finder:Apply(result)
			self:Recalculate()
			self:TrimTree()
			local price = GetPriceSource().uniques[title]
			self:Note(string.format("Archetype jewel: %s (%s)", result.label, GetPriceSource().FormatPrice(price)))
			self.costs = self.costs or { }
			t_insert(self.costs, price or false)
		end
	end
end

-- Joint moves: packages the top players of the skill use together (unique
-- pairs, popular uniques, keystones). Greedy steps miss them because each
-- piece alone often looks worse; here each package is applied for real and
-- the build adapts (passives re-spent, supports re-checked, configuration)
-- before it is judged. The best package is kept if the adapted build is better.
function BuildGeneratorClass:JointMoves(rounds)
	local details = self.options.meta and self.options.meta.details
	if not details or (details.count or 0) < 3 then return end
	local n = details.count
	local byTitle = { }
	for _, item in pairs(main.uniqueDB.list) do
		byTitle[item.title or item.name] = byTitle[item.title or item.name] or item
	end
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local function gearUnique(name)
		local item = byTitle[name]
		if item and item.type ~= "Jewel" and item.type ~= "Flask" and finder:IsItemAllowed(item, filter) then return item end
	end
	local function equipped(title)
		for _, slot in pairs(self.itemsTab.slots) do
			local item = self.itemsTab.items[slot.selItemId]
			if item and item.title == title then return true end
		end
		return false
	end
	-- 1. candidate packages
	local moves = { }
	for i, pair in ipairs(details.uniquePairs or { }) do
		if i > 15 then break end
		local a, b = gearUnique(pair.a), gearUnique(pair.b)
		if a and b and (pair.lift or 0) >= 1.5 and not equipped(pair.a) and not equipped(pair.b) then
			t_insert(moves, { label = pair.a .. " + " .. pair.b, uniques = { a, b }, share = pair.count / n })
		end
	end
	for name, count in pairs(details.uniques or { }) do
		local item = gearUnique(name)
		if item and count / n >= 0.2 and not equipped(name) then
			t_insert(moves, { label = name, uniques = { item }, share = count / n })
		end
	end
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	for name, count in pairs(details.keystones or { }) do
		local node = archetypes.NodeByName(self.build.spec, name)
		if node and not node.alloc and node.path and count / n >= 0.25 and not (self.forbiddenNodes and self.forbiddenNodes[node.id]) then
			t_insert(moves, { label = name, keystone = node, share = count / n })
		end
	end
	if #moves == 0 then return end
	local slots = finder:GetActiveSlots()
	for _ = 1, rounds or 1 do
		self:Recalculate()
		local base = self:FullScore()
		local current = self:Score()
		-- 2. quick screening with overrides (no adaptation yet)
		for _, move in ipairs(moves) do
			local override = { repItems = { }, addNodes = { } }
			move.placement = { }
			for _, item in ipairs(move.uniques or { }) do
				local bestSlot, bestScore
				for _, slotName in ipairs(slots) do
					if override.repItems[slotName] == nil and not (self.lockedSlots and self.lockedSlots[slotName]) and self.itemsTab:IsItemValidForSlot(item, slotName) then
						override.repItems[slotName] = item
						local score = self:Score(override)
						override.repItems[slotName] = nil
						if not bestScore or score > bestScore then bestSlot, bestScore = slotName, score end
					end
				end
				if bestSlot then
					override.repItems[bestSlot] = item
					t_insert(move.placement, { item = item, slot = bestSlot })
				end
			end
			if move.keystone and move.keystone.path then
				for _, node in ipairs(move.keystone.path) do override.addNodes[node] = true end
			end
			move.quick = (#move.placement == #(move.uniques or { })) and self:Score(override) or -math.huge
		end
		t_sort(moves, function(a, b) return a.quick > b.quick end)
		-- 3. the most promising, applied for real and adapted
		local spec = self.build.spec
		local function apply(move)
			local state = { tree = spec:CreateUndoState(), items = { }, gems = { }, input = { } }
			for name, slot in pairs(self.itemsTab.slots) do state.items[name] = slot.selItemId end
			for i, g in ipairs(self.mainGroup.gemList) do state.gems[i] = g end
			for k, v in pairs(self.build.configTab.input) do state.input[k] = v end
			state.newItems = { }
			for _, p in ipairs(move.placement) do
				t_insert(state.newItems, self:Equip(p.item, p.slot))
			end
			self.itemsTab:PopulateSlots()
			if move.keystone and not move.keystone.alloc and move.keystone.path then spec:AllocNode(move.keystone) end
			self:Recalculate()
			self:TrimTree()
			self:ChooseSupports(5)
			self:RefineTree(8)
			self:AutoConfigure()
			return state
		end
		local function revert(state)
			for name, id in pairs(state.items) do
				local slot = self.itemsTab.slots[name]
				if slot and slot.selItemId ~= id then slot:SetSelItemId(id) end
			end
			for _, item in ipairs(state.newItems) do self.itemsTab:DeleteItem(item, true) end
			for i = #self.mainGroup.gemList, 1, -1 do self.mainGroup.gemList[i] = nil end
			for i, g in ipairs(state.gems) do self.mainGroup.gemList[i] = g end
			self.build.skillsTab:ProcessSocketGroup(self.mainGroup)
			local input = self.build.configTab.input
			for k in pairs(input) do input[k] = nil end
			for k, v in pairs(state.input) do input[k] = v end
			self.build.configTab:BuildModList()
			spec:RestoreUndoState(state.tree)
			spec:BuildAllDependsAndPaths()
			self.itemsTab:PopulateSlots()
			self:Recalculate()
		end
		local savedLog = #self.log
		local best, bestScore
		for i = 1, math.min(self.options.jointMoveTries or 5, #moves) do
			local move = moves[i]
			if move.quick > current - 0.4 then
				local state = apply(move)
				local score = self:FullScore()
				revert(state)
				for j = #self.log, savedLog + 1, -1 do t_remove(self.log, j) end
				if score > base + 0.01 and (not bestScore or score > bestScore) then best, bestScore = move, score end
			end
			self:Tick()
		end
		if not best then break end
		apply(best)
		local after = self:FullScore()
		self:Note(string.format("Package from top players (%d%% of them): %s, with passives and supports adapted: score %+.3f",
			math.floor(best.share * 100 + 0.5), best.label, after - base))
		for _, p in ipairs(best.placement) do
			local price = GetPriceSource():UniquePrice(p.item)
			self.costs = self.costs or { }
			t_insert(self.costs, price or false)
			if self.lockedSlots then self.lockedSlots[p.slot] = nil end
		end
		for i = #moves, 1, -1 do if moves[i] == best then t_remove(moves, i) end end
	end
end

-- Pantheon gods and bandit choice, each kept if the build is better with it
-- (Brine King's freeze protection, Arakaali, Lunaris... and Kill all's 2
-- extra passive points against a bandit's stats)
function BuildGeneratorClass:ChoosePantheonAndBandit()
	local configTab = self.build.configTab
	local input = configTab.input
	local spec = self.build.spec
	local chosen = { }
	for _, var in ipairs({ "pantheonMajorGod", "pantheonMinorGod", "bandit" }) do
		local option
		for _, o in ipairs(configTab.varControls and configTab.varControls[var] and configTab.varControls[var].list or { }) do
			option = option or { }
			t_insert(option, o)
		end
		if not option then
			-- (headless builds without config controls: the option definitions)
			for _, o in ipairs(LoadModule("Modules/ConfigOptions")) do
				if o.var == var then option = o.list end
			end
		end
		if option then
			local original = input[var]
			local bestVal, bestScore, bestLabel
			for _, entry in ipairs(option) do
				input[var] = entry.val
				configTab:BuildModList()
				self:Recalculate()
				local undo = var == "bandit" and spec:CreateUndoState()
				if var == "bandit" then
					-- the points it gives or takes are spent / trimmed first
					self:TrimTree()
					self:AllocateTree(true)
				end
				local score = self:FullScore()
				if undo then
					spec:RestoreUndoState(undo)
				end
				if not bestScore or score > bestScore + 0.0005 then bestVal, bestScore, bestLabel = entry.val, score, entry.label end
			end
			input[var] = bestVal or original
			configTab:BuildModList()
			self:Recalculate()
			if var == "bandit" then
				self:TrimTree()
				self:AllocateTree(true)
			end
			if bestLabel and bestVal ~= "None" or var == "bandit" then t_insert(chosen, bestLabel) end
		end
	end
	if #chosen > 0 then
		self:Note("Pantheon and bandit: " .. table.concat(chosen, ", "))
	end
end

-- Removes the items left over from the search (white bases, replaced rares):
-- only what's equipped (or socketed in the tree) stays in the item list
function BuildGeneratorClass:RemoveUnusedItems()
	local itemsTab = self.itemsTab
	local used = { }
	for _, slot in pairs(itemsTab.slots) do
		if slot.selItemId and slot.selItemId ~= 0 then used[slot.selItemId] = true end
	end
	for _, itemSet in pairs(itemsTab.itemSets or { }) do
		for _, entry in pairs(itemSet) do
			if type(entry) == "table" and entry.selItemId and entry.selItemId ~= 0 then used[entry.selItemId] = true end
		end
	end
	for _, itemId in pairs(self.build.spec.jewels or { }) do
		if itemId ~= 0 then used[itemId] = true end
	end
	local unused = { }
	for id, item in pairs(itemsTab.items) do
		if not used[id] then t_insert(unused, item) end
	end
	for _, item in ipairs(unused) do itemsTab:DeleteItem(item, true) end
	itemsTab:PopulateSlots()
end

-- Uniques most players of this skill use (poe.ninja), tried one by one in
-- their slot; each stays if the build is better with it
function BuildGeneratorClass:ChooseMetaUniques()
	local meta = self.options.meta
	if not meta or not meta.items or #meta.items == 0 then return end
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local byTitle = { }
	for _, item in pairs(main.uniqueDB.list) do
		byTitle[item.title or item.name] = byTitle[item.title or item.name] or item
	end
	local slots = finder:GetActiveSlots()
	local kept = { }
	for _, entry in ipairs(meta.items) do
		local item = byTitle[entry.name]
		if item and entry.share >= (self.options.minMetaShare or 0.06) and item.type ~= "Jewel" and item.type ~= "Flask" and finder:IsItemAllowed(item, filter) then
			self:Recalculate()
			local current = self:Score()
			local bestSlot, bestScore
			for _, slotName in ipairs(slots) do
				local slot = self.itemsTab.slots[slotName]
				local equipped = slot and self.itemsTab.items[slot.selItemId]
				if self.itemsTab:IsItemValidForSlot(item, slotName) and not (equipped and equipped.title == item.title) and not (self.lockedSlots and self.lockedSlots[slotName]) then
					local score = self:Score({ repSlotName = slotName, repItem = item })
					if not bestScore or score > bestScore then bestSlot, bestScore = slotName, score end
				end
			end
			if bestSlot and bestScore > current + 0.003 then
				local before = self:FullScore()
				local slot = self.itemsTab.slots[bestSlot]
				local previous = slot.selItemId
				local newItem = finder:Equip(item, bestSlot, true)
				self.itemsTab:PopulateSlots()
				local after = self:FullScore()
				if after > before + 0.003 then
					local price = GetPriceSource():UniquePrice(item)
					t_insert(kept, string.format("%s in %s (%d%% of players; %s)", item.title or item.name, bestSlot, math.floor(entry.share * 100 + 0.5), GetPriceSource().FormatPrice(price)))
					self.costs = self.costs or { }
					t_insert(self.costs, price or false)
				else
					slot:SetSelItemId(previous)
					self.itemsTab:DeleteItem(newItem, true)
					self.itemsTab:PopulateSlots()
					self:Recalculate()
				end
			end
		end
	end
	if #kept > 0 then
		self:Note("Uniques used by players of this skill (poe.ninja): " .. table.concat(kept, ", "))
	elseif meta.total and meta.total > 0 then
		self:Note(string.format("poe.ninja: %d characters use this skill; none of their common uniques improved this build", meta.total))
	end
end

-- Socket groups and the main link state, to undo a move
function BuildGeneratorClass:SaveGroups()
	local skillsTab = self.build.skillsTab
	local saved = { list = { }, main = self.build.mainSocketGroup, limit = self.mainLinkLimit, mainSlot = self.mainGroup and self.mainGroup.slot, log = { } }
	for i, group in ipairs(skillsTab.socketGroupList) do
		local gems = { }
		for j, g in ipairs(group.gemList) do gems[j] = g end
		saved.list[i] = { group = group, gems = gems, slot = group.slot }
	end
	for i, l in ipairs(self.log) do saved.log[i] = l end
	return saved
end
function BuildGeneratorClass:RestoreGroups(saved)
	local skillsTab = self.build.skillsTab
	local list = skillsTab.socketGroupList
	for i = #list, 1, -1 do list[i] = nil end
	for i, entry in ipairs(saved.list) do
		local group = entry.group
		for j = #group.gemList, 1, -1 do group.gemList[j] = nil end
		for j, g in ipairs(entry.gems) do group.gemList[j] = g end
		group.slot = entry.slot
		list[i] = group
		skillsTab:ProcessSocketGroup(group)
	end
	self.build.mainSocketGroup = saved.main
	self.mainLinkLimit = saved.limit
	for i = #self.log, 1, -1 do self.log[i] = nil end
	for i, l in ipairs(saved.log) do self.log[i] = l end
end

-- The main skill moved out of the body armour (for a body armour without
-- sockets, like Kaom's Heart): into the 4-link of the helmet, gloves or boots
-- whose own gems matter least, supports chosen again for the smaller link,
-- then the utility setups again around it
function BuildGeneratorClass:RelocateMainLink()
	local group = self.mainGroup
	local skillsTab = self.build.skillsTab
	local setup = new("GemSetup"):GemSetup(self)
	local best, bestSockets, bestGems
	for _, slotName in ipairs({ "Helmet", "Gloves", "Boots" }) do
		local sockets = setup:SlotSockets(slotName)
		local gems = 0
		for _, g in ipairs(skillsTab.socketGroupList) do
			if g ~= group and g.slot == slotName then gems = gems + #g.gemList end
		end
		if sockets >= 3 and (not best or sockets > bestSockets or (sockets == bestSockets and gems < bestGems)) then
			best, bestSockets, bestGems = slotName, sockets, gems
		end
	end
	if not best then return false end
	local list = skillsTab.socketGroupList
	for i = #list, 1, -1 do
		if list[i] ~= group and list[i].slot == best then t_remove(list, i) end
	end
	for i, g in ipairs(list) do
		if g == group then self.build.mainSocketGroup = i end
	end
	group.slot = best
	self.mainLinkLimit = bestSockets - 1
	self:Recalculate()
	self:ChooseSupports(5)
	self:ChooseUtilityGems()
	self:Note(string.format("Main skill linked in the %s (%d sockets): the body armour has none", best, bestSockets))
	return true
end

-- Every affordable unique in every gear slot, without poe.ninja: the game's
-- whole unique list is screened with the quick score (one calculation each),
-- the best few are equipped for real and kept when the full score agrees.
-- Finds what top players find on their own (Kaom's Heart for Righteous Fire,
-- Mageblood when it is affordable...). Items without sockets are skipped in
-- slots that hold a gem setup.
function BuildGeneratorClass:UniqueSweep(maxTries)
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local groupSlots = { }
	for _, group in ipairs(self.build.skillsTab.socketGroupList) do
		if group.slot and group.enabled ~= false and #group.gemList > 0 then groupSlots[group.slot] = true end
	end
	local function noSockets(item)
		for _, modLine in ipairs(item.explicitModLines or { }) do
			if modLine.line == "Has no Sockets" then return true end
		end
		return false
	end
	-- (a two handed weapon would also empty the off hand: left to the weapon stages)
	local function changesHands(item, slotName)
		if not slotName:match("^Weapon 1") then return false end
		local info = item.base and data.weaponTypeInfo[item.base.type]
		local offSlot = self.itemsTab.slots[slotName:gsub("Weapon 1", "Weapon 2")]
		local offItem = offSlot and self.itemsTab.items[offSlot.selItemId]
		return info and not info.oneHand and offItem and offItem.base.type ~= "Quiver"
	end
	local candidates = { }
	for _, item in pairs(main.uniqueDB.list) do
		if item.type ~= "Jewel" and item.type ~= "Flask" and item.type ~= "Tincture" and finder:IsItemAllowed(item, filter) then
			t_insert(candidates, item)
		end
	end
	t_sort(candidates, function(a, b) return (a.title or a.name) < (b.title or b.name) end)
	self:Recalculate()
	local current = self:Score()
	local gains = { }
	for _, slotName in ipairs(finder:GetActiveSlots()) do
		local slot = self.itemsTab.slots[slotName]
		local equipped = slot and self.itemsTab.items[slot.selItemId]
		if slot and not (self.lockedSlots and self.lockedSlots[slotName]) then
			for _, item in ipairs(candidates) do
				-- (no sockets where the main skill is: it moves to a 4-link, scored when tried)
				local relocate = noSockets(item) and self.mainGroup and self.mainGroup.slot == slotName and slotName == "Body Armour"
				if self.itemsTab:IsItemValidForSlot(item, slotName) and not (equipped and equipped.title == item.title)
					and (relocate or not (groupSlots[slotName] and noSockets(item))) and not changesHands(item, slotName) then
					local score = self:Score({ repSlotName = slotName, repItem = item })
					if score > current + 0.01 then
						t_insert(gains, { item = item, slot = slotName, gain = score - current, relocate = relocate })
					end
				end
			end
		end
	end
	t_sort(gains, function(a, b) return a.gain > b.gain end)
	if self.options.debugTiming then
		ConPrintf("[uniques] %d candidates, %d gains", #candidates, #gains)
		for i = 1, m_min(10, #gains) do ConPrintf("  %.3f %s in %s", gains[i].gain, gains[i].item.title or gains[i].item.name, gains[i].slot) end
	end
	local kept, usedSlots, usedItems = { }, { }, { }
	local tries = 0
	for _, entry in ipairs(gains) do
		if tries >= (maxTries or 6) then break end
		local title = entry.item.title or entry.item.name
		if not usedSlots[entry.slot] and not usedItems[title] then
			tries = tries + 1
			self:Recalculate()
			local before = self:FullScore()
			local slot = self.itemsTab.slots[entry.slot]
			local previous = slot.selItemId
			local newItem = finder:Equip(entry.item, entry.slot, true)
			self.itemsTab:PopulateSlots()
			local savedGroups = entry.relocate and self:SaveGroups()
			local moved = entry.relocate and self:RelocateMainLink()
			self:Recalculate()
			local after = (not entry.relocate or moved) and self:FullScore() or before
			if self.options.debugTiming then ConPrintf("[uniques] tried %s in %s%s: %.3f -> %.3f", entry.item.title or entry.item.name, entry.slot, entry.relocate and " (main link moved)" or "", before, after) end
			if after > before + 0.005 then
				usedSlots[entry.slot] = true
				usedItems[title] = true
				if entry.slot:match("^Weapon") then self.weaponFinalists = nil end
				local price = GetPriceSource():UniquePrice(entry.item)
				t_insert(kept, string.format("%s in %s (+%.2f; %s)", title, entry.slot, after - before, GetPriceSource().FormatPrice(price)))
				self.costs = self.costs or { }
				t_insert(self.costs, price or false)
			else
				if savedGroups then self:RestoreGroups(savedGroups) end
				slot:SetSelItemId(previous)
				self.itemsTab:DeleteItem(newItem, true)
				self.itemsTab:PopulateSlots()
				self:Recalculate()
			end
		end
	end
	if #kept > 0 then
		self:Note("Uniques found by trying every affordable unique: " .. table.concat(kept, ", "))
	end
	return #kept
end

-- Unique flasks (Dying Sun, Bottled Faith, Cinderswallow Urn...) against the
-- generated magic ones: each affordable unique flask in each flask slot,
-- screened with the quick score, the best few checked with flask uptimes
function BuildGeneratorClass:UniqueFlaskSweep(maxTries)
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local candidates = { }
	for _, item in pairs(main.uniqueDB.list) do
		if item.type == "Flask" and item.base and item.base.flask and finder:IsItemAllowed(item, filter) then
			t_insert(candidates, item)
		end
	end
	t_sort(candidates, function(a, b) return (a.title or a.name) < (b.title or b.name) end)
	self:Recalculate()
	local current = self:Score()
	local gains = { }
	local active = { }
	for i = 1, 5 do active["Flask " .. i] = true end
	for i = 1, 5 do
		local slotName = "Flask " .. i
		local slot = self.itemsTab.slots[slotName]
		if slot then
			local equipped = self.itemsTab.items[slot.selItemId]
			for _, item in ipairs(candidates) do
				if self.itemsTab:IsItemValidForSlot(item, slotName) and not (equipped and equipped.title == item.title) then
					local score = self:Score({ repSlotName = slotName, repItem = item, activeFlaskSlots = active })
					if score > current + 0.005 then
						t_insert(gains, { item = item, slot = slotName, gain = score - current })
					end
				end
			end
		end
	end
	t_sort(gains, function(a, b) return a.gain > b.gain end)
	local kept, usedSlots, usedItems = { }, { }, { }
	local tries = 0
	for _, entry in ipairs(gains) do
		if tries >= (maxTries or 5) then break end
		local title = entry.item.title or entry.item.name
		if not usedSlots[entry.slot] and not usedItems[title] then
			tries = tries + 1
			self:Recalculate()
			local before = self:FullScore()
			local slot = self.itemsTab.slots[entry.slot]
			local previous, wasActive = slot.selItemId, slot.active
			local newItem = finder:Equip(entry.item, entry.slot, true)
			slot.active = true
			if self.itemsTab.activeItemSet[entry.slot] then self.itemsTab.activeItemSet[entry.slot].active = true end
			self.itemsTab:PopulateSlots()
			self:Recalculate()
			local after = self:FullScore()
			if after > before + 0.005 then
				usedSlots[entry.slot] = true
				usedItems[title] = true
				local price = GetPriceSource():UniquePrice(entry.item)
				t_insert(kept, string.format("%s in %s (+%.2f; %s)", title, entry.slot, after - before, GetPriceSource().FormatPrice(price)))
				self.costs = self.costs or { }
				t_insert(self.costs, price or false)
			else
				slot:SetSelItemId(previous)
				slot.active = wasActive
				if self.itemsTab.activeItemSet[entry.slot] then self.itemsTab.activeItemSet[entry.slot].active = wasActive end
				self.itemsTab:DeleteItem(newItem, true)
				self.itemsTab:PopulateSlots()
				self:Recalculate()
			end
		end
	end
	if #kept > 0 then
		self:Note("Unique flasks: " .. table.concat(kept, ", "))
	end
	return #kept
end

-- Best anoint for the amulet within the investment level
function BuildGeneratorClass:ChooseAnoint()
	local extras = new("TreeExtras"):TreeExtras(self.build)
	local slot = self.itemsTab.slots["Amulet"]
	local amulet = slot and self.itemsTab.items[slot.selItemId]
	if not extras:CanAnoint(amulet) then return end
	self:Recalculate()
	local current = self:Score()
	local best, bestScore, bestEntry
	for _, entry in ipairs(extras:AnointCandidates(self.options.investment)) do
		local copy = extras:AnointedCopy(amulet, entry.node)
		local score = self:Score({ repSlotName = "Amulet", repItem = copy })
		if not bestScore or score > bestScore then best, bestScore, bestEntry = copy, score, entry end
	end
	if best and bestScore > current + 0.002 then
		self:Equip(best, "Amulet")
		self.itemsTab:PopulateSlots()
		self:Note(string.format("Anoint: %s (%s)", bestEntry.node.dn, GetPriceSource().FormatPrice(bestEntry.price)))
		self.costs = self.costs or { }
		t_insert(self.costs, bestEntry.price or false)
	end
end

-- Tattoos on allocated attribute passives, keystones and masteries
function BuildGeneratorClass:ChooseTattoos()
	local extras = new("TreeExtras"):TreeExtras(self.build)
	self:Recalculate()
	local targets = extras:TattooTargets()
	local options = extras:TattooOptions(self.options.investment)
	local current = self:Score()
	-- 1. value of each tattoo on the first passive of its kind
	local ranked = { }
	for _, option in ipairs(options) do
		local list = targets[option.targetType]
		if list and list[1] then
			local override = { removeNodes = { [list[1]] = true }, addNodes = { [extras:VirtualTattoo(option.tattoo)] = true } }
			local gain = self:Score(override) - current
			if gain > 0.0005 then t_insert(ranked, { option = option, gain = gain }) end
		end
	end
	t_sort(ranked, function(a, b) return a.gain > b.gain end)
	-- 2. apply in that order while each one still helps
	local used, limits, applied = { }, { }, { }
	for _, entry in ipairs(ranked) do
		local option = entry.option
		if #applied >= (self.options.maxTattoos or 30) then break end
		if not (option.limitKey and limits[option.limitKey]) then
			local target
			for _, node in ipairs(targets[option.targetType] or { }) do
				if not used[node] then target = node break end
			end
			if target then
				self:Recalculate()
				current = self:Score()
				local override = { removeNodes = { [target] = true }, addNodes = { [extras:VirtualTattoo(option.tattoo)] = true } }
				if self:Score(override) > current + 0.0005 then
					extras:ApplyTattoo(target, option.name)
					used[target] = true
					if option.limitKey then limits[option.limitKey] = true end
					t_insert(applied, option.name)
					self.costs = self.costs or { }
					t_insert(self.costs, option.price or false)
				end
			end
		end
	end
	if #applied > 0 then
		self.build.spec:AddUndoState()
		local counts = { }
		for _, name in ipairs(applied) do counts[name] = (counts[name] or 0) + 1 end
		local parts = { }
		for name, n in pairs(counts) do t_insert(parts, (n > 1 and (n .. "x ") or "") .. name:gsub("^Tattoo of the ", "")) end
		table.sort(parts)
		self:Note(string.format("Tattoos (%d): %s", #applied, table.concat(parts, ", ")))
	end
end

function BuildGeneratorClass:AutoConfigure(note)
	local ac = new("AutoConfig"):AutoConfig(self.build, self.options.configScenario)
	ac:Run()
	-- one line per option across all runs, with its final value
	self.configChangeByVar = self.configChangeByVar or { }
	self.configOrder = self.configOrder or { }
	for var, text in pairs(ac.changeByVar or { }) do
		if not self.configChangeByVar[var] then t_insert(self.configOrder, var) end
		self.configChangeByVar[var] = text
	end
	self.configChanges = { }
	for _, var in ipairs(self.configOrder) do t_insert(self.configChanges, self.configChangeByVar[var]) end
	self:Recalculate()
end

-- Unique items, keystones and supports from the synergy finder
function BuildGeneratorClass:ApplySynergies(rounds)
	for round = 1, rounds do
		self:Recalculate()
		local before = self:FullScore()
		local finder = new("SynergyFinder"):SynergyFinder(self.itemsTab, {
			focus = self.options.focus, scenario = self.options.scenario, quality = self.options.quality,
			ehpFloor = self.options.ehpFloor, hitFloor = self.options.hitFloor, chargesPerSecond = self.options.chargesPerSecond,
			levelOnly = true, obtainableOnly = true, maxIdeas = 5, seedCount = 12,
			investment = self.options.investment, allowAnoints = self.options.allowAnoints, allowTattoos = self.options.allowTattoos, allowTimeless = self.options.timeless,
			meta = self.options.meta, metaSkill = self.mainGem and self.mainGem.name, protectedNodes = self.protectedNodes,
			yieldEvery = self.options.yieldEvery, onProgress = function(stage) self.stage = "Synergies: " .. stage end,
		})
		local result = finder:Run()
		local best
		for _, idea in ipairs(result.ideas) do
			if not best or idea.score > best.score then best = idea end
		end
		if not best or best.gain <= 0.01 then break end
		finder:Apply(best)
		self:Recalculate()
		self:TrimTree()
		local after = self:FullScore()
		if after < before then
			self:Note("Synergy idea did not hold up after applying, kept anyway: " .. best.title)
		end
		self:Note(string.format("Applied idea (%s): %s%s", best.kind, best.title, best.costs and #best.costs > 0 and (" [" .. table.concat(best.costs, ", ") .. "]") or ""))
		self.costs = self.costs or { }
		t_insert(self.costs, best.totalCost or false)
		self.ideas = self.ideas or { }
		t_insert(self.ideas, best)
	end
end

------------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------------

function BuildGeneratorClass:Run()
	local opts = self.options
	self.lastYield = GetTime()
	self.startClock = os.clock()
	self.overlap = nil
	self.costs = { }
	self.stageCount = 11
	local function stage(index, label)
		-- big searches leave a lot of garbage: free it between stages when it
		-- piled up (a full collection of the game data takes a second)
		if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
		if opts.debugTiming and self.scorer then
			local _, r = self:FullScore()
			ConPrintf("[stage] before %d: score %.3f dps %.0f ehp %.0f lua %.0f MB t=%.0fs", index, r.score, r.dps, r.ehp, collectgarbage("count") / 1024, os.clock() - (self.startClock or 0))
		end
		self.stageIndex, self.stage = index, label
		self:Tick()
	end
	-- Investment level decides rare quality and influences unless set
	local probe = new("PriceSource"):PriceSource()
	opts.investment = opts.investment or probe.levels[probe.defaultLevel]
	if not opts.quality then
		local finderProbe = new("BestItemFinder"):BestItemFinder(self.itemsTab)
		opts.quality = finderProbe.rareQualityList[opts.investment.quality or 2]
	end

	stage(1, "Setting up the character and configuration")
	self:Setup()
	self.overlap = new("HitOverlap"):HitOverlap(self.build, opts.scenario)
	local bossFight = not opts.configScenario or opts.configScenario.id == "BOSS"
	opts.chargesPerSecond = opts.chargesPerSecond or (bossFight and 1.5 or 4)
	self.scorer = new("BuildScorer"):BuildScorer(self.build, { focus = opts.focus, chargesPerSecond = opts.chargesPerSecond, overlap = self.overlap, ehpFloor = opts.ehpFloor, hitFloor = opts.hitFloor,
		bossTier = opts.investment and opts.investment.awakenedGems and "uber" or "pinnacle" })
	self.scorer.useChecklist = false -- on from the flask stage
	if opts.archetype then
		self:Note("Archetype: " .. opts.archetype.label)
	end
	self:AutoConfigure()
	self:FullScore()

	stage(2, "Choosing support gems")
	self:ChooseSupports(5)

	stage(3, "Allocating passive tree")
	self:FullScore()
	self:AllocateTree()

	stage(4, "Choosing item bases")
	self:ChooseBases()
	self:ApplyArchetypeUniques()

	stage(5, "Generating rare items")
	self:FullScore()
	self:MakeRares(false)

	stage(6, "Re-checking supports, adding curse, aura and utility setups")
	self:FullScore()
	self:ChooseSupports(5)
	self:ChooseUtilityGems(true)

	stage(7, "Re-allocating passive tree for the gear, choosing a bloodline")
	self:ResetTree()
	self:AutoConfigure()
	self:FullScore()
	self:AllocateTree()
	if opts.quick then
		-- archetype scan: a first version of the build, enough to compare archetypes
		-- (aura stacking needs its tree move to show what it's worth)
		if opts.archetype and opts.archetype.maxAuras then self:AuraStackMove() end
		-- the cheap late steps that change which archetype comes out best (a
		-- Watcher's Eye for the archetype's auras, a build-defining unique,
		-- supports for the gear): without them the scan ranks archetypes by
		-- their start, not by where they end
		if opts.scanExtras ~= false then
			if opts.uniqueSweep ~= false then self:UniqueSweep(3) end
			if opts.metaJewels ~= false then self:ChooseMetaJewels({ "watcher" }) end
			self:FinalSupports()
		end
		self:AutoConfigure()
		self:Recalculate()
		local final = self.scorer:Evaluate(self.calcFunc, { })
		self.final = final
		self.build.buildFlag = true
		local analyzer = new("ScalingAnalyzer"):ScalingAnalyzer(self.build, self.scorer, self.calcFunc)
		local okScale, scaling = pcall(function() return analyzer:Run() end)
		if okScale and scaling then
			local summary = analyzer.Summary(scaling, 3)
			if summary.damage then self:Note(summary.damage) end
		end
		local total = 0
		for _, price in ipairs(self.costs) do total = total + (price or 0) end
		return { log = self.log, final = final, cost = total, ideas = { }, configChanges = self.configChanges or { }, assumptions = { } }
	end
	self:ChooseBloodline()

	stage(8, (opts.investment.influences or 0) > 0 and "Generating influenced rare items" or "Generating rare items again")
	self:FullScore()
	self:MakeRares(true)

	stage(9, "Choosing gem setups, jewels, anoint and tattoos")
	self:FullScore()
	self:ChooseUtilityGems()
	self:ChooseMetaUniques()
	if opts.uniqueSweep ~= false then
		self.stage = "Trying every affordable unique"
		self:UniqueSweep()
	end
	self:ChooseArchetypeJewels()
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseMetaUniques', r.score, r.dps, r.ehp) end
	if opts.jewels ~= false then self:AddJewels(opts.maxJewels or 4) end
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'AddJewels', r.score, r.dps, r.ehp) end
	if opts.timeless ~= false then self:ChooseTimelessJewel() end
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseTimelessJewel', r.score, r.dps, r.ehp) end
	if opts.metaJewels ~= false then self:ChooseMetaJewels() end
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseMetaJewels', r.score, r.dps, r.ehp) end
	if opts.clusterJewels ~= false then self:ChooseClusterJewels(opts.maxClusterJewels or 2) end
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseClusterJewels', r.score, r.dps, r.ehp) end
	-- spend any points the jewel stages freed
	self:Recalculate()
	self:AllocateTree(true)
	if opts.allowAnoints ~= false then self:ChooseAnoint() end
	if opts.allowTattoos ~= false then self:ChooseTattoos() end

	stage(10, "Choosing flasks, pantheon and bandit")
	self.scorer.useChecklist = true
	self:FullScore()
	self:MakeFlasks()
	if opts.uniqueSweep ~= false then self:UniqueFlaskSweep() end
	self:ChoosePantheonAndBandit()
	if opts.auraStacking ~= false then
		self.stage = "Trying aura stacking"
		self:AuraStackMove()
	end
	if opts.fillMainLink ~= false then
		self.stage = "Filling the main link"
		self:FillMainLinkMove()
	end
	if opts.finalRares ~= false then
		self.stage = "Making the rares again for the finished build"
		self:FinalRares()
	end

	if opts.synergies ~= false then
		stage(11, "Looking for unique items and synergies")
		self:ApplySynergies(opts.synergyRounds or 1)
	end
	if opts.jointMoves ~= false then
		self.stage = "Trying packages from top players"
		self:JointMoves(opts.jointMoveRounds or 2)
	end
	self.stage = "Optimizing the passive tree"
	if opts.ascendancyRecheck ~= false then self:AscendancyRecheck() end
	if opts.finalSupports ~= false then
		-- (new supports can want other passives: a short tree round when they change)
		if self:FinalSupports() > 0 then self:RefineTree(10) end
	end
	self:PairAilments()
	self:OptimizeTree()

	self:RemoveUnusedItems()
	self:AutoConfigure()
	self:Recalculate()
	local final = self.scorer:Evaluate(self.calcFunc, { })
	self.final = final
	self.build.buildFlag = true
	-- defence summary: boss hits and the checklist
	local output = self.build.calcsTab.mainOutput
	local bossRatio, bossName = self.scorer:BossHitRatio(output)
	if bossRatio then
		self:Note(string.format("Toughest %s boss hit (%s): taken %.1f times over (max hits: physical %s, fire %s, cold %s, lightning %s, chaos %s)",
			self.scorer.bossTier == "uber" and "uber" or "pinnacle", bossName, bossRatio,
			formatNumSep(tostring(output.PhysicalMaximumHitTaken or 0)), formatNumSep(tostring(output.FireMaximumHitTaken or 0)), formatNumSep(tostring(output.ColdMaximumHitTaken or 0)),
			formatNumSep(tostring(output.LightningMaximumHitTaken or 0)), formatNumSep(tostring(output.ChaosMaximumHitTaken or 0))))
	end
	-- what scales the build next (same small amount of each stat, measured)
	local analyzer = new("ScalingAnalyzer"):ScalingAnalyzer(self.build, self.scorer, self.calcFunc)
	local okScale, scaling = pcall(function() return analyzer:Run() end)
	if okScale and scaling then
		self.scaling = scaling
		local summary = analyzer.Summary(scaling)
		for _, key in ipairs({ "damage", "saturated", "defence" }) do
			if summary[key] then self:Note(summary[key]) end
		end
	end
	local details = self.options.meta and self.options.meta.details
	if details and details.count > 0 and details.maxHit then
		local mh = details.maxHit
		self:Note(string.format("Top %d players of this skill (poe.ninja, median): max hit physical %s, fire %s, cold %s, lightning %s, chaos %s, EHP %s",
			details.count, formatNumSep(tostring(mh.Physical or 0)), formatNumSep(tostring(mh.Fire or 0)), formatNumSep(tostring(mh.Cold or 0)),
			formatNumSep(tostring(mh.Lightning or 0)), formatNumSep(tostring(mh.Chaos or 0)), formatNumSep(tostring(details.ehp or 0))))
	end
	-- how each generated rare can be made
	local advisor = new("CraftAdvisor"):CraftAdvisor()
	for _, slot in ipairs(self.itemsTab.orderedSlots) do
		local item = self.itemsTab.items[slot.selItemId]
		if item and item.rarity == "RARE" and item.title and item.title:match("^Best Rare") and not slot.slotName:match("^Jewel") then
			local ok, craft = pcall(function() return advisor:Describe(item) end)
			if ok and craft then self:Note(string.format("Craft %s (%s): %s", slot.slotName, item.baseName, craft.text)) end
		end
	end
	local _, checks = self.scorer:Checklist(output)
	local okList, missingList = { }, { }
	for _, entry in ipairs(checks) do t_insert(entry.ok and okList or missingList, entry.label) end
	self:Note("Defence checklist: " .. (#okList > 0 and ("has " .. table.concat(okList, ", ")) or "nothing")
		.. (#missingList > 0 and ("; missing " .. table.concat(missingList, ", ")) or ""))

	-- Estimated cost of the bought parts (uniques, anoint, tattoos)
	local total, unknown = 0, 0
	for _, price in ipairs(self.costs) do
		if price then total = total + price else unknown = unknown + 1 end
	end
	local prices = GetPriceSource()
	local costLine
	if not prices.loaded then
		costLine = "Prices not loaded: uniques, anoints and tattoos were not filtered by price"
	else
		costLine = string.format("Estimated cost of uniques, anoint and tattoos: %s%s (rares not priced)", prices.FormatPrice(total), unknown > 0 and string.format(", plus %d with no price", unknown) or "")
	end
	return {
		log = self.log,
		final = final,
		ideas = self.ideas or { },
		configChanges = self.configChanges or { },
		costLine = costLine,
		assumptions = {
			"Investment level: " .. opts.investment.label,
			"Main skill in a 6-link body armour, utility setups in the helmet, gloves, boots and weapon sockets; gems at their normal maximum level with 20% quality",
			"Abyss jewels are not used; cluster jewels are Large ones with 8 passives",
			"Configuration set automatically for: " .. ((opts.configScenario and opts.configScenario.label) or "Pinnacle boss") .. ", see the changes below",
			"Rares use " .. ((opts.quality and opts.quality.label) or "tier 2-3, average rolls") .. (opts.crafts ~= false and ", with up to one crafting bench mod" or ""),
		},
	}
end
