-- Path of Building
--
-- Class: Synergy Finder
-- Looks for combinations of changes that are worth more together than apart:
-- unique items (gear, flasks, jewels), keystones, notables, support gems and
-- regenerated flasks. Steps:
--   1. score every single change with BuildScorer (realistic flask uptime,
--      hit overlap scenario, penalties for broken resistances / attributes)
--   2. find changes that make a stat irrelevant ("removes a downside"), by
--      measuring what each stat is worth with and without the change, then
--      pair them with changes that pay with that stat
--   3. test pairs (best changes, plus partners the synergy index links), then
--      grow the best pairs into packages of three
-- Every idea keeps its explanation and the assumptions it relies on.
-- Runs entirely locally using PoB's calculator.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_min = math.min
local m_max = math.max
local m_abs = math.abs
local m_exp = math.exp
local configOptions = require("Modules.ConfigOptions")

---@class SynergyFinder
local SynergyFinderClass = newClass("SynergyFinder")

-- Stats probed to find changes that make a stat irrelevant.
-- downside: mod names that "pay" with this stat when negative
local probes = {
	{ id = "FlaskDuration", label = "flask duration", mod = { "FlaskDuration", "INC", 40 }, downside = { "FlaskDuration", "Duration" }, flasks = true },
	{ id = "Life", label = "maximum life", mod = { "Life", "INC", 20 }, downside = { "Life" } },
	{ id = "Mana", label = "maximum mana", mod = { "Mana", "INC", 40 }, downside = { "Mana" } },
	{ id = "EnergyShield", label = "energy shield", mod = { "EnergyShield", "INC", 40 }, downside = { "EnergyShield" } },
	{ id = "Accuracy", label = "accuracy", mod = { "Accuracy", "INC", 60 }, downside = { "Accuracy" } },
	{ id = "CritChance", label = "critical strike chance", mod = { "CritChance", "INC", 100 }, downside = { "CritChance" } },
	{ id = "Evasion", label = "evasion", mod = { "Evasion", "INC", 60 }, downside = { "Evasion" } },
	{ id = "Armour", label = "armour", mod = { "Armour", "INC", 60 }, downside = { "Armour" } },
	{ id = "ManaRegen", label = "mana regeneration", mod = { "ManaRegen", "INC", 60 }, downside = { "ManaRegen" } },
	{ id = "ChaosResist", label = "chaos resistance", mod = { "ChaosResist", "BASE", 30 }, downside = { "ChaosResist" } },
	{ id = "Str", label = "strength", mod = { "Str", "BASE", 40 }, downside = { "Str" } },
	{ id = "Dex", label = "dexterity", mod = { "Dex", "BASE", 40 }, downside = { "Dex" } },
	{ id = "Int", label = "intelligence", mod = { "Int", "BASE", 40 }, downside = { "Int" } },
}

-- Unique bases skipped: they need extra setup PoB can't guess (seed, cluster nodes)
local skippedBases = { ["Timeless Jewel"] = true }

