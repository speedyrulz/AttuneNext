-- =========================================================================
-- AttuneNext - Core.lua
-- Attunement planning addon for the Synastria WotLK server.
-- Recommends the next items to obtain, browsable by
-- Expansion -> Content type -> Dungeon/Raid/Zone/Vendor/Profession.
-- =========================================================================
local ADDON_NAME, ANx = ...
_G.AttuneNext = ANx
ANx.VERSION = "3.6.3"

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

-- The difficulty label of the instance the player is physically in (cached;
-- refreshed on zone changes). nil when not in a known instance.
ANx._curInstLabel = nil
ANx._curInstMap = nil

function ANx.UpdateCurrentInstance()
    local label, map
    if _G.IsInInstance and _G.IsInInstance() then
        local zone = (_G.GetRealZoneText and _G.GetRealZoneText()) or ""
        for _, inst in ipairs(ANx.Instances or {}) do
            if inst.name == zone then
                map = inst.map
                label = ANx.CurrentDifficultyLabel and ANx.CurrentDifficultyLabel(inst) or nil
                local diffs = ANx.Engine and ANx.Engine.InstanceDiffs
                    and ANx.Engine.InstanceDiffs(inst)
                if diffs and #diffs == 1 then label = diffs[1].label end
                break
            end
        end
    end
    local changed = (label ~= ANx._curInstLabel) or (map ~= ANx._curInstMap)
    ANx._curInstLabel, ANx._curInstMap = label, map
    if changed and ANx.db and ANx.db.matchInstance ~= false then
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end
end

-- Does an instance-difficulty label pass the difficulty tier + raid-size
-- filters? instMap (optional): the instance this label belongs to; when you
-- are standing inside THAT instance and haven't set the manual chips, the
-- list auto-narrows to the exact difficulty you are in (e.g. only 10-man
-- while in Ulduar-10). Other instances and the summaries are unaffected.
function ANx.DifficultyMatches(label, instMap)
    local d = ANx.db and ANx.db.difficulty or "all"
    local sz = ANx.db and ANx.db.raidSize or "all"

    if ANx.db and ANx.db.matchInstance ~= false and d == "all" and sz == "all"
        and instMap and instMap == ANx._curInstMap and ANx._curInstLabel then
        local cl = ANx._curInstLabel
        if (ANx.DIFF_TIER[label] or "normal") ~= (ANx.DIFF_TIER[cl] or "normal") then
            return false
        end
        local ls, cs = ANx.DIFF_SIZE[label], ANx.DIFF_SIZE[cl]
        if cs and ls ~= cs then return false end   -- 10-man vs 25-man
        return true
    end

    if d ~= "all" and (ANx.DIFF_TIER[label] or "normal") ~= d then return false end
    if sz ~= "all" then
        local ls = ANx.DIFF_SIZE[label]   -- nil = size-agnostic, always matches
        if ls and ls ~= sz then return false end
    end
    return true
end

