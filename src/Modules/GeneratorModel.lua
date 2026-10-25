-- Path of Building
--
-- Module: Generator Model
-- The candidate model trained from the generator's decision logs
-- (bench/train_model.py -> Data/GeneratorModel.json): for each support gem,
-- the chance that it helps a main skill with given gem tags and skill types
-- (a logistic regression). The generator skips the supports the model is
-- sure can't help (below "skipBelow", seen at least "minSeen" times), so the
-- calculations go to the ones that can. PoB's calculator still decides
-- between the supports that are tried. The trainer only sets a threshold
-- when, leaving each skill out in turn, nothing worth more than 0.02 score
-- would have been skipped: with the first 56 skills it found none (Lifetap,
-- trigger supports, minion supports surprise), so nothing is skipped yet.
--
local dkjson = require "dkjson"
local M = { }

function M.Load(force)
	if M.loaded and not force then return M.model end
	M.model, M.featureCache = nil, nil
	M.loaded = true
	local base = (GetScriptPath and GetScriptPath() or ".") .. "/Data/GeneratorModel.json"
	-- (the one trained on this computer first: Modules/GeneratorModelTrainer)
	local own = (main and main.userPath or "") .. "GeneratorModel.json"
	for _, path in ipairs({ own, base, "Data/GeneratorModel.json" }) do
		local f = io.open(path, "r")
		if f then
			local ok, value = pcall(dkjson.decode, f:read("*a"))
			f:close()
			if ok and type(value) == "table" and value.support then M.model = value break end
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
	local p, n = M.SupportChance(name, feats)
	return p ~= nil and n >= (model.minSeen or 30) and p < model.skipBelow
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
