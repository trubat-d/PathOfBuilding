-- Path of Building
--
-- Module: Generator Model Trainer
-- Trains the candidate model (Modules/GeneratorModel) inside PoB, from this
-- computer's decision log (GeneratorDecisions.jsonl, Modules/GeneratorKnowledge)
-- or from test generations (bench/train_model.lua). For each kind of choice
-- the generator measures one candidate at a time - support gems for the main
-- link, passives of a full tree scan, uniques of a slot scan - and for each
-- candidate: a logistic regression on the main skill's gem tags and skill
-- types, the skill itself and the build's situation, giving the chance it
-- helps; and the candidates that never helped each skill in two builds or
-- more. A candidate is skipped only when both agree. Each kind is checked
-- before it is used: the builds are split in five groups (twice,
-- differently), each group left out in turn, and the skip threshold kept is
-- the highest at which no left-out pick would have lost more than that kind's
-- "matters" (the best candidate skipped against the best one still measured),
-- less one step of margin; none: that kind is only ranked, nothing skipped.
-- The result goes to the user folder's GeneratorModel.json, which the
-- generator reads before the one shipped in Data/ when it learnt from more.
-- Run again by the window after every 10 new generations, in the background
-- (tick() is called often so the caller can yield).
--
local dkjson = require "dkjson"
local m_max = math.max
local M = { }

-- Per kind: a gain above "helps" counts as helping; a skip that loses more
-- than "matters" is a miss. Passives are measured per passive point
local KINDS = {
	support = { helps = 0.002, matters = 0.02, line = '"k":"support"' },
	passive = { helps = 0.0005, matters = 0.005, line = '"k":"passive_scan"' },
	unique = { helps = 0.002, matters = 0.02, line = '"k":"unique_scan"' },
}
M.kinds = KINDS
local KIND_ORDER = { "support", "passive", "unique" }
local THRESHOLDS = { 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1 }
local MIN_SEEN = 30
local FOLDS = 5
local ITERATIONS = 150
local RATE, L2 = 0.5, 1
local FAMILIAR_RUNS = 2
local MIN_CHECKED = 500 -- (skips seen in the check before a threshold counts as safe)

function M.ModelPath()
	return (main and main.userPath or "") .. "GeneratorModel.json"
end

