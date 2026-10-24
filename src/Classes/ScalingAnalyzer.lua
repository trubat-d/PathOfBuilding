-- Path of Building
--
-- Class: Scaling Analyzer
-- What scales a build next: the same small amount of each kind of stat
-- (about one notable's worth: increased damage, crit multiplier, speed,
-- penetration, flat damage of the skill's types, mana, attributes, gem levels,
-- life, energy shield, armour, resistances...) is added on its own, and the
-- change in damage, tankiness and score measured with PoB's calculator.
-- Damage is a product of buckets (base x increased x more x crit x speed x
-- penetration...), so a bucket that is already big gains little and a small
-- one gains a lot: this shows which buckets are saturated and where the next
-- passive, jewel or rare mod is worth the most. Used for the generator's
-- summary and the archetype scan.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort

---@class ScalingAnalyzer
local ScalingAnalyzerClass = newClass("ScalingAnalyzer")

-- scorer: BuildScorer; calcFunc: a misc calculator of the build
function ScalingAnalyzerClass:ScalingAnalyzer(build, scorer, calcFunc)
	self.build = build
	self.scorer = scorer
	self.calcFunc = calcFunc
	return self
end

-- Damage types the main skill deals (from its gem tags)
local function skillTypes(build)
	local env = build.calcsTab.mainEnv
	local skill = env and env.player.mainSkill
	local gem = skill and skill.activeEffect and skill.activeEffect.gemData
	local tags = gem and gem.tags or { }
	local flags = skill and skill.skillFlags or { }
	local types = { }
	for _, t in ipairs({ "Fire", "Cold", "Lightning", "Physical", "Chaos" }) do
		if tags[t:lower()] then t_insert(types, t) end
	end
	if #types == 0 then types = { "Physical" } end
	return types, flags.spell, flags.attack
end

-- Levers: { id, label, kind = "damage" / "defence", lines, max }
-- (max: how many units of it a build can realistically stack, from passives,
-- jewels and gear - e.g. only about +3 gem levels exist)
function ScalingAnalyzerClass:Levers()
	local types, spell, attack = skillTypes(self.build)
	local list = {
		{ id = "inc", max = 10, label = "+30% increased damage", kind = "damage", lines = { "30% increased Damage" } },
		{ id = "critMulti", max = 8, label = "+25% critical strike multiplier", kind = "damage", lines = { "+25% to Critical Strike Multiplier" } },
		{ id = "critChance", max = 6, label = "+60% increased critical strike chance", kind = "damage", lines = { "60% increased Critical Strike Chance" } },
		{ id = "speed", max = 6, label = "+8% attack and cast speed", kind = "damage", lines = { "8% increased Attack and Cast Speed" } },
		{ id = "pen", max = 4, label = "6% elemental penetration", kind = "damage", lines = { "Damage Penetrates 6% Elemental Resistances" } },
		{ id = "gemLevel", max = 3, label = "+1 level to all skill gems", kind = "damage", lines = { "+1 to Level of all Skill Gems" } },
		{ id = "dotMulti", max = 6, label = "+15% damage over time multiplier", kind = "damage", lines = { "+15% to Damage over Time Multiplier" } },
		{ id = "mana", max = 15, label = "+300 maximum mana", kind = "damage", lines = { "+300 to maximum Mana" } },
		{ id = "int", max = 10, label = "+60 intelligence", kind = "damage", lines = { "+60 to Intelligence" } },
		{ id = "str", max = 10, label = "+60 strength", kind = "damage", lines = { "+60 to Strength" } },
		{ id = "dex", max = 10, label = "+60 dexterity", kind = "damage", lines = { "+60 to Dexterity" } },
		{ id = "aoe", max = 3, label = "+20% area of effect", kind = "damage", lines = { "20% increased Area of Effect" } },
		{ id = "life", max = 6, label = "+8% maximum life", kind = "defence", lines = { "8% increased maximum Life" } },
		{ id = "es", max = 6, label = "+12% maximum energy shield", kind = "defence", lines = { "12% increased maximum Energy Shield" } },
		{ id = "armour", max = 4, label = "+40% armour", kind = "defence", lines = { "40% increased Armour" } },
		{ id = "evasion", max = 4, label = "+40% evasion", kind = "defence", lines = { "40% increased Evasion Rating" } },
		{ id = "maxRes", max = 2, label = "+1% all maximum elemental resistances", kind = "defence", lines = { "+1% to all maximum Elemental Resistances" } },
		{ id = "chaosRes", max = 4, label = "+20% chaos resistance", kind = "defence", lines = { "+20% to Chaos Resistance" } },
	}
	-- flat damage of the skill's own types, to spells or attacks
	for _, t in ipairs(types) do
		if spell then
			t_insert(list, { id = "flatSpell" .. t, max = 6, label = "flat " .. t:lower() .. " damage to spells", kind = "damage", lines = { "Adds 20 to 40 " .. t .. " Damage to Spells" } })
		end
		if attack then
			t_insert(list, { id = "flatAttack" .. t, max = 6, label = "flat " .. t:lower() .. " damage to attacks", kind = "damage", lines = { "Adds 15 to 30 " .. t .. " Damage to Attacks" } })
		end
	end
	return list
