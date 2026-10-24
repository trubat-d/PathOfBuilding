-- Scores saved builds with the current scorer (as the generator's final score),
-- so builds made by an older version can be compared with new ones.
-- From the src folder: FILES="<build .xml> ..." [FOCUS=DPS_FLOOR] [INVEST=ENDGAME] luajit ../bench/rescore.lua
io.stdout:setvbuf("no")
dofile("HeadlessWrapper.lua")
dofile("../bench/inflate.lua")
while main.uniqueDB.loading do runCallback("OnFrame") end
local investment
for _, level in ipairs(new("PriceSource"):PriceSource().levels) do if level.id == (os.getenv("INVEST") or "ENDGAME") then investment = level end end
for path in os.getenv("FILES"):gmatch("%S+") do
	local f = assert(io.open(path)); loadBuildFromXML(f:read("*a"), "b"); f:close(); runCallback("OnFrame")
	local focus
	for _, entry in ipairs(new("BuildScorer"):BuildScorer(build).focusList) do if entry.id == (os.getenv("FOCUS") or "DPS_FLOOR") then focus = entry end end
	local scorer = new("BuildScorer"):BuildScorer(build, { focus = focus, hitFloor = focus.hitFloor, chargesPerSecond = 1.5, bossTier = investment.awakenedGems and "uber" or "pinnacle" })
	scorer.useChecklist = true
	local r = scorer:Evaluate(build.calcsTab:GetMiscCalculator(), { })
	local minHit = scorer:MinMaxHit(r.output)
	print(string.format("RESCORE %-60s %.3f dps %.0f minHit %.0f share %.2f", path:match("[^/]+$"), r.score, r.dps, minHit or 0, scorer:DamageTakenShare(r.output)))
end
