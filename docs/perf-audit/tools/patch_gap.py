import sys, re
root = sys.argv[1]
def rep(path, old, new, count=1):
    s = open(path).read()
    assert s.count(old) == count, (path, old[:60], s.count(old))
    s = s.replace(old, new)
    open(path, 'w').write(s)

C = root + '/Core.lua'
E = root + '/Engine.lua'

# ---------------- Core.lua ----------------
rep(C, """    return l
end

function ANx.GetSources(itemId)""", """    return l
end
ANx.ZoneLower = ZoneLower   -- Engine streams rows and lowers zone names itself

function ANx.GetSources(itemId)""")

rep(C, """    elseif msg == "reset" then
        if ANx.Engine then ANx.Engine.ForceRescan() end""", """    elseif msg == "srcstats" then
        -- /an srcstats : background histogram of the loot DB's shape (rows per
        -- item, zone multiplicity, unrecognised zone names) for tuning
        if ANx.Engine and ANx.Engine.SourceStats then ANx.Engine.SourceStats() end
    elseif msg == "reset" then
        if ANx.Engine then ANx.Engine.ForceRescan() end""")

# ---------------- Engine.lua ----------------
# 1. locals + streaming helpers
rep(E, """local itemFlags = ANx.ItemFlags
local band, lshift, rshift = bit.band, bit.lshift, bit.rshift""", """local itemFlags = ANx.ItemFlags
local band, lshift, rshift, bor = bit.band, bit.lshift, bit.rshift, bit.bor
local ZoneLower = ANx.ZoneLower      -- memoized lower-case zone names (Core.lua)
-- Streaming row access: the per-item predicates and the zone classifier
-- used to go through Engine.Sources, i.e. build one 9-field table per
-- source row just to answer a yes/no. World-drop items list thousands of
-- creatures, so each cold predicate on one of them was thousands of
-- allocations (and an eviction of the whole bounded source cache). They now
-- read rows straight off the server API, stop at the first decisive row,
-- and allocate nothing. Row loops yield every ROW_YIELD rows when run from
-- a job, so one heavy item can no longer own a whole frame.
local ROW_YIELD = 1000
local function SrcApi()
    if not ANx.LootDbLoaded() then return nil end
    local c, a = _G.ItemLocGetSourceCount, _G.ItemLocGetSourceAt
    if c and a then return c, a end
    return nil
end
local zoneMemo            -- scan-lifetime per-item zone classification memo (see ZoneData)
local zoneBest = {}       -- per-item best-row index by zone (see BestSource)
local zoneBestN, zoneBestSlots = 0, 0
local ZONEBEST_ITEM_CAP, ZONEBEST_SLOT_CAP = 6000, 400000""")

# 2. InvalidateAll drops memo + index
rep(E, """    cachesWarm = false
    warmed = {}            -- every predicate must be swept again
    srcCacheCap = 3000     -- warmup re-runs; give it the big working set again""", """    cachesWarm = false
    warmed = {}            -- every predicate must be swept again
    srcCacheCap = 3000     -- warmup re-runs; give it the big working set again
    zoneMemo = nil
    zoneBest, zoneBestN, zoneBestSlots = {}, 0, 0""")

# 3. yields
rep(E, """function Engine.YieldNow()
    if coroutine.running() then
        yieldCheck = 0
        coroutine.yield()
    end
end""", """function Engine.YieldNow()
    if coroutine.running() then
        yieldCheck = 0
        coroutine.yield()
    end
end

-- Row-weighted yield: callers that just walked n source rows add them here,
-- so a run of small items and a run of heavy items both yield after about
-- the same amount of work (the item-count MaybeYield alone let a 25-item
-- slice of world drops run for 25,000+ rows).
local rowCheck = 0
function Engine.YieldRows(n)
    rowCheck = rowCheck + n
    if rowCheck >= ROW_YIELD then
        rowCheck = 0
        yieldCheck = 0
        if coroutine.running() then coroutine.yield() end
    end
end""")

