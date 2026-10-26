-- Several builds of one character in one Path of Building file, one loadout
-- each: a loadout is a passive tree, an item set, a skill set and a
-- configuration set whose titles carry the same "{n}" tag (Build:SyncLoadouts
-- links them; the Loadouts drop-down switches all four at once). Used for the
-- builds the generator finished in one session: every archetype / try that
-- was fully built, kept beside the best one instead of thrown away, each with
-- its own configuration (the one it was scored with).
--
--   local merged = LoadModule("Modules/BuildLoadouts").Merge({
--       { xml = bestXml, title = "Power charges (best) 17.6" },
--       { xml = otherXml, title = "Life stacking 17.4" }, ... })
--
-- The first build is the base: its Build section (class, level, stats), notes
-- and import link are kept, and its loadout is the active one. Each other
-- build brings only its active tree / item set / skill set / configuration
-- set, and its items renumbered (the item set's slots and the tree's jewel
-- sockets follow). The main skill's socket group is moved to the top of every
-- skill set: the main socket group is one number for the whole build.
local t_insert = table.insert
local t_remove = table.remove

local M = { }

local function child(node, elem)
	for _, c in ipairs(node) do
		if type(c) == "table" and c.elem == elem then return c end
	end
end

local function children(node, elem)
	local list = { }
	for _, c in ipairs(node) do
		if type(c) == "table" and c.elem == elem then t_insert(list, c) end
	end
	return list
end

local function deepCopy(node)
	if type(node) ~= "table" then return node end
	local copy = { }
	for k, v in pairs(node) do copy[k] = deepCopy(v) end
	return copy
end

-- (the section, creating an empty one when the build has none)
local function section(root, elem)
	local node = child(root, elem)
	if not node then
		node = { elem = elem, attrib = { } }
		t_insert(root, node)
	end
	node.attrib = node.attrib or { }
	return node
end

-- A build's active sets (older files without sets: the section itself is the
-- one set, wrapped). Returns spec, itemSet, skillSet, configSet, and the main
-- socket group index.
local function activeSets(root)
	local tree = section(root, "Tree")
	local specs = children(tree, "Spec")
	local spec = specs[tonumber(tree.attrib.activeSpec) or 1] or specs[1]

	local items = section(root, "Items")
	local itemSets = children(items, "ItemSet")
	local itemSet
	for _, s in ipairs(itemSets) do
		if s.attrib.id == tostring(items.attrib.activeItemSet or 1) then itemSet = s end
	end
	itemSet = itemSet or itemSets[1]
	if not itemSet then
		-- (slots straight in the Items section)
		itemSet = { elem = "ItemSet", attrib = { id = "1", useSecondWeaponSet = items.attrib.useSecondWeaponSet or "false" } }
		for _, s in ipairs(children(items, "Slot")) do t_insert(itemSet, deepCopy(s)) end
	end

	local skills = section(root, "Skills")
	local skillSets = children(skills, "SkillSet")
	local skillSet
	for _, s in ipairs(skillSets) do
		if s.attrib.id == tostring(skills.attrib.activeSkillSet or 1) then skillSet = s end
	end
	skillSet = skillSet or skillSets[1]
	if not skillSet then
		skillSet = { elem = "SkillSet", attrib = { id = "1" } }
		for _, s in ipairs(children(skills, "Skill")) do t_insert(skillSet, deepCopy(s)) end
	end

	local config = section(root, "Config")
	local configSets = children(config, "ConfigSet")
	local configSet
	for _, s in ipairs(configSets) do
		if s.attrib.id == tostring(config.attrib.activeConfigSet or 1) then configSet = s end
	end
	configSet = configSet or configSets[1]
	if not configSet then
		configSet = { elem = "ConfigSet", attrib = { id = "1" } }
		for _, c in ipairs(config) do
			if type(c) == "table" and c.elem ~= "ConfigSet" then t_insert(configSet, deepCopy(c)) end
		end
	end

	local build = child(root, "Build")
	local mainGroup = build and tonumber(build.attrib.mainSocketGroup) or 1
	-- (the bandit and the pantheon are configuration options, kept on the
	-- Build element by older files: copied into the set so that each loadout
	-- keeps its own)
	if build then
		local has = { }
		for _, c in ipairs(configSet) do
			if type(c) == "table" and c.elem == "Input" and c.attrib then has[c.attrib.name] = true end
		end
		for _, name in ipairs({ "bandit", "pantheonMajorGod", "pantheonMinorGod" }) do
			if not has[name] and build.attrib[name] then
				t_insert(configSet, { elem = "Input", attrib = { name = name, string = build.attrib[name] } })
			end
		end
	end
	return spec, itemSet, skillSet, configSet, mainGroup
end

-- (the skill set with its main socket group first)
local function mainGroupFirst(skillSet, mainGroup)
	local groups = { }
	for i, c in ipairs(skillSet) do
		if type(c) == "table" and c.elem == "Skill" then t_insert(groups, i) end
	end
	local at = groups[mainGroup]
	if at and at ~= groups[1] then
		local node = t_remove(skillSet, at)
		t_insert(skillSet, groups[1], node)
	end
