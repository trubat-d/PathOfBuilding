-- Path of Building
--
-- Class: Unique Combo Finder
-- Two-piece unique combos, where neither piece is worth it alone:
--   1. pair search: the most promising uniques of each gear slot (scored one
--      at a time, slightly negative ones included) are scored again two at a
--      time in different slots; pairs whose joint gain beats the sum of their
--      gains alone (synergy) become packages;
--   2. enablers and payoffs: some uniques grant a state (Elusive, Onslaught,
--      Unholy Might, Arcane Surge, Phasing, Adrenaline...) and others pay off
--      while in it ("while Elusive", "during Onslaught"...). PoB only counts a
--      payoff when the configuration says the state is on, so such pairs look
--      worthless one at a time; here the state is switched on when the pair
--      has an enabler, and AutoConfig keeps it on for a build that has one
--      (UniqueComboFinder.SelfBuffs).
-- Packages go through BuildGenerator:EvaluatePackages: applied for real, the
-- build adapted around them, the best kept if the build is better.
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert
local t_sort = table.sort
local m_min = math.min
local m_max = math.max

---@class UniqueComboFinder
local UniqueComboFinderClass = newClass("UniqueComboFinder")

-- States a build can give itself, the lines that grant them (enablers) and
-- the lines that pay off while in them. Patterns match lower-cased lines.
UniqueComboFinderClass.states = {
	{ var = "buffElusive", label = "Elusive", enable = { "gain elusive", "you are elusive", "grants elusive" }, payoff = { "while elusive", "while you are elusive" } },
	{ var = "buffOnslaught", label = "Onslaught", enable = { "gain onslaught", "you have onslaught", "grants onslaught" }, payoff = { "while you have onslaught", "during onslaught", "if you have onslaught" } },
	{ var = "buffUnholyMight", label = "Unholy Might", enable = { "gain unholy might", "you have unholy might", "grants unholy might" }, payoff = { "while you have unholy might", "during unholy might" } },
	{ var = "buffArcaneSurge", label = "Arcane Surge", enable = { "gain arcane surge", "grants arcane surge" }, payoff = { "while you have arcane surge", "arcane surge on you", "effect of arcane surge" } },
	{ var = "buffPhasing", label = "Phasing", enable = { "gain phasing", "you have phasing", "grants phasing" }, payoff = { "while phasing", "while you have phasing" } },
	{ var = "buffAdrenaline", label = "Adrenaline", enable = { "gain adrenaline" }, payoff = { "while you have adrenaline" } },
	{ var = "buffChaoticMight", label = "Chaotic Might", enable = { "gain chaotic might", "grants chaotic might" }, payoff = { "while you have chaotic might" } },
	{ var = "buffDivinity", label = "Divinity", enable = { "gain divinity", "gain a divine charge on hit" }, payoff = { "while you have divinity" } },
	{ var = "conditionOnConsecratedGround", label = "Consecrated Ground", enable = { "create consecrated ground", "creates consecrated ground", "you have consecrated ground around you" }, payoff = { "while on consecrated ground", "on consecrated ground" } },
}

-- the chance a line gives a state, and whether it only comes from kills
local function enablerChance(line)
	local chance = tonumber(line:match("(%d+)%% chance")) or 100
	return chance, line:find("on kill", 1, true) ~= nil
end

-- What makes a line give its state: "kill" (on kill, on rampage), "crit",
-- "hit", "event" (something else happening: a block, a flask, reaching low
-- life, ward breaking, a warcry, being hit...), "conditional" (only while or
-- if something holds) or "always"
local function triggerOf(line)
	local function has(...) for _, w in ipairs({ ... }) do if line:find(w, 1, true) then return true end end return false end
	if has("on kill", "when you kill", "on melee kill", "on rampage") then return "kill" end
	if has("on critical strike", "when you deal a critical strike", "on crit") then return "crit" end
	if has("on hit", "when you hit", "when you or your totems hit") then return "hit" end
	if has(" when ", " after ", " every ", " on reaching", " on use", " on block", "when hit", " on ") then return "event" end
	if has(" while ", " if ", " during ") then return "conditional" end
	return "always"
end
UniqueComboFinderClass.TriggerOf = triggerOf

