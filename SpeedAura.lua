-- =========================================================================
-- AttuneNext - SpeedAura.lua
-- Personal clear times come from Synastria's Dungeon Challenge system, read
-- straight off your buffs when you are inside an instance:
--   * "Dungeon Challenge" - the time to beat to improve your speed buff
--   * "Speed Buff"        - the movement speed you have already earned there
--
-- The Speed Buff is the useful one: the movement speed you have earned in an
-- instance is a direct function of how fast you have cleared it. Synastria's
-- challenge thresholds are linear in the earned percentage - measured from the
-- server's own numbers for Scholomance (30% = 7:39, 40% = 5:44, 50% = 3:49):
--
--     time(pct) = base * (1 - pct / 70)
--
-- ...so 70% is the asymptote, and an earned buff of P% means the account has
-- cleared that instance in base * (1 - P/70). Scaling the built-in estimate by
-- that factor gives a close personal clear time WITHOUT timing anything - and
-- it still works when the challenge itself fails (over-level), because the
-- speed buff is still there.
--   db.speedPct["<map>:<difficulty>"]      = earned speed buff, percent
--   db.challengeTimes["<map>:<difficulty>"] = challenge target, seconds
-- Both are account-wide (AttuneNextDB is a per-account saved variable).
-- =========================================================================
local ADDON_NAME, ANx = ...

ANx.BASE_RUN_SECONDS = 900          -- 1.00x = a 15:00 run

local CHALLENGE_AURA = "Dungeon Challenge"
local SPEED_AURA     = "Speed Buff"
local MIN_TIME, MAX_TIME = 60, 4 * 60 * 60

-- the speed percentage at which a clear would take no time at all
ANx.SPEED_CAP = 70
local MIN_FACTOR = 0.08          -- never claim a run is faster than this

local scanTip

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
function ANx.FormatRunTime(sec)
    sec = math.floor((sec or 0) + 0.5)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Difficulty label in the same shape the rest of the addon uses
-- ("", N, H, M for 5-mans; 10/25/10H/25H for raids).
function ANx.CurrentDifficultyLabel(inst)
    local d = (_G.GetInstanceDifficulty and _G.GetInstanceDifficulty()) or 1
    if inst and inst.kind == "R" then
        if d == 2 then return "25"
        elseif d == 3 then return "10H"
        elseif d == 4 then return "25H" end
        return "10"
    end
    if d >= 3 then return "M" end
    if d == 2 then return "H" end
    return "N"
end

local function Key(map, label)
    return tostring(map) .. ":" .. tostring(label or "")
end

local function Tip()
    if scanTip then return scanTip end
    scanTip = CreateFrame("GameTooltip", "AttuneNextAuraTip", UIParent, "GameTooltipTemplate")
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    return scanTip
end

