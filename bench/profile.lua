-- Where a generation spends its time: every method of the generator classes
-- wrapped, its time counted (inclusive, the outermost call only when it
-- recurses) with the number of calls and of full scores / recalculations made
-- inside it. Loaded by bench_case.lua when PROFILE=1; Report() prints the top.
local M = { }
local stats = { }
local depth = { }
local clock = os.clock

local function wrapClass(className)
	local class = common.classes[className]
	if not class then return end
	for name, fn in pairs(class) do
		if type(fn) == "function" and name ~= className and not name:match("^_") then
			local key = className .. ":" .. name
			stats[key] = stats[key] or { time = 0, calls = 0, scores = 0, recalcs = 0 }
			local entry = stats[key]
			class[name] = function(self, ...)
				entry.calls = entry.calls + 1
				depth[key] = (depth[key] or 0) + 1
				if depth[key] > 1 then
					local r = { fn(self, ...) }
					depth[key] = depth[key] - 1
					return unpack(r)
				end
				local t0 = clock()
				local gen = type(self) == "table" and (self.fullScoreCount and self or self.gen)
				local s0, r0 = gen and gen.fullScoreCount or 0, gen and gen.recalcCount or 0
				local r = { fn(self, ...) }
				entry.time = entry.time + clock() - t0
				if gen then
					entry.scores = entry.scores + (gen.fullScoreCount or 0) - s0
					entry.recalcs = entry.recalcs + (gen.recalcCount or 0) - r0
				end
				depth[key] = depth[key] - 1
				return unpack(r)
			end
		end
	end
end

function M.Install(classNames)
	for _, name in ipairs(classNames) do
		-- (the class is loaded on first use: load it now)
		pcall(getClass, name)
		wrapClass(name)
	end
end

function M.Report(top)
	local rows = { }
	for key, e in pairs(stats) do if e.calls > 0 then table.insert(rows, { key = key, e = e }) end end
	table.sort(rows, function(a, b) return a.e.time > b.e.time end)
	print("PROFILE (inclusive seconds, calls, full scores, recalculations)")
	for i = 1, math.min(top or 60, #rows) do
		local r = rows[i]
		print(string.format("PROFILE %8.1f s %7d calls %7d scores %7d recalcs  %s", r.e.time, r.e.calls, r.e.scores, r.e.recalcs, r.key))
	end
end

return M
