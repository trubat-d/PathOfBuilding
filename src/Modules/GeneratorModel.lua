-- Path of Building
--
-- Module: Generator Model
-- The candidate model trained from the generator's decision logs
-- (bench/train_model.py -> Data/GeneratorModel.json): for each support gem,
-- the chance that it helps a main skill with given gem tags (a logistic
-- regression on the tags). The generator skips the supports the model is
-- sure can't help (below "skipBelow", seen at least "minSeen" times), so the
-- calculations go to the ones that can. PoB's calculator still decides
-- between the supports that are tried.
--
local dkjson = require "dkjson"
local M = { }

function M.Load()
	if M.loaded then return M.model end
	M.loaded = true
	local base = (GetScriptPath and GetScriptPath() or ".") .. "/Data/GeneratorModel.json"
	for _, path in ipairs({ base, "Data/GeneratorModel.json" }) do
		local f = io.open(path, "r")
		if f then
			local ok, value = pcall(dkjson.decode, f:read("*a"))
			f:close()
			if ok and type(value) == "table" and value.support then M.model = value break end
		end
	end
	return M.model
end

-- Chance that a support helps a skill with these tags ({ [tag] = true }), and
-- how many measurements it is based on; nil when the model doesn't know it
function M.SupportChance(name, tags)
	local model = M.Load()
	local entry = model and model.support[name]
	if not entry then return nil end
	local z = entry.bias or 0
	for tag in pairs(tags or { }) do z = z + (entry.w[tag] or 0) end
	return 1 / (1 + math.exp(-z)), entry.n or 0
end

-- Should the generator skip this support for a skill with these tags?
function M.SkipSupport(name, tags)
	local model = M.Load()
	if not model then return false end
	local p, n = M.SupportChance(name, tags)
	return p ~= nil and n >= (model.minSeen or 30) and p < (model.skipBelow or 0.01)
end

return M
