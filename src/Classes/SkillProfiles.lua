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

-- Share of a prismatic skill's uses (Elemental Hit, Wild Strike) on one
-- element: the elements it can choose in turn, Combat Focus jewels in the
-- build ("Prismatic Skills cannot choose Cold") taking theirs out
local function prismaticShare(ctx, element)
	local build = ctx.gen and ctx.gen.build
	local excluded, count = { }, 0
	if build then
		for _, slot in pairs(build.itemsTab.slots) do
			local item = slot.selItemId and build.itemsTab.items[slot.selItemId]
			if item and (slot.nodeId == nil or build.spec.allocNodes[slot.nodeId]) then
				for _, modLine in ipairs(item.explicitModLines or { }) do
					local e = (modLine.line or ""):lower():match("prismatic skills cannot choose (%a+)")
					if e and not excluded[e] then excluded[e] = true count = count + 1 end
				end
			end
		end
	end
	if count >= 3 then return 1 / 3 end
	if excluded[element] then return 0 end
	return 1 / (3 - count)
end
SkillProfilesClass.PrismaticShare = prismaticShare

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
	-- Blade Blast detonates Lingering Blades it touches (PoB's stages: the blade
	-- hits, 50 by default whatever the build). The blades come from Bladefall
	-- (one per volley) or Ethereal Knives of Lingering Blades: a player casts
	-- one, then Blade Blast - the blade hits a second are the cycle's blades
	-- (and Blade Blast's own hit) over the two cast times. No blade source:
	-- Blade Blast's own hit only
	{ pattern = "^Blade Blast$", part = "Blade Hits Per Sec", stages = function(ctx)
		local build = ctx.gen and ctx.gen.build
		local blades, castTime = 0, 0
		for _, group in ipairs(build and build.skillsTab.socketGroupList or { }) do
			if group.enabled ~= false then
				for _, g in ipairs(group.gemList or { }) do
					local name = g.enabled ~= false and g.gemData and g.gemData.name or ""
					if name:match("^Bladefall") and blades < 5 then blades, castTime = 5 + m_floor((g.quality or 0) / 20), 0.7
					elseif name == "Ethereal Knives of Lingering Blades" and blades < 5 then blades, castTime = 5, 0.6 end
				end
			end
		end
		local speed = ctx.output.Speed or 0
		if speed <= 0 then return 1 end
		if blades == 0 then return m_max(1, m_floor(speed + 0.5)) end
		-- (Blade Blast's cast time 0.5 s, the other skill's at the same cast speed)
		local cycle = (0.5 + castTime) / (speed * 0.5)
		return m_max(1, m_floor((blades + 1) / cycle + 0.5))
	end, note = "the lingering blades the build makes, detonated: blade hits a second" },
	{ pattern = "^Detonate Dead", combine = { { part = "Spell", weight = 1 }, { part = "Corpse Explosion", weight = 1 } }, note = "each corpse's spell hit and explosion (corpses: BuildScorer:CorpseFactor)" },
	{ pattern = "^Volatile Dead", combine = { { part = "Spell", weight = 1 }, { part = "Corpse Explosion", weight = 1 } }, note = "each corpse's explosion and orb (corpses: BuildScorer:CorpseFactor)" },
	-- (Cremation: up to 3 geysers firing at once, each from a corpse that exploded)
	{ pattern = "^Cremation", combine = { { part = "Corpse Explosion", weight = 1 }, { part = "Spell", weight = 3 } }, note = "each corpse's explosion and its 3 geysers firing (corpses: BuildScorer:CorpseFactor)" },
	-- elements to choose from: the best one
	-- (poewiki: each attack picks an element at random, never the same twice in
	-- a row - the three in turn, unless Combat Focus jewels ("Prismatic Skills
	-- cannot choose ...") leave it fewer)
	{ pattern = "^Elemental Hit$", combine = { { part = "Fire Attack", weight = function(ctx) return prismaticShare(ctx, "fire") end },
		{ part = "Cold Attack", weight = function(ctx) return prismaticShare(ctx, "cold") end },
		{ part = "Lightning Attack", weight = function(ctx) return prismaticShare(ctx, "lightning") end } }, note = "the three elements in turn (random, never twice in a row)" },
	-- parts that all hit the same boss
	-- (Zenith: every 5th attack throws many more, stronger balls; PoB's weighted
	-- average mixes the 4 normal attacks and the 5th - showing one normal attack's
	-- balls undervalued it about 6 times)
	{ pattern = "^Molten Strike of the Zenith", combine = { { part = "Melee Hit", weight = 1 }, { part = "Total Weighted Ball Average", weight = 1 } }, note = "the melee hit and the magma balls landing on a boss, every 5th attack's bigger volley included (PoB's weighted average)" },
	{ pattern = "^Molten Strike", combine = { { part = "Melee Hit", weight = 1 }, { part = "Average Balls Hitting", weight = 1 } }, note = "the melee hit and its magma balls that land on a boss (PoB's average)" },
	-- (poewiki: a typical-sized target isn't hit by the explosions of a
	-- collision against it; a large boss's hitbox catches about one)
	{ pattern = "^Kinetic Blast", combine = { { part = "Projectile", weight = 1 }, { part = "Explosions", weight = bossOr(1, 2) } }, note = "the projectile and about one explosion on a large boss (the target hit isn't hit by its own explosions)" },
	{ pattern = "^Earthquake", combine = { { part = "Initial impact", weight = 1 }, { part = "Aftershock", weight = 1 } }, note = "each impact and its aftershock" },
	-- Earthshatter's spikes shatter only when a warcry or a different slam is
	-- used near them (poewiki), not by Earthshatter itself: counted when the
	-- build has a warcry or another slam skill
	{ pattern = "^Earthshatter", combine = { { part = "Initial impact", weight = 1 }, { part = "Spike", weight = function(ctx)
		local build = ctx.gen and ctx.gen.build
		for _, group in ipairs(build and build.skillsTab.socketGroupList or { }) do
			if group.enabled ~= false then
				for _, g in ipairs(group.gemList or { }) do
					local gd = g.enabled ~= false and g.gemData
					local types = gd and gd.grantedEffect and gd.grantedEffect.skillTypes
					if types and not gd.grantedEffect.support and gd.name ~= "Earthshatter" and (types[SkillType.Warcry] or types[SkillType.Slam]) then return 1 end
				end
			end
		end
		return 0
	end } }, note = "each impact, and its spikes when a warcry or another slam shatters them" },
	{ pattern = "^Sunder", combine = { { part = "First Wave Area", weight = 1 }, { part = "Final Wave Area", weight = 1 } }, note = "the first and the final wave hitting a boss" },
	{ pattern = "^Glacial Cascade", combine = { { part = "Initial Bursts", weight = 2 }, { part = "Final Burst", weight = 1 } }, note = "2 initial bursts and the final burst hitting a boss" },
	{ pattern = "^Venom Gyre", combine = { { part = "Outgoing Projectile", weight = 1 }, { part = "Returning Projectile", weight = 1 } }, note = "projectiles hitting a boss going out and coming back" },
	{ pattern = "^Static Strike", combine = { { part = "Melee hit", weight = 1 }, { part = "Beams", weight = 1 } }, note = "the melee hit and the beams on a boss" },
	-- (poewiki: projectiles created by a strike that hits an enemy don't hit that
	-- enemy, unless they come back: on a single boss only the melee hit lands,
	-- the projectiles hit returning with Returning Projectiles)
	{ pattern = "^Lightning Strike", combine = { { part = "Melee hit", weight = 1 }, { part = "Projectiles", weight = function(ctx)
		if not ctx.boss then return 1 end
		local build = ctx.gen and ctx.gen.build
		local group = ctx.gen and ctx.gen.mainGroup
		for _, g in ipairs(group and group.gemList or { }) do
			if g.enabled ~= false and g.gemData and g.gemData.name == "Returning Projectiles" then return 1 end
		end
		return 0
	end } }, note = "the melee hit (a boss isn't hit by the strike's own projectiles unless they return); projectiles on other enemies while mapping" },
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
	-- Firestorm (poewiki): the first impact, then a bolt every 0.15 s for the
	-- duration, landing at random in the storm's area; 3 storms at most (a
	-- faster cast rate shortens each). PoB shows one bolt per cast: the bolts
	-- of a cast that land on a boss (its hitbox about 1 metre) are counted
	{ pattern = "^Firestorm$", combine = { { part = "First Impact", weight = 1 }, { part = "Subsequent Impacts", weight = function(ctx)
		local o = ctx.output or { }
		local duration, speed = o.Duration or 1.4, o.Speed or 0
		local life = speed > 0 and m_min(duration, 3 / speed) or duration
		local bolts = m_floor(life / 0.15)
		local radius = o.AreaOfEffectRadius or 13
		local area = o.AreaOfEffectRadiusSecondary or 25 * radius / 13
		local share = m_min(1, ((radius + 10) / m_max(1, area)) ^ 2)
		return bolts * share
	end } }, note = "the first impact and the storm's bolts that land on a boss" },
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
	-- (poewiki: an enemy hit by the melee part can't be hit by the secondary
	-- effect - on a single boss only the strikes land; the explosion, bolt or
	-- wave hit the rest of a pack)
	{ pattern = "^Wild Strike", combine = {
		{ part = "Fire hit", weight = function(ctx) return prismaticShare(ctx, "fire") end }, { part = "Fire explosion", weight = function(ctx) return ctx.boss and 0 or prismaticShare(ctx, "fire") end },
		{ part = "Lightning hit", weight = function(ctx) return prismaticShare(ctx, "lightning") end }, { part = "Lightning bolt", weight = function(ctx) return ctx.boss and 0 or prismaticShare(ctx, "lightning") end },
		{ part = "Cold hit", weight = function(ctx) return prismaticShare(ctx, "cold") end }, { part = "Icy wave", weight = function(ctx) return ctx.boss and 0 or prismaticShare(ctx, "cold") end } }, note = "each element in turn; its secondary hit only on the rest of a pack (an enemy struck isn't hit by it)" },
	{ pattern = "^Tornado of Elemental Turbulence", combine = { { part = "Fire", weight = 1 / 3 }, { part = "Lightning", weight = 1 / 3 }, { part = "Cold", weight = 1 / 3 } }, note = "the three elements in turn" },
	-- arrows of one attack landing on a boss (PoB counts one arrow an attack;
	-- poewiki: 2-5 hits on an average-sized boss, 5-8 with Saturation's slower
	-- and more numerous arrows; Artillery's line of arrows crosses it)
	{ pattern = "^Rain of Arrows$", hits = bossOr(3, 1), note = "about 3 of an attack's arrows hitting a boss" },
	{ pattern = "^Rain of Arrows of Saturation", hits = bossOr(6, 1), note = "about 6 of an attack's arrows hitting a boss" },
	{ pattern = "^Rain of Arrows of Artillery", hits = bossOr(2, 1), note = "about 2 of the line's arrows hitting a boss" },
	-- (poewiki Bladefall: five volleys, each one wave's width further; enemies
	-- are hit more than once where they overlap - a boss's hitbox spans about two)
	{ pattern = "^Bladefall$", hits = bossOr(2, 1), note = "about 2 of the 5 volleys hitting a boss" },
	-- (Artillery Ballista: its arrows land in a line, a boss under about two)
	{ pattern = "^Artillery Ballista$", hits = bossOr(2, 1), note = "about 2 of a volley's arrows hitting a boss" },
	-- Lightning Arrow of Electrocution (poewiki): an arrow stuck in the target
	-- strikes it 4 more times (+1 at 20% quality), one every 0.5 s; up to 10
	-- stuck. PoB's stages are the arrows stuck, 10 by default: the arrows the
	-- attack rate keeps stuck
	{ pattern = "^Lightning Arrow of Electrocution", stages = function(ctx)
		local first = ctx.gen and ctx.gen.mainGroup and ctx.gen.mainGroup.gemList[1]
		local strikes = 4 + m_floor(((first and first.quality) or 0) * 0.05)
		local stuck = (ctx.output.Speed or 0) * strikes * 0.5
		return m_max(1, m_min(10, m_floor(stuck + 0.5)))
	end, note = "the arrows the attack rate keeps stuck in a boss" },
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

-- Hits of one use landing on the same target, beyond the one PoB counts
-- (Rain of Arrows): a number, or nil
function SkillProfilesClass.Hits(gem, ctx)
	local profile = gem and SkillProfilesClass.Find(gem.name)
	if not profile or not profile.hits then return nil end
	local hits = type(profile.hits) == "function" and profile.hits(ctx) or profile.hits
	return hits, profile.note
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
	if profile.stages then
		local stages = profile.stages(ctx)
		if stages and first.skillStageCount ~= stages then
			first.skillStageCount, first.skillStageCountCalcs = stages, stages
			gen.build.skillsTab:ProcessSocketGroup(gen.mainGroup)
			changed = true
		end
		note = string.format("%s (%s)", profile.note, tostring(stages))
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
