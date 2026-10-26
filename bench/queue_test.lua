-- Test: a background generation through Classes/GenerationQueue, its workers
-- as processes (bench/fake_threads.lua). From src:
--   SKILL="Righteous Fire" ASC=Chieftain luajit ../bench/queue_test.lua
-- QUICK=0 makes the full builds full (default: quick, for speed)
dofile("HeadlessWrapper.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end
dofile("../bench/fake_threads.lua")
main.generatorThreads = true
local skillName, ascName = os.getenv("SKILL") or "Righteous Fire", os.getenv("ASC") or "Chieftain"
local gemId
for id, gem in pairs(data.gems) do if gem.name == skillName and not gem.grantedEffect.support then gemId = id end end
local classId, ascendClassId
for cid, class in pairs(build.spec.tree.classes) do
	for aid, asc in pairs(class.classes) do if asc.name == ascName then classId, ascendClassId = cid, aid end end
end
local queue = new("GenerationQueue"):GenerationQueue()
main.generationQueue = queue
print("available", queue:Available())
local archetypes = new("BuildArchetypes"):BuildArchetypes()
local list = archetypes.ForSkill(data.gems[gemId], nil)
local standard
for _, a in ipairs(list) do if a.id == "STANDARD" then standard = a end end
local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == "MID" then investment = level end end
local pg = new("ParallelGenerator"):ParallelGenerator()
local quickAll = os.getenv("QUICK") ~= "0"
local batch = queue:Add({
	title = skillName .. " " .. ascName, buildName = "Generated test " .. skillName, skillLabel = skillName,
	archetypes = list, standard = standard or list[1], tries = 1, scanBuilds = 2,
	learningContext = { kind = "spell", investment = "MID" },
	makeJob = function(archetype, quick, variant, plan)
		return pg.JobFromOptions({ gemId = gemId, classId = classId, ascendClassId = ascendClassId, level = 90, investment = investment,
			archetype = archetype, quick = (quick or quickAll) or nil, synergies = false, variant = variant, knowledge = false }, plan and { plan = true } or nil)
	end,
})
local t0 = os.time()
local lastPrint = 0
while batch.status == "waiting" or batch.status == "running" do
	runCallback("OnFrame")
	os.execute("sleep 0.5")
	if os.time() - lastPrint >= 20 then
		lastPrint = os.time()
		local a, b, c = queue:Describe(batch)
		print(os.time() - t0, a, b, c or "")
	end
	if os.time() - t0 > 3000 then print("timeout") break end
end
print("STATUS", batch.status, batch.error or "", batch.file or "")
print(queue:Describe(batch))
for _, f in ipairs(batch.failures) do print("FAILURE", f) end
-- the panel draws and takes input headless
queue.panel:Draw({ x = 0, y = 0, width = 1920, height = 1080 })
print("panel height", queue:Height())
