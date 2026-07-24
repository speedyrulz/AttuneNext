-- =========================================================================
-- AttuneNext - Core.lua
-- Attunement planning addon for the Synastria WotLK server.
-- Recommends the next items to obtain, browsable by
-- Expansion -> Content type -> Dungeon/Raid/Zone/Vendor/Profession.
-- =========================================================================
local ADDON_NAME, ANx = ...
_G.AttuneNext = ANx
ANx.VERSION = "2.2.0"

-- ---------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------
ANx.EXP_NAMES  = { [1] = "Classic", [2] = "The Burning Crusade", [3] = "Wrath of the Lich King" }
ANx.EXP_SHORT  = { [1] = "Classic", [2] = "TBC", [3] = "WotLK" }
ANx.EXP_COLORS = { [1] = "|cffe6cc80", [2] = "|cff1eff00", [3] = "|cff66ccff" }

-- ItemLoc source types (official server documentation)
ANx.SRC = {
    CREATURE      = 0,  -- creature loot
    OBJECT        = 1,  -- gameobject loot (chest)
    QUEST         = 2,  -- quest reward
    ITEM          = 3,  -- item loot (lockbox)
    SPECIAL       = 4,  -- special / custom / dummy
    CRAFT_TRAINER = 5,  -- crafted, spell taught by trainer
    CRAFT_RECIPE  = 6,  -- crafted, spell learned from recipe item
    FISHING       = 7,  -- fishing (open water)
    FISHING_NODE  = 8,  -- fishing (node)
    VENDOR        = 9,  -- vendor
    MILLING       = 10,
    PROSPECTING   = 11,
    DISENCHANT    = 12,
    SKINNING      = 13,
    PICKPOCKET    = 14,
    ACHIEVEMENT   = 15,
    SPECIAL_NPC   = 16,
    SPECIAL_GO    = 17,
    SPECIAL_ITEM  = 18,
    PLAYER        = 19,
    MYTHIC_CREATURE = 20,
    MYTHIC_GO     = 21,
}

-- Source types that count as "drops in the world" for Zone World Drop browsing
ANx.WORLD_DROP_SRC = {
    [0] = true,  -- creature loot
    [1] = true,  -- chest
    [3] = true,  -- lockbox
    [7] = true,  -- fishing
    [8] = true,  -- fishing node
    [14] = true, -- pickpocket
    [20] = true, -- mythic creature
    [21] = true, -- mythic GO
}

-- Source types that count as instance drops (used when picking best source inside a dungeon/raid)
ANx.INSTANCE_DROP_SRC = {
    [0] = true, [1] = true, [3] = true, [14] = true, [16] = true, [17] = true, [20] = true, [21] = true,
}

ANx.MAP_ID_FLAG = 0x8000

-- ---------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------
local defaults = {
    merchant = {},        -- [itemId] = { { name=..., count=... }, ... } scanned costs (account-wide)
    scale = 1.0,
    minimapAngle = 220,
    sort = {},            -- [viewType] = sort mode
    vendorFilter = "all", -- currency category filter on vendor pages
    scope = "char",       -- "char" (current character) or "account"
    faction = "both",     -- "both", "A" (Alliance), or "H" (Horde)
    raresOnly = false,    -- World Drops: only items that drop from rare spawns
    zoneExclusive = false,-- global: only count/show items found in a single zone
    forge = 0,            -- forge target (0..4): "Left" = items at this tier or below
    stockFilter = "all",  -- vendor item lists: "all" / "limited" / "unlimited"
    stock = {},           -- [itemId] = last-seen numAvailable from a live merchant scan
}

local function ApplyDefaults(db, def)
    for k, v in pairs(def) do
        if db[k] == nil then
            if type(v) == "table" then
                db[k] = {}
                ApplyDefaults(db[k], v)
            else
                db[k] = v
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Simple timer (3.3.5 has no C_Timer)
-- ---------------------------------------------------------------------
local timerFrame = CreateFrame("Frame")
local timers = {}
timerFrame:SetScript("OnUpdate", function(self, elapsed)
    local now = GetTime()
    local i = 1
    while i <= #timers do
        local t = timers[i]
        if now >= t.at then
            table.remove(timers, i)
            local ok, err = pcall(t.func)
            if not ok then ANx.DebugMsg("timer error: " .. tostring(err)) end
        else
            i = i + 1
        end
    end
end)

