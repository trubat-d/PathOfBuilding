-- Benchmark: what if a generated build took one more node (an ascendancy
-- notable, a keystone) or wore some uniques? Applies the change, lets the
-- generator re-balance the points (trimmed to the budget, the tree refined)
-- and prints score / DPS / lowest max hit before and after.
-- Run from the src folder:
--   OURS=<build .xml> NODES="Ramako, Sun's Light" UNIQUES="Body Armour=Kaom's Heart;Weapon 2=Rathpith Globe" luajit ../bench/what_if.lua
-- REFINE=0: no tree refinement after the change (raw effect)
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
local f = assert(io.open(os.getenv("OURS")))
loadBuildFromXML(f:read("*a"), "ours")
f:close()
runCallback("OnFrame")
local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == (os.getenv("INVEST") or "ENDGAME") then investment = level end end
local focus
for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end end
local gen = new("BuildGenerator"):BuildGenerator(build, { investment = investment, focus = focus, yieldEvery = 1e9 })
gen.scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = os.getenv("TIER") or "uber" })
gen.scorer.useChecklist = true
gen.costs = { }
gen.mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
gen.mainGem = gen.mainGroup and gen.mainGroup.gemList[1] and data.gems[gen.mainGroup.gemList[1].gemId]
gen:AutoConfigure()
local function show(label)
	local score, r = gen:FullScore()
	print(string.format("%s score %.3f dps %.0f minHit %.0f", label, score, r.dps, gen.scorer:MinMaxHit(r.output)))
end
show("BEFORE")
local spec = build.spec
for name in (os.getenv("NODES") or ""):gmatch("[^;]+") do
	for _, node in pairs(spec.nodes) do
		if node.dn == name and not node.alloc then
			if node.path then spec:AllocNode(node) print("took " .. name) else print("no path to " .. name) end
		end
	end
end
for pair in (os.getenv("UNIQUES") or ""):gmatch("[^;]+") do
	local slot, title = pair:match("^(.-)=(.+)$")
	for _, item in pairs(main.uniqueDB.list) do
		if (item.title or item.name) == title then
			local copy = new("Item"):Item(item.raw)
			copy:NormaliseQuality()
			copy:BuildModList()
			gen:Equip(copy, slot)
			print("equipped " .. title .. " in " .. slot)
			break
		end
	end
end
build.itemsTab:PopulateSlots()
gen:Recalculate()
show("RAW")
gen.protectedNodes = { }
for name in (os.getenv("NODES") or ""):gmatch("[^;]+") do
	for _, node in pairs(spec.nodes) do if node.dn == name and node.alloc then gen.protectedNodes[node.id] = true end end
end
gen:TrimTree()
if os.getenv("REFINE") ~= "0" then
	gen:ChooseSupports(5)
	gen:RefineTree(10)
	gen:AutoConfigure()
end
show("AFTER")
for _, l in ipairs(gen.log) do print("LOG " .. l) end
