-- Test: drives the Generate Build popup headless through an archetype scan and
-- the automatic mode, with background threads replaced by worker processes
-- (bench/worker_proc.lua), to check the parallel code paths end to end.
-- From the src folder: SKILL="Ball Lightning" ASC=Hierophant INVEST=MID luajit ../bench/popup_test.lua
io.stdout:setvbuf("no")
dofile("HeadlessWrapper.lua")
local socketOk, socket = pcall(require, "socket")
function GetTime() return (socketOk and socket.gettime() or os.time()) * 1000 end
while main.uniqueDB.loading do runCallback("OnFrame") end
main.generatorWorkers = tonumber(os.getenv("WORKERS") or "2")

-- background threads as processes
dofile("../bench/fake_threads.lua")

new("BuildIdeasPopup"):BuildIdeasPopup():OpenGenerator()
local popup = main.popups[#main.popups]
local controls = popup.controls
local function select(control, pred)
	for i, entry in ipairs(control.list) do
		if pred(entry) then control.selIndex = i return true end
	end
	error("not found in list")
end
select(controls.skill, function(e) return e.label == (os.getenv("SKILL") or "Ball Lightning") end)
if controls.skill.selFunc then controls.skill.selFunc(controls.skill.selIndex, controls.skill.list[controls.skill.selIndex]) end
select(controls.ascend, function(e) return e.ascendName == (os.getenv("ASC") or "Hierophant") end)
select(controls.investment, function(e) return e.level and e.level.id == (os.getenv("INVEST") or "MID") end)
controls.synergies.state = false
-- OURS=<build .xml>: no generation, that build is opened (for COMPARE_CODE)
if os.getenv("OURS") then
	local xf = assert(io.open(os.getenv("OURS")))
	main:SetMode("BUILD", false, "ours", xf:read("*a"))
	xf:close()
	runCallback("OnFrame")
else
-- automatic mode (first entry of the archetype list)
controls.archetype.selIndex = 1
print("archetype entry: " .. tostring(controls.archetype.list[1].label))
controls.generate.onClick()
end
local t0 = os.time()
local last
while not os.getenv("OURS") and os.time() - t0 < (tonumber(os.getenv("TIMEOUT") or "3600")) do
	runCallback("OnFrame")
	local status = controls.status.label
	if type(status) == "function" then status = status() end
	if status ~= last then print("STATUS " .. tostring(status)) last = status end
	if status and (status:find("Finished") or status:find("failed") or status:find("Failed")) and not status:find("Scan finished") then break end
	os.execute("sleep 0.01")
end
local build = main.modes["BUILD"]
print("FINAL build " .. tostring(build and build.buildName) .. " dps " .. tostring(build and build.calcsTab.mainOutput and build.calcsTab.mainOutput.TotalDPS))

-- COMPARE_CODE=<file with a PoB code>: then "Compare with top players" with
-- that build as the only top player (statistics put in the cache: no downloads here)
local compareFile = os.getenv("COMPARE_CODE")
if compareFile then
	local f = assert(io.open(compareFile))
	local code = f:read("*a"):gsub("%s", "")
	f:close()
	local skillName = os.getenv("SKILL") or "Ball Lightning"
	local source = GetBuildMetaSource()
	source.SaveCache = function() end
	source.cache[skillName] = { time = os.time(), league = "test", total = 1, players = { { name = "test", account = "test" } }, snapshot = { },
		details = { topBuilds = { { name = "top player", ascendancy = "?", level = 100, code = code } } }, detailsTime = os.time(),
		items = { }, keystones = { }, anoints = { }, supports = { } }
	controls.compare.onClick()
	local t1 = os.time()
	local lastStatus
	while os.time() - t1 < 1800 do
		runCallback("OnFrame")
		local status = controls.status.label
		if type(status) == "function" then status = status() end
		if status ~= lastStatus then print("STATUS " .. tostring(status)) lastStatus = status end
		if status and (status:find("Comparison finished") or status:find("No top") or status:find("needs")) then break end
		os.execute("sleep 0.05")
	end
	for _, line in ipairs(controls.log.list or { }) do
		local text = type(line) == "table" and (line.text or line[1]) or line
		print("LOG " .. tostring(text))
	end
end