# 4. pump: drop the memo when the queue drains
rep(E, """        if #Engine.scanJobs == 0 then
            Engine.scanning = false
            -- persist the structural cache ONLY when a scan actually changed""", """        if #Engine.scanJobs == 0 then
            Engine.scanning = false
            zoneMemo = nil     -- the per-item zone memo only serves the scan
            -- persist the structural cache ONLY when a scan actually changed""")

# 5. warmup passes yielding=true
rep(E, """        if doQSide then Engine.ItemQuestSide(id) end
        if doQChar then Engine.ItemQuestCharBlocked(id) end
        if doZex then Engine.IsZoneExclusive(id) end""", """        if doQSide then Engine.ItemQuestSide(id, true) end
        if doQChar then Engine.ItemQuestCharBlocked(id, true) end
        if doZex then Engine.IsZoneExclusive(id, true) end""")

# 6. IsQuestOnly streaming
rep(E, """function Engine.IsQuestOnly(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QONLY), 3) or 0
    if c ~= 0 then return c == 2 end
    local v
    local srcs = Engine.Sources(itemId)
    if #srcs == 0 then
        v = false
    else
        v = true
        for _, src in ipairs(srcs) do
            if src.srcType ~= ANx.SRC.QUEST then v = false break end
        end
    end
    FSet(itemId, F_QONLY, 3, v and 2 or 1)
    return v
end""", """function Engine.IsQuestOnly(itemId, yielding)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QONLY), 3) or 0
    if c ~= 0 then return c == 2 end
    -- stream: the first non-quest row decides (a world drop costs one row)
    local v, seen = true, false
    local getCount, getAt = SrcApi()
    local n = getCount and (getCount(itemId) or 0) or 0
    local SRC_QUEST = ANx.SRC.QUEST
    for i = 1, n do
        local st = getAt(itemId, i)
        if st ~= nil then
            seen = true
            if st ~= SRC_QUEST then v = false break end
        end
        if yielding and i % ROW_YIELD == 0 then Engine.YieldNow() end
    end
    v = v and seen
    FSet(itemId, F_QONLY, 3, v and 2 or 1)
    return v
end""")

# 7. ItemHasRareSource / ItemIsUniqueToZone / IsZoneExclusive streaming
rep(E, """function Engine.ItemHasRareSource(itemId, zoneName)
    if not ANx.RareNPCs then return false end
    local zTarget = zoneName and zoneName:lower()
    for _, s in ipairs(Engine.Sources(itemId)) do
        if (s.srcType == ANx.SRC.CREATURE or s.srcType == ANx.SRC.MYTHIC_CREATURE)
            and s.objId and ANx.RareNPCs[s.objId] then
            if not zTarget or (s.zoneLower or "") == zTarget then
                return true
            end
        end
    end
    return false
end""", """function Engine.ItemHasRareSource(itemId, zoneName)
    local rare = ANx.RareNPCs
    if not rare then return false end
    local getCount, getAt = SrcApi()
    if not getCount then return false end
    local zTarget = zoneName and ZoneLower(zoneName)
    local CREATURE, MYTHIC = ANx.SRC.CREATURE, ANx.SRC.MYTHIC_CREATURE
    local n = getCount(itemId) or 0
    for i = 1, n do
        local st, _, objId, _, _, _, zn = getAt(itemId, i)
        if (st == CREATURE or st == MYTHIC) and objId and rare[objId] then
            if not zTarget or ZoneLower(zn) == zTarget then return true end
        end
    end
    return false
end""")

rep(E, """function Engine.ItemIsUniqueToZone(itemId, zoneName)
    if not zoneName then return true end
    local zTarget = zoneName:lower()
    local inThisZone = false
    for _, s in ipairs(Engine.Sources(itemId)) do
        local zn = s.zoneName
        if zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            if s.zoneLower == zTarget then
                inThisZone = true
            else
                return false   -- found a source in a different zone
            end
        end
    end
    return inThisZone
end""", """function Engine.ItemIsUniqueToZone(itemId, zoneName)
    if not zoneName then return true end
    local zTarget = ZoneLower(zoneName)
    local inThisZone = false
    local getCount, getAt = SrcApi()
    local n = getCount and (getCount(itemId) or 0) or 0
    for i = 1, n do
        local st, _, _, _, _, _, zn = getAt(itemId, i)
        if st ~= nil and zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            if ZoneLower(zn) == zTarget then
                inThisZone = true
            else
                return false   -- found a source in a different zone
            end
        end
    end
    return inThisZone
end""")

