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

function AutoConfigClass:GeneratesCharge(kind, lines, gems, flags)
	local word = kind:lower()
	for _, line in ipairs(lines) do
		-- "gain a frenzy charge on hit", "grant an endurance, frenzy or power charge"...
		if line:find(word, 1, true) and line:find("charge", 1, true) and (line:find("gain") or line:find("grant") or line:find("generat"))
			and not line:find("lose") and not line:find("maximum") then
			return true
		end
	end
	for _, name in ipairs(gems) do
		-- (a charge support's condition must be met: "on Melee Stun" needs a melee skill)
		local conditionMet = not (name:find("Melee", 1, true) and flags and not flags.melee)
		if name:find(kind .. " Charge", 1, true) and conditionMet then return true end
		for _, skill in ipairs(chargeSkills[kind]) do
			if name == skill then return true end
		end
	end
	return false
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
			if self:GeneratesCharge(kind, lines, gems, flags) then
				self:Set("use" .. kind .. "Charges", true, "the build generates them")
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

		-- what the main skill does
		local function setIfUsed(var, value, reason)
			local option = self.optionByVar[var]
			if option and self:IsUsed(option) then self:Set(var, value, reason) end
		end
		setIfUsed("conditionUsedSkillRecently", true, "you use your main skill")
		setIfUsed("conditionAttackedRecently", flags.attack and true or false, flags.attack and "main skill is an attack" or "main skill is not an attack")
		setIfUsed("conditionCastSpellRecently", flags.spell and true or false, flags.spell and "main skill is a spell" or "main skill is not a spell")
		setIfUsed("conditionHitRecently", flags.hit and true or false, flags.hit and "main skill hits" or "main skill does not hit")
		local crit = skillValue(output, "CritChance") or 0
		setIfUsed("conditionCritRecently", crit >= 30, string.format("%.0f%% critical strike chance", crit))
		setIfUsed("conditionKilledRecently", not boss, boss and "not while fighting a boss" or "clearing maps")
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
			end
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
		if modDB:Flag(nil, "Condition:CanWither") then
			self:Set("multiplierWitheredStackCount", 15, "withering is kept up at its maximum")
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
		for _, state in ipairs(comboFinder.SelfBuffs(lines, hitRate, boss)) do
			setIfUsed(state.var, state.on, state.reason)
		end

		-- leech and life
		local leech = (output.LifeLeechRate or 0) + (output.ManaLeechRate or 0) + (output.EnergyShieldLeechRate or 0)
		setIfUsed("conditionLeeching", leech > 0, leech > 0 and "the build leeches" or "the build does not leech")
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
