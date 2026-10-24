-- Benchmark: upgrades an existing build (BuildGenerator:Upgrade, the window's
-- "Upgrade this build") headless and prints one result line (JSON).
-- Run from the src folder:
--   BUILD=<build .xml or file with a PoB code> luajit ../bench/upgrade_build.lua
-- Optional: INVEST=<level id> (default HIGH), BUDGET=<total divines>,
--   FOCUS=<focus id> (default DPS_FLOOR), CONFIG=<BOSS|MAPPING|BOSS_CLEAR>,
--   SKILL=<gem name> (main skill, else the build's), SAVE=<path for the upgraded .xml>
-- Needs LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
local dkjson = require "dkjson"

local path = assert(os.getenv("BUILD"), "BUILD=<file> needed")
local f = assert(io.open(path))
local text = f:read("*a")
f:close()
if path:match("%.xml$") then
	loadBuildFromXML(text, "upgrade")
else
	local code = text:gsub("%s", "")
	loadBuildFromXML(Inflate(common.base64.decode(code:gsub("-", "+"):gsub("_", "/"))), "upgrade")
end
runCallback("OnFrame")
local skill = os.getenv("SKILL")
if skill and skill ~= "" then
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		for _, gem in ipairs(group.gemList) do
			if gem.gemData and gem.gemData.name == skill and not gem.gemData.grantedEffect.support then build.mainSocketGroup = index end
		end
	end
	runCallback("OnFrame")
end

local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == (os.getenv("INVEST") or "HIGH") then investment = level end end
local focus
for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end end
local configScenario
for _, sc in ipairs(new("AutoConfig"):AutoConfig(build).scenarioList) do if sc.id == os.getenv("CONFIG") then configScenario = sc end end
local gen = new("BuildGenerator"):BuildGenerator(build, {
	investment = investment, focus = focus, configScenario = configScenario,
	totalBudget = tonumber(os.getenv("BUDGET") or ""), yieldEvery = 1e9,
	debugTiming = os.getenv("DEBUG_TIMING") == "1",
})
local t0 = os.clock()
local co = coroutine.create(function() return gen:Upgrade() end)
local ok, res = coroutine.resume(co)
while ok and coroutine.status(co) ~= "dead" do ok, res = coroutine.resume(co) end
local result = { build = path, investment = investment and investment.id }
if not ok then
	result.error = tostring(res)
else
	result.score, result.dps, result.ehp = res.final.score, res.final.dps, res.final.ehp
	result.beforeScore, result.beforeDps, result.beforeEhp = res.before.score, res.before.dps, res.before.ehp
	result.log = res.log
	result.cost = (gen:BuildCost())
	local save = os.getenv("SAVE")
	if save and save ~= "" then
		local out = io.open(save, "w")
		if out then out:write(build:SaveDB("code")) out:close() result.xml = save end
	end
end
result.seconds = math.floor(os.clock() - t0)
print("BENCH " .. dkjson.encode(result))