rep(E, """function Engine.IsZoneExclusive(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_ZEX), 3) or 0
    if c ~= 0 then return c == 2 end
    local zone, multiple = nil, false
    for _, s in ipairs(Engine.Sources(itemId)) do
        local zn = s.zoneName
        if zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            if zone == nil then zone = zn:lower()
            elseif zone ~= zn:lower() then multiple = true break end
        end
    end
    local v = (zone ~= nil) and (not multiple)
    FSet(itemId, F_ZEX, 3, v and 2 or 1)
    return v
end""", """function Engine.IsZoneExclusive(itemId, yielding)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_ZEX), 3) or 0
    if c ~= 0 then return c == 2 end
    local zone, multiple = nil, false
    local getCount, getAt = SrcApi()
    local n = getCount and (getCount(itemId) or 0) or 0
    for i = 1, n do
        local st, _, _, _, _, _, zn = getAt(itemId, i)
        if st ~= nil and zn and zn ~= "" and zn ~= "Unknown" and zn ~= "?" then
            local zl = ZoneLower(zn)
            if zone == nil then zone = zl
            elseif zone ~= zl then multiple = true break end
        end
        if yielding and i % ROW_YIELD == 0 then Engine.YieldNow() end
    end
    local v = (zone ~= nil) and (not multiple)
    FSet(itemId, F_ZEX, 3, v and 2 or 1)
    return v
end""")

# 8. ItemQuestSide / ItemQuestCharBlocked streaming
rep(E, """function Engine.ItemQuestSide(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QSIDE), 3) or 0
    if c ~= 0 then return (c == 2 and "A") or (c == 3 and "H") or nil end
    if not Engine.IsQuestOnly(itemId) then
        FSet(itemId, F_QSIDE, 3, 1)
        return nil
    end
    local side
    for _, src in ipairs(Engine.Sources(itemId)) do
        if src.srcType == ANx.SRC.QUEST then
            local qs = ANx.QuestFactionSide(src.objId)
            if not qs or (side and side ~= qs) then
                FSet(itemId, F_QSIDE, 3, 1)
                return nil
            end
            side = qs
        end
    end""", """function Engine.ItemQuestSide(itemId, yielding)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QSIDE), 3) or 0
    if c ~= 0 then return (c == 2 and "A") or (c == 3 and "H") or nil end
    if not Engine.IsQuestOnly(itemId, yielding) then
        FSet(itemId, F_QSIDE, 3, 1)
        return nil
    end
    -- quest-only items have a handful of rows: stream them
    local side
    local getCount, getAt = SrcApi()
    local n = getCount and (getCount(itemId) or 0) or 0
    local SRC_QUEST = ANx.SRC.QUEST
    for i = 1, n do
        local st, _, objId = getAt(itemId, i)
        if st == SRC_QUEST then
            local qs = ANx.QuestFactionSide(objId)
            if not qs or (side and side ~= qs) then
                FSet(itemId, F_QSIDE, 3, 1)
                return nil
            end
            side = qs
        end
    end""")

