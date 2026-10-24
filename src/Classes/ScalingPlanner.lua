-- Path of Building
--
-- Class: Scaling Planner
-- Fast estimate of how far each archetype can take a skill, without building
-- each one. Starting from one quick build of the skill, an archetype's
-- commitments are applied on top (its keystones, supports, playstyle support,
-- best uniques), then a fixed amount of "investment" is spent one unit at a
-- time on whichever stat gives the most score right now (increased damage,
-- crit, speed, penetration, flat damage, mana, attributes, gem levels, life,
-- energy shield, armour, resistances...). Each unit is about one notable or
-- one good rare mod; re-measuring after every unit captures diminishing
-- returns (a big "increased" bucket gains little, a new "more" multiplier a
-- lot). Every number is still PoB's calculator; only the passives and gear
-- are abstracted, which makes an archetype cost seconds instead of a minute.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort

---@class ScalingPlanner
local ScalingPlannerClass = newClass("ScalingPlanner")

-- gen: a BuildGenerator that has just built the base (quick) build
function ScalingPlannerClass:ScalingPlanner(gen)
	self.gen = gen
	self.build = gen.build
	self.scorer = gen.scorer
	self.analyzer = new("ScalingAnalyzer"):ScalingAnalyzer(gen.build, gen.scorer, nil)
	return self
end

local nextId = -20000
local function virtualNode(spec, lines)
	nextId = nextId - 1
	local node = { id = nextId, type = "Normal", name = "Planned investment", dn = "Planned investment", sd = { } }
	for i, l in ipairs(lines) do node.sd[i] = l end
	spec.tree:ProcessStats(node)
	return node
end

-- Score of the base build with an override
function ScalingPlannerClass:Score(override)
	local output = self.calcFunc(override)
	self.gen:Tick()
	return self.scorer:ScoreOutput(output), output
end

-- Applies the archetype's supports to the main link (returns a restore function)
function ScalingPlannerClass:ApplySupports(archetype)
	local gen = self.gen
	local group = gen.mainGroup
	local saved = { }
	for i, g in ipairs(group.gemList) do saved[i] = g end
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	local wanted = { }
	for _, name in ipairs(archetype.supports or { }) do
		local gem = archetypes.GemByName(name)
		if gem and archetypes.CanSupport(gem, gen.mainGem) then t_insert(wanted, gem) end
	end
	if archetype.playstyle then
		-- the best support of the playstyle
		local best, bestScore
		for _, gem in pairs(data.gems) do
			if gem.grantedEffect and gem.grantedEffect.support and archetypes.SupportPlaystyle(gem) == archetype.playstyle
				and not (gem.tags and (gem.tags.exceptional or gem.tags.awakened)) and archetypes.CanSupport(gem, gen.mainGem) then
				t_insert(group.gemList, { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = self:GemId(gem) })
				self.build.skillsTab:ProcessSocketGroup(group)
				local score = self:Score({ })
				t_remove(group.gemList)
				if not bestScore or score > bestScore then best, bestScore = gem, score end
			end
		end
		if best then t_insert(wanted, 1, best) end
	end
	-- each wanted support replaces the support that loses the least
	for _, gem in ipairs(wanted) do
		local already = false
		for _, g in ipairs(group.gemList) do if g.gemData == gem or (g.gemId and data.gems[g.gemId] == gem) then already = true end end
		if not already then
			local bestIndex, bestScore
			for i = 2, #group.gemList do
				local old = group.gemList[i]
				group.gemList[i] = { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = self:GemId(gem) }
				self.build.skillsTab:ProcessSocketGroup(group)
				local score = self:Score({ })
				group.gemList[i] = old
				if not bestScore or score > bestScore then bestIndex, bestScore = i, score end
			end
			if bestIndex then
				group.gemList[bestIndex] = { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = self:GemId(gem) }
			elseif #group.gemList < 6 then
				t_insert(group.gemList, { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = self:GemId(gem) })
			end
			self.build.skillsTab:ProcessSocketGroup(group)
		end
	end
	-- a trigger setup (Classes/TriggerSetups): the first source the weapons
	-- allow that really triggers the spell, linked with its support (in the
	-- link's last sockets; a separate link for Spellslinger's wand attack)
	local sourceGroup
	if archetype.trigger then
		local ts = new("TriggerSetups"):TriggerSetups()
		local setup = ts.setups[archetype.trigger]
		local setupGems = new("GemSetup"):GemSetup(gen)
		local supportId = setup and setup.support and ts.GemId(setup.support)
		local function entry(id) return { level = data.gems[id].naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = id } end
		for _, name in ipairs(setup and setup.sources or { }) do
			local sourceId = ts.GemId(name)
			if sourceId and setupGems:CanUse(sourceId) then
				while #group.gemList > (setup.linkSource == false and 5 or 4) do t_remove(group.gemList) end
				if setup.linkSource == false then
					sourceGroup = { label = "Trigger (planning)", enabled = true, slot = "Weapon 1", gemList = { entry(sourceId) } }
					t_insert(self.build.skillsTab.socketGroupList, sourceGroup)
					self.build.skillsTab:ProcessSocketGroup(sourceGroup)
				else
					t_insert(group.gemList, entry(sourceId))
				end
				if supportId then t_insert(group.gemList, entry(supportId)) end
				self.build.skillsTab:ProcessSocketGroup(group)
				break
			end
		end
	end
	-- the archetype's auras, in a group of their own
	local auraGroup
	if archetype.auras and #archetype.auras > 0 then
		auraGroup = { label = "Archetype auras (planning)", enabled = true, gemList = { } }
		for _, name in ipairs(archetype.auras) do
			local gem = archetypes.GemByName(name)
			if gem then t_insert(auraGroup.gemList, { level = gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = self:GemId(gem) }) end
		end
		t_insert(self.build.skillsTab.socketGroupList, auraGroup)
		self.build.skillsTab:ProcessSocketGroup(auraGroup)
	end
	return function()
		for i = #group.gemList, 1, -1 do group.gemList[i] = nil end
		for i, g in ipairs(saved) do group.gemList[i] = g end
		self.build.skillsTab:ProcessSocketGroup(group)
		local list = self.build.skillsTab.socketGroupList
		for i = #list, 1, -1 do if (auraGroup and list[i] == auraGroup) or (sourceGroup and list[i] == sourceGroup) then t_remove(list, i) end end
	end
