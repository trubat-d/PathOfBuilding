-- Benchmark: generates one build headless and prints one result line (JSON).
-- Run from the src folder:
--   luajit ../bench/bench_case.lua "<Skill>" "<Ascendancy>" <investment id> <quick|full> [archetype id | LIST]
-- Needs LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
io.stdout:setvbuf("no")
local skillName, ascName, investmentId, mode, archetypeId = arg[1], arg[2], arg[3] or "MID", arg[4] or "quick", arg[5]
local benchDir = arg[0]:match("^(.*)[/\\]") or "."
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
newBuild()
local dkjson = require "dkjson"

local gen0 = new("BuildGenerator"):BuildGenerator(build)
local gemId
for _, s in ipairs(gen0.SkillList()) do if s.label == skillName then gemId = s.gemId end end
assert(gemId, "skill not found: " .. skillName)
local asc
for _, a in ipairs(gen0.AscendancyList(build.spec.tree)) do if a.ascendName == ascName then asc = a end end
assert(asc, "ascendancy not found: " .. ascName)
local ps = new("PriceSource"):PriceSource()
local investment
for _, level in ipairs(ps.levels) do if level.id == investmentId then investment = level end end
assert(investment, "investment level not found: " .. investmentId)

local archetype
if archetypeId == "LIST" then
	-- the archetypes that fit the skill (run_bench.py "auto" mode scans them)
	local ids = { }
	for _, a in ipairs(new("BuildArchetypes"):BuildArchetypes().ForSkill(data.gems[gemId], nil)) do table.insert(ids, a.id) end
	print("ARCHETYPES " .. table.concat(ids, ","))
	os.exit(0)
end
if archetypeId then
	for _, a in ipairs(new("BuildArchetypes"):BuildArchetypes().ForSkill(data.gems[gemId], nil)) do
		if a.id == archetypeId then archetype = a end
	end
	assert(archetype, "archetype not found: " .. archetypeId)
end

-- optional: FOCUS=<focus id> (BALANCED, DPS, TANK, DPS_FLOOR, CLEAR)
local focus = new("BuildScorer"):BuildScorer(build).focusList[1]
for _, f in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do
	if f.id == os.getenv("FOCUS") then focus = f end
end
-- optional: top player details (poe.ninja) saved as JSON, for offline tests
local meta
if os.getenv("META_DETAILS") then
	local f = assert(io.open(os.getenv("META_DETAILS")))
	meta = { items = { }, keystones = { }, anoints = { }, supports = { }, total = 0, details = dkjson.decode(f:read("*a")) }
	f:close()
end
-- optional: CONFIG=<AutoConfig scenario id> (BOSS, MAPPING, BOSS_CLEAR)
local configScenario
for _, sc in ipairs(new("AutoConfig"):AutoConfig(build).scenarioList) do
	if sc.id == os.getenv("CONFIG") then configScenario = sc end
end
local gen = new("BuildGenerator"):BuildGenerator(build, {
	meta = meta, configScenario = configScenario,
	-- (LEARN=1: the player data steers the build; otherwise it's only shown)
	learnFromPlayers = os.getenv("LEARN") == "1",
	-- FORCE="Unique A;Unique B", EXCLUDE="..." (the window's Uniques list)
	forcedUniques = (function() local t = { } for n in (os.getenv("FORCE") or ""):gmatch("[^;]+") do t[#t + 1] = n end return t end)(),
	excludedUniques = (function() local t = { } for n in (os.getenv("EXCLUDE") or ""):gmatch("[^;]+") do t[n] = true end return t end)(),
	gemId = gemId, classId = asc.classId, ascendClassId = asc.ascendClassId, level = 92,
	investment = investment, focus = focus,
	quick = mode == "quick", synergies = os.getenv("SYNERGIES") == "1", archetype = archetype, yieldEvery = 1e9,
	debugTiming = os.getenv("DEBUG_TIMING") == "1",
})
-- GEN_OPTS="name=value,...": generator options (true / false / numbers), for A/B runs
for pair in (os.getenv("GEN_OPTS") or ""):gmatch("[^,]+") do
	local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
	if k then
		if v == "true" then v = true elseif v == "false" then v = false else v = tonumber(v) or v end
		gen.options[k] = v
	end
end
local t0 = os.clock()
local co = coroutine.create(function() return gen:Run() end)
local ok, res = coroutine.resume(co)
while ok and coroutine.status(co) ~= "dead" do ok, res = coroutine.resume(co) end
local result = { skill = skillName, ascendancy = ascName, investment = investmentId, mode = mode, archetype = archetypeId }
if not ok then
	result.error = tostring(res)
else
	runCallback("OnFrame")
	local o = build.calcsTab.mainOutput
	local scorer = gen.scorer
	local minHit = scorer:MinMaxHit(o)
	local sustain = scorer:SkillSustain(o)
	result.score = res.final.score
	result.dps = res.final.dps
	result.ehp = res.final.ehp
	result.minHit = minHit
	result.maxHit = {
		phys = o.PhysicalMaximumHitTaken, fire = o.FireMaximumHitTaken, cold = o.ColdMaximumHitTaken,
		light = o.LightningMaximumHitTaken, chaos = o.ChaosMaximumHitTaken,
	}
	result.life, result.es, result.chaosRes = o.Life, o.EnergyShield, o.ChaosResist
	result.sustain = sustain
	result.penalties = { }
	for _, p in ipairs(res.final.penalties or { }) do table.insert(result.penalties, p.label) end
	local keystones = { }
	for _, node in pairs(build.spec.allocNodes) do
		if node.type == "Keystone" or (node.ascendancyName and node.type == "Notable") then table.insert(keystones, node.dn) end
	end
	table.sort(keystones)
	result.keystones = keystones
	local gems = { }
	for i, g in ipairs(gen.mainGroup.gemList) do if i > 1 and g.gemId then table.insert(gems, data.gems[g.gemId].name) end end
	result.supports = gems
	result.log = res.log
	-- the generated build, for comparisons (bench/transplant.lua)
	local saveDir = os.getenv("BENCH_SAVE")
	if saveDir and saveDir ~= "" then
		local name = (skillName .. "_" .. ascName .. "_" .. investmentId .. "_" .. mode .. (archetypeId and ("_" .. archetypeId) or "")):gsub("[^%w_]", "")
		local f = io.open(saveDir .. "/" .. name .. ".xml", "w")
		if f then
			f:write(build:SaveDB("code"))
			f:close()
			result.xml = saveDir .. "/" .. name .. ".xml"
		end
	end
end
result.seconds = math.floor(os.clock() - t0)
print("BENCH " .. dkjson.encode(result))