function ANx.After(delay, func)
    table.insert(timers, { at = GetTime() + delay, func = func })
end

-- ---------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------
ANx.debug = false
function ANx.DebugMsg(msg)
    if ANx.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99AttuneNext|r: " .. tostring(msg))
    end
end

function ANx.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99AttuneNext|r: " .. tostring(msg))
end

function ANx.FormatChance(chance)
    if not chance then return "?" end
    if chance >= 100 then return "100%" end
    if chance >= 10 then return string.format("%.1f%%", chance) end
    return string.format("%.2f%%", chance)
end

function ANx.FormatPct(part, total)
    if not total or total == 0 then return "0%" end
    return string.format("%.1f%%", part / total * 100)
end

-- Colored "attuned X / Y (Z%) - Left: N" stats string
function ANx.StatsString(attuned, total)
    local left = total - attuned
    local pct = total > 0 and (attuned / total * 100) or 0
    local color
    if total == 0 then color = "|cff808080"
    elseif left == 0 then color = "|cff00ff00"
    elseif pct >= 50 then color = "|cffffff00"
    else color = "|cffff8040" end
    return string.format("%s%d/%d (%.1f%%)|r  |cffaaaaaaLeft: %d|r", color, attuned, total, pct, left), left
end

-- ---------------------------------------------------------------------
-- Item info helper (handles uncached + custom Synastria items)
-- ---------------------------------------------------------------------
local itemNameCache = {}

function ANx.GetItemDisplay(itemId)
    -- returns name, link, quality, texture (name falls back to "Item #id")
    local cached = itemNameCache[itemId]
    if cached then return cached[1], cached[2], cached[3], cached[4] end

    local name, link, quality, _, _, _, _, _, _, tex
    if GetItemInfoCustom then
        name, link, quality, _, _, _, _, _, _, tex = GetItemInfoCustom(itemId)
    end
    if not name then
        name, link, quality, _, _, _, _, _, _, tex = GetItemInfo(itemId)
    end
    if name then
        itemNameCache[itemId] = { name, link, quality, tex }
        return name, link, quality, tex
    end
    -- Ask the server to cache it; list will self-refresh shortly after
    ANx.RequestItemCache(itemId)
    return "Item #" .. itemId, nil, 1, "Interface\\Icons\\INV_Misc_QuestionMark"
end

local cacheTip
function ANx.RequestItemCache(itemId)
    if not cacheTip then
        cacheTip = CreateFrame("GameTooltip", "AttuneNextCacheTip", nil, "GameTooltipTemplate")
        cacheTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    pcall(cacheTip.SetHyperlink, cacheTip, "item:" .. itemId)
end

-- ---------------------------------------------------------------------
-- Synastria API wrappers (all guarded so a missing API never errors)
-- ---------------------------------------------------------------------
function ANx.IsSynastria()
    return type(_G.GetItemAttuneProgress) == "function"
        and type(_G.CanAttuneItemHelper) == "function"
end

function ANx.LootDbLoaded()
    return type(_G.ItemLocIsLoaded) == "function" and _G.ItemLocIsLoaded() ~= nil
end

-- Can the CURRENT CHARACTER attune this item (class/armor/level checks)?
function ANx.CanCharAttune(itemId)
    local v = _G.CanAttuneItemHelper and _G.CanAttuneItemHelper(itemId)
    return (v or 0) > 0
end

-- Has the CURRENT CHARACTER fully attuned the base item?
function ANx.IsAttuned(itemId)
    local p = _G.GetItemAttuneProgress and _G.GetItemAttuneProgress(itemId)
    return (p or 0) >= 100
end

-- Attune progress 0..100
function ANx.Progress(itemId)
    return (_G.GetItemAttuneProgress and _G.GetItemAttuneProgress(itemId)) or 0
