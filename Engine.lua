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
local srcCache      = {}   -- [itemId]        -> sources array (bounded, see Sources)
local srcCacheN     = 0    -- entries in srcCache
local srcCacheRows  = 0    -- source records held across all cached entries
local srcCacheCap   = 32   -- flush past this. Since v3.7.0 every scan, count
                           -- and filter streams rows straight off the server
                           -- API (EachSourceRow / BuildItemMemo); only the item
                           -- detail page and the arrow router still want a
                           -- row ARRAY, and they look at one item at a time.
-- The item cap alone is not a memory bound: a world-drop item can list
-- thousands of creatures, so a 3000-item cache once held millions of record
-- tables and pushed the 32-bit client past its 2 GB limit at login. Budget
-- the cache by RECORDS too; an item bigger than the whole budget is never cached.
local SRC_ROW_BUDGET = 20000
local limitedItemsSet      -- set of itemIds limited-stock at some vendor (lazy)
local eventItemsCache = {} -- [eventName]     -> { itemIds }
local profCache     = {}   -- [prof.."-"..exp]-> { entries = { {id, spell, skill, srcType} } }
local statsCache    = {}   -- [key]           -> { attuned=, total= , best= {id, chance, srcName} }
local summaryCache  = {}   -- [exp]           -> { D=set, R=set, Q=set, W=set, V=set, C=set, ready=bool }
local remainingCache       -- "What's Left" report (lazy; nil = rebuild)
local clearChanceCache = {} -- ["item|zone"]  -> per-clear drop chance
local runsCache = {}       -- ["mode|ctx"]   -> { rev =, runs = }
local pickCache = {}       -- ["which|view"] -> { rev =, id = itemId or false }
-- Per-item quest-side / quest-only / char-blocked / zone-exclusive /
-- min-level predicates live in the consolidated flag cache (Core.lua). The
-- accessors below read their field INLINE off this shared table: going
-- through ANx.FlagGet cost two global lookups plus a call per read, and the
-- warmup performs one read (and one write) per item per predicate.
local itemFlags = ANx.ItemFlags
local band, lshift, rshift = bit.band, bit.lshift, bit.rshift
local F_QSIDE, F_QONLY, F_QCHAR = ANx.F_QSIDE, ANx.F_QONLY, ANx.F_QCHAR
local F_ZEX, F_MINLVL = ANx.F_ZEX, ANx.F_MINLVL

-- write one field without the ANx.FlagSet indirection
local function FSet(id, shift, mask, v)
    local f = itemFlags[id] or 0
    itemFlags[id] = f - lshift(band(rshift(f, shift), mask), shift) + lshift(band(v, mask), shift)
end

local cachesWarm = false   -- per-item filter caches walked once in the background
local warmed = {}          -- [predicate] = true once swept for the whole universe
                           -- (declared HERE so InvalidateAll clears this local
                           -- and not a stray global - see minLvlCache history)
local cacheDirty = false   -- structural data changed since the last export
-- Scan-lifetime classification memo (see BuildItemMemo): one walk over an
-- item's rows serves every zone that lists it. Created by the first ZoneData
-- call inside a background job, dropped when the job queue drains.
local scanMemo, qvMemo

-- /an perf telemetry: Engine's share of the counter table Core.lua owns
-- (created here too so a Core without it - AttuneNext-Simple's - still loads)
ANx.Perf = ANx.Perf or { readyAt = 0 }
local perf = ANx.Perf
perf.srcFlush, perf.srcTooBig = 0, 0                 -- Sources(): wholesale flushes, items never cached
perf.zoneItems, perf.zoneFallback, perf.zoneUnmatched = 0, 0, 0
perf.unk, perf.unkN = {}, 0                          -- bounded sample of zone names we do not know
perf.unmatched, perf.unmatchedN = {}, 0              -- bounded sample of OUR zones no row ever named
perf.ownedCalls = 0                                  -- GetItemCount from IsOwned
perf.pumpFrames, perf.pumpOver, perf.pumpMs, perf.pumpMaxMs, perf.pumpMaxTag = 0, 0, 0, 0, "-"
perf.resumeMaxMs, perf.resumeMaxTag = 0, "-"
perf.resumeMaxSite, perf.resumeMaxKbIn, perf.resumeMaxKbOut = "-", 0, 0  -- yield site that ended it, Lua KB before/after
perf.peakKb, perf.peakTag = 0, "-"                   -- highest Lua heap seen by the pump, and the job running
perf.gcMs, perf.gcMaxMs = 0, 0
perf.exportMs, perf.summariesS, perf.idleS = 0, 0, 0

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
    -- a filter may have just been switched on that needs a predicate the
    -- warmup skipped; top it up in the background (tag-deduped, so the
    -- repeated calls from other invalidation paths cost nothing)
    if Engine.WarmIfNeeded then Engine.WarmIfNeeded() end
end

function Engine.InvalidateAll()
    instDiffCache, instResolved, zoneCache, srcCache, profCache, statsCache, summaryCache =
        {}, {}, {}, {}, {}, {}, {}
    srcCacheN, srcCacheRows = 0, 0
    limitedItemsSet = nil
    eventItemsCache = {}
    remainingCache = nil
    clearChanceCache = {}
    runsCache = {}
    pickCache = {}
    -- clear the Engine-owned fields of the consolidated flag cache (quest
    -- side/only/char-blocked, zone-exclusive, min level). Core's bind/
    -- faction/accessory fields survive a data refresh exactly as their old
    -- separate caches did; ForceRescan clears those too.
    if ANx.FlagClearMask then
        local m = bit.lshift(3, ANx.F_QSIDE) + bit.lshift(3, ANx.F_QONLY)
            + bit.lshift(3, ANx.F_QCHAR) + bit.lshift(3, ANx.F_ZEX)
            + bit.lshift(1023, ANx.F_MINLVL)
        ANx.FlagClearMask(m)
    end
    cachesWarm = false
    warmed = {}            -- every predicate must be swept again
    scanMemo, qvMemo = nil, nil   -- the scan-lifetime classification memo
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
    if not provisional then
        -- the arrays now live on as summaryCache sets; keeping the source
        -- arrays in the db too held the same ~20k+ ids twice all session.
        -- ExportCache rebuilds them from the live sets at scan-end and at
        -- PLAYER_LOGOUT, so nothing is lost. (The provisional import keeps
        -- them: the validated import at data-ready re-reads this table.)
        sc.summaries = nil
    end
    return true
end

-- Full manual rescan (Refresh button / "/an reset")
function Engine.ForceRescan()
    if ANx.db then ANx.db.structCache = nil; ANx.db.tipCache = nil end
    if ANx.InvalidateBindCache then ANx.InvalidateBindCache() end
    if ANx.InvalidateClassLockCache then ANx.InvalidateClassLockCache() end
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
-- Pump time per frame, scan slices AND collector steps together. A 60 fps
-- client has 16.7 ms per frame, so this is a ceiling, not a target. The
-- v3.6.x pump scanned for 10 ms and THEN ran one unbounded
-- collectgarbage("step", 2048): 4-5 ms more per frame on average and up to
-- 45 ms in one frame (a Lua 5.1 step does the collector's whole catch-up for
-- everything allocated since its threshold). In game it was worse still:
-- the "every 25th call" yield rule let one resume run 3.8 s inside a
-- 1-2 GB heap.
local BUDGET_MS = 10
local COMBAT_BUDGET_MS = 4   -- while InCombatLockdown(): frame time matters more than scan time
local GC_SHARE = 0.3         -- part of the budget reserved for the collector (3 of 10 ms)
local GC_STEP_KB = 256       -- one collector step; several per frame (see CollectSome)
local GC_STEPS_MAX = 8       -- idle collector: pull its threshold in by at most 2 MB/frame
local SLICE_MS = 2           -- MaybeYield hands control back after this much work

local function Clock()
    if debugprofilestop then return debugprofilestop() end
    return GetTime() * 1000
end

-- Yield once the running slice has used SLICE_MS. The old "every 25th
-- call" rule let one slice run 35-50 ms in the harness (25 world-drop
-- items, each with hundreds of source rows) and seconds in game; a clock
-- check per call costs well under a microsecond. No-op off the pump.
local sliceStart = 0    -- Clock() when the pump last resumed the front job
local yieldSite = "-"   -- tag of the call site that last yielded (for /an perf:
                        -- the work of a resume lies between two yield sites, and
                        -- the 3.3.5 client has no debug.getinfo to name it after)
