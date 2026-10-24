-- Test: rare items for a saved build made with the slots shared out between
-- worker processes (the app's background threads, bench/fake_threads.lua),
-- against the same made in one thread. Prints both scores and times.
-- From the src folder: OURS=<build .xml> [INVEST=ENDGAME] [WORKERS=2] [PARALLEL=0] luajit ../bench/rares_parallel_test.lua
io.stdout:setvbuf("no")
dofile("HeadlessWrapper.lua")
dofile("../bench/inflate.lua")
local socketOk, socket = pcall(require, "socket")
function GetTime() return (socketOk and socket.gettime() or os.time()) * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
main.generatorWorkers = tonumber(os.getenv("WORKERS") or "2")
dofile("../bench/fake_threads.lua")

local f = assert(io.open(os.getenv("OURS")))
loadBuildFromXML(f:read("*a"), "ours")
f:close()
runCallback("OnFrame")
local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == (os.getenv("INVEST") or "ENDGAME") then investment = level end end
local focus
for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end end
local gen = new("BuildGenerator"):BuildGenerator(build, { investment = investment, focus = focus, yieldEvery = 1e9,
	parallelRares = os.getenv("PARALLEL") ~= "0" and true or false })
gen.scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = investment.awakenedGems and "uber" or "pinnacle" })
gen.scorer.useChecklist = true
gen.costs = { }
for _, g in ipairs(build.skillsTab.socketGroupList) do
	if g == build.skillsTab.socketGroupList[build.mainSocketGroup] then gen.mainGroup = g end
end
gen.mainGem = gen.mainGroup and gen.mainGroup.gemList[1] and data.gems[gen.mainGroup.gemList[1].gemId]
local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
gen:AutoConfigure()
local before = gen:FullScore()
print(string.format("BEFORE %.3f  parallel=%s available=%s workers=%d", before, tostring(gen.options.parallelRares), tostring(new("ParallelGenerator"):ParallelGenerator().Available()), new("ParallelGenerator"):ParallelGenerator().MaxWorkers()))
local t0 = GetTime()
local co = coroutine.create(function() gen:MakeRares(true) end)
local yields = 0
while true do
	local ok, err = coroutine.resume(co)
	if not ok then error(err) end
	if coroutine.status(co) == "dead" then break end
	yields = yields + 1
	runCallback("OnFrame")
	if socketOk then socket.sleep(0.05) end
end
local after = gen:FullScore()
print(string.format("AFTER %.3f  (%.0f s, %d waits)", after, (GetTime() - t0) / 1000, yields))
for _, slot in ipairs(build.itemsTab.orderedSlots) do
	local item = build.itemsTab.items[slot.selItemId]
	if item and item.rarity == "RARE" and not slot.nodeId then
		local lines = { }
		for _, l in ipairs(item.explicitModLines) do table.insert(lines, l.line) end
		print("ITEM", slot.slotName, item.baseName, table.concat(lines, " | "))
	end
end
