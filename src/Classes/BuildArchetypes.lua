-- Path of Building
--
-- Class: Build Archetypes
-- The main ways a skill can scale its damage and defences: critical strikes,
-- non-crit keystones, Chaos Inoculation, mana / attribute stacking, conversion,
-- mines / traps / totems... Each archetype is a set of things the build
-- generator commits to before optimising everything else around them:
--   keystones   allocated first and never refunded
--   supports    linked to the main skill (when they can support it)
--   playstyle   "mine" / "trap" / "totem": one support of that kind is linked;
--               without it, those supports are left out entirely
--   uniques     tried in every slot they fit; the best ones are equipped and
--               their slots kept (rares are generated for the other slots)
--   uniqueLines unique items with a mod line matching one of these patterns
--               (e.g. "per 10 Intelligence") are added to the candidates
--   jewels      unique jewels socketed if they help
-- The generator's archetype scan builds every archetype that fits the skill
-- quickly, so the player can compare them and pick one for the full build.
--
local t_insert = table.insert
local t_sort = table.sort

---@class BuildArchetypes
local BuildArchetypesClass = newClass("BuildArchetypes")

function BuildArchetypesClass:BuildArchetypes()
	return self
end

-- Facts about the main skill the archetypes check
local function skillInfo(gem)
	local effect = gem.grantedEffect
	local types = effect.skillTypes or { }
	local tags = gem.tags or { }
	local info = {
		gem = gem,
		types = types,
		tags = tags,
		spell = types[SkillType.Spell] and true or false,
		attack = types[SkillType.Attack] and true or false,
		minion = (types[SkillType.Minion] or tags.minion) and true or false,
		hits = (types[SkillType.Damage] or types[SkillType.Attack]) and true or false,
		elemental = (tags.fire or tags.cold or tags.lightning) and true or false,
		physical = tags.physical and true or false,
		weaponTypes = effect.weaponTypes,
	}
	return info
end
BuildArchetypesClass.SkillInfo = skillInfo

-- Can this support gem support that active skill gem (by skill types)?
function BuildArchetypesClass.CanSupport(supportGem, activeGem)
	local se, ae = supportGem.grantedEffect, activeGem.grantedEffect
	if not se or not ae or se.unsupported or ae.cannotBeSupported then return false end
	local types = ae.skillTypes or { }
	if se.requireSkillTypes and #se.requireSkillTypes > 0 and not calcLib.doesTypeExpressionMatch(se.requireSkillTypes, types) then
		return false
	end
	if se.excludeSkillTypes and #se.excludeSkillTypes > 0 and calcLib.doesTypeExpressionMatch(se.excludeSkillTypes, types) then
		return false
	end
	return true
end

-- Playstyle of a support gem: "mine", "trap", "totem" or nil
function BuildArchetypesClass.SupportPlaystyle(gem)
	local tags = gem.tags or { }
	if tags.mine and tags.trap then return "mine_or_trap" end
	if tags.mine then return "mine" end
	if tags.trap then return "trap" end
	if tags.totem then return "totem" end
	return nil
end

-- Is a support allowed for this playstyle (nil = self-cast / self-attack)?
function BuildArchetypesClass.PlaystyleAllows(gem, playstyle)
	local kind = BuildArchetypesClass.SupportPlaystyle(gem)
	if not kind then return true end
	if not playstyle then return false end
	if kind == "mine_or_trap" then return playstyle == "mine" or playstyle == "trap" end
	return kind == playstyle
end

-- A support gem by name (nil if missing)
local function gemByName(name)
	for _, gem in pairs(data.gems) do
		if gem.name == name and gem.grantedEffect then return gem end
	end
end

-- Some support of a playstyle can support the skill
local function playstylePossible(info, playstyle)
	for _, gem in pairs(data.gems) do
		local kind = BuildArchetypesClass.SupportPlaystyle(gem)
		if gem.grantedEffect and gem.grantedEffect.support and kind == playstyle and not gem.tags.exceptional
			and BuildArchetypesClass.CanSupport(gem, info.gem) then
			return true
		end
	end
	return false
end

