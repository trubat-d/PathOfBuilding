-- Path of Building
--
-- Module: Generator Learning
-- What the generator has learnt about its own choices, to make the next ones
-- better. A quick build ranks archetypes by how they start, but some end much
-- higher than they start (mines, physical weapons) and others less (stat
-- stacking): the full build's gain over the quick build is learnt per
-- archetype, from the benchmark (Data/GeneratorPriors.json) and from every
-- automatic generation on this computer (GeneratorLearning.json in the user
-- folder). Archetypes are then fully built in the order of their predicted
-- full score, plus a bonus for the ones tried least (so new ideas, like the
-- mined ones, get their chance: an upper confidence bound, as bandit
-- algorithms do).
--
local dkjson = require "dkjson"
local M = { }

local shrink = 2 -- (the global gain counts like this many builds)
local exploration = 0.35

local function readJson(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	local ok, value = pcall(dkjson.decode, text)
	return ok and value or nil
end

local function learningPath()
	return (main and main.userPath or "") .. "GeneratorLearning.json"
end

function M.Load()
	if M.loaded then return end
	M.loaded = true
	local base = (GetScriptPath and GetScriptPath() or ".") .. "/Data/GeneratorPriors.json"
	M.priors = readJson(base) or readJson("Data/GeneratorPriors.json") or { globalUplift = 2.8, upliftSpread = 0.8, archetypes = { } }
	M.learnt = readJson(learningPath()) or { records = { } }
	M.learnt.records = M.learnt.records or { }
end

-- A full build of an archetype finished: what its quick build scored and
-- what the full one did (same focus and investment)
-- context (optional): { kind = "attack" / "spell" / "minion", investment = level id }
function M.Record(archetypeId, skill, quick, full, context)
	M.Load()
	if not (archetypeId and quick and full) then return end
	local t = M.learnt.records
	context = context or { }
	t[#t + 1] = { archetype = archetypeId, skill = skill, uplift = full - quick, time = os.time(), kind = context.kind, investment = context.investment }
	while #t > 2000 do table.remove(t, 1) end
	local f = io.open(learningPath(), "w")
	if f then
		f:write(dkjson.encode(M.learnt))
		f:close()
	end
end

-- Predicted gain of a full build over its quick build: mean, number of builds
-- behind it. With a context, the builds of the same kind of skill (attack,
-- spell, minion) and investment level count more: their mean is shrunk to
-- the archetype's (a hierarchical average: the archetype's own mean is
-- shrunk to the global one the same way)
function M.Uplift(archetypeId, context)
	M.Load()
	local global = M.priors.globalUplift or 2.8
	local prior = M.priors.archetypes and M.priors.archetypes[archetypeId]
	local sum, n = 0, 0
	if prior then sum, n = prior.uplift * prior.count, prior.count end
	for _, r in ipairs(M.learnt.records) do
		if r.archetype == archetypeId then sum, n = sum + r.uplift, n + 1 end
	end
	local archetypeMean = (sum + global * shrink) / (n + shrink)
	if not context then return archetypeMean, n end
	local cs, cn = 0, 0
	for _, r in ipairs(M.learnt.records) do
		if r.archetype == archetypeId and (not context.kind or r.kind == context.kind) and (not context.investment or r.investment == context.investment) then
			cs, cn = cs + r.uplift, cn + 1
		end
	end
	return (cs + archetypeMean * shrink) / (cn + shrink), n
end

-- Value used to choose which archetypes to build fully: predicted full
-- score plus a bonus for little-known archetypes
function M.Priority(archetypeId, quickScore, context)
	local uplift, n = M.Uplift(archetypeId, context)
	local spread = M.priors.upliftSpread or 0.8
	return quickScore + uplift + exploration * spread / math.sqrt(n + 1), uplift, n
end

return M
