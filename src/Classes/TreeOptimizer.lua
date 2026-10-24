-- Path of Building
--
-- Class: Tree Optimizer
-- Improves a generated passive tree by choosing which targets (notables,
-- keystones, jewel sockets, useful small passives) to take, then connecting
-- them with the fewest points (shortest paths from the class start, a Steiner
-- tree approximation). Growing the tree one path at a time, as the greedy
-- allocator does, often reaches targets by long detours; reconnecting the same
-- targets usually frees points, and swapping weak targets for better ones
-- (judged with their real connection cost) finds trees the greedy never sees.
--
-- gen: a BuildGenerator (Score, FullScore, Recalculate, PointBudget,
-- AllocateTree, Tick, protectedNodes, build)
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_min = math.min
local m_max = math.max

---@class TreeOptimizer
local TreeOptimizerClass = newClass("TreeOptimizer")

function TreeOptimizerClass:TreeOptimizer(gen)
	self.gen = gen
	self.spec = gen.build.spec
	return self
end

-- Nodes that belong to cluster jewel subgraphs (generated ids) stay as they are
local function isSubgraph(node)
	return node.id >= 65536
end

-- Main tree nodes a path can go through
function TreeOptimizerClass:Passable(node)
	if node.ascendancyName or node.type == "Mastery" or node.type == "AscendClassStart" or node.isProxy or isSubgraph(node) then
		return false
	end
	if node.type == "ClassStart" then return node == self.startNode end
	return true
end

-- Builds a connected tree for the targets, starting from seed (a node set,
-- e.g. the current tree minus a target): keeps the part of seed still linked
-- to the class start, attaches the missing targets nearest first (multi-source
-- BFS = shortest paths), then removes branches that lead to no target.
-- Returns the node set (start included), or nil if a target can't be reached
function TreeOptimizerClass:Rebuild(seed, targets)
	local start = self.startNode
	local inTree = { [start] = true }
	local queue, head = { start }, 1
	while head <= #queue do
		local node = queue[head]
		head = head + 1
		for _, other in ipairs(node.linked) do
			if seed[other] and not inTree[other] and self:Passable(other) then
				inTree[other] = true
				t_insert(queue, other)
			end
		end
	end
	local remaining, count = { }, 0
	for node in pairs(targets) do
		if not inTree[node] then remaining[node] = true count = count + 1 end
	end
	while count > 0 do
		local parent = { }
		queue, head = { }, 1
		for node in pairs(inTree) do
			parent[node] = false
			t_insert(queue, node)
		end
		local found
		while head <= #queue do
			local node = queue[head]
			head = head + 1
			if remaining[node] then found = node break end
			for _, other in ipairs(node.linked) do
				if parent[other] == nil and self:Passable(other) then
					parent[other] = node
					t_insert(queue, other)
				end
			end
		end
		if not found then return nil end
		local node = found
		while node and not inTree[node] do
			inTree[node] = true
			if remaining[node] then remaining[node] = nil count = count - 1 end
			node = parent[node]
		end
	end
	-- prune: passives that are neither targets nor on the way to one
	local changed = true
	while changed do
		changed = false
		for node in pairs(inTree) do
			if node ~= start and not targets[node] then
				local degree = 0
				for _, other in ipairs(node.linked) do
					if inTree[other] then degree = degree + 1 end
				end
				if degree <= 1 then
					inTree[node] = nil
					changed = true
				end
			end
		end
	end
	return inTree
end

-- Shortest connection of the targets alone (no seed)
function TreeOptimizerClass:Connect(targets)
	return self:Rebuild({ }, targets)
end

-- Masteries are kept while a notable of their group stays allocated
function TreeOptimizerClass:KeptMasteries(nodeSet)
	local kept, dropped = { }, { }
	for _, node in pairs(self.spec.allocNodes) do
		if node.type == "Mastery" and not node.ascendancyName then
			local ok = false
			for other in pairs(nodeSet) do
				if other.group == node.group and other.type == "Notable" then ok = true break end
			end
			if ok then kept[node] = true else dropped[node] = true end
		end
	end
	return kept, dropped
end

-- Points a node set costs, with the masteries and cluster subgraph nodes kept
function TreeOptimizerClass:Cost(nodeSet)
	local cost = 0
	for node in pairs(nodeSet) do
		if node.type ~= "ClassStart" then cost = cost + 1 end
	end
	local kept = self:KeptMasteries(nodeSet)
	for _ in pairs(kept) do cost = cost + 1 end
	return cost + self.fixedCost
