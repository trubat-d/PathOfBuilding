-- Path of Building
--
-- Class: Gem Setup
-- Builds the utility gem setups of a generated build the way players do,
-- instead of single unlinked gems:
--   * curses: Mark On Hit + mark, Hextouch + hex on a hitting movement skill,
--     Arcanist Brand + hex, or Blasphemy + hex
--   * auras / heralds linked with Enlighten (by investment level) or Arrogance
--   * a guard skill on Automation or Cast when Damage Taken
--   * a movement skill (and Blood Rage for attacks)
--   * Lifetap linked into utility groups when it helps
-- Every option is scored with the build's scorer, then the groups are packed
-- into the sockets of the helmet, gloves, boots and weapons (the main skill
-- keeps the 6-link body armour). Groups that don't fit are dropped.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort

---@class GemSetup
local GemSetupClass = newClass("GemSetup")

local utilityLabel = "(generated utility)"
local utilitySlots = { "Helmet", "Gloves", "Boots", "Weapon 1", "Weapon 2" }

local gemIdCache
local function gemId(name)
	if not gemIdCache then
		gemIdCache = { }
		for id, gem in pairs(data.gems) do
			if not gemIdCache[gem.name] or id < gemIdCache[gem.name] then
				gemIdCache[gem.name] = id
			end
		end
	end
	return gemIdCache[name]
end
GemSetupClass.GemId = gemId

local function gemEntry(id, level)
	local gem = data.gems[id]
	return { level = level or gem.naturalMaxLevel or 20, quality = 20, enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1, gemId = id }
end

-- gen: a BuildGenerator (provides Score, Tick, Note, options, build)
function GemSetupClass:GemSetup(gen)
	self.gen = gen
	self.build = gen.build
	self.skillsTab = gen.build.skillsTab
	self.groups = { }
	return self
end

function GemSetupClass:Score()
	return (self.gen:Score())
end

