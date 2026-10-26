-- Path of Building
--
-- Class: Animate Guardian Setup
-- An Animate Guardian wearing uniques that buff nearby allies (Kingmaker's
-- Culling Strike, Replica Leer Cast, Victario's Flight's speed, Mask of the
-- Tribunal...): a top player defence and damage trick PoB doesn't
-- calculate (the guardian's items aren't the player's). Each candidate's
-- ally lines are turned into the player's own ("Nearby Allies have Culling
-- Strike" -> "Culling Strike") and measured; the best item per guardian slot
-- is kept while it helps, and the lines go into a Custom Modifier group of
-- the configuration ("Animate Guardian (generated)"), where PoB counts them
-- and the player can see and switch them off.
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert
local t_sort = table.sort

---@class AnimateGuardianSetup
local AnimateGuardianSetupClass = newClass("AnimateGuardianSetup")

AnimateGuardianSetupClass.groupTitle = "Animate Guardian (generated)"

function AnimateGuardianSetupClass:AnimateGuardianSetup(gen)
	self.gen = gen
	self.build = gen.build
	return self
end

-- Guardian slots by item type (it wears a weapon or shield, armour pieces)
local slotOfType = {
	["Helmet"] = "Helmet", ["Body Armour"] = "Body Armour", ["Gloves"] = "Gloves", ["Boots"] = "Boots",
	["Shield"] = "Off Hand",
}
-- (melee weapons only: a guardian can't animate a bow or a wand)
local rangedTypes = { ["Bow"] = true, ["Wand"] = true, ["Fishing Rod"] = true }
local function guardianSlot(item)
	if slotOfType[item.type] then return slotOfType[item.type] end
	if item.base and item.base.weapon and not rangedTypes[item.type] then return "Weapon" end
end

-- The highest item level requirement the guardian can use at a gem level
-- (poewiki: 33 at level 1 to 82 at 19, every item from 20): items above it
-- are disabled on the guardian
local maxReqByLevel = { 33, 36, 39, 43, 46, 48, 51, 53, 56, 58, 61, 63, 66, 68, 71, 73, 76, 79, 82 }
function AnimateGuardianSetupClass.MaxItemLevel(gemLevel)
	gemLevel = gemLevel or 20
	if gemLevel >= 20 then return 100 end
	return maxReqByLevel[math.max(1, gemLevel)] or 100
end

-- The guardian's slots it should always wear something in (poewiki: helmet,
-- body armour, gloves, boots, a melee weapon or a shield)
AnimateGuardianSetupClass.wornSlots = { "Weapon", "Helmet", "Body Armour", "Gloves", "Boots" }

-- The player's version of an ally line, or nil
function AnimateGuardianSetupClass.PlayerLine(line)
	local l = line
	-- (lines that depend on the guardian's own sockets or stats aren't used)
	if l:match("per %a+ Socket") then return nil end
	l = l:gsub("^You and [Nn]earby Allies have ", ""):gsub("^You and [Nn]earby Allies ", "")
	local rest = l:match("^[Nn]earby Allies have (.+)$") or l:match("^[Nn]earby Allies gain (.+)$") or l:match("^[Nn]earby Allies' (.+)$")
	if rest then l = rest elseif l == line then return nil end
	l = l:gsub(" you have$", "")
	return l
end

-- The item level the guardian of this build can use (its gem's level)
function AnimateGuardianSetupClass:MaxLevel()
	local level = 20
	for _, group in ipairs(self.build.skillsTab.socketGroupList) do
		for _, gem in ipairs(group.gemList or { }) do
			if gem.gemData and gem.gemData.name == "Animate Guardian" then level = gem.level or level end
		end
	end
	return self.MaxItemLevel(level)
end

-- Candidate items: { item, slot, lines }
function AnimateGuardianSetupClass:Candidates()
	local finder = new("BestItemFinder"):BestItemFinder(self.build.itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = self.gen.options.investment }
	local list = { }
	local titles = { }
	local byTitle = { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		if not byTitle[title] then byTitle[title] = item; t_insert(titles, title) end
	end
	t_sort(titles)
	local maxLevel = self:MaxLevel()
	for _, title in ipairs(titles) do
		local item = byTitle[title]
		local slot = guardianSlot(item)
		local req = item.requirements and item.requirements.level or 0
		if slot and req <= maxLevel and finder:IsItemAllowed(item, filter) then
			local lines = { }
			for _, modLine in ipairs(item.explicitModLines or { }) do
				local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
				if current and modLine.line then
					local playerLine = self.PlayerLine(modLine.line)
					if playerLine then
						local mods, extra = modLib.parseMod(playerLine)
						if mods and not extra then t_insert(lines, playerLine) end
					end
				end
			end
			if #lines > 0 then t_insert(list, { item = item, slot = slot, lines = lines, title = title }) end
		end
	end
	return list
end

local nextId = -30000
local function virtualNode(spec, lines)
	nextId = nextId - 1
	local node = { id = nextId, type = "Normal", name = "Animate Guardian buffs", dn = "Animate Guardian buffs", sd = { } }
	for i, l in ipairs(lines) do node.sd[i] = l end
	spec.tree:ProcessStats(node)
	return node
end

-- The guardian's custom modifier group in the active configuration set
function AnimateGuardianSetupClass:Group(create)
	local configTab = self.build.configTab
	local set = configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	if not set then return nil end
	set.customModsList = set.customModsList or { }
	for _, block in ipairs(set.customModsList) do
		-- (the title carries the items' names after the group's own title)
		if block.title and block.title:sub(1, #self.groupTitle) == self.groupTitle then return block end
	end
	if create then
		local block = { title = self.groupTitle, enabled = true, text = "" }
		t_insert(set.customModsList, block)
		return block
	end
end

-- Chooses the guardian's items and writes their buffs; returns the score gain
function AnimateGuardianSetupClass:Run()
	local gen = self.gen
	local spec = self.build.spec
	local candidates = self:Candidates()
	if #candidates == 0 then return 0 end
	local current = gen:Score()
	local chosen, lines, used = { }, { }, { }
	for _ = 1, 5 do
		local best
		for _, c in ipairs(candidates) do
			if not used[c.slot] and not chosen[c.title] then
				local all = { }
				for _, l in ipairs(lines) do t_insert(all, l) end
				for _, l in ipairs(c.lines) do t_insert(all, l) end
				local score = gen:Score({ addNodes = { [virtualNode(spec, all)] = true } })
				if score > current + 0.005 and (not best or score > best.score + 1e-9) then best = { c = c, score = score } end
			end
		end
		if not best then break end
		used[best.c.slot] = true
		chosen[best.c.title] = best.c
		for _, l in ipairs(best.c.lines) do t_insert(lines, l) end
		current = best.score
		gen:Tick()
	end
	if #lines == 0 then return 0 end
	local before = gen:FullScore()
	local block = self:Group(true)
	local oldText = block.text
	block.text = table.concat(lines, "\n")
	self.build.configTab:BuildModList()
	gen:Recalculate()
	local after = gen:FullScore()
	if after <= before + 0.005 then
		block.text = oldText
		self.build.configTab:BuildModList()
		gen:Recalculate()
		return 0
	end
	local names = { }
	for title, c in pairs(chosen) do
		local price = GetPriceSource():UniquePrice(c.item)
		t_insert(names, string.format("%s (%s, %s)", title, c.slot, GetPriceSource().FormatPrice(price)))
		gen.costs = gen.costs or { }
		t_insert(gen.costs, price or false)
	end
	t_sort(names)
	-- every slot worn (poewiki): the ones no buff item took get a rare for the
	-- guardian's own survival - it can't be summoned again in an area where it
	-- died - with life and resistances, within the level it can use
	local taken = { }
	for _, c in pairs(chosen) do taken[c.slot == "Off Hand" and "Weapon" or c.slot] = true end
	local maxLevel = self:MaxLevel()
	for _, slot in ipairs(self.wornSlots) do
		if not taken[slot] then
			t_insert(names, string.format("%s: any rare %s with maximum life and elemental resistances%s, for its survival",
				slot, slot == "Weapon" and "melee weapon or shield" or slot:lower(), maxLevel < 100 and string.format(" (level requirement %d or less at this gem level)", maxLevel) or ""))
		end
	end
	-- what the guardian wears, where the player looks for it: the group's title
	-- in the Configuration tab and the build's notes (BuildGenerator:WriteNotes)
	local titles = { }
	for title in pairs(chosen) do t_insert(titles, title) end
	t_sort(titles)
	block.title = self.groupTitle .. ": " .. table.concat(titles, ", ")
	gen.animateGuardianItems = names
	gen:Note(string.format("Animate Guardian wearing %s: their buffs to nearby allies are in the Configuration tab's custom modifiers (\"%s\"), score %+.3f",
		table.concat(names, ", "), self.groupTitle, after - before))
	return after - before
end
