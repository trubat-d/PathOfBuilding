-- Path of Building
--
-- Module: Build Comparison
-- Compares builds with the build generator's scorer and configuration:
--   Evaluate    score, damage and max hits of the loaded build
--   Ablate      what each part of the loaded build is worth (removed one at a time)
--   ReadParts   the parts of the loaded build (gear, supports, other skill
--               groups, passive tree with jewels, configuration)
--   Transplant  each part of another build put into the loaded one
-- Used by the "Compare with top players" step of the Generate Build window
-- (in background threads, Modules/GeneratorWorker) and the benchmark tools.
-- All functions work on the build currently loaded in `build` (a build mode).
--
local t_insert = table.insert
local t_sort = table.sort

local M = { }

-- A scorer like the generator's, with the generator's configuration applied
-- focusId: BuildScorer focus id (default DPS_FLOOR); tier: "uber" / "pinnacle"
function M.Setup(build, focusId, tier)
	local ac = new("AutoConfig"):AutoConfig(build)
	ac:Run()
	local focus
	for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do
		if entry.id == (focusId or "DPS_FLOOR") then focus = entry end
	end
	focus = focus or new("BuildScorer"):BuildScorer(build).focusList[1]
	local scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = tier or "uber" })
	scorer.useChecklist = true
	return { build = build, scorer = scorer, ac = ac }
end

-- Score of the build (with an optional calculator override)
function M.Measure(ctx, override, reconfigure)
	if reconfigure then ctx.ac:Run() else ctx.ac:Recalculate() end
	local r = ctx.scorer:Evaluate(ctx.build.calcsTab:GetMiscCalculator(), override or { })
	return { score = r.score, dps = r.dps, ehp = r.ehp, minHit = (ctx.scorer:MinMaxHit(r.output)), output = r.output, penalties = r.penalties }
end

-- The socket group with this skill becomes the main one (top players' exports
-- sometimes have another group selected)
function M.SelectMainSkill(build, name)
	if not name or name == "" then return false end
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		for _, gem in ipairs(group.gemList) do
			if gem.gemData and gem.gemData.name == name and not gem.gemData.grantedEffect.support then
				build.mainSocketGroup = index
				group.mainActiveSkill = 1
				return true
			end
		end
	end
	return false
end