BuildArchetypesClass.list = {
	{
		id = "STANDARD", label = "Standard: life, self-cast / self-attack",
		summary = "No commitment: the generator picks what scores best (no mines, traps or totems).",
		applies = function() return true end,
	},
	{
		id = "CRIT", label = "Critical strikes",
		summary = "Crit chance and multiplier supports linked; tree and gear follow.",
		supports = { "Increased Critical Strikes", "Increased Critical Damage" },
		excludeKeystones = { "Elemental Overload", "Resolute Technique" },
		applies = function(info) return info.hits and not info.minion end,
	},
	{
		id = "EO", label = "Non-crit: Elemental Overload",
		summary = "Elemental Overload: 40% more elemental damage after a crit, no crit multiplier needed.",
		keystones = { "Elemental Overload" },
		excludeKeystones = { "Resolute Technique" },
		applies = function(info) return info.hits and info.elemental and not info.minion end,
	},
	{
		id = "RT", label = "Non-crit attacks: Resolute Technique",
		summary = "Resolute Technique: attacks always hit, never crit; scale flat and increased damage.",
		keystones = { "Resolute Technique" },
		applies = function(info) return info.attack end,
	},
	{
		id = "CI", label = "Energy shield + Chaos Inoculation",
		lens = { stat = "EnergyShield", base = 1000, label = "Energy shield" },
		summary = "Chaos Inoculation: immune to chaos damage, life is 1, energy shield is the hit pool.",
		keystones = { "Chaos Inoculation" },
		applies = function(info) return not info.minion end,
	},
	{
		id = "MANA", label = "Mana stacking (Mind over Matter, Indigon, Archmage)",
		lens = { stat = "Mana", base = 1000, label = "Maximum mana" },
		summary = "Huge mana pool: Mind over Matter for defence; damage from mana spent / Archmage on spells.",
		keystones = { "Mind Over Matter" },
		supports = { "Archmage" },
		uniques = { "Indigon", "Atziri's Foible", "Cane of Kulemak" },
		-- (only damage that scales with the mana pool / mana spent: "increased maximum Mana"
		-- alone is on too many unrelated uniques)
		uniqueLines = { "per %d+ [Mm]aximum Mana", "per %d+ Mana", "Mana Spent Recently", "Damage per %d+ Mana" },
		jewels = { "Healthy Mind" },
		applies = function(info) return not info.minion end,
	},
	{
		id = "INT", label = "Intelligence stacking (Shaper's Touch, Split Personality)",
		lens = { stat = "Int", base = 100, label = "Intelligence" },
		summary = "Stack Intelligence: uniques that scale damage, accuracy, evasion or energy shield per Intelligence.",
		uniques = { "Shaper's Touch", "Astramentis" },
		uniqueLines = { "per %d* ?Intelligence", "%d+%% increased Intelligence" },
		jewels = { "Split Personality" }, jewelStat = "Intelligence",
		applies = function(info) return not info.minion end,
	},
	{
		id = "STR", label = "Strength stacking",
		lens = { stat = "Str", base = 100, label = "Strength" },
		summary = "Stack Strength: uniques that scale with Strength (Iron Will for spells).",
		uniqueLines = { "per %d* ?Strength", "%d+%% increased Strength" },
		keystonesIf = function(info) return info.spell and { "Iron Will" } or nil end,
		jewels = { "Split Personality" }, jewelStat = "Strength",
		applies = function(info) return not info.minion end,
	},
	{
		id = "DEX", label = "Dexterity stacking",
		lens = { stat = "Dex", base = 100, label = "Dexterity" },
		summary = "Stack Dexterity: uniques that scale with Dexterity.",
		uniqueLines = { "per %d* ?Dexterity", "%d+%% increased Dexterity" },
		jewels = { "Split Personality" }, jewelStat = "Dexterity",
		applies = function(info) return not info.minion end,
	},
	{
		id = "PHYS_ELE", label = "Physical weapon + damage as extra elemental (Hatred)",
		summary = "A high physical damage weapon; Hatred and \"gain % of physical as extra\" add elemental damage on top of it.",
		auras = { "Hatred" },
		applies = function(info) return info.attack and info.weaponTypes ~= nil and not info.minion end,
	},
	{
		-- (what top melee players run: Pride, Brutality, impale from the tree or the Impale support)
		id = "IMPALE", label = "Pure physical: Pride, Brutality, impale",
		summary = "Physical damage only: Pride and Brutality (no elemental or chaos damage), impales stacking on the target.",
		auras = { "Pride" },
		supports = { "Brutality" },
		excludeKeystones = { "Elemental Overload", "Avatar of Fire" },
		applies = function(info) return info.attack and info.weaponTypes ~= nil and not info.elemental and not info.minion end,
	},
	{
		-- (what top Righteous Fire players run: a huge life pool that the
		-- skill and its uniques turn into damage)
		id = "LIFE", label = "Life stacking (Kaom's Heart, life scaling uniques)",
		lens = { stat = "Life", base = 1000, label = "Maximum life" },
		summary = "A huge life pool: Kaom's Heart (the main skill moves to a 4-link) and uniques that turn life into damage.",
		uniques = { "Kaom's Heart" },
		uniqueLines = { "per %d+ Player Maximum Life", "per %d+ Maximum Life" },
		applies = function(info) return not info.minion end,
	},
	{
		id = "AURAS", label = "Aura stacking (reservation efficiency, many auras)",
		summary = "As many auras as reservation efficiency allows: the tree and gear pay for them.",
		maxAuras = 7,
		applies = function(info) return not info.minion end,
	},
	{
		id = "FIRE_CONV", label = "Conversion to fire (Avatar of Fire)",
		summary = "Avatar of Fire converts physical, lightning and cold damage to fire: scale fire only.",
		keystones = { "Avatar of Fire" },
		excludeKeystones = { "Roiling Tempest" },
		applies = function(info) return info.hits and (info.physical or info.tags.lightning or info.tags.cold) and not info.minion end,
	},
	{
		id = "MINES", label = "Mines", playstyle = "mine",
		summary = "The skill is thrown as mines (detonated together): mine supports and mine passives.",
		applies = function(info) return not info.minion and playstylePossible(info, "mine") end,
	},
	{
		id = "TRAPS", label = "Traps", playstyle = "trap",
		summary = "The skill is thrown as traps: trap supports and trap passives.",
		applies = function(info) return not info.minion and playstylePossible(info, "trap") end,
	},
	{
		id = "TOTEMS", label = "Totems / ballistas", playstyle = "totem",
		summary = "Totems (or ballistas for bows) use the skill: safer, totem passives.",
		applies = function(info) return not info.minion and playstylePossible(info, "totem") end,
	},
}

