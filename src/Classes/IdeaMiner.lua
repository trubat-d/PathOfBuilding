-- Path of Building
--
-- Class: Idea Miner
-- Build ideas found in the game data instead of written by hand: every unique
-- whose lines turn one stat into another ("per 1% Chance to Block", "per
-- Power Charge", "per 500 Evasion Rating"...) points to a stat that can be
-- stacked. Each stat with enough such uniques becomes an idea the archetype
-- scan treats like a written archetype: its uniques are tried, and its stat
-- is valued on its own while the build is made (the stat lens), so gear and
-- passives follow it before the uniques that pay it back are all in place.
-- The written stacking archetypes (Intelligence, Strength, Dexterity, mana,
-- life) are left out here. Lines that turn the stacked stat into another one
-- ("Maximum Frenzy Charges is equal to your Maximum Power Charges": Badge of
-- the Brotherhood) belong to the idea: a second layer stacked for free.
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert
local t_sort = table.sort

---@class IdeaMiner
local IdeaMinerClass = newClass("IdeaMiner")

function IdeaMinerClass:IdeaMiner()
	return self
end

-- Stats that can be stacked: the patterns of lines scaling with them, the
-- calculator output the lens values, and when the idea fits a skill
IdeaMinerClass.drivers = {
	{ key = "BLOCK", label = "Block stacking", stat = "BlockChance", base = 20,
		patterns = { "per %d*%%? ?[Cc]hance to [Bb]lock", "per 1%% Chance to Block" },
		summary = "Stack block chance: uniques that turn block into damage or recovery, and the block itself as defence." },
	{ key = "POWER", label = "Power charge stacking", stat = "PowerChargesMax", base = 3,
		patterns = { "per Power Charge", "for each Power Charge", "Count as having maximum number of Power Charges", "to [Mm]aximum Power Charges", "Maximum Power Charges is equal to", "equal to your Maximum Power Charges" },
		summary = "More maximum power charges, uniques that scale per power charge, and ones that count as having the maximum (Ralakesh's Impatience: the \"lose all on reaching maximum\" drawbacks of the others stop mattering)." },
	{ key = "FRENZY", label = "Frenzy charge stacking", stat = "FrenzyChargesMax", base = 3,
		patterns = { "per Frenzy Charge", "for each Frenzy Charge", "Count as having maximum number of Frenzy Charges", "to [Mm]aximum Frenzy Charges", "Maximum Frenzy Charges is equal to", "equal to your Maximum Frenzy Charges" },
		summary = "More maximum frenzy charges, and uniques that scale per frenzy charge." },
	{ key = "ENDURANCE", label = "Endurance charge stacking", stat = "EnduranceChargesMax", base = 3,
		patterns = { "per Endurance Charge", "for each Endurance Charge", "Count as having maximum number of Endurance Charges", "to [Mm]aximum Endurance Charges", "Maximum Endurance Charges is equal to", "equal to your Maximum Endurance Charges" },
		summary = "More maximum endurance charges, and uniques that scale per endurance charge." },
	{ key = "EVASION", label = "Evasion stacking", stat = "Evasion", base = 5000,
		patterns = { "per %d+ Evasion Rating", "per %d+ Evasion" },
		summary = "A huge evasion rating, and uniques that turn it into damage or speed." },
	{ key = "ARMOUR", label = "Armour stacking", stat = "Armour", base = 5000,
		patterns = { "per %d+ Armour" },
		summary = "A huge armour rating, and uniques that turn it into damage." },
	{ key = "ES", label = "Energy shield stacking", stat = "EnergyShield", base = 1000,
		patterns = { "per %d+ [Mm]aximum Energy Shield", "per %d+ Energy Shield" },
		summary = "A big energy shield pool (with or without Chaos Inoculation), and uniques that scale with it." },
	{ key = "RAGE", label = "Rage stacking", stat = "MaximumRage", base = 30, attack = true,
		patterns = { "per %d* ?Rage" },
		summary = "More maximum rage, and uniques that scale per rage." },
	{ key = "FORTIFY", label = "Fortification stacking", stat = "FortificationStacks", base = 20, melee = true,
		patterns = { "per Fortification" },
		summary = "Fortification kept high by melee hits, and uniques that scale per fortification." },
}

-- Uniques (not jewels or flasks, current versions) with a line matching one of the patterns
local function matchingUniques(patterns)
	local byTitle = { }
	for _, item in pairs(main.uniqueDB.list) do
		byTitle[item.title or item.name] = byTitle[item.title or item.name] or item
	end
	local titles = { }
	for title, item in pairs(byTitle) do
		if item.type ~= "Jewel" and item.type ~= "Flask" then
			for _, modLine in ipairs(item.explicitModLines or { }) do
				local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
				if current and modLine.line then
					local found = false
					for _, pattern in ipairs(patterns) do
						if modLine.line:match(pattern) then found = true break end
					end
					if found then t_insert(titles, title) break end
				end
			end
		end
	end
	t_sort(titles)
	return titles
end

-- Ideas for a skill (BuildArchetypes.SkillInfo): archetype tables with
-- uniqueLines, lens and mined = true; only stats with at least minUniques
-- uniques that scale with them
function IdeaMinerClass.Ideas(info, opts)
	opts = opts or { }
	local list = { }
	if info.minion then return list end
	for _, driver in ipairs(IdeaMinerClass.drivers) do
		local fits = (not driver.attack or info.attack) and (not driver.melee or (info.types and info.types[SkillType.Melee]))
		if fits then
			local titles = matchingUniques(driver.patterns)
			if #titles >= (opts.minUniques or 2) then
				local shown = { }
				for i = 1, math.min(4, #titles) do shown[i] = titles[i] end
				t_insert(list, {
					id = "MINED_" .. driver.key,
					label = string.format("%s (found: %s%s)", driver.label, table.concat(shown, ", "), #titles > 4 and "..." or ""),
					summary = driver.summary,
					uniqueLines = driver.patterns,
					lens = { stat = driver.stat, base = driver.base, label = driver.label:gsub(" stacking", "") },
					mined = true,
					-- (stacking sets are several pieces: Winter Orb's power charge set is five)
					maxUniques = ({ POWER = 5, FRENZY = 5, ENDURANCE = 5 })[driver.key],
					setTolerance = ({ POWER = 0.25, FRENZY = 0.25, ENDURANCE = 0.25 })[driver.key],
					applies = function() return true end,
				})
			end
		end
	end
	-- the stats found in the data itself (IdeaMiner.DataDrivers): every stat
	-- some uniques turn into damage, and the uniques that turn another stat
	-- into it (two steps: stack A, A becomes B, B becomes damage)
	if opts.dataDrivers ~= false then
		for _, d in ipairs(IdeaMinerClass.DataDrivers()) do
			if #d.payoffs >= (opts.minUniques or 2) and (not d.attackOnly or info.attack) and (not d.spellOnly or info.spell) then
				local titles = { }
				for _, t in ipairs(d.payoffs) do t_insert(titles, t) end
				for _, t in ipairs(d.converters) do t_insert(titles, t) end
				local shown = { }
				for i = 1, math.min(4, #d.payoffs) do shown[i] = d.payoffs[i] end
				t_insert(list, {
					id = "MINED_DATA_" .. d.key:gsub("[^%w]", ""),
					label = string.format("%s stacking (found in the data: %s%s%s)", d.label, table.concat(shown, ", "), #d.payoffs > 4 and "..." or "",
						#d.converters > 0 and ("; turned into it by " .. table.concat(d.converters, ", ")) or ""),
					summary = string.format("Uniques scale damage with %s: stack it (and the uniques that turn other stats into it).", d.label:lower()),
					uniques = titles,
					lens = d.lens,
					mined = true,
					maxUniques = 4,
					setTolerance = 0.15,
					applies = function() return true end,
				})
			end
		end
	end
	-- uniques a build is made around (IdeaMiner.Anchors)
	if opts.anchors ~= false then
		for _, a in ipairs(IdeaMinerClass.Anchors(info, opts.maxAnchors)) do t_insert(list, a) end
	end
	-- conversion / "gain as extra" towards one element (IdeaMiner.Conversions):
	-- the uniques adding it, that element's aura and penetration
	if opts.conversions ~= false then
		for _, c in ipairs(IdeaMinerClass.Conversions()) do
			local fromOk = false
			for src in pairs(c.sources) do
				if src == "Physical" and (info.physical or info.attack) then fromOk = true end
				if src == "Elemental" and info.elemental then fromOk = true end
				if (src == "Fire" or src == "Cold" or src == "Lightning") and info.tags and info.tags[src:lower()] then fromOk = true end
			end
			if fromOk and #c.titles >= 2 then
				local shown = { }
				for i = 1, math.min(4, #c.titles) do shown[i] = c.titles[i] end
				t_insert(list, {
					id = "MINED_TO_" .. c.element:upper(),
					label = string.format("Damage turned into %s (found: %s%s)", c.element:lower(), table.concat(shown, ", "), #c.titles > 4 and "..." or ""),
					summary = string.format("Uniques converting or adding damage as %s, the %s aura and %s penetration: one element scaled on top of the skill's own damage.", c.element:lower(), c.element:lower(), c.element:lower()),
					uniques = c.titles,
					auras = c.aura and { c.aura } or nil,
					supports = c.support and { c.support } or nil,
					mined = true,
					maxUniques = 3,
					setTolerance = 0.1,
					applies = function() return true end,
				})
			end
		end
	end
	return list
end

-- Anchors: uniques with one line far above what an affix gives - "Gain 700%
-- of Weapon Physical Damage as Extra Damage of a random Element" (Voidforge),
-- "N% more Damage" from 40% - that the skill can use. A build is made around
-- one (forced from the start: the archetype's `forced`); in the finished
-- build it never wins alone, its crit / charge / keystone set has to come
-- with it (top Cyclone of Tumult players: Voidforge, Overwhelm, Masterful
-- Form, 65% crit x6.3). The strongest few, by the line's size.
local anchorPatterns = {
	{ pattern = "^Gain (%d+)%% of .-Damage as Extra", min = 100, scale = 1 / 100 },
	{ pattern = "^(%d+)%% more Damage", min = 40, scale = 1 / 40 },
	{ pattern = "^(%d+)%% more Attack Damage", min = 40, scale = 1 / 40 },
	{ pattern = "^(%d+)%% more Spell Damage", min = 40, scale = 1 / 40 },
}
function IdeaMinerClass.Anchors(info, maxAnchors)
	local list = { }
	if info.minion or not main or not main.uniqueDB then return list end
	local found, seen = { }, { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		local base = item.base
		local slotOk = base and (base.weapon or base.armour) and not seen[title]
		-- (a weapon the attack can use; spells take any)
		if slotOk and base.weapon then
			if info.attack and info.weaponTypes and not info.weaponTypes[base.type] then slotOk = false end
			if info.spell and not info.attack and not (base.type == "Wand" or base.type == "Staff" or base.type == "Sceptre" or base.type == "Dagger" or base.type:match("^One Handed")) then slotOk = false end
		end
		if slotOk then
			for _, modLine in ipairs(item.explicitModLines or { }) do
				local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
				local line = current and modLine.line
				if line then
					for _, a in ipairs(anchorPatterns) do
						local v = tonumber(line:match(a.pattern) or "")
						-- (attack lines for attacks, spell lines for spells)
						local fits = not (line:find("Attack", 1, true) and not info.attack) and not (line:find("Spell", 1, true) and not info.spell)
						if v and v >= a.min and fits then
							seen[title] = true
							t_insert(found, { title = title, line = line, size = v * a.scale })
							break
						end
					end
				end
				if seen[title] then break end
			end
		end
	end
	table.sort(found, function(a, b) if a.size ~= b.size then return a.size > b.size end return a.title < b.title end)
	for i = 1, math.min(maxAnchors or 3, #found) do
		local f = found[i]
		t_insert(list, {
			id = "ANCHOR_" .. f.title:gsub("[^%w]", ""),
			label = string.format("Built around %s (%s)", f.title, f.line),
			summary = string.format("%s is forced from the start, and the build is made around its \"%s\" (the crit, charges and keystones it needs come with it).", f.title, f.line),
			forced = { f.title },
			mined = true,
			applies = function() return true end,
		})
	end
	return list
end

local conversions
-- { { element, titles, sources = { [src] = true }, aura, support } }
function IdeaMinerClass.Conversions()
	if conversions then return conversions end
	conversions = { }
	local byElement = { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		for _, modLine in ipairs(item.explicitModLines or { }) do
			local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
			for _, mod in ipairs(current and modLine.modList or { }) do
				local src, dst = mod.name:match("^(%a-)DamageConvertTo(%a+)$")
				if not src then src, dst = mod.name:match("^(%a-)DamageGainAs(%a+)$") end
				if src and dst and dst ~= "Random" then
					byElement[dst] = byElement[dst] or { titles = { }, sources = { } }
					byElement[dst].titles[title] = true
					byElement[dst].sources[src] = true
				end
			end
		end
	end
	local auras = { Fire = "Anger", Cold = "Hatred", Lightning = "Wrath", Chaos = "Malevolence" }
	local supports = { Fire = "Fire Penetration", Cold = "Cold Penetration", Lightning = "Lightning Penetration", Chaos = "Void Manipulation" }
	for element, e in pairs(byElement) do
		local titles = { }
		for t in pairs(e.titles) do t_insert(titles, t) end
		t_sort(titles)
		t_insert(conversions, { element = element, titles = titles, sources = e.sources, aura = auras[element], support = supports[element] })
	end
	t_sort(conversions, function(a, b) return a.element < b.element end)
	return conversions
end

-- Stats the hand-written ideas (and the drivers above) already cover
local coveredStats = {
	Str = true, Dex = true, Int = true, Mana = true, Life = true, Evasion = true, Armour = true, EnergyShield = true, BlockChance = true,
	["Multiplier:PowerCharge"] = true, ["Multiplier:FrenzyCharge"] = true, ["Multiplier:EnduranceCharge"] = true,
	["Multiplier:Rage"] = true, ["Multiplier:RageEffect"] = true, FortificationStacks = true,
}
-- Stats that can't be stacked by the build (sockets of one item, level...)
local function uncontrollable(key)
	return key:find("{SlotName}", 1, true) or key == "Multiplier:Level" or key:match("Recently") or key:match("Enemy") or key == "?"
end
-- Output values a lens can follow, per stat key
local lensStats = {
	Accuracy = { stat = "Accuracy", base = 2000 }, LowestAttribute = { stat = "LowestAttribute", base = 100 },
	ActiveZombieLimit = { stat = "ActiveZombieLimit", base = 1 }, ManaReserved = { stat = "ManaReserved", base = 500 },
	LifeReserved = { stat = "LifeReserved", base = 500 },
}
-- Modifier names that are damage
local function isDamage(name)
	return name:match("Damage$") or name:match("Min$") or name:match("Max$") or name:match("^Crit") or name == "Speed"
		or name:match("GainAs") or name:match("Penetration") or name:match("DotMultiplier") or name:match("Degen$")
end

local dataDrivers
-- { { key, label, payoffs = { titles }, converters = { titles }, lens } }
function IdeaMinerClass.DataDrivers()
	if dataDrivers then return dataDrivers end
	dataDrivers = { }
	local payoffs, converters = { }, { }
	local function add(map, key, title)
		map[key] = map[key] or { }
		map[key][title] = true
	end
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		if item.type ~= "Flask" and item.type ~= "Tincture" then
			for _, modLine in ipairs(item.explicitModLines or { }) do
				local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
				for _, mod in ipairs(current and modLine.modList or { }) do
					for _, tag in ipairs(mod) do
						if type(tag) == "table" and (tag.type == "PerStat" or tag.type == "Multiplier") then
							local key = tag.type == "PerStat" and (tag.stat or "?") or ("Multiplier:" .. (tag.var or "?"))
							if not uncontrollable(key) then
								if isDamage(mod.name) then add(payoffs, key, title)
								-- (a stat turned into another stat: "+1 to X per Y")
								elseif mod.type == "BASE" or mod.type == "INC" then add(converters, mod.name, title .. "|" .. key) end
							end
						end
					end
				end
			end
		end
	end
	for key, titles in pairs(payoffs) do
		if not coveredStats[key] then
			local list = { }
			for t in pairs(titles) do t_insert(list, t) end
			t_sort(list)
			-- uniques turning a stat into this one
			local conv = { }
			for entry in pairs(converters[key] or { }) do
				local t = entry:match("^(.-)|")
				if t and not titles[t] then conv[t] = true end
			end
			local convList = { }
			for t in pairs(conv) do t_insert(convList, t) end
			t_sort(convList)
			local label = key:gsub("^Multiplier:", ""):gsub("(%l)(%u)", "%1 %2")
			t_insert(dataDrivers, { key = key, label = label, payoffs = list, converters = convList, lens = lensStats[key] and { stat = lensStats[key].stat, base = lensStats[key].base, label = label } or nil,
				-- (accuracy only matters to attacks, intensity to spells)
				attackOnly = key == "Accuracy" or nil, spellOnly = key == "Multiplier:Intensity" or nil })
		end
	end
	t_sort(dataDrivers, function(a, b) return #a.payoffs > #b.payoffs or (#a.payoffs == #b.payoffs and a.key < b.key) end)
	return dataDrivers
end
