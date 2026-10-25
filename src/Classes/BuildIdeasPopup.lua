-- Path of Building
--
-- Class: Build Ideas Popup
-- The two windows of the build ideas tools:
--   * "Build ideas": synergies, removed downsides and best single changes for
--     the open build, with explanations, assumptions and an Apply button
--   * "Generate build": a complete build for a chosen skill and ascendancy
-- Everything runs locally with PoB's calculator, in a coroutine so the
-- window stays responsive.
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert
local t_remove = table.remove
local m_min = math.min
local m_floor = math.floor
local m_max = math.max

---@class BuildIdeasPopup
local BuildIdeasPopupClass = newClass("BuildIdeasPopup")

function BuildIdeasPopupClass:BuildIdeasPopup()
	return self
end

-- Splits text into lines of at most n characters
local function wrap(text, n)
	local lines = { }
	local color = text:match("^(%^x%x%x%x%x%x%x)") or text:match("^(%^%d)") or ""
	local line = ""
	for word in text:gmatch("%S+") do
		if #StripEscapes(line) + #StripEscapes(word) + 1 > n and line ~= "" then
			t_insert(lines, line)
			line = color .. "    " .. word
		else
			line = line == "" and word or (line .. " " .. word)
		end
	end
	if line ~= "" then t_insert(lines, line) end
	return lines
end

local function addLines(list, text, size, width)
	for _, line in ipairs(wrap(text, width or 118)) do
		t_insert(list, { height = size or 16, line })
	end
end

-- The player's unique choices for the generator: excluded (never used) and
-- forced (built around), kept between sessions in the settings folder
local uniqueChoices
local function uniqueChoicesPath()
	return main.userPath and (main.userPath .. "BuildIdeasUniques.json") or nil
end
local function loadUniqueChoices()
	if uniqueChoices then return uniqueChoices end
	uniqueChoices = { excluded = { }, forced = { } }
	local path = uniqueChoicesPath()
	local file = path and io.open(path, "r")
	if file then
		local ok, data = pcall(require("dkjson").decode, file:read("*a"))
		file:close()
		if ok and type(data) == "table" then
			uniqueChoices.excluded = type(data.excluded) == "table" and data.excluded or { }
			uniqueChoices.forced = type(data.forced) == "table" and data.forced or { }
		end
	end
	return uniqueChoices
end
local function saveUniqueChoices()
	local path = uniqueChoicesPath()
	local file = path and io.open(path, "w")
	if file then
		file:write(require("dkjson").encode(uniqueChoices))
		file:close()
	end
	-- (the Build Ideas search uses the same rules as the generator)
	local rules = GetGeneratorRules()
	rules.userExcluded, rules.userForced = { }, { }
	for _, title in ipairs(uniqueChoices.excluded) do rules.userExcluded[title] = true end
	for _, title in ipairs(uniqueChoices.forced) do rules.userForced[title] = true end
end

-- The player's own mix of goals (the generator's "Aim for: Custom mix..."),
-- kept between sessions in the settings folder
local goalWeights
local function goalWeightsPath() return main.userPath and (main.userPath .. "BuildIdeasGoals.json") or nil end
local function loadGoalWeights()
	if goalWeights then return goalWeights end
	-- (default: fast and tanky - movement speed with tankiness and avoidance)
	goalWeights = { dps = 0.5, ehp = 1, avoid = 0.8, clear = 0.3, goals = { move = 1 } }
	local path = goalWeightsPath()
	local file = path and io.open(path, "r")
	if file then
		local ok, data = pcall(require("dkjson").decode, file:read("*a"))
		file:close()
		if ok and type(data) == "table" then
			goalWeights = data
			goalWeights.goals = type(data.goals) == "table" and data.goals or { }
		end
	end
	return goalWeights
end
local function saveGoalWeights()
	local path = goalWeightsPath()
	local file = path and io.open(path, "w")
	if file then file:write(require("dkjson").encode(goalWeights)) file:close() end
end

-- Window to set the weights of a custom mix; onDone() when closed
local function openGoalWeights(onDone)
	local weights = loadGoalWeights()
	local controls = { }
	local rows = {
		{ key = "dps", label = "Damage" },
		{ key = "ehp", label = "Tankiness (max hit, EHP)" },
		{ key = "avoid", label = "Avoidance (block, evade...)" },
		{ key = "clear", label = "Clear speed" },
	}
	for _, goal in ipairs(new("BuildScorer"):BuildScorer({ }).goalList) do t_insert(rows, { goal = goal.id, label = goal.label }) end
	local y = 22
	for i, row in ipairs(rows) do
		local value = row.key and weights[row.key] or (weights.goals[row.goal] or 0)
		controls["label" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, y + 2, 0, 16}, "^7" .. row.label .. ":")
		controls["edit" .. i] = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {250, y, 60, 20}, tostring(value), nil, "[^%d%.]", 4, function(buf)
			local v = tonumber(buf) or 0
			if row.key then weights[row.key] = v else weights.goals[row.goal] = v end
		end)
		y = y + 26
	end
	controls.help = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {330, 24, 0, 14}, "^xC0C0C0Weights from 0 to about 3.")
	controls.help2 = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {330, 42, 0, 14}, "^xC0C0C0Weight 1: doubling the stat is worth")
	controls.help3 = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {330, 58, 0, 14}, "^xC0C0C0as much as doubling the damage.")
	controls.help4 = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {330, 82, 0, 14}, "^xC0C0C0Damage 0: nothing is spent on damage,")
	controls.help5 = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {330, 98, 0, 14}, "^xC0C0C0every skill and slot serves the other goals.")
	controls.done = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {430, y + 4, 80, 20}, "Done", function()
		saveGoalWeights()
		main:ClosePopup()
		if onDone then onDone() end
	end)
	main:OpenPopup(530, y + 36, "Custom mix of goals", controls, "done", nil, "done")
end

-- Review of the open build (Classes/BuildReview): each key stat marked too
-- low / fine / too high, kept to learn from; "Improve" calls onImprove(focus)
-- with the build's focus moved by the review
local function openReview(build, baseFocus, onImprove)
	local review = new("BuildReview"):BuildReview()
	local data = review.Load()
	local values = review.Values(build, baseFocus)
	local verdicts = { }
	local controls = { }
	controls.intro = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 20, 0, 14}, "^7How does the build look to you? Mark what is too low or too high (leave the rest).")
	local y = 44
	local colours = { [-1] = "^xFF8040", [0] = "^x60E060", [1] = "^x40A0FF" }
	for i, stat in ipairs(review.stats) do
		local v = values[stat.key]
		if v then
			controls["label" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, y + 2, 0, 16}, "^7" .. stat.label .. ":")
			controls["value" .. i] = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {210, y + 2, 0, 16}, "^xC0C0C0" .. v.text)
			local x = 380
			for _, verdict in ipairs({ -1, 0, 1 }) do
				local text = review.verdictLabels[verdict]
				local width = verdict == 0 and 50 or 70
				controls["v" .. i .. "_" .. verdict] = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {x, y, width, 20}, function()
					return (verdicts[stat.key] == verdict and colours[verdict] or "^7") .. text
				end, function()
					verdicts[stat.key] = verdicts[stat.key] ~= verdict and verdict or nil
				end)
				x = x + width + 4
			end
			y = y + 24
		end
	end
	controls.noteLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, y + 8, 0, 16}, "^7Note (kept with the review):")
	controls.note = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {210, y + 6, 390, 20}, "", nil, nil, 200)
	y = y + 34
	controls.ask = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {210, y, 18}, "Ask after every build:", function(on)
		data.askAfter = on
	end, "Open this review when a generation or an upgrade finishes.", data.askAfter ~= false)
	controls.learn = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {500, y, 18}, "Use what reviews taught:", function(on)
		data.useLearned = on
	end, "Every review moves a factor per stat a little (too low: up, too high: down);\nthe generator's focus is multiplied by them from then on.", data.useLearned ~= false)
	y = y + 28
	local learnt = { }
	for k, f in pairs(data.factors or { }) do if math.abs(f - 1) >= 0.05 then t_insert(learnt, string.format("%s x%.2f", k, f)) end end
	table.sort(learnt)
	controls.learnt = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, y, 0, 14}, "^xC0C0C0" .. (#learnt > 0 and ("Learnt so far (" .. #(data.records or { }) .. " reviews): " .. table.concat(learnt, ", ")) or "Nothing learnt yet: reviews move the weights a little each time."))
	y = y + 22
	local function keep()
		local record = { time = os.time(), verdicts = verdicts, values = { }, note = controls.note.buf ~= "" and controls.note.buf or nil,
			focus = baseFocus and baseFocus.id, skill = build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
				and build.skillsTab.socketGroupList[build.mainSocketGroup].displayLabel,
			ascendancy = build.spec and build.spec.curAscendClassName }
		for k, v in pairs(values) do record.values[k] = v.value end
		local any = next(verdicts) ~= nil or record.note
		if any then review.Learn(data, record) end
		review.Save(data)
		return any
	end
	local function anyChange()
		for _, v in pairs(verdicts) do if v ~= 0 then return true end end
		return false
	end
	controls.improve = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {16, y, 150, 20}, "Improve this build", function()
		keep()
		main:ClosePopup()
		if onImprove then onImprove((review.ImproveFocus(baseFocus, verdicts, values))) end
	end)
	controls.improve.enabled = function() return onImprove ~= nil and anyChange() end
	controls.improve.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Upgrades the open build again, with the weights of what you marked too low raised")
		tooltip:AddLine(16, "^7and of what you marked too high lowered (an upgraded copy opens).")
	end
	controls.save = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {176, y, 120, 20}, "Save review", function()
		keep()
		main:ClosePopup()
	end)
	controls.close = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {520, y, 80, 20}, "Close", function()
		review.Save(data)
		main:ClosePopup()
	end)
	main:OpenPopup(620, y + 32, "Review the build", controls, nil, nil, "close")
end