end

-- Calculator override that turns the current tree into nodeSet
function TreeOptimizerClass:Override(nodeSet)
	local add, remove = { }, { }
	for node in pairs(nodeSet) do
		if not node.alloc then add[node] = true end
	end
	local _, dropped = self:KeptMasteries(nodeSet)
	for _, node in pairs(self.spec.allocNodes) do
		if not node.ascendancyName and node.type ~= "ClassStart" and not self.fixed[node] then
			if node.type == "Mastery" then
				if dropped[node] then remove[node] = true end
			elseif not nodeSet[node] then
				remove[node] = true
			end
		end
	end
	return { addNodes = add, removeNodes = remove }
end

-- Score of a node set, plus the points it leaves free valued at the build's
-- typical value per point (so a shorter tree with the same targets wins)
function TreeOptimizerClass:Evaluate(nodeSet)
	if not nodeSet then return nil end
	local cost = self:Cost(nodeSet)
	if cost > self.budget then return nil end
	local score = self.gen:Score(self:Override(nodeSet))
	return score + (self.budget - cost) * self.pointValue, cost
end

-- Allocates exactly nodeSet in the main tree (ascendancy, masteries of kept
-- groups and cluster subgraphs untouched)
function TreeOptimizerClass:Apply(nodeSet)
	local spec = self.spec
	local _, dropped = self:KeptMasteries(nodeSet)
	for node in pairs(dropped) do spec:DeallocNode(node) end
	for _, node in pairs(spec.nodes) do
		if not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "Mastery" and not self.fixed[node] then
			local want = nodeSet[node] and true or false
			if node.alloc ~= want then
				node.alloc = want
				spec.allocNodes[node.id] = want and node or nil
			end
		end
	end
	spec:BuildAllDependsAndPaths()
end

-- Current targets: notables, keystones, sockets with jewels, protected nodes,
-- and allocated small passives at the end of a path (taken for themselves)
function TreeOptimizerClass:CurrentTargets()
	local spec = self.spec
	local protected = self.gen.protectedNodes or { }
	local targets = { }
	for _, node in pairs(spec.allocNodes) do
		if not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "Mastery" and not isSubgraph(node) then
			local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
			-- (depends: the nodes that would be lost without this one, itself included)
			local leaf = not node.depends or #node.depends <= 1
			if not self.fixed[node] and (node.type == "Notable" or node.type == "Keystone" or holdsJewel or protected[node.id] or leaf) then
				targets[node] = true
			end
		end
	end
	return targets
end

