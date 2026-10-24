-- Benchmark: where does a generated build lose to a top player's build?
-- Puts each part of the player's build into the generated one (each gear
-- item, the main skill's supports, the other skill groups, the passive tree
-- with its jewels, the configuration) and prints what each part is worth,
-- with the generator's configuration and scorer.
-- Run from the src folder:
--   OURS=<generated build .xml> CODE=<file with the player's PoB code> luajit ../bench/transplant.lua
-- Needs LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end

-- 1. the player's build: items, gems, tree
local f = assert(io.open(os.getenv("CODE")))
local code = f:read("*a"):gsub("%s", "")
f:close()
loadBuildFromXML(Inflate(common.base64.decode(code:gsub("-", "+"):gsub("_", "/"))), "pro")
runCallback("OnFrame")

-- SKILL=<gem name>: the socket group with that skill is the main one
local function selectMainSkill(name)
	if not name or name == "" then return end
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		for _, gem in ipairs(group.gemList) do
			if gem.gemData and gem.gemData.name == name and not gem.gemData.grantedEffect.support then
				build.mainSocketGroup = index
				group.mainActiveSkill = 1
				build.buildFlag = true
				runCallback("OnFrame")
				return
			end
		end
	end
end
selectMainSkill(os.getenv("SKILL"))
local pro = { items = { }, groups = { }, supports = { }, config = { } }
for slotName, slot in pairs(build.itemsTab.slots) do
	local item = build.itemsTab.items[slot.selItemId]
	if item and not slot.nodeId and not slotName:match("Swap") and not slotName:match("Abyssal") then
		pro.items[slotName] = item.raw
	end
end
local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
for index, group in ipairs(build.skillsTab.socketGroupList) do
	local gems = { }
	for _, gem in ipairs(group.gemList) do
		if gem.gemData and gem.enabled ~= false then
			table.insert(gems, { name = gem.gemData.name, level = gem.level, quality = gem.quality, support = gem.gemData.grantedEffect.support })
		end
	end
	if index == build.mainSocketGroup then
		for _, g in ipairs(gems) do if g.support then table.insert(pro.supports, g) end end
	elseif group.enabled ~= false and #gems > 0 then
		table.insert(pro.groups, gems)
	end
end
local spec = build.spec
pro.tree = { className = spec.curClassName, classId = spec.curClassId, ascendClassId = spec.curAscendClassId, secondary = spec.curSecondaryAscendClassId, nodes = { }, masteries = { }, jewels = { } }
for id, node in pairs(spec.allocNodes) do table.insert(pro.tree.nodes, id) end
for k, v in pairs(spec.masterySelections or { }) do pro.tree.masteries[k] = v end
for nodeId, itemId in pairs(spec.jewels) do
	local item = build.itemsTab.items[itemId]
	if item and spec.allocNodes[nodeId] then pro.tree.jewels[nodeId] = item.raw end
end
for k, v in pairs(build.configTab.input) do pro.config[k] = v end

-- 2. the generated build
local xf = assert(io.open(os.getenv("OURS")))
local xml = xf:read("*a")
xf:close()
loadBuildFromXML(xml, "ours")
runCallback("OnFrame")
local ac = new("AutoConfig"):AutoConfig(build)
ac:Run()
local focus
for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do
	if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end
end
local scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = os.getenv("TIER") or "uber" })
scorer.useChecklist = true
local fair = dofile(benchDir .. "/fair.lua")
local fairGen = not os.getenv("RAW_PART") and fair.Setup(build, scorer) or nil
local function measure(override, reconfigure)
	if reconfigure then ac:Run() else ac:Recalculate() end
	fair.Refresh(fairGen)
	local r = scorer:Evaluate(build.calcsTab:GetMiscCalculator(), override or { })
	return { score = r.score, dps = r.dps, minHit = scorer:MinMaxHit(r.output) }
end
local base = measure()
print(string.format("OURS score %.2f  dps %.0f  minHit %.0f", base.score, base.dps, base.minHit))
local rows = { }
local function record(label, m)
	table.insert(rows, { label = label, dScore = m.score - base.score, dps = m.dps / base.dps, hit = m.minHit / base.minHit })
end