-- Window to exclude or force uniques before generating
local function openUniqueChoices()
	local choices = loadUniqueChoices()
	local titles, seen = { }, { }
	for _, item in pairs(main.uniqueDB.list) do
		local title = item.title or item.name
		if title and not seen[title] then seen[title] = true t_insert(titles, title) end
	end
	table.sort(titles)
	local controls = { }
	local function matches()
		local text = (controls.search and controls.search.buf or ""):lower()
		local list = { }
		for _, title in ipairs(titles) do
			if text == "" or title:lower():find(text, 1, true) then
				t_insert(list, title)
				if #list >= 300 then break end
			end
		end
		if #list == 0 then list[1] = "(no unique matches)" end
		return list
	end
	local function remove(list, title)
		for i = #list, 1, -1 do if list[i] == title then t_remove(list, i) end end
	end
	local function listOrNone(list) return #list > 0 and list or { "(none)" } end
	controls.searchLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 22, 0, 16}, "^7Find a unique:")
	controls.search = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {130, 20, 250, 20}, "", "Name", nil, 60, function()
		controls.found.list = matches()
		controls.found.selIndex = 1
	end)
	controls.found = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {130, 48, 330, 20}, matches())
	controls.exclude = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {470, 48, 80, 20}, "Exclude", function()
		local title = controls.found.list[controls.found.selIndex]
		if not title or not seen[title] then return end
		remove(choices.forced, title) remove(choices.excluded, title)
		t_insert(choices.excluded, title)
		saveUniqueChoices()
		controls.excluded.list = listOrNone(choices.excluded)
		controls.forced.list = listOrNone(choices.forced)
	end)
	controls.exclude.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Never use this unique (too rare, too expensive, or you don't have it).")
	end
	controls.force = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {556, 48, 80, 20}, "Force", function()
		local title = controls.found.list[controls.found.selIndex]
		if not title or not seen[title] then return end
		remove(choices.forced, title) remove(choices.excluded, title)
		t_insert(choices.forced, title)
		saveUniqueChoices()
		controls.excluded.list = listOrNone(choices.excluded)
		controls.forced.list = listOrNone(choices.forced)
	end)
	controls.force.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Always use this unique: it's equipped early in the slot where it scores best,")
		tooltip:AddLine(16, "^7and the rest of the build is made around it (whatever its price or rules).")
	end
	controls.excludedLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 90, 0, 16}, "^7Excluded:")
	controls.excluded = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {130, 88, 330, 20}, listOrNone(choices.excluded))
	controls.removeExcluded = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {470, 88, 80, 20}, "Remove", function()
		remove(choices.excluded, controls.excluded.list[controls.excluded.selIndex])
		saveUniqueChoices()
		controls.excluded.list = listOrNone(choices.excluded)
		controls.excluded.selIndex = 1
	end)
	controls.forcedLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 118, 0, 16}, "^7Forced:")
	controls.forced = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {130, 116, 330, 20}, listOrNone(choices.forced))
	controls.removeForced = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {470, 116, 80, 20}, "Remove", function()
		remove(choices.forced, controls.forced.list[controls.forced.selIndex])
		saveUniqueChoices()
		controls.forced.list = listOrNone(choices.forced)
		controls.forced.selIndex = 1
	end)
	controls.note = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 150, 0, 14},
		"^xC0C0C0Stranglegasp is excluded unless forced (it needs the right anoints already on it).")
	controls.done = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {556, 176, 80, 20}, "Done", function()
		main:ClosePopup()
	end)
	main:OpenPopup(652, 206, "Uniques for the generator", controls, "done", nil, "done")
end

local function isPopupOpen(popup)
	-- (the generator window folded into its side panel still counts as open)
	if popup and popup.folded then return true end
	for _, p in ipairs(main.popups) do
		if p == popup then return true end
	end
	return false
end

-- Runs fn in a coroutine, one slice per frame, until it finishes or the popup closes
local function runInBackground(key, popup, fn, onDone, onError)
	local co = coroutine.create(fn)
	main.onFrameFuncs[key] = function()
		if not isPopupOpen(popup) then
			main.onFrameFuncs[key] = nil
			return
		end
		local ok, res = coroutine.resume(co)
		if not ok then
			main.onFrameFuncs[key] = nil
			ConPrintf("%s failed: %s", key, tostring(res))
			onError(res)
		elseif coroutine.status(co) == "dead" then
			main.onFrameFuncs[key] = nil
			onDone(res)
		end
	end
end

-- poe.ninja statistics for a skill, then the builds of its top players
-- (cached; both skipped after a timeout). done(entry or nil)
local function loadMeta(skillName, done, status)
	local source = GetBuildMetaSource()
	source:Load(skillName, function(entry)
		if not entry or not entry.players or #entry.players == 0 then return done(entry) end
		if status then status("^7Downloading the builds of the top " .. skillName .. " players (poe.ninja)...") end
		source:LoadPlayerDetails(skillName, 20, function(full) done(full or entry) end)
	end)
end

local function focusDropList()
	local list = { }
	for _, f in ipairs(new("BuildScorer"):BuildScorer({ }).focusList) do t_insert(list, { label = f.label, focus = f }) end
	return list
end
local function scenarioDropList()
	local list = { }
	for _, s in ipairs({
		{ label = "1 hit per target (safe, PoB default)", id = "SAFE" },
		{ label = "Optimistic overlap on a boss", id = "OPTIMISTIC" },
	}) do t_insert(list, { label = s.label, scenario = s }) end
	return list
end

local function investmentDropList()
	local list = { }
	for _, level in ipairs(GetPriceSource().levels) do t_insert(list, { label = level.label, level = level }) end
	return list
end

-- Price status line and "Update prices" button, at the given position
local function addPriceControls(controls, x, y, idle)
	controls.priceStatus = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {x, y + 2, 0, 14}, function() return GetPriceSource():Status() end)
	controls.updatePrices = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {x + 500, y, 120, 20}, "Update prices", function()
		GetPriceSource():Refresh()
	end)
	controls.updatePrices.enabled = function() return idle() and not GetPriceSource().loading end
	controls.updatePrices.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Download unique, gem, tattoo, runegraft and oil prices from poe.ninja (current league).")
		tooltip:AddLine(16, "^7Prices are cached for 6 hours. Without prices nothing is filtered by price.")
	end
end

local function investmentTooltip(tooltip)
	tooltip:Clear()
	tooltip:AddLine(16, "^7Investment level: the most you want to pay for one item, using poe.ninja prices.")
	tooltip:AddLine(16, "^7It also decides rare items. Influenced crafting is expensive: Mid allows one influence")
	tooltip:AddLine(16, "^7on the 2 slots where it gains the most, High up to two influences on 4 slots, Endgame on 7")
	tooltip:AddLine(16, "^7(tier 1 mods, good rolls, Mageblood-priced uniques), No limit everywhere with elevated mods.")
	tooltip:AddLine(16, "^7Exarch / Eater implicits")
	tooltip:AddLine(16, "^7on armour from tier 1 (League start) to Perfect (No limit).")
	tooltip:AddLine(16, "^7Items poe.ninja doesn't list are only allowed from High investment.")
end

------------------------------------------------------------------------------
-- Build ideas
------------------------------------------------------------------------------

