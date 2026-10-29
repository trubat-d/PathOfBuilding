-- Path of Building
--
-- Module: Generator Search
-- Search engines over the finished build, switched by options.engine:
--   * "alns": adaptive large neighbourhood search. A part of the build is torn
--     out and rebuilt with the generator's own steps (destroy / repair
--     operators: tree branches, supports, rares, a unique, a keystone, the
--     ascendancy, an expensive part), the result accepted with simulated
--     annealing (a slightly worse build can be kept early, to get out of the
--     path the greedy steps took) and the best build seen kept. Operators that
--     pay off are chosen more often (adaptive weights).
--   * "lagrange": the budget as a price inside the score (FullScore pays
--     priceWeight per budget's worth of divines), the price raised while the
--     build is over budget and lowered while it is far under (dual ascent), so
--     every step weighs what it buys against what it costs.
--   * "alns+lagrange": both.
-- Every operator is a general rebuild: the special cases the pipeline grew
-- (Blood Magic kept over auras, a unique that forced a downgrade elsewhere...)
-- are one more tear-out the search can try and judge on the whole build.
--
local BuildGeneratorClass = ...
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort
local m_min = math.min
local m_max = math.max
local m_exp = math.exp

local function hasEngine(opts, name)
	local e = opts.engine
	return e and (e == name or e:find(name, 1, true)) and true or false
end
BuildGeneratorClass.HasEngine = function(self, name) return hasEngine(self.options, name) end

------------------------------------------------------------------------------
-- Lagrangian budget
------------------------------------------------------------------------------

-- Price of the build in score: priceWeight per budget's worth of divines
-- (0 without the engine or a budget)
function BuildGeneratorClass:BudgetPrice()
	local opts = self.options
	local budget = opts.totalBudget
	if not self.priceWeight or not budget or budget <= 0 or not GetPriceSource().loaded then return 0, 0 end
	local cost = self:BuildCost()
	-- (over the budget: the price on the excess doubles, the fit at the end
	-- would take it out anyway)
	local over = m_max(0, cost - budget)
	return self.priceWeight * (cost + over) / budget, cost
end

-- Dual ascent on the price: over budget it goes up, far under it goes down
function BuildGeneratorClass:UpdatePriceWeight(label)
	if not self.priceWeight then return end
	local budget = self.options.totalBudget
	if not budget or budget <= 0 then return end
	local cost = self:BuildCost()
	local old = self.priceWeight
	if cost > budget then
		self.priceWeight = m_min(self.options.priceWeightMax or 1, old * (1 + 0.5 * m_min(1, (cost - budget) / budget)))
	elseif cost < 0.8 * budget then
		self.priceWeight = m_max(self.options.priceWeightMin or 0.02, old * 0.7)
	end
	if self.options.debugTiming then ConPrintf("[lagrange] %s: cost %.1f / %.1f, price %.3f -> %.3f", label or "", cost, budget, old, self.priceWeight) end
end

------------------------------------------------------------------------------
-- Escalating requirement weights (engine "escalate"): a requirement still
-- unmet when a stage ends weighs twice as much from then on (up to 16x), one
-- met relaxes back. A gap that needs several steps which each lose damage
-- (passives respecced for a max hit floor, a damage roll given up for a
-- resistance) gets paid for; a fixed weight never pays for the first step.
------------------------------------------------------------------------------

function BuildGeneratorClass:UpdateEscalation(label)
	local scorer = self.scorer
	if not scorer then return end
	scorer.escalate = scorer.escalate or { resist = 1, attributes = 1, dpsTarget = 1, hitFloor = 1 }
	local esc = scorer.escalate
	self:Recalculate()
	local o = self.build.calcsTab.mainOutput or { }
	local unmet = { }
	local missing = 0
	for _, elem in ipairs({ "Fire", "Cold", "Lightning" }) do missing = missing + m_max(0, o["Missing" .. elem .. "Resist"] or 0) end
	unmet.resist = missing > 0
	local short = false
	for _, attr in ipairs({ "Str", "Dex", "Int" }) do if (o["Req" .. attr] or 0) > (o[attr] or 0) then short = true end end
	unmet.attributes = short
	local _, r = self:FullScore()
	unmet.dpsTarget = scorer.dpsTarget and r and r.dps and r.dps < scorer.dpsTarget or false
	local minHit = scorer:MinMaxHit(o)
	local hitFloor = scorer.hitFloor or (scorer.focus and scorer.focus.hitFloor)
	unmet.hitFloor = hitFloor and minHit and minHit < hitFloor or false
	local max = self.options.escalateMax or 16
	local parts = { }
	for key, value in pairs(esc) do
		if unmet[key] then esc[key] = m_min(max, value * 2) else esc[key] = m_max(1, value * 0.7) end
		if esc[key] > 1 then t_insert(parts, string.format("%s x%.1f", key, esc[key])) end
	end
	t_sort(parts)
	if self.options.debugTiming then ConPrintf("[escalate] %s: %s", label or "", table.concat(parts, ", ")) end
end

------------------------------------------------------------------------------
-- ALNS operators: each tears out part of the build and rebuilds it.
-- Returns a label, or nil when it could do nothing
------------------------------------------------------------------------------

local alnsOps = { }

alnsOps.tree = function(self, finder) return self:Perturb("tree", finder) end
alnsOps.links = function(self, finder) return self:Perturb("links", finder) end
alnsOps.gear = function(self, finder) return self:Perturb("gear", finder) end

-- A unique taken out (a rare on its base instead), then every affordable
-- unique tried again on the build without it
alnsOps.unique = function(self, finder)
	local _, entries = self:BuildCost()
	local list = { }
	for _, e in ipairs(entries) do
		if e.unique and e.slot and not (self.lockedSlots and self.lockedSlots[e.slot]) and (e.kind == "gear" or e.kind == "jewel") then t_insert(list, e) end
	end
	if #list == 0 then return end
	local entry = list[self:Random(#list)]
	if not self:CheapVersion(entry) then return end
	self:AutoConfigure()
	pcall(function() self:UniqueSweep(2) end)
	self:RefineTree(6)
	return "unique taken out and the uniques tried again: " .. tostring(entry.label)
end

-- An expensive part made cheap, the divines spent again where they gain most
alnsOps.budget = function(self, finder)
	if not self.options.totalBudget then return end
	local _, entries = self:BuildCost()
	local list, total = { }, 0
	for _, e in ipairs(entries) do
		if e.price >= 1 and not (e.slot and self.lockedSlots and self.lockedSlots[e.slot]) then t_insert(list, e) total = total + e.price end
	end
	if #list == 0 then return end
	-- (by price: the expensive parts are the ones a budget move frees most for)
	local r, entry = self:Random(1000) / 1000 * total, list[#list]
	for _, e in ipairs(list) do r = r - e.price if r <= 0 then entry = e break end end
	if not self:CheapVersion(entry) then return end
	self:AutoConfigure()
	pcall(function() self:SpendBudgetMove() end)
	self:RefineTree(6)
	return string.format("%s (%.1f div) made cheap, the budget spent again", tostring(entry.label), entry.price)
end

-- Keystones: a taken one removed, or a near one taken; the utility gems and
-- the tree rebuilt around the change (Blood Magic out: auras come back)
alnsOps.keystone = function(self, finder)
	local spec = self.build.spec
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	local needed = { }
	for _, name in ipairs((self.options.archetype or { }).keystones or { }) do
		local node = archetypes.NodeByName(spec, name)
		if node then needed[node.id] = true end
	end
	local taken, near = { }, { }
	for _, node in ipairs(self.SortedNodes(spec.allocNodes)) do
		if node.type == "Keystone" and not node.ascendancyName and not needed[node.id] then t_insert(taken, node) end
	end
	for _, node in ipairs(self.SortedNodes(spec.nodes)) do
		if node.type == "Keystone" and not node.alloc and not node.ascendancyName and node.path and #node.path <= (self.options.keystonePath or 8)
			and not (self.forbiddenNodes and self.forbiddenNodes[node.id]) and not node.conqueredBy then
			t_insert(near, node)
		end
	end
	local label
	self.protectedNodes = self.protectedNodes or { }
	if #taken > 0 and (#near == 0 or self:Random(2) == 1) then
		local node = taken[self:Random(#taken)]
		self.protectedNodes[node.id] = nil
		if self.keystonesKept then self.keystonesKept[node.id] = nil end
		spec:DeallocNode(node)
		-- (not straight back in this round)
		local saved = self.forbiddenNodes
		self.forbiddenNodes = { }
		for k, v in pairs(saved or { }) do self.forbiddenNodes[k] = v end
		self.forbiddenNodes[node.id] = true
		spec:BuildAllDependsAndPaths()
		self:Recalculate()
		self:TrimTree()
		self:AutoConfigure()
		self:ChooseUtilityGems()
		self:Recalculate()
		self:AllocateTree(true)
		self:RefineTree(6)
		self.forbiddenNodes = saved
		label = "keystone taken out: " .. node.dn
	elseif #near > 0 then
		local node = near[self:Random(#near)]
		spec:AllocNode(node)
		self.protectedNodes[node.id] = true
		self:Recalculate()
		self:TrimTree()
		self:AutoConfigure()
		self:ChooseUtilityGems()
		self:Recalculate()
		self:RefineTree(6)
		if not node.alloc then return end
		self.keystonesKept = self.keystonesKept or { }
		self.keystonesKept[node.id] = true
		label = "keystone taken: " .. node.dn
	end
	self:AutoConfigure()
	return label
end

-- The ascendancy chosen again, starting from one random notable (a different
-- start than the greedy one), the utility gems again for it
alnsOps.ascendancy = function(self, finder)
	local spec = self.build.spec
	local notables = { }
	for _, node in ipairs(self.SortedNodes(spec.nodes)) do
		if node.ascendancyName == spec.curAscendClassName and (node.type == "Notable" or node.isMultipleChoiceOption) and not node.alloc then
			t_insert(notables, node)
		end
	end
	if #notables == 0 then return end
	self:ClearAscendancy()
	local node = notables[self:Random(#notables)]
	spec:AllocNode(node)
	self:Recalculate()
	self:AllocateTree(true, true)
	self:EnforceGolemLimit()
	self:AutoConfigure()
	self:ChooseUtilityGems()
	self:Recalculate()
	self:RefineTree(6)
	return "ascendancy rebuilt from " .. node.dn
end

-- The utility gems (auras, curses, guards...) chosen again from scratch, with
-- the passives after them
alnsOps.auras = function(self, finder)
	local list = self.build.skillsTab.socketGroupList
	-- (one buff the build runs left out of the rebuild: the same greedy choice
	-- would come back otherwise; its reservation goes to other buffs, or to a
	-- keystone that wanted the mana)
	local buffs = { }
	for _, g in ipairs(list) do
		if g ~= self.mainGroup and g.enabled ~= false then
			for _, gem in ipairs(g.gemList) do
				local d = gem.gemId and data.gems[gem.gemId]
				if d and d.tags and (d.tags.aura or d.tags.herald or d.tags.golem or d.tags.banner) and not d.grantedEffect.support then t_insert(buffs, d.name) end
			end
		end
	end
	t_sort(buffs)
	local removed = 0
	for i = #list, 1, -1 do
		local g = list[i]
		if g ~= self.mainGroup and (g.label or ""):find("(generated utility)", 1, true) then t_remove(list, i) removed = removed + 1 end
	end
	if removed == 0 or #buffs == 0 then return end
	local out = buffs[self:Random(#buffs)]
	self.forbiddenGems = { [out] = true }
	self:Recalculate()
	self:AutoConfigure()
	local ok, err = pcall(function() self:ChooseUtilityGems() end)
	self.forbiddenGems = nil
	if not ok then error(err) end
	self:Recalculate()
	self:RefineTree(6)
	return string.format("utility gems chosen again without %s", out)
end

local opOrder = { "tree", "links", "gear", "unique", "budget", "keystone", "ascendancy", "auras" }

-- Nodes of a table in id order (deterministic)
function BuildGeneratorClass.SortedNodes(tbl)
	local list = { }
	for _, node in pairs(tbl) do t_insert(list, node) end
	t_sort(list, function(a, b) return a.id < b.id end)
	return list
end

function BuildGeneratorClass:AlnsScore()
	self:AutoConfigure()
	local score, r = self:FullScore()
	-- (the excess over the budget priced in: the fit at the end takes it out)
	local budget = self.options.totalBudget
	if budget and budget > 0 and not self.priceWeight and GetPriceSource().loaded then
		local cost = self:BuildCost()
		if cost > budget then score = score - (self.options.alnsOverWeight or 4) * (cost - budget) / budget end
	end
	return score, r
end

function BuildGeneratorClass:AlnsSearch(rounds, seconds)
	local opts = self.options
	rounds = rounds or opts.alnsRounds or 30
	seconds = seconds or opts.alnsSeconds or 1500
	local finder = new("BestItemFinder"):BestItemFinder(self.itemsTab)
	local ops = { }
	local allowed = { }
	for name in (opts.alnsOps or ""):gmatch("[^/]+") do allowed[name] = true end
	for _, name in ipairs(opOrder) do
		if next(allowed) == nil or allowed[name] then t_insert(ops, { name = name, fn = alnsOps[name], weight = 1, used = 0, kept = 0, best = 0, time = 0 }) end
	end
	local function protectedCopy()
		local p, k = { }, { }
		for id, v in pairs(self.protectedNodes or { }) do p[id] = v end
		for id, v in pairs(self.keystonesKept or { }) do k[id] = v end
		return p, k
	end
	local function take()
		local snap = self:Snapshot()
		snap.protected, snap.keystones = protectedCopy()
		snap.priceWeight = self.priceWeight
		return snap
	end
	local function back(snap)
		self:Restore(snap)
		self.protectedNodes, self.keystonesKept = { }, { }
		for id, v in pairs(snap.protected) do self.protectedNodes[id] = v end
		for id, v in pairs(snap.keystones) do self.keystonesKept[id] = v end
		self:AutoConfigure()
		self:Recalculate()
	end
	local startScore = self:AlnsScore()
	local current, best = startScore, startScore
	local curSnap = take()
	local bestSnap = curSnap
	local t0 = opts.alnsT0 or 0.04
	local startClock = os.clock()
	local savedLog = #self.log
	local kept = { }
	local reaction = opts.alnsReaction or 0.3
	local round = 0
	while round < rounds and os.clock() - startClock < seconds do
		round = round + 1
		self:Inner((round - 1) / rounds)
		-- roulette on the weights
		local total = 0
		for _, op in ipairs(ops) do total = total + op.weight end
		local r, op = self:Random(100000) / 100000 * total, ops[#ops]
		for _, o in ipairs(ops) do r = r - o.weight if r <= 0 then op = o break end end
		local opClock = os.clock()
		local ok, label = pcall(op.fn, self, finder)
		if not ok then ConPrintf("ALNS %s failed: %s", op.name, tostring(label)) end
		local score = (ok and label) and self:AlnsScore() or nil
		-- (a rebuild close behind: polished before it is judged - the repair
		-- steps are quicker than the ones that made the build, a few more
		-- passives moved often decide it)
		if score and score <= current + 0.002 and score > current - (opts.alnsPolishGap or 0.2) and opts.alnsPolish ~= false then
			local okP = pcall(function() self:RefineTree(10) end)
			if okP then score = self:AlnsScore() end
		end
		for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
		op.used = op.used + 1
		op.time = op.time + os.clock() - opClock
		local temperature = t0 * m_max(0, 1 - (round - 1) / m_max(1, rounds - 1))
		local sigma = 0
		local accepted = false
		if score then
			local delta = score - current
			if delta > 0.002 then
				accepted = true
				sigma = 2
			elseif temperature > 0 and delta > -0.5 and self:Random(100000) / 100000 < m_exp(delta / temperature) and delta < -0.002 then
				accepted = true
				sigma = 0.5
			end
		end
		if opts.debugTiming then
			ConPrintf("[alns] %d %s: %s %.3f -> %s (best %.3f, T %.3f) %s %.0fs", round, op.name, tostring(label), current, score and string.format("%.3f", score) or "-", best, temperature, accepted and "ACCEPT" or "reject", os.clock() - opClock)
		end
		if accepted then
			current = score
			curSnap = take()
			op.kept = op.kept + 1
			if score > best + 0.002 then
				best = score
				bestSnap = curSnap
				sigma = 4
				op.best = op.best + 1
				t_insert(kept, string.format("%s (%s)", label, op.name))
			end
		else
			back(curSnap)
		end
		op.weight = m_max(0.15, (1 - reaction) * op.weight + reaction * sigma)
		self:Tick()
	end
	if bestSnap ~= curSnap then back(bestSnap) end
	for i = #self.log, savedLog + 1, -1 do t_remove(self.log, i) end
	local after = self:AlnsScore()
	local stats = { }
	for _, op in ipairs(ops) do t_insert(stats, string.format("%s %d/%d/%d %.0fs", op.name, op.best, op.kept, op.used, op.time)) end
	if opts.debugTiming then ConPrintf("[alns] done %d rounds %.0fs: %.3f -> %.3f; %s", round, os.clock() - startClock, startScore, after, table.concat(stats, ", ")) end
	self.alnsStats = { rounds = round, seconds = os.clock() - startClock, start = startScore, finish = after, ops = stats }
	if after > startScore + 0.002 then
		self:Note(string.format("Rebuild search (%d rounds): %d improvements kept (%s), score %+.3f", round, #kept, table.concat(kept, "; "), after - startScore))
	end
	return after - startScore
end
