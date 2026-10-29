-- Test: runs one generator step on a saved generated build and prints what
-- it did, so a step can be checked without a whole generation.
-- From the src folder: OURS=<build .xml> STEP=<skillprofile|flasks|flaskenchant|clusters|popular|learn|uniquejewels|aurastack|metajewels|uniquesweep|uniqueflasks|fillmain|finalrares|ascendancy|supports|refine|swap|rares> INVEST=ENDGAME luajit ../bench/stage_test.lua
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
local f = assert(io.open(os.getenv("OURS")))
loadBuildFromXML(f:read("*a"), "ours")
f:close()
runCallback("OnFrame")
local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == (os.getenv("INVEST") or "ENDGAME") then investment = level end end
local focus
for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end end
local gen = new("BuildGenerator"):BuildGenerator(build, { investment = investment, focus = focus, debugTiming = true, yieldEvery = 1e9 })
gen.scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = investment.awakenedGems and "uber" or "pinnacle" })
gen.scorer.useChecklist = true
gen.scorer.reservationSlope = tonumber(os.getenv("RES_SLOPE") or "")
gen.costs = { }
-- PLAYER_KNOWLEDGE=0: nothing from top players (the generator's playerKnowledge option)
if os.getenv("PLAYER_KNOWLEDGE") == "0" then gen.options.playerKnowledge = false new("BuildArchetypes"):BuildArchetypes().SetPlayerKnowledge(false) end
for _, g in ipairs(build.skillsTab.socketGroupList) do
	if g == build.skillsTab.socketGroupList[build.mainSocketGroup] then gen.mainGroup = g end
end
gen.mainGem = gen.mainGroup and gen.mainGroup.gemList[1] and data.gems[gen.mainGroup.gemList[1].gemId]
-- (skillprofile: the build as saved first, then with the main skill's profile)
if os.getenv("STEP") == "skillprofile" then gen.options.skillProfiles = false end
gen:AutoConfigure()
local before, r0 = gen:FullScore()
print(string.format("BEFORE score %.3f dps %.0f", before, r0.dps))
local step = os.getenv("STEP") or "flasks"
local t0 = os.clock()
if step == "flasks" then
	local fg = new("FlaskGenerator"):FlaskGenerator(new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator, gen.scorer)
	local bases = fg:GetBases(true)
	print("BASES " .. table.concat(bases, ", "))
	gen:MakeFlasks()
elseif step == "uniquejewels" then
	local finder = new("MetaJewelFinder"):MetaJewelFinder({ build = build, fullScore = function() return (gen:FullScore()) end,
		equip = function(item, slotName) return gen:Equip(item, slotName) end })
	local result = finder:BestUniqueJewel(before, function() return true end, function(o) return (gen:Score(o)) end)
	print("RESULT", result and result.label, result and result.gain)
elseif step == "aurastack" then
	gen:AuraStackMove()
elseif step == "uniquesweep" then
	print("KEPT", gen:UniqueSweep())
elseif step == "mageblood" then
	print("KEPT", gen:PermanentFlaskMove())
elseif step == "uniqueflasks" then
	print("KEPT", gen:UniqueFlaskSweep())
elseif step == "learn" then
	-- META_DETAILS=<json with topBuilds = { { name, code } }>
	local mf = assert(io.open(os.getenv("META_DETAILS")))
	gen.options.meta = { details = require("dkjson").decode(mf:read("*a")) }
	mf:close()
	print("KEPT", gen:LearnFromTopBuilds())
elseif step == "popular" then
	-- META_DETAILS=<json details> or META_CODES="<files with PoB codes>" (aggregated like poe.ninja players)
	if os.getenv("META_CODES") then
		local chars = { }
		for path in os.getenv("META_CODES"):gmatch("%S+") do
			local cf = assert(io.open(path))
			table.insert(chars, { pathOfBuildingExport = cf:read("*a") })
			cf:close()
		end
		gen.options.meta = { details = new("BuildMetaSource"):BuildMetaSource().AggregateCharacters(gen.mainGem.name, chars) }
	else
		local mf = assert(io.open(os.getenv("META_DETAILS")))
		gen.options.meta = { details = require("dkjson").decode(mf:read("*a")) }
		mf:close()
	end
	gen.options.popularMinBuilds = tonumber(os.getenv("MIN_BUILDS") or "")
	print("GAIN", gen:PopularPassivesMove())
elseif step == "watcher" then
	-- the build's Watcher's Eye taken out, then searched again
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and item.title == "Watcher's Eye" then
			print("REMOVED", table.concat((function() local t = { } for _, l in ipairs(item.explicitModLines) do t[#t + 1] = l.line end return t end)(), " | "))
			slot:SetSelItemId(0)
		end
	end
	build.itemsTab:PopulateSlots()
	local base = gen:FullScore()
	print(string.format("WITHOUT %.3f", base))
	local finder = new("MetaJewelFinder"):MetaJewelFinder({ build = build, fullScore = function() return (gen:FullScore()) end,
		quickScore = function() gen:Recalculate() return (gen:Score()) end,
		equip = function(item, slotName) return gen:Equip(item, slotName) end })
	local result = finder:WatchersEye(base, 3)
	print("RESULT", result and result.label, result and result.gain)
	if result then finder:Apply(result) end
elseif step == "metajewels" then
	gen:ChooseMetaJewels()
elseif step == "fillmain" or step == "finalrares" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	if step == "fillmain" then gen:FillMainLinkMove() else gen:FinalRares() end
elseif step == "refine" then
	-- (one allocation first, as the generator's tree has been allocated before refining)
	gen:AllocateTree(true)
	for _, n in ipairs({ 6, 10, 16, 6 }) do print("REFINE", n, gen:RefineTree(n)) end
elseif step == "tree" or step == "treeplain" then
	-- (tree: the tree optimizer with the whole-tree solver; treeplain: without)
	local opt = new("TreeOptimizer"):TreeOptimizer(gen)
	local gain, swaps = opt:Run({ global = step == "tree" })
	print("TREE", gain, swaps, "solver won:", tostring(opt.globalWon), "points", opt.globalPoints, opt.globalCount)
elseif step == "profile" then
	local prof = new("BuildDoctor"):BuildDoctor(gen):Profile()
	print("PROFILE " .. require("dkjson").encode(prof))
elseif step == "combos" then
	-- the combinations of commitments the doctor predicts best (ARCHETYPES="CRIT,POWER,...")
	local doctor = new("BuildDoctor"):BuildDoctor(gen)
	doctor:Diagnose()
	local archetypes = new("BuildArchetypes"):BuildArchetypes().ForSkill(gen.mainGem, nil)
	for i, c in ipairs(doctor:PredictCombos(archetypes, 3)) do
		if i > 8 then break end
		print(string.format("COMBO %s x%.2f (%s)", c.ids, c.predicted, c.why))
	end
elseif step == "joint" then
	-- JOINT="crit,power,resistance,ci": those commitments together, built for real
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	local doctor = new("BuildDoctor"):BuildDoctor(gen)
	doctor:Diagnose()
	local all = doctor:CommitmentPlans()
	local parts = { }
	for id in (os.getenv("JOINT") or "crit"):gmatch("[^,]+") do if all[id] then table.insert(parts, all[id]) end end
	local plan = doctor.Joint(parts)
	print("JOINT", plan.label)
	print("GAIN", doctor:Execute(plan))
	local prof = doctor:Profile()
	print(string.format("PROFILE crit %.2f enemy %.2f speed %.2f increased %.1f more %.2f power %s life %d es %d", prof.crit or 0, prof.enemy or 0, prof.speed or 0, prof.increased or 0, prof.more or 0, tostring(prof.power), prof.life or 0, prof.es or 0))
elseif step == "doctor" or step == "diagnose" then
	-- (diagnose: the layer report only; doctor: the plans tried too)
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	local doctor = new("BuildDoctor"):BuildDoctor(gen)
	doctor:Diagnose()
	for _, l in ipairs(doctor:ReportLines(20)) do print(l) end
	for _, p in ipairs(doctor:Plans()) do print("PLAN", p.id, p.label, p.reason) end
	if step == "doctor" then print("GAIN", doctor:Run(tonumber(os.getenv("PLANS") or "3"))) end
elseif step == "alns" or step == "alnsbase" or step == "ascstarts" then
	-- (the bench's setup: budget, league phase, mid tier, the scorer as SetupScorer makes it)
	gen.options.totalBudget = tonumber(os.getenv("BUDGET") or "")
	gen.options.leaguePhase = os.getenv("PHASE")
	gen.options.midTier = true
	gen.options.investment = nil
	for pair in (os.getenv("GEN_OPTS") or ""):gmatch("[^,]+") do
		local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
		if k then if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end gen.options[k] = v end
	end
	gen:PrepareOptions()
	gen:SetupScorer()
	gen.scorer.useChecklist = true
	if gen:HasEngine("lagrange") then gen.priceWeight = gen.options.priceWeight or 0.3 end
	gen:AutoConfigure()
	print("START", (gen:FullScore()), (gen:BuildCost()))
	if step == "ascstarts" then print("GAIN", gen:AscendancyStartsMove(tonumber(os.getenv("FULL") or "3")))
	elseif step == "alns" then print("GAIN", gen:AlnsSearch(tonumber(os.getenv("ROUNDS") or "10")))
	else print("GAIN", gen:RepairSearch(tonumber(os.getenv("ROUNDS") or "8"))) end
	local _, r = gen:FullScore()
	print("END", r.score, r.dps, r.ehp, (gen:BuildCost()))
	for _, l in ipairs(gen.log) do print("LOG", l) end
elseif step == "repair" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	print("GAIN", gen:RepairSearch(tonumber(os.getenv("ROUNDS") or "6")))
elseif step == "snapdebug" then
	local snap = gen:Snapshot()
	gen:AutoConfigure()
	print("AFTERSNAP", (gen:FullScore()), build.spec:CountAllocNodes(), gen:PointBudget(), build.calcsTab.mainOutput.ExtraPoints)
	gen:AllocateTree(true)
	print("AFTERALLOC", (gen:FullScore()))
	gen:Restore(snap)
	print("AFTERRESTORE", (gen:FullScore()))
	local branches = gen:TreeBranches()
	print("BRANCHES", #branches)
	for i = 1, math.min(5, #branches) do print("BR", #branches[i].nodes, branches[i].perPoint, branches[i].nodes[1].dn) end
elseif step == "guardian" then
	print("GAIN", new("AnimateGuardianSetup"):AnimateGuardianSetup(gen):Run())
elseif step == "skillprofile" then
	gen.options.skillProfiles = nil
	local first = gen.mainGroup.gemList[1]
	print("PART BEFORE", first.skillPart, gen.mainGem.grantedEffect.parts and gen.mainGem.grantedEffect.parts[first.skillPart or 1] and gen.mainGem.grantedEffect.parts[first.skillPart or 1].name)
	local _, r = gen:FullScore()
	print("PART AFTER", first.skillPart, gen.mainGem.grantedEffect.parts and gen.mainGem.grantedEffect.parts[first.skillPart or 1] and gen.mainGem.grantedEffect.parts[first.skillPart or 1].name, "hitScale", tostring(gen.scorer.hitScale))
	print("NOTE", tostring(gen.skillProfileNote))
elseif step == "combos" then
	gen:UniqueCombosMove(1)
elseif step == "cross" then
	gen:CrossIdeasMove(1)
elseif step == "explain" then
	gen:FullScore()
	gen:Explain()
elseif step == "anoint" then
	gen:ChooseAnoint()
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "script" then
	_G.gen = gen
	dofile(os.getenv("SCRIPT"))
elseif step == "pearl" then
	print("GAIN", gen:PearlMove())
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "fillsockets" then
	-- (FREE=n: n allocated sockets emptied first)
	local n = tonumber(os.getenv("FREE") or "1")
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		if n > 0 and slot.nodeId and build.spec.allocNodes[slot.nodeId] and slot.selItemId ~= 0 then
			local item = build.itemsTab.items[slot.selItemId]
			if item and item.rarity == "RARE" then print("EMPTIED", slot.slotName) slot:SetSelItemId(0) n = n - 1 end
		end
	end
	gen:Recalculate()
	print("BEFORE-FILL", gen:FullScore())
	print("DONE", gen:FillEmptySockets())
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "conditions" then
	local audit = new("ConditionAudit"):ConditionAudit(gen)
	for _, g in ipairs(audit:Gains(0.01)) do
		local u = audit:UniqueSources(g.condition, g.enemy)
		local names = { }
		for i = 1, math.min(6, #u) do names[i] = u[i].title end
		local p = audit:PassiveSources(g.condition, g.enemy, 8)
		print(string.format("GAIN %+.3f %-45s uniques %d (%s) passives %d", g.gain, g.label, #u, table.concat(names, ", "), #p))
	end
	print("KEPT", gen:ConditionEnablerMove(2))
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "corrupt" then
	print("GAIN", gen:CorruptionMove())
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "ostentation" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	gen.options.ostentationRefine = tonumber(os.getenv("OST_REFINE") or "")
	gen.options.ostentationSolver = os.getenv("OST_SOLVER") == "1"
	print("GAIN", gen:SupremeOstentationMove())
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "cost" or step == "upgrade" or step == "fitbudget" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	local total, entries = gen:BuildCost()
	for _, e in ipairs(entries) do print(string.format("PART %-8s %-14s %-40s %8.2f%s", e.kind, tostring(e.slot), e.label, e.price, e.known and "" or " (no price)")) end
	print("TOTAL", total)
	if step == "upgrade" then gen:UpgradeOrder() end
	if step == "fitbudget" then gen.options.totalBudget = tonumber(os.getenv("BUDGET") or "30") gen:FitTotalBudget() local t2, e2 = gen:BuildCost() for _, e in ipairs(e2) do print(string.format("PART2 %-8s %-14s %-40s %8.2f", e.kind, tostring(e.slot), e.label, e.price)) end print("TOTAL AFTER", t2) end
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "bossskill" then
	-- CONFIG=MAPPING or BOSS_CLEAR (the build's scenario)
	for _, sc in ipairs(new("AutoConfig"):AutoConfig(build).scenarioList) do if sc.id == (os.getenv("CONFIG") or "MAPPING") then gen.options.configScenario = sc end end
	gen:AutoConfigure()
	print("GAIN", gen:BossSkillMove())
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "fullscorecost" then
	-- how long one full score and one quick score take on this build
	local t = os.clock()
	for _ = 1, 10 do gen:FullScore() end
	local full = (os.clock() - t) / 10
	t = os.clock()
	for _ = 1, 10 do gen:Score() end
	local quick = (os.clock() - t) / 10
	t = os.clock()
	for _ = 1, 10 do gen:Recalculate() end
	print(string.format("FULLSCORE %.3f s  SCORE %.3f s  RECALC %.3f s", full, quick, (os.clock() - t) / 10))
elseif step == "population" then
	-- SIZE=, GENS=; compared with the repair search from the same start (REPAIR=1)
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	if os.getenv("REPAIR") == "1" then print("GAIN", gen:RepairSearch(tonumber(os.getenv("ROUNDS") or "8")))
	else print("GAIN", gen:PopulationSearch(tonumber(os.getenv("SIZE") or "3"), tonumber(os.getenv("GENS") or "3"))) end
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "prune" then
	print("REMOVED", gen:PruneUselessGems())
	for _, l in ipairs(gen.log) do print("NOTE " .. l) end
elseif step == "requirements" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	print("GAIN", gen:RequirementsMove())
elseif step == "flaskenchant" then
	gen:FlaskEnchantMove()
elseif step == "fitsockets" then
	-- UNIQUE=<name> SLOT=<slot>: equipped, then the gem setups fitted to its sockets
	local item
	for _, u in pairs(main.uniqueDB.list) do if u.title == os.getenv("UNIQUE") then item = u end end
	new("BestItemFinder"):BestItemFinder(build.itemsTab):Equip(item, os.getenv("SLOT"), true)
	build.itemsTab:PopulateSlots()
	print("SOCKETS", new("GemSetup"):GemSetup(gen).ItemGemSockets(item), "CHANGED", gen:FitSockets())
	for _, g in ipairs(build.skillsTab.socketGroupList) do
		local names = { }
		for _, gem in ipairs(g.gemList) do table.insert(names, gem.gemData and gem.gemData.name or "?") end
		print("GROUP", g.slot, g.label, table.concat(names, ", "))
	end
elseif step == "radiusjewels" then
	gen:ChooseRadiusJewels()
elseif step == "clusters" then
	gen:ChooseClusterJewels(tonumber(os.getenv("LARGE") or "0"))
elseif step == "swap" then
	print("KEPT", gen:SwapForNotables(10))
elseif step == "supports" then
	gen:FinalSupports()
elseif step == "ascendancy" then
	gen.options.classId = build.spec.curClassId
	gen.options.ascendClassId = build.spec.curAscendClassId
	gen:AscendancyRecheck()
elseif step == "rares" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	gen.options.weaponSeeds = tonumber(os.getenv("WEAPON_SEEDS") or "")
	gen.options.crafts = os.getenv("CRAFTS") ~= "0"
	gen:MakeRares(true)
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and item.rarity == "RARE" then
			for _, l in ipairs(item.explicitModLines) do if l.crafted then print("CRAFT", slot.slotName, l.line) end end
			print("RARE", slot.slotName, #item.explicitModLines .. " explicit lines")
		end
	end
end
local after, r1 = gen:FullScore()
print(string.format("AFTER score %.3f dps %.0f (%.0f s)", after, r1.dps, os.clock() - t0))
for _, l in ipairs(gen.log) do print("LOG " .. l) end