end

-- Account attuned some variant (affix/forge) of the item
function ANx.AccountHasVariant(itemId)
    if _G.HasAttunedAnyVariantOfItem then
        return _G.HasAttunedAnyVariantOfItem(itemId) and true or false
    end
    return false
end

-- ---------------------------------------------------------------------
-- Scope + faction dispatch (drives every count/list in the Engine)
-- ---------------------------------------------------------------------

-- Does this item count toward totals under the current scope?
--   char scope    -> current character can attune it (class/armor/level)
--   account scope -> item is attunable by someone on the account
function ANx.CanCount(itemId)
    if ANx.db and ANx.db.scope == "account" then
        return ANx.IsAttunableAtAll(itemId)
    end
    return ANx.CanCharAttune(itemId)
end

-- Is this item "done" under the current scope?
--   char scope    -> 100% progress on this character
--   account scope -> any variant attuned by any character on the account
function ANx.CountAttuned(itemId)
    if ANx.db and ANx.db.scope == "account" then
        return ANx.AccountHasVariant(itemId)
    end
    return ANx.IsAttuned(itemId)
end

-- Forge tiers: 0 Unattuned, 1 Attuned (base), 2 Titanforged, 3 Warforged, 4 Lightforged
ANx.FORGE_TIERS  = { "unattuned", "attuned", "tf", "wf", "lf" }
ANx.FORGE_LABELS = {
    [0] = "Unattuned", [1] = "Attuned", [2] = "Titanforged",
    [3] = "Warforged", [4] = "Lightforged",
}
ANx.FORGE_SHORT  = { [1] = "Attuned", [2] = "TF", [3] = "WF", [4] = "LF" }

-- Current attunement/forge tier of an item (0..4), scope-aware.
-- forge level from GetItemAttuneForge is account-wide (1=TF, 2=WF, 3=LF).
function ANx.CurrentTier(itemId)
    local forge = (_G.GetItemAttuneForge and _G.GetItemAttuneForge(itemId)) or 0
    if forge and forge >= 1 then
        if forge >= 3 then return 4 end
        if forge == 2 then return 3 end
        return 2
    end
    if ANx.CountAttuned(itemId) then return 1 end
    return 0
end

-- The forge filter is a TARGET tier. An item is still "left" (needs work) if
-- its current tier is at or below the target; it's "done" once it's past it.
--   target Unattuned(0): left = unattuned only          (default; = "what's left")
--   target Warforged(3): left = everything not Lightforged
--   target Lightforged(4): left = everything
function ANx.ForgeAllowed(itemId)   -- visible in item lists (= still "left")
    return ANx.CurrentTier(itemId) <= (ANx.db and ANx.db.forge or 0)
end

function ANx.CountDone(itemId)      -- counts toward "attuned"/done in the stats
    return ANx.CurrentTier(itemId) > (ANx.db and ANx.db.forge or 0)
end

-- Legacy "show attuned items" flag now derives from the forge threshold.
function ANx.ShowAttunedItems()
    return (ANx.db and ANx.db.forge or 0) >= 1
end

-- Item-level faction gate. Neutral items always pass.
function ANx.FactionAllowed(itemId)
    local fac = ANx.db and ANx.db.faction
    if not fac or fac == "both" then return true end
    local itf = ANx.ItemFaction and ANx.ItemFaction[itemId]
    if not itf then return true end
    return itf == fac
end

-- Node-level faction gate for quests / vendors. kind = "quest" | "vendor".
function ANx.NodeFactionAllowed(kind, id)
    local fac = ANx.db and ANx.db.faction
    if not fac or fac == "both" or not id then return true end
    local map = (kind == "quest") and ANx.QuestFaction or ANx.VendorFaction
    local nf = map and map[id]
    if not nf then return true end
    return nf == fac
end

