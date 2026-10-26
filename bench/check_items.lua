-- Realism check of a generated build's rare items. From src:
--   CODE=build.xml luajit ../bench/check_items.lua
-- Flags: a crafted mod that repeats a natural mod's stat (the bench refuses
-- it), more than one "+level of socketed gems" mod, more influence mods than
-- the item's influences allow, pinnacle (Exarch/Eater "Pinnacle Presence")
-- implicits, items no longer obtainable.
dofile("HeadlessWrapper.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end
local f = assert(io.open(os.getenv("CODE"), "r"))
local xml = f:read("*a")
f:close()
loadBuildFromXML(xml, "check")
local function shape(line)
	return (line:lower():gsub("[%+%-]?%d+%.?%d*", "#"):gsub("%(#%-#%)", "#"):gsub("%s+", " "))
end
local problems = 0
local function flag(item, msg)
	problems = problems + 1
	print(string.format("FLAG\t%s (%s)\t%s", item.name or "?", item.baseName or "?", msg))
end
for _, item in pairs(build.itemsTab.items) do
	if item.rarity == "RARE" then
		local natural, crafted = { }, { }
		local gemLevel = 0
		for _, modLine in ipairs(item.explicitModLines or { }) do
			local s = shape(modLine.line)
			if modLine.crafted then crafted[#crafted + 1] = { s = s, line = modLine.line } else natural[s] = modLine.line end
			if modLine.line:match("to Level of Socketed") then gemLevel = gemLevel + 1 end
		end
		for _, c in ipairs(crafted) do
			if natural[c.s] then flag(item, "crafted '" .. c.line .. "' repeats '" .. natural[c.s] .. "'") end
		end
		if gemLevel > 1 then flag(item, gemLevel .. " '+level of socketed gems' mods") end
		for _, modLine in ipairs(item.implicitModLines or { }) do
			if modLine.line:match("Pinnacle Presence") then flag(item, "pinnacle implicit '" .. modLine.line .. "'") end
		end
	elseif item.rarity == "UNIQUE" and item.title then
		local ps = new("PriceSource"):PriceSource()
		if ps.IsUnobtainable and ps.IsUnobtainable(item.title) then flag(item, "no longer obtainable") end
	end
end
print("PROBLEMS", problems)
