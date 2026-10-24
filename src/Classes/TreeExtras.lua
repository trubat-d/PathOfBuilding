-- Path of Building
--
-- Class: Tree Extras
-- Anoints and tattoos for the build ideas finder and the build generator.
--   * anoint: an amulet enchant "Allocates <notable>"; notables with an oil
--     recipe can be anointed. Priced from the three oils.
--   * tattoo: replaces an allocated passive. Small tattoos replace small
--     Strength / Dexterity / Intelligence passives of their attribute, keystone
--     tattoos replace a keystone, runegrafts replace a mastery.
--     Limits: one keystone tattoo, one of each runegraft.
-- Tested with the calculator as "remove the passive, add a temporary passive
-- carrying the tattoo's modifiers".
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove

---@class TreeExtras
local TreeExtrasClass = newClass("TreeExtras")

function TreeExtrasClass:TreeExtras(build)
	self.build = build
	self.nextId = -8000000
	return self
end

------------------------------------------------------------------------------
-- Anoints
------------------------------------------------------------------------------

-- Copy of an amulet with its anoint replaced by this notable (keep: added
-- to its anoints instead, for amulets with several, like Stranglegasp)
function TreeExtrasClass:AnointedCopy(amulet, node, keep)
	local item = new("Item"):Item(amulet:BuildRaw())
	if not keep then
		for i = #item.enchantModLines, 1, -1 do
			if item.enchantModLines[i].line:match("^Allocates ") then
				t_remove(item.enchantModLines, i)
			end
		end
	end
	t_insert(item.enchantModLines, 1, { crafted = true, line = "Allocates " .. node.dn })
	item:BuildAndParseRaw()
	return item
end

-- How many anoints an amulet takes ("Can have 3 additional Enchantment Modifiers": 4)
function TreeExtrasClass.AnointSlots(item)
	local slots = 1
	for _, modLine in ipairs(item and item.explicitModLines or { }) do
		local extra = modLine.line and tonumber(modLine.line:match("^Can have (%d+) additional Enchantment Modifiers"))
		if extra then slots = slots + extra end
	end
	return slots
end

function TreeExtrasClass:CanAnoint(item)
	return item and item.base and item.base.type == "Amulet" and not item.base.cannotBeAnointed and item.base.subType ~= "Talisman"
end

-- Anointable notables within the investment level, not already allocated
function TreeExtrasClass:AnointCandidates(investment)
	local prices = GetPriceSource()
	local list = { }
	local seen = { }
	for _, node in pairs(self.build.spec.tree.nodes) do
		if node.recipe and #node.recipe >= 1 and not node.alloc and not seen[node.dn] and not node.ascendancyName then
			seen[node.dn] = true
			local price = prices:AnointPrice(node)
			if prices:Allows(investment, "anoint", price) then
				t_insert(list, { node = node, price = price })
			end
		end
	end
	table.sort(list, function(a, b) return a.node.dn < b.node.dn end)
	return list
end

------------------------------------------------------------------------------
-- Tattoos
------------------------------------------------------------------------------

local attributeOf = { ["Strength"] = "Small Strength", ["Dexterity"] = "Small Dexterity", ["Intelligence"] = "Small Intelligence" }

-- Which tattoo target an allocated node is: "Small Strength", "Keystone", "Mastery" or nil
function TreeExtrasClass:TargetType(node)
	local spec = self.build.spec
	local original = spec.tree.nodes[node.id]
	if not original or spec.hashOverrides[node.id] or node.ascendancyName then
		return nil -- already tattooed, or not a tree node
	end
	if original.type == "Keystone" then
		return "Keystone"
	elseif original.type == "Mastery" then
		return "Mastery"
	elseif original.type == "Normal" and attributeOf[original.dn] then
		return attributeOf[original.dn]
	end
	return nil
end

-- Allocated nodes that can take a tattoo, by target type
function TreeExtrasClass:TattooTargets()
	local targets = { }
	for _, node in pairs(self.build.spec.allocNodes) do
		local targetType = self:TargetType(node)
		if targetType then
			targets[targetType] = targets[targetType] or { }
			t_insert(targets[targetType], node)
		end
	end
	for _, list in pairs(targets) do
		table.sort(list, function(a, b) return a.id < b.id end)
	end
	return targets
end

local function fitsTarget(tattoo, targetType)
	if tattoo.legacy then return false end
	if tattoo.targetType == targetType then return true end
	if tattoo.targetType == "Small Attribute" and targetType:match("^Small ") then return true end
	return false
end

-- Tattoo options within the investment level: { tattoo, targetType, price, limitKey }
function TreeExtrasClass:TattooOptions(investment)
	local prices = GetPriceSource()
	local list = { }
	for name, tattoo in pairs(self.build.spec.tree.tattoo.nodes) do
		if name ~= "" and not tattoo.legacy and (tattoo.modList and #tattoo.modList > 0 or tattoo.keystoneMod) then
			for _, targetType in ipairs({ "Small Strength", "Small Dexterity", "Small Intelligence", "Keystone", "Mastery" }) do
				if fitsTarget(tattoo, targetType) then
					local price = prices:TattooPrice(name)
					if prices:Allows(investment, "tattoo", price) then
						local limitKey
						if tattoo.overrideType == "KeystoneTattoo" then
							limitKey = "KeystoneTattoo"
						elseif tattoo.overrideType == "AlternateMastery" then
							limitKey = name
						end
						t_insert(list, { name = name, tattoo = tattoo, targetType = targetType, price = price, limitKey = limitKey })
					end
				end
			end
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

-- Temporary node carrying a tattoo's modifiers, for calculator overrides
function TreeExtrasClass:VirtualTattoo(tattoo)
	self.nextId = self.nextId - 1
	local nodeType = tattoo.type
	if nodeType == "Mastery" then nodeType = "Normal" end
	if nodeType == "Keystone" and not tattoo.keystoneMod then nodeType = "Normal" end
	return { id = self.nextId, type = nodeType, dn = tattoo.dn, modList = tattoo.modList or new("ModList"):ModList(), keystoneMod = tattoo.keystoneMod, modKey = "tattoo" .. self.nextId, sd = tattoo.sd or { } }
end

-- Tattoos a node for real (same as the Tree tab's "Modify node")
function TreeExtrasClass:ApplyTattoo(node, tattooName)
	local spec = self.build.spec
	local tattoo = copyTable(spec.tree.tattoo.nodes[tattooName], true)
	tattoo.id = node.id
	spec.hashOverrides[node.id] = tattoo
	spec:ReplaceNode(node, tattoo)
	if node.type == "Mastery" then
		node.allMasteryOptions = false
	end
	spec:BuildAllDependsAndPaths()
end
