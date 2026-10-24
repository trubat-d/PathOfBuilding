-- Path of Building
--
-- Class: Best Item List
-- Shows the results of the best item search: slot, item and stat gain.
--
local t_insert = table.insert

---@class BestItemListControl: ListControl
local BestItemListClass = newClass("BestItemListControl", "ListControl")

function BestItemListClass:BestItemListControl(anchor, rect, itemsTab, finder, onEquip)
	self:ListControl(anchor, rect, 18, "VERTICAL", false)
	self.itemsTab = itemsTab
	self.finder = finder
	self.onEquip = onEquip
	local width = rect[3]
	self.gainColumn = { width = width * 0.27, label = "Gain" }
	self.colList = {
		{ width = width * 0.18, label = "Slot" },
		{ width = width * 0.53, label = "Item" },
		self.gainColumn,
	}
	self.colLabels = true
	self.defaultText = "^7Press \"Search\" to find the best uniques for each slot."
	return self
end

-- Fills the list from a BestItemFinder report
function BestItemListClass:SetReport(report)
	self.list = { }
	self.report = report
	if not report then
		return
	end
	self.gainColumn.label = report.stat.label .. " gain"
	for _, slotName in ipairs(report.order) do
		local slotReport = report.slots[slotName]
		for rank, result in ipairs(slotReport.results) do
			result.rank = rank
			t_insert(self.list, result)
		end
	end
	if #self.list == 0 then
		self.defaultText = "^7No unique found that improves " .. report.stat.label .. " with these filters."
	end
	self.selIndex = nil
	self.selValue = nil
end

function BestItemListClass:GetRowValue(column, index, result)
	if column == 1 then
		return result.rank == 1 and ("^7" .. result.slotName) or "^8" .. result.slotName
	elseif column == 2 then
		if result.generated then
			local influence = result.influences and #result.influences > 0 and (" ^xA0A0FF" .. self.finder.rareGenerator.InfluenceLabel(result.influences)) or ""
			return colorCodes.RARE .. "Rare " .. result.item.baseName .. influence .. " ^8(" .. #result.chosen .. " mods)"
		end
		return colorCodes.UNIQUE .. result.item.name
	elseif column == 3 then
		return colorCodes.POSITIVE .. self.finder.FormatGain(result)
	end
	return ""
end

function BestItemListClass:AddValueTooltip(tooltip, index, result)
	if tooltip:CheckForUpdate(result, self.itemsTab.build.outputRevision) then
		self.itemsTab:AddItemTooltip(tooltip, result.item, nil, true)
		if result.modScores and #result.modScores > 0 then
			-- Mod priority list: what to look for when crafting or trading
			tooltip:AddSeparator(10)
			tooltip:AddLine(16, "^7Best mods for this slot on their own (" .. self.report.stat.label .. "):")
			for i = 1, math.min(10, #result.modScores) do
				local score = result.modScores[i]
				tooltip:AddLine(14, string.format("^8%d. %s%s ^8%s  %s+%s", i, score.type == "Prefix" and "^x8888FF" or "^xFFCC77", score.label, score.type, colorCodes.POSITIVE, formatNumSep(string.format("%.1f", score.gain))))
			end
			tooltip:AddLine(14, "^8Blue = prefix, yellow = suffix. An item can have at most 3 of each.")
		end
	end
end

function BestItemListClass:OnSelClick(index, result, doubleClick)
	if doubleClick and self.onEquip then
		self.onEquip(result)
	end
end
