-- Path of Building
--
-- Module: Generator Rules
-- Uniques and gems whose drawback PoB doesn't calculate (it only sees the
-- upside), from an audit of every unique line PoB can't parse and every gem
-- stat it doesn't map (bench/audit.lua, October 2026, PoB 3.29).
--
-- A drawback the build can counter is turned into what it costs, so the item
-- is still used when the build pays for it:
--   manaPerUse / manaPercentPerAttack: added to the main skill's mana cost
--     (high regeneration, leech or flasks cover it)
--   lifePercentPerCast: % of life lost on each spell cast, added to the life
--     cost (life regeneration / leech must keep up)
--   needsAvoid: the build must be immune to what is turned back on it
--     (Maligaro's Restraint with shock immunity is fine)
--   noMinions: only without minion skills
-- Only drawbacks with no counter here are excluded outright.
--
local rules = { }

-- { [title] = rule }
rules.uniques = {
	-- costs on every use
	["Apep's Rage"] = { manaPerUse = 40, reason = "loses 40 mana on every skill use" },
	["Voidbringer"] = { manaPerUse = 60, reason = "loses 40-80 mana on every skill use" },
	["Mind of the Council"] = { manaPercentPerAttack = 3, reason = "loses 3% of mana on every attack" },
	["Rathpith Globe"] = { lifePercentPerCast = 10, reason = "sacrifices 10% of life on every spell cast" },
	["Demon Stitcher"] = { lifePercentPerCast = 15, reason = "sacrifices life on every spell cast" },
	-- turned back on you: fine when immune
	["Maligaro's Restraint"] = { needsAvoid = { "ShockAvoidChance" }, reason = "shocks you cause are reflected to you" },
	["Skysunder"] = { needsAvoid = { "IgniteAvoidChance" }, reason = "ignites you cause are reflected to you" },
	["The Fulcrum"] = { needsAvoid = { "IgniteAvoidChance", "ShockAvoidChance", "FreezeAvoidChance", "ChillAvoidChance" }, reason = "elemental ailments you cause are reflected to you" },
	["The Golden Rule"] = { needsAvoid = { "BleedAvoidChance", "PoisonAvoidChance" }, reason = "bleeding and poison you inflict are reflected to you" },
	["Retaliation Charm"] = { needsAvoid = { "BlindAvoidChance" }, reason = "blind you inflict is reflected to you" },
	["Shackles of the Wretched"] = { needsAvoid = { "CurseAvoidChance" }, reason = "hexes from socketed curses are reflected to you" },
	["Temptation Step"] = { needsAvoid = { "PoisonAvoidChance" }, reason = "poison from travel skills is reflected to you" },
	["Self-Flagellation"] = { needsAvoid = { "CurseAvoidChance" }, reason = "an additional curse can be applied to you" },
	["Mokou's Embrace"] = { needsAvoid = { "IgniteAvoidChance" }, reason = "all damage taken from hits can ignite you" },
	["Call of the Void"] = { needsAvoid = { "ChillAvoidChance" }, reason = "all damage taken from hits can chill you" },
	-- minion restrictions: fine without minion skills
	["The Primordial Chain"] = { noMinions = true, reason = "you can't have non-golem minions" },
	["Wraithlord"] = { noMinions = true, reason = "you can't have non-spectre minions" },
	["Chains of Command"] = { noMinions = true, reason = "you can't have non-animated, non-manifested minions" },
	-- no counter in the generated build (charges PoB assumes stay at maximum,
	-- flasks it still uses, defences it still counts)
	["Romira's Banquet"] = { excluded = true, reason = "loses all power charges on critical strike" },
	["Malachai's Loop"] = { excluded = true, reason = "loses all power charges on reaching maximum" },
	["Tulfall"] = { excluded = true, reason = "loses all power charges on reaching maximum" },
	["Replica Tulfall"] = { excluded = true, reason = "loses all power charges on reaching maximum" },
	["The Eternal Apple"] = { excluded = true, reason = "loses all endurance charges on reaching maximum" },
	["Daresso's Defiance"] = { excluded = true, reason = "loses all endurance charges when hit" },
	["Willclash"] = { excluded = true, reason = "loses all power charges when you block" },
	["Replica Powerlessness"] = { excluded = true, reason = "loses a power charge every second" },
	["Replica Pacifism"] = { excluded = true, reason = "loses a frenzy charge every second" },
	["Replica Fragility"] = { excluded = true, reason = "loses an endurance charge every second" },
	["Machina Mitts"] = { excluded = true, reason = "loses a power charge each second without detonating mines" },
	["Khatal's Geyser"] = { excluded = true, reason = "life flasks can't be used" },
	["Khatal's Weeping"] = { excluded = true, reason = "mana flasks can't be used" },
	["The Druggery"] = { excluded = true, reason = "life recovery from flasks goes to allies instead of you" },
	["Hiltless"] = { excluded = true, reason = "enemies you attack reflect physical damage to you" },
	["Doedre's Elixir"] = { excluded = true, reason = "deals up to half your life as chaos damage to you on use" },
	["Vessel of Vinktar"] = { excluded = true, reason = "you are shocked during its effect (50% more damage taken)" },
	["The Flawed Refuge"] = { excluded = true, reason = "you take all elemental damage from blocked hits" },
	["Corrupted Energy"] = { excluded = true, reason = "physical damage bypasses energy shield with 5 corrupted items" },
	["Haunting Memories"] = { excluded = true, reason = "suppressed spell damage bypasses energy shield" },
	-- build checks
	["Midnight Bargain"] = { check = function(output) return not output.ChaosInoculation end, reason = "can't be used with Chaos Inoculation" },
	["Replica Midnight Bargain"] = { check = function(output) return not output.ChaosInoculation end, reason = "can't be used with Chaos Inoculation" },
}

-- Support gems left out of generated links: { [name] = reason }
rules.excludedSupports = {
	["Sacrifice"] = "takes 20% of current life on every cast; PoB only adds the chaos damage",
	["Vaal Sacrifice"] = "sacrifices all but one life and energy shield on use",
	["Pacifism"] = "hits can't kill enemies",
}

-- Supports granted by an item to its socketed gems that change what a utility
-- gem does there (auras become traps, totems, triggered on damage taken, or
-- only affect allies): no utility group goes in such an item (blessings are
-- handled separately: one aura as a blessing)
rules.behaviourSupports = {
	"Trap", "Cluster Trap", "Blastchain Mine", "High%-Impact Mine", "Spell Totem", "Multiple Totems",
	"Generosity", "Cast when Damage Taken", "Arrow Nova", "Greater Volley", "Blasphemy", "Lifetap",
	"Meat Shield", "Divine Blessing", "Eternal Blessing",
}

-- Is a unique ever allowed? (only drawbacks with no counter are refused here;
-- the others cost score through rules.Costs)
function rules.UniqueAllowed(item, output)
	local title = item and (item.title or item.name)
	local rule = title and rules.uniques[title]
	if not rule then return true end
	if rule.excluded then return false, rule.reason end
	if rule.check and output and not rule.check(output) then return false, rule.reason end
	return true
end

-- Uniques with a rule among the items a calculation used
local function ruledItems(output)
	local list = { }
	local items = GeneratorOutputItems and GeneratorOutputItems[output]
	for _, item in pairs(items or { }) do
		local rule = item and item.rarity == "UNIQUE" and rules.uniques[item.title or item.name]
		if rule then list[#list + 1] = { item = item, rule = rule } end
	end
	return list
end

-- Extra resource cost per second of the drawbacks: { Mana = n, Life = n }
-- (uses: the main skill's uses per second)
function rules.ExtraCosts(output, isAttack, isSpell)
	local extra = { Mana = 0, Life = 0 }
	local uses = output.Speed or 0
	for _, entry in ipairs(ruledItems(output)) do
		local rule = entry.rule
		if rule.manaPerUse then extra.Mana = extra.Mana + rule.manaPerUse * uses end
		if rule.manaPercentPerAttack and isAttack then extra.Mana = extra.Mana + (output.Mana or 0) * rule.manaPercentPerAttack / 100 * uses end
		if rule.lifePercentPerCast and isSpell then extra.Life = extra.Life + (output.Life or 0) * rule.lifePercentPerCast / 100 * uses end
	end
	return extra
end

-- Drawbacks the build doesn't counter: { { label, value } } (score penalties)
function rules.Penalties(output)
	local list = { }
	for _, entry in ipairs(ruledItems(output)) do
		local rule = entry.rule
		local title = entry.item.title or entry.item.name
		for _, key in ipairs(rule.needsAvoid or { }) do
			if (output[key] or 0) < 100 then
				list[#list + 1] = { label = string.format("%s: %s, and the build isn't immune", title, rule.reason), value = 1.5 }
				break
			end
		end
		if rule.noMinions and output.Minion then
			list[#list + 1] = { label = string.format("%s: %s", title, rule.reason), value = 3 }
		end
	end
	return list
end

-- Kept for older callers
rules.UniqueRule = function(title) return rules.uniques[title] end

return rules
