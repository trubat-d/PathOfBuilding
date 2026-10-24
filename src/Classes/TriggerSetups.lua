-- Path of Building
--
-- Class: Trigger Setups
-- Builds where the main spell isn't cast by hand but triggered, as top
-- players run them:
--   * Cast while Channelling: a channelling skill (Cyclone, Flameblast...)
--     linked with Cast while Channelling and the spell, triggered every
--     fraction of a second while channelling;
--   * Cast On Critical Strike: an attack (Cyclone, Ice Shot, Lacerate...)
--     linked with Cast On Critical Strike and the spell, triggered by crits;
--   * Arcanist Brand: the spell linked to Arcanist Brand, triggered each
--     time the brand activates;
--   * Spellslinger: the spell linked to Spellslinger, triggered by the wand
--     attacks the build uses (a wand attack in another link).
-- The main socket group stays the spell's (first gem): the trigger gems are
-- linked after it and kept there by the generator (gen.triggerFixed), so
-- PoB's main skill is the triggered spell and its DPS uses PoB's trigger
-- rate (Modules/CalcTriggers). The trigger source is the one that scores
-- best with the weapons it can use.
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert

---@class TriggerSetups
local TriggerSetupsClass = newClass("TriggerSetups")

function TriggerSetupsClass:TriggerSetups()
	return self
end

-- kind = { support (linked support gem, nil for Arcanist Brand), sources (the
-- trigger skills tried, in the main link or, linkSource = false, in a link of
-- their own), label }
TriggerSetupsClass.setups = {
	CWC = { support = "Cast while Channelling", label = "Cast while Channelling",
		sources = { "Cyclone", "Blade Flurry", "Flameblast", "Incinerate", "Winter Orb", "Scorching Ray", "Divine Ire", "Blight", "Wither", "Scourge Arrow" } },
	COC = { support = "Cast On Critical Strike", label = "Cast On Critical Strike",
		sources = { "Cyclone", "Ice Shot", "Lacerate", "Blade Flurry", "Frost Blades", "Double Strike", "Viper Strike", "Cleave", "Barrage", "Split Arrow", "Power Siphon", "Kinetic Bolt" } },
	ARCANIST = { label = "Arcanist Brand", sources = { "Arcanist Brand" } },
	SPELLSLINGER = { support = "Spellslinger", label = "Spellslinger", linkSource = false,
		sources = { "Power Siphon", "Kinetic Bolt", "Barrage", "Split Arrow", "Kinetic Blast" } },
}

local gemIdByName
local function gemId(name)
	if not gemIdByName then
		gemIdByName = { }
		for id, gem in pairs(data.gems) do
			if gem.name and not gem.vaalGem and gem.grantedEffect then
				-- (the plain gem first: transfigured / vaal versions have other names)
				if not gemIdByName[gem.name] or id < gemIdByName[gem.name] then gemIdByName[gem.name] = id end
			end
		end
	end
	return gemIdByName[name]
end
TriggerSetupsClass.GemId = gemId

-- Can a spell gem be triggered by these setups? (spells only, not
-- channelling, reserving, totem / trap / mine or already triggered skills)
function TriggerSetupsClass.Triggerable(gem)
	local effect = gem and gem.grantedEffect
	local types = effect and effect.skillTypes or { }
	if not (types[SkillType.Spell] and types[SkillType.Triggerable]) then return false end
	for _, t in ipairs({ SkillType.Channel, SkillType.HasReservation, SkillType.InbuiltTrigger, SkillType.SummonsTotem, SkillType.Trapped, SkillType.RemoteMined, SkillType.Minion, SkillType.Brand }) do
		if t and types[t] then return false end
	end
	return true
end

-- Is the main skill really triggered by the setup in PoB's calculation?
local function triggered(gen)
	local env = gen.build.calcsTab.mainEnv
	local skill = env and env.player.mainSkill
	if not skill then return false end
	local info = tostring(skill.infoMessage or "")
	return skill.skillData.triggered and not info:find("No .* Found")
end

