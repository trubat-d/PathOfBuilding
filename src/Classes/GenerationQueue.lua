-- Path of Building
--
-- Class: Generation Queue
-- Build generations that run in the background, the app staying usable: the
-- Generate window queues a generation and closes; its builds are made in
-- background threads (Classes/ParallelGenerator, Modules/GeneratorWorker) and
-- a small panel at the bottom right (drawn by Main, not a popup: it takes
-- the input only over itself) lists them with their step, how many of their
-- builds are done and the best score. A finished generation is saved in the
-- builds folder ("Generated"), every fully built build a loadout of it, and
-- can be opened from the panel.
--
-- A generation (a batch) goes through phases, each a set of worker jobs run
-- at once:
--   scan:  a quick build of the skill with every archetype planned on top
--          (ScalingPlanner), when no archetype was chosen and no recent scan
--          is known;
--   quick: quick builds of the most promising archetypes;
--   full:  full builds of the best ones (and anchors, a hybrid, the build
--          doctor's combinations), each try.
-- The batches run one after the other.
--
-- Nothing is lost: the queue, each phase's jobs and every build a worker
-- finished are saved as they come (GenerationQueue/ in the user folder). A
-- generation the app was closed on goes on when the app opens again, from
-- the builds still missing; a job that fails is tried once more, and the
-- build it had made so far is kept; a failed or stopped generation can be
-- resumed from the panel.
--
local t_insert = table.insert
local t_remove = table.remove
local m_max = math.max
local m_min = math.min
local m_floor = math.floor

---@class GenerationQueue
local GenerationQueueClass = newClass("GenerationQueue")

local maxAttempts = 2

local function folder()
	return (main.userPath or "") .. "GenerationQueue/"
end

local function readFile(path)
	local f = path and io.open(path, "rb")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end

local function writeFile(path, text)
	local f = io.open(path, "wb")
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

local function formatSeconds(s)
	s = m_floor(s or 0)
	if s >= 3600 then return string.format("%d:%02d:%02d", m_floor(s / 3600), m_floor(s / 60) % 60, s % 60) end
	return string.format("%d:%02d", m_floor(s / 60), s % 60)
end

function GenerationQueueClass:GenerationQueue()
	self.batches = { }
	self.byTrace = { }
	self.archetypeCache = { }
	self.collapsed = false
	self:BuildPanel()
	-- the workers' progress (Modules/GeneratorWorker calls it from its thread)
	local queue = self
	function GeneratorProgress(traceName, stage, index, count, sub)
		local entry = traceName and queue.byTrace[traceName]
		if entry then
			entry.stage = stage
			entry.progress = (count and count > 0) and (((index or 1) - 1 + (sub or 0)) / count) or entry.progress
		end
	end
	self:Load()
	return self
end

-- The queue, created when the app starts if generations were left in it
function GenerationQueueClass.Restore()
	if main.generationQueue then return main.generationQueue end
	if not readFile(folder() .. "queue.json") then return nil end
	main.generationQueue = new("GenerationQueue"):GenerationQueue()
	return main.generationQueue
end

function GenerationQueueClass:Available()
	return new("ParallelGenerator"):ParallelGenerator().Available()
end

------------------------------------------------------------------------------
-- Saving
------------------------------------------------------------------------------

local savedKeys = { "id", "title", "buildName", "skillLabel", "gemId", "baseJob", "tries", "scanBuilds", "learningContext",
	"selectedId", "standardId", "remembered", "combos", "hybrid", "status", "phase", "specs", "scan", "quickScores", "full",
	"bestScore", "error", "file", "fileBuildName", "partialFile", "startedWall", "finishedWall", "elapsedBefore", "forceQuick", "best", "combined" }

function GenerationQueueClass:Save()
	local dkjson = require "dkjson"
	local list = { }
	for _, b in ipairs(self.batches) do
		local copy = { }
		for _, k in ipairs(savedKeys) do copy[k] = b[k] end
		t_insert(list, copy)
	end
	pcall(MakeDir, folder())
	local ok, text = pcall(dkjson.encode, { version = 1, batches = list })
	if ok and text then writeFile(folder() .. "queue.json", text) end
end

function GenerationQueueClass:Load()
	local text = readFile(folder() .. "queue.json")
	if not text then return end
	local ok, data = pcall(require("dkjson").decode, text)
	if not ok or type(data) ~= "table" or type(data.batches) ~= "table" then return end
	for _, b in ipairs(data.batches) do
		-- (the app was closed while it ran: it goes on from what is missing)
		if b.status == "running" then
			b.status = "waiting"
			b.resumed = true
		end
		for _, s in ipairs(b.specs or { }) do
			if s.state == "running" then s.state = "pending" end
		end
		t_insert(self.batches, b)
	end
	self:Pump()
end

------------------------------------------------------------------------------
-- Archetypes (kept by id in the saved queue)
------------------------------------------------------------------------------

function GenerationQueueClass:Archetype(batch, id)
	if not id then return nil end
	local key = tostring(batch.gemId) .. "|" .. id
	if self.archetypeCache[key] == nil then
		local gem = data.gems[batch.gemId]
		local ok, a = pcall(function() return new("BuildArchetypes"):BuildArchetypes().ById(gem, id, batch.baseJob and batch.baseJob.meta) end)
		self.archetypeCache[key] = ok and a or false
	end
	return self.archetypeCache[key] or nil
end

function GenerationQueueClass:Label(batch, id)
	local a = self:Archetype(batch, id)
	return a and a.label or id or "?"
end

------------------------------------------------------------------------------
-- Running
------------------------------------------------------------------------------

-- batch (from the Generate window): { title, buildName, skillLabel, gemId,
--   baseJob (ParallelGenerator.JobFromOptions without an archetype), tries,
--   scanBuilds, learningContext, selectedId, standardId, remembered (scan
--   results by archetype id), combos, hybrid (true: the best two together) }
function GenerationQueueClass:Add(batch)
	self.counter = (self.counter or 0) + 1
	batch.id = os.date("%Y%m%d%H%M%S") .. "_" .. self.counter
	batch.status = "waiting"
	t_insert(self.batches, batch)
	self.collapsed = false
	self:Save()
	self:Pump()
	return batch
end

function GenerationQueueClass:Running()
	for _, b in ipairs(self.batches) do
		if b.status == "running" then return b end
	end
end

function GenerationQueueClass:Pump()
	if self:Running() then return end
	for _, b in ipairs(self.batches) do
		if b.status == "waiting" then
			-- (launched from a frame, never from a worker's callback, once the app's data is loaded)
			main.onFrameFuncs["GenerationQueueStart"] = function()
				if main.uniqueDB.loading or (main.rareDB and main.rareDB.loading) then return end
				main.onFrameFuncs["GenerationQueueStart"] = nil
				if b.status ~= "waiting" or self:Running() then return end
				b.status = "running"
				b.startedWall = os.time()
				b.finishedWall = nil
				local ok, err = pcall(function() self:Advance(b) end)
				if not ok then self:Fail(b, err) end
			end
			return
		end
	end
end

-- The next thing to do for a batch: start its first phase, run what is
-- pending in its phase, or go to the next phase
function GenerationQueueClass:Advance(batch)
	if not batch.phase then
		if batch.selectedId then
			return self:SetPhase(batch, "full", self:FullSpecs(batch, { batch.selectedId }))
		elseif batch.remembered then
			batch.scan = batch.remembered
			return self:RankAndBuild(batch)
		end
		return self:SetPhase(batch, "scan", { { archetypeId = batch.standardId, quick = true, plan = true } })
	end
	local pending = { }
	for i, s in ipairs(batch.specs or { }) do
		if s.state == "pending" then t_insert(pending, i) end
	end
	if #pending > 0 then return self:RunPending(batch, pending) end
	-- (a failed job: once more)
	local retry = { }
	for i, s in ipairs(batch.specs or { }) do
		if s.state == "failed" and (s.attempts or 0) < maxAttempts then
			s.state = "pending"
			t_insert(retry, i)
		end
	end
	if #retry > 0 then return self:RunPending(batch, retry) end
	return self:PhaseDone(batch)
end

function GenerationQueueClass:SetPhase(batch, phase, specs)
	batch.phase = phase
	batch.specs = specs
	for _, s in ipairs(specs) do s.state = "pending" s.attempts = 0 end
	self:Save()
	return self:Advance(batch)
end

function GenerationQueueClass:FullSpecs(batch, ids)
	local specs = { }
	for _, id in ipairs(ids) do
		for v = 1, m_max(1, batch.tries or 1) do t_insert(specs, { archetypeId = id, variant = v }) end
	end
	return specs
end

function GenerationQueueClass:MakeJob(batch, spec)
	local job = { }
	for k, v in pairs(batch.baseJob or { }) do job[k] = v end
	job.archetypeId = spec.archetypeId
	-- (the archetype the player chose keeps its commitment to the end)
	if batch.selectedId and spec.archetypeId == batch.selectedId and batch.selectedId ~= batch.standardId then job.keepCommitment = true end
	job.quick = spec.quick or batch.forceQuick or nil
	if spec.quick then job.synergies = false end
	job.variant = spec.variant
	job.plan = spec.plan or nil
	job.traceName = nil
	if spec.combine then
		-- (the best build crossed with the other tries: Modules/GeneratorWorker "combine")
		job.kind = "combine"
		job.buildXml = readFile(spec.buildFile)
		job.others = { }
		for _, o in ipairs(spec.others or { }) do
			local text = readFile(o.stateFile)
			local ok, state = pcall(require("dkjson").decode, text or "")
			if ok and state then t_insert(job.others, { state = state, label = o.label }) end
		end
	end
	-- (a failed job sends back the build it had made: Modules/GeneratorWorker)
	job.partialOnError = true
	return job
end

function GenerationQueueClass:RunPending(batch, indexes)
	local pg = new("ParallelGenerator"):ParallelGenerator()
	batch.pg = pg
	batch.running = { }
	local jobs = { }
	for n, i in ipairs(indexes) do
		jobs[n] = self:MakeJob(batch, batch.specs[i])
		batch.specs[i].state = "running"
		batch.specs[i].attempts = (batch.specs[i].attempts or 0) + 1
	end
	self:Save()
	pg:Run(jobs, {
		onStart = function(n)
			local spec = batch.specs[indexes[n]]
			local entry = { spec = spec, started = GetTime(), stage = "starting" }
			batch.running[n] = entry
			if jobs[n].traceName then self.byTrace[jobs[n].traceName] = entry end
		end,
		onDone = function(n, summary, xml)
			batch.running[n] = nil
			local i = indexes[n]
			local spec = batch.specs[i]
			local path = folder() .. string.format("%s_%s_%d%s.xml", batch.id, batch.phase, i, summary.partial and "_partial" or "")
			local saved = xml and writeFile(path, xml)
			if summary.partial then
				-- (the job failed: the build it had made so far is kept)
				spec.state = "failed"
				spec.error = summary.error
				if saved then spec.partialFile = path end
				ConPrintf("Background generation failed (build kept so far): %s", tostring(summary.error))
			else
				spec.state = "done"
				-- (a retry that worked: the earlier failure is gone)
				spec.error, spec.partialFile = nil, nil
				spec.file = saved and path or nil
				spec.score, spec.dps, spec.ehp = summary.score, summary.dps, summary.ehp
				spec.plan, spec.combos = summary.plan, summary.combos
				-- (the build as data, for the combination of the best tries)
				if summary.state and batch.phase == "full" then
					local okState, stateText = pcall(require("dkjson").encode, summary.state)
					if okState and stateText then
						local statePath = folder() .. string.format("%s_%s_%d.state.json", batch.id, batch.phase, i)
						if writeFile(statePath, stateText) then spec.stateFile = statePath end
					end
				end
				if batch.phase == "full" and summary.score and (not batch.bestScore or summary.score > batch.bestScore) then batch.bestScore = summary.score end
			end
			self:Save()
		end,
		onError = function(n, err)
			batch.running[n] = nil
			local spec = batch.specs[indexes[n]]
			spec.state = "failed"
			spec.error = tostring(err)
			ConPrintf("Background generation failed: %s", tostring(err))
			self:Save()
		end,
		onAllDone = function()
			batch.pg = nil
			if batch.status ~= "running" then return end
			-- (the next step from a frame)
			main.onFrameFuncs["GenerationQueueAdvance"] = function()
				main.onFrameFuncs["GenerationQueueAdvance"] = nil
				local ok, err = pcall(function() self:Advance(batch) end)
				if not ok then self:Fail(batch, err) end
			end
		end,
	})
end

function GenerationQueueClass:PhaseDone(batch)
	local done = { }
	for _, s in ipairs(batch.specs or { }) do
		if s.state == "done" then t_insert(done, s) end
	end
	if batch.phase == "scan" then
		local r = done[1]
		if not r then return self:Fail(batch, self:FirstError(batch) or "the first quick build failed") end
		batch.combos = r.combos
		batch.scan = { [batch.standardId] = { score = r.score, built = true } }
		-- the most promising archetypes get a quick build of their own
		local plan = r.plan or { }
		table.sort(plan, function(a, b) return (a.score or -math.huge) > (b.score or -math.huge) end)
		local quick, listed = { }, { }
		for _, p in ipairs(plan) do
			if not p.error and p.archetypeId ~= batch.standardId and not listed[p.archetypeId] and #quick < (batch.scanBuilds or 6) then
				listed[p.archetypeId] = true
				t_insert(quick, { archetypeId = p.archetypeId, quick = true })
			end
		end
		-- (anchors - builds made around one unique - always: their quick build can't show it)
		local gem = data.gems[batch.gemId]
		for _, a in ipairs(new("BuildArchetypes"):BuildArchetypes().ForSkill(gem, batch.baseJob and batch.baseJob.meta)) do
			if a.forced and #a.forced > 0 and not listed[a.id] then
				listed[a.id] = true
				t_insert(quick, { archetypeId = a.id, quick = true })
			end
		end
		if #quick == 0 then return self:RankAndBuild(batch) end
		return self:SetPhase(batch, "quick", quick)
	elseif batch.phase == "full" and not batch.combined and main.generatorCombine ~= false then
		-- the best build crossed with the next best ones (other tries and close
		-- archetypes), as the window does it: kept if it is better
		batch.full = batch.specs
		local ranked = { }
		for _, s in ipairs(done) do if s.score and s.file then t_insert(ranked, s) end end
		table.sort(ranked, function(a, b) return a.score > b.score end)
		local best = ranked[1]
		local others = { }
		for i = 2, #ranked do
			local s = ranked[i]
			if #others < 3 and s.stateFile and s.score >= best.score - 1.5 then
				t_insert(others, { stateFile = s.stateFile, label = self:Label(batch, s.archetypeId) .. " try " .. (s.variant or 1) })
			end
		end
		batch.combined = true
		if not best or #others == 0 then return self:Finish(batch) end
		return self:SetPhase(batch, "combine", { { archetypeId = best.archetypeId, variant = best.variant, combine = true, buildFile = best.file, others = others, baseScore = best.score } })
	elseif batch.phase == "quick" then
		batch.scan = batch.scan or { }
		for _, s in ipairs(done) do
			if s.score then batch.scan[s.archetypeId] = { score = s.score, built = true } end
		end
		return self:RankAndBuild(batch)
	else
		return self:Finish(batch)
	end
end

function GenerationQueueClass:FirstError(batch)
	for _, s in ipairs(batch.specs or { }) do
		if s.error then return self:Label(batch, s.archetypeId) .. ": " .. tostring(s.error) end
	end
end

-- The best archetypes of a scan fully built (as the automatic mode does it)
function GenerationQueueClass:RankAndBuild(batch)
	local learning = LoadModule("Modules/GeneratorLearning")
	local ranked = { }
	for id, s in pairs(batch.scan or { }) do
		local a = self:Archetype(batch, id)
		if a and type(s) == "table" and s.built and not s.error and s.score then
			t_insert(ranked, { archetype = a, quick = s.score, priority = learning.Priority(a.id, s.score, batch.learningContext) })
		end
	end
	table.sort(ranked, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		return a.archetype.id < b.archetype.id
	end)
	local ids, scores, inList = { }, { }, { }
	batch.quickScores = { }
	local best
	for _, r in ipairs(ranked) do
		local same = false
		for _, s in ipairs(scores) do if math.abs(s - r.quick) < 1e-6 then same = true end end
		best = best or r.priority
		if not same and (#ids < 3 or (#ids < 5 and r.priority >= best - 0.5)) then
			t_insert(ids, r.archetype.id)
			t_insert(scores, r.quick)
			inList[r.archetype.id] = true
			batch.quickScores[r.archetype.id] = r.quick
		end
	end
	local anchors = 0
	for _, r in ipairs(ranked) do
		if anchors < 2 and r.archetype.forced and not inList[r.archetype.id] then
			t_insert(ids, r.archetype.id)
			inList[r.archetype.id] = true
			batch.quickScores[r.archetype.id] = r.quick
			anchors = anchors + 1
		end
	end
	-- (the best two together, when they can be combined)
	if batch.hybrid and ranked[1] and ranked[2] then
		local hybridId = ranked[1].archetype.id .. "+" .. ranked[2].archetype.id
		if self:Archetype(batch, hybridId) and not inList[hybridId] then t_insert(ids, hybridId) inList[hybridId] = true end
	end
	-- (and the build doctor's two best combinations of commitments)
	local added = 0
	for _, c in ipairs(batch.combos or { }) do
		if added >= 2 then break end
		if c.ids and c.ids:find("+", 1, true) and (c.predicted or 0) >= 1.5 and not inList[c.ids] and self:Archetype(batch, c.ids) then
			t_insert(ids, c.ids)
			inList[c.ids] = true
			added = added + 1
		end
	end
	if #ids == 0 then ids = { batch.standardId } end
	return self:SetPhase(batch, "full", self:FullSpecs(batch, ids))
end

-- The best build with the others as loadouts, saved in the builds folder
function GenerationQueueClass:Finish(batch)
	local learning = LoadModule("Modules/GeneratorLearning")
	local results = { }
	local specs = { }
	-- (batch.full: the full builds, kept while the combine phase runs - only
	-- then: a copy left from a full phase that failed and was resumed would
	-- hide the builds the resumed phase made)
	for _, s in ipairs((batch.phase == "combine" and batch.full) or batch.specs or { }) do t_insert(specs, s) end
	-- (the combined build replaces the best try it was made from when it is better)
	local combined
	if batch.phase == "combine" then
		for _, s in ipairs(batch.specs or { }) do
			if s.state == "done" and s.file and s.score and s.score > (s.baseScore or -math.huge) then combined = s end
		end
	end
	if combined then
		for i = #specs, 1, -1 do
			if specs[i].file == combined.buildFile then t_remove(specs, i) end
		end
		combined.combinedLabel = true
		t_insert(specs, combined)
	end
	for _, s in ipairs(specs) do
		if s.state == "done" and s.file and s.score and not s.combine or s == combined then
			local xml = readFile(s.file)
			if xml then t_insert(results, { spec = s, xml = xml }) end
			local quick = batch.quickScores and batch.quickScores[s.archetypeId]
			if quick and (s.variant or 1) == 1 and not s.combine then
				pcall(learning.Record, s.archetypeId, batch.skillLabel, quick, s.score, batch.learningContext)
			end
		end
	end
	table.sort(results, function(a, b) return a.spec.score > b.spec.score end)
	local best = results[1]
	if not best then
		-- (no build finished: the best partial one is kept, it can be opened)
		for _, s in ipairs(batch.specs or { }) do
			if s.partialFile and not batch.partialFile then batch.partialFile = s.partialFile end
		end
		return self:Fail(batch, self:FirstError(batch) or "no build was made")
	end
	local list = { }
	for i = 1, m_min(8, #results) do
		local r = results[i]
		t_insert(list, { xml = r.xml, title = string.format("%s %s %.2f", self:Label(batch, r.spec.archetypeId), r.spec.combinedLabel and "combined" or ("try " .. (r.spec.variant or 1)), r.spec.score),
			summary = r.spec.dps and string.format("damage %s, effective hit pool %s", formatNumSep(string.format("%.0f", r.spec.dps)), formatNumSep(string.format("%.0f", r.spec.ehp or 0))) or nil })
	end
	local xml = best.xml
	if #list > 1 and main.generatorLoadouts ~= false then
		local ok, merged = pcall(LoadModule("Modules/BuildLoadouts").Merge, list)
		if ok and merged then xml = merged end
	end
	batch.best = { archetypeId = best.spec.archetypeId, score = best.spec.score }
	-- saved: Generated/<name>.xml in the builds folder
	local name = (batch.buildName .. " " .. self:Label(batch, best.spec.archetypeId) .. " " .. os.date("%Y-%m-%d %H%M")):gsub("[\\/:%*%?\"<>|]", "-")
	local dir = main.buildPath .. "Generated/"
	pcall(MakeDir, dir)
	local path = dir .. name .. ".xml"
	if not writeFile(path, xml) then
		-- (no Generated folder: the builds folder itself)
		path = main.buildPath .. name .. ".xml"
		if not writeFile(path, xml) then path = nil end
	end
	if path then
		batch.file, batch.fileBuildName = path, name
	else
		-- (kept in the queue's folder, opened from there)
		batch.file = folder() .. batch.id .. "_result.xml"
		writeFile(batch.file, xml)
		batch.fileBuildName = nil
	end
	batch.status = "done"
	batch.finishedWall = os.time()
	self:Save()
	self:Pump()
end

function GenerationQueueClass:Fail(batch, err)
	batch.status = "failed"
	batch.error = tostring(err)
	batch.finishedWall = os.time()
	ConPrintf("Background generation failed: %s", tostring(err))
	self:Save()
	self:Pump()
end

function GenerationQueueClass:Stop(batch)
	if batch.pg then batch.pg:Stop() batch.pg = nil end
	if batch.status == "running" or batch.status == "waiting" then
		batch.status = "stopped"
		batch.finishedWall = os.time()
		for _, s in ipairs(batch.specs or { }) do
			if s.state == "running" then s.state = "pending" s.attempts = m_max(0, (s.attempts or 1) - 1) end
		end
	end
	self:Save()
	self:Pump()
end

-- A stopped or failed generation goes on from what is missing
function GenerationQueueClass:Resume(batch)
	if batch.status ~= "stopped" and batch.status ~= "failed" then return end
	for _, s in ipairs(batch.specs or { }) do
		if s.state == "failed" or s.state == "running" then s.state = "pending" s.attempts = 0 end
	end
	-- (a full phase resumed: its builds are combined again once they are done)
	if batch.phase ~= "combine" then batch.full, batch.combined = nil, nil end
	batch.error = nil
	batch.status = "waiting"
	batch.resumed = true
	self:Save()
	self:Pump()
end

function GenerationQueueClass:Remove(batch)
	self:Stop(batch)
	for i, b in ipairs(self.batches) do
		if b == batch then t_remove(self.batches, i) break end
	end
	-- (its builds in the queue's folder; a finished one stays in the builds folder)
	for _, list in ipairs({ batch.specs or { }, batch.full or { } }) do
		for _, s in ipairs(list) do
			if s.file then os.remove(s.file) end
			if s.stateFile then os.remove(s.stateFile) end
			if s.partialFile and s.partialFile ~= batch.partialFile then os.remove(s.partialFile) end
		end
	end
	self:Save()
end

function GenerationQueueClass:Open(batch)
	local function open()
		if batch.file and batch.fileBuildName then
			main:SetMode("BUILD", batch.file, batch.fileBuildName)
		else
			local xml = readFile(batch.file or batch.partialFile)
			if xml then main:SetMode("BUILD", false, batch.buildName .. (batch.file and "" or " (partly built)"), xml) end
		end
	end
	local current = main.modes["BUILD"]
	if main.mode == "BUILD" and current and current.unsaved then
		main:OpenConfirmPopup("Open generated build", "The open build has unsaved changes.\nOpen the generated build anyway?", "Open", open)
	else
		open()
	end
end

------------------------------------------------------------------------------
-- Panel
------------------------------------------------------------------------------

local phaseLabels = { scan = "planning the archetypes", quick = "quick builds of the promising archetypes", full = "full builds", combine = "combining the best builds" }

-- The lines of text for a batch
function GenerationQueueClass:Describe(batch)
	local elapsed = (batch.elapsedBefore or 0) + ((batch.finishedWall or os.time()) - (batch.startedWall or os.time()))
	local done, total = 0, 0
	for _, s in ipairs(batch.specs or { }) do
		total = total + 1
		if s.state == "done" then done = done + 1 end
	end
	if batch.status == "waiting" then
		return "^7" .. batch.title, batch.resumed and "^xC0C0C0waiting to go on from where it stopped" or "^xC0C0C0waiting for the generation before it"
	elseif batch.status == "running" then
		local stage
		for _, e in pairs(batch.running or { }) do
			if not stage or (e.progress or 0) > (stage.progress or 0) then stage = e end
		end
		local line2 = string.format("^xC0C0C0%s: %d/%d builds done%s, %s", phaseLabels[batch.phase] or "starting", done, total,
			batch.bestScore and string.format(", best %.2f", batch.bestScore) or "", formatSeconds(os.time() - (batch.startedWall or os.time())))
		local line3 = stage and string.format("^x808080%s: %s", self:Label(batch, stage.spec.archetypeId), tostring(stage.stage or "")) or ""
		return "^7" .. batch.title, line2, line3
	elseif batch.status == "done" then
		return "^x33FF77" .. batch.title, string.format("^7Done: %s, score %.2f%s", self:Label(batch, batch.best and batch.best.archetypeId), batch.best and batch.best.score or 0,
			batch.fileBuildName and " (saved in your builds folder, Generated)" or "")
	elseif batch.status == "stopped" then
		return "^xC0C0C0" .. batch.title, string.format("^xC0C0C0Stopped (%s, %d/%d builds done): Resume goes on from there", phaseLabels[batch.phase] or "not started", done, total)
	else
		return colorCodes.NEGATIVE .. batch.title, colorCodes.NEGATIVE .. "Failed: ^7" .. tostring(batch.error or "?"):gsub("\n.*", ""),
			batch.partialFile and "^xC0C0C0The build made so far is kept: Open. Resume tries again." or "^xC0C0C0Resume tries again."
	end
end

local width, rowHeight, maxRows = 500, 54, 6

function GenerationQueueClass:Height()
	if self.collapsed then return 26 end
	return 30 + m_max(1, m_min(maxRows, #self.batches)) * rowHeight
end

local function fit(text, size, maxWidth)
	if DrawStringWidth(size, "VAR", text) > maxWidth then
		while #text > 4 and DrawStringWidth(size, "VAR", text .. "...") > maxWidth do text = text:sub(1, -2) end
		text = text .. "..."
	end
	return text
end

function GenerationQueueClass:BuildPanel()
	local queue = self
	local controls = { }
	controls.toggle = new("ButtonControl"):ButtonControl({"TOPRIGHT",nil,"TOPRIGHT"}, {-6, 4, 60, 18}, function()
		return queue.collapsed and "Show" or "Hide"
	end, function() queue.collapsed = not queue.collapsed end)
	controls.summary = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {8, 6, 0, 14}, function()
		local running, done = 0, 0
		for _, b in ipairs(queue.batches) do
			if b.status == "running" or b.status == "waiting" then running = running + 1 elseif b.status == "done" then done = done + 1 end
		end
		return string.format("^7Generations: %d running / waiting, %d done", running, done)
	end)
	for i = 1, maxRows do
		local function batch() return not queue.collapsed and queue.batches[i] end
		local y = 28 + (i - 1) * rowHeight
		controls["line1_" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {8, y, 0, 14}, function()
			local b = batch()
			return b and fit((select(1, queue:Describe(b))), 14, width - 200) or ""
		end)
		controls["line2_" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {8, y + 16, 0, 12}, function()
			local b = batch()
			return b and fit((select(2, queue:Describe(b))) or "", 12, width - 16) or ""
		end)
		controls["line3_" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {8, y + 31, 0, 12}, function()
			local b = batch()
			return b and fit((select(3, queue:Describe(b))) or "", 12, width - 16) or ""
		end)
		controls["open_" .. i] = new("ButtonControl"):ButtonControl({"TOPRIGHT",nil,"TOPRIGHT"}, {-128, y, 56, 18}, "Open", function()
			local b = batch()
			if b then queue:Open(b) end
		end)
		controls["open_" .. i].shown = function() local b = batch() return b and (b.status == "done" or (b.status ~= "running" and b.partialFile ~= nil)) end
		controls["resume_" .. i] = new("ButtonControl"):ButtonControl({"TOPRIGHT",nil,"TOPRIGHT"}, {-66, y, 58, 18}, "Resume", function()
			local b = batch()
			if b then queue:Resume(b) end
		end)
		controls["resume_" .. i].shown = function() local b = batch() return b and (b.status == "stopped" or b.status == "failed") end
		controls["stop_" .. i] = new("ButtonControl"):ButtonControl({"TOPRIGHT",nil,"TOPRIGHT"}, {-6, y, 56, 18}, function()
			local b = batch()
			return b and (b.status == "running" or b.status == "waiting") and "Stop" or "Remove"
		end, function()
			local b = batch()
			if not b then return end
			if b.status == "running" or b.status == "waiting" then queue:Stop(b) else queue:Remove(b) end
		end)
		controls["stop_" .. i].shown = function() return batch() and true or false end
	end
	controls.hide = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {-1000, -1000, 1, 1}, "", function() queue.collapsed = true end)
	local panel = new("PopupDialog"):PopupDialog(width, 100, "", controls, nil, nil, "hide")
	panel.width = function() return width end
	panel.height = function() return queue:Height() end
	panel.x = function() return main.screenW - width - 6 end
	panel.y = function() return main.screenH - queue:Height() - 32 end
	-- (no title box: drawn as a plain panel)
	panel.Draw = function(self, viewPort)
		local x, y = self:GetPos()
		local w, h = self:GetSize()
		SetDrawColor(0.6, 0.6, 0.6)
		DrawImage(nil, x, y, w, h)
		SetDrawColor(0.08, 0.08, 0.08)
		DrawImage(nil, x + 1, y + 1, w - 2, h - 2)
		self:DrawControls(viewPort)
	end
	self.panel = panel
end

-- Drawn and fed by Main while there is something to show
function GenerationQueueClass:Shown()
	return #self.batches > 0
end
