-- Path of Building
--
-- Class: Radius Jewel Finder
-- The jewels that let passives in their radius be allocated without a path,
-- the way top players use them: Thread of Hope (a ring around its socket,
-- one jewel per ring size), Intuitive Leap (a small radius) and Impossible
-- Escape (the radius of the keystone it names, from any socket). Their value
-- is in what gets allocated through them, which socketing alone doesn't show
-- (the unique jewel sweep skips them for that reason):
--   1. every passive in reach of any placement is valued once (the score it
--      adds on its own; the calculator doesn't check connections);
--   2. each placement (jewel variant x socket) is estimated: its best
--      passives, each worth more than what a passive point is worth in the
--      build now (the cheapest leaves of the tree), minus the socket's path;
--   3. the best few are applied for real: the jewel socketed, its passives
--      allocated one by one while they gain, the tree trimmed back to the
--      point budget and refilled, and the result kept only if the full score
--      is better.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_min = math.min
local m_max = math.max

---@class RadiusJewelFinder
local RadiusJewelFinderClass = newClass("RadiusJewelFinder")

local function nodesById(tbl)
	local list = { }
	for _, node in pairs(tbl) do list[#list + 1] = node end
	t_sort(list, function(a, b) return a.id < b.id end)
	return list
end

-- gen: the BuildGenerator (Score, FullScore, Equip, TrimTree, AllocateTree, RefineTree, Tick)
function RadiusJewelFinderClass:RadiusJewelFinder(gen)
	self.gen = gen
	self.build = gen.build
	self.spec = gen.build.spec
	self.itemsTab = gen.build.itemsTab
	return self
end

RadiusJewelFinderClass.titles = { "Thread of Hope", "Intuitive Leap", "Impossible Escape" }

local function dbItem(title)
	local found
	for _, unique in pairs(main.uniqueDB.list) do
		if unique.title == title and (not found or (unique.variantList and #unique.variantList > #(found.variantList or { }))) then found = unique end
	end
	return found
end

local function variantItem(db, variant)
	local item = new("Item"):Item(db.raw)
	if variant then item.variant = variant end
	item:BuildAndParseRaw()
	item:NormaliseQuality()
	return item
end

-- The jewel's versions worth trying: { item, label }
function RadiusJewelFinderClass:Versions(title, allowUber)
	local db = dbItem(title)
	if not db then return { } end
	local list = { }
	if db.variantList and #db.variantList > 1 then
		for i, name in ipairs(db.variantList) do
			local uber = name:find("Uber", 1, true)
			-- (no old versions, no test versions that can't drop)
			if not name:find("Pre ", 1, true) and not name:find("Test", 1, true) and (allowUber or not uber) then
				local ok, item = pcall(variantItem, db, i)
				if ok and item and item.jewelRadiusIndex then t_insert(list, { item = item, label = title .. " (" .. name .. ")", variantName = name }) end
			end
		end
	else
		local ok, item = pcall(variantItem, db, nil)
		if ok and item then t_insert(list, { item = item, label = title }) end
	end
	return list
end

-- Sockets that can take a new jewel: allocated, or a few points away, empty
-- or holding a generated rare jewel; cheapest first
function RadiusJewelFinderClass:Sockets(maxPath)
	local list = { }
	for _, node in ipairs(nodesById(self.spec.nodes)) do
		local slot = self.itemsTab.slots["Jewel " .. node.id]
		local current = self.itemsTab.items[self.spec.jewels[node.id] or 0]
		local free = not current or (current.rarity == "RARE" and current.title and current.title:match("^Best Rare") and node.alloc)
		if node.type == "Socket" and slot and not node.expansionJewel and not node.ascendancyName and free then
			local cost = node.alloc and 0 or (node.path and #node.path or 99)
			if cost <= (maxPath or 3) then
				t_insert(list, { node = node, cost = cost + (current and 0.5 or 0) })
			end
		end
	end
	t_sort(list, function(a, b)
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.node.id < b.node.id
	end)
	return list
end

-- Passives a placement makes allocatable: { node }
function RadiusJewelFinderClass:Reach(item, socketNode)
	local radiusIndex = item.jewelRadiusIndex
	if not radiusIndex then return { } end
	local inRadius
	local keystones = item.jewelData and item.jewelData.impossibleEscapeKeystones
	if keystones then
		inRadius = { }
		for name in pairs(keystones) do
			local key = self.spec.tree.keystoneMap[name]
			for id in pairs(key and key.nodesInRadius and key.nodesInRadius[radiusIndex] or { }) do inRadius[id] = true end
		end
	else
		inRadius = socketNode.nodesInRadius and socketNode.nodesInRadius[radiusIndex] or { }
	end
	local list = { }
	for id in pairs(inRadius) do
		local node = self.spec.nodes[id]
		if node and not node.alloc and (node.type == "Normal" or node.type == "Notable" or node.type == "Keystone")
			and not node.ascendancyName and not node.isProxy and not node.expansionJewel
			and not (self.gen.forbiddenNodes and self.gen.forbiddenNodes[node.id]) then
			t_insert(list, node)
		end
	end
	t_sort(list, function(a, b) return a.id < b.id end)
	return list
end

-- What a passive point is worth in the build now: losses of the cheapest
-- leaves, sorted (freeing n points costs about the n first)
function RadiusJewelFinderClass:LeafLosses()
	local spec = self.spec
	local current = self.gen:Score()
	local losses = { }
	for _, node in ipairs(nodesById(spec.allocNodes)) do
		local holdsJewel = node.type == "Socket" and (spec.jewels[node.id] or 0) ~= 0
		if not node.ascendancyName and not holdsJewel and node.type ~= "ClassStart" and node.type ~= "Mastery"
			and node.depends and #node.depends <= 1 and not (self.gen.protectedNodes and self.gen.protectedNodes[node.id]) then
			t_insert(losses, m_max(0, current - self.gen:Score({ removeNodes = { [node] = true } })))
		end
	end
	t_sort(losses)
	return losses
end

-- Runs the search; returns { label, gain, nodes } of what was kept, or nil.
-- allowed(title) -> bool (investment), allowUber: the Massive Ring
function RadiusJewelFinderClass:Run(allowed, allowUber, maxApply)
	local gen = self.gen
	local sockets = self:Sockets(3)
	if #sockets == 0 then return nil end
	-- 1. placements
	local placements = { }
	local allocatedSocket
	for _, s in ipairs(sockets) do if s.node.alloc then allocatedSocket = allocatedSocket or s end end
	for _, title in ipairs(self.titles) do
		local socketed = false
		for nodeId, itemId in pairs(self.spec.jewels) do
			local item = self.itemsTab.items[itemId]
			if item and item.title == title and self.spec.allocNodes[nodeId] then socketed = true end
		end
		if not socketed and allowed(title) then
			for _, version in ipairs(self:Versions(title, allowUber)) do
				local escape = version.item.jewelData and version.item.jewelData.impossibleEscapeKeystones
				-- (Impossible Escape works from any socket: the nearest one)
				local socketList = escape and { allocatedSocket or sockets[1] } or sockets
				for i = 1, m_min(#socketList, 8) do
					local s = socketList[i]
					local reach = self:Reach(version.item, s.node)
					if #reach > 0 then
						t_insert(placements, { version = version, socket = s, reach = reach })
					end
				end
			end
		end
	end
	if #placements == 0 then return nil end
	-- 2. every passive in reach valued once, placements estimated
	local base = gen:Score()
	local gains = { }
	for _, p in ipairs(placements) do
		for _, node in ipairs(p.reach) do
			if gains[node] == nil then
				gains[node] = gen:Score({ addNodes = { [node] = true } }) - base
			end
		end
	end
	local losses = self:LeafLosses()
	local function freeCost(n)
		local total = 0
		for i = 1, n do total = total + (losses[i] or losses[#losses] or 0.02) end
		return total
	end
	for _, p in ipairs(placements) do
		local values = { }
		for _, node in ipairs(p.reach) do t_insert(values, gains[node] or 0) end
		t_sort(values, function(a, b) return a > b end)
		local pathPoints = p.socket.node.alloc and 0 or #(p.socket.node.path or { })
		local best, sum = -pathPoints * 0.02, 0
		p.count = 0
		for i, v in ipairs(values) do
			sum = sum + v
			local est = sum - freeCost(i + pathPoints)
			if est > best then best, p.count = est, i end
			if i >= 16 then break end
		end
		p.estimate = best
	end
	t_sort(placements, function(a, b)
		if a.estimate ~= b.estimate then return a.estimate > b.estimate end
		return a.version.label < b.version.label
	end)
	if gen.options.debugTiming then
		for i = 1, m_min(6, #placements) do
			local p = placements[i]
			ConPrintf("[radius] %s in socket %d: %d passives, estimate %+.3f", p.version.label, p.socket.node.id, p.count, p.estimate)
		end
	end
	-- 3. the best few for real
	local before = gen:FullScore()
	local best
	for i = 1, m_min(maxApply or 3, #placements) do
		local p = placements[i]
		if p.estimate > 0.01 then
			local score, nodes = self:Apply(p, false)
			if gen.options.debugTiming then ConPrintf("[radius] applied %s: %.3f (base %.3f), %d passives", p.version.label, score, before, #nodes) end
			if score > before + 0.005 and (not best or score > best.score + 1e-9) then best = { placement = p, score = score } end
		end
	end
	if not best then return nil end
	local score, nodes = self:Apply(best.placement, true)
	local names = { }
	for _, node in ipairs(nodes) do if node.type ~= "Normal" then t_insert(names, node.dn) end end
	return { label = best.placement.version.label, gain = score - before, nodes = nodes, names = names, title = best.placement.version.item.title }
end

-- Socket the jewel, allocate its passives while they gain, trim the tree to
-- the budget and refill; returns the full score and the passives taken
-- (keep = false: everything put back)
function RadiusJewelFinderClass:Apply(p, keep)
	local gen, spec, itemsTab = self.gen, self.spec, self.itemsTab
	local undo = spec:CreateUndoState()
	local slotName = "Jewel " .. p.socket.node.id
	local slot = itemsTab.slots[slotName]
	local previous = slot.selItemId
	if not p.socket.node.alloc and p.socket.node.path then spec:AllocNode(p.socket.node) end
	local equipped = gen:Equip(p.version.item, slotName)
	itemsTab:PopulateSlots()
	spec:BuildAllDependsAndPaths()
	gen:Recalculate()
	-- passives through the jewel, best first, while each one gains more
	-- than a point is worth (checked against the build as it grows)
	local losses = self:LeafLosses()
	local taken = { }
	for pick = 1, 16 do
		local current = gen:Score()
		local bestNode, bestGain
		for _, node in ipairs(self:Reach(p.version.item, p.socket.node)) do
			if not node.alloc and #(node.intuitiveLeapLikesAffecting or { }) > 0 then
				local g = gen:Score({ addNodes = { [node] = true } }) - current
				if not bestGain or g > bestGain + 1e-9 then bestNode, bestGain = node, g end
			end
		end
		local threshold = losses[pick] or losses[#losses] or 0.02
		if not bestNode or bestGain <= threshold then break end
		spec:AllocNode(bestNode)
		t_insert(taken, bestNode)
		gen:Recalculate()
	end
	local score
	if #taken == 0 then
		score = -math.huge
	else
		local saved = gen.protectedNodes
		gen.protectedNodes = { }
		for k, v in pairs(saved or { }) do gen.protectedNodes[k] = v end
		gen.protectedNodes[p.socket.node.id] = true
		gen:TrimTree()
		gen.protectedNodes = saved
		gen:AllocateTree(true)
		gen:RefineTree(6)
		score = gen:FullScore()
	end
	local kept = { }
	for _, node in ipairs(taken) do if node.alloc then t_insert(kept, node) end end
	if keep then
		itemsTab:PopulateSlots()
		spec:AddUndoState()
		return score, kept
	end
	slot:SetSelItemId(previous)
	itemsTab:DeleteItem(equipped, true)
	spec:RestoreUndoState(undo)
	spec:BuildAllDependsAndPaths()
	itemsTab:PopulateSlots()
	gen:Recalculate()
	return score, kept
end