function SynergyFinderClass:SynergyFinder(itemsTab, options)
	self.itemsTab = itemsTab
	self.build = itemsTab.build
	self.options = options or { }
	self.itemFinder = new("BestItemFinder"):BestItemFinder(itemsTab)
	self.overlap = new("HitOverlap"):HitOverlap(self.build, self.options.scenario)
	self.scorer = new("BuildScorer"):BuildScorer(self.build, {
		focus = self.options.focus,
		chargesPerSecond = self.options.chargesPerSecond,
		overlap = self.overlap,
		ehpFloor = self.options.ehpFloor,
	})
	self.flaskGenerator = new("FlaskGenerator"):FlaskGenerator(self.itemFinder.rareGenerator, self.scorer)
	self.index = new("SynergyIndex"):SynergyIndex()
	self.extras = new("TreeExtras"):TreeExtras(self.build)
	-- realistic values for count options a candidate depends on (Indigon's mana spent...)
	local bossNow = self.build.configTab.input.enemyIsBoss ~= "None"
	local acProbe = new("AutoConfig"):AutoConfig(self.build)
	self.autoConfig = new("AutoConfig"):AutoConfig(self.build, acProbe.scenarioList[bossNow and 1 or 2])
	self.nextVirtualId = -9000000
	return self
end

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

-- A temporary passive node carrying arbitrary mods, used to test a modifier
function SynergyFinderClass:VirtualNode(name, modType, value, source)
	self.nextVirtualId = self.nextVirtualId - 1
	local modList = new("ModList"):ModList()
	modList:NewMod(name, modType, value, source or "Synergy probe")
	return { id = self.nextVirtualId, type = "Normal", dn = "Probe", modList = modList, modKey = "probe" .. self.nextVirtualId, sd = { } }
end

function SynergyFinderClass:Tick()
	local opts = self.options
	if opts.yieldEvery and GetTime() - (self.lastYield or 0) > opts.yieldEvery then
		if opts.onProgress then
			opts.onProgress(self.stage or "", self.done or 0, self.total or 0)
		end
		coroutine.yield()
		self.lastYield = GetTime()
	end
end

function SynergyFinderClass:MainSocketGroup()
	local list = self.build.skillsTab.socketGroupList
	return list[self.build.mainSocketGroup]
end

-- Supports of the main skill, weakest first: { index, gemInstance, loss }
function SynergyFinderClass:RankCurrentSupports()
	local group = self:MainSocketGroup()
	local ranked = { }
	if not group then
		return ranked
	end
	for index, gem in ipairs(group.gemList) do
		if gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support and gem.enabled ~= false then
			gem.enabled = false
			self.build.skillsTab:ProcessSocketGroup(group)
			local r = self.scorer:Evaluate(self.calcFunc, { }, { flasks = "ratio", ratio = self.baseRatio })
			gem.enabled = true
			self.build.skillsTab:ProcessSocketGroup(group)
			t_insert(ranked, { index = index, gem = gem, loss = self.base.score - r.score })
			self:Tick()
		end
	end
	t_sort(ranked, function(a, b) return a.loss < b.loss end)
	return ranked
end

-- Jewel sockets on the allocated tree; empty ones first
function SynergyFinderClass:JewelSockets()
	local list = { }
	for slotName, slot in pairs(self.itemsTab.slots) do
		if slot.nodeId and self.build.spec.allocNodes[slot.nodeId] then
			local node = self.build.spec.allocNodes[slot.nodeId]
			if not (node.expansionJewel and node.expansionJewel.size ~= 2) and not slotName:match("Abyssal") then
				t_insert(list, { slotName = slotName, empty = (slot.selItemId or 0) == 0 })
			end
		end
	end
	t_sort(list, function(a, b)
		if a.empty ~= b.empty then return a.empty end
		return a.slotName < b.slotName
	end)
	return list
end

------------------------------------------------------------------------------
-- Candidates
------------------------------------------------------------------------------

function SynergyFinderClass:CollectCandidates()
	local opts = self.options
	local itemsTab = self.itemsTab
	local candidates = { }
	local function add(candidate)
		candidate.id = #candidates + 1
		t_insert(candidates, candidate)
	end

	-- Unique items: gear, flasks, one jewel socket
	local slotNames = self.itemFinder:GetActiveSlots()
	for _, slotName in ipairs({ "Flask 1", "Flask 2", "Flask 3", "Flask 4", "Flask 5" }) do
		if itemsTab.slots[slotName] then
			t_insert(slotNames, slotName)
		end
	end
	self.jewelSockets = self:JewelSockets()
	if self.jewelSockets[1] then
		t_insert(slotNames, self.jewelSockets[1].slotName)
	end
	local filter = { obtainableOnly = opts.obtainableOnly ~= false, levelOnly = opts.levelOnly ~= false, investment = opts.investment }
	-- Uniques with versions (e.g. a jewel whose stats depend on the aura or
	-- keystone it names) are tried in every current version; jewels with
	-- dozens of versions are handled by the meta jewel search instead
	local uniques = { }
	for _, item in pairs(main.uniqueDB.list) do
		local variants = item.variantList
		local current = 0
		for _, variantName in ipairs(variants or { }) do
			if not variantName:find("Pre %d") and variantName ~= "None" then current = current + 1 end
		end
		-- only uniques with several current versions (old versions don't drop any more)
		if variants and current > 1 and current <= (opts.maxVariants or 30) and item.type ~= "Flask" then
			for index, variantName in ipairs(variants) do
				if not variantName:find("Pre %d") and variantName ~= "None" then
					local copy = new("Item"):Item(item.raw)
					copy.variant = index
					copy:BuildAndParseRaw()
					copy.variantLabel = variantName
					t_insert(uniques, copy)
				end
			end
		else
			t_insert(uniques, item)
		end
	end
	t_sort(uniques, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return (a.variant or 0) < (b.variant or 0)
	end)
	for _, item in ipairs(uniques) do
		if self.itemFinder:IsItemAllowed(item, filter) and not skippedBases[item.baseName] and not item.clusterJewel then
			local placed = false
			for _, slotName in ipairs(slotNames) do
				-- one slot per item (Ring 2 / Flask 2-5 only matter in packages)
				if not placed and itemsTab:IsItemValidForSlot(item, slotName) and not slotName:match("^Ring 2") and not slotName:match("^Ring 3") then
					local slot = itemsTab.slots[slotName]
					local current = slot and itemsTab.items[slot.selItemId]
					if not (current and current.name == item.name) then
						local isFlask = item.type == "Flask"
						if isFlask and slotName ~= "Flask 1" then
							-- flasks are tried in the first non-recovery slot
						else
							local provides, needs = self.index.ScanItem(item)
							add({
								kind = isFlask and "flask" or (item.type == "Jewel" and "jewel" or "unique"),
								label = item.name .. (item.variantLabel and (" (" .. item.variantLabel .. ")") or ""),
								item = item,
								slotName = isFlask and self.utilityFlaskSlot or slotName,
								provides = provides, needs = needs,
							})
							placed = true
						end
					end
				end
			end
		end
	end

	-- Keystones and linked notables within reach
	local buildProvides, buildNeeds = self.buildProvides, self.buildNeeds
	for _, node in pairs(self.build.spec.nodes) do
		if not node.alloc and node.path and not node.ascendancyName and (node.type == "Keystone" or node.type == "Notable") then
			local points = #node.path
			local provides, needs = self.index.ScanNode(node)
			local linked = false
			for key in pairs(needs) do if buildProvides[key] then linked = true break end end
			if not linked then
				for key in pairs(provides) do if buildNeeds[key] then linked = true break end end
			end
			local maxPoints = node.type == "Keystone" and (opts.maxKeystonePoints or 12) or (opts.maxNotablePoints or 6)
			if points <= maxPoints and (node.type == "Keystone" or linked) then
				local pathSet = { }
				for _, pathNode in ipairs(node.path) do pathSet[pathNode] = true end
				add({
					kind = node.type == "Keystone" and "keystone" or "notable",
					label = node.dn .. string.format(" (%d point%s)", points, points == 1 and "" or "s"),
					node = node,
					pathSet = pathSet,
					points = points,
					provides = provides, needs = needs,
				})
			end
		end
	end

	-- Support gems for the main skill (replacing the weakest current support)
	self.supportRank = self:RankCurrentSupports()
	local group = self:MainSocketGroup()
	if group and #self.supportRank > 0 then
		local function family(gem)
			return gem.grantedEffect and gem.grantedEffect.plusVersionOf or gem.grantedEffectId
		end
		local inGroup = { }
		for _, gem in ipairs(group.gemList) do
			if gem.gemId and data.gems[gem.gemId] then inGroup[family(data.gems[gem.gemId])] = true end
		end
		for gemId, gem in pairs(data.gems) do
			local assumptionTrigger = false
			for _, text in ipairs({ "when Stunned", "when Damage Taken", "on Death", "when Hit", "Cast while Channelling", "on Melee Kill", "Cast on Kill" }) do
				if gem.name:find(text, 1, true) then assumptionTrigger = true end
			end
			local investment = opts.investment or { }
			local tags = gem.tags or { }
			local affordable = (investment.awakenedGems ~= false or not tags.awakened) and (investment.exceptionalGems ~= false or not tags.exceptional)
			if gem.grantedEffect and gem.grantedEffect.support and not gem.grantedEffect.unsupported and not inGroup[family(gem)]
				and affordable and (opts.allowTriggerSupports or not assumptionTrigger) then
				add({
					kind = "support",
					label = gem.name .. " Support",
					gemId = gemId,
					gem = gem,
					provides = { }, needs = { },
				})
			end
		end
	end

	-- Anoints on the amulet
	local amuletSlot = itemsTab.slots["Amulet"]
	local amulet = amuletSlot and itemsTab.items[amuletSlot.selItemId]
	if opts.allowAnoints ~= false and self.extras:CanAnoint(amulet) then
		for _, entry in ipairs(self.extras:AnointCandidates(opts.investment)) do
			local provides, needs = self.index.ScanNode(entry.node)
			add({ kind = "anoint", label = "Anoint " .. entry.node.dn, anointNode = entry.node, provides = provides, needs = needs })
		end
	end

	-- Tattoos on allocated attribute passives, keystones and masteries
	if opts.allowTattoos ~= false then
		self.tattooTargets = self.extras:TattooTargets()
		for _, option in ipairs(self.extras:TattooOptions(opts.investment)) do
			if self.tattooTargets[option.targetType] then
				local provides, needs = self.index.ScanNode(option.tattoo)
				add({ kind = "tattoo", label = option.name .. " (tattoo)", tattoo = option.tattoo, tattooName = option.name, targetType = option.targetType, limitKey = option.limitKey, provides = provides, needs = needs })
			end
		end
	end

	-- Regenerated flasks for the current build
	add({ kind = "flaskset", label = "Re-optimised utility flasks", provides = { ["flask:active"] = true }, needs = { }, expensive = true })

	-- Flask related changes need the full uptime model
	for _, c in ipairs(candidates) do
		c.flaskRelated = c.kind == "flask" or c.kind == "flaskset" or c.provides["flask:permanent"] or c.needs["flask:active"] or c.needs["cond:UsingFlask"]
	end
	return candidates
end

------------------------------------------------------------------------------
-- Building and scoring packages
------------------------------------------------------------------------------

-- Turns a list of candidates into a calculator override plus gem changes.
-- Returns state or nil when the candidates conflict.
function SynergyFinderClass:BuildState(list)
	local state = { override = { repItems = { }, addNodes = { }, activeFlaskSlots = { } }, gemChanges = { }, points = 0, flaskRelated = false }
	local usedSlots = { }
	local jewelIndex = 1
	local supportIndex = 1
	local hasNodes = false
	local usedLimits, tattooIndex = { }, { }
	for _, c in ipairs(list) do
		state.flaskRelated = state.flaskRelated or c.flaskRelated
		if c.item then
			local slotName = c.slotName
			if usedSlots[slotName] then
				-- second ring / jewel / flask goes to the next free slot of that kind
				local alt
				if slotName:match("^Ring") and not usedSlots["Ring 2"] then
					alt = "Ring 2"
				elseif c.kind == "jewel" then
					jewelIndex = jewelIndex + 1
					alt = self.jewelSockets[jewelIndex] and self.jewelSockets[jewelIndex].slotName
				elseif c.kind == "flask" then
					for _, s in ipairs(self.freeFlaskSlots or { }) do
						if not usedSlots[s] then alt = s break end
					end
				end
				if not alt or usedSlots[alt] then
					return nil
				end
				slotName = alt
			end
			if c.kind == "unique" and usedSlots["Weapon 1"] and slotName == "Weapon 2" then
				local w1 = state.override.repItems["Weapon 1"]
				if w1 and w1.base and not (data.weaponTypeInfo[w1.base.type] or { oneHand = true }).oneHand then
					return nil
				end
			end
			usedSlots[slotName] = true
			state.override.repItems[slotName] = c.item
			if c.kind == "flask" then
				state.override.activeFlaskSlots[slotName] = true
			end
			c.placedSlot = slotName
		elseif c.pathSet then
			for node in pairs(c.pathSet) do
				if not state.override.addNodes[node] then
					state.override.addNodes[node] = true
					state.points = state.points + 1
				end
			end
			hasNodes = true
		elseif c.gemId then
			local target = self.supportRank[supportIndex]
			if not target then
				return nil
			end
			supportIndex = supportIndex + 1
			t_insert(state.gemChanges, { index = target.index, gemId = c.gemId, replaces = target.gem })
		elseif c.kind == "flaskset" then
			state.flaskSet = true
		elseif c.kind == "anoint" then
			if state.anointNode then
				return nil -- one anoint per amulet
			end
			state.anointNode = c.anointNode
		elseif c.kind == "tattoo" then
			if c.limitKey then
				if usedLimits[c.limitKey] then return nil end
				usedLimits[c.limitKey] = true
			end
			local targets = self.tattooTargets and self.tattooTargets[c.targetType] or { }
			tattooIndex[c.targetType] = (tattooIndex[c.targetType] or 0) + 1
			local target = targets[tattooIndex[c.targetType]]
			if not target then
				return nil
			end
			state.override.removeNodes = state.override.removeNodes or { }
			state.override.removeNodes[target] = true
			state.override.addNodes[self.extras:VirtualTattoo(c.tattoo)] = true
			hasNodes = true
			state.tattoos = state.tattoos or { }
			t_insert(state.tattoos, { node = target, name = c.tattooName })
		end
	end
	if state.anointNode then
		local amulet = state.override.repItems["Amulet"]
		if amulet == nil then
			local slot = self.itemsTab.slots["Amulet"]
			amulet = slot and self.itemsTab.items[slot.selItemId]
		end
		if not self.extras:CanAnoint(amulet) then
			return nil
		end
		state.override.repItems["Amulet"] = self.extras:AnointedCopy(amulet, state.anointNode)
	end
	-- More passive points than the character has free: pay with the least
	-- useful allocated passives (never one the new path hangs from)
	local free = self.freePoints or math.huge
	if state.points > free then
		local need = state.points - free
		state.refund = { }
		state.override.removeNodes = state.override.removeNodes or { }
		for _, node in ipairs(self.refundOrder or { }) do
			if need <= 0 then break end
			local anchor = false
			for _, other in ipairs(node.linked or { }) do
				if state.override.addNodes[other] then anchor = true end
			end
			if not anchor and not state.override.removeNodes[node] then
				state.override.removeNodes[node] = true
				t_insert(state.refund, node)
				need = need - 1
			end
		end
		if need > 0 then return nil end
	end
	if not hasNodes then
		state.override.addNodes = nil
	end
	return state
end

-- Passive points the character has, from its level (quests included)
function SynergyFinderClass:PointBudget()
	local output = self.build.calcsTab.mainOutput or { }
	return (self.build.characterLevel - 1) + 23 + (output.ExtraPoints or 0)
end

-- Allocated passives in the order they'd be removed to free points: least
-- useful first, only ones nothing else depends on (so the tree stays connected)
function SynergyFinderClass:BuildRefundOrder(maxCount)
	local spec = self.build.spec
	local base = self.base.score
	local losses = { }
	for _, node in pairs(spec.allocNodes) do
		local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
		local protected = self.options.protectedNodes and self.options.protectedNodes[node.id]
		if not node.ascendancyName and not holdsJewel and not protected and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
			and node.type ~= "Mastery" and not node.isProxy then
			local r = self.scorer:Evaluate(self.calcFunc, { removeNodes = { [node] = true } }, { flasks = "ratio", ratio = self.baseRatio })
			losses[node] = base - r.score
			self:Tick()
		end
	end
	local removed, order = { }, { }
	for _ = 1, maxCount do
		local best
		for node, loss in pairs(losses) do
			if not removed[node] then
				local leaf = true
				for _, dep in ipairs(node.depends or { }) do
					if dep ~= node and dep.alloc and not removed[dep] then leaf = false break end
				end
				if leaf and (not best or loss < losses[best] or (loss == losses[best] and node.id < best.id)) then best = node end
			end
		end
		if not best then break end
		removed[best] = true
		t_insert(order, best)
	end
	return order
end

function SynergyFinderClass:WithGems(state, fn)
	local group = self:MainSocketGroup()
	if not group or #state.gemChanges == 0 then
		return fn()
	end
	local saved = { }
	for _, change in ipairs(state.gemChanges) do
		saved[change.index] = group.gemList[change.index]
		local gem = data.gems[change.gemId]
		group.gemList[change.index] = { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = change.gemId }
	end
	self.build.skillsTab:ProcessSocketGroup(group)
	local ok, a, b = pcall(fn)
	for index, gem in pairs(saved) do
		group.gemList[index] = gem
	end
	self.build.skillsTab:ProcessSocketGroup(group)
	if not ok then
		error(a)
	end
	return a, b
end

-- Scores a list of candidates; caches by candidate ids
function SynergyFinderClass:Evaluate(list)
	local ids = { }
	for _, c in ipairs(list) do t_insert(ids, c.id) end
	t_sort(ids)
	local key = table.concat(ids, ",")
	if self.cache[key] ~= nil then
		return self.cache[key] or nil
	end
	local state = self:BuildState(list)
	if not state then
		self.cache[key] = false
		return nil
	end
	-- count options this package depends on that the user hasn't filled in
	local dynamic = { }
	local input = self.build.configTab.input
	for _, c in ipairs(list) do
		for key in pairs(c.needs or { }) do
			local mult = key:match("^mult:(.+)$")
			local option = mult and self.autoConfig.optionForMult[mult]
			if option and input[option.var] == nil then
				dynamic[mult] = option
			end
		end
	end
	local result = self:WithGems(state, function()
		local override = state.override
		local saved, notes = { }, { }
		if next(dynamic) then
			-- settle the counts from the package's own numbers (a few passes: e.g.
			-- Indigon raises the cost that feeds its own count), capped by sustain
			for pass = 1, 3 do
				local output = self.calcFunc(override)
				for mult, option in pairs(dynamic) do
					local value, reason = self.autoConfig:RealisticCount(mult, output, self.build.calcsTab.mainEnv)
					if saved[option.var] == nil then saved[option.var] = input[option.var] or false end
					input[option.var] = value
					notes[mult] = string.format("%s estimated at %s (%s)", (option.label or option.var):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""):gsub(":$", ""), tostring(value), reason)
				end
				self.build.configTab:BuildModList()
			end
		end
		local function restore()
			if next(saved) then
				for var, value in pairs(saved) do input[var] = value or nil end
				self.build.configTab:BuildModList()
			end
		end
		state.countNotes = notes
		if state.flaskSet then
			local generated = self.flaskGenerator:Generate({ calcFunc = self.calcFunc, override = override, opts = self.options, tick = function() self:Tick() end })
			override = generated.override
			state.generatedFlasks = generated.slots
		end
		local r = self.scorer:Evaluate(self.calcFunc, override, { flasks = state.flaskRelated and "full" or "ratio", ratio = self.baseRatio })
		restore()
		return r
	end)
	result.state = state
	result.list = list
	result.gain = result.score - self.base.score
	self.cache[key] = result
	self.done = (self.done or 0) + 1
	self:Tick()
	return result
