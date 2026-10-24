-- Path of Building
--
-- Class: Condition Audit
-- Damage hidden behind a condition: every condition of the configuration the
-- build's own modifiers use ("while on Full Life", "against Maimed enemies",
-- "while you have Onslaught"...) that is off, switched on for a moment and
-- measured. The big ones point to what would scale the build most - if
-- something keeps the condition up. Sources are found in the game data: any
-- unique or passive with a modifier that grants that condition (PoB counts it
-- like the configuration's switch, so a source is measured as it is).
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert
local t_sort = table.sort

---@class ConditionAudit
local ConditionAuditClass = newClass("ConditionAudit")

function ConditionAuditClass:ConditionAudit(gen)
	self.gen = gen
	self.build = gen.build
	return self
end

-- Conditions that can't be kept up all the time (a build counting them would
-- feel good only now and then) or that describe the fight, not the build
ConditionAuditClass.skipped = {
	conditionMoving = true, conditionFocused = true, conditionInsane = true, conditionUsingFlask = true, conditionUsingTincture = true,
	conditionUsedVaalSkillRecently = true, conditionStunnedRecently = true, conditionBeenHitRecently = true, conditionBeenCritRecently = true,
	conditionBeenSavageHitRecently = true, conditionBeenHitByAttackRecently = true, conditionHitByFireDamageRecently = true,
	conditionHitByColdDamageRecently = true, conditionHitByLightningDamageRecently = true, conditionHitBySpellDamageRecently = true,
	conditionTakenFireDamageFromEnemyHitRecently = true, conditionStunnedWhileCastingRecently = true, conditionLowLife = true,
	conditionLowMana = true, conditionLowEnergyShield = true, conditionBlinded = true, conditionBurning = true, conditionIgnited = true,
	conditionScorched = true, conditionChilled = true, conditionFrozen = true, conditionBrittle = true, conditionShocked = true,
	conditionSapped = true, conditionBleeding = true, conditionPoisoned = true, conditionKilledRecently = true, conditionKilledUniqueEnemy = true,
	conditionKilledTauntedEnemyRecently = true, conditionKilledAffectedByDoT = true, conditionMinionsDiedRecently = true,
	conditionShatteredEnemyRecently = true, conditionFrozenEnemyRecently = true, conditionEnemyFrozen = true, conditionEnemyLowLife = true,
	conditionEnemyFullLife = true, conditionEnemyStunned = true, LostNonVaalBuffRecently = true, EVBypass = true,
	conditionSingleBleed = true, conditionNonPoisonedOnly = true, changedStance = true, conditionChangedStanceLastSecond = true,
	conditionHeadhunterBuffs = true, conditionSacrificeMinion = true, conditionStoppedTakingDamageOverTimeRecently = true,
}

-- The condition a configuration option sets (its ifCond / ifEnemyCond)
local function conditionOf(option)
	local c = option.ifCond or option.ifEnemyCond
	if type(c) == "table" then c = c[1] end
	return c, option.ifEnemyCond ~= nil
end

-- Conditions used by the build and off, with what switching each on gains:
-- { { var, label, condition, enemy, gain } }, best first
function ConditionAuditClass:Gains(minGain)
	local gen = self.gen
	local configTab = self.build.configTab
	local input = configTab.input
	gen:Recalculate()
	local env = self.build.calcsTab.mainEnv
	local current = gen:Score()
	local list = { }
	for _, option in ipairs(new("AutoConfig"):AutoConfig(self.build).optionList or { }) do
		local cond, enemy = conditionOf(option)
		if option.type == "check" and cond and not self.skipped[option.var] and not input[option.var] then
			local used = enemy and env.enemyConditionsUsed[cond] or (not enemy and env.conditionsUsed[cond])
			if used then
				input[option.var] = true
				configTab:BuildModList()
				gen:Recalculate()
				local score = gen:Score()
				input[option.var] = nil
				configTab:BuildModList()
				gen:Recalculate()
				local gain = score - current
				if gain >= (minGain or 0.02) then
					t_insert(list, { var = option.var, label = (option.label or option.var):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""), condition = cond, enemy = enemy, gain = gain })
				end
			end
		end
	end
	t_sort(list, function(a, b) return a.gain > b.gain end)
	return list
end

-- Does a modifier list grant the condition (outright: a Condition:X flag)?
local function grants(modList, cond, enemy)
	for _, mod in ipairs(modList or { }) do
		if mod.type == "FLAG" and (mod.name == "Condition:" .. cond or (enemy and mod.name == "EnemyCondition:" .. cond)) then return true end
		-- (enemy conditions applied by you: "Nearby Enemies are Intimidated")
		if enemy and mod.name == "EnemyModifier" and type(mod.value) == "table" and mod.value.mod and mod.value.mod.name == "Condition:" .. cond then return true end
	end
	return false
end

-- Uniques with a modifier granting the condition
function ConditionAuditClass:UniqueSources(cond, enemy)
	local list, seen = { }, { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		if not seen[title] then
			for _, modLine in ipairs(item.explicitModLines or { }) do
				local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
				if current and grants(modLine.modList, cond, enemy) then
					seen[title] = true
					t_insert(list, item)
					break
				end
			end
		end
	end
	t_sort(list, function(a, b) return (a.title or a.name) < (b.title or b.name) end)
	return list
end

-- Passives (not allocated, in reach) granting the condition
function ConditionAuditClass:PassiveSources(cond, enemy, maxPath)
	local list = { }
	local spec = self.build.spec
	for _, node in pairs(spec.nodes) do
		if not node.alloc and not node.ascendancyName and node.path and #node.path <= (maxPath or 8) and grants(node.modList, cond, enemy) then
			t_insert(list, node)
		end
	end
	t_sort(list, function(a, b) return #a.path < #b.path or (#a.path == #b.path and a.id < b.id) end)
	return list
end
