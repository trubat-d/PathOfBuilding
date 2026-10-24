-- Path of Building
--
-- Class: Synergy Index
-- Reads PoB's parsed modifiers and records, for every unique item, keystone,
-- notable and ascendancy node, what it PROVIDES (a condition, charges, an
-- ailment on enemies, attributes...) and what it NEEDS or scales with
-- (damage against chilled enemies, X per power charge, Y per strength...).
-- A synergy is something one source provides that another needs. Used to
-- pick which combinations are worth testing, and to explain them.
--
local pairs = pairs
local ipairs = ipairs
local t_insert = table.insert

---@class SynergyIndex
local SynergyIndexClass = newClass("SynergyIndex")

function SynergyIndexClass:SynergyIndex()
	return self
end

-- Mod names that provide a resource, beyond the generic Condition:/Multiplier: ones
local providerRules = {
	{ "^PowerChargesM[ai][xn]$", "mult:PowerCharge" },
	{ "^FrenzyChargesM[ai][xn]$", "mult:FrenzyCharge" },
	{ "^EnduranceChargesM[ai][xn]$", "mult:EnduranceCharge" },
	{ "^MaximumRage$", "mult:Rage" },
	{ "^EnemyIgniteChance$", "enemy:Ignited" }, { "CanIgnite$", "enemy:Ignited" }, { "^IgniteAsThoughDealing", "enemy:Ignited" },
	{ "^EnemyShockChance$", "enemy:Shocked" }, { "CanShock$", "enemy:Shocked" }, { "^ShockBase$", "enemy:Shocked" }, { "^ShockAsThoughDealing", "enemy:Shocked" },
	{ "^EnemyChillEffect$", "enemy:Chilled" }, { "CanChill$", "enemy:Chilled" },
	{ "^EnemyFreezeChance$", "enemy:Frozen" }, { "CanFreeze$", "enemy:Frozen" }, { "^FreezeAsThoughDealing", "enemy:Frozen" },
	{ "^BleedChance$", "enemy:Bleeding" },
	{ "^PoisonChance$", "enemy:Poisoned" },
	{ "^ExtraCurse$", "enemy:Cursed" }, { "^EnemyCurseLimit$", "enemy:Cursed" },
	{ "Leech$", "cond:Leeching" },
	{ "^Str$", "stat:Str" }, { "^Dex$", "stat:Dex" }, { "^Int$", "stat:Int" },
	{ "^StrDex$", "stat:Str", "stat:Dex" }, { "^StrInt$", "stat:Str", "stat:Int" }, { "^DexInt$", "stat:Dex", "stat:Int" },
	{ "^StrDexInt$", "stat:Str", "stat:Dex", "stat:Int" },
	{ "^Devotion$", "stat:Devotion" },
	{ "^LeftActiveMagicUtilityFlasks$", "flask:permanent" }, { "^RightActiveMagicUtilityFlasks$", "flask:permanent" },
}

-- Mod names that consume a resource without saying so in a tag
local consumerRules = {
	{ "^FlaskEffect$", "flask:active" }, { "^MagicUtilityFlaskEffect$", "flask:active" },
	{ "^FlaskDuration$", "flask:active" },
}

-- Human readable names for keys
local keyLabels = {
	["cond:UsingFlask"] = "a flask active",
	["flask:active"] = "active flasks",
	["flask:permanent"] = "permanent flasks",
}

function SynergyIndexClass.KeyLabel(key)
	if keyLabels[key] then
		return keyLabels[key]
	end
	local kind, name = key:match("^(%w+):(.+)$")
	if not kind then
		return key
	end
	name = name:gsub("(%l)(%u)", "%1 %2")
	if kind == "enemy" then
		return "enemies " .. name:lower()
	elseif kind == "mult" then
		return name:lower() .. "s"
	elseif kind == "stat" then
		return name
	end
	return name:lower()
end

