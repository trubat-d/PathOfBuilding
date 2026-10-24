-- Path of Building
--
-- Class: Build Idea List
-- Lists the ideas found by the synergy finder.
--
local t_insert = table.insert

---@class BuildIdeaListControl: ListControl
local BuildIdeaListClass = newClass("BuildIdeaListControl", "ListControl")

local kindColors = {
	["Synergy"] = "^xFFCC44",
	["Removes a downside"] = "^x66CCFF",
	["Single change"] = "^7",
	["Tattoo set"] = "^xC0A0FF",
}

function BuildIdeaListClass:BuildIdeaListControl(anchor, rect, onSelect, onApply)
	self:ListControl(anchor, rect, 18, "VERTICAL", false)
	self.onSelect = onSelect
	self.onApply = onApply
	local width = rect[3]
	self.colList = {
		{ width = width * 0.16, label = "Kind" },
		{ width = width * 0.52, label = "Idea" },
		{ width = width * 0.11, label = "DPS" },
		{ width = width * 0.11, label = "EHP" },
		{ width = width * 0.10, label = "Points" },
	}
	self.colLabels = true
	self.defaultText = "^7Press \"Find ideas\" to look for synergies on this build."
	return self
end

local function pct(value)
	local color = value > 0.05 and colorCodes.POSITIVE or value < -0.05 and colorCodes.NEGATIVE or "^7"
	return string.format("%s%+.1f%%", color, value)
end

function BuildIdeaListClass:GetRowValue(column, index, idea)
	if column == 1 then
		return (kindColors[idea.kind] or "^7") .. idea.kind
	elseif column == 2 then
		return "^7" .. idea.title
	elseif column == 3 then
		return pct(idea.dpsPct)
	elseif column == 4 then
		return pct(idea.ehpPct)
	elseif column == 5 then
		return idea.points and idea.points > 0 and tostring(idea.points) or "-"
	end
	return ""
end

function BuildIdeaListClass:OnSelect(index, idea)
	if self.onSelect then
		self.onSelect(idea)
	end
end

function BuildIdeaListClass:OnSelClick(index, idea, doubleClick)
	if self.onSelect then
		self.onSelect(idea)
	end
	if doubleClick and self.onApply then
		self.onApply(idea)
	end
end