function Engine.MaybeYield(site)
    if coroutine.running() and Clock() - sliceStart >= SLICE_MS then
        yieldSite = site or "?"
        coroutine.yield()
    end
end

-- Unconditional yield (safe on the main thread). Use this around chunks of
-- work that are individually expensive and have no MaybeYield inside.
function Engine.YieldNow(site)
    if coroutine.running() then
        yieldSite = site or "?"
        coroutine.yield()
    end
end

-- A few small collector steps after the scan slices. Lua 5.1's step does
-- the collector's catch-up work for the bytes allocated since its threshold
-- plus the KB given, so it is already proportional to what the scan just
-- allocated; stop at the frame budget, or as soon as a collection cycle
-- completes. An idle collector makes a step nearly free (it only pulls the
-- next cycle closer), so the count is capped too: at most 2 MB per frame,
-- the pacing the old single 2048 KB step gave.
local function CollectSome(start, budget)
    for _ = 1, GC_STEPS_MAX do
        if collectgarbage("step", GC_STEP_KB) or Clock() - start >= budget then break end
    end
end

local function PumpBudget()
    if InCombatLockdown and InCombatLockdown() then return COMBAT_BUDGET_MS end
    return BUDGET_MS
end

pumpFrame:SetScript("OnUpdate", function(self)
    local job = Engine.scanJobs[1]
    if not job then
        Engine.scanning = false
        self:Hide()   -- sleep until the next Enqueue (OnUpdate needs shown)
        return
    end
    Engine.scanning = true
    local budget = PumpBudget()
    local start = Clock()
    local scanUntil = budget * (1 - GC_SHARE)
    local now = start
    while now - start < scanUntil do
        if coroutine.status(job.co) == "dead" then break end
        sliceStart = now
        local kbIn = collectgarbage("count")
        local ok, err = coroutine.resume(job.co)
        local t = Clock()   -- (the loop condition read the clock here anyway)
        if t - now > perf.resumeMaxMs then
            perf.resumeMaxMs = t - now
            perf.resumeMaxTag = tostring(job.tag)
            -- which yield ended it, and whether the heap shrank inside it (a
            -- big drop = an automatic collector cycle ran during the resume)
            perf.resumeMaxSite = (coroutine.status(job.co) == "dead") and "end" or yieldSite
            perf.resumeMaxKbIn = math.floor(kbIn)
            perf.resumeMaxKbOut = math.floor(collectgarbage("count"))
        end
        now = t
        if not ok then
            ANx.Print("|cffff4040scan error:|r " .. tostring(err))
            break
        end
    end
    -- Left to its default pacing, Lua's collector let the scan's garbage
    -- pile up to several times the live data during login; stepping it every
    -- scan frame keeps it bounded (only runs while a background job is active).
    local kb = collectgarbage("count")
    if kb > perf.peakKb then perf.peakKb = math.floor(kb); perf.peakTag = tostring(job.tag) end
    CollectSome(start, budget)
    local gcEnd = Clock()
    local gcMs, frameMs = gcEnd - now, gcEnd - start
    perf.pumpFrames = perf.pumpFrames + 1
    perf.pumpMs = perf.pumpMs + frameMs
    perf.gcMs = perf.gcMs + gcMs
    if gcMs > perf.gcMaxMs then perf.gcMaxMs = gcMs end
    if frameMs > perf.pumpMaxMs then perf.pumpMaxMs = frameMs; perf.pumpMaxTag = tostring(job.tag) end
    if frameMs > budget * 2 then perf.pumpOver = perf.pumpOver + 1 end
    if coroutine.status(job.co) == "dead" then
        table.remove(Engine.scanJobs, 1)
        if #Engine.scanJobs == 0 then
            Engine.scanning = false
            scanMemo, qvMemo = nil, nil
            if perf.readyAt > 0 then perf.idleS = GetTime() - perf.readyAt end
            -- persist the structural cache ONLY when a scan actually changed
            -- it - re-serializing thousands of ids after every filter click
            -- was a serious source of GC hitches and SavedVariables bloat
            if cacheDirty then
                cacheDirty = false
                if perf.readyAt > 0 then perf.summariesS = GetTime() - perf.readyAt end
                local t0 = Clock()
                pcall(Engine.ExportCache)
                perf.exportMs = Clock() - t0
            end
            -- FIRST: walk every item once in the background to fill the
            -- per-item filter caches (faction/bind tooltip scans, sources,
            -- levels). Counts render inline, and computing them against COLD
            -- caches is what froze the first open of every screen for
            -- seconds - warm, they are a cheap sweep of native calls.
            -- (only once the server data is live: a job that drains the queue
            -- before then - the zone watch at login - would warm predicates
            -- against the status cache, to be thrown away at data-ready)
            if ANx.dataReady then Engine.EnsureWarm() end
        end
        if job.onDone then
            local ok, err = pcall(job.onDone)
            if not ok then ANx.ReportError("scan callback error: " .. tostring(err)) end
        end
        for _, cb in ipairs(job.extra or {}) do
            local ok, err = pcall(cb)
            if not ok then ANx.ReportError("scan callback error: " .. tostring(err)) end
        end
    end
end)