rep(E, """function Engine.ItemQuestCharBlocked(itemId)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QCHAR), 3) or 0
    if c ~= 0 then return c == 2 end
    local blocked = false
    if Engine.IsQuestOnly(itemId) then
        blocked = true
        for _, src in ipairs(Engine.Sources(itemId)) do
            if src.srcType == ANx.SRC.QUEST and ANx.CharCanDoQuest(src.objId) then
                blocked = false
                break
            end
        end
    end""", """function Engine.ItemQuestCharBlocked(itemId, yielding)
    local f = itemFlags[itemId]
    local c = f and band(rshift(f, F_QCHAR), 3) or 0
    if c ~= 0 then return c == 2 end
    local blocked = false
    if Engine.IsQuestOnly(itemId, yielding) then
        blocked = true
        local getCount, getAt = SrcApi()
        local n = getCount and (getCount(itemId) or 0) or 0
        local SRC_QUEST = ANx.SRC.QUEST
        for i = 1, n do
            local st, _, objId = getAt(itemId, i)
            if st == SRC_QUEST and ANx.CharCanDoQuest(objId) then
                blocked = false
                break
            end
        end
    end""")

# 9. IsCraftObtained streaming
rep(E, """function Engine.IsCraftObtained(itemId)
    local sources = Engine.Sources(itemId)
    if #sources == 0 then return true end   -- loot DB gap: benefit of the doubt
    for _, s in ipairs(sources) do
        if s.srcType == ANx.SRC.CRAFT_TRAINER or s.srcType == ANx.SRC.CRAFT_RECIPE then
            return true
        end
    end
    return false
end""", """function Engine.IsCraftObtained(itemId)
    local getCount, getAt = SrcApi()
    if not getCount then return true end
    local n = getCount(itemId) or 0
    local T, R = ANx.SRC.CRAFT_TRAINER, ANx.SRC.CRAFT_RECIPE
    local seen = false
    for i = 1, n do
        local st = getAt(itemId, i)
        if st ~= nil then
            seen = true
            if st == T or st == R then return true end
        end
    end
    if not seen then return true end   -- loot DB gap: benefit of the doubt
    return false
end""")

# 10. ZoneData with per-item memo
old_zd_start = """    local questsById = {}
    local known = Engine.KnownZoneNameSet()
    local zLower = (zoneEntry.name or ""):lower()
    for _, itemId in ipairs(universe) do
        if inCoroutine then Engine.MaybeYield() end
        local sources = Engine.Sources(itemId)"""
