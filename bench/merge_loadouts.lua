-- Several generated builds in one Path of Building file, one loadout each
-- (Modules/BuildLoadouts), checked: every loadout of the merged file is
-- calculated again and compared with the build it came from.
--
--   OUT=merged.xml luajit ../bench/merge_loadouts.lua a.xml "Title A" b.xml "Title B" ...
--
-- Run from src (LUA_PATH as for the other bench scripts). CHECK=0 skips the check.
local argv = { }
for i, a in ipairs(arg or { }) do argv[i] = a end
dofile("HeadlessWrapper.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end

local function read(path)
	local f = assert(io.open(path, "r"))
	local text = f:read("*a")
	f:close()
	return text
end

local entries = { }
for i = 1, #argv, 2 do
	table.insert(entries, { xml = read(argv[i]), title = argv[i + 1] or argv[i]:match("([^/]+)%.xml$") })
end
local merged, err = LoadModule("Modules/BuildLoadouts").Merge(entries)
if not merged then error(err) end
local out = os.getenv("OUT") or "merged.xml"
local f = assert(io.open(out, "w"))
f:write(merged)
f:close()
print(string.format("MERGED %d builds -> %s (%d bytes)", #entries, out, #merged))
if os.getenv("CHECK") == "0" then return end

local function stats(build)
	-- (as the app does on a rebuild: the socket colours matched again for the
	-- active skill set, +10% quality in a matching socket)
	build.skillsTab:UpdateSocketGroups()
	build.buildFlag = false
	build.calcsTab:BuildOutput()
	local o = build.calcsTab.mainOutput
	local skill = build.calcsTab.mainEnv.player.mainSkill
	return { dps = math.max(o.FullDPS or 0, o.CombinedDPS or 0), ehp = o.TotalEHP or 0, life = o.Life or 0,
		skill = skill and skill.activeEffect and skill.activeEffect.grantedEffect.name or "?" }
end

local original = { }
for i, entry in ipairs(entries) do
	loadBuildFromXML(entry.xml, "original " .. i)
	original[i] = stats(build)
end
loadBuildFromXML(merged, "merged")
local worst = 0
for i, entry in ipairs(entries) do
	local itemSetId = build.itemsTab.itemSetOrderList[i]
	-- (as the Loadouts drop-down does it)
	build.itemsTab:SetActiveItemSet(itemSetId)
	build.skillsTab:SetActiveSkillSet(build.skillsTab.skillSetOrderList[i])
	build.configTab:SetActiveConfigSet(build.configTab.configSetOrderList[i])
	build.treeTab:SetActiveSpec(i)
	if os.getenv("TWICE") then build.treeTab:SetActiveSpec(i) end
	local s, o = stats(build), original[i]
	local diff = o.dps > 0 and math.abs(s.dps / o.dps - 1) or 0
	worst = math.max(worst, diff)
	print(string.format("LOADOUT %d %-40s %s: DPS %.0f (original %.0f, %+.2f%%), EHP %.0f (original %.0f)",
		i, entry.title, s.skill, s.dps, o.dps, (s.dps / math.max(o.dps, 1) - 1) * 100, s.ehp, o.ehp))
end
print(string.format("CHECK worst DPS difference %.3f%%", worst * 100))
