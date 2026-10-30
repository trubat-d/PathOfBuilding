-- Evaluates saved builds with Path of Building's calculator and the generator's
-- scorer: damage, pools, max hits, block, resistances, recovery, cost (week-1
-- prices by default) and what the scorer penalises. One JSON line per build
-- ("EVAL {...}"), first with the build's own configuration, then with the
-- generator's automatic configuration (what PoB believes when the "recently"
-- states, charges and debuffs are set from the build itself).
-- Run from the src folder (buildlab/tools/eval.sh does this):
--   FILES="a.xml b.xml" BUDGET=30 PHASE=WEEK1 luajit ../buildlab/tools/eval.lua
dofile("HeadlessWrapper.lua")
local dk = require("dkjson")
while main.uniqueDB.loading do runCallback("OnFrame") end
local budget = tonumber(os.getenv("BUDGET") or "30")
local phase = os.getenv("PHASE") or "WEEK1"
for path in (os.getenv("FILES") or ""):gmatch("%S+") do
	local f = assert(io.open(path))
	loadBuildFromXML(f:read("*a"), "eval")
	f:close()
	runCallback("OnFrame")
	local gen = new("BuildGenerator"):BuildGenerator(build, { totalBudget = budget, leaguePhase = phase, midTier = true, yieldEvery = 1e9, engine = "none" })
	for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == "ENDGAME" then gen.options.investment = level end end
	gen:PrepareOptions()
	gen:SetupScorer()
	gen.scorer.useChecklist = true
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if group then gen.mainGroup = group end
	gen:Recalculate()
	local function report(label)
		local r = gen.scorer:Evaluate(gen.calcFunc, { })
		local o = build.calcsTab.mainOutput
		local total, entries = gen:BuildCost()
		table.sort(entries, function(a, b) return a.price > b.price end)
		local parts = { }
		for i, e in ipairs(entries) do if i <= 10 then table.insert(parts, string.format("%s %.1f", e.label, e.price)) end end
		local penalties = { }
		for _, p in ipairs(r.penalties or { }) do table.insert(penalties, string.format("%.2f %s", p.value or 0, p.label)) end
		local keystones = { }
		for _, node in pairs(build.spec.allocNodes) do
			if node.type == "Keystone" or (node.ascendancyName and node.type == "Notable") then table.insert(keystones, node.dn) end
		end
		table.sort(keystones)
		local mainGems = { }
		for _, g in ipairs(group and group.gemList or { }) do if g.gemData then table.insert(mainGems, g.gemData.name) end end
		print("EVAL " .. dk.encode({
			file = path:match("[^/\\]+$"), config = label, level = build.characterLevel, tree = build.spec.treeVersion,
			score = r.score, dps = r.dps, combinedDPS = o.CombinedDPS, fullDPS = o.FullDPS,
			life = o.Life, es = o.EnergyShield, mana = o.Mana, ehp = o.TotalEHP,
			minHit = (gen.scorer:MinMaxHit(o)),
			maxHit = { phys = o.PhysicalMaximumHitTaken, fire = o.FireMaximumHitTaken, cold = o.ColdMaximumHitTaken, light = o.LightningMaximumHitTaken, chaos = o.ChaosMaximumHitTaken },
			block = o.BlockChance, spellBlock = o.SpellBlockChance, suppression = o.EffectiveSpellSuppressionChance,
			res = { fire = o.FireResist, cold = o.ColdResist, light = o.LightningResist, chaos = o.ChaosResist },
			lifeRegen = o.LifeRegenRecovery, netLifeRegen = o.NetLifeRegen, degen = o.TotalBuildDegen,
			sustain = gen.scorer:SkillSustain(o),
			cost = total, costParts = parts, penalties = penalties, keystones = keystones, mainSkill = mainGems,
		}))
	end
	report("own")
	gen:AutoConfigure()
	gen:Recalculate()
	report("auto")
end
