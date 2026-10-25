-- Path of Building
--
-- Module: Generator Model Trainer
-- Trains the candidate model (Modules/GeneratorModel) inside PoB, from this
-- computer's decision log (GeneratorDecisions.jsonl, Modules/GeneratorKnowledge),
-- the way bench/train_model.py does: for each support gem, a logistic
-- regression on the main skill's gem tags and skill types giving the chance
-- it helps. It is checked before it is used: the skills are split in five
-- groups, each group left out in turn, and the skip threshold kept is the
-- highest at which no left-out support worth more than 0.02 score would have
-- been skipped (none: the model only ranks, skipping nothing). The result
-- goes to the user folder's GeneratorModel.json, which the generator reads
-- before the one shipped in Data/.
-- Run again by the window after every 10 new generations, in the background
-- (tick() is called often so the caller can yield).
--
local dkjson = require "dkjson"
local M = { }

local HELPS = 0.002
local MATTERS = 0.02
local THRESHOLDS = { 0.001, 0.002, 0.005, 0.01, 0.02 }
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
	local f = io.open(path or LoadModule("Modules/GeneratorKnowledge").DecisionsPath(), "r")
	if not f then return rows, 0 end
	local features = gemFeatures()
	local contexts = { }
	local n = 0
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
				local feats = features[skill]
				-- (the build's situation at that choice: "c:" features)
				local ctx = r.cx and contexts[r.run .. "#" .. r.cx]
				if ctx then
					feats = { }
					for _, x in ipairs(features[skill]) do feats[#feats + 1] = x end
					for _, c in ipairs(ctx) do feats[#feats + 1] = "c:" .. c end
					M.hasContext = true
				end
				rows[#rows + 1] = { name = r.n, gain = r.g, skill = skill, feats = feats }
			end
		end
	end
	f:close()
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

-- Skills split in groups, each left out in turn: per threshold, how many
-- measurements would be skipped and how many of them mattered
function M.Validate(rows, tick)
	local skills, index = { }, { }
	for _, r in ipairs(rows) do if not index[r.skill] then index[r.skill] = true skills[#skills + 1] = r.skill end end
	table.sort(skills)
	local fold = { }
	for i, s in ipairs(skills) do fold[s] = i % FOLDS end
	local stats = { }
	for _, t in ipairs(THRESHOLDS) do stats[t] = { skipped = 0, missed = 0 } end
	for k = 0, FOLDS - 1 do
		local trainRows, testRows = { }, { }
		for _, r in ipairs(rows) do
			if fold[r.skill] == k then testRows[#testRows + 1] = r else trainRows[#trainRows + 1] = r end
		end
		if #trainRows > 0 and #testRows > 0 then
			local model = train(trainRows, tick)
			for _, r in ipairs(testRows) do
				local e = model[r.name]
				if e and e.n >= MIN_SEEN then
					local p = chance(e, r.feats)
					for _, t in ipairs(THRESHOLDS) do
						if p < t then
							stats[t].skipped = stats[t].skipped + 1
							if r.gain > MATTERS then stats[t].missed = stats[t].missed + 1 end
						end
					end
				end
			end
		end
	end
	return stats, #skills
end

-- Trains and writes the model; returns a summary line
function M.Run(tick, logPath, outPath)
	local rows, runs = M.ReadRows(logPath, tick)
	if #rows < 1000 then return nil, string.format("not enough decisions yet (%d support measurements)", #rows) end
	local stats, skills = M.Validate(rows, tick)
	local chosen = 0
	for _, t in ipairs(THRESHOLDS) do if stats[t].missed == 0 then chosen = t end end
	local model = train(rows, tick)
	local out = { version = 3, helps = HELPS, skipBelow = chosen, minSeen = MIN_SEEN, typeFeatures = true, contextFeatures = M.hasContext or false, skills = skills, runs = runs,
		measurements = #rows, trainedAt = os.time(), validation = { }, support = model }
	for _, t in ipairs(THRESHOLDS) do out.validation[tostring(t)] = stats[t] end
	-- unique pairs: their mean synergy (ranks the pairs worth a calculation: UniqueComboFinder)
	out.pairs = { }
	for key, e in pairs(M.pairs or { }) do out.pairs[key] = { n = e.n, syn = math.floor(e.syn / e.n * 1e4 + 0.5) / 1e4 } end
	local f = io.open(outPath or M.ModelPath(), "w")
	if f then f:write(dkjson.encode(out)) f:close() end
	return out, string.format("Candidate model trained on %d support measurements from %d skills: %s", #rows, skills,
		chosen > 0 and string.format("supports below %.1f%% chance are skipped (%d%% of the measurements in the check, none that mattered)", chosen * 100, math.floor(100 * stats[chosen].skipped / #rows + 0.5))
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
