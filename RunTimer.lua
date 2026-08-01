-- =========================================================================
-- AttuneNext - RunTimer.lua
-- Times your actual dungeon/raid runs and uses them in place of the built-in
-- estimates. The scale is anchored at 1.00x = a 15:00 run, so a 7:30 clear
-- records as 0.50x and a 45:00 clear as 3.00x.
--
-- Only your BEST time for each instance+difficulty is kept, and it is only
-- replaced when you beat it. Times are per character.
--   db.runTimes["<map>:<difficulty>"] = seconds
-- =========================================================================
local ADDON_NAME, ANx = ...

ANx.BASE_RUN_SECONDS = 900          -- 1.00x = 15:00

local MIN_RUN        = 120          -- ignore anything under two minutes
local MAX_RUN        = 4 * 60 * 60  -- ...and anything over four hours
local RESUME_WINDOW  = 600          -- re-entering within 10 min continues the run

local cur                            -- { key, name, label, start, elapsed, combat }
local lastExit                       -- { key, at, elapsed }

local function Now()
    return (GetTime and GetTime()) or 0
end

-- ---------------------------------------------------------------------
-- Where am I, and on what difficulty?
-- ---------------------------------------------------------------------
local function InstanceByName(zname)
    if not zname or zname == "" then return nil end
    for _, inst in ipairs(ANx.Instances or {}) do
        if inst.name == zname then return inst end
    end
end

-- Difficulty label in the same shape the rest of the addon uses
-- ("", N, H, M for 5-mans; 10/25/10H/25H for raids).
function ANx.CurrentDifficultyLabel(inst)
    local d = (_G.GetInstanceDifficulty and _G.GetInstanceDifficulty()) or 1
    local raid = inst and inst.kind == "R"
    if raid then
        if d == 1 then return "10"
        elseif d == 2 then return "25"
        elseif d == 3 then return "10H"
        elseif d == 4 then return "25H" end
        return "10"
    end
    if d >= 3 then return "M" end
    if d == 2 then return "H" end
    return "N"
end

-- The label an instance actually uses (single-difficulty places use "")
local function ResolveLabel(inst, label)
    local diffs = ANx.Engine and ANx.Engine.InstanceDiffs and ANx.Engine.InstanceDiffs(inst)
    if not diffs or #diffs == 0 then return label end
    for _, d in ipairs(diffs) do
        if d.label == label then return label end
    end
    if #diffs == 1 then return diffs[1].label end
    return label
end

local function Key(map, label)
    return tostring(map) .. ":" .. tostring(label or "")
end

-- ---------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------
local function FormatTime(sec)
    sec = math.floor((sec or 0) + 0.5)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end
ANx.FormatRunTime = FormatTime

-- Your best recorded time for a run, in seconds (nil if never timed).
function ANx.MeasuredRunSeconds(map, label)
    local t = ANx.db and ANx.db.runTimes
    return t and t[Key(map, label)]
end

local function FinishRun(reason)
    if not cur then return end
    local run = cur
    cur = nil
    local total = run.elapsed + (Now() - run.start)
    lastExit = { key = run.key, at = Now(), elapsed = total, name = run.name, label = run.label }
    if not run.combat then return end                 -- never fought: not a run
    if total < MIN_RUN or total > MAX_RUN then return end

    ANx.db.runTimes = ANx.db.runTimes or {}
    local prev = ANx.db.runTimes[run.key]
    if prev and prev <= total then return end          -- only keep your best
    -- remembered so a corpse run can undo this partial leg when you come back
    lastExit.recordedAs = math.floor(total + 0.5)
    lastExit.prevBest = prev
    ANx.db.runTimes[run.key] = math.floor(total + 0.5)
    if ANx.Engine and ANx.Engine.InvalidateStats then
        ANx.Engine.InvalidateStats()                   -- rankings use run times
    end
    local pretty = run.name .. ((run.label ~= "" and run.label) and (" (" .. run.label .. ")") or "")
    if prev then
        ANx.Print(string.format("New best time for |cffffff00%s|r: |cff00ff00%s|r (was %s)",
            pretty, FormatTime(total), FormatTime(prev)))
    else
        ANx.Print(string.format("Run timed: |cffffff00%s|r in |cff00ff00%s|r (%.2gx an average run)",
            pretty, FormatTime(total), total / ANx.BASE_RUN_SECONDS))
    end
    if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
