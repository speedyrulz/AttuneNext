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
        -- chains fork per faction: an "either of" list can hold the Alliance
        -- AND the Horde copy of the same step, and a parent can be the other
        -- faction's version. Never walk into a quest this character cannot
        -- take - that is how a Horde player got arrowed to the Alliance
        -- "The Hand of Gul'dan".
        local can = ANx.CharCanDoQuest
        if row then
            local parent, mode = row[2], row[3]
            -- parent quest must be active or completed for the child to exist
            if parent > 0 and QuestState(parent) == nil and can(parent) then
                nextQuest = parent
            end
            if not nextQuest and mode == 1 then
                -- any ONE of the listed prereqs
                local satisfied = false
                for i = 4, #row do
                    if QuestState(row[i]) == "done" then satisfied = true break end
                end
                if not satisfied then
                    -- prefer a DOABLE prereq already in the log, else a doable
                    -- one with a known giver, else the first doable one
                    for i = 4, #row do
                        if QuestState(row[i]) == "inlog" and can(row[i]) then
                            nextQuest = row[i] break
                        end
                    end
                    if not nextQuest then
                        for i = 4, #row do
                            if ANx.QuestGivers[row[i]] and can(row[i]) then
                                nextQuest = row[i] break
                            end
                        end
                    end
                    if not nextQuest then
                        for i = 4, #row do
                            if can(row[i]) then nextQuest = row[i] break end
                        end
                    end
                    -- every alternative is the other faction's: stop rather
                    -- than route somewhere unusable
                end
            elseif not nextQuest and mode == 2 then
                -- ALL listed prereqs required
                for i = 4, #row do
                    if QuestState(row[i]) ~= "done" and can(row[i]) then
                        nextQuest = row[i] break
                    end
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

-- Public wrapper used by the Distance sort.
function ANx.ZoneToContinentZone(zoneName)
    return FindCZByZoneName(zoneName)
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

