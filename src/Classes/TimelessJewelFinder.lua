-- Path of Building
--
-- Class: Timeless Jewel Finder
-- Finds the best timeless (Historic) jewel for a build: jewel type, socket,
-- seed and conqueror (which decides the keystone).
--   1. The value of every possible transformed passive is measured once with
--      the build's own calculator (a virtual node added, the original removed).
--   2. Every seed of every jewel type is scored by adding up the values of what
--      it does to the allocated passives in the socket's radius (PoB's lookup
--      tables, the same data as the "Find Timeless Jewel" window).
--   3. The best seeds are socketed for real and the build recalculated; the
--      conqueror (keystone) and Militant Faith's devotion mods are chosen there.
-- Only one Historic jewel can be used, so the result is a single jewel.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_max = math.max

---@class TimelessJewelFinder
local TimelessJewelFinderClass = newClass("TimelessJewelFinder")

-- Jewel types (PoB ids), the item text and the conquerors with their keystones
TimelessJewelFinderClass.jewelTypes = {
	{ id = 2, name = "Lethal Pride", conquered = "Karui", line = "Commanded leadership over %d warriors under %s",
		conquerors = { { "Kaom", "Strength of Blood" }, { "Rakiata", "Tempered by War" }, { "Akoya", "Chainbreaker" } } },
	{ id = 4, name = "Militant Faith", conquered = "Templars", line = "Carved to glorify %d new faithful converted by High Templar %s",
		conquerors = { { "Avarius", "Power of Purpose" }, { "Dominus", "Inner Conviction" }, { "Maxarius", "Transcendence" } } },
	{ id = 5, name = "Elegant Hubris", conquered = "Eternal Empire", line = "Commissioned %d coins to commemorate %s", seedStep = 20,
		conquerors = { { "Cadiro", "Supreme Decadence" }, { "Victario", "Supreme Grandstanding" }, { "Caspiro", "Supreme Ostentation" } } },
	{ id = 3, name = "Brutal Restraint", conquered = "Maraketh", line = "Denoted service of %d dekhara in the akhara of %s",
		conquerors = { { "Asenath", "Dance with Death" }, { "Nasima", "Second Sight" }, { "Balbala", "The Traitor" } } },
	{ id = 1, name = "Glorious Vanity", conquered = "Vaal", line = "Bathed in the blood of %d sacrificed in the name of %s",
		conquerors = { { "Doryani", "Corrupted Soul" }, { "Xibaqua", "Divine Flesh" }, { "Ahuana", "Immortal Ambition" } } },
	{ id = 6, name = "Heroic Tragedy", conquered = "Kalguur", line = "Remembrancing %d songworthy deeds by the line of %s",
		conquerors = { { "Vorana", "Black Scythe Training" }, { "Uhtred", "Celestial Mathematics" }, { "Medved", "The Unbreaking Circle" } } },
}

-- Militant Faith's devotion mods (two per jewel)
TimelessJewelFinderClass.devotionLines = {
	"4% increased Area Damage per 10 Devotion",
	"Channelling Skills deal 4% increased Damage per 10 Devotion",
	"4% increased Elemental Damage per 10 Devotion",
	"+2% to all Elemental Resistances per 10 Devotion",
	"3% increased Mana Cost Efficiency per 10 Devotion",
	"Regenerate 0.6 Mana per Second per 10 Devotion",
	"Minions have +60 to Accuracy Rating per 10 Devotion",
	"1% increased Minion Attack and Cast Speed per 10 Devotion",
	"1% increased effect of Non-Curse Auras per 10 Devotion",
	"3% increased Effect of non-Damaging Ailments on Enemies per 10 Devotion",
	"4% reduced Duration of Curses on you per 10 Devotion",
	"4% reduced Elemental Ailment Duration on you per 10 Devotion",
	"3% increased Defences from Equipped Shield per 10 Devotion",
	"4% increased Brand Damage per 10 Devotion",
	"4% increased Totem Damage per 10 Devotion",
}

-- ctx: { build, score = function(override) -> number, fullScore = function() -> number,
--        equip = function(item, slotName) -> item, tick = function(), investment }
function TimelessJewelFinderClass:TimelessJewelFinder(ctx)
	self.ctx = ctx
	self.build = ctx.build
	self.spec = ctx.build.spec
	self.tree = ctx.build.spec.tree
	self.addValue = { }
	self.removeValue = { }
	return self
