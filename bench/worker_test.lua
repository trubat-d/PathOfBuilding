-- Test: runs Modules/GeneratorWorker the way a background thread does (fresh Lua state).
-- From the src folder: luajit ../bench/worker_test.lua '<job json>'
io.stdout:setvbuf("no")
local run = dofile("Modules/GeneratorWorker.lua")
local t0 = os.clock()
local summary, xml = run(arg[1], "")
print("WORKER " .. summary)
print("XML bytes " .. #xml .. ", seconds " .. math.floor(os.clock() - t0))
