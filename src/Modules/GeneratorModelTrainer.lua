-- Path of Building
--
-- Module: Generator Model Trainer
-- Trains the candidate model (Modules/GeneratorModel) inside PoB, from this
-- computer's decision log (GeneratorDecisions.jsonl, Modules/GeneratorKnowledge),
-- the way bench/train_model.py does: for each support gem, a logistic
-- regression on the main skill's gem tags and skill types giving the chance
-- it helps, and the supports that never helped each skill in two builds or
-- more (a support is skipped only when both agree). It is checked before it
-- is used: the builds are split in five groups (twice, differently), each
-- group left out in turn, and the skip threshold kept is the highest at which
-- no left-out pick would have lost more than 0.02 score (the best support
-- skipped against the best one still tried; none: the model only ranks,
-- skipping nothing). The result goes to the user folder's GeneratorModel.json, which the generator reads
-- before the one shipped in Data/.
-- Run again by the window after every 10 new generations, in the background
-- (tick() is called often so the caller can yield).
--
local dkjson = require "dkjson"
local m_max = math.max
local M = { }

local HELPS = 0.002
local MATTERS = 0.02
local THRESHOLDS = { 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1 }
local MIN_SEEN = 30
local FOLDS = 5
local ITERATIONS = 150
local RATE, L2 = 0.5, 1

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

