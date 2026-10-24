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
	-- (found by the unique combo search: PoB reads each of its timed effects as always on)
	["Bound Fate"] = { excluded = true, reason = "every 5 seconds one random effect, half of them drawbacks; PoB counts the good ones as permanent" },
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
-- (from the audit of every unique's socketed gem lines, bench/unique_audit.lua)
rules.behaviourSupports = {
	"Trap", "Cluster Trap", "Blastchain Mine", "High%-Impact Mine", "Locus Mine", "Spell Totem", "Ballista Totem",
	"Multiple Totems", "Crab Totem", "Earthbreaker", "Generosity", "Cast when Damage Taken", "Cast when Stunned",
	"Cast on Death", "Cast On Critical Strike", "Cast on Melee Kill", "Cast while Channelling", "Cast on Ward Break",
	"Manaforged Arrows", "Mark On Hit", "Snipe", "Arrow Nova", "Greater Volley", "Blasphemy", "Lifetap",
	"Meat Shield", "Pacifism", "Sacrifice", "Divine Blessing", "Eternal Blessing",
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

-- Passives (mostly cluster jewel notables) whose effect PoB doesn't
-- calculate (bench: every cluster notable line its parser can't read), valued
-- for the situations where top players take them for it: score bonus as a
-- function of ctx = { output, focus, skill = main skill types, mainSkill,
-- hasSupport(name), itemHas(pattern), uses(charge) }. 0.01 is about 1% damage.
local function clearWeight(ctx) return ctx.focus.clear or 0.25 end
local function defenceWeight(ctx) return 0.5 + (ctx.focus.ehp or 0.5) end
-- (ignites that are a real part of the damage, not a few % chance on a hit build)
local function ignites(ctx)
	local o = ctx.output
	local ignite = o.IgniteDPS or 0
	return ignite > 0 and (o.IgniteChance or o.IgniteChanceOnHit or 0) >= 20
		and ignite / math.max(1, (o.TotalDPS or 0) + ignite) >= 0.15
end
local function igniteSpreads(ctx)
	return ctx.hasSupport("Ignite Proliferation") or ctx.hasSupport("Elemental Proliferation")
		or ctx.itemHas("Ignites you inflict.-spread") or ctx.itemHas("Supported by Level %d+ Ignite Proliferation")
		or ctx.itemHas("Supported by Level %d+ Elemental Proliferation")
end
local function freezes(ctx)
	local o = ctx.output
	return (o.FreezeChanceOnHit or 0) >= 20 and (o.ColdHitAverage or 0) > 0
end
local function blocks(ctx) return (ctx.output.EffectiveBlockChance or 0) >= 30 end
rules.uncountedNodes = {
	-- ailment spread: how an ignite (freeze) build clears without a proliferation source
	["Fan the Flames"] = function(ctx)
		if not ignites(ctx) then return 0 end
		return igniteSpreads(ctx) and 0.1 * clearWeight(ctx) or 0.6 * clearWeight(ctx)
	end,
	["Blast-Freeze"] = function(ctx)
		if not freezes(ctx) or ctx.itemHas("Freezes you inflict.-spread") then return 0 end
		return 0.3 * clearWeight(ctx) + 0.01 * defenceWeight(ctx)
	end,
	-- extra hits / brands / detonations the calculation leaves out
	["Remarkable"] = function(ctx) return ctx.skill.Brand and 0.3 * (ctx.focus.dps or 1) or 0 end,
	["Expert Sabotage"] = function(ctx) return ctx.skill.Mine and 0.1 * (ctx.focus.dps or 1) or 0 end,
	["Follow-Through"] = function(ctx)
		local chains = math.min(5, ctx.output.ChainMax or 0)
		return chains > 0 and math.log(1 + 0.1 * chains) * (ctx.focus.dps or 1) or 0
	end,
	-- auras: 8% effect on you per herald (up to 40%)
	["Purposeful Harbinger"] = function(ctx)
		local heralds = math.min(5, ctx.heralds or 0)
		return (ctx.auras or 0) > 0 and 0.015 * heralds * (ctx.auras or 0) or 0
	end,
	-- ailments and grounds you are mostly spared
	["Hibernator"] = function(ctx) return (ctx.output.FreezeAvoidChance or 0) < 100 and 0.12 * defenceWeight(ctx) or 0 end,
	["Capacitor"] = function(ctx) return (ctx.output.ShockAvoidChance or 0) < 100 and 0.06 * defenceWeight(ctx) or 0 end,
	["Fire Attunement"] = function(ctx) return (ctx.output.IgniteAvoidChance or 0) < 100 and 0.04 * defenceWeight(ctx) or 0 end,
	["Mender's Wellspring"] = function(ctx) return (ctx.output.BleedAvoidChance or 0) < 100 and 0.04 * defenceWeight(ctx) or 0 end,
	-- blind and maim: enemies hit and move less
	["Pure Guile"] = function(ctx) return 0.015 * defenceWeight(ctx) end,
	["Shifting Shadow"] = function(ctx) return 0.025 * defenceWeight(ctx) end,
	["Disorienting Display"] = function(ctx) return 0.02 * defenceWeight(ctx) end,
	["Disorienting Wounds"] = function(ctx) return (ctx.output.BleedChance or 0) > 0 and 0.03 * defenceWeight(ctx) or 0 end,
	["Smoking Remains"] = function(ctx) return 0.01 * defenceWeight(ctx) end,
	["Drive the Destruction"] = function(ctx) return ctx.skill.Attack and 0.01 or 0 end,
	["Smite the Weak"] = function(ctx) return ctx.skill.Attack and 0.01 or 0 end,
	["Fearsome Warrior"] = function(ctx) return ctx.skill.Melee and 0.02 or 0 end,
	["Disease Vector"] = function(ctx) return (ctx.output.PoisonChance or 0) > 0 and 0.01 or 0 end,
	-- charges the configuration can't know the build gets
	["Enduring Composure"] = function(ctx) return ctx.uses("Endurance") and 0 or 0.04 * defenceWeight(ctx) end,
	["Enduring Ward"] = function(ctx) return blocks(ctx) and 0.02 or 0 end,
	["Rote Reinforcement"] = function(ctx) return blocks(ctx) and 0.02 or 0 end,
	["Mage Bane"] = function(ctx) return blocks(ctx) and 0.02 or 0 end,
	["Mage Hunter"] = function(ctx) return blocks(ctx) and 0.02 or 0 end,
	["Powerful Ward"] = function(ctx) return blocks(ctx) and 0.02 or 0 end,
	["Aggressive Defence"] = function(ctx) return (ctx.output.FortificationStacks or ctx.output.MaximumFortification or 0) > 0 and 0.03 * defenceWeight(ctx) or 0 end,
	["Unwaveringly Evil"] = function(ctx) return ctx.skill.Chaos and 0.01 or 0 end,
}

-- Bonus of the uncounted passives among the given ones (names, sorted, each once)
function rules.UncountedBonus(names, ctx)
	local total = 0
	for _, name in ipairs(names) do
		local rule = rules.uncountedNodes[name]
		if rule then total = total + (rule(ctx) or 0) end
	end
	return total
end

-- Kept for older callers
rules.UniqueRule = function(title) return rules.uniques[title] end

return rules
