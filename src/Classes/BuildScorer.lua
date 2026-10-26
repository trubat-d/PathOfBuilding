-- Path of Building
--
-- Class: Build Scorer
-- Turns calculator output into one score used by the build ideas finder and
-- the build generator, and corrects for things PoB assumes are always true:
--   * utility flasks: PoB treats a flask that is switched on as up 100% of
--     the time. Here each flask's benefit only counts for its estimated
--     uptime (duration vs charges), except flasks made permanent (Mageblood).
--   * hits per target: see HitOverlap; the scorer applies its multiplier.
--   * survivability is more than the effective hit pool: recovery (regen,
--     leech, recoup, life on hit / kill, energy shield recharge) counts too,
--     and self-damage over time (Righteous Fire...) must be out-regenerated.
--   * clear speed: explosions on kill, area, projectiles and movement speed.
-- Score = dpsWeight * ln(DPS) + ehpWeight * (ln(EHP) + recovery term)
--         + avoidWeight * ln(1 / share of hit damage taken)
--         + clearWeight * clear term - penalties
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local m_log = math.log
local m_exp = math.exp
local m_max = math.max
local m_min = math.min
local m_floor = math.floor

---@class BuildScorer
local BuildScorerClass = newClass("BuildScorer")

BuildScorerClass.focusList = {
	{ label = "Balanced (damage, tankiness, clear)", id = "BALANCED", dps = 1, ehp = 1, avoid = 0.8, clear = 0.4, hitTarget = 40000 },
	{ label = "Damage first", id = "DPS", dps = 1, ehp = 0.35, avoid = 0.3, clear = 0.2, hitTarget = 15000 },
	{ label = "Tankiness first", id = "TANK", dps = 0.35, ehp = 1, avoid = 1, clear = 0.2 },
	{ label = "Damage, with a minimum max hit (every damage type)", id = "DPS_FLOOR", dps = 1, ehp = 0.15, avoid = 0.35, hitFloor = 10000, clear = 0.25 },
	{ label = "Mapping (clear speed first)", id = "CLEAR", dps = 0.7, ehp = 0.6, avoid = 0.5, clear = 1, hitTarget = 25000 },
	-- (a mix the player sets in the window: BuildScorer.CustomFocus)
}

local elements = { "Fire", "Cold", "Lightning" }
local attributes = { "Str", "Dex", "Int" }

-- options:
--   focus: entry of focusList (default Balanced)
--   chargesPerSecond: flask charges gained per second from kills (default 4, mapping)
--   flaskRealism: true to correct flask uptime (default true)
--   overlap: HitOverlap instance (optional)
function BuildScorerClass:BuildScorer(build, options)
	self.build = build
	options = options or { }
	self.focus = options.focus or self.focusList[1]
	self.ehpFloor = options.ehpFloor
	self.hitFloor = options.hitFloor
	-- "uber" or "pinnacle": which boss hits the build must survive
	self.bossTier = options.bossTier or "pinnacle"
	self.chargesPerSecond = options.chargesPerSecond or 4
	self.flaskRealism = options.flaskRealism ~= false
	self.overlap = options.overlap
	-- kills per second for on-kill recovery: a few while mapping, almost none against a boss
	self.killsPerSecond = options.killsPerSecond or (self.chargesPerSecond >= 3 and 3 or 0.1)
	return self
end

-- Life and energy shield recovered per second while fighting, net of
-- self-damage over time. Leech, gain on hit and recoup only happen while
-- hitting / being hit, which is most of a fight; recharge needs a pause.
-- Life and energy shield recovered per second from blocking and suppressing
-- (an enemy hit a second, half attacks and half spells: what a fight is like)
local hitsTakenPerSecond = 1
function BuildScorerClass:BlockRecovery(output)
	local attackBlock = (output.EffectiveBlockChance or output.BlockChance or 0) / 100
	local spellBlock = (output.EffectiveSpellBlockChance or output.SpellBlockChance or 0) / 100
	local suppress = (output.EffectiveSpellSuppressionChance or output.SpellSuppressionChance or 0) / 100
	local anyBlock = (attackBlock + spellBlock) / 2
	local life = (output.LifeOnBlock or 0) * anyBlock + (output.LifeOnSuppress or 0) * suppress * 0.5
	local es = (output.EnergyShieldOnBlock or 0) * anyBlock + (output.EnergyShieldOnSpellBlock or 0) * spellBlock * 0.5
		+ (output.EnergyShieldOnSuppress or 0) * suppress * 0.5
	return life * hitsTakenPerSecond, es * hitsTakenPerSecond
end

function BuildScorerClass:Recovery(output)
	local blockLife, blockES = self:BlockRecovery(output)
	local life = (output.ComprehensiveNetLifeRegen or output.NetLifeRegen or output.LifeRegenRecovery or 0) + blockLife
	local es = output.ComprehensiveNetEnergyShieldRegen or output.NetEnergyShieldRegen or output.EnergyShieldRegenRecovery or 0
	local leech = (output.LifeLeechGainRate or 0) + (output.EnergyShieldLeechGainRate or 0)
	local onKill = ((output.LifeOnKill or 0) + (output.EnergyShieldOnKill or 0)) * self.killsPerSecond
	local recharge = (output.EnergyShieldRecharge or 0) * 0.25
	return life + es + blockES + leech * 0.8 + onKill + recharge
end

function BuildScorerClass:DissolutionActive()
	local env = self.build.calcsTab and self.build.calcsTab.mainEnv
	return env and env.player and env.player.modDB:Flag(nil, "DamageInsteadReservesLife") or false
end

-- Recovery per second as a share of the life + energy shield pool. Each pool
-- only counts what it can hold (regenerating a 1 life pool under Chaos
-- Inoculation is worth nothing), over at least a normal sized pool.
function BuildScorerClass:RecoveryRatio(output)
	local lifePool = m_max(0, output.Life or 0)
	local esPool = m_max(0, output.EnergyShield or 0)
	local blockLife, blockES = self:BlockRecovery(output)
	local lifeSide = (output.ComprehensiveNetLifeRegen or output.NetLifeRegen or output.LifeRegenRecovery or 0)
		+ (output.LifeLeechGainRate or 0) * 0.8 + (output.LifeOnKill or 0) * self.killsPerSecond + blockLife
	local esSide = (output.ComprehensiveNetEnergyShieldRegen or output.NetEnergyShieldRegen or output.EnergyShieldRegenRecovery or 0)
		+ (output.EnergyShieldLeechGainRate or 0) * 0.8 + (output.EnergyShieldOnKill or 0) * self.killsPerSecond
		+ (output.EnergyShieldRecharge or 0) * 0.25 + blockES
	-- Dissolution of the Flesh (poewiki): life lost to damage is reserved
	-- until no life damage for 2 seconds, and life recovery doesn't touch the
	-- reservation - regen, leech and flasks give back nothing while hits keep
	-- coming
	if self:DissolutionActive() then lifeSide = 0 end
	local recovered = m_min(lifeSide, 0.5 * lifePool) + m_min(esSide, 0.5 * esPool)
	return recovered / m_max(lifePool + esPool, 3000)
end

-- Self-damage over time not covered by regeneration (per second, 0 if fine)
function BuildScorerClass:DegenDeficit(output)
	local net = (output.NetLifeRegen or 0) + m_max(0, output.NetEnergyShieldRegen or 0)
	local regen = output.LifeRegenRecovery or 0
	local degen = regen - (output.NetLifeRegen or regen)
	if degen > 1 and net < 0 then
		return -net, degen
	end
	return 0, degen
end

-- Is the main skill linked to this support gem? (cached per main socket group contents)
function BuildScorerClass:SupportedBy(name)
	local build = self.build
	local group = build and build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
	if not group then return false end
	for _, gem in ipairs(group.gemList or { }) do
		if gem.enabled ~= false and gem.gemData and gem.gemData.name == name then return true end
	end
	return false
end

