-- =========================================================================
-- AttuneNext - QuestArrow.lua
-- Clicking a quest sets a waypoint arrow to its quest giver.
-- If the quest can't be picked up yet, the arrow points to the next
-- actionable prerequisite quest in its chain instead.
-- Arrow priority: Carbonite (Nx goto + HUD arrow) -> TomTom -> chat coords.
-- Data: Data_QuestGivers.lua (givers, prereq chains - Questie 3.3.5 DB).
-- =========================================================================
local ADDON_NAME, ANx = ...

-- ---------------------------------------------------------------------
-- Completed-quest + quest-log tracking
-- ---------------------------------------------------------------------
local completed = nil          -- [questId] = true, from server query
local logSet, logDirty = {}, true
local lastQueryAt = 0

local qaFrame = CreateFrame("Frame")
qaFrame:RegisterEvent("PLAYER_LOGIN")
qaFrame:RegisterEvent("QUEST_QUERY_COMPLETE")
qaFrame:RegisterEvent("QUEST_LOG_UPDATE")
qaFrame:RegisterEvent("QUEST_FINISHED")

function ANx.RequestCompletedQuests(force)
    if not QueryQuestsCompleted then return end
    local now = GetTime()
    if force or now - lastQueryAt > 15 then
        lastQueryAt = now
        pcall(QueryQuestsCompleted)
    end
end

local function RebuildLogSet()
    logSet = {}
    if not GetNumQuestLogEntries then return end
    local n = GetNumQuestLogEntries() or 0
    for i = 1, n do
        local _, _, _, _, isHeader, _, _, _, qid = GetQuestLogTitle(i)
        if not isHeader and qid and qid > 0 then logSet[qid] = true end
    end
    logDirty = false
end

qaFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        ANx.After(5, function() ANx.RequestCompletedQuests(true) end)
    elseif event == "QUEST_QUERY_COMPLETE" then
        if GetQuestsCompleted then
            local ok, t = pcall(GetQuestsCompleted, {})
            if ok and type(t) == "table" then
                completed = t
                if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
            end
        end
    elseif event == "QUEST_LOG_UPDATE" then
        logDirty = true
    elseif event == "QUEST_FINISHED" then
        -- possible turn-in: refresh completed list shortly after
        ANx.After(2, function() ANx.RequestCompletedQuests() end)
    end
end)

local function QuestState(qid)
    if completed and completed[qid] then return "done" end
    if logDirty then RebuildLogSet() end
    if logSet[qid] then return "inlog" end
    return nil
end

function ANx.HasCompletedData()
    return completed ~= nil
end

-- ---------------------------------------------------------------------
-- Chain resolution
-- Returns: targetQuestId, status, chainLength, blockerInLogId
--   status: "completed" | "inlog"  (state of the clicked quest itself)
--           "ready"                (clicked quest obtainable now)
--           "chain"                (target = next prerequisite to do)
--           "chain_inlog"          (a prerequisite is already in the log)
--           "unknown"              (no completed-quest data yet)
-- ---------------------------------------------------------------------
function ANx.ResolveActionableQuest(qid)
    if not completed then return qid, "unknown", 0, nil end
    local pre = ANx.QuestPre or {}
    local visited, hops = {}, 0
    local cur = qid
    while true do
        if visited[cur] or hops > 30 then
            return cur, (cur == qid) and "ready" or "chain", hops, nil
        end
        visited[cur] = true

        local st = QuestState(cur)
        if st == "done" then return cur, "completed", hops, nil end
        if st == "inlog" then
            return cur, (cur == qid) and "inlog" or "chain_inlog", hops, cur
        end

        local row = pre[cur]
        local nextQuest = nil
        if row then
            local parent, mode = row[2], row[3]
            -- parent quest must be active or completed for the child to exist
            if parent > 0 and QuestState(parent) == nil then
                nextQuest = parent
            end
            if not nextQuest and mode == 1 then
                -- any ONE of the listed prereqs
                local satisfied = false
                for i = 4, #row do
                    if QuestState(row[i]) == "done" then satisfied = true break end
                end
                if not satisfied then
                    -- prefer a prereq that's already in the log, else one with a known giver
                    for i = 4, #row do
                        if QuestState(row[i]) == "inlog" then nextQuest = row[i] break end
                    end
                    if not nextQuest then
                        for i = 4, #row do
                            if ANx.QuestGivers[row[i]] then nextQuest = row[i] break end
                        end
                    end
                    nextQuest = nextQuest or row[4]
                end
            elseif not nextQuest and mode == 2 then
                -- ALL listed prereqs required
                for i = 4, #row do
                    if QuestState(row[i]) ~= "done" then nextQuest = row[i] break end
                end
            end
        end

        if not nextQuest then
            return cur, (cur == qid) and "ready" or "chain", hops, nil
        end
        cur = nextQuest
        hops = hops + 1
    end
end

-- Lightweight state for UI row decoration
-- Returns "ready" | "locked" | "inlog" | "completed" | nil (unknown)
function ANx.GetQuestLockInfo(qid)
    if not completed then return nil end
    local target, status = ANx.ResolveActionableQuest(qid)
    if status == "ready" then return "ready" end
    if status == "inlog" then return "inlog" end
    if status == "completed" then return "completed" end
    return "locked"
end