function ANx.IsAttunableAtAll(itemId)
    if _G.GetItemTagsCustom then
        local t = _G.GetItemTagsCustom(itemId)
        if t then return bit.band(t, 64) ~= 0 end
    end
    if _G.IsAttunableBySomeone then
        local r = _G.IsAttunableBySomeone(itemId)
        return r ~= nil and r ~= 0 and r ~= false
    end
    return false
end

-- Player's current world position: continent index, zone index, x, y (0..1).
-- Continent/zone indices match GetMapContinents()/GetMapZones() ordering.
function ANx.PlayerLoc()
    if SetMapToCurrentZone then pcall(SetMapToCurrentZone) end
    local c = GetCurrentMapContinent and GetCurrentMapContinent() or nil
    local z = GetCurrentMapZone and GetCurrentMapZone() or nil
    local x, y = 0, 0
    if GetPlayerMapPosition then
        local ok, mx, my = pcall(GetPlayerMapPosition, "player")
        if ok and mx then x, y = mx, my end
    end
    if type(c) ~= "number" or c < 1 then c = nil end
    if type(z) ~= "number" or z < 1 then z = nil end
    return c, z, x, y
end

-- Distance rank for sorting (lower = closer). loc = { zoneName=, x=, y= } (x,y in 0..100)
-- Same zone with coords -> real planar distance; same zone -> ~150; same continent
-- -> ~10000; other continent -> ~100000; unknown location -> huge.
function ANx.DistanceRank(loc)
    if not loc or not loc.zoneName then return 1e9 end
    if not ANx.ZoneToContinentZone then return 1e8 end
    local c, z = ANx.ZoneToContinentZone(loc.zoneName)  -- must be a plain call (multi-return)
    if not c then return 1e8 end
    local pc, pz, px, py = ANx.PlayerLoc()
    if pc and c == pc then
        if pz and z == pz then
            if loc.x and loc.y and (px > 0 or py > 0) then
                local dx, dy = px * 100 - loc.x, py * 100 - loc.y
                return math.sqrt(dx * dx + dy * dy)   -- ~0..140
            end
            return 150
        end
        return 10000 + (z or 0)
    end
    return 100000 + c * 1000 + (z or 0)
end

-- Build ItemLoc zone id for an instance map + difficulty.
-- Format: mapId in low bits, difficulty in bits 10-13, 0x8000 = "this is a mapId" flag.
-- (Verified against TheJournal data: 37397 = 533(Naxx) + 0x8000 + 4(25man)<<10,
--  35448 = 632(Forge of Souls) + 0x8000 + 2(heroic)<<10.)
function ANx.BuildMapZoneId(mapId, difficulty)
    difficulty = difficulty or 0
    return mapId + ANx.MAP_ID_FLAG + (difficulty % 16) * 1024
end

-- All attunable + obtainable itemIds for a zoneId (open world) or map zone id
function ANx.ItemsInZone(zoneId)
    if not ANx.LootDbLoaded() then return {} end
    return _G.ItemLocGetAllItemsInZone(zoneId, 0, 0, 1, 1) or {}
end

