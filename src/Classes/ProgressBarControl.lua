-- Path of Building
--
-- Class: Progress Bar Control
-- A thin bar filled to a fraction (0 to 1), e.g. how far a build generation is.
-- Hidden while the fraction is nil.
--
---@class ProgressBarControl: Control
local ProgressBarClass = newClass("ProgressBarControl", "Control")

---@param anchor? Anchor
---@param rect? Rect
---@param fraction Prop<number|nil>
function ProgressBarClass:ProgressBarControl(anchor, rect, fraction)
	self:Control(anchor, rect)
	self.fraction = fraction
	return self
end

function ProgressBarClass:Draw()
	local fraction = self:GetProperty("fraction")
	if not fraction then return end
	fraction = math.max(0, math.min(1, fraction))
	local x, y = self:GetPos()
	local width, height = self:GetSize()
	SetDrawColor(0.5, 0.5, 0.5)
	DrawImage(nil, x, y, width, height)
	SetDrawColor(0.05, 0.05, 0.05)
	DrawImage(nil, x + 1, y + 1, width - 2, height - 2)
	if fraction > 0 then
		SetDrawColor(0.85, 0.6, 0.15)
		DrawImage(nil, x + 1, y + 1, math.floor((width - 2) * fraction + 0.5), height - 2)
	end
	SetDrawColor(1, 1, 1)
end
