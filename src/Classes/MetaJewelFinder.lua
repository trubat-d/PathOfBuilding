-- Path of Building
--
-- Class: Meta Jewel Finder
-- The unique jewels most builds on poe.ninja use, chosen for this build:
--   * Forbidden Flame + Forbidden Flesh: a pair that grants one more ascendancy
--     notable of the character's class (both jewels must name the same notable)
--   * Watcher's Eye: mods that work while one of the build's auras is active
-- Each option is socketed for real (paths allocated if needed, charged per
-- passive point) and the build recalculated; everything is restored afterwards.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort

---@class MetaJewelFinder
local MetaJewelFinderClass = newClass("MetaJewelFinder")

-- ctx: { build, fullScore = function() -> number, equip = function(item, slotName) -> item, tick = function() }
function MetaJewelFinderClass:MetaJewelFinder(ctx)
	self.ctx = ctx
	self.build = ctx.build
	self.spec = ctx.build.spec
	self.pointValue = ctx.pointValue or 0.006
	return self
end

local function dbItem(title)
	for _, unique in pairs(main.uniqueDB.list) do
		if unique.title == title then return unique end
	end
end

local function isGeneratedRare(item)
	return item and item.rarity == "RARE" and item.title and item.title:match("^Best Rare")
end

-- Jewel sockets usable for new jewels: empty or holding a generated rare jewel,
-- allocated or a few points away, cheapest first
-- (anywhere: also sockets on cluster jewels and outer cluster sockets that
-- don't hold a cluster jewel - for jewels that like distance)
function MetaJewelFinderClass:Sockets(maxPath, anywhere)
	local itemsTab = self.build.itemsTab
	local list = { }
	for id, node in pairs(self.spec.nodes) do
		local slot = itemsTab.slots["Jewel " .. id]
		local holder = itemsTab.items[self.spec.jewels[id] or 0]
		local clusterOk = anywhere and not (holder and holder.clusterJewel)
		if node.type == "Socket" and slot and (not node.expansionJewel or clusterOk) and not node.ascendancyName then
			local current = itemsTab.items[self.spec.jewels[id] or 0]
			local free = not current or (isGeneratedRare(current) and node.alloc)
			local cost = node.alloc and 0 or (node.path and #node.path or 99)
			if free and cost <= (maxPath or 4) then
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

-- Is a jewel with this title already socketed in an allocated socket?
function MetaJewelFinderClass:HasJewel(title)
	local itemsTab = self.build.itemsTab
	for nodeId, itemId in pairs(self.spec.jewels) do
		local item = itemsTab.items[itemId]
		if item and item.title == title and self.spec.allocNodes[nodeId] then return true end
	end
	return false
end

-- How many jewels with this title are socketed in allocated sockets
function MetaJewelFinderClass:CountJewel(title)
	local itemsTab = self.build.itemsTab
	local n = 0
	for nodeId, itemId in pairs(self.spec.jewels) do
		local item = itemsTab.items[itemId]
		if item and item.title == title and self.spec.allocNodes[nodeId] then n = n + 1 end
	end
	return n
end

-- Socket jewels for real ({ { node, item } }), score, then restore
function MetaJewelFinderClass:TryJewels(placements, keep)
	local spec = self.spec
	local itemsTab = self.build.itemsTab
	local undo = spec:CreateUndoState()
	local usedBefore = spec:CountAllocNodes()
	local restore = { }
	for _, p in ipairs(placements) do
		if not p.node.alloc and p.node.path then spec:AllocNode(p.node) end
	end
	for _, p in ipairs(placements) do
		local slot = itemsTab.slots["Jewel " .. p.node.id]
		t_insert(restore, { slot = slot, previous = slot.selItemId })
		local equipped = self.ctx.equip(p.item, "Jewel " .. p.node.id)
		restore[#restore].equipped = equipped
	end
	spec:BuildAllDependsAndPaths()
	for _, p in ipairs(placements) do
		p.distance = p.node.distanceToClassStart
	end
	local points = spec:CountAllocNodes() - usedBefore
	local score = self.ctx.fullScore() - points * self.pointValue
	if keep then
		itemsTab:PopulateSlots()
		spec:AddUndoState()
		return score, points
	end
	for i = #restore, 1, -1 do
		restore[i].slot:SetSelItemId(restore[i].previous)
		itemsTab:DeleteItem(restore[i].equipped, true)
	end
	spec:RestoreUndoState(undo)
	spec:BuildAllDependsAndPaths()
	if self.ctx.tick then self.ctx.tick() end
	return score, points
end

local function variantItem(db, variant, alt, alt2)
	local item = new("Item"):Item(db.raw)
	item.variant = variant
	if alt then item.variantAlt = alt end
	if alt2 then item.variantAlt2 = alt2 end
	item:BuildAndParseRaw()
	item:NormaliseQuality()
	return item
end

-- Best Forbidden Flame / Flesh notable for the character's class
-- Returns { score, gain, label, placements } or nil
function MetaJewelFinderClass:ForbiddenPair(baseScore)
	local flame, flesh = dbItem("Forbidden Flame"), dbItem("Forbidden Flesh")
	if not flame or not flesh or self:HasJewel("Forbidden Flame") or self:HasJewel("Forbidden Flesh") then return nil end
	local sockets = self:Sockets()
	if #sockets < 2 then return nil end
	local className = self.spec.curClassName
	-- ascendancy notables already allocated can't be taken again
	local allocatedNames = { }
	for _, node in pairs(self.spec.allocNodes) do
		if node.ascendancyName then allocatedNames[node.dn] = true end
	end
	local best
	for index, name in ipairs(flame.variantList or { }) do
		local class, notable = name:match("^%((.-)%) (.+)$")
		if class == className and not allocatedNames[notable] then
			local fleshIndex
			for i, n in ipairs(flesh.variantList or { }) do
				if n == name then fleshIndex = i break end
			end
			if fleshIndex then
				local placements = {
					{ node = sockets[1].node, item = variantItem(flame, index) },
					{ node = sockets[2].node, item = variantItem(flesh, fleshIndex) },
				}
				local score = self:TryJewels(placements)
				if not best or score > best.score then
					best = { score = score, notable = notable, placements = placements }
				end
			end
		end
	end
	if not best then return nil end
	best.gain = best.score - baseScore
	best.label = "Forbidden Flame + Forbidden Flesh: " .. best.notable
	return best
end

-- Best Watcher's Eye for the auras the build uses (mods: 2, or 3 from High investment)
function MetaJewelFinderClass:WatchersEye(baseScore, modCount)
	local db = dbItem("Watcher's Eye")
	if not db or not db.variantList or self:HasJewel("Watcher's Eye") then return nil end
	local sockets = self:Sockets()
	if not sockets[1] then return nil end
	-- auras in use
	local auras = { }
	for _, group in ipairs(self.build.skillsTab.socketGroupList) do
		if group.enabled ~= false then
			for _, gem in ipairs(group.gemList or { }) do
				local g = gem.gemData or data.gems[gem.gemId]
				if g and g.tags and g.tags.aura and not g.grantedEffect.support and gem.enabled ~= false then
					auras[g.name:gsub("^Vaal ", "")] = true
				end
			end
		end
	end
	local options = { }
	for index, name in ipairs(db.variantList) do
		local aura = name:match("^(.-):")
		if aura and auras[aura] and not name:find("(Pre ", 1, true) then
			t_insert(options, { index = index, name = name })
		end
	end
	if #options == 0 then return nil end
	local none = 1
	for i, n in ipairs(db.variantList) do if n == "None" then none = i end end
	local chosen = { }
	local bestScore
	for slotIndex = 1, (modCount or 2) do
		local pick, pickScore
		for _, option in ipairs(options) do
			local used = false
			for _, c in ipairs(chosen) do if c.index == option.index then used = true end end
			if not used then
				local idx = { none, none, none }
				for i, c in ipairs(chosen) do idx[i] = c.index end
				idx[slotIndex] = option.index
				local item = variantItem(db, idx[1], idx[2], idx[3])
				local score = self:TryJewels({ { node = sockets[1].node, item = item } })
				if not pickScore or score > pickScore then pick, pickScore = option, score end
			end
		end
		if not pick or (bestScore and pickScore <= bestScore) then break end
		t_insert(chosen, pick)
		bestScore = pickScore
	end
	if not chosen[1] then return nil end
	local idx = { none, none, none }
	local names = { }
	for i, c in ipairs(chosen) do idx[i] = c.index t_insert(names, c.name) end
	return {
		score = bestScore,
		gain = bestScore - baseScore,
		label = "Watcher's Eye: " .. table.concat(names, ", "),
		placements = { { node = sockets[1].node, item = variantItem(db, idx[1], idx[2], idx[3]) } },
	}
end

-- A unique jewel by title (e.g. an archetype's Split Personality / Healthy Mind),
-- in the nearest free socket. Jewels with stat variants (Split Personality) try
-- the preferred stat with every second stat. Returns { score, gain, label, placements } or nil
function MetaJewelFinderClass:UniqueJewel(baseScore, title, preferredStat, limit)
	local db = dbItem(title)
	if not db or self:CountJewel(title) >= (limit or 1) then return nil end
	local sockets = self:Sockets()
	if not sockets[1] then return nil end
	local options = { }
	local list = db.variantList or { }
	if db.hasAltVariant and #list > 1 then
		local mains = { }
		for i, name in ipairs(list) do
			if not preferredStat or name == preferredStat then t_insert(mains, i) end
		end
		for _, m in ipairs(mains) do
			for j = 1, #list do
				if j ~= m then t_insert(options, { m, j, label = list[m] .. " / " .. list[j] }) end
			end
		end
	else
		t_insert(options, { db.defaultVariant or (#list > 0 and #list or nil) })
	end
	local best
	for _, opt in ipairs(options) do
		local item = variantItem(db, opt[1], opt[2])
		local placement = { node = sockets[1].node, item = item }
		local score = self:TryJewels({ placement })
		if not best or score > best.score then
			best = { score = score, placements = { placement }, label = title .. (opt.label and (" (" .. opt.label .. ")") or "") }
		end
	end
	if not best then return nil end
	-- jewels that grow with the passives between their socket and the class
	-- start (Split Personality): the same jewel in every socket within reach,
	-- far ones included (long paths and sockets deep in cluster jewels), the
	-- points a path costs counted against it
	if title == "Split Personality" then
		local item = best.placements[1].item
		local candidates = self:Sockets(8, true)
		for i = 1, math.min(#candidates, 16) do
			local node = candidates[i].node
			if node ~= best.placements[1].node then
				local placement = { node = node, item = item }
				local score = self:TryJewels({ placement })
				if score > best.score then
					best.score, best.placements = score, { placement }
				end
			end
		end
		local placement = best.placements[1]
		best.label = best.label .. string.format(" in a socket %d passives from the class start", placement.distance or placement.node.distanceToClassStart or 0)
	end
	best.gain = best.score - baseScore
	return best
end

-- Unique jewels handled elsewhere (their own search), or whose value PoB
-- can't see by socketing them (they change what can be allocated)
local skipJewels = {
	["Forbidden Flame"] = true, ["Forbidden Flesh"] = true, ["Watcher's Eye"] = true, ["Split Personality"] = true,
	["Thread of Hope"] = true, ["Intuitive Leap"] = true, ["Impossible Escape"] = true, ["Inspired Learning"] = true,
	["Glorious Vanity"] = true, ["Lethal Pride"] = true, ["Brutal Restraint"] = true, ["Militant Faith"] = true,
	["Elegant Hubris"] = true, ["Heroic Tragedy"] = true,
}

-- Every other unique jewel, priced within the budget (allowed(title) -> bool):
-- each variant screened with one calculation in the nearest sockets (radius
-- jewels depend on where they sit), the best few socketed for real.
-- Returns { score, gain, label, placements } or nil
function MetaJewelFinderClass:BestUniqueJewel(baseScore, allowed, quickScore)
	local sockets = self:Sockets(4)
	if not sockets[1] then return nil end
	local spec = self.spec
	local socketList = { }
	for i = 1, math.min(#sockets, 4) do
		local node = sockets[i].node
		local pathSet
		if not node.alloc and node.path then
			pathSet = { }
			for _, n in ipairs(node.path) do pathSet[n] = true end
		end
		t_insert(socketList, { node = node, pathSet = pathSet, points = node.alloc and 0 or #(node.path or { }) })
	end
	local base = quickScore({ })
	local byTitle = { }
	for _, unique in pairs(main.uniqueDB.list) do
		local title = unique.title
		if unique.type == "Jewel" and not skipJewels[title] and not (unique.base and unique.base.subType == "Abyss")
			and not unique.clusterJewel and allowed(title) and self:CountJewel(title) == 0 then
			local variants = { }
			if unique.variantList and #unique.variantList > 1 then
				for i = 1, math.min(#unique.variantList, 24) do
					if not unique.variantList[i]:find("Pre ", 1, true) then t_insert(variants, i) end
				end
			else
				variants[1] = false
			end
			for _, v in ipairs(variants) do
				local ok, item = pcall(variantItem, unique, v or nil)
				if ok and item then
					for _, socket in ipairs(socketList) do
						local slotName = "Jewel " .. socket.node.id
						local override = { repItems = { [slotName] = item }, addNodes = socket.pathSet }
						local score = quickScore(override) - socket.points * self.pointValue
						local entry = byTitle[title]
						if score > base + 0.005 and (not entry or score > entry.quick) then
							byTitle[title] = { quick = score, item = item, node = socket.node, variant = v and unique.variantList[v] }
						end
					end
				end
			end
		end
	end
	local ranked = { }
	for title, entry in pairs(byTitle) do entry.title = title t_insert(ranked, entry) end
	t_sort(ranked, function(a, b) return a.quick > b.quick end)
	local best
	for i = 1, math.min(#ranked, 3) do
		local entry = ranked[i]
		local placement = { node = entry.node, item = entry.item }
		local score = self:TryJewels({ placement })
		if not best or score > best.score then
			best = { score = score, placements = { placement }, label = entry.title .. (entry.variant and (" (" .. entry.variant .. ")") or ""), title = entry.title }
		end
	end
	if not best then return nil end
	best.gain = best.score - baseScore
	return best
end

-- Socket a result's jewels for good
function MetaJewelFinderClass:Apply(result)
	return self:TryJewels(result.placements, true)
end