end

local largeRadius
local function radiusIndex()
	if not largeRadius then
		for i, r in ipairs(data.jewelRadius) do
			if r.label == "Large" then largeRadius = i break end
		end
	end
	return largeRadius or 3
end

function TimelessJewelFinderClass:Tick()
	if self.ctx.tick then self.ctx.tick() end
end

-- Jewel sockets worth looking at: many allocated notables in radius, few points away
function TimelessJewelFinderClass:CandidateSockets(maxSockets, maxPath)
	local list = { }
	local itemsTab = self.build.itemsTab
	for id, node in pairs(self.spec.nodes) do
		if node.type == "Socket" and not node.expansionJewel and itemsTab.slots["Jewel " .. id]
			and node.nodesInRadius and node.nodesInRadius[radiusIndex()] then
			local cost = node.alloc and 0 or (node.path and #node.path or 99)
			if cost <= (maxPath or 3) then
				local notables, keystones = 0, 0
				local nearKeystones = { }
				for nodeId in pairs(node.nodesInRadius[radiusIndex()]) do
					local n = self.spec.nodes[nodeId]
					if n and not n.ascendancyName then
						if n.alloc and n.type == "Notable" then notables = notables + 1 end
						if n.alloc and n.type == "Keystone" then keystones = keystones + 1 end
						-- an unallocated keystone close enough to path to for the conqueror's keystone
						if not n.alloc and n.type == "Keystone" and n.path and #n.path <= (maxPath or 3) + 3 then
							t_insert(nearKeystones, n)
						end
					end
				end
				t_sort(nearKeystones, function(a, b) return #a.path < #b.path end)
				if notables >= 2 or keystones > 0 or nearKeystones[1] then
					t_insert(list, { node = node, cost = cost, notables = notables, keystones = keystones, nearKeystone = nearKeystones[1],
						value = notables + (keystones > 0 and 3 or 0) + (nearKeystones[1] and 1 or 0) - cost })
				end
			end
		end
	end
	t_sort(list, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.node.id < b.node.id
	end)
	for i = #list, (maxSockets or 3) + 1, -1 do list[i] = nil end
	return list
end

-- A virtual passive with the given stat lines (to measure them with addNodes)
function TimelessJewelFinderClass:VirtualNode(sd)
	self.virtualId = (self.virtualId or -900000) - 1
	local node = { id = self.virtualId, type = "Normal", name = "timeless probe", dn = "timeless probe", sd = { } }
	for i, line in ipairs(sd) do node.sd[i] = line end
	self.tree:ProcessStats(node)
	return node
end

-- Stat lines of a legion node with ranges set to their maximum
local function maxRolls(sd)
	local out = { }
	for i, line in ipairs(sd) do
		out[i] = line:gsub("%((%d+%.?%d*)%-(%d+%.?%d*)%)", "%2")
	end
	return out
end

-- Largest roll of a legion node's first ranged stat (to scale Glorious Vanity rolls)
local function maxRoll(legionNode)
	for _, line in ipairs(legionNode.sd or { }) do
		local hi = line:match("%(%d+%.?%d*%-(%d+%.?%d*)%)")
		if hi then return tonumber(hi) end
	end
	return nil
end

-- Score change from adding a legion node's (or addition's) stats
function TimelessJewelFinderClass:AddValue(key, legionNode)
	local v = self.addValue[key]
	if v == nil then
		local node = self:VirtualNode(maxRolls(legionNode.sd or { }))
		v = self.ctx.score({ addNodes = { [node] = true } }) - self.base
		self.addValue[key] = v
		self:Tick()
	end
	return v
end

-- Score change from losing an allocated passive's own stats
function TimelessJewelFinderClass:RemoveValue(node)
	local v = self.removeValue[node.id]
	if v == nil then
		v = self.ctx.score({ removeNodes = { [node] = true } }) - self.base
		self.removeValue[node.id] = v
		self:Tick()
	end
	return v
end

-- Estimated value of what a seed does to one allocated passive
function TimelessJewelFinderClass:NodeValue(jewelTypeId, seed, node)
	local legion = self.tree.legion
	local tbl = data.readLUT(seed, node.id, jewelTypeId)
	if not tbl or not tbl[1] then return 0 end
	local additions = data.timelessJewelAdditions
	if jewelTypeId == 1 then
		local size = #tbl
		if size == 2 or size == 3 then
			local legionNode = legion.nodes[tbl[1] + 1 - additions]
			if not legionNode then return 0 end
			local hi = maxRoll(legionNode)
			local scale = 1
			if hi and hi > 0 then
				local statKey = legionNode.sortedStats and legionNode.sortedStats[1]
				local statMod = statKey and legionNode.stats[statKey]
				local roll = statMod and tbl[statMod.index + 1]
				if roll then scale = roll / hi end
			end
			return self:AddValue("n" .. legionNode.id, legionNode) * scale + self:RemoveValue(node)
		elseif size == 6 or size == 8 then
			local total = self:RemoveValue(node)
			for i = 1, size / 2 do
				local addition = legion.additions[tbl[i] + 1]
				if addition then
					local hi = maxRoll(addition)
					local roll = tbl[i + size / 2]
					local scale = (hi and hi > 0 and roll) and roll / hi or 1
					total = total + self:AddValue("a" .. addition.id, addition) * scale
				end
			end
			return total
		end
		return 0
	end
	local total = 0
	for _, value in ipairs(tbl) do
		if value >= additions then
			local legionNode = legion.nodes[value + 1 - additions]
			if legionNode then
				total = total + self:AddValue("n" .. legionNode.id, legionNode) + self:RemoveValue(node)
			end
		else
			local addition = legion.additions[value + 1]
			if addition then
				total = total + self:AddValue("a" .. addition.id, addition)
			end
		end
	end
	return total
end

-- Best seeds of a jewel type for a socket, by estimated value
function TimelessJewelFinderClass:RankSeeds(jewelType, socket, keep)
	local targets = { }
	for nodeId in pairs(socket.node.nodesInRadius[radiusIndex()]) do
		local node = self.spec.nodes[nodeId]
		if node and node.alloc and not node.ascendancyName and node.type ~= "Socket" and node.type ~= "Mastery"
			and (node.type == "Notable" or (jewelType.id == 1 and node.type == "Normal")) and data.nodeIDList[nodeId] then
			t_insert(targets, node)
		end
	end
	t_sort(targets, function(a, b) return a.id < b.id end)
	if #targets == 0 then return { } end
	local step = jewelType.seedStep or 1
	local results = { }
	local count = 0
	for seed = data.timelessJewelSeedMin[jewelType.id] * step, data.timelessJewelSeedMax[jewelType.id] * step, step do
		local value = 0
		for _, node in ipairs(targets) do
			value = value + self:NodeValue(jewelType.id, seed, node)
		end
		t_insert(results, { seed = seed, value = value })
		count = count + 1
		if count % 500 == 0 then self:Tick() end
	end
	t_sort(results, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.seed < b.seed
	end)
	for i = #results, (keep or 3) + 1, -1 do results[i] = nil end
	return results
end

function TimelessJewelFinderClass.MakeItem(jewelType, seed, conqueror, extraLines)
	local lines = {
		"Rarity: UNIQUE", jewelType.name, "Timeless Jewel", "League: Legion", "Limited to: 1 Historic", "Radius: Large", "Implicits: 0",
		string.format(jewelType.line, seed, conqueror[1]),
	}
	for _, line in ipairs(extraLines or { }) do t_insert(lines, line) end
	t_insert(lines, "Passives in radius are Conquered by the " .. jewelType.conquered)
	t_insert(lines, "Historic")
	local item = new("Item"):Item(table.concat(lines, "\n"))
	item:BuildModList()
	return item
end

-- Allocated passives that only give attributes (+30 to Strength...)
function TimelessJewelFinderClass:AttributeOnlyPassives()
	local count = 0
	for _, node in pairs(self.spec.allocNodes) do
		if node.type == "Normal" and not node.ascendancyName and node.sd and #node.sd > 0 then
			local only = true
			for _, line in ipairs(node.sd) do
				if not (line:match("^%+%d+ to Strength$") or line:match("^%+%d+ to Dexterity$") or line:match("^%+%d+ to Intelligence$")
					or line:match("^%+%d+ to all Attributes$") or line:match("^%+%d+ to Strength and %a+$") or line:match("^%+%d+ to Dexterity and Intelligence$")) then
					only = false
					break
				end
			end
			if only then count = count + 1 end
		end
	end
	return count
end

-- Socket a jewel for real and score the build; everything is restored afterwards.
-- Points spent on the socket path (and on a keystone, if given) are charged at pointValue.
function TimelessJewelFinderClass:TryReal(socket, item, keystone)
	local spec = self.spec
	local itemsTab = self.build.itemsTab
	local slot = itemsTab.slots["Jewel " .. socket.node.id]
	local undo = spec:CreateUndoState()
	local previous = slot.selItemId
	local usedBefore = spec:CountAllocNodes()
	if not socket.node.alloc then spec:AllocNode(socket.node) end
	if keystone and not keystone.alloc and keystone.path then spec:AllocNode(keystone) end
	local equipped = self.ctx.equip(item, "Jewel " .. socket.node.id)
	spec:BuildAllDependsAndPaths()
	local points = spec:CountAllocNodes() - usedBefore
	local score = self.ctx.fullScore() - points * (self.pointValue or 0.006)
	-- Supreme Ostentation ("Ignore Attribute Requirements"): the passives taken
	-- only for attributes become free points - what casters use it for. PoB's
	-- score can't see it until the tree is rebuilt, so they count as refunded
	local env = self.build.calcsTab.mainEnv
	if env and env.player.modDB:Flag(nil, "IgnoreAttributeRequirements") then
		score = score + self:AttributeOnlyPassives() * (self.pointValue or 0.006)
	end
	slot:SetSelItemId(previous)
	itemsTab:DeleteItem(equipped, true)
	spec:RestoreUndoState(undo)
	spec:BuildAllDependsAndPaths()
	self:Tick()
	return score
end

-- What the jewel does to the allocated passives in its radius (socketed for a moment)
function TimelessJewelFinderClass:Describe(result)
	local spec = self.spec
	local itemsTab = self.build.itemsTab
	local slot = itemsTab.slots["Jewel " .. result.socket.node.id]
	local undo = spec:CreateUndoState()
	local previous = slot.selItemId
	-- stat lines of a passive, split and trimmed
	local function statLines(n)
		local out = { }
		for _, sd in ipairs(n.sd or { }) do
			for line in (sd .. "\n"):gmatch("([^\n]*)\n") do
				line = line:gsub("^%s+", ""):gsub("%s+$", "")
				if line ~= "" then t_insert(out, line) end
			end
		end
		return out
	end
	local before = { }
	for nodeId in pairs(result.socket.node.nodesInRadius[radiusIndex()]) do
		local n = spec.nodes[nodeId]
		if n then before[nodeId] = { dn = n.dn, lines = statLines(n) } end
	end
	if not result.socket.node.alloc then spec:AllocNode(result.socket.node) end
	if result.keystone and not result.keystone.alloc and result.keystone.path then spec:AllocNode(result.keystone) end
	local equipped = self.ctx.equip(result.item, "Jewel " .. result.socket.node.id)
	spec:BuildAllDependsAndPaths()
	local lines = { }
	local smallCount = 0
	for nodeId in pairs(result.socket.node.nodesInRadius[radiusIndex()]) do
		local n = spec.nodes[nodeId]
		local old = before[nodeId]
		if n and old and n.alloc and n.conqueredBy and not n.ascendancyName then
			if n.type == "Notable" or n.type == "Keystone" then
				local after = statLines(n)
				if n.dn ~= old.dn then
					t_insert(lines, string.format("%s becomes %s: %s", old.dn, n.dn, table.concat(after, ", ")))
				else
					local had = { }
					for _, l in ipairs(old.lines) do had[l] = true end
					local added = { }
					for _, l in ipairs(after) do if not had[l] then t_insert(added, l) end end
					if added[1] then t_insert(lines, string.format("%s gains: %s", n.dn, table.concat(added, ", "))) end
				end
			else
				smallCount = smallCount + 1
			end
		end
	end
	t_sort(lines)
	if smallCount > 0 then
		t_insert(lines, string.format("%d small passive%s in radius also changed", smallCount, smallCount == 1 and "" or "s"))
	end
	slot:SetSelItemId(previous)
	itemsTab:DeleteItem(equipped, true)
	spec:RestoreUndoState(undo)
	spec:BuildAllDependsAndPaths()
	return lines
end

-- Applies a result to the build (allocates the socket, and the keystone if any)
function TimelessJewelFinderClass:Apply(result)
	local spec = self.spec
	if not result.socket.node.alloc then spec:AllocNode(result.socket.node) end
	if result.keystone and not result.keystone.alloc and result.keystone.path then spec:AllocNode(result.keystone) end
	local item = self.ctx.equip(result.item, "Jewel " .. result.socket.node.id)
	self.build.itemsTab:PopulateSlots()
	spec:BuildAllDependsAndPaths()
	spec:AddUndoState()
	return item
end

-- Is a Historic jewel already used?
function TimelessJewelFinderClass:HasHistoric()
	local itemsTab = self.build.itemsTab
	for nodeId, itemId in pairs(self.spec.jewels) do
		local item = itemsTab.items[itemId]
		if item and item.jewelData and item.jewelData.conqueredBy and self.spec.allocNodes[nodeId] then
			return true
		end
	end
	return false
end

-- Returns the best jewel found, or nil: { item, socket, jewelType, seed, conqueror, gain, label, lines }
function TimelessJewelFinderClass:Run(opts)
	opts = opts or { }
	if self:HasHistoric() then return nil end
	self.pointValue = opts.pointValue or 0.006
	self.base = self.ctx.score({ })
	local baseReal = self.ctx.fullScore()
	local sockets = self:CandidateSockets(opts.maxSockets or 3, opts.maxPath or 3)
	if not sockets[1] then return nil end
	-- 1-2: estimated best seeds per socket and jewel type
	local finalists = { }
	for _, socket in ipairs(sockets) do
		for _, jewelType in ipairs(self.jewelTypes) do
			for _, r in ipairs(self:RankSeeds(jewelType, socket, opts.seedsPerType or 2)) do
				t_insert(finalists, { socket = socket, jewelType = jewelType, seed = r.seed, estimate = r.value })
			end
		end
	end
	t_sort(finalists, function(a, b) return a.estimate > b.estimate end)
	-- 3: real check of the best finalists, with each conqueror where a keystone is in radius
	local best
	local checked = 0
	for _, f in ipairs(finalists) do
		if checked >= (opts.maxChecks or 10) then break end
		checked = checked + 1
		-- keystone options: the allocated keystone in radius, or a nearby one to path to
		local keystoneOptions = { { keystone = nil } }
		if f.socket.nearKeystone and f.socket.keystones == 0 then t_insert(keystoneOptions, { keystone = f.socket.nearKeystone }) end
		for _, ko in ipairs(keystoneOptions) do
			local conquerors = (f.socket.keystones > 0 or ko.keystone) and f.jewelType.conquerors or { f.jewelType.conquerors[1] }
			for _, conqueror in ipairs(conquerors) do
				local extra = { }
				if f.jewelType.id == 4 then
					-- Militant Faith: the two devotion mods that help most
					local scored = { }
					for _, line in ipairs(self.devotionLines) do
						local s = self:TryReal(f.socket, self.MakeItem(f.jewelType, f.seed, conqueror, { line }), ko.keystone)
						t_insert(scored, { line = line, score = s })
					end
					t_sort(scored, function(a, b) return a.score > b.score end)
					extra = { scored[1].line, scored[2].line }
				end
				local item = self.MakeItem(f.jewelType, f.seed, conqueror, extra)
				local score = self:TryReal(f.socket, item, ko.keystone)
				if not best or score > best.score then
					best = { item = item, socket = f.socket, jewelType = f.jewelType, seed = f.seed, conqueror = conqueror, score = score, extra = extra, keystone = ko.keystone }
				end
			end
		end
	end
	if not best then return nil end
	best.gain = best.score - baseReal
	best.label = string.format("%s (%s, seed %d%s)", best.jewelType.name, best.conqueror[1], best.seed,
		best.socket.cost > 0 and string.format(", socket %d point%s away", best.socket.cost, best.socket.cost == 1 and "" or "s") or "")
	if best.keystone or best.socket.keystones > 0 then
		best.label = best.label .. ", keystone becomes " .. best.conqueror[2]
	end
	if best.extra[1] then best.label = best.label .. ": " .. table.concat(best.extra, ", ") end
	return best
end
