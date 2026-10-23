-- Path of Building
--
-- Class: Best Item Finder
-- Tries every unique in the item database in each gear slot and ranks them
-- by how much they improve a chosen stat, using the build's own calculator.
-- Runs entirely locally; no network or external service is used.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_abs = math.abs

---@class BestItemFinder
local BestItemFinderClass = newClass("BestItemFinder")

-- Gear slots that are searched, in display order
BestItemFinderClass.gearSlots = { "Weapon 1", "Weapon 2", "Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Ring 2", "Ring 3", "Belt" }

local elements = { "Fire", "Cold", "Lightning" }
local attributes = { "Str", "Dex", "Int" }

---@param itemsTab ItemsTab
function BestItemFinderClass:BestItemFinder(itemsTab)
	self.itemsTab = itemsTab
	self.build = itemsTab.build
	return self
end

-- Default options; any field can be overridden when calling Run
function BestItemFinderClass:DefaultOptions()
	return {
		stat = nil,             -- entry from data.powerStatList; defaults to Full DPS
		topN = 3,               -- results kept per slot
		obtainableOnly = true,  -- skip items that can no longer be obtained
		levelOnly = true,       -- skip items above the character's level
		keepResists = true,     -- reject items that lower an elemental resistance below its cap
		keepAttributes = true,  -- reject items that leave attribute requirements unmet
		keepSkillUsable = true, -- reject items that stop the main skill from dealing damage (e.g. wrong weapon type)
		slots = nil,            -- list of slot names; defaults to every active gear slot
		yieldEvery = nil,       -- ms between coroutine yields (nil = never yield)
		onProgress = nil,       -- function(done, total)
	}
end

local function statByName(name)
	for _, stat in ipairs(data.powerStatList) do
		if stat.stat == name then
			return stat
		end
	end
end
BestItemFinderClass.StatByName = statByName

-- Returns the slot names that are currently in use for this build
function BestItemFinderClass:GetActiveSlots()
	local itemsTab = self.itemsTab
	local useSwap = itemsTab.activeItemSet and itemsTab.activeItemSet.useSecondWeaponSet
	local list = { }
	for _, baseName in ipairs(self.gearSlots) do
		local slotName = baseName
		if baseName:match("^Weapon") and useSwap then
			slotName = baseName .. " Swap"
		end
		local slot = itemsTab.slots[slotName]
		if slot and not slot.inactive and slot:IsShown() then
			t_insert(list, slotName)
		end
	end
	return list
end

function BestItemFinderClass:IsItemAllowed(item, opts)
	if opts.obtainableOnly then
		local source = item.source or ""
		if source == "No longer obtainable" or (item.league and item.league == "Race Events") then
			return false
		end
	end
	if opts.levelOnly and item.requirements and item.requirements.level and item.requirements.level > self.build.characterLevel then
		return false
	end
	return true
end

-- Checks the constraints that compare the candidate's output to the current build
local function passesConstraints(output, baseOutput, opts)
	if opts.keepResists then
		for _, elem in ipairs(elements) do
			local key = "Missing" .. elem .. "Resist"
			if (output[key] or 0) > (baseOutput[key] or 0) then
				return false
			end
		end
	end
	if opts.keepAttributes then
		for _, attr in ipairs(attributes) do
			local newMissing = (output["Req" .. attr] or 0) - (output[attr] or 0)
			local oldMissing = (baseOutput["Req" .. attr] or 0) - (baseOutput[attr] or 0)
			if newMissing > 0 and newMissing > oldMissing then
				return false
			end
		end
	end
	if opts.keepSkillUsable then
		local function dps(out)
			return (out.CombinedDPS or 0) + (out.Minion and out.Minion.CombinedDPS or 0)
		end
		if dps(baseOutput) > 0 and dps(output) <= 0 then
			return false
		end
	end
	return true
end
BestItemFinderClass.PassesConstraints = passesConstraints

