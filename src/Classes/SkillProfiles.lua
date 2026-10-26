-- Path of Building
--
-- Class: Skill Profiles
-- How the main skill is used in a fight, for the parts, stages and counts PoB
-- leaves to the user. PoB shows one skill part at a time (Tornado Shot: one
-- projectile, or all of them; Ball Lightning: one bolt, or all in range),
-- defaults "count" options like Toxic Rain's overlapping pods to 1, and some
-- skills deal their damage on one target with several parts at once
-- (Earthquake's impact then its aftershock). A profile says what a player
-- realistically gets on a pinnacle boss (and while mapping), from the skill's
-- behaviour and the build's own numbers, never the theoretical maximum:
--   part: the skill part shown (by name: transfigured gems have their own)
--   bestOf: part names, the one with the most hit DPS is used (Elemental Hit)
--   combine: { { part = name, weight = n or function(ctx) } }: the parts that
--     add up on one target, weighted (scorer.hitScale, see BuildGenerator)
--   config: { [config var] = value or function(ctx) }
--   stacks: { counts = { ... }, sustain = function(ctx) } (Blade Vortex: the
--     part with the most stacks the build keeps up)
--   note: what was assumed, shown in the generator's log
-- ctx: { output, boss, gen }
--
local ipairs = ipairs
local pairs = pairs
local m_floor = math.floor
local m_min = math.min
local m_max = math.max

---@class SkillProfiles
local SkillProfilesClass = newClass("SkillProfiles")

function SkillProfilesClass:SkillProfiles()
	return self
end

local function bossOr(boss, mapping) return function(ctx) if ctx.boss then return boss end return mapping end end

SkillProfilesClass.list = {
	-- stacks the build keeps up
	{ pattern = "^Blade Vortex", stacks = { parts = { "0 Blades", "5 Blades", "10 Blades" }, counts = { 0, 5, 10 }, sustain = function(ctx)
		-- one blade per cast, each lasting the skill duration
		return (ctx.output.Speed or 0) * (ctx.output.Duration or 4)
	end }, note = "blades kept up: casts per second x blade duration" },
	-- overlap of several projectiles / beams / spikes on one boss
	{ pattern = "^Toxic Rain", config = { toxicRainPodOverlap = bossOr(3, 2) }, note = "3 pods overlapping on a boss (2 while mapping)" },
	{ pattern = "^Storm Rain$", part = "Beam", config = { stormRainBeamOverlap = bossOr(3, 2) }, note = "beams, 3 overlapping on a boss (2 while mapping)" },
	{ pattern = "^Perforate", config = { perforateSpikeOverlap = bossOr(3, 2) }, note = "3 overlapping spikes on a boss (2 while mapping)" },
	{ pattern = "^Shrapnel Ballista", config = { ShrapnelBallistaProjectileOverlap = bossOr(2, 1) }, note = "2 projectiles of each volley hitting a boss" },
	{ pattern = "^Tornado Shot", part = "Combined Average Projectiles", note = "the main projectile and its secondary projectiles hitting a boss (PoB's average)" },
	{ pattern = "^Ball Lightning", part = "All Bolts in Range", note = "every bolt in range of a boss the ball passes through" },
	{ pattern = "^Barrage", part = "All Projectiles", note = "all projectiles of a volley hit one target" },
	{ pattern = "^Forbidden Rite", part = "All Primary Projectiles", note = "the primary projectiles converging on a boss" },
	{ pattern = "^Ice Spear", part = "Second Form, 1 Projectile", note = "second form (a boss isn't point blank), one projectile" },
	{ pattern = "^Lacerate", part = "Both slashes", note = "both slashes hit a boss's large hitbox" },
	-- the part that deals the damage
	{ pattern = "^Explosive Arrow", part = "Explosion (Maximum Sustainable Fuses)", note = "explosions with the fuses the attack rate sustains" },
	{ pattern = "^Divine Ire", part = "Release", note = "released at full stages" },
	{ pattern = "^Blade Flurry", part = "Channel & Release", note = "channelled to full stages, then released" },
	{ pattern = "^Charged Dash", part = "Channelling, Max Stages", note = "channelled at full stages" },
	{ pattern = "^Blade Blast", part = "Blade Hits Per Sec", note = "blades detonated as fast as the cast rate allows" },
	{ pattern = "^Detonate Dead", part = "Corpse Explosion", note = "corpse explosions" },
	{ pattern = "^Volatile Dead", part = "Corpse Explosion", note = "corpse explosions" },
	{ pattern = "^Cremation", part = "Corpse Explosion", note = "corpse eruptions" },
	-- elements to choose from: the best one
	{ pattern = "^Elemental Hit", bestOf = { "Fire Attack", "Cold Attack", "Lightning Attack" }, note = "the element that deals the most damage" },
	-- parts that all hit the same boss
	-- (Zenith: every 5th attack throws many more, stronger balls; PoB's weighted
	-- average mixes the 4 normal attacks and the 5th - showing one normal attack's
	-- balls undervalued it about 6 times)
	{ pattern = "^Molten Strike of the Zenith", combine = { { part = "Melee Hit", weight = 1 }, { part = "Total Weighted Ball Average", weight = 1 } }, note = "the melee hit and the magma balls landing on a boss, every 5th attack's bigger volley included (PoB's weighted average)" },
	{ pattern = "^Molten Strike", combine = { { part = "Melee Hit", weight = 1 }, { part = "Average Balls Hitting", weight = 1 } }, note = "the melee hit and its magma balls that land on a boss (PoB's average)" },
	{ pattern = "^Kinetic Blast", combine = { { part = "Projectile", weight = 1 }, { part = "Explosions", weight = 2 } }, note = "the projectile and 2 of its 3 explosions hitting a boss" },
	{ pattern = "^Earthquake", combine = { { part = "Initial impact", weight = 1 }, { part = "Aftershock", weight = 1 } }, note = "each impact and its aftershock" },
	{ pattern = "^Earthshatter", combine = { { part = "Initial impact", weight = 1 }, { part = "Spike", weight = 1 } }, note = "each impact and its spikes shattering on a boss" },
	{ pattern = "^Sunder", combine = { { part = "First Wave Area", weight = 1 }, { part = "Final Wave Area", weight = 1 } }, note = "the first and the final wave hitting a boss" },
	{ pattern = "^Glacial Cascade", combine = { { part = "Initial Bursts", weight = 2 }, { part = "Final Burst", weight = 1 } }, note = "2 initial bursts and the final burst hitting a boss" },
	{ pattern = "^Venom Gyre", combine = { { part = "Outgoing Projectile", weight = 1 }, { part = "Returning Projectile", weight = 1 } }, note = "projectiles hitting a boss going out and coming back" },
	{ pattern = "^Static Strike", combine = { { part = "Melee hit", weight = 1 }, { part = "Beams", weight = 1 } }, note = "the melee hit and the beams on a boss" },
	{ pattern = "^Lightning Strike", combine = { { part = "Melee hit", weight = 1 }, { part = "Projectiles", weight = 1 } }, note = "the melee hit and its projectiles hitting a boss" },
	{ pattern = "^Bladestorm", combine = { { part = "Attack", weight = 1 }, { part = "Bladestorm", weight = 1 } }, note = "the attack and one storm on a boss" },
	{ pattern = "^Ice Crash", combine = { { part = "First Hit", weight = 1 / 3 }, { part = "Second Hit", weight = 1 / 3 }, { part = "Third Hit", weight = 1 / 3 } }, note = "the three hits in turn (their average)" },
	-- Spark: projectiles wander; "Maximum Hits" is a boss in a corner. About a
	-- third of the hits its duration allows, at least one
	{ pattern = "^Spark", combine = { { part = "1 Hit", weight = function(ctx)
		local maxHits = 1 + m_floor((ctx.output.Duration or 0) / 0.66)
		return m_max(1, maxHits / 3)
	end } }, note = "about a third of the hits each projectile could deal on a boss" },
	-- (skills whose first part, used when none is chosen, is only a piece of
	-- their damage on a boss: found by listing every skill with several parts)
	{ pattern = "^Blast Rain", part = "All Projectiles", note = "all the arrows of a volley landing on a boss" },
	{ pattern = "^Blazing Salvo", part = "All Projectiles", note = "all the projectiles of a volley landing on a boss" },
	{ pattern = "^Blight", part = "Maximum Sustainable Stacks", note = "the stacks the cast rate keeps up while channelling" },
	{ pattern = "^Scorching Ray", part = "Maximum Stages", note = "channelled at full stages" },
	{ pattern = "^Explosive Trap", part = "Average explosions hitting", note = "the explosions that land on a boss (PoB's average)" },
	{ pattern = "^Lightning Spire Trap", part = "Average active traps, average waves", note = "the traps a throw rate keeps active, average waves hitting" },
	{ pattern = "^Seismic Trap of Swells", part = "Average waves hitting configured size enemy", note = "the waves that hit a boss" },
	{ pattern = "^Seismic Trap", part = "Average active traps, average waves", note = "the traps a throw rate keeps active, average waves hitting" },
	{ pattern = "^Flamethrower Trap", part = "Average # traps (good placement)", note = "the traps a throw rate keeps active, well placed" },
	{ pattern = "^Lancing Steel", part = "All Projectiles Hit", note = "the projectiles converging on a boss" },
	{ pattern = "^Eviscerate", part = "Both Waves", note = "both waves hitting a boss" },
	{ pattern = "^Shield Crush", part = "2 Overlapping Waves", note = "the two waves overlapping on a boss" },
	{ pattern = "^Storm Burst of Repulsion", part = "Max Duration Explode", note = "orbs exploding at full duration" },
	{ pattern = "^Storm Burst", part = "Max Channelled Orbs", note = "the orbs a full channel keeps up" },
	{ pattern = "^Storm Rain of", part = "Beam", note = "the beams between arrows" },
	-- Boneshatter's pulse only when the strike stuns (poewiki): on a map pack
	-- most strikes stun; on a pinnacle boss the stun chance is 200 x hit /
	-- threshold (none below 15%), the threshold taken as the boss's ailment
	-- threshold (its life scale) and the build's reduced stun threshold
	{ pattern = "^Boneshatter", combine = { { part = "Attack", weight = 1 }, { part = "Pulse", weight = function(ctx)
		if not ctx.boss then return 1 end
		local env = ctx.gen and ctx.gen.build.calcsTab.mainEnv
		local threshold = env and new("AutoConfig"):AutoConfig(ctx.gen.build).EnemyAilmentThreshold(env)
		local o = ctx.output or { }
		local hit = (o.MainHand and o.MainHand.AverageHit) or o.AverageHit or 0
		local mod = (o.MainHand and o.MainHand.EnemyStunThresholdMod) or o.EnemyStunThresholdMod or 1
		if not threshold or threshold <= 0 or hit <= 0 then return 0 end
		local chance = 200 * hit / (threshold * m_max(0.1, mod))
		if chance < 15 then return 0 end
		return m_min(1, chance / 100)
	end } }, note = "the hit, and its pulse when the strike stuns (rare on a pinnacle boss)" },
	{ pattern = "^Fireball", combine = { { part = "Projectile", weight = 1 }, { part = "Explosion", weight = 1 } }, note = "the projectile and its explosion on a boss" },
	{ pattern = "^Conflagration", combine = { { part = "Projectile", weight = 1 }, { part = "Explosion", weight = 1 } }, note = "the projectile and its explosion on a boss" },
	{ pattern = "^Somatic Shell", combine = { { part = "Projectile", weight = 1 }, { part = "Explosion", weight = 1 } }, note = "the projectile and its explosion on a boss" },
	{ pattern = "^Divine Blast", combine = { { part = "Beam Implosion", weight = 1 }, { part = "Explosion", weight = 1 } }, note = "the beams and the explosion on a boss" },
	{ pattern = "^Holy Sweep", combine = { { part = "Melee Hit", weight = 1 }, { part = "Holy Hammer", weight = 1 } }, note = "the sweep and its hammer on a boss" },
	{ pattern = "^Holy Hammers", combine = { { part = "Slam", weight = 1 }, { part = "First Hammer", weight = 1 } }, note = "the slam and the first hammer on a boss" },
	{ pattern = "^Infernal Blow", combine = { { part = "Melee Hit", weight = 1 }, { part = "Debuff Explosion - 6 Stacks", weight = 1 / 6 } }, note = "the hits and one full explosion every 6 hits" },
	{ pattern = "^Purifying Flame", combine = { { part = "Initial hit", weight = 1 }, { part = "Shockwave", weight = 1 } }, note = "the hit and its shockwave on a boss" },
	{ pattern = "^Rage Vortex", combine = { { part = "Melee", weight = 1 }, { part = "Rage Storm", weight = 1 } }, note = "the attack and its storm on a boss" },
	{ pattern = "^Scourge Arrow", combine = { { part = "Release", weight = 1 }, { part = "Thorn Arrows", weight = 1 } }, note = "the released arrow and the thorn arrows on a boss" },
	{ pattern = "^Shattering Steel", combine = { { part = "Projectile", weight = 1 }, { part = "Cone AoE", weight = 1 } }, note = "the projectiles and the cone at close range" },
	{ pattern = "^Smite", combine = { { part = "Melee Hit", weight = 1 }, { part = "Area Hit", weight = 1 } }, note = "the strike and its lightning on a boss" },
	{ pattern = "^Volcanic Fissure", combine = { { part = "Ground Fissure", weight = 1 }, { part = "Magma Balls", weight = 1 } }, note = "the fissure and its magma balls on a boss" },
	{ pattern = "^Wild Strike", combine = { { part = "Fire hit", weight = 1 / 3 }, { part = "Fire explosion", weight = 1 / 3 }, { part = "Lightning hit", weight = 1 / 3 },
		{ part = "Lightning bolt", weight = 1 / 3 }, { part = "Cold hit", weight = 1 / 3 }, { part = "Icy wave", weight = 1 / 3 } }, note = "each element in turn, with its secondary hit" },
	{ pattern = "^Tornado of Elemental Turbulence", combine = { { part = "Fire", weight = 1 / 3 }, { part = "Lightning", weight = 1 / 3 }, { part = "Cold", weight = 1 / 3 } }, note = "the three elements in turn" },
	-- conditions the skill is used under
	{ pattern = "^Cyclone", config = { channellingCycloneCheck = true }, note = "channelled" },
}

-- Profile of a skill gem (by name: transfigured gems match their base skill)
function SkillProfilesClass.Find(name)
	if not name then return nil end
	for _, profile in ipairs(SkillProfilesClass.list) do
		if name:match(profile.pattern) then return profile end
	end
	return nil
end

-- Index of a part by name in a granted effect (nil if the gem has no such part)
local function partIndex(grantedEffect, partName)
	for i, part in ipairs(grantedEffect and grantedEffect.parts or { }) do
		if part.name == partName then return i end
	end
	return nil
end
SkillProfilesClass.PartIndex = partIndex

-- Parts that add up on one target: { { part = index, weight = number } } or nil
function SkillProfilesClass.Combine(gem, ctx)
	local profile = gem and SkillProfilesClass.Find(gem.name)
	if not profile or not profile.combine then return nil end
	local list = { }
	for _, entry in ipairs(profile.combine) do
		local index = partIndex(gem.grantedEffect, entry.part)
		if not index then return nil end
		local weight = type(entry.weight) == "function" and entry.weight(ctx) or entry.weight
		list[#list + 1] = { part = index, weight = weight }
	end
	return list, profile.note
end

local function setPart(gen, index)
	local first = gen.mainGroup.gemList[1]
	if index and first.skillPart ~= index then
		first.skillPart, first.skillPartCalcs = index, index
		gen.build.skillsTab:ProcessSocketGroup(gen.mainGroup)
		return true
	end
	return false
end

-- Applies the main skill's profile to the build: returns true if the part or
-- the configuration changed (the build then needs recalculating), and the note
function SkillProfilesClass.Apply(gen)
	local gem = gen.mainGem
	local first = gen.mainGroup and gen.mainGroup.gemList[1]
	if not gem or not first then return false end
	local profile = SkillProfilesClass.Find(gem.name)
	if not profile then return false end
	local output = gen.build.calcsTab.mainOutput or { }
	local configScenario = gen.options.configScenario
	local ctx = { output = output, boss = not configScenario or configScenario.boss and true or false, gen = gen }
	local changed = false
	local note = profile.note
	if profile.stacks then
		local sustained = profile.stacks.sustain(ctx)
		local chosen
		for i, count in ipairs(profile.stacks.counts) do
			if sustained >= count then chosen = profile.stacks.parts[i] end
		end
		changed = setPart(gen, partIndex(gem.grantedEffect, chosen)) or changed
		gen.sustainedStacks = sustained
		note = string.format("%s (%.1f): %s", profile.note, sustained, tostring(chosen))
	end
	if profile.part then
		changed = setPart(gen, partIndex(gem.grantedEffect, profile.part)) or changed
	end
	if profile.bestOf then
		-- (each part's hit DPS once; the best one shown)
		local best, bestDps
		local before = first.skillPart
		for _, name in ipairs(profile.bestOf) do
			local index = partIndex(gem.grantedEffect, name)
			if index then
				first.skillPart, first.skillPartCalcs = index, index
				gen.build.skillsTab:ProcessSocketGroup(gen.mainGroup)
				local out = gen.calcFunc({ })
				local dps = out.TotalDPS or 0
				if not bestDps or dps > bestDps + 1e-9 then best, bestDps = index, dps end
			end
		end
		if best then
			first.skillPart, first.skillPartCalcs = best, best
			gen.build.skillsTab:ProcessSocketGroup(gen.mainGroup)
			changed = changed or before ~= best
			note = profile.note .. ": " .. gem.grantedEffect.parts[best].name
		end
	end
	if profile.combine then
		-- (the first combined part is the one shown; the others add through the scorer)
		local index = partIndex(gem.grantedEffect, profile.combine[1].part)
		changed = setPart(gen, index) or changed
	end
	if profile.config then
		local input = gen.build.configTab.input
		local configChanged = false
		for var, value in pairs(profile.config) do
			local v = type(value) == "function" and value(ctx) or value
			if input[var] ~= v then
				input[var] = v
				configChanged = true
			end
		end
		if configChanged then
			gen.build.configTab:BuildModList()
			changed = true
		end
	end
	gen.skillProfileNote = string.format("%s: %s", gem.name, note)
	return changed
end