-- ---------------------------------------------------------------------
-- Filter-aware warmup
-- ---------------------------------------------------------------------
-- The background sweep exists so the first render of a screen isn't computing
-- thousands of cold predicates inline. But Engine.Eligible only CONSULTS a
-- predicate when the matching filter is active, and most are off by default -
-- so warming all of them meant (for a default setup) thousands of wasted
-- tooltip scans and source walks at every login. Warm what the current
-- filters actually read; anything switched on later gets a top-up sweep.
local function NeededPredicates()
    local db = ANx.db or {}
    return {
        -- BindAllowed short-circuits unless a specific bind type is chosen
        bind = (db.bindFilter or "both") ~= "both",
        -- AccessoryAllowed short-circuits unless accessories are hidden
        acc = db.accessories == false,
        -- the quest-side test only runs under a one-faction filter
        qside = (db.faction or "both") ~= "both",
        -- min level is only read by the current-level gate
        lvl = (ANx.LevelGate and (ANx.LevelGate("btn") or ANx.LevelGate("rec"))) or false,
        zex = db.zoneExclusive == true,
        -- "my quests" hiding applies under character scope
        qchar = (db.scope ~= "account") and ((db.questClass or "mine") ~= "all"),
    }
end

-- true when a filter now needs a predicate the last sweep skipped
function Engine.WarmupIncomplete()
    for pred, need in pairs(NeededPredicates()) do
        if need and not warmed[pred] then return true end
    end
    return false
end

function Engine.WarmPredicates()
    local need = NeededPredicates()
    local items = Engine.Universe()
    -- only sweep the predicates that are needed AND not already swept
    local doBind = need.bind and not warmed.bind
    local doAcc = need.acc and not warmed.acc
    local doQSide = need.qside and not warmed.qside
    local doLvl = need.lvl and not warmed.lvl
    local doZex = need.zex and not warmed.zex
    local doQChar = need.qchar and not warmed.qchar
    local first = not cachesWarm
    for _, id in ipairs(items) do
        Engine.MaybeYield("warmup")
        -- (no Engine.Sources pre-fill here: the universe is far larger than
        -- the bounded source cache, so pre-loading every item just built and
        -- threw away every source record a second time; the predicates
        -- below fetch what they need themselves)
        if first then
            ANx.FactionAllowed(id)      -- no-op while the faction filter is off
        end
        if doLvl or doBind then
            local known = Engine.ItemMinLevel(id) ~= nil
            -- only resolve bind for items the client has data for:
            -- scanning an uncached item would bake in "unknown"
            if doBind and ANx.BindType and (known or (ANx.ItemBindSeed and ANx.ItemBindSeed(id))) then
                ANx.BindType(id)
            end
        end
        if doAcc and ANx.IsAccessory then ANx.IsAccessory(id) end
        if doQSide then Engine.ItemQuestSide(id) end
        if doQChar then Engine.ItemQuestCharBlocked(id) end
        if doZex then Engine.IsZoneExclusive(id) end
    end
    if doBind then warmed.bind = true end
    if doAcc then warmed.acc = true end
    if doQSide then warmed.qside = true end
    if doLvl then warmed.lvl = true end
    if doZex then warmed.zex = true end
    if doQChar then warmed.qchar = true end
    cachesWarm = true
    -- the per-item filter caches are built; the raw source arrays for the
    -- whole universe are no longer needed
    Engine.FlushSources()
end

-- A filter changed: if it needs a predicate we skipped, sweep it in the
-- background rather than letting the next render compute it inline.
function Engine.WarmIfNeeded()
    if not cachesWarm then return end          -- the initial sweep covers it
    if not Engine.WarmupIncomplete() then return end
    Engine.Enqueue(Engine.WarmPredicates, function()
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end, "warmup")
end

-- Queue the predicate warmup and the AttuneNext button's pick unless they
-- are already done or queued. The pump does this itself when a scan ends;
-- a cached login runs no scan.
function Engine.EnsureWarm()
    if not ANx.dataReady then return end
    if not cachesWarm or Engine.WarmupIncomplete() then
        Engine.Enqueue(Engine.WarmPredicates, function()
            if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
        end, "warmup")
    end
    if Engine.PickCached and Engine.PickCached(nil, "btn") == nil then
        Engine.PickAsync(nil, "btn")
    end
end

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
    pumpFrame:Show()
end

-- ---------------------------------------------------------------------
-- Sources (cached per item)
-- ---------------------------------------------------------------------
-- Does the item have any source at all? Count-only - avoids building (and
-- caching) the heavy source array just to test presence.
function Engine.HasAnySource(itemId)
    if not (ANx.LootDbLoaded() and _G.ItemLocGetSourceCount) then return false end
    local ok, n = pcall(_G.ItemLocGetSourceCount, itemId)
    return ok and n and n > 0
end

function Engine.Sources(itemId)
    local s = srcCache[itemId]
    if not s then
        -- keep only a working set: source records are named-key tables (~8
        -- fields each), so caching every item in a big DB burned hundreds of
        -- MB. Filters/counts use the small derived caches, not this - only
        -- the items actually viewed/ranked need their raw sources.
        s = ANx.GetSources(itemId)
        local rows = #s
        if rows <= SRC_ROW_BUDGET then
            if srcCacheN >= srcCacheCap or srcCacheRows + rows > SRC_ROW_BUDGET then
                srcCache = {}
                srcCacheN, srcCacheRows = 0, 0
                perf.srcFlush = perf.srcFlush + 1
            end
            srcCache[itemId] = s
            srcCacheN = srcCacheN + 1
            srcCacheRows = srcCacheRows + rows
        else
            perf.srcTooBig = perf.srcTooBig + 1
        end
    end
    return s
end

-- Drop the raw-source working set (rebuilds on demand). Called once the
-- background warm-up has distilled everything into the small filter caches;
-- after that only viewed/ranked items need raw sources, so a smaller working
-- set suffices (ClearChance results are memoized separately).
function Engine.FlushSources()
    srcCache = {}
    srcCacheN, srcCacheRows = 0, 0
end

-- Walk an item's source rows straight off the server API without building
-- the row tables (ANx.GetSources): the per-item predicates below read one or
-- two fields per row and usually stop at the first row that decides them.
-- fn(srcType, objType, objId, chance, perMille, objName, zoneName, spawned, i)
-- returns true to stop early. Returns true if any row was visited.
-- Building one 9-field table per row was the login scan's dominant cost in
-- v3.6.x: 42 million row tables for 2.2 million real rows on a live client.
local function EachSourceRow(itemId, fn)
    local getCount, getAt = _G.ItemLocGetSourceCount, _G.ItemLocGetSourceAt
    if not (getCount and getAt and ANx.LootDbLoaded()) then return false end
    local n = getCount(itemId) or 0
    perf.rowReads = perf.rowReads + n
    local any = false
    for i = 1, n do
        local srcType, objType, objId, chance, perMille, objName, zoneName, spawned = getAt(itemId, i)
        if srcType ~= nil then
            any = true
            if fn(srcType, objType, objId, chance or 0, perMille, objName or "?", zoneName or "", spawned, i) then break end
        end
    end
    return any