-- Unallocated notables / keystones worth trying, best value per point first
function TreeOptimizerClass:Candidates(limit)
	local gen = self.gen
	local spec = self.spec
	local current = gen:Score()
	local list = { }
	for _, node in pairs(spec.nodes) do
		if not node.alloc and node.path and #node.path <= 10 and not node.ascendancyName and not isSubgraph(node)
			and (node.type == "Notable" or node.type == "Keystone") and not (gen.forbiddenNodes and gen.forbiddenNodes[node.id]) then
			local pathSet = { }
			for _, n in ipairs(node.path) do pathSet[n] = true end
			local gain = gen:Score({ addNodes = pathSet }) - current
			if gain > 0 then t_insert(list, { node = node, value = gain / #node.path, gain = gain }) end
		end
	end
	t_sort(list, function(a, b) return a.value > b.value end)
	for i = #list, (limit or 30) + 1, -1 do list[i] = nil end
	return list
end

-- Runs the optimisation; returns the score gain kept (0 if none)
function TreeOptimizerClass:Run(opts)
	opts = opts or { }
	local gen = self.gen
	local spec = self.spec
	gen:Recalculate()
	self.startNode = spec.nodes[spec.curClass.startNodeId]
	if not self.startNode then return 0 end
	self.budget = gen:PointBudget()
	-- cluster subgraph nodes, and allocated nodes only reachable through them,
	-- are kept as they are
	self.fixed = { }
	local queue, head = { self.startNode }, 1
	local reach = { [self.startNode] = true }
	while head <= #queue do
		local node = queue[head]
		head = head + 1
		for _, other in ipairs(node.linked) do
			if not reach[other] and self:Passable(other) then reach[other] = true t_insert(queue, other) end
		end
	end
	self.fixedCost = 0
	for _, node in pairs(spec.allocNodes) do
		if not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "Mastery" and (isSubgraph(node) or not reach[node]) then
			self.fixed[node] = true
			self.fixedCost = self.fixedCost + 1
		end
	end
	local before = gen:FullScore()
	local undo = spec:CreateUndoState()
	local masteryBefore = { }
	for k, v in pairs(spec.masterySelections) do masteryBefore[k] = v end

	-- value of a free point: the average loss of the weakest end-of-path passives
	local current = gen:Score()
	local losses = { }
	for _, node in pairs(spec.allocNodes) do
		if not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "Mastery" and not isSubgraph(node) and node.depends and #node.depends <= 1 then
			t_insert(losses, m_max(0, current - gen:Score({ removeNodes = { [node] = true } })))
		end
	end
	t_sort(losses)
	local sum, n = 0, 0
	for i = 1, m_min(8, #losses) do sum, n = sum + losses[i], n + 1 end
	self.pointValue = n > 0 and sum / n or 0.003

	local targets = self:CurrentTargets()
	-- the current tree (main part) as the starting solution
	local bestSet = { [self.startNode] = true }
	for _, node in pairs(spec.allocNodes) do
		if not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "Mastery" and not self.fixed[node] then
			bestSet[node] = true
		end
	end
	local bestScore = self:Evaluate(bestSet)
	if not bestScore then return 0 end
	local function without(set, node)
		local copy = { }
		for n in pairs(set) do if n ~= node then copy[n] = true end end
		return copy
	end
	-- 1. reroute: reattach each target by its shortest path from the rest of
	--    the tree (removes detours; keeps a change when it costs fewer points)
	local rerouted = 0
	for _ = 1, 2 do
		local improved = false
		for node in pairs(targets) do
			local set = self:Rebuild(without(bestSet, node), targets)
			if set and self:Cost(set) < self:Cost(bestSet) then
				local score = self:Evaluate(set)
				if score and score > bestScore + 0.0002 then
					bestSet, bestScore = set, score
					rerouted = rerouted + 1
					improved = true
				end
			end
			gen:Tick()
		end
		if not improved then break end
	end
	-- 2. swaps: drop a weak target, add a better one, both with real path costs
	local candidates = self:Candidates(opts.candidates or 30)
	local protected = gen.protectedNodes or { }
	local swaps = 0
	for _ = 1, opts.rounds or 6 do
		local weak = { }
		for node in pairs(targets) do
			local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
			if not protected[node.id] and not holdsJewel then
				targets[node] = nil
				local set = self:Rebuild(without(bestSet, node), targets)
				targets[node] = true
				local score = self:Evaluate(set)
				if score then t_insert(weak, { node = node, loss = bestScore - score, set = set }) end
			end
			gen:Tick()
		end
		t_sort(weak, function(a, b) return a.loss < b.loss end)
		local bestMove
		for i = 0, m_min(opts.weak or 8, #weak) do
			local w = weak[i]
			if w and w.loss < 0 and (not bestMove or bestScore - w.loss > bestMove.score) then
				bestMove = { score = bestScore - w.loss, drop = w.node, set = w.set }
			end
			local drop = w and w.node
			local seed = w and w.set or bestSet
			if drop then targets[drop] = nil end
			for _, c in ipairs(candidates) do
				if not targets[c.node] then
					targets[c.node] = true
					local set = self:Rebuild(seed, targets)
					targets[c.node] = nil
					local score = self:Evaluate(set)
					if score and score > (bestMove and bestMove.score or bestScore) + 0.0005 then
						bestMove = { score = score, drop = drop, add = c.node, set = set }
					end
				end
			end
			if drop then targets[drop] = true end
			gen:Tick()
		end
		if not bestMove or bestMove.score <= bestScore + 0.0005 then break end
		if bestMove.drop then targets[bestMove.drop] = nil end
		if bestMove.add then targets[bestMove.add] = true end
		bestSet, bestScore = bestMove.set, bestMove.score
		swaps = swaps + 1
	end
	self.rerouted = rerouted

	-- apply, spend the points left with the normal allocator, keep if better
	self:Apply(bestSet)
	gen:Recalculate()
	gen:AllocateTree(true)
	local after = gen:FullScore()
	if after <= before + 0.001 then
		spec:RestoreUndoState(undo)
		for k in pairs(spec.masterySelections) do spec.masterySelections[k] = nil end
		for k, v in pairs(masteryBefore) do spec.masterySelections[k] = v end
		spec:BuildAllDependsAndPaths()
		gen:Recalculate()
		return 0, swaps
	end
	spec:AddUndoState()
	return after - before, swaps
end