s = open(E).read()
a = s.index(old_zd_start)
b = s.index("""    table.sort(zc.questList, function(a, b) return (a.name or "") < (b.name or "") end)
    zoneCache[zoneEntry.zone] = zc
    return zc
end""", a)
new_zd = """    local questsById = {}
    local zLower = (zoneEntry.name or ""):lower()
    -- One streamed source walk per item for the WHOLE scan: a world drop is
    -- listed in dozens of zones, and ZoneData used to rebuild its thousands
    -- of rows once per zone. The memo keeps, per item, only what the zone
    -- classifier reads (per-zone type bits plus the few quest/vendor rows)
    -- and is dropped when the job queue drains.
    local memo = zoneMemo
    if not memo and inCoroutine then memo = {}; zoneMemo = memo end
    local SRC_QUEST, SRC_VENDOR = ANx.SRC.QUEST, ANx.SRC.VENDOR
    for _, itemId in ipairs(universe) do
        if inCoroutine then Engine.MaybeYield() end
        local m = memo and memo[itemId]
        if not m then
            m = BuildZoneMemo(itemId, inCoroutine)
            if memo then memo[itemId] = m end
        end
        -- The loot DB already scoped this item to THIS zone by its numeric id,
        -- so it belongs here. Source rows are name-matched only to attribute
        -- the source type; when no row names a zone we recognise (localized
        -- client) fall back to the item's own source types.
        local bits = m[zLower]
        local fallback = false
        if bits == nil then
            if m[2] then bits = 0 else fallback = true; bits = m[1] end
        end
        if band(bits, 1) ~= 0 then
            local q = m.Q
            if q then
                local indexed = 0
                for k = 1, #q, 3 do
                    if fallback or q[k + 2] == zLower then
                        local objId = q[k]
                        -- a quest row with no objId counts but is not indexed;
                        -- in fallback mode only the first few rows are indexed
                        -- (every zone listing the item would otherwise absorb
                        -- all of its quests)
                        if objId and (not fallback or indexed < FALLBACK_INDEX_CAP) then
                            indexed = indexed + 1
                            local qq = questsById[objId]
                            if not qq then
                                qq = { id = objId, name = q[k + 1], items = {} }
                                questsById[objId] = qq
                                zc.questList[#zc.questList + 1] = qq
                            end
                            qq.items[#qq.items + 1] = itemId
                        end
                    end
                end
            end
            zc.quest[#zc.quest + 1] = itemId
        end
        if band(bits, 2) ~= 0 then zc.world[#zc.world + 1] = itemId end
        if band(bits, 4) ~= 0 then
            local v = m.V
            if v then
                local indexed = 0
                for k = 1, #v, 3 do
                    if fallback or v[k + 2] == zLower then
                        if not fallback or indexed < FALLBACK_INDEX_CAP then
                            indexed = indexed + 1
                            local objId, objName = v[k], v[k + 1]
                            local list = zc.vendorByName[objName]
                            if not list then
                                list = {}
                                zc.vendorByName[objName] = list
                            end
                            list[#list + 1] = itemId
                            if objId > 0 and not zc.vendorIdByName[objName] then
                                zc.vendorIdByName[objName] = objId
                            end
                        end
                    end
                end
            end
            zc.vendor[#zc.vendor + 1] = itemId
        end
    end
"""
s = s[:a] + new_zd + s[b:]
# BuildZoneMemo definition before Engine.ZoneData
s = s.replace("""-- Builds and caches the classification for one zone. Safe to call from a
-- coroutine (yields periodically) or synchronously.
function Engine.ZoneData(zoneEntry, inCoroutine)""", """-- Per-item zone classification memo: m[1] = type bits over every row (the
-- localized-client fallback), m[2] = true when any row names a zone we know,
-- m[<zoneLower>] = type bits of the rows in that zone (bits: 1 quest, 2 world
-- drop, 4 vendor), m.Q / m.V = flat {objId|false, name, zoneLower, ...} for
-- the quest / vendor rows (the only rows the classifier indexes). Creature
-- rows, however many, leave only a bit per zone behind.
local FALLBACK_INDEX_CAP = 8     -- quest/vendor rows indexed per item per zone in fallback mode
local MEMO_ROW_CAP = 256         -- quest/vendor rows kept per item (beyond: counted, not indexed)
local function BuildZoneMemo(itemId, yielding)
    local m = { 0, false }
    local getCount, getAt = SrcApi()
    if not getCount then return m end
    local known = Engine.KnownZoneNameSet()
    local SRC_QUEST, SRC_VENDOR, WORLD = ANx.SRC.QUEST, ANx.SRC.VENDOR, ANx.WORLD_DROP_SRC
    local n = getCount(itemId) or 0
    local fb, rec = 0, false
    for i = 1, n do
        local st, _, objId, _, _, objName, zoneName = getAt(itemId, i)
        if st ~= nil then
            local zl = ZoneLower(zoneName)
            local b = 0
            if st == SRC_QUEST then
                b = 1
                local q = m.Q
                if not q then q = {}; m.Q = q end
                if #q < MEMO_ROW_CAP * 3 then
                    q[#q + 1] = objId or false; q[#q + 1] = objName or "?"; q[#q + 1] = zl
                end
            elseif st == SRC_VENDOR then
                b = 4
                local v = m.V
                if not v then v = {}; m.V = v end
                if #v < MEMO_ROW_CAP * 3 then
                    v[#v + 1] = objId or 0; v[#v + 1] = objName or "?"; v[#v + 1] = zl
                end
            elseif WORLD[st] then
                b = 2
            end
            if b ~= 0 then fb = bor(fb, b) end
            if zl ~= "" and known[zl] then
                rec = true
                local cur = m[zl]
                if cur == nil then m[zl] = b elseif b ~= 0 then m[zl] = bor(cur, b) end
            end
        end
        if yielding and i % ROW_YIELD == 0 then Engine.YieldNow() end
    end
    m[1], m[2] = fb, rec
    if yielding then Engine.YieldRows(n) end
    return m
end

-- Builds and caches the classification for one zone. Safe to call from a
-- coroutine (yields periodically) or synchronously.
function Engine.ZoneData(zoneEntry, inCoroutine)""")
open(E, 'w').write(s)

