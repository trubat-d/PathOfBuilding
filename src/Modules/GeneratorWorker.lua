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
-- job: { gemId, classId, ascendClassId, level, investmentId, focusId, hitFloor,
--        scenarioId, configScenarioId, archetypeId, quick, synergies,
--        allowAnoints, allowTattoos, timeless, meta, plan (true: also run the
--        scaling planner over every archetype) }
--
return function(jobJson, userPath)
	local startClock = os.clock()

	-- headless Path of Building in this Lua state (the host functions the
	-- thread was given, like Inflate for the timeless jewel tables, are kept:
	-- the definitions file would replace them with empty stand-ins)
	local host = { Inflate = Inflate, Deflate = Deflate, GetScriptPath = GetScriptPath, GetRuntimePath = GetRuntimePath }
	dofile("_SimpleGraphic.def.lua")
	for name, fn in pairs(host) do _G[name] = fn end
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
	runCallback("OnInit")
	runCallback("OnFrame")
	if __mainObject__.promptMsg then
		error("Path of Building failed to start in the worker: " .. tostring(__mainObject__.promptMsg))
	end
	local main = __mainObject__.main
	if userPath and userPath ~= "" then
		-- the app's price and statistics caches
		main.userPath = userPath
		main.priceSource = nil
	end
	while main.uniqueDB.loading or main.rareDB.loading do runCallback("OnFrame") end
	main:SetMode("BUILD", false, "Generated build")
	runCallback("OnFrame")
	local build = main.modes["BUILD"]

	local dkjson = require "dkjson"
	local job = dkjson.decode(jobJson)
	local function byId(list, id, key)
		for _, entry in ipairs(list or { }) do
			local value = key and entry[key] or entry
			if value and value.id == id then return value end
		end
	end
	local scorerStatics = new("BuildScorer"):BuildScorer(build)
	local options = {
		gemId = job.gemId, classId = job.classId, ascendClassId = job.ascendClassId, level = job.level,
		focus = byId(scorerStatics.focusList, job.focusId) or scorerStatics.focusList[1],
		investment = byId(new("PriceSource"):PriceSource().levels, job.investmentId),
		hitFloor = job.hitFloor,
		scenario = byId(new("HitOverlap"):HitOverlap(build).scenarioList, job.scenarioId),
		configScenario = byId(new("AutoConfig"):AutoConfig(build).scenarioList, job.configScenarioId),
		allowAnoints = job.allowAnoints, allowTattoos = job.allowTattoos, timeless = job.timeless,
		synergies = job.synergies, quick = job.quick, meta = job.meta,
		yieldEvery = 1e9,
	}
	local archetypes = new("BuildArchetypes"):BuildArchetypes()
	local archetypeList = archetypes.ForSkill(data.gems[job.gemId], job.meta)
	if job.archetypeId then
		options.archetype = byId(archetypeList, job.archetypeId)
	end
	local generator = new("BuildGenerator"):BuildGenerator(build, options)
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
	return dkjson.encode(summary), build:SaveDB("code")
end
