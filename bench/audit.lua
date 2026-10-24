-- Lists every unique line PoB cannot calculate, item-granted supports, and gem
-- stats without a stat map, to review Modules/GeneratorRules.lua after a patch.
--   cd src; OUT=../bench/results/audit.txt luajit ../bench/audit.lua
io.stdout:setvbuf("no")
dofile("HeadlessWrapper.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end
local out = io.open(os.getenv("OUT"), "w")
local drawback = { "lose", "you take", "taken", "sacrific", "cannot", "can't", "degenerat", "reduced", "less ", "no ", "%-", "only", "removed", "costs", "cost ", "instead", "while you have no", "self" }
local nUnparsed, nItems = 0, 0
for _, item in pairs(main.uniqueDB.list) do
  nItems = nItems + 1
  local unparsed, granted = { }, { }
  for _, list in ipairs({ item.explicitModLines or { }, item.implicitModLines or { } }) do
    for _, ml in ipairs(list) do
      local current = not ml.variantList or (item.variant and ml.variantList[item.variant])
      if current and ml.line then
        if ml.line:match("Socketed Gems are Supported by Level") or ml.line:match("Socketed .* Gems are Supported by") then table.insert(granted, ml.line) end
        if (not ml.modList or #ml.modList == 0) and not ml.line:match("^%s*$") or ml.extra then
          table.insert(unparsed, ml.line .. (ml.extra and (" [unsupported part: " .. ml.extra .. "]") or ""))
        end
      end
    end
  end
  if #unparsed > 0 or #granted > 0 then
    local flags = { }
    for _, l in ipairs(unparsed) do
      local low = l:lower()
      for _, k in ipairs(drawback) do if low:find(k) then flags[#flags+1] = k break end end
    end
    if #unparsed > 0 then nUnparsed = nUnparsed + 1 end
    out:write(string.format("ITEM\t%s\t%s\tunparsed=%d\tdrawbackish=%d\n", item.title or item.name, item.type or "?", #unparsed, #flags))
    for _, l in ipairs(unparsed) do out:write("  U\t" .. l .. "\n") end
    for _, l in ipairs(granted) do out:write("  G\t" .. l .. "\n") end
  end
end
-- gems: stats without a stat map (not calculated)
local global = data.skillStatMap or { }
local nGems = 0
for id, gem in pairs(data.gems) do
  local e = gem.grantedEffect
  if e and not e.unsupported then
    local missing = { }
    for _, stat in ipairs(e.stats or { }) do
      if not (e.statMap and e.statMap[stat]) and not global[stat] then missing[#missing+1] = stat end
    end
    for _, c in ipairs(e.constantStats or { }) do
      local stat = c[1]
      if not (e.statMap and e.statMap[stat]) and not global[stat] then missing[#missing+1] = stat end
    end
    if #missing > 0 then
      nGems = nGems + 1
      out:write(string.format("GEM\t%s\t%s\n", gem.name, e.support and "support" or "active"))
      for _, m in ipairs(missing) do out:write("  M\t" .. m .. "\n") end
    end
  end
end
out:close()
print("items", nItems, "with unparsed lines", nUnparsed, "gems with unmapped stats", nGems)