# 11. BestSource via per-item zone index
s = open(E).read()
a = s.index("""local function SourceUsable(s)
    if s.srcType ~= ANx.SRC.QUEST or not s.objId then return true end
    return ANx.CharCanDoQuest(s.objId)
end""")
b = s.index("""-- ---------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------""", a)
new_bs = """-- Per-item best-row index. One streamed pass over an item's rows records,
-- for every zone the rows name (and for "anywhere" under key 1), the best
-- usable and the best blocked row PER SOURCE TYPE. Any (zone, srcFilter)
-- query is then answered from that index without touching the rows again,
-- so a world drop listed in 40 zones costs one walk per session instead of
-- one per zone per render (and per InvalidateStats). Entries are flat
-- arrays of 11 slots per type: st, uChance, uName, uId, uZone, uRow,
-- bChance, bName, bId, bZone, bRow (row = first row index, keeps the old
-- "first row wins ties" order). Bounded by items and slots, flushed wholesale.
local function IdxUpdate(idx, key, st, usable, chance, objName, objId, zoneName, row)
    local list = idx[key]
    if not list then list = {}; idx[key] = list; zoneBestSlots = zoneBestSlots + 11 end
    local k = 1
    while k <= #list and list[k] ~= st do k = k + 11 end
    if k > #list then
        list[k] = st
        for j = 1, 10 do list[k + j] = false end
        zoneBestSlots = zoneBestSlots + 11
    end
    local o = usable and k + 1 or k + 6
    local cur = list[o]
    if cur == false or chance > cur then
        list[o], list[o + 1], list[o + 2], list[o + 3], list[o + 4] = chance, objName, objId, zoneName, row
    end
end

local function BuildZoneBest(itemId)
    local idx = {}
    local getCount, getAt = SrcApi()
    if not getCount then return idx, false end
    local SRC_QUEST = ANx.SRC.QUEST
    local CanDo = ANx.CharCanDoQuest
    local n = getCount(itemId) or 0
    for i = 1, n do
        local st, _, objId, chance, _, objName, zoneName = getAt(itemId, i)
        if st ~= nil then
            chance = chance or 0; objName = objName or "?"; zoneName = zoneName or ""
            local usable = st ~= SRC_QUEST or not objId or CanDo(objId)
            IdxUpdate(idx, 1, st, usable, chance, objName, objId, zoneName, i)
            IdxUpdate(idx, ZoneLower(zoneName), st, usable, chance, objName, objId, zoneName, i)
        end
    end
    return idx, true
end

-- best row over the types the filter allows: usable beats blocked, then
-- higher chance, then the earlier row
local function IdxPick(list, srcFilter)
    if not list then return nil end
    local bc, bu, bn, bt, bz, bi, br
    for k = 1, #list, 11 do
        local st = list[k]
        if (not srcFilter) or srcFilter[st] then
            local c = list[k + 1]
            if c ~= false and (bc == nil or not bu or c > bc or (c == bc and list[k + 5] < br)) then
                bc, bu, bn, bt, bz, bi, br = c, true, list[k + 2], st, list[k + 4], list[k + 3], list[k + 5]
            end
            c = list[k + 6]
            if c ~= false and (bc == nil or (not bu and (c > bc or (c == bc and list[k + 10] < br)))) then
                bc, bu, bn, bt, bz, bi, br = c, false, list[k + 7], st, list[k + 9], list[k + 8], list[k + 10]
            end
        end
    end
    return bc, bn, bt, bz, bi
end

function Engine.InvalidateBestSource()
    zoneBest, zoneBestN, zoneBestSlots = {}, 0, 0
end

-- Returns chance, sourceName, srcType, restricted(bool), zoneName, objId
function Engine.BestSource(itemId, zoneName, srcFilter)
    local idx = zoneBest[itemId]
    if not idx then
        if zoneBestN >= ZONEBEST_ITEM_CAP or zoneBestSlots >= ZONEBEST_SLOT_CAP then
            zoneBest, zoneBestN, zoneBestSlots = {}, 0, 0
        end
        local loaded
        idx, loaded = BuildZoneBest(itemId)
        if loaded then zoneBest[itemId] = idx; zoneBestN = zoneBestN + 1 end
    end
    if zoneName then
        local c, name, st, zn, id = IdxPick(idx[ZoneLower(zoneName)], srcFilter)
        if c then return c, name, st, true, zn, id end
    end
    local c, name, st, zn, id = IdxPick(idx[1], srcFilter)
    if c then return c, name, st, false, zn, id end
    return nil
end

"""
s = s[:a] + new_bs + s[b:]
open(E, 'w').write(s)

