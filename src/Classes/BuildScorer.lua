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
--         + clearWeight * clear term - penalties
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local m_log = math.log
local m_max = math.max
local m_min = math.min
local m_floor = math.floor

---@class BuildScorer
local BuildScorerClass = newClass("BuildScorer")

BuildScorerClass.focusList = {
	{ label = "Balanced (damage, tankiness, clear)", id = "BALANCED", dps = 1, ehp = 1, clear = 0.4 },
	{ label = "Damage first", id = "DPS", dps = 1, ehp = 0.35, clear = 0.2 },
	{ label = "Tankiness first", id = "TANK", dps = 0.35, ehp = 1, clear = 0.2 },
	{ label = "Damage, with a minimum max hit (every damage type)", id = "DPS_FLOOR", dps = 1, ehp = 0.15, hitFloor = 10000, clear = 0.25 },
	{ label = "Mapping (clear speed first)", id = "CLEAR", dps = 0.7, ehp = 0.6, clear = 1 },
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
function BuildScorerClass:Recovery(output)
	local life = output.ComprehensiveNetLifeRegen or output.NetLifeRegen or output.LifeRegenRecovery or 0
	local es = output.ComprehensiveNetEnergyShieldRegen or output.NetEnergyShieldRegen or output.EnergyShieldRegenRecovery or 0
	local leech = (output.LifeLeechGainRate or 0) + (output.EnergyShieldLeechGainRate or 0)
	local onKill = ((output.LifeOnKill or 0) + (output.EnergyShieldOnKill or 0)) * self.killsPerSecond
	local recharge = (output.EnergyShieldRecharge or 0) * 0.25
	return life + es + leech * 0.8 + onKill + recharge
end

-- Recovery per second as a share of the life + energy shield pool. Each pool
-- only counts what it can hold (regenerating a 1 life pool under Chaos
-- Inoculation is worth nothing), over at least a normal sized pool.
function BuildScorerClass:RecoveryRatio(output)
	local lifePool = m_max(0, output.Life or 0)
	local esPool = m_max(0, output.EnergyShield or 0)
	local lifeSide = (output.ComprehensiveNetLifeRegen or output.NetLifeRegen or output.LifeRegenRecovery or 0)
		+ (output.LifeLeechGainRate or 0) * 0.8 + (output.LifeOnKill or 0) * self.killsPerSecond
	local esSide = (output.ComprehensiveNetEnergyShieldRegen or output.NetEnergyShieldRegen or output.EnergyShieldRegenRecovery or 0)
		+ (output.EnergyShieldLeechGainRate or 0) * 0.8 + (output.EnergyShieldOnKill or 0) * self.killsPerSecond
		+ (output.EnergyShieldRecharge or 0) * 0.25
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

-- Clear speed term: movement speed, area or projectiles, explosions on kill
function BuildScorerClass:ClearTerm(output)
	local ms = m_max(0.2, output.EffectiveMovementSpeedMod or 1)
	local radius = output.AreaOfEffectRadius
	local areaFactor = radius and m_min(4, m_max(0.3, (radius / 18) ^ 2)) or 1
	local projectiles = (output.ProjectileCount or 1) - 1 + 0.5 * m_min(4, output.PierceCount or 0) + 0.7 * m_min(4, output.ChainMax or 0)
	local projFactor = 1 + 0.25 * m_max(0, projectiles)
	local explode = output.ClearExplodeValue or 0
	return 0.6 * m_log(ms) + 0.25 * m_log(areaFactor * projFactor) + m_log(1 + 3 * explode)
end

-- Survivability and clear bonuses added to the score
function BuildScorerClass:ExtraTerms(output)
	if not output then return 0 end
	local ratio = m_max(0, self:RecoveryRatio(output))
	local extra = self.focus.ehp * 0.6 * m_log(1 + 10 * ratio)
	extra = extra + (self.focus.clear or 0) * self:ClearTerm(output)
	return extra
end

-- How much of a resource the build can spend per second over a long fight:
-- recovery (regen, leech, gain on hit, recovery flasks fed by charges, energy
-- shield with Eldritch Battery) plus the unreserved pool spread over the fight.
local fightLength = 60
-- other skills (movement, curses, guard...) also cost mana: the main skill
-- needs this much more recovery than its own cost
local costMargin = 1.15
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
	for _, resource in ipairs({ "Mana", "Life" }) do
		local cost = (output[resource .. "PerSecondCost"] or 0) * costMargin
		if cost > 0 then
			local f = math.min(1, self:SustainableRate(output, resource) / cost)
			if f < fraction then fraction, limiting = f, resource end
		end
	end
	return fraction, limiting
end

-- DPS figure used for scoring (player + minions, full DPS when the build uses it)
function BuildScorerClass:GetDPS(output)
	local dps
	if output.FullDPS and output.FullDPS > 0 then
		dps = output.FullDPS
	else
		dps = (output.CombinedDPS or 0) + (output.Minion and output.Minion.CombinedDPS or 0)
	end
	if self.overlap then
		dps = self.overlap:AdjustDPS(output, dps)
	end
	-- a skill you can't pay for doesn't deal its DPS for long
	if self.resourceSustain ~= false then
		dps = dps * (self:SkillSustain(output))
	end
	return dps
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
	if missing > 0 then
		-- ailments and map mods hurt more than EHP shows
		local p = missing * 0.004
		total = total + p
		t_insert(penalties, { label = string.format("Elemental resistances %d%% below cap", missing), value = p })
	end
	for _, attr in ipairs(attributes) do
		local short = (output["Req" .. attr] or 0) - (output[attr] or 0)
		-- (ignoreAttributes: while choosing gems before the gear is made to supply them)
		if short > 0 and not self.ignoreAttributes then
			local p = 1 + short * 0.01
			total = total + p
			t_insert(penalties, { label = string.format("%d %s missing for gem/item requirements", short, attr), value = p })
		end
	end
	for _, pool in ipairs({ "Mana", "Life" }) do
		local unreserved = output[pool .. "Unreserved"]
		if unreserved and unreserved < 0 then
			total = total + 2
			t_insert(penalties, { label = pool .. " reservation is over 100%", value = 2 })
		end
	end
	local sustain, limiting = self:SkillSustain(output)
	if sustain < 0.999 then
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
	-- Ailments and stuns the build isn't protected against
	local missingTotal, missingList = self:Checklist(output)
	if missingTotal > 0 then
		local names = { }
		for _, entry in ipairs(missingList) do
			if not entry.ok then t_insert(names, entry.avoid and string.format("%s (%d%%)", entry.label, entry.avoid) or entry.label) end
		end
		total = total + missingTotal
		t_insert(penalties, { label = "Missing defences: " .. table.concat(names, ", "), value = missingTotal })
	end
	-- One-shot by a pinnacle boss hit
	local bossRatio, bossName = self:BossHitRatio(output)
	if bossRatio and bossRatio < 1 then
		local p = 1.5 * m_log(1 / m_max(bossRatio, 0.01))
		total = total + p
		t_insert(penalties, { label = string.format("One-shot by %s%s (survives %d%% of the hit)", self.bossTier == "uber" and "Uber " or "", bossName, bossRatio * 100), value = p })
	end
	-- Not being able to pay for the main skill
	local cost = output.ManaCost or 0
	if cost > 0 and output.ManaUnreserved and cost > output.ManaUnreserved then
		total = total + 1
		t_insert(penalties, { label = "Not enough unreserved mana to cast the main skill", value = 1 })
	end
	return total, penalties
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

function BuildScorerClass:ScoreFromValues(dps, ehp, penalty, output)
	-- tankiness: mostly the maximum hit the build survives (the weakest damage
	-- type first, then all of them), a little effective hit pool. EHP counts
	-- block, evasion and suppression as averages, so a build can have huge EHP
	-- and still die to one hit; max hit is the consistent part.
	local minHit, meanLogHit
	if output then minHit, meanLogHit = self:MinMaxHit(output) end
	local tank
	local bossRatio = output and self:BossHitRatio(output)
	if minHit and bossRatio then
		-- (boss hits: how many times over the build takes the worst pinnacle hit)
		tank = 0.15 * m_log(m_max(ehp, 1)) + 0.35 * m_log(minHit) + 0.2 * meanLogHit + 0.3 * m_log(m_max(bossRatio, 0.01) * 10000)
	elseif minHit then
		tank = 0.15 * m_log(m_max(ehp, 1)) + 0.55 * m_log(minHit) + 0.3 * meanLogHit
	else
		tank = m_log(m_max(ehp, 1))
	end
	local score = self.focus.dps * m_log(m_max(dps, 1)) + self.focus.ehp * tank - penalty + self:ExtraTerms(output)
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

-- Is a flask a utility flask (not life / mana / hybrid)?
local function isUtilityFlask(item)
	return item.base and item.base.flask and not (item.base.flask.life or item.base.flask.mana)
end

-- Estimated share of time a utility flask is up (0 to 1)
function BuildScorerClass:FlaskUptime(item, modDB)
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
	if rate <= 0 then
		return 0
	end
	return m_min(1, duration * rate / chargesUsed)
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
		if isUtilityFlask(item) then
			local uptime
			if permanent[item] then
				uptime = 1
			elseif (left > 0 or right > 0) and item.rarity == "MAGIC" then
				uptime = 0 -- "Magic Utility Flasks cannot be Used"
			else
				uptime = self:FlaskUptime(item, modDB)
			end
			t_insert(list, { item = item, uptime = uptime, permanent = permanent[item] or false })
		end
	end
	return list, env
end

-- Full evaluation of a candidate state.
-- calcFunc: from calcsTab:GetMiscCalculator(); override: calculator override
-- opts.flasks: "full" (measure each flask), "ratio" (reuse ratios), or false
-- Returns { score, dps, ehp, rawDps, rawEhp, penalty, penalties, output, flasks }
function BuildScorerClass:Evaluate(calcFunc, override, opts)
	opts = opts or { }
	override = override or { }
	local output = calcFunc(override, opts.useFullDPS)
	local rawDps, rawEhp = self:GetDPS(output), self:GetEHP(output)
	local dps, ehp = rawDps, rawEhp
	local flasks
	local mode = self.flaskRealism and (opts.flasks or "full")
	if mode == "full" then
		local list = self:GetFlaskUptimes(override)
		flasks = list
		for _, entry in ipairs(list) do
			if entry.uptime < 1 then
				local off = { }
				for k, v in pairs(override) do off[k] = v end
				off.toggleFlask = entry.item
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
	local penalty, penalties = self:GetPenalties(output)
	return {
		score = self:ScoreFromValues(dps, ehp, penalty, output),
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