end

------------------------------------------------------------------------------
-- Downside removal
------------------------------------------------------------------------------

-- Value of every probe (score gain of adding the stat) in a given state
function SynergyFinderClass:ProbeValues(list)
	local values = { }
	local state = list and self:BuildState(list) or { override = { }, gemChanges = { } }
	if not state then
		return values
	end
	self:WithGems(state, function()
		local base = self.scorer:Evaluate(self.calcFunc, state.override, { flasks = "full" })
		-- keep this state's flask ratio: the flask probe below changes the stored one
		local ratio = self.scorer.lastFlaskRatio
		for _, probe in ipairs(probes) do
			local override = { }
			for k, v in pairs(state.override) do override[k] = v end
			local addNodes = { }
			for node in pairs(state.override.addNodes or { }) do addNodes[node] = true end
			addNodes[self:VirtualNode(probe.mod[1], probe.mod[2], probe.mod[3])] = true
			override.addNodes = addNodes
			local r = self.scorer:Evaluate(self.calcFunc, override, { flasks = probe.flasks and "full" or "ratio", ratio = ratio })
			values[probe.id] = r.score - base.score
			self:Tick()
		end
	end)
	return values
end

-- Does a candidate carry a downside paid with this probe's stat?
local function hasDownside(candidate, probe)
	local item = candidate.item
	if not item then
		return false
	end
	for _, list in ipairs({ item.implicitModLines, item.explicitModLines }) do
		for _, line in ipairs(list or { }) do
			for _, mod in ipairs(line.modList or { }) do
				for _, name in ipairs(probe.downside) do
					if mod.name == name and type(mod.value) == "number" and mod.value < 0 and (mod.type == "INC" or mod.type == "BASE" or mod.type == "MORE") then
						return true
					end
				end
			end
		end
	end
	return false