-- items, one at a time (weapons together: a bow needs its quiver's slot free)
local all = { }
for slotName, raw in pairs(pro.items) do
	local item = new("Item"):Item(raw)
	item:NormaliseQuality()
	item:BuildModList()
	all[slotName] = item
	if not slotName:match("^Flask") then
		record("item " .. slotName .. ": " .. (item.title or item.name), measure({ repItems = { [slotName] = item } }))
	end
end
record("all the player's gear", measure({ repItems = all }))

-- main skill supports
local ourMain = build.skillsTab.socketGroupList[build.mainSocketGroup]
local saved = { }
for i, g in ipairs(ourMain.gemList) do saved[i] = g end
local function gemByName(name)
	for gemId, gem in pairs(data.gems) do if gem.name == name then return gemId, gem end end
end
local kept = { }
for _, g in ipairs(ourMain.gemList) do
	local gd = g.gemData or (g.gemId and data.gems[g.gemId])
	if gd and not gd.grantedEffect.support then table.insert(kept, g) end
end
local newList = { }
for _, g in ipairs(kept) do table.insert(newList, g) end
for _, s in ipairs(pro.supports) do
	local gemId = gemByName(s.name)
	if gemId then table.insert(newList, { level = s.level, quality = s.quality, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId }) end
end
ourMain.gemList = newList
build.skillsTab:ProcessSocketGroup(ourMain)
local names = { }
for _, s in ipairs(pro.supports) do table.insert(names, s.name) end
record("the player's supports (" .. table.concat(names, ", ") .. ")", measure(nil, true))
ourMain.gemList = saved
build.skillsTab:ProcessSocketGroup(ourMain)

-- the player's other skill groups, replacing ours
local savedGroups = { }
for i, g in ipairs(build.skillsTab.socketGroupList) do savedGroups[i] = g end
local mainRef = build.skillsTab.socketGroupList[build.mainSocketGroup]
local list = { mainRef }
for _, gems in ipairs(pro.groups) do
	local group = { label = "", enabled = true, gemList = { } }
	for _, s in ipairs(gems) do
		local gemId = gemByName(s.name)
		if gemId then table.insert(group.gemList, { level = s.level, quality = s.quality, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = gemId }) end
	end
	table.insert(list, group)
end
build.skillsTab.socketGroupList = list
local mainBefore = build.mainSocketGroup
build.mainSocketGroup = 1
for _, g in ipairs(list) do build.skillsTab:ProcessSocketGroup(g) end
record("the player's other skill groups (auras, curses, buffs)", measure(nil, true))
build.skillsTab.socketGroupList = savedGroups
build.mainSocketGroup = mainBefore
for _, g in ipairs(savedGroups) do build.skillsTab:ProcessSocketGroup(g) end

-- the player's configuration (everything they switched on)
local savedConfig = { }
for k, v in pairs(build.configTab.input) do savedConfig[k] = v end
for k, v in pairs(pro.config) do build.configTab.input[k] = v end
build.configTab:BuildModList()
record("the player's configuration", measure())
for k in pairs(build.configTab.input) do build.configTab.input[k] = savedConfig[k] end
build.configTab:BuildModList()

-- the player's passive tree with its jewels (same class)
if pro.tree.classId == build.spec.curClassId then
	local undo = build.spec:CreateUndoState()
	local savedJewels = { }
	for k, v in pairs(build.spec.jewels) do savedJewels[k] = v end
	build.spec:ImportFromNodeList(pro.tree.className, pro.tree.classId, pro.tree.ascendClassId, pro.tree.secondary, pro.tree.nodes, { }, pro.tree.masteries)
	for nodeId, raw in pairs(pro.tree.jewels) do
		local item = new("Item"):Item(raw)
		item:NormaliseQuality()
		build.itemsTab:AddItem(item, true)
		local slot = build.itemsTab.slots["Jewel " .. nodeId]
		if slot then slot:SetSelItemId(item.id) end
	end
	build.itemsTab:PopulateSlots()
	build.spec:BuildAllDependsAndPaths()
	record("the player's passive tree and tree jewels", measure(nil, true))
	build.spec:RestoreUndoState(undo)
end

table.sort(rows, function(a, b) return a.dScore > b.dScore end)
for _, row in ipairs(rows) do
	print(string.format("%+7.2f  dps x%.2f  hit x%.2f  %s", row.dScore, row.dps, row.hit, row.label))
end