-- Sets the setup up on the generator's main link (after Setup, with the
-- scorer ready): the best source by score. Returns true if a setup works.
function TriggerSetupsClass.Apply(gen, kind)
	local setup = TriggerSetupsClass.setups[kind]
	if not setup then return false end
	local group = gen.mainGroup
	local skillsTab = gen.build.skillsTab
	local mainEntry = group.gemList[1]
	local supportId = setup.support and gemId(setup.support)
	if setup.support and not supportId then return false end
	local function entry(id)
		return { level = gen:GemLevel(data.gems[id]), quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = id }
	end
	local sourceGroup
	local function place(sourceId)
		for i = #group.gemList, 2, -1 do table.remove(group.gemList, i) end
		if sourceGroup then
			for i, g in ipairs(skillsTab.socketGroupList) do
				if g == sourceGroup then table.remove(skillsTab.socketGroupList, i) break end
			end
			sourceGroup = nil
		end
		local fixed = { }
		if setup.linkSource == false then
			-- (the source in a link of its own, in the weapon)
			sourceGroup = { label = setup.label .. " trigger (generated)", enabled = true, slot = "Weapon 1", gemList = { entry(sourceId) } }
			t_insert(skillsTab.socketGroupList, sourceGroup)
			skillsTab:ProcessSocketGroup(sourceGroup)
		else
			t_insert(group.gemList, entry(sourceId))
			t_insert(fixed, sourceId)
		end
		if supportId then
			t_insert(group.gemList, entry(supportId))
			t_insert(fixed, supportId)
		end
		group.mainActiveSkill = 1
		group.mainActiveSkillCalcs = 1
		skillsTab:ProcessSocketGroup(group)
		return fixed
	end
	local best
	local savedTrigger = gen.triggerSource
	for _, name in ipairs(setup.sources) do
		local sourceId = gemId(name)
		local source = sourceId and data.gems[sourceId]
		if source and source.grantedEffect and not source.grantedEffect.support then
			-- the weapons the source skill can use (an attack needs its weapon)
			gen.triggerSource = source.grantedEffect.weaponTypes and source or nil
			gen.weaponOptions = gen:WeaponOptions()
			if gen.weaponOptions[1] then gen:EquipWeapons(gen.weaponOptions[1]) end
			gen.itemsTab:PopulateSlots()
			local fixed = place(sourceId)
			gen:Recalculate()
			local ok = triggered(gen)
			local score = ok and gen:Score() or nil
			if gen.options.debugTiming then
				local skill = gen.build.calcsTab.mainEnv.player.mainSkill
				ConPrintf("[trigger] %s: %s, score %s, weapon %s (%s)", name, ok and "triggers" or "doesn't trigger", tostring(score),
					tostring(gen.weaponOptions[1] and gen.weaponOptions[1].weapon1), tostring(skill and skill.infoMessage))
			end
			if score and (not best or score > best.score + 1e-9) then
				best = { sourceId = sourceId, score = score, triggerSource = gen.triggerSource }
			end
			gen:Tick()
		end
	end
	if not best then
		-- nothing triggers the spell here: back to self-cast
		for i = #group.gemList, 2, -1 do table.remove(group.gemList, i) end
		if sourceGroup then
			for i, g in ipairs(skillsTab.socketGroupList) do if g == sourceGroup then table.remove(skillsTab.socketGroupList, i) break end end
		end
		gen.triggerSource = savedTrigger
		gen.weaponOptions = gen:WeaponOptions()
		if gen.weaponOptions[1] then gen:EquipWeapons(gen.weaponOptions[1]) end
		gen.itemsTab:PopulateSlots()
		skillsTab:ProcessSocketGroup(group)
		gen:Recalculate()
		gen:Note(string.format("%s: no trigger skill works for %s here; self-cast instead", setup.label, gen.mainGem.name))
		return false
	end
	gen.triggerSource = best.triggerSource
	gen.weaponOptions = gen:WeaponOptions()
	if gen.weaponOptions[1] then gen:EquipWeapons(gen.weaponOptions[1]) end
	gen.itemsTab:PopulateSlots()
	gen.triggerFixed = place(best.sourceId)
	gen.triggerKind = kind
	gen:Recalculate()
	gen:Note(string.format("Trigger setup: %s triggered by %s (%s)", gen.mainGem.name, data.gems[best.sourceId].name, setup.label))
	return true
end