local function tagKey(tag)
	local var = tag.var or (tag.varList and tag.varList[1])
	if tag.type == "Condition" and var and not var:match("{") then
		return "cond:" .. var
	elseif tag.type == "ActorCondition" and var then
		return (tag.actor == "enemy" and "enemy:" or "cond:") .. var
	elseif (tag.type == "Multiplier" or tag.type == "MultiplierThreshold") and var and not var:match("{") then
		return "mult:" .. var
	elseif (tag.type == "PerStat" or tag.type == "StatThreshold") then
		local stat = tag.stat or (tag.statList and tag.statList[1])
		return stat and ("stat:" .. stat)
	end
end

-- Adds the provides / needs of one mod to the sets
function SynergyIndexClass.ScanMod(mod, provides, needs)
	local name = mod.name or ""
	local cond = name:match("^Condition:(.+)$")
	if cond and not cond:match("{") then
		provides["cond:" .. cond] = true
	end
	local mult = name:match("^Multiplier:(.+)$")
	if mult and not mult:match("{") then
		provides["mult:" .. mult] = true
	end
	local positive = type(mod.value) ~= "number" or mod.value > 0
	if positive then
		for _, rule in ipairs(providerRules) do
			if name:match(rule[1]) then
				for i = 2, #rule do
					provides[rule[i]] = true
				end
			end
		end
	end
	for _, rule in ipairs(consumerRules) do
		if name:match(rule[1]) then
			needs[rule[2]] = true
		end
	end
	for _, tag in ipairs(mod) do
		if type(tag) == "table" then
			local key = tagKey(tag)
			if key then
				needs[key] = true
			end
		end
	end
end

function SynergyIndexClass.ScanModList(modList, provides, needs)
	for _, mod in ipairs(modList or { }) do
		SynergyIndexClass.ScanMod(mod, provides, needs)
	end
end

-- provides / needs of an item
function SynergyIndexClass.ScanItem(item)
	local provides, needs = { }, { }
	for _, list in ipairs({ item.implicitModLines, item.explicitModLines, item.enchantModLines }) do
		for _, line in ipairs(list or { }) do
			SynergyIndexClass.ScanModList(line.modList, provides, needs)
		end
	end
	if item.type == "Flask" and item.base and item.base.flask and not (item.base.flask.life or item.base.flask.mana) then
		provides["cond:UsingFlask"] = true
		provides["flask:active"] = true
	end
	return provides, needs
end

-- provides / needs of a passive node
function SynergyIndexClass.ScanNode(node)
	local provides, needs = { }, { }
	if node.type == "Keystone" and node.keystoneMod then
		SynergyIndexClass.ScanMod(node.keystoneMod, provides, needs)
	end
	SynergyIndexClass.ScanModList(node.modList, provides, needs)
	return provides, needs
end

-- Keys that one side provides and the other needs, both directions
function SynergyIndexClass.Links(aProvides, aNeeds, bProvides, bNeeds)
	local links = { }
	for key in pairs(aProvides) do
		if bNeeds[key] then
			t_insert(links, { from = "A", key = key })
		end
	end
	for key in pairs(bProvides) do
		if aNeeds[key] then
			t_insert(links, { from = "B", key = key })
		end
	end
	return links
end

-- What the current build already provides (tree, items, config conditions)
function SynergyIndexClass.ScanBuild(build)
	local provides, needs = { }, { }
	for _, node in pairs(build.spec.allocNodes) do
		local p, n = SynergyIndexClass.ScanNode(node)
		for k in pairs(p) do provides[k] = true end
		for k in pairs(n) do needs[k] = true end
	end
	for _, slot in pairs(build.itemsTab.slots) do
		local item = build.itemsTab.items[slot.selItemId]
		if item and not slot.inactive then
			local p, n = SynergyIndexClass.ScanItem(item)
			for k in pairs(p) do provides[k] = true end
			for k in pairs(n) do needs[k] = true end
		end
	end
	return provides, needs
end