-- ---------------------------------------------------------------------
-- Zone name -> continent index + zone index (world map API)
-- ---------------------------------------------------------------------
local czCache
local function FindCZByZoneName(zoneName)
    if not zoneName then return nil end
    if not czCache then
        czCache = {}
        local continents = { GetMapContinents() }
        for c = 1, #continents do
            local zones = { GetMapZones(c) }
            for z, zn in ipairs(zones) do
                czCache[zn:lower()] = { c, z }
            end
        end
    end
    local hit = czCache[zoneName:lower()]
    if hit then return hit[1], hit[2] end
    return nil
end

-- ---------------------------------------------------------------------
-- Waypoint dispatch
-- ---------------------------------------------------------------------
local function SendWaypoint(c, z, x, y, label)
    -- Carbonite: its TomTom-emulation entry point works even when the
    -- "Emulate TomTom" option is disabled, and engages the goto HUD arrow.
    if _G.Nx and _G.Nx.TTSTCZXY then
        local ok = pcall(_G.Nx.TTSTCZXY, _G.Nx, c, z, x, y, label)
        if ok then return "Carbonite" end
    end
    -- Real TomTom (or Carbonite with TomTom emulation enabled)
    if _G.TomTom and _G.TomTom.AddZWaypoint then
        local ok = pcall(_G.TomTom.AddZWaypoint, _G.TomTom, c, z, x, y, label)
        if ok then return "TomTom" end
    end
    return nil
end

local function QuestName(qid, fallback)
    return (ANx.QuestNames and ANx.QuestNames[qid]) or fallback or ("quest " .. tostring(qid))
end

local function ZoneNameById(zoneId)
    return (ANx.QuestZoneNames and ANx.QuestZoneNames[zoneId])
        or (ANx.VendorZoneNames and ANx.VendorZoneNames[zoneId])
        or ("Zone " .. zoneId)
end

-- Generic: set the arrow to a zone-percent location. Returns true on arrow.
local function ArrowToPoint(zoneId, x, y, label, subject)
    local zoneName = ZoneNameById(zoneId)
    local locText = string.format("%s (%.1f, %.1f) in %s", subject, x, y, zoneName)
    local c, z = FindCZByZoneName(zoneName)
    if c then
        local via = SendWaypoint(c, z, x, y, label)
        if via then
            ANx.Print("|cff00ff00Waypoint set|r via " .. via .. ": " .. locText)
            return true
        end
        ANx.Print("|cffff8040No arrow addon found|r (install Carbonite or TomTom). " .. locText)
        return false
    end
    ANx.Print("Location: " .. locText .. " |cff888888(zone not on world map, no arrow)|r")
    return false
end

-- Sets the arrow to the giver of a specific quest id. Returns true on arrow.
local function ArrowToGiver(qid, label)
    local e = ANx.QuestGivers and ANx.QuestGivers[qid]
    if not e then
        ANx.Print("No quest giver location known for \"" .. QuestName(qid)
            .. "\" (it may start from a dropped item).")
        return false
    end
    return ArrowToPoint(e[1], e[2] / 10, e[3] / 10, label, e[4])
end

-- Public: arrow to a vendor's spawn location (npcId from the loot DB).
function ANx.SetVendorWaypoint(npcId, vendorName)
    vendorName = vendorName or "Vendor"
    local e = npcId and ANx.VendorLocs and ANx.VendorLocs[npcId]
    if not e then
        ANx.Print("No location known for vendor \"" .. vendorName .. "\".")
        return false
    end
    return ArrowToPoint(e[1], e[2] / 10, e[3] / 10, vendorName, vendorName)
end

function ANx.HasVendorLoc(npcId)
    return npcId ~= nil and ANx.VendorLocs ~= nil and ANx.VendorLocs[npcId] ~= nil
end

-- ---------------------------------------------------------------------
-- Public entry: click handler
-- ---------------------------------------------------------------------
function ANx.SetQuestWaypoint(questId, questTitle)
    if not (ANx.QuestGivers and questId) then return false end
    local title = QuestName(questId, questTitle)

    local target, status, hops, blocker = ANx.ResolveActionableQuest(questId)

    if status == "unknown" then
        ANx.RequestCompletedQuests(true)
        ANx.Print("|cff888888(Prerequisite check pending - server queried, click again in a moment.)|r")
        return ArrowToGiver(questId, title)
    end

    if status == "completed" then
        ANx.Print("\"" .. title .. "\" is |cff00ff00already completed|r on this character.")
        return false
    end

    if status == "inlog" then
        ANx.Print("\"" .. title .. "\" is |cffffff00already in your quest log|r - go finish it!")
        return false
    end

    if status == "chain_inlog" then
        ANx.Print("To unlock \"" .. title .. "\": finish |cffffff00" .. QuestName(blocker)
            .. "|r, which is |cffffff00already in your quest log|r.")
        return false
    end

    if status == "chain" then
        local targetName = QuestName(target)
        ANx.Print(string.format(
            "You can't pick up \"%s\" yet. |cffffd100Next step:|r \"%s\"%s",
            title, targetName,
            hops > 1 and string.format(" |cff888888(%d quests in the chain before it unlocks)|r", hops) or ""))
        -- level requirement note for the actionable quest
        local row = ANx.QuestPre and ANx.QuestPre[target]
        if row and row[1] > 0 and UnitLevel and UnitLevel("player") < row[1] then
            ANx.Print("|cffff8040Note:|r \"" .. targetName .. "\" requires level " .. row[1] .. ".")
        end
        return ArrowToGiver(target, targetName .. " (unlocks: " .. title .. ")")
    end

    -- ready
    local e = ANx.QuestGivers[questId]
    local giver = e and e[4]
    return ArrowToGiver(questId, title .. (giver and (" (" .. giver .. ")") or ""))
end