end

-- gem id of a gem data table
function ScalingPlannerClass:GemId(gem)
	if not self.gemIds then
		self.gemIds = { }
		for id, g in pairs(data.gems) do self.gemIds[g] = id end
	end
	return self.gemIds[gem]
end

-- Override for the archetype's keystones and best uniques
function ScalingPlannerClass:Commitments(archetype)
	local spec = self.build.spec
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	local override = { addNodes = { }, repItems = { } }
	local labels = { }
	for _, name in ipairs(archetype.keystones or { }) do
		local node = archetypes.NodeByName(spec, name)
		if node and not node.alloc then
			override.addNodes[node] = true
			t_insert(labels, name)
		end
	end
	-- keystones already in the base build that work against the archetype
	-- (Elemental Overload for crit, Roiling Tempest for Avatar of Fire...)
	override.removeNodes = { }
	for _, name in ipairs(archetype.excludeKeystones or { }) do
		local node = archetypes.NodeByName(spec, name)
		if node and node.alloc then override.removeNodes[node] = true end
	end
	if next(override.addNodes) then
		local current = self:Score(override)
		for _, node in pairs(spec.allocNodes) do
			if node.type == "Keystone" and not override.removeNodes[node] then
				override.removeNodes[node] = true
				local score = self:Score(override)
				if score > current + 0.002 then
					current = score
					t_insert(labels, "without " .. node.dn)
				else
					override.removeNodes[node] = nil
				end
			end
		end
	end
	-- uniques: the best (item, slot) pairs, up to 3, each kept while it helps
	local candidates = archetypes.UniqueCandidates(archetype)
	if #candidates > 0 then
		local finder = new("BestItemFinder"):BestItemFinder(self.build.itemsTab)
		local filter = { obtainableOnly = true, levelOnly = true, investment = self.gen.options.investment }
		local slots = finder:GetActiveSlots()
		local used = { }
		local current = self:Score(override)
		for round = 1, archetype.maxUniques or 3 do
			local best
			for _, item in ipairs(candidates) do
				if not used[item] and finder:IsItemAllowed(item, filter) then
					for _, slotName in ipairs(slots) do
						if override.repItems[slotName] == nil and self.build.itemsTab:IsItemValidForSlot(item, slotName) then
							override.repItems[slotName] = item
							local score = self:Score(override)
							override.repItems[slotName] = nil
							if not best or score > best.score then best = { item = item, slot = slotName, score = score } end
						end
					end
				end
			end
			-- (the first one is the archetype's commitment, more only if they help)
			if not best or best.score < current - (round == 1 and 1.0 or -0.003) then break end
			used[best.item] = true
			override.repItems[best.slot] = best.item
			current = best.score
			t_insert(labels, best.item.title or best.item.name)
		end
	end
	return override, labels
end

-- Spends units of investment on the best stat each time.
-- Returns final score, { [lever id] = units }, final output
-- (levers for what an idea stacks, beyond the usual ones)
local lensLevers = {
	BlockChance = { "+5% Chance to Block Attack Damage", "+5% Chance to Block Spell Damage" },
	PowerChargesMax = { "+1 to Maximum Power Charges" },
	FrenzyChargesMax = { "+1 to Maximum Frenzy Charges" },
	EnduranceChargesMax = { "+1 to Maximum Endurance Charges" },
	Evasion = { "+1000 to Evasion Rating" },
	Armour = { "+1000 to Armour" },
	EnergyShield = { "+150 to maximum Energy Shield" },
	MaximumRage = { "+10 to Maximum Rage" },
	FortificationStacks = { "+3 to maximum Fortification" },
}
function ScalingPlannerClass:Invest(override, units, archetype)
	local spec = self.build.spec
	local levers = self.analyzer:Levers()
	local lens = archetype and archetype.lens
	if lens and lensLevers[lens.stat] then
		t_insert(levers, { id = "lens", max = 6, label = lens.label or lens.stat, kind = "damage", lines = lensLevers[lens.stat] })
	end
	local counts = { }
	local addNodes = { }
	for node in pairs(override.addNodes or { }) do addNodes[node] = true end
	local o = { addNodes = addNodes, repItems = override.repItems, removeNodes = override.removeNodes }
	local current, output = self:Score(o)
	for _ = 1, units do
		local best
		for _, lever in ipairs(levers) do
			if (counts[lever.id] or 0) < (lever.max or 99) then
			local node = virtualNode(spec, lever.lines)
			addNodes[node] = true
			local score, out = self:Score(o)
			addNodes[node] = nil
			if not best or score > best.score then best = { lever = lever, node = node, score = score, output = out } end
			end
		end
		if not best or best.score <= current then break end
		addNodes[best.node] = true
		counts[best.lever.id] = (counts[best.lever.id] or 0) + 1
		current, output = best.score, best.output
	end
	return current, counts, output, levers
end

-- Plans every archetype on the base build. Returns a list sorted best first:
-- { archetype, score, dps, minHit, commitments = { labels }, plan = "text" }
function ScalingPlannerClass:Run(archetypes, opts)
	opts = opts or { }
	local gen = self.gen
	gen:Recalculate()
	self.calcFunc = gen.calcFunc
	self.analyzer.calcFunc = gen.calcFunc
	local results = { }
	for _, archetype in ipairs(archetypes) do
		local restore = self:ApplySupports(archetype)
		gen:Recalculate()
		self.calcFunc = gen.calcFunc
		local ok, err = pcall(function()
			local override, labels = self:Commitments(archetype)
			local score, counts, output, levers = self:Invest(override, opts.units or 20, archetype)
			local parts = { }
			for _, lever in ipairs(levers) do
				if counts[lever.id] then t_insert(parts, string.format("%dx %s", counts[lever.id], lever.label)) end
			end
			t_insert(results, {
				archetype = archetype, score = score,
				dps = self.scorer:GetDPS(output), minHit = (self.scorer:MinMaxHit(output)),
				commitments = labels, plan = table.concat(parts, ", "),
			})
		end)
		if not ok then
			t_insert(results, { archetype = archetype, error = tostring(err) })
		end
		restore()
		gen:Recalculate()
		self.calcFunc = gen.calcFunc
	end
	t_sort(results, function(a, b) return (a.score or -math.huge) > (b.score or -math.huge) end)
	return results
end