-- Is the in-instance auto-narrow currently affecting this instance's list?
function ANx.InstanceAutoNarrow(instMap)
    return (ANx.db and ANx.db.matchInstance ~= false
        and (ANx.db.difficulty or "all") == "all" and (ANx.db.raidSize or "all") == "all"
        and instMap and instMap == ANx._curInstMap and ANx._curInstLabel) and true or false
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
    hideInBags = false,   -- global: hide items you already carry (bags, bank, equipped)
    forge = 1,            -- Forge Level (1 Attunable, 2 TF, 3 WF, 4 LF)
    classicSkin = false,  -- true = "unskinned" look (no painted art pack)
    browseWinPos = nil,   -- saved position of the simple browse window
    timeMode = "off",     -- how run length weighs in: off/builtin/personal/both
    challengeTimes = {},  -- ["map:diff"] = Dungeon Challenge target, in seconds
    speedPct = {},        -- ["map:diff"] = earned Speed Buff, percent
    stockFilter = "all",  -- vendor item lists: "all" / "limited" / "unlimited"
    affordableOnly = false,-- vendor screens: only items you can currently pay for
    bindFilter = "both",  -- item lists: "both" / "bop" / "boe"
    questClass = "mine",  -- quest pages: "mine" hides quests this class can't take
    matchInstance = true, -- while inside an instance, its list shows only the difficulty you're in
    prestige = false,     -- prestige mode: unlocks the manual Class filter chip
    classFilter = "all",  -- prestige only: narrow lists to gear one class can use
    classFilterMode = "gear", -- what the Class filter means: "gear" = the class's
                          -- own armor types; "equip" = anything it can physically wear
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
    plates = {            -- nameplate marking of mobs/vendors with unattuned items
        mode = "on",      --   "off" / "on" (everything unattuned) / "filters" (window filters)
        scope = "acct",   --   "char" or "acct": whose attunes count (On mode)
        pulse = true,     --   breathe the glow
    },
    rec = {               -- the ON-SCREEN recommendation cards (always context
        focus = false,    -- sensitive; WHAT they recommend follows the screen,
        dropRate = false, -- so they carry no run-mode option)
        level = false,
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
        elseif type(v) == "table" and type(db[k]) == "table" then
            -- recurse into EXISTING subtables too: keys added to nested
            -- defaults (anext/plates/rec) in an upgrade used to stay nil
            -- forever for anyone with an older SavedVariables
            ApplyDefaults(db[k], v)
        end
    end
end

-- Every filter the chip row / lists honor, reset from the defaults table.
-- ONE shared implementation: the two "reset filters" buttons each carried
-- their own (different, both incomplete) key lists.
local FILTER_RESET_KEYS = {
    "scope", "faction", "forge", "zoneExclusive", "hideInBags", "stockFilter", "vendorFilter",
    "raresOnly", "questClass", "classFilter", "bindFilter", "accessories",
    "difficulty", "raidSize", "affordableOnly",
}
function ANx.ResetFilters()
    if not ANx.db then return end
    for _, k in ipairs(FILTER_RESET_KEYS) do
        ANx.db[k] = defaults[k]
    end
    ANx.db.sort = {}
    ANx.InvalidatePlayerCurrency()
    if ANx.Engine then ANx.Engine.InvalidateStats() end
end

-- ---------------------------------------------------------------------
-- Simple timer (3.3.5 has no C_Timer)
-- ---------------------------------------------------------------------
local timerFrame = CreateFrame("Frame")
local timers = {}
-- /an perf telemetry: plain integer counters on paths that already run.
-- Core owns the table (it loads first); Engine.lua adds its own fields and
-- Engine.PerfStats() merges everything for the printer. Nothing here is
-- more than an increment or a debugprofilestop() read per event.
local perf = {
    gsCalls = 0, gsEmpty = 0, gsRows = 0, gsMaxRows = 0, gsMaxItem = 0,   -- ANx.GetSources
    cacheReq = 0,                                            -- RequestItemCache (SetHyperlink queries)
    tipBind = 0, tipClass = 0, tipFac = 0, tipEmpty = 0,     -- tooltip scrapes per scraper, empty = item not cached
    afterN = 0, afterMs = 0, afterMaxMs = 0, afterMaxName = "-",
    statusExportMs = 0, statusExportN = 0,
    readyAt = 0, readyN = 0,                                 -- GetTime() of the last data-ready
    zfN = 0, zfMs = 0, zfMaxMs = 0, zfMaxZone = 0,           -- ItemLocGetAllItemsInZone calls
    rowReads = 0, memoItems = 0,                             -- streamed source rows read, scan memos built
}
ANx.Perf = perf
local function PerfClock()
    if debugprofilestop then return debugprofilestop() end
    return GetTime() * 1000
end
ANx.PerfClock = PerfClock

timerFrame:SetScript("OnUpdate", function(self, elapsed)
    local now = GetTime()
    local i = 1
    while i <= #timers do
        local t = timers[i]
        if now >= t.at then
            table.remove(timers, i)
            local t0 = PerfClock()
            local ok, err = pcall(t.func)
            local ms = PerfClock() - t0
            perf.afterN = perf.afterN + 1
            perf.afterMs = perf.afterMs + ms
            if ms > perf.afterMaxMs then
                perf.afterMaxMs = ms
                perf.afterMaxName = t.name or "anon"
            end
            if not ok then ANx.ReportError("timer error: " .. tostring(err)) end
        else
            i = i + 1
        end
    end
    if #timers == 0 then self:Hide() end   -- OnUpdate only fires while shown
end)

-- `name` is optional: /an perf reports the slowest deferred callback by it
-- (the 3.3.5 client has no debug.getinfo to name a function after the fact)
function ANx.After(delay, func, name)
    table.insert(timers, { at = GetTime() + delay, func = func, name = name })
    timerFrame:Show()
end

-- Deferred-callback errors used to vanish unless debug logging was on - the
-- only symptom was "the list never refreshed". Say each distinct error once.
local reportedErrors = {}
function ANx.ReportError(msg)
    msg = tostring(msg)
    if not reportedErrors[msg] then
        reportedErrors[msg] = true
        ANx.Print("|cffff4040" .. msg .. "|r")
    elseif ANx.debug then
        ANx.DebugMsg(msg)
    end
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
-- Packed data tables. Several Data_* tables ship as one sorted fixed-width
-- hex string instead of a Lua hash: a [id]=value hash node costs ~28 bytes
-- on the 32-bit client, a packed record 5-6 chars. Records are 4 hex chars
-- of id (all packed ids are < 65,536) followed by `vw` hex chars of value
-- (vw = 0/nil: a plain membership set). Lookup binary-searches the string;
-- ~13 probes of a few bytes each, so wrap call sites in a cache only when
-- they are genuinely hot.
-- ---------------------------------------------------------------------
-- hex character -> value, indexed by byte code (no string allocation)
local HEXV = {}
for i = 0, 9 do HEXV[48 + i] = i end                       -- '0'..'9'
for i = 0, 5 do HEXV[65 + i] = 10 + i; HEXV[97 + i] = 10 + i end  -- A-F / a-f

local strbyte, mfloor = string.byte, math.floor

-- Binary search a packed table. Probes read raw bytes: the obvious
-- sub()+tonumber(x,16) form allocated a string per probe (~13 per lookup),
-- which showed up as a fifth of the whole background warmup.
function ANx.PackedFind(s, id, vw)
    if not s or not id then return nil end
    vw = vw or 0
    local rw = 4 + vw
    local lo, hi = 0, mfloor(#s / rw) - 1
    while lo <= hi do
        local mid = mfloor((lo + hi) / 2)
        local p = mid * rw
        local b1, b2, b3, b4 = strbyte(s, p + 1, p + 4)
        local v = HEXV[b1] * 4096 + HEXV[b2] * 256 + HEXV[b3] * 16 + HEXV[b4]
        if v == id then
            if vw == 0 then return true end
            if vw == 1 then return HEXV[strbyte(s, p + 5)] end
            if vw == 2 then
                local c1, c2 = strbyte(s, p + 5, p + 6)
                return HEXV[c1] * 16 + HEXV[c2]
            end
            local acc = 0
            for i = p + 5, p + 4 + vw do acc = acc * 16 + HEXV[strbyte(s, i)] end
            return acc
        elseif v < id then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return nil
end

-- ---------------------------------------------------------------------
-- Consolidated per-item flag cache.
-- The per-item predicate caches (bind, faction, accessory, quest-side,
-- quest-only, quest-char-blocked, zone-exclusive, min-level) each used to
-- be their own [itemId]=value hash. The background warmup fills every one
-- of them for the whole universe, and each sparse hash rounds up to a
-- 16,384-node table (~460 KB on the 32-bit client) - together ~3 MB to
-- remember a few bits per item. They now share ONE packed-integer table.
--
-- Field layout of a flags value (0 always means "nothing known yet"):
--   F_BIND   (3 bits)  1 retry-when-item-caches, 2 BOP, 3 BOE, 4 NONE
--   F_FAC    (2 bits)  1 neutral, 2 Alliance, 3 Horde
--   F_ACC    (2 bits)  1 not an accessory, 2 accessory
--   F_QSIDE  (2 bits)  1 none/mixed, 2 Alliance, 3 Horde
--   F_QONLY  (2 bits)  1 no, 2 yes (every source is a quest)
--   F_QCHAR  (2 bits)  1 no, 2 yes (every quest impossible for this char)
--   F_ZEX    (2 bits)  1 no, 2 yes (drops in exactly one zone)
--   F_MINLVL (10 bits) 1 client-can't-say-yet, else requiredLevel + 2
-- ---------------------------------------------------------------------
ANx.F_BIND, ANx.F_FAC, ANx.F_ACC, ANx.F_QSIDE = 0, 3, 5, 7
ANx.F_QONLY, ANx.F_QCHAR, ANx.F_ZEX, ANx.F_MINLVL = 9, 11, 13, 15

local itemFlags = {}
local band, lshift, rshift = bit.band, bit.lshift, bit.rshift

-- Shared with Engine.lua, which reads fields INLINE off this table. The
-- table object is never replaced (FlagClearMask nils entries in place), so
-- a cached reference stays valid for the session. Reading through
-- ANx.FlagGet costs two global lookups plus a call, and these predicates
-- are read once per item per background warmup - it measured as a third of
-- the warmup, so the hot accessors do the two bit ops themselves.
ANx.ItemFlags = itemFlags

function ANx.FlagGet(id, shift, mask)
    local f = itemFlags[id]
    if not f then return 0 end
    return band(rshift(f, shift), mask)
end

function ANx.FlagSet(id, shift, mask, v)
    local f = itemFlags[id] or 0
    -- subtract the old field, add the new (fields never overlap, so plain
    -- arithmetic avoids any bnot/sign pitfalls of the 3.3.5 bit library)
    itemFlags[id] = f - lshift(band(rshift(f, shift), mask), shift)
        + lshift(band(v, mask), shift)
    return v
end

-- Clear specific fields (rawMask = field masks shifted into place) for every
-- cached item. O(cached items), only used by the rare invalidation paths.
function ANx.FlagClearMask(rawMask)
    for id, f in pairs(itemFlags) do
        local hit = band(f, rawMask)
        if hit ~= 0 then
            local rest = f - hit
            if rest == 0 then itemFlags[id] = nil else itemFlags[id] = rest end
        end
    end
end

function ANx.FlagClearAll(shift, mask)
    ANx.FlagClearMask(lshift(mask, shift))
end

-- ---------------------------------------------------------------------
-- Item info helper (handles uncached + custom Synastria items)
-- ---------------------------------------------------------------------
-- [itemId] = display name. Name ONLY: caching the full {name, link, quality,
-- tex} tuple kept a unique ~100-byte link string plus a 4-slot table alive for
-- every item ever displayed (~2.5 MB once a search had touched the whole
-- universe). Link/quality/texture are re-read live from the client - cheap C
-- lookups once the item is resolvable.
local itemNameCache = {}

-- Quality + texture for the items currently being DISPLAYED. Bounded and
-- flushed wholesale on overflow (the srcCache pattern): rows re-read these
-- every render, but only a screenful of items is ever live, so this stays
-- tiny - unlike the old cache, which kept a table AND a unique link string
-- for every item the search had ever touched.
local dispCache, dispN = {}, 0
local DISP_CAP = 3000

function ANx.InvalidateDisplayCache()
    dispCache, dispN = {}, 0
end

function ANx.GetItemDisplay(itemId, noRequest)
    -- returns name, link, quality, texture (name falls back to "Item #id")
    local cname = itemNameCache[itemId]
    if cname then
        local d = dispCache[itemId]
        -- link is deliberately NOT cached (unique ~100-byte string per item);
        -- the two shift-click sites fetch it live
        if d then return cname, nil, d[1], d[2] end
    end
    local name, link, quality, _, _, _, _, _, _, tex
    if GetItemInfoCustom then
        name, link, quality, _, _, _, _, _, _, tex = GetItemInfoCustom(itemId)
    end
    if not name then
        name, link, quality, _, _, _, _, _, _, tex = GetItemInfo(itemId)
    end
    if name then
        itemNameCache[itemId] = name
        if dispN >= DISP_CAP then dispCache, dispN = {}, 0 end
        dispCache[itemId] = { quality, tex }
        dispN = dispN + 1
        return name, link, quality, tex
    end
    name = itemNameCache[itemId]     -- resolved earlier this session
    if not name then
        -- Ask the server to cache it; list will self-refresh shortly after
        if not noRequest then ANx.RequestItemCache(itemId) end
        name = "Item #" .. itemId
    end
    return name, nil, 1, "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- The item's chat link, fetched live. GetItemDisplay deliberately does NOT
-- cache links (a unique ~100-byte string per item, and the old cache kept one
-- for every item a search had ever touched), so anything that actually needs
-- a link - chat insertion, loot alerts - asks for it here.
function ANx.GetItemLink(itemId)
    local _, link
    if GetItemInfoCustom then _, link = GetItemInfoCustom(itemId) end
    if not link and GetItemInfo then _, link = GetItemInfo(itemId) end
    return link
end

-- Name-only accessor for bulk loops (search, sort keys). Never queries the
-- server; returns nil for items the client hasn't resolved yet.
function ANx.GetItemName(itemId)
    local n = itemNameCache[itemId]
    if n then return n end
    if GetItemInfoCustom then n = GetItemInfoCustom(itemId) end
    if not n and GetItemInfo then n = GetItemInfo(itemId) end
    if n then itemNameCache[itemId] = n end
    return n
end

local cacheTip
local cacheRequested = {}   -- ask the server about each unresolved id at most
                            -- once per session (SetHyperlink IS a server query;
                            -- un-deduped it re-fired for the same ids on every
                            -- render of a list containing them)
function ANx.RequestItemCache(itemId)
    if cacheRequested[itemId] then return end
    cacheRequested[itemId] = true
    perf.cacheReq = perf.cacheReq + 1
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

-- Decode helpers: the snapshot ships as packed strings (see ExportStatusCache)
-- but the old array/hash form is still read for one session after upgrading.
local function ScFillSet(t, s)
    if type(s) == "string" then
        for id in s:gmatch("%d+") do t[tonumber(id)] = true end
    elseif type(s) == "table" then
        for _, id in ipairs(s) do t[id] = true end
    end
end

local function ScFillMap(t, s)
    if type(s) == "string" then
        for id, v in s:gmatch("(%d+):([%d%.]+)") do t[tonumber(id)] = tonumber(v) end
    elseif type(s) == "table" then
        for id, v in pairs(s) do t[id] = v end
    end
end

local function SC()
    local sc = ANx.db and ANx.db.statusCache
    if not sc then return nil end
    local me = (_G.UnitName and _G.UnitName("player")) or "?"
    if sc.char ~= me then return nil end   -- another character's snapshot
    if not scSets then
        scSets = { can = {}, acct = {}, tags = {}, prog = {}, forge = {} }
        ScFillSet(scSets.can, sc.can)
        ScFillSet(scSets.acct, sc.acct)
        ScFillSet(scSets.tags, sc.tags)
        ScFillMap(scSets.prog, sc.prog)
        ScFillMap(scSets.forge, sc.forge)
    end
    return sc, scSets
end

-- Save the snapshot (call when data is live: logout + after refresh).
-- Everything is packed into a handful of concatenated strings: the old
-- per-id arrays/hashes stayed resident in the db all session (~250-400 KB
-- at high completion) and serialized as one SavedVariables line PER ID;
-- the strings are a fraction of the RAM and parse in one gmatch pass.
function ANx.ExportStatusCache()
    if not (ANx.db and ANx.Engine and ANx.dataReady) then return end
    local universe, ready = ANx.Engine.Universe()
    if not ready or #universe == 0 then return end
    local t0 = PerfClock()
    local tags, can, acct, prog, forge = {}, {}, {}, {}, {}
    local MaybeYield = ANx.Engine.MaybeYield   -- no-op on the main thread (logout)
    for _, id in ipairs(universe) do
        MaybeYield("status-export")
        if ANx.IsAttunableAtAll(id) then tags[#tags + 1] = id end
        if ANx.CanCharAttune(id) then can[#can + 1] = id end
        if ANx.AccountHasVariant(id) then acct[#acct + 1] = id end
        local p = ANx.Progress(id)
        if p > 0 then
            -- floor at one decimal: never round 99.96 UP to an "attuned" 100
            prog[#prog + 1] = id .. ":" .. string.format("%.1f", math.floor(p * 10) / 10)
        end
        local f = (_G.GetItemAttuneForge and _G.GetItemAttuneForge(id)) or 0
        if f >= 1 then forge[#forge + 1] = id .. ":" .. f end
    end
    -- five 20k-id concatenations: one per slice, so the job's last resume
    -- is not a 25 ms frame (no-ops at logout, off the pump)
    local sTags = "," .. table.concat(tags, ",") .. ","; MaybeYield("status-export")
    local sCan = "," .. table.concat(can, ",") .. ","; MaybeYield("status-export")
    local sAcct = "," .. table.concat(acct, ",") .. ","; MaybeYield("status-export")
    local sProg = table.concat(prog, ","); MaybeYield("status-export")
    ANx.db.statusCache = {
        char = (_G.UnitName and _G.UnitName("player")) or "?",
        tags = sTags, can = sCan, acct = sAcct, prog = sProg,
        forge = table.concat(forge, ","),
    }
    scSets = nil
    perf.statusExportMs = PerfClock() - t0
    perf.statusExportN = perf.statusExportN + 1
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
        local _, sets = SC()
        if sets then return sets.prog[itemId] or 0 end
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
-- Which profession crafts this item (reverse lookup, built lazily).
-- This is the ONE reverse index - Engine.ItemBucket uses it too (a second
-- identical local copy in Engine.lua was deleted; it doubled the RAM).
local profOfItem
function ANx.ProfessionOfItem(itemId)
    if not profOfItem then
        profOfItem = {}
        for prof, rows in pairs(ANx.ProfessionItems or {}) do
            local ids = rows.ids or rows   -- parallel-array form (or legacy rows)
            for i = 1, #ids do
                local e = ids[i]
                if type(e) == "number" then profOfItem[e] = prof
                elseif type(e) == "table" and e[1] then profOfItem[e[1]] = prof end
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
        local _, sets = SC()
        if sets then forge = sets.forge[itemId] or 0 end
    end
    forge = forge or (_G.GetItemAttuneForge and _G.GetItemAttuneForge(itemId)) or 0
    if forge and forge >= 1 then
        -- forge level is ACCOUNT-wide: under Character scope it must not mark
        -- an item done for a character that has never attuned it (an alt's
        -- titanforge used to hide the item from this character's lists)
        local scope = (ANx.db and ANx.db.scope) or "char"
        if scope == "account" or ANx.IsAttuned(itemId) then
            if forge >= 3 then return 4 end
            if forge == 2 then return 3 end
            return 2
        end
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
local bindTip
local BIND_CODE = { BOP = 2, BOE = 3, NONE = 4 }
local BIND_NAME = { [2] = "BOP", [3] = "BOE", [4] = "NONE" }

-- Static bind-type seed: ONE probe into the packed table (Data_ItemBind).
local BIND_SEED = { [1] = "BOP", [2] = "BOE", [3] = "NONE" }
function ANx.ItemBindSeed(itemId)
    local c = ANx.ItemBindPacked and ANx.PackedFind(ANx.ItemBindPacked, itemId, 1)
    return c and BIND_SEED[c] or nil
end

function ANx.InvalidateBindCache()
    ANx.FlagClearAll(ANx.F_BIND, 7)
end

function ANx.BindType(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, 0), 7) or 0    -- F_BIND == 0
    if c >= 2 then return BIND_NAME[c] end
    -- a cached "unknown" must never shadow the static seed (the tooltip may
    -- have been scanned before the item was in the client cache)
    local seed = ANx.ItemBindSeed(itemId)
    if seed then ANx.FlagSet(itemId, ANx.F_BIND, 7, BIND_CODE[seed]); return seed end
    if c == 1 then
        -- scanned before the client had this item's data. Retry only once
        -- the item resolves - otherwise a filtered render during the early
        -- provisional window used to bake in "unknown" for the whole session
        if not (GetItemInfo and GetItemInfo(itemId)) then return nil end
    end
    if not CreateFrame then return nil end
    if not bindTip then
        bindTip = CreateFrame("GameTooltip", "AttuneNextBindTip", nil, "GameTooltipTemplate")
        bindTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    bindTip:ClearLines()
    perf.tipBind = perf.tipBind + 1
    local ok = pcall(bindTip.SetHyperlink, bindTip, "item:" .. itemId)
    if not ok then return nil end
    local n = bindTip:NumLines()
    if not n or n == 0 then
        perf.tipEmpty = perf.tipEmpty + 1
        -- item not in the client cache yet; remember that so counts don't
        -- rescan the tooltip every render (retried above once it caches)
        ANx.FlagSet(itemId, ANx.F_BIND, 7, 1)
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
    ANx.FlagSet(itemId, ANx.F_BIND, 7, BIND_CODE[result])
    return result
end

-- ---------------------------------------------------------------------
-- Accessories (cloak / ring / neck / trinket) - not armor-type restricted,
-- so any character on the account can attune them.
-- ---------------------------------------------------------------------
local ACCESSORY_LOC = {
    INVTYPE_CLOAK = true, INVTYPE_FINGER = true,
    INVTYPE_NECK = true, INVTYPE_TRINKET = true,
}

function ANx.InvalidateAccessoryCache()
    ANx.FlagClearAll(ANx.F_ACC, 3)
end

-- true if the item is a cloak/ring/neck/trinket. Static seed first, else the
-- item's equip location (needs the item cached; cached "no" once resolved).
function ANx.IsAccessory(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, 5), 3) or 0    -- F_ACC == 5
    if c ~= 0 then return c == 2 end
    if ANx.AccessoryItems and ANx.AccessoryItems[itemId] then
        ANx.FlagSet(itemId, ANx.F_ACC, 3, 2); return true
    end
    local loc
    if GetItemInfoCustom then loc = select(9, GetItemInfoCustom(itemId)) end
    if (not loc or loc == "") and GetItemInfo then loc = select(9, GetItemInfo(itemId)) end
    if not loc or loc == "" then
        ANx.FlagSet(itemId, ANx.F_ACC, 3, 1)  -- uncached; assume not-accessory (safe: don't hide)
        return false
    end
    local r = ACCESSORY_LOC[loc] == true
    ANx.FlagSet(itemId, ANx.F_ACC, 3, r and 2 or 1)
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
-- Prestige: which class can use an item?
-- After prestiging, a character attunes as TWO classes at once, so the
-- Class filter chip (unlocked by the Prestige mode option) lets you look at
-- one class's gear at a time. "Class-appropriate" means: the armor types the
-- class wears (cloaks and misc/accessories count for everyone), the weapon
-- types it can learn, its own relic, and any explicit "Classes: ..." lock on
-- the tooltip (which always wins - tier pieces etc.). Anything the client
-- doesn't know yet passes, so the filter never hides items by accident.
-- ---------------------------------------------------------------------
ANx.CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
                    "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
ANx.CLASS_LABELS = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
    PRIEST = "Priest", DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman",
    MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
ANx.CLASS_HEX = {  -- standard class colors
    WARRIOR = "c79c6e", PALADIN = "f58cba", HUNTER = "abd473", ROGUE = "fff569",
    PRIEST = "ffffff", DEATHKNIGHT = "c41f3b", SHAMAN = "0070de",
    MAGE = "69ccf0", WARLOCK = "9482c9", DRUID = "ff7d0a",
}

local function ClassSet(...)
    local t = {}
    for _, c in ipairs({ ... }) do t[c] = true end
    return t
end

-- Armor the class actually wears (leveling types included: a DK in mail, a
-- shaman in leather). Cloth is the caster classes' own armor.
local CLASS_ARMOR = {
    Cloth   = ClassSet("PRIEST", "MAGE", "WARLOCK"),
    Leather = ClassSet("ROGUE", "DRUID", "HUNTER", "SHAMAN"),
    Mail    = ClassSet("HUNTER", "SHAMAN", "WARRIOR", "PALADIN", "DEATHKNIGHT"),
    Plate   = ClassSet("WARRIOR", "PALADIN", "DEATHKNIGHT"),
    Shields = ClassSet("WARRIOR", "PALADIN", "SHAMAN"),
    Librams = ClassSet("PALADIN"),
    Idols   = ClassSet("DRUID"),
    Totems  = ClassSet("SHAMAN"),
    Sigils  = ClassSet("DEATHKNIGHT"),
    -- Miscellaneous (rings, trinkets, necks, held items, shirts): everyone
}

-- "Can equip" mode: the four armor materials loosen to physical equip rules
-- (anyone can wear lower armor - a warrior CAN equip cloth). Shields, relics,
-- weapons and tooltip locks are hard restrictions and stay strict.
local CLASS_ARMOR_EQUIP = {
    Cloth   = ClassSet("WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
                       "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID"),
    Leather = ClassSet("WARRIOR", "PALADIN", "HUNTER", "ROGUE",
                       "DEATHKNIGHT", "SHAMAN", "DRUID"),
    Mail    = ClassSet("WARRIOR", "PALADIN", "HUNTER", "SHAMAN", "DEATHKNIGHT"),
    Plate   = ClassSet("WARRIOR", "PALADIN", "DEATHKNIGHT"),
}

-- Weapon skills each class can learn (3.3.5 trainers, max)
local CLASS_WEAPON = {
    ["Daggers"]           = ClassSet("WARRIOR", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"),
    ["Fist Weapons"]      = ClassSet("WARRIOR", "HUNTER", "ROGUE", "SHAMAN", "DRUID"),
    ["One-Handed Axes"]   = ClassSet("WARRIOR", "PALADIN", "HUNTER", "ROGUE", "SHAMAN", "DEATHKNIGHT"),
    ["Two-Handed Axes"]   = ClassSet("WARRIOR", "PALADIN", "HUNTER", "SHAMAN", "DEATHKNIGHT"),
    ["One-Handed Maces"]  = ClassSet("WARRIOR", "PALADIN", "ROGUE", "PRIEST", "SHAMAN", "DRUID", "DEATHKNIGHT"),
    ["Two-Handed Maces"]  = ClassSet("WARRIOR", "PALADIN", "SHAMAN", "DRUID", "DEATHKNIGHT"),
    ["One-Handed Swords"] = ClassSet("WARRIOR", "PALADIN", "HUNTER", "ROGUE", "MAGE", "WARLOCK", "DEATHKNIGHT"),
    ["Two-Handed Swords"] = ClassSet("WARRIOR", "PALADIN", "HUNTER", "DEATHKNIGHT"),
    ["Polearms"]          = ClassSet("WARRIOR", "PALADIN", "HUNTER", "DRUID", "DEATHKNIGHT"),
    ["Staves"]            = ClassSet("WARRIOR", "HUNTER", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"),
    ["Bows"]              = ClassSet("WARRIOR", "HUNTER", "ROGUE"),
    ["Guns"]              = ClassSet("WARRIOR", "HUNTER", "ROGUE"),
    ["Crossbows"]         = ClassSet("WARRIOR", "HUNTER", "ROGUE"),
    ["Thrown"]            = ClassSet("WARRIOR", "HUNTER", "ROGUE"),
    ["Wands"]             = ClassSet("PRIEST", "MAGE", "WARLOCK"),
    -- Fishing Poles / Miscellaneous: everyone
}

-- Reverse map: localized class name (tooltip text) -> class token. Works on
-- any client locale via the game's own LOCALIZED_CLASS_NAMES tables.
local classNameToToken
local function ClassToken(name)
    if not classNameToToken then
        classNameToToken = {}
        for _, tbl in ipairs({ _G.LOCALIZED_CLASS_NAMES_MALE, _G.LOCALIZED_CLASS_NAMES_FEMALE }) do
            if type(tbl) == "table" then
                for token, localized in pairs(tbl) do
                    classNameToToken[localized] = token
                end
            end
        end
        for token, label in pairs(ANx.CLASS_LABELS) do   -- English fallback
            classNameToToken[label] = classNameToToken[label] or token
        end
    end
    return classNameToToken[name]
end

-- The "Classes: X, Y" tooltip lock, as a token set; false = no lock;
-- nil = not resolvable yet (item not in the client cache).
local classLockCache = {}
local classLockPattern
function ANx.ClassLock(itemId)
    local c = classLockCache[itemId]
    if c ~= nil then return c or nil end
    if not CreateFrame then return nil end
    if not bindTip then
        bindTip = CreateFrame("GameTooltip", "AttuneNextBindTip", nil, "GameTooltipTemplate")
        bindTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    bindTip:ClearLines()
    perf.tipClass = perf.tipClass + 1
    local ok = pcall(bindTip.SetHyperlink, bindTip, "item:" .. itemId)
    if not ok then return nil end
    local n = bindTip:NumLines()
    if not n or n == 0 then perf.tipEmpty = perf.tipEmpty + 1 return nil end   -- not cached yet; retry later
    if not classLockPattern then
        -- the client's own (localized) "Classes: %s" format, as a pattern
        local fmt = _G.ITEM_CLASSES_ALLOWED or "Classes: %s"
        classLockPattern = "^" .. fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
                                     :gsub("%%%%s", "(.+)")
    end
    local lock = false
    for i = 1, n do
        local fs = _G["AttuneNextBindTipTextLeft" .. i]
        local t = fs and fs:GetText()
        local names = t and t:match(classLockPattern)
        if names then
            for name in names:gmatch("([^,]+)") do
                local token = ClassToken(name:match("^%s*(.-)%s*$"))
                if token then
                    if not lock then lock = {} end
                    lock[token] = true
                end
            end
            break
        end
    end
    classLockCache[itemId] = lock
    return lock or nil
end

-- Can gear of this item's kind be used by `token`? (see block comment above)
function ANx.ItemUsableByClass(itemId, token)
    if not token or token == "all" then return true end
    local lock = ANx.ClassLock(itemId)
    if lock then return lock[token] == true end
    local _, _, _, _, _, itype, isub, _, equipLoc = _G.GetItemInfo(itemId)
    if not itype then return true end            -- unknown: never hide
    if equipLoc == "INVTYPE_CLOAK" then return true end
    if itype == "Armor" then
        local set = CLASS_ARMOR[isub]
        if set and (ANx.db and ANx.db.classFilterMode) == "equip" then
            set = CLASS_ARMOR_EQUIP[isub] or set   -- materials loosen; shields/relics stay
        end
        if set then return set[token] == true end
        return true                              -- Miscellaneous / unknown subtype
    end
    if itype == "Weapon" then
        local set = CLASS_WEAPON[isub]
        if set then return set[token] == true end
        return true                              -- fishing poles / misc
    end
    return true
end

function ANx.InvalidateClassLockCache()
    classLockCache = {}
    classNameToToken = nil
end

-- ---------------------------------------------------------------------
-- Item faction ("A"/"H"/nil) - static seed first, else read the item's
-- race restriction from its tooltip (covers raid/dungeon drops the vendor
-- seed doesn't have, e.g. faction-locked Trial of the Crusader loot).
-- ---------------------------------------------------------------------
local ALLIANCE_RACES = { "Human", "Dwarf", "Night Elf", "Gnome", "Draenei", "Worgen" }
local HORDE_RACES    = { "Orc", "Scourge", "Undead", "Tauren", "Troll", "Blood Elf", "Goblin" }
local factionTip
local FAC_NAME = { [2] = "A", [3] = "H" }   -- flag code -> side (1 = neutral)

function ANx.InvalidateFactionCache()
    ANx.FlagClearAll(ANx.F_FAC, 3)
end

function ANx.ItemFactionOf(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, 3), 3) or 0    -- F_FAC == 3
    if c ~= 0 then return FAC_NAME[c] end         -- 1 = resolved, neutral/unknown
    local seed = ANx.ItemFaction and ANx.ItemFaction[itemId]   -- optional override table
    if not seed and ANx.ItemFactionPacked then
        local side = ANx.PackedFind(ANx.ItemFactionPacked, itemId, 1)
        seed = (side == 1 and "A") or (side == 2 and "H") or nil
    end
    if seed then
        ANx.FlagSet(itemId, ANx.F_FAC, 3, seed == "A" and 2 or 3)
        return seed
    end
    if not CreateFrame then return nil end
    if not factionTip then
        factionTip = CreateFrame("GameTooltip", "AttuneNextFactionTip", nil, "GameTooltipTemplate")
        factionTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    factionTip:ClearLines()
    perf.tipFac = perf.tipFac + 1
    local ok = pcall(factionTip.SetHyperlink, factionTip, "item:" .. itemId)
    if not ok then return nil end
    local n = factionTip:NumLines()
    if not n or n == 0 then perf.tipEmpty = perf.tipEmpty + 1 return nil end        -- not cached yet; retry later
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
    ANx.FlagSet(itemId, ANx.F_FAC, 3, result == "A" and 2 or result == "H" and 3 or 1)
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

-- Which side can do this quest? "A"/"H", or nil for both/unknown. Derived
-- from the quest's DBC race mask (Data_QuestReq) - a quest only Horde races
-- can take IS a Horde quest. An optional ANx.QuestFaction override table is
-- consulted first (the shipped copy was deleted: it was 100% derivable).
local Q_ALLIANCE_MASK = 1 + 4 + 8 + 64 + 1024      -- Human/Dwarf/NElf/Gnome/Draenei
local Q_HORDE_MASK    = 2 + 16 + 32 + 128 + 512    -- Orc/Undead/Tauren/Troll/Belf

-- Which side is the PLAYER on? ("A"/"H", from their race)
function ANx.PlayerFactionSide()
    local m = ANx.PlayerRaceMask()
    if m == 0 then return nil end
    if bit.band(m, Q_ALLIANCE_MASK) ~= 0 then return "A" end
    if bit.band(m, Q_HORDE_MASK) ~= 0 then return "H" end
    return nil
end

-- DBC race/class mask for a quest, from the packed palette encoding in
-- Data_QuestReq (nil = no restriction of that kind).
function ANx.QuestRaceMaskOf(questId)
    local i = ANx.QuestRacesPacked and ANx.PackedFind(ANx.QuestRacesPacked, questId, 2)
    return i and ANx.QuestRaceMasks and ANx.QuestRaceMasks[i] or nil
end

function ANx.QuestClassMaskOf(questId)
    local i = ANx.QuestClassesPacked and ANx.PackedFind(ANx.QuestClassesPacked, questId, 2)
    return i and ANx.QuestClassMasks and ANx.QuestClassMasks[i] or nil
end

-- Decode a QuestGivers value ("zoneAreaId:x10:y10:name", Data_QuestGivers)
-- -> zoneAreaId, x*10, y*10, giverName. nil when the quest has no giver.
function ANx.QuestGiver(qid)
    local e = ANx.QuestGivers and ANx.QuestGivers[qid]
    if not e then return nil end
    local zone, x, y, name = e:match("^(%d+):(%d+):(%d+):(.*)$")
    if not zone then return nil end
    if name == "" then name = nil end
    return tonumber(zone), tonumber(x), tonumber(y), name
end

-- Decode a VendorLocs value ("zoneAreaId:x10:y10", Data_VendorLocs)
-- -> zoneAreaId, x*10, y*10.
function ANx.VendorLoc(npcId)
    local e = npcId and ANx.VendorLocs and ANx.VendorLocs[npcId]
    if not e then return nil end
    local zone, x, y = e:match("^(%d+):(%d+):(%d+)$")
    if not zone then return nil end
    return tonumber(zone), tonumber(x), tonumber(y)
end

-- Quest name from the packed name blobs (Data_QuestGivers). Only needed for
-- click-time chat/arrow labels, so an O(n) scan of a few big strings replaces
-- a ~440 KB always-resident hash. QuestNamesExtra (dropped-item starters from
-- Data_QuestItemStarts) is the fallback, matching the old merge precedence.
function ANx.QuestNameOf(qid)
    local blobs = ANx.QuestNameBlobs
    if blobs then
        local pat = "\n" .. qid .. "=([^\n]*)"
        for i = 1, #blobs do
            local n = blobs[i]:match(pat)
            if n then return n end
        end
    end
    return ANx.QuestNamesExtra and ANx.QuestNamesExtra[qid] or nil
end

function ANx.QuestFactionSide(questId)
    if not questId then return nil end
    local f = ANx.QuestFaction and ANx.QuestFaction[questId]
    if f then return f end
    local r = ANx.QuestRaceMaskOf(questId)
    if not r then return nil end
    local a = bit.band(r, Q_ALLIANCE_MASK) ~= 0
    local h = bit.band(r, Q_HORDE_MASK) ~= 0
    if a and not h then return "A" end
    if h and not a then return "H" end
    return nil
end

-- Node-level faction gate for quests / vendors. kind = "quest" | "vendor".
function ANx.NodeFactionAllowed(kind, id)
    local fac = ANx.db and ANx.db.faction
    if not fac or fac == "both" or not id then return true end
    if kind == "quest" then
        local side = ANx.QuestFactionSide(id)
        return not side or side == fac
    end
    -- a vendor passes unless it belongs to the OTHER side (one packed probe)
    if not ANx.VendorFactionPacked then return true end
    local side = ANx.PackedFind(ANx.VendorFactionPacked, id, 1)
    if not side then return true end                    -- neutral / unlisted
    return (side == 1 and "A" or "H") == fac
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
    if ANx.InvalidateQuestDoable then ANx.InvalidateQuestDoable() end
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

-- Hand-curated masks for quests the generated DB does not know (Synastria's
-- custom quests, e.g. the role-ring trios). Same DBC bitmask format.
--   ANx.QuestClassExtra[questId] = class mask
--   ANx.QuestRaceExtra[questId]  = race mask
ANx.QuestClassExtra = ANx.QuestClassExtra or {}
ANx.QuestRaceExtra = ANx.QuestRaceExtra or {}

-- Can the CURRENT CHARACTER (race + class) ever complete this quest?
-- Unknown quests / missing data count as doable.
-- Memoized: the answer depends only on the quest and this character's fixed
-- race/class, but BestSource asks it for every quest source of every item it
-- ranks - two packed binary searches per ask was measurably hot.
local questDoable = {}

function ANx.InvalidateQuestDoable()
    questDoable = {}
end

function ANx.CharCanDoQuest(questId)
    if not questId then return true end
    local memo = questDoable[questId]
    if memo ~= nil then return memo end
    local ok = true
    local r = ANx.QuestRaceMaskOf(questId) or ANx.QuestRaceExtra[questId]
    if r then
        local pm = ANx.PlayerRaceMask()
        if pm ~= 0 and bit.band(r, pm) == 0 then ok = false end
    end
    if ok then
        local c = ANx.QuestClassMaskOf(questId) or ANx.QuestClassExtra[questId]
        if c then
            local pm = ANx.PlayerClassMask()
            if pm ~= 0 and bit.band(c, pm) == 0 then ok = false end
        end
    end
    questDoable[questId] = ok
    return ok
end

-- Quest-page filter: "mine" (default) hides quests this character can never
-- take; "all" shows everything.
function ANx.QuestForClassAllowed(questId)
    if ANx.db and ANx.db.questClass == "all" then return true end
    return ANx.CharCanDoQuest(questId)
end

-- Quest-node gate: the faction filter. Race/class hiding is the "My quests"
-- filter's job now (ANx.QuestForClassAllowed) - callers apply both, so the
-- All-classes setting can actually reveal quests the old scope gate hid.
function ANx.QuestNodeAllowed(questId)
    return ANx.NodeFactionAllowed("quest", questId)
end

function ANx.IsAttunableAtAll(itemId)
    if not ANx.dataReady then
        local _, sets = SC()
        if sets then return sets.tags[itemId] == true end
    end
    if _G.GetItemTagsCustom then
        local t = _G.GetItemTagsCustom(itemId)
        -- bit 64 = Attunable, bit 32 = Disabled: a disabled item is
        -- unobtainable and must not inflate (account-scope) totals
        if t then return bit.band(t, 64) ~= 0 and bit.band(t, 32) == 0 end
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
            -- rows under a COLLAPSED header vanish from the enumeration, so
            -- temporarily expand collapsed headers and restore them after -
            -- otherwise the Affordable filter reads 0 for those currencies
            local collapsed
            if ExpandCurrencyList then
                local i = 1
                while i <= GetCurrencyListSize() do
                    local cname, isHeader, isExpanded = GetCurrencyListInfo(i)
                    if isHeader and not isExpanded then
                        collapsed = collapsed or {}
                        collapsed[cname or ""] = true
                        ExpandCurrencyList(i, 1)
                    end
                    i = i + 1
                end
            end
            for i = 1, GetCurrencyListSize() do
                local cname, isHeader, _, _, _, count = GetCurrencyListInfo(i)
                if cname and not isHeader then currencyMap[cname] = count or 0 end
            end
            if collapsed and ExpandCurrencyList then
                for i = GetCurrencyListSize(), 1, -1 do
                    local cname, isHeader = GetCurrencyListInfo(i)
                    if isHeader and collapsed[cname or ""] then
                        ExpandCurrencyList(i, 0)
                    end
                end
            end
        end
        currencyMapAt = now
    end
    return currencyMap[name] or 0
end

-- Player's current world position: continent index, zone index, x, y (0..1).
-- Continent/zone indices match GetMapContinents()/GetMapZones() ordering.
-- Cached ~1s: distance sorting used to call this once per row (or per sort
-- COMPARISON in the arrow router) and every call did a SetMapToCurrentZone
-- round trip - which also visibly snaps the user's open world map.
local locC, locZ, locX, locY, locAt = nil, nil, 0, 0, -10

function ANx.InvalidatePlayerLoc()
    locAt = -10
end

function ANx.PlayerLoc()
    local now = (GetTime and GetTime()) or 0
    if now - locAt < 1 then return locC, locZ, locX, locY end
    -- never touch the map while the player is browsing it: SetMapToCurrentZone
    -- yanks an open world map back to the current zone. Serve the last fix.
    if _G.WorldMapFrame and _G.WorldMapFrame.IsShown and _G.WorldMapFrame:IsShown() then
        return locC, locZ, locX, locY
    end
    locAt = now
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
    locC, locZ, locX, locY = c, z, x, y
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
    -- timed: one server call per zone / instance difficulty, untimed until
    -- v3.7.0 and a suspect for the multi-second scan resumes seen in game
    local t0 = PerfClock()
    local r = _G.ItemLocGetAllItemsInZone(zoneId, 0, 0, 1, 1) or {}
    local ms = PerfClock() - t0
    perf.zfN = perf.zfN + 1
    perf.zfMs = perf.zfMs + ms
    if ms > perf.zfMaxMs then perf.zfMaxMs = ms; perf.zfMaxZone = zoneId end
    return r
end

-- All sources of an item: { {srcType, objType, objId, chance, perMille, objName, zoneName, spawned}, ... }
-- lowercased zone names, memoized: there are only a few hundred distinct
-- zone strings but hundreds of thousands of source rows, so calling :lower()
-- per row during the warmup was pure waste
local zoneLowerCache = {}
local function ZoneLower(zoneName)
    if not zoneName or zoneName == "" then return "" end
    local l = zoneLowerCache[zoneName]
    if not l then
        l = zoneName:lower()
        zoneLowerCache[zoneName] = l
    end
    return l
end

ANx.ZoneLower = ZoneLower   -- shared with Engine's streaming row walks

function ANx.GetSources(itemId)
    if not ANx.LootDbLoaded() then return {} end
    local n = _G.ItemLocGetSourceCount(itemId)
    perf.gsCalls = perf.gsCalls + 1
    if not n or n == 0 then perf.gsEmpty = perf.gsEmpty + 1 return {} end
    perf.gsRows = perf.gsRows + n
    if n > perf.gsMaxRows then perf.gsMaxRows = n; perf.gsMaxItem = itemId end
    local out = {}
    for i = 1, n do
        local srcType, objType, objId, chance, perMille, objName, zoneName, spawned = _G.ItemLocGetSourceAt(itemId, i)
        if srcType ~= nil then
            out[#out + 1] = {
                srcType = srcType, objType = objType, objId = objId,
                chance = chance or 0, perMille = perMille,
                objName = objName or "?", zoneName = zoneName or "",
                -- pre-lowered once here (memoized): zone matching used to
                -- allocate two lowered strings per comparison in hot loops
                zoneLower = ZoneLower(zoneName),
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
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
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
        -- keep next login's snapshot fresh: four client calls per universe
        -- item, 60-200 ms in one frame when run inline, so it runs as a
        -- yielding pump job (the logout export stays synchronous)
        ANx.Engine.Enqueue(ANx.ExportStatusCache, nil, "status-export")
        ANx.Toast("AttuneNext data has been refreshed.")
        return
    end
    ANx.After(1, WatchRefreshDone, "WatchRefreshDone")
end

-- Global function invoked by the Synastria client when server data is fully loaded.
-- Both the SynastriaSafeInvoke queue and the login poll below can call this;
-- collapse near-simultaneous duplicates while still honoring later re-pushes.
local lastDataReadyAt = 0
function AttuneNext_OnDataReady()
    local now = (GetTime and GetTime()) or 0
    if ANx.dataReady and (now - lastDataReadyAt) < 10 then return end
    lastDataReadyAt = now
    TryInit()
    ANx.dataReady = true
    perf.readyAt = GetTime()
    perf.readyN = perf.readyN + 1
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
        if ANx.Plates and ANx.Plates.OnDataReady then ANx.Plates.OnDataReady() end
        ANx.After(2, WatchRefreshDone, "WatchRefreshDone")
    end
    if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    -- alt awareness: snapshot what this character can attune (background)
    if ANx.SnapshotAltCan then ANx.After(8, ANx.SnapshotAltCan, "SnapshotAltCan") end
    -- one-time SavedVariables trim (needs live attunable data)
    if ANx.TrimMerchantDb then ANx.After(15, ANx.TrimMerchantDb, "TrimMerchantDb") end
    -- on-screen goal window
    if ANx.GoalHudUpdate then ANx.After(6, ANx.GoalHudUpdate, "GoalHudUpdate") end
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
                r.focus, r.dropRate = a.focus, a.dropRate
            end
        end
        if ANx.InitSettings then ANx.InitSettings() end
        if ANx.Plates and ANx.Plates.Init then ANx.Plates.Init() end

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
            if typeId == 11 then -- ATTUNE_HAS: fires on EVERY progress tick
                if ANx.OnAttuneCompleted then ANx.OnAttuneCompleted(id) end
                -- stats/marks only change when an item CROSSES 100%: run the
                -- cache-wiping paths on completion only. A mere progress tick
                -- (roughly every kill while wearing attuning gear) just
                -- refreshes the visible window, throttled, with caches intact.
                local done = (not id) or (ANx.Progress(id) or 0) >= 100
                if done then
                    ANx.MarkAttuneDirty()
                    if ANx.Plates then ANx.Plates.OnAttune() end
                    if ANx.ZoneWatchUpdate then ANx.ZoneWatchUpdate(false) end
                    if ANx.GoalHudUpdate then ANx.GoalHudUpdate() end
                else
                    ANx.MarkProgressDirty()
                end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        if _G.SynastriaSafeInvoke then
            _G.SynastriaSafeInvoke("AttuneNext_OnDataReady")
        end
        -- ALWAYS also poll: the SynastriaSafeInvoke queue has historically been
        -- cleared on /reload, which would otherwise leave the addon stuck
        -- serving the stale status cache all session. The guard in
        -- AttuneNext_OnDataReady collapses a double fire.
        local tries = 0
        local function poll()
            if ANx.dataReady then return end
            tries = tries + 1
            if _G.GetCustomGameData then
                if _G.GetCustomGameData(41, 0) ~= 0 then
                    AttuneNext_OnDataReady()
                elseif tries <= 600 then
                    ANx.After(1, poll, "login-poll")
                end
            elseif tries > 20 then
                AttuneNext_OnDataReady()   -- non-Synastria client: init anyway
            else
                ANx.After(1, poll, "login-poll")
            end
        end
        poll()
    elseif event == "MERCHANT_SHOW" then
        if ANx.ScanMerchant then ANx.After(0.2, ANx.ScanMerchant, "ScanMerchant") end
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
        if ANx.QueueTradeSkillScan then ANx.QueueTradeSkillScan() end
    elseif event == "BAG_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED"
        or event == "PLAYER_EQUIPMENT_CHANGED" then
        -- the What's Left materials screen nets out your stock; keep it fresh
        if event ~= "PLAYER_EQUIPMENT_CHANGED" and ANx.UI and ANx.UI.RefreshMats then
            ANx.UI.RefreshMats()
        end
        -- with "Hide in bags" on, what you carry IS a filter: recount once the
        -- burst of bag events settles (looting fires one per stack moved)
        if ANx.db and ANx.db.hideInBags and ANx.Engine then
            ANx.Engine.InvalidateOwned()
            if not ANx.ownedRefreshPending then
                ANx.ownedRefreshPending = true
                ANx.After(0.5, function()
                    ANx.ownedRefreshPending = nil
                    ANx.Engine.InvalidateOwned()
                    ANx.Engine.InvalidateStats()
                    if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
                end, "bags-refresh")
            end
        end
    elseif event == "LOOT_OPENED" then
        if ANx.CheckLootWindow then ANx.CheckLootWindow() end
    elseif event == "START_LOOT_ROLL" then
        if ANx.CheckLootRoll then ANx.CheckLootRoll(arg1) end
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        if ANx.InvalidatePlayerLoc then ANx.InvalidatePlayerLoc() end
        if ANx.UpdateCurrentInstance then ANx.UpdateCurrentInstance() end
        if ANx.ZoneWatchUpdate then ANx.ZoneWatchUpdate(true) end
        if ANx.ScanSpeedAuras then ANx.After(2, ANx.ScanSpeedAuras, "ScanSpeedAuras") end
        if ANx.Plates then ANx.Plates.OnZone() end
    elseif event == "UNIT_AURA" then
        -- debounced: in instanced combat this fires several times per second,
        -- and each scan is an Instances sweep + up-to-40 UnitBuff loop + a
        -- tooltip scrape for values that only change on new records
        if arg1 == "player" and ANx.QueueSpeedAuraScan then ANx.QueueSpeedAuraScan() end
    elseif event == "PLAYER_LEVEL_UP" then
        -- the level filters compare against the character's level
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.Plates then ANx.Plates.Invalidate() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    elseif event == "PLAYER_LOGOUT" then
        if ANx.Engine then pcall(ANx.Engine.ExportCache) end
        pcall(ANx.ExportStatusCache)
    elseif event == "PLAYER_MONEY" or event == "CURRENCY_DISPLAY_UPDATE" then
        ANx.InvalidatePlayerCurrency()
        -- coalesced: while farming, every coin looted fires this (bursts per
        -- second); the old code wiped every stat cache + re-rendered per event
        if ANx.db and ANx.db.affordableOnly then ANx.MarkMoneyDirty() end
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
    end, "attune-dirty")
end

-- Debounced light refresh for mere attune-progress ticks (no cache wipe:
-- progress text re-reads the live APIs anyway)
local progPending = false
function ANx.MarkProgressDirty()
    if progPending then return end
    progPending = true
    ANx.After(2, function()
        progPending = false
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end, "progress-tick")
end

-- Debounced stats invalidation for money/currency changes (affordable filter)
local moneyPending = false
function ANx.MarkMoneyDirty()
    if moneyPending then return end
    moneyPending = true
    ANx.After(2, function()
        moneyPending = false
        if ANx.db and ANx.db.affordableOnly then
            if ANx.Engine then ANx.Engine.InvalidateStats() end
            if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
        end
    end, "money-dirty")
end

-- Debounced speed-aura scan (UNIT_AURA storms in combat)
local speedScanPending = false
function ANx.QueueSpeedAuraScan()
    if speedScanPending then return end
    speedScanPending = true
    ANx.After(2, function()
        speedScanPending = false
        if ANx.ScanSpeedAuras then ANx.ScanSpeedAuras() end
    end, "speed-aura")
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
    elseif msg == "plates" then
        local m = ANx.db.plates.mode
        ANx.db.plates.mode = (m == "off" and "on") or (m == "on" and "filters") or "off"
        ANx.Print("Nameplates: |cffffff00" .. ({ off = "Off", on = "On (everything unattuned)",
            filters = "Respect window filters" })[ANx.db.plates.mode] .. "|r")
        if ANx.Plates then ANx.Plates.Invalidate() end
        if ANx.SyncOptionsPanel then ANx.SyncOptionsPanel() end
    elseif msg == "perf" then
        local st = ANx.Engine and ANx.Engine.PerfStats and ANx.Engine.PerfStats()
        if st then
            ANx.Print(string.format("Lua memory: |cffffff00%d KB|r   background jobs: %d   caches %s",
                st.lua_kb, st.jobs, st.warm and "|cff00ff00warm|r" or "|cffffd100warming|r"))
            ANx.Print(string.format("caches: sources=%d  stats=%d  zones=%d  runs=%d  picks=%d  odds=%d",
                st.srcCache, st.stats, st.zones, st.runsKeys, st.pickKeys, st.clearChance))
            ANx.Print(string.format("fps %.0f  universe %d  flags %d  data-ready x%d; scan: summaries %.1fs, idle %.1fs after data-ready",
                (GetFramerate and GetFramerate()) or 0, st.universe, st.flags, st.readyN, st.summariesS, st.idleS))
            ANx.Print(string.format("pump: %d frames, %.0fms (max %.1fms in %s, %d over %dms); resume max %.1fms in %s; gc step %.0fms (max %.1fms)",
                st.pumpFrames, st.pumpMs, st.pumpMaxMs, st.pumpMaxTag, st.pumpOver, st.budget * 2,
                st.resumeMaxMs, st.resumeMaxTag, st.gcMs, st.gcMaxMs))
            ANx.Print(string.format("sources: GetSources %d calls (%d empty) / %d rows, biggest %d rows (item %d); srcCache %d items / %d rows, %d flushes, %d too big",
                st.gsCalls, st.gsEmpty, st.gsRows, st.gsMaxRows, st.gsMaxItem, st.srcCache, st.srcRows, st.srcFlush, st.srcTooBig))
            ANx.Print(string.format("zones: %d items classified, %d by fallback, %d recognised-unmatched; unknown names: %s; zones with no match: %s",
                st.zoneItems, st.zoneFallback, st.zoneUnmatched, st.unknownZones, st.unmatchedZones))
            ANx.Print(string.format("client: tooltip scans bind %d / class %d / faction %d (empty %d), cache requests %d, GetItemCount %d",
                st.tipBind, st.tipClass, st.tipFac, st.tipEmpty, st.cacheReq, st.ownedCalls))
            ANx.Print(string.format("timers: %d callbacks, %.0fms, slowest %.1fms (%s); exports: struct %.0fms, status %.0fms x%d",
                st.afterN, st.afterMs, st.afterMaxMs, st.afterMaxName, st.exportMs, st.statusExportMs, st.statusExportN))
            ANx.Print(string.format("zone fetches: %d calls, %.0fms, max %.1fms (zone %s); longest resume ended at '%s', Lua %d KB -> %d KB; peak Lua %d KB during %s",
                st.zfN, st.zfMs, st.zfMaxMs, tostring(st.zfMaxZone), st.resumeMaxSite, st.resumeMaxKbIn, st.resumeMaxKbOut, st.peakKb, st.peakTag))
            ANx.Print(string.format("streaming: %d source rows read without tables, %d items memoized for the scan",
                st.rowReads, st.memoItems))
            collectgarbage("collect")
            ANx.Print(string.format("after GC: |cffffff00%d KB|r", math.floor(collectgarbage("count"))))
        end
    elseif msg == "perf reset" then
        if ANx.Engine and ANx.Engine.PerfReset then ANx.Engine.PerfReset() end
        ANx.Print("perf counters reset")
    elseif msg == "srcstats" then
        if ANx.Engine and ANx.Engine.SourceStats then ANx.Engine.SourceStats() end
    elseif msg == "flush" then
        local before = math.floor(collectgarbage("count"))
        if ANx.Engine and ANx.Engine.FlushSources then ANx.Engine.FlushSources() end
        collectgarbage("collect")
        local after = math.floor(collectgarbage("count"))
        ANx.Print(string.format("Flushed the source cache: |cffffff00%d KB|r -> |cff00ff00%d KB|r (freed %d KB).",
            before, after, before - after))
    elseif msg == "plates report" then
        if ANx.Plates then ANx.Plates.Report() end
    elseif msg == "plates why" then
        if ANx.Plates then ANx.Plates.Why() end
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
        ANx.Print("commands: /an (open), /an browse (simple window), /an settings, /an minimap, /an hud, /an unskinned, /an times [reset], /an timemode <mode>, /an plates, /an perf [reset], /an srcstats, /an flush, /an src <itemId>, /an scale <n>, /an reset, /an debug")
    else
        if ANx.UI then ANx.UI.Toggle() end
    end
end
