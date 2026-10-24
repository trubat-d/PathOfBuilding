-- Path of Building
--
-- Class: Hit Overlap
-- How many times one use of the main skill hits the same target is an
-- assumption, not something PoB calculates in general:
--   * by default PoB counts 1 hit per target
--   * about ten skills have a manual "# of overlapping ..." Config setting,
--     and a few have a geometric model based on the enemy radius
--   * in the game, projectiles from one use of a skill generally cannot hit
--     the same target more than once; skill data marks the exceptions with
--     "projectiles_can_shotgun"
-- This class lists those assumptions for a build, and in the optimistic
-- scenario adds extra hits only where the game allows them.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local m_max = math.max
local configOptions = require("Modules.ConfigOptions")

---@class HitOverlap
local HitOverlapClass = newClass("HitOverlap")

HitOverlapClass.scenarioList = {
	{ label = "1 hit per target (safe, PoB default)", id = "SAFE" },
	{ label = "Optimistic overlap on a boss", id = "OPTIMISTIC" },
}

-- Share of extra projectiles assumed to connect on a large target
local optimisticShare = 0.5

function HitOverlapClass:HitOverlap(build, scenario)
	self.build = build
	self.scenario = scenario or self.scenarioList[1]
	self:Analyse()
	return self
end

local function hasStat(grantedEffect, statName)
	for _, stat in ipairs(grantedEffect and grantedEffect.stats or { }) do
		if stat == statName then
			return true
		end
	end
	return false
end

-- Reads the main skill and the Config tab
function HitOverlapClass:Analyse()
	self.assumptions = { }
	self.canShotgun = false
	self.modeledByPoB = false
	local env = self.build.calcsTab.mainEnv
	local skill = env and env.player and env.player.mainSkill
	if skill and skill.activeEffect and skill.activeEffect.grantedEffect then
		local grantedEffect = skill.activeEffect.grantedEffect
		self.skillName = grantedEffect.name
		self.isProjectile = skill.skillTypes and skill.skillTypes[SkillType.Projectile] or false
		self.canShotgun = hasStat(grantedEffect, "projectiles_can_shotgun")
	end
	-- Overlap-style settings the user has set in the Config tab
	local input = self.build.configTab and self.build.configTab.input or { }
	for _, option in ipairs(configOptions) do
		local var = option.var
		if var and (var:match("[Oo]verlap") or var:match("[Ss]hotgun") or var == "enemyRadius") then
			local value = input[var]
			if value and value ~= 0 and value ~= 1 and value ~= false then
				self.modeledByPoB = true
				t_insert(self.assumptions, string.format("Config: %s %s", (option.label or var):gsub(":$", ""), tostring(value)))
			end
		end
	end
	if self.scenario.id == "OPTIMISTIC" then
		if self.canShotgun and not self.modeledByPoB then
			t_insert(self.assumptions, string.format("Optimistic: %d%% of extra projectiles hit the same target", optimisticShare * 100))
		elseif self.isProjectile and not self.canShotgun then
			t_insert(self.assumptions, (self.skillName or "This skill") .. " cannot hit one target with several projectiles from one use, so no extra hits are counted")
		end
	end
end

-- Adds the extra hits of the optimistic scenario to a DPS figure
function HitOverlapClass:AdjustDPS(output, dps)
	if self.scenario.id ~= "OPTIMISTIC" or not self.canShotgun or self.modeledByPoB then
		return dps
	end
	local projectiles = output.ProjectileCount or 1
	if projectiles <= 1 then
		return dps
	end
	local hitDps = output.TotalDPS or 0
	return dps + hitDps * (projectiles - 1) * optimisticShare
end

-- Strings shown on idea cards
function HitOverlapClass:GetAssumptions()
	return self.assumptions
end
