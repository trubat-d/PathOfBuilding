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
local tmp = os.getenv("TMPDIR_TEST") or "/tmp"
local pending, counter = { }, 0
function LaunchSubScript(script, funcs, subs, jobJson, userPath)
	counter = counter + 1
	local id = { n = counter }
	if not jobJson then
		pending[id] = { immediate = true }
		return id
	end
	if jobJson:match("^https?://") then
		-- downloads: not available in this test
		pending[id] = { download = true }
		return id
	end
	local base = string.format("%s/popup_job_%d", tmp, counter)
	local f = io.open(base .. ".job", "w") f:write(jobJson) f:close()
	os.remove(base .. ".done")
	os.execute(string.format("luajit ../bench/worker_proc.lua %s.job %s > %s.log 2>&1 &", base, base, base))
	pending[id] = { base = base }
	print("launched worker " .. counter)
	return id
end
function AbortSubScript(id) pending[id] = nil end
local function readAll(path) local f = io.open(path) if not f then return nil end local t = f:read("*a") f:close() return t end
main.onFrameFuncs["FakeSubScripts"] = function()
	for id, p in pairs(pending) do
		if p.immediate then
			pending[id] = nil
			if launch.subScripts[id] then launch:OnSubFinished(id, true) end
		elseif p.download then
			pending[id] = nil
			if launch.subScripts[id] then launch:OnSubError(id, "no downloads in this test") end
		elseif readAll(p.base .. ".done") then
			pending[id] = nil
			local err = readAll(p.base .. ".err")
			if launch.subScripts[id] then
				if err then launch:OnSubError(id, err) else launch:OnSubFinished(id, readAll(p.base .. ".json"), readAll(p.base .. ".xml")) end
			end
			print("worker finished " .. id.n .. (err and (" with error: " .. err) or ""))
		end
	end
end

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
-- automatic mode (first entry of the archetype list)
controls.archetype.selIndex = 1
print("archetype entry: " .. tostring(controls.archetype.list[1].label))
controls.generate.onClick()
local t0 = os.time()
local last
while os.time() - t0 < (tonumber(os.getenv("TIMEOUT") or "3600")) do
	runCallback("OnFrame")
	local status = controls.status.label
	if type(status) == "function" then status = status() end
	if status ~= last then print("STATUS " .. tostring(status)) last = status end
	if status and (status:find("Finished") or status:find("failed") or status:find("Failed")) and not status:find("Scan finished") then break end
	os.execute("sleep 0.01")
end
local build = main.modes["BUILD"]
print("FINAL build " .. tostring(build and build.buildName) .. " dps " .. tostring(build and build.calcsTab.mainOutput and build.calcsTab.mainOutput.TotalDPS))