# ClearChance uses objId return
rep(E, """    local chance, srcName, srcType, restricted, zname, src = Engine.BestSource(itemId, zoneName, srcFilter)""",
       """    local chance, srcName, srcType, restricted, zname, srcObjId = Engine.BestSource(itemId, zoneName, srcFilter)""")
rep(E, """            local n = Engine.SpawnCount(src and src.objId)""", """            local n = Engine.SpawnCount(srcObjId)""")

# InvalidateStats also drops the index? NO: rows do not change with filters. Only InvalidateAll (done) and quest-doable changes.
rep(C, """function ANx.InvalidateQuestDoable()
    questDoable = {}
end""", """function ANx.InvalidateQuestDoable()
    questDoable = {}
    if ANx.Engine and ANx.Engine.InvalidateBestSource then ANx.Engine.InvalidateBestSource() end
end""")

# 12. ItemBestDropChance via index; picker precompute
rep(E, """function Engine.ItemBestDropChance(itemId)
    local best
    for _, s in ipairs(Engine.Sources(itemId)) do
        if DROP_SRC[s.srcType] and s.chance and s.chance > 0 then
            if not best or s.chance > best then best = s.chance end
        end
    end
    return best
end""", """function Engine.ItemBestDropChance(itemId)
    local c = Engine.BestSource(itemId, nil, DROP_SRC)
    if c and c > 0 then return c end
    return nil
end""")
rep(E, """    local rankByDrop = false
    if a.dropRate then
        local dp = {}
        for _, id in ipairs(pool) do
            if Engine.ItemBestDropChance(id) then dp[#dp + 1] = id end
        end
        if #dp > 0 then pool = dp; rankByDrop = true end
    end""", """    local rankByDrop = false
    local dropOf
    if a.dropRate then
        local dp = {}
        dropOf = {}
        for _, id in ipairs(pool) do
            if yielding then Engine.MaybeYield() end
            local c = Engine.ItemBestDropChance(id)
            if c then dp[#dp + 1] = id; dropOf[id] = c end
        end
        if #dp > 0 then pool = dp; rankByDrop = true end
    end""")
rep(E, """        table.sort(pool, function(x, y)
            return (Engine.ItemBestDropChance(x) or 0) > (Engine.ItemBestDropChance(y) or 0)
        end)""", """        -- chances were computed once above: the comparator used to re-walk
        -- both items' rows on every comparison
        table.sort(pool, function(x, y)
            return (dropOf[x] or 0) > (dropOf[y] or 0)
        end)""")

# 13. PerfStats
rep(E, """        zones = count(zoneCache),
        jobs = #Engine.scanJobs,""", """        zones = count(zoneCache),
        zoneMemo = count(zoneMemo),
        zoneBest = zoneBestN,
        zoneBestSlots = zoneBestSlots,
        jobs = #Engine.scanJobs,""")

