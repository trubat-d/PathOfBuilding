-- Profiling: where does a generation spend its time? Times every method of
-- the generator classes (inclusive time, so nested methods count in both)
-- and counts calculator runs.
-- From the src folder: luajit ../bench/profile_gen.lua "<Skill>" "<Ascendancy>" <investment> <quick|full>
io.stdout:setvbuf("no")
local skillName, ascName, investmentId, mode = arg[1], arg[2], arg[3] or "MID", arg[4] or "quick"
local benchDir = arg[0]:match("^(.*)[/\\]") or "."
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
newBuild()

local stats = { }
local clock = os.clock
local function wrapClass(className)
	local class = common.classes[className]
	if not class then return end
	for name, fn in pairs(class) do
		if type(fn) == "function" and name ~= className and not name:match("^_") then
			local key = className .. ":" .. name
			class[name] = function(...)
				local t0 = clock()
				local r = { fn(...) }
				local s = stats[key] or { time = 0, calls = 0 }
				s.time = s.time + (clock() - t0)
				s.calls = s.calls + 1
				stats[key] = s
				return unpack(r)
			end
		end
	end
end
-- load the classes first, then wrap them
local gen0 = new("BuildGenerator"):BuildGenerator(build)
for _, c in ipairs({ "BuildScorer", "GemSetup", "RareItemGenerator", "FlaskGenerator", "MetaJewelFinder", "ClusterJewelGenerator", "TreeOptimizer",
	"ScalingAnalyzer", "SynergyFinder", "BestItemFinder", "AutoConfig", "HitOverlap", "CraftAdvisor", "BuildArchetypes" }) do
	pcall(new, c)
end
for _, c in ipairs({ "BuildGenerator", "BuildScorer", "GemSetup", "RareItemGenerator", "FlaskGenerator", "MetaJewelFinder", "ClusterJewelGenerator",
	"TreeOptimizer", "ScalingAnalyzer", "SynergyFinder", "BestItemFinder", "AutoConfig", "HitOverlap" }) do
	wrapClass(c)
end
-- calculator runs
local calcs = build.calcsTab.calcs
local origPerform = calcs.perform
local performCount, performTime = 0, 0
calcs.perform = function(...)
	local t0 = clock()
	local r = { origPerform(...) }
	performCount = performCount + 1
	performTime = performTime + clock() - t0
	return unpack(r)
end
local origInit = calcs.initEnv
local initCount, initTime = 0, 0
calcs.initEnv = function(...)
	local t0 = clock()
	local r = { origInit(...) }
	initCount = initCount + 1
	initTime = initTime + clock() - t0
	return unpack(r)
end

local gemId
for _, s in ipairs(gen0.SkillList()) do if s.label == skillName then gemId = s.gemId end end
local asc
for _, a in ipairs(gen0.AscendancyList(build.spec.tree)) do if a.ascendName == ascName then asc = a end end
local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == investmentId then investment = level end end
local focus
for _, f in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do if f.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = f end end
local gen = new("BuildGenerator"):BuildGenerator(build, {
	gemId = gemId, classId = asc.classId, ascendClassId = asc.ascendClassId, level = 92,
	investment = investment, focus = focus, quick = mode == "quick", synergies = false, yieldEvery = 1e9,
})
local t0 = clock()
local co = coroutine.create(function() return gen:Run() end)
local ok, res = coroutine.resume(co)
while ok and coroutine.status(co) ~= "dead" do ok, res = coroutine.resume(co) end
local total = clock() - t0
print(string.format("TOTAL %.1f s  (initEnv %d calls %.1f s, perform %d calls %.1f s)  ok=%s score=%s", total, initCount, initTime, performCount, performTime, tostring(ok), ok and tostring(res.final.score) or tostring(res)))
local list = { }
for key, s in pairs(stats) do table.insert(list, { key = key, time = s.time, calls = s.calls }) end
table.sort(list, function(a, b) return a.time > b.time end)
for i = 1, math.min(45, #list) do
	local e = list[i]
	print(string.format("%7.1f s %6.1f%%  %7d calls  %s", e.time, e.time / total * 100, e.calls, e.key))
end
if gen.treeStats then
	local t = gen.treeStats
	print(string.format("TREE refresh evaluations %d, kept values %d, rechecks %d, picks %d", t.refresh, t.skipped, t.recheck, t.picks))
end