-- All the text of one buff, joined (both columns, all lines).
local function BuffText(index)
    local tip = Tip()
    if not (tip and tip.SetUnitBuff) then return "" end
    tip:ClearLines()
    local ok = pcall(tip.SetUnitBuff, tip, "player", index)
    if not ok then return "" end
    local out = {}
    local n = (tip.NumLines and tip:NumLines()) or 0
    for i = 1, n do
        local l = _G["AttuneNextAuraTipTextLeft" .. i]
        local r = _G["AttuneNextAuraTipTextRight" .. i]
        if l and l.GetText and l:GetText() then out[#out + 1] = l:GetText() end
        if r and r.GetText and r:GetText() then out[#out + 1] = r:GetText() end
    end
    return table.concat(out, " ")
end

-- First "m:ss" (or "mm:ss") in a string, as seconds.
function ANx.ParseClock(text)
    if not text then return nil end
    local m, s = text:match("(%d+):(%d%d)")
    if not m then return nil end
    local secs = tonumber(m) * 60 + tonumber(s)
    if secs >= MIN_TIME and secs <= MAX_TIME then return secs end
    return nil
end

local function ParsePercent(text)
    if not text then return nil end
    local p = text:match("(%d+)%%")
    return p and tonumber(p) or nil
end

-- ---------------------------------------------------------------------
-- Reading the auras
-- ---------------------------------------------------------------------
-- Returns challengeSeconds, speedPercent (either may be nil).
function ANx.ReadSpeedAuras()
    if not _G.UnitBuff then return nil, nil end
    local challenge, speed
    for i = 1, 40 do
        local name, _, _, _, _, duration = _G.UnitBuff("player", i)
        if not name then break end
        if name == CHALLENGE_AURA then
            -- the aura's own length is the time limit; fall back to its text
            if type(duration) == "number" and duration >= MIN_TIME and duration <= MAX_TIME then
                challenge = duration
            else
                challenge = ANx.ParseClock(BuffText(i))
            end
        elseif name == SPEED_AURA then
            speed = ParsePercent(name .. " " .. BuffText(i))
        end
    end
    return challenge, speed
end

-- The account's target time for a run, in seconds (nil if never seen).
function ANx.ChallengeSeconds(map, label)
    local t = ANx.db and ANx.db.challengeTimes
    if not t then return nil end
    return t[Key(map, label)] or t[Key(map, "")]
end

-- The speed buff this account has earned in a run, in percent (nil if unseen).
function ANx.SpeedPct(map, label)
    local t = ANx.db and ANx.db.speedPct
    if not t then return nil end
    return t[Key(map, label)] or t[Key(map, "")]
end

-- Personal clear time for a run, in seconds:
--   * from the earned speed buff, which implies how fast the account cleared it
--   * failing that, the Dungeon Challenge target if we happen to have seen one
function ANx.EstimatedRunSeconds(map, label)
    local pct = ANx.SpeedPct(map, label)
    if pct and pct > 0 then
        local base = 1
        if ANx.Engine and ANx.Engine.BuiltinRunTime then
            base = ANx.Engine.BuiltinRunTime(map, label) or 1
        end
        local factor = base * (1 - pct / ANx.SPEED_CAP)
        if factor < base * MIN_FACTOR then factor = base * MIN_FACTOR end
        return factor * ANx.BASE_RUN_SECONDS
    end
    return ANx.ChallengeSeconds(map, label)
end

function ANx.MeasuredRunSeconds(map, label)
    return ANx.EstimatedRunSeconds(map, label)
end

-- Called on entering an instance and whenever the player's auras change.
function ANx.ScanSpeedAuras()
    if not (_G.IsInInstance and _G.IsInInstance()) then return end
    local zone = (_G.GetRealZoneText and _G.GetRealZoneText()) or ""
    local inst
    for _, i in ipairs(ANx.Instances or {}) do
        if i.name == zone then inst = i break end
    end
    if not inst then return end

    local label = ANx.CurrentDifficultyLabel(inst)
    local diffs = ANx.Engine and ANx.Engine.InstanceDiffs and ANx.Engine.InstanceDiffs(inst)
    if diffs and #diffs == 1 then label = diffs[1].label end

    local challenge, speed = ANx.ReadSpeedAuras()
    ANx.currentSpeedBuff = speed
    local key = Key(inst.map, label)
    local changed = false

    -- the earned speed buff: the account's best-ever here, so keep the highest
    if speed and speed > 0 then
        ANx.db.speedPct = ANx.db.speedPct or {}
        local prev = ANx.db.speedPct[key]
        if not prev or speed > prev then
            ANx.db.speedPct[key] = speed
            changed = true
            ANx.DebugMsg(string.format("speed buff in %s (%s): %d%% -> ~%s clear",
                inst.name, label ~= "" and label or "-", speed,
                ANx.FormatRunTime(ANx.EstimatedRunSeconds(inst.map, label) or 0)))
        end
    end

    if challenge then
        ANx.db.challengeTimes = ANx.db.challengeTimes or {}
        local prev = ANx.db.challengeTimes[key]
        if not prev or math.abs(prev - challenge) >= 1 then
            ANx.db.challengeTimes[key] = math.floor(challenge + 0.5)
            changed = true
            ANx.DebugMsg(string.format("challenge time for %s (%s): %s",
                inst.name, label ~= "" and label or "-", ANx.FormatRunTime(challenge)))
        end
    end

    if changed then
        if ANx.Engine and ANx.Engine.InvalidateStats then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end
end

-- ---------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------
function ANx.PrintChallengeTimes()
    local seen = {}
    for key in pairs((ANx.db and ANx.db.speedPct) or {}) do seen[key] = true end
    for key in pairs((ANx.db and ANx.db.challengeTimes) or {}) do seen[key] = true end
    local rows = {}
    for key in pairs(seen) do
        local sec = ANx.EstimatedRunSeconds(tonumber(key:match("^(%d+):")), key:match(":(.*)$"))
        local map, label = key:match("^(%d+):(.*)$")
        map = tonumber(map)
        local name = "map " .. tostring(map)
        for _, inst in ipairs(ANx.Instances or {}) do
            if inst.map == map then name = inst.name break end
        end
        rows[#rows + 1] = { name = name .. ((label ~= "") and (" (" .. label .. ")") or ""),
                            sec = sec or 0, pct = ANx.SpeedPct(map, label) }
    end
    table.sort(rows, function(a, b) return a.sec < b.sec end)
    if #rows == 0 then
        ANx.Print("Nothing seen yet - your speed buff is read when you enter an instance.")
        return
    end
    ANx.Print("Estimated clear times (1.00x = " .. ANx.FormatRunTime(ANx.BASE_RUN_SECONDS) .. "):")
    for _, r in ipairs(rows) do
        ANx.Print(string.format("  %-34s %s  |cff888888(%.2gx)%s|r",
            r.name, ANx.FormatRunTime(r.sec), r.sec / ANx.BASE_RUN_SECONDS,
            r.pct and ("  " .. r.pct .. "% speed") or ""))
    end
end

function ANx.ResetChallengeTimes()
    ANx.db.challengeTimes = {}
    ANx.db.speedPct = {}
    if ANx.Engine and ANx.Engine.InvalidateStats then ANx.Engine.InvalidateStats() end
    ANx.Print("Dungeon Challenge times cleared - they will be read again on your next run.")
    if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
end
