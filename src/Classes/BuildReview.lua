-- Path of Building
--
-- Class: Build Review
-- The player's review of a generated (or upgraded) build: each key stat
-- marked too low, fine or too high. A review does two things:
--   * Improve: the focus the build was made for, with the weights of the
--     stats marked too low raised and those marked too high lowered, for an
--     upgrade of the build (BuildGenerator:Upgrade) aimed at what was missing.
--   * Learn: every review is kept (BuildIdeasReviews.json in the settings
--     folder) and moves a factor per stat a little; the generator's focus is
--     multiplied by those factors from then on ("Use my reviews"), so a player
--     who keeps finding builds too squishy gets tankier builds by default.
--
local ipairs = ipairs
local pairs = pairs
local t_insert = table.insert
local m_max = math.max
local m_min = math.min
local m_log = math.log
local dkjson = require "dkjson"

local BuildReviewClass = newClass("BuildReview")

function BuildReviewClass:BuildReview()
	return self
end

-- The stats reviewed: key, label, value read from the output (with the
-- scorer), how it is shown, and the weight it moves: a focus weight (dps,
-- ehp, avoid, clear) or a custom goal (BuildScorer.goalList)
BuildReviewClass.stats = {
	{ key = "dps", label = "Damage (DPS)", weight = "dps", read = function(o, s) return s:GetDPS(o) end, format = "%s" },
	{ key = "maxhit", label = "Max hit (weakest type)", weight = "ehp", read = function(o, s) return (s:MinMaxHit(o)) end, format = "%s" },
	{ key = "avoid", label = "Avoidance (hits avoided)", weight = "avoid", read = function(o, s) return s.DamageTakenShare and (1 - s:DamageTakenShare(o)) * 100 or nil end, format = "%d%%" },
	{ key = "clear", label = "Clear speed", weight = "clear", read = function(o, s) return s:ClearTerm(o) end, format = "%.2f (clear score)" },
	{ key = "move", label = "Movement speed", goal = "move", read = function(o) return (o.EffectiveMovementSpeedMod or 0) * 100 end, format = "%d%%" },
	{ key = "speed", label = "Attack / cast speed", goal = "speed", read = function(o) return o.Speed end, format = "%.2f /s" },
	{ key = "life", label = "Life", goal = "life", read = function(o) return o.Life end, format = "%s" },
	{ key = "es", label = "Energy shield", goal = "es", read = function(o) return o.EnergyShield end, format = "%s" },
	{ key = "armour", label = "Armour", goal = "armour", read = function(o) return o.Armour end, format = "%s" },
	{ key = "evasion", label = "Evasion", goal = "evasion", read = function(o) return o.Evasion end, format = "%s" },
	{ key = "block", label = "Block (attack + spell)", goal = "block", read = function(o) return (o.EffectiveBlockChance or 0) + (o.EffectiveSpellBlockChance or 0) end, format = "%d%%" },
	{ key = "recovery", label = "Recovery", goal = "recovery", read = function(o, s) return s.RecoveryRatio and s:RecoveryRatio(o) * 100 or nil end, format = "%.1f%% of pool /s" },
}

-- Verdicts: -1 too low, 0 fine, 1 too high (nil: not reviewed)
BuildReviewClass.verdictLabels = { [-1] = "Too low", [0] = "Fine", [1] = "Too high" }

-- Each stat's value on the open build, formatted: { [key] = { value, text } }
function BuildReviewClass.Values(build, focus)
	local scorer = new("BuildScorer"):BuildScorer(build, { focus = focus })
	local output = build.calcsTab.mainOutput or { }
	local values = { }
	for _, stat in ipairs(BuildReviewClass.stats) do
		local ok, v = pcall(stat.read, output, scorer)
		if ok and v and v == v then
			local text
			if stat.format == "%s" then
				text = (formatNumSep(string.format("%.0f", v)))
			else
				text = string.format(stat.format, v)
			end
			values[stat.key] = { value = v, text = text }
		end
	end
	return values
end

------------------------------------------------------------------------------
-- Improve: the focus moved by a review
------------------------------------------------------------------------------

local focusKeys = { "dps", "ehp", "avoid", "clear" }

