-- Test helper: a generator worker as a separate process (stands in for a
-- background thread in bench/popup_test.lua).
-- From the src folder: luajit ../bench/worker_proc.lua <job file> <output prefix>
local jobFile, out = arg[1], arg[2]
local f = assert(io.open(jobFile))
local job = f:read("*a")
f:close()
local run = dofile("Modules/GeneratorWorker.lua")
local ok, summary, xml = pcall(run, job, "")
if ok then
	local s = io.open(out .. ".json", "w") s:write(summary) s:close()
	local x = io.open(out .. ".xml", "w") x:write(xml) x:close()
else
	local e = io.open(out .. ".err", "w") e:write(tostring(summary)) e:close()
end
local d = io.open(out .. ".done", "w") d:write("1") d:close()
