-- Scores a loaded build the way the generator scores its own builds: the
-- main skill's profile (Classes/SkillProfiles: the part used in a fight, the
-- parts that add up on one boss) applied, instead of whichever part the
-- build was saved with (a player's PoB often shows the most flattering one).
-- Used by eval_build, ablate_build and transplant so comparisons are fair.
--   local fair = dofile(benchDir .. "/fair.lua")
--   local gen = fair.Setup(build, scorer)   -- once the build and scorer exist
--   fair.Refresh(gen)                       -- after the build changed
local fair = { }

function fair.Setup(build, scorer)
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if not group then return nil end
	-- (the profile works on the group's first gem: the main skill goes first)
	local env = build.calcsTab.mainEnv
	local mainSkill = env and env.player.mainSkill
	local name = mainSkill and mainSkill.activeEffect and mainSkill.activeEffect.grantedEffect.name
	for i, gem in ipairs(group.gemList) do
		if i > 1 and gem.gemData and gem.gemData.grantedEffect.name == name then
			table.remove(group.gemList, i)
			table.insert(group.gemList, 1, gem)
			group.mainActiveSkill = 1
			break
		end
	end
	local gen = new("BuildGenerator"):BuildGenerator(build, { })
	gen.scorer = scorer
	gen.mainGroup = group
	gen.mainGem = group.gemList[1] and group.gemList[1].gemData
	fair.Refresh(gen, true)
	return gen
end

function fair.Refresh(gen, adjust)
	if not gen then return end
	gen:Recalculate()
	if adjust and gen:AdjustSkillPart() then gen:Recalculate() end
	gen:UpdateCombinedParts()
end

return fair
