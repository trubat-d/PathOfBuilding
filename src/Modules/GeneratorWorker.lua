-- Path of Building
--
-- Module: Generator Worker
-- Runs one build generation in its own Lua state: a background thread of the
-- app (LaunchSubScript, see Classes/ParallelGenerator) or a separate process
-- (luajit, for tests and benchmarks). It starts a headless Path of Building,
-- generates the build described by the job and returns it as build XML plus a
-- JSON summary, so several generations use several processor cores.
--
-- Returns function(jobJson, userPath) -> resultJson, buildXml
-- job.kind: nil (a generation), "compare" (a top player's build against
-- ours) or "rares" (rare items for some gear slots of a build)
-- job: { gemId, classId, ascendClassId, level, investmentId, focusId, hitFloor,
--        scenarioId, configScenarioId, archetypeId, quick, synergies,
--        allowAnoints, allowTattoos, timeless, meta, plan (true: also run the
--        scaling planner over every archetype) }
--
return function(jobJson, userPath, scriptBase)
	local startClock = os.clock()
	-- every file by absolute path (scriptBase: the scripts' folder): the
	-- process's working directory can change while the thread runs
	if scriptBase and scriptBase ~= "" then
		local function abs(path)
			if type(path) ~= "string" or path:match("^%a:[/\\]") or path:match("^[/\\]") then return path end
			return scriptBase .. path
		end
		local l_dofile, l_loadfile, l_open, l_lines = dofile, loadfile, io.open, io.lines
		dofile = function(path, ...) return l_dofile(abs(path), ...) end
		loadfile = function(path, ...) return l_loadfile(abs(path), ...) end
		io.open = function(path, ...) return l_open(abs(path), ...) end
		io.lines = function(path, ...) if path == nil then return l_lines() end return l_lines(abs(path), ...) end
		local function absPaths(list)
			local out = { }
			for entry in list:gmatch("[^;]+") do
				if entry:match("^%.[/\\]") or entry:match("^%.%.[/\\]") then entry = scriptBase .. entry end
				out[#out + 1] = entry
			end
			return table.concat(out, ";")
		end
		package.path = absPaths(package.path)
		package.cpath = absPaths(package.cpath)
	end
	-- trace of the worker's start-up and steps (GeneratorWorker_<n>.log next
	-- to the scripts), to find where a background thread fails
	local traceName = jobJson:match('"traceName"%s*:%s*"([^"]+)"')
	local function trace(text)
		if not traceName then return end
		local f = io.open(traceName, "a")
		if f then
			f:write(string.format("%8.2f s  %6.0f MB  %s\n", os.clock() - startClock, collectgarbage("count") / 1024, text))
			f:close()
		end
	end
	trace("thread started (Inflate " .. type(Inflate) .. ", ConPrintf " .. type(ConPrintf) .. ", jit " .. tostring(jit and jit.version) .. ")")

	-- headless Path of Building in this Lua state (the host functions the
	-- thread was given, like Inflate for the timeless jewel tables, are kept:
	-- the definitions file would replace them with empty stand-ins)
	local host = { Inflate = Inflate, Deflate = Deflate, GetScriptPath = GetScriptPath, GetRuntimePath = GetRuntimePath }
	dofile("_SimpleGraphic.def.lua")
	for name, fn in pairs(host) do _G[name] = fn end
	trace("definitions loaded")
	function GetVirtualScreenSize() return 1920, 1080 end
	function GetTime() return os.clock() * 1000 end
	__callbackTable__ = { }
	function runCallback(name, ...)
		if __callbackTable__[name] then
			return __callbackTable__[name](...)
		elseif __mainObject__ and __mainObject__[name] then
			return __mainObject__[name](__mainObject__, ...)
		end
	end
	local l_require = require
	function require(name)
		if name == "lcurl.safe" then return end
		return l_require(name)
	end
	dofile("Launch.lua")
	trace("Launch.lua loaded")
	runCallback("OnInit")
	trace("OnInit done")
	runCallback("OnFrame")
	trace("first frame done")
	if __mainObject__.promptMsg then
		error("Path of Building failed to start in the worker: " .. tostring(__mainObject__.promptMsg))
	end
	local main = __mainObject__.main
	if userPath and userPath ~= "" then
		-- the app's price and statistics caches
		main.userPath = userPath
		main.priceSource = nil
	end
	local dkjson = require "dkjson"
	local job = dkjson.decode(jobJson)
	local initClock = os.clock() - startClock
	-- (rare items need neither database: no wait for them)
	if job.kind ~= "rares" then
		while main.uniqueDB.loading or main.rareDB.loading do runCallback("OnFrame") end
	end
	local dbClock = os.clock() - startClock
	trace("databases ready, job kind " .. tostring(job.kind))
	main:SetMode("BUILD", false, "Generated build")
	runCallback("OnFrame")
	local build = main.modes["BUILD"]

	local function load(xml, name)
		main:SetMode("BUILD", false, name, xml)
		runCallback("OnFrame")
		return main.modes["BUILD"]
	end
	local function byId(list, id, key)
		for _, entry in ipairs(list or { }) do
			local value = key and entry[key] or entry
			if value and value.id == id then return value end
		end
	end

	-- rare items for some of a build's gear slots (a generation in the app
	-- hands each worker a share of the slots: Classes/BuildGenerator
	-- RunRaresParallel). The scorer is set up exactly as the generator's.
	if job.kind == "rares" then
		local b = load(job.build, "rares")
		local statics = new("BuildScorer"):BuildScorer(b)
		local sc = job.scorer or { }
		local overlap
		if sc.scenarioId then
			overlap = new("HitOverlap"):HitOverlap(b, byId(new("HitOverlap"):HitOverlap(b).scenarioList, sc.scenarioId))
		end
		local scorer = new("BuildScorer"):BuildScorer(b, {
			focus = sc.focusCustom or byId(statics.focusList, sc.focusId) or statics.focusList[1], chargesPerSecond = sc.chargesPerSecond, overlap = overlap,
			ehpFloor = sc.ehpFloor, hitFloor = sc.hitFloor, bossTier = sc.bossTier, killsPerSecond = sc.killsPerSecond, flaskRealism = sc.flaskRealism,
		})
		for _, key in ipairs({ "hitScale", "resourceSustain", "ignoreCosts", "ignoreAttributes", "ignoreReservation", "useChecklist",
			"lens", "lens2", "avoidanceWeight", "pastTarget", "fightWeight", "smoothBuffs", "reservationSlope", "clearBoost", "clearBuffs", "fightSim", "softSustain", "secondaryTrim", "stationaryBlend" }) do
			scorer[key] = sc[key]
		end
		if sc.focusEhp and scorer.focus and scorer.focus.ehp ~= sc.focusEhp then
			scorer.focus = copyTable(scorer.focus, true)
			scorer.focus.ehp = sc.focusEhp
		end
		local finder = new("BestItemFinder"):BestItemFinder(b.itemsTab)
		local options = job.options or { }
		local ratio = job.ratio
		options.scoreFunc = function(output) return scorer:ScoreOutput(output, ratio) end
		options.slots = job.slots
		local report = finder:RunRares(options)
		local out = { }
		for _, slotName in ipairs(job.slots or { }) do
			local r = report.slots[slotName]
			local result = r and r.results and r.results[1]
			if result and result.item and result.item.raw then
				out[slotName] = { raw = result.item.raw, power = result.power, delta = result.delta }
			end
		end
		return dkjson.encode({ slots = out, seconds = os.clock() - startClock, startup = initClock, databases = dbClock }), ""
	end

	-- comparison with a top player's build (Modules/BuildComparison):
	-- their build scored and taken apart, then each part of it tried in ours
	if job.kind == "compare" then
		local BC = LoadModule("Modules/BuildComparison")
		local function top(rows, n, positive)
			local list = { }
			for _, r in ipairs(rows) do
				if #list >= n then break end
				if (positive and r.dScore > 0.01) or (not positive and r.dScore < -0.01) then table.insert(list, r) end
			end
			return list
		end
		local theirsBuild = load(BC.DecodeCode(job.code), "theirs")
		if BC.SelectMainSkill(theirsBuild, job.skill) then
			theirsBuild.buildFlag = true
			runCallback("OnFrame")
		end
		local ctx = BC.Setup(theirsBuild, job.focusId, job.tier)
		local theirs = BC.Evaluate(ctx)
		local ablation = top(BC.Ablate(ctx), job.rows or 8, false)
		local parts = BC.ReadParts(theirsBuild)
		local oursBuild = load(job.ours, "ours")
		local ctx2 = BC.Setup(oursBuild, job.focusId, job.tier)
		local ours = BC.Evaluate(ctx2)
		local transplant = top(BC.Transplant(ctx2, parts), job.rows or 8, true)
		return dkjson.encode({ player = job.player, theirs = theirs, ablation = ablation, ours = ours, transplant = transplant,
			seconds = os.clock() - startClock }), ""
	end
	local scorerStatics = new("BuildScorer"):BuildScorer(build)
	local options = {
		gemId = job.gemId, classId = job.classId, ascendClassId = job.ascendClassId, level = job.level,
		focus = job.focusCustom or byId(scorerStatics.focusList, job.focusId) or scorerStatics.focusList[1],
		investment = byId(new("PriceSource"):PriceSource().levels, job.investmentId),
		hitFloor = job.hitFloor,
		scenario = byId(new("HitOverlap"):HitOverlap(build).scenarioList, job.scenarioId),
		configScenario = byId(new("AutoConfig"):AutoConfig(build).scenarioList, job.configScenarioId),
		allowAnoints = job.allowAnoints, allowTattoos = job.allowTattoos, timeless = job.timeless,
		synergies = job.synergies, quick = job.quick, meta = job.meta, learnFromPlayers = job.learnFromPlayers, variant = job.variant,
		excludedUniques = job.excludedUniques, forcedUniques = job.forcedUniques, totalBudget = job.totalBudget,
		midTier = job.midTier, midTierMaxUnique = job.midTierMaxUnique,
		-- (knowledge read here, written by the main thread from the result)
		knowledge = job.knowledge, knowledgeWrite = false, learntNote = job.learntNote, leaguePhase = job.leaguePhase,
		yieldEvery = 1e9,
	}
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	local archetypeList = archetypes.ForSkill(data.gems[job.gemId], job.meta)
	if job.archetypeId then
		options.archetype = byId(archetypeList, job.archetypeId) or archetypes.ById(data.gems[job.gemId], job.archetypeId, job.meta)
	end
	local lastStage
	options.yieldEvery = 1000
	options.onProgress = function(stage)
		if stage ~= lastStage then lastStage = stage trace("step: " .. tostring(stage)) end
	end
	local generator = new("BuildGenerator"):BuildGenerator(build, options)
	trace("generating")
	local co = coroutine.create(function() return generator:Run() end)
	local ok, result = coroutine.resume(co)
	while ok and coroutine.status(co) ~= "dead" do ok, result = coroutine.resume(co) end
	if not ok then error(tostring(result)) end
	runCallback("OnFrame")

	local summary = {
		archetypeId = job.archetypeId,
		score = result.final.score, dps = result.final.dps, ehp = result.final.ehp,
		minHit = (generator.scorer:MinMaxHit(build.calcsTab.mainOutput)),
		log = result.log, costLine = result.costLine, configChanges = result.configChanges,
		assumptions = result.assumptions,
		knowledge = result.knowledge,
		-- (the build as data: the main thread crosses the best builds)
		state = (function() local ok, st = pcall(function() return generator:SerializeState() end) return ok and st or nil end)(),
		penalties = { },
		keystones = { },
		seconds = os.clock() - startClock,
	}
	for _, p in ipairs(result.final.penalties or { }) do table.insert(summary.penalties, { label = p.label, value = p.value }) end
	for _, node in pairs(build.spec.allocNodes) do
		if node.type == "Keystone" then table.insert(summary.keystones, node.dn) end
	end
	table.sort(summary.keystones)
	if job.plan then
		local plan = new("ScalingPlanner"):ScalingPlanner(generator):Run(archetypeList, { units = 20 })
		summary.plan = { }
		for _, p in ipairs(plan or { }) do
			table.insert(summary.plan, { archetypeId = p.archetype.id, error = p.error and tostring(p.error), score = p.score, dps = p.dps, minHit = p.minHit,
				commitments = p.commitments, plan = p.plan })
		end
	end
	local xml = build:SaveDB("code")
	trace("done, returning " .. #xml .. " bytes")
	return dkjson.encode(summary), xml
end
