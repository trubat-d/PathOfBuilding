-- Path of Building
--
-- Class: Cluster Jewel Generator
-- Makes Large Cluster Jewels for a build's outer jewel sockets:
--   1. every enchant (small passive type) the jewel can have is valued: its
--      small passive stats and each notable it can roll, measured once with
--      the build's calculator as virtual passives;
--   2. for the best enchants, the best notables are picked (2 prefixes and
--      2 suffixes at most, 3 notables on an 8-passive jewel);
--   3. those jewels are socketed for real, their notables allocated, and the
--      build recalculated; passive points spent are charged per point.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_max = math.max

---@class ClusterJewelGenerator

-- Nodes of a node table in id order (pairs() order changes from run to run:
-- LuaJIT seeds its hashing per process, and greedy choices follow the order)
local function nodesById(tbl)
	local list = { }
	for _, node in pairs(tbl) do list[#list + 1] = node end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

local ClusterJewelGeneratorClass = newClass("ClusterJewelGenerator")

-- ctx: { build, score = function(override) -> number, fullScore = function() -> number,
--        equip = function(item, slotName) -> item, tick = function(), pointValue }
function ClusterJewelGeneratorClass:ClusterJewelGenerator(ctx)
	self.ctx = ctx
	self.build = ctx.build
	self.spec = ctx.build.spec
	self.tree = ctx.build.spec.tree
	self.pointValue = ctx.pointValue or 0.006
	self.values = { }
	return self
end

function ClusterJewelGeneratorClass:Tick()
	if self.ctx.tick then self.ctx.tick() end
end

-- Score gain of a set of stat lines as a virtual passive (cached by key)
function ClusterJewelGeneratorClass:LinesValue(key, lines)
	if self.values[key] == nil then
		self.virtualId = (self.virtualId or -800000) - 1
		local node = { id = self.virtualId, type = "Normal", name = key, dn = key, sd = { } }
		for i, line in ipairs(lines) do node.sd[i] = line end
		self.tree:ProcessStats(node)
		self.values[key] = self.ctx.score({ addNodes = { [node] = true } }) - self.base
		self:Tick()
	end
	return self.values[key]
end

-- Outer sockets that take a Large Cluster Jewel, empty, within reach
function ClusterJewelGeneratorClass:Sockets(maxPath)
	local list = { }
	local itemsTab = self.build.itemsTab
	for _, node in ipairs(nodesById(self.spec.nodes)) do local id = node.id
		if node.type == "Socket" and node.expansionJewel and node.expansionJewel.size == 2 and not node.expansionJewel.parent
			and itemsTab.slots["Jewel " .. id] and (self.spec.jewels[id] or 0) == 0 then
			local cost = node.alloc and 0 or (node.path and #node.path or 99)
			if cost <= (maxPath or 5) then
				t_insert(list, { node = node, cost = cost })
			end
		end
	end
	t_sort(list, function(a, b)
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.node.id < b.node.id
	end)
	return list
end

-- Notable mods a Large jewel with this enchant can roll
local notablesBySkill
local function notablesFor(skillId)
	if not notablesBySkill then
		notablesBySkill = { }
		for modId, mod in pairs(data.itemMods.JewelCluster or { }) do
			local name = mod[1] and mod[1]:match("^1 Added Passive Skill is (.+)$")
			if name and (mod.level or 1) <= 84 then
				local largeOk = true
				for i, key in ipairs(mod.weightMultiplierKey or { }) do
					if key == "expansion_jewel_large" and (mod.weightMultiplierVal[i] or 0) == 0 then largeOk = false end
				end
				for i, key in ipairs(mod.weightKey or { }) do
					if (mod.weightVal[i] or 0) > 0 and key ~= "default" and largeOk then
						notablesBySkill[key] = notablesBySkill[key] or { }
						t_insert(notablesBySkill[key], { modId = modId, name = name, type = mod.type })
					end
				end
			end
		end
		for _, list in pairs(notablesBySkill) do
			t_sort(list, function(a, b) return a.name < b.name end)
		end
	end
	return notablesBySkill[skillId] or { }
end

function ClusterJewelGeneratorClass.MakeItem(skillId, nodeCount, notableNames)
	local jewel = data.clusterJewels.jewels["Large Cluster Jewel"]
	local skill = jewel.skills[skillId]
	local lines = { "Rarity: RARE", "Generated Cluster", "Large Cluster Jewel", "Item Level: 84" }
	local enchant = { "Adds " .. nodeCount .. " Passive Skills", "2 Added Passive Skills are Jewel Sockets" }
	for _, l in ipairs(skill.enchant) do t_insert(enchant, l) end
	t_insert(lines, "Implicits: " .. #enchant)
	for _, l in ipairs(enchant) do t_insert(lines, "{crafted}" .. l) end
	for _, name in ipairs(notableNames) do t_insert(lines, "1 Added Passive Skill is " .. name) end
	local item = new("Item"):Item(table.concat(lines, "\n"))
	item:BuildModList()
	return item
end

-- Socket a cluster jewel, allocate its notables, score, restore (unless keep)
function ClusterJewelGeneratorClass:TryReal(socket, item, keep)
	local spec = self.spec
	local itemsTab = self.build.itemsTab
	local undo = spec:CreateUndoState()
	local usedBefore = spec:CountAllocNodes()
	if not socket.node.alloc then spec:AllocNode(socket.node) end
	local slot = itemsTab.slots["Jewel " .. socket.node.id]
	local equipped = self.ctx.equip(item, "Jewel " .. socket.node.id)
	spec:BuildClusterJewelGraphs()
	-- allocate every notable of the new subgraph
	for _, subGraph in pairs(spec.subGraphs or { }) do
		if subGraph.parentSocket and subGraph.parentSocket.id == socket.node.id then
			for _, node in ipairs(subGraph.nodes) do
				local n = spec.nodes[node.id]
				if n and n.type == "Notable" and not n.alloc and n.path then spec:AllocNode(n) end
			end
		end
	end
	spec:BuildAllDependsAndPaths()
	local points = spec:CountAllocNodes() - usedBefore
	local score = self.ctx.fullScore() - points * self.pointValue
	if keep then
		itemsTab:PopulateSlots()
		spec:AddUndoState()
		return score, points
	end
	slot:SetSelItemId(0)
	itemsTab:DeleteItem(equipped, true)
	spec:RestoreUndoState(undo)
	spec:BuildClusterJewelGraphs()
	self:Tick()
	return score, points
end

-- Best Large Cluster Jewel for the nearest free outer socket: { item, socket, score, gain, label } or nil
function ClusterJewelGeneratorClass:Best(baseScore, opts)
	opts = opts or { }
	local sockets = self:Sockets(opts.maxPath)
	local socket = sockets[1]
	if not socket then return nil end
	self.base = self.ctx.score({ })
	local jewel = data.clusterJewels.jewels["Large Cluster Jewel"]
	local nodeCount = 8
	local smallCount = 3 -- 8 passives: 3 notables, 2 sockets, 3 small passives
	-- 1-2: estimate every enchant with its best notables
	local plans = { }
	for skillId, skill in pairs(jewel.skills) do
		local smallValue = self:LinesValue("small:" .. skillId, skill.stats or { })
		local options = { }
		for _, n in ipairs(notablesFor(skill.tag or skillId)) do
			local node = self.tree.clusterNodeMap[n.name]
			if node and node.sd then
				t_insert(options, { name = n.name, type = n.type, value = self:LinesValue("notable:" .. n.name, node.sd) })
			end
		end
		t_sort(options, function(a, b) return a.value > b.value end)
		local chosen, prefixes, suffixes, value = { }, 0, 0, smallValue * smallCount
		for _, o in ipairs(options) do
			if #chosen >= 3 then break end
			if o.value > 0 and ((o.type == "Prefix" and prefixes < 2) or (o.type == "Suffix" and suffixes < 2)) then
				t_insert(chosen, o.name)
				value = value + o.value
				if o.type == "Prefix" then prefixes = prefixes + 1 else suffixes = suffixes + 1 end
			end
		end
		if #chosen > 0 then
			t_insert(plans, { skillId = skillId, skill = skill, notables = chosen, value = value })
		end
	end
	t_sort(plans, function(a, b) return a.value > b.value end)
	-- 3: real check of the best few
	local best
	for i = 1, math.min(opts.checks or 3, #plans) do
		local plan = plans[i]
		local item = self.MakeItem(plan.skillId, nodeCount, plan.notables)
		local score = self:TryReal(socket, item)
		if not best or score > best.score then
			best = { item = item, socket = socket, score = score, plan = plan }
		end
	end
	if not best then return nil end
	best.gain = best.score - baseScore
	best.label = string.format("Large Cluster Jewel (%s): %s", best.plan.skill.name, table.concat(best.plan.notables, ", "))
	return best
end

function ClusterJewelGeneratorClass:Apply(result)
	return self:TryReal(result.socket, result.item, true)
end
