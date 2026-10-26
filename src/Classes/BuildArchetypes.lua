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

-- Can the skill be triggered by a trigger setup (a spell that isn't
-- channelled, reserving, a totem / trap / mine or a brand)?
local function triggerable(info)
	return info.spell and new("TriggerSetups"):TriggerSetups().Triggerable(info.gem)
end

BuildArchetypesClass.list = {
	{
		id = "STANDARD", label = "Standard: life, self-cast / self-attack",
		summary = "No commitment: the generator picks what scores best (no mines, traps or totems).",
		applies = function() return true end,
	},
	{
		id = "CRIT", label = "Critical strikes",
		summary = "Crit chance and multiplier built together; Elemental Overload and supports that lower crit chance left out; tree and gear follow.",
		-- (crit pays off only when chance and multiplier are both high: the
		-- crit damage factor counts on its own while the build is made, so
		-- neither is judged alone. Winter Orb: top players x7.9, ours x1)
		lens = { stat = "CritEffect", base = 1, label = "Crit damage factor" },
		-- (no forced crit supports: linked first, they pushed the main link's
		-- more multipliers out - x10.6 on top Winter Orbs, x2.3 on ours; the
		-- supports are chosen by the build's real score)
		blockSupports = { "Controlled Destruction", "Awakened Controlled Destruction" },
		excludeKeystones = { "Elemental Overload", "Resolute Technique" },
		applies = function(info) return info.hits and not info.minion end,
	},
	{
		-- (the enemy layer committed to: curse, exposure, penetration and damage
		-- taken valued while the build is made; top Winter Orbs reach x2.6)
		id = "ENEMY", label = "Enemy resistance and damage taken (curse, exposure, penetration, shock)",
		summary = "What the enemy lets through valued on its own: curses, exposure, penetration and damage taken sources are taken together.",
		lens = { func = function(o)
			local best = 0
			for _, t in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do best = math.max(best, o[t .. "EffMult"] or 0) end
			return best > 0 and best or 1
		end, base = 0.5, label = "Enemy damage multiplier", weight = 0.5 },
		applies = function(info) return info.hits and not info.minion end,
	},
	{
		id = "SPEED", label = "Attack / cast speed",
		summary = "Speed valued on its own: more hits per second from tree, gear, charges and buffs.",
		lens = { stat = "Speed", base = 1, label = "Speed", weight = 0.4 },
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
		-- (all three top Winter Orb players of the league: Malachai's Loop, Tulfall,
		-- Ralakesh's Impatience, Willclash)
		id = "POWER", label = "Power charge stacking (Malachai's Loop, Tulfall, Ralakesh's Impatience)",
		lens = { stat = "PowerChargesMax", base = 3, label = "Maximum power charges" },
		summary = "Many power charges kept at the maximum: damage per power charge (Malachai's Loop, Tulfall, Willclash), Ralakesh's Impatience to count as always having the maximum.",
		uniques = { "Malachai's Loop", "Ralakesh's Impatience", "Tulfall", "Willclash" },
		uniqueLines = { "per Power Charge", "[Mm]aximum Power Charges", "equal to your Maximum Power Charges", "maximum number of Power Charges" },
		applies = function(info) return info.spell and not info.minion end,
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
		-- (an attack scaled by spell damage: Crown of Eyes turns spell damage
		-- increases into attack ones at 150%, Iron Will turns strength into spell
		-- damage; rares then roll spell damage, cheaper than attack damage mods)
		id = "SPELL_ATTACK", label = "Strength into spell damage for an attack (Iron Will, Crown of Eyes)",
		lens = { stat = "Str", base = 100, label = "Strength" },
		summary = "Crown of Eyes applies spell damage increases to attacks at 150%, and Iron Will turns strength into spell damage: stack strength (and strength scaling mods) for a strength attack.",
		uniques = { "Crown of Eyes" },
		uniqueLines = { "per %d* ?Strength", "%d+%% increased Strength" },
		keystones = { "Iron Will" },
		jewels = { "Split Personality" }, jewelStat = "Strength",
		applies = function(info) return info.attack and not info.minion end,
	},
	{
		-- (heralds whose buffs add the skill's own damage type, kept up all the
		-- time; damage per herald and reservation from the tree and uniques)
		id = "HERALDS", label = "Herald stacking (The Coming Calamity, Alpha's Howl, damage per herald)",
		summary = "Several heralds up at once: their buffs add damage to the skill, and the tree and gear pay for them and scale with each herald.",
		auras = { },
		maxAuras = 6,
		uniques = { "The Coming Calamity", "Replica Alpha's Howl" },
		uniqueLines = { "for each Herald affecting you", "Herald Skills" },
		applies = function(info) return not info.minion and info.hits end,
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
	-- trigger setups (Classes/TriggerSetups): the spell triggered, not cast by hand
	{
		id = "CWC", label = "Cast while Channelling (spell triggered by a channelling skill)", trigger = "CWC",
		summary = "A channelling skill (Cyclone, Flameblast...) linked with Cast while Channelling triggers the spell several times a second.",
		applies = function(info) return not info.minion and triggerable(info) end,
	},
	{
		id = "COC", label = "Cast On Critical Strike (spell triggered by an attack's crits)", trigger = "COC",
		-- (the build commits to critical strikes: the triggers come from them)
		lens = { stat = "CritChance", base = 20, label = "Critical strike chance" },
		summary = "An attack (Cyclone, Ice Shot, Lacerate...) linked with Cast On Critical Strike triggers the spell when it crits: crit chance and attack speed.",
		applies = function(info) return not info.minion and triggerable(info) end,
	},
	{
		id = "ARCANIST", label = "Arcanist Brand (spell triggered by a brand)", trigger = "ARCANIST",
		summary = "The spell linked to Arcanist Brand, triggered each time the brand activates on the enemy.",
		applies = function(info) return not info.minion and triggerable(info) end,
	},
	{
		id = "SPELLSLINGER", label = "Spellslinger (spell triggered by wand attacks)", trigger = "SPELLSLINGER",
		summary = "The spell linked to Spellslinger (mana reserved), triggered by the wand attacks fired from another link.",
		applies = function(info) return not info.minion and triggerable(info) end,
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
	-- the skill's top players' archetype (bench/mine_archetypes.py,
	-- Data/GeneratorPlayerArchetypes.json): one more candidate, built and
	-- compared like the others
	-- (playerKnowledge false: built from the game's math and the generator's
	-- own knowledge only, nothing from top players)
	local players = BuildArchetypesClass.playerKnowledge ~= false and BuildArchetypesClass.PlayersArchetype(gem)
	if players then t_insert(list, players) end
	-- ideas found in the game data (Classes/IdeaMiner): stats that uniques scale with
	if BuildArchetypesClass.minedIdeas ~= false then
		local ok, mined = pcall(function() return new("IdeaMiner"):IdeaMiner().Ideas(info) end)
		if ok then
			for _, idea in ipairs(mined) do t_insert(list, idea) end
		else
			ConPrintf("Idea miner failed: %s", tostring(mined))
		end
	end
	return list
end

-- Player knowledge on or off for the archetypes offered (the generator's
-- options.playerKnowledge)
function BuildArchetypesClass.SetPlayerKnowledge(on)
	BuildArchetypesClass.playerKnowledge = on
end

-- The archetype most top players of a skill share (keystones, gear uniques,
-- main link supports, from their PoB codes): nil when none was mined for it.
-- Its stat lens follows what those choices stack: energy shield with Chaos
-- Inoculation, life with Blood Magic or Kaom's Heart; crit supports add the
-- crit damage factor as a second lens (chance and multiplier pay off together)
local playersData
function BuildArchetypesClass.PlayersArchetype(gem)
	if not gem then return nil end
	if playersData == nil then
		playersData = false
		local dkjson = require "dkjson"
		for _, path in ipairs({ (GetScriptPath and GetScriptPath() or ".") .. "/Data/GeneratorPlayerArchetypes.json", "Data/GeneratorPlayerArchetypes.json" }) do
			local f = io.open(path, "r")
			if f then
				local ok, value = pcall(dkjson.decode, f:read("*a"))
				f:close()
				if ok and type(value) == "table" and value.skills then playersData = value.skills break end
			end
		end
	end
	local entry = playersData and (playersData[gem.name] or playersData[(gem.name or ""):gsub("^Vaal ", "")])
	if not entry or ((#(entry.keystones or { }) == 0) and #(entry.uniques or { }) == 0) then return nil end
	local set = function(list) local t = { } for _, v in ipairs(list or { }) do t[v] = true end return t end
	local ks, us, sup = set(entry.keystones), set(entry.uniques), set(entry.supports)
	local lens
	if ks["Chaos Inoculation"] then
		lens = { stat = "EnergyShield", base = 1000, label = "Energy shield" }
	elseif ks["Blood Magic"] or us["Kaom's Heart"] then
		lens = { stat = "Life", base = 1000, label = "Life" }
	end
	local lens2
	if sup["Power Charge On Critical"] or sup["Increased Critical Damage"] or sup["Increased Critical Strikes"] then
		lens2 = { stat = "CritEffect", base = 1, label = "Crit damage factor", weight = 0.3 }
		if not lens then lens, lens2 = lens2, nil end
	end
	local parts = { }
	if #(entry.keystones or { }) > 0 then t_insert(parts, table.concat(entry.keystones, ", ")) end
	if #(entry.uniques or { }) > 0 then t_insert(parts, table.concat(entry.uniques, ", ")) end
	return {
		id = "PLAYERS",
		label = string.format("Top players' archetype (%s)", table.concat(parts, "; ")),
		summary = string.format("What most of the %d top %s players share: %s.", entry.builds or 0, gem.name, table.concat(parts, "; ")),
		keystones = entry.keystones, uniques = entry.uniques, supports = entry.supports,
		lens = lens, lens2 = lens2,
		maxUniques = math.max(3, #(entry.uniques or { })), setTolerance = 0.25,
		players = true,
		applies = function() return true end,
	}
end

-- Two archetypes together ("A+B"): keystones, uniques, auras, supports and
-- jewels of both, the first one's stat lens and the second's as a second
-- lens. nil when they can't go together (a keystone one excludes, both
-- with a play style or trigger setup).
function BuildArchetypesClass.Hybrid(a, b)
	if not a or not b or a.id == b.id then return nil end
	if (a.playstyle and b.playstyle) or a.trigger or b.trigger then return nil end
	local function excludes(x, y)
		for _, k in ipairs(x.excludeKeystones or { }) do
			for _, k2 in ipairs(y.keystones or { }) do if k == k2 then return true end end
		end
		return false
	end
	if excludes(a, b) or excludes(b, a) then return nil end
	local function union(x, y)
		if not x and not y then return nil end
		local out, seen = { }, { }
		for _, list in ipairs({ x or { }, y or { } }) do
			for _, v in ipairs(list) do if not seen[v] then seen[v] = true t_insert(out, v) end end
		end
		return out
	end
	local h = {
		id = a.id .. "+" .. b.id,
		label = string.format("Hybrid: %s + %s", (a.label:gsub(" %(found.*%)$", ""):gsub("^Hybrid: ", "")), (b.label:gsub(" %(found.*%)$", ""):gsub("^Hybrid: ", ""))),
		summary = (a.summary or "") .. " Together with: " .. (b.summary or ""),
		keystones = union(a.keystones, b.keystones), excludeKeystones = union(a.excludeKeystones, b.excludeKeystones),
		uniques = union(a.uniques, b.uniques), uniqueLines = union(a.uniqueLines, b.uniqueLines),
		auras = union(a.auras, b.auras), supports = union(a.supports, b.supports), blockSupports = union(a.blockSupports, b.blockSupports),
		jewels = union(a.jewels, b.jewels), jewelStat = a.jewelStat or b.jewelStat,
		lens = a.lens or b.lens, lens2 = a.lens and b.lens or nil,
		-- (lenses past the second: valued too, as the scorer's lensExtra)
		lensExtra = (function()
			local extra = { }
			for _, l in ipairs(a.lensExtra or { }) do t_insert(extra, l) end
			for _, l in ipairs(b.lensExtra or { }) do t_insert(extra, l) end
			if a.lens and a.lens2 and b.lens then t_insert(extra, b.lens) end
			return #extra > 0 and extra or nil
		end)(),
		maxAuras = (a.maxAuras or b.maxAuras) and math.max(a.maxAuras or 4, b.maxAuras or 4) or nil,
		maxUniques = math.max(a.maxUniques or 3, b.maxUniques or 3),
		setTolerance = a.setTolerance or b.setTolerance,
		playstyle = a.playstyle or b.playstyle,
		hybrid = true, parts = { a.id, b.id },
		lens2Of = nil,
		applies = function() return true end,
	}
	return h
end

-- An archetype by id among those that fit a skill ("A+B": their hybrid)
function BuildArchetypesClass.ById(gem, id, meta)
	if not id then return nil end
	local list = BuildArchetypesClass.ForSkill(gem, meta)
	local function find(x) for _, a in ipairs(list) do if a.id == x then return a end end end
	-- ("A+B+C": three or more commitments folded into one hybrid)
	if id:find("+", 1, true) then
		local h
		for part in id:gmatch("[^+]+") do
			local p = find(part)
			if not p then return nil end
			h = h and BuildArchetypesClass.Hybrid(h, p) or p
			if not h then return nil end
		end
		return h
	end
	return find(id)
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
