-- =========================================================================
-- AttuneNext - Core.lua
-- Attunement planning addon for the Synastria WotLK server.
-- Recommends the next items to obtain, browsable by
-- Expansion -> Content type -> Dungeon/Raid/Zone/Vendor/Profession.
-- =========================================================================
local ADDON_NAME, ANx = ...
_G.AttuneNext = ANx
ANx.VERSION = "3.4.0"

-- ---------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------
ANx.EXP_NAMES  = { [1] = "Classic", [2] = "The Burning Crusade", [3] = "Wrath of the Lich King" }
ANx.EXP_SHORT  = { [1] = "Classic", [2] = "TBC", [3] = "WotLK" }
ANx.EXP_COLORS = { [1] = "|cffe6cc80", [2] = "|cff1eff00", [3] = "|cff66ccff" }

-- Difficulty tier + raid size for each instance-difficulty label (Data_Instances).
ANx.DIFF_TIER = {
    [""]    = "normal", ["N"] = "normal", ["H"] = "heroic", ["M"] = "mythic",
    ["10"]  = "normal", ["25"] = "normal",
    ["10N"] = "normal", ["25N"] = "normal", ["10H"] = "heroic", ["25H"] = "heroic",
}
ANx.DIFF_SIZE = {  -- nil = size-agnostic (dungeons, single-difficulty raids)
    ["10"] = "10", ["25"] = "25",
    ["10N"] = "10", ["25N"] = "25", ["10H"] = "10", ["25H"] = "25",
}
ANx.DIFF_TIER_LABELS = { all = "All", normal = "Normal", heroic = "Heroic", mythic = "Mythic" }
-- pretty text for an instance difficulty label
ANx.DIFF_LABEL_TEXT = {
    [""] = "", N = "Normal", H = "Heroic", M = "Mythic",
    ["10"] = "10 Player", ["25"] = "25 Player",
    ["10N"] = "10 Normal", ["25N"] = "25 Normal",
    ["10H"] = "10 Heroic", ["25H"] = "25 Heroic",
}
ANx.RAID_SIZE_LABELS = { all = "All", ["10"] = "10-man", ["25"] = "25-man" }

-- Does an instance-difficulty label pass the difficulty tier + raid-size filters?
function ANx.DifficultyMatches(label)
    local d = ANx.db and ANx.db.difficulty or "all"
    if d ~= "all" and (ANx.DIFF_TIER[label] or "normal") ~= d then return false end
    local sz = ANx.db and ANx.db.raidSize or "all"
    if sz ~= "all" then
        local ls = ANx.DIFF_SIZE[label]   -- nil = size-agnostic, always matches
        if ls and ls ~= sz then return false end
    end
    return true
end

-- Is any difficulty/size filter active? (for count adjustments)
function ANx.DifficultyFilterActive()
    return (ANx.db and (ANx.db.difficulty ~= "all" or ANx.db.raidSize ~= "all")) or false
end

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
    minimapShow = true,
    sort = {},            -- [viewType] = sort mode
    vendorFilter = "all", -- currency category filter on vendor pages
    scope = "char",       -- "char" (current character) or "account"
    faction = "both",     -- "both", "A" (Alliance), or "H" (Horde)
    raresOnly = false,    -- World Drops: only items that drop from rare spawns
    zoneExclusive = false,-- global: only count/show items found in a single zone
    forge = 1,            -- Forge Level (1 Attunable, 2 TF, 3 WF, 4 LF)
    classicSkin = false,  -- true = "unskinned" look (no painted art pack)
    browseWinPos = nil,   -- saved position of the simple browse window
    timeMode = "off",     -- how run length weighs in: off/builtin/personal/both
    challengeTimes = {},  -- ["map:diff"] = Dungeon Challenge target, in seconds
    speedPct = {},        -- ["map:diff"] = earned Speed Buff, percent
    stockFilter = "all",  -- vendor item lists: "all" / "limited" / "unlimited"
    affordableOnly = false,-- vendor screens: only items you can currently pay for
    bindFilter = "both",  -- item lists: "both" / "bop" / "boe"
    accessories = true,   -- show accessory-slot items (cloak/ring/neck/trinket)
    difficulty = "all",   -- dungeon/raid difficulty tier: "all"/"normal"/"heroic"/"mythic"
    raidSize = "all",     -- raid size: "all"/"10"/"25"
    anext = {             -- the AttuneNext BUTTON config (never context sensitive)
        focus = false,    --   focus the zone/instance/craft/currency with the most left
        dropRate = false, --   factor in drop rates (excludes vendor/quest/crafted items)
        level = false,    --   only content the current character's level supports
        instance = "off", --   whole-run mode: off/D/R/DR/Z/all
        ignore = {},      --   itemId -> true  (shared with the recommendation cards)
        ignoreInst = {},  --   "map:diff" / "z:zone" -> true (shared too)
    },
    rec = {               -- the ON-SCREEN recommendation cards (always context sensitive)
        focus = false,
        dropRate = false,
        level = false,
        instance = "off",
    },
    stock = {},           -- [itemId] = last-seen numAvailable from a live merchant scan
    reagents = {},        -- [craftedItemId] = { reagentId1, count1, ... } from profession-window scans (account-wide)
    reagentProfs = {},    -- [professionName] = true once its window has been scanned
    reagentOutput = {},   -- [craftedItemId] = items produced per craft (scanned; only >1)
    tooltip = true,       -- add attunement info to item tooltips
    alerts = true,        -- loot/roll alerts + "swap it out" when an equipped item attunes
    zonewatch = true,     -- zone-entry chat note ("N attunables left in ...")
    zoneHud = true,       -- the draggable in-instance HUD window
    goalHud = true,       -- the on-screen goal progress window (shows while goals exist)
    goals = {},           -- tracked goals: {kind="content",exp=,content=} or {kind="inst",map=,name=}
    altCan = {},          -- [charName] = { class=, className=, level=, items={ids} } login snapshots
    searchType = "items", -- search mode: items/vendors/dungeons/raids/profs/quests
    favorites = {},       -- saved screens+filters: { label=, desc=, filters=, key= }
    searchFilters = true, -- searches respect the active filters (toggle next to Find)
    statusCache = nil,    -- per-item status snapshot served before server data arrives
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

