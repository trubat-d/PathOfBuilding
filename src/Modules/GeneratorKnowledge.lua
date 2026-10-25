-- Path of Building
--
-- Module: Generator Knowledge
-- What earlier generations on this computer found out, to make the next ones
-- faster and better (GeneratorKnowledge.json in the user folder):
--   * Steps: for each kind of build (investment level and attack / spell /
--     minion), how often each optional late step of a generation improved the
--     build, by how much and how long it took. A step that never improved
--     the last builds of that kind is skipped (and tried again now and then,
--     in case the builds changed).
--   * Builds: the best builds made for each skill, ascendancy, budget, focus
--     and configuration (their gear, main link and passives). A new
--     generation tries their parts in its own build, like the top players'
--     gear and passives, so it starts where earlier generations ended.
--   * Decisions (GeneratorDecisions.jsonl, one JSON object per line): every
--     choice a generation measured and what it did to the score - each
--     support tried at each pick, each passive picked with the best
--     alternatives it beat, each unique, anoint, tattoo or jewel kept or
--     rejected, each step's gain and time, the log lines - after a "run" line
--     with the build's context (skill and its tags, class, ascendancy, budget,
--     focus weights, configuration, archetype) and its final numbers. It is
--     the training data for models of the generator's choices
--     (bench/train_model.py); see docs/buildGenerator.md for the format.
-- Workers (background threads) only read it; what they learn travels back
-- with their result and is written by the main thread (Commit).
--
local dkjson = require "dkjson"
local M = { }

