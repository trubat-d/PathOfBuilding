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
	self.rareGenerator = new("RareItemGenerator"):RareItemGenerator(self)
	self.rareQualityList = self.rareGenerator.qualityList
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
		keepLife = true,        -- reject items that lower maximum life or energy shield
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

-- The current versions of a unique with several (Ralakesh's Impatience:
-- endurance, frenzy or power; a jewel's different modifiers...): one copy per
-- variant, legacy ones ("Pre 3.19.0") left out. Uniques with very many
-- variants (Pearl of Tsoatha's hundreds of supports) keep their default one.
function BestItemFinderClass.CurrentVariants(item, maxVariants)
	local list = { }
	if not item.variantList or #item.variantList < 2 or item.hasAltVariant then return { item } end
	local current = { }
	for index, name in ipairs(item.variantList) do
		if not name:match("^Pre ") and not name:match("%(Pre ") and not name:match("Legacy") then t_insert(current, index) end
	end
	if #current < 2 or #current > (maxVariants or 8) then return { item } end
	for _, index in ipairs(current) do
		local copy = new("Item"):Item(item:BuildRaw())
		copy.variant = index
		copy:BuildAndParseRaw()
		copy.variantLabel = item.variantList[index]
		t_insert(list, copy)
	end
	return list
end

function BestItemFinderClass:IsItemAllowed(item, opts)
	-- drawbacks PoB doesn't calculate (Modules/GeneratorRules)
	local rules = GetGeneratorRules()
	if item.rarity == "UNIQUE" or item.rarity == "RELIC" or not item.rarity then
		-- (charges the build counts as always at maximum: items that lose them are fine)
		local countsMax = opts.assumeMaxCharges
		if not countsMax then
			local env = self.build.calcsTab and self.build.calcsTab.mainEnv
			local modDB = env and env.player and env.player.modDB
			countsMax = modDB and {
				Power = modDB:Flag(nil, "HaveMaximumPowerCharges"),
				Frenzy = modDB:Flag(nil, "HaveMaximumFrenzyCharges"),
				Endurance = modDB:Flag(nil, "HaveMaximumEnduranceCharges"),
			} or nil
		end
		if not rules.UniqueAllowed(item, self.build.calcsTab and self.build.calcsTab.mainOutput, countsMax) then
			return false
		end
	end
	if opts.obtainableOnly then
		local source = item.source or ""
		if source == "No longer obtainable" or (item.league and item.league == "Race Events") then
			return false
		end
	end
	if opts.levelOnly and item.requirements and item.requirements.level and item.requirements.level > self.build.characterLevel then
		return false
	end
	if opts.investment then
		local prices = GetPriceSource()
		if not prices.Available(opts.investment, item.title or item.name) then
			return false
		end
		if not prices:Allows(opts.investment, "unique", prices:UniquePrice(item)) then
			return false
		end
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
	if opts.keepLife then
		for _, key in ipairs({ "Life", "EnergyShield" }) do
			if (output[key] or 0) < (baseOutput[key] or 0) - 0.5 then
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

-- Generates the best rare for every active slot, on the base of the item
-- currently in that slot. Same report format as Run.
function BestItemFinderClass:RunRares(options)
	local opts = self:DefaultOptions()
	for k, v in pairs(options or { }) do
		opts[k] = v
	end
	local stat = opts.stat or statByName("FullDPS")
	local useFullDPS = stat.stat == "FullDPS"
	local itemsTab = self.itemsTab
	local calcFunc = self.build.calcsTab:GetMiscCalculator()
	local baseOutput = calcFunc({ }, useFullDPS)
	local measure = opts.scoreFunc or function(output) return data.powerStatList.GetFromOutput(output, stat) end
	local basePower = measure(baseOutput)
	local generator = self.rareGenerator
	local slotNames = opts.slots or self:GetActiveSlots()

	local report = { stat = stat, base = basePower, slots = { }, order = slotNames, options = opts, rares = true }
	local lastYield = GetTime()
	local slotIndex = 0
	local ctx = {
		calcFunc = calcFunc,
		useFullDPS = useFullDPS,
		stat = stat,
		baseOutput = baseOutput,
		basePower = basePower,
		measure = measure,
		opts = opts,
		tick = function()
			if opts.yieldEvery and GetTime() - lastYield > opts.yieldEvery then
				if opts.onProgress then
					opts.onProgress(slotIndex - 1, #slotNames)
				end
				coroutine.yield()
				lastYield = GetTime()
			end
		end,
	}
	for _, slotName in ipairs(slotNames) do
		slotIndex = slotIndex + 1
		if opts.onSlot then opts.onSlot(slotIndex, #slotNames) end
		local slot = itemsTab.slots[slotName]
		local current = slot and itemsTab.items[slot.selItemId]
		local slotReport = { current = current and current.name or nil, results = { } }
		if not current then
			slotReport.note = "empty slot"
		elseif not generator:IsSupported(current) then
			slotReport.note = "not supported"
		else
			local result, scores = generator:GenerateForSlot(slotName, current, ctx)
			slotReport.modScores = scores
			if result then
				t_insert(slotReport.results, result)
			end
		end
		report.slots[slotName] = slotReport
	end
	if opts.onProgress then
		opts.onProgress(#slotNames, #slotNames)
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
	local measure = opts.scoreFunc or function(output) return data.powerStatList.GetFromOutput(output, stat) end
	local currentPower = measure(originalOutput)
	local used = { }
	local count = 0
	for _, slotName in ipairs(report.order) do
		local slotReport = report.slots[slotName]
		local slot = itemsTab.slots[slotName]
		if slotReport and slot then
			for _, result in ipairs(slotReport.results) do
				if result.generated or not used[result.item.name] then
					local previousId = slot.selItemId
					local newItem = self:Equip(result.item, slotName, true)
					self:Recalculate()
					calcFunc = self.build.calcsTab:GetMiscCalculator()
					local output = calcFunc({ }, useFullDPS)
					local power = measure(output)
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
