-- Benchmark: generates one build headless and prints one result line (JSON).
-- Run from the src folder:
--   luajit ../bench/bench_case.lua "<Skill>" "<Ascendancy>" <investment id> <quick|full> [archetype id]
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
if archetypeId then
	for _, a in ipairs(new("BuildArchetypes"):BuildArchetypes().ForSkill(data.gems[gemId], nil)) do
		if a.id == archetypeId then archetype = a end
	end
	assert(archetype, "archetype not found: " .. archetypeId)
end

local gen = new("BuildGenerator"):BuildGenerator(build, {
	gemId = gemId, classId = asc.classId, ascendClassId = asc.ascendClassId, level = 92,
	investment = investment, focus = new("BuildScorer"):BuildScorer(build).focusList[1],
	quick = mode == "quick", synergies = false, archetype = archetype, yieldEvery = 1e9,
})
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
	result.checklist = res.checklist
end
result.seconds = math.floor(os.clock() - t0)
print("BENCH " .. dkjson.encode(result))