-- Clear speed term: movement speed, area or projectiles, explosions on kill
function BuildScorerClass:ClearTerm(output)
	local ms = m_max(0.2, output.EffectiveMovementSpeedMod or 1)
	local radius = output.AreaOfEffectRadius
	local areaFactor = radius and m_min(4, m_max(0.3, (radius / 18) ^ 2)) or 1
	-- (melee strikes splashing around their target: Tribal Fury)
	if output.MeleeSplash then areaFactor = m_max(areaFactor, 1.5) end
	local projectiles = (output.ProjectileCount or 1) - 1 + 0.5 * m_min(4, output.PierceCount or 0) + 0.7 * m_min(4, output.ChainMax or 0)
	local projFactor = 1 + 0.25 * m_max(0, projectiles)
	local explode = output.ClearExplodeValue or 0
	-- ignites that spread to other enemies (Fan the Flames, glove implicits,
	-- Ignite Proliferation Support): a build whose damage is mostly ignite
	-- reaches the whole pack with it, like a bigger area
	local spreadFactor = 1
	local combined = m_max(1, output.CombinedDPS or 0)
	local igniteShare = (output.IgniteDPS or 0) / combined
	if igniteShare > 0.1 then
		if (output.IgniteSpreadRadius or 0) > 0 or self:SupportedBy("Ignite Proliferation") then
			spreadFactor = spreadFactor * (1 + 2 * m_min(1, igniteShare))
		elseif output.IgniteSpreadOnKill then
			-- (only from kills: the pack is reached once the first one dies)
			spreadFactor = spreadFactor * (1 + m_min(1, igniteShare))
		end
	end
	local poisonShare = (output.PoisonDPS or 0) / combined
	if poisonShare > 0.1 and output.PoisonSpreadOnKill then spreadFactor = spreadFactor * (1 + m_min(1, poisonShare)) end
	local impaleShare = (output.ImpaleDPS or 0) / combined
	if impaleShare > 0.1 and output.ImpaleSpread then spreadFactor = spreadFactor * (1 + 0.5 * m_min(1, impaleShare)) end
	-- (shock / chill / freeze spreading: the pack takes more damage or is slowed)
	local function onHit(name)
		return m_max(output[name .. "ChanceOnHit"] or 0, output.MainHand and output.MainHand[name .. "ChanceOnHit"] or 0)
	end
	if (output.ShockSpreadRadius or 0) > 0 and onHit("Shock") >= 20 then spreadFactor = spreadFactor * 1.15 end
	if ((output.FreezeSpreadRadius or 0) > 0 and onHit("Freeze") >= 20) or ((output.ChillSpreadRadius or 0) > 0) then spreadFactor = spreadFactor * 1.05 end
	local term = 0.6 * m_log(ms) + 0.25 * m_log(areaFactor * projFactor * spreadFactor) + m_log(1 + 3 * explode)
	-- Headhunter while clearing: the stolen rare modifiers (a typical set: 20%
	-- movement speed, 40% damage, 20% speed - the configuration's "Headhunter"
	-- switch counts them in PoB's numbers; when it's off, as against a boss,
	-- they still count here for a build made to clear too)
	if self.clearBuffs and not self.build.configTab.input.conditionHeadhunterBuffs then
		local items = GeneratorOutputItems and GeneratorOutputItems[output]
		for _, item in pairs(items or { }) do
			if item and item.title == "Headhunter" then
				term = term + 0.6 * m_log(1.2) + 0.3 * m_log(1.4 * 1.2)
				break
			end
		end
	end
	return term
end

-- Goals a custom mix can add on top of damage / tankiness / avoidance / clear:
-- each a stat of the build's output, counted as weight x log(stat / base)
-- (doubling it is worth "weight" whatever its size, like damage)
BuildScorerClass.goalList = {
	{ id = "move", label = "Movement speed", stat = "EffectiveMovementSpeedMod", base = 1 },
	{ id = "speed", label = "Attack / cast speed", stat = "Speed", base = 1 },
	{ id = "life", label = "Life", stat = "Life", base = 1000 },
	{ id = "es", label = "Energy shield", stat = "EnergyShield", base = 1000 },
	{ id = "armour", label = "Armour", stat = "Armour", base = 1000 },
	{ id = "evasion", label = "Evasion", stat = "Evasion", base = 1000 },
	{ id = "block", label = "Block (attacks and spells)", stat = "_block", base = 10 },
	{ id = "recovery", label = "Recovery (life / ES per second)", stat = "_recovery", base = 0.02 },
	{ id = "area", label = "Area of effect", stat = "AreaOfEffectRadius", base = 10 },
}

