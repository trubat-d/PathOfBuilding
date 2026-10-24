-- Audit: every unique gear item the generator can use, for what changes how
-- gem setups fit in it: fixed socket counts ("Has 1 Socket"), supports it
-- grants to its socketed gems (behaviour ones are kept out of utility setups:
-- Modules/GeneratorRules behaviourSupports) and other socketed gem lines.
-- From the src folder: luajit ../bench/unique_audit.lua
dofile("HeadlessWrapper.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end
local rules = GetGeneratorRules()
local behaviour = {}
for _, n in ipairs(rules.behaviourSupports) do behaviour[n:gsub("%%", "")] = true end
local setup = new("GemSetup"):GemSetup({ build = build })
local supportsSeen, socketIssues, socketedOther = {}, {}, {}
local titles = {}
for _, item in pairs(main.uniqueDB.list) do titles[#titles+1] = item end
table.sort(titles, function(a,b) return (a.title or "") < (b.title or "") end)
for _, item in ipairs(titles) do
	if item.base and item.type ~= "Jewel" and item.type ~= "Flask" then
		local title = item.title or item.name
		for _, ml in ipairs(item.explicitModLines or {}) do
			local line = ml.line or ""
			local sup = line:match("Socketed Gems are Supported by Level %d+ (.+)$")
			if sup then supportsSeen[sup] = supportsSeen[sup] or {}; table.insert(supportsSeen[sup], title) end
			if line:match("^Socketed") and not sup then socketedOther[line:gsub("%d+","#")] = title end
		end
		local n = setup.ItemGemSockets(item)
		if item.base.socketLimit and n < item.base.socketLimit then table.insert(socketIssues, string.format("%s (%s): %d gem sockets of %d", title, item.type, n, item.base.socketLimit)) end
	end
end
for _, l in ipairs(socketIssues) do print("SOCKETS", l) end
local names = {}
for k in pairs(supportsSeen) do names[#names+1] = k end
table.sort(names)
for _, k in ipairs(names) do print("SUPPORT", behaviour[k] and "behaviour" or "-", k, table.concat(supportsSeen[k], "; ")) end
local o = {}
for k, v in pairs(socketedOther) do o[#o+1] = k .. "  <" .. v .. ">" end
table.sort(o)
for _, l in ipairs(o) do print("SOCKETED", l) end
