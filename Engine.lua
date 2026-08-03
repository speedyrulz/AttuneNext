-- =========================================================================
-- AttuneNext - Engine.lua
-- Structural scanning of the server loot DB, classification of item
-- sources, attunement stat computation and caching.
-- =========================================================================
local ADDON_NAME, ANx = ...
local Engine = {}
ANx.Engine = Engine

-- ---------------------------------------------------------------------
-- Caches
-- ---------------------------------------------------------------------
local instDiffCache = {}   -- ["map:diff"]    -> { itemIds }
local instResolved  = {}   -- [instTableRef]  -> { {label, diff, items}, ... }
local zoneCache     = {}   -- [zoneId]        -> { universe, quest, questList, world, vendor, vendorByName }
local srcCache      = {}   -- [itemId]        -> sources array
local zexCache      = {}   -- [itemId]        -> bool: drops in exactly one zone
local limitedItemsSet      -- set of itemIds limited-stock at some vendor (lazy)
local eventItemsCache = {} -- [eventName]     -> { itemIds }
local profCache     = {}   -- [prof.."-"..exp]-> { entries = { {id, spell, skill, srcType} } }
local statsCache    = {}   -- [key]           -> { attuned=, total= , best= {id, chance, srcName} }
local summaryCache  = {}   -- [exp]           -> { D=set, R=set, Q=set, W=set, V=set, C=set, ready=bool }
local remainingCache       -- "What's Left" report (lazy; nil = rebuild)
local clearChanceCache = {} -- ["item|zone"]  -> per-clear drop chance
local runsCache = {}       -- ["mode|ctx"]   -> { rev =, runs = }
local pickCache = {}       -- ["which|view"] -> { rev =, id = itemId or false }
local cacheDirty = false   -- structural data changed since the last export

-- Bumped whenever anything that affects counts changes (filters, attunes,
-- scans). Caches key off it instead of being cleared everywhere by hand.
Engine.rev = 0
local function BumpRev() Engine.rev = Engine.rev + 1 end

function Engine.InvalidateRemaining()
    remainingCache = nil
end

function Engine.InvalidateStats()
    statsCache = {}
    remainingCache = nil
    clearChanceCache = {}
    runsCache = {}
    pickCache = {}
    BumpRev()
end

function Engine.InvalidateAll()
    instDiffCache, instResolved, zoneCache, srcCache, profCache, statsCache, summaryCache =
        {}, {}, {}, {}, {}, {}, {}
    if Engine.InvalidateQuestOnly then Engine.InvalidateQuestOnly() end
    zexCache = {}
    limitedItemsSet = nil
    eventItemsCache = {}
    remainingCache = nil
    clearChanceCache = {}
    runsCache = {}
    pickCache = {}
    BumpRev()
    Engine.universeCache = nil
    Engine.scanJobs = {}
    Engine.scanning = false
end

