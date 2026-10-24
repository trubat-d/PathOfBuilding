-- Benchmark: scores an existing build (a PoB code, e.g. a top player's) with
-- the generator's scorer, so generated builds can be compared with it.
-- Run from the src folder:
--   CODE=<file with the PoB code> luajit ../bench/eval_build.lua
-- Optional: FOCUS=<focus id> (default DPS_FLOOR), TIER=uber|pinnacle (default uber),
--   KEEP_CONFIG=1 to keep the build's own configuration instead of the generator's
-- Needs LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;"
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
local codeFile = os.getenv("CODE")
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
local dkjson = require "dkjson"

local f = assert(io.open(codeFile))
local code = f:read("*a"):gsub("%s", "")
f:close()
local xml = Inflate(common.base64.decode(code:gsub("-", "+"):gsub("_", "/")))
loadBuildFromXML(xml, "eval")
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

local scorerClass = new("BuildScorer"):BuildScorer(build)
local focus = scorerClass.focusList[1]
for _, entry in ipairs(scorerClass.focusList) do
	if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end
end
local scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = os.getenv("TIER") or "uber" })
scorer.useChecklist = true

local function evaluate(label)
	local calcFunc = build.calcsTab:GetMiscCalculator()
	local r = scorer:Evaluate(calcFunc, { })
	local o = r.output
	local minHit = scorer:MinMaxHit(o)
	local skill = build.calcsTab.mainEnv.player.mainSkill
	local result = {
		label = label,
		score = r.score, dps = r.dps, rawDps = r.rawDps, ehp = r.ehp, minHit = minHit,
		maxHit = { phys = o.PhysicalMaximumHitTaken, fire = o.FireMaximumHitTaken, cold = o.ColdMaximumHitTaken, light = o.LightningMaximumHitTaken, chaos = o.ChaosMaximumHitTaken },
		life = o.Life, es = o.EnergyShield, mana = o.Mana, ward = o.Ward,
		armour = o.Armour, evasion = o.Evasion, block = o.EffectiveBlockChance, spellBlock = o.EffectiveSpellBlockChance,
		suppression = o.EffectiveSpellSuppressionChance, chaosRes = o.ChaosResist,
		sustain = scorer:SkillSustain(o),
		bossRatio = scorer:BossHitRatio(o),
		skill = skill and skill.activeEffect.grantedEffect.name,
		skillPart = skill and skill.skillPart,
		penalties = { },
	}
	for _, p in ipairs(r.penalties or { }) do table.insert(result.penalties, string.format("%s (%.2f)", p.label, p.value or 0)) end
	return result
end

local own = evaluate("own configuration")
local normalized
if not os.getenv("KEEP_CONFIG") then
	local ac = new("AutoConfig"):AutoConfig(build)
	ac:Run()
	runCallback("OnFrame")
	normalized = evaluate("generator configuration")
end

-- what the build is made of
local summary = { keystones = { }, ascendancy = { }, uniques = { }, rares = 0, groups = { }, notables = 0, points = 0, masteries = { } }
for _, node in pairs(build.spec.allocNodes) do
	if node.type == "Keystone" then table.insert(summary.keystones, node.dn)
	elseif node.ascendancyName and node.type == "Notable" then table.insert(summary.ascendancy, node.dn)
	elseif node.type == "Notable" then summary.notables = summary.notables + 1
	elseif node.type == "Mastery" then table.insert(summary.masteries, node.dn .. ": " .. tostring(node.sd and node.sd[1])) end
	if not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then summary.points = summary.points + 1 end
end
table.sort(summary.keystones) table.sort(summary.ascendancy)
for slotName, slot in pairs(build.itemsTab.slots) do
	local item = build.itemsTab.items[slot.selItemId]
	if item and not slot.nodeId or (item and build.spec.allocNodes[slot.nodeId]) then
		if item.rarity == "UNIQUE" or item.rarity == "RELIC" then table.insert(summary.uniques, slotName .. ": " .. item.title)
		elseif item.rarity == "RARE" then summary.rares = summary.rares + 1 end
	end
end
table.sort(summary.uniques)
for _, group in ipairs(build.skillsTab.socketGroupList) do
	if group.enabled ~= false then
		local names = { }
		for _, gem in ipairs(group.gemList) do
			if gem.enabled ~= false and (gem.gemData or gem.grantedEffect) then
				table.insert(names, string.format("%s %d/%d", (gem.gemData and gem.gemData.name) or gem.grantedEffect.name, gem.level or 0, gem.quality or 0))
			end
		end
		table.insert(summary.groups, (group.slot or "?") .. ": " .. table.concat(names, ", "))
	end
end
local config = { }
for var, value in pairs(build.configTab.input) do table.insert(config, var .. "=" .. tostring(value)) end
table.sort(config)
summary.config = config
summary.level = build.characterLevel
summary.class = build.spec.curAscendClassName
summary.bandit = build.bandit
summary.pantheon = { build.pantheonMajorGod, build.pantheonMinorGod }

print("EVAL " .. dkjson.encode({ own = own, normalized = normalized, summary = summary }))
