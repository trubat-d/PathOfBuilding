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

local function isPopupOpen(popup)
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
		tooltip:AddLine(16, "^7Download unique, tattoo, runegraft and oil prices from poe.ninja (current league).")
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
			yieldEvery = 30,
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
	controls.focus = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {120, 48, 260, 20}, focusDropList())
	controls.focus.enabled = idle
	controls.investmentLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {400, 50, 0, 16}, "^7Investment:")
	controls.investment = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {490, 48, 276, 20}, investmentDropList())
	controls.investment.selIndex = GetPriceSource().defaultLevel
	controls.investment.enabled = idle
	controls.investment.tooltipFunc = investmentTooltip
	controls.ehpFloorLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {776, 50, 0, 16}, "^7Min max hit:")
	controls.ehpFloor = new("EditControl"):EditControl({"TOPLEFT",nil,"TOPLEFT"}, {856, 48, 50, 20}, "10000", nil, "%D", 8)
	local function floorShown() return controls.focus.list[controls.focus.selIndex].focus.hitFloor ~= nil end
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
				label = string.format("%s   ^x88CC88built: DPS %s, max hit %s, score %.2f", a.label, formatNumSep(string.format("%.0f", scan.dps or 0)), formatNumSep(string.format("%.0f", scan.minHit or 0)), scan.score)
			end
			t_insert(list, { label = label, archetype = a, scan = scan })
		end
		if results then
			-- built archetypes first (by score), then the estimated ones
			table.sort(list, function(x, y)
				local bx, by = x.scan and x.scan.built and 1 or 0, y.scan and y.scan.built and 1 or 0
				if bx ~= by then return bx > by end
				local sx, sy = x.scan and x.scan.score or -math.huge, y.scan and y.scan.score or -math.huge
				return sx > sy
			end)
		else
			t_insert(list, 1, { label = "Automatic: scan every archetype, then fully build the best one", auto = true })
		end
		return list
	end
	controls.archetypeLabel = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 136, 0, 16}, "^7Archetype:")
	controls.archetype = new("DropDownControl"):DropDownControl({"TOPLEFT",nil,"TOPLEFT"}, {120, 134, 620, 20}, archetypeList())
	controls.archetype.enabled = idle
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
		"^7  4. item bases   5. rare items: influenced from Mid investment, Exarch / Eater implicits on armour",
		"^7  6. supports again; curse, aura, guard and movement setups linked like real builds",
		"^7  7. tree again for the gear, ascendancy and bloodline (shared points)",
		"^7  8. uniques players of the skill use (poe.ninja), rare / timeless / Forbidden / Watcher's Eye / cluster jewels,",
		"^7      anoint and tattoos   9. utility flasks, pantheon and bandit   10. optionally, the best unique / keystone idea",
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
			focus = controls.focus.list[controls.focus.selIndex].focus,
			investment = controls.investment.list[controls.investment.selIndex].level,
			hitFloor = controls.focus.list[controls.focus.selIndex].focus.hitFloor and tonumber(controls.ehpFloor.buf) or nil,
			scenario = controls.scenario.list[controls.scenario.selIndex].scenario,
			configScenario = controls.config.list[controls.config.selIndex].scenario,
			allowAnoints = controls.anoints.state,
			allowTattoos = controls.tattoos.state,
			timeless = controls.timeless.state,
			synergies = controls.synergies.state,
			yieldEvery = 30,
		}
		options.archetype = archetypeEntry and archetypeEntry.archetype
		return options
	end

	controls.generate = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {16, 162, 100, 20}, function()
		return state.running and "Stop" or "Generate"
	end, function()
		if state.running then
			main.onFrameFuncs["BuildGenerator"] = nil
			main.onFrameFuncs["BuildMetaWait"] = nil
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
		local entry = controls.archetype.list[controls.archetype.selIndex]
		if entry and entry.auto then
			-- scan first; the scan sorts the list best first, then this runs again
			state.afterScan = function()
				state.confirmDiscard = true
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
		local function startGeneration()
		state.status = "^7Creating a new build..."
		-- Open a new empty build, then generate into it once it exists
		main:SetMode("BUILD", false, "Generated " .. skill.label .. " " .. asc.ascendName)
		local waited = false
		main.onFrameFuncs["BuildGenerator"] = function()
			if not waited then waited = true return end
			local build = main.modes["BUILD"]
			local generator = new("BuildGenerator"):BuildGenerator(build, options)
			options.onProgress = function(stage, index, count)
				state.status = string.format("^7Step %d of %d: %s...", index, count, stage)
			end
			runInBackground("BuildGenerator", popup, function() return generator:Run() end, function(result)
				state.running = false
				local lines = { string.format("^7Done. Damage %s, effective hit pool %s. The build is open and not saved yet: use Save As to keep it.",
					formatNumSep(string.format("%.0f", result.final.dps)), formatNumSep(string.format("%.0f", result.final.ehp))) }
				for _, l in ipairs(result.log) do t_insert(lines, "^7- " .. l) end
				t_insert(lines, "^xC0C0C0" .. result.costLine)
				for _, c in ipairs(result.configChanges or { }) do t_insert(lines, "^x66CCFFConfig: ^7" .. c) end
				for _, p in ipairs(result.final.penalties or { }) do t_insert(lines, colorCodes.NEGATIVE .. "Cost: ^7" .. p.label) end
				for _, a in ipairs(result.assumptions) do t_insert(lines, "^x66CCFFAssumes: ^7" .. a) end
				for _, a in ipairs(generator.overlap and generator.overlap:GetAssumptions() or { }) do t_insert(lines, "^x66CCFFAssumes: ^7" .. a) end
				setLog(lines)
				state.status = "^7Finished."
				build.buildFlag = true
				build.modFlag = true
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
			startGeneration()
		end
		main.onFrameFuncs["BuildMetaWait"] = function()
			if GetTime() - t0 > 60000 then go(nil) end
		end
		loadMeta(skill.label, function(entry) go(entry) end, function(text) state.status = text end)
	end)
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
				local planning = archetype == standard
				options.onProgress = function(stage)
					state.status = string.format("^7Building %d of %d (%s): %s...", built, total, archetype.label, stage)
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
								if promising < (state.scanBuilds or 3) then
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

	controls.status = new("LabelControl"):LabelControl({"TOPLEFT",nil,"TOPLEFT"}, {128, 164, 0, 16}, function() return state.status end)
	addPriceControls(controls, 16, 464, idle)
	controls.close = new("ButtonControl"):ButtonControl({"TOPLEFT",nil,"TOPLEFT"}, {824, 464, 80, 20}, "Close", function()
		main.onFrameFuncs["BuildGenerator"] = nil
		main:ClosePopup()
	end)
	popup = main:OpenPopup(920, 496, "Generate Build", controls, nil, nil, "close")
end
