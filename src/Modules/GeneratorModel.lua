-- Path of Building
--
-- Module: Generator Model
-- The candidate model trained from the generator's decision logs
-- (bench/train_model.py -> Data/GeneratorModel.json): for each support gem,
-- the chance that it helps a main skill with given gem tags and skill types
-- (a logistic regression), and the supports that never helped each skill in
-- two builds or more. The generator skips a support only when both agree
-- (chance below "skipBelow", seen at least "minSeen" times, a skill seen in
-- "familiarRuns" builds), so the calculations go to the ones that can help.
-- PoB's calculator still decides between the supports that are tried. The
-- trainer only sets a threshold when, leaving builds out in turn, nothing
-- worth more than 0.02 score would have been skipped.
--
local dkjson = require "dkjson"
local M = { }

function M.Load(force)
	if M.loaded and not force then return M.model end
	M.model, M.featureCache, M.uselessSets, M.kindUseless = nil, nil, nil, nil
	M.loaded = true
	local base = (GetScriptPath and GetScriptPath() or ".") .. "/Data/GeneratorModel.json"
	-- (the one trained on this computer, Modules/GeneratorModelTrainer, or
	-- the shipped one: whichever learnt from more measurements)
	local own = (main and main.userPath or "") .. "GeneratorModel.json"
	for _, path in ipairs({ own, base, "Data/GeneratorModel.json" }) do
		local f = io.open(path, "r")
		if f then
			local ok, value = pcall(dkjson.decode, f:read("*a"))
			f:close()
			if ok and type(value) == "table" and value.support then
				if not M.model or (value.measurements or 0) > (M.model.measurements or 0) then M.model = value end
			end
		end
	end
	return M.model
end

-- The features of a main skill gem: its tags, and its skill types as "t:<name>"
local typeNames
function M.Features(gem)
	local feats = { }
	for tag in pairs(gem and gem.tags or { }) do feats[tag] = true end
	if not typeNames then
		typeNames = { }
		for name, id in pairs(SkillType or { }) do typeNames[id] = name end
	end
	for id in pairs(gem and gem.grantedEffect and gem.grantedEffect.skillTypes or { }) do
		if typeNames[id] then feats["t:" .. typeNames[id]] = true end
	end
	return feats
end

-- Chance that a support helps a skill with these features (M.Features), and
-- how many measurements it is based on; nil when the model doesn't know it
function M.SupportChance(name, feats)
	local model = M.Load()
	local entry = model and model.support[name]
	if not entry then return nil end
	local z = entry.bias or 0
	for f in pairs(feats or { }) do z = z + (entry.w[f] or 0) end
	return 1 / (1 + math.exp(-z)), entry.n or 0
end

-- Should the generator skip this support for this main skill gem? (never when
-- the trainer found no safe threshold: skipBelow 0)
function M.SkipSupport(name, gem, context)
	local model = M.Load()
	if not model or (model.skipBelow or 0) <= 0 then return false end
	M.featureCache = M.featureCache or { }
	local feats = M.featureCache[gem]
	if not feats then feats = M.Features(gem) M.featureCache[gem] = feats end
	-- (only for skills the model has seen in enough builds: what a support
	-- does for a skill it never saw can't be trusted)
	if model.familiar then
		if not gem or (model.familiar[gem.name] or 0) < (model.familiarRuns or 2) then return false end
	end
	-- (the build's situation: BuildGenerator:SupportContext, "c:" features; the skill: "s:")
	if (context and model.contextFeatures) or model.skillFeatures then
		local all = { }
		for k in pairs(feats) do all[k] = true end
		if context and model.contextFeatures then
			for _, c in ipairs(context) do all["c:" .. c] = true end
		end
		if model.skillFeatures and gem then all["s:" .. gem.name] = true end
		feats = all
	end
	-- (and only supports that never helped this skill in two builds or more:
	-- the model alone misses supports whose use depends on the situation)
	if model.historyRule then
		if not M.uselessSets then
			M.uselessSets = { }
			for skill, list in pairs(model.useless or { }) do
				local set = { }
				for _, n in ipairs(list) do set[n] = true end
				M.uselessSets[skill] = set
			end
		end
		local set = gem and M.uselessSets[gem.name]
		if not set or not set[name] then return false end
	end
	local p, n = M.SupportChance(name, feats)
	return p ~= nil and n >= (model.minSeen or 30) and p < model.skipBelow
end

-- Should the generator skip this candidate of another kind ("passive": a
-- passive node key from a full tree scan, "unique": a unique's name in a slot
-- scan) for this main skill gem? Same rules as supports, from that kind's
-- section of the model (Modules/GeneratorModelTrainer); extra: one more
-- situation feature ("asc", "slot:Ring 1"...). Never when the trainer found
-- no safe threshold for that kind
function M.SkipCandidate(kind, name, gem, context, extra)
	local model = M.Load()
	local section = model and model.kinds and model.kinds[kind]
	if not section or (section.skipBelow or 0) <= 0 or not gem then return false end
	if (section.familiar and section.familiar[gem.name] or 0) < (section.familiarRuns or 2) then return false end
	-- (only candidates that never helped this skill in two builds or more)
	M.kindUseless = M.kindUseless or { }
	local sets = M.kindUseless[kind]
	if not sets then
		sets = { }
		for skill, list in pairs(section.useless or { }) do
			local set = { }
			for _, n in ipairs(list) do set[n] = true end
			sets[skill] = set
		end
		M.kindUseless[kind] = sets
	end
	local set = sets[gem.name]
	if not set or not set[name] then return false end
	local entry = section.candidates and section.candidates[name]
	if not entry or (entry.n or 0) < (section.minSeen or 30) then return false end
	M.featureCache = M.featureCache or { }
	local base = M.featureCache[gem]
	if not base then base = M.Features(gem) M.featureCache[gem] = base end
	local z = entry.bias or 0
	for f in pairs(base) do z = z + (entry.w[f] or 0) end
	for _, c in ipairs(context or { }) do z = z + (entry.w["c:" .. c] or 0) end
	if extra then z = z + (entry.w["c:" .. extra] or 0) end
	z = z + (entry.w["s:" .. gem.name] or 0)
	return 1 / (1 + math.exp(-z)) < section.skipBelow
end

-- Mean synergy measured for a pair of uniques (names in either order), and
-- how many times; nil when never measured
function M.PairSynergy(a, b)
	local model = M.Load()
	if not model or not model.pairs or not a or not b then return nil end
	if b < a then a, b = b, a end
	local e = model.pairs[a .. " + " .. b]
	if e then return e.syn, e.n end
	return nil
end

return M
