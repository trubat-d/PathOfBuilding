-- Checks every generated rare of saved builds for crafting problems
-- (RareItemGenerator.Validate). From src: FILES="<xml> <xml>..." luajit ../bench/rare_audit.lua
io.stdout:setvbuf("no")
local benchDir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "../bench"
dofile("HeadlessWrapper.lua")
dofile(benchDir .. "/inflate.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end
local total, bad = 0, 0
for path in (os.getenv("FILES") or ""):gmatch("%S+") do
	local f = io.open(path)
	if f then
		loadBuildFromXML(f:read("*a"), "audit")
		f:close()
		runCallback("OnFrame")
		for id, item in pairs(build.itemsTab.items) do
			if item.rarity == "RARE" and item.title and item.title:match("^Best Rare") then
				total = total + 1
				local problems = new("BestItemFinder"):BestItemFinder(build.itemsTab).rareGenerator.Validate(item)
				if #problems > 0 then
					bad = bad + 1
					print(string.format("%s | %s (%s): %s", path:match("[^/]+$"), item.title, item.baseName, table.concat(problems, "; ")))
				end
			end
		end
	end
end
print(string.format("RARES %d, with problems %d", total, bad))
