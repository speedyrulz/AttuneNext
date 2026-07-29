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

function Engine.InvalidateStats()
    statsCache = {}
end

function Engine.InvalidateAll()
    instDiffCache, instResolved, zoneCache, srcCache, profCache, statsCache, summaryCache =
        {}, {}, {}, {}, {}, {}, {}
    zexCache = {}
    limitedItemsSet = nil
    eventItemsCache = {}
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

-- Returns true if a valid cache was restored
function Engine.ImportCache()
    local sc = ANx.db and ANx.db.structCache
    if not sc then return false end
    if not ANx.LootDbLoaded() or sc.version ~= _G.ItemLocIsLoaded() or sc.rev ~= ANx.VERSION then
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
            -- all scans done: persist the structural cache for next session
            pcall(Engine.ExportCache)
        end
        if job.onDone then pcall(job.onDone) end
    end
end)

function Engine.Enqueue(fn, onDone, tag)
    -- avoid duplicate queued jobs for the same tag
    if tag then
        for _, j in ipairs(Engine.scanJobs) do
            if j.tag == tag then return end
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

local function ZoneNameMatch(a, b)
    if not a or not b then return false end
    return a:lower() == b:lower()
end

-- Best source for an item, preferring sources in the given zone name + src filter.
-- Returns chance, sourceName, srcType, restricted(bool), zoneName
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
    if best then return best.chance, best.objName, best.srcType, true, best.zoneName end
    if bestAny then return bestAny.chance, bestAny.objName, bestAny.srcType, false, bestAny.zoneName end
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
    summaryCache[exp] = sum
end

-- Returns summary sets or nil if still scanning (auto-enqueues the scan)
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

-- Pick the next item for the AttuneNext button, honoring its config.
-- Returns itemId (or nil) and the size of the pool it chose from.
-- opts.forceContext: draw from the launch screen's category even if the global
-- "Context sensitive" toggle is off (used when the selected category overrides a
-- conflicting option like whole-instance mode).
function Engine.AttuneNextPick(view, opts)
    local a = (ANx.db and ANx.db.anext) or {}
    local ignore = a.ignore or {}
    local useContext = a.context or (opts and opts.forceContext)
    local items = useContext and Engine.ContextItems(view) or Engine.Universe()

    -- base pool: eligible, unattuned, obtainable, not ignored
    local pool = {}
    local seen = {}
    for _, id in ipairs(items) do
        if not seen[id] and not ignore[id] and Engine.Eligible(id)
            and not ANx.CountDone(id) and #Engine.Sources(id) > 0 then
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
-- Instance-run recommendations (expected new attunes per run)
-- ---------------------------------------------------------------------
-- Which (expansion, kind) pairs to consider, given the view and Context option.
local function InstanceScope(view)
    local a = ANx.db and ANx.db.anext or {}
    if a.context and view then
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
function Engine.RankInstanceRuns(view)
    local a = ANx.db and ANx.db.anext or {}
    local ignoreInst = a.ignoreInst or {}
    local exps, kinds = InstanceScope(view)
    local runs = {}
    for _, exp in ipairs(exps) do
        for _, kind in ipairs(kinds) do
            for _, inst in ipairs(Engine.InstancesFor(exp, kind)) do
                for _, d in ipairs(Engine.InstanceDiffs(inst)) do
                    if ANx.DifficultyMatches(d.label) then
                        local instKey = inst.map .. ":" .. d.diff
                        if not ignoreInst[instKey] then
                            local expected, count = 0, 0
                            for _, id in ipairs(d.items) do
                                if Engine.Eligible(id) and not ANx.CountDone(id) then
                                    count = count + 1
                                    local chance = Engine.BestSource(id, inst.name, ANx.INSTANCE_DROP_SRC) or 0
                                    if chance > 0 then expected = expected + chance / 100 end
                                end
                            end
                            if count > 0 then
                                runs[#runs + 1] = {
                                    inst = inst, d = d, expected = expected,
                                    count = count, instKey = instKey, kind = kind,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(runs, function(x, y)
        if x.expected ~= y.expected then return x.expected > y.expected end
        return x.count > y.count
    end)
    return runs
end