end
ANx.FinishRun = FinishRun

-- Called on zone changes (and on login).
function ANx.RunTimerUpdate()
    local inInstance = _G.IsInInstance and _G.IsInInstance() or false
    local zone = (_G.GetRealZoneText and _G.GetRealZoneText()) or ""
    local inst = inInstance and InstanceByName(zone) or nil

    if not inst then
        FinishRun("left")
        return
    end

    local label = ResolveLabel(inst, ANx.CurrentDifficultyLabel(inst))
    local key = Key(inst.map, label)
    if cur and cur.key == key then return end         -- still in the same run
    FinishRun("switched")

    local elapsed, combat = 0, false
    if lastExit and lastExit.key == key then
        local gap = Now() - lastExit.at
        -- only a genuine, recent step outside counts as the same run; a
        -- negative gap means the clock moved (relog/session change)
        if gap >= 0 and gap <= RESUME_WINDOW then
            elapsed = lastExit.elapsed                 -- corpse run / quick relog
            combat = true
            -- that leg was banked as if the run had ended: take it back, the
            -- real time is whatever the whole run adds up to
            if lastExit.recordedAs and ANx.db.runTimes
               and ANx.db.runTimes[key] == lastExit.recordedAs then
                ANx.db.runTimes[key] = lastExit.prevBest
            end
        end
        lastExit = nil                                 -- consume it either way
    end
    cur = { key = key, name = inst.name, label = label,
            start = Now(), elapsed = elapsed, combat = combat }
end

-- Entering combat is what separates a real run from zoning in to look around.
function ANx.RunTimerCombat()
    if cur then cur.combat = true end
end

-- Forget any in-flight run (used by /an times reset and by the tests).
function ANx.RunTimerReset()
    cur = nil
    lastExit = nil
end

function ANx.RunTimerActive()
    if not cur then return nil end
    return cur.name, cur.label, cur.elapsed + (Now() - cur.start)
end

-- ---------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------
function ANx.PrintRunTimes()
    local t = (ANx.db and ANx.db.runTimes) or {}
    local rows = {}
    for key, sec in pairs(t) do
        local map, label = key:match("^(%d+):(.*)$")
        map = tonumber(map)
        local name = "map " .. tostring(map)
        for _, inst in ipairs(ANx.Instances or {}) do
            if inst.map == map then name = inst.name break end
        end
        rows[#rows + 1] = { name = name .. ((label ~= "") and (" (" .. label .. ")") or ""),
                            sec = sec }
    end
    table.sort(rows, function(a, b) return a.sec < b.sec end)
    if #rows == 0 then
        ANx.Print("No runs timed yet - finish a dungeon or raid and it will be recorded.")
        return
    end
    ANx.Print("Your best run times (1.00x = " .. FormatTime(ANx.BASE_RUN_SECONDS) .. "):")
    for _, r in ipairs(rows) do
        ANx.Print(string.format("  %-38s %s  |cff888888(%.2gx)|r",
            r.name, FormatTime(r.sec), r.sec / ANx.BASE_RUN_SECONDS))
    end
end

function ANx.ResetRunTimes()
    ANx.db.runTimes = {}
    ANx.RunTimerReset()
    if ANx.Engine and ANx.Engine.InvalidateStats then ANx.Engine.InvalidateStats() end
    ANx.Print("Recorded run times cleared - the built-in estimates are back.")
    if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
end