-- Runs the search. Returns { stat = <stat>, base = <number>, slots = { [slotName] = { current = <name>, results = { ... } } }, order = { slotName... } }
-- Each result: { slotName, item, power, delta, deltaPct }
function BestItemFinderClass:Run(options)
	local opts = self:DefaultOptions()
	for k, v in pairs(options or { }) do
		opts[k] = v
	end
	local stat = opts.stat or statByName("FullDPS")
	local useFullDPS = stat.stat == "FullDPS"
	local itemsTab = self.itemsTab
	local calcFunc = self.build.calcsTab:GetMiscCalculator()

	local baseOutput = calcFunc({ }, useFullDPS)
	local basePower = data.powerStatList.GetFromOutput(baseOutput, stat)

	local slotNames = opts.slots or self:GetActiveSlots()

	-- Collect candidate items once
	local candidates = { }
	for _, item in pairs(main.uniqueDB.list) do
		if self:IsItemAllowed(item, opts) then
			t_insert(candidates, item)
		end
	end
	t_sort(candidates, function(a, b) return a.name < b.name end)

	-- Count work for progress reporting
	local total = 0
	local work = { }
	for _, slotName in ipairs(slotNames) do
		local list = { }
		for _, item in ipairs(candidates) do
			if itemsTab:IsItemValidForSlot(item, slotName) then
				t_insert(list, item)
			end
		end
		work[slotName] = list
		total = total + #list
	end

	local report = { stat = stat, base = basePower, slots = { }, order = slotNames, options = opts }
	local done = 0
	local lastYield = GetTime()
	for _, slotName in ipairs(slotNames) do
		local slot = itemsTab.slots[slotName]
		local current = slot and itemsTab.items[slot.selItemId]
		local results = { }
		for _, item in ipairs(work[slotName]) do
			if not (current and current.name == item.name) then
				local output = calcFunc({ repSlotName = slotName, repItem = item }, useFullDPS)
				local power = data.powerStatList.GetFromOutput(output, stat)
				local delta = power - basePower
				if delta > 0 and passesConstraints(output, baseOutput, opts) then
					t_insert(results, {
						slotName = slotName,
						item = item,
						power = power,
						delta = delta,
						deltaPct = basePower ~= 0 and delta / m_abs(basePower) * 100 or nil,
					})
				end
			end
			done = done + 1
			if opts.yieldEvery and GetTime() - lastYield > opts.yieldEvery then
				if opts.onProgress then
					opts.onProgress(done, total)
				end
				coroutine.yield()
				lastYield = GetTime()
			end
		end
		t_sort(results, function(a, b) return a.delta > b.delta end)
		for i = #results, opts.topN + 1, -1 do
			results[i] = nil
		end
		report.slots[slotName] = { current = current and current.name or nil, results = results }
	end
	if opts.onProgress then
		opts.onProgress(total, total)
	end
	return report
end

-- Adds a copy of the database item to the build and equips it in the given slot
function BestItemFinderClass:Equip(item, slotName, deferUpdate)
	local itemsTab = self.itemsTab
	local newItem = new("Item"):Item(item.raw)
	newItem:NormaliseQuality()
	itemsTab:AddItem(newItem, true)
	itemsTab.slots[slotName]:SetSelItemId(newItem.id)
	itemsTab:AddForbiddenJewelCounterpart(newItem)
	if not deferUpdate then
		itemsTab:PopulateSlots()
		itemsTab:AddUndoState()
		self.build.buildFlag = true
	end
	return newItem
end

-- Recalculates the build right away so the next check sees the changes
function BestItemFinderClass:Recalculate()
	wipeGlobalCache()
	self.build.outputRevision = self.build.outputRevision + 1
	self.build.buildFlag = false
	self.build.skillsTab:UpdateSocketGroups()
	self.build.calcsTab:BuildOutput()
end

-- Equips the best result of every slot, one slot at a time. After each swap the
-- build is recalculated, and the swap is undone if the combination no longer
-- improves the stat or breaks a constraint (e.g. two items that each kept
-- resists capped on their own, but not together). Then the next result is tried.
function BestItemFinderClass:EquipAll(report)
	if not report then
		return 0
	end
	local itemsTab = self.itemsTab
	local opts = report.options or self:DefaultOptions()
	local stat = report.stat
	local useFullDPS = stat.stat == "FullDPS"
	local calcFunc = self.build.calcsTab:GetMiscCalculator()
	local originalOutput = calcFunc({ }, useFullDPS)
	local currentPower = data.powerStatList.GetFromOutput(originalOutput, stat)
	local used = { }
	local count = 0
	for _, slotName in ipairs(report.order) do
		local slotReport = report.slots[slotName]
		local slot = itemsTab.slots[slotName]
		if slotReport and slot then
			for _, result in ipairs(slotReport.results) do
				if not used[result.item.name] then
					local previousId = slot.selItemId
					local newItem = self:Equip(result.item, slotName, true)
					self:Recalculate()
					calcFunc = self.build.calcsTab:GetMiscCalculator()
					local output = calcFunc({ }, useFullDPS)
					local power = data.powerStatList.GetFromOutput(output, stat)
					if power > currentPower and passesConstraints(output, originalOutput, opts) then
						used[result.item.name] = true
						currentPower = power
						count = count + 1
						break
					end
					-- Undo this swap and try the next result for the slot
					slot:SetSelItemId(previousId)
					itemsTab:DeleteItem(newItem, true)
					self:Recalculate()
				end
			end
		end
	end
	itemsTab:PopulateSlots()
	if count > 0 then
		itemsTab:AddUndoState()
	end
	self.build.buildFlag = true
	return count, currentPower
end

-- Formats a result's gain for display
function BestItemFinderClass.FormatGain(result)
	local str = "+" .. formatNumSep(string.format("%.1f", result.delta))
	if result.deltaPct then
		str = str .. string.format(" (+%.1f%%)", result.deltaPct)
	end
	return str
end