-- on-screen toast (center text) + chat line
function ANx.Toast(msg)
    ANx.Print(msg)
    if _G.UIErrorsFrame and _G.UIErrorsFrame.AddMessage then
        local plain = tostring(msg):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        _G.UIErrorsFrame:AddMessage(plain, 0.2, 1.0, 0.6, 1.0)
    end
end

-- true once the Synastria server data (attunes + loot DB) is available this
-- session; before that, item status is served from the saved statusCache
ANx.dataReady = false

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

-- ---------------------------------------------------------------------
-- Status cache: a per-item snapshot saved at logout (and after each data
-- refresh) so the UI shows real numbers IMMEDIATELY at login, before the
-- server has pushed this session's data. Once live data arrives every
-- accessor switches back to the real APIs.
-- ---------------------------------------------------------------------
local scSets   -- runtime membership sets built lazily from the saved arrays

function ANx.InvalidateStatusCacheSets()
    scSets = nil
end

local function SC()
    local sc = ANx.db and ANx.db.statusCache
    if not sc then return nil end
    local me = (_G.UnitName and _G.UnitName("player")) or "?"
    if sc.char ~= me then return nil end   -- another character's snapshot
    if not scSets then
        scSets = { can = {}, acct = {}, tags = {} }
        for _, id in ipairs(sc.can or {}) do scSets.can[id] = true end
        for _, id in ipairs(sc.acct or {}) do scSets.acct[id] = true end
        for _, id in ipairs(sc.tags or {}) do scSets.tags[id] = true end
    end
    return sc, scSets
end