end

local nextId = -9000
local function virtualNode(spec, lines)
	nextId = nextId - 1
	local node = { id = nextId, type = "Normal", name = "Scaling probe", dn = "Scaling probe", sd = { } }
	for i, l in ipairs(lines) do node.sd[i] = l end
	spec.tree:ProcessStats(node)
	return node
end

-- Runs every lever: returns { base = { dps, score, tank }, levers = { { lever, dpsGain, tankGain, scoreGain } } }
-- dpsGain: relative DPS change (0.05 = +5%); tankGain: change of the tank part
-- of the score (log scale, 0.05 ~ +5% max hit / hit pool)
function ScalingAnalyzerClass:Run()
	local scorer = self.scorer
	local spec = self.build.spec
	local function measure(override)
		local output = self.calcFunc(override or { })
		local dps = scorer:GetDPS(output)
		local score = scorer:ScoreOutput(output)
		local minHit, meanLog = scorer:MinMaxHit(output)
		local tank = minHit and (0.6 * math.log(minHit) + 0.4 * meanLog) or math.log(math.max(1, scorer:GetEHP(output)))
		return dps, score, tank
	end
	local baseDps, baseScore, baseTank = measure()
	local results = { }
	for _, lever in ipairs(self:Levers()) do
		local node = virtualNode(spec, lever.lines)
		local dps, score, tank = measure({ addNodes = { [node] = true } })
		t_insert(results, {
			lever = lever,
			dpsGain = baseDps > 0 and (dps / baseDps - 1) or 0,
			tankGain = tank - baseTank,
			scoreGain = score - baseScore,
		})
	end
	t_sort(results, function(a, b) return a.scoreGain > b.scoreGain end)
	return { base = { dps = baseDps, score = baseScore, tank = baseTank }, levers = results }
end

-- One-line summaries: best damage levers and best defence levers
function ScalingAnalyzerClass.Summary(result, count)
	local damage, defence = { }, { }
	for _, r in ipairs(result.levers) do
		if r.lever.kind == "damage" and r.dpsGain > 0.005 then
			t_insert(damage, r)
		elseif r.lever.kind == "defence" and r.tankGain > 0.005 then
			t_insert(defence, r)
		end
	end
	t_sort(damage, function(a, b) return a.dpsGain > b.dpsGain end)
	t_sort(defence, function(a, b) return a.tankGain > b.tankGain end)
	local function list(entries, field)
		local parts = { }
		for i = 1, math.min(count or 4, #entries) do
			local r = entries[i]
			t_insert(parts, string.format("%s %+.1f%%", r.lever.label, (field == "dps" and r.dpsGain or (math.exp(r.tankGain) - 1)) * 100))
		end
		return table.concat(parts, ", ")
	end
	local saturated = { }
	for _, r in ipairs(result.levers) do
		if r.lever.id == "inc" and r.dpsGain < 0.04 then t_insert(saturated, "increased damage") end
		if r.lever.id == "critMulti" and r.dpsGain < 0.01 then t_insert(saturated, "crit multiplier (crit chance too low, or non-crit)") end
	end
	return {
		damage = #damage > 0 and ("Damage scales best with: " .. list(damage, "dps")) or nil,
		defence = #defence > 0 and ("Tankiness (max hit) scales best with: " .. list(defence, "tank")) or nil,
		saturated = #saturated > 0 and ("Already saturated: " .. table.concat(saturated, ", ")) or nil,
	}
end
