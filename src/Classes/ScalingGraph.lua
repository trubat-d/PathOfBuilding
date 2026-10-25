-- Path of Building
--
-- Class: Scaling Graph
-- Which scaling vector each unique acts on, read from PoB's own parse of its
-- lines, and which uniques feed each other. A mod's tags say it all:
--   - the layer it scales: crit, speed, enemy (penetration, resistance,
--     damage taken), increased, more, flat added damage, gain as extra,
--     damage over time multiplier, charges, pools, attributes;
--   - what it consumes: "per Power Charge" (Multiplier: PowerCharge), "per
--     10 Intelligence" (PerStat: Int);
--   - what it produces: maximum power charges, Intelligence, energy shield...;
--     converts ("Your Maximum Frenzy Charges is equal to your Maximum Power
--     Charges": power -> frenzy); enables ("Count as having maximum number of
--     Power Charges"; "gain a frenzy charge on reaching maximum power charges").
-- Uniques are nodes, an edge joins a producer (or enabler, converter) of a
-- stat to a consumer of it. A stat several uniques consume is a vector worth
-- stacking; the group that feeds it is a package to try whole - its worth is
-- an interaction (together minus each alone), which picking one piece at a
-- time never sees. A unique joined to nothing is standalone: it must win on
-- its own numbers.
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert
local t_sort = table.sort

---@class ScalingGraph
local ScalingGraphClass = newClass("ScalingGraph")

function ScalingGraphClass:ScalingGraph()
	self.cache = { }
	return self
end

-- Multiplier variables -> the stat that feeds them
local multiplierStat = {
	PowerCharge = "PowerCharges", FrenzyCharge = "FrenzyCharges", EnduranceCharge = "EnduranceCharges",
	RemovablePowerCharge = "PowerCharges", RemovableFrenzyCharge = "FrenzyCharges", RemovableEnduranceCharge = "EnduranceCharges",
	Rage = "Rage", ImpaleStacks = "Impale", WitheredStack = "Wither",
}
-- Produced stats: mod name -> stat key
local producedStat = {
	PowerChargesMax = "PowerCharges", FrenzyChargesMax = "FrenzyCharges", EnduranceChargesMax = "EnduranceCharges",
	Int = "Int", Str = "Str", Dex = "Dex", Life = "Life", Mana = "Mana", EnergyShield = "EnergyShield",
	Evasion = "Evasion", Armour = "Armour", BlockChance = "BlockChance", SpellBlockChance = "SpellBlockChance",
	MaximumRage = "Rage", ImpaleStacksMax = "Impale",
}
local chargeKind = { Power = "PowerCharges", Frenzy = "FrenzyCharges", Endurance = "EnduranceCharges" }

-- The layer a mod scales (from its name and type)
local function layerOf(mod)
	local n, t = mod.name or "", mod.type
	if n:match("^CritChance") or n:match("^CritMultiplier") then return "crit" end
	if n:match("Penetration$") or n:match("Resist$") and mod.source == "enemy" then return "enemy" end
	if n:match("DamageTaken") then return "enemy" end
	if n == "Speed" or n:match("CastSpeed") or n:match("AttackSpeed") then return "speed" end
	if n:match("DotMultiplier$") then return "dotMulti" end
	if n:match("GainAs") or n:match("ConvertTo") then return "extra" end
	if n:match("Min$") or n:match("Max$") and not n:match("ChargesMax$") then
		if t == "BASE" and (n:match("^Physical") or n:match("^Fire") or n:match("^Cold") or n:match("^Lightning") or n:match("^Chaos")) then return "flat" end
	end
	if n:match("ChargesMax$") then return "charges" end
	if n == "Life" or n == "Mana" or n == "EnergyShield" then return "pool" end
	if n == "Int" or n == "Str" or n == "Dex" then return "attribute" end
	if n:match("Damage$") or n:match("Damage") then
		if t == "MORE" then return "more" end
		if t == "INC" then return "increased" end
	end
	if n == "EnemyModifier" then return "enemy" end
	return nil
end

-- One unique analysed: { title, layers, consumes, produces, enables, converts, lines }
function ScalingGraphClass:Analyze(item)
	local key = item.title or item.name
	if self.cache[key] then return self.cache[key] end
	local a = { title = key, item = item, layers = { }, consumes = { }, produces = { }, enables = { }, converts = { }, lines = { } }
	for _, modLine in ipairs(item.explicitModLines or { }) do
		local current = not modLine.variantList or (item.variant and modLine.variantList[item.variant])
		local line = modLine.line
		if current and line then
			-- (the item's own parse, ranges rolled; parsed here when missing)
			local modList = modLine.modList
			if not modList or #modList == 0 then modList = modLib.parseMod(line) end
			local used = false
			for _, mod in ipairs(modList or { }) do
				local layer = layerOf(mod)
				if layer then a.layers[layer] = true end
				for _, tag in ipairs(mod) do
					if type(tag) == "table" then
						local stat = tag.type == "Multiplier" and tag.var and (multiplierStat[tag.var] or tag.var)
							or tag.type == "PerStat" and tag.stat and (producedStat[tag.stat] or tag.stat)
						if stat then a.consumes[stat] = (a.consumes[stat] or 0) + 1 used = true end
					end
				end
				local produced = producedStat[mod.name]
				if produced and (mod.type == "BASE" or mod.type == "INC" or mod.type == "MORE") and #mod == 0 and (tonumber(mod.value) or 0) > 0 then
					a.produces[produced] = true used = true
				end
				-- "count as having maximum number of power charges"
				local have = (mod.name or ""):match("^HaveMaximum(%a+)Charges$")
				if have and chargeKind[have] then a.enables[chargeKind[have]] = true used = true end
				-- "your maximum frenzy charges is equal to your maximum power charges"
				local to, from = (mod.name or ""):match("^Maximum(%a+)ChargesIsMaximum(%a+)Charges$")
				if to and chargeKind[to] and chargeKind[from] then a.converts[chargeKind[from]] = chargeKind[to] used = true end
			end
			-- lines PoB doesn't parse into mods: charge generators
			local l = line:lower()
			for kind, stat in pairs(chargeKind) do
				if l:find("gain an? " .. kind:lower() .. " charge") and not l:find("kill") then a.enables[stat] = true used = true end
			end
			if used then t_insert(a.lines, line) end
		end
	end
	self.cache[key] = a
	return a
end

-- The graph of a list of uniques: per stat, who produces / enables /
-- converts into it and who consumes it. Returns { stats = { [stat] = {
-- producers, enablers, consumers } }, nodes = { analyses } }
function ScalingGraphClass:Graph(items)
	local stats, nodes = { }, { }
	local function entry(stat)
		stats[stat] = stats[stat] or { producers = { }, enablers = { }, consumers = { }, converters = { } }
		return stats[stat]
	end
	for _, item in ipairs(items) do
		local a = self:Analyze(item)
		t_insert(nodes, a)
		for stat, n in pairs(a.consumes) do t_insert(entry(stat).consumers, a) end
		for stat in pairs(a.produces) do t_insert(entry(stat).producers, a) end
		for stat in pairs(a.enables) do t_insert(entry(stat).enablers, a) end
		for from, to in pairs(a.converts) do
			-- (a converter feeds the target stat from the source one)
			t_insert(entry(to).converters, a)
			entry(from)
		end
	end
	return { stats = stats, nodes = nodes }
end

-- Stats several uniques consume (vectors worth stacking), with the uniques
-- around each: { stat, consumers, feeders (producers, enablers, converters) },
-- most consumers first. A converter brings the consumers of its target stat
-- into its source stat's group (Badge of the Brotherhood: power charges
-- also feed everything per frenzy charge).
function ScalingGraphClass:Vectors(graph, minConsumers)
	local out = { }
	for stat, e in pairs(graph.stats) do
		local consumers, seen = { }, { }
		local function add(list) for _, a in ipairs(list) do if not seen[a] then seen[a] = true t_insert(consumers, a) end end end
		add(e.consumers)
		local feeders = { }
		for _, list in ipairs({ e.enablers, e.producers }) do for _, a in ipairs(list) do t_insert(feeders, a) end end
		-- converters out of this stat
		for other, oe in pairs(graph.stats) do
			for _, conv in ipairs(oe.converters) do
				if conv.converts[stat] == other then
					t_insert(feeders, conv)
					add(oe.consumers)
				end
			end
		end
		if #consumers >= (minConsumers or 2) then
			t_insert(out, { stat = stat, consumers = consumers, feeders = feeders })
		end
	end
	t_sort(out, function(a, b)
		if #a.consumers ~= #b.consumers then return #a.consumers > #b.consumers end
		return a.stat < b.stat
	end)
	return out
end

-- The edges among the given (equipped) uniques: { { from, to, stat, kind } }
-- kind = "produces" / "enables" / "converts"; and the ones joined to nothing
function ScalingGraphClass:Interactions(items)
	local graph = self:Graph(items)
	local edges, joined = { }, { }
	for stat, e in pairs(graph.stats) do
		for _, c in ipairs(e.consumers) do
			for kind, list in pairs({ produces = e.producers, enables = e.enablers, converts = e.converters }) do
				for _, f in ipairs(list) do
					if f ~= c then
						t_insert(edges, { from = f.title, to = c.title, stat = stat, kind = kind })
						joined[f.title], joined[c.title] = true, true
					end
				end
			end
		end
		-- (two consumers of the same stat stack it together)
		if #e.consumers >= 2 then for _, c in ipairs(e.consumers) do joined[c.title] = true end end
	end
	local standalone = { }
	for _, a in ipairs(graph.nodes) do if not joined[a.title] then t_insert(standalone, a.title) end end
	return edges, standalone, graph
end

-- Every unique of the database (gear and jewels, one copy per title)
function ScalingGraphClass.AllUniques()
	local list, seen = { }, { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		if not seen[title] and item.type ~= "Flask" then
			seen[title] = true
			t_insert(list, item)
		end
	end
	t_sort(list, function(a, b) return (a.title or a.name) < (b.title or b.name) end)
	return list
end
