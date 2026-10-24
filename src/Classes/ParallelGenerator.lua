-- Path of Building
--
-- Class: Parallel Generator
-- Runs several build generations at once, each in its own background thread
-- with its own headless Path of Building (Modules/GeneratorWorker), so they
-- use several processor cores. Used by the archetype scan (several quick builds)
-- and the final step of the automatic mode (the best archetypes fully built,
-- the best one kept). Each worker needs its own copy of the game data (a few
-- hundred MB), so the number running together is limited.
-- When background threads aren't available (headless runs), Available() is
-- false and callers run the jobs one after the other as before.
--
local t_insert = table.insert
local t_remove = table.remove
local m_max = math.max
local m_min = math.min

---@class ParallelGenerator
local ParallelGeneratorClass = newClass("ParallelGenerator")

local workerScript = [[
local jobJson, userPath = ...
local run = dofile("Modules/GeneratorWorker.lua")
return run(jobJson, userPath)
]]

function ParallelGeneratorClass:ParallelGenerator()
	self.running = { }
	self.queue = { }
	return self
end

-- Processor cores (Windows sets NUMBER_OF_PROCESSORS; 4 otherwise)
function ParallelGeneratorClass.CoreCount()
	return tonumber(os.getenv("NUMBER_OF_PROCESSORS") or "") or 4
end

-- How many workers to run together: one core is left for the app itself,
-- and at most 3 (each one holds its own game data in memory, about 1 GB)
function ParallelGeneratorClass.MaxWorkers()
	local setting = main and tonumber(main.generatorWorkers or "")
	if setting and setting >= 1 then return m_min(8, setting) end
	-- each worker holds its own copy of the game data (about 1 GB): 3 on
	-- machines with 6+ cores, 2 below
	local cores = ParallelGeneratorClass.CoreCount()
	return m_max(1, m_min(cores >= 6 and 3 or 2, cores - 1))
end

-- Turns parallel generation off for the session (after workers failed)
function ParallelGeneratorClass.Disable()
	ParallelGeneratorClass.disabled = true
end

-- Can several copies of the game data live in this process? Background
-- threads share the process's memory, and a LuaJIT built without GC64 keeps
-- every Lua state's objects in the same low 2 GB: the app's own data plus a
-- worker's copy doesn't fit, and the app crashes (access violation) instead
-- of reporting "not enough memory". Worker processes (bench/fake_threads.lua)
-- have their own memory.
function ParallelGeneratorClass.MemoryAllowsWorkers()
	if ParallelGeneratorClass.processWorkers then return true end
	local ok, ffi = pcall(require, "ffi")
	if not ok or not ffi or not ffi.abi then return false end
	local okAbi, gc64 = pcall(ffi.abi, "gc64")
	return okAbi and gc64 == true
end

-- Background threads available? (not in headless runs, not without GC64)
function ParallelGeneratorClass.Available()
	if ParallelGeneratorClass.disabled then return false end
	if not ParallelGeneratorClass.MemoryAllowsWorkers() then return false end
	-- (opt-in: a generation with background threads crashed the app on a
	-- player's PC; the Generate window's "Several cores" box turns them on)
	if not ParallelGeneratorClass.processWorkers and not (main and main.generatorThreads) then return false end
	if not (LaunchSubScript and launch and launch.RegisterSubScript and launch.subScripts) then return false end
	if ParallelGeneratorClass.availableChecked == nil then
		local ok, id = pcall(LaunchSubScript, "return true", "", "")
		ParallelGeneratorClass.availableChecked = ok and id ~= nil or false
		if ok and id then launch:RegisterSubScript(id, function() end) end
	end
	return ParallelGeneratorClass.availableChecked and ParallelGeneratorClass.MaxWorkers() > 1
end

-- The job description a worker needs, from the generator options
-- (tables are passed by id; the worker looks them up again)
function ParallelGeneratorClass.JobFromOptions(options, extra)
	local job = {
		gemId = options.gemId, classId = options.classId, ascendClassId = options.ascendClassId, level = options.level,
		focusId = options.focus and options.focus.id, investmentId = options.investment and options.investment.id,
		hitFloor = options.hitFloor,
		scenarioId = options.scenario and options.scenario.id,
		configScenarioId = options.configScenario and options.configScenario.id,
		archetypeId = options.archetype and options.archetype.id,
		allowAnoints = options.allowAnoints, allowTattoos = options.allowTattoos, timeless = options.timeless,
		synergies = options.synergies, quick = options.quick, meta = options.meta,
	}
	for k, v in pairs(extra or { }) do job[k] = v end
	return job
