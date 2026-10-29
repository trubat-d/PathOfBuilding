-- lists gem stats PoB has no mapping for (they do nothing in its calculations)
dofile("HeadlessWrapper.lua")
local dk = require("dkjson")
local out = {}
for id, gem in pairs(data.gems) do
  local ge = gem.grantedEffect
  if ge and not gem.name:match("^Vaal ") then
    local miss, seen = {}, {}
    local function check(stat)
      if stat and not seen[stat] then
        seen[stat] = true
        if not ge.statMap[stat] then table.insert(miss, stat) end
      end
    end
    for _, s in ipairs(ge.stats or {}) do check(s) end
    for _, s in ipairs(ge.constantStats or {}) do check(s[1]) end
    for _, s in ipairs(ge.qualityStats or {}) do check(s[1]) end
    if #miss > 0 then
      table.sort(miss)
      table.insert(out, { name = gem.name, support = ge.support and true or false, tags = gem.tagString, missing = miss })
    end
  end
end
table.sort(out, function(a, b) return a.name < b.name end)
print("JSON " .. dk.encode(out))
