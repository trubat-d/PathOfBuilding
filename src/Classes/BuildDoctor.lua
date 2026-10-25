-- Path of Building
--
-- Class: Build Doctor
-- Reasons about a build's damage as a product of layers instead of one
-- passive at a time (docs/scalingVectors.md): base / flat, increased, more,
-- crit (chance x multiplier together), speed, enemy resistance (curse,
-- exposure, penetration), damage taken, damage over time multiplier, gem
-- level, the pools some skills scale with (Righteous Fire: life and energy
-- shield), charges.
--
-- 1. The damage mode (hits, ignite, bleed, poison, a skill's own DoT) decides
--    which layers apply (penetration and crit multiplier never apply to
--    ailments; speed barely helps a non-stacking ailment...).
-- 2. Each layer gets a test dose (a virtual passive with its stat) measured
--    by PoB, and, for layers that only pay off when built together, a full
--    commitment (crit: chance and multiplier at once, Elemental Overload
--    dropped). Divided by what that much of the layer typically costs in
--    passive points or affixes, it gives the damage per point each layer has
--    left: the build is balanced when they are about equal.
-- 3. The layers with the most left become plans: the build rebuilt with that
--    layer valued on its own while it is made (a stat lens), conflicting
--    keystones dropped, tree, supports, curses / auras and rares chosen
--    again; kept only when the finished build scores better.
-- 4. Pools spent twice or for nothing: Mind over Matter with no mana (Blood
--    Magic, Eternal Youth), and Mind over Matter against reserving that mana
--    for auras (mana stackers excepted).
--
-- gen: a BuildGenerator (Score, FullScore, Snapshot, Restore, RefineTree,
-- ChooseSupports, ChooseUtilityGems, FinalRares, AutoConfigure, Note, build)
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local m_max = math.max
local m_min = math.min
local m_log = math.log

local BuildDoctorClass = newClass("BuildDoctor")

function BuildDoctorClass:BuildDoctor(gen)
	self.gen = gen
	self.build = gen.build
	return self
end

local ELEMENTS = { "Fire", "Cold", "Lightning" }

-- What the main skill's damage is made of: shares of the combined DPS
function BuildDoctorClass:Mode()
	local o = self.build.calcsTab.mainOutput or { }
	local env = self.build.calcsTab.mainEnv
	local skill = env and env.player.mainSkill
	local flags = skill and skill.skillFlags or { }
	local combined = m_max(1, (o.CombinedDPS or 0) - (o.CullingDPS or 0))
	local parts = {
		hit = (o.TotalDPS or 0) + (o.ImpaleDPS or 0),
		ignite = o.IgniteDPS or 0,
		bleed = o.BleedDPS or 0,
		poison = o.PoisonDPS or 0,
		dot = (o.TotalDot or 0) + (o.BurningGroundDPS or 0) + (o.CausticGroundDPS or 0),
	}
	local main, best = "hit", -1
	for k, v in pairs(parts) do
		if v > best then main, best = k, v end
	end
	local shares = { }
	for k, v in pairs(parts) do shares[k] = v / combined end
	-- the hit's main damage type (for penetration, curses, flat damage)
	local element, top = nil, 0
	for _, t in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
		local v = o[t .. "HitAverage"] or 0
		if v > top then element, top = t, v end
	end
	if main == "ignite" then element = "Fire"
	elseif main == "poison" then element = "Chaos"
	elseif main == "bleed" then element = "Physical"
	elseif main == "dot" and not element then
		for _, t in ipairs({ "Fire", "Cold", "Lightning", "Chaos", "Physical" }) do
			if (o[t .. "Dot"] or 0) > 0 then element = t break end
		end
	end
	return {
		main = main, shares = shares, element = element or "Physical",
		spell = flags.spell, attack = flags.attack, minion = flags.minion,
		hits = parts.hit > 0.15 * combined,
		output = o,
	}
end

-- Test doses: per layer, the stat lines of one dose, what that much
-- typically costs (passive points, an affix counted as about 3 points), and
-- which damage modes it applies to. commit: a full commitment for layers
-- that only pay off when built together; drop: keystones it conflicts with.
local function layerList(mode)
	local e = mode.element
	local elemental = e == "Fire" or e == "Cold" or e == "Lightning"
	local isHit = mode.main == "hit"
	local isAilment = mode.main == "ignite" or mode.main == "bleed" or mode.main == "poison"
	local isDot = mode.main == "dot" or isAilment
	local list = {
		{ id = "increased", label = "Increased damage (one additive pool)", lines = { "25% increased Damage" }, cost = 2.5 },
		{ id = "more", label = "More damage (supports, ascendancy)", lines = { "10% more Damage" }, cost = 6 },
		{ id = "crit", label = "Critical strikes (chance x multiplier)", hitOnly = true, lines = { "100% increased Critical Strike Chance" }, cost = 4,
			-- (a realistic endgame crit investment: tree, jewels, a crit support,
			-- Assassin's Mark / Power Charge On Critical, gear; top Winter Orbs
			-- reach 99% chance and x8)
			commit = { "+4% to Critical Strike Chance", "500% increased Critical Strike Chance", "+250% to Critical Strike Multiplier" }, commitCost = 30,
			drop = { "Elemental Overload", "Resolute Technique" } },
		{ id = "speed", label = mode.attack and "Attack speed" or "Cast speed", hitOnly = not (mode.main == "poison"), lines = { "15% increased Attack and Cast Speed" }, cost = 3.5 },
		{ id = "penetration", label = e .. " penetration (hits only)", hitOnly = true, lines = { "Damage Penetrates 15% " .. e .. " Resistance" }, cost = 4,
			skip = e == "Physical" },
		{ id = "resistance", label = "Enemy " .. e:lower() .. " resistance (curse, exposure)", lines = { "Nearby Enemies have -15% to " .. e .. " Resistance" }, cost = 5,
			skip = e == "Physical" },
		{ id = "taken", label = "Damage taken by the enemy (shock, wither, Vulnerability...)", lines = { "Nearby Enemies take 15% increased Damage" }, cost = 5 },
		{ id = "dotmulti", label = "Damage over time multiplier", dotOnly = true, lines = { "+25% to Damage over Time Multiplier" }, cost = 3 },
		{ id = "duration", label = "Ailment duration (stacking poison)", modes = { poison = true }, lines = { "30% increased Duration of Ailments on Enemies" }, cost = 3 },
		{ id = "gemlevel", label = "Gem levels", lines = { "+1 to Level of all Skill Gems" }, cost = 3 },
		{ id = "flat", label = "Flat added " .. e:lower() .. " damage (x the skill's effectiveness)", notModes = { dot = true },
			lines = { string.format("Adds 60 to 100 %s Damage", e) }, cost = 3 },
		{ id = "extra", label = "Gain as extra damage", notModes = { dot = true }, lines = { "Gain 10% of Non-Chaos Damage as extra Chaos Damage" }, cost = 4 },
		-- (pools: 10% more of the whole pool, not 15% increased, which a pool at
		-- 200% increased turns into 5%: how much the damage follows the pool)
		{ id = "life", label = "Maximum life (the base of life-scaled skills)", pool = "Life", lines = { "10% more maximum Life" }, cost = 6 },
		{ id = "es", label = "Maximum energy shield", pool = "EnergyShield", lines = { "10% more maximum Energy Shield" }, cost = 6 },
		{ id = "mana", label = "Maximum mana", pool = "Mana", lines = { "10% more maximum Mana" }, cost = 6 },
		{ id = "power", label = "Maximum power charges", lines = { "+1 to Maximum Power Charges" }, cost = 4 },
	}
	local out = { }
	for _, l in ipairs(list) do
		local ok = not l.skip
		if l.hitOnly and not mode.hits then ok = false end
		if l.dotOnly and not isDot then ok = false end
		if l.modes and not l.modes[mode.main] then ok = false end
		if l.notModes and l.notModes[mode.main] then ok = false end
		if ok then t_insert(out, l) end
	end
	return out
end

-- A virtual passive carrying stat lines (as PoB's power report does)
local probeId = -960000
local function probeNode(tree, lines)
	probeId = probeId - 1
	local node = { id = probeId, type = "Normal", name = "doctor probe", dn = "doctor probe", sd = { } }
	for i, l in ipairs(lines) do node.sd[i] = l end
	tree:ProcessStats(node)
	return node
end

-- The layer report: for each layer that applies, the damage a dose brings
-- (x DPS), per point of its cost, and for commit layers the full commitment
function BuildDoctorClass:Diagnose()
	local gen = self.gen
	local spec = self.build.spec
	gen:Recalculate()
	local mode = self:Mode()
	local baseScore, baseR = gen:Score()
	local baseDps = m_max(1, baseR.dps or 0)
	local function measure(lines, dropNames)
		local override = { addNodes = { [probeNode(spec.tree, lines)] = true } }
		if dropNames then
			override.removeNodes = { }
			for _, name in ipairs(dropNames) do
				for _, node in pairs(spec.allocNodes) do
					if node.dn == name then override.removeNodes[node] = true end
				end
			end
		end
		local score, r = gen:Score(override)
		if os.getenv("DOCTOR_DEBUG") then
			local removed = { }
			for node in pairs(override.removeNodes or { }) do t_insert(removed, node.dn) end
			ConPrintf("[doctor probe] %s | removed: %s | crit %.1f%% x%.2f, dps %.0f", table.concat(lines, "; "), table.concat(removed, ", "),
				r.output and r.output.CritChance or -1, r.output and r.output.CritMultiplier or -1, r.dps or 0)
		end
		return score - baseScore, m_max(1e-9, (r.dps or 0) / baseDps)
	end
	-- supports in the main link that block crit ("less critical strike
	-- chance": Controlled Destruction): a full crit commitment takes them out,
	-- so the probe cancels their crit penalty and their damage bonus
	local blockers, cancel = { }, { }
	local env = self.build.calcsTab.mainEnv
	local skill = env and env.player.mainSkill
	if skill then
		local critLess, damageMore = 1, 1
		for _, row in ipairs(skill.skillModList:Tabulate("MORE", skill.skillCfg, "CritChance")) do
			local source = row.mod.source or ""
			local name = source:match("^Skill:(Support.+)$")
			if row.value < 0 and name then
				critLess = critLess * (1 + row.value / 100)
				local gem
				for _, g in ipairs(self.gen.mainGroup and self.gen.mainGroup.gemList or { }) do
					if g.gemData and g.gemData.grantedEffect and g.gemData.grantedEffect.id == name then gem = g.gemData end
				end
				if gem then blockers[gem.name] = true end
				for _, d in ipairs(skill.skillModList:Tabulate("MORE", skill.skillCfg, "Damage", "ElementalDamage", "ColdDamage", "FireDamage", "LightningDamage", "PhysicalDamage", "ChaosDamage")) do
					if d.mod.source == source and d.value > 0 then damageMore = damageMore * (1 + d.value / 100) end
				end
			end
		end
		if critLess < 1 then
			t_insert(cancel, string.format("%d%% more Critical Strike Chance", math.floor((1 / critLess - 1) * 100 + 0.5)))
			if damageMore > 1 then t_insert(cancel, string.format("%d%% less Damage", math.floor((1 - 1 / damageMore) * 100 + 0.5))) end
		end
	end
	self.critBlockers = blockers
	local layers = { }
	for _, l in ipairs(layerList(mode)) do
		local gain, ratio = measure(l.lines)
		local entry = { layer = l, gain = gain, ratio = ratio, perPoint = m_log(ratio) / l.cost }
		if l.commit then
			local lines = { }
			for _, x in ipairs(l.commit) do t_insert(lines, x) end
			if l.id == "crit" then for _, x in ipairs(cancel) do t_insert(lines, x) end end
			entry.commitGain, entry.commitRatio = measure(lines, l.drop)
			entry.commitPerPoint = m_log(entry.commitRatio) / l.commitCost
		end
		t_insert(layers, entry)
		gen:Tick()
	end
	t_sort(layers, function(a, b)
		return m_max(a.perPoint, a.commitPerPoint or -1) > m_max(b.perPoint, b.commitPerPoint or -1)
	end)
	-- the current state of the layers worth showing
	local o = mode.output
	local state = {
		critChance = o.CritChance, critMulti = o.CritMultiplier, critEffect = o.CritEffect,
		speed = o.Speed, life = o.Life, es = o.EnergyShield, mana = o.Mana, power = o.PowerChargesMax,
		effMult = o[mode.element .. "EffMult"],
	}
	-- the gap to the skill's top players, layer by layer
	local profile = self:Profile()
	-- (top players' targets only with player knowledge on: without it the
	-- plans come from the test doses alone)
	local target = gen.options.playerKnowledge ~= false and self.Targets(gen.mainGem and gen.mainGem.name) or nil
	local gaps
	if target and target.mode == profile.mode then
		gaps = { }
		for _, k in ipairs({ "crit", "speed", "enemy", "increased", "more", "dotMulti", "power", "frenzy", "life", "es" }) do
			if target[k] and profile[k] and profile[k] > 0 and target[k] > 0 then
				gaps[k] = { ours = profile[k], target = target[k], ratio = target[k] / profile[k] }
			end
		end
	end
	gen:Recalculate()
	self.report = { mode = mode, layers = layers, state = state, baseScore = baseScore, baseDps = baseDps, profile = profile, target = target, gaps = gaps }
	return self.report
end

-- What the enemy lets through of the main damage type: resistance (after
-- curses, exposure; minus penetration for hits) and damage taken (shock,
-- wither, Vulnerability...). PoB keeps its own only in the Calcs view
function BuildDoctorClass:EnemyMultiplier(mode)
	local env = self.build.calcsTab.mainEnv
	local skill = env and env.player.mainSkill
	if not skill or not env.enemyDB then return 1 end
	local e = mode.element
	local edb = env.enemyDB
	local elemental = e == "Fire" or e == "Cold" or e == "Lightning"
	local res = 0
	if e ~= "Physical" then
		res = edb:Sum("BASE", nil, e .. "Resist") + (elemental and edb:Sum("BASE", nil, "ElementalResist") or 0)
		res = m_max(-200, m_min(res, edb:Sum("BASE", nil, e .. "ResistMax") > 0 and edb:Sum("BASE", nil, e .. "ResistMax") or 75))
	end
	if mode.main == "hit" and e ~= "Physical" then
		local mdb, cfg = skill.skillModList, skill.skillCfg
		res = res - mdb:Sum("BASE", cfg, e .. "Penetration") - (elemental and mdb:Sum("BASE", cfg, "ElementalPenetration") or 0)
	end
	local takenNames = { "DamageTaken", e .. "DamageTaken" }
	if elemental then t_insert(takenNames, "ElementalDamageTaken") end
	if mode.main ~= "hit" then t_insert(takenNames, "DamageTakenOverTime") end
	local taken = (1 + edb:Sum("INC", nil, unpack(takenNames)) / 100) * edb:More(nil, unpack(takenNames))
	return (1 - res / 100) * taken
end

-- The layers' current values (for comparing with a top player's build:
-- each one's ratio is that layer's share of the gap; their product is about
-- the DPS ratio): crit factor, speed, enemy multiplier (resistance and damage
-- taken), increased pool, more multipliers, DoT multiplier, charges, gem
-- level, pools, and the rest (base and flat damage, conversion, hits per use)
function BuildDoctorClass:Profile()
	self.gen:Recalculate()
	local mode = self:Mode()
	local o = mode.output
	local env = self.build.calcsTab.mainEnv
	local skill = env and env.player.mainSkill
	local p = { mode = mode.main, element = mode.element, dps = (o.CombinedDPS or 0) - (o.CullingDPS or 0) }
	if skill then
		local mdb, cfg = skill.skillModList, skill.skillCfg
		local e = mode.element
		local names = { "Damage", e .. "Damage" }
		if e == "Fire" or e == "Cold" or e == "Lightning" then t_insert(names, "ElementalDamage") end
		local isDot = mode.main ~= "hit"
		local dotCfg = cfg
		if isDot then t_insert(names, "DamageOverTime") end
		-- (a skill's own damage over time: PoB's DoT configuration for that
		-- type, with "Damage over Time" and the DoT keywords, and its base)
		if mode.main == "dot" and skill["dot" .. e .. "Cfg"] then
			dotCfg = skill["dot" .. e .. "Cfg"]
			names = { "Damage", e .. "Damage" }
			if e == "Fire" or e == "Cold" or e == "Lightning" then t_insert(names, "ElementalDamage") end
			p.base = skill.skillData and skill.skillData[e .. "Dot"] or nil
		end
		p.increased = 1 + mdb:Sum("INC", dotCfg, unpack(names)) / 100
		p.more = mdb:More(dotCfg, unpack(names))
		p.dotMulti = isDot and (1 + mdb:Sum("BASE", dotCfg, "DotMultiplier", e .. "DotMultiplier") / 100) or 1
		p.gemLevel = skill.activeEffect and skill.activeEffect.level or 0
	end
	p.crit = mode.main == "hit" and (o.CritEffect or 1) or 1
	p.speed = mode.main == "hit" and (o.Speed or 0) or 1
	-- (PoB's own for hits; computed for damage over time)
	p.enemy = (mode.main == "hit" and o[mode.element .. "EffMult"]) or (mode.main == "dot" and o[mode.element .. "DotEffMult"]) or self:EnemyMultiplier(mode)
	p.power, p.frenzy, p.endurance = o.PowerCharges or 0, o.FrenzyCharges or 0, o.EnduranceCharges or 0
	p.life, p.es, p.mana = o.Life or 0, o.EnergyShield or 0, o.Mana or 0
	-- the rest: whatever the named layers don't explain
	local named = (p.increased or 1) * (p.more or 1) * p.crit * m_max(p.speed, 1e-6) * p.enemy * (p.dotMulti or 1)
	p.rest = p.dps / m_max(named, 1e-9)
	return p
end

-- The skill's top players' layer targets (bench/layer_targets.py,
-- Data/GeneratorLayerTargets.json): medians of each layer; nil without one
local targetsData
function BuildDoctorClass.Targets(skillName)
	if targetsData == nil then
		targetsData = false
		local dkjson = require "dkjson"
		for _, path in ipairs({ (GetScriptPath and GetScriptPath() or ".") .. "/Data/GeneratorLayerTargets.json", "Data/GeneratorLayerTargets.json" }) do
			local f = io.open(path, "r")
			if f then
				local ok, value = pcall(dkjson.decode, f:read("*a"))
				f:close()
				if ok and type(value) == "table" and value.skills then targetsData = value.skills break end
			end
		end
	end
	return targetsData and skillName and targetsData[skillName] or nil
end

-- One line per layer, best damage per point first
function BuildDoctorClass:ReportLines(limit)
	local r = self.report
	if not r then return { } end
	local lines = { }
	local s = r.state
	local modeLabel = ({ hit = "hits", ignite = "ignite", bleed = "bleeding", poison = "poison", dot = "the skill's damage over time" })[r.mode.main] or r.mode.main
	t_insert(lines, string.format("Build doctor: damage mostly from %s (%s); crit %.0f%% x %.2f (factor x%.2f), %s %.1f/s, enemy %s damage taken x%.2f",
		modeLabel, r.mode.element:lower(), s.critChance or 0, s.critMulti or 1, s.critEffect or 1,
		r.mode.attack and "attacks" or "casts", s.speed or 0, r.mode.element:lower(), s.effMult or 1))
	if r.gaps then
		local parts = { }
		for _, k in ipairs({ "crit", "enemy", "speed", "increased", "more", "dotMulti", "power", "life", "es" }) do
			local g = r.gaps[k]
			if g and (g.ratio >= 1.15 or g.ratio <= 0.87) then
				t_insert(parts, string.format("%s %.3g vs %.3g", k, g.ours, g.target))
			end
		end
		t_insert(lines, string.format("    Against the skill's top players (%d builds, medians): %s", r.target.builds or 0, #parts > 0 and table.concat(parts, ", ") or "every layer within 15%"))
	end
	for i, e in ipairs(r.layers) do
		if i > (limit or 8) then break end
		local text = string.format("    %s: a dose x%.3f DPS (%.1f%% per point)", e.layer.label, e.ratio, (math.exp(e.perPoint) - 1) * 100)
		if e.commitRatio then
			text = text .. string.format("; committed x%.2f (%.1f%% per point)", e.commitRatio, (math.exp(e.commitPerPoint) - 1) * 100)
		end
		t_insert(lines, text)
	end
	return lines
end

-- Plans from the report: the layers with the most damage per point left
-- that the greedy allocation can't reach one passive at a time
function BuildDoctorClass:Plans()
	local r = self.report
	if not r then return { } end
	local plans = { }
	local s = r.state
	local byId = { }
	for _, e in ipairs(r.layers) do byId[e.layer.id] = e end
	local spec = self.build.spec
	local function allocated(name)
		for _, node in pairs(spec.allocNodes) do if node.dn == name then return node end end
	end
	-- the average damage per point of all the layers measured: a plan's layer
	-- must clearly beat it
	local sum, n = 0, 0
	for _, e in ipairs(r.layers) do sum, n = sum + e.perPoint, n + 1 end
	local average = n > 0 and sum / n or 0
	-- 1. crit: chance and multiplier built together
	local crit = byId.crit
	if crit and crit.commitRatio and crit.commitRatio >= 1.5 and (s.critEffect or 1) < 2.5 and crit.commitPerPoint > average * 1.2 then
		local drop = { }
		for _, name in ipairs(crit.layer.drop or { }) do if allocated(name) then t_insert(drop, name) end end
		local blockSupports = { }
		for name in pairs(self.critBlockers or { }) do t_insert(blockSupports, name) end
		t_sort(blockSupports)
		for _, name in ipairs(blockSupports) do t_insert(drop, name) end
		t_insert(plans, {
			id = "crit", label = "commit to critical strikes",
			reason = string.format("crit factor x%.2f now, x%.2f when chance and multiplier are built together (%s)", s.critEffect or 1, crit.commitRatio,
				#drop > 0 and (table.concat(drop, ", ") .. " dropped") or "no keystone in the way"),
			lens = { func = function(o) return o.CritEffect or 1 end, base = 1, label = "Crit damage factor", weight = 0.5 },
			drop = drop, blockSupports = blockSupports, rares = true, refine = 30, utility = true, value = crit.commitPerPoint,
		})
	end
	-- 2. pools the damage scales with (life for Righteous Fire, mana for
	-- mana stackers...): the pool valued on its own while rebuilding
	for _, id in ipairs({ "life", "es", "mana" }) do
		local e = byId[id]
		-- (the damage follows the pool: half or more of 10% more of it)
		if e and e.ratio >= 1.05 then
			local stat = e.layer.pool
			t_insert(plans, {
				id = "pool_" .. id, label = "stack " .. e.layer.label:lower():gsub(" %(.*%)", ""),
				reason = string.format("10%% more of it gives x%.3f damage: the skill's damage follows it", e.ratio),
				lens = { stat = stat, base = 1000, label = stat, weight = 0.5 },
				rares = true, refine = 24, value = e.perPoint,
			})
		end
	end
	-- 3. enemy resistance: curse / exposure / penetration together
	local res, pen = byId.resistance, byId.penetration
	if res and res.ratio >= 1.12 and res.perPoint > average * 1.2 then
		local element = r.mode.element
		t_insert(plans, {
			id = "resistance", label = "lower the enemy's " .. element:lower() .. " resistance",
			reason = string.format("-15%% %s resistance gives x%.3f%s", element:lower(), res.ratio, pen and string.format(", 15%% penetration x%.3f", pen.ratio) or ""),
			lens = { func = function(o) return o[element .. "EffMult"] or o.MainHand and o.MainHand[element .. "EffMult"] or 1 end, base = 0.5, label = element .. " damage multiplier against the enemy", weight = 0.5 },
			rares = true, refine = 16, utility = true, value = res.perPoint,
		})
	end
	-- 4. power charges
	local power = byId.power
	if power and power.ratio >= 1.06 and power.perPoint > average * 1.3 then
		t_insert(plans, {
			id = "power", label = "more maximum power charges",
			reason = string.format("+1 maximum power charge gives x%.3f", power.ratio),
			lens = { stat = "PowerChargesMax", base = 3, label = "Maximum power charges", weight = 0.4 },
			rares = true, refine = 16, value = power.perPoint,
		})
	end
	-- 5. Mind over Matter: with no mana it does nothing; otherwise the mana
	-- it needs unreserved is tried as aura reservation instead (mana
	-- stackers, whose damage needs the pool, keep it)
	local mom = allocated("Mind Over Matter")
	if mom then
		local mana = byId.mana
		local stacker = mana and mana.ratio >= 1.05
		if (s.mana or 0) <= 0 then
			t_insert(plans, { id = "mom_empty", label = "drop Mind over Matter", reason = "the build has no mana for it to use", drop = { "Mind Over Matter" }, refine = 4, quick = true, value = 1 })
			-- (no mana: nothing to lose, tried first)
		elseif not stacker then
			t_insert(plans, { id = "mom_auras", label = "drop Mind over Matter for auras", reason = "the mana it keeps unreserved can hold auras instead",
				drop = { "Mind Over Matter" }, auras = true, refine = 8, value = average })
		end
	end
	-- the layers clearly below the skill's top players: a plan for each, even
	-- when a test dose looks small (the players show the layer pays off)
	local gaps = r.gaps or { }
	local have = { }
	for _, p in ipairs(plans) do have[p.id] = p end
	local function gapPlan(id, key, make)
		local g = gaps[key]
		if g and g.ratio >= 1.25 then
			local existing = have[id]
			local reason = string.format("the skill's top players have %s %.3g, this build %.3g", key, g.target, g.ours)
			if existing then
				existing.value = m_max(existing.value or 0, m_log(g.ratio))
				existing.reason = existing.reason .. "; " .. reason
			else
				local p = make(g)
				if p then
					p.reason = reason
					p.value = m_log(g.ratio)
					t_insert(plans, p)
					have[id] = p
				end
			end
		end
	end
	gapPlan("crit", "crit", function()
		local drop = { }
		for _, name in ipairs({ "Elemental Overload", "Resolute Technique" }) do if allocated(name) then t_insert(drop, name) end end
		local blockSupports = { }
		for name in pairs(self.critBlockers or { }) do t_insert(blockSupports, name) t_insert(drop, name) end
		return { id = "crit", label = "commit to critical strikes", drop = drop, blockSupports = blockSupports,
			lens = { func = function(o) return o.CritEffect or 1 end, base = 1, label = "Crit damage factor", weight = 0.5 },
			rares = true, refine = 30, utility = true }
	end)
	if r.mode.main == "hit" then
		local element = r.mode.element
		gapPlan("resistance", "enemy", function()
			return { id = "resistance", label = "lower the enemy's " .. element:lower() .. " resistance and raise its damage taken",
				lens = { func = function(o) return o[element .. "EffMult"] or 1 end, base = 0.5, label = element .. " damage multiplier against the enemy", weight = 0.6 },
				rares = true, refine = 16, utility = true }
		end)
	else
		gapPlan("resistance", "enemy", function()
			return { id = "resistance", label = "lower the enemy's resistance", rares = true, refine = 16, utility = true }
		end)
	end
	gapPlan("speed", "speed", function()
		return { id = "speed", label = "more attack / cast speed", lens = { stat = "Speed", base = 1, label = "Speed", weight = 0.4 }, rares = true, refine = 16 }
	end)
	gapPlan("power", "power", function()
		return { id = "power", label = "more power charges", lens = { stat = "PowerChargesMax", base = 3, label = "Maximum power charges", weight = 0.4 }, rares = true, refine = 16 }
	end)
	gapPlan("frenzy", "frenzy", function()
		return { id = "frenzy", label = "more frenzy charges", lens = { stat = "FrenzyChargesMax", base = 3, label = "Maximum frenzy charges", weight = 0.4 }, rares = true, refine = 16 }
	end)
	gapPlan("pool_life", "life", function()
		if (byId.life and byId.life.ratio or 1) < 1.03 then return nil end
		return { id = "pool_life", label = "stack maximum life", lens = { stat = "Life", base = 1000, label = "Life", weight = 0.5 }, rares = true, refine = 24 }
	end)
	gapPlan("pool_es", "es", function()
		if (byId.es and byId.es.ratio or 1) < 1.03 then return nil end
		return { id = "pool_es", label = "stack maximum energy shield", lens = { stat = "EnergyShield", base = 1000, label = "Energy shield", weight = 0.5 }, rares = true, refine = 24 }
	end)
	t_sort(plans, function(a, b) return (a.value or 0) > (b.value or 0) end)
	return plans
end

-- Builds a plan for real and keeps it when the finished build scores better.
-- Returns the gain kept (0 if none)
function BuildDoctorClass:Execute(plan)
	local gen = self.gen
	local spec = self.build.spec
	gen:AutoConfigure()
	local before = gen:FullScore()
	local snap = gen:Snapshot()
	local savedForbidden = gen.forbiddenNodes
	local savedBlocked = gen.blockedSupports and copyTable(gen.blockedSupports, true) or nil
	local savedLens2 = gen.scorer.lens2
	local savedLog = #gen.log
	local ok, err = pcall(function()
		gen.forbiddenNodes = { }
		for k, v in pairs(savedForbidden or { }) do gen.forbiddenNodes[k] = v end
		for _, name in ipairs(plan.drop or { }) do
			for _, node in pairs(spec.nodes) do
				if node.dn == name and not node.ascendancyName then
					gen.forbiddenNodes[node.id] = true
					if node.alloc then spec:DeallocNode(node) end
				end
			end
		end
		spec:BuildAllDependsAndPaths()
		if plan.blockSupports and #plan.blockSupports > 0 then
			gen.blockedSupports = gen.blockedSupports or { }
			local block = { }
			for _, name in ipairs(plan.blockSupports) do gen.blockedSupports[name] = true block[name] = true end
			local group = gen.mainGroup
			for i = #group.gemList, 1, -1 do
				local g = group.gemList[i]
				if g.gemData and block[g.gemData.name] then table.remove(group.gemList, i) end
			end
			self.build.skillsTab:ProcessSocketGroup(group)
		end
		if plan.lens then gen.scorer.lens2 = plan.lens end
		gen:Recalculate()
		if plan.utility then gen:ChooseUtilityGems(true) end
		if plan.auras then gen:AuraStackMove() end
		gen:AllocateTree(true)
		gen:RefineTree(plan.refine or 16)
		if not plan.quick then gen:ChooseSupports(5) end
		if plan.rares and gen.options.finalRares ~= false then gen:FinalRares() end
		gen:RefineTree(8)
		gen.scorer.lens2 = savedLens2
		gen:AutoConfigure()
		gen:RefineTree(6)
	end)
	gen.scorer.lens2 = savedLens2
	for j = #gen.log, savedLog + 1, -1 do table.remove(gen.log, j) end
	local after = ok and gen:FullScore() or before
	if gen.options.debugTiming then ConPrintf("[doctor] plan %s: %.3f -> %.3f%s", plan.id, before, after, ok and "" or (" failed: " .. tostring(err))) end
	if ok and after > before + 0.01 then
		gen:Note(string.format("Build doctor: %s (%s): score %+.3f", plan.label, plan.reason, after - before))
		return after - before
	end
	gen:Restore(snap)
	gen.forbiddenNodes = savedForbidden
	gen.blockedSupports = savedBlocked
	gen:Recalculate()
	return 0
end

-- Diagnose, log the report, and try the best plans (each one measured
-- again after any change: the balance moves)
function BuildDoctorClass:Run(maxPlans)
	local gen = self.gen
	local total = 0
	local tried = { }
	for round = 1, maxPlans or 3 do
		self:Diagnose()
		if round == 1 then
			for _, line in ipairs(self:ReportLines(8)) do gen:Note(line) end
		end
		local plan
		for _, p in ipairs(self:Plans()) do
			if not tried[p.id] then plan = p break end
		end
		if not plan then break end
		tried[plan.id] = true
		total = total + self:Execute(plan)
		gen:Tick()
	end
	return total
end
