-- Path of Building
--
-- Class: Auto Config
-- Fills in the Configuration tab from what the build actually does, for a
-- chosen scenario (a pinnacle boss, or clearing maps). Only options the
-- build's modifiers use are touched, and an option is only switched on when
-- the build has a reliable source for it:
--   * charges: a gem, passive or item line that generates them
--   * enemy ailments: the main skill's chance to inflict them per hit
--   * "recently" conditions: the main skill's type (attack, spell, hit, crit)
--   * killed recently: mapping only
--   * leeching / low life: the build's leech and life reservation
-- Every change is listed so it can be checked in the Configuration tab.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local m_max, m_min, m_floor = math.max, math.min, math.floor
local configOptions = require("Modules.ConfigOptions")

---@class AutoConfig
local AutoConfigClass = newClass("AutoConfig")

-- (boss: the configuration and damage are a pinnacle boss's; clear: what
-- only matters while mapping - on-kill Eldritch implicits, movement speed,
-- clear speed - is still valued, without changing the boss numbers)
AutoConfigClass.scenarioList = {
	{ label = "Pinnacle boss", id = "BOSS", boss = true },
	{ label = "Clearing maps", id = "MAPPING" },
	{ label = "Clearing + bossing (damage on a pinnacle boss)", id = "BOSS_CLEAR", boss = true, clear = true },
}

