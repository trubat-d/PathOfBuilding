-- Test: the tries of a generation combined (BuildGenerator:Combine). The
-- other builds (OTHERS="a.xml;b.xml") are read first as states, then the
-- main one (OURS=<xml>) is opened and crossed with them.
-- From the src folder: OURS=<xml> OTHERS=<xml;xml> INVEST=ENDGAME luajit ../bench/combine_test.lua
-- Optional: FOCUS=<focus id> (default DPS_FLOOR), GENS=<generations> (default 2), SAVE=<xml>
io.stdout:setvbuf("no")
dofile("HeadlessWrapper.lua")
dofile("../bench/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
local dkjson = require "dkjson"
local function open(path)
	local f = assert(io.open(path))
	loadBuildFromXML(f:read("*a"), "combine")
	f:close()
	runCallback("OnFrame")
end
local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == (os.getenv("INVEST") or "ENDGAME") then investment = level end end
local focus
for _, entry in ipairs(new("BuildScorer"):BuildScorer({ }).focusList) do if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end end
local others = { }
for path in (os.getenv("OTHERS") or ""):gmatch("[^;]+") do
	open(path)
	local gen = new("BuildGenerator"):BuildGenerator(build, { investment = investment, focus = focus })
	-- (through JSON, as from a background thread)
	t_insert = table.insert
	table.insert(others, { state = dkjson.decode(dkjson.encode(gen:SerializeState())), label = path:match("[^/]+$") })
end
open(assert(os.getenv("OURS")))
local gen = new("BuildGenerator"):BuildGenerator(build, { investment = investment, focus = focus, yieldEvery = 1e9,
	combineGenerations = tonumber(os.getenv("GENS") or "2"), debugTiming = os.getenv("DEBUG_TIMING") == "1" })
local t0 = os.clock()
local co = coroutine.create(function() return gen:Combine(others) end)
local ok, res = coroutine.resume(co)
while ok and coroutine.status(co) ~= "dead" do ok, res = coroutine.resume(co) end
if not ok then print("ERROR", res) os.exit(1) end
print(string.format("BEFORE %.3f dps %.0f", res.before.score, res.before.dps))
print(string.format("AFTER %.3f dps %.0f (%d s)", res.final.score, res.final.dps, os.clock() - t0))
for _, l in ipairs(res.log) do print("NOTE " .. l) end
if os.getenv("SAVE") then
	local f = io.open(os.getenv("SAVE"), "w")
	if f then f:write(build:SaveDB("code")) f:close() end
end