-- Support measurements from the decision log: { name, gain, skill, feats }
function M.ReadRows(path, tick)
	local rows, runs, runCount = { }, { }, 0
	M.pairs = { }
	M.hasContext = false
	-- (one log, or several: a list of paths)
	local paths = type(path) == "table" and path or { path or LoadModule("Modules/GeneratorKnowledge").DecisionsPath() }
	local features = gemFeatures()
	local contexts, featCache = { }, { }
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
		elseif line:find('"k":"support"', 1, true) then
			local ok, r = pcall(dkjson.decode, line)
			local skill = ok and r and runs[r.run]
			if skill and r.g and features[skill] then
				-- (the build's situation at that choice: "c:" features; the skill itself: "s:";
				-- one list shared by every support measured at that choice)
				local ctxKey = r.cx and (r.run .. "#" .. r.cx)
				local ctx = ctxKey and contexts[ctxKey]
				local featKey = skill .. "|" .. (ctx and ctxKey or "")
				local feats = featCache[featKey]
				if not feats then
					feats = { }
					for _, x in ipairs(features[skill]) do feats[#feats + 1] = x end
					for _, c in ipairs(ctx or { }) do feats[#feats + 1] = "c:" .. c end
					feats[#feats + 1] = "s:" .. skill
					featCache[featKey] = feats
				end
				if ctx then M.hasContext = true end
				local hasContext = ctx ~= nil
				rows[#rows + 1] = { name = r.n, gain = r.g, skill = skill, feats = feats, run = r.run, hasContext = hasContext, cx = r.cx, pick = r.pick }
			end
		end
	end
	f:close()
	end
	end
	return rows, runCount
end

-- One logistic regression per support: { [name] = { n, bias, w = { [feature] = weight } } }
local function train(rows, tick)
	local bySupport = { }
	for _, r in ipairs(rows) do
		local list = bySupport[r.name]
		if not list then list = { } bySupport[r.name] = list end
		list[#list + 1] = r
	end
	local model = { }
	for name, list in pairs(bySupport) do
		local w, bias = { }, 0
		local n = #list
		for _ = 1, ITERATIONS do
			local gradB, gradW = 0, { }
			for _, r in ipairs(list) do
				local z = bias
				for _, f in ipairs(r.feats) do z = z + (w[f] or 0) end
				local p = 1 / (1 + math.exp(-z))
				local err = p - (r.gain > HELPS and 1 or 0)
				gradB = gradB + err
				for _, f in ipairs(r.feats) do gradW[f] = (gradW[f] or 0) + err end
			end
			bias = bias - RATE * gradB / n
			for f, g in pairs(gradW) do w[f] = (w[f] or 0) - RATE * (g + L2 * (w[f] or 0)) / n end
			if tick then tick() end
		end
		local helped = 0
		for _, r in ipairs(list) do if r.gain > HELPS then helped = helped + 1 end end
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
local FAMILIAR_RUNS = 2
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

-- Supports measured for a skill in two builds or more and that never helped
-- it: { [skill] = { [support] = true } }. The model only skips a support when
-- this history agrees: a model alone misses the supports whose use depends on
-- the build's situation (Lifetap when mana is short...), a history alone too;
-- both together missed nothing in the checks (bench/train_model.py)
local function uselessPairs(rows)
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
			if e.count >= FAMILIAR_RUNS and e.best <= HELPS then
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
-- measurements would be skipped and how many of them mattered
function M.Validate(rows, tick, repeats)
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
			local model = train(trainRows, tick)
			local familiar = familiarSkills(trainRows)
			local useless = uselessPairs(trainRows)
			-- Each logged pick measured every candidate and kept the best: a
			-- skip only costs something when the best support it hid beats the
			-- best one still tried (or nothing, when none of those helps) by
			-- more than MATTERS. Later picks are logged as their own steps.
			local steps, order = { }, { }
			for _, r in ipairs(testRows) do
				-- (checked as used: the generator always gives the build's
				-- situation, so measurements logged before it was recorded are
				-- only trained on)
				if r.hasContext or not M.hasContext then
					local key = r.cx and (r.run .. "#" .. r.cx .. "#" .. (r.pick or 0)) or tostring(r)
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
					if bestSkipped and bestSkipped.r.gain - bestKept > MATTERS then
						local r = bestSkipped.r
						stats[t].missed = stats[t].missed + 1
						stats[t].worst = stats[t].worst or { }
						if #stats[t].worst < 20 then
							local ctx = { }
							for _, f in ipairs(r.feats) do if f:sub(1, 2) == "c:" then ctx[#ctx + 1] = f:sub(3) end end
							table.insert(stats[t].worst, string.format("%s for %s %+.3f over the best tried %+.3f (p %.4f; %s)", r.name, r.skill, r.gain, bestKept, bestSkipped.p, table.concat(ctx, " ")))
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

-- Trains and writes the model; returns a summary line
function M.Run(tick, logPath, outPath)
	local rows, runs = M.ReadRows(logPath, tick)
	if #rows < 1000 then return nil, string.format("not enough decisions yet (%d support measurements)", #rows) end
	local stats, skills = M.Validate(rows, tick)
	-- (the highest safe threshold, less one step of margin when there is one)
	local chosen, safe = 0, 0
	for i, t in ipairs(THRESHOLDS) do
		if stats[t].missed == 0 then safe = i else break end
	end
	if safe > 0 then chosen = THRESHOLDS[m_max(1, safe - 1)] end
	local model = train(rows, tick)
	-- (the history, as lists of support names per skill)
	local useless = { }
	for skill, set in pairs(uselessPairs(rows)) do
		local list = { }
		for name in pairs(set) do list[#list + 1] = name end
		table.sort(list)
		useless[skill] = list
	end
	local out = { version = 5, historyRule = true, useless = useless, helps = HELPS, skipBelow = chosen, minSeen = MIN_SEEN, typeFeatures = true, contextFeatures = M.hasContext or false,
		skillFeatures = true, familiarRuns = FAMILIAR_RUNS, familiar = familiarSkills(rows), skills = skills, runs = runs,
		measurements = #rows, trainedAt = os.time(), validation = { }, support = model }
	for _, t in ipairs(THRESHOLDS) do out.validation[tostring(t)] = stats[t] end
	-- unique pairs: their mean synergy (ranks the pairs worth a calculation: UniqueComboFinder)
	out.pairs = { }
	for key, e in pairs(M.pairs or { }) do out.pairs[key] = { n = e.n, syn = math.floor(e.syn / e.n * 1e4 + 0.5) / 1e4 } end
	local f = io.open(outPath or M.ModelPath(), "w")
	if f then f:write(dkjson.encode(out)) f:close() end
	return out, string.format("Candidate model trained on %d support measurements from %d skills: %s", #rows, skills,
		chosen > 0 and string.format("supports below %.1f%% chance are skipped (%d%% of the measurements in the check, none that mattered in two splits of the builds)", chosen * 100, math.floor(100 * stats[chosen].skipped / 2 / #rows + 0.5))
			or "no skip threshold was safe yet, so it only ranks")
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