-- A copy of a focus with every weight multiplied ({ [weight or goal id] = factor });
-- goals get an extra term (or a bigger one) when their factor is above 1
local function scaledFocus(focus, factors, label)
	local out = copyTable(focus, true)
	out.extra = { }
	for _, e in ipairs(focus.extra or { }) do t_insert(out.extra, copyTable(e, true)) end
	for _, k in ipairs(focusKeys) do
		if factors[k] and out[k] then out[k] = m_max(k == "dps" and 0.001 or 0, out[k] * factors[k]) end
	end
	for _, goal in ipairs(new("BuildScorer"):BuildScorer({ }).goalList) do
		local f = factors[goal.id]
		if f and f ~= 1 then
			local entry
			for _, e in ipairs(out.extra) do if e.stat == goal.stat then entry = e end end
			if entry then
				entry.weight = entry.weight * f
			elseif f > 1 then
				-- (a goal the focus didn't have: weighted by how much more it is wanted)
				t_insert(out.extra, { stat = goal.stat, base = goal.base, weight = 0.4 * (f - 1) + 0.1 })
			end
		end
	end
	out.id = focus.id == "CUSTOM" and "CUSTOM" or (focus.id .. "_REVIEWED")
	out.label = (focus.label or focus.id) .. (label or "")
	return out
end
BuildReviewClass.ScaledFocus = scaledFocus

-- The focus for an improvement after a review: weights of stats marked too
-- low raised (x1.6 and +0.25), too high lowered (x0.6)
function BuildReviewClass.ImproveFocus(focus, verdicts, values)
	local factors, parts = { }, { }
	for _, stat in ipairs(BuildReviewClass.stats) do
		local v = verdicts[stat.key]
		local k = stat.weight or stat.goal
		if v == -1 then
			local base = stat.weight and (focus[k] or 0.3) or 0.3
			factors[k] = m_max(factors[k] or 1, (base * 1.6 + 0.25) / m_max(base, 0.05))
			t_insert(parts, stat.label:lower() .. " up")
		elseif v == 1 then
			factors[k] = m_min(factors[k] or 1, 0.6)
			t_insert(parts, stat.label:lower() .. " down")
		end
	end
	local out = scaledFocus(focus, factors, #parts > 0 and (" (reviewed: " .. table.concat(parts, ", ") .. ")") or "")
	-- (a max hit too low with a floor focus: the floor a quarter above it)
	if verdicts.maxhit == -1 and values and values.maxhit and (focus.hitFloor or focus.hitTarget) then
		out.raiseHitFloor = math.floor(values.maxhit.value * 1.25)
	end
	return out, factors
end

------------------------------------------------------------------------------
-- Learn: reviews kept, factors per stat
------------------------------------------------------------------------------

local function path() return main.userPath and (main.userPath .. "BuildIdeasReviews.json") or nil end

function BuildReviewClass.Load()
	local data = { records = { }, factors = { }, askAfter = true }
	local p = path()
	local file = p and io.open(p, "r")
	if file then
		local ok, loaded = pcall(dkjson.decode, file:read("*a"))
		file:close()
		if ok and type(loaded) == "table" then
			data.records = type(loaded.records) == "table" and loaded.records or { }
			data.factors = type(loaded.factors) == "table" and loaded.factors or { }
			if loaded.askAfter == false then data.askAfter = false end
			if loaded.useLearned == false then data.useLearned = false end
		end
	end
	return data
end

function BuildReviewClass.Save(data)
	local p = path()
	local file = p and io.open(p, "w")
	if file then
		file:write(dkjson.encode(data))
		file:close()
	end
end

-- One review kept and learnt from: each factor moves 15% towards what the
-- verdict asks (too low: up, too high: down), a "fine" pulls it a little back
-- towards 1; factors stay between 1/3 and 3
function BuildReviewClass.Learn(data, record)
	data.records = data.records or { }
	t_insert(data.records, record)
	while #data.records > 500 do table.remove(data.records, 1) end
	data.factors = data.factors or { }
	for _, stat in ipairs(BuildReviewClass.stats) do
		local v = record.verdicts[stat.key]
		local k = stat.weight or stat.goal
		local f = data.factors[k] or 1
		if v == -1 then
			f = f * 1.15
		elseif v == 1 then
			f = f / 1.15
		elseif v == 0 then
			f = math.exp(m_log(f) * 0.9)
		end
		data.factors[k] = m_max(1 / 3, m_min(3, f))
	end
	return data.factors
end

-- The generator's focus with what the reviews taught, and a line saying what
-- changed (nil when nothing did)
function BuildReviewClass.ApplyLearned(focus, data)
	data = data or BuildReviewClass.Load()
	if data.useLearned == false then return focus, nil end
	local factors, parts = { }, { }
	for k, f in pairs(data.factors or { }) do
		if math.abs(f - 1) >= 0.05 then
			factors[k] = f
			t_insert(parts, string.format("%s x%.2f", k, f))
		end
	end
	if #parts == 0 then return focus, nil end
	table.sort(parts)
	return scaledFocus(focus, factors, ""), "Learnt from your reviews: " .. table.concat(parts, ", ")
end

-- A choice between variations of a build (the window's "Variations"): the
-- picked one's stats against each other one's; every stat where the pick is
-- clearly higher moves its factor up 5%, clearly lower down 5%.
-- stats: { dps, maxhit, move, speed } (the weights they move: dps, ehp, move, speed)
local choiceStats = { dps = "dps", maxhit = "ehp", move = "move", speed = "speed" }
function BuildReviewClass.LearnChoice(data, picked, others)
	data.factors = data.factors or { }
	data.choices = (data.choices or 0) + 1
	for _, other in ipairs(others) do
		for stat, k in pairs(choiceStats) do
			local a, b = picked[stat], other[stat]
			if a and b and a > 0 and b > 0 then
				local r = m_log(a / b)
				if math.abs(r) > 0.05 then
					local f = data.factors[k] or 1
					f = r > 0 and f * 1.05 or f / 1.05
					data.factors[k] = m_max(1 / 3, m_min(3, f))
				end
			end
		end
	end
	return data.factors
end
