-- Path of Building
--
-- Module: Generator Rules
-- Uniques and gems the build generator / build ideas must not pick on their
-- own, because their drawback is something PoB doesn't calculate (it only
-- sees the upside), and items whose socketed-gem supports change what a
-- utility gem placed in them does. From an audit of every unique's lines PoB
-- can't parse and every gem stat it doesn't map (October 2026, PoB 3.29).
--
local rules = { }

-- Uniques never suggested automatically: { [title] = reason }
rules.excludedUniques = {
	-- life / energy shield taken on every cast or use
	["Rathpith Globe"] = "sacrifices 10% of life on every spell cast",
	["Demon Stitcher"] = "sacrifices life on every spell cast",
	["Doedre's Elixir"] = "deals up to half your life as chaos damage to you on use",
	-- ailments / curses / damage turned back on you
	["Maligaro's Restraint"] = "shocks you cause are reflected to you",
	["Skysunder"] = "ignites you cause are reflected to you",
	["The Fulcrum"] = "elemental ailments you cause are reflected to you",
	["The Golden Rule"] = "bleeding and poison you inflict are reflected to you",
	["Retaliation Charm"] = "blind you inflict is reflected to you",
	["Shackles of the Wretched"] = "hexes from socketed curses are reflected to you",
	["Temptation Step"] = "poison from travel skills is reflected to you",
	["Hiltless"] = "enemies you attack reflect physical damage to you",
	["Self-Flagellation"] = "an additional curse can be applied to you",
	["Mokou's Embrace"] = "all damage taken from hits can ignite you",
	["Call of the Void"] = "all damage taken from hits can chill you",
	["The Flawed Refuge"] = "you take all elemental damage from blocked hits",
	["Corrupted Energy"] = "physical damage bypasses energy shield with 5 corrupted items",
	["Haunting Memories"] = "suppressed spell damage bypasses energy shield",
	-- charges PoB assumes stay at maximum
	["Romira's Banquet"] = "loses all power charges on critical strike",
	["Malachai's Loop"] = "loses all power charges on reaching maximum",
	["Replica Tulfall"] = "loses all power charges on reaching maximum",
	["The Eternal Apple"] = "loses all endurance charges on reaching maximum",
	["Daresso's Defiance"] = "loses all endurance charges when hit",
	["Replica Powerlessness"] = "loses a power charge every second",
	["Replica Pacifism"] = "loses a frenzy charge every second",
	["Replica Fragility"] = "loses an endurance charge every second",
	["Machina Mitts"] = "loses a power charge each second without detonating mines",
	-- flasks the generated build would still use
	["Khatal's Geyser"] = "life flasks can't be used",
	["Khatal's Weeping"] = "mana flasks can't be used",
	["The Druggery"] = "life recovery from flasks goes to allies instead of you",
	-- mana lost on every use
	["Apep's Rage"] = "loses 40 mana on every skill use",
	["Mind of the Council"] = "loses 3% of mana on every attack",
	["Voidbringer"] = "loses 40-80 mana on every skill use",
	-- more of the same kinds
	["Tulfall"] = "loses all power charges on reaching maximum",
	["Willclash"] = "loses all power charges when you block",
	["Vessel of Vinktar"] = "you are shocked during its effect (50% more damage taken)",
	-- minion restrictions the build may not respect
	["The Primordial Chain"] = "you can't have non-golem minions",
	["Wraithlord"] = "you can't have non-spectre minions",
	["Chains of Command"] = "you can't have non-animated, non-manifested minions",
}

-- Uniques allowed only when a check on the build passes: { [title] = function(output) -> ok, reason }
rules.conditionalUniques = {
	["Midnight Bargain"] = function(output) return not output.ChaosInoculation, "can't be used with Chaos Inoculation" end,
	["Replica Midnight Bargain"] = function(output) return not output.ChaosInoculation, "can't be used with Chaos Inoculation" end,
}

-- Support gems left out of generated links: { [name] = reason }
rules.excludedSupports = {
	["Sacrifice"] = "takes 20% of current life on every cast; PoB only adds the chaos damage",
	["Vaal Sacrifice"] = "sacrifices all but one life and energy shield on use",
	["Pacifism"] = "hits can't kill enemies",
}

-- Supports granted by an item to its socketed gems that change what a utility
-- gem does there (auras become traps, totems, blessings, triggered on damage
-- taken, or only affect allies): no utility group goes in such an item
-- (blessings are handled separately: one aura as a blessing)
rules.behaviourSupports = {
	"Trap", "Cluster Trap", "Blastchain Mine", "High%-Impact Mine", "Spell Totem", "Multiple Totems",
	"Generosity", "Cast when Damage Taken", "Arrow Nova", "Greater Volley", "Blasphemy", "Lifetap",
	"Meat Shield", "Divine Blessing", "Eternal Blessing",
}

-- Is a unique allowed for the build? returns ok, reason
function rules.UniqueAllowed(item, output)
	local title = item and (item.title or item.name)
	if not title then return true end
	if rules.excludedUniques[title] then return false, rules.excludedUniques[title] end
	local check = rules.conditionalUniques[title]
	if check and output then
		local ok, reason = check(output)
		if not ok then return false, reason end
	end
	return true
end

return rules