# 14. SourceStats diagnostic
rep(E, """-- Returns summary sets or nil if still scanning (auto-enqueues the scan)
function Engine.CachesWarm()""", """-- /an srcstats: background histogram of the loot DB's shape, so the caches
-- can be tuned against the real server data rather than a synthetic DB.
function Engine.SourceStats()
    local getCount, getAt = SrcApi()
    if not getCount then ANx.Print("srcstats: loot DB not loaded") return end
    Engine.Enqueue(function()
        local t0 = Clock()
        local known = Engine.KnownZoneNameSet()
        local mult, listings = {}, 0
        for _, z in ipairs(ANx.Zones or {}) do
            for _, id in ipairs(ANx.ItemsInZone(z.zone)) do
                mult[id] = (mult[id] or 0) + 1
                listings = listings + 1
            end
            Engine.YieldNow()
        end
        local items = Engine.Universe()
        local buckets = { 0, 0, 0, 0, 0, 0 }
        local totalRows, maxRows, maxId, nItems = 0, 0, nil, 0
        local heavyItems, heavyListings, heavyRowsListed = 0, 0, 0
        local multHist = { 0, 0, 0, 0, 0 }   -- listed in 0 / 1 / 2-5 / 6-20 / 21+ zones (items >= 1000 rows)
        local sampled, unrec, unrecNames, unrecDistinct = 0, 0, {}, 0
        local SAMPLE = 25
        for _, id in ipairs(items) do
            Engine.MaybeYield()
            local n = getCount(id) or 0
            nItems = nItems + 1
            totalRows = totalRows + n
            if n > maxRows then maxRows, maxId = n, id end
            local b = (n == 0 and 1) or (n < 10 and 2) or (n < 100 and 3) or (n < 1000 and 4) or (n < 10000 and 5) or 6
            buckets[b] = buckets[b] + 1
            local mz = mult[id] or 0
            if n >= 1000 then
                heavyItems = heavyItems + 1
                heavyListings = heavyListings + mz
                heavyRowsListed = heavyRowsListed + n * mz
                local hb = (mz == 0 and 1) or (mz == 1 and 2) or (mz <= 5 and 3) or (mz <= 20 and 4) or 5
                multHist[hb] = multHist[hb] + 1
            end
            local k = n < SAMPLE and n or SAMPLE
            for i = 1, k do
                local st, _, _, _, _, _, zn = getAt(id, i)
                if st ~= nil then
                    sampled = sampled + 1
                    local zl = ZoneLower(zn)
                    if zl ~= "" and not known[zl] then
                        unrec = unrec + 1
                        if unrecNames[zn] then unrecNames[zn] = unrecNames[zn] + 1
                        elseif unrecDistinct < 200 then unrecNames[zn] = 1; unrecDistinct = unrecDistinct + 1 end
                    end
                end
            end
            Engine.YieldRows(k)
        end
        ANx.Print(string.format("srcstats: %d items, %d rows total, max %d rows (item %s), %d zone listings over %d zones",
            nItems, totalRows, maxRows, tostring(maxId), listings, #(ANx.Zones or {})))
        ANx.Print(string.format("  rows/item: 0:%d  1-9:%d  10-99:%d  100-999:%d  1000-9999:%d  10000+:%d",
            buckets[1], buckets[2], buckets[3], buckets[4], buckets[5], buckets[6]))
        ANx.Print(string.format("  items >= 1000 rows: %d, listed %d times (rows x listings = %d); zones per such item 0:%d 1:%d 2-5:%d 6-20:%d 21+:%d",
            heavyItems, heavyListings, heavyRowsListed, multHist[1], multHist[2], multHist[3], multHist[4], multHist[5]))
        local names = {}
        for zn, c in pairs(unrecNames) do names[#names + 1] = { zn, c } end
        table.sort(names, function(x, y) return x[2] > y[2] end)
        local top = {}
        for i = 1, math.min(8, #names) do top[#top + 1] = names[i][1] .. "x" .. names[i][2] end
        ANx.Print(string.format("  zone names: %d of %d sampled rows name a zone the addon does not know (%d distinct%s): %s",
            unrec, sampled, unrecDistinct, unrecDistinct >= 200 and "+" or "", table.concat(top, ", ")))
        ANx.Print(string.format("  (%.0f ms of background work)", Clock() - t0))
    end, nil, "srcstats")
end

-- Returns summary sets or nil if still scanning (auto-enqueues the scan)
function Engine.CachesWarm()""")
print("patched", root)