-- Save the snapshot (call when data is live: logout + after refresh)
function ANx.ExportStatusCache()
    if not (ANx.db and ANx.Engine and ANx.dataReady) then return end
    local universe, ready = ANx.Engine.Universe()
    if not ready or #universe == 0 then return end
    local sc = { char = (_G.UnitName and _G.UnitName("player")) or "?",
                 prog = {}, can = {}, acct = {}, tags = {}, forge = {} }
    for _, id in ipairs(universe) do
        if ANx.IsAttunableAtAll(id) then sc.tags[#sc.tags + 1] = id end
        if ANx.CanCharAttune(id) then sc.can[#sc.can + 1] = id end
        if ANx.AccountHasVariant(id) then sc.acct[#sc.acct + 1] = id end
        local p = ANx.Progress(id)
        if p > 0 then sc.prog[id] = p end
        local f = (_G.GetItemAttuneForge and _G.GetItemAttuneForge(id)) or 0
        if f >= 1 then sc.forge[id] = f end
    end
    ANx.db.statusCache = sc
    scSets = nil
end

-- Can the CURRENT CHARACTER attune this item (class/armor/level checks)?
function ANx.CanCharAttune(itemId)
    if not ANx.dataReady then
        local _, sets = SC()
        if sets then return sets.can[itemId] == true end
    end
    local v = _G.CanAttuneItemHelper and _G.CanAttuneItemHelper(itemId)
    return (v or 0) > 0
end

-- Has the CURRENT CHARACTER fully attuned the base item?
function ANx.IsAttuned(itemId)
    return ANx.Progress(itemId) >= 100
end

-- Attune progress 0..100
function ANx.Progress(itemId)
    if not ANx.dataReady then
        local sc = SC()
        if sc then return (sc.prog and sc.prog[itemId]) or 0 end
    end
    return (_G.GetItemAttuneProgress and _G.GetItemAttuneProgress(itemId)) or 0
end

-- Account attuned some variant (affix/forge) of the item
function ANx.AccountHasVariant(itemId)
    if not ANx.dataReady then
        local _, sets = SC()
        if sets then return sets.acct[itemId] == true end
    end
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
    -- an item nobody can attune never counts, whatever the char helper claims
    -- (the server tooltip and CanAttuneItemHelper can disagree on e.g. armor type)
    if not ANx.IsAttunableAtAll(itemId) then return false end
    if ANx.db and ANx.db.scope == "account" then
        return true
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

-- Item tiers stay 0..4 (0 unattuned, 1 attuned, 2 TF, 3 WF, 4 LF).
-- The FILTER is a Forge Level - the state you're working toward:
--   1 Attunable   : done once attuned            (left = unattuned)
--   2 Titanforged : done once TF or better       (left = tiers 0-1)
--   3 Warforged   : done once WF or better       (left = tiers 0-2)
--   4 Lightforged : done once LF                 (left = tiers 0-3)
ANx.FORGE_TIERS  = { "unattuned", "attuned", "tf", "wf", "lf" }
ANx.FORGE_LABELS = {
    [1] = "Attunable", [2] = "Titanforged",
    [3] = "Warforged", [4] = "Lightforged",
}
ANx.FORGE_SHORT  = { [1] = "Attuned", [2] = "TF", [3] = "WF", [4] = "LF" }

-- Whole-run recommendation mode (the "Recommend a whole dungeon/raid/zone"
-- option). Old saved booleans map onto the new modes transparently.
ANx.RUN_MODES = { "off", "D", "R", "DR", "Z", "all" }
ANx.RUN_MODE_LABELS = {
    off = "Off", D = "Dungeons only", R = "Raids only",
    DR = "Dungeons & raids", Z = "Zones", all = "All",
}
-- Which profession crafts this item (reverse lookup, built lazily)
local profOfItem
function ANx.ProfessionOfItem(itemId)
    if not profOfItem then
        profOfItem = {}
        for prof, list in pairs(ANx.ProfessionItems or {}) do
            for _, e in ipairs(list) do
                if type(e) == "table" and e[1] then profOfItem[e[1]] = prof end
            end
        end
    end
    return profOfItem[itemId]
end
function ANx.InvalidateProfOfItem() profOfItem = nil end

-- Is the painted art pack in use? (the Classic layout turns it off, but the
-- AttuneNext logo/emblem stay painted either way)
function ANx.ArtOn()
    if ANx.db and ANx.db.classicSkin then return false end
    return ANx.Art ~= nil
end

-- How clear times factor into the recommendations.
--   off      - ignore run length entirely (default)
--   builtin  - the shipped per-instance estimates only
--   personal - only times this account has actually recorded
--   both     - estimates, with your own times overriding them once you have one
ANx.TIME_MODES = { "off", "builtin", "personal", "both" }
ANx.TIME_MODE_LABELS = {
    off = "Off (ignore run length)",
    builtin = "Built-in estimates",
    personal = "Personal times only",
    both = "Built-in + personal",
}
function ANx.TimeMode()
    local m = ANx.db and ANx.db.timeMode
    if m == true then return "both" end          -- migrate an old boolean
    if ANx.TIME_MODE_LABELS[m] then return m end
    return "off"
end

-- The two recommendation features share one options shape but separate values:
--   "btn" = the AttuneNext button (global - never context sensitive)
--   "rec" = the on-screen recommendation cards (always context sensitive)
function ANx.Cfg(which)
    local db = ANx.db or {}
    if which == "rec" then return db.rec or {} end
    return db.anext or {}
end

function ANx.RunMode(which)
    local m = ANx.Cfg(which).instance
    if m == true then return "DR" end
    if not m or m == false or m == "off" then return "off" end
    if ANx.RUN_MODE_LABELS[m] then return m end
    return "off"
end

function ANx.CharLevel()
    return (_G.UnitLevel and _G.UnitLevel("player")) or 80
end

-- Is the current-character-level filter on for this feature?
function ANx.LevelGate(which)
    return ANx.Cfg(which).level == true
end

function ANx.ForgeLevel()
    local l = (ANx.db and ANx.db.forge) or 1
    if l < 1 then l = 1 elseif l > 4 then l = 4 end
    return l
end

-- Current attunement/forge tier of an item (0..4), scope-aware.
-- forge level from GetItemAttuneForge is account-wide (1=TF, 2=WF, 3=LF).
function ANx.CurrentTier(itemId)
    local forge
    if not ANx.dataReady then
        local sc = SC()
        if sc then forge = (sc.forge and sc.forge[itemId]) or 0 end
    end
    forge = forge or (_G.GetItemAttuneForge and _G.GetItemAttuneForge(itemId)) or 0
    if forge and forge >= 1 then
        if forge >= 3 then return 4 end
        if forge == 2 then return 3 end
        return 2
    end
    if ANx.CountAttuned(itemId) then return 1 end
    return 0
end

-- Per-item forge target: quest rewards can never be forged, so their target
-- is always plain attunement no matter the Forge Level.
function ANx.ItemForgeTarget(itemId)
    local l = ANx.ForgeLevel()
    if l > 1 and ANx.Engine and ANx.Engine.IsQuestOnly and ANx.Engine.IsQuestOnly(itemId) then
        return 1
    end
    return l
end

function ANx.ForgeAllowed(itemId)   -- visible in item lists (= still "left")
    return ANx.CurrentTier(itemId) < ANx.ItemForgeTarget(itemId)
end

function ANx.CountDone(itemId)      -- counts toward "done" in the stats
    return ANx.CurrentTier(itemId) >= ANx.ItemForgeTarget(itemId)
end

-- Completed nodes stay listed while you're chasing forge upgrades.
function ANx.ShowAttunedItems()
    return ANx.ForgeLevel() >= 2
end

-- ---------------------------------------------------------------------
-- Item bind type (for the BoP / BoE filter)
-- ---------------------------------------------------------------------
-- Returns "BOP", "BOE", "NONE", or nil (not cached yet). Static seed first
-- (from Data_ItemBind), else read from the item's tooltip like other addons do.
local bindCache = {}
local bindTip

function ANx.InvalidateBindCache()
    bindCache = {}
end

function ANx.BindType(itemId)
    local c = bindCache[itemId]
    if c ~= nil then return c or nil end   -- c == false means "resolved, unknown"
    local seed = ANx.ItemBind and ANx.ItemBind[itemId]
    if seed then bindCache[itemId] = seed; return seed end
    if not CreateFrame then return nil end
    if not bindTip then
        bindTip = CreateFrame("GameTooltip", "AttuneNextBindTip", nil, "GameTooltipTemplate")
        bindTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    bindTip:ClearLines()
    local ok = pcall(bindTip.SetHyperlink, bindTip, "item:" .. itemId)
    if not ok then return nil end
    local n = bindTip:NumLines()
    if not n or n == 0 then
        -- item not cached; cache "unknown" so counts don't rescan every render.
        -- Rescan (/an reset) clears this once the item has been cached.
        bindCache[itemId] = false
        return nil
    end
    local result = "NONE"
    for i = 1, math.min(n, 6) do
        local fs = _G["AttuneNextBindTipTextLeft" .. i]
        local t = fs and fs:GetText()
        if t then
            if t == ITEM_BIND_ON_PICKUP or t == ITEM_SOULBOUND then result = "BOP"; break
            elseif t == ITEM_BIND_ON_EQUIP then result = "BOE"; break
            elseif t == ITEM_BIND_ON_USE then result = "BOE"; break end
        end
    end
    bindCache[itemId] = result
    return result
end

-- ---------------------------------------------------------------------
-- Accessories (cloak / ring / neck / trinket) - not armor-type restricted,
-- so any character on the account can attune them.
-- ---------------------------------------------------------------------
local accCache = {}
local ACCESSORY_LOC = {
    INVTYPE_CLOAK = true, INVTYPE_FINGER = true,
    INVTYPE_NECK = true, INVTYPE_TRINKET = true,
}

function ANx.InvalidateAccessoryCache()
    accCache = {}
end

-- true if the item is a cloak/ring/neck/trinket. Static seed first, else the
-- item's equip location (needs the item cached; cached "false" once resolved).
function ANx.IsAccessory(itemId)
    local c = accCache[itemId]
    if c ~= nil then return c end
    if ANx.AccessoryItems and ANx.AccessoryItems[itemId] then
        accCache[itemId] = true; return true
    end
    local loc
    if GetItemInfoCustom then loc = select(9, GetItemInfoCustom(itemId)) end
    if (not loc or loc == "") and GetItemInfo then loc = select(9, GetItemInfo(itemId)) end
    if not loc or loc == "" then
        accCache[itemId] = false  -- uncached; assume not-accessory (safe: don't hide)
        return false
    end
    local r = ACCESSORY_LOC[loc] == true
    accCache[itemId] = r
    return r
end

-- Gate: when accessories are toggled off, hide accessory items.
function ANx.AccessoryAllowed(itemId)
    if not ANx.db or ANx.db.accessories ~= false then return true end
    return not ANx.IsAccessory(itemId)
end

-- Bind-filter gate for item lists. "both" passes everything; a specific
-- filter passes only that bind type (unknown/other types are hidden).
function ANx.BindAllowed(itemId)
    local f = ANx.db and ANx.db.bindFilter or "both"
    if f == "both" then return true end
    local b = ANx.BindType(itemId)
    if f == "bop" then return b == "BOP" end
    if f == "boe" then return b == "BOE" end
    return true
end

-- ---------------------------------------------------------------------
-- Item faction ("A"/"H"/nil) - static seed first, else read the item's
-- race restriction from its tooltip (covers raid/dungeon drops the vendor
-- seed doesn't have, e.g. faction-locked Trial of the Crusader loot).
-- ---------------------------------------------------------------------
local ALLIANCE_RACES = { "Human", "Dwarf", "Night Elf", "Gnome", "Draenei", "Worgen" }
local HORDE_RACES    = { "Orc", "Scourge", "Undead", "Tauren", "Troll", "Blood Elf", "Goblin" }
local factionCache = {}
local factionTip

function ANx.InvalidateFactionCache()
    factionCache = {}
end

function ANx.ItemFactionOf(itemId)
    local c = factionCache[itemId]
    if c ~= nil then return c or nil end          -- false = resolved, neutral/unknown
    local seed = ANx.ItemFaction and ANx.ItemFaction[itemId]
    if seed then factionCache[itemId] = seed; return seed end
    if not CreateFrame then return nil end
    if not factionTip then
        factionTip = CreateFrame("GameTooltip", "AttuneNextFactionTip", nil, "GameTooltipTemplate")
        factionTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    factionTip:ClearLines()
    local ok = pcall(factionTip.SetHyperlink, factionTip, "item:" .. itemId)
    if not ok then return nil end
    local n = factionTip:NumLines()
    if not n or n == 0 then return nil end        -- not cached yet; retry later
    local function clean(s)
        if not s then return nil end
        return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local result = false
    for i = 1, n do
        local left = clean(_G["AttuneNextFactionTipTextLeft" .. i]
            and _G["AttuneNextFactionTipTextLeft" .. i]:GetText())
        local right = clean(_G["AttuneNextFactionTipTextRight" .. i]
            and _G["AttuneNextFactionTipTextRight" .. i]:GetText())
        -- Synastria shows a "Faction:" line with "Alliance"/"Horde" on the right
        -- (some items instead show "Alliance Only"/"Horde Only" on the left).
        if left == "Alliance" or left == "Alliance Only" or right == "Alliance" or right == "Alliance Only" then
            result = "A"; break
        elseif left == "Horde" or left == "Horde Only" or right == "Horde" or right == "Horde Only" then
            result = "H"; break
        end
        -- fallback: a race-restriction line lists one faction's races only
        if left then
            local a, h = 0, 0
            for _, r in ipairs(ALLIANCE_RACES) do if left:find(r, 1, true) then a = a + 1 end end
            for _, r in ipairs(HORDE_RACES) do if left:find(r, 1, true) then h = h + 1 end end
            if a >= 3 and h == 0 then result = "A"; break
            elseif h >= 3 and a == 0 then result = "H"; break end
        end
    end
    factionCache[itemId] = result
    return result or nil
end

-- Item-level faction gate. Neutral items always pass.
function ANx.FactionAllowed(itemId)
    local fac = ANx.db and ANx.db.faction
    if not fac or fac == "both" then return true end
    local itf = ANx.ItemFactionOf(itemId)
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

-- ---------------------------------------------------------------------
-- Quest race/class requirements (standard DBC bitmasks from Data_QuestReq)
-- ---------------------------------------------------------------------
local RACE_MASK = {  -- UnitRace("player") file names
    Human = 1, Orc = 2, Dwarf = 4, NightElf = 8, Scourge = 16, Tauren = 32,
    Gnome = 64, Troll = 128, Goblin = 256, BloodElf = 512, Draenei = 1024,
}
local CLASS_MASK = { -- UnitClass("player") file names
    WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16,
    DEATHKNIGHT = 32, SHAMAN = 64, MAGE = 128, WARLOCK = 256, DRUID = 1024,
}
local playerRaceMask, playerClassMask

function ANx.InvalidatePlayerIdentity()
    playerRaceMask, playerClassMask = nil, nil
end

function ANx.PlayerRaceMask()
    if not playerRaceMask then
        local file
        if _G.UnitRace then          -- plain call: `and` would truncate returns
            local _, f = _G.UnitRace("player")
            file = f
        end
        playerRaceMask = (file and RACE_MASK[file]) or 0
    end
    return playerRaceMask
end

function ANx.PlayerClassMask()
    if not playerClassMask then
        local file
        if _G.UnitClass then
            local _, f = _G.UnitClass("player")
            file = f
        end
        playerClassMask = (file and CLASS_MASK[file]) or 0
    end
    return playerClassMask
end

-- Can the CURRENT CHARACTER (race + class) ever complete this quest?
-- Unknown quests / missing data count as doable.
function ANx.CharCanDoQuest(questId)
    if not questId then return true end
    local r = ANx.QuestRaces and ANx.QuestRaces[questId]
    if r then
        local pm = ANx.PlayerRaceMask()
        if pm ~= 0 and bit.band(r, pm) == 0 then return false end
    end
    local c = ANx.QuestClasses and ANx.QuestClasses[questId]
    if c then
        local pm = ANx.PlayerClassMask()
        if pm ~= 0 and bit.band(c, pm) == 0 then return false end
    end
    return true
end

-- Full quest-node gate: faction filter always applies; under Character scope
-- quests this character's race/class can never complete are hidden too.
function ANx.QuestNodeAllowed(questId)
    if not ANx.NodeFactionAllowed("quest", questId) then return false end
    if ANx.db and ANx.db.scope == "char" and not ANx.CharCanDoQuest(questId) then
        return false
    end
    return true
end

function ANx.IsAttunableAtAll(itemId)
    if not ANx.dataReady then
        local _, sets = SC()
        if sets then return sets.tags[itemId] == true end
    end
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

-- ---------------------------------------------------------------------
-- Player currency (for the "affordable only" vendor filter)
-- ---------------------------------------------------------------------
local currencyMap, currencyMapAt = nil, 0

function ANx.InvalidatePlayerCurrency()
    currencyMap = nil
end

-- How much of a named currency the player has right now.
-- Gold is returned in copper (matching the stored cost format).
function ANx.PlayerCurrency(name)
    if name == "Gold" then return GetMoney and GetMoney() or 0 end
    if name == "Honor Points" then
        return (GetHonorCurrency and GetHonorCurrency())
            or (GetHonorPoints and GetHonorPoints()) or 0
    end
    if name == "Arena Points" then
        return (GetArenaCurrency and GetArenaCurrency())
            or (GetArenaPoints and GetArenaPoints()) or 0
    end
    -- token/emblem/mark currencies live in the currency panel; scan it (cached)
    local now = GetTime and GetTime() or 0
    if not currencyMap or (now - currencyMapAt) > 5 then
        currencyMap = {}
        if GetCurrencyListSize and GetCurrencyListInfo then
            for i = 1, GetCurrencyListSize() do
                local cname, isHeader, _, _, _, count = GetCurrencyListInfo(i)
                if cname and not isHeader then currencyMap[cname] = count or 0 end
            end
        end
        currencyMapAt = now
    end
    return currencyMap[name] or 0
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
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_UPDATE")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("PLAYER_MONEY")
eventFrame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")

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

-- Toast once per session, after the post-login background refresh completes
local refreshToasted = false
local function WatchRefreshDone()
    if refreshToasted then return end
    if ANx.Engine and not ANx.Engine.scanning and #(ANx.Engine.scanJobs or {}) == 0 then
        refreshToasted = true
        if ANx.Engine.InvalidateStats then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
        pcall(ANx.ExportStatusCache)     -- keep next login's snapshot fresh
        ANx.Toast("AttuneNext data has been refreshed.")
        return
    end
    ANx.After(1, WatchRefreshDone)
end

-- Global function invoked by the Synastria client when server data is fully loaded
function AttuneNext_OnDataReady()
    TryInit()
    ANx.dataReady = true
    ANx.InvalidateStatusCacheSets()
    refreshToasted = false   -- each data arrival announces one refresh
    if ANx.Engine then
        ANx.Engine.InvalidateAll()
        -- restore last session's structural scan (loot DB version must match)
        if ANx.Engine.ImportCache() then
            ANx.DebugMsg("structural cache restored from previous session")
        end
        -- refresh in the background; toast when everything is live
        for exp = 1, 3 do ANx.Engine.GetSummary(exp) end
        ANx.After(2, WatchRefreshDone)
    end
    if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    -- alt awareness: snapshot what this character can attune (background)
    if ANx.SnapshotAltCan then ANx.After(8, ANx.SnapshotAltCan) end
    -- on-screen goal window
    if ANx.GoalHudUpdate then ANx.After(6, ANx.GoalHudUpdate) end
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        _G.AttuneNextDB = _G.AttuneNextDB or {}
        ApplyDefaults(_G.AttuneNextDB, defaults)
        ANx.db = _G.AttuneNextDB
        -- one-time: the recommendation cards used to share the button's config
        if not ANx.db.recSeeded then
            ANx.db.recSeeded = true
            local a, r = ANx.db.anext or {}, ANx.db.rec
            if r then
                r.focus, r.dropRate, r.instance = a.focus, a.dropRate, a.instance
            end
        end
        if ANx.InitSettings then ANx.InitSettings() end

        -- instant data at login: restore last session's structure right away
        -- (validated again once the server data arrives) - item status comes
        -- from the statusCache until then
        if ANx.Engine and ANx.Engine.ImportCache and ANx.Engine.ImportCache(true) then
            ANx.DebugMsg("provisional structure restored (pre-login data)")
        end

        -- Chain into the Synastria custom-data event to catch attunement changes
        local prevHandler = _G.OnCustomGameData
        _G.OnCustomGameData = function(typeId, id, prev, cur)
            if prevHandler then prevHandler(typeId, id, prev, cur) end
            if typeId == 11 then -- ATTUNE_HAS
                ANx.MarkAttuneDirty()
                if ANx.OnAttuneCompleted then ANx.OnAttuneCompleted(id) end
                if ANx.ZoneWatchUpdate then ANx.ZoneWatchUpdate(false) end
                if ANx.GoalHudUpdate then ANx.GoalHudUpdate() end
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
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
        if ANx.QueueTradeSkillScan then ANx.QueueTradeSkillScan() end
    elseif event == "BAG_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED" then
        -- the What's Left materials screen nets out your stock; keep it fresh
        if ANx.UI and ANx.UI.RefreshMats then ANx.UI.RefreshMats() end
    elseif event == "LOOT_OPENED" then
        if ANx.CheckLootWindow then ANx.CheckLootWindow() end
    elseif event == "START_LOOT_ROLL" then
        if ANx.CheckLootRoll then ANx.CheckLootRoll(arg1) end
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        if ANx.ZoneWatchUpdate then ANx.ZoneWatchUpdate(true) end
        if ANx.ScanSpeedAuras then ANx.After(2, ANx.ScanSpeedAuras) end
    elseif event == "UNIT_AURA" then
        if arg1 == "player" and ANx.ScanSpeedAuras then ANx.ScanSpeedAuras() end
    elseif event == "PLAYER_LOGOUT" then
        if ANx.Engine then pcall(ANx.Engine.ExportCache) end
        pcall(ANx.ExportStatusCache)
    elseif event == "PLAYER_MONEY" or event == "CURRENCY_DISPLAY_UPDATE" then
        ANx.InvalidatePlayerCurrency()
        if ANx.db and ANx.db.affordableOnly then
            if ANx.Engine then ANx.Engine.InvalidateStats() end
            if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
        end
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
    elseif msg == "settings" or msg == "config" or msg == "options" then
        if ANx.OpenSettings then ANx.OpenSettings() end
    elseif msg == "unskinned" or msg == "classic" or msg == "skin" then
        if ANx.UI and ANx.UI.ToggleUnskinned then ANx.UI.ToggleUnskinned() end
    elseif msg == "browse" then
        if ANx.WinBrowse then ANx.WinBrowse.Toggle() end
    elseif msg:match("^timemode") then
        local arg = msg:match("^timemode%s+(%S+)")
        if arg and ANx.TIME_MODE_LABELS[arg] then
            ANx.db.timeMode = arg
            if ANx.Engine then ANx.Engine.InvalidateStats() end
            if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
            if ANx.SyncOptionsPanel then ANx.SyncOptionsPanel() end
        end
        ANx.Print("Run-time weighting: |cffffff00" .. (ANx.TIME_MODE_LABELS[ANx.TimeMode()])
            .. "|r  (off / builtin / personal / both)")
    elseif msg == "ldb" or msg:match("^ldb ") then
        -- Diagnostic: the leaderboard menu shows dungeon-challenge times
        -- (including the 30/40/50% thresholds) for every instance. Nothing in
        -- the documented API exposes them, so look at what the menu itself
        -- populates: new globals, and the text of its frames.
        --   /an ldb        open + update the menu, then dump
        --   /an ldb dump   dump what is on screen right now
        --   /an ldb globals  list global names mentioning leaderboard/challenge
        local sub = msg:match("^ldb%s+(%S+)")

        local function DumpFrameText()
            if not _G.EnumerateFrames then
                ANx.Print("EnumerateFrames unavailable.")
                return
            end
            local shown, lines = 0, 0
            local f = _G.EnumerateFrames()
            while f and lines < 120 do
                local ok, name = pcall(function() return f.GetName and f:GetName() end)
                local vis = false
                pcall(function() vis = f.IsVisible and f:IsVisible() end)
                if ok and name and vis and name:lower():find("leader") then
                    shown = shown + 1
                    ANx.Print("|cffffd100frame|r " .. name)
                    local function Walk(fr, depth)
                        if depth > 3 or lines >= 120 then return end
                        local regs = {}
                        pcall(function() regs = { fr:GetRegions() } end)
                        for _, r in ipairs(regs) do
                            local txt
                            pcall(function()
                                if r.GetText then txt = r:GetText() end
                            end)
                            if txt and txt ~= "" then
                                lines = lines + 1
                                ANx.Print("   " .. string.rep(" ", depth) .. txt)
                                if lines >= 120 then return end
                            end
                        end
                        local kids = {}
                        pcall(function() kids = { fr:GetChildren() } end)
                        for _, k in ipairs(kids) do Walk(k, depth + 1) end
                    end
                    Walk(f, 0)
                end
                f = _G.EnumerateFrames(f)
            end
            if shown == 0 then
                ANx.Print("No visible frame named *leader* - open the Leaderboards menu, pick the dungeon challenge tab, then run |cffffff00/an ldb dump|r.")
            end
        end

        local function DumpGlobals(before)
            local n = 0
            for name, v in pairs(_G) do
                if type(name) == "string" then
                    local low = name:lower()
                    local interesting = low:find("leader") or low:find("challenge")
                        or low:find("ldb") or low:find("speedrun")
                    if interesting and (not before or not before[name]) then
                        n = n + 1
                        if n <= 40 then
                            local extra = ""
                            if type(v) == "table" then
                                local cnt = 0
                                for _ in pairs(v) do cnt = cnt + 1 end
                                extra = " (" .. cnt .. " entries)"
                            end
                            ANx.Print("  |cff33ff99" .. name .. "|r " .. type(v) .. extra)
                        end
                    end
                end
            end
            if n == 0 then ANx.Print("  (nothing found)") end
        end

        if sub == "globals" then
            ANx.Print("Globals mentioning leaderboard / challenge:")
            DumpGlobals(nil)
        elseif sub == "dump" then
            ANx.Print("Leaderboard frame text:")
            DumpFrameText()
        else
            local before = {}
            for k in pairs(_G) do before[k] = true end
            local opened = false
            for _, fn in ipairs({ "OpenLeaderboards", "UpdateLeaderboards" }) do
                if type(_G[fn]) == "function" then
                    opened = true
                    pcall(_G[fn])
                end
            end
            ANx.Print(opened and "Opened the leaderboard menu; dumping in a moment..."
                or "OpenLeaderboards() not found on this client.")
            ANx.After(1, function()
                ANx.Print("New globals after opening:")
                DumpGlobals(before)
                ANx.Print("Existing leaderboard globals:")
                DumpGlobals(nil)
                DumpFrameText()
                ANx.Print("Tip: switch the menu to the dungeon-challenge list, then |cffffff00/an ldb dump|r.")
            end)
        end
    elseif msg == "times" or msg == "challenge" then
        if ANx.PrintChallengeTimes then ANx.PrintChallengeTimes() end
    elseif msg == "times reset" or msg == "challenge reset" then
        if ANx.ResetChallengeTimes then ANx.ResetChallengeTimes() end
    elseif msg == "hud" then
        ANx.db.zoneHud = not ANx.db.zoneHud
        ANx.Print("instance HUD " .. (ANx.db.zoneHud and "on" or "off"))
        if ANx.ZoneWatchNow then ANx.ZoneWatchNow(false) end
    elseif msg == "minimap" then
        ANx.db.minimapShow = not ANx.db.minimapShow
        if ANx.UpdateMinimapButton then ANx.UpdateMinimapButton() end
        ANx.Print("minimap button " .. (ANx.db.minimapShow and "shown" or "hidden"))
    elseif msg == "help" then
        ANx.Print("commands: /an (open), /an browse (simple window), /an settings, /an minimap, /an hud, /an unskinned, /an times [reset], /an timemode <mode>, /an ldb, /an src <itemId>, /an scale <n>, /an reset, /an debug")
    else
        if ANx.UI then ANx.UI.Toggle() end
    end
end
