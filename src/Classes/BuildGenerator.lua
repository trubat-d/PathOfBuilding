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

-- Lists the active skill gems that can be the main skill of a generated build
function BuildGeneratorClass.SkillList()
	local list = { }
	for gemId, gem in pairs(data.gems) do
		local effect = gem.grantedEffect
		if effect and not effect.support and gem.tags and gem.tags.grants_active_skill and not gem.vaalGem and not effect.unsupported
			and not (gem.tags.aura or gem.tags.herald or gem.tags.guard or gem.tags.movement or gem.tags.travel or gem.tags.blink or gem.tags.warcry and not gem.tags.attack) then
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

function BuildGeneratorClass:FullScore()
	self:Recalculate()
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
		{ level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = opts.gemId },
	} }
	t_insert(build.skillsTab.socketGroupList, group)
	build.skillsTab:ProcessSocketGroup(group)
	build.mainSocketGroup = #build.skillsTab.socketGroupList
	self.mainGroup = group

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
function BuildGeneratorClass:ChooseSupports(maxSupports)
	local group = self.mainGroup
	local supports = { }
	for gemId, gem in pairs(data.gems) do
		local investment = self.options.investment or { }
		local tags = gem.tags or { }
		local affordable = (investment.awakenedGems ~= false or not tags.awakened) and (investment.exceptionalGems ~= false or not tags.exceptional)
		if gem.grantedEffect and gem.grantedEffect.support and not gem.grantedEffect.unsupported and affordable
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
		t_insert(group.gemList, { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
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
				t_insert(group.gemList, { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
				self.build.skillsTab:ProcessSocketGroup(group)
				local score = self:Score()
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
		t_insert(group.gemList, { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = best })
		current = bestScore
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
				t_insert(group.gemList, { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
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
	local names = { }
	for i = 2, #group.gemList do t_insert(names, data.gems[group.gemList[i].gemId].name) end
	self:Note("Supports: " .. table.concat(names, ", "))
end

-- Curse, aura, guard and movement setups linked like real builds, packed into gear sockets
function BuildGeneratorClass:ChooseUtilityGems(ignoreAttributes)
	-- drop the previous gem setup notes so the log shows the final one
	for i = #self.log, 1, -1 do
		local l = self.log[i]
		if l:match("^Curse setup") or l:match("^Buffs:") or l:match("^Guard setup") or l:match("^Movement setup") or l:match("^Blink setup") or l:match("^Blood Rage setup") or l:match("^Lifetap linked") or l:match("^Sockets used")
			or l:match("^Possible addition: Animate") or l:match("^Animate Guardian setup") or l:match("^Secondary bow skill setup") then
			t_remove(self.log, i)
		end
	end
	new("GemSetup"):GemSetup(self):Run(self.options.maxAuras or 4, ignoreAttributes)
end

-- Passive tree: repeatedly allocate the path with the best score per point
function BuildGeneratorClass:AllocateTree(quiet, ascendancyOnly)
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
				and node.type ~= "Socket" and not node.isProxy and not node.expansionJewel then
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
	local function run(ascendancy)
		local refreshEvery = 12
		local sinceRefresh = refreshEvery
		local queue = { }
		while true do
			local used, ascUsed = spec:CountAllocNodes()
			local left = ascendancy and (ascBudget - ascUsed) or (budget - used)
			if left <= 0 then break end
			if sinceRefresh >= refreshEvery then
				queue = { }
				for _, entry in ipairs(candidates(ascendancy)) do
					if pathCost(entry.node) <= left then
						entry.value = ratio(entry)
						t_insert(queue, entry)
					end
				end
				sinceRefresh = 0
			end
			t_sort(queue, function(a, b) return a.value > b.value end)
			-- lazy greedy: re-check the best few against the current tree
			for i = 1, m_min(8, #queue) do
				local entry = queue[i]
				if entry.node.alloc or not entry.node.path or pathCost(entry.node) > left then
					entry.value = -math.huge
				else
					entry.value = ratio(entry)
				end
			end
			t_sort(queue, function(a, b) return a.value > b.value end)
			local picked = queue[1]
			if not picked or picked.value <= 0 or picked.value == -math.huge then
				if sinceRefresh > 0 then
					sinceRefresh = refreshEvery -- try a full refresh before stopping
				else
					break
				end
			else
				allocate(picked)
				t_remove(queue, 1)
				current = self:Score()
				sinceRefresh = sinceRefresh + 1
			end
		end
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
	if not archetype or not archetype.keystones or #archetype.keystones == 0 then return end
	local spec = self.build.spec
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	self.protectedNodes = self.protectedNodes or { }
	local changed = false
	for _, name in ipairs(archetype.keystones) do
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

-- Removes every allocated ascendancy / bloodline passive (start nodes stay)
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
		local report = finder:RunRares(options)
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
	for _ = 1, count or 8 do
		local current = self:Score()
		local best, bestLoss
		for _, node in pairs(spec.allocNodes) do
			local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
			local protected = self.protectedNodes and self.protectedNodes[node.id]
			if not node.ascendancyName and not holdsJewel and not protected and node.type ~= "ClassStart" and node.type ~= "Mastery" and node.depends and #node.depends <= 1 then
				local loss = current - self:Score({ removeNodes = { [node] = true } })
				if not bestLoss or loss < bestLoss then best, bestLoss = node, loss end
			end
		end
		if not best then break end
		spec:DeallocNode(best)
	end
	self:Recalculate()
	self:AllocateTree(true)
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
function BuildGeneratorClass:ChooseMetaJewels()
	local investment = self.options.investment or { }
	if investment.timeless == false then return end
	local finder = new("MetaJewelFinder"):MetaJewelFinder({
		build = self.build,
		fullScore = function() return (self:FullScore()) end,
		equip = function(item, slotName) return self:Equip(item, slotName) end,
		tick = function() self:Tick() end,
	})
	local prices = GetPriceSource()
	local kinds = { "forbidden" }
	if investment.exceptionalGems then t_insert(kinds, "watcher") end
	for _, kind in ipairs(kinds) do
		self:Recalculate()
		local base = self:FullScore()
		local result
		if kind == "forbidden" then
			result = finder:ForbiddenPair(base)
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
			ehpFloor = self.options.ehpFloor, chargesPerSecond = self.options.chargesPerSecond,
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
	self.overlap = nil
	self.costs = { }
	self.stageCount = 11
	local function stage(index, label)
		-- big searches leave a lot of garbage: free it between stages
		collectgarbage("collect")
		if opts.debugTiming and self.scorer then
			local _, r = self:FullScore()
			ConPrintf("[stage] before %d: score %.3f dps %.0f ehp %.0f lua %.0f MB", index, r.score, r.dps, r.ehp, collectgarbage("count") / 1024)
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
	self.scorer = new("BuildScorer"):BuildScorer(self.build, { focus = opts.focus, chargesPerSecond = opts.chargesPerSecond, overlap = self.overlap, ehpFloor = opts.ehpFloor })
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
		self:AutoConfigure()
		self:Recalculate()
		local final = self.scorer:Evaluate(self.calcFunc, { })
		self.final = final
		self.build.buildFlag = true
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
	self:ChooseArchetypeJewels()
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseMetaUniques', r.score, r.dps, r.ehp) end
	if opts.jewels ~= false then self:AddJewels(opts.maxJewels or 4) end
	collectgarbage("collect")
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'AddJewels', r.score, r.dps, r.ehp) end
	if opts.timeless ~= false then self:ChooseTimelessJewel() end
	collectgarbage("collect")
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseTimelessJewel', r.score, r.dps, r.ehp) end
	if opts.metaJewels ~= false then self:ChooseMetaJewels() end
	collectgarbage("collect")
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseMetaJewels', r.score, r.dps, r.ehp) end
	if opts.clusterJewels ~= false then self:ChooseClusterJewels(opts.maxClusterJewels or 2) end
	collectgarbage("collect")
	if opts.debugTiming then local _, r = self:FullScore() ConPrintf("[stage] after %s: score %.3f dps %.0f ehp %.0f", 'ChooseClusterJewels', r.score, r.dps, r.ehp) end
	-- spend any points the jewel stages freed
	self:Recalculate()
	self:AllocateTree(true)
	if opts.allowAnoints ~= false then self:ChooseAnoint() end
	if opts.allowTattoos ~= false then self:ChooseTattoos() end

	stage(10, "Choosing flasks")
	self:FullScore()
	self:MakeFlasks()

	if opts.synergies ~= false then
		stage(11, "Looking for unique items and synergies")
		self:ApplySynergies(opts.synergyRounds or 1)
	end
	self.stage = "Optimizing the passive tree"
	self:PairAilments()
	self:OptimizeTree()

	self:AutoConfigure()
	self:Recalculate()
	local final = self.scorer:Evaluate(self.calcFunc, { })
	self.final = final
	self.build.buildFlag = true

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
			"Rares use " .. ((opts.quality and opts.quality.label) or "tier 2-3, average rolls"),
		},
	}
end