end

------------------------------------------------------------------------------
-- Explanations and assumptions
------------------------------------------------------------------------------

function SynergyFinderClass:ConfigAssumptions(list)
	local needs, provides = { }, { }
	for k in pairs(self.buildProvides) do provides[k] = true end
	for _, c in ipairs(list) do
		for k in pairs(c.needs or { }) do needs[k] = true end
		for k in pairs(c.provides or { }) do provides[k] = true end
	end
	local input = self.build.configTab.input
	local out = { }
	for key in pairs(needs) do
		local kind, name = key:match("^(%w+):(.+)$")
		if (kind == "cond" or kind == "enemy") and not provides[key] then
			for _, option in ipairs(configOptions) do
				local matches = (kind == "cond" and option.ifCond == name and option.var and option.var:match("^condition"))
					or (kind == "enemy" and option.var == "conditionEnemy" .. name)
				if matches and input[option.var] then
					t_insert(out, "Relies on Config: " .. (option.label or option.var):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
				end
			end
		end
	end
	t_sort(out)
	return out
end

function SynergyFinderClass:Explain(idea)
	local lines = { }
	local list = idea.list
	local seenKeys = { }
	-- Links between the parts of the idea, one line per shared resource
	for i = 1, #list do
		for j = i + 1, #list do
			local a, b = list[i], list[j]
			for _, link in ipairs(self.index.Links(a.provides, a.needs, b.provides, b.needs)) do
				local from, to = link.from == "A" and a or b, link.from == "A" and b or a
				local key = link.key .. "|" .. to.label
				if not seenKeys[key] and #lines < 3 then
					seenKeys[key] = true
					t_insert(lines, string.format("%s provides %s, which %s scales with", from.label, self.index.KeyLabel(link.key), to.label))
				end
			end
		end
	end
	-- Otherwise, what in the build each part plays with
	if #lines == 0 then
		for _, c in ipairs(list) do
			for key in pairs(c.needs or { }) do
				if self.buildProvides[key] and key ~= "cond:UsingFlask" and #lines < 2 then
					t_insert(lines, string.format("%s uses %s, which your build already has", c.label, self.index.KeyLabel(key)))
					break
				end
			end
		end
	end
	if idea.freed and idea.freed.text then
		t_insert(lines, 1, idea.freed.text)
	elseif idea.freed then
		t_insert(lines, 1, string.format("%s makes %s irrelevant (worth %+.1f%% of score before, %+.1f%% after), so trading it away costs nothing", idea.freed.by.label, idea.freed.probe.label, idea.freed.before * 100, idea.freed.after * 100))
	end
	if idea.synergy and idea.synergy > 0.005 and #list > 1 then
		t_insert(lines, string.format("Together they are worth %.1f%% more than the sum of each change alone", (m_exp(idea.synergy) - 1) * 100))
	end
	return lines
end

------------------------------------------------------------------------------
-- Main search
------------------------------------------------------------------------------

function SynergyFinderClass:Run()
	local opts = self.options
	local t0 = os.clock()
	local function mark(label)
		if opts.debugTiming then
			ConPrintf("[synergy] %-32s %6.1fs  (%d evaluations)", label, os.clock() - t0, self.done or 0)
		end
	end
	collectgarbage("collect")
	self.cache = { }
	self.done = 0
	self.lastYield = GetTime()
	self.calcFunc = self.build.calcsTab:GetMiscCalculator()
	self.base = self.scorer:Evaluate(self.calcFunc, { })
	self.baseRatio = self.scorer.lastFlaskRatio
	self.buildProvides, self.buildNeeds = self.index.ScanBuild(self.build)
	-- free passive points, and what to remove when an idea needs more
	local used = self.build.spec:CountAllocNodes()
	self.freePoints = math.max(0, self:PointBudget() - used)
	self.refundOrder = self:BuildRefundOrder(opts.maxRefund or 24)
	-- First flask slot that does not hold a life / mana flask, and the free ones after it
	self.freeFlaskSlots = { }
	for _, slotName in ipairs({ "Flask 1", "Flask 2", "Flask 3", "Flask 4", "Flask 5" }) do
		local slot = self.itemsTab.slots[slotName]
		local item = slot and self.itemsTab.items[slot.selItemId]
		if slot and not (item and item.base and item.base.flask and (item.base.flask.life or item.base.flask.mana)) then
			t_insert(self.freeFlaskSlots, slotName)
		end
	end
	self.utilityFlaskSlot = self.freeFlaskSlots[1] or "Flask 1"

	-- 1. Single changes
	self.stage = "Testing single changes"
	local candidates = self:CollectCandidates()
	-- share of this skill's players (poe.ninja) using each unique / keystone
	if opts.meta then
		local share = { }
		for _, list in ipairs({ opts.meta.items or { }, opts.meta.keystones or { } }) do
			for _, e in ipairs(list) do share[e.name] = e.share end
		end
		for _, c in ipairs(candidates) do
			local name = c.item and (c.item.title or c.item.name) or (c.node and c.node.dn)
			if name and share[name] then c.metaShare = share[name] end
		end
	end
	self.total = #candidates
	local solos = { }
	for _, c in ipairs(candidates) do
		local r = self:Evaluate({ c })
		if r then
			c.solo = r
			t_insert(solos, c)
		end
	end
	t_sort(solos, function(a, b) return a.solo.score > b.solo.score end)
	self.solos = solos
	mark("singles (" .. #candidates .. " candidates)")

	-- 2. Changes that make a stat irrelevant
	self.stage = "Looking for removed downsides"
	local baseValues = self:ProbeValues(nil)
	local probeTargets = { }
	for i = 1, m_min(30, #solos) do t_insert(probeTargets, solos[i]) end
	for _, c in ipairs(candidates) do
		if (c.kind == "keystone" or c.provides["flask:permanent"]) and c.solo then
			t_insert(probeTargets, c)
		end
	end
	local seen = { }
	local freedPairs = { }
	for _, c in ipairs(probeTargets) do
		if not seen[c] then
			seen[c] = true
			local values = self:ProbeValues({ c })
			-- How much stats keep their value on average: a change that wrecks the
			-- build makes every stat worthless, which is not "removing a downside"
			local kept, counted = 0, 0
			for _, probe in ipairs(probes) do
				local before = baseValues[probe.id] or 0
				if before > 0.01 then
					kept = kept + m_max(0, m_min(1, (values[probe.id] or 0) / before))
					counted = counted + 1
				end
			end
			local typicalKept = counted > 0 and kept / counted or 1
			local usable = c.solo.gain > -(opts.maxNeutraliserLoss or 1) and typicalKept > 0.5
			for _, probe in ipairs(probes) do
				local before, after = baseValues[probe.id] or 0, values[probe.id] or 0
				if not usable then before = 0 end
				if opts.debugTiming and before > 0.01 and after < before * 0.2 then
					ConPrintf("[synergy] %s makes %s irrelevant (%.3f -> %.3f)", c.label, probe.label, before, after)
				end
				if before > 0.01 and after < before * 0.2 then
					-- c frees this stat: try it with things that pay with it
					local partners = { }
					if probe.flasks then
						for _, other in ipairs(candidates) do
							if other.kind == "flaskset" then t_insert(partners, other) end
						end
					end
					for _, other in ipairs(candidates) do
						if other ~= c and other.solo and hasDownside(other, probe) then
							t_insert(partners, other)
						end
					end
					t_sort(partners, function(a, b) return a.solo.score > b.solo.score end)
					for i = 1, m_min(4, #partners) do
						local r = self:Evaluate({ c, partners[i] })
						if r then
							t_insert(freedPairs, { result = r, freed = { by = c, probe = probe, before = before, after = after } })
							if opts.debugTiming then
								ConPrintf("[synergy] %s frees %s (%.3f -> %.3f): + %s = gain %.3f (alone %.3f / %.3f)", c.label, probe.label, before, after, partners[i].label, r.gain, c.solo.gain, partners[i].solo.gain)
							end
						end
					end
				end
			end
		end
	end

	-- Things that make flasks permanent always get flasks re-optimised for them:
	-- duration and charges stop mattering, so "increased effect, reduced
	-- duration" becomes free (Mageblood)
	local flaskset
	for _, c in ipairs(candidates) do
		if c.kind == "flaskset" then flaskset = c end
	end
	if flaskset and flaskset.solo then
		for _, c in ipairs(candidates) do
			if c.provides["flask:permanent"] and c.solo then
				local r = self:Evaluate({ c, flaskset })
				if r then
					t_insert(freedPairs, { result = r, freed = { by = c, text = c.label .. " makes its flasks permanent, so flask duration and charges no longer matter: the flasks are re-optimised for effect" } })
				end
			end
		end
	end
	mark("downsides (" .. #freedPairs .. " pairs)")
	-- Tattoo set: tattoos are small one by one, so stack the best ones
	local tattooSolos = { }
	for _, c in ipairs(solos) do
		if c.kind == "tattoo" and c.solo.gain > 0 then t_insert(tattooSolos, c) end
	end
	if #tattooSolos >= 2 then
		local set, current = { }, self.base.score
		for _, c in ipairs(tattooSolos) do
			if #set >= (opts.maxTattoos or 30) then break end
			local trial = { }
			for _, x in ipairs(set) do t_insert(trial, x) end
			t_insert(trial, c)
			local r = self:Evaluate(trial)
			if r and r.score > current + 0.0005 then
				set, current = trial, r.score
				self.tattooSetResult = r
			end
		end
		if self.tattooSetResult then self.tattooSetResult.tattooSet = true end
	end
	-- 3. Pairs: best singles with each other, and with their linked partners
	self.stage = "Testing combinations"
	local seeds = { }
	for _, c in ipairs(solos) do
		if #seeds >= (opts.seedCount or 18) then break end
		if c.solo.gain > -0.05 and not c.expensive then t_insert(seeds, c) end
	end
	-- What players of this skill use (poe.ninja) is always combined, even when it
	-- looks weak alone: those items usually work together with something else
	local metaSeeds = { }
	for _, c in ipairs(solos) do
		if c.metaShare and c.metaShare >= (opts.minMetaShare or 0.04) and not c.expensive and c.solo.gain > -0.6 then
			t_insert(metaSeeds, c)
		end
	end
	t_sort(metaSeeds, function(a, b) return a.metaShare > b.metaShare end)
	for i = 1, m_min(opts.metaSeedCount or 8, #metaSeeds) do
		local present = false
		for _, s in ipairs(seeds) do if s == metaSeeds[i] then present = true end end
		if not present then t_insert(seeds, metaSeeds[i]) end
	end
	local results = { }
	local function consider(r, extra)
		if r and #r.list > 0 then
			local soloSum = 0
			for _, c in ipairs(r.list) do soloSum = soloSum + c.solo.gain end
			r.synergy = r.gain - soloSum
			for k, v in pairs(extra or { }) do r[k] = v end
			t_insert(results, r)
		end
	end
	for _, c in ipairs(solos) do
		if c.solo.gain > 0 then consider(c.solo) end
	end
	for _, fp in ipairs(freedPairs) do
		consider(fp.result, { freed = fp.freed })
	end
	for i = 1, #seeds do
		for j = i + 1, #seeds do
			consider(self:Evaluate({ seeds[i], seeds[j] }))
		end
		-- partners the synergy index links to this seed
		local partners = { }
		for _, other in ipairs(solos) do
			if other ~= seeds[i] and not other.expensive and #self.index.Links(seeds[i].provides, seeds[i].needs, other.provides, other.needs) > 0 then
				t_insert(partners, other)
			end
		end
		for k = 1, m_min(opts.partnersPerSeed or 6, #partners) do
			consider(self:Evaluate({ seeds[i], partners[k] }))
		end
	end

	mark("pairs")
	-- 4. Grow the best pairs into packages of three
	local pairsList = { }
	for _, r in ipairs(results) do
		if #r.list == 2 then t_insert(pairsList, r) end
	end
	t_sort(pairsList, function(a, b) return a.score > b.score end)
	for i = 1, m_min(8, #pairsList) do
		local pair = pairsList[i]
		for _, s in ipairs(seeds) do
			if s ~= pair.list[1] and s ~= pair.list[2] then
				local r = self:Evaluate({ pair.list[1], pair.list[2], s })
				if r and r.score > pair.score then
					consider(r, { freed = pair.freed })
				end
			end
		end
	end

	mark("triples")
	-- 5. Three kinds of ideas, each ranked on its own:
	--    real synergies (worth more together than apart), removed downsides,
	--    and the best single changes. A change appears in at most two ideas.
	local function keyOf(r)
		local ids = { }
		for _, c in ipairs(r.list) do t_insert(ids, c.id) end
		t_sort(ids)
		return table.concat(ids, ",")
	end
	local synergies, downsides, singles = { }, { }, { }
	for _, r in ipairs(results) do
		if r.gain > 0 then
			if r.freed and (r.synergy or 0) > (opts.minSynergy or 0.01) then
				t_insert(downsides, r)
			elseif r.freed then
				-- the pair adds nothing beyond its parts: not a removed downside
			elseif #r.list > 1 and (r.synergy or 0) > (opts.minSynergy or 0.01) then
				t_insert(synergies, r)
			elseif #r.list == 1 then
				t_insert(singles, r)
			end
		end
	end
	t_sort(synergies, function(a, b) return a.synergy + a.gain * 0.25 > b.synergy + b.gain * 0.25 end)
	t_sort(downsides, function(a, b) return a.gain > b.gain end)
	t_sort(singles, function(a, b) return a.gain > b.gain end)
	local ideas, used, uses = { }, { }, { }
	local function take(list, limit)
		local count = 0
		for _, r in ipairs(list) do
			if count >= limit then break end
			local key = keyOf(r)
			local tooMany = false
			for _, c in ipairs(r.list) do
				if (uses[c] or 0) >= 2 then tooMany = true end
			end
			if not used[key] and not tooMany then
				used[key] = true
				for _, c in ipairs(r.list) do uses[c] = (uses[c] or 0) + 1 end
				t_insert(ideas, self:MakeIdea(r))
				count = count + 1
			end
		end
	end
	take(synergies, opts.maxSynergies or 8)
	if self.tattooSetResult and self.tattooSetResult.gain > 0 then
		t_insert(ideas, self:MakeIdea(self.tattooSetResult))
	end
	take(downsides, opts.maxDownsides or 5)
	take(singles, opts.maxSingles or 6)
	mark("ideas")
	local investment = opts.investment or { }
	if opts.allowTimeless ~= false and investment.timeless ~= false then
		self.stage = "Looking for a timeless jewel"
		local idea = self:TimelessIdea()
		if idea then t_insert(ideas, idea) end
		mark("timeless jewel")
	end
	if opts.allowTreeRespec ~= false then
		self.stage = "Trying a re-spent passive tree"
		local idea = self:TreeRespecIdea()
		if idea then t_insert(ideas, 1, idea) end
		mark("tree respec")
	end
	if opts.allowMetaJewels ~= false and investment.timeless ~= false then
		self.stage = "Trying Forbidden Flame / Flesh and Watcher's Eye"
		for _, idea in ipairs(self:MetaJewelIdeas(investment)) do t_insert(ideas, idea) end
		mark("meta jewels")
	end
	self.cache = { }
	collectgarbage("collect")
	return { base = self.base, ideas = ideas, tested = self.done, assumptions = self.overlap:GetAssumptions() }
end

-- Display data for one idea
function SynergyFinderClass:MakeIdea(r)
	local base = self.base
	local idea = {
		list = r.list,
		state = r.state,
		score = r.score,
		gain = r.gain,
		synergy = r.synergy,
		freed = r.freed,
		dpsPct = base.dps > 0 and (r.dps / base.dps - 1) * 100 or 0,
		ehpPct = base.ehp > 0 and (r.ehp / base.ehp - 1) * 100 or 0,
		points = r.state.points,
		penalties = r.penalties,
		generatedFlasks = r.state.generatedFlasks,
	}
	local labels = { }
	for _, c in ipairs(r.list) do t_insert(labels, c.label) end
	idea.title = table.concat(labels, " + ")
	idea.kind = #r.list > 1 and "Synergy" or "Single change"
	idea.rawDps, idea.rawEhp = r.rawDps, r.rawEhp
	if r.freed then idea.kind = "Removes a downside" end
	if r.tattooSet then
		idea.kind = "Tattoo set"
		idea.title = string.format("%d tattoos on attribute / keystone / mastery passives", #r.list)
	end
	-- What the idea costs to buy, from poe.ninja prices
	local prices = GetPriceSource()
	local total, unknown = 0, false
	idea.costs = { }
	for _, c in ipairs(r.list) do
		local price
		if c.item and c.item.rarity == "UNIQUE" then
			price = prices:UniquePrice(c.item)
		elseif c.anointNode then
			price = prices:AnointPrice(c.anointNode)
		elseif c.tattoo then
			price = prices:TattooPrice(c.tattoo.dn)
		else
			price = 0
		end
		if price == nil then unknown = true else total = total + price end
		if price ~= 0 then t_insert(idea.costs, c.label .. ": " .. prices.FormatPrice(price)) end
	end
	idea.totalCost = (prices.loaded and not unknown) and total or nil
	idea.explanation = self:Explain(idea)
	if r.state.refund and #r.state.refund > 0 then
		local names = { }
		for _, node in ipairs(r.state.refund) do t_insert(names, node.dn) end
		t_insert(idea.explanation, string.format("Your %d free point%s aren't enough: remove %s (the least useful passives) to pay for it", self.freePoints, self.freePoints == 1 and "" or "s", table.concat(names, ", ")))
	end
	for _, c in ipairs(r.list) do
		if c.metaShare then
			t_insert(idea.explanation, string.format("%s is used by %d%% of %s characters on poe.ninja", c.item and (c.item.title or c.item.name) or c.node.dn, math.floor(c.metaShare * 100 + 0.5), self.options.metaSkill or "this skill's"))
		end
	end
	for _, t in ipairs(r.state.tattoos or { }) do
		local original = self.build.spec.tree.nodes[t.node.id]
		t_insert(idea.explanation, string.format("%s replaces %s", t.name, original and original.dn or "a passive"))
	end
	if r.state.anointNode then
		t_insert(idea.explanation, "Anoint the amulet with " .. r.state.anointNode.dn .. " (oils: " .. table.concat(r.state.anointNode.recipe or { }, ", "):gsub("(%l)(%u)", "%1 %2") .. ")")
	end
	idea.assumptions = self:ConfigAssumptions(r.list)
	for _, a in ipairs(self.overlap:GetAssumptions()) do t_insert(idea.assumptions, a) end
	for _, note in pairs(r.state.countNotes or { }) do t_insert(idea.assumptions, note) end
	for _, entry in ipairs(r.flasks or { }) do
		if entry.uptime < 0.999 then
			t_insert(idea.assumptions, string.format("%s up %d%% of the time (estimated from charges)", entry.item.name, entry.uptime * 100))
		end
	end
	return idea
end

-- Best timeless jewel as an idea (it changes the tree, so it is tested with
-- full recalculations and the build is restored afterwards)
function SynergyFinderClass:TimelessIdea()
	local build = self.build
	local lastFull
	local function recalc()
		wipeGlobalCache()
		build.outputRevision = build.outputRevision + 1
		build.buildFlag = false
		build.skillsTab:UpdateSocketGroups()
		build.calcsTab:BuildOutput()
	end
	local finder = new("TimelessJewelFinder"):TimelessJewelFinder({
		build = build,
		score = function(override)
			local r = self.scorer:Evaluate(self.calcFunc, override, { flasks = "ratio", ratio = self.baseRatio })
			self:Tick()
			return r.score
		end,
		fullScore = function()
			recalc()
			lastFull = self.scorer:Evaluate(build.calcsTab:GetMiscCalculator(), { }, { flasks = "ratio", ratio = self.baseRatio })
			self:Tick()
			return lastFull.score
		end,
		equip = function(item, slotName) return self.itemFinder:Equip(item, slotName, true) end,
		tick = function() self:Tick() end,
	})
	local result = finder:Run({ })
	local idea
	if result and result.gain > 0.005 then
		-- measure it once more to show its damage and EHP change
		finder:TryReal(result.socket, result.item, result.keystone)
		local r = lastFull
		local base = self.base
		local prices = GetPriceSource()
		local price = prices:UniquePrice(result.item)
		local points = (result.socket.cost or 0) + (result.keystone and result.keystone.path and #result.keystone.path or 0)
		idea = {
			kind = "Timeless jewel",
			title = result.label,
			list = { },
			state = { override = { }, points = points },
			score = result.score,
			gain = result.gain,
			dpsPct = base.dps > 0 and (r.dps / base.dps - 1) * 100 or 0,
			ehpPct = base.ehp > 0 and (r.ehp / base.ehp - 1) * 100 or 0,
			points = points,
			penalties = r.penalties,
			costs = { result.jewelType.name .. ": " .. prices.FormatPrice(price) .. " (base price; this seed may cost more)" },
			totalCost = price,
			explanation = finder:Describe(result),
			assumptions = { "Only one Historic jewel can be used. The jewel's name decides the keystone, the seed decides the other passives." },
			timeless = { finder = finder, result = result },
		}
		-- a timeless jewel with a chosen seed (and conqueror) is a high-end purchase
		if not (self.options.investment and self.options.investment.awakenedGems) then
			idea.title = "(High investment) " .. idea.title
			t_insert(idea.assumptions, "Timeless jewels with a specific seed and conqueror are counted as High investment: they usually cost far more than the base price")
		end
		if points > 0 then
			t_insert(idea.explanation, string.format("Uses %d more passive point%s: remove the same number elsewhere", points, points == 1 and "" or "s"))
		end
	end
	recalc()
	self.calcFunc = build.calcsTab:GetMiscCalculator()
	return idea
end

-- Same points, better passives: free the least useful passives a few times
-- and let the build generator's allocator spend them again (masteries too).
-- The tree is restored afterwards; the idea carries the new tree.
function SynergyFinderClass:TreeRespecIdea()
	local build = self.build
	local spec = build.spec
	local before = spec:CreateUndoState()
	local beforeAlloc = { }
	for id, node in pairs(spec.allocNodes) do beforeAlloc[id] = node end
	local gen = new("BuildGenerator"):BuildGenerator(build, { focus = self.options.focus, investment = self.options.investment,
		yieldEvery = self.options.yieldEvery, onProgress = self.options.onProgress and function() self:Tick() end })
	gen.scorer = self.scorer
	gen.protectedNodes = self.options.protectedNodes
	gen.options.classId = spec.curClassId
	gen.options.ascendClassId = spec.curAscendClassId
	local gain = 0
	local ok, err = pcall(function()
		for _, count in ipairs(self.options.respecRounds or { 8, 14 }) do
			gain = gain + gen:RefineTree(count)
		end
	end)
	local idea
	if ok and gain > 0.005 then
		local after = spec:CreateUndoState()
		local _, r = gen:FullScore()
		local added, removed = { }, { }
		for id, node in pairs(spec.allocNodes) do
			if not beforeAlloc[id] and (node.type == "Notable" or node.type == "Keystone" or node.type == "Mastery") then t_insert(added, node.dn) end
		end
		for id, node in pairs(beforeAlloc) do
			if not spec.allocNodes[id] and (node.type == "Notable" or node.type == "Keystone" or node.type == "Mastery") then t_insert(removed, node.dn) end
		end
		t_sort(added)
		t_sort(removed)
		local base = self.base
		idea = {
			kind = "Tree respec",
			title = "Re-spend passive points (same total)",
			list = { },
			state = { override = { }, points = 0 },
			score = r.score, gain = gain,
			dpsPct = base.dps > 0 and (r.dps / base.dps - 1) * 100 or 0,
			ehpPct = base.ehp > 0 and (r.ehp / base.ehp - 1) * 100 or 0,
			points = 0,
			penalties = r.penalties,
			costs = { },
			explanation = {
				"Remove: " .. (#removed > 0 and table.concat(removed, ", ") or "small passives only"),
				"Add: " .. (#added > 0 and table.concat(added, ", ") or "small passives only"),
				"Found by freeing the least useful passives and spending the points again, in rounds",
			},
			assumptions = { },
			treeState = after,
		}
	end
	spec:RestoreUndoState(before)
	spec:BuildAllDependsAndPaths()
	wipeGlobalCache()
	build.outputRevision = build.outputRevision + 1
	build.buildFlag = false
	build.calcsTab:BuildOutput()
	self.calcFunc = build.calcsTab:GetMiscCalculator()
	if not ok and self.options.debugTiming then ConPrintf("[synergy] tree respec failed: %s", tostring(err)) end
	return idea
end

-- Forbidden Flame / Flesh pair and Watcher's Eye as ideas
function SynergyFinderClass:MetaJewelIdeas(investment)
	local build = self.build
	local lastFull
	local function recalc()
		wipeGlobalCache()
		build.outputRevision = build.outputRevision + 1
		build.buildFlag = false
		build.skillsTab:UpdateSocketGroups()
		build.calcsTab:BuildOutput()
	end
	local finder = new("MetaJewelFinder"):MetaJewelFinder({
		build = build,
		fullScore = function()
			recalc()
			lastFull = self.scorer:Evaluate(build.calcsTab:GetMiscCalculator(), { }, { flasks = "ratio", ratio = self.baseRatio })
			self:Tick()
			return lastFull.score
		end,
		equip = function(item, slotName) return self.itemFinder:Equip(item, slotName, true) end,
		tick = function() self:Tick() end,
	})
	local ideas = { }
	local prices = GetPriceSource()
	local base = self.base
	local results = { finder:ForbiddenPair(base.score) }
	if investment.exceptionalGems ~= false then
		t_insert(results, finder:WatchersEye(base.score, investment.awakenedGems and 3 or 2))
	end
	for _, result in ipairs(results) do
		if result and result.gain > 0.005 then
			local _, points = finder:TryJewels(result.placements)
			local r = lastFull
			local titles = { }
			local total, known = 0, true
			for _, p in ipairs(result.placements) do
				local price = prices:UniquePrice(p.item)
				t_insert(titles, p.item.title .. ": " .. prices.FormatPrice(price))
				if price then total = total + price else known = false end
			end
			local explanation = { }
			for _, p in ipairs(result.placements) do
				local item = p.item
				for _, line in ipairs(item.explicitModLines or { }) do
					local v = line.variantList
					local active = not v or v[item.variant] or (item.variantAlt and v[item.variantAlt]) or (item.variantAlt2 and v[item.variantAlt2])
					if active and not line.line:match("^Historic") then t_insert(explanation, item.title .. ": " .. line.line) end
				end
			end
			if points > 0 then
				t_insert(explanation, string.format("Uses %d more passive point%s for jewel sockets: remove the same number elsewhere", points, points == 1 and "" or "s"))
			end
			t_insert(ideas, {
				kind = "Meta jewel",
				title = result.label,
				list = { },
				state = { override = { }, points = points },
				score = result.score,
				gain = result.gain,
				dpsPct = base.dps > 0 and (r.dps / base.dps - 1) * 100 or 0,
				ehpPct = base.ehp > 0 and (r.ehp / base.ehp - 1) * 100 or 0,
				points = points,
				penalties = r.penalties,
				costs = titles,
				totalCost = known and prices.loaded and total or nil,
				explanation = explanation,
				assumptions = { "Prices are base prices from poe.ninja; jewels with these exact mods / notable usually cost more" },
				metaJewel = { finder = finder, result = result },
			})
		end
	end
	recalc()
	self.calcFunc = build.calcsTab:GetMiscCalculator()
	return ideas
end

------------------------------------------------------------------------------
-- Applying an idea to the build
------------------------------------------------------------------------------

function SynergyFinderClass:Apply(idea)
	local itemsTab = self.itemsTab
	if idea.treeState then
		self.build.spec:RestoreUndoState(idea.treeState)
		self.build.spec:AddUndoState()
		self.build.buildFlag = true
		return
	end
	if idea.metaJewel then
		idea.metaJewel.finder:Apply(idea.metaJewel.result)
		itemsTab:PopulateSlots()
		itemsTab:AddUndoState()
		self.build.buildFlag = true
		return
	end
	if idea.timeless then
		idea.timeless.finder:Apply(idea.timeless.result)
		itemsTab:PopulateSlots()
		itemsTab:AddUndoState()
		self.build.buildFlag = true
		return
	end
	local state = idea.state
	for slotName, item in pairs(state.override.repItems or { }) do
		if item then
			self.itemFinder:Equip(item, slotName, true)
		end
	end
	for slotName, item in pairs(idea.generatedFlasks or { }) do
		self.itemFinder:Equip(item, slotName, true)
	end
	for slotName in pairs(state.override.activeFlaskSlots or { }) do
		if itemsTab.slots[slotName] then
			itemsTab.slots[slotName].active = true
			if itemsTab.activeItemSet[slotName] then itemsTab.activeItemSet[slotName].active = true end
		end
	end
	for slotName in pairs(idea.generatedFlasks or { }) do
		if itemsTab.slots[slotName] then
			itemsTab.slots[slotName].active = true
			if itemsTab.activeItemSet[slotName] then itemsTab.activeItemSet[slotName].active = true end
		end
	end
	local allocated = false
	for _, c in ipairs(idea.list) do
		if c.node then
			self.build.spec:AllocNode(c.node)
			allocated = true
		end
	end
	if state.refund and #state.refund > 0 then
		for i = #state.refund, 1, -1 do
			local node = state.refund[i]
			if node.alloc then self.build.spec:DeallocNode(node) end
		end
		allocated = true
	end
	for _, t in ipairs(state.tattoos or { }) do
		self.extras:ApplyTattoo(t.node, t.name)
		allocated = true
	end
	local group = self:MainSocketGroup()
	if group then
		for _, change in ipairs(state.gemChanges or { }) do
			local gem = data.gems[change.gemId]
			-- find the replaced gem by identity (indexes may have shifted)
			for index, g in ipairs(group.gemList) do
				if g == change.replaces then
					group.gemList[index] = { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = change.gemId }
				end
			end
		end
		self.build.skillsTab:ProcessSocketGroup(group)
	end
	-- keep the estimated counts the idea was scored with
	for _, c in ipairs(idea.list) do
		for key in pairs(c.needs or { }) do
			local mult = key:match("^mult:(.+)$")
			local option = mult and self.autoConfig.optionForMult[mult]
			if option and self.build.configTab.input[option.var] == nil then
				self.build.calcsTab:BuildOutput()
				local value = self.autoConfig:RealisticCount(mult, self.build.calcsTab.mainOutput, self.build.calcsTab.mainEnv)
				self.build.configTab.input[option.var] = value
				self.build.configTab:BuildModList()
			end
		end
	end
	itemsTab:PopulateSlots()
	itemsTab:AddUndoState()
	if allocated then
		self.build.spec:AddUndoState()
	end
	self.build.buildFlag = true
end