-- States the build keeps up from its own lines (for AutoConfig): { { var,
-- on, reason } }. A state from kills only counts while mapping; a chance on
-- hit (or on crit, with the crit chance) is turned into uptime at the main
-- skill's hit rate over the state's duration (4 seconds when not given); a
-- state from another event (a block, a flask, reaching low life, ward
-- breaking...) or only under a condition isn't counted as kept up
function UniqueComboFinderClass.SelfBuffs(lines, hitRate, boss, crit)
	local list = { }
	for _, state in ipairs(UniqueComboFinderClass.states) do
		local best, source = 0, nil
		for _, line in ipairs(lines) do
			for _, pattern in ipairs(state.enable) do
				-- (not a line that triggers on the state: "24% chance to lose a power
				-- charge when you gain elusive" gives no Elusive)
				if line:find(pattern, 1, true) and not line:find("enemies", 1, true) and not line:find("allies", 1, true)
					and not line:find("when you " .. pattern, 1, true) and not line:find("on " .. pattern, 1, true) and not line:find("lose", 1, true) then
					local chance = enablerChance(line)
					local trigger = triggerOf(line)
					local p = m_min(1, chance / 100)
					local duration = tonumber(line:match("for (%d+) seconds")) or 4
					local uptime = 0
					if trigger == "always" then
						uptime = 1
					elseif trigger == "kill" then
						uptime = boss and 0 or (p >= 1 and 1 or 1 - (1 - p) ^ (10 * duration / 4))
					elseif trigger == "hit" or trigger == "crit" then
						if trigger == "crit" then p = p * m_min(1, crit or 0) end
						uptime = p >= 1 and 1 or (1 - (1 - p) ^ (m_max(0.5, hitRate or 1) * duration))
					end
					if uptime > best then best, source = uptime, line end
				end
			end
		end
		if source and best >= (boss and 0.8 or 0.6) then
			t_insert(list, { var = state.var, on = true, reason = string.format("%s from \"%s\" (up %.0f%% of the time)", state.label, source, best * 100) })
		end
	end
	return list
end

-- gen: the BuildGenerator (Score, options, itemsTab, lockedSlots)
function UniqueComboFinderClass:UniqueComboFinder(gen)
	self.gen = gen
	self.build = gen.build
	self.itemsTab = gen.itemsTab
	return self
end

local function lowerLines(item)
	local list = { }
	for _, modLine in ipairs(item.explicitModLines or { }) do
		local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
		if current and modLine.line then t_insert(list, modLine.line:lower()) end
	end
	return list
end

-- States found in the game data: a condition some unique grants outright (a
-- "Condition:X" flag with no condition of its own) and other uniques pay off
-- ("... while X", a modifier needing Condition X). The pair is measured as
-- it is (PoB counts the granted condition), so no configuration switch.
local dataStates
function UniqueComboFinderClass.DataStates()
	if dataStates then return dataStates end
	dataStates = { }
	local known = { }
	for _, state in ipairs(UniqueComboFinderClass.states) do known[(state.var or ""):gsub("^buff", ""):gsub("^condition", "")] = true end
	local enablers, payoffs = { }, { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		for _, modLine in ipairs(item.explicitModLines or { }) do
			local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
			for _, mod in ipairs(current and modLine.modList or { }) do
				local cond = mod.type == "FLAG" and mod.name:match("^Condition:(%a+)$")
				if cond and #mod == 0 then
					enablers[cond] = enablers[cond] or { }
					enablers[cond][title] = true
				end
				for _, tag in ipairs(mod) do
					if type(tag) == "table" and tag.type == "Condition" and tag.var and not tag.neg then
						payoffs[tag.var] = payoffs[tag.var] or { }
						payoffs[tag.var][title] = true
					end
				end
			end
		end
	end
	for cond, titles in pairs(enablers) do
		if payoffs[cond] and not known[cond] then
			t_insert(dataStates, { label = cond, enableTitles = titles, payTitles = payoffs[cond], data = true })
		end
	end
	t_sort(dataStates, function(a, b) return a.label < b.label end)
	return dataStates
end

-- Which states an item enables / pays off: { [state] = true }, { [state] = true }
local function itemStates(item)
	local enables, pays = { }, { }
	local title = item.title or item.name
	for _, state in ipairs(UniqueComboFinderClass.DataStates()) do
		if state.enableTitles[title] then enables[state] = true end
		if state.payTitles[title] then pays[state] = true end
	end
	for _, line in ipairs(lowerLines(item)) do
		for _, state in ipairs(UniqueComboFinderClass.states) do
			for _, pattern in ipairs(state.enable) do
				-- (not a line that triggers on the state: "24% chance to lose a power
				-- charge when you gain elusive" gives no Elusive)
				if line:find(pattern, 1, true) and not line:find("enemies", 1, true) and not line:find("allies", 1, true)
					and not line:find("when you " .. pattern, 1, true) and not line:find("on " .. pattern, 1, true) and not line:find("lose", 1, true) then
					-- (a state kept up: always, or from hits and crits - not from a
					-- block, a flask, reaching low life... nor only under a condition)
					local trigger = triggerOf(line)
					if trigger == "always" or trigger == "hit" or trigger == "crit" then enables[state] = true end
				end
			end
			for _, pattern in ipairs(state.payoff) do
				if line:find(pattern, 1, true) then pays[state] = true end
			end
		end
	end
	return enables, pays
end

-- Candidate packages: { { label, uniques = { a, b }, share = 0, reason } }, best first
-- opts: perSlot (singles kept per slot, default 15), maxPairs (pair
-- calculations, default 400), keep (packages returned, default 4)
function UniqueComboFinderClass:Find(opts)
	opts = opts or { }
	local gen = self.gen
	local itemsTab = self.itemsTab
	local finder = new("BestItemFinder"):BestItemFinder(itemsTab)
	local filter = { obtainableOnly = true, levelOnly = true, investment = gen.options.investment }
	local prices = GetPriceSource()
	local locked = gen.lockedSlots or { }
	-- gear slots only, weapons left out (a pair would have to agree with the
	-- weapon setup: the weapon stages handle them)
	local slots = { }
	for _, slotName in ipairs(finder:GetActiveSlots()) do
		if not slotName:match("^Weapon") and not locked[slotName] then t_insert(slots, slotName) end
	end
	local equippedTitles = { }
	for _, slot in pairs(itemsTab.slots) do
		local item = itemsTab.items[slot.selItemId]
		if item and item.title then equippedTitles[item.title] = true end
	end
	local candidates = { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		if item.type ~= "Jewel" and item.type ~= "Flask" and item.type ~= "Tincture" and not equippedTitles[title]
			and prices.Available(gen.options.investment, title) and finder:IsItemAllowed(item, filter) then
			t_insert(candidates, item)
		end
	end
	t_sort(candidates, function(a, b) return (a.title or a.name) < (b.title or b.name) end)
	gen:Recalculate()
	local current = gen:Score()
	-- 1. every candidate alone, in each slot it fits
	local singles = { }   -- list of { item, slot, gain, enables, pays }
	local bySlot = { }
	for _, slotName in ipairs(slots) do bySlot[slotName] = { } end
	for _, item in ipairs(candidates) do
		local enables, pays = itemStates(item)
		for _, slotName in ipairs(slots) do
			if itemsTab:IsItemValidForSlot(item, slotName) then
				local gain = gen:Score({ repSlotName = slotName, repItem = item }) - current
				local entry = { item = item, slot = slotName, gain = gain, enables = enables, pays = pays }
				t_insert(bySlot[slotName], entry)
			end
		end
	end
	local perSlot = opts.perSlot or 15
	local pool = { }
	for _, slotName in ipairs(slots) do
		local list = bySlot[slotName]
		t_sort(list, function(a, b)
			if math.abs(a.gain - b.gain) > 1e-9 then return a.gain > b.gain end
			return (a.item.title or a.item.name) < (b.item.title or b.item.name)
		end)
		local kept = 0
		for _, e in ipairs(list) do
			-- (the best few, slightly worse ones too, and every enabler / payoff
			-- that isn't far off: a payoff looks worthless until its state is on)
			local special = next(e.enables) or next(e.pays)
			if (kept < perSlot and e.gain > -0.3) or (special and e.gain > -0.6) then
				t_insert(pool, e)
				kept = kept + 1
			end
		end
	end
	-- 2. pairs in different slots (two rings count as different slots)
	local pairsList = { }
	local function stateVars(a, b)
		local vars, dataLinked = { }, false
		for state in pairs(a.enables) do if b.pays[state] or a.pays[state] then if state.var then vars[state.var] = true else dataLinked = true end end end
		for state in pairs(b.enables) do if a.pays[state] or b.pays[state] then if state.var then vars[state.var] = true else dataLinked = true end end end
		return vars, dataLinked
	end
	local input = self.build.configTab.input
	local function scoreWith(vars, override)
		-- the states the pair enables switched on for its score
		local saved, any = { }, false
		for var in pairs(vars) do
			saved[var] = input[var]
			if not input[var] then input[var] = true; any = true end
		end
		if any then self.build.configTab:BuildModList() end
		local score = gen:Score(override)
		if any then
			for var, v in pairs(saved) do input[var] = v end
			self.build.configTab:BuildModList()
		end
		return score
	end
	-- pairs worth a calculation: two strong ones, or an enabler with a payoff;
	-- pairs earlier generations found working together first (Modules/GeneratorModel)
	local okModel, model = pcall(LoadModule, "Modules/GeneratorModel")
	if not okModel or not model or not model.Load() then model = nil end
	local candidatesPairs = { }
	for i = 1, #pool do
		for j = i + 1, #pool do
			local a, b = pool[i], pool[j]
			if a.slot ~= b.slot and a.item ~= b.item and (a.item.title or a.item.name) ~= (b.item.title or b.item.name) then
				local vars, dataLinked = stateVars(a, b)
				local linked = next(vars) ~= nil or dataLinked
				local priority = (linked and 1 or 0) + a.gain + b.gain
				local learnt = model and model.PairSynergy(a.item.title or a.item.name, b.item.title or b.item.name)
				if learnt then priority = priority + 5 * learnt end
				t_insert(candidatesPairs, { a = a, b = b, vars = vars, linked = linked, priority = priority })
			end
		end
	end
	t_sort(candidatesPairs, function(x, y)
		if x.linked ~= y.linked then return x.linked end
		if math.abs(x.priority - y.priority) > 1e-9 then return x.priority > y.priority end
		local xa, ya = (x.a.item.title or "") .. (x.b.item.title or ""), (y.a.item.title or "") .. (y.b.item.title or "")
		if xa ~= ya then return xa < ya end
		return x.a.slot .. x.b.slot < y.a.slot .. y.b.slot
	end)
	local maxPairs = opts.maxPairs or 400
	if gen.options.debugTiming then
		local linked = 0
		for _, p in ipairs(candidatesPairs) do if p.linked then linked = linked + 1 end end
		ConPrintf("[combos] %d candidates, %d in the pool, %d pairs (%d enabler + payoff)", #candidates, #pool, #candidatesPairs, linked)
		for i = 1, m_min(8, #candidatesPairs) do
			local p = candidatesPairs[i]
			if p.linked then ConPrintf("  linked: %s (%s) + %s (%s)", p.a.item.title, p.a.slot, p.b.item.title, p.b.slot) end
		end
	end
	for n, p in ipairs(candidatesPairs) do
		if n > maxPairs then break end
		local joint = scoreWith(p.vars, { repItems = { [p.a.slot] = p.a.item, [p.b.slot] = p.b.item } }) - current
		local synergy = joint - p.a.gain - p.b.gain
		-- (decision log: every pair measured, the training data of a pair model)
		if gen.decisions then
			gen:Decision("unique_pair", (p.a.item.title or "?") .. " + " .. (p.b.item.title or "?"), joint, synergy > 0.01,
				{ slots = { p.a.slot, p.b.slot }, ga = math.floor(p.a.gain * 1e5 + 0.5) / 1e5, gb = math.floor(p.b.gain * 1e5 + 0.5) / 1e5,
					syn = math.floor(synergy * 1e5 + 0.5) / 1e5, linked = p.linked or nil, priority = p.priority and math.floor(p.priority * 1e5 + 0.5) / 1e5 or nil })
		end
		if joint > 0.01 and synergy > 0.01 and joint > m_max(p.a.gain, p.b.gain) + 0.01 then
			t_insert(pairsList, { a = p.a, b = p.b, joint = joint, synergy = synergy, linked = p.linked, vars = p.vars })
		end
		if n % 20 == 0 then gen:Tick() end
	end
	t_sort(pairsList, function(x, y)
		if math.abs(x.joint - y.joint) > 1e-9 then return x.joint > y.joint end
		return (x.a.item.title or "") .. (x.b.item.title or "") < (y.a.item.title or "") .. (y.b.item.title or "")
	end)
	-- 3. the best few as packages (each unique once)
	local packages, used = { }, { }
	for _, p in ipairs(pairsList) do
		if #packages >= (opts.keep or 4) then break end
		local ta, tb = p.a.item.title or p.a.item.name, p.b.item.title or p.b.item.name
		if not used[ta] and not used[tb] then
			used[ta], used[tb] = true, true
			local states = { }
			for _, state in ipairs(UniqueComboFinderClass.states) do
				if p.vars[state.var] then t_insert(states, state.label) end
			end
			t_insert(packages, {
				label = string.format("%s + %s", ta, tb),
				uniques = { p.a.item, p.b.item }, share = 0,
				reason = string.format("together %+.2f, alone %+.2f and %+.2f%s", p.joint, p.a.gain, p.b.gain,
					#states > 0 and (" (" .. table.concat(states, ", ") .. " from one, paid off by the other)") or ""),
			})
		end
	end
	self.pairsTried = m_min(#candidatesPairs, maxPairs)
	return packages
end