end

-- itemId attributes anywhere below a node (item set slots, tree sockets)
local function remapItemIds(node, map)
	if type(node) ~= "table" then return end
	if node.attrib and node.attrib.itemId and map[node.attrib.itemId] then
		node.attrib.itemId = map[node.attrib.itemId]
	end
	for _, c in ipairs(node) do remapItemIds(c, map) end
end

local function titled(title, n)
	title = (title or ("Build " .. n)):gsub("[{}]", "")
	return title .. " {" .. n .. "}"
end

-- entries: { { xml = text, title = string }, ... } (first: the base, active).
-- Returns the merged XML text, or nil and an error.
function M.Merge(entries)
	if not entries or not entries[1] then return nil, "no builds" end
	local parsed = { }
	for i, entry in ipairs(entries) do
		local db, err = common.xml.ParseXML(entry.xml)
		if not db or not db[1] or db[1].elem ~= "PathOfBuilding" then
			return nil, string.format("build %d: %s", i, tostring(err or "not a Path of Building file"))
		end
		parsed[i] = db
	end
	local root = parsed[1][1]
	local base = { }
	base.spec, base.itemSet, base.skillSet, base.configSet, base.mainGroup = activeSets(root)

	-- the base keeps only its active sets, with its loadout title
	local tree, items, skills, config = section(root, "Tree"), section(root, "Items"), section(root, "Skills"), section(root, "Config")
	local function strip(node, elems)
		for i = #node, 1, -1 do
			local c = node[i]
			if type(c) == "table" and elems[c.elem] then t_remove(node, i) end
		end
	end
	strip(tree, { Spec = true })
	strip(items, { ItemSet = true, Slot = true })
	strip(skills, { SkillSet = true, Skill = true })
	strip(config, { ConfigSet = true, Input = true, Placeholder = true })

	local maxItem = 0
	for _, item in ipairs(children(items, "Item")) do
		maxItem = math.max(maxItem, tonumber(item.attrib.id) or 0)
	end

	local function addLoadout(n, title, spec, itemSet, skillSet, configSet, mainGroup)
		spec.attrib.title = titled(title, n)
		t_insert(tree, spec)
		itemSet.attrib.id, itemSet.attrib.title = tostring(n), titled(title, n)
		t_insert(items, itemSet)
		mainGroupFirst(skillSet, mainGroup)
		skillSet.attrib.id, skillSet.attrib.title = tostring(n), titled(title, n)
		t_insert(skills, skillSet)
		configSet.attrib.id, configSet.attrib.title = tostring(n), titled(title, n)
		t_insert(config, configSet)
	end
	addLoadout(1, entries[1].title, base.spec, base.itemSet, base.skillSet, base.configSet, base.mainGroup)

	for i = 2, #entries do
		local other = parsed[i][1]
		local spec, itemSet, skillSet, configSet, mainGroup = activeSets(other)
		spec, itemSet, skillSet, configSet = deepCopy(spec), deepCopy(itemSet), deepCopy(skillSet), deepCopy(configSet)
		-- its items, renumbered after the ones already there
		local map = { }
		local offset = maxItem
		for _, item in ipairs(children(section(other, "Items"), "Item")) do
			local copy = deepCopy(item)
			local id = tonumber(copy.attrib.id) or 0
			local newId = tostring(offset + id)
			map[copy.attrib.id] = newId
			copy.attrib.id = newId
			maxItem = math.max(maxItem, offset + id)
			-- (items go before the item sets: Items:Load reads them in order)
			local at = #items + 1
			for j, c in ipairs(items) do
				if type(c) == "table" and c.elem == "ItemSet" then at = j break end
			end
			t_insert(items, at, copy)
		end
		remapItemIds(itemSet, map)
		remapItemIds(spec, map)
		addLoadout(i, entries[i].title, spec, itemSet, skillSet, configSet, mainGroup)
	end

	tree.attrib.activeSpec = "1"
	items.attrib.activeItemSet = "1"
	skills.attrib.activeSkillSet = "1"
	config.attrib.activeConfigSet = "1"
	local build = child(root, "Build")
	if build then build.attrib.mainSocketGroup = "1" end

	-- the notes list the loadouts
	if #entries > 1 then
		local notes = section(root, "Notes")
		local lines = { "Loadouts (the drop-down next to the ascendancy switches tree, items, skills and configuration together):" }
		for i, entry in ipairs(entries) do t_insert(lines, "  {" .. i .. "} " .. (entry.title or ("Build " .. i)) .. (entry.summary and (": " .. entry.summary) or "")) end
		local old = { }
		for _, c in ipairs(notes) do if type(c) == "string" then t_insert(old, c) end end
		for j = #notes, 1, -1 do if type(notes[j]) == "string" then t_remove(notes, j) end end
		t_insert(notes, table.concat(lines, "\n") .. (#old > 0 and ("\n\n" .. table.concat(old)) or ""))
	end
	local text, err = common.xml.ComposeXML(root)
	if not text then return nil, err end
	return text
end

return M