end
Engine.EachSourceRow = EachSourceRow

-- true when EVERY source of the item is a quest reward (can't be forged)
function Engine.IsQuestOnly(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QONLY), 3) or 0
    if c ~= 0 then return c == 2 end
    local SRC_QUEST = ANx.SRC.QUEST
    local v = true
    local any = EachSourceRow(itemId, function(srcType)
        if srcType ~= SRC_QUEST then v = false return true end
    end)
    v = any and v
    FSet(itemId, F_QONLY, 3, v and 2 or 1)
    return v
end
function Engine.InvalidateQuestOnly()
    ANx.FlagClearAll(ANx.F_QONLY, 3)
end

-- (Zone-name comparisons now use the pre-lowered s.zoneLower field that
-- ANx.GetSources stamps on every source record: the old ZoneNameMatch
-- helper allocated two fresh lowered strings per comparison inside the
-- per-item hot loops.)

-- Every zone name the addon knows, lowercased. Used to tell an English client
-- (source zoneNames are recognizable) from a localized one (they are not).
local knownZoneNames
function Engine.KnownZoneNameSet()
    if knownZoneNames then return knownZoneNames end
    knownZoneNames = {}
    for _, z in ipairs(ANx.Zones or {}) do
        if z.name then knownZoneNames[z.name:lower()] = true end
    end
    for _, inst in ipairs(ANx.Instances or {}) do
        if inst.name then knownZoneNames[inst.name:lower()] = true end
    end
    return knownZoneNames
end

-- Best source for an item, preferring sources in the given zone name + src filter.
-- Returns chance, sourceName, srcType, restricted(bool), zoneName
-- returns chance, sourceName, srcType, restricted, zoneName, sourceRecord
-- Quest sources this character can never take (the other faction's copy of
-- a dual-version quest) must not win "best source" while a usable source
-- exists - a Horde player should be shown the Horde quest giver.
local function SourceUsable(s)
    if s.srcType ~= ANx.SRC.QUEST or not s.objId then return true end
    return ANx.CharCanDoQuest(s.objId)
end

function Engine.BestSource(itemId, zoneName, srcFilter)
    -- Streams the rows (no tables): keeps the best row INDEX in each of four
    -- classes, then re-reads the winner. Returns chance, objName, srcType,
    -- inZone, zoneName, objId.
    local getCount, getAt = _G.ItemLocGetSourceCount, _G.ItemLocGetSourceAt
    if not (getCount and getAt and ANx.LootDbLoaded()) then return nil end
    local ZoneLower = ANx.ZoneLower
    local zTarget = zoneName and ZoneLower(zoneName)
    local SRC_QUEST = ANx.SRC.QUEST
    local CanDo = ANx.CharCanDoQuest
    local bC, bI, aC, aI, bbC, bbI, abC, abI   -- zone/usable, any/usable, zone/blocked, any/blocked
    local n = getCount(itemId) or 0
    perf.rowReads = perf.rowReads + n
    for i = 1, n do
        local srcType, _, objId, chance, _, _, zn = getAt(itemId, i)
        if srcType ~= nil and ((not srcFilter) or srcFilter[srcType]) then
            chance = chance or 0
            local zoneHit = zTarget ~= nil and ZoneLower(zn) == zTarget
            if srcType ~= SRC_QUEST or not objId or CanDo(objId) then
                if (not aI) or chance > aC then aC, aI = chance, i end
                if zoneHit and ((not bI) or chance > bC) then bC, bI = chance, i end
            else
                if (not abI) or chance > abC then abC, abI = chance, i end
                if zoneHit and ((not bbI) or chance > bbC) then bbC, bbI = chance, i end
            end
        end
    end
    -- usable sources always outrank blocked ones; blocked are a last resort
    -- so account-scope displays still have something to show
    local idx, inZone = bI or bbI, true
    if not idx then idx, inZone = aI or abI, false end
    if not idx then return nil end
    local srcType, _, objId, chance, _, objName, zn = getAt(itemId, idx)
    return chance or 0, objName or "?", srcType, inZone, zn or "", objId
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
    local rares = ANx.RareNPCs
    if not rares then return false end
    local ZoneLower = ANx.ZoneLower
    local zTarget = zoneName and ZoneLower(zoneName)
    local C, MC = ANx.SRC.CREATURE, ANx.SRC.MYTHIC_CREATURE
    local hit = false
    EachSourceRow(itemId, function(srcType, _, objId, _, _, _, zn)
        if (srcType == C or srcType == MC) and objId and rares[objId]
            and (not zTarget or ZoneLower(zn) == zTarget) then
            hit = true
            return true
        end
    end)
    return hit
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
    local ZoneLower = ANx.ZoneLower
    local zTarget = ZoneLower(zoneName)
    local inThisZone, elsewhere = false, false
    EachSourceRow(itemId, function(_, _, _, _, _, _, zn)
        if zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            if ZoneLower(zn) == zTarget then
                inThisZone = true
            else
                elsewhere = true   -- found a source in a different zone
                return true
            end
        end
    end)
    return inThisZone and not elsewhere
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
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_ZEX), 3) or 0
    if c ~= 0 then return c == 2 end
    local zone, multiple = nil, false
    local ZoneLower = ANx.ZoneLower
    EachSourceRow(itemId, function(_, _, _, _, _, _, zn)
        if zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            local zl = ZoneLower(zn)
            if zone == nil then zone = zl
            elseif zone ~= zl then multiple = true return true end
        end
    end)
    local v = (zone ~= nil) and (not multiple)
    FSet(itemId, F_ZEX, 3, v and 2 or 1)
    return v
end

-- Shared item eligibility for counting/listing: character/account can attune it,
-- faction filter passes, and (if the global toggle is on) it's zone-exclusive.
-- For quest-only items: the one faction whose quests reward it, or nil if
-- any of its quests are neutral / doable by both (or it has other sources).
function Engine.ItemQuestSide(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QSIDE), 3) or 0
    if c ~= 0 then return (c == 2 and "A") or (c == 3 and "H") or nil end
    if not Engine.IsQuestOnly(itemId) then
        FSet(itemId, F_QSIDE, 3, 1)
        return nil
    end
    local side, mixed
    local SRC_QUEST = ANx.SRC.QUEST
    EachSourceRow(itemId, function(srcType, _, objId)
        if srcType == SRC_QUEST then
            local qs = ANx.QuestFactionSide(objId)
            if not qs or (side and side ~= qs) then mixed = true return true end
            side = qs
        end
    end)
    if mixed then
        FSet(itemId, F_QSIDE, 3, 1)
        return nil
    end
    FSet(itemId, F_QSIDE, 3, side == "A" and 2 or side == "H" and 3 or 1)
    return side
end