-- Features of each active gem by name: tags and "t:<skill type>"
local function gemFeatures()
	local typeNames = { }
	for name, id in pairs(SkillType or { }) do typeNames[id] = name end
	local byName = { }
	for _, gem in pairs(data.gems) do
		local effect = gem.grantedEffect
		if effect and not effect.support and not byName[gem.name] then
			local f = { }
			for tag in pairs(gem.tags or { }) do f[#f + 1] = tag end
			for id in pairs(effect.skillTypes or { }) do if typeNames[id] then f[#f + 1] = "t:" .. typeNames[id] end end
			byName[gem.name] = f
		end
	end
	return byName
end

-- Measurements from the decision log, by kind: { support = { rows }, passive
-- = ..., unique = ... }; each row { name, gain, skill, feats, run, hasContext,
-- step } (step: the pick or scan it was measured in)
function M.ReadRows(path, tick)
	local byKind = { support = { }, passive = { }, unique = { } }
	local runs, runCount = { }, 0
	M.pairs = { }
	M.hasContext = false
	-- (one log, or several: a list of paths)
	local paths = type(path) == "table" and path or { path or LoadModule("Modules/GeneratorKnowledge").DecisionsPath() }
	local features = gemFeatures()
	local contexts, featCache = { }, { }
	-- (the build's situation at that choice: "c:" features; the skill itself:
	-- "s:"; one list shared by every candidate measured at that choice)
	local function featsFor(skill, run, cx, extra)
		local ctxKey = cx and (run .. "#" .. cx)
		local ctx = ctxKey and contexts[ctxKey]
		local featKey = skill .. "|" .. (ctx and ctxKey or "") .. "|" .. (extra or "")
		local feats = featCache[featKey]
		if not feats then
			feats = { }
			for _, x in ipairs(features[skill]) do feats[#feats + 1] = x end
			for _, c in ipairs(ctx or { }) do feats[#feats + 1] = "c:" .. c end
			if extra then feats[#feats + 1] = "c:" .. extra end
			feats[#feats + 1] = "s:" .. skill
			featCache[featKey] = feats
		end
		if ctx then M.hasContext = true end
		return feats, ctx ~= nil
	end
	local n = 0
	for _, onePath in ipairs(paths) do
	local f = io.open(onePath, "r")
	if f then
	for line in f:lines() do
		n = n + 1
		if n % 2000 == 0 and tick then tick() end
		-- (only the lines that matter are decoded)
		if line:find('"type":"run"', 1, true) then
			local ok, r = pcall(dkjson.decode, line)
			if ok and r and r.id then runs[r.id] = r.skill runCount = runCount + 1 end
		elseif line:find('"k":"support_ctx"', 1, true) then
			local ok, r = pcall(dkjson.decode, line)
			if ok and r and r.run and r.cx then contexts[r.run .. "#" .. r.cx] = r.f end
		elseif line:find('"k":"unique_pair"', 1, true) then
			-- (unique pairs: the synergy measured, by the two names in order)
			local ok, r = pcall(dkjson.decode, line)
			if ok and r and r.n and r.syn then
				local a, b = r.n:match("^(.-) %+ (.+)$")
				if a then
					if b < a then a, b = b, a end
					local key = a .. " + " .. b
					local e = M.pairs[key] or { n = 0, syn = 0 }
					e.n = e.n + 1
					e.syn = e.syn + r.syn
					M.pairs[key] = e
				end
			end
		elseif line:find(KINDS.support.line, 1, true) then
			local ok, r = pcall(dkjson.decode, line)
			local skill = ok and r and runs[r.run]
			if skill and r.g and features[skill] then
				local feats, hasContext = featsFor(skill, r.run, r.cx)
				local rows = byKind.support
				rows[#rows + 1] = { name = r.n, gain = r.g, skill = skill, feats = feats, run = r.run, hasContext = hasContext,
					step = r.cx and (r.run .. "#" .. r.cx .. "#" .. (r.pick or 0)) or nil }
			end
		elseif line:find(KINDS.passive.line, 1, true) then
			-- (a full tree scan: every passive's gain per point)
			local ok, r = pcall(dkjson.decode, line)
			local skill = ok and r and runs[r.run]
			if skill and features[skill] and type(r.ids) == "table" and type(r.v) == "table" then
				local feats, hasContext = featsFor(skill, r.run, r.cx, r.asc and "asc" or nil)
				local rows, step = byKind.passive, r.run .. "#p" .. n
				for i, id in ipairs(r.ids) do
					if r.v[i] then rows[#rows + 1] = { name = tostring(id), gain = r.v[i], skill = skill, feats = feats, run = r.run, hasContext = hasContext, step = step } end
				end
			end
		elseif line:find(KINDS.unique.line, 1, true) then
			-- (a slot scan: every unique's gain net of its price)
			local ok, r = pcall(dkjson.decode, line)
			local skill = ok and r and runs[r.run]
			if skill and features[skill] and type(r.names) == "table" and type(r.g) == "table" then
				local feats, hasContext = featsFor(skill, r.run, r.cx, r.slot and ("slot:" .. r.slot) or nil)
				local rows, step = byKind.unique, r.run .. "#u" .. n
				for i, name in ipairs(r.names) do
					if r.g[i] then rows[#rows + 1] = { name = name, gain = r.g[i], skill = skill, feats = feats, run = r.run, hasContext = hasContext, step = step } end
				end
			end
		end
	end
	f:close()
	end
	end
	return byKind, runCount
end

-- One logistic regression per candidate: { [name] = { n, bias, w = { [feature] = weight }, helped } }
local function train(rows, tick, helps)
	local byName = { }
	for _, r in ipairs(rows) do
		local list = byName[r.name]
		if not list then list = { } byName[r.name] = list end
		list[#list + 1] = r
	end
	local model = { }
	for name, list in pairs(byName) do
		local w, bias = { }, 0
		local n = #list
		for _ = 1, ITERATIONS do
			local gradB, gradW = 0, { }
			for _, r in ipairs(list) do
				local z = bias
				for _, f in ipairs(r.feats) do z = z + (w[f] or 0) end
				local p = 1 / (1 + math.exp(-z))
				local err = p - (r.gain > helps and 1 or 0)
				gradB = gradB + err
				for _, f in ipairs(r.feats) do gradW[f] = (gradW[f] or 0) + err end
			end
			bias = bias - RATE * gradB / n
			for f, g in pairs(gradW) do w[f] = (w[f] or 0) - RATE * (g + L2 * (w[f] or 0)) / n end
			if tick then tick() end
		end
		local helped = 0
		for _, r in ipairs(list) do if r.gain > helps then helped = helped + 1 end end
		local weights = { }
		for f, v in pairs(w) do if math.abs(v) > 1e-3 then weights[f] = math.floor(v * 1e4 + 0.5) / 1e4 end end
		model[name] = { n = n, bias = math.floor(bias * 1e4 + 0.5) / 1e4, w = weights, helped = helped }
	end
	return model
end

local function chance(entry, feats)
	local z = entry.bias
	for _, f in ipairs(feats) do z = z + (entry.w[f] or 0) end
	return 1 / (1 + math.exp(-z))
end

-- Skills seen in how many builds: { [skill] = builds }
local function familiarSkills(rows)
	local runs, out = { }, { }
	for _, r in ipairs(rows) do
		runs[r.skill] = runs[r.skill] or { }
		runs[r.skill][r.run or "?"] = true
	end
	for skill, set in pairs(runs) do
		local n = 0
		for _ in pairs(set) do n = n + 1 end
		out[skill] = n
	end
	return out
end

-- Candidates measured for a skill in two builds or more and that never
-- helped it: { [skill] = { [name] = true } }. The model only skips a
-- candidate when this history agrees: a model alone misses the ones whose use
-- depends on the build's situation (Lifetap when mana is short...), a history
-- alone too; both together missed nothing in the checks
local function uselessPairs(rows, helps)
	local seen = { }
	for _, r in ipairs(rows) do
		local bySkill = seen[r.skill]
		if not bySkill then bySkill = { } seen[r.skill] = bySkill end
		local e = bySkill[r.name]
		if not e then e = { runs = { }, count = 0, best = -1e9 } bySkill[r.name] = e end
		if not e.runs[r.run or "?"] then e.runs[r.run or "?"] = true e.count = e.count + 1 end
		if r.gain > e.best then e.best = r.gain end
	end
	local out = { }
	for skill, bySkill in pairs(seen) do
		for name, e in pairs(bySkill) do
			if e.count >= FAMILIAR_RUNS and e.best <= helps then
				out[skill] = out[skill] or { }
				out[skill][name] = true
			end
		end
	end
	return out
end

-- Builds split in groups, each left out in turn (a new build of a skill the
-- model knows, as when a player generates one; only skills seen in two
-- builds of the training part are skipped for): per threshold, how many
-- measurements would be skipped and how many picks would have lost more than
-- "matters"
function M.Validate(rows, tick, repeats, cfg)
	cfg = cfg or KINDS.support
	local runIds, index = { }, { }
	for _, r in ipairs(rows) do
		local id = r.run or "?"
		if not index[id] then index[id] = true runIds[#runIds + 1] = id end
	end
	table.sort(runIds)
	local stats = { }
	for _, t in ipairs(THRESHOLDS) do stats[t] = { skipped = 0, missed = 0 } end
	-- (several splits of the builds: a threshold must be safe in all of them)
	for rep = 1, repeats or 2 do
	local fold = { }
	local rng = rep * 7919
	for i, id in ipairs(runIds) do
		rng = (rng * 1103515245 + 12345) % 2147483648
		fold[id] = rep == 1 and i % FOLDS or rng % FOLDS
	end
	for k = 0, FOLDS - 1 do
		local trainRows, testRows = { }, { }
		for _, r in ipairs(rows) do
			if fold[r.run or "?"] == k then testRows[#testRows + 1] = r else trainRows[#trainRows + 1] = r end
		end
		if #trainRows > 0 and #testRows > 0 then
			-- (each round's tables freed before the next: over a million measurements)
			collectgarbage("collect")
			local model = train(trainRows, tick, cfg.helps)
			local familiar = familiarSkills(trainRows)
			local useless = uselessPairs(trainRows, cfg.helps)
			-- Each logged pick or scan measured every candidate and kept the
			-- best: a skip only costs something when the best candidate it hid
			-- beats the best one still measured (or nothing, when none of those
			-- helps) by more than "matters"
			local steps, order = { }, { }
			for _, r in ipairs(testRows) do
				-- (checked as used: the generator always gives the build's
				-- situation, so measurements logged before it was recorded are
				-- only trained on)
				if r.hasContext or not M.hasContext then
					local key = r.step or tostring(r)
					local step = steps[key]
					if not step then step = { } steps[key] = step order[#order + 1] = key end
					local e = model[r.name]
					local p = 1
					if e and e.n >= MIN_SEEN and (familiar[r.skill] or 0) >= FAMILIAR_RUNS and useless[r.skill] and useless[r.skill][r.name] then
						p = chance(e, r.feats)
					end
					step[#step + 1] = { r = r, p = p }
				end
			end
			for _, key in ipairs(order) do
				local step = steps[key]
				for _, t in ipairs(THRESHOLDS) do
					local bestKept, bestSkipped = 0, nil
					for _, m in ipairs(step) do
						if m.p < t then
							stats[t].skipped = stats[t].skipped + 1
							if not bestSkipped or m.r.gain > bestSkipped.r.gain then bestSkipped = m end
						elseif m.r.gain > bestKept then
							bestKept = m.r.gain
						end
					end
					if bestSkipped and bestSkipped.r.gain - bestKept > cfg.matters then
						local r = bestSkipped.r
						stats[t].missed = stats[t].missed + 1
						stats[t].worst = stats[t].worst or { }
						if #stats[t].worst < 20 then
							local ctx = { }
							for _, f in ipairs(r.feats) do if f:sub(1, 2) == "c:" then ctx[#ctx + 1] = f:sub(3) end end
							table.insert(stats[t].worst, string.format("%s for %s %+.4f over the best measured %+.4f (p %.4f; %s)", r.name, r.skill, r.gain, bestKept, bestSkipped.p, table.concat(ctx, " ")))
						end
					end
				end
			end
		end
	end
	end
	local skills = 0
	for _ in pairs(familiarSkills(rows)) do skills = skills + 1 end
	-- (skipped counts are summed over the splits: per split, divide by repeats)
	return stats, skills
end

-- One kind trained and checked: its section of the model file
local function trainKind(rows, tick, cfg, field)
	local stats, skills = M.Validate(rows, tick, 2, cfg)
	-- (the highest safe threshold, less one step of margin when there is one;
	-- safe means no miss among enough skips checked, not nothing skipped)
	local chosen, safe = 0, 0
	for i, t in ipairs(THRESHOLDS) do
		if stats[t].missed == 0 and stats[t].skipped >= MIN_CHECKED then safe = i
		elseif stats[t].missed > 0 then break end
	end
	if safe > 0 then chosen = THRESHOLDS[m_max(1, safe - 1)] end
	collectgarbage("collect")
	local model = train(rows, tick, cfg.helps)
	-- (the history, as lists of candidate names per skill)
	local useless = { }
	for skill, set in pairs(uselessPairs(rows, cfg.helps)) do
		local list = { }
		for name in pairs(set) do list[#list + 1] = name end
		table.sort(list)
		useless[skill] = list
	end
	local section = { skipBelow = chosen, minSeen = MIN_SEEN, helps = cfg.helps, historyRule = true, useless = useless,
		familiarRuns = FAMILIAR_RUNS, familiar = familiarSkills(rows), skills = skills, measurements = #rows, validation = { } }
	section[field or "support"] = model
	for _, t in ipairs(THRESHOLDS) do section.validation[tostring(t)] = stats[t] end
	return section, stats, chosen
end

-- Trains and writes the model; returns it and a summary line
function M.Run(tick, logPath, outPath)
	local byKind, runs = M.ReadRows(logPath, tick)
	local supportRows = byKind.support
	if #supportRows < 1000 then return nil, string.format("not enough decisions yet (%d support measurements)", #supportRows) end
	-- supports: the model file's top level (as read by Modules/GeneratorModel)
	byKind.support = nil
	local out, stats, chosen = trainKind(supportRows, tick, KINDS.support)
	out.version = 6
	out.typeFeatures = true
	out.contextFeatures = M.hasContext or false
	out.skillFeatures = true
	out.runs = runs
	out.trainedAt = os.time()
	local skills, measurements = out.skills, #supportRows
	supportRows = nil
	-- passives and uniques: their own sections, once there are enough of them
	out.kinds = { }
	local parts = { }
	for _, kind in ipairs(KIND_ORDER) do
		local rows = byKind[kind]
		if kind ~= "support" and rows and #rows >= 1000 then
			byKind[kind] = nil
			local section, _, kindChosen = trainKind(rows, tick, KINDS[kind], "candidates")
			out.kinds[kind] = section
			table.insert(parts, string.format("%s: %d measurements, %s", kind, #rows, kindChosen > 0 and string.format("skipped below %.1f%%", kindChosen * 100) or "only ranked"))
			rows = nil
			collectgarbage("collect")
		end
	end
	-- unique pairs: their mean synergy (ranks the pairs worth a calculation: UniqueComboFinder)
	out.pairs = { }
	for key, e in pairs(M.pairs or { }) do out.pairs[key] = { n = e.n, syn = math.floor(e.syn / e.n * 1e4 + 0.5) / 1e4 } end
	local f = io.open(outPath or M.ModelPath(), "w")
	if f then f:write(dkjson.encode(out)) f:close() end
	return out, string.format("Candidate model trained on %d support measurements from %d skills: %s%s", measurements, skills,
		chosen > 0 and string.format("supports below %.1f%% chance are skipped (%d%% of the measurements in the check, none that mattered in two splits of the builds)", chosen * 100, math.floor(100 * stats[chosen].skipped / 2 / measurements + 0.5))
			or "no skip threshold was safe yet, so it only ranks",
		#parts > 0 and ("; " .. table.concat(parts, "; ")) or "")
end

-- Should the window train again? (10 more generations in the log since the last training)
function M.Due()
	local know = LoadModule("Modules/GeneratorKnowledge")
	local f = io.open(know.DecisionsPath(), "r")
	if not f then return false end
	local runs = 0
	for line in f:lines() do if line:find('"type":"run"', 1, true) then runs = runs + 1 end end
	f:close()
	local mf = io.open(M.ModelPath(), "r")
	local last = 0
	if mf then
		local ok, m = pcall(dkjson.decode, mf:read("*a"))
		mf:close()
		if ok and m and m.runs then last = m.runs end
	end
	return runs >= last + 10 and runs >= 20
end

return M