-- (bumped when the scorer changes enough that old scores can't be compared)
M.version = 1
local maxBuildsPerKey = 3
local maxBuilds = 120
local minTries = 8 -- (a step is judged after this many builds of a kind)
local retryEvery = 5 -- (a skipped step is tried again every this many builds)

local function path()
	return (main and main.userPath or "") .. "GeneratorKnowledge.json"
end

function M.Load(force)
	if M.data and not force then return M.data end
	local data
	local f = io.open(path(), "r")
	if f then
		local ok, value = pcall(dkjson.decode, f:read("*a"))
		f:close()
		if ok and type(value) == "table" then data = value end
	end
	data = data or { }
	if data.version ~= M.version then
		-- (step statistics stay valid; builds scored by an older scorer don't)
		data.builds = { }
		data.version = M.version
	end
	data.steps = type(data.steps) == "table" and data.steps or { }
	data.builds = type(data.builds) == "table" and data.builds or { }
	M.data = data
	return data
end

function M.Save()
	if not M.data then return end
	local f = io.open(path(), "w")
	if f then
		f:write(dkjson.encode(M.data))
		f:close()
	end
end

------------------------------------------------------------------------------
-- Keys
------------------------------------------------------------------------------

-- The kind of build, for step statistics
function M.StepContext(options, mainGem)
	local investment = options.investment or { }
	local tags = mainGem and mainGem.tags or { }
	local kind = tags.minion and "minion" or tags.attack and "attack" or "spell"
	return (investment.baseId or investment.id or "?") .. "|" .. kind
end

-- The build, for remembered builds: skill, ascendancy, budget, focus, configuration
function M.BuildKey(options, gemName, ascendName)
	local investment = options.investment or { }
	local focus = options.focus or { }
	local focusId = (focus.id or "?"):gsub("_REVIEWED$", "")
	return table.concat({ gemName or "?", ascendName or "?", investment.baseId or investment.id or "?",
		investment.totalBudget and tostring(math.floor(investment.totalBudget)) or "-", focusId,
		options.configScenario and options.configScenario.id or "BOSS" }, "|")
end

------------------------------------------------------------------------------
-- Steps
------------------------------------------------------------------------------

-- Should an optional step be skipped for this kind of build? skip, reason
function M.ShouldSkip(context, step)
	local data = M.Load()
	local stats = data.steps[context] and data.steps[context][step]
	if not stats or (stats.tries or 0) < minTries then return false end
	if (stats.kept or 0) > 0 then return false end
	-- (now and then tried again)
	if (stats.tries % retryEvery) == retryEvery - 1 then return false end
	return true, string.format("it improved none of the last %d builds like this one", stats.tries)
end

-- A step's outcome: { context, step, gain, seconds }
local function addStep(data, r)
	data.steps[r.context] = data.steps[r.context] or { }
	local stats = data.steps[r.context][r.step] or { tries = 0, kept = 0, gain = 0, seconds = 0 }
	stats.tries = stats.tries + 1
	if r.gain > 0.005 then stats.kept = stats.kept + 1 end
	stats.gain = stats.gain + math.max(0, r.gain)
	stats.seconds = stats.seconds + (r.seconds or 0)
	data.steps[r.context][r.step] = stats
end

------------------------------------------------------------------------------
-- Builds
------------------------------------------------------------------------------

-- The parts of a build worth remembering (gear, main link supports, passives):
-- a slim BuildComparison.ReadParts
function M.Parts(build)
	local parts = { items = { }, supports = { }, groups = { } }
	for slotName, slot in pairs(build.itemsTab.slots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and not slot.nodeId and not slotName:match("Swap") and not slotName:match("Abyssal") then
			parts.items[slotName] = { raw = item.raw, name = item.title or item.name }
		end
	end
	local main = build.skillsTab.socketGroupList[build.mainSocketGroup]
	for _, gem in ipairs(main and main.gemList or { }) do
		if gem.gemData and gem.enabled ~= false and gem.gemData.grantedEffect.support then
			table.insert(parts.supports, { name = gem.gemData.name, level = gem.level, quality = gem.quality, support = true })
		end
	end
	local spec = build.spec
	parts.tree = { className = spec.curClassName, classId = spec.curClassId, ascendClassId = spec.curAscendClassId, nodes = { } }
	for id in pairs(spec.allocNodes) do table.insert(parts.tree.nodes, id) end
	table.sort(parts.tree.nodes)
	return parts
end

local function addBuild(data, key, entry)
	local list = data.builds[key] or { }
	-- (the same build again: only the better one)
	for i = #list, 1, -1 do
		if math.abs((list[i].score or 0) - (entry.score or 0)) < 1e-6 then table.remove(list, i) end
	end
	table.insert(list, entry)
	table.sort(list, function(a, b) return (a.score or 0) > (b.score or 0) end)
	for i = #list, maxBuildsPerKey + 1, -1 do list[i] = nil end
	data.builds[key] = list
	-- (the oldest builds go first when there are too many)
	local all = { }
	for k, l in pairs(data.builds) do for i, e in ipairs(l) do table.insert(all, { key = k, index = i, time = e.time or 0 }) end end
	if #all > maxBuilds then
		table.sort(all, function(a, b) return a.time < b.time end)
		local drop = { }
		for i = 1, #all - maxBuilds do drop[all[i].key .. "#" .. all[i].index] = true end
		for k, l in pairs(data.builds) do
			for i = #l, 1, -1 do if drop[k .. "#" .. i] then table.remove(l, i) end end
			if #l == 0 then data.builds[k] = nil end
		end
	end
end

-- The remembered builds for a key, best first
function M.Past(key)
	local data = M.Load()
	return data.builds[key] or { }
end

------------------------------------------------------------------------------
-- Decisions
------------------------------------------------------------------------------

M.decisionVersion = 1
local maxDecisionBytes = 300 * 1024 * 1024 -- (then the file is renamed .old and a new one started)

function M.DecisionsPath()
	return (main and main.userPath or "") .. "GeneratorDecisions.jsonl"
end

-- One generation's decisions appended after its run line (to the given file,
-- else the user folder's)
function M.AppendDecisions(run, decisions, filePath)
	if not run then return end
	filePath = filePath or M.DecisionsPath()
	local probe = io.open(filePath, "r")
	if probe then
		local size = probe:seek("end")
		probe:close()
		if size and size > maxDecisionBytes then
			os.remove(filePath .. ".old")
			os.rename(filePath, filePath .. ".old")
		end
	end
	local f = io.open(filePath, "a")
	if not f then return end
	run.type = "run"
	run.v = M.decisionVersion
	f:write(dkjson.encode(run), "\n")
	for _, d in ipairs(decisions or { }) do
		d.run = run.id
		f:write(dkjson.encode(d), "\n")
	end
	f:close()
end

-- One line of its own (a player's review of a build: "type":"review")
function M.AppendLine(entry, filePath)
	local f = io.open(filePath or M.DecisionsPath(), "a")
	if not f then return end
	entry.v = M.decisionVersion
	f:write(dkjson.encode(entry), "\n")
	f:close()
end

------------------------------------------------------------------------------
-- Writing
------------------------------------------------------------------------------

-- What a generation learnt: { steps = { ... }, builds = { { key, entry } } },
-- merged into the file (re-read first: other generations may have written)
function M.Commit(records)
	if not records then return end
	local data = M.Load(true)
	for _, r in ipairs(records.steps or { }) do addStep(data, r) end
	for _, b in ipairs(records.builds or { }) do addBuild(data, b.key, b.entry) end
	M.Save()
	if records.run then M.AppendDecisions(records.run, records.decisions) end
end

-- Totals for the window: number of builds remembered and step records
function M.Summary()
	local data = M.Load()
	local builds, steps = 0, 0
	for _, l in pairs(data.builds) do builds = builds + #l end
	for _, ctx in pairs(data.steps) do for _, s in pairs(ctx) do steps = steps + (s.tries or 0) end end
	return builds, steps
end

return M
