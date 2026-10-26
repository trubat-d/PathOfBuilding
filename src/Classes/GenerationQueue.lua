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
--   full:  full builds of the best ones (and anchors, a hybrid), each try.
-- The batches run one after the other.
--
local t_insert = table.insert
local t_remove = table.remove
local m_max = math.max
local m_min = math.min
local m_floor = math.floor

---@class GenerationQueue
local GenerationQueueClass = newClass("GenerationQueue")

function GenerationQueueClass:GenerationQueue()
	self.batches = { }
	self.byTrace = { }
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
	return self
end

local function formatSeconds(s)
	s = m_floor(s or 0)
	if s >= 3600 then return string.format("%d:%02d:%02d", m_floor(s / 3600), m_floor(s / 60) % 60, s % 60) end
	return string.format("%d:%02d", m_floor(s / 60), s % 60)
end

-- The queue: one per app
function GetGenerationQueue()
	if not main.generationQueue then
		main.generationQueue = new("GenerationQueue"):GenerationQueue()
	end
	return main.generationQueue
end

function GenerationQueueClass:Available()
	return new("ParallelGenerator"):ParallelGenerator().Available()
end

-- batch: { title, buildName, makeJob = function(archetype, quick, variant, plan) -> job,
--   archetypes (all, for the scan), standard, selected (an archetype or nil),
--   tries, remembered (scan results by archetype id, or nil), hybrid = function(a, b) or nil,
--   learningContext, skillLabel, scanBuilds }
function GenerationQueueClass:Add(batch)
	batch.status = "waiting"
	batch.added = GetTime()
	batch.results = { }
	batch.failures = { }
	batch.jobsDone, batch.jobsTotal = 0, 0
	t_insert(self.batches, batch)
	self.collapsed = false
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
			b.status = "running"
			b.started = GetTime()
			-- (launched from a frame, never from a worker's callback)
			main.onFrameFuncs["GenerationQueueStart"] = function()
				main.onFrameFuncs["GenerationQueueStart"] = nil
				self:StartBatch(b)
			end
			return
		end
	end
end

-- Runs one phase: jobs = { { archetype, quick, variant, plan } }; onDone(list of { spec, summary, xml } or errors)
function GenerationQueueClass:RunPhase(batch, label, specs, onDone)
	local pg = new("ParallelGenerator"):ParallelGenerator()
	batch.pg = pg
	batch.phase = label
	batch.running = { }
	local jobs = { }
	for i, spec in ipairs(specs) do
		jobs[i] = batch.makeJob(spec.archetype, spec.quick, spec.variant, spec.plan)
	end
	batch.jobsTotal = batch.jobsTotal + #jobs
	local results = { }
	pg:Run(jobs, {
		onStart = function(index)
			local entry = { spec = specs[index], started = GetTime(), stage = "starting" }
			batch.running[index] = entry
			if jobs[index].traceName then self.byTrace[jobs[index].traceName] = entry end
		end,
		onDone = function(index, summary, xml)
			batch.running[index] = nil
			batch.jobsDone = batch.jobsDone + 1
			t_insert(results, { spec = specs[index], summary = summary, xml = xml })
			if summary.score and (not batch.bestScore or summary.score > batch.bestScore) and not specs[index].quick then batch.bestScore = summary.score end
		end,
		onError = function(index, err)
			batch.running[index] = nil
			batch.jobsDone = batch.jobsDone + 1
			t_insert(batch.failures, (specs[index].archetype and specs[index].archetype.label or "?") .. ": " .. tostring(err))
			ConPrintf("Background generation failed: %s", tostring(err))
		end,
		onAllDone = function()
			batch.pg = nil
			if batch.status ~= "running" then return end
			-- (the next phase starts from a frame)
			main.onFrameFuncs["GenerationQueuePhase"] = function()
				main.onFrameFuncs["GenerationQueuePhase"] = nil
				local ok, err = pcall(onDone, results)
				if not ok then self:Fail(batch, err) end
			end
		end,
	})
end

function GenerationQueueClass:Fail(batch, err)
	batch.status = "failed"
	batch.error = tostring(err)
	batch.finished = GetTime()
	ConPrintf("Background generation failed: %s", tostring(err))
	self:Pump()
end

function GenerationQueueClass:StartBatch(batch)
	if batch.selected then
		return self:FullPhase(batch, { batch.selected })
	end
	if batch.remembered then
		return self:RankAndBuild(batch, batch.remembered)
	end
	-- the scan: a quick build of the skill and every archetype planned on top
	self:RunPhase(batch, "planning the archetypes", { { archetype = batch.standard, quick = true, plan = true } }, function(results)
		local r = results[1]
		if not r then return self:Fail(batch, batch.failures[1] or "the first quick build failed") end
		batch.combos = r.summary.combos
		local scan = { }
		scan[batch.standard.id] = { score = r.summary.score, built = true }
		-- the most promising archetypes get a quick build of their own
		local plan = r.summary.plan or { }
		table.sort(plan, function(a, b) return (a.score or -math.huge) > (b.score or -math.huge) end)
		local byId = { }
		for _, a in ipairs(batch.archetypes) do byId[a.id] = a end
		local quick = { }
		for _, p in ipairs(plan) do
			if not p.error and p.archetypeId ~= batch.standard.id and byId[p.archetypeId] and #quick < (batch.scanBuilds or 6) then
				t_insert(quick, { archetype = byId[p.archetypeId], quick = true })
			end
		end
		-- (anchors - builds made around one unique - always: their quick build can't show it)
		for _, a in ipairs(batch.archetypes) do
			if a.forced and #a.forced > 0 then
				local listed = false
				for _, q in ipairs(quick) do if q.archetype == a then listed = true end end
				if not listed then t_insert(quick, { archetype = a, quick = true }) end
			end
		end
		if #quick == 0 then return self:RankAndBuild(batch, scan) end
		self:RunPhase(batch, "quick builds of the promising archetypes", quick, function(quickResults)
			for _, q in ipairs(quickResults) do
				if q.summary.score then scan[q.spec.archetype.id] = { score = q.summary.score, built = true } end
			end
			self:RankAndBuild(batch, scan)
		end)
	end)
end

-- The best archetypes of a scan fully built (as the automatic mode does it)
function GenerationQueueClass:RankAndBuild(batch, scan)
	local learning = LoadModule("Modules/GeneratorLearning")
	local ranked = { }
	for _, a in ipairs(batch.archetypes) do
		local s = scan[a.id]
		if s and s.built and not s.error and s.score then
			t_insert(ranked, { archetype = a, quick = s.score, priority = learning.Priority(a.id, s.score, batch.learningContext) })
		end
	end
	table.sort(ranked, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		return a.archetype.id < b.archetype.id
	end)
	local candidates, scores, inList = { }, { }, { }
	batch.quickScores = { }
	local best
	for _, r in ipairs(ranked) do
		local same = false
		for _, s in ipairs(scores) do if math.abs(s - r.quick) < 1e-6 then same = true end end
		best = best or r.priority
		if not same and (#candidates < 3 or (#candidates < 5 and r.priority >= best - 0.5)) then
			t_insert(candidates, r.archetype)
			t_insert(scores, r.quick)
			inList[r.archetype] = true
			batch.quickScores[r.archetype.id] = r.quick
		end
	end
	local anchors = 0
	for _, r in ipairs(ranked) do
		if anchors < 2 and r.archetype.forced and not inList[r.archetype] then
			t_insert(candidates, r.archetype)
			batch.quickScores[r.archetype.id] = r.quick
			anchors = anchors + 1
		end
	end
	if batch.hybrid and ranked[1] and ranked[2] then
		local hybrid = batch.hybrid(ranked[1].archetype, ranked[2].archetype)
		if hybrid then t_insert(candidates, hybrid) end
	end
	-- (and the build doctor's two best combinations of commitments)
	local added = 0
	for _, c in ipairs(batch.combos or { }) do
		if added >= 2 then break end
		if batch.comboArchetype and c.ids and c.ids:find("+", 1, true) and (c.predicted or 0) >= 1.5 then
			local combo = batch.comboArchetype(c.ids)
			if combo then
				combo.label = string.format("Combination: %s (predicted x%.1f damage)", c.ids, c.predicted)
				t_insert(candidates, combo)
				added = added + 1
			end
		end
	end
	if #candidates == 0 then candidates = { batch.standard } end
	self:FullPhase(batch, candidates)
end

function GenerationQueueClass:FullPhase(batch, archetypes)
	local specs = { }
	for _, a in ipairs(archetypes) do
		for v = 1, m_max(1, batch.tries or 1) do t_insert(specs, { archetype = a, variant = v }) end
	end
	self:RunPhase(batch, "full builds", specs, function(results)
		local learning = LoadModule("Modules/GeneratorLearning")
		local bestR
		for _, r in ipairs(results) do
			local quick = batch.quickScores and batch.quickScores[r.spec.archetype.id]
			if quick and r.summary.score and (r.spec.variant or 1) == 1 then
				pcall(learning.Record, r.spec.archetype.id, batch.skillLabel, quick, r.summary.score, batch.learningContext)
			end
			if r.summary.score and (not bestR or r.summary.score > bestR.summary.score) then bestR = r end
		end
		if not bestR then return self:Fail(batch, batch.failures[1] or "no build was made") end
		self:Finish(batch, bestR, results)
	end)
end

-- The best build with the others as loadouts, saved in the builds folder
function GenerationQueueClass:Finish(batch, best, results)
	local list = { { xml = best.xml, title = string.format("%s try %d %.2f", best.spec.archetype.label, best.spec.variant or 1, best.summary.score) } }
	local others = { }
	for _, r in ipairs(results) do
		if r ~= best and r.xml and r.summary.score then t_insert(others, r) end
	end
	table.sort(others, function(a, b) return a.summary.score > b.summary.score end)
	for i = 1, m_min(7, #others) do
		local r = others[i]
		t_insert(list, { xml = r.xml, title = string.format("%s try %d %.2f", r.spec.archetype.label, r.spec.variant or 1, r.summary.score),
			summary = r.summary.dps and string.format("damage %s, effective hit pool %s", formatNumSep(string.format("%.0f", r.summary.dps)), formatNumSep(string.format("%.0f", r.summary.ehp or 0))) or nil })
	end
	local xml = best.xml
	if #list > 1 and main.generatorLoadouts ~= false then
		local ok, merged = pcall(LoadModule("Modules/BuildLoadouts").Merge, list)
		if ok and merged then xml = merged end
	end
	batch.best = best
	batch.xml = xml
	batch.status = "done"
	batch.finished = GetTime()
	-- saved: Generated/<name>.xml in the builds folder
	local name = (batch.buildName .. " " .. best.spec.archetype.label .. " " .. os.date("%Y-%m-%d %H%M")):gsub("[\\/:%*%?\"<>|]", "-")
	local folder = main.buildPath .. "Generated/"
	pcall(MakeDir, folder)
	local path = folder .. name .. ".xml"
	local f = io.open(path, "w")
	if not f then
		-- (no Generated folder: the builds folder itself)
		path = main.buildPath .. name .. ".xml"
		f = io.open(path, "w")
	end
	if f then
		f:write(xml)
		f:close()
		batch.file, batch.fileBuildName = path, name
	end
	self:Pump()
end

function GenerationQueueClass:Stop(batch)
	if batch.pg then batch.pg:Stop() batch.pg = nil end
	if batch.status == "running" or batch.status == "waiting" then
		batch.status = "stopped"
		batch.finished = GetTime()
	end
	self:Pump()
end

function GenerationQueueClass:Remove(batch)
	self:Stop(batch)
	for i, b in ipairs(self.batches) do
		if b == batch then t_remove(self.batches, i) break end
	end
end

function GenerationQueueClass:Open(batch)
	local function open()
		if batch.file then
			main:SetMode("BUILD", batch.file, batch.fileBuildName)
		elseif batch.xml then
			main:SetMode("BUILD", false, batch.buildName, batch.xml)
		end
	end
	local current = main.modes["BUILD"]
	if main.mode == "BUILD" and current and current.unsaved then
		main:OpenConfirmPopup("Open generated build", "The open build has unsaved changes.\nOpen the generated build anyway?", "Open", open)
	else
		open()
	end
end

-- One line of text per batch
function GenerationQueueClass:Describe(batch)
	local now = GetTime()
	local elapsed = ((batch.finished or now) - (batch.started or now)) / 1000
	if batch.status == "waiting" then
		return "^7" .. batch.title, "^xC0C0C0waiting for the generation before it"
	elseif batch.status == "running" then
		local stage
		for _, e in pairs(batch.running or { }) do
			if not stage or (e.progress or 0) > (stage.progress or 0) then stage = e end
		end
		local line2 = string.format("^xC0C0C0%s: %d/%d builds done%s, %s", batch.phase or "starting", batch.jobsDone, batch.jobsTotal,
			batch.bestScore and string.format(", best %.2f", batch.bestScore) or "", formatSeconds(elapsed))
		local line3 = stage and string.format("^x808080%s: %s", stage.spec.archetype and stage.spec.archetype.label or "", tostring(stage.stage or "")) or ""
		return "^7" .. batch.title, line2, line3
	elseif batch.status == "done" then
		return "^x33FF77" .. batch.title, string.format("^7Done in %s: %s, score %.2f%s", formatSeconds(elapsed), batch.best.spec.archetype.label, batch.best.summary.score,
			batch.file and " (saved in your builds folder)" or " (not saved: open it and save it)")
	elseif batch.status == "stopped" then
		return "^xC0C0C0" .. batch.title, "^xC0C0C0Stopped"
	else
		return colorCodes.NEGATIVE .. batch.title, colorCodes.NEGATIVE .. "Failed: ^7" .. tostring(batch.error or "?"):sub(1, 80)
	end
end

local width, rowHeight, maxRows = 460, 54, 6

function GenerationQueueClass:Height()
	if self.collapsed then return 26 end
	return 30 + m_max(1, m_min(maxRows, #self.batches)) * rowHeight
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
			return b and (select(1, queue:Describe(b))) or ""
		end)
		controls["line2_" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {8, y + 16, 0, 12}, function()
			local b = batch()
			return b and (select(2, queue:Describe(b))) or ""
		end)
		controls["line3_" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {8, y + 31, 0, 12}, function()
			local b = batch()
			local text = b and (select(3, queue:Describe(b))) or ""
			if DrawStringWidth(12, "VAR", text) > width - 150 then
				while #text > 4 and DrawStringWidth(12, "VAR", text .. "...") > width - 150 do text = text:sub(1, -2) end
				text = text .. "..."
			end
			return text
		end)
		controls["open_" .. i] = new("ButtonControl"):ButtonControl({"TOPRIGHT",nil,"TOPRIGHT"}, {-72, y + 2, 60, 18}, "Open", function()
			local b = batch()
			if b then queue:Open(b) end
		end)
		controls["open_" .. i].shown = function() local b = batch() return b and b.status == "done" end
		controls["stop_" .. i] = new("ButtonControl"):ButtonControl({"TOPRIGHT",nil,"TOPRIGHT"}, {-6, y + 2, 60, 18}, function()
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