-- Quest-only items where EVERY quest is impossible for this character
-- (class- or race-locked): the item can be attunable yet unreachable, like
-- the role rings behind class-locked quest trios.
function Engine.ItemQuestCharBlocked(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QCHAR), 3) or 0
    if c ~= 0 then return c == 2 end
    local blocked = false
    if Engine.IsQuestOnly(itemId) then
        blocked = true
        local SRC_QUEST = ANx.SRC.QUEST
        EachSourceRow(itemId, function(srcType, _, objId)
            if srcType == SRC_QUEST and ANx.CharCanDoQuest(objId) then
                blocked = false
                return true
            end
        end)
    end
    FSet(itemId, F_QCHAR, 3, blocked and 2 or 1)
    return blocked
end

-- ---------------------------------------------------------------------
-- "Hide in bags": items the character already carries (bags, bank, or
-- equipped) - looted, waiting to be attuned, no longer worth chasing.
-- ---------------------------------------------------------------------
-- Equipped items are not counted by GetItemCount on 3.3.5, so the 19
-- inventory slots are read once per pass and cached until the next
-- bag / equipment event.
-- One set of owned item ids per bag/bank/equipment change, built by walking
-- the containers (about 300 client calls). The previous IsOwned asked
-- GetItemCount per item per eligibility check: 19-36 thousand calls per
-- render with "In bags: Hide" on. Bank contents are known to the client
-- once the bank has been opened this session, as before.
local ownedSet
local function OwnedSet()
    if ownedSet then return ownedSet end
    ownedSet = {}
    perf.ownedCalls = perf.ownedCalls + 1
    local invLink = _G.GetInventoryItemLink
    if invLink then
        for slot = 1, 19 do
            local ok, link = pcall(invLink, "player", slot)
            local id = ok and link and tonumber(link:match("item:(%d+)"))
            if id then ownedSet[id] = true end
        end
    end
    local numSlots, cLink = _G.GetContainerNumSlots, _G.GetContainerItemLink
    if numSlots and cLink then
        local function walk(bag)
            local ok, n = pcall(numSlots, bag)
            if not ok or not n then return end
            for slot = 1, n do
                local ok2, link = pcall(cLink, bag, slot)
                local id = ok2 and link and tonumber(link:match("item:(%d+)"))
                if id then ownedSet[id] = true end
            end
        end
        local nBags = _G.NUM_BAG_SLOTS or 4
        for bag = 0, nBags do walk(bag) end
        walk(_G.BANK_CONTAINER or -1)
        for bag = nBags + 1, nBags + (_G.NUM_BANKBAGSLOTS or 7) do walk(bag) end
    end
    return ownedSet
end

function Engine.InvalidateOwned()
    ownedSet = nil
end

function Engine.IsOwned(itemId)
    return OwnedSet()[itemId] == true
end

function Engine.Eligible(itemId)
    if not (ANx.CanCount(itemId) and ANx.FactionAllowed(itemId)) then return false end
    if ANx.db and ANx.db.hideInBags and Engine.IsOwned(itemId) then return false end
    -- an item ONLY obtainable from the other faction's quests is as
    -- faction-locked as any Alliance-only drop, even without an item flag
    local fac = ANx.db and ANx.db.faction
    if fac and fac ~= "both" then
        local qs = Engine.ItemQuestSide(itemId)
        if qs and qs ~= fac then return false end
    end
    -- under Character scope with the quest-class filter on, a reward whose
    -- every quest is impossible for this character is unreachable: hide it
    if ANx.db and ANx.db.scope == "char" and ANx.db.questClass ~= "all"
        and Engine.ItemQuestCharBlocked(itemId) then return false end
    if ANx.db and ANx.db.zoneExclusive and not Engine.IsZoneExclusive(itemId) then return false end
    if not ANx.BindAllowed(itemId) then return false end
    if not ANx.AccessoryAllowed(itemId) then return false end
    -- prestige: the manual Class filter narrows every list to one class's gear
    if ANx.db and ANx.db.prestige and (ANx.db.classFilter or "all") ~= "all"
        and not ANx.ItemUsableByClass(itemId, ANx.db.classFilter) then return false end
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
-- ---- scan-lifetime item memo --------------------------------------------
-- A world drop is listed by every open-world zone whose creatures carry it,
-- and v3.6.x re-read (and re-tabled) its rows once per zone: 42 million row
-- reads for 2.2 million real rows on a live client. Each item is now walked
-- ONCE while a background job runs, into a compact memo that every zone's
-- ZoneData reads:
--   scanMemo[itemId] = string: byte 1 = flags (bit 1: some row names a zone or
--     instance we know; bits 2-4: union of type bits over ALL rows), then one
--     (zoneOrdinal, typeBits) byte pair per ANx.Zones entry named by a row.
--     Type bits: 1 quest, 2 world drop, 4 vendor. "" = no rows.
--   qvMemo[itemId] = flat array of 4 slots per quest/vendor row, in row
--     order: kind (1 quest / 2 vendor), zone ordinal (0 = not an ANx.Zones
--     zone), objId or false, objName. Only items with such rows get one.
-- Outside a job the same builder runs without storing, so ZoneData keeps
-- working for a zone the UI asks for after the scan.
local zoneOrd            -- [zoneLower] -> index in ANx.Zones (built once)
local ordOf = {}         -- scratch: ordinal -> type bits for the item being walked
local ordList = {}       -- scratch: ordinals touched, in first-seen order
local bytes = {}         -- scratch: the memo string's bytes
local ROW_YIELD = 128    -- rows walked between slice checks inside a job
local strchar, unpack = string.char, unpack

local function ZoneOrdinals()
    if zoneOrd then return zoneOrd end
    zoneOrd = {}
    for i, z in ipairs(ANx.Zones or {}) do
        if z.name then
            local l = z.name:lower()
            if not zoneOrd[l] then zoneOrd[l] = i end
        end
    end
    return zoneOrd
end

