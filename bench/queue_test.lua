-- Test: a background generation through Classes/GenerationQueue, its workers
-- as processes (bench/fake_threads.lua). From src:
--   SKILL="Righteous Fire" ASC=Chieftain luajit ../bench/queue_test.lua
-- MODE=start: queues it and exits once the quick builds started (as if the
-- app were closed); MODE=resume: the queue is loaded from its file and the
-- generation goes on; default: queued and run to the end.
-- (builds are quick ones throughout, for speed)
dofile("HeadlessWrapper.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end
dofile("../bench/fake_threads.lua")
main.generatorThreads = true
main.userPath = os.getenv("USERPATH") or main.userPath or "./"
main.buildPath = main.buildPath or main.userPath
-- (no MakeDir headless)
os.execute("mkdir -p '" .. main.userPath .. "GenerationQueue' '" .. main.buildPath .. "Generated'")
local mode = os.getenv("MODE") or "full"
local skillName, ascName = os.getenv("SKILL") or "Righteous Fire", os.getenv("ASC") or "Chieftain"
local queue, batch
if mode == "resume" then
	queue = new("GenerationQueue"):GenerationQueue()
	main.generationQueue = queue
	batch = queue.batches[#queue.batches]
	print("resumed", batch and batch.status, batch and batch.phase)
else
	os.remove(main.userPath .. "GenerationQueue/queue.json")
	local gemId
	for id, gem in pairs(data.gems) do if gem.name == skillName and not gem.grantedEffect.support then gemId = id end end
	local classId, ascendClassId
	for cid, class in pairs(build.spec.tree.classes) do
		for aid, asc in pairs(class.classes) do if asc.name == ascName then classId, ascendClassId = cid, aid end end
	end
	queue = new("GenerationQueue"):GenerationQueue()
	main.generationQueue = queue
	print("available", queue:Available())
	local investment
	for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == "MID" then investment = level end end
	local pg = new("ParallelGenerator"):ParallelGenerator()
	batch = queue:Add({
		title = skillName .. " " .. ascName, buildName = "Generated test " .. skillName, skillLabel = skillName, gemId = gemId,
		standardId = "STANDARD", tries = 1, scanBuilds = 2, forceQuick = true,
		learningContext = { kind = "spell", investment = "MID" },
		baseJob = pg.JobFromOptions({ gemId = gemId, classId = classId, ascendClassId = ascendClassId, level = 90, investment = investment, synergies = false, knowledge = false }),
	})
end
local t0 = os.time()
local lastPrint = 0
while batch and (batch.status == "waiting" or batch.status == "running") do
	runCallback("OnFrame")
	os.execute("sleep 0.5")
	if os.time() - lastPrint >= 20 then
		lastPrint = os.time()
		local a, b, c = queue:Describe(batch)
		print(os.time() - t0, a, b, c or "")
	end
	if mode == "start" and batch.phase == "quick" then
		print("EXIT while the quick builds run (as if the app were closed)")
		os.exit(0)
	end
	if os.time() - t0 > 3000 then print("timeout") break end
end
print("STATUS", batch and batch.status, batch and batch.error or "", batch and batch.file or "")
if batch then print(queue:Describe(batch)) end
for _, s in ipairs(batch and batch.specs or { }) do print("SPEC", s.archetypeId, s.state, s.score or "", s.error or "") end
queue.panel:Draw({ x = 0, y = 0, width = 1920, height = 1080 })
print("panel height", queue:Height())
