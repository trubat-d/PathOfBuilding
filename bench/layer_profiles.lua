-- Benchmark: the damage layer profile (Classes/BuildDoctor:Profile) of saved
-- top-player builds, with the generator's configuration, one JSON line each:
--   PROFILE {"skill":..., "file":..., "crit":..., "speed":..., "enemy":..., ...}
-- Run from the src folder: FILES="a.txt;b.txt" luajit ../bench/layer_profiles.lua
-- (file names <Skill_Name>__<n>.txt; PoB codes or saved XML)
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
function GetTime() return os.clock() * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
local dkjson = require "dkjson"
local fair = dofile(benchDir .. "/fair.lua")
for path in (os.getenv("FILES") or ""):gmatch("[^;]+") do
	local ok, err = pcall(function()
		local f = assert(io.open(path))
		local text = f:read("*a")
		f:close()
		local xml = text:match("^%s*<") and text or Inflate(common.base64.decode(text:gsub("%s", ""):gsub("-", "+"):gsub("_", "/")))
		loadBuildFromXML(xml, "profile")
		runCallback("OnFrame")
		local skillName = path:match("([^/\\]+)__%d+%.%w+$"):gsub("_", " ")
		local found
		for index, group in ipairs(build.skillsTab.socketGroupList) do
			for _, gem in ipairs(group.gemList) do
				if not found and gem.gemData and not gem.gemData.grantedEffect.support and gem.gemData.name:find(skillName, 1, true) then
					build.mainSocketGroup = index
					group.mainActiveSkill = 1
					found = true
				end
			end
		end
		build.buildFlag = true
		runCallback("OnFrame")
		local focus
		for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do if entry.id == "DPS_FLOOR" then focus = entry end end
		local scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = "uber" })
		local gen = fair.Setup(build, scorer)
		new("AutoConfig"):AutoConfig(build):Run()
		fair.Refresh(gen, true)
		local prof = new("BuildDoctor"):BuildDoctor(gen):Profile()
		prof.skill, prof.file = skillName, path:match("([^/\\]+)$")
		print("PROFILE " .. dkjson.encode(prof))
	end)
	if not ok then print("FAILED " .. path .. " " .. tostring(err)) end
end