local function BuildItemMemo(itemId, inCoroutine)
    local getCount, getAt = _G.ItemLocGetSourceCount, _G.ItemLocGetSourceAt
    if not (getCount and getAt and ANx.LootDbLoaded()) then return "", nil end
    local ord = ZoneOrdinals()
    local known = Engine.KnownZoneNameSet()
    local ZoneLower = ANx.ZoneLower
    local SRC_QUEST, SRC_VENDOR, WORLD = ANx.SRC.QUEST, ANx.SRC.VENDOR, ANx.WORLD_DROP_SRC
    local n = getCount(itemId) or 0
    perf.rowReads = perf.rowReads + n
    perf.memoItems = perf.memoItems + 1
    local rec, union, k, qv = false, 0, 0, nil
    for i = 1, n do
        if inCoroutine and i % ROW_YIELD == 0 then Engine.MaybeYield("memo-rows") end
        local srcType, _, objId, _, _, objName, zn = getAt(itemId, i)
        if srcType ~= nil then
            local zl = ZoneLower(zn)
            local o = 0
            if zl ~= "" then
                o = ord[zl] or 0
                if known[zl] then rec = true
                elseif perf.unkN < 8 and not perf.unk[zl] then
                    -- a zone name the addon does not know (localized client,
                    -- renamed or new content): keep the first eight for /an perf
                    perf.unk[zl] = true; perf.unkN = perf.unkN + 1
                end
            end
            local bit = 0
            if srcType == SRC_QUEST then bit = 1
            elseif srcType == SRC_VENDOR then bit = 4
            elseif WORLD[srcType] then bit = 2 end
            if bit ~= 0 then
                if band(union, bit) == 0 then union = union + bit end
                if srcType == SRC_QUEST or srcType == SRC_VENDOR then
                    qv = qv or {}
                    local m = #qv
                    qv[m + 1], qv[m + 2], qv[m + 3], qv[m + 4] = (bit == 1) and 1 or 2, o, objId or false, objName or "?"
                end
            end
            if o ~= 0 then
                local cur = ordOf[o]
                if not cur then
                    k = k + 1; ordList[k] = o; ordOf[o] = bit
                elseif bit ~= 0 and band(cur, bit) == 0 then
                    ordOf[o] = cur + bit
                end
            end
        end
    end
    local m
    if n == 0 then
        m = ""
    else
        bytes[1] = (rec and 1 or 0) + union * 2
        local b = 1
        for j = 1, k do
            local o = ordList[j]
            bytes[b + 1], bytes[b + 2] = o, ordOf[o]
            b = b + 2
            ordOf[o] = nil
        end
        m = strchar(unpack(bytes, 1, b))
    end
    return m, qv
end