end

-- Runs the jobs, at most MaxWorkers() at a time.
-- callbacks: onDone(index, summary, xml), onError(index, errMsg), onAllDone(),
--   onStart(index) (optional)
function ParallelGeneratorClass:Run(jobs, callbacks)
	local dkjson = require "dkjson"
	self.callbacks = callbacks
	self.remaining = #jobs
	self.stopped = false
	ParallelGeneratorClass.traceCount = ParallelGeneratorClass.traceCount or 0
	for index, job in ipairs(jobs) do
		-- (each worker writes its trace to its own file next to the scripts)
		ParallelGeneratorClass.traceCount = ParallelGeneratorClass.traceCount % 8 + 1
		job.traceName = job.traceName or string.format("GeneratorWorker_%d.log", ParallelGeneratorClass.traceCount)
		local f = io.open(job.traceName, "w")
		if f then f:write(string.format("job %d (%s), launched at %s\n", index, tostring(job.kind or (job.quick and "quick build" or "full build")), os.date("%H:%M:%S"))) f:close() end
		local ok, text = pcall(dkjson.encode, job)
		if ok then
			t_insert(self.queue, { index = index, json = text })
		else
			self.remaining = self.remaining - 1
			if callbacks.onError then callbacks.onError(index, "job could not be encoded: " .. tostring(text)) end
		end
	end
	self:Fill()
	if self.remaining == 0 and callbacks.onAllDone then callbacks.onAllDone() end
end

function ParallelGeneratorClass:Fill()
	local dkjson = require "dkjson"
	local maxWorkers = ParallelGeneratorClass.MaxWorkers()
	while not self.stopped and #self.queue > 0 and self:RunningCount() < maxWorkers do
		local entry = t_remove(self.queue, 1)
		-- (Inflate / Deflate: the timeless jewel tables are compressed)
		local id = LaunchSubScript(workerScript, "Inflate,Deflate", "ConPrintf", entry.json, main.userPath or "")
		local callbacks = self.callbacks
		local function finished()
			self.running[entry.index] = nil
			self.remaining = self.remaining - 1
			self:Fill()
			if self.remaining == 0 and callbacks.onAllDone and not self.stopped then callbacks.onAllDone() end
		end
		if not id then
			self.remaining = self.remaining - 1
			if callbacks.onError then callbacks.onError(entry.index, "could not start a background thread") end
		else
			self.running[entry.index] = id
			if callbacks.onStart then callbacks.onStart(entry.index) end
			local traceName = entry.json:match('"traceName"%s*:%s*"([^"]+)"')
			local function mainTrace(text)
				local f = traceName and io.open(traceName, "a")
				if f then f:write("main thread: " .. text .. "\n") f:close() end
			end
			mainTrace("thread launched")
			launch:RegisterSubScript(id, function(summaryJson, xml)
				mainTrace(string.format("result received (%d + %d bytes)", #(summaryJson or ""), #(xml or "")))
				if not self.stopped then
					local ok, summary = pcall(dkjson.decode, summaryJson or "")
					if ok and type(summary) == "table" and xml then
						callbacks.onDone(entry.index, summary, xml)
					elseif callbacks.onError then
						callbacks.onError(entry.index, "the worker returned no build")
					end
				end
				finished()
			end, function(errMsg)
				mainTrace("error: " .. tostring(errMsg))
				if not self.stopped and callbacks.onError then callbacks.onError(entry.index, errMsg) end
				finished()
			end)
		end
	end
end

function ParallelGeneratorClass:RunningCount()
	local n = 0
	for _ in pairs(self.running) do n = n + 1 end
	return n
end

-- Stops everything (running threads are aborted)
function ParallelGeneratorClass:Stop()
	self.stopped = true
	self.queue = { }
	for index, id in pairs(self.running) do
		if AbortSubScript then pcall(AbortSubScript, id) end
		if launch.subScripts then launch.subScripts[id] = nil end
		self.running[index] = nil
	end
end