function BuildIdeasPopupClass:OpenIdeas(build)
	local controls = { }
	local popup
	local state = { running = false, status = "", result = nil, selected = nil }
	local function idle() return not state.running end

	controls.focusLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 22, 0, 16}, "^7Aim for:")
	controls.focus = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {90, 20, 240, 20}, focusDropList())
	controls.focus.enabled = idle
	controls.focus.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7How ideas are scored. Balanced = damage x effective hit pool.")
		tooltip:AddLine(16, "^7Penalties apply for uncapped resistances, missing attributes and over-reserved mana.")
	end
	controls.scenarioLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {350, 22, 0, 16}, "^7Hits per target:")
	controls.scenario = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {460, 20, 260, 20}, scenarioDropList())
	controls.scenario.enabled = idle
	controls.scenario.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7How many times one use of your skill hits the same target is an assumption.")
		tooltip:AddLine(16, "^7Safe: 1 hit, as PoB counts it (plus any overlap you set in the Config tab).")
		tooltip:AddLine(16, "^7Optimistic: extra projectiles count only for skills the game lets hit a target")
		tooltip:AddLine(16, "^7several times. Ideas that rely on it say so.")
	end
	controls.chargesLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {740, 22, 0, 16}, "^7Flask charges/s:")
	controls.charges = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {850, 20, 50, 20}, "4", nil, "%D", 3)
	controls.charges.enabled = idle
	controls.charges.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Flask charges you gain per second from kills, used to estimate flask uptime.")
		tooltip:AddLine(16, "^7About 4 while mapping, 0 against a single boss. Mageblood flasks are always up.")
	end
	controls.investmentLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 50, 0, 16}, "^7Investment:")
	controls.investment = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {90, 48, 270, 20}, investmentDropList())
	controls.investment.selIndex = GetPriceSource().defaultLevel
	controls.investment.enabled = idle
	controls.investment.tooltipFunc = investmentTooltip
	controls.anoints = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {430, 49, 18}, "Anoints:", nil, "Try anointing the amulet with each notable (priced from its three oils).", true)
	controls.anoints.enabled = idle
	controls.tattoos = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {520, 49, 18}, "Tattoos:", nil, "Try tattoos on allocated attribute passives, keystone tattoos and runegrafts.", true)
	controls.tattoos.enabled = idle
	controls.timeless = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {625, 49, 18}, "Timeless:", nil, "Look for the best timeless jewel (type, seed, conqueror keystone and socket).\nOnly one Historic jewel can be used; skipped if the build already has one.", true)
	controls.timeless.enabled = idle
	controls.obtainable = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {750, 49, 18}, "Obtainable:", nil, "Only uniques that can still be obtained.", true)
	controls.obtainable.enabled = idle
	controls.level = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {880, 49, 18}, "My level:", nil, "Only uniques usable at the character's level.", true)
	controls.level.enabled = idle

	-- Details of the selected idea
	-- Upgrade plan: the ideas that cost something, best score gain per divine first
	local function upgradePlan(ideas)
		local priced = { }
		for _, idea in ipairs(ideas or { }) do
			if idea.totalCost and idea.totalCost >= 0.05 and (idea.gain or 0) > 0 then t_insert(priced, idea) end
		end
		table.sort(priced, function(a, b) return a.gain / a.totalCost > b.gain / b.totalCost end)
		local lines = { }
		if #priced > 0 then
			t_insert(lines, "^7Upgrade order (most score per divine first):")
			local spent = 0
			for i = 1, math.min(6, #priced) do
				local idea = priced[i]
				spent = spent + idea.totalCost
				t_insert(lines, string.format("^7  %d. %s: %s, damage %+.0f%%, hit pool %+.0f%% (total so far %s)", i, idea.title,
					GetPriceSource().FormatPrice(idea.totalCost), idea.dpsPct, idea.ehpPct, GetPriceSource().FormatPrice(spent)))
			end
		end
		return lines
	end
	local function showDetails(idea)
		state.selected = idea
		local list = { }
		if not idea and state.result then
			for _, line in ipairs(upgradePlan(state.result.ideas)) do addLines(list, line, 16) end
		end
		if idea then
			addLines(list, "^7" .. idea.title, 18)
			addLines(list, string.format("^7Damage %+.1f%%   Effective hit pool %+.1f%%   Passive points: %d", idea.dpsPct, idea.ehpPct, idea.points or 0), 16)
			for _, line in ipairs(idea.explanation or { }) do addLines(list, "^xFFCC44Why: ^7" .. line, 16) end
			if idea.costs and #idea.costs > 0 then
				addLines(list, "^xC0C0C0Price: ^7" .. table.concat(idea.costs, ", ") .. (idea.totalCost and ("   total " .. GetPriceSource().FormatPrice(idea.totalCost)) or ""), 16)
			end
			if idea.totalCost and idea.totalCost >= 0.05 then
				-- budget view: what one divine buys with this idea
				addLines(list, string.format("^xC0C0C0Value: ^7%+.1f%% damage and %+.1f%% effective hit pool per divine spent", idea.dpsPct / idea.totalCost, idea.ehpPct / idea.totalCost), 16)
			end
			for slotName, item in pairs(idea.generatedFlasks or { }) do addLines(list, "^7" .. slotName .. ": " .. item.name, 16) end
			for _, p in ipairs(idea.penalties or { }) do addLines(list, colorCodes.NEGATIVE .. "Cost: ^7" .. p.label, 16) end
			for _, a in ipairs(idea.assumptions or { }) do addLines(list, "^x66CCFFAssumes: ^7" .. a, 16) end
		end
		controls.details.list = list
	end
	local function applyIdea(idea)
		if state.running or not idea or not state.finder then return end
		state.finder:Apply(idea)
		state.status = "^7Applied: " .. idea.title .. ". Undo with Ctrl+Z in the Tree / Items tabs; search again for more ideas."
		state.result = nil
		controls.ideas.list = { }
		showDetails(nil)
	end
	controls.ideas = new("BuildIdeaListControl"):BuildIdeaListControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 106, 888, 250}, showDetails, applyIdea)
	controls.details = new("TextListControl"):TextListControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 364, 888, 150}, nil, { })

	controls.search = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 76, 100, 20}, function()
		return state.running and "Stop" or "Find ideas"
	end, function()
		if state.running then
			main.onFrameFuncs["BuildIdeasSearch"] = nil
			main.onFrameFuncs["BuildIdeasMetaWait"] = nil
			state.running = false
			state.status = "^7Stopped."
			return
		end
		if main.uniqueDB.loading then
			state.status = "^7The unique database is still loading, try again in a moment."
			return
		end
		local function startSearch(meta, skillName)
		local finder = new("SynergyFinder"):SynergyFinder(build.itemsTab, {
			focus = controls.focus.list[controls.focus.selIndex].focus,
			scenario = controls.scenario.list[controls.scenario.selIndex].scenario,
			chargesPerSecond = tonumber(controls.charges.buf) or 4,
			obtainableOnly = controls.obtainable.state,
			levelOnly = controls.level.state,
			investment = controls.investment.list[controls.investment.selIndex].level,
			allowAnoints = controls.anoints.state,
			allowTattoos = controls.tattoos.state,
			allowTimeless = controls.timeless.state,
			meta = meta, metaSkill = skillName,
			hitFloor = controls.focus.list[controls.focus.selIndex].focus.hitFloor and tonumber(controls.ehpFloor.buf) or nil,
			yieldEvery = 80,
			onProgress = function(stage, done)
				state.status = string.format("^7%s... (%d combinations tested)", stage, done)
			end,
		})
		state.finder = finder
		state.status = "^7Starting..."
		controls.ideas.list = { }
		showDetails(nil)
		runInBackground("BuildIdeasSearch", popup, function() return finder:Run() end, function(result)
			state.running = false
			state.result = result
			controls.ideas.list = result.ideas
			controls.ideas.defaultText = "^7No idea improved this build with these settings."
			state.status = string.format("^7%d ideas from %d combinations tested. Click one for details, double-click or \"Apply\" to use it.", #result.ideas, result.tested)
			-- (nothing selected first: the details show the upgrade order)
			showDetails(nil)
		end, function(err)
			state.running = false
			state.status = "^1Search failed: " .. tostring(err)
		end)
		end
		-- What players of the main skill use, from poe.ninja (cached 12 hours)
		local mainSkill = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player.mainSkill
		local skillName = mainSkill and mainSkill.activeEffect and mainSkill.activeEffect.grantedEffect and mainSkill.activeEffect.grantedEffect.name
		state.running = true
		controls.ideas.list = { }
		showDetails(nil)
		if not skillName then return startSearch(nil, nil) end
		state.status = "^7Loading poe.ninja build statistics for " .. skillName .. "..."
		local started, t0 = false, GetTime()
		local function go(entry)
			if started or not state.running then return end
			started = true
			main.onFrameFuncs["BuildIdeasMetaWait"] = nil
			startSearch(entry, skillName)
		end
		main.onFrameFuncs["BuildIdeasMetaWait"] = function()
			if GetTime() - t0 > 60000 then go(nil) end
		end
		GetBuildMetaSource():Load(skillName, function(entry) go(entry) end)
	end)
	controls.status = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {128, 78, 0, 16}, function() return state.status end)
	controls.ehpFloorLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {742, 78, 0, 16}, "^7Min max hit:")
	controls.ehpFloor = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {830, 76, 74, 20}, "10000", nil, "%D", 8)
	local function floorShown() return controls.focus.list[controls.focus.selIndex].focus.hitFloor ~= nil end
	controls.ehpFloorLabel.shown = floorShown
	controls.ehpFloor.shown = floorShown
	controls.ehpFloor.enabled = idle

	controls.apply = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 524, 130, 20}, "Apply selected", function()
		applyIdea(state.selected)
	end)
	controls.apply.enabled = function() return not state.running and state.selected ~= nil end
	addPriceControls(controls, 160, 524, idle)
	controls.close = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {824, 524, 80, 20}, "Close", function()
		main.onFrameFuncs["BuildIdeasSearch"] = nil
		main:ClosePopup()
	end)
	popup = main:OpenPopup(920, 556, "Build Ideas", controls, nil, nil, "close")
end

------------------------------------------------------------------------------
-- Build generator
------------------------------------------------------------------------------