function Engine.ZoneData(zoneEntry, inCoroutine)
    local zc = zoneCache[zoneEntry.zone]
    if zc then return zc end

    local universe = ANx.ItemsInZone(zoneEntry.zone)
    zc = {
        -- NOTE: the raw `universe` array is intentionally NOT stored - it is
        -- only needed while classifying below, and keeping one per zone was
        -- pure dead weight in the cache (and in the saved structure blob).
        quest = {},          -- itemIds with a quest source in this zone
        questList = {},      -- { {id=questId, name=questName, items={itemIds}} }
        world = {},          -- itemIds that drop from creatures/objects in this zone
        vendor = {},         -- itemIds sold by vendors in this zone
        vendorByName = {},   -- [vendorName] = { itemIds }
        vendorIdByName = {}, -- [vendorName] = npcId
    }
    local questsById = {}
    local zLower = (zoneEntry.name or ""):lower()
    local o = ZoneOrdinals()[zLower] or -1   -- -1: a name outside ANx.Zones never matches a pair
    local quest, world, vendor, questList, vendorByName, vendorIdByName =
        zc.quest, zc.world, zc.vendor, zc.questList, zc.vendorByName, zc.vendorIdByName
    if inCoroutine and not scanMemo then scanMemo, qvMemo = {}, {} end
    local memo, qvm = scanMemo, qvMemo
    local strbyte, floor = string.byte, math.floor
    local zMatched = 0
    for _, itemId in ipairs(universe) do
        if inCoroutine then Engine.MaybeYield("zone-items") end
        local m, qv
        if memo then
            m = memo[itemId]
            if m then qv = qvm[itemId]
            else
                m, qv = BuildItemMemo(itemId, inCoroutine)
                memo[itemId] = m
                if qv then qvm[itemId] = qv end
            end
        else
            m, qv = BuildItemMemo(itemId, inCoroutine)
        end
        -- The loot DB already scoped this item to THIS zone by its numeric id,
        -- so it belongs here. Rows are name-matched only to attribute the
        -- correct source type. On a localized client the server's source
        -- zoneNames won't match the addon's English names, so nothing would
        -- classify: detect that (no row names a zone we recognise) and fall
        -- back to the item's own source types (the memo's union bits).
        local flags = strbyte(m, 1) or 0
        local recognized = flags % 2 == 1
        local bits, matched = 0, false
        for p = 2, #m, 2 do
            if strbyte(m, p) == o then matched = true; bits = strbyte(m, p + 1); break end
        end
        local fallback = (not matched) and (not recognized)
        perf.zoneItems = perf.zoneItems + 1
        if matched then zMatched = zMatched + 1
        elseif fallback then perf.zoneFallback = perf.zoneFallback + 1
        else perf.zoneUnmatched = perf.zoneUnmatched + 1 end
        if fallback then bits = floor(flags / 2) end
        local isQuest, isWorld, isVendor = bits % 2 == 1, floor(bits / 2) % 2 == 1, floor(bits / 4) % 2 == 1
        if qv and (isQuest or isVendor) then
            for p = 1, #qv, 4 do
                if fallback or qv[p + 1] == o then
                    local kind, objId, objName = qv[p], qv[p + 2], qv[p + 3]
                    if kind == 1 then
                        -- a quest row with no objId is counted (isQuest) but
                        -- not indexed: questsById[nil] would raise in the job
                        if objId then
                            local q = questsById[objId]
                            if not q then
                                q = { id = objId, name = objName, items = {} }
                                questsById[objId] = q
                                questList[#questList + 1] = q
                            end
                            q.items[#q.items + 1] = itemId
                        end
                    else
                        local list = vendorByName[objName]
                        if not list then
                            list = {}
                            vendorByName[objName] = list
                        end
                        list[#list + 1] = itemId
                        if objId and objId > 0 and not vendorIdByName[objName] then
                            vendorIdByName[objName] = objId
                        end
                    end
                end
            end
        end
        if isQuest then quest[#quest + 1] = itemId end
        if isWorld then world[#world + 1] = itemId end
        if isVendor then vendor[#vendor + 1] = itemId end
    end
    table.sort(zc.questList, function(a, b) return (a.name or "") < (b.name or "") end)
    if zMatched == 0 and #universe > 0 and perf.unmatchedN < 8 then
        -- none of this zone's items named it: the server spells it differently
        perf.unmatchedN = perf.unmatchedN + 1
        perf.unmatched[perf.unmatchedN] = zoneEntry.name or tostring(zoneEntry.zone)
    end
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
    local T, R = ANx.SRC.CRAFT_TRAINER, ANx.SRC.CRAFT_RECIPE
    local craft = false
    local any = EachSourceRow(itemId, function(srcType)
        if srcType == T or srcType == R then craft = true return true end
    end)
    if not any then return true end   -- loot DB gap: benefit of the doubt
    return craft
end

function Engine.ProfessionEntries(prof, exp)
    local key = prof .. "-" .. exp
    local c = profCache[key]
    if c then return c end
    c = {}
    local dbReady = ANx.LootDbLoaded()
    local rows = ANx.ProfessionItems and ANx.ProfessionItems[prof]
    if rows and rows.ids then
        -- parallel arrays: same index across ids/spells/skills/exps
        local ids, spells, skills, exps = rows.ids, rows.spells, rows.skills, rows.exps
        for i = 1, #ids do
            -- a whole profession ran as one 15-25 ms slice inside BuildSummary
            -- (IsCraftObtained reads every recipe's rows); no-op off the pump
            Engine.MaybeYield("prof-items")
            local itemId = ids[i]
            if exps[i] == exp and ANx.IsAttunableAtAll(itemId)
                and Engine.IsCraftObtained(itemId) then
                c[#c + 1] = { id = itemId, spell = spells[i], skill = skills[i] }
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
    if ANx.db and ANx.db.hideInBags and Engine.IsOwned(itemId) then return false end
    if ANx.db and ANx.db.zoneExclusive and not Engine.IsZoneExclusive(itemId) then return false end
    if not ANx.BindAllowed(itemId) then return false end
    if not ANx.AccessoryAllowed(itemId) then return false end
    if ANx.db and ANx.db.prestige and (ANx.db.classFilter or "all") ~= "all"
        and not ANx.ItemUsableByClass(itemId, ANx.db.classFilter) then return false end
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
            if yielding then Engine.MaybeYield("whatsleft") end
            for _, e in ipairs(Engine.ProfessionEntries(prof, exp)) do
                r.craftProf[e.id] = prof
            end
        end
    end
    local universe, ready = Engine.Universe()
    r.ready = ready
    local seenCur = {}
    for _, id in ipairs(universe) do
        if yielding then Engine.MaybeYield("whatsleft") end
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
        perf.ownedCalls = perf.ownedCalls + 1
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

-- Static costs from Data_VendorCosts.lua (packed "cur:count,cur:count|..."
-- variant strings), decoded to { {name=,count=}, ... } variants
local function StaticCosts(itemId)
    local raw = ANx.VendorCosts and ANx.VendorCosts[itemId]
    if not raw then return nil end
    local out = {}
    for variant in raw:gmatch("[^|]+") do
        local cost = {}
        for idx, count in variant:gmatch("(%d+):(%d+)") do
            cost[#cost + 1] = {
                name = (ANx.VendorCurrencyNames and ANx.VendorCurrencyNames[tonumber(idx)]) or "?",
                count = tonumber(count),
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
                Engine.MaybeYield("inst")
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
        Engine.MaybeYield("zone")
    end
    -- professions
    for _, prof in ipairs(ANx.ProfessionOrder or {}) do
        for _, e in ipairs(Engine.ProfessionEntries(prof, exp)) do
            sum.C[e.id] = true
        end
        Engine.MaybeYield("prof")
    end
    sum.ready = true
    cacheDirty = true
    summaryCache[exp] = sum
end

-- Returns summary sets or nil if still scanning (auto-enqueues the scan)
function Engine.CachesWarm()
    return cachesWarm
end

function Engine._TestUnwarm()   -- regression coverage only
    cachesWarm = false
end

-- Rough cache/memory accounting for /an perf
function Engine.PerfStats()
    local function count(t)
        local n = 0
        for _ in pairs(t or {}) do n = n + 1 end
        return n
    end
    local st = {
        lua_kb = math.floor(collectgarbage("count")),
        srcCache = count(srcCache),
        srcRows = srcCacheRows,
        srcCap = srcCacheCap,
        runsKeys = count(runsCache),
        pickKeys = count(pickCache),
        clearChance = count(clearChanceCache),
        stats = count(statsCache),
        zones = count(zoneCache),
        jobs = #Engine.scanJobs,
        warm = cachesWarm,
        budget = BUDGET_MS,
        universe = Engine.universeCache and #Engine.universeCache or 0,
        flags = count(itemFlags),
    }
    for k, v in pairs(perf) do
        if type(v) ~= "table" then st[k] = v end
    end
    local names = {}
    for name in pairs(perf.unk) do names[#names + 1] = name end
    table.sort(names)
    st.unknownZones = (#names > 0) and table.concat(names, ", ") or "none"
    st.unmatchedZones = (perf.unmatchedN > 0) and table.concat(perf.unmatched, ", ") or "none"
    return st
end

-- /an srcstats: the real loot DB's shape, which every cache cap in the
-- engine depends on and which the headless harness can only guess at. Runs
-- as a pump job: one count call per universe item (no row tables), a
-- rows-per-item histogram, the heaviest items, and for items with 1000+
-- rows how many open-world zones list them (rows x listings is the term
-- behind the v3.6.2 crash). Prints when done.
local SRC_BUCKETS = { 0, 1, 2, 5, 10, 50, 100, 500, 1000, 5000 }
function Engine.SourceStats(onDone)
    if not (ANx.LootDbLoaded() and _G.ItemLocGetSourceCount) then
        ANx.Print("srcstats: loot DB not loaded")
        return
    end
    local items, ready = Engine.Universe()
    if not ready then
        ANx.Print("srcstats: waiting for the login scan to finish; try again in a moment")
        return
    end
    Engine.Enqueue(function()
        local getCount, getAt = _G.ItemLocGetSourceCount, _G.ItemLocGetSourceAt
        local counts, heavy, total, n = {}, {}, 0, 0
        local heavyRows = {}
        for _, id in ipairs(items) do
            Engine.MaybeYield("srcstats")
            local ok, c = pcall(getCount, id)
            c = (ok and c) or 0
            n = n + 1
            total = total + c
            local b = #SRC_BUCKETS
            for i = 1, #SRC_BUCKETS do
                if c <= SRC_BUCKETS[i] then b = i break end
            end
            counts[b] = (counts[b] or 0) + 1
            if c >= 1000 then heavy[#heavy + 1] = id; heavyRows[id] = c end
        end
        table.sort(heavy, function(a, b) return heavyRows[a] > heavyRows[b] end)
        -- how many zones list each heavy item (the scan walks it once per zone)
        local listings, heavySet = {}, {}
        for _, id in ipairs(heavy) do heavySet[id] = true end
        local zonesListed = 0
        if #heavy > 0 then
            for _, z in ipairs(ANx.Zones or {}) do
                Engine.YieldNow("srcstats")
                for _, id in ipairs(ANx.ItemsInZone(z.zone)) do
                    if heavySet[id] then listings[id] = (listings[id] or 0) + 1 end
                end
                zonesListed = zonesListed + 1
            end
        end
        -- source-type mix and unknown zone names on a bounded sample of the
        -- heaviest items (their rows dominate the scan)
        local typeN, sampled, unknownN = {}, 0, 0
        local known = Engine.KnownZoneNameSet()
        for i = 1, math.min(#heavy, 20) do
            Engine.YieldNow("srcstats")
            local id = heavy[i]
            for r = 1, heavyRows[id] do
                local st, _, _, _, _, _, zn = getAt(id, r)
                if st ~= nil then
                    typeN[st] = (typeN[st] or 0) + 1
                    if zn and zn ~= "" and not known[zn:lower()] then unknownN = unknownN + 1 end
                end
            end
            sampled = sampled + 1
        end
        local lines = {}
        lines[#lines + 1] = string.format("srcstats: %d items, %d source rows, %.1f rows/item avg", n, total, n > 0 and total / n or 0)
        local parts, lo = {}, 0
        for i = 1, #SRC_BUCKETS do
            local c = counts[i] or 0
            if c > 0 then
                parts[#parts + 1] = string.format("%s%d:%d", (SRC_BUCKETS[i] <= lo + 1) and "" or ((lo + 1) .. "-"), SRC_BUCKETS[i], c)
            end
            lo = SRC_BUCKETS[i]
        end
        if (counts[#SRC_BUCKETS] or 0) > 0 then parts[#parts] = string.format(">%d:%d", SRC_BUCKETS[#SRC_BUCKETS - 1], counts[#SRC_BUCKETS]) end
        lines[#lines + 1] = "rows-per-item buckets (rows:items): " .. table.concat(parts, "  ")
        local rowsXlist = 0
        for _, id in ipairs(heavy) do rowsXlist = rowsXlist + heavyRows[id] * (listings[id] or 0) end
        lines[#lines + 1] = string.format("heavy items (1000+ rows): %d, %d rows, listed in %d zones scanned, rows x listings %d",
            #heavy, (function() local s = 0 for _, id in ipairs(heavy) do s = s + heavyRows[id] end return s end)(), zonesListed, rowsXlist)
        for i = 1, math.min(#heavy, 10) do
            local id = heavy[i]
            lines[#lines + 1] = string.format("  %s (%d): %d rows, in %d zones", ANx.GetItemDisplay(id, true), id, heavyRows[id], listings[id] or 0)
        end
        if sampled > 0 then
            local tp = {}
            for st, c in pairs(typeN) do tp[#tp + 1] = string.format("type%d:%d", st, c) end
            table.sort(tp)
            lines[#lines + 1] = string.format("source types over the %d heaviest: %s; rows naming an unknown zone: %d", sampled, table.concat(tp, " "), unknownN)
        end
        ANx.srcStatsLines = lines
        for _, l in ipairs(lines) do ANx.Print(l) end
        if onDone then pcall(onDone) end
    end, nil, "srcstats")
    ANx.Print("srcstats: walking the loot DB in the background...")
end

-- /an perf reset: zero the counters (after a /an reset rescan, say)
function Engine.PerfReset()
    for k, v in pairs(perf) do
        if type(v) == "number" then perf[k] = 0
        elseif type(v) == "string" then perf[k] = "-"
        elseif type(v) == "table" then perf[k] = {} end
    end
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
    EachSourceRow(itemId, function(srcType, _, _, chance)
        if DROP_SRC[srcType] and chance > 0 and ((not best) or chance > best) then best = chance end
    end)
    return best
end

-- "node" bucket key for the focus-most-left option: which zone / instance /
-- profession / currency an item primarily belongs to.
function Engine.ItemBucket(itemId)
    local _, srcName, srcType, _, zone = Engine.BestSource(itemId)
    if srcType == ANx.SRC.VENDOR then
        local costs = Engine.ItemCurrencies(itemId)
        return "$" .. ((costs and costs[1] and costs[1].name) or "Vendor")
    elseif srcType == ANx.SRC.CRAFT_TRAINER or srcType == ANx.SRC.CRAFT_RECIPE then
        return "@" .. (ANx.ProfessionOfItem(itemId) or "Crafting")
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
-- Cached in the consolidated flag table (0 unknown, 1 can't-say, else lvl+2).
function Engine.ItemMinLevel(id)
    local f = itemFlags[id]
    local c = f and band(rshift(f, F_MINLVL), 1023) or 0
    if c ~= 0 then
        if c == 1 then return nil end
        return c - 2
    end
    local name, _, _, _, minLvl = (_G.GetItemInfoCustom or _G.GetItemInfo or function() end)(id)
    if name == nil and minLvl == nil then
        FSet(id, F_MINLVL, 1023, 1)   -- unknown to the client (so far)
        return nil
    end
    local v = tonumber(minLvl) or 0
    if v < 0 then v = 0 elseif v > 1000 then v = 1000 end
    FSet(id, F_MINLVL, 1023, v + 2)
    return v
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
        if yielding then Engine.MaybeYield("pick") end
        if not seen[id] and not ignore[id] and Engine.Eligible(id)
            and not ANx.CountDone(id) and Engine.HasAnySource(id)
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
    local dropOf = {}
    if a.dropRate then
        local dp = {}
        for _, id in ipairs(pool) do
            if yielding then Engine.MaybeYield("pick") end
            local c = Engine.ItemBestDropChance(id)
            if c then dp[#dp + 1] = id; dropOf[id] = c end
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
            return (dropOf[x] or 0) > (dropOf[y] or 0)
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
    if not view then return (which or "btn") .. "|global" end
    -- content-derived key: a fresh view TABLE is pushed on every navigation,
    -- so the old tostring(view) address key could never hit on a revisit and
    -- re-ran the full background pick per screen. items-views key on their
    -- item list's identity (same view object -> same list -> cache hit).
    return (which or "btn") .. "|" .. (view.type or "")
        .. ":" .. tostring(view.exp or "")
        .. ":" .. tostring(view.kind or view.content or "")
        .. ":" .. tostring(view.mode or "")
        .. ":" .. tostring(view.zoneEntry and view.zoneEntry.zone or "")
        .. ":" .. tostring(view.itemId or view.questId or "")
        .. ":" .. (view.items and tostring(view.items) or "")
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
    -- MobCountPacked: sorted hex records, counts pre-capped (Data_MobCounts)
    local n = objId and ANx.MobCountPacked
        and ANx.PackedFind(ANx.MobCountPacked, objId, 2)
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
    local chance, srcName, srcType, restricted, zname, objId = Engine.BestSource(itemId, zoneName, srcFilter)
    local out
    if not chance or chance <= 0 then
        out = 0
    else
        local p = chance / 100
        if p >= 1 then
            out = 1
        else
            local n = Engine.SpawnCount(objId)
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
                    if yielding then Engine.YieldNow("rank") end
                    if ANx.DifficultyMatches(d.label, inst.map) then
                        local instKey = inst.map .. ":" .. d.diff
                        if not ignoreInst[instKey] then
                            local expected, count = 0, 0
                            for _, id in ipairs(d.items) do
                                if yielding then Engine.MaybeYield("rank") end
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
        if yielding then Engine.YieldNow("rank") end
        local key = "z:" .. z.zone
        if not ignoreInst[key]
            and (not scopeExp or z.exp == scopeExp)
            and (not levelOn or Engine.ZoneMinLevel(z) <= charLvl) then
            local expected, count, items = 0, 0, {}
            for _, id in ipairs(ANx.ItemsInZone(z.zone) or {}) do
                if yielding then Engine.MaybeYield("rank") end
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
                if ANx.DifficultyMatches(d.label, inst.map) then
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