-- All sources of an item: { {srcType, objType, objId, chance, perMille, objName, zoneName, spawned}, ... }
function ANx.GetSources(itemId)
    if not ANx.LootDbLoaded() then return {} end
    local n = _G.ItemLocGetSourceCount(itemId)
    if not n or n == 0 then return {} end
    local out = {}
    for i = 1, n do
        local srcType, objType, objId, chance, perMille, objName, zoneName, spawned = _G.ItemLocGetSourceAt(itemId, i)
        if srcType ~= nil then
            out[#out + 1] = {
                srcType = srcType, objType = objType, objId = objId,
                chance = chance or 0, perMille = perMille,
                objName = objName or "?", zoneName = zoneName or "",
                spawned = spawned,
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Init / events
-- ---------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

local initialized = false
local function TryInit()
    if initialized then return end
    initialized = true
    ANx.Print("v" .. ANx.VERSION .. " loaded. Type |cffffff00/attunenext|r or |cffffff00/an|r to open.")
    if not ANx.IsSynastria() then
        ANx.Print("|cffff4040Synastria attunement API not detected - is this the Synastria client?|r")
    elseif not ANx.LootDbLoaded() then
        ANx.Print("|cffff4040Loot database not loaded - item lists will be empty. (ItemLocIsLoaded() is nil)|r")
    end
end

-- Global function invoked by the Synastria client when server data is fully loaded
function AttuneNext_OnDataReady()
    TryInit()
    if ANx.Engine then
        ANx.Engine.InvalidateAll()
        -- restore last session's structural scan (loot DB version must match)
        if ANx.Engine.ImportCache() then
            ANx.DebugMsg("structural cache restored from previous session")
        end
    end
    if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        _G.AttuneNextDB = _G.AttuneNextDB or {}
        ApplyDefaults(_G.AttuneNextDB, defaults)
        ANx.db = _G.AttuneNextDB

        -- Chain into the Synastria custom-data event to catch attunement changes
        local prevHandler = _G.OnCustomGameData
        _G.OnCustomGameData = function(typeId, id, prev, cur)
            if prevHandler then prevHandler(typeId, id, prev, cur) end
            if typeId == 11 then -- ATTUNE_HAS
                ANx.MarkAttuneDirty()
            end
        end
    elseif event == "PLAYER_LOGIN" then
        if _G.SynastriaSafeInvoke then
            _G.SynastriaSafeInvoke("AttuneNext_OnDataReady")
        else
            -- Fallback: poll for data-ready
            local tries = 0
            local function poll()
                tries = tries + 1
                if (_G.GetCustomGameData and _G.GetCustomGameData(41, 0) ~= 0) or tries > 20 then
                    AttuneNext_OnDataReady()
                else
                    ANx.After(1, poll)
                end
            end
            poll()
        end
    elseif event == "MERCHANT_SHOW" then
        if ANx.ScanMerchant then ANx.After(0.2, ANx.ScanMerchant) end
    elseif event == "PLAYER_LOGOUT" then
        if ANx.Engine then pcall(ANx.Engine.ExportCache) end
    end
end)

-- Debounced cache invalidation when attunement data changes
local dirtyPending = false
function ANx.MarkAttuneDirty()
    if dirtyPending then return end
    dirtyPending = true
    ANx.After(2, function()
        dirtyPending = false
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end)
end

-- ---------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------
SLASH_ATTUNENEXT1 = "/attunenext"
SLASH_ATTUNENEXT2 = "/an"
SlashCmdList["ATTUNENEXT"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "debug" then
        ANx.debug = not ANx.debug
        ANx.Print("debug " .. (ANx.debug and "on" or "off"))
    elseif msg:match("^src%s+%d+") then
        -- /an src <itemId> : dump raw sources for verification
        local id = tonumber(msg:match("(%d+)"))
        local name = ANx.GetItemDisplay(id)
        ANx.Print("Sources for " .. name .. " (" .. id .. "):")
        local sources = ANx.GetSources(id)
        if #sources == 0 then ANx.Print("  none / loot DB not loaded") end
        for i, s in ipairs(sources) do
            ANx.Print(string.format("  %d. srcType=%d objType=%d objId=%d chance=%.2f obj=%s zone=%s",
                i, s.srcType, s.objType or -1, s.objId or -1, s.chance, s.objName, s.zoneName))
        end
    elseif msg:match("^scale") then
        local v = tonumber(msg:match("([%d%.]+)"))
        if v and v >= 0.5 and v <= 2 then
            ANx.db.scale = v
            if ANx.UI and ANx.UI.frame then ANx.UI.frame:SetScale(v) end
            ANx.Print("scale set to " .. v)
        else
            ANx.Print("usage: /an scale 0.5 - 2.0")
        end
    elseif msg == "reset" then
        if ANx.Engine then ANx.Engine.ForceRescan() end
        ANx.Print("caches cleared (including saved scan) - rescanning")
        if ANx.UI then ANx.UI.Show(true) end
    elseif msg == "help" then
        ANx.Print("commands: /an (open), /an src <itemId>, /an scale <n>, /an reset, /an debug")
    else
        if ANx.UI then ANx.UI.Toggle() end
    end
end
