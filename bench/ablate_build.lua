-- Benchmark: what carries an existing build (a top player's PoB code)?
-- Removes each part in turn (item, support gem, utility group, keystone,
-- ascendancy notable, jewel) and prints how much DPS, lowest max hit and
-- score it was worth, with the generator's configuration and scorer.
-- Run from the src folder:
--   CODE=<file with the PoB code> luajit ../bench/ablate_build.lua
-- Needs LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end

local f = assert(io.open(os.getenv("CODE")))
local code = f:read("*a"):gsub("%s", "")
f:close()
loadBuildFromXML(Inflate(common.base64.decode(code:gsub("-", "+"):gsub("_", "/"))), "ablate")
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
local ac = new("AutoConfig"):AutoConfig(build)
ac:Run()

local focus
for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do
	if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end
end
local scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = os.getenv("TIER") or "uber" })
scorer.useChecklist = true

local function measure()
	ac:Recalculate()
	local r = scorer:Evaluate(build.calcsTab:GetMiscCalculator(), { })
	return { score = r.score, dps = r.dps, minHit = scorer:MinMaxHit(r.output) }
end
local base = measure()
print(string.format("BASE score %.2f  dps %.0f  minHit %.0f", base.score, base.dps, base.minHit))
local rows = { }
local function record(label, m)
	table.insert(rows, { label = label, dScore = m.score - base.score, dps = m.dps / base.dps, hit = m.minHit / base.minHit })
end

-- items (removed through the calculator override, nothing is changed)
local function measureOverride(override)
	local r = scorer:Evaluate(build.calcsTab:GetMiscCalculator(), override)
	return { score = r.score, dps = r.dps, minHit = scorer:MinMaxHit(r.output) }
end
for slotName, slot in pairs(build.itemsTab.slots) do
	local item = build.itemsTab.items[slot.selItemId]
	if item and (not slot.nodeId or build.spec.allocNodes[slot.nodeId]) and not slotName:match("Swap") then
		record(string.format("item %s: %s %s", slotName, item.rarity, item.title or item.name), measureOverride({ repItems = { [slotName] = false } }))
	end
end
-- gems and groups
local mainIndex = build.mainSocketGroup
for index, group in ipairs(build.skillsTab.socketGroupList) do
	if group.enabled ~= false then
		if index == mainIndex then
			for _, gem in ipairs(group.gemList) do
				if gem.enabled ~= false and gem.gemData and gem.gemData.grantedEffect.support then
					gem.enabled = false
					record("support " .. gem.gemData.name, measure())
					gem.enabled = true
				end
			end
		else
			local names = { }
			for _, gem in ipairs(group.gemList) do if gem.gemData then table.insert(names, gem.gemData.name) end end
			group.enabled = false
			record("group " .. table.concat(names, "+"), measure())
			group.enabled = true
		end
	end
end
-- keystones and ascendancy notables, jewels' tree effects (Forbidden pairs come with items)
for id, node in pairs(build.spec.allocNodes) do
	if node.type == "Keystone" or (node.ascendancyName and node.type == "Notable") or (node.type == "Mastery") then
		local calcFunc = build.calcsTab:GetMiscCalculator()
		local r = scorer:Evaluate(calcFunc, { removeNodes = { [node] = true } })
		record(string.format("%s %s", node.type == "Mastery" and "mastery" or node.type == "Keystone" and "keystone" or "ascendancy", node.dn .. (node.type == "Mastery" and (": " .. tostring(node.sd and node.sd[1])) or "")),
			{ score = r.score, dps = r.dps, minHit = scorer:MinMaxHit(r.output) })
	end
end
-- configuration the build relies on (the generator's choice vs off)
table.sort(rows, function(a, b) return a.dScore < b.dScore end)
for _, row in ipairs(rows) do
	print(string.format("%7.2f  dps x%.2f  hit x%.2f  %s", row.dScore, row.dps, row.hit, row.label))
end