function BuildIdeasPopupClass:OpenGenerator()
	local controls = { }
	local selectedFocus
	local popup
	local state = { running = false, status = "", confirmDiscard = false }
	local function idle() return not state.running end
	local tree = main:LoadTree(latestTreeVersion)
	local generatorStatics = new("BuildGenerator"):BuildGenerator({ }, { })

	local skills = generatorStatics.SkillList()
	controls.skillLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 22, 0, 16}, "^7Main skill:")
	controls.skill = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {120, 20, 260, 20}, skills)
	controls.skill.enabled = idle
	controls.skill.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Open the list and type to search.")
	end
	local ascendancies = generatorStatics.AscendancyList(tree)
	controls.ascendLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {400, 22, 0, 16}, "^7Ascendancy:")
	controls.ascend = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {490, 20, 240, 20}, ascendancies)
	controls.ascend.enabled = idle
	controls.levelLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {750, 22, 0, 16}, "^7Level:")
	controls.level = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {800, 20, 50, 20}, "92", nil, "%D", 3)
	controls.level.enabled = idle

	controls.focusLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 50, 0, 16}, "^7Aim for:")
	local focusList = focusDropList()
	-- (the player's own mix: movement speed and tankiness, block and life...)
	t_insert(focusList, { label = "Custom mix...", custom = true })
	controls.focus = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {120, 48, 260, 20}, focusList, function(index, value)
		if value and value.custom then
			openGoalWeights(function()
				value.label = "Custom: " .. new("BuildScorer"):BuildScorer({ }).CustomFocus(loadGoalWeights()).label:gsub("^Custom: ", "")
			end)
		end
	end)
	controls.focus.enabled = idle
	selectedFocus = function()
		local entry = controls.focus.list[controls.focus.selIndex]
		if entry.custom then return new("BuildScorer"):BuildScorer({ }).CustomFocus(loadGoalWeights()) end
		return entry.focus
	end
	controls.focus.tooltipFunc = function(tooltip)
		tooltip:Clear()
		local entry = controls.focus.list[controls.focus.selIndex]
		if entry and entry.custom then
			tooltip:AddLine(16, "^7" .. new("BuildScorer"):BuildScorer({ }).CustomFocus(loadGoalWeights()).label)
			tooltip:AddLine(16, "^7Select it again to change the weights.")
		else
			tooltip:AddLine(16, "^7What the build is made for. \"Custom mix...\" sets your own weights:")
			tooltip:AddLine(16, "^7damage, tankiness, avoidance, clear, movement speed, speed, life, ES, armour, evasion, block, recovery, area.")
		end
	end
	controls.investmentLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {400, 50, 0, 16}, "^7Investment:")
	controls.investment = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {490, 48, 276, 20}, investmentDropList())
	controls.investment.selIndex = GetPriceSource().defaultLevel
	controls.investment.enabled = idle
	controls.investment.tooltipFunc = investmentTooltip
	controls.ehpFloorLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {776, 50, 0, 16}, "^7Min max hit:")
	controls.ehpFloor = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {856, 48, 50, 20}, "10000", nil, "%D", 8)
	local function floorShown() return selectedFocus().hitFloor ~= nil end
	controls.ehpFloorLabel.shown = floorShown
	controls.ehpFloor.shown = floorShown
	controls.ehpFloor.enabled = idle
	controls.ehpFloor.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Maximum hit the build must survive, for its weakest damage type (physical, fire, cold,")
		tooltip:AddLine(16, "^7lightning, chaos). Above it, damage is maximised; below it, the score drops fast.")
	end
	controls.scenarioLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 78, 0, 16}, "^7Hits per target:")
	controls.scenario = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {120, 76, 260, 20}, scenarioDropList())
	controls.scenario.enabled = idle
	local configList = { }
	for _, sc in ipairs(new("AutoConfig"):AutoConfig({ }).scenarioList) do t_insert(configList, { label = sc.label, scenario = sc }) end
	controls.configLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {400, 78, 0, 16}, "^7Configure for:")
	controls.config = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {490, 76, 300, 20}, configList)
	-- several attempts of the same build, each exploring other early choices
	-- (BuildGenerator variants), the best one kept
	controls.triesLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {800, 78, 0, 16}, "^7Tries:")
	controls.tries = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {846, 76, 58, 20}, { "1", "2", "3", "4", "6", "8" })
	controls.tries.enabled = idle
	controls.tries.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Builds the same build several times, each try exploring other early choices")
		tooltip:AddLine(16, "^7(supports, passives, ascendancy, weapon), and keeps the best. Builds come out")
		tooltip:AddLine(16, "^7up to a point apart, so more tries give a better build. With \"Several cores\"")
		tooltip:AddLine(16, "^7the tries run at once; without, one after the other (each takes the full time).")
	end
	controls.config.enabled = idle
	controls.config.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7The Configuration tab is filled in for this situation, from what the build actually does:")
		tooltip:AddLine(16, "^7charges it generates, ailments its main skill inflicts reliably, attack / spell / crit")
		tooltip:AddLine(16, "^7conditions, leech and low life. Every change is listed when the build is done.")
	end
	controls.anoints = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {90, 105, 18}, "Anoint:", nil, "Anoint the amulet with the best notable within the investment level.", true)
	controls.anoints.enabled = idle
	controls.tattoos = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {190, 105, 18}, "Tattoos:", nil, "Tattoo allocated attribute passives (and keystones / masteries) within the investment level.", true)
	controls.tattoos.enabled = idle
	controls.timeless = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {330, 105, 18}, "Timeless jewel:", nil, "Socket the best timeless jewel (type, seed, conqueror keystone) from High investment,\nthen re-spend some passive points for the passives it transformed. Below High it's noted as an upgrade.", true)
	controls.timeless.enabled = idle
	controls.synergies = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {600, 105, 18}, "Look for uniques & synergies (slower):", nil, "After everything else, run the build ideas search once and apply the best idea.", true)
	controls.synergies.enabled = idle
	controls.threads = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {800, 105, 18}, "Several cores:", function(on)
		main.generatorThreads = on
		-- (checked here, in the app's frame: never from inside a generation)
		if on then
			local pg = new("ParallelGenerator"):ParallelGenerator()
			-- tries run at once: as many as there are threads by default
			if pg.Available() and controls.tries.selIndex == 1 then
				controls.tries:SelByValue(tostring(m_min(4, pg.MaxWorkers())))
			end
		end
	end, "Experimental: background threads build several archetypes (and rare items) at once.\nEach thread holds its own copy of the game data (about 1 GB). Off by default:\nit crashed the app on one PC. Without it everything runs one after the other.", main.generatorThreads == true)
	controls.threads.enabled = idle

	-- Archetypes: the ways this skill can scale; "Scan" builds each one quickly to compare them
	local archetypeLib = new("BuildArchetypes"):BuildArchetypes()
	local function archetypeList(results)
		local skill = controls.skill.list[controls.skill.selIndex]
		local list = { }
		for _, a in ipairs(archetypeLib.ForSkill(data.gems[skill.gemId], state.meta)) do
			local scan = results and results[a.id]
			local label = a.label
			if a.metaShare and a.metaShare >= 0.01 then
				label = string.format("%s (%d%% of players)", label, m_floor(a.metaShare * 100 + 0.5))
			end
			if scan and scan.error then
				label = label .. "   ^1(failed)"
			elseif scan and scan.estimated then
				label = string.format("%s   ^xC0C0C0(estimated) DPS %s, max hit %s", a.label, formatNumSep(string.format("%.0f", scan.dps or 0)), formatNumSep(string.format("%.0f", scan.minHit or 0)))
			elseif scan then
				label = string.format("%s   ^x88CC88quick build: DPS %s, max hit %s, score %.2f", a.label, formatNumSep(string.format("%.0f", scan.dps or 0)), formatNumSep(string.format("%.0f", scan.minHit or 0)), scan.score)
			end
			t_insert(list, { label = label, archetype = a, scan = scan })
		end
		if results then
			-- built archetypes first (by predicted full score: Modules/GeneratorLearning), then the estimated ones
			local learning = LoadModule("Modules/GeneratorLearning")
			for _, entry in ipairs(list) do
				if entry.scan and entry.scan.built and entry.scan.score then
					entry.priority = learning.Priority(entry.archetype.id, entry.scan.score)
					entry.label = entry.label .. string.format(", full build expected about %.1f", entry.scan.score + learning.Uplift(entry.archetype.id))
				end
			end
			table.sort(list, function(x, y)
				local bx, by = x.scan and x.scan.built and 1 or 0, y.scan and y.scan.built and 1 or 0
				if bx ~= by then return bx > by end
				local sx, sy = x.priority or (x.scan and x.scan.score) or -math.huge, y.priority or (y.scan and y.scan.score) or -math.huge
				if sx ~= sy then return sx > sy end
				return x.archetype.id < y.archetype.id
			end)
		else
			t_insert(list, 1, { label = "Automatic: scan every archetype, then fully build the best one", auto = true })
		end
		return list
	end
	controls.archetypeLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 136, 0, 16}, "^7Archetype:")
	controls.archetype = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {120, 134, 378, 20}, archetypeList())
	-- optional total budget for the whole build (divines)
	controls.totalBudgetLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {506, 136, 0, 16}, "^7Total div:")
	controls.totalBudget = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {568, 134, 54, 20}, "", nil, "%D", 6)
	controls.totalBudget.enabled = idle
	controls.totalBudget.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Optional: the total budget for the whole build, in divines (uniques, rares, anoints,")
		tooltip:AddLine(16, "^7tattoos, awakened gems). When set, it replaces the Investment level: the level is picked")
		tooltip:AddLine(16, "^7from it (rares, influences, gems), one item can't take more than half of it, and the")
		tooltip:AddLine(16, "^7finished build is fitted under it by making the parts worth least per divine cheaper.")
		tooltip:AddLine(16, "^7Every full build also lists its upgrade order: what to buy first, best score per divine.")
		tooltip:AddLine(16, "^7Rares are priced roughly by level (poe.ninja doesn't list them). Leave empty for no total.")
	end
	controls.uniqueChoices = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {628, 134, 114, 20}, function()
		local c = loadUniqueChoices()
		return string.format("Uniques (%d/%d)", #c.forced, #c.excluded)
	end, function()
		openUniqueChoices()
	end)
	controls.uniqueChoices.enabled = idle
	controls.uniqueChoices.tooltipFunc = function(tooltip)
		tooltip:Clear()
		local c = loadUniqueChoices()
		tooltip:AddLine(16, "^7Force uniques to build around, or exclude uniques the generator must not use.")
		tooltip:AddLine(16, "^7Forced: " .. (#c.forced > 0 and table.concat(c.forced, ", ") or "none"))
		tooltip:AddLine(16, "^7Excluded: " .. (#c.excluded > 0 and table.concat(c.excluded, ", ") or "none"))
	end
	controls.archetype.enabled = idle
	controls.hybrids = new("CheckBoxControl"):CheckBoxControl({"TOPLEFT",nil,"TOPLEFT"}, {886, 105, 18}, "Hybrids:", nil,
		"Automatic mode: also build the two best archetypes together (e.g. strength stacking + impale),\nwhen they can be combined.", true)
	controls.hybrids.enabled = idle
	controls.archetype.tooltipFunc = function(tooltip)
		tooltip:Clear()
		local entry = controls.archetype.list[controls.archetype.selIndex]
		if entry and entry.auto then
			tooltip:AddLine(16, "^7Builds a quick version of every archetype that fits the skill, then the full build")
			tooltip:AddLine(16, "^7of the one that scored best. Takes longer: about a minute per archetype first.")
		end
		if entry and entry.archetype then
			tooltip:AddLine(16, "^7" .. entry.archetype.summary)
			if entry.archetype.keystones and #entry.archetype.keystones > 0 then tooltip:AddLine(16, "^7Keystones: " .. table.concat(entry.archetype.keystones, ", ")) end
			if entry.archetype.supports then tooltip:AddLine(16, "^7Supports: " .. table.concat(entry.archetype.supports, ", ")) end
			if entry.archetype.uniques then tooltip:AddLine(16, "^7Uniques tried first: " .. table.concat(entry.archetype.uniques, ", ")) end
			if entry.archetype.jewels then tooltip:AddLine(16, "^7Jewels: " .. table.concat(entry.archetype.jewels, ", ")) end
			if entry.scan and entry.scan.log then
				tooltip:AddLine(16, "^7Scan result:")
				for _, l in ipairs(entry.scan.log) do tooltip:AddLine(14, "^xC0C0C0  " .. l) end
			end
		end
		tooltip:AddLine(16, "^7The full build commits to this archetype, then optimises everything else around it.")
	end
	controls.skill.selFunc = function()
		state.meta = nil
		controls.archetype.list = archetypeList()
		controls.archetype.selIndex = 1
	end
	controls.scan = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {750, 134, 154, 20}, "Scan archetypes", function()
		state.startScan()
	end)
	controls.scan.enabled = idle
	controls.scan.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Builds one quick version of the skill, then plans every archetype on top of it (its keystones,")
		tooltip:AddLine(16, "^7supports, uniques, then the stats that scale it best), a few seconds each. The 3 most promising")
		tooltip:AddLine(16, "^7get their own quick build. Pick one in the list and click Generate for the full build.")
	end

	controls.log = new("TextListControl"):TextListControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 192, 888, 262}, nil, { })
	local function setLog(lines)
		local list = { }
		for _, l in ipairs(lines) do addLines(list, l, 16) end
		controls.log.list = list
	end
	setLog({
		"^7Optional first: Scan archetypes builds a quick version of each way the skill can scale (crit, non-crit keystones,",
		"^7Chaos Inoculation, mana / attribute stacking, conversion, mines / traps / totems) and sorts them by result.",
		"^7Generates a complete build on a new, unsaved build, committed to the chosen archetype:",
		"^7  1. configuration from what the build does   2. support gems for a 6-link   3. passive tree, masteries, ascendancy",
		"^7  4. item bases   5. rare items (one bench craft each): influenced from Mid investment, Exarch / Eater implicits",
		"^7  6. supports again; curse, aura, guard and movement setups linked like real builds",
		"^7  7. tree again for the gear, ascendancy and bloodline (shared points)",
		"^7  8. every affordable unique tried in every slot, uniques players of the skill use (poe.ninja), rare / timeless /",
		"^7      Forbidden / Watcher's Eye / cluster jewels, anoint and tattoos   9. flasks (unique ones too), pantheon, bandit,",
		"^7      aura stacking, the rares made again for the finished build   10. optionally, the best unique / keystone idea",
		"^7  11. packages the top players use together (adapted before judging)   12. passive tree rebuilt with shortest paths",
		"^7Scored on your PC with PoB's calculator: damage the build can pay for; mostly the max hit it survives (weakest",
		"^7damage type, pinnacle / uber boss hits), little EHP; recovery; a defence checklist (freeze, shock, bleed...).",
	})

	local function makeOptions()
		local skill = controls.skill.list[controls.skill.selIndex]
		local asc = controls.ascend.list[controls.ascend.selIndex]
		local archetypeEntry = controls.archetype.list[controls.archetype.selIndex]
		local options = {
			gemId = skill.gemId, classId = asc.classId, ascendClassId = asc.ascendClassId,
			level = m_min(100, math.max(1, tonumber(controls.level.buf) or 92)),
			focus = selectedFocus(),
			investment = controls.investment.list[controls.investment.selIndex].level,
			hitFloor = selectedFocus().hitFloor and tonumber(controls.ehpFloor.buf) or nil,
			scenario = controls.scenario.list[controls.scenario.selIndex].scenario,
			configScenario = controls.config.list[controls.config.selIndex].scenario,
			allowAnoints = controls.anoints.state,
			allowTattoos = controls.tattoos.state,
			timeless = controls.timeless.state,
			synergies = controls.synergies.state,
			-- what earlier generations learnt (Modules/GeneratorKnowledge)
			knowledge = true,
			totalBudget = tonumber(controls.totalBudget.buf) and tonumber(controls.totalBudget.buf) > 0 and tonumber(controls.totalBudget.buf) or nil,
			-- (the generation runs between frames: longer slices leave more of
			-- the time to it; the window still redraws about 12 times a second)
			yieldEvery = 80,
		}
		options.archetype = archetypeEntry and archetypeEntry.archetype
		-- what the player's reviews taught (Classes/BuildReview)
		local learnt, note = new("BuildReview"):BuildReview().ApplyLearned(options.focus)
		if note then options.focus, options.learntNote = learnt, note end
		-- the player's unique choices
		local choices = loadUniqueChoices()
		options.excludedUniques = { }
		for _, title in ipairs(choices.excluded) do options.excludedUniques[title] = true end
		options.forcedUniques = { }
		for _, title in ipairs(choices.forced) do t_insert(options.forcedUniques, title) end
		return options
	end

	controls.generate = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 162, 100, 20}, function()
		return state.running and "Stop" or "Generate"
	end, function()
		if state.running then
			main.onFrameFuncs["BuildGenerator"] = nil
			main.onFrameFuncs["BuildMetaWait"] = nil
			if state.parallel then state.parallel:Stop() state.parallel = nil end
			state.running = false
			state.status = "^7Stopped. The partly generated build is still open."
			return
		end
		if main.uniqueDB.loading then
			state.status = "^7The unique database is still loading, try again in a moment."
			return
		end
		local current = main.modes["BUILD"]
		if main.mode == "BUILD" and current and current.unsaved and not state.confirmDiscard then
			state.confirmDiscard = true
			state.status = colorCodes.WARNING .. "Your open build has unsaved changes. Click Generate again to discard them."
			return
		end
		state.confirmDiscard = false
		state.progress = nil
		state.generator = nil
		local entry = controls.archetype.list[controls.archetype.selIndex]
		if entry and entry.auto then
			-- scan first; the scan sorts the list best first, then this runs again
			-- (with background threads: the best few archetypes fully built at
			-- once, the best result kept)
			state.afterScan = function()
				state.confirmDiscard = true
				if state.parallelFull and state.parallelFull() then return end
				controls.generate.onClick()
			end
			state.confirmDiscard = true -- (already confirmed above)
			state.startScan()
			return
		end
		local skill = controls.skill.list[controls.skill.selIndex]
		local asc = controls.ascend.list[controls.ascend.selIndex]
		local options = makeOptions()
		state.running = true
		-- several tries (variants of the same generation), the best one kept:
		-- at once in background threads when they're on, else one after the other
		local tries = tonumber(controls.tries.list[controls.tries.selIndex]) or 1
		local parallelTries = tries > 1 and not state.noParallelTries and options.archetype
			and new("ParallelGenerator"):ParallelGenerator().Available()
		state.noParallelTries = nil
		local attempt, bestTry, tryScores = 1, nil, { }
		options.variant = 1
		local buildName = "Generated " .. skill.label .. " " .. asc.ascendName
		local startGeneration
		startGeneration = function()
		state.status = tries > 1 and string.format("^7Try %d of %d: creating a new build...", attempt, tries) or "^7Creating a new build..."
		-- Open a new empty build, then generate into it once it exists
		main:SetMode("BUILD", false, buildName)
		local waited = false
		main.onFrameFuncs["BuildGenerator"] = function()
			if not waited then waited = true return end
			local build = main.modes["BUILD"]
			local generator = new("BuildGenerator"):BuildGenerator(build, options)
			state.generator = generator
			state.progress = 0
			options.onProgress = function(stage, index, count, sub)
				local inTry = ((index - 1) + (sub or 0)) / m_max(1, count)
				state.progress = ((attempt - 1) + inTry) / tries
				state.status = string.format("^7%sStep %d of %d (%d%%): %s...", tries > 1 and string.format("Try %d of %d, ", attempt, tries) or "",
					index, count, m_floor(inTry * 100), stage)
			end
			runInBackground("BuildGenerator", popup, function() return generator:Run() end, function(result)
				-- this try kept if it's the best so far; the next try, or the best one opened
				local record = { score = result.final.score or -math.huge, xml = build:SaveDB("code"), result = result, variant = attempt,
					overlap = generator.overlap and generator.overlap:GetAssumptions() or { } }
				t_insert(tryScores, string.format("%.2f", record.score))
				if not bestTry or record.score > bestTry.score then bestTry = record end
				if attempt < tries and state.running then
					attempt = attempt + 1
					options.variant = attempt
					startGeneration()
					return
				end
				state.running = false
				if bestTry.variant ~= attempt then
					main:SetMode("BUILD", false, buildName, bestTry.xml)
				end
				result = bestTry.result
				local lines = { string.format("^7Done%s. Damage %s, effective hit pool %s. The build is open and not saved yet: use Save As to keep it.",
					tries > 1 and string.format(" (best of %d tries: try %d; scores %s)", tries, bestTry.variant, table.concat(tryScores, ", ")) or "",
					formatNumSep(string.format("%.0f", result.final.dps)), formatNumSep(string.format("%.0f", result.final.ehp))) }
				for _, l in ipairs(result.log) do t_insert(lines, "^7- " .. l) end
				t_insert(lines, "^xC0C0C0" .. result.costLine)
				for _, c in ipairs(result.configChanges or { }) do t_insert(lines, "^x66CCFFConfig: ^7" .. c) end
				for _, p in ipairs(result.final.penalties or { }) do t_insert(lines, colorCodes.NEGATIVE .. "Cost: ^7" .. p.label) end
				for _, a in ipairs(result.assumptions) do t_insert(lines, "^x66CCFFAssumes: ^7" .. a) end
				for _, a in ipairs(bestTry.overlap) do t_insert(lines, "^x66CCFFAssumes: ^7" .. a) end
				setLog(lines)
				state.status = "^7Finished."
				local opened = main.modes["BUILD"]
				if opened then
					opened.buildFlag = true
					opened.modFlag = true
				end
				state.lastFocus = options.focus
				state.askReview()
			end, function(err)
				state.running = false
				state.status = "^1Generation failed: " .. tostring(err)
			end)
		end
		end
		-- What players of this skill use, from poe.ninja (cached 12 hours); generation
		-- starts when it arrives, or after 20 seconds without it
		state.status = "^7Loading poe.ninja build statistics for " .. skill.label .. "..."
		local started, t0 = false, GetTime()
		local function go(entry)
			if started or not state.running then return end
			started = true
			main.onFrameFuncs["BuildMetaWait"] = nil
			options.meta = entry
			if parallelTries then
				state.meta = entry
				state.running = false
				if state.fullParallel({ options.archetype }, tries) then return end
				state.running = true
			end
			startGeneration()
		end
		main.onFrameFuncs["BuildMetaWait"] = function()
			if GetTime() - t0 > 60000 then go(nil) end
		end
		loadMeta(skill.label, function(entry) go(entry) end, function(text) state.status = text end)
	end)
	-- Notes shown for a scanned archetype, from a generation log
	local function scanNotes(log, keystones)
		local notes = { }
		for _, l in ipairs(log or { }) do
			if l:match("^Archetype uniques") or l:match("^Supports") or l:match("^Armour type") or l:match("^Damage scales best") then t_insert(notes, l) end
		end
		if keystones and #keystones > 0 then t_insert(notes, "Keystones: " .. table.concat(keystones, ", ")) end
		return notes
	end
	-- Generations in background threads, several at once (Classes/ParallelGenerator).
	-- onResult(archetype, summary, xml) / onFailed(archetype, err), then onAll()
	local function runParallel(archetypes, quick, meta, onResult, onFailed, onAll, variants)
		local pg = new("ParallelGenerator"):ParallelGenerator()
		state.parallel = pg
		local jobs = { }
		for i, archetype in ipairs(archetypes) do
			local options = makeOptions()
			options.archetype = archetype
			options.quick = quick
			if quick then options.synergies = false end
			options.meta = meta
			options.variant = variants and variants[i] or nil
			jobs[i] = pg.JobFromOptions(options)
		end
		local doneCount, runningCount = 0, 0
		local t0 = GetTime()
		main.onFrameFuncs["BuildParallelStatus"] = function()
			if not state.running then main.onFrameFuncs["BuildParallelStatus"] = nil return end
			state.progress = doneCount / m_max(1, #jobs)
			state.status = string.format("^7Building %d build%s at once (up to %d threads): %d running, %d done, %d s...",
				#jobs, #jobs == 1 and "" or "s", pg.MaxWorkers(), runningCount, doneCount, m_floor((GetTime() - t0) / 1000))
		end
		pg:Run(jobs, {
			onStart = function() runningCount = runningCount + 1 end,
			onDone = function(index, summary, xml)
				runningCount, doneCount = runningCount - 1, doneCount + 1
				onResult(archetypes[index], summary, xml, variants and variants[index])
			end,
			onError = function(index, err)
				runningCount, doneCount = math.max(0, runningCount - 1), doneCount + 1
				ConPrintf("Parallel generation failed: %s", tostring(err))
				onFailed(archetypes[index], err)
			end,
			onAllDone = function()
				main.onFrameFuncs["BuildParallelStatus"] = nil
				state.parallel = nil
				if state.running then onAll() end
			end,
		})
	end

	-- Archetype scan: a quick build per archetype, each in its own new build
	state.startScan = function()
		if main.uniqueDB.loading then
			state.status = "^7The unique database is still loading, try again in a moment."
			return
		end
		local current = main.modes["BUILD"]
		if main.mode == "BUILD" and current and current.unsaved and not state.confirmDiscard then
			state.confirmDiscard = true
			state.status = colorCodes.WARNING .. "Your open build has unsaved changes. Click Scan again to discard them."
			return
		end
		state.confirmDiscard = false
		local skill = controls.skill.list[controls.skill.selIndex]
		local asc = controls.ascend.list[controls.ascend.selIndex]
		local list = { }
		local standard
		for _, entry in ipairs(archetypeList()) do
			if entry.archetype then
				t_insert(list, entry.archetype)
				if entry.archetype.id == "STANDARD" then standard = entry.archetype end
			end
		end
		standard = standard or list[1]
		-- Step 1: a quick build of the skill, then every archetype planned on top
		-- of it (seconds each); step 2: quick builds of the most promising ones
		local results = { }
		local queue = { standard }
		local built = 0
		state.running = true
		local meta
		local t0 = GetTime()
		local function finish()
			state.running = false
			controls.archetype.list = archetypeList(results)
			controls.archetype.selIndex = 1
			local lines = { string.format("^7Archetype scan for %s (%s), best first. Pick one in the Archetype list and click Generate:", skill.label, asc.ascendName) }
			for _, entry in ipairs(controls.archetype.list) do
				t_insert(lines, "^7- " .. entry.label)
				if entry.scan and entry.scan.notes then
					for _, l in ipairs(entry.scan.notes) do t_insert(lines, "^xC0C0C0      " .. l) end
				end
			end
			t_insert(lines, "^xC0C0C0Built: quick builds (no bloodline, jewels, flasks or synergies yet; the full build adds them). Estimated: planned on top of")
			t_insert(lines, "^xC0C0C0the first quick build with 20 units of investment spent on the best stats; not comparable with built scores.")
			setLog(lines)
			state.status = string.format("^7Scan finished in %d s.", m_floor((GetTime() - t0) / 1000))
			-- Automatic: go on with the full build of the best archetype
			local after = state.afterScan
			state.afterScan = nil
			if after then after() end
		end
		local function nextOne()
			if not state.running then return end
			-- after the first (planning) build: the promising archetypes all at once
			if built > 0 and #queue >= 2 and new("ParallelGenerator"):ParallelGenerator().Available() then
				local batch = queue
				queue = { }
				local okCount = 0
				runParallel(batch, true, meta, function(archetype, summary)
					local notes = scanNotes(summary.log, summary.keystones)
					results[archetype.id] = { score = summary.score, dps = summary.dps, ehp = summary.ehp, minHit = summary.minHit, notes = notes, log = notes, built = true }
					okCount = okCount + 1
				end, function(archetype, err)
					results[archetype.id] = { error = tostring(err) }
				end, function()
					if okCount == 0 then
						-- background threads don't work here: one after the other instead
						ConPrintf("Parallel generation unavailable, building one at a time")
						new("ParallelGenerator"):ParallelGenerator().Disable()
						for _, a in ipairs(batch) do results[a.id] = nil t_insert(queue, a) end
						return nextOne()
					end
					built = built + #batch
					finish()
				end)
				return
			end
			local archetype = t_remove(queue, 1)
			if not archetype then return finish() end
			built = built + 1
			local total = built + #queue
			state.status = string.format("^7Building %d of %d: %s...", built, total, archetype.label)
			main:SetMode("BUILD", false, "Archetype scan: " .. archetype.label)
			local waited = false
			main.onFrameFuncs["BuildGenerator"] = function()
				if not waited then waited = true return end
				local build = main.modes["BUILD"]
				local options = makeOptions()
				options.archetype = archetype
				options.quick = true
				options.synergies = false
				options.meta = meta
				local generator = new("BuildGenerator"):BuildGenerator(build, options)
				state.generator = generator
				local planning = archetype == standard
				options.onProgress = function(stage, index, count, sub)
					local inBuild = ((index or 1) - 1 + (sub or 0)) / m_max(1, count or 1)
					state.progress = ((built - 1) + inBuild) / m_max(1, built + #queue)
					state.status = string.format("^7Building %d of %d (%s, %d%%): %s...", built, built + #queue, archetype.label, m_floor(inBuild * 100), stage)
				end
				runInBackground("BuildGenerator", popup, function()
					local result = generator:Run()
					local plan
					if planning then
						state.status = "^7Planning every archetype on top of the first build..."
						generator.stage = "Planning archetypes"
						plan = new("ScalingPlanner"):ScalingPlanner(generator):Run(list, { units = 20 })
					end
					return { result = result, plan = plan, minHit = (generator.scorer:MinMaxHit(build.calcsTab.mainOutput)) }
				end, function(r)
					local result = r.result
					local notes = { }
					for _, l in ipairs(result.log) do
						if l:match("^Archetype uniques") or l:match("^Supports") or l:match("^Armour type") or l:match("^Damage scales best") then t_insert(notes, l) end
					end
					local keystones = { }
					for _, node in pairs(build.spec.allocNodes) do
						if node.type == "Keystone" then t_insert(keystones, node.dn) end
					end
					table.sort(keystones)
					if #keystones > 0 then t_insert(notes, "Keystones: " .. table.concat(keystones, ", ")) end
					results[archetype.id] = { score = result.final.score, dps = result.final.dps, ehp = result.final.ehp, minHit = r.minHit, notes = notes, log = notes, built = true }
					if r.plan then
						-- estimates for the others; the best few get a quick build
						local promising = 0
						for _, p in ipairs(r.plan) do
							local id = p.archetype.id
							if not p.error and id ~= archetype.id then
								local planNotes = { }
								if #p.commitments > 0 then t_insert(planNotes, "Commits to: " .. table.concat(p.commitments, ", ")) end
								if p.plan ~= "" then t_insert(planNotes, "Best investment: " .. p.plan) end
								results[id] = { score = p.score, dps = p.dps, minHit = p.minHit, notes = planNotes, log = planNotes, estimated = true }
								-- (with background threads, as many as they build in two rounds)
								local pgInfo = new("ParallelGenerator"):ParallelGenerator()
								local scanBuilds = state.scanBuilds or (pgInfo.Available() and math.max(3, 2 * pgInfo.MaxWorkers()) or 3)
								if promising < scanBuilds then
									promising = promising + 1
									for _, a in ipairs(list) do if a.id == id then t_insert(queue, a) end end
								end
							elseif p.archetype.id == archetype.id and not p.error then
								t_insert(notes, "Best investment: " .. p.plan)
							end
						end
					end
					build.modFlag = false
					nextOne()
				end, function(err)
					results[archetype.id] = { error = tostring(err) }
					nextOne()
				end)
			end
		end
		state.status = "^7Loading poe.ninja build statistics for " .. skill.label .. "..."
		local started = false
		local function go(entry)
			if started or not state.running then return end
			started = true
			main.onFrameFuncs["BuildMetaWait"] = nil
			meta = entry
			state.meta = entry
			nextOne()
		end
		main.onFrameFuncs["BuildMetaWait"] = function()
			if GetTime() - t0 > 60000 then go(nil) end
		end
		loadMeta(skill.label, function(entry) go(entry) end, function(text) state.status = text end)
	end
	-- Automatic mode, last step: the best built archetypes fully generated in
	-- background threads at once; the best one is opened. false = not possible
	state.parallelFull = function()
		local pgStatic = new("ParallelGenerator"):ParallelGenerator()
		if not pgStatic.Available() then return false end
		-- (at least the best three: a quick build ranks archetypes by how they
		-- start, and the one that ends best is often second or third)
		-- (and up to five when more start close to the best one; archetypes whose
		-- quick builds came out the same, e.g. one adding nothing usable, once)
		-- (ranked by predicted full score: the quick score plus what a full
		-- build of the archetype usually gains over its quick build, learnt
		-- from earlier generations, with a bonus for little-tried ones:
		-- Modules/GeneratorLearning)
		local learning = LoadModule("Modules/GeneratorLearning")
		local ranked = { }
		for _, entry in ipairs(controls.archetype.list) do
			local scan = entry.scan
			if entry.archetype and scan and scan.built and not scan.error and scan.score then
				t_insert(ranked, { archetype = entry.archetype, quick = scan.score, priority = learning.Priority(entry.archetype.id, scan.score) })
			end
		end
		table.sort(ranked, function(a, b)
			if a.priority ~= b.priority then return a.priority > b.priority end
			return a.archetype.id < b.archetype.id
		end)
		local candidates, scores = { }, { }
		state.quickScores = { }
		local bestScore
		for _, r in ipairs(ranked) do
			local same = false
			for _, s in ipairs(scores) do if math.abs(s - r.quick) < 1e-6 then same = true end end
			bestScore = bestScore or r.priority
			if not same and (#candidates < 3 or (#candidates < 5 and r.priority >= bestScore - 0.5)) then
				t_insert(candidates, r.archetype)
				t_insert(scores, r.quick)
				state.quickScores[r.archetype.id] = r.quick
			end
		end
		-- (and the best two together, when they can be combined: a hybrid)
		if ranked[1] and ranked[2] and controls.hybrids.state then
			local hybrid = archetypeLib.Hybrid(ranked[1].archetype, ranked[2].archetype)
			if hybrid then t_insert(candidates, hybrid) end
		end
		if #candidates < 2 then return false end
		return state.fullParallel(candidates, tonumber(controls.tries.list[controls.tries.selIndex]) or 1)
	end
	-- Full builds in background threads: each archetype, each try (variant),
	-- the best one opened. false when background threads aren't available
	state.fullParallel = function(archetypes, tries)
		local pgStatic = new("ParallelGenerator"):ParallelGenerator()
		if not pgStatic.Available() then return false end
		local candidates, variants = { }, { }
		for _, archetype in ipairs(archetypes) do
			for v = 1, m_max(1, tries or 1) do
				t_insert(candidates, archetype)
				t_insert(variants, v)
			end
		end
		local skill = controls.skill.list[controls.skill.selIndex]
		local asc = controls.ascend.list[controls.ascend.selIndex]
		state.running = true
		state.builtByArchetype = { }
		state.alternatives = nil
		local best
		local failures = { }
		runParallel(candidates, false, state.meta, function(archetype, summary, xml, variant)
			-- (learnt: how much the full build gained over the quick one)
			local quick = state.quickScores and state.quickScores[archetype.id]
			if quick and summary.score and (variant or 1) == 1 then
				pcall(function() LoadModule("Modules/GeneratorLearning").Record(archetype.id, skill.label, quick, summary.score) end)
			end
			-- (each archetype's best build kept: the close ones are offered as alternatives)
			state.builtByArchetype = state.builtByArchetype or { }
			local prev = state.builtByArchetype[archetype.id]
			if summary.score and (not prev or summary.score > prev.score) then
				state.builtByArchetype[archetype.id] = { archetype = archetype, score = summary.score, dps = summary.dps, ehp = summary.ehp, xml = xml }
			end
			if not best or (summary.score or -math.huge) > (best.summary.score or -math.huge) then
				best = { archetype = archetype, summary = summary, xml = xml, variant = variant }
			end
		end, function(archetype, err)
			t_insert(failures, archetype.label .. ": " .. tostring(err))
		end, function()
			state.running = false
			if not best then
				-- background threads don't work here: the usual full build instead
				ConPrintf("Parallel generation failed (%s), building in the app instead", tostring(failures[1]))
				pgStatic.Disable()
				state.confirmDiscard = true
				state.noParallelTries = true
				controls.generate.onClick()
				return
			end
			main:SetMode("BUILD", false, "Generated " .. skill.label .. " " .. asc.ascendName .. " (" .. best.archetype.label .. ")", best.xml)
			local result = best.summary
			local lines = { string.format("^7Done: %d builds fully built at once (%d archetype%s x %d tr%s), the best kept: %s, try %d. Damage %s, effective hit pool %s. The build is open and not saved yet: use Save As to keep it.",
				#candidates, #archetypes, #archetypes == 1 and "" or "s", m_max(1, tries or 1), (tries or 1) == 1 and "y" or "ies", best.archetype.label, best.variant or 1,
				formatNumSep(string.format("%.0f", result.dps or 0)), formatNumSep(string.format("%.0f", result.ehp or 0))) }
			for _, l in ipairs(result.log or { }) do t_insert(lines, "^7- " .. l) end
			if result.costLine then t_insert(lines, "^xC0C0C0" .. result.costLine) end
			for _, c in ipairs(result.configChanges or { }) do t_insert(lines, "^x66CCFFConfig: ^7" .. c) end
			for _, pen in ipairs(result.penalties or { }) do t_insert(lines, colorCodes.NEGATIVE .. "Cost: ^7" .. pen.label) end
			for _, a in ipairs(result.assumptions or { }) do t_insert(lines, "^x66CCFFAssumes: ^7" .. a) end
			for _, f in ipairs(failures) do t_insert(lines, colorCodes.NEGATIVE .. "Failed: ^7" .. f) end
			-- other ideas that came close: kept so they can be opened (uncommon
			-- builds within reach of the best one)
			local alternatives = { }
			for id, built in pairs(state.builtByArchetype or { }) do
				if id ~= best.archetype.id and built.score >= result.score - 1.0 then t_insert(alternatives, built) end
			end
			table.sort(alternatives, function(a, b) return a.score > b.score end)
			if #alternatives > 0 then
				t_insert(lines, "^7Other ideas close to it (open them below, Alternatives):")
				for _, alt in ipairs(alternatives) do
					t_insert(lines, string.format("^7- %s: score %.2f (%+.2f), damage %s, effective hit pool %s", alt.archetype.label, alt.score, alt.score - result.score,
						formatNumSep(string.format("%.0f", alt.dps or 0)), formatNumSep(string.format("%.0f", alt.ehp or 0))))
				end
				state.alternatives = alternatives
				local list = { }
				for _, alt in ipairs(alternatives) do t_insert(list, { label = string.format("%s (%+.2f)", alt.archetype.label, alt.score - result.score), alt = alt }) end
				controls.alternatives:SetList(list)
				controls.alternatives.selIndex = 1
			end
			setLog(lines)
			state.status = "^7Finished."
		end)
		return true
	end

	-- Compare with top players: the open build against the strongest builds of
	-- the skill on poe.ninja, each scored like a generated build, taken apart
	-- (what carries it) and tried part by part in the open build (what of
	-- theirs would help it); in background threads (Modules/BuildComparison)
	controls.compare = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {650, 464, 168, 20}, "Compare with top players", function()
		local pg = new("ParallelGenerator"):ParallelGenerator()
		if not pg.Available() then
			state.status = "^7Comparing needs background threads: tick \"Several cores\" (experimental) first."
			return
		end
		local build = main.modes["BUILD"]
		if main.mode ~= "BUILD" or not build then
			state.status = "^7Generate or open a build first."
			return
		end
		local skill = controls.skill.list[controls.skill.selIndex]
		local investment = controls.investment.list[controls.investment.selIndex].level
		local focus = selectedFocus()
		local ours = build:SaveDB("code")
		local function num(v) return formatNumSep(string.format("%.0f", v or 0)) end
		state.running = true
		state.status = "^7Loading the top " .. skill.label .. " builds (poe.ninja)..."
		local source = GetBuildMetaSource()
		local cached = source.cache and source.cache[skill.label]
		if cached and cached.details and not cached.details.topBuilds then cached.detailsTime = nil end
		loadMeta(skill.label, function(entry)
			local top = entry and entry.details and entry.details.topBuilds or { }
			if #top == 0 then
				state.running = false
				state.status = "^7No top player builds found for " .. skill.label .. "."
				return
			end
			local jobs = { }
			for i, t in ipairs(top) do
				jobs[i] = { kind = "compare", code = t.code, ours = ours, skill = skill.label, focusId = focus.id,
					tier = investment.awakenedGems and "uber" or "pinnacle", player = { name = t.name, ascendancy = t.ascendancy, level = t.level } }
			end
			local lines = { "^7Comparison with the strongest " .. skill.label .. " builds on poe.ninja (" .. (entry.league or "current league") .. "), scored like generated builds:" }
			setLog(lines)
			state.parallel = pg
			pg:Run(jobs, {
				onDone = function(index, r)
					local p = r.player or { }
					local t, o = r.theirs or { }, r.ours or { }
					t_insert(lines, string.format("^7%s (%s, level %s): score %.2f, DPS %s, lowest max hit %s   ^xC0C0C0(yours: score %.2f, DPS %s, max hit %s)",
						tostring(p.name), tostring(t.class or p.ascendancy), tostring(t.level or p.level), t.score or 0, num(t.dps), num(t.minHit), o.score or 0, num(o.dps), num(o.minHit)))
					local carries = { }
					for _, row in ipairs(r.ablation or { }) do t_insert(carries, string.format("%s (%+.2f)", row.label, row.dScore)) end
					if #carries > 0 then t_insert(lines, "^xC0C0C0    What carries their build: " .. table.concat(carries, ", ")) end
					local helps = { }
					for _, row in ipairs(r.transplant or { }) do t_insert(helps, string.format("%s (%+.2f)", row.label, row.dScore)) end
					t_insert(lines, "^x88CC88    Of theirs, would help yours: " .. (#helps > 0 and table.concat(helps, ", ") or "none of their single parts beats yours"))
					setLog(lines)
				end,
				onError = function(index, err)
					t_insert(lines, colorCodes.NEGATIVE .. "    Could not compare with " .. tostring(jobs[index].player.name) .. ": " .. tostring(err))
					setLog(lines)
				end,
				onAllDone = function()
					state.parallel = nil
					state.running = false
					state.status = "^7Comparison finished."
				end,
			})
			state.status = string.format("^7Comparing with %d top build%s in background threads...", #jobs, #jobs == 1 and "" or "s")
		end, function(text) state.status = text end)
	end)
	controls.compare.enabled = idle
	controls.compare.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(14, "^7Scores the strongest builds of the selected skill on poe.ninja like generated builds,")
		tooltip:AddLine(14, "^7shows what carries each of them and which of their parts would improve the open build.")
	end

	-- the open build improved instead of a new one: a copy opens, upgraded
	-- (BuildGenerator:Upgrade), with every change and its gain listed
	local startUpgrade
	controls.upgrade = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {122, 162, 120, 20}, "Upgrade open build", function()
		startUpgrade()
	end)
	-- (focusOverride: the focus a review asked for)
	startUpgrade = function(focusOverride)
		local current = main.modes["BUILD"]
		if main.mode ~= "BUILD" or not current or not current.skillsTab then
			state.status = "^7Open the build to upgrade first (it must have a main skill)."
			return
		end
		if main.uniqueDB.loading then
			state.status = "^7The unique database is still loading, try again in a moment."
			return
		end
		local options = makeOptions()
		if focusOverride then
			options.focus = focusOverride
			if focusOverride.raiseHitFloor then options.hitFloor = m_max(options.hitFloor or 0, focusOverride.raiseHitFloor) end
		end
		state.lastFocus = options.focus
		local xml = current:SaveDB("code")
		local buildName = "Upgraded " .. (current.buildName or "build")
		state.running = true
		state.progress = 0
		state.status = "^7Opening a copy of the build..."
		main:SetMode("BUILD", false, buildName, xml)
		local waited = false
		main.onFrameFuncs["BuildGenerator"] = function()
			if not waited then waited = true return end
			local build = main.modes["BUILD"]
			local generator = new("BuildGenerator"):BuildGenerator(build, options)
			state.generator = generator
			options.onProgress = function(stage, index, count, sub)
				local inTry = ((index - 1) + (sub or 0)) / m_max(1, count)
				state.progress = inTry
				state.status = string.format("^7Upgrading, step %d of %d (%d%%): %s...", index, count, m_floor(inTry * 100), stage)
			end
			runInBackground("BuildGenerator", popup, function() return generator:Upgrade() end, function(result)
				state.running = false
				local before, final = result.before or { }, result.final
				local lines = { string.format("^7Upgraded copy of the build: score %.2f -> %.2f, damage %s -> %s, effective hit pool %s -> %s. It is open and not saved yet: use Save As to keep it (your own build file is unchanged).",
					before.score or 0, final.score or 0, formatNumSep(string.format("%.0f", before.dps or 0)), formatNumSep(string.format("%.0f", final.dps or 0)),
					formatNumSep(string.format("%.0f", before.ehp or 0)), formatNumSep(string.format("%.0f", final.ehp or 0))) }
				for _, l in ipairs(result.log) do t_insert(lines, "^7- " .. l) end
				t_insert(lines, "^xC0C0C0" .. result.costLine)
				for _, c in ipairs(result.configChanges or { }) do t_insert(lines, "^x66CCFFConfig: ^7" .. c) end
				for _, p in ipairs(final.penalties or { }) do t_insert(lines, colorCodes.NEGATIVE .. "Cost: ^7" .. p.label) end
				for _, a in ipairs(result.assumptions) do t_insert(lines, "^x66CCFFAssumes: ^7" .. a) end
				setLog(lines)
				state.status = "^7Upgrade finished."
				local opened = main.modes["BUILD"]
				if opened then
					opened.buildFlag = true
					opened.modFlag = true
				end
				state.askReview()
			end, function(err)
				state.running = false
				state.status = "^1Upgrade failed: " .. tostring(err)
			end)
		end
	end
	controls.upgrade.enabled = idle
	-- the review of the open build (Classes/BuildReview); "Improve" upgrades it
	-- with the focus the review asks for
	local function reviewOpen()
		local current = main.modes["BUILD"]
		if main.mode ~= "BUILD" or not current or not current.calcsTab then
			state.status = "^7Open a build to review first."
			return
		end
		openReview(current, state.lastFocus or selectedFocus(), function(focus) startUpgrade(focus) end)
	end
	controls.review = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {248, 162, 110, 20}, "Review & improve", reviewOpen)
	controls.review.enabled = idle
	controls.review.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Mark the open build's key stats too low, fine or too high. \"Improve\" upgrades it with")
		tooltip:AddLine(16, "^7those weights moved; every review is kept and slowly moves the generator's weights.")
	end
	-- (after a generation or an upgrade, when the player wants it)
	state.askReview = function()
		local data = new("BuildReview"):BuildReview().Load()
		if data.askAfter ~= false then reviewOpen() end
	end
	controls.upgrade.tooltipFunc = function(tooltip)
		tooltip:Clear()
		tooltip:AddLine(16, "^7Improves the build that is open instead of making a new one. Its main skill, class, tree,")
		tooltip:AddLine(16, "^7gear and gems are the start; supports, ascendancy, uniques, rares, jewels, anoint, tattoos,")
		tooltip:AddLine(16, "^7flasks and the tree are then improved within the Investment level (or Total div), each change")
		tooltip:AddLine(16, "^7kept only if the build scores better for \"Aim for\" and \"Configure for\". The upgraded copy")
		tooltip:AddLine(16, "^7opens as a new, unsaved build with every change, its gain and cost, and what to buy first.")
		tooltip:AddLine(16, "^7The skill, ascendancy and archetype choices above are not used.")
	end
	controls.status = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {366, 164, 0, 16}, function() return state.status end)
	-- how far the running generation / scan is
	controls.progress = new("ProgressBarControl"):ProgressBarControl({"TOPLEFT",nil,"TOPLEFT"}, {128, 182, 776, 8}, function()
		return state.running and state.progress or nil
	end)
	addPriceControls(controls, 16, 464, idle)
	-- builds of other ideas that came close to the best one (automatic mode)
	controls.alternatives = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {120, 464, 400, 20}, { })
	controls.alternatives.shown = function() return state.alternatives ~= nil and #state.alternatives > 0 end
	controls.alternativesLabel = new("LabelControl"):LabelControl({"RIGHT",controls.alternatives,"LEFT"}, {-4, 0, 0, 16}, "^7Alternatives:")
	controls.alternativesLabel.shown = controls.alternatives.shown
	controls.openAlternative = new("ButtonControl"):ButtonControl({"LEFT",controls.alternatives,"RIGHT"}, {6, 0, 110, 20}, "Open this one", function()
		local entry = controls.alternatives.list[controls.alternatives.selIndex]
		if not entry or not entry.alt then return end
		local skill = controls.skill.list[controls.skill.selIndex]
		local asc = controls.ascend.list[controls.ascend.selIndex]
		main:SetMode("BUILD", false, "Generated " .. skill.label .. " " .. asc.ascendName .. " (" .. entry.alt.archetype.label .. ")", entry.alt.xml)
		state.status = "^7Opened the alternative: " .. entry.alt.archetype.label .. ". Not saved yet: use Save As to keep it."
	end)
	controls.openAlternative.shown = controls.alternatives.shown
	controls.openAlternative.enabled = idle
	controls.close = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {824, 464, 80, 20}, "Close", function()
		main.onFrameFuncs["BuildGenerator"] = nil
		main.onFrameFuncs["BuildGeneratorPanel"] = nil
		main:ClosePopup()
	end)
	popup = main:OpenPopup(920, 496, "Generate Build", controls, nil, nil, "close")

	-- While a generation or scan runs, the window folds into a panel on the
	-- right of the screen: the build stays visible on its passive tree (no
	-- switching between tabs: less to draw while it works), and the panel shows
	-- the progress and the notes as they come. Back to the full window when it ends.
	local panel
	local panelState = { lastView = nil, idleSince = nil, notes = { } }
	local unfoldWindow
	local function foldWindow()
		if panel or popup.folded or main.popups[1] ~= popup then return end
		local width = 440
		local height = m_max(300, main.screenH - 110)
		local pc = { }
		pc.status = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {12, 14, 0, 14}, function()
			local text = state.status or ""
			-- (long status lines are cut to the panel)
			if DrawStringWidth(14, "VAR", text) > width - 24 then
				while #text > 4 and DrawStringWidth(14, "VAR", text .. "...") > width - 24 do text = text:sub(1, -2) end
				text = text .. "..."
			end
			return text
		end)
		pc.progress = new("ProgressBarControl"):ProgressBarControl({"TOPLEFT",nil,"TOPLEFT"}, {12, 34, width - 24, 10}, function()
			return state.progress or 0
		end)
		pc.notesLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {12, 76, 0, 14}, "^7What the generator decided so far:")
		pc.notes = new("TextListControl"):TextListControl({"TOPLEFT",nil,"TOPLEFT"}, {12, 94, width - 24, height - 134}, nil, { })
		pc.stop = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {12, height - 32, 100, 20}, "Stop", function()
			if state.running then controls.generate.onClick() end
		end)
		pc.window = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {width - 132, height - 32, 120, 20}, "Full window", function()
			panelState.suppressed = true
			unfoldWindow()
		end)
		main:ClosePopup()
		popup.folded = true
		panel = main:OpenPopup(width, height, "Generating", pc)
		panel.sidePanel = true
		panel.x = function() return main.screenW - width - 6 end
		panel.y = function() return 44 end
		panel.notesControl = pc.notes
		panelState.lastCount = nil
	end
	unfoldWindow = function()
		if panel then
			for i, p in ipairs(main.popups) do
				if p == panel then table.remove(main.popups, i) break end
			end
			panel = nil
		end
		if popup.folded then
			popup.folded = nil
			t_insert(main.popups, 1, popup)
		end
	end
	main.onFrameFuncs["BuildGeneratorPanel"] = function()
		if not popup.folded and not isPopupOpen(popup) then
			main.onFrameFuncs["BuildGeneratorPanel"] = nil
			return
		end
		if state.running then
			panelState.idleSince = nil
			if not panelState.suppressed then foldWindow() end
		else
			-- (a scan hands over to the generation within a frame or two: wait a moment)
			panelState.idleSince = panelState.idleSince or GetTime()
			if GetTime() - panelState.idleSince > 600 then
				panelState.suppressed = nil
				if panel or popup.folded then unfoldWindow() end
			end
			return
		end
		if not panel then return end
		-- notes as the generator writes them
		local gen = state.generator
		local log = gen and gen.log or { }
		if panelState.lastCount ~= #log or panelState.lastGen ~= gen then
			panelState.lastCount, panelState.lastGen = #log, gen
			local list = { }
			for _, l in ipairs(log) do addLines(list, "^7- " .. l, 14, 58) end
			panel.notesControl.list = list
		end
		-- the build is shown on its passive tree while it is made
		local build = main.modes["BUILD"]
		if gen and build and main.mode == "BUILD" and panelState.lastView ~= gen then
			panelState.lastView = gen
			build.viewMode = "TREE"
		end
	end
end