-- Public: arrow to the middle of a named zone (drop sources tell us the
-- zone, not the mob's patrol path). Returns true on arrow.
function ANx.SetZoneCenterWaypoint(zoneName, label)
    if not zoneName or zoneName == "" then return false end
    local c, z = FindCZByZoneName(zoneName)
    if not c then return false end
    local via = SendWaypoint(c, z, 50, 50, label or zoneName)
    if via then
        ANx.Print("|cff00ff00Waypoint set|r via " .. via .. ": "
            .. (label or "") .. " - " .. zoneName)
        return true
    end
    ANx.Print("|cffff8040No arrow addon found|r (install Carbonite or TomTom).")
    return false
end

-- Public: right-click router - arrow to an item's best source.
--  drops first (highest chance, ties -> closest), then quest start, then the
--  closest vendor; craft-only items open their profession's window instead.
function ANx.ArrowToItem(itemId)
    local Engine = ANx.Engine
    local srcs = (Engine and Engine.Sources and Engine.Sources(itemId))
        or (ANx.GetSources and ANx.GetSources(itemId)) or {}
    local name = (ANx.GetItemDisplay and ANx.GetItemDisplay(itemId)) or ("Item " .. itemId)
    if #srcs == 0 then
        ANx.Print("No source data for " .. name .. ".")
        return false
    end
    local S = ANx.SRC
    -- 1) drop sources
    local drops = {}
    for _, sc in ipairs(srcs) do
        if sc.srcType ~= S.QUEST and sc.srcType ~= S.VENDOR
            and sc.srcType ~= S.CRAFT_TRAINER and sc.srcType ~= S.CRAFT_RECIPE then
            drops[#drops + 1] = sc
        end
    end
    if #drops > 0 then
        table.sort(drops, function(x, y)
            if (x.chance or 0) ~= (y.chance or 0) then return (x.chance or 0) > (y.chance or 0) end
            return ANx.DistanceRank({ zoneName = x.zoneName })
                 < ANx.DistanceRank({ zoneName = y.zoneName })
        end)
        local d = drops[1]
        if ANx.HasRareLoc and ANx.HasRareLoc(d.objId) then
            return ANx.SetRareWaypoint(d.objId, d.objName)
        end
        if ANx.SetZoneCenterWaypoint(d.zoneName, name .. " - " .. (d.objName or "?")) then
            return true
        end
        ANx.Print(string.format("%s drops from |cffffff00%s|r in |cffffff00%s|r %s(no overworld route).",
            name, d.objName or "?", d.zoneName or "?",
            string.format("|cff00ff88%.1f%%|r ", d.chance or 0)))
        return false
    end
    -- 2) quest start: dual-faction quests share rewards, so pick the version
    -- THIS character can take - never arrow a Horde player to the Alliance
    -- quest giver (or vice versa)
    local blockedQuest
    for _, sc in ipairs(srcs) do
        if sc.srcType == S.QUEST and sc.objId then
            if ANx.CharCanDoQuest(sc.objId) then
                return ANx.SetQuestWaypoint(sc.objId, sc.objName)
            end
            blockedQuest = blockedQuest or sc
        end
    end
    -- 3) closest vendor
    local vends = {}
    for _, sc in ipairs(srcs) do
        if sc.srcType == S.VENDOR then vends[#vends + 1] = sc end
    end
    if #vends > 0 then
        table.sort(vends, function(x, y)
            return ANx.DistanceRank({ zoneName = x.zoneName })
                 < ANx.DistanceRank({ zoneName = y.zoneName })
        end)
        return ANx.SetVendorWaypoint(vends[1].objId, vends[1].objName)
    end
    -- 4) craft-only: open the profession window
    local prof = ANx.ProfessionOfItem and ANx.ProfessionOfItem(itemId)
    if prof then
        if _G.CastSpellByName then
            local ok = pcall(_G.CastSpellByName, prof)
            if ok then
                ANx.Print(name .. " is crafted by |cffffff00" .. prof .. "|r - opening its window.")
                return true
            end
        end
        ANx.Print(name .. " is crafted by |cffffff00" .. prof
            .. "|r (this character may not know it).")
        return false
    end
    if blockedQuest then
        local side = ANx.QuestFactionSide and ANx.QuestFactionSide(blockedQuest.objId)
        ANx.Print(name .. " only comes from "
            .. (side == "A" and "an |cff4a9eeaAlliance|r" or side == "H" and "a |cffff4040Horde|r"
                or "another faction's/race's")
            .. " quest this character cannot take.")
        return false
    end
    ANx.Print("No routable source for " .. name .. ".")
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
-- Rare-spawn arrows: rares patrol several camps, so repeated clicks cycle
-- through the known spawn points.
-- ---------------------------------------------------------------------
local rareCycle = {}   -- [npcId] = index of the spawn point shown last

function ANx.HasRareLoc(npcId)
    return npcId ~= nil and ANx.RareLocs ~= nil and ANx.RareLocs[npcId] ~= nil
end

function ANx.SetRareWaypoint(npcId, rareName)
    rareName = rareName or "Rare spawn"
    local pts = npcId and ANx.RareLocs and ANx.RareLocs[npcId]
    if not pts or #pts < 3 then
        ANx.Print("No spawn location known for \"" .. rareName .. "\".")
        return false
    end
    local n = math.floor(#pts / 3)
    local idx = ((rareCycle[npcId] or 0) % n) + 1
    rareCycle[npcId] = idx
    local base = (idx - 1) * 3
    local label = rareName .. (n > 1 and string.format(" (spawn %d of %d)", idx, n) or "")
    if n > 1 then
        ANx.Print("|cffff8000Rare spawn point " .. idx .. " of " .. n
            .. "|r - click again for the next one.")
    end
    return ArrowToPoint(pts[base + 1], pts[base + 2] / 10, pts[base + 3] / 10, label, label)
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
