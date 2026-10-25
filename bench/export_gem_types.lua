-- Writes every active skill gem's skill types and tags as JSON (for
-- bench/train_model.py --gems): { [gem name] = { types = { ... }, tags = { ... } } }
-- From the src folder: OUT=gems.json luajit ../bench/export_gem_types.lua
dofile("HeadlessWrapper.lua")
local dkjson = require "dkjson"
local names = { }
for name, id in pairs(SkillType) do names[id] = name end
local out = { }
for _, gem in pairs(data.gems) do
	local effect = gem.grantedEffect
	if effect and not effect.support then
		local types, tags = { }, { }
		for id in pairs(effect.skillTypes or { }) do if names[id] then table.insert(types, names[id]) end end
		for tag in pairs(gem.tags or { }) do table.insert(tags, tag) end
		table.sort(types)
		table.sort(tags)
		out[gem.name] = { types = types, tags = tags }
	end
end
local f = assert(io.open(os.getenv("OUT") or "gems.json", "w"))
f:write(dkjson.encode(out))
f:close()
