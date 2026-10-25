-- Passive tree nodes (notables, keystones, ascendancy and bloodline) with lines PoB does not
-- understand, after joining lines it reads together. From the src folder: luajit ../bench/unsupported_tree.lua
dofile("HeadlessWrapper.lua")
local tree = main.tree[latestTreeVersion]
local out, seen = { }, { }
local function check(kind, node)
	if not node or seen[node] or not node.dn then return end
	seen[node] = true
	if node.unknown or node.extra then
		local bad = { }
		for i, line in ipairs(node.sd or { }) do
			local mods, extra = modLib.parseMod(line)
			if not mods or extra then
				-- (a line PoB reads joined with the next is not counted)
				local nextLine = node.sd[i + 1]
				local joined = nextLine and modLib.parseMod(line .. " " .. nextLine)
				local prevLine = node.sd[i - 1]
				local joinedPrev = prevLine and modLib.parseMod(prevLine .. " " .. line)
				if not joined and not joinedPrev then bad[#bad + 1] = line end
			end
		end
		if #bad > 0 then out[#out + 1] = string.format("%s\t%s\t%s", kind, node.dn, table.concat(bad, " | ")) end
	end
end
for _, node in pairs(tree.nodes) do
	if node.ascendancyName then check("Asc:" .. node.ascendancyName, node)
	elseif node.type == "Notable" or node.type == "Keystone" then check(node.type, node) end
end
for _, node in pairs(tree.clusterNodeMap or { }) do check("Cluster", node) end
table.sort(out)
for _, l in ipairs(out) do print(l) end