-- Archetypes that fit a skill gem, with poe.ninja usage when known
-- (share of players with the archetype's keystone)
function BuildArchetypesClass.ForSkill(gem, meta)
	local info = skillInfo(gem)
	local keystoneShare = { }
	for _, k in ipairs(meta and meta.keystones or { }) do keystoneShare[k.name] = k.share end
	local list = { }
	for _, a in ipairs(BuildArchetypesClass.list) do
		if a.applies(info) then
			local copy = { }
			for k, v in pairs(a) do copy[k] = v end
			copy.keystones = { }
			for _, k in ipairs(a.keystones or { }) do t_insert(copy.keystones, k) end
			for _, k in ipairs(a.keystonesIf and a.keystonesIf(info) or { }) do t_insert(copy.keystones, k) end
			local share
			for _, k in ipairs(copy.keystones) do
				if keystoneShare[k] then share = math.max(share or 0, keystoneShare[k]) end
			end
			copy.metaShare = share
			t_insert(list, copy)
		end
	end
	return list
end

-- Unique items (not jewels or flasks) an archetype tries: its named uniques,
-- plus those with a mod line matching its patterns (current variant)
function BuildArchetypesClass.UniqueCandidates(archetype)
	local list, seen = { }, { }
	local function add(item)
		local title = item.title or item.name
		if not seen[title] and item.type ~= "Jewel" and item.type ~= "Flask" and not (item.title or ""):match("^Replica Dragonfang") then
			seen[title] = true
			t_insert(list, item)
		end
	end
	local byTitle = { }
	for _, item in pairs(main.uniqueDB.list) do
		byTitle[item.title or item.name] = byTitle[item.title or item.name] or item
	end
	for _, name in ipairs(archetype.uniques or { }) do
		if byTitle[name] then add(byTitle[name]) end
	end
	if archetype.uniqueLines then
		local titles = { }
		for title in pairs(byTitle) do t_insert(titles, title) end
		t_sort(titles)
		for _, title in ipairs(titles) do
			local item = byTitle[title]
			for _, modLine in ipairs(item.explicitModLines or { }) do
				local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
				if current and modLine.line then
					local match = false
					for _, pattern in ipairs(archetype.uniqueLines) do
						if modLine.line:match(pattern) then match = true break end
					end
					if match then add(item) break end
				end
			end
		end
	end
	return list
end

-- A tree node by name (keystones)
function BuildArchetypesClass.NodeByName(spec, name)
	for _, node in pairs(spec.nodes) do
		if node.dn == name and not node.ascendancyName then return node end
	end
end

BuildArchetypesClass.GemByName = gemByName
