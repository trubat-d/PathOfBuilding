-- Trains the candidate model with PoB's own trainer (Modules/GeneratorModelTrainer)
-- from decision logs, as shipped in Data/GeneratorModel.json (support model,
-- unique pair synergies, familiar skills).
-- From the src folder: LOGS="a.jsonl;b.jsonl" OUT=Data/GeneratorModel.json luajit ../bench/train_model.lua
io.stdout:setvbuf("no")
dofile("HeadlessWrapper.lua")
local T = LoadModule("Modules/GeneratorModelTrainer")
local paths = { }
for p in (os.getenv("LOGS") or ""):gmatch("[^;]+") do paths[#paths + 1] = p end
local t0 = os.clock()
local out, line = T.Run(nil, paths, os.getenv("OUT") or "Data/GeneratorModel.json")
print(line)
if out then
	local keys = { }
	for t in pairs(out.validation) do keys[#keys + 1] = t end
	table.sort(keys, function(a, b) return tonumber(a) < tonumber(b) end)
	for _, t in ipairs(keys) do
		print(string.format("skip below %s: %d skipped, %d that mattered", t, out.validation[t].skipped, out.validation[t].missed))
		for _, w in ipairs(out.validation[t].worst or { }) do print("    " .. w) end
	end
	local familiar, pairsCount = 0, 0
	for _, n in pairs(out.familiar or { }) do if n >= (out.familiarRuns or 2) then familiar = familiar + 1 end end
	for _ in pairs(out.pairs or { }) do pairsCount = pairsCount + 1 end
	print(string.format("familiar skills: %d, unique pairs: %d, seconds: %d", familiar, pairsCount, os.clock() - t0))
end
