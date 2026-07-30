-- =========================================================================
-- AttuneNext - Alerts.lua
-- Moment-of-truth alerts so you never pass on an attune by accident:
--   * an attunable item you still NEED appears in a loot window
--   * a group loot roll starts for one
--   * an item you're WEARING finishes attuning (time to swap it out)
-- but hasn't (equip them to start) - shown on the main menu.
-- Toggle: Interface Options -> AddOns -> AttuneNext.
-- =========================================================================
local ADDON_NAME, ANx = ...

local function ItemIdFromLink(link)
    return link and tonumber(tostring(link):match("item:(%d+)")) or nil
end

-- does THIS character still need it?
local function CharNeeds(itemId)
    return ANx.IsAttunableAtAll(itemId)
        and ANx.CanCharAttune(itemId)
        and not ANx.IsAttuned(itemId)
end

local function Announce(msg)
    ANx.Print(msg)
    if _G.UIErrorsFrame and _G.UIErrorsFrame.AddMessage then
        local plain = tostring(msg):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        _G.UIErrorsFrame:AddMessage(plain, 0.2, 1.0, 0.6, 1.0)
    end
end

-- ---------------------------------------------------------------------
-- Loot window + group rolls
-- ---------------------------------------------------------------------
local lastAlert = {}   -- [itemId] = time of last loot alert (throttle re-opens)

function ANx.CheckLootWindow()
    if not (ANx.db and ANx.db.alerts) then return end
    if not _G.GetNumLootItems then return end
    local now = (_G.GetTime and _G.GetTime()) or 0
    for i = 1, _G.GetNumLootItems() or 0 do
        local link = _G.GetLootSlotLink and _G.GetLootSlotLink(i)
        local id = ItemIdFromLink(link)
        if id and CharNeeds(id) and (now - (lastAlert[id] or -999)) > 30 then
            lastAlert[id] = now
            Announce("|cffff8000Attunable drop:|r " .. tostring(link)
                .. " |cff33ff99- you still need it!|r")
        end
    end
end

function ANx.CheckLootRoll(rollID)
    if not (ANx.db and ANx.db.alerts) then return end
    if not (rollID and _G.GetLootRollItemLink) then return end
    local link = _G.GetLootRollItemLink(rollID)
    local id = ItemIdFromLink(link)
    if id and CharNeeds(id) then
        Announce("|cffff8000Roll started:|r " .. tostring(link)
            .. " |cff33ff99- you still need it!|r")
    end
end

-- ---------------------------------------------------------------------
-- "Swap it out": an equipped item just finished attuning
-- (called from the OnCustomGameData chain, typeId 11 = ATTUNE_HAS)
-- ---------------------------------------------------------------------
function ANx.OnAttuneCompleted(itemId)
    if not (ANx.db and ANx.db.alerts) then return end
    if not (itemId and _G.GetInventoryItemLink) then return end
    for slot = 1, 19 do
        local id = ItemIdFromLink(_G.GetInventoryItemLink("player", slot))
        if id == itemId then
            local name, link = ANx.GetItemDisplay(itemId)
            Announce("|cff00ff00Fully attuned:|r " .. tostring(link or name or itemId)
                .. " |cffffd100- swap it for the next one!|r")
            return
        end
    end
end