-- Gem sockets an item can have: its fixed count for uniques that have one
-- ("Has 1 Socket": Crest of Desire, "Has no Sockets": Kaom's Heart), else the
-- base's limit; abyssal sockets take the place of gem sockets
function GemSetupClass.ItemGemSockets(item)
	if not item or not item.base then return 0 end
	local fixed, abyssal = nil, 0
	for _, modLine in ipairs(item.explicitModLines or { }) do
		if not item.CheckModLineVariant or item:CheckModLineVariant(modLine) then
			local line = modLine.line or ""
			if line == "Has no Sockets" then return 0 end
			local n = line:match("^Has (%d+) Sockets?$")
			if n then fixed = tonumber(n) end
			local a = line:match("^Has (%d+) Abyssal Sockets?$")
			if a then abyssal = abyssal + tonumber(a) end
		end
	end
	if fixed then return fixed end
	local count = 0
	for _, socket in ipairs(item.sockets or { }) do
		if socket.color ~= "A" then count = count + 1 end
	end
	if count == 0 or item.rarity ~= "UNIQUE" then
		count = (item.base.socketLimit or 0) - abyssal
	end
	return math.max(0, count)
end

-- Number of gem sockets of the item in a slot (abyssal sockets don't count)
function GemSetupClass:SlotSockets(slotName)
	local itemsTab = self.build.itemsTab
	local slot = itemsTab.slots[slotName]
	return GemSetupClass.ItemGemSockets(slot and itemsTab.items[slot.selItemId])
end

function GemSetupClass:AddGroup(label, gems, slot)
	local group = { label = label .. " " .. utilityLabel, enabled = true, slot = slot, gemList = gems }
	t_insert(self.skillsTab.socketGroupList, group)
	self.skillsTab:ProcessSocketGroup(group)
	return group
end

function GemSetupClass:RemoveGroup(group)
	for i, g in ipairs(self.skillsTab.socketGroupList) do
		if g == group then
			t_remove(self.skillsTab.socketGroupList, i)
			return
		end
	end
end

-- Removes the utility groups made earlier (keeps the main skill)
function GemSetupClass:Clear()
	local list = self.skillsTab.socketGroupList
	for i = #list, 1, -1 do
		local label = list[i].label or ""
		if label:find(utilityLabel, 1, true) or label == "Aura (generated)" then
			t_remove(list, i)
		end
	end
	self.groups = { }
end

-- Score with a temporary group added
function GemSetupClass:TryGroup(gems)
	local group = self:AddGroup("try", gems, nil)
	local score = self:Score()
	self:RemoveGroup(group)
	return score
end

-- Score with a gem temporarily added to a group
function GemSetupClass:TryInGroup(group, entry)
	t_insert(group.gemList, entry)
	self.skillsTab:ProcessSocketGroup(group)
	local score = self:Score()
	t_remove(group.gemList)
	self.skillsTab:ProcessSocketGroup(group)
	return score
end

-- Can this skill be used with the equipped weapons? (Leap Slam needs a melee
-- weapon, Blink Arrow a bow, Shield Charge a shield...)
function GemSetupClass:CanUse(id)
	local gem = id and data.gems[id]
	local effect = gem and gem.grantedEffect
	if not effect then return false end
	local itemsTab = self.build.itemsTab
	local function itemIn(slotName)
		local slot = itemsTab.slots[slotName]
		return slot and itemsTab.items[slot.selItemId]
	end
	local weapon = itemIn("Weapon 1")
	if effect.weaponTypes then
		local weaponType = weapon and weapon.base and weapon.base.type or "None"
		if not effect.weaponTypes[weaponType] then return false end
	end
	if effect.skillTypes and effect.skillTypes[SkillType.RequiresShield] then
		local offhand = itemIn("Weapon 2")
		if not (offhand and offhand.base and offhand.base.type == "Shield") then return false end
	end
	return true
end

function GemSetupClass:HasShield()
	local slot = self.build.itemsTab.slots["Weapon 2"]
	local offhand = slot and self.build.itemsTab.items[slot.selItemId]
	return offhand and offhand.base and offhand.base.type == "Shield"
end

-- Chaos Inoculation (life is 1): nothing that pays or reserves life
function GemSetupClass:LifeIsOne()
	local output = self.build.calcsTab.mainOutput
	return output and (output.ChaosInoculation or (output.Life or 2) <= 1)
end

function GemSetupClass:MainIsAttack()
	local gem = self.gen.mainGem
	return gem and gem.tags and gem.tags.attack
end

-- Free sockets per slot, after the groups already placed
function GemSetupClass:FreeSockets()
	local free = { }
	for _, slotName in ipairs(utilitySlots) do
		free[slotName] = self:BehaviourSlot(slotName) and 0 or self:SlotSockets(slotName)
	end
	for _, group in ipairs(self.groups) do
		if group.slot and free[group.slot] then
			-- an aura group still being filled keeps its whole capacity
			free[group.slot] = free[group.slot] - math.max(#group.gemList, group.capacity or 0)
		end
	end
	-- the main skill moved out of the body armour (e.g. for Kaom's Heart)
	local main = self.gen.mainGroup
	if main and main.slot and free[main.slot] then
		free[main.slot] = math.max(0, free[main.slot] - #main.gemList)
	end
	return free
end

-- Does the item in a slot support its socketed gems with a support matching
-- the pattern (e.g. March of the Legion's Divine Blessing)?
function GemSetupClass:SlotGrantsSupport(slotName, pattern)
	local itemsTab = self.build.itemsTab
	local slot = itemsTab.slots[slotName]
	local item = slot and itemsTab.items[slot.selItemId]
	for _, list in ipairs({ item and item.explicitModLines or { }, item and item.implicitModLines or { } }) do
		for _, line in ipairs(list) do
			-- ("Socketed Gems are supported by...", "Socketed Slam Gems / Spells are
			-- Supported by level...": any case, any kind of socketed gem)
			local text = line.line and line.line:lower()
			if text and (not item.CheckModLineVariant or item:CheckModLineVariant(line))
				and (text:match("^socketed .-supported by level %d+ " .. pattern:lower()) or (pattern == "Snipe" and text:match("^socketed .-triggered by snipe"))) then
				return true
			end
		end
	end
	return false
end

-- Slots whose item supports its gems with something that changes what a
-- utility gem does there (traps, totems, Generosity, triggers...): left out of
-- utility setups (blessing items are handled on their own)
function GemSetupClass:BehaviourSlot(slotName)
	if self.behaviourCache and self.behaviourCache[slotName] ~= nil then return self.behaviourCache[slotName] end
	self.behaviourCache = self.behaviourCache or { }
	local found = false
	for _, name in ipairs(GetGeneratorRules().behaviourSupports) do
		if name ~= "Divine Blessing" and name ~= "Eternal Blessing" and self:SlotGrantsSupport(slotName, name) then found = true break end
	end
	self.behaviourCache[slotName] = found
	return found
end

-- Slots whose item turns auras into blessings (one aura there, not a group)
function GemSetupClass:BlessingSlot(slotName)
	return self:SlotGrantsSupport(slotName, "Divine Blessing") or self:SlotGrantsSupport(slotName, "Eternal Blessing")
end

-- Smallest slot that still fits n gems (keeps big slots for auras);
-- filter(slotName) can exclude slots
function GemSetupClass:SlotFor(n, largest, filter)
	local best, bestFree
	for slotName, count in pairs(self:FreeSockets()) do
		if count >= n and (not filter or filter(slotName)) then
			if not best or (largest and count > bestFree) or (not largest and count < bestFree) or (count == bestFree and slotName < best) then
				best, bestFree = slotName, count
			end
		end
	end
	return best, bestFree
end

function GemSetupClass:Keep(label, gems, slot)
	local group = self:AddGroup(label, gems, slot)
	t_insert(self.groups, group)
	return group
end

------------------------------------------------------------------------------
-- Curses
------------------------------------------------------------------------------

-- Ways to apply a curse without casting it by hand
function GemSetupClass:CurseOptions(curseId)
	local gem = data.gems[curseId]
	local options = { }
	local tags = gem.tags or { }
	-- PoB counts a curse in full however it is applied, so each way carries what
	-- it costs in play (only for the choice; the build's numbers stay PoB's):
	--   uptime: share of a fight the curse is on the target
	--   actionCost: time taken from the main skill to keep it up (as score)
	-- Without these the free-looking Arcanist Brand won every time.
	local brandBuild = self.gen.mainGem and self.gen.mainGem.tags and self.gen.mainGem.tags.brand
	if tags.mark then
		-- (marks: applied by the attack's own hits; by hand for spells)
		t_insert(options, { label = gem.name .. " on Mark On Hit", gems = { curseId, gemId("Mark On Hit") }, actionCost = self:MainIsAttack() and 0 or 0.04 })
		t_insert(options, { label = gem.name .. " cast by hand", gems = { curseId }, actionCost = 0.05 })
	else
		-- Hextouch on a movement skill that hits (one the weapons allow): only
		-- cursed when the movement skill hits the target
		local carrier
		for _, name in ipairs(self:MainIsAttack() and { "Shield Charge", "Leap Slam", "Whirling Blades", "Frostblink" } or { "Frostblink" }) do
			if not carrier and self:CanUse(gemId(name)) then carrier = gemId(name) end
		end
		if carrier then
			t_insert(options, { label = gem.name .. " on Hextouch (" .. data.gems[carrier].name .. ")", gems = { carrier, gemId("Hextouch"), curseId }, movement = true, uptime = 0.7 })
		end
		-- (a brand cast every few seconds; free for a brand build's own casting)
		t_insert(options, { label = gem.name .. " on Arcanist Brand", gems = { gemId("Arcanist Brand"), curseId }, actionCost = brandBuild and 0.01 or 0.035 })
		-- (an aura: always on, paid in reservation, which the score sees)
		t_insert(options, { label = gem.name .. " on Blasphemy", gems = { curseId, gemId("Blasphemy") } })
		t_insert(options, { label = gem.name .. " cast by hand", gems = { curseId }, actionCost = 0.06 })
	end
	return options
end

function GemSetupClass:CurseLimit()
	local env = self.build.calcsTab.mainEnv
	local output = env and env.player.output
	return output and output.EnemyCurseLimit or 1
end

function GemSetupClass:ChooseCurses()
	local curses = { }
	for id, gem in pairs(data.gems) do
		if gem.tags and gem.tags.curse and gem.grantedEffect and not gem.grantedEffect.support and not gem.vaalGem and not gem.grantedEffect.unsupported then
			t_insert(curses, id)
		end
	end
	t_sort(curses)
	local current = self:Score()
	local used = { }
	for _ = 1, math.max(1, math.min(3, self:CurseLimit())) do
		local best, bestScore, bestRaw
		-- an Arcanist Brand already placed can carry another curse in a free linked socket
		local brandGroup
		local free = self:FreeSockets()
		for _, group in ipairs(self.groups) do
			if group.gemList[1] and group.gemList[1].gemId == gemId("Arcanist Brand") and group.slot and (free[group.slot] or 0) > 0 then
				brandGroup = group
			end
		end
		for _, id in ipairs(curses) do
			if not used[id] then
				for _, option in ipairs(self:CurseOptions(id)) do
					local valid = true
					for _, gid in ipairs(option.gems) do if not gid then valid = false end end
					if valid and self:SlotFor(#option.gems) then
						local gems = { }
						for _, gid in ipairs(option.gems) do t_insert(gems, gemEntry(gid)) end
						local raw = self:TryGroup(gems)
						local dpsWeight = self.gen.scorer and self.gen.scorer.focus and self.gen.scorer.focus.dps or 1
						local score = current + (raw - current) * (option.uptime or 1) - (option.actionCost or 0) * dpsWeight
						if os.getenv("DEBUG_CURSES") then ConPrintf("[curse] %-50s raw %+.3f adjusted %+.3f", option.label, raw - current, score - current) end
						if not bestScore or score > bestScore + 1e-9 then
							best, bestScore, bestRaw = { id = id, option = option, gems = gems }, score, raw
						end
					end
				end
				if brandGroup and not data.gems[id].tags.mark then
					local score = self:TryInGroup(brandGroup, gemEntry(id))
					if not bestScore or score > bestScore + 1e-9 then
						best, bestScore, bestRaw = { id = id, option = { label = data.gems[id].name .. " on the same Arcanist Brand" }, into = brandGroup }, score, score
					end
				end
				self.gen:Tick()
			end
		end
		if not best or bestScore <= current + 0.003 then break end
		if best.into then
			t_insert(best.into.gemList, gemEntry(best.id))
			self.skillsTab:ProcessSocketGroup(best.into)
		else
			self:Keep("Curse", best.gems, self:SlotFor(#best.gems))
		end
		used[best.id] = true
		if best.option.movement then self.hasMovement = true end
		current = bestRaw
		self.gen:Note("Curse setup: " .. best.option.label)
	end
end

------------------------------------------------------------------------------
-- Auras, heralds, golems
------------------------------------------------------------------------------

function GemSetupClass:AuraSupportOptions()
	local list = { }
	local investment = self.gen.options.investment or { }
	if investment.enlighten and gemId(investment.enlighten.name) then
		t_insert(list, { label = investment.enlighten.name .. " " .. investment.enlighten.level, entry = function() return gemEntry(gemId(investment.enlighten.name), investment.enlighten.level) end })
	end
	if gemId("Arrogance") and not self:LifeIsOne() then
		t_insert(list, { label = "Arrogance (life reservation)", entry = function() return gemEntry(gemId("Arrogance")) end })
	end
	return list
end

-- Does the character's ascendancy have passives for golems?
function GemSetupClass:AscendancyLovesGolems()
	local spec = self.build.spec
	for _, node in pairs(spec.nodes) do
		if node.ascendancyName and node.ascendancyName == spec.curAscendClassName then
			for _, line in ipairs(node.sd or { }) do
				if line:find("Golem", 1, true) then return true end
			end
		end
	end
	return false
end

function GemSetupClass:ChooseAuras(maxBuffs)
	local candidates = { }
	for id, gem in pairs(data.gems) do
		-- (attacks with an aura, like Smite, only give it while you use them)
		-- (as are mines / traps with an aura: only while they are placed)
		if gem.tags and (gem.tags.aura or gem.tags.herald or gem.tags.golem or gem.tags.banner) and not gem.tags.attack and not gem.tags.mine and not gem.tags.trap and not gem.tags.totem
			and gem.grantedEffect and not gem.grantedEffect.support and not gem.vaalGem and not gem.grantedEffect.unsupported then
			t_insert(candidates, id)
		end
	end
	t_sort(candidates)
	local function golemLimit()
		local env = self.build.calcsTab.mainEnv
		local extra = env and env.player.modDB:Sum("BASE", nil, "ActiveGolemLimit") or 0
		return 1 + extra
	end
	local supportOptions = self:AuraSupportOptions()
	local current = self:Score()
	local chosen, golems, count = { }, 0, 0
	local archetype = self.gen.options.archetype
	local archetypeAuras = archetype and archetype.auras or { }
	local forcedAura = false
	local auraGroup
	while count < (maxBuffs or 4) do
		-- the open aura group, linked with the first support option (Enlighten if available)
		if not auraGroup then
			-- (not in an item that makes its gems blessings: only one of those can be up)
			local slot, free = self:SlotFor(2, true, function(name) return not self:BlessingSlot(name) end)
			if not slot then break end
			local gems = { }
			if supportOptions[1] then t_insert(gems, supportOptions[1].entry()) end
			auraGroup = self:Keep("Auras", gems, slot)
			auraGroup.capacity = free
			auraGroup.supportIndex = supportOptions[1] and 1 or nil
		end
		local best, bestScore
		-- auras the archetype commits to come first, whatever they score alone
		-- (e.g. Hatred for a physical weapon build: the weapon follows later)
		for _, name in ipairs(archetypeAuras) do
			local id = gemId(name)
			if id and not chosen[id] and #auraGroup.gemList < auraGroup.capacity then
				best, bestScore = id, self:TryInGroup(auraGroup, gemEntry(id))
				forcedAura = true
				break
			end
		end
		for _, id in ipairs(best and { } or candidates) do
			local gem = data.gems[id]
			-- golems die and need looking after: only builds made for them (extra golem limit) use one
			-- (or an ascendancy built around them, e.g. Elementalist's Liege of the Primordial)
			local golemOk = not gem.tags.golem or (golems < golemLimit() and (golemLimit() > 1 or self:AscendancyLovesGolems()))
			if not chosen[id] and golemOk then
				local score
				if gem.tags.golem then
					-- golems don't need reservation supports: their own single socket
					if self:SlotFor(1) then score = self:TryGroup({ gemEntry(id) }) end
				elseif #auraGroup.gemList < auraGroup.capacity then
					score = self:TryInGroup(auraGroup, gemEntry(id))
				end
				if score and (not bestScore or score > bestScore + 1e-9) then
					best, bestScore = id, score
				end
			end
		end
		self.gen:Tick()
		if not best or (bestScore <= current + 0.005 and not forcedAura) then break end
		forcedAura = false
		local gem = data.gems[best]
		if gem.tags.golem then
			self:Keep("Golem", { gemEntry(best) }, self:SlotFor(1))
			golems = golems + 1
		else
			t_insert(auraGroup.gemList, gemEntry(best))
			self.skillsTab:ProcessSocketGroup(auraGroup)
			if #auraGroup.gemList >= auraGroup.capacity then
				auraGroup = nil -- full: the next aura opens a new group elsewhere
			end
		end
		chosen[best] = true
		count = count + 1
		current = bestScore
	end
	for _, group in ipairs(self.groups) do group.capacity = nil end
	-- each aura group: keep the support that scores best (Enlighten, Arrogance or none)
	local names = { }
	for _, group in ipairs(self.groups) do
		if group.label:match("^Auras") then
			local hasAura = false
			for _, g in ipairs(group.gemList) do
				if not data.gems[g.gemId].grantedEffect.support then hasAura = true end
			end
			if not hasAura then
				self:RemoveGroup(group)
				group.removed = true
			else
				local supportPos
				for i, g in ipairs(group.gemList) do
					if data.gems[g.gemId].grantedEffect.support then supportPos = i end
				end
				local bestLabel, bestEntry, bestS = nil, nil, nil
				local options = { { label = "no support" } }
				for _, o in ipairs(supportOptions) do t_insert(options, o) end
				if supportPos then t_remove(group.gemList, supportPos) end
				for _, o in ipairs(options) do
					local entry = o.entry and o.entry()
					if entry then t_insert(group.gemList, entry) end
					self.skillsTab:ProcessSocketGroup(group)
					local s = self:Score()
					if entry then t_remove(group.gemList) end
					if not bestS or s > bestS + 0.0005 then bestLabel, bestEntry, bestS = o.label, entry, s end
				end
				if bestEntry then t_insert(group.gemList, bestEntry) end
				self.skillsTab:ProcessSocketGroup(group)
				local auraNames = { }
				for _, g in ipairs(group.gemList) do t_insert(auraNames, data.gems[g.gemId].name) end
				t_insert(names, table.concat(auraNames, " + ") .. " (" .. group.slot .. ")")
				local _ = saved
			end
		elseif group.label:match("^Golem") then
			t_insert(names, data.gems[group.gemList[1].gemId].name .. " (" .. group.slot .. ")")
		end
	end
	for i = #self.groups, 1, -1 do
		if self.groups[i].removed then t_remove(self.groups, i) end
	end
	if #names > 0 then self.gen:Note("Buffs: " .. table.concat(names, "; ")) end
end

------------------------------------------------------------------------------
-- Guard, movement, Lifetap
------------------------------------------------------------------------------

-- Adds the best of a list of setups. Setups that PoB doesn't value are still
-- added when sockets are free (every real build has them), unless they cost score.
function GemSetupClass:ChooseBest(kind, options, allowNeutral)
	local current = self:Score()
	local best, bestScore
	for _, option in ipairs(options) do
		local valid = true
		for _, gid in ipairs(option.gems) do if not gid then valid = false end end
		if valid and self:SlotFor(#option.gems) then
			local gems = { }
			for _, gid in ipairs(option.gems) do t_insert(gems, gemEntry(gid)) end
			local score = self:TryGroup(gems)
			if not bestScore or score > bestScore + 1e-9 then
				best, bestScore = { option = option, gems = gems }, score
			end
		end
	end
	if not best then return nil end
	local gain = bestScore - current
	if gain > 0.002 or (allowNeutral and gain > -0.0005) then
		self:Keep(kind, best.gems, self:SlotFor(#best.gems))
		self.gen:Note(string.format("%s setup: %s%s", kind, best.option.label, gain > 0.002 and "" or " (not counted by PoB)"))
		return best
	end
end

-- A guard skill on an automatic trigger. Its buff isn't up all the time, so
-- the group is added switched off: the setup is there to use in game, but the
-- build's numbers don't count on it.
function GemSetupClass:ChooseGuard()
	local output = self.build.calcsTab.mainOutput or { }
	local guard = (output.Armour or 0) >= (output.Evasion or 0) and "Molten Shell" or "Steelskin"
	local trigger = gemId("Cast when Damage Taken")
	if not (gemId(guard) and trigger) then return end
	local slot = self:SlotFor(2)
	if not slot then return end
	local group = self:Keep("Guard (switched off: not a permanent buff)", { gemEntry(trigger), gemEntry(gemId(guard)) }, slot)
	group.enabled = false
	self.skillsTab:ProcessSocketGroup(group)
	self.gen:Note(string.format("Guard setup: %s on Cast when Damage Taken (switched off in PoB so the numbers don't count on it)", guard))
end

function GemSetupClass:ChooseMovement()
	if self.hasMovement then return end
	local options = { }
	local function add(label, names)
		local gems = { }
		for _, name in ipairs(names) do
			local id = gemId(name)
			if not id or (not data.gems[id].grantedEffect.support and not self:CanUse(id)) then return end
			t_insert(gems, id)
		end
		t_insert(options, { label = label, gems = gems })
	end
	if self:HasShield() and gemId("Shield Charge") and self:CanUse(gemId("Shield Charge")) then
		-- any build with a shield (spells too): Shield Charge is the fastest way to
		-- move, plus a Frostblink for walls and gaps
		add("Shield Charge + Faster Attacks", { "Shield Charge", "Faster Attacks" })
	elseif self:MainIsAttack() then
		add("Leap Slam + Faster Attacks", { "Leap Slam", "Faster Attacks" })
		add("Whirling Blades + Faster Attacks", { "Whirling Blades", "Faster Attacks" })
		add("Blink Arrow + Faster Attacks", { "Blink Arrow", "Faster Attacks" })
		add("Dash + Second Wind", { "Dash", "Second Wind" })
	end
	if #options == 0 then
		add("Flame Dash + Faster Casting", { "Flame Dash", "Faster Casting" })
		add("Frostblink + Faster Casting", { "Frostblink", "Faster Casting" })
	end
	local chosen = self:ChooseBest("Movement", options, true)
	if chosen and chosen.option.label:match("^Shield Charge") then
		self:ChooseBest("Blink", { { label = "Frostblink", gems = { gemId("Frostblink") } } }, true)
	end
	-- Blood Rage for attack builds when PoB values it (attack speed, frenzy charges);
	-- its life degeneration is pointless at 1 life (Chaos Inoculation)
	if self:MainIsAttack() and not self:LifeIsOne() then
		self:ChooseBest("Blood Rage", { { label = "Blood Rage", gems = { gemId("Blood Rage") } } }, false)
	end
end

-- Bow builds: Manaforged Arrows fires a second bow skill as mana is spent on the
-- main one, applying its debuff for free (caustic ground, shock, exposure...).
-- PoB doesn't add the triggered skill to the main skill's numbers.
function GemSetupClass:ChooseManaforged()
	local main = self.gen.mainGem
	local weaponTypes = main and main.grantedEffect.weaponTypes
	local trigger = gemId("Manaforged Arrows")
	if not (weaponTypes and weaponTypes.Bow and trigger) then return end
	local options = { }
	for _, name in ipairs({ "Caustic Arrow", "Galvanic Arrow", "Ice Shot", "Toxic Rain", "Explosive Arrow" }) do
		local id = gemId(name)
		if id and id ~= self.gen.options.gemId and data.gems[id].name ~= main.name and self:CanUse(id) then
			t_insert(options, { label = name .. " on Manaforged Arrows", gems = { id, trigger } })
		end
	end
	self:ChooseBest("Secondary bow skill", options, true)
end

-- Animate Guardian: a permanent minion wearing buff uniques. PoB doesn't count
-- the buffs from its items, so it's added for high-end builds with free
-- sockets, and noted otherwise.
function GemSetupClass:ChooseAnimateGuardian()
	local id = gemId("Animate Guardian")
	if not id then return end
	local investment = self.gen.options.investment or { }
	local support = gemId("Meat Shield")
	if investment.awakenedGems and self:SlotFor(2) and support then
		self:Keep("Animate Guardian", { gemEntry(id), gemEntry(support) }, self:SlotFor(2))
		self.gen:Note("Animate Guardian setup: Animate Guardian + Meat Shield; give it buff uniques (e.g. Kingmaker, Leer Cast, Victario's Influence) - PoB doesn't count their buffs")
	else
		self.gen:Note("Possible addition: Animate Guardian (+ Meat Shield) wearing buff uniques like Kingmaker or Victario's Influence, if sockets are free (PoB doesn't count it)")
	end
end

-- Empty sockets: useful setups, automatic ones first (warcries on
-- Autoexertion, spells on Automation, a blessing in a Divine Blessing item,
-- Vaal auras), each kept if it helps or costs nothing
function GemSetupClass:ChooseFillers()
	local options = { }
	local function add(label, names, auto)
		local gems = { }
		for _, name in ipairs(names) do
			local id = gemId(name)
			if not id or (not data.gems[id].grantedEffect.support and not self:CanUse(id)) then return end
			t_insert(gems, id)
		end
		t_insert(options, { label = label, gems = gems, auto = auto })
	end
	local used = { }
	for _, group in ipairs(self.skillsTab.socketGroupList) do
		for _, g in ipairs(group.gemList or { }) do if g.gemId then used[g.gemId] = true end end
	end
	local function free(name) local id = gemId(name) return id and not used[id] end
	-- warcries on Autoexertion (used automatically, exerting the next attacks)
	local cries = { "Enduring Cry", "Battlemage's Cry", "Rallying Cry", "Intimidating Cry", "Ancestral Cry", "General's Cry", "Seismic Cry" }
	if free("Autoexertion") then
		for i, a in ipairs(cries) do
			if free(a) then
				add("Autoexertion + " .. a, { "Autoexertion", a }, true)
				for j = i + 1, #cries do
					if free(cries[j]) then add("Autoexertion + " .. a .. " + " .. cries[j], { "Autoexertion", a, cries[j] }, true) end
				end
			end
		end
	end
	-- spells cast automatically on cooldown
	if free("Automation") then
		for _, spell in ipairs({ "Wave of Conviction", "Frost Bomb", "Arctic Armour", "Tempest Shield", "Sigil of Power" }) do
			if free(spell) then add("Automation + " .. spell, { "Automation", spell }, true) end
		end
	end
	local kept = { }
	for _ = 1, 6 do
		local current = self:Score()
		local best, bestScore
		for _, option in ipairs(options) do
			if not option.taken and self:SlotFor(#option.gems) then
				local gems = { }
				for _, gid in ipairs(option.gems) do t_insert(gems, gemEntry(gid)) end
				local score = self:TryGroup(gems)
				-- (automatic setups are worth a slot even when PoB can't count them)
				local value = score + (option.auto and 0.001 or 0)
				if not bestScore or value > bestScore + 1e-9 then best, bestScore = option, value end
			end
		end
		if not best or bestScore - current < (best.auto and -0.0005 or 0.002) then break end
		local gems = { }
		for _, gid in ipairs(best.gems) do t_insert(gems, gemEntry(gid)) end
		self:Keep("Filler", gems, self:SlotFor(#best.gems))
		best.taken = true
		-- a gem can only be used once
		for _, option in ipairs(options) do
			for _, a in ipairs(option.gems) do
				for _, b in ipairs(best.gems) do
					if a == b and not data.gems[a].grantedEffect.support then option.taken = true end
				end
			end
		end
		t_insert(kept, best.label)
	end
	-- a Vaal aura for bosses, switched off like the guard (PoB would count it as
	-- always up): the first that fits a free socket
	for _, vaal in ipairs({ "Vaal Haste", "Vaal Grace", "Vaal Discipline" }) do
		local id = gemId(vaal)
		local slot = self:SlotFor(1)
		if id and free(vaal) and slot then
			local group = self:Keep("Vaal aura (switched off: used by hand)", { gemEntry(id) }, slot)
			group.enabled = false
			self.skillsTab:ProcessSocketGroup(group)
			t_insert(kept, vaal .. " (by hand on bosses, not counted)")
			break
		end
	end
	-- an item that makes its gems blessings: the best single aura there
	for slotName, count in pairs(self:FreeSockets()) do
		if count >= 1 and self:BlessingSlot(slotName) then
			local current = self:Score()
			local best, bestScore
			for id, gem in pairs(data.gems) do
				if gem.tags and gem.tags.aura and not gem.tags.vaal and not gem.tags.attack and not gem.tags.totem and not gem.tags.mine
					and gem.grantedEffect and not gem.grantedEffect.support and not used[id] then
					local group = self:AddGroup("try", { gemEntry(id) }, slotName)
					local score = self:Score()
					self:RemoveGroup(group)
					if not bestScore or score > bestScore + 1e-9 then best, bestScore = id, score end
				end
			end
			if best and bestScore > current + 0.002 then
				self:Keep("Blessing", { gemEntry(best) }, slotName)
				t_insert(kept, data.gems[best].name .. " as a blessing (" .. slotName .. ")")
			end
		end
	end
	if #kept > 0 then self.gen:Note("Empty sockets filled: " .. table.concat(kept, "; ")) end
end

-- Lifetap into a utility group (its buff counts for the whole build)
function GemSetupClass:ChooseLifetap()
	local id = gemId("Lifetap")
	if not id or self:LifeIsOne() then return end
	local current = self:Score()
	local best, bestScore
	local free = self:FreeSockets()
	for _, group in ipairs(self.groups) do
		if not group.label:match("^Auras") and not group.label:match("^Golem") and group.slot and (free[group.slot] or 0) > 0 then
			local score = self:TryInGroup(group, gemEntry(id))
			if not bestScore or score > bestScore + 1e-9 then best, bestScore = group, score end
		end
	end
	if best and bestScore > current + 0.002 then
		t_insert(best.gemList, gemEntry(id))
		self.skillsTab:ProcessSocketGroup(best)
		self.gen:Note("Lifetap linked with: " .. best.label:gsub(" %(generated utility%)", ""))
	end
end

-- ignoreAttributes: score setups without attribute requirement penalties
-- (used before the rares are made, which then supply the attributes)
function GemSetupClass:Run(maxBuffs, ignoreAttributes)
	local scorer = self.gen.scorer
	local savedIgnore = scorer.ignoreAttributes
	scorer.ignoreAttributes = ignoreAttributes or nil
	self:Clear()
	self.hasMovement = false
	self.gen:Recalculate()
	self:ChooseCurses()
	self:ChooseAuras(maxBuffs)
	self:ChooseGuard()
	self:ChooseMovement()
	self:ChooseManaforged()
	self:ChooseAnimateGuardian()
	self:ChooseLifetap()
	self:ChooseFillers()
	scorer.ignoreAttributes = savedIgnore
	self.gen:Recalculate()
	local free = self:FreeSockets()
	local parts = { }
	for _, slotName in ipairs(utilitySlots) do
		if free[slotName] and self:SlotSockets(slotName) > 0 then
			t_insert(parts, string.format("%s %d/%d", slotName, self:SlotSockets(slotName) - free[slotName], self:SlotSockets(slotName)))
		end
	end
	local main = self.gen.mainGroup
	if main.slot == "Body Armour" then
		self.gen:Note("Sockets used: Body Armour " .. #main.gemList .. "/6 (main skill), " .. table.concat(parts, ", "))
	else
		self.gen:Note("Sockets used (main skill in the " .. tostring(main.slot) .. "): " .. table.concat(parts, ", "))
	end
end