-- Full attunable item universe for search: union of every instance/zone/
-- profession/vendor-cost item id the addon knows about. Requires the
-- background summaries to be built (returns partial + nil-cached until ready).
function Engine.Universe()
    if Engine.universeCache then return Engine.universeCache, true end
    local set = {}
    local allReady = true
    for exp = 1, 3 do
        local s = summaryCache[exp]
        if s and s.ready then
            for _, cat in ipairs({ "D", "R", "Q", "W", "V", "C" }) do
                for id in pairs(s[cat]) do set[id] = true end
            end
        else
            allReady = false
        end
    end
    if ANx.VendorCosts then
        for id in pairs(ANx.VendorCosts) do set[id] = true end
    end
    for _, id in ipairs(Engine.AllEventItems()) do set[id] = true end
    local arr = {}
    for id in pairs(set) do arr[#arr + 1] = id end
    if allReady then Engine.universeCache = arr end
    return arr, allReady
end

-- ---------------------------------------------------------------------
-- Persistent structural cache (SavedVariables)
-- Structure only - attunement progress is always read live, so cached
-- sessions stay accurate. Invalidated when the server loot-DB version
-- or the addon version changes, or via the Refresh button.
-- ---------------------------------------------------------------------
local function SetToArray(set)
    local a = {}
    for id in pairs(set) do
        if type(id) == "number" then a[#a + 1] = id end
    end
    return a
end

local function ArrayToSet(a)
    local s = {}
    for _, id in ipairs(a) do s[id] = true end
    return s
end

function Engine.ExportCache()
    if not (ANx.db and ANx.LootDbLoaded()) then return end
    local sums = {}
    for exp, sum in pairs(summaryCache) do
        if sum.ready then
            local dl, rl = {}, {}
            for label, set in pairs(sum.Dl or {}) do dl[label] = SetToArray(set) end
            for label, set in pairs(sum.Rl or {}) do rl[label] = SetToArray(set) end
            sums[exp] = {
                D = SetToArray(sum.D), R = SetToArray(sum.R), Q = SetToArray(sum.Q),
                W = SetToArray(sum.W), V = SetToArray(sum.V), C = SetToArray(sum.C),
                Dl = dl, Rl = rl,
            }
        end
    end
    ANx.db.structCache = {
        version = _G.ItemLocIsLoaded(),
        rev = ANx.VERSION,
        inst = instDiffCache,
        zones = zoneCache,
        summaries = sums,
        savedAt = date and date("%Y-%m-%d %H:%M") or "",
    }
end

-- Returns true if a valid cache was restored. `provisional` restores the
-- structure BEFORE the server loot DB is ready (instant UI at login); the
-- normal validated import at data-ready then confirms or rescans.
function Engine.ImportCache(provisional)
    local sc = ANx.db and ANx.db.structCache
    if not sc then return false end
    if sc.rev ~= ANx.VERSION then
        ANx.db.structCache = nil
        return false
    end
    if not provisional and (not ANx.LootDbLoaded() or sc.version ~= _G.ItemLocIsLoaded()) then
        ANx.db.structCache = nil
        return false
    end
    instDiffCache = sc.inst or {}
    zoneCache = sc.zones or {}
    summaryCache = {}
    for exp, sum in pairs(sc.summaries or {}) do
        local dl, rl = {}, {}
        for label, arr in pairs(sum.Dl or {}) do dl[label] = ArrayToSet(arr) end
        for label, arr in pairs(sum.Rl or {}) do rl[label] = ArrayToSet(arr) end
        summaryCache[exp] = {
            D = ArrayToSet(sum.D or {}), R = ArrayToSet(sum.R or {}), Q = ArrayToSet(sum.Q or {}),
            W = ArrayToSet(sum.W or {}), V = ArrayToSet(sum.V or {}), C = ArrayToSet(sum.C or {}),
            Dl = dl, Rl = rl,
            ready = true,
        }
    end
    return true
end

-- Full manual rescan (Refresh button / "/an reset")
function Engine.ForceRescan()
    if ANx.db then ANx.db.structCache = nil end
    if ANx.InvalidateBindCache then ANx.InvalidateBindCache() end
    if ANx.InvalidateAccessoryCache then ANx.InvalidateAccessoryCache() end
    if ANx.InvalidateFactionCache then ANx.InvalidateFactionCache() end
    Engine.InvalidateAll()
end

-- ---------------------------------------------------------------------
-- Background job pump (coroutine based, ~10ms/frame budget)
-- ---------------------------------------------------------------------
Engine.scanJobs = {}
Engine.scanning = false
local pumpFrame = CreateFrame("Frame")
local BUDGET_MS = 10

local function Clock()
    if debugprofilestop then return debugprofilestop() end
    return GetTime() * 1000
end

local yieldCheck = 0
function Engine.MaybeYield()
    yieldCheck = yieldCheck + 1
    if yieldCheck >= 25 then
        yieldCheck = 0
        if coroutine.running() then coroutine.yield() end
    end
end

-- Unconditional yield (safe on the main thread). Use this around chunks of
-- work that are individually expensive - MaybeYield only stops every 25th
-- call, which is far too coarse for "one whole instance" sized steps.
function Engine.YieldNow()
    if coroutine.running() then
        yieldCheck = 0
        coroutine.yield()
    end
end

pumpFrame:SetScript("OnUpdate", function()
    local job = Engine.scanJobs[1]
    if not job then
        Engine.scanning = false
        return
    end
    Engine.scanning = true
    local start = Clock()
    while Clock() - start < BUDGET_MS do
        if coroutine.status(job.co) == "dead" then break end
        local ok, err = coroutine.resume(job.co)
        if not ok then
            ANx.Print("|cffff4040scan error:|r " .. tostring(err))
            break
        end
    end
    if coroutine.status(job.co) == "dead" then
        table.remove(Engine.scanJobs, 1)
        if #Engine.scanJobs == 0 then
            Engine.scanning = false
            -- persist the structural cache ONLY when a scan actually changed
            -- it - re-serializing thousands of ids after every filter click
            -- was a serious source of GC hitches and SavedVariables bloat
            if cacheDirty then
                cacheDirty = false
                pcall(Engine.ExportCache)
            end
            -- keep the button's global pick warm so pressing it is instant
            if Engine.PickCached(nil, "btn") == nil then
                Engine.PickAsync(nil, "btn")
            end
        end
        if job.onDone then pcall(job.onDone) end
        for _, cb in ipairs(job.extra or {}) do pcall(cb) end
    end
end)

function Engine.Enqueue(fn, onDone, tag)
    -- one job per tag: a second caller waiting on the same work gets its
    -- callback chained onto the queued job instead of being dropped
    if tag then
        for _, j in ipairs(Engine.scanJobs) do
            if j.tag == tag then
                if onDone then
                    j.extra = j.extra or {}
                    j.extra[#j.extra + 1] = onDone
                end
                return
            end
        end
    end
    table.insert(Engine.scanJobs, { co = coroutine.create(fn), onDone = onDone, tag = tag })
end

-- ---------------------------------------------------------------------
-- Sources (cached per item)
-- ---------------------------------------------------------------------
function Engine.Sources(itemId)
    local s = srcCache[itemId]
    if not s then
        s = ANx.GetSources(itemId)
        srcCache[itemId] = s
    end
    return s
end

-- true when EVERY source of the item is a quest reward (can't be forged)
local questOnlyCache = {}
function Engine.IsQuestOnly(itemId)
    local v = questOnlyCache[itemId]
    if v == nil then
        local srcs = Engine.Sources(itemId)
        if #srcs == 0 then
            v = false
        else
            v = true
            for _, src in ipairs(srcs) do
                if src.srcType ~= ANx.SRC.QUEST then v = false break end
            end
        end
        questOnlyCache[itemId] = v
    end
    return v
end
function Engine.InvalidateQuestOnly()
    questOnlyCache = {}
end

local function ZoneNameMatch(a, b)
    if not a or not b then return false end
    return a:lower() == b:lower()
end

-- Best source for an item, preferring sources in the given zone name + src filter.
-- Returns chance, sourceName, srcType, restricted(bool), zoneName
-- returns chance, sourceName, srcType, restricted, zoneName, sourceRecord
function Engine.BestSource(itemId, zoneName, srcFilter)
    local best, bestAny
    for _, s in ipairs(Engine.Sources(itemId)) do
        local typeOk = (not srcFilter) or srcFilter[s.srcType]
        if typeOk then
            if (not bestAny) or s.chance > bestAny.chance then bestAny = s end
            if zoneName and ZoneNameMatch(s.zoneName, zoneName) then
                if (not best) or s.chance > best.chance then best = s end
            end
        end
    end
    if best then return best.chance, best.objName, best.srcType, true, best.zoneName, best end
    if bestAny then return bestAny.chance, bestAny.objName, bestAny.srcType, false, bestAny.zoneName, bestAny end
    return nil
end

-- ---------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------
local function FetchInstDiff(map, diff)
    local key = map .. ":" .. diff
    local c = instDiffCache[key]
    if not c then
        c = ANx.ItemsInZone(ANx.BuildMapZoneId(map, diff))
        instDiffCache[key] = c
    end
    return c
end

-- Resolved difficulty list for an instance (applies altDiffs fallback once)
function Engine.InstanceDiffs(inst)
    local r = instResolved[inst]
    if r then return r end
    r = {}
    local total = 0
    for _, d in ipairs(inst.diffs) do
        local items = FetchInstDiff(inst.map, d[2])
        total = total + #items
        r[#r + 1] = { label = d[1], diff = d[2], items = items }
    end
    if total == 0 and inst.altDiffs then
        local r2, total2 = {}, 0
        for _, d in ipairs(inst.altDiffs) do
            local items = FetchInstDiff(inst.map, d[2])
            total2 = total2 + #items
            r2[#r2 + 1] = { label = d[1], diff = d[2], items = items }
        end
        if total2 > 0 then r = r2 end
    end
    instResolved[inst] = r
    return r
end

function Engine.InstancesFor(exp, kind)
    local out = {}
    for _, inst in ipairs(ANx.Instances) do
        if inst.exp == exp and inst.kind == kind then out[#out + 1] = inst end
    end
    return out
end

-- Does this item drop from a rare / rare-elite creature? (optionally in a
-- specific zone). Used by the World Drops "Rares only" filter.
function Engine.ItemHasRareSource(itemId, zoneName)
    if not ANx.RareNPCs then return false end
    for _, s in ipairs(Engine.Sources(itemId)) do
        if (s.srcType == ANx.SRC.CREATURE or s.srcType == ANx.SRC.MYTHIC_CREATURE)
            and s.objId and ANx.RareNPCs[s.objId] then
            if not zoneName or ZoneNameMatch(s.zoneName, zoneName) then
                return true
            end
        end
    end
    return false
end

-- Filter an item list down to those with a rare source (in zoneName if given).
function Engine.FilterRareItems(items, zoneName)
    local out = {}
    for _, id in ipairs(items) do
        if Engine.ItemHasRareSource(id, zoneName) then out[#out + 1] = id end
    end
    return out
end

-- Is this item obtainable ONLY from the given zone (no source anywhere else)?
-- Considers named zones only; empty/Unknown source zones are ignored.
function Engine.ItemIsUniqueToZone(itemId, zoneName)
    if not zoneName then return true end
    local inThisZone = false
    for _, s in ipairs(Engine.Sources(itemId)) do
        local zn = s.zoneName
        if zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            if ZoneNameMatch(zn, zoneName) then
                inThisZone = true
            else
                return false   -- found a source in a different zone
            end
        end
    end
    return inThisZone
end

function Engine.FilterZoneExclusive(items, zoneName)
    local out = {}
    for _, id in ipairs(items) do
        if Engine.ItemIsUniqueToZone(id, zoneName) then out[#out + 1] = id end
    end
    return out
end

-- Global zone-exclusivity: does the item drop in exactly ONE named zone?
-- (For an item in a node's set this is equivalent to "unique to this node".)
function Engine.IsZoneExclusive(itemId)
    local c = zexCache[itemId]
    if c ~= nil then return c end
    local zone, multiple = nil, false
    for _, s in ipairs(Engine.Sources(itemId)) do
        local zn = s.zoneName
        if zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            if zone == nil then zone = zn:lower()
            elseif zone ~= zn:lower() then multiple = true break end
        end
    end
    c = (zone ~= nil) and (not multiple)
    zexCache[itemId] = c
    return c
end

-- Shared item eligibility for counting/listing: character/account can attune it,
-- faction filter passes, and (if the global toggle is on) it's zone-exclusive.
function Engine.Eligible(itemId)
    if not (ANx.CanCount(itemId) and ANx.FactionAllowed(itemId)) then return false end
    if ANx.db and ANx.db.zoneExclusive and not Engine.IsZoneExclusive(itemId) then return false end
    if not ANx.BindAllowed(itemId) then return false end
    if not ANx.AccessoryAllowed(itemId) then return false end
    -- the on-screen Current level filter is a WINDOW filter: with it on, every
    -- list, count and card hides items whose required level the character does
    -- not meet (vendor stock included)
    if ANx.LevelGate and ANx.LevelGate("rec")
        and not Engine.ItemLevelOk(itemId, true) then return false end
    return true
end

-- ---------------------------------------------------------------------
-- Open world zones
-- ---------------------------------------------------------------------
-- Builds and caches the classification for one zone. Safe to call from a
-- coroutine (yields periodically) or synchronously.
function Engine.ZoneData(zoneEntry, inCoroutine)
    local zc = zoneCache[zoneEntry.zone]
    if zc then return zc end

    local universe = ANx.ItemsInZone(zoneEntry.zone)
    zc = {
        universe = universe,
        quest = {},          -- itemIds with a quest source in this zone
        questList = {},      -- { {id=questId, name=questName, items={itemIds}} }
        world = {},          -- itemIds that drop from creatures/objects in this zone
        vendor = {},         -- itemIds sold by vendors in this zone
        vendorByName = {},   -- [vendorName] = { itemIds }
        vendorIdByName = {}, -- [vendorName] = npcId
    }
    local questsById = {}
    for _, itemId in ipairs(universe) do
        if inCoroutine then Engine.MaybeYield() end
        local sources = Engine.Sources(itemId)
        local isQuest, isWorld, isVendor = false, false, false
        for _, s in ipairs(sources) do
            if ZoneNameMatch(s.zoneName, zoneEntry.name) then
                if s.srcType == ANx.SRC.QUEST then
                    isQuest = true
                    local q = questsById[s.objId]
                    if not q then
                        q = { id = s.objId, name = s.objName, items = {} }
                        questsById[s.objId] = q
                        zc.questList[#zc.questList + 1] = q
                    end
                    q.items[#q.items + 1] = itemId
                elseif s.srcType == ANx.SRC.VENDOR then
                    isVendor = true
                    local list = zc.vendorByName[s.objName]
                    if not list then
                        list = {}
                        zc.vendorByName[s.objName] = list
                    end
                    list[#list + 1] = itemId
                    if s.objId and s.objId > 0 and not zc.vendorIdByName[s.objName] then
                        zc.vendorIdByName[s.objName] = s.objId
                    end
                elseif ANx.WORLD_DROP_SRC[s.srcType] then
                    isWorld = true
                end
            end
        end
        if isQuest then zc.quest[#zc.quest + 1] = itemId end
        if isWorld then zc.world[#zc.world + 1] = itemId end
        if isVendor then zc.vendor[#zc.vendor + 1] = itemId end
    end
    table.sort(zc.questList, function(a, b) return (a.name or "") < (b.name or "") end)
    zoneCache[zoneEntry.zone] = zc
    return zc
end

function Engine.ZoneReady(zoneEntry)
    return zoneCache[zoneEntry.zone] ~= nil
end

function Engine.ZonesFor(exp, includeCities, citiesOnlyMode)
    local out = {}
    for _, z in ipairs(ANx.Zones) do
        if z.exp == exp then
            if citiesOnlyMode then
                out[#out + 1] = z
            elseif includeCities or not z.city then
                out[#out + 1] = z
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Holiday / world events
-- ---------------------------------------------------------------------
-- Attunable items obtainable during an event: its boss's loot (pulled live
-- from the loot DB by creature id) plus any fixed `items` list.
function Engine.EventItems(eventEntry)
    local cached = eventItemsCache[eventEntry.name]
    if cached then return cached end
    local set = {}
    if eventEntry.items then
        for _, id in ipairs(eventEntry.items) do
            if ANx.IsAttunableAtAll(id) then set[id] = true end
        end
    end
    if ANx.LootDbLoaded() and _G.ItemLocGetObjCount and _G.ItemLocGetObjAt then
        -- Harvest every item a set of source objects drops. Holiday gear lives on
        -- several kinds of source: the boss creature, but often a loot gameobject
        -- (Ahune's Ice Chest, Noblegarden's Brightly Colored Egg) with its own id.
        local function harvest(ids, objTypes)
            for _, oid in ipairs(ids or {}) do
                for _, objType in ipairs(objTypes) do
                    local cnt = _G.ItemLocGetObjCount(objType, oid)
                    if cnt and cnt > 0 then
                        for i = 1, cnt do
                            local _, itemId = _G.ItemLocGetObjAt(objType, oid, i)
                            if itemId and ANx.IsAttunableAtAll(itemId) then set[itemId] = true end
                        end
                    end
                end
            end
        end
        harvest(eventEntry.npcs, { 0, 20 })   -- creature + mythic-creature loot
        harvest(eventEntry.gos,  { 1, 21 })   -- gameobject + mythic-gameobject loot
    end
    local arr = {}
    for id in pairs(set) do arr[#arr + 1] = id end
    eventItemsCache[eventEntry.name] = arr
    return arr
end

-- Union of every event's items (for the home-menu "Events" row).
function Engine.AllEventItems()
    local set = {}
    for _, e in ipairs(ANx.EventList or {}) do
        for _, id in ipairs(Engine.EventItems(e)) do set[id] = true end
    end
    local arr = {}
    for id in pairs(set) do arr[#arr + 1] = id end
    return arr
end

-- ---------------------------------------------------------------------
-- Professions
-- ---------------------------------------------------------------------
-- A profession screen lists CRAFTED items. Some entries in the profession data
-- merely REQUIRE the profession (e.g. the Light's Hope Chapel "Polar Tunic"
-- quests need Leatherworking 300): their loot-DB source is a quest, not a craft
-- spell, so they belong under Quests, not under Crafting.
function Engine.IsCraftObtained(itemId)
    local sources = Engine.Sources(itemId)
    if #sources == 0 then return true end   -- loot DB gap: benefit of the doubt
    for _, s in ipairs(sources) do
        if s.srcType == ANx.SRC.CRAFT_TRAINER or s.srcType == ANx.SRC.CRAFT_RECIPE then
            return true
        end
    end
    return false
end

function Engine.ProfessionEntries(prof, exp)
    local key = prof .. "-" .. exp
    local c = profCache[key]
    if c then return c end
    c = {}
    local dbReady = ANx.LootDbLoaded()
    local rows = ANx.ProfessionItems and ANx.ProfessionItems[prof]
    if rows then
        for _, row in ipairs(rows) do
            local itemId, spellId, skill, rowExp = row[1], row[2], row[3], row[4]
            if rowExp == exp and ANx.IsAttunableAtAll(itemId)
                and Engine.IsCraftObtained(itemId) then
                c[#c + 1] = { id = itemId, spell = spellId, skill = skill }
            end
        end
        table.sort(c, function(a, b) return a.skill < b.skill end)
    end
    -- don't cache a pre-loot-DB view: sources are empty then, so the craft
    -- filter can't tell crafts from quest turn-ins yet
    if dbReady then profCache[key] = c end
    return c
end

-- ---------------------------------------------------------------------
-- "What's Left" report (totals-only summary + drill-downs)
-- ---------------------------------------------------------------------
-- Is this item still LEFT for the given scope, independent of db.scope?
-- Applies the user's optional filters (faction, zone-exclusive, bind,
-- accessories). "Done" is base attunement - the forge target is intentionally
-- ignored here: this report counts attunes, not forge upgrades.
function Engine.ScopeLeft(itemId, scope)
    if not ANx.IsAttunableAtAll(itemId) then return false end
    if scope == "char" then
        if not ANx.CanCharAttune(itemId) then return false end
        if ANx.IsAttuned(itemId) then return false end
    else
        if ANx.AccountHasVariant(itemId) then return false end
    end
    if not ANx.FactionAllowed(itemId) then return false end
    if ANx.db and ANx.db.zoneExclusive and not Engine.IsZoneExclusive(itemId) then return false end
    if not ANx.BindAllowed(itemId) then return false end
    if not ANx.AccessoryAllowed(itemId) then return false end
    return true
end

-- Full remaining report for both scopes in one pass over the universe:
--   char/acct = { attunes = n, crafted = n, cur = { [currency] = total } }
--   curNames  = currency names sorted by account need (Gold last)
--   curItems  = { char = { [currency] = {ids} }, acct = ... } for drill-downs
--   craftProf = [itemId] = professionName for every craftable
-- Is the What's Left report already built? (cheap check for the UI)
function Engine.RemainingReady()
    return remainingCache ~= nil
end

-- Build it on the background pump, then call back.
function Engine.RemainingAsync(onDone)
    if remainingCache then
        if onDone then onDone(remainingCache) end
        return remainingCache
    end
    Engine.Enqueue(function()
        Engine.RemainingReport(true)
    end, function()
        if onDone then onDone(remainingCache) end
    end, "remaining")
    return nil
end

function Engine.RemainingReport(yielding)
    if remainingCache then return remainingCache end
    local r = {
        char = { attunes = 0, crafted = 0, cur = {} },
        acct = { attunes = 0, crafted = 0, cur = {} },
        curNames = {},
        curItems = { char = {}, acct = {} },
        craftProf = {},
    }
    for _, prof in ipairs(ANx.ProfessionOrder or {}) do
        for exp = 1, 3 do
            if yielding then Engine.MaybeYield() end
            for _, e in ipairs(Engine.ProfessionEntries(prof, exp)) do
                r.craftProf[e.id] = prof
            end
        end
    end
    local universe, ready = Engine.Universe()
    r.ready = ready
    local seenCur = {}
    for _, id in ipairs(universe) do
        if yielding then Engine.MaybeYield() end
        local costs
        for _, scope in ipairs({ "char", "acct" }) do
            if Engine.ScopeLeft(id, scope) then
                local t = r[scope]
                t.attunes = t.attunes + 1
                if r.craftProf[id] then t.crafted = t.crafted + 1 end
                if costs == nil then costs = Engine.ItemCurrencies(id) or false end
                if costs then
                    local li = r.curItems[scope]
                    for _, c in ipairs(costs) do
                        t.cur[c.name] = (t.cur[c.name] or 0) + c.count
                        if not seenCur[c.name] then
                            seenCur[c.name] = true
                            r.curNames[#r.curNames + 1] = c.name
                        end
                        li[c.name] = li[c.name] or {}
                        li[c.name][#li[c.name] + 1] = id
                    end
                end
            end
        end
    end
    table.sort(r.curNames, function(a, b)
        if (a == "Gold") ~= (b == "Gold") then return b == "Gold" end -- Gold last
        local na, nb = r.acct.cur[a] or 0, r.acct.cur[b] or 0
        if na ~= nb then return na > nb end
        return a < b
    end)
    if ready then remainingCache = r end
    return r
end

-- Remaining counts by expansion + content type + events, for one scope.
function Engine.RemainingByCategory(scope)
    local out = { exps = {}, cats = {}, events = 0 }
    for exp = 1, 3 do
        local s = summaryCache[exp]
        local seenExp = {}
        if s then
            for _, cat in ipairs({ "D", "R", "Q", "W", "V", "C" }) do
                local n = 0
                for id in pairs(s[cat] or {}) do
                    if Engine.ScopeLeft(id, scope) then
                        n = n + 1
                        seenExp[id] = true
                    end
                end
                out.cats[cat] = (out.cats[cat] or 0) + n
            end
        end
        local e = 0
        for _ in pairs(seenExp) do e = e + 1 end
        out.exps[exp] = e
    end
    for _, id in ipairs(Engine.AllEventItems()) do
        if Engine.ScopeLeft(id, scope) then out.events = out.events + 1 end
    end
    return out
end

-- Remaining craftable counts per profession (both scopes).
function Engine.RemainingCraftByProf()
    local craftProf = Engine.RemainingReport().craftProf
    local per = {}
    for id, p in pairs(craftProf) do
        local t = per[p]
        if not t then t = { char = 0, acct = 0 }; per[p] = t end
        if Engine.ScopeLeft(id, "char") then t.char = t.char + 1 end
        if Engine.ScopeLeft(id, "acct") then t.acct = t.acct + 1 end
    end
    return per
end

-- Reagent list for a crafted item: a live profession-window scan wins (server
-- truth, covers Synastria custom recipes), else the built-in 3.3.5 craft data.
function Engine.ReagentsOf(itemId)
    local rg = ANx.db and ANx.db.reagents and ANx.db.reagents[itemId]
    if rg then return rg end
    return ANx.Reagents and ANx.Reagents[itemId] or nil
end

-- Items produced per craft (e.g. one smelt yields 2 Bronze Bars). Follows the
-- same precedence as ReagentsOf: for a scanned recipe the scanned output (or 1)
-- applies; otherwise the built-in table.
function Engine.ReagentOutputOf(itemId)
    if ANx.db and ANx.db.reagents and ANx.db.reagents[itemId] then
        return (ANx.db.reagentOutput and ANx.db.reagentOutput[itemId]) or 1
    end
    return (ANx.ReagentOutput and ANx.ReagentOutput[itemId]) or 1
end

-- Everything the CURRENT character has of an item: bags + bank + resource bank.
function Engine.HaveCount(itemId)
    local n = 0
    if _G.GetItemCount then
        local ok, c = pcall(_G.GetItemCount, itemId, true)   -- bags + bank
        if ok and type(c) == "number" then n = n + c end
    end
    if _G.GetCustomGameData then
        local ok, c = pcall(_G.GetCustomGameData, 13, itemId) -- Synastria resource bank
        if ok and type(c) == "number" then n = n + c end
    end
    return n
end

-- Raw materials needed to craft every remaining craftable (optionally one
-- profession). Demands are expanded down the crafting chain to TRUE raw
-- materials (Casing -> Bars -> Ore), and what the current character already
-- has (bags + bank + resource bank) is consumed at every level of the chain.
-- Each scope column is computed with its own copy of your stock.
-- Returns: rows { {id=reagentId, char=n, acct=n} } sorted by account total desc,
--          left { char=n, acct=n } remaining craftables,
--          unscanned { char=n, acct=n } craftables with no reagent data at all.
function Engine.RemainingMaterials(prof)
    local craftProf = Engine.RemainingReport().craftProf
    local mats, left, unscanned = {}, { char = 0, acct = 0 }, { char = 0, acct = 0 }

    local users = {}   -- [rawMaterialId] = { set of remaining gear itemIds that need it }

    -- expand a demand of `count` x item `id` into raw materials, consuming
    -- on-hand stock first; `path` guards against recipe cycles (essences).
    local function expand(out, avail, id, count, path, depth, topId)
        local have = avail[id]
        if have == nil then have = Engine.HaveCount(id); avail[id] = have end
        if have > 0 then
            local use = (have < count) and have or count
            avail[id] = have - use
            count = count - use
            if count == 0 then return end
        end
        local rg = Engine.ReagentsOf(id)
        if not rg or path[id] or depth >= 8 then
            out[id] = (out[id] or 0) + count       -- a true raw material
            local u = users[id]
            if not u then u = {}; users[id] = u end
            u[topId] = true
            return
        end
        local crafts = math.ceil(count / Engine.ReagentOutputOf(id))
        path[id] = true
        for i = 1, #rg - 1, 2 do
            expand(out, avail, rg[i], rg[i + 1] * crafts, path, depth + 1, topId)
        end
        path[id] = nil
    end

    for _, scope in ipairs({ "char", "acct" }) do
        local out, avail = {}, {}
        for id, p in pairs(craftProf) do
            if not prof or p == prof then
                if Engine.ScopeLeft(id, scope) then
                    left[scope] = left[scope] + 1
                    local rg = Engine.ReagentsOf(id)
                    if rg then
                        for i = 1, #rg - 1, 2 do
                            expand(out, avail, rg[i], rg[i + 1], {}, 1, id)
                        end
                    else
                        unscanned[scope] = unscanned[scope] + 1
                    end
                end
            end
        end
        for rid, n in pairs(out) do
            if n > 0 then
                local m = mats[rid]
                if not m then m = { char = 0, acct = 0 }; mats[rid] = m end
                m[scope] = n
            end
        end
    end

    local rows = {}
    for rid, m in pairs(mats) do
        local ulist = {}
        for gid in pairs(users[rid] or {}) do ulist[#ulist + 1] = gid end
        table.sort(ulist)
        rows[#rows + 1] = { id = rid, char = m.char, acct = m.acct, users = ulist }
    end
    table.sort(rows, function(a, b)
        if a.acct ~= b.acct then return a.acct > b.acct end
        if a.char ~= b.char then return a.char > b.char end
        return a.id < b.id
    end)
    return rows, left, unscanned
end

-- ---------------------------------------------------------------------
-- Stats
-- ---------------------------------------------------------------------
-- Character-scope stats for a plain list of itemIds.
-- Returns { attuned=, total= } (cached under key if given)
function Engine.Stats(itemIds, key)
    if key and statsCache[key] then return statsCache[key] end
    local attuned, total = 0, 0
    for _, id in ipairs(itemIds) do
        if Engine.Eligible(id) then
            total = total + 1
            if ANx.CountDone(id) then attuned = attuned + 1 end
        end
    end
    local r = { attuned = attuned, total = total }
    if key then statsCache[key] = r end
    return r
end

-- Stats + best unattuned item (highest drop chance) for a node.
-- zoneName restricts the chance lookup to sources in that zone; srcFilter
-- restricts by source type.
function Engine.StatsWithBest(itemIds, key, zoneName, srcFilter)
    if key and statsCache[key] then return statsCache[key] end
    local attuned, total = 0, 0
    local best
    for _, id in ipairs(itemIds) do
        if Engine.Eligible(id) then
            total = total + 1
            if ANx.CountDone(id) then
                attuned = attuned + 1
            else
                local chance, srcName = Engine.BestSource(id, zoneName, srcFilter)
                if chance and ((not best) or chance > best.chance) then
                    best = { id = id, chance = chance, srcName = srcName }
                end
            end
        end
    end
    local r = { attuned = attuned, total = total, best = best }
    if key then statsCache[key] = r end
    return r
end

-- Detailed remaining-item rows for the item list screens, sorted by chance desc.
-- Visibility is governed by the forge-tier threshold (ANx.db.forge).
-- Returns { {id, chance, srcName, srcType, attuned, tier, acct, progress, srcZone}, ... }
function Engine.ItemRows(itemIds, zoneName, srcFilter)
    local rows = {}
    local seen = {}
    for _, id in ipairs(itemIds) do
        if not seen[id] and Engine.Eligible(id) then
            seen[id] = true
            if ANx.ForgeAllowed(id) then
                local isAtt = ANx.CountAttuned(id)
                local chance, srcName, srcType, _, srcZone = Engine.BestSource(id, zoneName, srcFilter)
                rows[#rows + 1] = {
                    id = id, chance = chance or 0, srcName = srcName,
                    srcType = srcType, attuned = isAtt, srcZone = srcZone,
                    tier = ANx.CurrentTier(id),
                    acct = (not isAtt) and ANx.AccountHasVariant(id) or false,
                    progress = ANx.Progress(id),
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.attuned ~= b.attuned then return not a.attuned end
        return a.chance > b.chance
    end)
    return rows
end

-- ---------------------------------------------------------------------
-- Vendor currency layer (uses merchant scan data from MerchantScan.lua)
-- ---------------------------------------------------------------------
local UNKNOWN_CURRENCY = "Unknown (visit vendor to scan)"
ANx.UNKNOWN_CURRENCY = UNKNOWN_CURRENCY

-- ---------------------------------------------------------------------
-- Vendor stock filtering (all / limited / unlimited)
-- ---------------------------------------------------------------------
-- Item ids that sell with limited stock at *some* vendor (static data), cached.
local function LimitedItems()
    if not limitedItemsSet then
        limitedItemsSet = {}
        if ANx.VendorStock then
            for _, items in pairs(ANx.VendorStock) do
                for itemId in pairs(items) do limitedItemsSet[itemId] = true end
            end
        end
    end
    return limitedItemsSet
end

-- Is this item limited-stock? Exact for a known vendor, else "limited anywhere".
function Engine.ItemIsLimited(itemId, vendorId)
    if vendorId then
        local _, limited = ANx.StockString(itemId, vendorId)
        return limited == true
    end
    if LimitedItems()[itemId] then return true end
    local live = ANx.db and ANx.db.stock and ANx.db.stock[itemId]
    return live ~= nil and live >= 0
end

function Engine.StockMatches(itemId, filter, vendorId)
    filter = filter or "all"
    if filter == "all" then return true end
    local limited = Engine.ItemIsLimited(itemId, vendorId)
    return (filter == "limited") == limited
end

function Engine.FilterByStock(items, filter, vendorId)
    if not filter or filter == "all" then return items end
    local out = {}
    for _, id in ipairs(items) do
        if Engine.StockMatches(id, filter, vendorId) then out[#out + 1] = id end
    end
    return out
end

-- Can the player afford this item right now with any one of its cost variants?
-- Items with no known cost are treated as affordable (not hidden).
function Engine.CanAfford(itemId)
    local all = Engine.ItemAllCosts(itemId)
    if not all then return true end
    for _, cost in ipairs(all) do
        local ok = true
        for _, c in ipairs(cost) do
            if ANx.PlayerCurrency(c.name) < c.count then ok = false break end
        end
        if ok then return true end
    end
    return false
end

function Engine.FilterAffordable(items)
    local out = {}
    for _, id in ipairs(items) do
        if Engine.CanAfford(id) then out[#out + 1] = id end
    end
    return out
end

-- Static costs from Data_VendorCosts.lua, decoded to { {name=,count=}, ... } variants
local function StaticCosts(itemId)
    local raw = ANx.VendorCosts and ANx.VendorCosts[itemId]
    if not raw then return nil end
    local out = {}
    for _, v in ipairs(raw) do
        local cost = {}
        for i = 1, #v - 1, 2 do
            cost[#cost + 1] = {
                name = (ANx.VendorCurrencyNames and ANx.VendorCurrencyNames[v[i]]) or "?",
                count = v[i + 1],
            }
        end
        if #cost > 0 then out[#out + 1] = cost end
    end
    if #out > 0 then return out end
    return nil
end

local function CostSignature(cost)
    local parts = {}
    for _, c in ipairs(cost) do parts[#parts + 1] = c.name .. ":" .. c.count end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- All known ways to buy an item: live merchant scan first (server truth,
-- covers Synastria customs), then static TDB variants (deduped).
function Engine.ItemAllCosts(itemId)
    local out, seen = {}, {}
    local scanned = ANx.db and ANx.db.merchant and ANx.db.merchant[itemId]
    if scanned and #scanned > 0 then
        out[#out + 1] = scanned
        seen[CostSignature(scanned)] = true
    end
    local static = StaticCosts(itemId)
    if static then
        for _, cost in ipairs(static) do
            local sig = CostSignature(cost)
            if not seen[sig] then
                seen[sig] = true
                out[#out + 1] = cost
            end
        end
    end
    if #out > 0 then return out end
    return nil
end

-- Back-compat: primary (scanned or first static) cost variant
function Engine.ItemCurrencies(itemId)
    local all = Engine.ItemAllCosts(itemId)
    return all and all[1] or nil
end

-- Currency category classification (shared by the vendor filter UI)
function Engine.CurrencyCategory(name)
    if name == "Gold" then return "gold" end
    if name == "Honor Points" or name == "Arena Points" then return "points" end
    if name == UNKNOWN_CURRENCY then return "unknown" end
    if name:find("^Emblem") or name:find("^Badge") or name:find("^Mark")
        or name:find("Trophy") or name:find("^Sigil") or name:find("^Splinter")
        or name:find("^Seal") or name:find("^Champion's") then
        return "emblem"
    end
    return "token"
end

-- A zone's vendor items restricted to a currency category ("all" = everything,
-- "unknown" matches items with no cost data).
function Engine.VendorItemsMatchingCategory(zoneEntry, category)
    local zc = Engine.ZoneData(zoneEntry)
    if not category or category == "all" then return zc.vendor end
    local out = {}
    for _, itemId in ipairs(zc.vendor) do
        local all = Engine.ItemAllCosts(itemId)
        if all then
            local hit = false
            for _, cost in ipairs(all) do
                for _, c in ipairs(cost) do
                    if Engine.CurrencyCategory(c.name) == category then
                        hit = true
                        break
                    end
                end
                if hit then break end
            end
            if hit then out[#out + 1] = itemId end
        elseif category == "unknown" then
            out[#out + 1] = itemId
        end
    end
    return out
end

-- Group a zone's vendor items by currency name (an item purchasable with
-- several currencies appears under each). Unknown bucket only for items
-- with no scan AND no static data.
-- Returns array { {name=currencyName, items={itemIds}}, ... } sorted by name,
-- with Unknown last.
function Engine.CurrenciesForZone(zoneEntry)
    local zc = Engine.ZoneData(zoneEntry)
    local byName, order = {}, {}
    local function Bucket(name)
        local bucket = byName[name]
        if not bucket then
            bucket = { name = name, items = {}, seen = {} }
            byName[name] = bucket
            order[#order + 1] = bucket
        end
        return bucket
    end
    for _, itemId in ipairs(zc.vendor) do
        local all = Engine.ItemAllCosts(itemId)
        if all then
            for _, cost in ipairs(all) do
                for _, c in ipairs(cost) do
                    local bucket = Bucket(c.name)
                    if not bucket.seen[itemId] then
                        bucket.seen[itemId] = true
                        bucket.items[#bucket.items + 1] = itemId
                    end
                end
            end
        else
            local bucket = Bucket(UNKNOWN_CURRENCY)
            if not bucket.seen[itemId] then
                bucket.seen[itemId] = true
                bucket.items[#bucket.items + 1] = itemId
            end
        end
    end
    table.sort(order, function(a, b)
        if a.name == UNKNOWN_CURRENCY then return false end
        if b.name == UNKNOWN_CURRENCY then return true end
        return a.name < b.name
    end)
    return order
end

-- Vendors in a zone selling items from the given list.
-- Returns array { {name=vendorName, items={itemIds}}, ... }
function Engine.VendorsForItems(zoneEntry, itemIds)
    local inList = {}
    for _, id in ipairs(itemIds) do inList[id] = true end
    local zc = Engine.ZoneData(zoneEntry)
    local out = {}
    for vendorName, list in pairs(zc.vendorByName) do
        local matched = {}
        for _, id in ipairs(list) do
            if inList[id] then matched[#matched + 1] = id end
        end
        if #matched > 0 then
            out[#out + 1] = { name = vendorName, items = matched,
                id = zc.vendorIdByName and zc.vendorIdByName[vendorName] or nil }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- ---------------------------------------------------------------------
-- Expansion / content summaries (background scanned)
-- ---------------------------------------------------------------------
local function AddSet(set, ids)
    for _, id in ipairs(ids) do set[id] = true end
end

local function BuildSummary(exp)
    local sum = { D = {}, R = {}, Q = {}, W = {}, V = {}, C = {},
                  -- per-difficulty-label dungeon/raid sets (for the difficulty/size filters)
                  Dl = {}, Rl = {} }
    -- dungeons + raids
    for _, kind in ipairs({ "D", "R" }) do
        local labelSets = (kind == "D") and sum.Dl or sum.Rl
        for _, inst in ipairs(Engine.InstancesFor(exp, kind)) do
            for _, d in ipairs(Engine.InstanceDiffs(inst)) do
                Engine.MaybeYield()
                AddSet(sum[kind], d.items)
                labelSets[d.label] = labelSets[d.label] or {}
                AddSet(labelSets[d.label], d.items)
            end
        end
    end
    -- zones (quest + world drops + vendors)
    for _, z in ipairs(Engine.ZonesFor(exp, true)) do
        local zc = Engine.ZoneData(z, true)
        if not z.city then
            AddSet(sum.Q, zc.quest)
            AddSet(sum.W, zc.world)
        end
        AddSet(sum.V, zc.vendor)
        Engine.MaybeYield()
    end
    -- professions
    for _, prof in ipairs(ANx.ProfessionOrder or {}) do
        for _, e in ipairs(Engine.ProfessionEntries(prof, exp)) do
            sum.C[e.id] = true
        end
        Engine.MaybeYield()
    end
    sum.ready = true
    cacheDirty = true
    summaryCache[exp] = sum
end

-- Returns summary sets or nil if still scanning (auto-enqueues the scan)
-- Rough cache/memory accounting for /an perf
function Engine.PerfStats()
    local function count(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end
    return {
        lua_kb = math.floor(collectgarbage("count")),
        srcCache = count(srcCache),
        runsKeys = count(runsCache),
        pickKeys = count(pickCache),
        clearChance = count(clearChanceCache),
        stats = count(statsCache),
        zones = count(zoneCache),
        jobs = #Engine.scanJobs,
    }
end

function Engine.GetSummary(exp, onDone)
    local s = summaryCache[exp]
    if s and s.ready then return s end
    Engine.Enqueue(function() BuildSummary(exp) end, onDone, "summary" .. exp)
    return nil
end

function Engine.SetStats(set, key)
    if key and statsCache[key] then return statsCache[key] end
    local attuned, total = 0, 0
    for id in pairs(set) do
        if type(id) == "number" and Engine.Eligible(id) then
            total = total + 1
            if ANx.CountDone(id) then attuned = attuned + 1 end
        end
    end
    local r = { attuned = attuned, total = total }
    if key then statsCache[key] = r end
    return r
end

function Engine.UnionStats(sets, key)
    if key and statsCache[key] then return statsCache[key] end
    local union = {}
    for _, set in ipairs(sets) do
        for id in pairs(set) do
            if type(id) == "number" then union[id] = true end
        end
    end
    local r = Engine.SetStats(union)
    if key then statsCache[key] = r end
    return r
end

-- The item set for a content category in a summary, honoring the difficulty
-- and raid-size filters for dungeons (D) and raids (R). Others ignore them.
function Engine.ContentSet(sum, cat)
    if not sum then return {} end
    if (cat == "D" or cat == "R") and ANx.DifficultyFilterActive() then
        local labelSets = (cat == "D") and sum.Dl or sum.Rl
        local union = {}
        if labelSets then
            for label, set in pairs(labelSets) do
                if ANx.DifficultyMatches(label) then
                    for id in pairs(set) do union[id] = true end
                end
            end
        end
        return union
    end
    return sum[cat] or {}
end

-- All six content sets for a summary (difficulty-adjusted) - for expansion totals.
function Engine.AllContentSets(sum)
    return {
        Engine.ContentSet(sum, "D"), Engine.ContentSet(sum, "R"),
        sum.Q or {}, sum.W or {}, sum.V or {}, sum.C or {},
    }
end

-- ---------------------------------------------------------------------
-- Context items (for the Random button) - the item universe for a view
-- ---------------------------------------------------------------------
local ZONEMODE_CAT = { Q = "Q", W = "W", V = "V" }

local function AddSetToList(list, seen, set)
    for id in pairs(set) do
        if type(id) == "number" and not seen[id] then seen[id] = true; list[#list + 1] = id end
    end
end

local function AddListToList(list, seen, arr)
    for _, id in ipairs(arr) do
        if not seen[id] then seen[id] = true; list[#list + 1] = id end
    end
end

-- Returns the list of item ids relevant to the current view (its "context").
function Engine.ContextItems(view)
    local list, seen = {}, {}
    if not view then return list end
    local t = view.type

    if t == "items" then
        AddListToList(list, seen, view.items or {})
        return list
    elseif t == "sources" then
        if view.itemId then list[1] = view.itemId end
        return list
    elseif t == "quests" then
        local zc = view.zoneEntry and Engine.ZoneData(view.zoneEntry)
        if zc then AddListToList(list, seen, zc.quest) end
        return list
    elseif t == "currencies" or t == "vendors" then
        local zc = view.zoneEntry and Engine.ZoneData(view.zoneEntry)
        if zc then AddListToList(list, seen, zc.vendor) end
        return list
    elseif t == "events" then
        AddListToList(list, seen, Engine.AllEventItems())
        return list
    elseif t == "instances" then
        local s = summaryCache[view.exp]
        if s then AddSetToList(list, seen, Engine.ContentSet(s, view.kind)) end
        return list
    elseif t == "zones" then
        local cat = ZONEMODE_CAT[view.mode]
        local s = summaryCache[view.exp]
        if s and cat then AddSetToList(list, seen, s[cat] or {}) end
        return list
    elseif t == "profs" then
        local s = summaryCache[view.exp]
        if s then AddSetToList(list, seen, s.C or {}) end
        return list
    elseif t == "content" then
        local s = summaryCache[view.exp]
        if s then for _, set in ipairs(Engine.AllContentSets(s)) do AddSetToList(list, seen, set) end end
        return list
    elseif t == "contentExp" then
        -- a content type chosen, no expansion yet: union that content across expansions
        for exp = 1, 3 do
            local s = summaryCache[exp]
            if s then AddSetToList(list, seen, Engine.ContentSet(s, view.content)) end
        end
        return list
    end

    -- root / home / contentTypes / anything else: the whole known universe
    AddListToList(list, seen, Engine.Universe())
    AddListToList(list, seen, Engine.AllEventItems())
    return list
end

-- ---------------------------------------------------------------------
-- The smart AttuneNext (random) picker
-- ---------------------------------------------------------------------
-- source types that have a real drop rate (exclude vendor/quest/craft)
local DROP_SRC = { [0] = true, [1] = true, [3] = true, [7] = true, [8] = true,
                   [14] = true, [20] = true, [21] = true }

-- best drop chance for an item among its drop-type sources, or nil (no drop rate)
function Engine.ItemBestDropChance(itemId)
    local best
    for _, s in ipairs(Engine.Sources(itemId)) do
        if DROP_SRC[s.srcType] and s.chance and s.chance > 0 then
            if not best or s.chance > best then best = s.chance end
        end
    end
    return best
end

-- reverse profession lookup (itemId -> profession), built lazily
local profOfItem
local function ProfessionOf(itemId)
    if not profOfItem then
        profOfItem = {}
        for prof, rows in pairs(ANx.ProfessionItems or {}) do
            for _, row in ipairs(rows) do profOfItem[row[1]] = prof end
        end
    end
    return profOfItem[itemId]
end

-- "node" bucket key for the focus-most-left option: which zone / instance /
-- profession / currency an item primarily belongs to.
function Engine.ItemBucket(itemId)
    local _, srcName, srcType, _, zone = Engine.BestSource(itemId)
    if srcType == ANx.SRC.VENDOR then
        local costs = Engine.ItemCurrencies(itemId)
        return "$" .. ((costs and costs[1] and costs[1].name) or "Vendor")
    elseif srcType == ANx.SRC.CRAFT_TRAINER or srcType == ANx.SRC.CRAFT_RECIPE then
        return "@" .. (ProfessionOf(itemId) or "Crafting")
    end
    if zone and zone ~= "" and zone ~= "Unknown" then return "#" .. zone end
    return "#" .. (srcName or "Unknown")
end

-- ---------------------------------------------------------------------
-- Current-character-level gates (used by both recommendation features)
-- ---------------------------------------------------------------------
function Engine.InstanceMinLevel(inst)
    return (ANx.InstanceLevels and inst and ANx.InstanceLevels[inst.map]) or 1
end

function Engine.ZoneMinLevel(z)
    return (ANx.ZoneLevels and z and ANx.ZoneLevels[z.zone]) or 1
end

-- nil = the client cannot say (item info unavailable). The level gate treats
-- that as "does not pass": an item we cannot verify must not be recommended,
-- or uncached high-level vendor stock slips straight through the filter.
function Engine.ItemMinLevel(id)
    local name, _, _, _, minLvl = (_G.GetItemInfoCustom or _G.GetItemInfo or function() end)(id)
    if name == nil and minLvl == nil then return nil end
    return tonumber(minLvl) or 0
end

-- Does this item pass the current-level filter? (true when the gate is off)
function Engine.ItemLevelOk(id, levelOn, charLvl)
    if not levelOn then return true end
    local ml = Engine.ItemMinLevel(id)
    return ml ~= nil and ml <= (charLvl or ANx.CharLevel())
end

-- Pick the next item for the AttuneNext button, honoring its config.
-- Returns itemId (or nil) and the size of the pool it chose from.
-- opts.forceContext: draw from the launch screen's category even if the global
-- "Context sensitive" toggle is off (used when the selected category overrides a
-- conflicting option like whole-instance mode).
function Engine.AttuneNextPick(view, opts)
    local which = (opts and opts.cfg) or "btn"
    local a = ANx.Cfg(which)
    local ignore = (ANx.db and ANx.db.anext and ANx.db.anext.ignore) or {}
    -- the cards are context sensitive by nature; the button never is
    local useContext = (which == "rec") or (opts and opts.forceContext)
    local items = useContext and Engine.ContextItems(view) or Engine.Universe()
    local levelOn = ANx.LevelGate(which)
    local charLvl = ANx.CharLevel()

    -- base pool: eligible, unattuned, obtainable, not ignored, level-appropriate
    local yielding = opts and opts.yielding
    local pool = {}
    local seen = {}
    for _, id in ipairs(items) do
        if yielding then Engine.MaybeYield() end
        if not seen[id] and not ignore[id] and Engine.Eligible(id)
            and not ANx.CountDone(id) and #Engine.Sources(id) > 0
            and Engine.ItemLevelOk(id, levelOn, charLvl) then
            seen[id] = true
            pool[#pool + 1] = id
        end
    end
    if #pool == 0 then return nil, 0 end

    -- drop-rate mode: prefer items that actually have a drop rate. Quests, vendor
    -- items and crafted items have none; if that would leave nothing, the selected
    -- category wins - fall back to the full eligible pool instead of dead-ending.
    local rankByDrop = false
    if a.dropRate then
        local dp = {}
        for _, id in ipairs(pool) do
            if Engine.ItemBestDropChance(id) then dp[#dp + 1] = id end
        end
        if #dp > 0 then pool = dp; rankByDrop = true end
    end

    -- focus: narrow to the node (zone/instance/craft/currency) with the most left
    if a.focus then
        local buckets, order = {}, {}
        for _, id in ipairs(pool) do
            local b = Engine.ItemBucket(id)
            if not buckets[b] then buckets[b] = {}; order[#order + 1] = b end
            buckets[b][#buckets[b] + 1] = id
        end
        local best
        for _, b in ipairs(order) do
            if not best or #buckets[b] > #buckets[best] then best = b end
        end
        pool = buckets[best]
    end

    if rankByDrop then
        -- deterministic: the easiest (highest drop rate) item, so Ignore steps
        -- through best -> next best
        table.sort(pool, function(x, y)
            return (Engine.ItemBestDropChance(x) or 0) > (Engine.ItemBestDropChance(y) or 0)
        end)
        return pool[1], #pool
    end
    return pool[math.random(#pool)], #pool
end

-- back-compat name
function Engine.RandomUnattuned(view)
    return Engine.AttuneNextPick(view)
end

-- ---------------------------------------------------------------------
-- What should the CONTEXT-SENSITIVE cards recommend on this screen?
-- The cards have no run-mode option: the screen decides. Returns a run mode
-- ("D"/"R"/"Z"/"all") or "item" for screens whose natural recommendation is
-- a single item (vendors, quests, professions, specific item lists...).
-- ---------------------------------------------------------------------
function Engine.ContextRunMode(view)
    if not view then return "all" end
    local t = view.type
    if t == "instances" then
        return (view.kind == "R") and "R" or "D"
    end
    if t == "contentExp" then
        if view.content == "D" then return "D" end
        if view.content == "R" then return "R" end
        if view.content == "W" or view.content == "Q" then return "Z" end
        return "item"                       -- vendors/professions categories
    end
    if t == "zones" then return "Z" end     -- a list of zones
    if t == "content" or t == "home" or t == "root" or t == "browse"
        or t == "contentTypes" then
        return "all"                        -- broad overviews: best of anything
    end
    -- drilled all the way down (an instance's or zone's item list, a vendor,
    -- a quest, a profession, search results...): recommend an item from HERE
    return "item"
end

-- ---------------------------------------------------------------------
-- Cached / background picks
-- ---------------------------------------------------------------------
-- The pick walks every item in its scope, so it must NEVER run inline on a
-- render: results are cached per screen (and per revision) and computed on
-- the background pump. false = computed, nothing to recommend.
local function PickKey(view, which)
    return (which or "btn") .. "|" .. (view and tostring(view) or "global")
end

function Engine.PickCached(view, which)
    local c = pickCache[PickKey(view, which)]
    if c and c.rev == Engine.rev then return c.id end
    return nil
end

function Engine.PickAsync(view, which, onDone)
    local key = PickKey(view, which)
    local c = pickCache[key]
    if c and c.rev == Engine.rev then
        if onDone then onDone(c.id) end
        return c.id
    end
    if not Engine.SummariesReady() then return nil end
    Engine.Enqueue(function()
        local id = Engine.AttuneNextPick(view, { cfg = which, yielding = true })
        pickCache[key] = { rev = Engine.rev, id = id or false }
    end, function()
        if onDone then
            local e = pickCache[key]
            onDone(e and e.rev == Engine.rev and e.id or nil)
        end
    end, "pick:" .. key)
    return nil
end

-- ---------------------------------------------------------------------
-- Realistic per-clear odds and run length
-- ---------------------------------------------------------------------
-- A drop chance is per kill. Trash that spawns 40 times over a clear is a very
-- different proposition to a single boss with the same chance, so convert to
-- "at least one drop in a full clear": 1 - (1-p)^n.
local SPAWN_CAP = 60      -- sanity cap: nobody clears more than this of one mob

function Engine.SpawnCount(objId)
    local n = objId and ANx.MobCount and ANx.MobCount[objId]
    if not n or n < 1 then return 1 end
    if n > SPAWN_CAP then return SPAWN_CAP end
    return n
end

-- Chance (0..1) that a full clear yields at least one of this item.
-- Memoized: BestSource walks every source of the item, and the ranker asks
-- for thousands of these on the first pass.
function Engine.ClearChance(itemId, zoneName, srcFilter)
    local ck = itemId .. "|" .. (zoneName or "")
    local hit = clearChanceCache[ck]
    if hit then return hit[1], hit[2] end
    local chance, srcName, srcType, restricted, zname, src = Engine.BestSource(itemId, zoneName, srcFilter)
    local out
    if not chance or chance <= 0 then
        out = 0
    else
        local p = chance / 100
        if p >= 1 then
            out = 1
        else
            local n = Engine.SpawnCount(src and src.objId)
            out = (n <= 1) and p or (1 - (1 - p) ^ n)
        end
    end
    clearChanceCache[ck] = { out, srcName }
    return out, srcName
end

-- How long a run takes, as a multiple of an average run (1.0). Dungeons use
-- one time for normal/heroic and a separate mythic time; raids are per size.
-- The shipped estimate for a run, as a multiple of an average run.
function Engine.BuiltinRunTime(map, diffLabel)
    local t = ANx.InstanceTime and ANx.InstanceTime[map]
    if not t then return 1 end
    local lbl = diffLabel or ""
    -- every mythic time in the data is exactly 10x its normal run, so classic
    -- dungeons (which have no mythic row) follow the same relationship
    if lbl == "M" then
        if t["M"] then return t["M"] end
        if t["*"] then return t["*"] * 10 end
        return 10
    end
    if t[lbl] then return t[lbl] end
    local sized = lbl:gsub("N$", "")           -- 10N/25N share the 10/25 time
    if t[sized] then return t[sized] end
    return t["*"] or t["10"] or t["25"] or 1
end

function Engine.RunTime(map, diffLabel)
    local mode = ANx.TimeMode and ANx.TimeMode() or "off"
    if mode == "off" then return 1 end            -- run length ignored entirely
    -- what this account actually clears it in beats the estimate
    if mode ~= "builtin" then
        local measured = ANx.MeasuredRunSeconds and ANx.MeasuredRunSeconds(map, diffLabel)
        if measured and measured > 0 then
            return measured / (ANx.BASE_RUN_SECONDS or 900)
        end
        if mode == "personal" then return 1 end   -- nothing personal: stay neutral
    end
    return Engine.BuiltinRunTime(map, diffLabel)
end

-- ---------------------------------------------------------------------
-- Instance-run recommendations (expected new attunes per run)
-- ---------------------------------------------------------------------
-- Which (expansion, kind) pairs to consider, given the view and Context option.
local function InstanceScope(view, which)
    if which == "rec" and view then
        local t = view.type
        if t == "instances" then return { view.exp }, { view.kind } end
        if t == "content" then return { view.exp }, { "D", "R" } end
        if t == "contentExp" and (view.content == "D" or view.content == "R") then
            return { 1, 2, 3 }, { view.content }
        end
    end
    return { 1, 2, 3 }, { "D", "R" }
end

-- Ranked list of instance runs (each = a specific instance + difficulty),
-- best first by expected new attunes per clear. Honors all filters + difficulty
-- + Context + the ignored-instance list.
function Engine.RankInstanceRuns(view, yielding, which)
    local ignoreInst = (ANx.db and ANx.db.anext and ANx.db.anext.ignoreInst) or {}
    local exps, kinds = InstanceScope(view, which)
    local levelOn = ANx.LevelGate(which)
    local charLvl = ANx.CharLevel()
    local runs = {}
    for _, exp in ipairs(exps) do
        for _, kind in ipairs(kinds) do
            for _, inst in ipairs(Engine.InstancesFor(exp, kind)) do
                if levelOn and Engine.InstanceMinLevel(inst) > charLvl then
                    inst = nil     -- above the character: skip this instance
                end
                if inst then
                for _, d in ipairs(Engine.InstanceDiffs(inst)) do
                    if yielding then Engine.YieldNow() end
                    if ANx.DifficultyMatches(d.label) then
                        local instKey = inst.map .. ":" .. d.diff
                        if not ignoreInst[instKey] then
                            local expected, count = 0, 0
                            for _, id in ipairs(d.items) do
                                if yielding then Engine.MaybeYield() end
                                if Engine.Eligible(id) and not ANx.CountDone(id) then
                                    count = count + 1
                                    expected = expected
                                        + Engine.ClearChance(id, inst.name, ANx.INSTANCE_DROP_SRC)
                                end
                            end
                            if count > 0 then
                                local rt = Engine.RunTime(inst.map, d.label)
                                runs[#runs + 1] = {
                                    inst = inst, d = d, expected = expected,
                                    count = count, instKey = instKey, kind = kind,
                                    time = rt, score = expected / math.max(rt, 0.02),
                                }
                            end
                        end
                    end
                end
                end
            end
        end
    end
    table.sort(runs, function(x, y)
        local sx, sy = x.score or x.expected, y.score or y.expected
        if sx ~= sy then return sx > sy end
        if x.expected ~= y.expected then return x.expected > y.expected end
        return x.count > y.count
    end)
    return runs
end

-- Ranked list of ZONE runs (quests + world drops in open-world zones),
-- best first by expected new attunes for a full sweep of the zone.
local zoneRunSrc
local function ZoneRunSrc()
    if not zoneRunSrc then
        zoneRunSrc = { [ANx.SRC.QUEST] = true }
        for k in pairs(ANx.WORLD_DROP_SRC or {}) do zoneRunSrc[k] = true end
    end
    return zoneRunSrc
end

function Engine.RankZoneRuns(view, yielding, which)
    local ignoreInst = (ANx.db and ANx.db.anext and ANx.db.anext.ignoreInst) or {}
    local levelOn = ANx.LevelGate(which)
    local charLvl = ANx.CharLevel()
    -- The context-sensitive feature respects BOTH context dimensions:
    --   * expansion: a Classic screen never recommends a TBC zone sweep
    --   * content:   a dungeons/raids screen never recommends a zone sweep
    --     at all (the instance side already pins itself the same way)
    local scopeExp = (which == "rec") and view and view.exp or nil
    if which == "rec" and view then
        local t = view.type
        if t == "instances"
            or (t == "contentExp" and (view.content == "D" or view.content == "R"))
            or (t == "items" and view.instMap) then
            return {}                 -- instance context: zones are out of scope
        end
    end
    local runs = {}
    for _, z in ipairs(ANx.Zones or {}) do
        if yielding then Engine.YieldNow() end
        local key = "z:" .. z.zone
        if not ignoreInst[key]
            and (not scopeExp or z.exp == scopeExp)
            and (not levelOn or Engine.ZoneMinLevel(z) <= charLvl) then
            local expected, count, items = 0, 0, {}
            for _, id in ipairs(ANx.ItemsInZone(z.zone) or {}) do
                if yielding then Engine.MaybeYield() end
                if Engine.Eligible(id) and not ANx.CountDone(id)
                    and Engine.ItemLevelOk(id, levelOn, charLvl) then
                    local cc = Engine.ClearChance(id, z.name, ZoneRunSrc())
                    if cc > 0 then
                        count = count + 1
                        items[#items + 1] = id
                        expected = expected + cc
                    end
                end
            end
            if count > 0 then
                -- a zone sweep is treated as one average-length run
                runs[#runs + 1] = { zone = z, expected = expected, count = count,
                    instKey = key, items = items, time = 1, score = expected }
            end
        end
    end
    table.sort(runs, function(x, y)
        local sx, sy = x.score or x.expected, y.score or y.expected
        if sx ~= sy then return sx > sy end
        if x.expected ~= y.expected then return x.expected > y.expected end
        return x.count > y.count
    end)
    return runs
end

-- Unified run ranking for the AttuneNext button, honoring the run mode:
-- "D"/"R"/"DR" = instances of those kinds, "Z" = zones, "all" = everything.
-- Context key: rankings differ per screen only when Context sensitive is on.
local function RunsKey(view, mode, which)
    local ctx = ""
    if which == "rec" and view then
        ctx = (view.type or "") .. ":" .. tostring(view.exp or "") .. ":" .. tostring(view.kind or view.content or "")
    end
    local lvl = ANx.LevelGate(which) and ("L" .. ANx.CharLevel()) or ""
    return (which or "btn") .. "|" .. (mode or "DR") .. "|" .. ctx .. "|" .. lvl
end

function Engine.RankRuns(view, mode, yielding, which)
    mode = mode or "DR"
    local key = RunsKey(view, mode, which)
    local c = runsCache[key]
    if c and c.rev == Engine.rev then return c.runs end
    local runs = {}
    if mode ~= "Z" then
        local only = (mode == "D" and "D") or (mode == "R" and "R") or nil
        for _, r in ipairs(Engine.RankInstanceRuns(view, yielding, which)) do
            if not only or r.kind == only then runs[#runs + 1] = r end
        end
    end
    if mode == "Z" or mode == "all" then
        for _, r in ipairs(Engine.RankZoneRuns(view, yielding, which)) do runs[#runs + 1] = r end
    end
    table.sort(runs, function(x, y)
        local sx, sy = x.score or x.expected, y.score or y.expected
        if sx ~= sy then return sx > sy end
        if x.expected ~= y.expected then return x.expected > y.expected end
        return x.count > y.count
    end)
    -- only the head of the list is ever consumed (best run + ignore
    -- stepping); keeping hundreds of tails per screen just burns memory
    for i = #runs, 26, -1 do runs[i] = nil end
    runsCache[key] = { rev = Engine.rev, runs = runs }
    return runs
end

-- Are the background scans finished? Ranking before they are is wasted work:
-- each summary that lands invalidates the result and we would start over.
function Engine.SummariesReady()
    for exp = 1, 3 do
        local s = summaryCache[exp]
        if not (s and s.ready) then return false end
    end
    -- structural scans still queued? (a queued ranking does not count - it is
    -- the thing waiting on this)
    for _, j in ipairs(Engine.scanJobs) do
        local tag = j.tag or ''
        if tag == '' or tag:sub(1, 7) == 'summary' then return false end
    end
    return true
end

-- Ready-made ranking if it is already cached, else nil (no work done).
function Engine.RunsCached(view, mode, which)
    local c = runsCache[RunsKey(view, mode or "DR", which)]
    if c and c.rev == Engine.rev then return c.runs end
    return nil
end

-- Rank in the background (10ms/frame budget) and call back when done. The UI
-- uses this so opening a screen never blocks on a full pass over every
-- instance, difficulty and item.
function Engine.RankRunsAsync(view, mode, onDone, which)
    mode = mode or "DR"
    local ready = Engine.RunsCached(view, mode, which)
    if ready then
        if onDone then onDone(ready) end
        return ready
    end
    -- wait for the item scans: ranking now would be thrown away when they land
    if not Engine.SummariesReady() then return nil end
    local key = RunsKey(view, mode, which)
    Engine.Enqueue(function()
        Engine.RankRuns(view, mode, true, which)
    end, function()
        if onDone then onDone(Engine.RunsCached(view, mode, which) or {}) end
    end, "runs:" .. key)
    return nil
end

-- ---------------------------------------------------------------------
-- Goal tracker
-- ---------------------------------------------------------------------
function Engine.InstanceByMap(map)
    for _, inst in ipairs(ANx.Instances or {}) do
        if inst.map == map then return inst end
    end
end

function Engine.GoalName(goal)
    if goal.kind == "inst" then
        -- goals tracked from the recommendation pane only carry map + diff, so
        -- resolve the display name rather than trusting stored fields
        local n = goal.name
        if not n then
            local inst = Engine.InstanceByMap and Engine.InstanceByMap(goal.map)
            n = inst and inst.name or ("Instance " .. tostring(goal.map))
        end
        local d = goal.diffText
        if (not d or d == "") and goal.diff and goal.diff ~= "" then
            d = (ANx.DIFF_LABEL_TEXT and ANx.DIFF_LABEL_TEXT[goal.diff]) or goal.diff
        end
        if d and d ~= "" then n = n .. "  (" .. d .. ")" end
        return n
    end
    return (ANx.EXP_SHORT[goal.exp] or "?") .. " "
        .. (goal.content == "D" and "Dungeons" or "Raids")
end

function Engine.GoalKey(goal)
    if goal.kind == "inst" then
        return "i" .. tostring(goal.map) .. ":" .. tostring(goal.diff or "*")
    end
    return "c" .. tostring(goal.exp) .. tostring(goal.content)
end

-- does this difficulty entry belong to the goal? A difficulty-specific goal
-- pins its own difficulty (and ignores the global Difficulty/Size filter);
-- whole-instance goals follow the filter like everything else.
local function GoalDiffMatch(diff, label)
    if diff then return label == diff end
    return ANx.DifficultyMatches(label)
end

-- Estimated clears to finish one instance, using the same expected-attunes-
-- per-clear math as the AttuneNext recommender. Also counts left items with
-- no drop rate (vendor/quest/craft-sourced things inside the instance set).
local function InstanceClears(inst, diff)
    local leftDrop, expected, noDrop = 0, 0, 0
    local seen = {}
    for _, d in ipairs(Engine.InstanceDiffs(inst) or {}) do
        if GoalDiffMatch(diff, d.label) then
            for _, id in ipairs(d.items) do
                if not seen[id] and Engine.Eligible(id) and not ANx.CountDone(id) then
                    seen[id] = true
                    local cc = Engine.ClearChance(id, inst.name, ANx.INSTANCE_DROP_SRC)
                    if cc > 0 then
                        leftDrop = leftDrop + 1
                        expected = expected + cc
                    else
                        noDrop = noDrop + 1
                    end
                end
            end
        end
    end
    if leftDrop == 0 or expected <= 0 then return 0, noDrop end
    return math.ceil(leftDrop / expected), noDrop
end

-- Full status for one goal: { name, total, done, left, pct, clears, noDrop,
-- items (inst goals: the deduped item list for click-through) }
function Engine.GoalStatus(goal)
    local st = { name = Engine.GoalName(goal), total = 0, done = 0,
                 clears = 0, noDrop = 0 }
    local seen = {}
    local function addItem(id)
        if not seen[id] and Engine.Eligible(id) then
            seen[id] = true
            st.total = st.total + 1
            if ANx.CountDone(id) then st.done = st.done + 1 end
            return true
        end
    end
    if goal.kind == "inst" then
        local inst = Engine.InstanceByMap(goal.map)
        if inst then
            st.items = {}
            for _, d in ipairs(Engine.InstanceDiffs(inst) or {}) do
                if GoalDiffMatch(goal.diff, d.label) then
                    for _, id in ipairs(d.items) do
                        if addItem(id) then st.items[#st.items + 1] = id end
                    end
                end
            end
            st.clears, st.noDrop = InstanceClears(inst, goal.diff)
        end
    else
        for _, inst in ipairs(Engine.InstancesFor(goal.exp, goal.content) or {}) do
            for _, d in ipairs(Engine.InstanceDiffs(inst) or {}) do
                if ANx.DifficultyMatches(d.label) then
                    for _, id in ipairs(d.items) do addItem(id) end
                end
            end
            local clears, noDrop = InstanceClears(inst)
            st.clears = st.clears + clears
            st.noDrop = st.noDrop + noDrop
        end
    end
    st.left = st.total - st.done
    st.pct = (st.total > 0) and (st.done / st.total) or 0
    return st
end