-- A focus from the player's weights: { dps, ehp, avoid, clear, goals = { [id] = weight } }
function BuildScorerClass.CustomFocus(weights)
	weights = weights or { }
	local parts = { }
	-- (damage can be 0: a build made only to survive and move; a trace of it
	-- is kept so equal builds are still told apart by their damage)
	local focus = { id = "CUSTOM", dps = m_max(0.001, weights.dps or 1), ehp = weights.ehp or 0.5, avoid = weights.avoid or 0.3,
		clear = weights.clear or 0.2, hitTarget = 30000, extra = { } }
	for _, goal in ipairs(BuildScorerClass.goalList) do
		local w = weights.goals and weights.goals[goal.id]
		if w and w > 0 then
			t_insert(focus.extra, { stat = goal.stat, base = goal.base, weight = w })
			t_insert(parts, string.format("%s %g", goal.label:lower(), w))
		end
	end
	focus.label = string.format("Custom: damage %g, tankiness %g, avoidance %g, clear %g%s", focus.dps, focus.ehp, focus.avoid, focus.clear,
		#parts > 0 and (", " .. table.concat(parts, ", ")) or "")
	return focus
end

-- The custom goals' share of the score
function BuildScorerClass:GoalTerms(output)
	local extra = self.focus.extra
	if not extra or not output then return 0 end
	local total = 0
	for _, goal in ipairs(extra) do
		local value
		if goal.stat == "_block" then
			value = (output.EffectiveBlockChance or 0) + (output.EffectiveSpellBlockChance or 0)
		elseif goal.stat == "_recovery" then
			value = self:RecoveryRatio(output)
		else
			value = output[goal.stat] or 0
		end
		total = total + goal.weight * m_log(m_max(value, goal.base * 0.05) / goal.base)
	end
	return total
end

-- Survivability and clear bonuses added to the score
function BuildScorerClass:ExtraTerms(output)
	if not output then return 0 end
	-- (recovering 15% of the pool per second is plenty: more isn't worth a
	-- 6-link support slot, which a big recovery weight made Life Leech take)
	local ratio = m_min(0.15, m_max(0, self:RecoveryRatio(output)))
	local extra = self.focus.ehp * 0.4 * m_log(1 + 10 * ratio)
	extra = extra + ((self.focus.clear or 0) + (self.clearBoost or 0)) * self:ClearTerm(output)
	return extra
end

-- How much of a resource the build can spend per second over a long fight:
-- recovery (regen, leech, gain on hit, recovery flasks fed by charges, energy
-- shield with Eldritch Battery) plus the unreserved pool spread over the fight.
local fightLength = 60
-- other skills (movement, curses, guard...) also cost mana: the main skill
-- needs this much more recovery than its own cost
local costMargin = 1.15
-- (share of the cost a build must recover to count as paying for it all the time)
local sustainTolerance = 0.8
function BuildScorerClass:SustainableRate(output, resource)
	local recovery, pool = 0, 0
	if resource == "Mana" then
		recovery = (output.ManaRegenRecovery or output.ManaRegen or 0) + (output.ManaLeechGainRate or 0) + (output.ManaOnHitRate or 0)
		pool = math.max(0, output.ManaUnreserved or 0)
		if output.EnergyShieldProtectsMana then
			recovery = recovery + (output.EnergyShieldRegenRecovery or 0) + (output.EnergyShieldLeechGainRate or 0)
			pool = pool + (output.EnergyShield or 0)
		end
	else
		recovery = (output.LifeRegenRecovery or output.LifeRegen or 0) + (output.LifeLeechGainRate or 0) + (output.LifeOnHitRate or 0)
		pool = math.max(0, (output.LifeUnreserved or 0) * 0.5) -- keep half your life
	end
	-- recovery flasks: what they restore each use x uses per second from charges
	local itemsTab = self.build.itemsTab
	if itemsTab and self.chargesPerSecond > 0 then
		for _, slotName in ipairs({ "Flask 1", "Flask 2", "Flask 3", "Flask 4", "Flask 5" }) do
			local slot = itemsTab.slots[slotName]
			local item = slot and itemsTab.items[slot.selItemId]
			local fd = item and item.flaskData
			local total = fd and (resource == "Mana" and fd.manaTotal or resource == "Life" and fd.lifeTotal)
			if total and fd.chargesUsed and fd.chargesUsed > 0 then
				-- (half: recovery flasks must be pressed and overlap their own recovery)
				recovery = recovery + 0.5 * total * self.chargesPerSecond * (fd.gainMod or 1) / fd.chargesUsed
			end
		end
	end
	return recovery + pool / fightLength
end

-- Share of time the main skill can be paid for (1 = always)
function BuildScorerClass:SkillSustain(output)
	local fraction, limiting = 1, nil
	-- costs of unique drawbacks PoB doesn't calculate (mana lost on use, life
	-- sacrificed on cast...): the build's recovery must cover them too
	local env = self.build.calcsTab and self.build.calcsTab.mainEnv
	local flags = env and env.player.mainSkill and env.player.mainSkill.skillFlags or { }
	local extra = GetGeneratorRules().ExtraCosts(output, flags.attack, flags.spell)
	-- the damage the skill deals to its user (Boneshatter's trauma, Scold's
	-- Bridle, Heartbound Loop...: PoB's SelfHitDamage, per use) is a life
	-- cost too; one use taking the whole pool can't be used at all. Without
	-- it a Boneshatter at 120 trauma (12,316 to itself per hit, 5,313 life)
	-- scored its 34M DPS.
	local selfHit = output.SelfHitDamage or 0
	if selfHit > 0 then
		local uses = output.Speed or 0
		extra = { Mana = extra.Mana, Life = (extra.Life or 0) + selfHit * uses }
		local pool = (output.LifeUnreserved or output.Life or 0) + (output.EnergyShield or 0)
		if pool > 0 and selfHit >= pool then return 0, "Life" end
	end
	for _, resource in ipairs({ "Mana", "Life" }) do
		local perSecond = output[resource .. "PerSecondCost"] or 0
		-- totems and brands are placed again only when they expire, not at the
		-- placement / cast speed PoB's per-second cost assumes
		if perSecond > 0 and (flags.totem or flags.brand) and (output[resource .. "Cost"] or 0) > 0 then
			local count = flags.totem and (output.ActiveTotemLimit or 1) or (output.ActiveBrandLimit or 1)
			local duration = flags.totem and (output.TotemDuration or 8) or m_max(output.Duration or 4, 2)
			perSecond = m_min(perSecond, output[resource .. "Cost"] * m_max(1, count) / m_max(duration, 1))
		end
		local cost = (perSecond + (extra[resource] or 0)) * costMargin
		if cost > 0 then
			-- (calibrated on the top players' builds: a fifth of a long fight short
			-- of the cost is covered by flasks, pauses and positioning)
			local f = math.min(1, self:SustainableRate(output, resource) / cost / sustainTolerance)
			if f < fraction then fraction, limiting = f, resource end
		end
	end
	return fraction, limiting
end

-- Share of the DPS kept for the cost (1 = paid for all the time). Hard: the
-- share of time the skill can be paid for. Soft (while a build is being
-- made, softSustain): what is missing is a price, not a cut - recovery is a
-- cheap layer of its own (regeneration nodes and mods, Clarity, cost
-- reduction), so a shortfall of N per second costs about what the points
-- to recover it cost (N / 12 points at ~1.5% DPS each). With the hard cut, a
-- build at the edge of its mana saw every speed source as a loss (Badge of
-- the Brotherhood's frenzy charges: -8% DPS instead of +30%) and recovery
-- as worthless until something needed it: neither could come first.
function BuildScorerClass:SustainFactor(output)
	local fraction, resource = self:SkillSustain(output)
	-- (soft only for a shortfall recovery can close: below a fifth of the
	-- cost paid for, the hard cut - a degenerate build with an absurd hit rate
	-- and cost would otherwise keep its absurd DPS)
	if not self.softSustain or not resource or fraction >= 0.999 or fraction < 0.2 then return fraction, resource end
	local rate = self:SustainableRate(output, resource)
	local missing = rate * (1 / math.max(fraction, 0.05) - 1)
	local soft = math.exp(-(self.sustainPointValue or 0.015) * missing / (self.sustainPerPoint or 12))
	return math.max(fraction, soft), resource
end

-- DPS figure used for scoring (player + minions, full DPS when the build uses it)
function BuildScorerClass:HasSecondarySkill()
	for _, group in ipairs(self.build.skillsTab and self.build.skillsTab.socketGroupList or { }) do
		if group.enabled ~= false and group.includeInFullDPS and (group.label or ""):find("(generated secondary)", 1, true) then return true end
	end
	return false
end

-- Damage that builds up over time, as maps are played: PoB's damage over
-- time that stacks (Toxic Rain's spore pods - poewiki: "enemies can take
-- damage from multiple spore pods" - and poison) is the boss's steady state,
-- stacks = rate x duration, so a longer duration (More Duration in the main
-- link) adds damage there; a pack dies within a second or so, and over a
-- kill window W the stacks average rate x W/2 when the duration outlasts it
-- (rate x (D - D^2 / 2W) when shorter). The damage counted is the boss's
-- and the pack's, half each (geometric mean): duration is worth only the
-- boss half, damage per stack both.
local clearWindow, clearShare = 1.5, 0.5
local function rampShare(duration)
	if not duration or duration <= 0 then return 1 end
	if duration >= clearWindow then return (clearWindow / 2) / duration end
	return 1 - duration / (2 * clearWindow)
end
function BuildScorerClass:ClearRampDPS(output, dps)
	if dps <= 0 then return dps end
	local lost = 0
	local env = self.build.calcsTab and self.build.calcsTab.mainEnv
	local mainSkill = env and env.player and env.player.mainSkill
	if mainSkill and mainSkill.skillFlags and mainSkill.skillFlags.DotCanStack and (output.TotalDot or 0) > 0 then
		lost = lost + output.TotalDot * (1 - rampShare(output.Duration))
	end
	if (output.TotalPoisonDPS or 0) > 0 and (output.PoisonStacks or 0) > 1 then
		lost = lost + output.TotalPoisonDPS * (1 - rampShare(output.PoisonDuration))
	end
	if lost <= 0 then return dps end
	local clearDps = m_max(dps - lost, dps * 0.05)
	output.ClearRampDPS = clearDps
	return dps ^ (1 - clearShare) * clearDps ^ clearShare
end

function BuildScorerClass:GetDPS(output)
	local dps
	if output.FullDPS and output.FullDPS > 0 then
		dps = output.FullDPS
		-- (a generated second damage skill whose own cost isn't always paid:
		-- BuildGenerator:SecondaryDamageMove)
		if self.secondaryTrim and self:HasSecondarySkill() then dps = dps * self.secondaryTrim end
	else
		dps = (output.CombinedDPS or 0) + (output.Minion and output.Minion.CombinedDPS or 0)
	end
	-- skills whose parts add up on one target (SkillProfiles combine)
	if self.hitScale and output.TotalDPS then
		dps = dps + (self.hitScale - 1) * output.TotalDPS
	end
	if self.overlap then
		dps = self.overlap:AdjustDPS(output, dps)
	end
	if self.clearRamp ~= false then
		dps = self:ClearRampDPS(output, dps)
	end
	-- (no real build deals this: a calculation broken by an extreme value -
	-- speed reduced past -100%, a negative multiplier - scores nothing)
	if dps ~= dps or dps < 0 or dps > 1e11 then
		if os.getenv("DEBUG_ABSURD") and not self.absurdShown then
			self.absurdShown = true
			local keys = { }
			for _, k in ipairs({ "Speed", "HitTime", "HitSpeed", "AverageHit", "AverageDamage", "TotalDPS", "CombinedDPS", "FullDPS", "CritChance", "CritMultiplier", "ManaCost", "ManaPerSecondCost", "ColdHitAverage", "PowerCharges", "FrenzyCharges", "EnemyCurseLimit" }) do t_insert(keys, k .. "=" .. tostring(output[k])) end
			ConPrintf("[absurd dps] %s", table.concat(keys, " "))
		end
		return 0
	end
	-- a skill you can't pay for doesn't deal its DPS for long
	if self.resourceSustain ~= false and not self.ignoreCosts then
		dps = dps * (self:SustainFactor(output))
	end
	-- a boss fight as it is played: moving and dodging stop the hits
	if self.fightSim then
		dps = dps * (self:FightUptime(output))
	end
	return dps
end

-- The share of a boss fight the main skill's damage keeps going, as it is
-- played: a fifth of the fight is spent moving at normal movement speed
-- (less when faster: positioning, following the boss, ground effects), and
-- each big telegraphed hit (one every 10 seconds) the build can't take is
-- dodged for 0.8 seconds (none when it takes the hit twice over, all of it
-- below 60%). While moving, only damage that doesn't need the player keeps
-- going: totems, brands, traps, mines, minions, a channelled skill that moves
-- (Cyclone), and damage over time (ailments last through a short move).
-- Returns the share, and the moving and dodging shares of the fight.
local moveShare, bigHitEvery, dodgeTime = 0.2, 10, 0.8
function BuildScorerClass:FightUptime(output)
	local env = self.build.calcsTab and self.build.calcsTab.mainEnv
	local skill = env and env.player.mainSkill
	local flags = skill and skill.skillFlags or { }
	local types = skill and skill.skillTypes or { }
	local persist
	if flags.totem or flags.brand or flags.trap or flags.mine or flags.minion
		or (types[SkillType.Channel] and types[SkillType.Movement]) then
		persist = 1
	else
		-- (the damage over time share keeps going)
		-- (culling strike's share follows the hits)
		local total = (output.CombinedDPS or 0) - (output.CullingDPS or 0)
		local hits = output.TotalDPS or 0
		persist = total > 0 and m_max(0, m_min(1, 1 - hits / total)) or 0
	end
	local moving = moveShare / m_max(0.5, output.EffectiveMovementSpeedMod or 1)
	local ratio = self:BossHitRatio(output)
	local dodge = 0
	if ratio then
		local need = ratio >= 2 and 0 or ratio <= 0.6 and 1 or (2 - ratio) / 1.4
		dodge = need * dodgeTime / bigHitEvery
	end
	return 1 - (moving + dodge) * (1 - persist), moving, dodge
end

-- Effective hit pool, capped: immunities make PoB report infinite EHP, which
-- would make every other difference meaningless (poe.ninja caps at 10M too)
local maxEHP = 5000000
function BuildScorerClass:GetEHP(output)
	local ehp = output.TotalEHP or ((output.Life or 0) + (output.EnergyShield or 0))
	if ehp ~= ehp or ehp > maxEHP then ehp = maxEHP end
	return ehp
end

-- Things that make a build unplayable or clearly worse than its numbers say
function BuildScorerClass:GetPenalties(output)
	local penalties = { }
	local total = 0
	local missing = 0
	for _, elem in ipairs(elements) do
		missing = missing + m_max(0, output["Missing" .. elem .. "Resist"] or 0)
	end
	if missing > 0 and not self.ignoreRequirements then
		-- ailments and map mods hurt more than EHP shows; and a finished build
		-- below the cap is a mistake a player sees at once (a Slayer left 2%
		-- short on cold and lightning, 0.016 lost: the generator kept a damage
		-- craft over the resistance) - a step, then more per point
		local p = 0.3 + missing * 0.05
		total = total + p
		t_insert(penalties, { label = string.format("Elemental resistances %d%% below cap", missing), value = p })
	end
	for _, attr in ipairs(attributes) do
		local short = (output["Req" .. attr] or 0) - (output[attr] or 0)
		-- (ignoreAttributes: while choosing gems before the gear is made to supply them)
		if short > 0 and not self.ignoreAttributes and not self.ignoreRequirements then
			local p = 1 + short * 0.01
			total = total + p
			t_insert(penalties, { label = string.format("%d %s missing for gem/item requirements", short, attr), value = p })
		end
	end
	-- (Dissolution of the Flesh without a big life pool: no recovery during a
	-- fight - see RecoveryRatio - and every hit taken shrinks the pool until
	-- 2 seconds pass unhit, rare while mapping; worth it only on very high
	-- life, as players say)
	if self:DissolutionActive() and not self.ignoreRequirements then
		local life = output.Life or 0
		if life < 9000 then
			local p = 0.6 * m_log(9000 / m_max(life, 1000))
			total = total + p
			t_insert(penalties, { label = string.format("Dissolution of the Flesh on %d life (no recovery while hit, needs a very large pool)", life), value = p })
		end
	end
	-- Imbalanced Guard (poewiki): armour doubled against hits, damage
	-- reduction capped at 50% instead of 90% - better against a boss's big
	-- hits, worse against the many small hits of a map pack, where a lot of
	-- armour reduces far more than 50%. The map hit (1500 physical) taken
	-- with and without it; the loss counted (half the damage taken while
	-- mapping is physical, roughly)
	if (output.DamageReductionMax or 90) < 90 and (output.Armour or 0) > 0 and not self.ignoreRequirements then
		local armour, hit = output.Armour, 1500
		local cap = output.DamageReductionMax
		local without = m_min(90, 100 * armour / (armour + 5 * hit))
		local with = m_min(cap, 100 * 2 * armour / (2 * armour + 5 * hit))
		local factor = (1 - with / 100) / m_max(0.1, 1 - without / 100)
		if factor > 1.02 then
			local p = 0.3 * m_log(factor)
			total = total + p
			t_insert(penalties, { label = string.format("Damage reduction capped at %d%% (Imbalanced Guard): map hits reduced %d%% instead of %d%%", cap, with, without), value = p })
		end
	end
	for _, pool in ipairs({ "Mana", "Life" }) do
		local unreserved = output[pool .. "Unreserved"]
		if unreserved and unreserved < 0 and not self.ignoreReservation then
			-- (more the further over: passives with reservation efficiency, a
			-- few at a time, then show what they are worth to aura stacking)
			local over = -unreserved / m_max(output[pool] or 1, 1)
			local p = 2 + (self.reservationSlope or 4) * m_min(1, over)
			total = total + p
			t_insert(penalties, { label = string.format("%s reservation is over 100%% (by %d%%)", pool, over * 100), value = p })
		end
	end
	local sustain, limiting = self:SustainFactor(output)
	if sustain < 0.999 and not self.ignoreCosts then
		-- running out of mana mid-fight is worse than lower DPS: casting stops
		local p = 4 * (1 - sustain)
		total = total + p
		t_insert(penalties, { label = string.format("Can only pay for the main skill %d%% of the time in a long fight (%s recovery below its cost plus other skills); DPS is reduced to match", sustain * 100, limiting:lower()), value = p })
	end
	-- Self-damage over time (Righteous Fire, degen auras...) bigger than regeneration
	local deficit, degen = self:DegenDeficit(output)
	if deficit > 0 then
		local p = 4 + 6 * m_min(1, deficit / m_max(1, degen))
		total = total + p
		t_insert(penalties, { label = string.format("Self-damage over time is %.0f/s more than regeneration (%.0f/s degen): the build can't keep it up", deficit, degen), value = p })
	end
	-- Ailments and stuns the build isn't protected against (the generator turns
	-- this on once flasks are chosen: before that, rares would waste mods on
	-- ailment avoidance a flask suffix gives for free)
	local missingTotal, missingList = 0, { }
	if self.useChecklist ~= false then missingTotal, missingList = self:Checklist(output) end
	if missingTotal > 0 then
		local names = { }
		for _, entry in ipairs(missingList) do
			if not entry.ok then t_insert(names, entry.avoid and string.format("%s (%d%%)", entry.label, entry.avoid) or entry.label) end
		end
		total = total + missingTotal
		t_insert(penalties, { label = "Missing defences: " .. table.concat(names, ", "), value = missingTotal })
	end
	-- Gem colours an item can't realistically roll (six blue gems in a
	-- strength body armour...)
	if self.socketColours ~= false then
		for _, entry in ipairs(self:SocketColourIssues()) do
			total = total + entry.penalty
			t_insert(penalties, { label = entry.label, value = entry.penalty })
		end
	end
	-- Unique drawbacks the build doesn't counter (Modules/GeneratorRules)
	for _, p in ipairs(GetGeneratorRules().Penalties(output)) do
		total = total + p.value
		t_insert(penalties, p)
	end
	-- One-shot by a pinnacle boss hit
	local bossRatio, bossName = self:BossHitRatio(output)
	if bossRatio and bossRatio < 1 then
		-- Uber hits, calibrated on the top players' builds (half survive less
		-- than 58% of the worst, and dodge it): full weight below 60%, a light
		-- one from 60% to surviving it
		local p
		if self.bossTier == "uber" then
			local target = 0.6
			p = 1.5 * m_log(target / m_min(target, m_max(bossRatio, 0.01))) + 0.4 * m_log(1 / m_max(bossRatio, target))
		else
			p = 1.5 * m_log(1 / m_max(bossRatio, 0.01))
		end
		total = total + p
		t_insert(penalties, { label = string.format("One-shot by %s%s (survives %d%% of the hit)", self.bossTier == "uber" and "Uber " or "", bossName, bossRatio * 100), value = p })
	end
	-- Not being able to pay for the main skill
	local cost = output.ManaCost or 0
	if cost > 0 and output.ManaUnreserved and cost > output.ManaUnreserved and not self.ignoreReservation and not self.ignoreCosts then
		total = total + 1
		t_insert(penalties, { label = "Not enough unreserved mana to cast the main skill", value = 1 })
	end
	return total, penalties
end

-- Chance that n random sockets give at least the wanted number of each
-- colour (probabilities pr, pg, pb per socket)
local function colourChance(n, want, probs)
	local total = 0
	local fact = { [0] = 1 }
	for i = 1, n do fact[i] = fact[i - 1] * i end
	for r = 0, n do
		for g = 0, n - r do
			local b = n - r - g
			if r >= want[1] and g >= want[2] and b >= want[3] then
				total = total + fact[n] / (fact[r] * fact[g] * fact[b]) * probs[1] ^ r * probs[2] ^ g * probs[3] ^ b
			end
		end
	end
	return total
end
BuildScorerClass.ColourChance = colourChance

-- Items whose gems need socket colours that are very hard to roll: the
-- chromatic odds from the base's attribute requirements (weight 12 + the
-- requirement for each attribute the base asks for, 12 for the others),
-- with the crafting bench forcing up to three sockets of the hardest colour.
-- White sockets fit any gem. { { slot, label, penalty, chance } }
local colourNames = { "red", "green", "blue" }
function BuildScorerClass:SocketColourIssues()
	local build = self.build
	local itemsTab = build.itemsTab
	local skillsTab = build.skillsTab
	if not itemsTab or not skillsTab then return { } end
	local need = { }
	for _, group in ipairs(skillsTab.socketGroupList) do
		if group.enabled ~= false and group.slot and not group.source and itemsTab.slots[group.slot] then
			local counts = need[group.slot] or { 0, 0, 0 }
			for _, gem in ipairs(group.gemList) do
				local effect = gem.gemData and gem.gemData.grantedEffect
				local colour = effect and effect.color
				if gem.enabled ~= false and colour and colour >= 1 and colour <= 3 then counts[colour] = counts[colour] + 1 end
			end
			need[group.slot] = counts
		end
	end
	local issues = { }
	self.colourCache = self.colourCache or { }
	for slotName, counts in pairs(need) do
		local slot = itemsTab.slots[slotName]
		local item = slot and itemsTab.items[slot.selItemId]
		local n = counts[1] + counts[2] + counts[3]
		if item and item.base and n >= 4 then
			-- (white sockets fit anything)
			local white = 0
			for _, socket in ipairs(item.sockets or { }) do if socket.color == "W" then white = white + 1 end end
			local key = (item.baseName or "?") .. ":" .. counts[1] .. counts[2] .. counts[3] .. ":" .. white
			local chance = self.colourCache[key]
			if not chance then
				local req = item.base.req or { }
				local weights = { 12 + (req.str or 0), 12 + (req.dex or 0), 12 + (req.int or 0) }
				local sum = weights[1] + weights[2] + weights[3]
				local probs = { weights[1] / sum, weights[2] / sum, weights[3] / sum }
				local want = { counts[1], counts[2], counts[3] }
				-- white sockets take the hardest colours first
				for _ = 1, white do
					local worst, worstP
					for c = 1, 3 do if want[c] > 0 and (not worstP or probs[c] < worstP) then worst, worstP = c, probs[c] end end
					if worst then want[worst] = want[worst] - 1 end
				end
				-- the bench: up to three sockets of the hardest colour forced
				local hardest, hardestP
				for c = 1, 3 do if want[c] > 0 and (not hardestP or probs[c] < hardestP) then hardest, hardestP = c, probs[c] end end
				local rest = n - white
				if hardest then
					local forced = m_min(3, want[hardest])
					want[hardest] = want[hardest] - forced
					rest = rest - forced
				end
				chance = rest > 0 and colourChance(rest, want, probs) or 1
				self.colourCache[key] = chance
			end
			-- (a thousand chromatic orbs is affordable; past that it gets unrealistic)
			if chance < 1e-3 then
				local penalty = 0.4 * (m_log(1 / chance) / m_log(10) - 3)
				local parts = { }
				for c = 1, 3 do if counts[c] > 0 then t_insert(parts, counts[c] .. " " .. colourNames[c]) end end
				t_insert(issues, { slot = slotName, chance = chance, penalty = penalty,
					label = string.format("%s: %s gems on a %s base, about 1 in %s chromatic rolls", slotName, table.concat(parts, " + "), item.baseName or "?", chance > 0 and string.format("%.0f", 1 / chance) or "never") })
			end
		end
	end
	return issues
