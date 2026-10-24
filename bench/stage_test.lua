-- Test: runs one generator step on a saved generated build and prints what
-- it did, so a step can be checked without a whole generation.
-- From the src folder: OURS=<build .xml> STEP=<flasks|flaskenchant|clusters|popular|learn|uniquejewels|aurastack|metajewels|uniquesweep|uniqueflasks|fillmain|finalrares|ascendancy|supports|refine|swap|rares> INVEST=ENDGAME luajit ../bench/stage_test.lua
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
local gen = new("BuildGenerator"):BuildGenerator(build, { investment = investment, focus = focus, debugTiming = true, yieldEvery = 1e9 })
gen.scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = investment.awakenedGems and "uber" or "pinnacle" })
gen.scorer.useChecklist = true
gen.scorer.reservationSlope = tonumber(os.getenv("RES_SLOPE") or "")
gen.costs = { }
for _, g in ipairs(build.skillsTab.socketGroupList) do
	if g == build.skillsTab.socketGroupList[build.mainSocketGroup] then gen.mainGroup = g end
end
gen.mainGem = gen.mainGroup and gen.mainGroup.gemList[1] and data.gems[gen.mainGroup.gemList[1].gemId]
gen:AutoConfigure()
local before, r0 = gen:FullScore()
print(string.format("BEFORE score %.3f dps %.0f", before, r0.dps))
local step = os.getenv("STEP") or "flasks"
local t0 = os.clock()
if step == "flasks" then
	local fg = new("FlaskGenerator"):FlaskGenerator(new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator, gen.scorer)
	local bases = fg:GetBases(true)
	print("BASES " .. table.concat(bases, ", "))
	gen:MakeFlasks()
elseif step == "uniquejewels" then
	local finder = new("MetaJewelFinder"):MetaJewelFinder({ build = build, fullScore = function() return (gen:FullScore()) end,
		equip = function(item, slotName) return gen:Equip(item, slotName) end })
	local result = finder:BestUniqueJewel(before, function() return true end, function(o) return (gen:Score(o)) end)
	print("RESULT", result and result.label, result and result.gain)
elseif step == "aurastack" then
	gen:AuraStackMove()
elseif step == "uniquesweep" then
	print("KEPT", gen:UniqueSweep())
elseif step == "mageblood" then
	print("KEPT", gen:PermanentFlaskMove())
elseif step == "uniqueflasks" then
	print("KEPT", gen:UniqueFlaskSweep())
elseif step == "learn" then
	-- META_DETAILS=<json with topBuilds = { { name, code } }>
	local mf = assert(io.open(os.getenv("META_DETAILS")))
	gen.options.meta = { details = require("dkjson").decode(mf:read("*a")) }
	mf:close()
	print("KEPT", gen:LearnFromTopBuilds())
elseif step == "popular" then
	-- META_DETAILS=<json details> or META_CODES="<files with PoB codes>" (aggregated like poe.ninja players)
	if os.getenv("META_CODES") then
		local chars = { }
		for path in os.getenv("META_CODES"):gmatch("%S+") do
			local cf = assert(io.open(path))
			table.insert(chars, { pathOfBuildingExport = cf:read("*a") })
			cf:close()
		end
		gen.options.meta = { details = new("BuildMetaSource"):BuildMetaSource().AggregateCharacters(gen.mainGem.name, chars) }
	else
		local mf = assert(io.open(os.getenv("META_DETAILS")))
		gen.options.meta = { details = require("dkjson").decode(mf:read("*a")) }
		mf:close()
	end
	gen.options.popularMinBuilds = tonumber(os.getenv("MIN_BUILDS") or "")
	print("GAIN", gen:PopularPassivesMove())
elseif step == "watcher" then
	-- the build's Watcher's Eye taken out, then searched again
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and item.title == "Watcher's Eye" then
			print("REMOVED", table.concat((function() local t = { } for _, l in ipairs(item.explicitModLines) do t[#t + 1] = l.line end return t end)(), " | "))
			slot:SetSelItemId(0)
		end
	end
	build.itemsTab:PopulateSlots()
	local base = gen:FullScore()
	print(string.format("WITHOUT %.3f", base))
	local finder = new("MetaJewelFinder"):MetaJewelFinder({ build = build, fullScore = function() return (gen:FullScore()) end,
		quickScore = function() gen:Recalculate() return (gen:Score()) end,
		equip = function(item, slotName) return gen:Equip(item, slotName) end })
	local result = finder:WatchersEye(base, 3)
	print("RESULT", result and result.label, result and result.gain)
	if result then finder:Apply(result) end
elseif step == "metajewels" then
	gen:ChooseMetaJewels()
elseif step == "fillmain" or step == "finalrares" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	if step == "fillmain" then gen:FillMainLinkMove() else gen:FinalRares() end
elseif step == "refine" then
	-- (one allocation first, as the generator's tree has been allocated before refining)
	gen:AllocateTree(true)
	for _, n in ipairs({ 6, 10, 16, 6 }) do print("REFINE", n, gen:RefineTree(n)) end
elseif step == "flaskenchant" then
	gen:FlaskEnchantMove()
elseif step == "clusters" then
	gen:ChooseClusterJewels(tonumber(os.getenv("LARGE") or "0"))
elseif step == "swap" then
	print("KEPT", gen:SwapForNotables(10))
elseif step == "supports" then
	gen:FinalSupports()
elseif step == "ascendancy" then
	gen.options.classId = build.spec.curClassId
	gen.options.ascendClassId = build.spec.curAscendClassId
	gen:AscendancyRecheck()
elseif step == "rares" then
	local rg = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator
	gen.options.quality = rg.qualityList[investment.quality or rg.defaultQuality]
	gen.options.weaponSeeds = tonumber(os.getenv("WEAPON_SEEDS") or "")
	gen.options.crafts = os.getenv("CRAFTS") ~= "0"
	gen:MakeRares(true)
	for _, slot in ipairs(build.itemsTab.orderedSlots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and item.rarity == "RARE" then
			for _, l in ipairs(item.explicitModLines) do if l.crafted then print("CRAFT", slot.slotName, l.line) end end
		end
	end
end
local after, r1 = gen:FullScore()
print(string.format("AFTER score %.3f dps %.0f (%.0f s)", after, r1.dps, os.clock() - t0))
for _, l in ipairs(gen.log) do print("LOG " .. l) end
