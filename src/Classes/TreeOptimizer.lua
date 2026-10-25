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

-- Nodes of a node table in id order (pairs() order changes from run to run:
-- LuaJIT seeds its hashing per process, and greedy choices follow the order)
local function nodesById(tbl)
	local list = { }
	for _, node in pairs(tbl) do list[#list + 1] = node end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

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
	for _, node in ipairs(nodesById(self.spec.allocNodes)) do
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
	for _, node in ipairs(nodesById(self.spec.allocNodes)) do
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
	for _, node in ipairs(nodesById(spec.nodes)) do
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
	for _, node in ipairs(nodesById(spec.allocNodes)) do
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
	for _, node in ipairs(nodesById(spec.nodes)) do
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

------------------------------------------------------------------------------
-- Whole-tree solver: a prize-collecting Steiner tree. Every main tree passive
-- gets a value (allocated ones: what the build loses without it; the others:
-- what it gains with it alone; small passives with the same stats measured
-- once), each point costs lambda, and the tree of the most value for its
-- points is found at once (Goemans-Williamson growth, then strong pruning),
-- lambda searched so it fits the points. Unlike the allocator, which pays
-- each path from the tree as it is, a group of strong notables far away is
-- valued together, so a long road to a rich area can win.
------------------------------------------------------------------------------

-- Values of the passives in reach of the class start (node -> value), in
-- the context of a node set (nil: the current tree): what the build loses
-- without a passive of the set, or gains with one more
function TreeOptimizerClass:NodeValues(reach, set)
	local gen = self.gen
	local spec = self.spec
	local base = set and self:Override(set) or { addNodes = { }, removeNodes = { } }
	local function with(node, add)
		local o = { addNodes = { }, removeNodes = { } }
		for k in pairs(base.addNodes) do o.addNodes[k] = true end
		for k in pairs(base.removeNodes) do o.removeNodes[k] = true end
		if add then
			if o.removeNodes[node] then o.removeNodes[node] = nil else o.addNodes[node] = true end
		else
			if o.addNodes[node] then o.addNodes[node] = nil else o.removeNodes[node] = true end
		end
		return o
	end
	local current = gen:Score(base)
	local protected = gen.protectedNodes or { }
	local values, bySig = { }, { }
	local measured = 0
	for _, node in ipairs(nodesById(spec.nodes)) do
		if reach[node] and node ~= self.startNode and not self.fixed[node] then
			local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
			local inSet
			if set then inSet = set[node] and true or false else inSet = node.alloc end
			if protected[node.id] or holdsJewel then
				values[node] = 1000
			elseif inSet then
				values[node] = current - gen:Score(with(node, false))
			elseif gen.forbiddenNodes and gen.forbiddenNodes[node.id] then
				values[node] = -1000
			elseif node.type == "Socket" then
				values[node] = 0
			else
				-- (small passives: one measurement per set of stats)
				local sig = node.type == "Normal" and table.concat(node.sd or { }, "|") or nil
				if sig and bySig[sig] then
					values[node] = bySig[sig]
				else
					values[node] = gen:Score(with(node, true)) - current
					if sig then bySig[sig] = values[node] end
				end
			end
			measured = measured + 1
			if measured % 50 == 0 then gen:Tick() end
		end
	end
	return values
end

-- Rooted prize-collecting Steiner tree for one lambda (cost of a point).
-- nodes: list of graph nodes (start first), prize[node] >= 0, weight[node]
-- (point cost, start 0). Returns the node set (start included).
local function solvePCST(nodes, adj, prize, weight, start)
	local n = #nodes
	local index = { }
	for i, node in ipairs(nodes) do index[node] = i end
	-- edges (i < j), cost = mean of the endpoints' weights (exact for equal weights)
	local eu, ev, ec = { }, { }, { }
	for i, node in ipairs(nodes) do
		for _, other in ipairs(adj[node]) do
			local j = index[other]
			if j and j > i then
				eu[#eu + 1], ev[#ev + 1], ec[#ec + 1] = i, j, (weight[node] + weight[other]) / 2
			end
		end
	end
	local comp, members, active, paid, total, d = { }, { }, { }, { }, { }, { }
	for i, node in ipairs(nodes) do
		comp[i], members[i], d[i] = i, { i }, 0
		paid[i], total[i] = 0, prize[node]
		active[i] = node ~= start and prize[node] > 0
	end
	local rootComp = index[start]
	local forest = { }
	local live = { }
	for e = 1, #eu do live[e] = true end
	local eps = 1e-12
	while true do
		local bestT, bestE, bestC = math.huge, nil, nil
		for c = 1, n do
			if active[c] and members[c] then
				local t = total[c] - paid[c]
				if t < bestT then bestT, bestE, bestC = t, nil, c end
			end
		end
		for e = 1, #eu do
			if live[e] then
				local a, b = comp[eu[e]], comp[ev[e]]
				if a == b then
					live[e] = false
				else
					local rate = (active[a] and 1 or 0) + (active[b] and 1 or 0)
					if rate > 0 then
						local t = (ec[e] - d[eu[e]] - d[ev[e]]) / rate
						if t < bestT then bestT, bestE, bestC = t, e, nil end
					end
				end
			end
		end
		if bestT == math.huge then break end
		if bestT < 0 then bestT = 0 end
		for c = 1, n do
			if active[c] and members[c] then
				paid[c] = paid[c] + bestT
				for _, i in ipairs(members[c]) do d[i] = d[i] + bestT end
			end
		end
		if bestC then
			active[bestC] = false
		else
			local a, b = comp[eu[bestE]], comp[ev[bestE]]
			forest[#forest + 1] = bestE
			live[bestE] = false
			-- merge the smaller into the larger
			if #members[a] < #members[b] then a, b = b, a end
			for _, i in ipairs(members[b]) do comp[i] = a; t_insert(members[a], i) end
			members[b] = nil
			paid[a] = paid[a] + paid[b]
			total[a] = total[a] + total[b]
			if a == rootComp or b == rootComp then
				rootComp = a
				active[a] = false
			else
				active[a] = total[a] - paid[a] > eps
			end
			active[b] = false
		end
	end
	-- the root's tree, strongly pruned: a branch stays if what it brings beats its points
	local treeAdj = { }
	for _, e in ipairs(forest) do
		local u, v = eu[e], ev[e]
		treeAdj[u] = treeAdj[u] or { }
		treeAdj[v] = treeAdj[v] or { }
		t_insert(treeAdj[u], v)
		t_insert(treeAdj[v], u)
	end
	local root = index[start]
	local order, parent = { root }, { [root] = 0 }
	local head = 1
	while head <= #order do
		local u = order[head]
		head = head + 1
		for _, v in ipairs(treeAdj[u] or { }) do
			if parent[v] == nil then parent[v] = u; t_insert(order, v) end
		end
	end
	local net = { }
	for k = #order, 1, -1 do
		local u = order[k]
		net[u] = (net[u] or 0) + prize[nodes[u]] - weight[nodes[u]]
		local p = parent[u]
		if p and p > 0 and net[u] > 0 then net[p] = (net[p] or 0) + net[u] end
	end
	local set = { }
	for _, u in ipairs(order) do
		local p = parent[u]
		if u == root or (set[nodes[p]] and net[u] > 0) then set[nodes[u]] = true end
	end
	return set
end

-- The whole-tree solver: values measured one passive at a time miss what
-- passives do together (many mana passives dropped at once break mana
-- sustain, while each alone has slack), so it iterates: values measured in
-- the context of a tree, trees solved for several "stay" bonuses (passives
-- of that tree get a bonus: from close to it to free), each measured for
-- real; the best becomes the context of the next round. Returns the best
-- tree found and its score (Evaluate), or nil.
function TreeOptimizerClass:GlobalSolve(reach, currentScore)
	local gen = self.gen
	local debug = gen.options.debugTiming
	local nodes, adj, prize, weight = { self.startNode }, { }, { }, { }
	for node in pairs(reach) do
		if node ~= self.startNode and not self.fixed[node] then t_insert(nodes, node) end
	end
	t_sort(nodes, function(a, b)
		if a == self.startNode then return true elseif b == self.startNode then return false end
		return a.id < b.id
	end)
	local inGraph = { }
	for _, node in ipairs(nodes) do inGraph[node] = true end
	for _, node in ipairs(nodes) do
		local list = { }
		for _, other in ipairs(node.linked) do
			if inGraph[other] and self:Passable(other) then t_insert(list, other) end
		end
		adj[node] = list
	end
	-- points the main tree has: the budget less the kept parts and masteries
	local masteries = 0
	for _, node in pairs(self.spec.allocNodes) do
		if node.type == "Mastery" and not node.ascendancyName then masteries = masteries + 1 end
	end
	local points = self.budget - self.fixedCost - masteries
	local function solve(values, context, lambda, stay)
		for _, node in ipairs(nodes) do
			local inContext
			if context then inContext = context[node] else inContext = node.alloc end
			local v = (values[node] or 0) + (inContext and stay or 0)
			prize[node] = m_max(0, v)
			weight[node] = node == self.startNode and 0 or (lambda + m_max(0, -v))
		end
		local set = solvePCST(nodes, adj, prize, weight, self.startNode)
		local count = 0
		for node in pairs(set) do if node ~= self.startNode then count = count + 1 end end
		return set, count
	end
	-- (lambda: bisection on a log scale for the largest tree within the points)
	-- (the tree size isn't monotonic in lambda: the largest tree within the
	-- points seen during the search is kept)
	local function fit(values, context, stay)
		local lo, hi = 1e-6, 1
		local best, bestCount
		for _ = 1, 18 do
			local mid = math.sqrt(lo * hi)
			local set, count = solve(values, context, mid, stay)
			if count > points then
				lo = mid
			else
				hi = mid
				if not bestCount or count > bestCount then best, bestCount = set, count end
			end
			gen:Tick()
		end
		return best
	end
	local function same(a, b)
		for node in pairs(a) do if not b[node] then return false end end
		for node in pairs(b) do if not a[node] then return false end end
		return true
	end
	local bestSet, bestScore
	local context
	local tried = { }
	for round = 1, gen.options.treeSolverRounds or 3 do
		local t0 = os.clock()
		local values = self:NodeValues(reach, context)
		local roundBest, roundScore, nextContext, nextScore
		for _, stay in ipairs(gen.options.treeSolverStay or { 0, 0.002, 0.004, 0.008, 0.016, 0.03 }) do
			local set = fit(values, context, stay)
			local new = set and true
			for _, old in ipairs(tried) do if set and same(set, old) then new = false break end end
			if new then
				t_insert(tried, set)
				local score = self:Evaluate(set)
				if debug then
					local changed = 0
					for node in pairs(set) do if not node.alloc then changed = changed + 1 end end
					ConPrintf("[tree solver] round %d, stay %.3f: %d of %d points, %d passives new: %s (current %.4f)", round, stay, self:Cost(set), self.budget, changed, score and string.format("%.4f", score) or "over budget", currentScore)
				end
				if score and (not roundScore or score > roundScore) then roundBest, roundScore = set, score end
				-- (the next round's context: the best tree that changed something,
				-- even if worse: measured there, what it lacks shows its worth)
				local changed = false
				for node in pairs(set) do if node ~= self.startNode and not node.alloc then changed = true break end end
				if score and changed and (not nextScore or score > nextScore) then nextContext, nextScore = set, score end
			end
			gen:Tick()
		end
		if debug then ConPrintf("[tree solver] round %d: %.1f s", round, os.clock() - t0) end
		if not roundBest then break end
		if not bestScore or roundScore > bestScore then bestSet, bestScore = roundBest, roundScore end
		if not nextContext then break end
		context = nextContext
	end
	return bestSet, bestScore
end

-- Targets of a node set: notables, keystones, sockets with jewels, protected
-- nodes and its leaves
function TreeOptimizerClass:TargetsOf(set)
	local protected = self.gen.protectedNodes or { }
	local targets = { }
	for node in pairs(set) do
		if node ~= self.startNode then
			local degree = 0
			for _, other in ipairs(node.linked) do if set[other] then degree = degree + 1 end end
			local holdsJewel = node.type == "Socket" and (self.spec.jewels[node.id] or 0) ~= 0
			if node.type == "Notable" or node.type == "Keystone" or holdsJewel or protected[node.id] or degree <= 1 then
				targets[node] = true
			end
		end
	end
	return targets
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
	for _, node in ipairs(nodesById(spec.allocNodes)) do
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
	for _, node in ipairs(nodesById(spec.allocNodes)) do
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
	for _, node in ipairs(nodesById(spec.allocNodes)) do
		if not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "Mastery" and not self.fixed[node] then
			bestSet[node] = true
		end
	end
	-- (a tree already over the budget, e.g. points from a bandit the
	-- calculation doesn't see yet: its own size is the budget)
	self.budget = m_max(self.budget, self:Cost(bestSet))
	local bestScore = self:Evaluate(bestSet)
	if not bestScore then
		if gen.options.debugTiming then ConPrintf("[tree] current tree over budget: %d of %d points", self:Cost(bestSet), self.budget) end
		return 0
	end
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
	-- 1b. the whole-tree solver's tree, kept when it measures better
	self.globalWon = false
	if opts.global ~= false and gen.options.globalTree ~= false then
		local ok, set, score = pcall(function() return self:GlobalSolve(reach, bestScore) end)
		if not ok then
			ConPrintf("Whole-tree solver failed: %s", tostring(set))
		elseif set and score > bestScore + 0.0005 then
			bestSet, bestScore = set, score
			targets = self:TargetsOf(set)
			self.globalWon = true
		end
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
