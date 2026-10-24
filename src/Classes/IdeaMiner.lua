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
-- life) are left out here.
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
		patterns = { "per Power Charge", "for each Power Charge" },
		summary = "More maximum power charges, and uniques that scale per power charge." },
	{ key = "FRENZY", label = "Frenzy charge stacking", stat = "FrenzyChargesMax", base = 3,
		patterns = { "per Frenzy Charge", "for each Frenzy Charge" },
		summary = "More maximum frenzy charges, and uniques that scale per frenzy charge." },
	{ key = "ENDURANCE", label = "Endurance charge stacking", stat = "EnduranceChargesMax", base = 3,
		patterns = { "per Endurance Charge", "for each Endurance Charge" },
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
					applies = function() return true end,
				})
			end
		end
	end
	return list
end