-- Summary of the loaded build
function M.Evaluate(ctx)
	local m = M.Measure(ctx, nil, true)
	local o = m.output
	local build = ctx.build
	local skill = build.calcsTab.mainEnv.player.mainSkill
	local result = {
		score = m.score, dps = m.dps, ehp = m.ehp, minHit = m.minHit,
		maxHit = { physical = o.PhysicalMaximumHitTaken, fire = o.FireMaximumHitTaken, cold = o.ColdMaximumHitTaken, lightning = o.LightningMaximumHitTaken, chaos = o.ChaosMaximumHitTaken },
		life = o.Life, energyShield = o.EnergyShield, skill = skill and skill.activeEffect.grantedEffect.name,
		penalties = { }, keystones = { }, uniques = { },
		class = build.spec.curAscendClassName, level = build.characterLevel,
	}
	for _, p in ipairs(m.penalties or { }) do t_insert(result.penalties, p.label) end
	for _, node in pairs(build.spec.allocNodes) do
		if node.type == "Keystone" then t_insert(result.keystones, node.dn) end
	end
	t_sort(result.keystones)
	for slotName, slot in pairs(build.itemsTab.slots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and (item.rarity == "UNIQUE" or item.rarity == "RELIC") and (not slot.nodeId or build.spec.allocNodes[slot.nodeId]) and not slotName:match("Swap") then
			t_insert(result.uniques, item.title or item.name)
		end
	end
	t_sort(result.uniques)
	return result
end

local function row(label, base, m)
	return { label = label, dScore = m.score - base.score, dps = base.dps > 0 and m.dps / base.dps or 1, hit = base.minHit > 0 and m.minHit / base.minHit or 1 }
end

-- What each part of the loaded build is worth: removed one at a time
-- (items through the calculator override; gems and groups switched off)
-- Returns rows sorted by score lost, most important first
function M.Ablate(ctx)
	local build = ctx.build
	local base = M.Measure(ctx)
	local rows = { }
	for slotName, slot in pairs(build.itemsTab.slots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and (not slot.nodeId or build.spec.allocNodes[slot.nodeId]) and not slotName:match("Swap") then
			t_insert(rows, row(string.format("%s (%s)", item.title or item.name, slotName), base, M.Measure(ctx, { repItems = { [slotName] = false } })))
		end
	end
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		if group.enabled ~= false then
			if index == build.mainSocketGroup then
				for _, gem in ipairs(group.gemList) do
					if gem.enabled ~= false and gem.gemData and gem.gemData.grantedEffect.support then
						gem.enabled = false
						t_insert(rows, row(gem.gemData.name .. " (support)", base, M.Measure(ctx)))
						gem.enabled = true
					end
				end
			else
				local names = { }
				for _, gem in ipairs(group.gemList) do if gem.gemData then t_insert(names, gem.gemData.name) end end
				if #names > 0 then
					group.enabled = false
					t_insert(rows, row(table.concat(names, " + "), base, M.Measure(ctx)))
					group.enabled = true
				end
			end
		end
	end
	for _, node in pairs(build.spec.allocNodes) do
		if node.type == "Keystone" or (node.ascendancyName and node.type == "Notable") or node.type == "Mastery" then
			local label = node.type == "Mastery" and (node.dn .. ": " .. tostring(node.sd and node.sd[1])) or node.dn
			t_insert(rows, row(label, base, M.Measure(ctx, { removeNodes = { [node] = true } })))
		end
	end
	M.Measure(ctx)
	t_sort(rows, function(a, b) return a.dScore < b.dScore end)
	return rows
end

-- The parts of the loaded build, to put into another one
function M.ReadParts(build)
	local parts = { items = { }, groups = { }, supports = { }, config = { } }
	for slotName, slot in pairs(build.itemsTab.slots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and not slot.nodeId and not slotName:match("Swap") and not slotName:match("Abyssal") then
			parts.items[slotName] = { raw = item.raw, name = item.title or item.name }
		end
	end
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		local gems = { }
		for _, gem in ipairs(group.gemList) do
			if gem.gemData and gem.enabled ~= false then
				t_insert(gems, { name = gem.gemData.name, level = gem.level, quality = gem.quality, support = gem.gemData.grantedEffect.support })
			end
		end
		if index == build.mainSocketGroup then
			for _, g in ipairs(gems) do if g.support then t_insert(parts.supports, g) end end
		elseif group.enabled ~= false and #gems > 0 then
			t_insert(parts.groups, gems)
		end
	end
	local spec = build.spec
	parts.tree = { className = spec.curClassName, classId = spec.curClassId, ascendClassId = spec.curAscendClassId,
		secondary = spec.curSecondaryAscendClassId, nodes = { }, masteries = { }, jewels = { } }
	for id in pairs(spec.allocNodes) do t_insert(parts.tree.nodes, id) end
	for k, v in pairs(spec.masterySelections or { }) do parts.tree.masteries[k] = v end
	for nodeId, itemId in pairs(spec.jewels) do
		local item = build.itemsTab.items[itemId]
		if item and spec.allocNodes[nodeId] then parts.tree.jewels[nodeId] = item.raw end
	end
	for k, v in pairs(build.configTab.input) do parts.config[k] = v end
	return parts
end

local function gemByName(name)
	for gemId, gem in pairs(data.gems) do if gem.name == name then return gemId, gem end end
end

-- Each part of another build (from ReadParts) put into the loaded build
-- Returns rows sorted by score gained, most helpful first
function M.Transplant(ctx, parts)
	local build = ctx.build
	local base = M.Measure(ctx, nil, true)
	local rows = { }
	-- gear, one item at a time
	local all = { }
	for slotName, entry in pairs(parts.items) do
		local item = new("Item"):Item(entry.raw)
		item:NormaliseQuality()
		item:BuildModList()
		all[slotName] = item
		if not slotName:match("^Flask") then
			t_insert(rows, row(string.format("their %s: %s", slotName, entry.name), base, M.Measure(ctx, { repItems = { [slotName] = item } })))
		end
	end
	t_insert(rows, row("all their gear", base, M.Measure(ctx, { repItems = all })))
	-- main skill supports
	local main = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if main and #parts.supports > 0 then
		local saved = { }
		for i, g in ipairs(main.gemList) do saved[i] = g end
		local list = { }
		for _, g in ipairs(main.gemList) do
			local gd = g.gemData or (g.gemId and data.gems[g.gemId])
			if gd and not gd.grantedEffect.support then t_insert(list, g) end
		end
		local names = { }
		for _, s in ipairs(parts.supports) do
			local gemId = gemByName(s.name)
			if gemId then
				t_insert(list, { level = s.level, quality = s.quality, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId })
				t_insert(names, s.name)
			end
		end
		main.gemList = list
		build.skillsTab:ProcessSocketGroup(main)
		t_insert(rows, row("their supports (" .. table.concat(names, ", ") .. ")", base, M.Measure(ctx, nil, true)))
		main.gemList = saved
		build.skillsTab:ProcessSocketGroup(main)
	end
	-- their other skill groups instead of ours
	if #parts.groups > 0 then
		local savedGroups = { }
		for i, g in ipairs(build.skillsTab.socketGroupList) do savedGroups[i] = g end
		local mainBefore = build.mainSocketGroup
		local list = { build.skillsTab.socketGroupList[mainBefore] }
		for _, gems in ipairs(parts.groups) do
			local group = { label = "", enabled = true, gemList = { } }
			for _, s in ipairs(gems) do
				local gemId = gemByName(s.name)
				if gemId then t_insert(group.gemList, { level = s.level, quality = s.quality, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId }) end
			end
			t_insert(list, group)
		end
		build.skillsTab.socketGroupList = list
		build.mainSocketGroup = 1
		for _, g in ipairs(list) do build.skillsTab:ProcessSocketGroup(g) end
		t_insert(rows, row("their other skill groups (auras, curses, buffs)", base, M.Measure(ctx, nil, true)))
		build.skillsTab.socketGroupList = savedGroups
		build.mainSocketGroup = mainBefore
		for _, g in ipairs(savedGroups) do build.skillsTab:ProcessSocketGroup(g) end
	end
	-- their passive tree with its jewels (same class only)
	if parts.tree.classId == build.spec.curClassId then
		local undo = build.spec:CreateUndoState()
		local savedJewels = { }
		for k, v in pairs(build.spec.jewels) do savedJewels[k] = v end
		build.spec:ImportFromNodeList(parts.tree.className, parts.tree.classId, parts.tree.ascendClassId, parts.tree.secondary, parts.tree.nodes, { }, parts.tree.masteries)
		for nodeId, raw in pairs(parts.tree.jewels) do
			local item = new("Item"):Item(raw)
			item:NormaliseQuality()
			build.itemsTab:AddItem(item, true)
			local slot = build.itemsTab.slots["Jewel " .. nodeId]
			if slot then slot:SetSelItemId(item.id) end
		end
		build.itemsTab:PopulateSlots()
		build.spec:BuildAllDependsAndPaths()
		t_insert(rows, row("their passive tree and tree jewels", base, M.Measure(ctx, nil, true)))
		build.spec:RestoreUndoState(undo)
		for k in pairs(build.spec.jewels) do build.spec.jewels[k] = savedJewels[k] end
		build.itemsTab:PopulateSlots()
		build.spec:BuildAllDependsAndPaths()
	end
	M.Measure(ctx, nil, true)
	t_sort(rows, function(a, b) return a.dScore > b.dScore end)
	return rows
end

-- XML of a PoB code ("eN..." base64url of zlib data)
function M.DecodeCode(code)
	code = (code or ""):gsub("%s", "")
	return Inflate(common.base64.decode((code:gsub("-", "+"):gsub("_", "/"))))
end

return M
