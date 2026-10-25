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
local m_log = math.log
local m_floor = math.floor

---@class BuildGenerator

-- Nodes of a node table in id order (pairs() order changes from run to run:
-- LuaJIT seeds its hashing per process, and greedy choices follow the order)
local function nodesById(tbl)
	local list = { }
	for _, node in pairs(tbl) do list[#list + 1] = node end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

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
			-- (movement skills are utility, except channelled attacks like Cyclone and
			-- strikes like Flicker Strike; auras too, except attacks like Smite)
			and not ((gem.tags.aura and not gem.tags.attack) or gem.tags.herald or gem.tags.guard
				or ((gem.tags.movement or gem.tags.travel or gem.tags.blink) and not gem.tags.channelling and not (gem.tags.strike and not gem.tags.travel))
				or gem.tags.warcry and not gem.tags.attack) then
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
	-- Builds are made from their own value only: what players use (poe.ninja)
	-- is kept for showing and comparing (options.metaShown), and steers the
	-- build only when options.learnFromPlayers is set
	if self.options.meta and not self.options.learnFromPlayers then
		self.options.metaShown = self.options.meta
		self.options.meta = nil
	end
	-- a total budget (divines for the whole build) picks the investment level
	-- and caps one item at half of it; the finished build is fitted under it
	if self.options.totalBudget and self.options.totalBudget > 0 then
		self.options.investment = new("PriceSource"):PriceSource().ForBudget(self.options.totalBudget)
	end
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
			opts.onProgress(self.stage or "", self.stageIndex or 0, self.stageCount or 1, self.subProgress or 0)
		end
		coroutine.yield()
		self.lastYield = GetTime()
	end
end

-- Variants of a generation (options.variant 2, 3...): the structural
-- choices of the first stages (supports, passive tree, ascendancy, weapon)
-- see their gains scaled by a fixed pseudo-random factor around 1 (15%), so
-- each variant explores another near-best path; the later stages are exact.
-- The same variant always gives the same build. 1 for the plain generation.
function BuildGeneratorClass:Jitter(key)
	local variant = self.options.variant or 1
	if variant <= 1 or (self.stageIndex or 0) > (self.options.variantStages or 8) then return 1 end
	local text = tostring(key) .. "#" .. variant
	local h = 5381
	for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
	h = (h * 2654435761) % 4294967296
	return 1 + (self.options.variantSpread or 0.15) * ((h % 10007) / 10006 - 0.5) * 2
end

-- Progress within the current stage (0 to 1), for the window's progress bar:
-- Move(i, n) starts the i-th of n steps of the stage, Inner(f) is how far
-- the running step is (only ever moves forward)
function BuildGeneratorClass:Move(index, count, label)
	self.moveFrom, self.moveTo = (index - 1) / count, index / count
	self.subProgress = m_max(self.subProgress or 0, self.moveFrom)
	if label then self.stage = label end
end
function BuildGeneratorClass:Inner(fraction)
	local from, to = self.moveFrom or 0, self.moveTo or 1
	local p = from + (to - from) * m_max(0, m_min(1, fraction or 0))
	if p > (self.subProgress or 0) then self.subProgress = p end
end

function BuildGeneratorClass:Note(text)
	if self.decisions then self:Decision("note", text) end
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
	self.recalcCount = (self.recalcCount or 0) + 1
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

-- How the main skill is used in a fight (Classes/SkillProfiles): the skill
-- part, stages and counts a player realistically gets on a boss (Blade
-- Vortex blades kept up, Toxic Rain pods overlapping, Tornado Shot's
-- projectiles...). Returns true if the build changed (it needs recalculating).
function BuildGeneratorClass:AdjustSkillPart()
	if self.options.skillProfiles == false then return false end
	self.skillProfiles = self.skillProfiles or new("SkillProfiles"):SkillProfiles()
	return self.skillProfiles.Apply(self)
end

-- Skills whose damage on one target adds several of their parts (PoB shows
-- one part at a time: Kinetic Blast's projectile, or one explosion): their
-- hit damage relative to the part shown, kept on the scorer (it adds that
-- much more of the shown part's hit DPS)
function BuildGeneratorClass:UpdateCombinedParts()
	if not self.scorer then return end
	self.skillProfiles = self.skillProfiles or new("SkillProfiles"):SkillProfiles()
	local gem = self.mainGem
	local first = self.mainGroup and self.mainGroup.gemList[1]
	local configScenario = self.options.configScenario
	local ctx = { output = self.build.calcsTab.mainOutput or { }, boss = not configScenario or configScenario.boss and true or false, gen = self }
	local rule = gem and first and self.options.skillProfiles ~= false and self.skillProfiles.Combine(gem, ctx)
	if not rule then
		self.scorer.hitScale = nil
		return
	end
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
end

function BuildGeneratorClass:FullScore()
	self.fullScoreCount = (self.fullScoreCount or 0) + 1
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
		{ level = self:GemLevel(gem, true), quality = (self.options.investment or { }).corruptedSupports and 23 or 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = opts.gemId },
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
	-- (a trigger setup's attack needs its weapon: Classes/TriggerSetups)
	local effect = self.triggerSource and self.triggerSource.grantedEffect.weaponTypes and self.triggerSource.grantedEffect or self.mainGem.grantedEffect
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
			and (not GetGeneratorRules().ownDamageSupports[gem.name] or GetGeneratorRules().ownDamageSupports[gem.name](self.mainGem))
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
	-- (a trigger setup's gems stay linked first: its trigger skill and support)
	if self.triggerFixed then
		for i = #self.triggerFixed, 1, -1 do t_insert(forced, 1, self.triggerFixed[i]) end
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
				if not bestScore or score > bestScore + 1e-9 then best, bestScore = gemId, score end
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
	-- the supports the candidate model is sure can't help this skill skipped
	-- (Modules/GeneratorModel; options.useModel = false to try them all)
	local tryList = supports
	if self.options.useModel ~= false then
		local okModel, model = pcall(LoadModule, "Modules/GeneratorModel")
		if okModel and model and model.Load() then
			tryList = { }
			local skipped = 0
			for _, gemId in ipairs(supports) do
				if model.SkipSupport(data.gems[gemId].name, self.mainGem and self.mainGem.tags) then skipped = skipped + 1 else t_insert(tryList, gemId) end
			end
			self.modelSkipped = (self.modelSkipped or 0) + skipped
		end
	end
	for pick = 1, maxSupports - forcedCount do
		self:Inner((pick - 1) / m_max(1, maxSupports - forcedCount))
		local best, bestScore, bestSeen
		for _, gemId in ipairs(tryList) do
			if not inGroup(gemId) then
				local gem = data.gems[gemId]
				t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
				self.build.skillsTab:ProcessSocketGroup(group)
				local score = self:WithChargesOf(gem, function() return self:Score() end)
				t_remove(group.gemList)
				if self.decisions then self:Decision("support", gem.name, score - current, false, { pick = pick }) end
				-- (variants: gains seen through their factor)
				local seen = current + (score - current) * (score > current and self:Jitter("support" .. gemId) or 1)
				if not bestScore or seen > bestSeen + 1e-9 then
					best, bestScore, bestSeen = gemId, score, seen
				end
			end
		end
		-- (a build that doesn't value damage - a custom mix with damage 0 - only
		-- links supports that serve its other goals: life leech, speed...)
		local minGain = (self.scorer and self.scorer.focus and self.scorer.focus.dps or 1) < 0.05 and 0.003 or 0
		if not best or bestScore <= current + minGain then
			break
		end
		local gem = data.gems[best]
		t_insert(group.gemList, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = best })
		self:Decision("support", gem.name, bestScore - current, true, { pick = pick })
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
	-- swaps: each chosen support against every other one (supports that work
	-- together, like Impale with Pride's impale mods, can lose one at a time;
	-- a swap sees the pair). The archetype's and playstyle's supports stay.
	if self.options.supportSwaps ~= false and self.swapSupports then
		local keep = { }
		for _, gemId in ipairs(forced) do keep[gemId] = true end
		for _ = 1, 2 do
			self.build.skillsTab:ProcessSocketGroup(group)
			local base = self:Score()
			local best, bestScore, bestPos
			for pos = 2, #group.gemList do
				local old = group.gemList[pos]
				-- (charge supports switched their charges on in the configuration: kept)
				if not keep[old.gemId] and not data.gems[old.gemId].name:find("Charge", 1, true) then
					for _, gemId in ipairs(tryList) do
						if not inGroup(gemId) then
							local gem = data.gems[gemId]
							group.gemList[pos] = { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId }
							self.build.skillsTab:ProcessSocketGroup(group)
							local score = self:WithChargesOf(gem, function() return self:Score() end)
							if score > (bestScore or base) + 1e-9 then best, bestScore, bestPos = gemId, score, pos end
						end
					end
					group.gemList[pos] = old
				end
			end
			if not best or bestScore <= base + 0.002 then break end
			local gem = data.gems[best]
			group.gemList[bestPos] = { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = best }
		end
		self.build.skillsTab:ProcessSocketGroup(group)
	end
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
			if not bestScore or score > bestScore + 1e-9 then best, bestScore, bestCount = ids, score, set.count end
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
	-- (costs too: reserving mana leaves less to cast with, which the tree and
	-- the gear fix afterwards; the full score at the end has the real costs)
	self.scorer.ignoreReservation = true
	self.scorer.ignoreCosts = true
	local ok, err = pcall(function()
		self:ChooseUtilityGems()
	end)
	self.scorer.ignoreReservation = false
	self.scorer.ignoreCosts = false
	if ok and auraCount() > beforeAuras then
		self:AutoConfigure()
		local function debugState(label)
			if not self.options.debugTiming then return end
			self:Recalculate()
			local o = self.build.calcsTab.mainOutput
			ConPrintf("[auras] %s: %d auras, mana %s unreserved %s, life %s unreserved %s, score %.3f", label, auraCount(), tostring(o.Mana), tostring(o.ManaUnreserved), tostring(o.Life), tostring(o.LifeUnreserved), (self:Score()))
		end
		debugState("chosen")
		self:RefineTree(16)
		self:RefineTree(10)
		debugState("tree re-spent")
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
							if not bestScore or score > bestScore + 1e-9 then bestGroup, bestIndex, bestScore = group, i, score end
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
	-- (a trigger setup's trigger skill takes a socket of the link too)
	if supports + (self.triggerFixed and 1 or 0) >= 5 then return 0 end
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
		for _, node in ipairs(nodesById(spec.nodes)) do
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
	local function jittered(value, entry)
		if value > 0 then return value * self:Jitter(entry.node.id .. (entry.effect and ("_" .. entry.effect.id) or "")) end
		return value
	end
	local function ratio(entry)
		if entry.effect then
			if not effectFree(entry.effect.id) then return -math.huge end
			return jittered(self:Score({ addNodes = { [effectNode(entry.node, entry.effect)] = true } }) - current, entry)
		end
		local pathSet = { }
		for _, n in ipairs(entry.node.path) do pathSet[n] = true end
		local score = self:Score({ addNodes = pathSet })
		return jittered((score - current) / pathCost(entry.node), entry)
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
		local startLeft
		while true do
			local used, ascUsed = spec:CountAllocNodes()
			local left = ascendancy and (ascBudget - ascUsed) or (budget - used)
			if left <= 0 then break end
			startLeft = startLeft or left
			if not ascendancy and startLeft > 0 then self:Inner(1 - left / startLeft) end
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
				if self.decisions then
					local alternatives = { }
					for i = 2, m_min(5, #queue) do
						local e = queue[i]
						if e.value ~= -math.huge then t_insert(alternatives, { n = e.node.dn .. (e.effect and (": " .. table.concat(e.effect.sd or { }, " / ")) or ""), v = m_floor(e.value * 1e5 + 0.5) / 1e5, id = e.node.id }) end
					end
					self:Decision("passive", picked.node.dn .. (picked.effect and (": " .. table.concat(picked.effect.sd or { }, " / ")) or ""), picked.value, true,
						{ id = picked.node.id, type = picked.node.type, points = pathCost(picked.node), asc = ascendancy or nil, alt = alternatives })
				end
				if self.treeStats then self.treeStats.picks = self.treeStats.picks + 1 end
				t_remove(queue, 1)
				current = self:Score()
				sinceRefresh = sinceRefresh + 1
			end
		end
		if not ascendancy then self.treePrev = prev end
	end
	-- (labels only for the tree stages themselves: inside a named step the
	-- window keeps showing that step)
	local savedStage = self.stage
	local label = (self.moveFrom or 0) == 0 and (self.moveTo or 1) == 1
	if not ascendancyOnly then
		if label then self.stage = "Allocating passive tree" end
		run(false)
	end
	if label then self.stage = "Allocating ascendancy" end
	self:SearchAscendancy()
	current = self:Score()
	run(true) -- spend any point left after the notables
	if not label then self.stage = savedStage end
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
	for _, node in ipairs(nodesById(spec.nodes)) do
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
					if score > current and (self.options.variant or 1) > 1 then
						local key = { }
						for _, c in ipairs(chosen) do key[#key + 1] = c.node.id end
						score = current + (score - current) * self:Jitter("asc" .. table.concat(key, ","))
					end
					if score > bestScore + 1e-9 then
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
			for _, node in ipairs(nodesById(spec.allocNodes)) do
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

-- Swaps for strong passives out of reach: allocation spends points by gain
-- per point, so the last points go to cheap nearby passives while a strong
-- notable a few points away is never affordable. Here the passives worth
-- the most on their own (with their path) are tried one at a time: the
-- cheapest leaves are taken back to pay for the path, and the swap is kept
-- if the build is better.
function BuildGeneratorClass:SwapForNotables(maxTries)
	local spec = self.build.spec
	local maxDist = self.options.swapDistance or 7
	self:Recalculate()
	local budget = self:PointBudget()
	local current = self:Score()
	local function pathCost(node)
		local cost = 0
		for _, n in ipairs(node.path) do if not n.isMultipleChoiceOption then cost = cost + 1 end end
		return m_max(1, cost)
	end
	-- 1. the strongest single targets (whole gain, not per point)
	local targets = { }
	for _, node in ipairs(nodesById(spec.nodes)) do
		if not node.alloc and node.path and #node.path >= 2 and #node.path <= maxDist and not node.ascendancyName
			and (node.type == "Notable" or node.type == "Keystone") and not node.isProxy
			and not (self.forbiddenNodes and self.forbiddenNodes[node.id]) then
			local pathSet = { }
			for _, n in ipairs(node.path) do pathSet[n] = true end
			local gain = self:Score({ addNodes = pathSet }) - current
			if gain > 0.01 then t_insert(targets, { node = node, gain = gain, cost = pathCost(node) }) end
		end
	end
	t_sort(targets, function(a, b)
		if m_floor(a.gain * 1e9) ~= m_floor(b.gain * 1e9) then return a.gain > b.gain end
		return a.node.id < b.node.id
	end)
	local kept, tries = { }, 0
	for _, target in ipairs(targets) do
		if tries >= (maxTries or 10) then break end
		local node = target.node
		if not node.alloc and node.path then
			tries = tries + 1
			local before = self:FullScore()
			local undo = spec:CreateUndoState()
			local onPath = { }
			for _, n in ipairs(node.path) do onPath[n] = true end
			-- 2. leaves taken back, cheapest first, until the path fits
			local used = spec:CountAllocNodes()
			-- (a tree already over the count, e.g. with points from items, stays as over)
			local need = pathCost(node) - m_max(0, budget - used)
			local base = self:Score()
			local leaves = { }
			for _, leaf in ipairs(nodesById(spec.allocNodes)) do
				local holdsJewel = leaf.type == "Socket" and (spec.jewels[leaf.id] or 0) ~= 0
				local protected = self.protectedNodes and self.protectedNodes[leaf.id]
				if not leaf.ascendancyName and not holdsJewel and not protected and leaf.type ~= "ClassStart" and leaf.type ~= "Mastery"
					and leaf.type ~= "Keystone" and leaf.depends and #leaf.depends <= 1 and not onPath[leaf] then
					t_insert(leaves, { node = leaf, loss = base - self:Score({ removeNodes = { [leaf] = true } }) })
				end
			end
			t_sort(leaves, function(a, b)
				if a.loss ~= b.loss then return a.loss < b.loss end
				return a.node.id < b.node.id
			end)
			local freed = 0
			for _, leaf in ipairs(leaves) do
				if freed >= need then break end
				if leaf.node.alloc and leaf.node.depends and #leaf.node.depends <= 1 then
					spec:DeallocNode(leaf.node)
					freed = freed + 1
				end
			end
			local ok = freed >= need and node.path
			if ok then
				spec:AllocNode(node)
				self:Recalculate()
				-- (a mastery on the new notable's cluster, if a point is free)
				local after = self:FullScore()
				if self.options.debugTiming then ConPrintf("[swap] %s: gain alone %+.3f, cost %d, freed %d: %.3f -> %.3f", node.dn, target.gain, target.cost, freed, before, after) end
				if after > before + 0.005 and spec:CountAllocNodes() <= m_max(budget, used) then
					t_insert(kept, string.format("%s (%+.2f)", node.dn, after - before))
					current = self:Score()
				else
					ok = false
				end
			end
			if not ok then
				spec:RestoreUndoState(undo)
				spec:BuildAllDependsAndPaths()
				self:Recalculate()
			end
		end
	end
	if #kept > 0 then
		self:Note("Passives swapped for stronger ones out of reach: " .. table.concat(kept, ", "))
	end
	return #kept
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
	local before = self:FullScore()
	local undo = spec:CreateUndoState()
	local function notables()
		local list = { }
		for _, node in ipairs(nodesById(spec.allocNodes)) do
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
	-- (with swaps: worth their time on the finished build)
	self.swapSupports = true
	self:ChooseSupports(5)
	self.swapSupports = nil
	for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
	self:AutoConfigure()
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
	for _, node in ipairs(nodesById(spec.allocNodes)) do
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
		for _, node in ipairs(nodesById(spec.nodes)) do
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
		for _, node in ipairs(nodesById(spec.allocNodes)) do
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
		for _, node in ipairs(nodesById(spec.allocNodes)) do
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
		if not bestScore or score > bestScore + 1e-9 then bestTag, bestScore = tag, score end
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
			if not bestS or score > bestS + 1e-9 then best, bestS = baseName, score end
		end
		if best then self:Equip(makeBase(best), slotName) end
	end
	-- weapons: white bases first, then the top two get rares
	self:Recalculate()
	local scored = { }
	for _, option in ipairs(self.weaponOptions or { }) do
		self:EquipWeapons(option)
		-- (variants: up to 0.3 either way)
		t_insert(scored, { option = option, score = (self:FullScore()) + (self:Jitter("weapon" .. tostring(option.weapon1) .. tostring(option.weapon2)) - 1) * 2 })
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
	pgClass.Trace(string.format("rare items in %d threads: %d slots", workers, #usable))
	local dkjson = require "dkjson"
	local plain = { }
	for k, v in pairs(options) do
		if type(v) ~= "function" and k ~= "slots" then plain[k] = v end
	end
	local sc = self.scorer
	local scorerJob = {
		focusId = sc.focus and sc.focus.id, focusCustom = sc.focus,
		chargesPerSecond = sc.chargesPerSecond, ehpFloor = sc.ehpFloor, hitFloor = sc.hitFloor,
		bossTier = sc.bossTier, killsPerSecond = sc.killsPerSecond, flaskRealism = sc.flaskRealism,
		scenarioId = self.options.scenario and self.options.scenario.id,
		hitScale = sc.hitScale, resourceSustain = sc.resourceSustain, ignoreCosts = sc.ignoreCosts, ignoreAttributes = sc.ignoreAttributes,
		ignoreReservation = sc.ignoreReservation, useChecklist = sc.useChecklist,
		-- (the generator's own settings: the threads must score as it does)
		lens = sc.lens, lens2 = sc.lens2, avoidanceWeight = sc.avoidanceWeight, pastTarget = sc.pastTarget, fightWeight = sc.fightWeight,
		smoothBuffs = sc.smoothBuffs, reservationSlope = sc.reservationSlope, focusEhp = sc.focus and sc.focus.ehp,
		clearBoost = sc.clearBoost, clearBuffs = sc.clearBuffs,
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
	-- (launched from the app's frame, not from this coroutine: the app calls
	-- back the Lua thread that launched a background thread)
	main.onFrameFuncs["GeneratorRareThreads"] = function()
		main.onFrameFuncs["GeneratorRareThreads"] = nil
		pg:Run(jobs, {
			onDone = function(_, summary)
				for slotName, r in pairs(summary.slots or { }) do results[slotName] = r end
			end,
			onError = function(_, err) failed = failed or tostring(err) end,
			onAllDone = function() done = true end,
		})
	end
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

-- Options for making rares the way MakeRares does
function BuildGeneratorClass:RareOptions(withInfluences)
	local scorer, ratio = self.scorer, self.ratio
	local investment = self.options.investment
	return {
		quality = self.options.quality,
		levelOnly = true,
		keepResists = false, keepAttributes = false, keepLife = false,
		scoreFunc = function(output) return scorer:ScoreOutput(output, ratio) end,
		influences = withInfluences and investment and investment.influences or 0,
		elevated = withInfluences and investment and investment.elevated or false,
		eldritchTier = withInfluences and investment and investment.eldritchTier or 0,
		weaponSeeds = self.options.weaponSeeds, crafts = self.options.crafts, lazyFill = self.options.lazyFill,
		maxAffixes = investment and investment.rareAffixes,
		multiCraft = investment and investment.multiCraft,
		mappingBlend = self:MappingBlend(),
	}
end

-- Rares that can't exist (Eldritch implicits on an influenced item, from
-- older versions): the Eldritch implicits taken off
function BuildGeneratorClass:SanitizeRares()
	local fixed = 0
	for _, slot in ipairs(self.itemsTab.orderedSlots) do
		local item = self.itemsTab.items[slot.selItemId]
		if item and item.rarity == "RARE" then
			local influenced = item.shaper or item.elder or item.adjudicator or item.basilisk or item.crusader or item.eyrie
			if influenced then
				local changed = false
				for i = #(item.implicitModLines or { }), 1, -1 do
					local l = item.implicitModLines[i]
					if l.exarch or l.eater then t_remove(item.implicitModLines, i) changed = true end
				end
				if changed then item:BuildAndParseRaw() fixed = fixed + 1 end
			end
		end
	end
	if fixed > 0 then self:Recalculate() end
	return fixed
end

function BuildGeneratorClass:MakeRares(withInfluences)
	self:SanitizeRares()
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
		weaponSeeds = self.options.weaponSeeds, crafts = self.options.crafts, lazyFill = self.options.lazyFill,
		maxAffixes = investment and investment.rareAffixes,
		multiCraft = investment and investment.multiCraft,
		mappingBlend = self:MappingBlend(),
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
			if not bestScore or score > bestScore + 1e-9 then best, bestScore = option, score end
		end
		self:EquipWeapons(best)
		self:Recalculate()
	end
	-- two passes: the second one adapts to what the first one did elsewhere
	local passes = self.options.quick and 1 or 2
	for pass = 1, passes do
		self:Recalculate()
		options.onSlot = function(i, n) self:Inner(((pass - 1) + (i - 1) / n) / passes) end
		local report = self:RunRaresParallel(finder, options)
		-- (decision log: each rare made, its mods and what it measured)
		if self.decisions and report and report.slots then
			for slotName, slotReport in pairs(report.slots) do
				local r = slotReport.results and slotReport.results[1]
				if r and r.item then
					local mods = { }
					for _, l in ipairs(r.item.explicitModLines or { }) do t_insert(mods, l.line) end
					for _, l in ipairs(r.item.implicitModLines or { }) do t_insert(mods, "implicit: " .. l.line) end
					self:Decision("rare", r.item.baseName or slotName, r.deltaPct and r.deltaPct / 100 or nil, true, { slot = slotName, mods = mods })
				end
			end
		end
		options.onSlot = nil
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

-- Enkindling Orb enchantments on the utility flasks (more effect, duration,
-- charges...; the flask then gains no charges while it is up, which its uptime
-- counts): each flask keeps the best one, if the build is better with it.
-- Top players enchant their flasks, mostly with "increased effect" when
-- the flasks are permanent (Mageblood).
function BuildGeneratorClass:FlaskEnchantMove()
	local enchants = data.enchantments and data.enchantments["UtilityFlask"] and data.enchantments["UtilityFlask"]["ENKINDLING"]
	if not enchants then return end
	-- (Enkindling: the flask gains no charges while it's active - it can't be
	-- kept up, unless Mageblood keeps the magic utility flasks on for good)
	local permanent = false
	for _, slot in pairs(self.itemsTab.slots) do
		local item = self.itemsTab.items[slot.selItemId]
		if item and item.title == "Mageblood" then permanent = true end
	end
	if not permanent then return end
	local kept = { }
	for _, slotName in ipairs({ "Flask 1", "Flask 2", "Flask 3", "Flask 4", "Flask 5" }) do
		local slot = self.itemsTab.slots[slotName]
		local item = slot and self.itemsTab.items[slot.selItemId]
		if item and item.base and item.base.flask and not (item.base.flask.life or item.base.flask.mana)
			and item.rarity == "MAGIC" and #(item.enchantModLines or { }) == 0 then
			local before = self:FullScore()
			local best
			for _, enchant in ipairs(enchants) do
				local copy = new("Item"):Item(item:BuildRaw())
				for part in enchant:gmatch("[^/]+") do
					-- (the top of the range: enchanting again is cheap)
					local line = part:gsub("%((%d+)%-(%d+)%)", "%2")
					t_insert(copy.enchantModLines, { line = line, enchant = true })
				end
				copy:BuildAndParseRaw()
				-- (full score: the uptime is what changes)
				local equipped = self:Equip(copy, slotName)
				self:Recalculate()
				local score = self:FullScore()
				slot:SetSelItemId(item.id)
				self.itemsTab:DeleteItem(equipped, true)
				if not best or score > best.score + 1e-9 then best = { item = copy, score = score, label = enchant } end
				self:Tick()
			end
			self.itemsTab:PopulateSlots()
			self:Recalculate()
			if best and best.score > before + 0.003 then
				self:Equip(best.item, slotName)
				self.itemsTab:DeleteItem(item, true)
				self.itemsTab:PopulateSlots()
				self:Recalculate()
				local label = best.label:gsub("%((%d+)%-(%d+)%)", "%2"):gsub("/", ", ")
				t_insert(kept, string.format("%s: %s", item.name, label))
			end
		end
	end
	if #kept > 0 then self:Note("Flask enchantments (Enkindling Orb): " .. table.concat(kept, "; ")) end
end

-- Everything a late move can change (tree, gear, gem groups, configuration),
-- to put it back exactly when the move doesn't help
function BuildGeneratorClass:Snapshot()
	local snap = { tree = self.build.spec:CreateUndoState(), items = { }, active = { }, input = { }, groups = self:SaveGroups(),
		locked = { }, newItems = { } }
	for name, slot in pairs(self.itemsTab.slots) do snap.items[name] = slot.selItemId; snap.active[name] = slot.active end
	for k, v in pairs(self.build.configTab.input) do snap.input[k] = v end
	for k, v in pairs(self.lockedSlots or { }) do snap.locked[k] = v end
	snap.itemIds = { }
	for id in pairs(self.itemsTab.items) do snap.itemIds[id] = true end
	snap.decisionCount = self.decisions and #self.decisions
	return snap
end
function BuildGeneratorClass:Restore(snap)
	-- (choices made since the snapshot were undone: still training data, marked)
	if self.decisions and snap.decisionCount then
		for i = snap.decisionCount + 1, #self.decisions do self.decisions[i].undone = true end
	end
	for name, id in pairs(snap.items) do
		local slot = self.itemsTab.slots[name]
		if slot and slot.selItemId ~= id then slot:SetSelItemId(id) end
		if slot then slot.active = snap.active[name] end
	end
	-- items added since the snapshot
	local added = { }
	for id, item in pairs(self.itemsTab.items) do if not snap.itemIds[id] then t_insert(added, item) end end
	for _, item in ipairs(added) do self.itemsTab:DeleteItem(item, true) end
	local log = { }
	for i, l in ipairs(self.log) do log[i] = l end
	self:RestoreGroups(snap.groups)
	for i = #self.log, 1, -1 do self.log[i] = nil end
	for i, l in ipairs(log) do self.log[i] = l end
	local input = self.build.configTab.input
	for k in pairs(input) do input[k] = nil end
	for k, v in pairs(snap.input) do input[k] = v end
	self.build.configTab:BuildModList()
	self.lockedSlots = { }
	for k, v in pairs(snap.locked) do self.lockedSlots[k] = v end
	self.build.spec:RestoreUndoState(snap.tree)
	self.build.spec:BuildClusterJewelGraphs()
	self.build.spec:BuildAllDependsAndPaths()
	self.itemsTab:PopulateSlots()
	self:Recalculate()
end

-- Deterministic pseudo-random numbers for the search (a run gives the same
-- build every time; the variant changes the sequence)
function BuildGeneratorClass:Random(n)
	self.rngState = self.rngState or (12345 + 7919 * (self.options.variant or 1))
	self.rngState = (self.rngState * 1103515245 + 12345) % 2147483648
	return (self.rngState % n) + 1
end

-- Branches of the allocated tree: each leaf with the nodes leading to it up
-- to the last node with other branches (pruning a branch frees all its
-- points at once). Value per point: score lost without it.
function BuildGeneratorClass:TreeBranches()
	local spec = self.build.spec
	local current = self:Score()
	local function removable(node)
		local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
		return node.alloc and not node.ascendancyName and not holdsJewel and node.type ~= "ClassStart" and node.type ~= "Mastery"
			and not node.isProxy and not (self.protectedNodes and self.protectedNodes[node.id]) and not node.expansionJewel
	end
	local function allocatedNeighbours(node)
		local list = { }
		for _, other in ipairs(node.linked or { }) do
			if other.alloc and not other.ascendancyName then t_insert(list, other) end
		end
		return list
	end
	local branches = { }
	for _, node in ipairs(nodesById(spec.allocNodes)) do
		if removable(node) and #allocatedNeighbours(node) == 1 then
			-- walk back while the next node only continues this branch
			local branch, seen = { node }, { [node] = true }
			local prev, cur = node, allocatedNeighbours(node)[1]
			while cur and removable(cur) and #allocatedNeighbours(cur) == 2 and #branch < 12 do
				t_insert(branch, cur)
				seen[cur] = true
				local nextNode
				for _, n in ipairs(allocatedNeighbours(cur)) do if not seen[n] then nextNode = n end end
				prev, cur = cur, nextNode
			end
			local remove = { }
			for _, n in ipairs(branch) do remove[n] = true end
			local loss = current - self:Score({ removeNodes = remove })
			t_insert(branches, { nodes = branch, loss = loss, perPoint = loss / #branch })
		end
	end
	t_sort(branches, function(a, b)
		if a.perPoint ~= b.perPoint then return a.perPoint < b.perPoint end
		return a.nodes[1].id < b.nodes[1].id
	end)
	return branches
end

-- Large neighbourhood search on the finished build: part of it is undone
-- and rebuilt with everything else in place, and the result kept only if the
-- build is better. Each round takes one kind of rebuild:
--   * tree: weak branches pruned as a whole (by value per point, with a
--     random pick among the weakest), then the freed points re-spent where
--     they gain the most (multi-node swaps one-point greedy can't make);
--   * gear: one or two rare slots made again for the build as it is;
--   * links: two supports of the main link taken out and chosen again.
-- Starting from a good build, each round is cheap; it is how the search gets
-- out of the path the greedy steps took.
function BuildGeneratorClass:RepairSearch(rounds)
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local kinds = { "tree", "gear", "tree", "links", "tree", "gear" }
	local kept, gainTotal = { }, 0
	for round = 1, rounds or 8 do
		self:Inner((round - 1) / (rounds or 8))
		local kind = kinds[(round - 1) % #kinds + 1]
		-- (configured as the round will be, so the comparison is fair; later
		-- rounds start configured: the previous one ended with it)
		if round == 1 then self:AutoConfigure() end
		local before = self:FullScore()
		local snap = self:Snapshot()
		local savedLog = #self.log
		local label
		local ok, err = pcall(function()
			if kind == "tree" then
				local branches = self:TreeBranches()
				local weakest = m_min(#branches, 12)
				if weakest == 0 then return end
				-- prune some of the weakest branches, 10 to 20 points
				local pruned, points = { }, 0
				local target = 10 + self:Random(11) - 1
				for _ = 1, 12 do
					local b = branches[self:Random(weakest)]
					if b and not pruned[b] then
						pruned[b] = true
						for _, node in ipairs(b.nodes) do
							if node.alloc then self.build.spec:DeallocNode(node); points = points + 1 end
						end
					end
					if points >= target then break end
				end
				self.build.spec:BuildAllDependsAndPaths()
				self:Recalculate()
				-- (the pruned branches' leaves can't come straight back this round:
				-- the points go somewhere else, which is the point of the move)
				local savedForbidden = self.forbiddenNodes
				self.forbiddenNodes = { }
				for k, v in pairs(savedForbidden or { }) do self.forbiddenNodes[k] = v end
				for b in pairs(pruned) do self.forbiddenNodes[b.nodes[1].id] = true end
				if self.options.debugTiming then ConPrintf("[repair] pruned %d points: %.3f", points, (self:FullScore())) end
				self:AllocateTree(true)
				self.forbiddenNodes = savedForbidden
				if self.options.debugTiming then ConPrintf("[repair] regrown: %.3f (%d allocated, budget %d)", (self:FullScore()), self.build.spec:CountAllocNodes(), self:PointBudget()) end
				self:RefineTree(6)
				label = string.format("%d passive points re-spent", points)
			elseif kind == "gear" then
				local rares = { }
				for _, slotName in ipairs(finder:GetActiveSlots()) do
					local slot = self.itemsTab.slots[slotName]
					local item = slot and self.itemsTab.items[slot.selItemId]
					if item and item.rarity == "RARE" and not (self.lockedSlots and self.lockedSlots[slotName]) and not slotName:match("^Weapon") then
						t_insert(rares, slotName)
					end
				end
				if #rares == 0 then return end
				local chosen = { rares[self:Random(#rares)] }
				local second = rares[self:Random(#rares)]
				if second ~= chosen[1] then t_insert(chosen, second) end
				for _, slotName in ipairs(chosen) do
					local item = self.itemsTab.items[self.itemsTab.slots[slotName].selItemId]
					local influenced = false
					for _, info in ipairs(finder.rareGenerator.influenceList) do if item[info.key] then influenced = true end end
					self:Equip(makeBase(item.baseName), slotName)
					self.itemsTab:PopulateSlots()
					self:Recalculate()
					local opts = self:RareOptions(influenced)
					opts.slots = { slotName }
					finder:EquipAll(finder:RunRares(opts))
				end
				self:Recalculate()
				self:RefineTree(6)
				label = "rares made again: " .. table.concat(chosen, ", ")
			else
				local group = self.mainGroup
				if not group or #group.gemList < 3 then return end
				for _ = 1, 2 do
					local supports = { }
					for i, g in ipairs(group.gemList) do
						if i > 1 and g.gemId and data.gems[g.gemId].grantedEffect.support then t_insert(supports, i) end
					end
					if #supports == 0 then break end
					t_remove(group.gemList, supports[self:Random(#supports)])
				end
				self.build.skillsTab:ProcessSocketGroup(group)
				self:ChooseSupports(5)
				self:RefineTree(6)
				label = "main link supports chosen again"
			end
		end)
		if not ok then ConPrintf("Repair round failed: %s", tostring(err)) end
		self:AutoConfigure()
		local after = ok and label and self:FullScore() or before
		for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
		if self.options.debugTiming then ConPrintf("[repair] round %d (%s): %s: %.3f -> %.3f", round, kind, tostring(label), before, after) end
		if ok and label and after > before + 0.002 then
			t_insert(kept, label)
			gainTotal = gainTotal + after - before
		else
			self:Restore(snap)
			self:AutoConfigure()
		end
		self:Tick()
	end
	if #kept > 0 then
		self:Note(string.format("Rebuild-and-repair search: %d of %d rounds improved the build (%s), score %+.3f", #kept, rounds or 8, table.concat(kept, "; "), gainTotal))
	end
	return gainTotal
end

-- Hard requirements solved directly: when the finished build is below the
-- resistance cap or short of attributes, each rare's crafted mod is tried
-- against every bench craft of the same kind (prefix / suffix) that gives
-- resistances or attributes; the best swap is kept while the build gets
-- better. Cheaper than another round of rares, and exact.
function BuildGeneratorClass:RequirementsMove(rounds)
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local rg = finder.rareGenerator
	local quality = self.options.quality
	if not rg or not quality then return 0 end
	local total = 0
	for _ = 1, rounds or 3 do
		self:Recalculate()
		local o = self.build.calcsTab.mainOutput
		local missing = 0
		for _, elem in ipairs({ "Fire", "Cold", "Lightning" }) do missing = missing + m_max(0, o["Missing" .. elem .. "Resist"] or 0) end
		local short = false
		for _, attr in ipairs({ "Str", "Dex", "Int" }) do
			if (o["Req" .. attr] or 0) > (o[attr] or 0) then short = true end
		end
		if missing <= 0 and not short then break end
		local before = self:FullScore()
		local current = self:Score()
		local best
		for _, slot in ipairs(self.itemsTab.orderedSlots) do
			local item = self.itemsTab.items[slot.selItemId]
			if item and item.rarity == "RARE" and not slot.nodeId and item.type ~= "Jewel" and not (item.base and item.base.flask) then
				local craftedLines = { }
				for _, modLine in ipairs(item.explicitModLines or { }) do
					if modLine.crafted then t_insert(craftedLines, modLine.line) end
				end
				if #craftedLines > 0 then
					local candidates = rg:GetCraftCandidates(item, quality)
					local kind
					for _, c in ipairs(candidates) do
						if c.lines[1] == craftedLines[1] then kind = c.type end
					end
					for _, c in ipairs(candidates) do
						local text = table.concat(c.lines, " ")
						if (not kind or c.type == kind) and c.lines[1] ~= craftedLines[1]
							and (text:match("Resistance") or text:match("to Strength") or text:match("to Dexterity") or text:match("to Intelligence") or text:match("to all Attributes")) then
							local raw = item:BuildRaw()
							local copy = new("Item"):Item(raw)
							for i = #copy.explicitModLines, 1, -1 do
								if copy.explicitModLines[i].crafted then table.remove(copy.explicitModLines, i) end
							end
							for _, line in ipairs(c.lines) do t_insert(copy.explicitModLines, { line = line, crafted = true }) end
							copy:BuildAndParseRaw()
							local score = self:Score({ repSlotName = slot.slotName, repItem = copy })
							if score > current + 0.002 and (not best or score > best.score + 1e-9) then
								best = { slot = slot, item = copy, old = item, score = score, label = c.label, was = craftedLines[1] }
							end
						end
					end
				end
			end
		end
		if not best then break end
		local previous = best.slot.selItemId
		local newItem = self:Equip(best.item, best.slot.slotName)
		self.itemsTab:PopulateSlots()
		local after = self:FullScore()
		if after > before + 0.002 then
			total = total + after - before
			self:Note(string.format("Requirement fixed with a bench craft on %s: %s instead of %s, score %+.3f", best.slot.slotName, best.label, tostring(best.was), after - before))
		else
			best.slot:SetSelItemId(previous)
			self.itemsTab:DeleteItem(newItem, true)
			self.itemsTab:PopulateSlots()
			self:Recalculate()
			break
		end
	end
	return total
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
	for _, node in ipairs(nodesById(spec.nodes)) do
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

-- Allocated jewel sockets left empty (a jewel taken out by a later step, a
-- socket the tree passed through): each gets the best rare jewel for it; one
-- that can't take a jewel worth having (a cluster jewel's own socket) is
-- given back if nothing depends on it
function BuildGeneratorClass:FillEmptySockets()
	local spec = self.build.spec
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local generator = finder.rareGenerator
	self:Recalculate()
	local empty = { }
	for _, node in ipairs(nodesById(spec.allocNodes)) do
		if node.type == "Socket" and (spec.jewels[node.id] or 0) == 0 and self.itemsTab.slots["Jewel " .. node.id] then t_insert(empty, node) end
	end
	if #empty == 0 then return 0 end
	local scorer, ratio = self.scorer, self.ratio
	local measure = function(output) return scorer:ScoreOutput(output, ratio) end
	local filled, freed = 0, 0
	local jewelText
	for _, node in ipairs(empty) do
		-- (the sockets a Large Cluster Jewel adds take cluster jewels)
		local clusterSocket = node.expansionJewel and node.expansionJewel.parent ~= nil
		local done = false
		if not clusterSocket then
			self:Recalculate()
			local baseOutput = self.calcFunc({ })
			local ctx = {
				calcFunc = self.calcFunc, baseOutput = baseOutput, basePower = measure(baseOutput),
				measure = measure, tick = function() self:Tick() end,
				opts = { quality = self.options.quality, levelOnly = true, keepResists = false, keepAttributes = false, keepLife = false },
			}
			local best
			for _, baseName in ipairs({ "Crimson Jewel", "Viridian Jewel", "Cobalt Jewel" }) do
				if data.itemBases[baseName] then
					local blank = new("Item"):Item("Rarity: NORMAL\n" .. baseName)
					blank:BuildModList()
					local result = generator:GenerateForSlotWith("Jewel " .. node.id, blank, ctx, nil)
					if result and (not best or result.power > best.power) then best = result end
				end
			end
			if best then
				self:Equip(best.item, "Jewel " .. node.id)
				self.itemsTab:PopulateSlots()
				filled = filled + 1
				done = true
				local mods = { }
				for _, l in ipairs(best.item.explicitModLines) do t_insert(mods, l.line) end
				jewelText = table.concat(mods, ", ")
			end
		end
		if not done and node.alloc and not node.ascendancyName and node.depends and #node.depends <= 1 then
			spec:DeallocNode(node)
			freed = freed + 1
		end
	end
	spec:BuildAllDependsAndPaths()
	self:Recalculate()
	if filled > 0 then self:Note(string.format("Empty jewel sockets filled: %d (%s)", filled, jewelText)) end
	if freed > 0 then self:Note(string.format("Empty jewel sockets given back: %d point%s", freed, freed == 1 and "" or "s")) end
	return filled + freed
end

-- Frees the least useful passives and lets the allocator spend them again
-- (after something changed what passives are worth, e.g. a timeless jewel)
function BuildGeneratorClass:RefineTree(count)
	local spec = self.build.spec
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
		for _, node in ipairs(nodesById(spec.allocNodes)) do
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
	if self.options.notableSwaps then self:SwapForNotables(10) end
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
			local before = self:FullScore()
			-- 1. any passive worth taking if the ailment were up?
			input[pair.var] = true
			self:Recalculate()
			local current = self:Score()
			local bestRatio = 0
			for _, node in ipairs(nodesById(spec.nodes)) do
				if not node.alloc and node.path and #node.path <= 8 and not node.ascendancyName and text(node):find(pair.target, 1, true) then
					local pathSet = { }
					for _, n in ipairs(node.path) do pathSet[n] = true end
					bestRatio = m_max(bestRatio, (self:Score({ addNodes = pathSet }) - current) / #node.path)
				end
			end
			-- 2. the cheapest passive that adds a chance to inflict it
			local source
			if bestRatio > 0.002 then
				for _, node in ipairs(nodesById(spec.nodes)) do
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
	local before = self:FullScore()
	local finder = new("TimelessJewelFinder"):TimelessJewelFinder({
		build = self.build,
		score = function(override) return (self:Score(override)) end,
		fullScore = function() return (self:FullScore()) end,
		quickScore = function() self:Recalculate() return (self:Score()) end, noQuick = self.options.jewelQuick == false,
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
		quickScore = function() self:Recalculate() return (self:Score()) end, noQuick = self.options.jewelQuick == false,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	local prices = GetPriceSource()
	local kinds = { "forbidden" }
	-- (Watcher's Eye and Split Personality are scarce: from High investment)
	if prices.Available(investment, "Watcher's Eye") then t_insert(kinds, "watcher") end
	-- Split Personality (limited to 2): stronger the further its socket
	-- is from the class start, so long paths and cluster sockets are tried
	if prices.Available(investment, "Split Personality") then
		t_insert(kinds, "split")
		t_insert(kinds, "split")
	end
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
		if not prices.Available(investment, title) then return false end
		local price = prices.uniques[title]
		if price then return not investment.maxUnique or price <= investment.maxUnique end
		return investment.unknownAllowed ~= false
	end
	for _, kind in ipairs(kinds) do
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

-- Thread of Hope, Intuitive Leap, Impossible Escape: passives in their
-- radius allocated without a path (Classes/RadiusJewelFinder)
function BuildGeneratorClass:ChooseRadiusJewels()
	local investment = self.options.investment or { }
	if investment.timeless == false then return end
	local prices = GetPriceSource()
	local function allowed(title)
		if not prices.Available(investment, title) then return false end
		local price = prices.uniques[title]
		if price then return not investment.maxUnique or price <= investment.maxUnique end
		return investment.unknownAllowed ~= false
	end
	local finder = new("RadiusJewelFinder"):RadiusJewelFinder(self)
	local ok, result = pcall(function() return finder:Run(allowed, investment.corruptedSupports, self.options.radiusJewelTries or 3) end)
	if not ok then ConPrintf("Radius jewels failed: %s", tostring(result)) return end
	if result then
		local price = prices.uniques[result.title]
		self:Note(string.format("%s: %d passives allocated through it without a path%s, score %+.3f (%s)", result.label, #result.nodes,
			#result.names > 0 and (" (" .. table.concat(result.names, ", ") .. ")") or "", result.gain, prices.FormatPrice(price)))
		self.costs = self.costs or { }
		t_insert(self.costs, price or false)
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
		quickScore = function() self:Recalculate() return (self:Score()) end, noQuick = self.options.jewelQuick == false,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	-- socket the jewel, rebuild the tree around it; false (and undone) if the
	-- build isn't better once the points come from elsewhere
	local function place(result, base)
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
			return false
		end
		self:Note(string.format("%s (%d passive points; a crafted / bought rare, price varies)", result.label, points))
		return true
	end
	for _ = 1, maxJewels or 2 do
		local base = self:FullScore()
		gen.values = { } -- values change once a jewel is in
		local result = gen:Best(base, { maxPath = 6 })
		if not result or result.gain <= 0.01 or not place(result, base) then break end
	end
	-- Medium or Small ones in the sockets the Large ones add (whichever is
	-- better for the points: a Small one is 2 points for its notable)
	if self.options.innerClusters == false then return end
	local tried = { }
	for _ = 1, 4 do
		local socket
		for _, s in ipairs(gen:Sockets(12, true)) do
			if not tried[s.node.id] then socket = s break end
		end
		if not socket then break end
		tried[socket.node.id] = true
		local base = self:FullScore()
		local best
		for _, jewelName in ipairs({ "Medium Cluster Jewel", "Small Cluster Jewel" }) do
			gen.values = { }
			local result = gen:Best(base, { jewel = jewelName, socket = socket })
			if result and (not best or result.score > best.score + 1e-9) then best = result end
		end
		if best and best.gain > 0.01 then
			local kept = place(best, base)
			if self.options.debugTiming then ConPrintf("[clusters] %s: estimated %+.3f, %s (%.3f -> %.3f)", best.label, best.gain, kept and "kept" or "dropped", base, self:FullScore()) end
		end
	end
end

-- The uniques the player forces (the window's "Uniques..." list): each in
-- the slot of its kind where it scores best, kept there (the rest of the
-- build is made around it). Jewels go in the best free jewel socket in reach,
-- flasks in the flask slot that loses least.
function BuildGeneratorClass:ForceUniques()
	local forced = self.options.forcedUniques
	if not forced or #forced == 0 then return end
	local byTitle = { }
	for _, item in pairs(main.uniqueDB.list) do byTitle[item.title or item.name] = byTitle[item.title or item.name] or item end
	self.lockedSlots = self.lockedSlots or { }
	local placed = { }
	for _, title in ipairs(forced) do
		local item = byTitle[title]
		if item then
			self:Recalculate()
			local best
			if item.type == "Jewel" then
				local spec = self.build.spec
				for _, node in ipairs(nodesById(spec.nodes)) do
					local slotName = "Jewel " .. node.id
					if node.type == "Socket" and not node.expansionJewel and self.itemsTab.slots[slotName] and (spec.jewels[node.id] or 0) == 0
						and (node.alloc or (node.path and #node.path <= 6)) and not self.lockedSlots[slotName] then
						local cost = node.alloc and 0 or #node.path
						if not best or cost < best.cost then best = { slot = slotName, node = node, cost = cost } end
					end
				end
				if best and not best.node.alloc then self.build.spec:AllocNode(best.node) end
			else
				for _, slotName in ipairs(new("BestItemFinder"):BestItemFinder(self.itemsTab):GetActiveSlots()) do
					if not self.lockedSlots[slotName] and self.itemsTab:IsItemValidForSlot(item, slotName) then
						local score = self:Score({ repSlotName = slotName, repItem = item })
						if not best or score > best.score then best = { slot = slotName, score = score } end
					end
				end
			end
			if best then
				new("BestItemFinder"):BestItemFinder(self.itemsTab):Equip(item, best.slot, true)
				self.itemsTab:PopulateSlots()
				self.lockedSlots[best.slot] = true
				if best.slot:match("^Weapon") then self.weaponFinalists = nil end
				t_insert(placed, string.format("%s (%s)", title, best.slot))
				local price = GetPriceSource():UniquePrice(item)
				self.costs = self.costs or { }
				t_insert(self.costs, price or false)
			else
				t_insert(placed, title .. " (no free slot for it)")
			end
		end
	end
	self:FitSockets()
	self:Recalculate()
	if #placed > 0 then self:Note("Forced uniques: " .. table.concat(placed, ", ")) end
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
	-- (a set with a piece that counts as maximum charges: the pieces that lose
	-- those charges are candidates too - kept only if that piece is taken)
	local enables = { }
	for _, item in ipairs(candidates) do
		for _, modLine in ipairs(item.explicitModLines or { }) do
			local kind = (modLine.line or ""):match("^Count as having maximum number of (%a+) Charges")
			if kind then enables[kind] = true end
		end
	end
	if next(enables) then filter.assumeMaxCharges = enables end
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
		local singles = { }
		for _, item in ipairs(allowed) do
			if not used[item] then
				for _, slotName in ipairs(slots) do
					if not self.lockedSlots[slotName] and self.itemsTab:IsItemValidForSlot(item, slotName) then
						local score = self:Score({ repSlotName = slotName, repItem = item })
						t_insert(singles, { item = item, slot = slotName, score = score })
						if not best or score > best.score + 1e-9 then best = { item = item, slot = slotName, score = score } end
					end
				end
			end
		end
		-- two steps ahead: a piece worth little alone can unlock the others
		-- (Ralakesh's Impatience counts as maximum power charges: Tulfall's and
		-- Malachai's Loop's "lose all at maximum" stop mattering). The pair
		-- that scores best together picks this round's piece.
		if archetype.lookahead ~= false and #singles > 1 then
			t_sort(singles, function(a, b) return a.score > b.score end)
			local firsts = { }
			for i = 1, m_min(5, #singles) do t_insert(firsts, singles[i]) end
			-- (and the enablers, whatever they score alone)
			for _, sgl in ipairs(singles) do
				for _, modLine in ipairs(sgl.item.explicitModLines or { }) do
					local l = modLine.line or ""
					if l:match("^Count as having maximum number of") or l:match("is equal to your Maximum") then t_insert(firsts, sgl) break end
				end
			end
			local bestPair
			for _, a in ipairs(firsts) do
				for i = 1, m_min(12, #singles) do
					local b = singles[i]
					if b.item ~= a.item and b.slot ~= a.slot and not (a.slot:match("^Ring") and b.slot:match("^Ring") and a.item.title == b.item.title) then
						local score = self:Score({ repItems = { [a.slot] = a.item, [b.slot] = b.item } })
						if not bestPair or score > bestPair.score + 1e-9 then bestPair = { first = a, score = score } end
					end
				end
			end
			-- (the pair's first piece, if the pair beats the best single by a margin)
			if bestPair and bestPair.score > best.score + 0.01 then
				best = bestPair.first
			end
		end
		-- a set whose pieces lose charges starts with the piece that counts them
		-- at maximum (without it the others aren't taken at all)
		if round == 1 and filter.assumeMaxCharges then
			local enabler
			for _, sgl in ipairs(singles) do
				for _, modLine in ipairs(sgl.item.explicitModLines or { }) do
					if (modLine.line or ""):match("^Count as having maximum number of") and (not enabler or sgl.score > enabler.score) then enabler = sgl end
				end
			end
			if enabler then best = enabler end
		end
		-- (a stacking set - archetype.setTolerance - is committed to as a whole:
		-- its pieces pay off once the tree and gear stack the stat, which the
		-- rest of the generation does with the stat lens; the archetype scan
		-- compares the finished builds, so a set that doesn't pay off loses there)
		local tolerance = round == 1 and 1.0 or (archetype.setTolerance or -0.003)
		if self.options.debugTiming and best then ConPrintf("[archetype uniques] round %d: best %s in %s %.3f (current %.3f)", round, best.item.title or "?", best.slot, best.score, current) end
		if not best or best.score < current - tolerance then break end
		used[best.item] = true
		finder:Equip(best.item, best.slot, true)
		self.itemsTab:PopulateSlots()
		self.lockedSlots[best.slot] = true
		-- (fewer sockets than the gems there, e.g. a body armour without
		-- sockets: the main skill moves to a 4-link, setups packed again)
		self:FitSockets()
		if best.slot:match("^Weapon") then self.weaponFinalists = nil end
		local price = GetPriceSource():UniquePrice(best.item)
		t_insert(kept, string.format("%s in %s (%s)", best.item.title or best.item.name, best.slot, GetPriceSource().FormatPrice(price)))
		self.costs = self.costs or { }
		t_insert(self.costs, price or false)
	end
	self:Recalculate()
	-- (a piece that loses charges, kept without the piece that counts them at maximum: out again)
	if filter.assumeMaxCharges then
		local check = { obtainableOnly = true }
		for slotName in pairs(self.lockedSlots) do
			local slot = self.itemsTab.slots[slotName]
			local item = slot and self.itemsTab.items[slot.selItemId]
			if item and item.rarity == "UNIQUE" and not finder:IsItemAllowed(item, check) then
				slot:SetSelItemId(0)
				self.lockedSlots[slotName] = nil
				for i = #kept, 1, -1 do if kept[i]:find(item.title, 1, true) == 1 then table.remove(kept, i) end end
				self.itemsTab:PopulateSlots()
				self:Recalculate()
			end
		end
	end
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
		quickScore = function() self:Recalculate() return (self:Score()) end, noQuick = self.options.jewelQuick == false,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	for _, title in ipairs(archetype.jewels) do
		if not GetPriceSource().Available(self.options.investment, title) then goto nextJewel end
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
		::nextJewel::
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
	self:EvaluatePackages(moves, rounds, function(best, gain)
		return string.format("Package from top players (%d%% of them): %s, with passives and supports adapted: score %+.3f",
			math.floor(best.share * 100 + 0.5), best.label, gain)
	end)
end

-- Ideas of the other archetypes tried on the finished build: each one's
-- keystone and best uniques as a package, applied for real and adapted like
-- the top players' packages (a crossover between ideas: the best build with
-- the commitment another idea is built around)
function BuildGeneratorClass:CrossIdeasMove(rounds)
	if not self.mainGem then return end
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local current = self.options.archetype and self.options.archetype.id
	local function equipped(title)
		for _, slot in pairs(self.itemsTab.slots) do
			local item = self.itemsTab.items[slot.selItemId]
			if item and item.title == title then return true end
		end
		return false
	end
	local moves = { }
	for _, a in ipairs(archetypes.ForSkill(self.mainGem, self.options.meta)) do
		if a.id ~= current and not a.playstyle and not a.trigger then
			local move = { label = a.label, uniques = { }, share = 0, idea = a }
			for _, item in ipairs(archetypes.UniqueCandidates(a)) do
				if #move.uniques < 2 and finder:IsItemAllowed(item, filter) and not equipped(item.title or item.name) then
					t_insert(move.uniques, item)
				end
			end
			for _, name in ipairs(a.keystones or { }) do
				local node = archetypes.NodeByName(self.build.spec, name)
				if node and not node.alloc and node.path and not (self.forbiddenNodes and self.forbiddenNodes[node.id]) then move.keystone = node break end
			end
			if #move.uniques > 0 or move.keystone then t_insert(moves, move) end
		end
	end
	if self.options.debugTiming then ConPrintf("[cross] %d ideas", #moves) end
	if #moves == 0 then return end
	self:EvaluatePackages(moves, rounds, function(best, gain)
		return string.format("Idea from another archetype added: %s (%s), with passives and supports adapted: score %+.3f",
			best.idea.label, table.concat((function()
				local names = { }
				for _, p in ipairs(best.placement) do t_insert(names, p.item.title or p.item.name) end
				if best.keystone then t_insert(names, best.keystone.dn) end
				return names
			end)(), ", "), gain)
	end, { threshold = 1.0, tries = 3 })
end

-- Damage behind conditions (Classes/ConditionAudit): the conditions the
-- build's modifiers use that are off, measured; for the biggest ones, the
-- uniques and passives that grant them are tried (a unique in the slot where
-- it scores best, a passive with its path), and the best kept when the build
-- is better. Repeated while it finds something.
function BuildGeneratorClass:ConditionEnablerMove(rounds)
	local audit = new("ConditionAudit"):ConditionAudit(self)
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local slots = finder:GetActiveSlots()
	local total = 0
	local tried = { }
	for _ = 1, rounds or 2 do
		local gains = audit:Gains(0.05)
		self.conditionGains = gains
		if #gains == 0 then break end
		self:Recalculate()
		local current = self:Score()
		local best
		for i = 1, math.min(5, #gains) do
			local g = gains[i]
			if not tried[g.var] then
				tried[g.var] = true
				for _, item in ipairs(audit:UniqueSources(g.condition, g.enemy)) do
					if finder:IsItemAllowed(item, filter) then
						for _, slotName in ipairs(slots) do
							if not (self.lockedSlots and self.lockedSlots[slotName]) and self.itemsTab:IsItemValidForSlot(item, slotName) then
								local score = self:Score({ repSlotName = slotName, repItem = item }) - self:PriceCost(item)
								if score > current + 0.02 and (not best or score > best.score) then
									best = { item = item, slot = slotName, score = score, g = g }
								end
							end
						end
					end
				end
				for _, node in ipairs(audit:PassiveSources(g.condition, g.enemy, 8)) do
					local add = { }
					for _, n in ipairs(node.path) do add[n] = true end
					local score = self:Score({ addNodes = add }) - #node.path * 0.006
					if score > current + 0.02 and (not best or score > best.score) then
						best = { node = node, score = score, g = g }
					end
				end
				self:Tick()
			end
		end
		if not best then break end
		local before = self:FullScore()
		local snap = self:Snapshot()
		if best.item then
			finder:Equip(best.item, best.slot, true)
			self.itemsTab:PopulateSlots()
			self:FitSockets()
		else
			self.build.spec:AllocNode(best.node)
			self:Recalculate()
			self:TrimTree()
		end
		self:Recalculate()
		local after = self:FullScore()
		if after > before + 0.005 then
			total = total + after - before
			self.lockedSlots = self.lockedSlots or { }
			if best.slot then self.lockedSlots[best.slot] = true end
			self:Note(string.format("Condition found worth scaling: \"%s\" (switched on it gains %+.2f); kept up by %s, score %+.3f",
				best.g.label, best.g.gain, best.item and string.format("%s in %s", best.item.title or best.item.name, best.slot) or ("the passive " .. best.node.dn), after - before))
		else
			self:Restore(snap)
		end
	end
	return total
end

-- Corrupted implicits (Endgame and Mirror budgets: a Vaal Orb on a copy of
-- the item): "+1 to Level of Socketed Gems" on the main skill's item, "+2 to
-- Level of Socketed Projectile Gems", "+1 to Maximum Frenzy Charges" on
-- boots... Each gear item not already corrupted gets the corrupted implicit
-- that helps most, if any helps enough.
function BuildGeneratorClass:CorruptionMove()
	local investment = self.options.investment or { }
	if not investment.corruptedSupports then return 0 end
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local total = 0
	local notes = { }
	for _, slotName in ipairs(finder:GetActiveSlots()) do
		local slot = self.itemsTab.slots[slotName]
		local item = slot and self.itemsTab.items[slot.selItemId]
		if item and not item.corrupted and (item.rarity == "RARE" or item.rarity == "UNIQUE") and item.base and item.base.tags
			and not slotName:match("^Flask") and not slotName:match("^Jewel") then
			self:Recalculate()
			local current = self:Score()
			local best
			for modId, mod in pairs(data.itemMods.Corrupted or { }) do
				if modId:match("^V2") and mod[1] then
					local weight = 0
					for i, key in ipairs(mod.weightKey or { }) do
						if item.base.tags[key] then weight = mod.weightVal[i] or 0 break end
					end
					if weight > 0 then
						local copy = new("Item"):Item(item:BuildRaw())
						copy.implicitModLines = { }
						for _, line in ipairs(mod) do t_insert(copy.implicitModLines, { line = itemLib.applyRange(line, 1, 1, 1), modTags = mod.modTags or { } }) end
						copy.corrupted = true
						copy:BuildAndParseRaw()
						local score = self:Score({ repSlotName = slotName, repItem = copy })
						if score > current + 0.02 and (not best or score > best.score) then best = { item = copy, score = score, text = table.concat(mod, ", ") } end
					end
				end
			end
			if best then
				self:Equip(best.item, slotName)
				self.itemsTab:PopulateSlots()
				total = total + best.score - current
				t_insert(notes, string.format("%s: %s (%+.3f)", slotName, itemLib.applyRange(best.text, 1, 1, 1), best.score - current))
			end
			self:Tick()
		end
	end
	self:Recalculate()
	if #notes > 0 then self:Note("Corrupted implicits (a Vaal Orb on a spare copy: it can also brick it): " .. table.concat(notes, "; ")) end
	return total
end

------------------------------------------------------------------------------
-- A second skill for bosses
------------------------------------------------------------------------------

local damageTags = { "fire", "cold", "lightning", "physical", "chaos" }

-- Builds made for clearing (Clearing maps, Clearing + bossing): the main skill
-- is chosen for packs, and another skill sharing its scaling (same damage
-- types, attack or spell) can do far more to one target. Each such skill is
-- measured on a pinnacle boss alone in a 4-link of the helmet, gloves or
-- boots, the best few with their own supports; the best is linked there (or
-- only suggested, if what it displaces is worth more) when it beats the main
-- skill on a boss by 30% or more.
function BuildGeneratorClass:BossSkillMove()
	local scenario = self.options.configScenario
	if not scenario or (scenario.boss and not scenario.clear) then return 0 end
	local mainGem, mainGroup = self.mainGem, self.mainGroup
	if not mainGem or not mainGroup then return 0 end
	local skillsTab = self.build.skillsTab
	local setup = new("GemSetup"):GemSetup(self)
	-- the 4-link with the fewest utility gems
	local slotName, fewest
	for _, name in ipairs({ "Gloves", "Helmet", "Boots" }) do
		if setup:SlotSockets(name) >= 4 and mainGroup.slot ~= name then
			local gems = 0
			for _, g in ipairs(skillsTab.socketGroupList) do if g.slot == name then gems = gems + #g.gemList end end
			if not fewest or gems < fewest then slotName, fewest = name, gems end
		end
	end
	if self.options.debugTiming then
		for _, name in ipairs({ "Gloves", "Helmet", "Boots" }) do ConPrintf("[boss skill] %s: %d sockets", name, setup:SlotSockets(name)) end
	end
	if not slotName then return 0 end
	local mainTags = mainGem.tags or { }
	local candidates = { }
	for _, entry in ipairs(self.SkillList()) do
		local gem = data.gems[entry.gemId]
		local tags = gem.tags or { }
		-- (same damage types; a main skill without any - most physical attacks -
		-- takes the same kind of skill: melee for melee, bow for bow)
		local shares, mainHas = false, false
		for _, t in ipairs(damageTags) do
			if mainTags[t] then mainHas = true end
			if tags[t] and mainTags[t] then shares = true end
		end
		if not mainHas then
			shares = (mainTags.melee and tags.melee) or (mainTags.bow and tags.bow) or (mainTags.spell and tags.spell) or false
		end
		local sameKind = (tags.attack and mainTags.attack) or (tags.spell and mainTags.spell)
		if shares and sameKind and gem ~= mainGem and self.GemFamily(gem) ~= self.GemFamily(mainGem)
			and (not tags.minion or mainTags.minion) then
			t_insert(candidates, entry.gemId)
		end
	end
	if self.options.debugTiming then ConPrintf("[boss skill] %s, %d candidates", slotName, #candidates) end
	if #candidates == 0 then return 0 end
	local before = self:FullScore()
	local snap = self:Snapshot()
	local savedLog = #self.log
	local savedMainGem, savedMainGroup, savedLimit, savedMainIndex = self.mainGem, self.mainGroup, self.mainLinkLimit, self.build.mainSocketGroup
	local bossScenario
	for _, sc in ipairs(new("AutoConfig"):AutoConfig(self.build).scenarioList) do if sc.id == "BOSS" then bossScenario = sc end end
	local function dpsNow()
		self:Recalculate()
		return self.scorer:GetDPS(self.build.calcsTab.mainOutput)
	end
	local best
	local ok, err = pcall(function()
		self.options.configScenario = bossScenario
		self:AutoConfigure()
		local mainDps = dpsNow()
		-- the slot's own setups out, a group for the candidates in
		local list = skillsTab.socketGroupList
		for i = #list, 1, -1 do if list[i].slot == slotName then t_remove(list, i) end end
		local group = { label = "Boss skill (generated)", enabled = true, slot = slotName, gemList = { } }
		t_insert(list, group)
		self.build.mainSocketGroup = #list
		local function try(gemId)
			local gem = data.gems[gemId]
			group.gemList = { { level = self:GemLevel(gem, true), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId } }
			local part = self.RealisticSkillPart(gem.grantedEffect)
			if part then group.gemList[1].skillPart, group.gemList[1].skillPartCalcs = part, part end
			skillsTab:ProcessSocketGroup(group)
			return dpsNow()
		end
		-- 1. bare, to keep the best few
		local ranked = { }
		for _, gemId in ipairs(candidates) do
			local dps = try(gemId)
			if dps > 0 then t_insert(ranked, { gemId = gemId, dps = dps }) end
			self:Tick()
		end
		t_sort(ranked, function(a, b) return a.dps > b.dps end)
		-- 2. with their own three supports
		self.mainGroup, self.mainLinkLimit = group, 3
		for i = 1, m_min(4, #ranked) do
			self.mainGem = data.gems[ranked[i].gemId]
			try(ranked[i].gemId)
			self:ChooseSupports(3)
			local dps = dpsNow()
			if not best or dps > best.dps then
				local gems = { }
				for _, g in ipairs(group.gemList) do t_insert(gems, g) end
				best = { gemId = ranked[i].gemId, dps = dps, gems = gems }
			end
		end
		if best then best.mainDps = mainDps end
	end)
	if not ok then ConPrintf("Boss skill search failed: %s", tostring(err)) end
	self.mainGem, self.mainGroup, self.mainLinkLimit = savedMainGem, savedMainGroup, savedLimit
	self.options.configScenario = scenario
	for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
	self:Restore(snap)
	self.build.mainSocketGroup = savedMainIndex
	self:AutoConfigure()
	if self.options.debugTiming and best then ConPrintf("[boss skill] best %s %.0f vs main %.0f", data.gems[best.gemId].name, best.dps, best.mainDps) end
	if not best or best.dps < best.mainDps * 1.3 then return 0 end
	-- linked for real: the slot's setups give way, kept if that costs little
	local names = { }
	for i, g in ipairs(best.gems) do if i > 1 then t_insert(names, data.gems[g.gemId].name) end end
	local text = string.format("%s in the %s (with %s): %s DPS on a pinnacle boss, %.1fx the main skill's %s",
		data.gems[best.gemId].name, slotName, #names > 0 and table.concat(names, ", ") or "no supports", formatNumSep(math.floor(best.dps)), best.dps / m_max(best.mainDps, 1), formatNumSep(math.floor(best.mainDps)))
	local list = skillsTab.socketGroupList
	local displaced = { }
	for i = #list, 1, -1 do
		if list[i].slot == slotName then
			for _, g in ipairs(list[i].gemList) do if g.gemId then t_insert(displaced, data.gems[g.gemId].name) end end
			t_remove(list, i)
		end
	end
	local group = { label = "Boss skill (generated)", enabled = true, slot = slotName, gemList = best.gems }
	t_insert(list, group)
	for i, g in ipairs(list) do if g == savedMainGroup then self.build.mainSocketGroup = i end end
	skillsTab:ProcessSocketGroup(group)
	local after = self:FullScore()
	if after < before - 0.1 then
		self:Restore(snap)
		self.build.mainSocketGroup = savedMainIndex
		self:AutoConfigure()
		self:Note("Boss skill (suggestion, not linked: the setups it would displace are worth more): " .. text)
		return 0
	end
	self:Note("Boss skill, for when the main skill is too slow on one target: " .. text .. (#displaced > 0 and (" (replaces " .. table.concat(displaced, ", ") .. ")") or ""))
	return after - before
end

------------------------------------------------------------------------------
-- Stat target planning for stacking archetypes
------------------------------------------------------------------------------

local lensLines = {
	Int = "+%d to Intelligence", Str = "+%d to Strength", Dex = "+%d to Dexterity",
	Life = "+%d to maximum Life", EnergyShield = "+%d to maximum Energy Shield", Mana = "+%d to maximum Mana",
}

-- A stacking build's stat is worth more the more of it there is (damage per
-- 10 Intelligence on top of increased Intelligence...), so its value now
-- undersells it: gear and passives would never start stacking. The plan
-- measures what doubling the stat is worth (the uniques equipped, the lens
-- off) against what the first steps are worth, and gives the lens the
-- difference: the build is steered towards the target, not the next point.
function BuildGeneratorClass:PlanStatTarget(label)
	local lens = self.scorer.lens
	if not lens or not lensLines[lens.stat] then return end
	local savedLens, savedLens2 = self.scorer.lens, self.scorer.lens2
	self.scorer.lens, self.scorer.lens2 = nil, nil
	self:Recalculate()
	local output = self.build.calcsTab.mainOutput
	local current = m_max(output[lens.stat] or 0, lens.base or 100)
	local tree = self.build.spec.tree
	local probeId = -950000
	local function probe(amount)
		probeId = probeId - 1
		local node = { id = probeId, type = "Normal", name = "stat probe", dn = "stat probe", sd = { string.format(lensLines[lens.stat], m_max(1, math.floor(amount + 0.5))) } }
		tree:ProcessStats(node)
		local override = { addNodes = { [node] = true } }
		local out = self.calcFunc(override)
		return self:Score(override), (out[lens.stat] or 0)
	end
	local base = self:Score()
	-- (flat stat is multiplied by the build's increases: scaled to reach the target)
	local _, outSmall = probe(100)
	local ratio = m_max(0.2, (outSmall - (output[lens.stat] or 0)) / 100)
	local step = current * 0.1
	local scoreStep = probe(step / ratio)
	local scoreDouble, reached = probe(current / ratio)
	self.scorer.lens, self.scorer.lens2 = savedLens, savedLens2
	-- what doubling is worth beyond ten times the first tenth (the convex part)
	local convex = (scoreDouble - base) - 10 * (scoreStep - base)
	-- (never below the lens's own weight: a linear payoff still needs the push
	-- of a stat the gear isn't stacking yet; measured, lowering it lost 0.6)
	local weight = m_min(1.0, m_max(lens.weight or 0.3, convex / m_log(2)))
	self.scorer.lens = copyTable(lens, true)
	self.scorer.lens.weight = self.options.lensWeight or weight
	self:Note(string.format("Stat plan (%s): %s %d now, target about %d; doubling it is worth %+.3f score (the first tenth %+.3f), so it is valued at weight %.2f while the build is made",
		label, lens.label or lens.stat, math.floor(output[lens.stat] or 0), math.floor(reached), scoreDouble - base, scoreStep - base, self.scorer.lens.weight))
end

------------------------------------------------------------------------------
-- Cost of the build, total budget and upgrade order
------------------------------------------------------------------------------

local exceptionalGems = { ["Enlighten Support"] = true, ["Empower Support"] = true, ["Enhance Support"] = true }

-- What the finished build costs, item by item (divines): uniques at their
-- poe.ninja price, rares at the level's typical price, anoints at their oils,
-- tattoos, awakened and exceptional gems (when gem prices are loaded).
-- Returns total, entries { kind, slot, label, price, known, item, gem, group }
function BuildGeneratorClass:BuildCost()
	local prices = GetPriceSource()
	local level = self.options.investment or { }
	local rare = level.rarePrice or 1
	local spec = self.build.spec
	local entries = { }
	local function add(entry)
		entry.known = entry.price ~= nil
		entry.price = entry.price or 0
		t_insert(entries, entry)
	end
	for _, slot in ipairs(self.itemsTab.orderedSlots) do
		local item = self.itemsTab.items[slot.selItemId]
		local active = item and not slot.slotName:match("Swap") and not slot.inactive
			and (not slot.nodeId or spec.allocNodes[slot.nodeId])
		if active then
			local kind = (slot.nodeId or item.type == "Jewel") and "jewel" or (item.base and (item.base.flask or item.base.tincture) and "flask") or "gear"
			if item.rarity == "UNIQUE" or item.rarity == "RELIC" then
				add({ kind = kind, slot = slot.slotName, label = item.title or item.name, price = prices:UniquePrice(item), item = item, unique = true })
			elseif item.rarity == "RARE" then
				-- (rares made at a cheaper level, by the total budget, at that level's price)
				local own = self.rarePriceById and self.rarePriceById[item.id] or rare
				local price = kind == "gear" and own or (item.clusterJewel and own * 0.5) or own * 0.25
				add({ kind = kind, slot = slot.slotName, label = "rare " .. (item.baseName or item.type or "item"), price = price, item = item, estimate = true })
			end
			-- anoints (the oils), on any amulet
			if item.type == "Amulet" then
				local total, names = 0, { }
				for _, modLine in ipairs(item.enchantModLines or { }) do
					local name = modLine.line:match("^Allocates (.+)$")
					local node = name and spec.tree.notableMap and spec.tree.notableMap[name:lower()]
					if node then
						total = total + (prices:AnointPrice(node) or 0)
						t_insert(names, node.dn)
					end
				end
				if #names > 0 then add({ kind = "anoint", slot = slot.slotName, label = "anoint " .. table.concat(names, " + "), price = total, item = item }) end
			end
		end
	end
	local tattoos, tattooCount = 0, 0
	for nodeId, tattoo in pairs(spec.hashOverrides or { }) do
		if spec.allocNodes[nodeId] then
			tattoos = tattoos + (prices:TattooPrice(tattoo.dn) or 0)
			tattooCount = tattooCount + 1
		end
	end
	if tattooCount > 0 then add({ kind = "tattoos", label = tattooCount .. " tattoo" .. (tattooCount == 1 and "" or "s"), price = tattoos }) end
	for _, group in ipairs(self.build.skillsTab.socketGroupList) do
		for index, g in ipairs(group.gemList) do
			local gemData = g.gemId and data.gems[g.gemId]
			if gemData and g.enabled ~= false and (gemData.name:match("^Awakened ") or exceptionalGems[gemData.name]) then
				add({ kind = "gem", label = gemData.name .. " " .. (g.level or 20), price = prices:GemPrice(gemData.name, g.level), gem = g, group = group, index = index })
			end
		end
	end
	local total = 0
	for _, entry in ipairs(entries) do total = total + entry.price end
	return total, entries
end

-- Replaces a priced part of the build by its cheap version: a unique by a
-- rare on the same base (jewels: a rare jewel; flasks: taken out), an anoint
-- taken off, an awakened gem by its normal version, an exceptional gem taken out
function BuildGeneratorClass:CheapVersion(entry)
	if entry.kind == "gear" or entry.kind == "jewel" then
		local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
		local generator = finder.rareGenerator
		-- (measured against the empty slot: a rare is only kept if it beats what's there)
		self.itemsTab.slots[entry.slot]:SetSelItemId(0)
		self.itemsTab:PopulateSlots()
		self:Recalculate()
		local measure = function(output) return self.scorer:ScoreOutput(output, self.ratio) end
		local baseOutput = self.calcFunc({ })
		local opts = self:RareOptions(false)
		-- (a rare: made again as a cheaper level makes it)
		if entry.cheapLevel then
			opts.maxAffixes, opts.multiCraft = entry.cheapLevel.rareAffixes, entry.cheapLevel.multiCraft
			opts.quality = generator.qualityList[entry.cheapLevel.quality or generator.defaultQuality] or opts.quality
		end
		local ctx = { calcFunc = self.calcFunc, baseOutput = baseOutput, basePower = measure(baseOutput), measure = measure, tick = function() self:Tick() end, opts = opts }
		local bases = entry.kind == "jewel" and { "Crimson Jewel", "Viridian Jewel", "Cobalt Jewel" } or { entry.item.baseName }
		local best
		for _, baseName in ipairs(bases) do
			if data.itemBases[baseName] and not (entry.kind == "jewel" and entry.item.base and entry.item.base.subType == "Abyss") then
				local result = generator:GenerateForSlotWith(entry.slot, makeBase(baseName), ctx, nil)
				if result and (not best or result.power > best.power) then best = result end
			end
		end
		if best then
			local item = self:Equip(best.item, entry.slot)
			self.rarePriceById = self.rarePriceById or { }
			self.rarePriceById[item.id] = entry.cheapLevel and entry.cheapLevel.rarePrice or (self.options.investment or { }).rarePrice
		elseif entry.kind == "gear" and data.itemBases[entry.item.baseName] then
			-- (no rare helps there: the plain base, so the slot isn't left empty)
			self:Equip(makeBase(entry.item.baseName), entry.slot)
		end
		if self.lockedSlots then self.lockedSlots[entry.slot] = nil end
	elseif entry.kind == "flask" then
		self.itemsTab.slots[entry.slot]:SetSelItemId(0)
	elseif entry.kind == "anoint" then
		local copy = new("Item"):Item(entry.item:BuildRaw())
		for i = #copy.enchantModLines, 1, -1 do
			if copy.enchantModLines[i].line:match("^Allocates ") then t_remove(copy.enchantModLines, i) end
		end
		copy:BuildAndParseRaw()
		self:Equip(copy, entry.slot)
	elseif entry.kind == "gem" then
		-- (where the gem is now: other gems of the group may have gone)
		entry.index = nil
		for i, g in ipairs(entry.group.gemList) do if g == entry.gem then entry.index = i end end
		if not entry.index then return false end
		local name = data.gems[entry.gem.gemId].name
		local plain = name:match("^Awakened (.+)$")
		local gemId
		if plain then
			for id, gem in pairs(data.gems) do if gem.name == plain then gemId = id end end
		end
		if gemId then
			local g = copyTable(entry.gem, true)
			g.gemId, g.skillId, g.gemData, g.grantedEffect, g.level, g.nameSpec = gemId, nil, nil, nil, 20, nil
			entry.group.gemList[entry.index] = g
		else
			t_remove(entry.group.gemList, entry.index)
		end
		self.build.skillsTab:ProcessSocketGroup(entry.group)
	else
		return false
	end
	self.itemsTab:PopulateSlots()
	self:Recalculate()
	return true
end

-- Score each priced part is worth: the build with its cheap version instead
-- (everything else as it is). Returns the entries with .loss, priced ones only
function BuildGeneratorClass:PartValues(minPrice, withRares, withUnknown)
	local _, entries = self:BuildCost()
	local list = { }
	local before = self:FullScore()
	-- rares compared with the ones two investment levels down
	local levels = GetPriceSource().levels
	local investment = self.options.investment or { }
	local cheapLevel
	for i, level in ipairs(levels) do
		if level.id == (investment.baseId or investment.id) then cheapLevel = levels[m_max(1, i - 2)] end
	end
	for _, entry in ipairs(entries) do
		local wanted
		if entry.estimate then
			wanted = withRares and entry.kind == "gear" and cheapLevel and cheapLevel.rarePrice < entry.price
			if wanted then
				entry.cheapLevel = cheapLevel
				entry.label = entry.label .. " (" .. (investment.baseId or investment.id or "") .. " rare instead of " .. cheapLevel.id .. ")"
				entry.price = entry.price - cheapLevel.rarePrice
			end
		elseif entry.known then
			wanted = entry.price >= (minPrice or 0.5)
		else
			wanted = withUnknown
		end
		if wanted then
			local snap = self:Snapshot()
			local savedLog = #self.log
			local ok, done = pcall(function() return self:CheapVersion(entry) end)
			if ok and done then
				entry.loss = before - self:FullScore()
				t_insert(list, entry)
			elseif not ok then
				ConPrintf("Cheap version of %s failed: %s", entry.label, tostring(done))
			end
			for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
			self:Restore(snap)
			self:Tick()
		end
	end
	return list
end

-- Total budget: while the build costs more, the part giving the least score
-- per divine is replaced by its cheap version
function BuildGeneratorClass:FitTotalBudget()
	local budget = self.options.totalBudget
	if not budget or budget <= 0 or not GetPriceSource().loaded then return end
	local replaced = { }
	for _ = 1, 6 do
		local total = self:BuildCost()
		if total <= budget then break end
		local values = self:PartValues(0.5, true)
		t_sort(values, function(a, b) return a.loss / a.price < b.loss / b.price end)
		local entry = values[1]
		if not entry then break end
		-- (several cheap parts at once when far over: the worst value first)
		local over = total - budget
		local chosen = { }
		for _, e in ipairs(values) do
			t_insert(chosen, e)
			over = over - e.price
			if over <= 0 or #chosen >= 3 then break end
		end
		for _, e in ipairs(chosen) do
			if self:CheapVersion(e) then
				t_insert(replaced, string.format("%s (%s, %+.3f)", e.label, GetPriceSource().FormatPrice(e.price), -e.loss))
			end
		end
		self:RefineTree(6)
	end
	local total = self:BuildCost()
	if #replaced > 0 then
		self:Note(string.format("Fitted under the total budget of %s: %s replaced by cheaper versions; build now about %s",
			GetPriceSource().FormatPrice(budget), table.concat(replaced, ", "), GetPriceSource().FormatPrice(total)))
	end
	if total > budget * 1.05 then
		self:Note(string.format("Still over the total budget (about %s): rares at this level cost about %s each", GetPriceSource().FormatPrice(total), GetPriceSource().FormatPrice((self.options.investment or { }).rarePrice)))
	end
end

-- Upgrade order: the priced parts sorted by score per divine, with what the
-- build has after each step (what to buy first when building it up)
function BuildGeneratorClass:UpgradeOrder()
	if not GetPriceSource().loaded then return end
	local prices = GetPriceSource()
	local total = self:BuildCost()
	local all = self:PartValues(1, true, true)
	local values, unknown = { }, { }
	for _, e in ipairs(all) do
		if e.loss > 0.002 then t_insert(e.known and values or unknown, e) end
	end
	if #values == 0 and #unknown == 0 then return end
	t_sort(values, function(a, b) return a.loss / m_max(a.price, 0.1) > b.loss / m_max(b.price, 0.1) end)
	t_sort(unknown, function(a, b) return a.loss > b.loss end)
	local base = total
	for _, e in ipairs(values) do base = base - e.price end
	self:Note(string.format("Cost: about %s (uniques at their cheapest poe.ninja copy: chosen mods and seeds cost more; rares about %s each). Upgrade order, best score per divine first, from about %s:",
		prices.FormatPrice(total), prices.FormatPrice((self.options.investment or { }).rarePrice), prices.FormatPrice(base)))
	local spent = base
	for i, e in ipairs(values) do
		if i > 12 then break end
		spent = spent + e.price
		self:Note(string.format("    %d. %s (%s): score %+.3f, build about %s", i, e.label, prices.FormatPrice(e.price), e.loss, prices.FormatPrice(spent)))
	end
	if #unknown > 0 then
		local parts = { }
		for i, e in ipairs(unknown) do
			if i > 6 then break end
			t_insert(parts, string.format("%s %+.3f", e.label, e.loss))
		end
		self:Note("    Not priced (update prices to place them): " .. table.concat(parts, ", "))
	end
	self.upgradeOrder = values
end

-- Supreme Ostentation (Elegant Hubris, Caspiro): attribute requirements ignored.
-- Its value only shows once the build is rebuilt without them: the passives
-- taken for attributes spent elsewhere and the rares made without attribute
-- mods. So it is tried as a package (jewel, tree, rares) against the build as
-- it is, replacing the timeless jewel already chosen if there is one.
function BuildGeneratorClass:SupremeOstentationMove()
	local investment = self.options.investment or { }
	if not investment.awakenedGems or investment.timeless == false then return 0 end
	if self.rules and self.rules.userExcluded and self.rules.userExcluded["Elegant Hubris"] then return 0 end
	local spec = self.build.spec
	self:Recalculate()
	local output = self.build.calcsTab.mainOutput
	local env = self.build.calcsTab.mainEnv
	if env and env.player.modDB:Flag(nil, "IgnoreAttributeRequirements") then return 0 end
	-- (only when attributes cost the build something: requirements well above the base)
	local need = 0
	for _, attr in ipairs({ "Str", "Dex", "Int" }) do need = need + m_max(0, (output["Req" .. attr] or 0) - 40) end
	if need < 100 then return 0 end
	local finder = new("TimelessJewelFinder"):TimelessJewelFinder({
		build = self.build,
		score = function(override) return (self:Score(override)) end,
		fullScore = function() return (self:FullScore()) end,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	local jewelType
	for _, jt in ipairs(finder.jewelTypes) do if jt.name == "Elegant Hubris" then jewelType = jt end end
	if not jewelType then return 0 end
	local conqueror
	for _, c in ipairs(jewelType.conquerors) do if c[1] == "Caspiro" then conqueror = c end end
	local before = self:FullScore()
	-- the timeless jewel already socketed (it is replaced for the trial)
	local historicSocket
	for nodeId, itemId in pairs(spec.jewels) do
		local item = self.itemsTab.items[itemId]
		if item and item.jewelData and item.jewelData.conqueredBy and spec.allocNodes[nodeId] then historicSocket = nodeId end
	end
	local sockets = { }
	for _, socket in ipairs(finder:CandidateSockets(6, 3)) do
		if socket.keystones > 0 or socket.nearKeystone or socket.node.id == historicSocket then t_insert(sockets, socket) end
	end
	-- (the historic socket first: no points to spend on it)
	t_sort(sockets, function(a, b)
		local ah, bh = a.node.id == historicSocket, b.node.id == historicSocket
		if ah ~= bh then return ah end
		return a.value > b.value
	end)
	-- (each socket tried as a package; the first that improves the build is kept)
	for i = 1, m_min(2, #sockets) do
		local socket = sockets[i]
		local snap = self:Snapshot()
		local savedLog = #self.log
		local seed
		local ok, err = pcall(function()
			if historicSocket and historicSocket ~= socket.node.id then
				local slot = self.itemsTab.slots["Jewel " .. historicSocket]
				if slot then slot:SetSelItemId(0) end
			end
			self:Recalculate()
			finder.base, finder.addValue, finder.removeValue = self:Score(), { }, { }
			seed = (finder:RankSeeds(jewelType, socket, 1)[1] or { }).seed or (data.timelessJewelSeedMin[jewelType.id] * jewelType.seedStep)
			local item = finder.MakeItem(jewelType, seed, conqueror)
			finder:Apply({ item = item, socket = socket, keystone = socket.keystones == 0 and socket.nearKeystone or nil })
			self:Recalculate()
			local dbg = self.options.debugTiming and function(what) ConPrintf("[ostentation]   %s: %.3f", what, (self:FullScore())) end or function() end
			dbg("jewel")
			self:TrimTree()
			dbg("trim")
			-- passives taken for attributes are the cheapest leaves now: spent again
			self:RefineTree(16)
			dbg("refine")
			if self.options.finalRares ~= false then self:FinalRares() end
			dbg("rares")
			-- (targets re-chosen: paths no longer need to pass through attributes)
			self:OptimizeTree()
			dbg("optimize")
		end)
		if not ok then ConPrintf("Supreme Ostentation trial failed: %s", tostring(err)) end
		for j = #self.log, savedLog + 1, -1 do t_remove(self.log, j) end
		local after = ok and self:FullScore() or before
		if self.options.debugTiming then ConPrintf("[ostentation] socket %d (historic %s, keystones %d, near %s): %.3f -> %.3f", socket.node.id, tostring(historicSocket), socket.keystones, socket.nearKeystone and socket.nearKeystone.dn or "-", before, after) end
		if ok and after > before + 0.01 then
			self:Note(string.format("Elegant Hubris (Caspiro, seed %d): Supreme Ostentation, attribute requirements ignored; the passives and rare mods that were there for attributes spent on other stats: score %+.3f", seed, after - before))
			self.costs = self.costs or { }
			t_insert(self.costs, GetPriceSource():UniquePrice(self.itemsTab.items[self.itemsTab.slots["Jewel " .. socket.node.id].selItemId]) or false)
			return after - before
		end
		self:Restore(snap)
		self:Tick()
	end
	return 0
end

-- Two-piece unique combos (Classes/UniqueComboFinder): pairs that gain more
-- together than apart, and uniques granting a state (Elusive, Onslaught...)
-- with the ones paying off in it; tried as packages with the build adapted
function BuildGeneratorClass:UniqueCombosMove(rounds)
	if not self.mainGem then return end
	local combo = new("UniqueComboFinder"):UniqueComboFinder(self)
	local packages = combo:Find({ perSlot = self.options.comboPerSlot, maxPairs = self.options.comboPairs })
	if self.options.debugTiming then
		ConPrintf("[combos] %d pairs scored, %d packages", combo.pairsTried or 0, #packages)
		for _, p in ipairs(packages) do ConPrintf("  %s: %s", p.label, p.reason) end
	end
	if #packages == 0 then return end
	self:EvaluatePackages(packages, rounds, function(best, gain, overAdaptation)
		return string.format("Unique combo: %s (%s), with passives and supports adapted: score %+.3f (%+.3f more than adapting them without it)", best.label, best.reason, gain, overAdaptation)
	end, { threshold = 1.0, tries = 3, baseline = true })
end

-- Packages (uniques and / or a keystone) screened with the quick score,
-- the most promising applied for real with the build adapted around them
-- (passives trimmed and refined, supports again), the best one kept per round
function BuildGeneratorClass:EvaluatePackages(moves, rounds, describe, opts)
	opts = opts or { }
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local slots = finder:GetActiveSlots()
	for _ = 1, rounds or 1 do
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
						if not bestScore or score > bestScore + 1e-9 then bestSlot, bestScore = slotName, score end
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
			state.groups = self:SaveGroups()
			for _, p in ipairs(move.placement) do
				t_insert(state.newItems, self:Equip(p.item, p.slot))
			end
			self.itemsTab:PopulateSlots()
			self:FitSockets()
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
			local log = { }
			for i, l in ipairs(self.log) do log[i] = l end
			self:RestoreGroups(state.groups)
			for i = #self.log, 1, -1 do self.log[i] = nil end
			for i, l in ipairs(log) do self.log[i] = l end
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
		-- (opts.baseline: the same adaptation with no package first; a package
		-- must beat it, so what the adaptation alone gains isn't credited to it)
		local bar = base
		if opts.baseline then
			local state = apply({ placement = { }, label = "(adaptation alone)" })
			bar = m_max(base, (self:FullScore()))
			revert(state)
			for j = #self.log, savedLog + 1, -1 do t_remove(self.log, j) end
			if self.options.debugTiming then ConPrintf("[packages] adaptation alone: %.3f (base %.3f)", bar, base) end
		end
		for i = 1, math.min(opts.tries or self.options.jointMoveTries or 5, #moves) do
			local move = moves[i]
			if self.options.debugTiming then ConPrintf("[packages] %s: quick %+.3f", move.label, move.quick - current) end
			if move.quick > current - (opts.threshold or 0.4) then
				local state = apply(move)
				local score = self:FullScore()
				if self.options.debugTiming then ConPrintf("[packages] %s applied and adapted: %.3f (base %.3f)", move.label, score, base) end
				revert(state)
				for j = #self.log, savedLog + 1, -1 do t_remove(self.log, j) end
				if score > bar + 0.01 and (not bestScore or score > bestScore + 1e-9) then best, bestScore = move, score end
			end
			self:Tick()
		end
		if not best then break end
		apply(best)
		local after = self:FullScore()
		self:Note(describe(best, after - base, after - bar))
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
					if not bestScore or score > bestScore + 1e-9 then bestSlot, bestScore = slotName, score end
				end
			end
			if bestSlot and bestScore > current + 0.003 then
				local before = self:FullScore()
				local slot = self.itemsTab.slots[bestSlot]
				local previous = slot.selItemId
				local newItem = finder:Equip(item, bestSlot, true)
				self.itemsTab:PopulateSlots()
				local savedGroups = self:SaveGroups()
				self:FitSockets()
				local after = self:FullScore()
				if after <= before + 0.003 then self:RestoreGroups(savedGroups) end
				if after > before + self:PriceCost(item) + 0.003 then
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

-- Gem setups that no longer fit their item's sockets after an item change
-- (a unique with a fixed socket count, like Crest of Desire's one socket):
-- the main link moves to a 4-link when its slot has fewer than 3 sockets,
-- or keeps fewer supports; the utility setups are packed again. Returns
-- true if anything changed.
function BuildGeneratorClass:FitSockets()
	local setup = new("GemSetup"):GemSetup(self)
	local skillsTab = self.build.skillsTab
	local changed = false
	local main = self.mainGroup
	if main and main.slot then
		local sockets = setup:SlotSockets(main.slot)
		if sockets < #main.gemList then
			changed = true
			if sockets < 3 then
				self:RelocateMainLink()
			else
				self.mainLinkLimit = sockets - 1
				while #main.gemList > sockets do t_remove(main.gemList) end
				skillsTab:ProcessSocketGroup(main)
				self:ChooseSupports(5)
			end
		end
	end
	local used = { }
	for _, group in ipairs(skillsTab.socketGroupList) do
		if group ~= main and group.slot and group.enabled ~= false then
			used[group.slot] = (used[group.slot] or 0) + #group.gemList
		end
	end
	if main and main.slot then used[main.slot] = (used[main.slot] or 0) + #main.gemList end
	for slotName, count in pairs(used) do
		if count > setup:SlotSockets(slotName) then
			self:ChooseUtilityGems()
			changed = true
			break
		end
	end
	if changed then self:Recalculate() end
	return changed
end

-- The idea the build is built around, and its parts that carry it most
function BuildGeneratorClass:Explain(final)
	local archetype = self.options.archetype
	if archetype then
		self:Note(string.format("Built around: %s. %s", archetype.label, archetype.summary or ""))
	end
	local base = final or self.scorer:Evaluate(self.calcFunc, { })
	local baseHit = self.scorer:MinMaxHit(base.output) or 1
	local rows = { }
	local function measure(label, override)
		local r = self.scorer:Evaluate(self.calcFunc, override, { flasks = "ratio", ratio = self.ratio })
		local hit = self.scorer:MinMaxHit(r.output) or 1
		t_insert(rows, { label = label, loss = base.score - r.score, dps = base.dps > 0 and (1 - r.dps / base.dps) or 0, hit = 1 - hit / baseHit })
	end
	for _, slot in ipairs(self.itemsTab.orderedSlots) do
		local item = self.itemsTab.items[slot.selItemId]
		if item and (not slot.nodeId or self.build.spec.allocNodes[slot.nodeId]) and not slot.slotName:match("Swap") and (item.rarity == "UNIQUE" or item.rarity == "RELIC" or slot.nodeId) then
			measure(string.format("%s (%s)", item.title or item.name, slot.slotName), { repItems = { [slot.slotName] = false } })
		end
	end
	for _, node in ipairs(nodesById(self.build.spec.allocNodes)) do
		if node.type == "Keystone" or (node.ascendancyName and node.type == "Notable") then
			measure(node.dn, { removeNodes = { [node] = true } })
		end
	end
	local main = self.mainGroup
	if main then
		for _, gem in ipairs(main.gemList) do
			if gem.enabled ~= false and gem.gemData and gem.gemData.grantedEffect.support then
				gem.enabled = false
				self.build.skillsTab:ProcessSocketGroup(main)
				self:Recalculate()
				measure(gem.gemData.name .. " (support)", { })
				gem.enabled = true
				self.build.skillsTab:ProcessSocketGroup(main)
			end
		end
		self:Recalculate()
	end
	table.sort(rows, function(a, b)
		if a.loss ~= b.loss then return a.loss > b.loss end
		return a.label < b.label
	end)
	local parts = { }
	for i = 1, m_min(6, #rows) do
		local r = rows[i]
		if r.loss > 0.01 then
			local what = { }
			if r.dps > 0.005 then t_insert(what, string.format("%.0f%% of the damage", r.dps * 100)) end
			if r.hit > 0.01 then t_insert(what, string.format("%.0f%% of the max hit", r.hit * 100)) end
			t_insert(parts, #what > 0 and string.format("%s (%s)", r.label, table.concat(what, ", ")) or r.label)
		end
	end
	if #parts > 0 then self:Note("What carries it: " .. table.concat(parts, "; ")) end
end

-- Utility gems that add nothing measurable to the finished build (a herald
-- whose buff doesn't reach the main skill's damage, a golem, a filler...)
-- are taken out one at a time: each costs mana or life reserved and sockets,
-- and a build full of skills that don't touch its damage isn't smooth to play.
-- Kept: setups PoB can't count but a player uses (movement, guard skills,
-- Animate Guardian, trigger setups, Vaal skills switched off for hand use).
function BuildGeneratorClass:PruneUselessGems()
	-- (auras: each aura or herald alone; other setups as a whole: a curse
	-- without its Arcanist Brand would just be cast by hand)
	local prunable = { "^Auras", "^Golem", "^Filler", "^Blessing", "^Curse" }
	local function isPrunable(label)
		for _, p in ipairs(prunable) do if (label or ""):match(p) then return true end end
		return false
	end
	local removed = { }
	local current = self:FullScore()
	local list = self.build.skillsTab.socketGroupList
	local function names(group)
		local out = { }
		for _, gem in ipairs(group.gemList) do
			if gem.gemData and not gem.gemData.grantedEffect.support then t_insert(out, gem.gemData.name) end
		end
		return out
	end
	for gi = #list, 1, -1 do
		local group = list[gi]
		if group ~= self.mainGroup and group.enabled ~= false and isPrunable(group.label) then
			if (group.label or ""):match("^Auras") then
				for i = #group.gemList, 1, -1 do
					local gem = group.gemList[i]
					local gd = gem.gemData
					if gem.enabled ~= false and gd and not gd.grantedEffect.support then
						gem.enabled = false
						self.build.skillsTab:ProcessSocketGroup(group)
						local score = self:FullScore()
						if score >= current - 0.002 then
							t_remove(group.gemList, i)
							t_insert(removed, gd.name)
							current = math.max(current, score)
						else
							gem.enabled = true
						end
						self.build.skillsTab:ProcessSocketGroup(group)
					end
				end
				if #names(group) == 0 then t_remove(list, gi) end
			else
				group.enabled = false
				local score = self:FullScore()
				if score >= current - 0.002 then
					t_remove(list, gi)
					t_insert(removed, table.concat(names(group), " + "))
					current = math.max(current, score)
				else
					group.enabled = true
				end
			end
		end
	end
	self:Recalculate()
	if #removed > 0 then
		table.sort(removed)
		self:Note("Taken out (added nothing measurable to damage or defence): " .. table.concat(removed, ", "))
	end
	return #removed
end

-- Clearing + bossing: the score is the boss's, and Eldritch implicits are
-- also measured while mapping (killed recently, normal enemies), that score
-- counting at this weight. Returns { weight, toggle(on) } or nil.
function BuildGeneratorClass:MappingBlend()
	local sc = self.options.configScenario
	if not (sc and sc.clear) then return nil end
	local input = self.build.configTab.input
	local saved
	return {
		weight = self.options.mappingWeight or 0.35,
		toggle = function(on)
			if on then
				saved = { killed = input.conditionKilledRecently, boss = input.enemyIsBoss, hh = input.conditionHeadhunterBuffs }
				input.conditionKilledRecently = true
				input.conditionHeadhunterBuffs = true
				input.enemyIsBoss = "None"
			else
				input.conditionKilledRecently = saved and saved.killed
				input.conditionHeadhunterBuffs = saved and saved.hh
				input.enemyIsBoss = saved and saved.boss
			end
			self.build.configTab:BuildModList()
		end,
	}
end

-- Is a gem in an enabled socket group?
function BuildGeneratorClass:HasGem(name)
	for _, group in ipairs(self.build.skillsTab.socketGroupList) do
		if group.enabled ~= false then
			for _, gem in ipairs(group.gemList) do
				if gem.gemData and gem.gemData.name == name and gem.enabled ~= false then return true end
			end
		end
	end
	return false
end

-- What buying an item costs in score: the budget is an investment, so an
-- expensive item must gain more than a cheap one that does nearly as well
-- (a quarter of the item limit costs 0.01, the full limit 0.04: about 1% and
-- 4% damage). Nothing for items without a price or levels without a limit.
function BuildGeneratorClass:PriceCost(item)
	if not item or self.options.priceAware == false then return 0 end
	local investment = self.options.investment or { }
	local cap = investment.maxUnique
	if not cap or cap <= 0 then return 0 end
	local price = GetPriceSource():UniquePrice(item)
	if not price then return 0 end
	return 0.04 * m_min(1, price / cap)
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

-- Pearl of Tsoatha (a ring): "Skills Socketed in your Helmet / Gloves /
-- Boots are Supported by level 20 <two supports>". Top players link the main
-- skill in that 4-link and the ring gives the other two supports - a 6-link
-- without the body armour, which is then free for a unique or a better rare.
-- Tried in each of those slots: the main skill moved there with its best 3
-- supports, the ring's two supports chosen one after the other by value, the
-- utility setups placed again; kept if the build is better.
function BuildGeneratorClass:PearlMove()
	local pearl
	for _, item in pairs(main.uniqueDB.list) do if item.title == "Pearl of Tsoatha" then pearl = item break end end
	local group = self.mainGroup
	if not pearl or not group then return 0 end
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	if not finder:IsItemAllowed(pearl, { obtainableOnly = true, levelOnly = true, investment = self.options.investment }) then return 0 end
	local index = { }
	for i, name in ipairs(pearl.variantList or { }) do index[name] = i end
	local function pearlItem(slotName, first, second)
		local copy = new("Item"):Item(pearl:BuildRaw())
		copy.variant = index[slotName .. " / " .. first]
		copy.variantAlt = second and index[slotName .. " / " .. second] or copy.variant
		copy:BuildAndParseRaw()
		return copy
	end
	-- (for scoring: the ring with only its current lines - the full item has
	-- hundreds of variants, and parsing it for every support tried took a
	-- tenth of a whole generation)
	local baseLines, variantLine = { }, { }
	for _, modLine in ipairs(pearl.explicitModLines or { }) do
		if modLine.variantList then
			for v in pairs(modLine.variantList) do variantLine[v] = modLine.line end
		else
			t_insert(baseLines, modLine.line)
		end
	end
	local implicitLines = { }
	for _, modLine in ipairs(pearl.implicitModLines or { }) do t_insert(implicitLines, modLine.line) end
	local quickCache = { }
	local function pearlQuick(slotName, first, second)
		local key = slotName .. "|" .. first .. "|" .. (second or "")
		if quickCache[key] then return quickCache[key] end
		local a = variantLine[index[slotName .. " / " .. first]]
		local b = second and variantLine[index[slotName .. " / " .. second]]
		if not a then return pearlItem(slotName, first, second) end
		local lines = { "Rarity: UNIQUE", "Pearl of Tsoatha", pearl.baseName, "Implicits: " .. #implicitLines }
		for _, l in ipairs(implicitLines) do t_insert(lines, l) end
		for _, l in ipairs(baseLines) do t_insert(lines, l) end
		t_insert(lines, a)
		if b and b ~= a then t_insert(lines, b) end
		local item = new("Item"):Item(table.concat(lines, "\n"))
		item:BuildModList()
		quickCache[key] = item
		return item
	end
	local supportNames = { }
	for _, entry in ipairs(require("Data.PearlSupports")) do t_insert(supportNames, (entry.baseItemName:gsub(" Support$", ""))) end
	local setup = new("GemSetup"):GemSetup(self)
	local before = self:FullScore()
	local snap = self:Snapshot()
	-- the ring to give up: the one whose loss costs least
	self:Recalculate()
	local ringSlot, ringLoss
	for _, r in ipairs({ "Ring 1", "Ring 2" }) do
		local loss = self:Score() - self:Score({ repItems = { [r] = false } })
		if not ringLoss or loss < ringLoss then ringSlot, ringLoss = r, loss end
	end
	local best
	local logLength = #self.log
	local shortlist
	for _, slotName in ipairs({ "Helmet", "Gloves", "Boots" }) do
		if not (self.lockedSlots and self.lockedSlots[slotName]) and setup:SlotSockets(slotName) >= 4 and index[slotName .. " / " .. supportNames[1]] then
			self:Restore(snap)
			for i = #self.log, logLength + 1, -1 do self.log[i] = nil end
			group = self.mainGroup
			-- 1. the main skill in this slot's 4-link, its 3 best supports
			local list = self.build.skillsTab.socketGroupList
			for i = #list, 1, -1 do
				if list[i] ~= group and list[i].slot == slotName then t_remove(list, i) end
			end
			for i, g in ipairs(list) do if g == group then self.build.mainSocketGroup = i end end
			group.slot = slotName
			self.mainLinkLimit = 3
			self:Recalculate()
			self:ChooseSupports(5)
			-- 2. the ring's two supports, one after the other
			-- (every support for the first slot tried; the best 8 of it for the others)
			local chosen = { }
			local scored = { }
			for k = 1, 2 do
				local bestName, bestScore
				for _, name in ipairs(shortlist or supportNames) do
					if not chosen[1] or chosen[1] ~= name then
						local item = pearlQuick(slotName, chosen[1] or name, chosen[1] and name or nil)
						local score = self:Score({ repSlotName = ringSlot, repItem = item })
						if k == 1 then t_insert(scored, { name = name, score = score }) end
						if not bestScore or score > bestScore + 1e-9 then bestName, bestScore = name, score end
					end
				end
				chosen[k] = bestName
				self:Tick()
			end
			if not shortlist then
				t_sort(scored, function(a, b) return a.score > b.score end)
				shortlist = { }
				for i = 1, m_min(8, #scored) do shortlist[i] = scored[i].name end
			end
			local item = pearlItem(slotName, chosen[1], chosen[2])
			self:Equip(item, ringSlot)
			self.itemsTab:PopulateSlots()
			self:Recalculate()
			-- 3. the utility setups placed again around it
			self:ChooseUtilityGems()
			local score = self:FullScore()
			if self.options.debugTiming then ConPrintf("[pearl] %s: %s + %s, %.3f (before %.3f)", slotName, chosen[1], chosen[2], score, before) end
			if not best or score > best.score then best = { slot = slotName, supports = chosen, score = score } end
		end
	end
	self:Restore(snap)
	for i = #self.log, logLength + 1, -1 do self.log[i] = nil end
	if not best or best.score <= before + 0.01 then return 0 end
	-- the best one again, for real
	group = self.mainGroup
	local list = self.build.skillsTab.socketGroupList
	for i = #list, 1, -1 do
		if list[i] ~= group and list[i].slot == best.slot then t_remove(list, i) end
	end
	for i, g in ipairs(list) do if g == group then self.build.mainSocketGroup = i end end
	group.slot = best.slot
	self.mainLinkLimit = 3
	self:Recalculate()
	self:ChooseSupports(5)
	self:Equip(pearlItem(best.slot, best.supports[1], best.supports[2]), ringSlot)
	self.itemsTab:PopulateSlots()
	self:Recalculate()
	self:ChooseUtilityGems()
	local after = self:FullScore()
	if after <= before + 0.005 then
		self:Restore(snap)
		for i = #self.log, logLength + 1, -1 do self.log[i] = nil end
		return 0
	end
	self.lockedSlots = self.lockedSlots or { }
	self.lockedSlots[ringSlot] = true
	local price = GetPriceSource():UniquePrice(pearl)
	self.costs = self.costs or { }
	t_insert(self.costs, price or false)
	self:Note(string.format("Pearl of Tsoatha in %s (%s): main skill linked in the %s, the ring adds %s and %s (a 6-link without the body armour), score %+.3f",
		ringSlot, GetPriceSource().FormatPrice(price), best.slot, best.supports[1], best.supports[2], after - before))
	return after - before
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
	local setup = new("GemSetup"):GemSetup(self)
	local function noSockets(item)
		return setup.ItemGemSockets(item) == 0
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
			-- (each current version of it: Ralakesh's endurance, frenzy or power boots...)
			for _, version in ipairs(finder.CurrentVariants(item)) do t_insert(candidates, version) end
		end
	end
	t_sort(candidates, function(a, b)
		if (a.title or a.name) ~= (b.title or b.name) then return (a.title or a.name) < (b.title or b.name) end
		return (a.variant or 0) < (b.variant or 0)
	end)
	self:Recalculate()
	local current = self:Score()
	local fullCurrent = self.scorer:Evaluate(self.calcFunc, { }).score
	local function flaskItem(item)
		for _, modLine in ipairs(item.explicitModLines or { }) do
			if modLine.line:find("Flask", 1, true) then return true end
		end
		return false
	end
	local gains = { }
	local sweepSlots = finder:GetActiveSlots()
	for slotIndex, slotName in ipairs(sweepSlots) do
		self:Inner((slotIndex - 1) / #sweepSlots * 0.7)
		local slot = self.itemsTab.slots[slotName]
		local equipped = slot and self.itemsTab.items[slot.selItemId]
		if slot and not (self.lockedSlots and self.lockedSlots[slotName]) then
			for _, item in ipairs(candidates) do
				-- (no sockets where the main skill is: it moves to a 4-link, scored when tried)
				local relocate = noSockets(item) and self.mainGroup and self.mainGroup.slot == slotName and slotName == "Body Armour"
				if self.itemsTab:IsItemValidForSlot(item, slotName) and not (equipped and equipped.title == item.title)
					and (relocate or not (groupSlots[slotName] and noSockets(item))) and not changesHands(item, slotName) then
					-- (items that change flasks, like Mageblood, need the flask uptimes: a full evaluation)
					local score
					if flaskItem(item) then
						score = self.scorer:Evaluate(self.calcFunc, { repSlotName = slotName, repItem = item }).score - fullCurrent + current
					else
						score = self:Score({ repSlotName = slotName, repItem = item })
					end
					-- (gain net of what the item costs: Price Cost)
					if score > current + 0.01 + self:PriceCost(item) then
						t_insert(gains, { item = item, slot = slotName, gain = score - current - self:PriceCost(item), relocate = relocate })
					end
				end
			end
		end
	end
	t_sort(gains, function(a, b)
		local qa, qb = m_floor(a.gain * 1e9 + 0.5), m_floor(b.gain * 1e9 + 0.5)
		if qa ~= qb then return qa > qb end
		if a.slot ~= b.slot then return a.slot < b.slot end
		return (a.item.title or a.item.name) < (b.item.title or b.item.name)
	end)
	if self.options.debugTiming then
		ConPrintf("[uniques] %d candidates, %d gains", #candidates, #gains)
		for i = 1, m_min(10, #gains) do ConPrintf("  %.3f %s in %s", gains[i].gain, gains[i].item.title or gains[i].item.name, gains[i].slot) end
	end
	if self.decisions then
		for i = 1, m_min(20, #gains) do
			self:Decision("unique_screen", gains[i].item.title or gains[i].item.name, gains[i].gain, false, { slot = gains[i].slot })
		end
	end
	local kept, usedSlots, usedItems = { }, { }, { }
	local tries = 0
	for _, entry in ipairs(gains) do
		if tries >= (maxTries or 6) then break end
		local title = entry.item.title or entry.item.name
		if not usedSlots[entry.slot] and not usedItems[title] then
			tries = tries + 1
			local before = self:FullScore()
			local slot = self.itemsTab.slots[entry.slot]
			local previous = slot.selItemId
			local newItem = finder:Equip(entry.item, entry.slot, true)
			self.itemsTab:PopulateSlots()
			local savedGroups = self:SaveGroups()
			self:FitSockets()
			local moved = not entry.relocate or self.mainGroup.slot ~= "Body Armour"
			self:Recalculate()
			local after = moved and self:FullScore() or before
			if self.options.debugTiming then ConPrintf("[uniques] tried %s in %s%s: %.3f -> %.3f", entry.item.title or entry.item.name, entry.slot, entry.relocate and " (main link moved)" or "", before, after) end
			self:Decision("unique", title, after - before, after > before + self:PriceCost(entry.item) + 0.005, { slot = entry.slot, price = GetPriceSource():UniquePrice(entry.item) })
			if after > before + self:PriceCost(entry.item) + 0.005 then
				usedSlots[entry.slot] = true
				usedItems[title] = true
				if entry.slot:match("^Weapon") then self.weaponFinalists = nil end
				local price = GetPriceSource():UniquePrice(entry.item)
				t_insert(kept, string.format("%s in %s (+%.2f; %s)", title, entry.slot, after - before, GetPriceSource().FormatPrice(price)))
				self.costs = self.costs or { }
				t_insert(self.costs, price or false)
			else
				self:RestoreGroups(savedGroups)
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

-- The parts (gear, links, passives) of the i-th top player build of the
-- skill, read once: ok, parts
function BuildGeneratorClass:TopBuildParts(i)
	local tops = self.options.meta and self.options.meta.details and self.options.meta.details.topBuilds
	if not tops or not tops[i] then return false, "no build" end
	-- (builds remembered by earlier generations come as parts already)
	if tops[i].parts then return true, tops[i].parts end
	self.topParts = self.topParts or { }
	if self.topParts[i] == nil then
		local BC = LoadModule("Modules/BuildComparison")
		local ok, parts = pcall(function()
			local entry = new("CompareEntry"):CompareEntry(BC.DecodeCode(tops[i].code), "top player")
			BC.SelectMainSkill(entry, self.mainGem.name)
			return BC.ReadParts(entry)
		end)
		if not ok then ConPrintf("Top build %d could not be read: %s", i, tostring(parts)) end
		self.topParts[i] = { ok = ok, parts = parts }
		self:Tick()
	end
	return self.topParts[i].ok, self.topParts[i].parts
end

-- The passives most top players of the skill take (poe.ninja top builds,
-- when loaded): the notables and keystones at least half of them allocate,
-- and then those most of them do, each set allocated with its paths, the
-- tree trimmed back to the budget around them and refilled; kept if the
-- build is better. What players converge on often only pays off together.
function BuildGeneratorClass:PopularPassivesMove(maxBuilds)
	local details = self.options.meta and self.options.meta.details
	if not details or not self.mainGem then return 0 end
	local spec = self.build.spec
	local counts, read = { }, 0
	-- the passives of every top player of the class (BuildMetaSource), else
	-- the few top builds themselves
	local popular = details.popularNodes and details.popularNodes[tostring(spec.curClassId)]
	if popular and (popular.builds or 0) >= (self.options.popularMinBuilds or 3) then
		read = popular.builds
		for _, e in ipairs(popular.nodes or { }) do counts[e.id] = e.count end
	else
		for i = 1, m_min(maxBuilds or 8, #(details.topBuilds or { })) do
			local ok, parts = self:TopBuildParts(i)
			if ok and parts and parts.tree and parts.tree.classId == spec.curClassId then
				read = read + 1
				for _, id in ipairs(parts.tree.nodes) do counts[id] = (counts[id] or 0) + 1 end
			end
		end
	end
	if read < (self.options.popularMinBuilds or 3) then return 0 end
	local total, lastKey = 0, nil
	for _, share in ipairs({ 0.5, 0.75 }) do
		local wanted = { }
		for _, node in ipairs(nodesById(spec.nodes)) do
			local c = counts[node.id] or 0
			if c >= read * share and not node.alloc and node.path and (node.type == "Notable" or node.type == "Keystone")
				and not node.ascendancyName and not node.expansionJewel and not (self.forbiddenNodes and self.forbiddenNodes[node.id]) then
				t_insert(wanted, node)
			end
		end
		local ids = { }
		for _, node in ipairs(wanted) do t_insert(ids, node.id) end
		local key = table.concat(ids, ",")
		if #wanted > 0 and key ~= lastKey then
			lastKey = key
			self:Recalculate()
			local before = self:FullScore()
			local undo = spec:CreateUndoState()
			local savedLog = #self.log
			local protected = { }
			for _, node in ipairs(wanted) do
				if not node.alloc and node.path then spec:AllocNode(node) end
				protected[node.id] = true
			end
			spec:BuildAllDependsAndPaths()
			self:Recalculate()
			local savedProtected = self.protectedNodes
			self.protectedNodes = protected
			self:TrimTree()
			self.protectedNodes = savedProtected
			self:AllocateTree(true)
			self:Recalculate()
			local after = self:FullScore()
			for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
			local names = { }
			for _, node in ipairs(wanted) do t_insert(names, node.dn) end
			if self.options.debugTiming then ConPrintf("[popular] %d%%+ of %d builds: %s: %.3f -> %.3f", share * 100, read, table.concat(names, ", "), before, after) end
			if after > before + 0.005 then
				self:Note(string.format("Passives most top players take (%d%%+ of %d builds): %s, score %+.3f", share * 100, read, table.concat(names, ", "), after - before))
				total = total + after - before
			else
				spec:RestoreUndoState(undo)
				spec:BuildAllDependsAndPaths()
				self:Recalculate()
			end
		end
	end
	return total
end

-- What the strongest players of the skill wear and link (poe.ninja top
-- builds, when they're loaded): each of their gear items and their main
-- link tried in this build, the best few kept when the full score agrees.
-- Their uniques must fit the budget; their rares (often mirror-tier) only
-- at the No limit level. Runs once the build is finished, so it only takes
-- what beats what the generator found on its own.
function BuildGeneratorClass:LearnFromTopBuilds(maxTries)
	local details = self.options.meta and self.options.meta.details
	local tops = details and details.topBuilds
	if not tops or #tops == 0 or not self.mainGem then return 0 end
	local BC = LoadModule("Modules/BuildComparison")
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local investment = self.options.investment or { }
	local filter = { obtainableOnly = true, levelOnly = true, investment = investment }
	self:Recalculate()
	local current = self:Score()
	local candidates = { }
	for i = 1, m_min(3, #tops) do
		local ok, parts = self:TopBuildParts(i)
		if ok and parts then
			local who = tostring(tops[i].name or ("player " .. i))
			local slotNames = { }
			for slotName in pairs(parts.items) do t_insert(slotNames, slotName) end
			t_sort(slotNames)
			for _, slotName in ipairs(slotNames) do
				local entry = parts.items[slotName]
				local slot = self.itemsTab.slots[slotName]
				if slot and not slotName:match("^Flask") and not (self.lockedSlots and self.lockedSlots[slotName]) then
					local item = new("Item"):Item(entry.raw)
					item:NormaliseQuality()
					item:BuildModList()
					local unique = item.rarity == "UNIQUE" or item.rarity == "RELIC"
					local allowed = (unique and finder:IsItemAllowed(item, filter)) or (not unique and investment.elevated)
					if allowed and self.itemsTab:IsItemValidForSlot(item, slotName) then
						local score = self:Score({ repSlotName = slotName, repItem = item })
						if self.options.debugTiming then ConPrintf("[top] %s %s: %+.3f", slotName, tostring(entry.name), score - current) end
						if score > current + 0.01 then
							t_insert(candidates, { kind = "item", slot = slotName, item = item, gain = score - current,
								label = string.format("%s's %s (%s)", who, entry.name or item.name, slotName) })
						end
					end
				end
			end
			-- their main link (supports this budget can buy)
			local group = self.mainGroup
			if group and #parts.supports > 0 and not self.triggerFixed then
				local saved = { }
				for k, g in ipairs(group.gemList) do saved[k] = g end
				local list, names = { saved[1] }, { }
				for _, sup in ipairs(parts.supports) do
					local gemId
					for id, gem in pairs(data.gems) do if gem.name == sup.name and gem.grantedEffect and gem.grantedEffect.support then gemId = id end end
					local gem = gemId and data.gems[gemId]
					local rules = GetGeneratorRules()
					local ownOk = gem and (not rules.ownDamageSupports[gem.name] or rules.ownDamageSupports[gem.name](self.mainGem))
					if gem and ownOk and not rules.excludedSupports[gem.name] and (investment.awakenedGems ~= false or not gem.tags.awakened) and (investment.exceptionalGems ~= false or not gem.tags.exceptional) and #list - 1 < (self.mainLinkLimit or 5) then
						t_insert(list, { level = self:GemLevel(gem), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
						t_insert(names, gem.name)
					end
				end
				group.gemList = list
				self.build.skillsTab:ProcessSocketGroup(group)
				local score = self:Score()
				group.gemList = saved
				self.build.skillsTab:ProcessSocketGroup(group)
				if score > current + 0.01 then
					t_insert(candidates, { kind = "supports", list = list, gain = score - current, label = string.format("%s's main link (%s)", who, table.concat(names, ", ")) })
				end
			end
		end
	end
	t_sort(candidates, function(a, b)
		local qa, qb = m_floor(a.gain * 1e9 + 0.5), m_floor(b.gain * 1e9 + 0.5)
		if qa ~= qb then return qa > qb end
		return a.label < b.label
	end)
	local kept, usedSlots, supportsDone = { }, { }, false
	local tries = 0
	for _, c in ipairs(candidates) do
		if tries >= (maxTries or 4) then break end
		if (c.kind == "item" and not usedSlots[c.slot]) or (c.kind == "supports" and not supportsDone) then
			tries = tries + 1
			local before = self:FullScore()
			local undo
			if c.kind == "item" then
				local slot = self.itemsTab.slots[c.slot]
				local previous = slot.selItemId
				local newItem = finder:Equip(c.item, c.slot, true)
				self.itemsTab:PopulateSlots()
				local savedGroups = self:SaveGroups()
				self:FitSockets()
				undo = function()
					self:RestoreGroups(savedGroups)
					slot:SetSelItemId(previous)
					self.itemsTab:DeleteItem(newItem, true)
					self.itemsTab:PopulateSlots()
				end
			else
				local group = self.mainGroup
				local saved = { }
				for k, g in ipairs(group.gemList) do saved[k] = g end
				group.gemList = c.list
				self.build.skillsTab:ProcessSocketGroup(group)
				undo = function()
					group.gemList = saved
					self.build.skillsTab:ProcessSocketGroup(group)
				end
			end
			self:AutoConfigure()
			local after = self:FullScore()
			if after > before + self:PriceCost(c.item) + 0.005 then
				if c.kind == "item" then usedSlots[c.slot] = true else supportsDone = true end
				t_insert(kept, string.format("%s %+.2f", c.label, after - before))
				if c.kind == "item" and (c.item.rarity == "UNIQUE" or c.item.rarity == "RELIC") then
					self.costs = self.costs or { }
					t_insert(self.costs, GetPriceSource():UniquePrice(c.item) or false)
				end
			else
				undo()
				self:AutoConfigure()
				self:Recalculate()
			end
		end
	end
	if #kept > 0 then
		self:Note("Taken from " .. (self.topSource or "the top players of the skill (poe.ninja)") .. ": " .. table.concat(kept, "; "))
	end
	return #kept
end

-- Uniques that make flasks permanent (Mageblood): worth nothing until the
-- flasks are chosen for them, so each one is equipped, the flasks are made
-- again around it, and the result is kept if the build is better
function BuildGeneratorClass:PermanentFlaskMove()
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	local list = { }
	for _, item in pairs(main.uniqueDB.list) do
		for _, modLine in ipairs(item.explicitModLines or { }) do
			if modLine.line:find("constantly apply their Flask Effects", 1, true) and finder:IsItemAllowed(item, filter) then
				t_insert(list, item)
				break
			end
		end
	end
	t_sort(list, function(a, b) return (a.title or a.name) < (b.title or b.name) end)
	local kept = 0
	for _, item in ipairs(list) do
		for _, slotName in ipairs(finder:GetActiveSlots()) do
			if self.itemsTab:IsItemValidForSlot(item, slotName) and not (self.lockedSlots and self.lockedSlots[slotName]) then
				local slot = self.itemsTab.slots[slotName]
				local equipped = self.itemsTab.items[slot.selItemId]
				if not (equipped and equipped.title == item.title) then
					local before = self:FullScore()
					local savedLog = #self.log
					local saved = { }
					for i = 1, 5 do
						local fs = self.itemsTab.slots["Flask " .. i]
						if fs then saved[i] = { id = fs.selItemId, active = fs.active } end
					end
					local previous = slot.selItemId
					local newItem = finder:Equip(item, slotName, true)
					self.itemsTab:PopulateSlots()
					self:MakeFlasks()
					if self.options.uniqueSweep ~= false then self:UniqueFlaskSweep() end
					local after = self:FullScore()
					if self.options.debugTiming then ConPrintf("[mageblood] %s in %s: %.3f -> %.3f", item.title or item.name, slotName, before, after) end
					if after > before + self:PriceCost(item) + 0.01 then
						kept = kept + 1
						local price = GetPriceSource():UniquePrice(item)
						self:Note(string.format("%s in %s with flasks made for it (+%.2f; %s)", item.title or item.name, slotName, after - before, GetPriceSource().FormatPrice(price)))
						self.costs = self.costs or { }
						t_insert(self.costs, price or false)
					else
						for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
						slot:SetSelItemId(previous)
						self.itemsTab:DeleteItem(newItem, true)
						for i, entry in pairs(saved) do
							local fs = self.itemsTab.slots["Flask " .. i]
							fs:SetSelItemId(entry.id)
							fs.active = entry.active
							if self.itemsTab.activeItemSet["Flask " .. i] then self.itemsTab.activeItemSet["Flask " .. i].active = entry.active end
						end
						self.itemsTab:PopulateSlots()
						self:Recalculate()
					end
					break
				end
			end
		end
	end
	return kept
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
	t_sort(gains, function(a, b)
		local qa, qb = m_floor(a.gain * 1e9 + 0.5), m_floor(b.gain * 1e9 + 0.5)
		if qa ~= qb then return qa > qb end
		if a.slot ~= b.slot then return a.slot < b.slot end
		return (a.item.title or a.item.name) < (b.item.title or b.item.name)
	end)
	local kept, usedSlots, usedItems = { }, { }, { }
	local tries = 0
	for _, entry in ipairs(gains) do
		if tries >= (maxTries or 5) then break end
		local title = entry.item.title or entry.item.name
		if not usedSlots[entry.slot] and not usedItems[title] then
			tries = tries + 1
			local before = self:FullScore()
			local slot = self.itemsTab.slots[entry.slot]
			local previous, wasActive = slot.selItemId, slot.active
			local newItem = finder:Equip(entry.item, entry.slot, true)
			slot.active = true
			if self.itemsTab.activeItemSet[entry.slot] then self.itemsTab.activeItemSet[entry.slot].active = true end
			self.itemsTab:PopulateSlots()
			local after = self:FullScore()
			if after > before + self:PriceCost(entry.item) + 0.005 then
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

-- Best anoints for an amulet (as many as it takes), chosen one after the
-- other: { item, score, entries } or nil if none helps
function BuildGeneratorClass:BestAnoints(extras, amulet, baseScore)
	local candidates = extras:AnointCandidates(self.options.investment)
	local item, score, entries = amulet, baseScore, { }
	local taken = { }
	for k = 1, extras.AnointSlots(amulet) do
		local best, bestScore, bestEntry
		for _, entry in ipairs(candidates) do
			if not taken[entry.node.dn] then
				local copy = extras:AnointedCopy(item, entry.node, k > 1)
				local s = self:Score({ repSlotName = "Amulet", repItem = copy })
				if not bestScore or s > bestScore + 1e-9 then best, bestScore, bestEntry = copy, s, entry end
			end
		end
		if not best or bestScore <= score + 0.002 then break end
		item, score = best, bestScore
		taken[bestEntry.node.dn] = true
		t_insert(entries, bestEntry)
		self:Tick()
	end
	if #entries == 0 then return nil end
	return { item = item, score = score, entries = entries }
end

-- Best anoint for the amulet within the investment level; amulets with
-- several anoints (Stranglegasp: four) are also tried in its place, each
-- with its best anoints - worth nothing bare, a lot anointed
function BuildGeneratorClass:ChooseAnoint()
	local extras = new("TreeExtras"):TreeExtras(self.build)
	local slot = self.itemsTab.slots["Amulet"]
	local amulet = slot and self.itemsTab.items[slot.selItemId]
	self:Recalculate()
	local current = self:Score()
	local best = extras:CanAnoint(amulet) and self:BestAnoints(extras, amulet, current) or nil
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.options.investment }
	-- (an amulet the build is built around stays: only anointed)
	local locked = self.lockedSlots and self.lockedSlots["Amulet"]
	for _, item in pairs(locked and { } or main.uniqueDB.list) do
		if item.type == "Amulet" and extras.AnointSlots(item) > 1 and extras:CanAnoint(item) and finder:IsItemAllowed(item, filter) then
			local bare = new("Item"):Item(item:BuildRaw())
			bare:BuildAndParseRaw()
			local bareScore = self:Score({ repSlotName = "Amulet", repItem = bare })
			local option = self:BestAnoints(extras, bare, bareScore)
			if option and option.score > (best and best.score or current) + 0.002 then
				option.unique = bare
				best = option
			end
		end
	end
	if best and best.score > current + 0.002 then
		self:Equip(best.item, "Amulet")
		self.itemsTab:PopulateSlots()
		local names = { }
		for _, entry in ipairs(best.entries) do
			t_insert(names, string.format("%s (%s)", entry.node.dn, GetPriceSource().FormatPrice(entry.price)))
			self.costs = self.costs or { }
			t_insert(self.costs, entry.price or false)
		end
		if best.unique then
			local price = GetPriceSource():UniquePrice(best.unique)
			t_insert(self.costs, price or false)
			self:Note(string.format("Amulet: %s (%s), for its %d anoints: %s", best.unique.title or best.unique.name, GetPriceSource().FormatPrice(price), #best.entries, table.concat(names, ", ")))
		else
			self:Note("Anoint: " .. table.concat(names, ", "))
		end
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
			if not best or idea.score > best.score + 1e-9 then best = idea end
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

-- Upgrades the open build instead of making one: its main skill, class,
-- tree, gear and gems are the start, and the late steps of a generation run
-- on it within the investment level (or total budget), each change kept only
-- when the build is better: supports, ascendancy, every affordable unique,
-- rares made for the build, jewels, anoint, tattoos, flasks, the tree,
-- conditions and unique combos, rebuild-and-repair rounds. Returns what Run
-- returns, plus .before (the build's own numbers) for the comparison.
function BuildGeneratorClass:Upgrade()
	local opts = self.options
	local build = self.build
	self.lastYield = GetTime()
	self.startClock = os.clock()
	self.costs = { }
	self.stageCount = 6
	local function stage(index, label)
		if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
		self.stageIndex, self.stage = index, label
		self.subProgress, self.moveFrom, self.moveTo = 0, 0, 1
		self:Tick()
	end
	self:PrepareOptions()
	stage(1, "Reading the build")
	if opts.learntNote then self:Note(opts.learntNote) end
	if opts.focus and opts.focus.label and opts.focus.label:find("reviewed", 1, true) then self:Note("Aimed at: " .. opts.focus.label) end
	-- the build's main skill, class and level
	local skillsTab = build.skillsTab
	local group = skillsTab.socketGroupList[build.mainSocketGroup]
	local first
	for _, g in ipairs(group and group.gemList or { }) do
		if g.gemData and not g.gemData.grantedEffect.support then first = g break end
	end
	if not first then error("the build has no main skill to upgrade (choose one in the Skills tab)") end
	self.mainGroup, self.mainGem = group, first.gemData
	opts.gemId = first.gemId
	opts.classId, opts.ascendClassId = build.spec.curClassId, build.spec.curAscendClassId
	opts.level = build.characterLevel
	self.className, self.ascendName = build.spec.curClassName, build.spec.curAscendClassName
	self.bloodlineId = build.spec.curSecondaryAscendClassId
	local sockets = new("GemSetup"):GemSetup(self):SlotSockets(group.slot or "Body Armour")
	self.mainLinkLimit = m_max(1, m_min(5, (sockets > 0 and sockets or #group.gemList) - 1))
	self.lockedSlots = { }
	self:SetupScorer()
	self.scorer.useChecklist = true
	self:InitKnowledge()
	self:WrapSteps()
	self:AutoConfigure()
	local beforeScore, beforeResult = self:FullScore()
	local beforeCost = self:BuildCost()
	local beforeHit = self.scorer:MinMaxHit(build.calcsTab.mainOutput) or 0
	self:Note(string.format("Upgrading %s (%s, level %d): score %.2f, %s DPS, max hit %s, about %s",
		self.mainGem.name, self.ascendName or self.className or "?", build.characterLevel, beforeScore,
		formatNumSep(math.floor(beforeResult.dps or 0)), formatNumSep(math.floor(beforeHit)),
		GetPriceSource().FormatPrice(beforeCost)))

	stage(2, "Supports and ascendancy")
	self:Move(1, 2, "Supports of the main skill")
	self:FinalSupports()
	self:Move(2, 2, "Ascendancy")
	self:AscendancyRecheck()

	stage(3, "Uniques and rares")
	self:Move(1, 3, "Every affordable unique")
	if opts.uniqueSweep ~= false then self:UniqueSweep() end
	self:Move(2, 3, "Rares made for the build")
	if opts.finalRares ~= false then self:FinalRares() end
	self:Move(3, 3, "Flasks")
	if opts.uniqueSweep ~= false then self:UniqueFlaskSweep() end
	if opts.permanentFlasks ~= false then self:PermanentFlaskMove() end

	stage(4, "Jewels, anoint, tattoos, pantheon")
	self:Move(1, 4, "Jewels")
	if opts.jewels ~= false then self:FillEmptySockets() end
	if opts.timeless ~= false then self:ChooseTimelessJewel() end
	if opts.metaJewels ~= false then self:ChooseMetaJewels() end
	self:Move(2, 4, "Anoint")
	if opts.allowAnoints ~= false then self:ChooseAnoint() end
	self:Move(3, 4, "Tattoos")
	if opts.allowTattoos ~= false then self:ChooseTattoos() end
	self:Move(4, 4, "Pantheon and bandit")
	self:ChoosePantheonAndBandit()

	stage(5, "Passive tree, conditions and combos")
	self:Move(1, 3, "Passive tree")
	self:OptimizeTree()
	self:Move(2, 3, "Damage behind conditions and unique combos")
	if opts.conditionAudit ~= false then
		local ok, err = pcall(function() self:ConditionEnablerMove(1) end)
		if not ok then ConPrintf("Condition audit failed: %s", tostring(err)) end
	end
	if opts.uniqueCombos ~= false then
		local ok, err = pcall(function() self:UniqueCombosMove(1) end)
		if not ok then ConPrintf("Unique combos failed: %s", tostring(err)) end
	end
	self:Move(3, 3, "Rebuilding parts of the build")
	if self.know then
		local ok, err = pcall(function() self:PastBuildsMove() end)
		if not ok then ConPrintf("Past builds failed: %s", tostring(err)) end
	end
	if (opts.repairRounds or 6) > 0 then self:RepairSearch(opts.repairRounds or 6) end

	stage(6, "Finishing")
	if opts.totalBudget then
		local ok, err = pcall(function() self:FitTotalBudget() end)
		if not ok then ConPrintf("Fitting the total budget failed: %s", tostring(err)) end
	end
	if opts.requirements ~= false then self:RequirementsMove() end
	self:RemoveUnusedItems()
	if self:FitSockets() then self:Note("Gem setups packed again to fit the items' sockets") end
	self:SanitizeRares()
	if opts.upgradeOrder ~= false then
		local ok, err = pcall(function() self:UpgradeOrder() end)
		if not ok then ConPrintf("Upgrade order failed: %s", tostring(err)) end
	end
	self:AutoConfigure()
	self:Recalculate()
	local final = self.scorer:Evaluate(self.calcFunc, { })
	self.final = final
	build.buildFlag = true
	self:FinishKnowledge(final, "upgrade", beforeResult)
	local afterCost = self:BuildCost()
	self:Note(string.format("Upgraded: score %.2f -> %.2f, DPS %s -> %s, max hit %s -> %s, cost about %s -> %s",
		beforeScore, final.score, formatNumSep(math.floor(beforeResult.dps or 0)), formatNumSep(math.floor(final.dps or 0)),
		formatNumSep(math.floor(beforeHit)), formatNumSep(math.floor(self.scorer:MinMaxHit(build.calcsTab.mainOutput) or 0)),
		GetPriceSource().FormatPrice(beforeCost), GetPriceSource().FormatPrice(afterCost)))
	local prices = GetPriceSource()
	return {
		log = self.log, final = final, before = beforeResult, ideas = { }, knowledge = self.knowRecords,
		configChanges = self.configChanges or { },
		costLine = prices.loaded and string.format("Estimated cost of the upgraded build: %s (it was about %s)", prices.FormatPrice(afterCost), prices.FormatPrice(beforeCost))
			or "Prices not loaded: uniques, anoints and tattoos were not filtered by price",
		assumptions = {
			"Investment level: " .. opts.investment.label,
			"Configuration set automatically for: " .. ((opts.configScenario and opts.configScenario.label) or "Pinnacle boss") .. " (your own configuration was replaced)",
			"Your items, gems and passives were the start; every change was kept only if it scored better",
		},
	}
end

------------------------------------------------------------------------------
-- Knowledge from earlier generations (Modules/GeneratorKnowledge)
------------------------------------------------------------------------------

-- Optional late steps: skipped for a kind of build where they never helped
local skippableSteps = {
	"ChooseMetaUniques", "UniqueSweep", "ChooseArchetypeJewels", "AddJewels", "ChooseTimelessJewel", "ChooseMetaJewels",
	"ChooseRadiusJewels", "ChooseClusterJewels", "ChooseAnoint", "ChooseTattoos", "UniqueFlaskSweep", "PermanentFlaskMove",
	"FlaskEnchantMove", "AuraStackMove", "FillMainLinkMove", "ApplySynergies", "JointMoves", "UniqueCombosMove",
	"ConditionEnablerMove", "CrossIdeasMove", "LearnFromTopBuilds", "PopularPassivesMove", "AscendancyRecheck",
	"FinalSupports", "PairAilments", "PearlMove", "CorruptionMove", "SupremeOstentationMove", "BossSkillMove", "PastBuildsMove",
}
-- (measured, never skipped)
local recordedSteps = { "FinalRares", "OptimizeTree", "RepairSearch" }

-- Knowledge on for this generation (full builds; options.knowledge)
function BuildGeneratorClass:InitKnowledge()
	local opts = self.options
	if opts.knowledge ~= true and not opts.decisionLog then return end
	local ok, know = pcall(LoadModule, "Modules/GeneratorKnowledge")
	if not ok or not know then return end
	-- (every choice measured is logged, quick builds included)
	self.decisions = { }
	self.knowModule = know
	if opts.knowledge ~= true then return end
	self.know = know
	know.Load()
	self.knowCtx = know.StepContext(opts, self.mainGem)
	self.knowRecords = { steps = { }, builds = { } }
	self.skippedSteps = { }
end

-- One choice the generation measured (Modules/GeneratorKnowledge decisions):
-- kind ("support", "passive", "unique", "step", "note"...), what, its score
-- gain, whether it was kept, and extra fields
function BuildGeneratorClass:Decision(kind, name, gain, kept, extra)
	if not self.decisions then return end
	local d = { k = kind, n = name, step = self.stepName or self.stage }
	if gain then d.g = m_floor(gain * 1e5 + 0.5) / 1e5 end
	if kept then d.kept = true end
	for key, v in pairs(extra or { }) do d[key] = v end
	t_insert(self.decisions, d)
end

-- The late steps measured (score before and after, seconds) and the ones that
-- never helped this kind of build skipped: each method wrapped on this
-- generator only; a step called from inside another one isn't counted again
function BuildGeneratorClass:WrapSteps()
	if not self.know or self.stepsWrapped then return end
	self.stepsWrapped = true
	self.stepDepth = 0
	local know = self.know
	local function wrap(name, canSkip)
		local original = BuildGeneratorClass[name]
		if not original then return end
		self[name] = function(gen, ...)
			if gen.stepDepth > 0 then return original(gen, ...) end
			if canSkip then
				local skip, reason = know.ShouldSkip(gen.knowCtx, name)
				if skip then
					t_insert(gen.skippedSteps, name)
					gen:Decision("step", name, nil, false, { skipped = true })
					return 0
				end
			end
			local before = gen:FullScore()
			local t0 = os.clock()
			gen.stepDepth = gen.stepDepth + 1
			local savedStep = gen.stepName
			gen.stepName = name
			local results = { pcall(original, gen, ...) }
			gen.stepName = savedStep
			gen.stepDepth = gen.stepDepth - 1
			if not results[1] then error(results[2], 0) end
			local after = gen:FullScore()
			t_insert(gen.knowRecords.steps, { context = gen.knowCtx, step = name, gain = after - before, seconds = os.clock() - t0 })
			gen:Decision("step", name, after - before, after - before > 0.005, { sec = m_floor((os.clock() - t0) * 10 + 0.5) / 10, before = m_floor(before * 1e4 + 0.5) / 1e4 })
			return unpack(results, 2)
		end
	end
	for _, name in ipairs(skippableSteps) do wrap(name, true) end
	for _, name in ipairs(recordedSteps) do wrap(name, false) end
end

-- The best builds earlier generations made for the same skill, ascendancy,
-- budget, focus and configuration: their gear, main link and passives tried
-- in this build like the top players' (LearnFromTopBuilds, PopularPassivesMove)
function BuildGeneratorClass:PastBuildsMove()
	if not self.know or not self.mainGem then return 0 end
	local key = self.know.BuildKey(self.options, self.mainGem.name, self.build.spec.curAscendClassName)
	local past = self.know.Past(key)
	if #past == 0 then return 0 end
	local tops = { }
	for i, entry in ipairs(past) do
		t_insert(tops, { name = string.format("your earlier build %d (score %.2f)", i, entry.score or 0), parts = entry.parts })
	end
	local savedMeta, savedParts, savedSource = self.options.meta, self.topParts, self.topSource
	self.options.meta = { details = { topBuilds = tops } }
	self.topParts, self.topSource = nil, "earlier generations of this build"
	local kept = 0
	local ok, err = pcall(function()
		kept = self:LearnFromTopBuilds(4)
		if #tops >= 3 then kept = kept + self:PopularPassivesMove(3) end
	end)
	if not ok then ConPrintf("Past builds move failed: %s", tostring(err)) end
	self.options.meta, self.topParts, self.topSource = savedMeta, savedParts, savedSource
	return kept
end

-- The finished build remembered, and what this generation learnt written
-- (by the main thread; workers send it back with their result)
function BuildGeneratorClass:FinishKnowledge(final, mode, before)
	if not self.knowModule then return end
	local opts = self.options
	-- the run line of the decision log: the build's context and its result
	local tags = { }
	for tag in pairs(self.mainGem and self.mainGem.tags or { }) do t_insert(tags, tag) end
	t_sort(tags)
	local focus = opts.focus or { }
	local extra = { }
	for _, e in ipairs(focus.extra or { }) do extra[e.stat] = e.weight end
	local output = self.build.calcsTab.mainOutput or { }
	local run = {
		id = string.format("%d-%06d", os.time(), math.random(0, 999999)), mode = mode or (opts.quick and "quick" or "generate"),
		skill = self.mainGem and self.mainGem.name, tags = tags, class = self.build.spec.curClassName, ascendancy = self.build.spec.curAscendClassName,
		level = self.build.characterLevel, investment = opts.investment and (opts.investment.baseId or opts.investment.id), budget = opts.investment and opts.investment.totalBudget,
		focus = { id = focus.id, dps = focus.dps, ehp = focus.ehp, avoid = focus.avoid, clear = focus.clear, hitFloor = opts.hitFloor or focus.hitFloor, goals = extra },
		config = opts.configScenario and opts.configScenario.id or "BOSS", archetype = opts.archetype and opts.archetype.id, variant = opts.variant,
		seconds = m_floor(os.clock() - (self.startClock or os.clock())),
		final = final and { score = final.score, dps = final.dps, ehp = final.ehp, minHit = (self.scorer:MinMaxHit(output)), move = output.EffectiveMovementSpeedMod } or nil,
		before = before and { score = before.score, dps = before.dps, ehp = before.ehp } or nil,
		decisions = #(self.decisions or { }),
	}
	if not self.know then
		-- (decision log only: the benchmark's file)
		pcall(self.knowModule.AppendDecisions, run, self.decisions, opts.decisionLog)
		return
	end
	self.knowRecords.run, self.knowRecords.decisions = run, self.decisions
	if #self.skippedSteps > 0 then
		self:Note(string.format("Skipped, as they improved none of the last builds like this one (learnt): %s", table.concat(self.skippedSteps, ", ")))
	end
	if final and final.score and self.mainGem and not opts.quick then
		local key = self.know.BuildKey(self.options, self.mainGem.name, self.build.spec.curAscendClassName)
		local ok, parts = pcall(self.know.Parts, self.build)
		if ok then
			t_insert(self.knowRecords.builds, { key = key, entry = { score = final.score, dps = final.dps, ehp = final.ehp,
				archetype = self.options.archetype and self.options.archetype.id, time = os.time(), parts = parts } })
		end
	end
	if self.options.knowledgeWrite ~= false then
		local ok, err = pcall(self.know.Commit, self.knowRecords)
		if not ok then ConPrintf("Writing the generator knowledge failed: %s", tostring(err)) end
	end
end

-- The player's unique choices, the investment level and rare quality
function BuildGeneratorClass:PrepareOptions()
	local opts = self.options
	-- the player's excluded / forced uniques (the window's "Uniques..." list)
	do
		local rules = GetGeneratorRules()
		rules.userExcluded, rules.userForced = { }, { }
		for title in pairs(opts.excludedUniques or { }) do rules.userExcluded[title] = true end
		for _, title in ipairs(opts.forcedUniques or { }) do rules.userForced[title] = true end
	end
	-- Investment level decides rare quality and influences unless set
	local probe = new("PriceSource"):PriceSource()
	opts.investment = opts.investment or probe.levels[probe.defaultLevel]
	if not opts.quality then
		local finderProbe = new("BestItemFinder"):BestItemFinder(self.itemsTab)
		opts.quality = finderProbe.rareQualityList[opts.investment.quality or 2]
	end
end

-- The scorer for the options (focus, budget tier, configuration, archetype lens)
function BuildGeneratorClass:SetupScorer()
	local opts = self.options
	self.overlap = new("HitOverlap"):HitOverlap(self.build, opts.scenario)
	local bossFight = not opts.configScenario or opts.configScenario.boss and true or false
	opts.chargesPerSecond = opts.chargesPerSecond or (bossFight and 1.5 or 4)
	self.scorer = new("BuildScorer"):BuildScorer(self.build, { focus = opts.focus, chargesPerSecond = opts.chargesPerSecond, overlap = self.overlap, ehpFloor = opts.ehpFloor, hitFloor = opts.hitFloor,
		bossTier = opts.investment and opts.investment.awakenedGems and "uber" or "pinnacle" })
	self.scorer.useChecklist = false -- on from the flask stage
	-- (Clearing + bossing: clear speed counts more than the focus says)
	if opts.configScenario and opts.configScenario.clear then self.scorer.clearBoost = opts.clearBoost or 0.35 end
	-- (buffs that only exist while clearing - Headhunter's stolen modifiers -
	-- count for clear speed when the build is made for clearing too)
	self.scorer.clearBuffs = (opts.configScenario and (opts.configScenario.clear or not opts.configScenario.boss)) or (opts.focus and opts.focus.id and opts.focus.id:match("^CLEAR") ~= nil) or nil
	-- the archetype's stacked stat, valued on its own while the build is made
	if opts.archetype and opts.archetype.lens and opts.statLens ~= false then
		self.scorer.lens = opts.archetype.lens
		if opts.lensWeight then
			self.scorer.lens = copyTable(opts.archetype.lens, true)
			self.scorer.lens.weight = opts.lensWeight
		end
		self:Note(string.format("Commitment: %s is valued on its own while the build is made (gear, passives, jewels follow it)", opts.archetype.lens.label or opts.archetype.lens.stat))
	end
	-- (a hybrid's second stacked stat)
	if opts.archetype and opts.archetype.lens2 and opts.statLens ~= false then
		self.scorer.lens2 = opts.archetype.lens2
		self:Note(string.format("Commitment: %s too", opts.archetype.lens2.label or opts.archetype.lens2.stat))
	end
	-- (A/B options: weight of avoidance in tankiness, weight of tankiness)
	self.scorer.avoidanceWeight = opts.avoidanceWeight
	self.scorer.pastTarget = opts.pastTarget
	self.scorer.fightWeight = opts.fightWeight
	if opts.ehpWeight and self.scorer.focus then
		self.scorer.focus = copyTable(self.scorer.focus, true)
		self.scorer.focus.ehp = opts.ehpWeight
	end
end

function BuildGeneratorClass:Run()
	local opts = self.options
	self.lastYield = GetTime()
	self.startClock = os.clock()
	self.overlap = nil
	self.costs = { }
	self.stageCount = opts.quick and 7 or 12
	local function stage(index, label)
		-- big searches leave a lot of garbage: free it between stages when it
		-- piled up (a full collection of the game data takes a second)
		if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
		if opts.debugTiming and self.scorer then
			local _, r = self:FullScore()
			ConPrintf("[stage] before %d: score %.3f dps %.0f ehp %.0f lua %.0f MB t=%.0fs", index, r.score, r.dps, r.ehp, collectgarbage("count") / 1024, os.clock() - (self.startClock or 0))
		end
		self.stageIndex, self.stage = index, label
		self.subProgress, self.moveFrom, self.moveTo = 0, 0, 1
		self:Tick()
	end
	self:PrepareOptions()

	stage(1, "Setting up the character and configuration")
	if opts.learntNote then self:Note(opts.learntNote) end
	self:Setup()
	self:InitKnowledge()
	self:SetupScorer()
	if opts.archetype then
		self:Note("Archetype: " .. opts.archetype.label)
	end
	-- trigger archetypes: the spell linked with what triggers it (Classes/TriggerSetups)
	if opts.archetype and opts.archetype.trigger then
		new("TriggerSetups"):TriggerSetups().Apply(self, opts.archetype.trigger)
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
	self:ForceUniques()
	self:ApplyArchetypeUniques()
	if opts.statPlan ~= false then self:PlanStatTarget("with the archetype's uniques") end

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
	if opts.quick then self.moveFrom, self.moveTo = 0, 0.6 end
	self:AllocateTree()
	if opts.quick then
		self:Move(2, 2, "Trying uniques, a Watcher's Eye and the supports again")
		self.moveFrom = 0.6
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
		if self.skillProfileNote then self:Note("Main skill as used in a fight: " .. self.skillProfileNote) end
		-- (the archetype's stat lens left out: archetypes compared as they are)
		self.scorer.lens = nil
	self.scorer.lens2 = nil
		local final = self.scorer:Evaluate(self.calcFunc, { })
		self.final = final
		self.build.buildFlag = true
		self:FinishKnowledge(final)
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
	-- (the plan again with the first gear: the target follows what the build reached)
	if opts.statPlan ~= false and self.scorer.lens then self:PlanStatTarget("with the first gear") end
	self:FullScore()
	self:MakeRares(true)

	stage(9, "Choosing gem setups, jewels, anoint and tattoos")
	-- (from here on, steps are measured and the useless ones skipped: Modules/GeneratorKnowledge)
	self:WrapSteps()
	self:FullScore()
	self:Move(1, 10, "Choosing gem setups")
	self:ChooseUtilityGems()
	self:Move(2, 10, "Uniques players of the skill use")
	self:ChooseMetaUniques()
	if opts.uniqueSweep ~= false then
		self:Move(3, 10, "Trying every affordable unique")
		self:UniqueSweep()
	end
	self:Move(4, 10, "Archetype jewels")
	self:ChooseArchetypeJewels()
	self:Move(5, 10, "Rare jewels")
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseMetaUniques', r.score, r.dps, r.ehp) end
	if opts.jewels ~= false then self:AddJewels(opts.maxJewels or 4) end
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'AddJewels', r.score, r.dps, r.ehp) end
	self:Move(6, 10, "Timeless jewel")
	if opts.timeless ~= false then self:ChooseTimelessJewel() end
	self:Move(7, 10, "Forbidden, Watcher's Eye, Split Personality and other unique jewels")
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseTimelessJewel', r.score, r.dps, r.ehp) end
	if opts.metaJewels ~= false then self:ChooseMetaJewels() end
	if opts.radiusJewels ~= false then self:ChooseRadiusJewels() end
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseMetaJewels', r.score, r.dps, r.ehp) end
	self:Move(8, 10, "Cluster jewels")
	if opts.clusterJewels ~= false then self:ChooseClusterJewels(opts.maxClusterJewels or 2) end
	if collectgarbage("count") > 900 * 1024 then collectgarbage("collect") end
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseClusterJewels', r.score, r.dps, r.ehp) end
	-- spend any points the jewel stages freed
	self:Move(9, 10, "Passive points freed by the jewels")
	self:Recalculate()
	self:AllocateTree(true)
	self:Move(10, 10, "Anoint and tattoos")
	if opts.allowAnoints ~= false then self:ChooseAnoint() end
	if opts.allowTattoos ~= false then self:ChooseTattoos() end

	stage(10, "Choosing flasks, pantheon and bandit")
	self.scorer.useChecklist = true
	self:FullScore()
	self:Move(1, 6, "Flasks")
	self:MakeFlasks()
	if opts.uniqueSweep ~= false then self:UniqueFlaskSweep() end
	if opts.permanentFlasks ~= false then self:PermanentFlaskMove() end
	if opts.flaskEnchants ~= false then self:FlaskEnchantMove() end
	self:Move(2, 6, "Pantheon and bandit")
	self:ChoosePantheonAndBandit()
	-- an Animate Guardian wearing uniques that buff nearby allies (when the build has one)
	if opts.animateGuardian ~= false and self:HasGem("Animate Guardian") then
		local ok, err = pcall(function() new("AnimateGuardianSetup"):AnimateGuardianSetup(self):Run() end)
		if not ok then ConPrintf("Animate Guardian setup failed: %s", tostring(err)) end
	end
	if opts.auraStacking ~= false then
		self:Move(3, 6, "Trying aura stacking")
		self:AuraStackMove()
	end
	if opts.fillMainLink ~= false then
		self:Move(4, 6, "Filling the main link")
		self:FillMainLinkMove()
	end
	if opts.finalRares ~= false then
		self:Move(5, 6, "Making the rares again for the finished build")
		self:FinalRares()
		-- gear and tree made for each other: passives again for the new rares,
		-- rares again for the new passives, until neither gains
		local alternated = 0
		for _ = 1, opts.alternateRounds or 2 do
			local tree = self:RefineTree(10)
			if tree < 0.01 then break end
			alternated = alternated + tree
			local rares = self:FinalRares()
			alternated = alternated + (rares or 0)
			if (rares or 0) < 0.01 then break end
		end
		if alternated > 0.005 then self:Note(string.format("Passives and rares adjusted to each other in turns: score %+.3f", alternated)) end
	end

	stage(11, "Looking for unique items, synergies and the top players' gear")
	if opts.synergies ~= false then
		self:Move(1, 3, "Looking for unique items and synergies")
		self:ApplySynergies(opts.synergyRounds or 1)
	end
	if opts.jointMoves ~= false then
		self:Move(2, 3, "Trying packages from top players")
		self:JointMoves(opts.jointMoveRounds or 2)
	end
	if opts.uniqueCombos ~= false then
		self:Move(3, 3, "Trying unique combos")
		local ok, err = pcall(function() self:UniqueCombosMove(1) end)
		if not ok then ConPrintf("Unique combos failed: %s", tostring(err)) end
	end
	if opts.conditionAudit ~= false then
		self:Move(3, 3, "Damage behind conditions: what keeps them up")
		local ok, err = pcall(function() self:ConditionEnablerMove(2) end)
		if not ok then ConPrintf("Condition audit failed: %s", tostring(err)) end
	end
	if opts.crossIdeas ~= false then
		self:Move(3, 3, "Trying the ideas of the other archetypes")
		local ok, err = pcall(function() self:CrossIdeasMove(1) end)
		if not ok then ConPrintf("Cross ideas failed: %s", tostring(err)) end
	end
	-- the best builds earlier generations made for the same build
	if self.know then
		self:Move(3, 3, "Trying what earlier generations of this build found")
		local ok, err = pcall(function() self:PastBuildsMove() end)
		if not ok then ConPrintf("Past builds failed: %s", tostring(err)) end
	end
	if opts.learnFromTop ~= false then
		self:Move(3, 3, "Trying the top players' gear and links")
		local ok, err = pcall(function() self:LearnFromTopBuilds() end)
		if not ok then ConPrintf("Learning from top builds failed: %s", tostring(err)) end
		ok, err = pcall(function() self:PopularPassivesMove() end)
		if not ok then ConPrintf("Popular passives failed: %s", tostring(err)) end
	end
	stage(12, "Finishing: ascendancy, supports and passive tree")
	self:Move(1, 6, "Choosing the ascendancy again")
	if opts.ascendancyRecheck ~= false then self:AscendancyRecheck() end
	if opts.finalSupports ~= false then
		self:Move(2, 6, "Choosing the supports again")
		-- (new supports can want other passives: a short tree round when they change)
		if self:FinalSupports() > 0 then self:RefineTree(10) end
	end
	self:Move(3, 6, "Ailments the build can inflict")
	self:PairAilments()
	self:Move(4, 6, "Optimizing the passive tree")
	self:OptimizeTree()
	-- a second, cheap round: the rebuilt tree can want other supports or
	-- ascendancy notables (and those other passives)
	if opts.polishRound ~= false then
		local gain = 0
		-- (auras again: the finished tree and gear can pay for more of them)
		self:Move(5, 6, "Aura stacking on the finished build")
		if opts.auraStacking ~= false then self:AuraStackMove() end
		self:Move(6, 6, "Supports and ascendancy once more")
		if opts.finalSupports ~= false then gain = gain + self:FinalSupports() end
		if opts.ascendancyRecheck ~= false then gain = gain + self:AscendancyRecheck() end
		if gain > 0 then
			local tree = self:RefineTree(10)
			if tree > 0.001 then self:Note(string.format("Passive tree adjusted for them: score %+.3f", tree)) end
		end
	end

	-- Pearl of Tsoatha: the main skill's 6-link moved off the body armour
	if opts.pearl ~= false then
		local ok, err = pcall(function() self:PearlMove() end)
		if not ok then ConPrintf("Pearl move failed: %s", tostring(err)) end
	end
	-- corrupted implicits (Endgame / Mirror)
	if opts.corruption ~= false then
		local ok, err = pcall(function() self:CorruptionMove() end)
		if not ok then ConPrintf("Corruption move failed: %s", tostring(err)) end
	end
	-- Supreme Ostentation: no attribute requirements, tree and rares rebuilt (High+)
	if opts.ostentation ~= false then
		local ok, err = pcall(function() self:SupremeOstentationMove() end)
		if not ok then ConPrintf("Supreme Ostentation move failed: %s", tostring(err)) end
	end
	-- a second skill for bosses (builds made for clearing)
	if opts.bossSkill ~= false then
		local ok, err = pcall(function() self:BossSkillMove() end)
		if not ok then ConPrintf("Boss skill move failed: %s", tostring(err)) end
	end
	-- the finished build partly rebuilt, again and again (large neighbourhood search)
	if (opts.repairRounds or 8) > 0 then
		self:Move(6, 6, "Rebuilding parts of the build to improve it")
		self:RepairSearch(opts.repairRounds or 8)
	end
	-- utility gems that add nothing taken out
	if opts.pruneGems ~= false then
		local ok, err = pcall(function() self:PruneUselessGems() end)
		if not ok then ConPrintf("Pruning gems failed: %s", tostring(err)) end
	end
	-- total budget: the parts worth least per divine made cheap until it fits
	if opts.totalBudget then
		local ok, err = pcall(function() self:FitTotalBudget() end)
		if not ok then ConPrintf("Fitting the total budget failed: %s", tostring(err)) end
	end
	-- hard requirements (resistances, attributes) fixed with bench crafts
	if opts.requirements ~= false then self:RequirementsMove() end
	-- (no allocated jewel socket left empty)
	do
		local ok, err = pcall(function() self:FillEmptySockets() end)
		if not ok then ConPrintf("Filling jewel sockets failed: %s", tostring(err)) end
	end
	self:RemoveUnusedItems()
	-- (last check: every gem setup fits its item's sockets)
	if self:FitSockets() then self:Note("Gem setups packed again to fit the items' sockets") end
	-- (no impossible rare in the finished build: Eldritch implicits stay off influenced items)
	self:SanitizeRares()
	self:AutoConfigure()
	self:Recalculate()
	-- what each bought part is worth, best value first (not for quick builds)
	if opts.upgradeOrder ~= false and not opts.quick then
		local ok, err = pcall(function() self:UpgradeOrder() end)
		if not ok then ConPrintf("Upgrade order failed: %s", tostring(err)) end
		self:AutoConfigure()
		self:Recalculate()
	end
	if self.skillProfileNote then self:Note("Main skill as used in a fight: " .. self.skillProfileNote) end
	-- (the archetype's stat lens left out: archetypes compared as they are)
	self.scorer.lens = nil
	self.scorer.lens2 = nil
	local final = self.scorer:Evaluate(self.calcFunc, { })
	self.final = final
	self.build.buildFlag = true
	self:FinishKnowledge(final)
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
	-- (top players: only shown, for comparison)
	local shown = self.options.meta or self.options.metaShown
	local details = shown and shown.details
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
	-- what the build is built around and what carries it (each part taken
	-- out alone: the score, damage and max hit it would lose)
	if opts.explain ~= false then pcall(function() self:Explain(final) end) end
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
		local buildTotal, entries = self:BuildCost()
		local noPrice = 0
		for _, e in ipairs(entries) do if not e.known then noPrice = noPrice + 1 end end
		costLine = string.format("Estimated cost of the build: %s (uniques, anoints, tattoos and gems at poe.ninja prices, rares about %s each)%s",
			prices.FormatPrice(buildTotal), prices.FormatPrice(opts.investment.rarePrice), noPrice > 0 and string.format(", plus %d part%s with no price", noPrice, noPrice == 1 and "" or "s") or "")
	end
	return {
		log = self.log,
		final = final,
		ideas = self.ideas or { },
		configChanges = self.configChanges or { },
		costLine = costLine,
		knowledge = self.knowRecords,
		assumptions = {
			"Investment level: " .. opts.investment.label,
			"Main skill in a 6-link body armour, utility setups in the helmet, gloves, boots and weapon sockets; gems at their normal maximum level with 20% quality",
			"Abyss jewels are not used; cluster jewels are Large ones with 8 passives",
			"Configuration set automatically for: " .. ((opts.configScenario and opts.configScenario.label) or "Pinnacle boss") .. ", see the changes below",
			"Rares use " .. ((opts.quality and opts.quality.label) or "tier 2-3, average rolls") .. (opts.crafts ~= false and ", with up to one crafting bench mod" or ""),
		},
	}
end
