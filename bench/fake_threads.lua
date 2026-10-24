-- Test helper: background threads (LaunchSubScript) replaced by worker
-- processes (bench/worker_proc.lua), so the app's parallel code paths run
-- headless. dofile it after HeadlessWrapper.lua, from the src folder.
-- TMPDIR_TEST=<folder for the job files> (default /tmp)
-- (separate processes: each has its own memory)
new("ParallelGenerator"):ParallelGenerator()
common.classes["ParallelGenerator"].processWorkers = true
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