end

-- Smallest of the maximum hits the build survives (physical, elemental,
-- chaos): a build is only as tanky as its weakest damage type. Immunities
-- (e.g. chaos with Chaos Inoculation) are capped and don't hide the others.
-- Also returns the mean log of all of them (how tanky it is overall).
function BuildScorerClass:MinMaxHit(output)
	local lowest
	local sum, n = 0, 0
	for _, damageType in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
		local hit = output[damageType .. "MaximumHitTaken"]
		if hit and hit == hit then
			hit = m_max(1, m_min(hit, maxEHP))
			if not lowest or hit < lowest then lowest = hit end
			sum, n = sum + m_log(hit), n + 1
		end
	end
	return lowest, n > 0 and sum / n or nil
end

-- Pinnacle boss hits the build should survive (from PoB's boss skill presets;
-- telegraphed one-shots meant to be dodged - Atziri Flameblast, Sirus Meteor,
-- Maven's memory game - and damage over time are left out)
local bossHits = { "Shaper Ball", "Shaper Slam", "Exarch Ball", "Eater Beam", "Maven Fireball" }

-- How many times over the build survives the worst of those hits (1 = just
-- survives), using its maximum hit per damage type, with the boss's
-- penetration applied to resistances. Returns ratio, skill name.
function BuildScorerClass:BossHitRatio(output)
	if not (data.bossSkills and data.monsterDamageTable) then return nil end
	local configTab = self.build.configTab
	local level = configTab and configTab.enemyLevel or 84
	if level < 68 then level = 84 end
	local base = data.monsterDamageTable[m_min(level, #data.monsterDamageTable)]
	local uber = self.bossTier == "uber"
	local worst, worstName
	for _, name in ipairs(bossHits) do
		local boss = data.bossSkills[name]
		if boss and boss.DamageMultipliers then
			local mult = uber and boss.UberDamageMultiplier or 1
			local pens = uber and boss.UberDamagePenetrations or boss.DamagePenetrations or { }
			local sum = 0
			for damageType, m in pairs(boss.DamageMultipliers) do
				local damage = base * (m[1] + 70 * m[2]) * mult
				local hit = output[damageType .. "MaximumHitTaken"]
				if hit and hit == hit and hit > 0 then
					local pen = tonumber(pens[damageType .. "Pen"] or "")
					if pen and damageType ~= "Physical" then
						local res = (output[damageType .. "Resist"] or 0) / 100
						hit = hit * (1 - res) / m_max(0.01, 1 - (res - pen / 100))
					end
					sum = sum + damage / m_min(hit, maxEHP)
				end
			end
			if sum > 0 and (not worst or 1 / sum < worst) then worst, worstName = 1 / sum, name end
		end
	end
	return worst, worstName
end

-- The pressure of a pinnacle boss fight between its big telegraphed hits
-- (those are dodged, or taken as BossHitRatio says): its regular hits and
-- ground effects take a tenth of its worst hit each second (as a share of
-- the life + energy shield pool: 0.1 / BossHitRatio), less what evasion,
-- block and suppression avoid (DamageTakenShare), against what the build
-- recovers (RecoveryRatio: leech, regeneration, recoup...). Simulated a
-- tenth of a second at a time; returns the seconds survived (out of 60) and
-- the lowest share of the pool.
local fightLength = 60
function BuildScorerClass:FightSurvival(output)
	local ratio = self:BossHitRatio(output)
	if not ratio or ratio <= 0 then return nil end
	local drain = 0.1 / ratio * self:DamageTakenShare(output)
	local recovery = m_max(0, self:RecoveryRatio(output))
	local pool, lowest = 1, 1
	local step = 0.1
	for i = 1, fightLength / step do
		pool = pool - drain * step
		if pool <= 0 then return i * step, 0 end
		lowest = m_min(lowest, pool)
		pool = m_min(1, pool + recovery * step)
	end
	return fightLength, lowest
end

-- Things every endgame build needs that hit pools don't show: being frozen,
-- shocked, bled... Each missing one costs score (flask immunities count while
-- the flask is up). Returns total, { { label, value, ok } }
local checklist = {
	{ key = "FreezeAvoidChance", label = "Freeze immunity", weight = 0.6 },
	{ key = "ShockAvoidChance", label = "Shock avoidance", weight = 0.3 },
	{ key = "BleedAvoidChance", label = "Bleed immunity", weight = 0.25 },
	{ key = "IgniteAvoidChance", label = "Ignite avoidance", weight = 0.15 },
	{ key = "ChillAvoidChance", label = "Chill avoidance", weight = 0.15 },
	{ key = "PoisonAvoidChance", label = "Poison avoidance", weight = 0.1 },
	{ key = "StunAvoidChance", label = "Stun avoidance", weight = 0.15 },
}
function BuildScorerClass:Checklist(output)
	local total, list = 0, { }
	for _, entry in ipairs(checklist) do
		local avoid = output[entry.key]
		if avoid then
			local missing = 1 - m_min(100, m_max(0, avoid)) / 100
			local value = entry.weight * missing
			total = total + value
			t_insert(list, { label = entry.label, value = value, ok = missing <= 0.001, avoid = avoid })
		end
	end
	if output.CorruptedBloodImmunity == false then
		total = total + 0.1
		t_insert(list, { label = "Corrupted Blood immunity", value = 0.1, ok = false })
	elseif output.CorruptedBloodImmunity then
		t_insert(list, { label = "Corrupted Blood immunity", value = 0, ok = true })
	end
	return total, list
end

-- Share of incoming hit damage the build takes on average (melee,
-- projectile, spell, spell projectile hits): evasion, dodge and avoidance,
-- then block (with its block effect) and spell suppression. 1 = takes every
-- hit in full. EHP counts these too, but only as a small part of tankiness,
-- which left block, suppression and evasion worth less than a few % damage.
function BuildScorerClass:DamageTakenShare(output)
	local function chance(key) return m_min(1, m_max(0, (output[key] or 0) / 100)) end
	local blockEffect = m_min(1, m_max(0, (output.BlockEffect or 100) / 100))
	local suppress = chance("EffectiveSpellSuppressionChance") * m_min(1, m_max(0, (output.SpellSuppressionEffect or 50) / 100))
	local function taken(notHit, block, spell)
		return (1 - chance(notHit)) * (1 - chance(block) * blockEffect) * (spell and (1 - suppress) or 1)
	end
	local share = (taken("MeleeNotHitChance", "EffectiveBlockChance")
		+ taken("ProjectileNotHitChance", "EffectiveProjectileBlockChance")
		+ taken("SpellNotHitChance", "EffectiveSpellBlockChance", true)
		+ taken("SpellProjectileNotHitChance", "EffectiveSpellProjectileBlockChance", true)) / 4
	return m_max(0.05, m_min(1, share))
end

function BuildScorerClass:ScoreFromValues(dps, ehp, penalty, output)
	-- tankiness: mostly the maximum hit the build survives (the weakest damage
	-- type first, then all of them), a little effective hit pool. EHP counts
	-- block, evasion and suppression as averages, so a build can have huge EHP
	-- and still die to one hit; max hit is the consistent part.
	local minHit, meanLogHit
	if output then minHit, meanLogHit = self:MinMaxHit(output) end
	local tank
	local bossRatio = output and self:BossHitRatio(output)
	-- defence layers have targets: past them each layer is worth less (a
	-- third), so damage isn't traded for tankiness the build doesn't need
	-- (targets: hitTarget, or 2.5x the focus's max hit floor; taking the
	-- toughest boss hit twice over)
	local hitTarget = self.hitTarget or self.focus.hitTarget or ((self.hitFloor or self.focus.hitFloor) and 2.5 * (self.hitFloor or self.focus.hitFloor))
	local past = self.pastTarget or 0.35
	local function layer(value, target)
		if not target or value <= target then return m_log(value) end
		return m_log(target) + past * m_log(value / target)
	end
	if minHit and bossRatio then
		-- (boss hits: how many times over the build takes the worst pinnacle hit)
		tank = 0.15 * m_log(m_max(ehp, 1)) + 0.35 * layer(minHit, hitTarget) + 0.2 * layer(m_exp(meanLogHit), hitTarget and hitTarget * 2)
			+ 0.3 * layer(m_max(bossRatio, 0.01) * 10000, 20000)
	elseif minHit then
		tank = 0.15 * m_log(m_max(ehp, 1)) + 0.55 * layer(minHit, hitTarget) + 0.3 * layer(m_exp(meanLogHit), hitTarget and hitTarget * 2)
	else
		tank = m_log(m_max(ehp, 1))
	end
	-- (killing fast is a defence too: a boss dead in 10 seconds throws fewer
	-- of its hits than one fought for 60. The risk scales with the time the
	-- fight lasts, life of the boss over the DPS, down to the phases and
	-- invulnerable time no damage shortens. Counted in the defences, after
	-- the max hit layers that no speed of kill changes)
	if output and self.killTimeDefence ~= false then
		local bossLife = self.bossLife or (self.bossTier == "uber" and 3e8 or 1e8)
		local fight = m_max(self.minFightTime or 8, bossLife / m_max(dps, 1))
		tank = tank + (self.killTimeWeight or 0.25) * m_log(60 / fight)
	end
	local score = self.focus.dps * m_log(m_max(dps, 1)) + self.focus.ehp * tank - penalty + self:ExtraTerms(output) + self:GoalTerms(output)
	-- avoiding, blocking and suppressing hits (see DamageTakenShare): its own
	-- weight, as top players value it (max block or 100% suppression is worth
	-- about as much as doubling the damage to them)
	-- an archetype's commitment (e.g. Intelligence stacking): its stat counts
	-- on its own while the build is made, so gear, passives and jewels follow
	-- it before the uniques that pay it back are complete. Left out of the
	-- final score, which compares archetypes as they are.
	if self.lens2 and output then
		-- (lens.func: a computed layer, e.g. the build doctor's crit factor)
		local value = self.lens2.func and self.lens2.func(output) or output[self.lens2.stat] or 0
		score = score + (self.lens2.weight or 0.2) * m_log(m_max(1, value) / (self.lens2.base or 100))
	end
	if self.lens and output then
		local value = self.lens.func and self.lens.func(output) or output[self.lens.stat] or 0
		score = score + (self.lens.weight or 0.3) * m_log(m_max(1, value) / (self.lens.base or 100))
	end
	-- (the commitment of an archetype the player chose: below its floor the
	-- build is not what was asked for - BuildGenerator keepCommitment)
	if self.commitFloor and output then
		local floor = self.commitFloor
		local value = floor.func and floor.func(output) or output[floor.stat] or 0
		if value < floor.min then
			score = score - 3 * m_log(floor.min / m_max(value, floor.min * 0.05))
		end
	end
	-- (several layers committed to at once: the build doctor's joint plans)
	if self.lensExtra and output then
		for _, lens in ipairs(self.lensExtra) do
			local value = lens.func and lens.func(output) or output[lens.stat] or 0
			score = score + (lens.weight or 0.3) * m_log(m_max(1e-6, value) / (lens.base or 100))
		end
	end
	-- surviving a whole boss fight (FightSurvival): dying early costs, a fight
	-- survived with room to spare gains a little (a defence layer with a target)
	if output and self.fightSim ~= false then
		local seconds, lowest = self:FightSurvival(output)
		if seconds then
			local fight = m_log((seconds + 6) / (fightLength + 6)) + 0.15 * m_min(lowest, 0.5)
			score = score + (self.focus.ehp or 0.5) * (self.fightWeight or 1.5) * fight
		end
	end
	-- (a layer with a target too: taking half the hit damage on average; past
	-- it, more avoidance counts for a third)
	local avoidWeight = self.avoidanceWeight or self.focus.avoid or 0
	if output and avoidWeight > 0 then
		local avoided = m_log(1 / self:DamageTakenShare(output))
		local target = m_log(2)
		if avoided > target then avoided = target + (self.pastTarget or 0.35) * (avoided - target) end
		score = score + avoidWeight * avoided
	end
	-- below the EHP floor, every missing bit costs more than damage can pay back
	local floor = self.ehpFloor or self.focus.ehpFloor
	if floor and ehp < floor then
		score = score - 3 * m_log(floor / m_max(ehp, 1))
	end
	-- same for the max hit floor (weakest damage type)
	local hitFloor = self.hitFloor or self.focus.hitFloor
	if hitFloor and minHit and minHit < hitFloor then
		score = score - 3 * m_log(hitFloor / minHit)
	end
	return score
end

-- Score straight from a calculator output (flask uptime applied as fixed ratios)
function BuildScorerClass:ScoreOutput(output, ratio)
	local dps, ehp = self:GetDPS(output), self:GetEHP(output)
	if ratio then
		dps, ehp = dps * ratio.dps, ehp * ratio.ehp
	end
	return self:ScoreFromValues(dps, ehp, (self:GetPenalties(output)), output)
end

-- Passives whose effect PoB doesn't calculate (GeneratorRules.uncountedNodes:
-- ignite spread from Fan the Flames...), valued for the build. Counts the
-- allocated passives and those a calculation adds (virtual cluster notables
-- are named "notable:<name>").
function BuildScorerClass:UncountedBonus(output, override)
	local rules = GetGeneratorRules()
	local known = rules.uncountedNodes
	if not known or not self.build.spec or self.uncounted == false then return 0 end
	override = override or { }
	local found = { }
	local function consider(node)
		local name = node and (node.dn or node.name)
		if name then
			name = name:gsub("^notable:", "")
			if known[name] then found[name] = true end
		end
	end
	local removed = override.removeNodes or { }
	for _, node in pairs(self.build.spec.allocNodes) do
		if not removed[node] then consider(node) end
	end
	for node in pairs(override.addNodes or { }) do consider(node) end
	local names = { }
	for name in pairs(found) do t_insert(names, name) end
	if #names == 0 then return 0 end
	table.sort(names)
	return rules.UncountedBonus(names, self:RuleContext(output))
end

-- What the uncounted passive rules look at
function BuildScorerClass:RuleContext(output)
	local build = self.build
	local env = build.calcsTab and build.calcsTab.mainEnv
	local mainSkill = env and env.player and env.player.mainSkill
	local skill = { }
	for skillType, on in pairs(mainSkill and mainSkill.skillTypes or { }) do
		for name, value in pairs(SkillType) do
			if value == skillType and on then skill[name] = true end
		end
	end
	local supports, heralds, auras = { }, 0, 0
	for _, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or { }) do
		if group.enabled ~= false then
			for _, gem in ipairs(group.gemList or { }) do
				local gd = gem.gemData
				if gd and gem.enabled ~= false then
					if group == build.skillsTab.socketGroupList[build.mainSocketGroup] and gd.grantedEffect.support then supports[gd.name] = true end
					if not gd.grantedEffect.support and gd.tags then
						if gd.tags.herald then heralds = heralds + 1 elseif gd.tags.aura then auras = auras + 1 end
					end
				end
			end
		end
	end
	local itemsTab = build.itemsTab
	return {
		output = output, focus = self.focus, skill = skill, mainSkill = mainSkill, heralds = heralds, auras = auras,
		hasSupport = function(name) return supports[name] or false end,
		itemHas = function(pattern)
			for _, slot in ipairs(itemsTab and itemsTab.orderedSlots or { }) do
				local item = itemsTab.items[slot.selItemId]
				if item then
					for _, list in ipairs({ item.explicitModLines or { }, item.implicitModLines or { }, item.enchantModLines or { } }) do
						for _, modLine in ipairs(list) do
							if modLine.line and modLine.line:match(pattern) then return true end
						end
					end
				end
			end
			return false
		end,
		uses = function(charge) return build.configTab and build.configTab.input["use" .. charge .. "Charges"] or false end,
	}
end

-- Is a flask a utility flask (not life / mana / hybrid)?
local function isUtilityFlask(item)
	return item.base and item.base.flask and not (item.base.flask.life or item.base.flask.mana)
end
-- A life / mana flask with an effect of its own while it is up (Lavianga's
-- Spirit: no mana cost during its effect; Dying Sun...): up only part of the
-- time like a utility flask, not counted as always on
local function hasFlaskEffect(item)
	if not (item.base and item.base.flask) or item.rarity ~= "UNIQUE" then return false end
	for _, l in ipairs(item.explicitModLines or { }) do
		local line = (l.line or ""):lower()
		if line:find("during flask effect", 1, true) or line:find("during effect", 1, true) then return true end
	end
	return false
end

-- Estimated share of time a utility flask is up (0 to 1)
-- (output: the build's, for the hits it takes - "Gain 2 Charges when you are
-- Hit by an Enemy" fills a flask as fast as the build lets itself be hit: a
-- build that tanks rather than avoids gets the most from it)
function BuildScorerClass:FlaskUptime(item, modDB, output)
	local fd = item.flaskData
	if not fd or not fd.duration or fd.duration <= 0 then
		return 1
	end
	local durationInc = modDB:Sum("INC", nil, "FlaskDuration")
	local duration = fd.duration * (1 + durationInc / 100)
	local chargesUsed = (fd.chargesUsed or 0) * (1 + modDB:Sum("INC", nil, "FlaskChargesUsed") / 100)
	if chargesUsed <= 0 then
		return 1
	end
	if chargesUsed > (fd.chargesMax or 0) then
		return 0
	end
	local gainedInc = modDB:Sum("INC", nil, "FlaskChargesGained") + modDB:Sum("INC", nil, "FlaskChargeRecovery")
	local rate = self.chargesPerSecond * (1 + gainedInc / 100) * modDB:More(nil, "FlaskChargesGained") * (fd.gainMod or 1)
	rate = rate + modDB:Sum("BASE", nil, "FlaskChargesGenerated") + modDB:Sum("BASE", nil, "UtilityFlaskChargesGenerated")
	local onHit = 0
	for _, modLine in ipairs(item.explicitModLines or { }) do
		local n = (modLine.line or ""):match("^Gain (%d+) Charges? when you are Hit by an Enemy")
		if n then onHit = onHit + tonumber(n) end
	end
	if onHit > 0 then
		-- (a boss's regular hits, about one a second, less those evaded, blocked or suppressed)
		local hits = (self.enemyHitsPerSecond or 1) * (output and self:DamageTakenShare(output) or 1)
		rate = rate + onHit * hits * (1 + gainedInc / 100) * (fd.gainMod or 1)
	end
	if rate <= 0 then
		return 0
	end
	-- (Enkindling enchantments: no charges while it is up)
	local noGainDuring = false
	for _, modLine in ipairs(item.enchantModLines or { }) do
		if modLine.line:lower():match("gains no charges during effect") then noGainDuring = true end
	end
	return self.SimulateFlask(duration, chargesUsed, fd.chargesMax or chargesUsed, rate, noGainDuring)
end

-- A minute of fighting, a tenth of a second at a time: the flask is used
-- whenever it is down and has the charges, charges come in at the rate
-- (none while it is up with Enkindling) and stop at the maximum. Returns the
-- share of the time it is up. Unlike the average (duration x rate / charges
-- used), this sees the charges lost at the maximum and the refill gaps.
-- (the minute counted comes after two minutes of the same: the charges
-- carried in from the start of a fight don't count, what it keeps up does)
local fightSeconds, warmSeconds, step = 60, 120, 0.1
function BuildScorerClass.SimulateFlask(duration, chargesUsed, chargesMax, rate, noGainDuring)
	local charges, left, up = chargesMax, 0, 0
	local warm, steps = warmSeconds / step, (warmSeconds + fightSeconds) / step
	for i = 1, steps do
		if left <= 0 and charges >= chargesUsed then
			charges = charges - chargesUsed
			left = duration
		end
		if left > 0 then
			if i > warm then up = up + 1 end
			left = left - step
		end
		if not (noGainDuring and left > 0) then
			charges = m_min(chargesMax, charges + rate * step)
		end
	end
	return up / (steps - warm)
end

-- Estimated share of time a tincture is up (0 to 1): mana burn stacks build up
-- while it is active (one every manaBurn seconds, each 1% of mana lost per
-- second), so it stays on until the mana pool runs dry, then waits its cooldown
function BuildScorerClass:TinctureUptime(item, modDB, output)
	local td = item.tinctureData
	if not td or not td.manaBurn then return 1 end
	if modDB and modDB:Sum("BASE", nil, "TincturesNotInflictManaBurn") >= 100 then return 1 end
	local b = td.manaBurn
	local mana = output and output.Mana or 0
	local regen = output and (output.ManaRegenRecovery or output.ManaRegen) or 0
	local r = mana > 0 and regen / mana * 100 or 0
	-- seconds until the burn (t^2 / 2b % of mana) outweighs the pool and its regeneration
	local active = b * r + math.sqrt((b * r) ^ 2 + 200 * b)
	local cooldown = td.cooldown or 8
	return m_min(1, active / (active + cooldown))
end

-- The item a calculation sees in a slot, taking swapped items into account
function BuildScorerClass:ItemInSlot(slot, override)
	override = override or { }
	if override.repItems and override.repItems[slot.slotName] ~= nil then
		return override.repItems[slot.slotName] or nil
	elseif override.repSlotName == slot.slotName then
		return override.repItem
	end
	return self.build.itemsTab.items[slot.selItemId]
end

-- Lists the active utility flasks of a calculation, with their uptime.
-- Flasks forced on by Mageblood-like effects are permanent (uptime 1).
function BuildScorerClass:GetFlaskUptimes(override)
	local calcs = self.build.calcsTab.calcs
	local env = calcs.initEnv(self.build, "CALCULATOR", override)
	calcs.perform(env)
	local modDB = env.player.modDB
	local permanent = { }
	local left = modDB:Sum("BASE", nil, "LeftActiveMagicUtilityFlasks")
	local right = modDB:Sum("BASE", nil, "RightActiveMagicUtilityFlasks")
	local magic = { }
	if left > 0 or right > 0 then
		for _, slot in ipairs(self.build.itemsTab.orderedSlots) do
			local item
			if env.flaskSlotItems then
				item = env.flaskSlotItems[slot.slotName]
			else
				item = self:ItemInSlot(slot, override)
			end
			if item and item.type == "Flask" and item.rarity == "MAGIC" and isUtilityFlask(item) then
				t_insert(magic, item)
			end
		end
		for i = 1, m_min(left, #magic) do
			permanent[magic[i]] = true
		end
		for i = #magic, m_max(#magic - right + 1, 1), -1 do
			permanent[magic[i]] = true
		end
	end
	local list = { }
	for item in pairs(env.flasks) do
		if isUtilityFlask(item) or hasFlaskEffect(item) then
			local uptime
			if permanent[item] then
				uptime = 1
			elseif (left > 0 or right > 0) and item.rarity == "MAGIC" then
				uptime = 0 -- "Magic Utility Flasks cannot be Used"
			else
				uptime = self:FlaskUptime(item, modDB, env.player.output)
			end
			t_insert(list, { item = item, uptime = uptime, permanent = permanent[item] or false })
		end
	end
	for item in pairs(env.tinctures or { }) do
		t_insert(list, { item = item, uptime = self:TinctureUptime(item, modDB, env.player.output), permanent = false, tincture = true })
	end
	return list, env
end

-- Full evaluation of a candidate state.
-- calcFunc: from calcsTab:GetMiscCalculator(); override: calculator override
-- opts.flasks: "full" (measure each flask), "ratio" (reuse ratios), or false
-- Returns { score, dps, ehp, rawDps, rawEhp, penalty, penalties, output, flasks }
-- Does a calculation have lines that work while stationary ("while you are
-- Stationary": Chieftain's Ramako, Rational Doctrine, armour masteries)?
-- (from the calculation's own mods, Modules/Calcs: a candidate node or item counts)
function BuildScorerClass:StationaryRelevant(output)
	return GeneratorOutputStationary and GeneratorOutputStationary[output] or false
end

function BuildScorerClass:Evaluate(calcFunc, override, opts)
	opts = opts or { }
	override = override or { }
	-- A boss fight is mostly fought standing in place (the fight simulation
	-- charges the time spent moving and dodging): the build is calculated
	-- stationary, and when it has "while stationary" lines its damage is
	-- blended with the damage it keeps while moving for that share (below).
	-- Without it those lines (Ramako's -20% fire resistance against damage
	-- over time, Consecrated Ground) were never counted: Pohx's Righteous Fire
	-- deals 2.3 times as much stationary. (Stationary changes nothing for a
	-- build without such lines: one calculation either way; the moving one is
	-- made on full evaluations and its ratio reused by the quick ones.)
	local moveOverride
	if (self.fightSim or self.stationaryBlend) and self.stationaryBlend ~= false
		and not (self.build.configTab and self.build.configTab.input.conditionStationary) then
		moveOverride = override
		local copy = { }
		for k, v in pairs(override) do copy[k] = v end
		copy.conditions = { "Stationary" }
		for _, c in ipairs(override.conditions or { }) do t_insert(copy.conditions, c) end
		override = copy
	end
	local output = calcFunc(override, opts.useFullDPS)
	if moveOverride and not self:StationaryRelevant(output) then moveOverride = nil end
	local rawDps, rawEhp = self:GetDPS(output), self:GetEHP(output)
	local dps, ehp = rawDps, rawEhp
	local flasks
	local mode = self.flaskRealism and (opts.flasks or "full")
	if mode == "full" then
		local list = self:GetFlaskUptimes(override)
		flasks = list
		for _, entry in ipairs(list) do
			-- (smooth play: a buff that comes and goes counts for less than its
			-- average, and one up less than half the time not at all)
			if self.smoothBuffs ~= false and entry.uptime < 0.999 then
				entry.rawUptime = entry.uptime
				entry.uptime = entry.uptime < 0.5 and 0 or entry.uptime ^ 1.5
			end
			if entry.uptime < 1 then
				local off = { }
				for k, v in pairs(override) do off[k] = v end
				if entry.tincture then off.toggleTincture = entry.item else off.toggleFlask = entry.item end
				local offOutput = calcFunc(off, opts.useFullDPS)
				local offDps, offEhp = self:GetDPS(offOutput), self:GetEHP(offOutput)
				entry.dpsShare = rawDps > 0 and (rawDps - offDps) / rawDps or 0
				entry.ehpShare = rawEhp > 0 and (rawEhp - offEhp) / rawEhp or 0
				dps = dps - (1 - entry.uptime) * (rawDps - offDps)
				ehp = ehp - (1 - entry.uptime) * (rawEhp - offEhp)
			end
		end
		self.lastFlaskRatio = { dps = rawDps > 0 and dps / rawDps or 1, ehp = rawEhp > 0 and ehp / rawEhp or 1 }
	elseif mode == "ratio" and opts.ratio then
		dps = rawDps * opts.ratio.dps
		ehp = rawEhp * opts.ratio.ehp
	end
	local stationaryShare
	if moveOverride and rawDps > 0 then
		-- (moving + dodging share m, damage that keeps going while moving p:
		-- stationary damage S for 1 - m, the moving damage M for m p, where
		-- GetDPS charged S for (1 - m (1 - p)))
		local r = self.stationaryRatio
		if opts.flasks ~= "ratio" or not r then
			r = m_min(1, self:GetDPS(calcFunc(moveOverride, opts.useFullDPS)) / rawDps)
			self.stationaryRatio = r
		end
		local uptime, moving, dodge = self:FightUptime(output)
		local m = (moving or 0) + (dodge or 0)
		local p = m > 0 and m_max(0, m_min(1, 1 - (1 - uptime) / m)) or 1
		-- (without the fight simulation nothing stops while moving: only the
		-- stationary lines are lost for that share)
		if not self.fightSim then p = 1 end
		local blend = ((1 - m) + r * m * p) / m_max(1e-6, 1 - m * (1 - p))
		dps = dps * blend
		stationaryShare = 1 - r
	end
	self.lastStationaryShare = stationaryShare
	local penalty, penalties = self:GetPenalties(output)
	local bonus = self:UncountedBonus(output, override)
	return {
		score = self:ScoreFromValues(dps, ehp, penalty, output) + bonus,
		uncounted = bonus,
		dps = dps,
		ehp = ehp,
		rawDps = rawDps,
		rawEhp = rawEhp,
		penalty = penalty,
		penalties = penalties,
		output = output,
		flasks = flasks,
	}
end