-- Skills that generate charges, beyond support gems named "... Charge ..."
local chargeSkills = {
	Power = { "Assassin's Mark" },
	Frenzy = { "Frenzy", "Blood Rage", "Poacher's Mark" },
	Endurance = { "Enduring Cry", "Warlord's Mark" },
}
-- Buffs a support grants the skill it supports, which PoB only counts with a
-- Configuration switch (Fortify's fortification, Lifetap's buff...): on when
-- the support is linked to the main skill and that skill can produce it.
-- Also used while the generator measures supports (BuildGenerator:WithChargesOf),
-- so a support is valued with what it really grants (Fortify's defence)
AutoConfigClass.supportStates = {
	{ gem = "Fortify", var = "buffFortification", needs = "Melee", label = "fortification from the main skill's melee hits (Fortify Support)" },
	{ gem = "Lifetap", var = "buffLifetap", label = "Lifetap from the main skill's life cost (Lifetap Support)" },
	{ gem = "Arcane Surge", var = "buffArcaneSurge", needs = "Spell", label = "Arcane Surge from the main skill's mana spent (Arcane Surge Support)" },
	{ gem = "Close Combat", var = "closeCombatCombatRush", label = "Combat Rush (Close Combat Support)" },
	{ gem = "Feeding Frenzy", var = "feedingFrenzyFeedingFrenzyActive", label = "Feeding Frenzy (Feeding Frenzy Support)" },
	{ gem = "Fresh Meat", var = "freshMeatBuffs", label = "Fresh Meat (Fresh Meat Support)" },
	{ gem = "Infused Channelling", var = "infusedChannellingInfusion", needs = "Channel", label = "Infusion while channelling (Infused Channelling Support)" },
	-- (Intensity at its maximum against a boss: casting in place; the full
	-- configuration sets it from the scenario, see Run)
	-- (Trinity: Resonance at its maximum when the skill hits with all three elements)
	{ gem = "Trinity", var = "configResonanceCount", value = 50, allElements = true, label = "Resonance kept at its maximum: hits of all three elements (Trinity Support)" },
	{ gem = "Predator", var = "deathmarkDeathmarkActive", needs = "Minion", label = "the minions mark their target with Signal Prey (Predator Support)" },
	-- (Innervation comes from killing shocked enemies: mapping only)
	{ gem = "Innervate", var = "innervateInnervation", mappingOnly = true, label = "Innervation from killing shocked enemies while mapping (Innervate Support)" },
	{ gem = "Pinpoint", var = "intensifyIntensity", value = 3, needs = "Spell", label = "Intensity from casting in place (Pinpoint Support)" },
	{ gem = "Intensify", var = "intensifyIntensity", value = 3, needs = "Spell", label = "Intensity from casting in place (Intensify Support)" },
}

-- Trinity's lowest Resonance as the hits really give it (poewiki): a hit
-- grants Resonance of the elements other than its highest damage type, and
-- only when that highest type is elemental (physical or chaos highest: none);
-- an element that is always the highest never gains, so the lowest stays at
-- 0. Hits sampled from each damage type's range: the share of hits granting
-- each element, then the chance it gains in the last 2 seconds (hits made in
-- 2 seconds). 50 when every element gains steadily. (A Cyclone with Trinity
-- counted at 50 while physical was its highest damage: nothing in game)
function AutoConfigClass.TrinityResonance(output)
	if not output then return 0 end
	local src = output.MainHand or output
	local types = { "Physical", "Fire", "Cold", "Lightning", "Chaos" }
	local elements = { Fire = true, Cold = true, Lightning = true }
	-- (PoB keeps a type's min / max only in the Calcs tab's mode; from its
	-- average otherwise, with the usual spread of that type: lightning
	-- rolls 1 to 10, the others about 1 to 2-3)
	local spread = { Physical = 0.33, Fire = 0.4, Cold = 0.4, Lightning = 0.82, Chaos = 0.33 }
	local ranges, anyElement = { }, false
	for _, t in ipairs(types) do
		local mn, mx = src[t .. "Min"], src[t .. "Max"]
		if not (mn and mx) then
			local avg = src[t .. "HitAverage"] or 0
			mn, mx = avg * (1 - spread[t]), avg * (1 + spread[t])
		end
		ranges[t] = { mn, m_max(mn, mx) }
		if elements[t] and mx > 0 then anyElement = true end
	end
	if not anyElement then return 0 end
	local seed = 12345
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local gain = { Fire = 0, Cold = 0, Lightning = 0 }
	local samples = 400
	for _ = 1, samples do
		local best, bestType = -1, nil
		for _, t in ipairs(types) do
			local r = ranges[t]
			if r[2] > 0 then
				local v = r[1] + (r[2] - r[1]) * rnd()
				if v > best then best, bestType = v, t end
			end
		end
		if bestType and elements[bestType] then
			for el in pairs(gain) do
				if el ~= bestType then gain[el] = gain[el] + 1 end
			end
		end
	end
	local hits = 2 * m_max(0.5, output.HitSpeed or output.Speed or src.Speed or 1)
	local lowest = 50
	for _, count in pairs(gain) do
		local q = count / samples
		local gaining = 1 - (1 - q) ^ hits
		lowest = m_min(lowest, 50 * gaining)
	end
	return m_floor(lowest)
end

-- The enemy's ailment threshold, as CalcOffence works it out for
-- non-damaging ailments (level, boss type, map multipliers, its modifiers)
function AutoConfigClass.EnemyAilmentThreshold(env)
	if not (env and env.enemyDB) then return nil end
	local isBoss = env.configInput and env.configInput.enemyIsBoss and env.configInput.enemyIsBoss ~= "None"
	local level = env.enemyLevel or 84
	local threshold = data.monsterAilmentThresholdTable[level] or 20000
	local lifeMult, ailmentMult = 1, 1
	if level >= 66 then
		lifeMult = isBoss and data.mapLevelBossLifeMult and data.mapLevelBossLifeMult[level] or (data.mapLevelLifeMult and data.mapLevelLifeMult[level]) or 1
		ailmentMult = isBoss and data.mapLevelBossAilmentMult and data.mapLevelBossAilmentMult[level] or 1
	end
	return threshold * (isBoss and 7.68 or 1) * lifeMult * env.enemyDB:More(nil, "Life") * ailmentMult * env.enemyDB:More(nil, "AilmentThreshold")
end

-- The chance a hit of the main skill stuns: on a pinnacle boss 200 x hit /
-- threshold (the boss's ailment threshold as its life scale, the build's
-- reduced stun threshold), none below 15% (poewiki Stun); a map pack is
-- stunned by most hits
function AutoConfigClass.StunChance(output, env, boss)
	if not boss then return 0.6 end
	local threshold = AutoConfigClass.EnemyAilmentThreshold(env)
	local hit = output.AverageHit or (output.MainHand and output.MainHand.AverageHit) or 0
	local mod = (output.MainHand and output.MainHand.EnemyStunThresholdMod) or output.EnemyStunThresholdMod or 1
	if not threshold or threshold <= 0 or hit <= 0 then return 0 end
	local chance = 200 * hit / (threshold * m_max(0.1, mod))
	if chance < 15 then return 0 end
	return m_min(1, chance / 100)
end

-- Cruelty's effect from the main skill's average hit and the enemy's
-- ailment threshold (as CalcOffence works it out for non-damaging ailments)
function AutoConfigClass.CrueltyEffect(output, env, gem)
	if not (output and env and env.enemyDB) then return nil end
	local hit = output.AverageHit or (output.MainHand and output.MainHand.AverageHit) or output.AverageDamage or (output.MainHand and output.MainHand.AverageDamage)
	if not hit or hit <= 0 then return nil end
	local threshold = AutoConfigClass.EnemyAilmentThreshold(env)
	if not threshold or threshold <= 0 then return nil end
	-- (gem level 20: 19% increased effect, quality 0.25% each)
	local level20 = (gem.level or 20)
	local inc = m_max(0, (level20 - 1)) / 100 + (gem.quality or 0) * 0.0025
	return m_floor(m_min(40, 100 * (hit / threshold) ^ 0.2 * (1 + inc)))
end

-- The support states a support gem grants a main skill with these skill
-- types: { state, ... }
-- (output: the main skill's, for states that depend on its damage; boss: the
-- fight is a boss, so states that need kills don't count)
function AutoConfigClass.SupportStatesOf(gemName, skillTypes, output, boss)
	local list = { }
	for _, state in ipairs(AutoConfigClass.supportStates) do
		if state.gem == gemName and (not state.needs or (skillTypes and skillTypes[SkillType[state.needs]]))
			and not (state.mappingOnly and boss) then
			local ok = true
			if state.allElements then
				local value = AutoConfigClass.TrinityResonance(output)
				if value < 5 then
					ok = false
				else
					local copy = { }
					for k, v in pairs(state) do copy[k] = v end
					copy.value = value
					copy.label = string.format("Resonance %d of 50 on the lowest element: the highest element of a hit changes often enough (Trinity Support)", value)
					state = copy
				end
			end
			if ok then t_insert(list, state) end
		end
	end
	return list
end

-- base durations (seconds) used when PoB gives none, to estimate uptime
local ailments = {
	{ ailment = "Shock", var = "conditionEnemyShocked", cond = "Shocked", duration = 2 },
	{ ailment = "Chill", var = "conditionEnemyChilled", cond = "Chilled", duration = 2 },
	{ ailment = "Freeze", var = "conditionEnemyFrozen", cond = "Frozen", notOnBoss = true, duration = 0.3 },
	{ ailment = "Ignite", var = "conditionEnemyIgnited", cond = "Ignited", duration = 4 },
	{ ailment = "Bleed", var = "conditionEnemyBleeding", cond = "Bleeding", duration = 5 },
	{ ailment = "Poison", var = "conditionEnemyPoisoned", cond = "Poisoned", duration = 2 },
}

-- Enemy debuffs inflicted by hits (lines found in the build's passives and
-- items, or gems that inflict them), with how long one lasts
local enemyDebuffs = {
	{ var = "conditionEnemyIntimidated", words = { "intimidate" }, gems = { "Intimidating Cry" }, duration = 4 },
	{ var = "conditionEnemyUnnerved", words = { "unnerve" }, duration = 4 },
	{ var = "conditionEnemyBlinded", words = { "blind" }, gems = { "Blind" }, duration = 4 },
	{ var = "conditionEnemyMaimed", words = { "maim" }, gems = { "Maim" }, duration = 4 },
	{ var = "conditionEnemyHindered", words = { "hinder" }, duration = 4 },
	{ var = "conditionEnemyCoveredInAsh", words = { "cover enemies in ash" }, duration = 5 },
	{ var = "conditionEnemyCoveredInFrost", words = { "cover enemies in frost" }, duration = 5 },
	{ var = "conditionEnemyCrushed", words = { "crush" }, duration = 4 },
	{ var = "conditionEnemyScorched", words = { "scorch" }, duration = 4 },
	{ var = "conditionEnemyBrittle", words = { "brittle" }, duration = 4 },
	{ var = "conditionEnemySapped", words = { "inflict sap", "to sap " }, duration = 4 },
}

-- Realistic values for "count" options, from what the build does in 4 seconds
-- ("recently" in Path of Exile means the past 4 seconds).
-- Each rule: multiplier name -> function(output, ctx) returning value, reason
local recently = 4
local function speedOf(output)
	return output.Speed or (output.MainHand and output.MainHand.Speed) or 0
end
local function chanceOf(output, ailment)
	local crit = (output.CritChance or (output.MainHand and output.MainHand.CritChance) or 0) / 100
	local onHit = output[ailment .. "ChanceOnHit"] or (output.MainHand and output.MainHand[ailment .. "ChanceOnHit"]) or 0
	local onCrit = output[ailment .. "ChanceOnCrit"] or (output.MainHand and output.MainHand[ailment .. "ChanceOnCrit"]) or onHit
	return (onHit * (1 - crit) + onCrit * crit) / 100
end
AutoConfigClass.countRules = {
	-- capped by what the build can actually pay for (no infinite Indigon loops)
	ManaSpentRecently = function(output, ctx)
		local cost = output.ManaPerSecondCost or 0
		local sustainable = ctx.scorer:SustainableRate(output, "Mana")
		local perSecond = math.min(cost, sustainable)
		return math.floor(perSecond * recently), string.format("%.0f mana per second x 4 s%s", perSecond, perSecond < cost and string.format(", limited by mana recovery (skill costs %.0f/s)", cost) or "")
	end,
	LifeSpentRecently = function(output, ctx)
		local cost = output.LifePerSecondCost or 0
		local sustainable = ctx.scorer:SustainableRate(output, "Life")
		local perSecond = math.min(cost, sustainable)
		return math.floor(perSecond * recently), string.format("%.0f life per second x 4 s%s", perSecond, perSecond < cost and ", limited by life recovery" or "")
	end,
	SkillUsedRecently = function(output)
		local speed = speedOf(output)
		return math.floor(speed * recently), string.format("%.1f uses per second x 4 s", speed)
	end,
	CritRecently = function(output, ctx)
		if not ctx.attack then return 0, "main skill is not an attack" end
		local crit = (output.CritChance or (output.MainHand and output.MainHand.CritChance) or 0) / 100
		return math.floor(speedOf(output) * recently * crit), string.format("%.1f attacks per second x %.0f%% crit x 4 s", speedOf(output), crit * 100)
	end,
	IgniteAppliedRecently = function(output)
		local chance = chanceOf(output, "Ignite")
		return math.floor(speedOf(output) * recently * chance), string.format("%.0f%% ignite chance x %.1f hits per second x 4 s", chance * 100, speedOf(output))
	end,
	PoisonAppliedRecently = function(output)
		local chance = chanceOf(output, "Poison")
		return math.floor(speedOf(output) * recently * chance), string.format("%.0f%% poison chance x %.1f hits per second x 4 s", chance * 100, speedOf(output))
	end,
	EnemyKilledRecently = function(output, ctx)
		if ctx.boss then return 0, "no kills while fighting a boss" end
		return 10, "a typical map pack in 4 s"
	end,
	NearbyEnemies = function(output, ctx)
		if ctx.boss then return 1, "the boss" end
		return 5, "a typical map pack"
	end,
	Rage = function(output, ctx)
		local env = ctx.env
		local modDB = env and env.player.modDB
		if not (modDB and modDB:Flag(nil, "Condition:CanGainRage")) then return 0, "the build can't gain rage" end
		local maxRage = math.floor(modDB:Sum("BASE", nil, "MaximumRage") * modDB:More(nil, "MaximumRage"))
		-- (all rage lost on reaching the maximum, The Wild Bear: half of it on
		-- average; its Wild Savagery is up about 29% of the time - rage refills at
		-- about 4 a second, 1 s of it per 10 lost - so its switch stays off)
		if modDB:Flag(nil, "WildSavagery") then return math.floor(maxRage / 2), "rage lost at its maximum and built again: half of it on average" end
		return maxRage, "rage builds stay at maximum while fighting"
	end,
	ChannellingTime = function(output, ctx)
		if not ctx.channelling then return 0, "main skill does not channel" end
		return 2, "channelling for 2 s"
	end,
}

-- Config option for each multiplier name
local optionForMult = { }
for _, option in ipairs(configOptions) do
	if option.type == "count" and type(option.ifMult) == "string" and AutoConfigClass.countRules[option.ifMult] then
		optionForMult[option.ifMult] = option
	elseif option.var == "multiplierRage" then
		optionForMult.Rage = option
	end
end
AutoConfigClass.optionForMult = optionForMult

-- Realistic value for one multiplier: value, reason, option (or nil)
function AutoConfigClass:RealisticCount(multName, output, env)
	local rule, option = self.countRules[multName], optionForMult[multName]
	if not rule or not option then return nil end
	local skill = env and env.player and env.player.mainSkill
	local flags = skill and skill.skillFlags or { }
	self.scorer = self.scorer or new("BuildScorer"):BuildScorer(self.build, { chargesPerSecond = self.scenario.boss and 0 or 4 })
	local ctx = { boss = self.scenario.boss and true or false, attack = flags.attack, channelling = skill and skill.skillTypes and skill.skillTypes[SkillType.Channel], scorer = self.scorer, env = env }
	local value, reason = rule(output, ctx)
	return value, reason, option
end

function AutoConfigClass:AutoConfig(build, scenario)
	self.build = build
	self.scenario = scenario or self.scenarioList[1]
	self.optionByVar = { }
	self.optionList = configOptions
	for _, option in ipairs(configOptions) do
		if option.var then self.optionByVar[option.var] = option end
	end
	return self
end

local function cleanLabel(text)
	return (text or ""):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", "")
end

function AutoConfigClass:Recalculate()
	local build = self.build
	build.configTab:BuildModList()
	wipeGlobalCache()
	build.outputRevision = build.outputRevision + 1
	build.buildFlag = false
	build.skillsTab:UpdateSocketGroups()
	build.calcsTab:BuildOutput()
end

-- Is an option relevant to this build (does a modifier use its condition)?
function AutoConfigClass:IsUsed(option)
	local env = self.build.calcsTab.mainEnv
	if option.ifCond then
		local conds = type(option.ifCond) == "table" and option.ifCond or { option.ifCond }
		for _, c in ipairs(conds) do
			if env.conditionsUsed[c] then return true end
		end
		return false
	elseif option.ifEnemyCond then
		local conds = type(option.ifEnemyCond) == "table" and option.ifEnemyCond or { option.ifEnemyCond }
		for _, c in ipairs(conds) do
			if env.enemyConditionsUsed[c] then return true end
		end
		return false
	end
	return true
end

function AutoConfigClass:Set(var, value, reason)
	local input = self.build.configTab.input
	local option = self.optionByVar[var]
	if not option then return end
	if input[var] ~= value then
		input[var] = value
		local shown = value == true and "on" or value == false and "off" or tostring(value)
		local text = string.format("%s %s (%s)", cleanLabel(option.label), shown, reason)
		-- one line per option, even when a later pass refines the value
		self.changeIndex = self.changeIndex or { }
		if self.changeIndex[var] then
			self.changes[self.changeIndex[var]] = text
		else
			t_insert(self.changes, text)
			self.changeIndex[var] = #self.changes
		end
		self.changeByVar = self.changeByVar or { }
		self.changeByVar[var] = text
	end
end

-- Text of every line of the build's passives, items and gem names, lower case
function AutoConfigClass:BuildText()
	local lines = { }
	for _, node in pairs(self.build.spec.allocNodes) do
		for _, line in ipairs(node.sd or { }) do t_insert(lines, line:lower()) end
	end
	for _, slot in pairs(self.build.itemsTab.slots) do
		local item = self.build.itemsTab.items[slot.selItemId]
		if item and not slot.inactive then
			for _, list in ipairs({ item.implicitModLines, item.explicitModLines, item.enchantModLines }) do
				for _, line in ipairs(list or { }) do t_insert(lines, line.line:lower()) end
			end
		end
	end
	local gems = { }
	for _, group in ipairs(self.build.skillsTab.socketGroupList) do
		if group.enabled ~= false then
			for _, gem in ipairs(group.gemList) do
				if gem.enabled ~= false and gem.gemData then t_insert(gems, gem.gemData.name) end
			end
		end
	end
	return lines, gems
end

-- (charge skills and supports whose condition a pinnacle boss doesn't meet:
-- kills, or stuns a boss shrugs off - poewiki)
local onKillChargeSkills = { ["Blood Rage"] = true, ["Assassin's Mark"] = true }
function AutoConfigClass:GeneratesCharge(kind, lines, gems, flags, boss, output)
	local word = kind:lower()
	for _, line in ipairs(lines) do
		-- "gain a frenzy charge on hit", "grant an endurance, frenzy or power charge"...
		if line:find(word, 1, true) and line:find("charge", 1, true) and (line:find("gain") or line:find("grant") or line:find("generat"))
			and not line:find("lose") and not line:find("maximum") then
			return true
		end
	end
	for _, name in ipairs(gems) do
		-- (a charge support's condition must be met: "on Melee Stun" needs a melee
		-- skill, and on a boss strikes that stun it)
		local conditionMet = not (name:find("Melee", 1, true) and flags and not flags.melee)
		if conditionMet and boss and name:find("Stun", 1, true) and output then
			conditionMet = AutoConfigClass.StunChance(output, self.build.calcsTab.mainEnv, boss) > 0
		end
		if name:find(kind .. " Charge", 1, true) and conditionMet then return true end
		for _, skill in ipairs(chargeSkills[kind]) do
			if name == skill and not (boss and onKillChargeSkills[name]) then return true end
		end
	end
	return false
end

-- How many charges of a kind the build's own lines keep up, from what
-- triggers them and how often: { count, max, reason } or nil when there is no
-- line-based source. A chance on kill only counts while mapping; on hit / on
-- critical strike from the main skill's hit rate; when you block / are hit
-- from about one enemy hit a second; "every N seconds" as it says. Kept charges
-- = gained per second x charge duration, up to the maximum.
local HITS_TAKEN_PER_SECOND = 1
local KILLS_PER_SECOND = 2
function AutoConfigClass:ChargeUptime(kind, lines, flags, output, boss)
	local word = kind:lower()
	local hitRate = output.Speed or (output.MainHand and output.MainHand.Speed) or 0
	local crit = ((output.CritChance or (output.MainHand and output.MainHand.CritChance)) or 0) / 100
	local block = (output.EffectiveBlockChance or output.BlockChance or 0) / 100
	local rate, sources = 0, { }
	for _, line in ipairs(lines) do
		if line:find(word, 1, true) and line:find("charge", 1, true) and (line:find("gain") or line:find("grant") or line:find("generat"))
			and not line:find("lose") and not line:find("maximum") and not line:find("enemies", 1, true) then
			local chance = (tonumber(line:match("([%d%.]+)%% chance")) or 100) / 100
			local every = tonumber(line:match("every ([%d%.]+) seconds?")) or (line:find("every second", 1, true) or line:find("each second", 1, true)) and 1
			local r
			if line:find("on kill", 1, true) or line:find("when you kill", 1, true) or line:find("melee kill", 1, true) then
				r = boss and 0 or KILLS_PER_SECOND * chance
			elseif line:find("non%-critical strike") then
				r = hitRate * (1 - crit) * chance
			elseif line:find("critical strike", 1, true) then
				r = hitRate * crit * chance
			elseif line:find("when you block", 1, true) then
				r = HITS_TAKEN_PER_SECOND * block * chance
			elseif line:find("when you are hit", 1, true) or line:find("when hit", 1, true) then
				r = HITS_TAKEN_PER_SECOND * chance
			elseif every then
				r = chance / every
				local skill = self.build.calcsTab.mainEnv and self.build.calcsTab.mainEnv.player.mainSkill
				if line:find("while channelling", 1, true) and not (skill and skill.skillTypes and skill.skillTypes[SkillType.Channel]) then r = 0 end
				-- (moving: part of a boss fight)
				if line:find("while moving", 1, true) and boss then r = r * 0.3 end
			elseif line:find("on hit", 1, true) or line:find("when you hit", 1, true) then
				r = hitRate * chance
			elseif line:find("after spending a total of", 1, true) then
				local mana = tonumber(line:match("total of (%d+) mana"))
				r = mana and (output.ManaPerSecondCost or 0) / mana or 0
			elseif line:find("when you stun", 1, true) or line:find("on melee stun", 1, true) then
				r = hitRate * AutoConfigClass.StunChance(output, self.build.calcsTab.mainEnv, boss) * chance
			else
				-- (a trigger not recognised: counted as before, as reliable)
				r = 10
			end
			if r > 0 then
				rate = rate + r
				t_insert(sources, line)
			end
		end
	end
	if #sources == 0 then return nil end
	local duration = output[kind .. "ChargesDuration"] or 10
	local max = output[kind .. "ChargesMax"] or 3
	local count = math.min(max, rate * math.max(1, duration))
	return { count = count, max = max, reason = string.format("about %.1f per second from \"%s\"%s, %.0f s each", rate, sources[1], #sources > 1 and string.format(" and %d more", #sources - 1) or "", duration) }
end

-- Main skill output (attacks keep per-hand numbers in MainHand)
local function skillValue(output, key)
	if output[key] ~= nil then return output[key] end
	return output.MainHand and output.MainHand[key]
end

function AutoConfigClass:Run()
	self.changes = { }
	self.changeIndex = { }
	local boss = self.scenario.boss and true or false
	self:Set("enemyIsBoss", boss and "Pinnacle" or "None", boss and "pinnacle boss scenario" or "map clearing scenario")
	for pass = 1, 4 do
		self:Recalculate()
		local output = self.build.calcsTab.mainOutput
		local env = self.build.calcsTab.mainEnv
		local skill = env.player.mainSkill
		local flags = skill and skill.skillFlags or { }
		local lines, gems = self:BuildText()

		-- charges
		for _, kind in ipairs({ "Power", "Frenzy", "Endurance" }) do
			-- only switched on: charge sources can be indirect, so never switched off
			-- (from gems, or lines that keep them up: on hit, on crit, every N seconds...
			-- a chance on kill or on block alone keeps few or none against a boss)
			local fromGems = self:GeneratesCharge(kind, { }, gems, flags, boss, output)
			-- ("gain a frenzy charge on reaching maximum power charges", Tulfall:
			-- gained every time the other charges cycle to their maximum)
			local onReaching
			for _, line in ipairs(lines) do
				local other = line:match("gain an? " .. kind:lower() .. " charge on reaching maximum (%a+) charges")
				if other and other ~= kind:lower() then onReaching = other end
			end
			-- (Assassin's Mark on a boss: no kills, only its quality's chance on
			-- hit - 5% at 20% quality, poewiki)
			local chargeLines = lines
			if boss and kind == "Power" then
				for _, group in ipairs(self.build.skillsTab.socketGroupList) do
					for _, g in ipairs(group.enabled ~= false and group.gemList or { }) do
						if g.enabled ~= false and g.gemData and g.gemData.name == "Assassin's Mark" and (g.quality or 0) > 0 then
							chargeLines = { }
							for _, l in ipairs(lines) do t_insert(chargeLines, l) end
							t_insert(chargeLines, string.format("%g%% chance to gain a power charge on hit", (g.quality or 0) * 0.25))
						end
					end
				end
			end
			local uptime = not fromGems and not onReaching and self:ChargeUptime(kind, chargeLines, flags, output, boss)
			if fromGems then
				self:Set("use" .. kind .. "Charges", true, "the build generates them")
			elseif onReaching then
				self:Set("use" .. kind .. "Charges", true, "gained each time the build reaches its maximum " .. onReaching .. " charges")
			elseif uptime then
				if uptime.count >= uptime.max * 0.75 then
					self:Set("use" .. kind .. "Charges", true, "kept at the maximum: " .. uptime.reason)
				elseif uptime.count >= 1 then
					self:Set("use" .. kind .. "Charges", true, string.format("about %d kept: %s", math.floor(uptime.count), uptime.reason))
					self:Set("override" .. kind .. "Charges", math.floor(uptime.count), string.format("about %d kept: %s", math.floor(uptime.count), uptime.reason))
				end
			end
			-- "Lose all Power Charges on reaching Maximum Power Charges" (Tulfall,
			-- Malachai's Loop...): the charges cycle from none to the maximum, half
			-- of it on average - unless the build counts as always having the
			-- maximum (Ralakesh's Impatience), which turns the drawback off
			local word = kind:lower()
			local cycles, countsMax = false, false
			for _, line in ipairs(lines) do
				if line:find("lose all " .. word .. " charges on reaching maximum", 1, true) then cycles = true end
				if line:find("count as having maximum number of " .. word .. " charges", 1, true) then countsMax = true end
			end
			local maxCharges = output[kind .. "ChargesMax"]
			if cycles and not countsMax and maxCharges and maxCharges > 0 then
				self:Set("override" .. kind .. "Charges", math.floor(maxCharges / 2), string.format("charges lost on reaching the maximum (%d): half of it on average", maxCharges))
			end
		end
		-- (cooldowns bypassed by spending a charge - poewiki: Flicker Strike a
		-- Frenzy Charge, Consecrated Path of Endurance an Endurance Charge;
		-- PoB bypasses them by default: only with a source of those charges)
		for var, kind in pairs({ FlickerStrikeBypassCD = "Frenzy", ConcPathBypassCD = "Endurance", ColdSnapBypassCD = "Power" }) do
			if self.optionByVar[var] then
				local has = self.build.configTab.input["use" .. kind .. "Charges"] and true or false
				self:Set(var, has, has and ("cooldown bypassed with " .. kind:lower() .. " charges the build generates") or ("no " .. kind:lower() .. " charges to bypass the cooldown"))
			end
		end

		-- what the main skill does
		local function setIfUsed(var, value, reason)
			local option = self.optionByVar[var]
			if option and self:IsUsed(option) then self:Set(var, value, reason) end
		end
		-- fortification from the build's own lines ("Melee Hits have 20% chance to
		-- Fortify", "Melee Hits with Maces... Fortify"): a melee main skill
		-- fortifying about once a second or more keeps it up
		if flags.melee then
			local perSecond = 0
			local source
			for _, line in ipairs(lines) do
				if line:find("fortify", 1, true) and line:find("hit", 1, true) and not line:find("fortifying hits", 1, true) and not line:find("cannot", 1, true) then
					local chance = (tonumber(line:match("([%d%.]+)%% chance")) or 100) / 100
					if line:find("which stun", 1, true) then chance = chance * 0.3 end
					local rate = speedOf(output) * chance
					if rate > perSecond then perSecond, source = rate, line end
				end
			end
			if source and perSecond >= 1 then
				self:Set("buffFortification", true, string.format("fortifying about %.1f times a second from \"%s\"", perSecond, source))
			end
		end
		-- Intensity (Pinpoint, Intensify, Crackling Lance): gained by casting, lost
		-- every 0.5 s while moving, 3 at most (+1 per "+1 to maximum Intensity").
		-- At its maximum against a boss (casting in place), about 1 while
		-- mapping; Apex Mode keeps it up, Nadir Mode drains it
		local hasIntensity = false
		for _, name in ipairs(gems) do
			if name == "Pinpoint" or name == "Intensify" or name:find("^Crackling Lance") then hasIntensity = true end
		end
		if hasIntensity and self.optionByVar["intensifyIntensity"] then
			local maxIntensity, apex, nadir = 3, false, false
			for _, line in ipairs(lines) do
				local extra = tonumber(line:match("%+(%d+) to maximum intensity"))
				if extra then maxIntensity = maxIntensity + extra end
				if line:find("gained intensity recently gain", 1, true) then apex = true end
				if line:find("gained intensity recently lose", 1, true) then nadir = true end
			end
			local value = nadir and 1 or (boss or apex) and maxIntensity or 1
			self:Set("intensifyIntensity", value, nadir and "Intensity drained by Nadir Mode" or apex and "kept at its maximum by Apex Mode"
				or boss and "at its maximum: casting in place against a boss" or "about 1 while moving through maps")
		end
		-- buffs the supports linked to the main skill grant it
		local mainGroup = self.build.skillsTab.socketGroupList[self.build.mainSocketGroup]
		local mainTypes = skill and skill.skillTypes
		for _, gem in ipairs(mainGroup and mainGroup.enabled ~= false and mainGroup.gemList or { }) do
			if gem.enabled ~= false and gem.gemData then
				for _, state in ipairs(AutoConfigClass.SupportStatesOf(gem.gemData.name, mainTypes, output, boss)) do
					-- (Intensity: set from the scenario below)
					if state.var == "buffArcaneSurge" then
						-- (poewiki: mana spent only - life costs, Blood Magic or Lifetap,
						-- give nothing; the threshold is the gem's, 400 mana at level 20,
						-- and the buff lasts 4 s: up when the skill spends that much in 4 s)
						local threshold = 400
						local levels = gem.gemData.grantedEffect and gem.gemData.grantedEffect.levels
						local lv = levels and levels[m_min(#levels, m_max(1, gem.level or 20))]
						if lv and tonumber(lv[1]) then threshold = tonumber(lv[1]) end
						local spent = (output.ManaPerSecondCost or 0) * 4
						if spent >= threshold * 0.9 then
							self:Set(state.var, true, string.format("Arcane Surge: the main skill spends %d mana in 4 s (%d needed)", spent, threshold))
						else
							self:Set(state.var, nil, string.format("no Arcane Surge: the main skill spends %d mana in 4 s, %d needed (life costs don't count)", spent, threshold))
						end
					elseif state.var ~= "intensifyIntensity" then self:Set(state.var, state.value or true, state.label) end
				end
				-- Cruelty (poewiki): up to 40% more damage over time, by the hit's
				-- damage against the target's ailment threshold, (D / L)^0.2 x
				-- (1 + increased effect); PoB counts 40 unless told. A pinnacle
				-- boss's threshold is millions: a 5k hit gives about 27%
				if gem.gemData.name == "Cruelty" and self.optionByVar["overrideCruelty"] then
					local value = AutoConfigClass.CrueltyEffect(output, env, gem)
					if value then self:Set("overrideCruelty", value, string.format("Cruelty %d%%: the main skill's hit against the enemy's ailment threshold", value)) end
				end
			end
		end
		setIfUsed("conditionUsedSkillRecently", true, "you use your main skill")
		setIfUsed("conditionAttackedRecently", flags.attack and true or false, flags.attack and "main skill is an attack" or "main skill is not an attack")
		setIfUsed("conditionCastSpellRecently", flags.spell and true or false, flags.spell and "main skill is a spell" or "main skill is not a spell")
		setIfUsed("conditionHitRecently", flags.hit and true or false, flags.hit and "main skill hits" or "main skill does not hit")
		local crit = skillValue(output, "CritChance") or 0
		setIfUsed("conditionCritRecently", crit >= 30, string.format("%.0f%% critical strike chance", crit))
		-- (hit recently: a boss or a pack hits about once a second; the build
		-- goes 4 seconds without being hit only if it avoids nearly all of them
		-- - Wind Dancer's "less damage taken if you haven't been hit recently"
		-- is then off most of the time, its downside on)
		do
			self.scorer = self.scorer or new("BuildScorer"):BuildScorer(self.build, { chargesPerSecond = boss and 0 or 4 })
			local okShare, share = pcall(function() return self.scorer:DamageTakenShare(output) end)
			share = okShare and share or 1
			-- (three hits a second: a boss alone throws about one, but a map's
			-- packs many more, and these states are for playing the whole
			-- game - Wind Dancer is off while clearing even at 70% avoidance)
			local hits = 3
			local notHit = (1 - share) ^ (4 * hits)
			setIfUsed("conditionBeenHitRecently", notHit < 0.5, string.format("%.0f%% of hits avoided: %.0f%% chance to go 4 seconds without being hit", (1 - share) * 100, notHit * 100))
			-- (attacks: about half of them)
			local notHitByAttack = (1 - share) ^ (4 * hits / 2)
			setIfUsed("conditionBeenHitByAttackRecently", notHitByAttack < 0.5, string.format("%.0f%% of hits avoided: %.0f%% chance to go 4 seconds without being hit by an attack", (1 - share) * 100, notHitByAttack * 100))
		end
		setIfUsed("conditionKilledRecently", not boss, boss and "not while fighting a boss" or "clearing maps")
		setIfUsed("conditionHeadhunterBuffs", not boss, boss and "no rare monsters to steal from on a boss" or "rare monsters' modifiers stolen while clearing maps")
		local impale = math.max(skillValue(output, "ImpaleChance") or 0, skillValue(output, "ImpaleChanceOnCrit") or 0)
		setIfUsed("conditionImpaledRecently", impale * speedOf(output) >= 100, string.format("%.0f%% impale chance", impale))

		-- enemy ailments the main skill keeps up: a small chance is enough when
		-- the skill hits often and the ailment lasts (e.g. 20% bleed chance at
		-- 5 hits a second keeps a 5 s bleed up all the time: Cornered Prey works)
		local threshold = boss and 0.8 or 0.6
		local hitRate = speedOf(output)
		for _, entry in ipairs(ailments) do
			local option = self.optionByVar[entry.var]
			-- set even when nothing uses it yet, so the passive tree sees what
			-- "against Chilled / Bleeding... enemies" passives are worth
			if option then
				local onHit = skillValue(output, entry.ailment .. "ChanceOnHit") or 0
				local onCrit = skillValue(output, entry.ailment .. "ChanceOnCrit") or 0
				local chance = onHit * (1 - crit / 100) + onCrit * crit / 100
				-- (cold hits always chill in the game - PoB gives them no chill
				-- chance - with an effect from the hit against the enemy's ailment
				-- threshold: 50% x (damage / threshold)^0.4, up to 30%)
				local chillEffect
				if entry.ailment == "Chill" and (skillValue(output, "ColdHitAverage") or 0) > 0 and skill then
					chance = 100
					local isBoss = env.configInput and env.configInput["enemyIsBoss"] ~= "None"
					local level = env.enemyLevel or 84
					local threshold = (data.monsterAilmentThresholdTable[level] or 1) * (isBoss and 7.68 or 1)
					if level >= 66 then
						threshold = threshold * ((isBoss and data.mapLevelBossLifeMult[level] or data.mapLevelLifeMult[level]) or 1) * ((isBoss and data.mapLevelBossAilmentMult[level]) or 1)
					end
					threshold = threshold * env.enemyDB:More(nil, "Life") * env.enemyDB:More(nil, "AilmentThreshold")
					local mdb, cfg = skill.skillModList, skill.skillCfg
					local effectMod = (1 + mdb:Sum("INC", cfg, "EnemyChillEffect") / 100) * mdb:More(cfg, "EnemyChillEffect")
					local maxChill = mdb:Override(nil, "ChillMax") or 30
					-- (the average hit with crits, its cold part)
					local typesTotal = 0
					for _, t in ipairs({ "Physical", "Lightning", "Cold", "Fire", "Chaos" }) do typesTotal = typesTotal + (skillValue(output, t .. "HitAverage") or 0) end
					local coldHit = (skillValue(output, "AverageHit") or 0) * (skillValue(output, "ColdHitAverage") or 0) / math.max(1, typesTotal)
					coldHit = math.max(coldHit, skillValue(output, "ColdHitAverage") or 0)
					chillEffect = math.floor(math.min(maxChill, 50 * ((coldHit / math.max(1, threshold)) ^ 0.4) * effectMod))
					if chillEffect < 5 then chance = 0 end
				end
				if entry.ailment == "Chill" and (skillValue(output, "ColdHitAverage") or 0) <= 0 then
					-- other damage chills too with "all damage can chill" (Elementalist...)
					local canChill = false
					local skillModList = skill and skill.skillModList
					for _, damageType in ipairs({ "Physical", "Lightning", "Fire", "Chaos" }) do
						if skillModList and skillModList:Flag(nil, damageType .. "CanChill") and (skillValue(output, damageType .. "HitAverage") or 0) > 0 then
							canChill = true
						end
					end
					if not canChill then chance = 0 end
				end
				local duration = skillValue(output, entry.ailment .. "Duration") or entry.duration
				local p = math.min(1, math.max(0, chance / 100))
				local uptime = p >= 1 and 1 or (1 - (1 - p) ^ (hitRate * duration))
				local on = uptime >= threshold and not (boss and entry.notOnBoss)
				local reason = string.format("%.0f%% chance per hit, %.1f hits/s, %.1f s: up %.0f%% of the time", chance, hitRate, duration, uptime * 100)
				if boss and entry.notOnBoss then reason = "pinnacle bosses can't be frozen reliably" end
				self:Set(entry.var, on, reason)
				if chillEffect and on then
					self:Set("conditionEnemyChilledEffect", chillEffect, string.format("cold hits always chill: %d%% from the average hit against the enemy's ailment threshold", chillEffect))
				end
			end
		end
		-- (game states the build's own setup guarantees)
		-- (not a channelled skill that moves: Cyclone channels while moving -
		-- its "while stationary" passives and Stationary bonuses never apply)
		if skill and skill.skillTypes and skill.skillTypes[SkillType.Channel] and not skill.skillTypes[SkillType.Movement] then
			setIfUsed("conditionStationary", 1, "the main skill is channelled: the character stands still while using it")
		elseif skill and skill.skillTypes and skill.skillTypes[SkillType.Channel] then
			setIfUsed("conditionStationary", nil, "the main skill moves while channelled (Cyclone)")
		end
		if env.player.modDB:Flag(nil, "ChaosInoculation") then
			setIfUsed("conditionFullLife", true, "Chaos Inoculation: life is always full")
		end
		-- Trauma (Boneshatter): PoB counts the stacks the attack rate keeps up
		-- (120 on a fast Boneshatter), but every hit then deals its user damage
		-- per stack (12,316 a hit against 5,313 life): players hold what their
		-- recovery pays for. The stacks are set to that: the self damage per
		-- second no more than the life recovery, one hit no more than 40% of
		-- the pool (passes after this one refine it with the new leech).
		if (output.SustainableTrauma or 0) > 0 and (output.SelfHitDamage or 0) > 0 then
			local input = self.build.configTab.input
			local current = math.max(1, tonumber(input.traumaStacks) or output.SustainableTrauma)
			local perStack = output.SelfHitDamage / current
			self.scorer = self.scorer or new("BuildScorer"):BuildScorer(self.build, { chargesPerSecond = boss and 0 or 4 })
			local recovery = self.scorer:SustainableRate(output, "Life")
			local speed = output.Speed or 0
			local pool = (output.LifeUnreserved or output.Life or 0) + (output.EnergyShield or 0)
			local byRecovery = speed > 0 and recovery / (perStack * speed) or math.huge
			local byPool = 0.4 * pool / perStack
			local stacks = math.max(1, math.floor(math.min(output.SustainableTrauma, byRecovery, byPool)))
			self:Set("traumaStacks", stacks, string.format("trauma held at %d of the %d the attack rate keeps up: each stack costs %.0f life a hit, recovery %.0f a second",
				stacks, math.floor(output.SustainableTrauma), perStack, recovery))
		end
		if (output.EnergyShield or 0) > 0 and (output.EnergyShield or 0) >= (output.Life or 0) then
			setIfUsed("conditionHaveEnergyShield", true, "the energy shield pool is the main one")
		end

		-- buffs and stacks the build gives itself (its ascendancy, gems or items
		-- say it can have them; they build up within seconds of fighting)
		local modDB = env.player.modDB
		local function anyLine(patterns)
			for _, line in ipairs(lines) do
				for _, pattern in ipairs(patterns) do
					if line:find(pattern) then return true end
				end
			end
			return false
		end
		if modDB:Flag(nil, "Condition:CanGainGaleForce") then
			local maxGale = 10 + modDB:Sum("BASE", nil, "MaximumGaleForce")
			self:Set("multiplierGaleForce", maxGale, "Gale Force builds up while using skills")
		end
		if modDB:Flag(nil, "Condition:CanGainFanaticism") and flags.spell then
			self:Set("buffFanaticism", true, "gained by casting the main skill")
		end
		if anyLine({ "gain tailwind", "you have tailwind", "grants tailwind" }) then
			self:Set("buffTailwind", true, "the build gains Tailwind")
		end
		local inspired = false
		for _, name in ipairs(gems) do if name == "Inspiration" then inspired = true end end
		if inspired or anyLine({ "gain an? inspiration charge", "gain inspiration charges" }) then
			self:Set("useInspirationCharges", true, "the build generates Inspiration charges")
		end
		-- Withered (poewiki): each stack has its own 2 s duration (not
		-- refreshed), up to 15 - the stacks a build keeps up are the rate it
		-- inflicts them x their duration, not always 15 (Withering Touch on a 5
		-- attacks/s skill: 25% x 5 x 2 s = 2.5)
		if modDB:Flag(nil, "Condition:CanWither") then
			-- (hits a use lands on one target: Toxic Rain's arrows, PoB's dpsMultiplier)
			local perUse = m_max(1, (skill and skill.skillData and skill.skillData.dpsMultiplier) or 1)
			local hitRate = speedOf(output) * perUse
			local stacks, cap, sources = 0, 15, { }
			for _, line in ipairs(lines) do
				local chance, dur = line:match("(%d+)%% chance to inflict withered for (%d+) seconds on hit")
				if not chance then
					chance = line:match("(%d+)%% chance to inflict withered for two seconds on hit")
					if chance then dur = 2 end
					local few = line:match("if there are (%d+) or fewer withered debuffs")
					if few then cap = m_min(cap, tonumber(few) + 1) end
				end
				if chance then
					stacks = stacks + hitRate * tonumber(chance) / 100 * tonumber(dur)
					t_insert(sources, line)
				else
					dur = line:match("^inflict withered for (%d+) seconds on hit")
					if dur then stacks = stacks + hitRate * tonumber(dur) t_insert(sources, line) end
					dur = line:match("every second, inflict withered on nearby enemies for (%d+) seconds")
					if dur then stacks = stacks + tonumber(dur) t_insert(sources, line) end
					local n = line:match("inflict (%d+) withered debuffs for (%d+) seconds")
					local n2, d2 = line:match("inflict (%d+)%-?%d* withered debuffs for (%d+) seconds")
					if n2 then stacks = stacks + hitRate * tonumber(n2) * tonumber(d2) t_insert(sources, line) end
					if line:find("inflict up to 15 withered debuffs", 1, true) then stacks = 15 t_insert(sources, line) end
				end
			end
			for _, name in ipairs(gems) do
				if name == "Withering Touch" then stacks = stacks + hitRate * 0.25 * 2 t_insert(sources, name) end
				-- (Wither channelled, Toxic Rain of Withering's pods, Withering Step's
				-- cloud: many stacks in quick succession)
				if name == "Wither" or name == "Toxic Rain of Withering" then stacks = 15 t_insert(sources, name) end
				if name == "Withering Step" then stacks = stacks + 3 t_insert(sources, name) end
			end
			-- (a source PoB knows but not found here - Unholy Might... - counted
			-- as a few stacks)
			if #sources == 0 then stacks = 5 end
			local value = m_max(1, m_floor(m_min(cap, stacks)))
			self:Set("multiplierWitheredStackCount", value, string.format("%d Withered kept up (%s)", value, #sources > 0 and table.concat(sources, "; "):sub(1, 120) or "a source PoB knows"))
		end

		-- counts estimated from the build's own numbers (Indigon's mana spent recently...)
		for multName, option in pairs(optionForMult) do
			if env.multipliersUsed and (env.multipliersUsed[multName] or (multName == "Rage" and env.player.modDB:Flag(nil, "Condition:CanGainRage"))) then
				local value, reason = self:RealisticCount(multName, output, env)
				if value then
					self:Set(option.var, value, reason)
				end
			end
		end

		-- enemy debuffs the build keeps up: a line that inflicts it on hit (with
		-- its chance) or a gem that does, kept up at the main skill's hit rate
		-- for the debuff's duration (as ailments above)
		for _, debuff in ipairs(enemyDebuffs) do
			local option = self.optionByVar[debuff.var]
			if option and self:IsUsed(option) then
				local best = 0
				for _, line in ipairs(lines) do
					local found = false
					for _, word in ipairs(debuff.words) do
						if line:find(word, 1, true) then found = true break end
					end
					if found and (line:find("on hit", 1, true) or line:find("when you hit", 1, true) or line:find("with hits", 1, true)
						or line:find("on melee hit", 1, true) or line:find("on critical", 1, true))
						and not line:find("against", 1, true) and not line:find("you are", 1, true) and not line:find("cannot", 1, true)
						and not line:find("while", 1, true) then
						local chance = tonumber(line:match("(%d+)%% chance")) or 100
						if line:find("on critical", 1, true) then chance = chance * math.min(1, crit / 100) end
						best = math.max(best, chance)
					end
				end
				for _, name in ipairs(gems) do
					for _, g in ipairs(debuff.gems or { }) do
						if name == g then best = 100 end
					end
				end
				local p = math.min(1, best / 100)
				local uptime = p >= 1 and 1 or (1 - (1 - p) ^ (hitRate * debuff.duration))
				if best > 0 then
					self:Set(debuff.var, uptime >= threshold, string.format("%.0f%% chance per hit, %.1f hits/s: up %.0f%% of the time", best, hitRate, uptime * 100))
				end
			end
		end
		-- exposure from a skill the build keeps casting (Wave of Conviction on
		-- Automation: the element the build deals most of; Frost Bomb: cold)
		local hasGem = { }
		for _, name in ipairs(gems) do hasGem[name] = true end
		if hasGem["Wave of Conviction"] then
			local bestType, bestHit
			for _, t in ipairs({ "Fire", "Cold", "Lightning" }) do
				local hit = skillValue(output, t .. "HitAverage") or 0
				if hit > 0 and (not bestHit or hit > bestHit) then bestType, bestHit = t, hit end
			end
			if bestType then setIfUsed("conditionEnemy" .. bestType .. "Exposure", true, "Wave of Conviction applies " .. bestType:lower() .. " exposure") end
		end
		if hasGem["Frost Bomb"] then
			setIfUsed("conditionEnemyColdExposure", true, "Frost Bomb applies cold exposure")
		end
		-- states the build gives itself from its own lines (Elusive, Onslaught,
		-- Unholy Might...: Classes/UniqueComboFinder), when something uses them
		local comboFinder = new("UniqueComboFinder"):UniqueComboFinder({ build = self.build, itemsTab = self.build.itemsTab, options = { } })
		-- (and off again when the line is gone: states switched on here are
		-- remembered on the configuration tab; a mid-tier Righteous Fire kept
		-- "on Consecrated Ground" after the passive giving it was respecced -
		-- its regeneration held up the burn in the generator's numbers only)
		local configTab = self.build.configTab
		configTab.autoSelfBuffs = configTab.autoSelfBuffs or { }
		local found = { }
		for _, state in ipairs(comboFinder.SelfBuffs(lines, hitRate, boss)) do
			setIfUsed(state.var, state.on, state.reason)
			if state.on then found[state.var] = true configTab.autoSelfBuffs[state.var] = true end
		end
		for var in pairs(configTab.autoSelfBuffs) do
			if not found[var] and configTab.input[var] then
				self:Set(var, false, "no line keeps it up any more")
				configTab.autoSelfBuffs[var] = nil
			end
		end

		-- leech and life
		-- (poewiki Leech: every life leech instance is discarded the moment
		-- unreserved life is full, so "while Leeching" holds only while life
		-- stays below full - overleech (Petrified Blood, "not removed when
		-- unreserved life is filled"), a life drain the build pays all the time
		-- (Righteous Fire, Blood Rage...), or mana leech while the skill spends
		-- mana. A build leeching with full life most of the time isn't leeching)
		local leech = (output.LifeLeechRate or 0) + (output.ManaLeechRate or 0) + (output.EnergyShieldLeechRate or 0)
		local leechReason
		if leech > 0 then
			local mod = env.player.modDB
			-- (Strength of Blood: non-instant leech isn't applied, so it never
			-- fills life and keeps going once life is below full)
			local overleech = mod:Flag(nil, "CanLeechLifeOnFullLife") or mod:Flag(nil, "UnaffectedByNonInstantLifeLeech")
			for _, group in ipairs(self.build.skillsTab.socketGroupList) do
				if group.enabled ~= false then
					for _, g in ipairs(group.gemList or { }) do
						if g.enabled ~= false and g.gemData and g.gemData.name == "Petrified Blood" then overleech = true end
					end
				end
			end
			local degen = (output.LifeRegenRecovery or 0) - (output.NetLifeRegen or output.LifeRegenRecovery or 0)
			local manaLeech = (output.ManaLeechRate or 0) > 0 and (output.ManaPerSecondCost or 0) > 0
			if overleech then leechReason = "life leech kept at full life (overleech)"
			elseif degen > 0 and (output.LifeLeechRate or 0) > 0 then leechReason = "life drained all the time: never full"
			elseif manaLeech then leechReason = "mana leech while the skill spends mana"
			else leech = 0 leechReason = "leech ends at full life (poewiki): no overleech or life drain" end
		end
		setIfUsed("conditionLeeching", leech > 0, leechReason or "the build does not leech")
		local life, unreserved = output.Life or 0, output.LifeUnreserved
		if life > 1 and unreserved then
			local lowLife = unreserved / life <= 0.5
			setIfUsed("conditionLowLife", lowLife, lowLife and "half of life or more is reserved" or "life is not reserved to low life")
		end
	end
	self:Recalculate()
	if self.build.configTab.UpdateControls then
		self.build.configTab:UpdateControls()
	end
	return self.changes
end
