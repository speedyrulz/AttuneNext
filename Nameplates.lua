-- =========================================================================
-- AttuneNext - Nameplates.lua
-- Marks nameplates of mobs that still DROP something you have not attuned
-- (pulsing green wash) and of NPCs that SELL something you have not attuned
-- (blue), plus a "drops N / sells N" tag above the plate.
-- Ported from AttuneMaster's Hunt module, adapted to AttuneNext's data.
--
-- Options (db.plates):
--   mode  - "off"      standard nameplates
--           "on"       every mob/vendor with something unattuned (default)
--           "filters"  only items that pass the AttuneNext window's filters
--   scope - "char" / "acct": whose attunes decide "not attuned yet" (On mode;
--           Respect-filters mode follows the window's own scope chip)
--   pulse - the glow breathes when true, steady when false
--
-- 3.3.5a has no C_NamePlate and no NAME_PLATE_UNIT_ADDED. Plates are
-- anonymous WorldFrame children with no unit token and no GUID, so the only
-- thing a plate offers is its name string. That makes this two lookups
-- against the same data:
--   by name  - built once per zone from the loot DB, used for nameplates
--   by entry - exact, from the GUID behind mouseover/target/merchant, which
--              also teaches the name index (vendor stock never reaches the
--              zone item list, so vendors light up once you point at them)
-- =========================================================================
local ADDON_NAME, ANx = ...

local NP = {}
ANx.Plates = NP

local NAMEPLATE_BORDER = "Interface\\Tooltips\\Nameplate-Border"
-- A plain white square: no atlas, no TexCoords to get wrong, and it cannot
-- be mistaken for the plate's own threat flash.
local GLOW_TEXTURE = "Interface\\Buttons\\WHITE8X8"

local CHILD_POLL   = 0.10   -- look for new plates
local PLATE_POLL   = 0.20   -- re-read plate names
local GLOW_STEADY  = 0.55   -- alpha when the pulse is switched off
local ENTRY_TTL    = 120    -- per-NPC exact-answer lifetime
local ZONE_BUDGET  = 20     -- items indexed per frame while building
local REBUILD_WAIT = 1.5    -- coalesce a burst of zone events
local ATTUNE_WAIT  = 10     -- rebuild after an attunement completes

local DROP_SRC = { [0] = true, [20] = true }   -- creature, mythic creature
local VEND_SRC = { [9] = true }                -- vendor

local COLOR_DROP = { r = 0.15, g = 1.00, b = 0.25 }   -- green
local COLOR_VEND = { r = 0.25, g = 0.55, b = 1.00 }   -- blue

local needByName  = {}      -- [lower name] = { drop, vend, count, best }
local learned     = {}      -- [lower name] = info, or false for "nothing"
local entryCache  = {}      -- [entryId] = info + at
local plates      = {}      -- [frame] = true, every plate ever seen
local activeGlows = {}      -- [frame] = true, only those currently marked
local lastKids    = 0

local staging, zoneSeen, zoneQueue, zoneAt, zoneBuilding
local rebuildQueued, builtZone

local function Cfg()
    return (ANx.db and ANx.db.plates) or { mode = "off", scope = "acct", pulse = true }
end

function NP.Enabled()
    return Cfg().mode ~= "off"
end

-- ---------------------------------------------------------------------
-- What counts as "still needed"
-- ---------------------------------------------------------------------
local function Attuned(itemId)
    if Cfg().mode ~= "filters" and Cfg().scope == "char" then
        return ANx.IsAttuned(itemId)                     -- this character
    end
    return ANx.AccountHasVariant(itemId)                 -- anyone on the account
end

function NP.StillNeeded(itemId)
    if not itemId then return false end
    local mode = Cfg().mode
    if mode == "off" then return false end
    if mode == "filters" then
        -- exactly what the AttuneNext window would show: every filter chip,
        -- including its scope and Forge Level
        return ANx.Engine.Eligible(itemId) and not ANx.CountDone(itemId)
    end
    -- plain On: anything this character could attune and hasn't (or the
    -- account hasn't, per the feature's own scope option)
    if not ANx.CanCount(itemId) then return false end
    return not Attuned(itemId)
end

-- ---------------------------------------------------------------------
-- Exact lookup: what does this NPC entry still hold for me?
-- ---------------------------------------------------------------------
-- One pass over an item's source rows, restricted to THIS entry: does this
-- NPC drop it, sell it (or both), and at what best chance? This is what
-- tells stock apart from loot - the server registers a vendor's wares under
-- its creature associations too, so the obj enumeration alone cannot.
local function SourceInfoFor(itemId, entryId)
    if not (_G.ItemLocGetSourceCount and _G.ItemLocGetSourceAt) then return nil end
    local ok, n = pcall(_G.ItemLocGetSourceCount, itemId)
    if not ok or not n or n == 0 then return nil end
    local hasDrop, hasVend, best
    for i = 1, n do
        local ok2, srcType, _, objId, chance = pcall(_G.ItemLocGetSourceAt, itemId, i)
        if ok2 and objId == entryId then
            if VEND_SRC[srcType] then
                hasVend = true
            elseif DROP_SRC[srcType] then
                hasDrop = true
                if type(chance) == "number" and (not best or chance > best) then
                    best = chance
                end
            end
        end
    end
    return hasDrop, hasVend, best
end

function NP.ScanEntry(entryId)
    if not entryId or not ANx.dataReady then return nil end
    local cached = entryCache[entryId]
    if cached and (GetTime() - cached.at) < ENTRY_TTL then return cached end
    if not (_G.ItemLocGetObjCount and _G.ItemLocGetObjAt) then return nil end

    local seen = {}
    local info = { drop = 0, vend = 0, count = 0, best = nil, at = GetTime(),
                   dropIds = {} }
    -- the obj enumeration lists every itemloc association of this creature,
    -- INCLUDING its vendor stock - classify each item by its own source rows
    -- for this entry (sold vs dropped), falling back to "drop" if the rows
    -- are silent about this NPC
    local function harvest(objType)
        local ok, n = pcall(_G.ItemLocGetObjCount, objType, entryId)
        if not ok or not n or n == 0 then return end
        for i = 1, n do
            -- the item id is the second return; the first is undocumented
            local ok2, a, b = pcall(_G.ItemLocGetObjAt, objType, entryId, i)
            local itemId = (type(b) == "number" and b) or (type(a) == "number" and a) or nil
            if ok2 and itemId and not seen[itemId] and NP.StillNeeded(itemId) then
                seen[itemId] = true
                local hasDrop, hasVend, best = SourceInfoFor(itemId, entryId)
                if hasVend and not hasDrop then
                    info.vend = info.vend + 1
                else
                    info.drop = info.drop + 1
                    info.dropIds[itemId] = true
                    if hasVend then info.vend = info.vend + 1 end
                end
                info.count = info.count + 1
                if best and (not info.best or best > info.best) then
                    info.best = best
                end
            end
        end
    end
    harvest(0)
    harvest(20)

    entryCache[entryId] = info
    return info
end

-- 3.3.5 creature GUID: 0xF130 EEEEEE SSSSSS - the entry is hex chars 7..12
-- (after the 0x), between the 4-char type prefix and the spawn counter.
function NP.NpcID(guid)
    if type(guid) ~= "string" then return nil end
    local hex = guid:match("^0x%x%x%x%x(%x%x%x%x%x%x)%x%x%x%x%x%x$")
        or guid:sub(7, 12)
    local n = hex and tonumber(hex, 16)
    return n and n > 0 and n or nil
end

-- ---------------------------------------------------------------------
-- Name index for the current zone (built incrementally, swapped atomically)
-- ---------------------------------------------------------------------
local function CurrentZoneId()
    local zname = (_G.GetRealZoneText and _G.GetRealZoneText()) or ""
    if zname == "" then return nil end
    for _, z in ipairs(ANx.Zones or {}) do
        if z.name == zname then return z.zone, zname end
    end
    for _, inst in ipairs(ANx.Instances or {}) do
        if inst.name == zname then
            -- index the instance across all difficulties (plates carry no
            -- difficulty; a mob that drops anything unattuned should mark)
            return nil, zname, inst
        end
    end
    return nil, zname
end

local function IndexItem(itemId)
    if not NP.StillNeeded(itemId) then return end
    if not (_G.ItemLocGetSourceCount and _G.ItemLocGetSourceAt) then return end
    local ok, n = pcall(_G.ItemLocGetSourceCount, itemId)
    if not ok or not n then return end
    for i = 1, n do
        local ok2, srcType, _, _, chance, _, objName = pcall(_G.ItemLocGetSourceAt, itemId, i)
        if ok2 and objName and objName ~= "" and objName ~= "?" then
            local kind
            if DROP_SRC[srcType] then kind = "drop"
            elseif VEND_SRC[srcType] then kind = "vend" end
            if kind then
                local key = NP.NameKey(objName)
                if key then
                local seen = zoneSeen[key]
                if not seen then seen = {}; zoneSeen[key] = seen end
                if not seen[itemId] then
                    seen[itemId] = true
                    local e = staging[key]
                    if not e then
                        e = { drop = 0, vend = 0, count = 0 }
                        staging[key] = e
                    end
                    e[kind] = e[kind] + 1
                    e.count = e.count + 1
                    if type(chance) == "number" and (not e.best or chance > e.best) then
                        e.best = chance
                    end
                end
                end
            end
        end
    end
end

function NP.RebuildZoneIndex(force)
    rebuildQueued = false
    if not NP.Enabled() or not ANx.dataReady then return end
    local zid, zname, inst = CurrentZoneId()
    if not zname then return end
    if not force and zname == builtZone and not zoneBuilding then return end

    local list = {}
    local push = {}
    local function add(ids)
        for _, id in ipairs(ids or {}) do
            if not push[id] then push[id] = true; list[#list + 1] = id end
        end
    end
    if zid then
        add(ANx.ItemsInZone(zid))
    elseif inst then
        for _, d in ipairs(ANx.Engine.InstanceDiffs(inst) or {}) do
            add(d.items)
        end
    else
        return                        -- unknown zone: keep the previous index
    end

    staging      = {}
    zoneSeen     = {}
    zoneQueue    = list
    zoneAt       = 1
    zoneBuilding = true
    builtZone    = zname
    ANx.DebugMsg("plate index: walking " .. #list .. " attunable item(s) in " .. zname)
end

local function QueueRebuild(delay)
    if rebuildQueued then return end
    rebuildQueued = true
    ANx.After(delay or REBUILD_WAIT, function() NP.RebuildZoneIndex(true) end)
end

local function PumpZoneIndex()
    if not zoneBuilding then return end
    local stop = math.min(zoneAt + ZONE_BUDGET - 1, #zoneQueue)
    for i = zoneAt, stop do
        IndexItem(zoneQueue[i])
    end
    zoneAt = stop + 1
    if zoneAt > #zoneQueue then
        needByName   = staging          -- atomic swap, no flicker
        staging      = nil
        zoneSeen     = nil
        zoneQueue    = nil
        zoneBuilding = false
        -- an NPC looked at BEFORE the index existed may be recorded as an
        -- exact "nothing" - for vendors that answer was blind (stock is not
        -- enumerable by entry), so the fresh index wins and re-marks them
        for key, e in pairs(needByName) do
            if learned[key] == false and (e.vend or 0) > 0 then
                learned[key] = nil
            end
        end
        ANx.DebugMsg("plate index built")
        if NP.RefreshAllPlates then NP.RefreshAllPlates() end
    end
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------
local function ColorFor(info)
    if info.drop >= info.vend then return COLOR_DROP end
    return COLOR_VEND
end

local function ShortText(info)
    local parts = {}
    if info.drop > 0 then parts[#parts + 1] = "drops " .. info.drop end
    if info.vend > 0 then parts[#parts + 1] = "sells " .. info.vend end
    return table.concat(parts, ", ")
end
NP.ShortText = ShortText

local function IsNameplate(frame)
    if frame.GetName and frame:GetName() then return false end
    local region = select(2, frame:GetRegions())
    if region and region.GetObjectType and region:GetObjectType() == "Texture" then
        local ok, tex = pcall(region.GetTexture, region)
        if ok and tex == NAMEPLATE_BORDER then return true end
    end
    return false
end

local function PlateNameString(frame)
    if frame.anxNameFS then return frame.anxNameFS end
    local regions = { frame:GetRegions() }
    for i = 1, #regions do
        local r = regions[i]
        if r and r.GetObjectType and r:GetObjectType() == "FontString" then
            frame.anxNameFS = r
            return r
        end
    end
    return nil
end

function NP.LookupName(name)
    local key = NP.NameKey(name)
    if not key then return nil end
    local exact = learned[key]
    if exact ~= nil then
        if exact == false then return nil end
        return exact
    end
    return needByName[key]
end

-- The exact entry scan is authoritative for DROPS (kill loot enumerates by
-- entry) but blind to vendor stock. Merge: take the scan's drops, keep the
-- zone index's vendor knowledge, and only record "nothing" when both agree.
local function Learn(name, info)
    local key = NP.NameKey(name)
    if not key then return end
    local zone = needByName[key]
    local drop = (info and info.drop) or 0
    local vend = math.max((info and info.vend) or 0,
                          (info and info.vendExact) and 0 or (zone and zone.vend) or 0)
    if drop + vend > 0 then
        learned[key] = {
            drop = drop, vend = vend, count = drop + vend,
            best = (info and info.best) or (zone and zone.best),
        }
    else
        learned[key] = false
    end
end

-- Exact vendor answer from an open merchant window: enumerate the stock and
-- count what is still needed. This CAN overrule the zone index (vendExact).
function NP.LearnMerchant()
    if not NP.Enabled() then return end
    if not (_G.GetMerchantNumItems and _G.GetMerchantItemLink) then return end
    if not (UnitExists("npc") and not UnitIsPlayer("npc")) then return end
    local n = _G.GetMerchantNumItems() or 0
    local vend = 0
    local stockIds = {}
    for i = 1, n do
        local link = _G.GetMerchantItemLink(i)
        local id = link and tonumber(tostring(link):match("item:(%d+)"))
        if id then
            stockIds[id] = true
            if NP.StillNeeded(id) then vend = vend + 1 end
        end
    end
    local base = NP.ScanEntry(NP.NpcID(UnitGUID("npc"))) or { drop = 0 }
    -- the server also registers vendor stock under the NPC's creature
    -- associations: anything that is literally in the shop is a sale, not a
    -- drop, or a pure jeweler shows up green with a bogus "drops N" tag
    local drop = 0
    for id in pairs(base.dropIds or {}) do
        if not stockIds[id] then drop = drop + 1 end
    end
    local name = UnitName("npc")
    Learn(name, { drop = drop, vend = vend,
                  vendExact = true, count = drop + vend, best = base.best })
    if NP.RefreshAllPlates then NP.RefreshAllPlates() end

    -- would mark, but there is no plate frame carrying this name: friendly
    -- nameplates are almost certainly switched off - say so once
    if vend + drop > 0 and not NP.hintedFriendly then
        local carried = false
        for frame in pairs(plates) do
            local fs = frame.anxNameFS
            local ok, txt = pcall(function() return fs and fs:GetText() end)
            if ok and NP.NameKey(txt) == NP.NameKey(name) then carried = true break end
        end
        if not carried then
            NP.hintedFriendly = true
            ANx.Print("|cffffd100" .. tostring(name) .. "|r has unattuned stock but no "
                .. "nameplate to mark - friendly nameplates are off. Press "
                .. "|cffffff00Shift-V|r to show them.")
        end
    end
end

local function HidePlateMark(frame)
    if frame.anxGlow then frame.anxGlow:Hide() end
    if frame.anxTag then frame.anxTag:Hide() end
    activeGlows[frame] = nil
end

local UpdatePlate   -- forward declaration, hooked as OnShow

local function EnsurePlateMark(frame)
    if frame.anxGlow then return end
    -- resolve the client's name FontString before adding ours, or the scan
    -- would later latch onto our own tag
    PlateNameString(frame)

    local glow = frame:CreateTexture(nil, "BACKGROUND")
    glow.anxMine = true
    glow:SetTexture(GLOW_TEXTURE)
    glow:SetBlendMode("ADD")
    -- one anchor + explicit size: two-point stretch is unreliable here
    glow:SetPoint("CENTER", frame, "CENTER", 0, 4)
    glow:SetWidth(150)
    glow:SetHeight(30)
    glow:Hide()
    frame.anxGlow = glow

    local tag = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tag.anxMine = true
    tag:SetPoint("BOTTOM", frame, "TOP", 0, 2)
    tag:Hide()
    frame.anxTag = tag

    -- plates are pooled: the same frame returns as a different unit
    if frame.HookScript then
        frame:HookScript("OnHide", HidePlateMark)
        frame:HookScript("OnShow", function(f)
            ANx.After(0.05, function() UpdatePlate(f) end)
        end)
    end
end

function UpdatePlate(frame)
    if frame.IsShown and not frame:IsShown() then return end
    if not NP.Enabled() then
        HidePlateMark(frame)
        return
    end

    local fs = PlateNameString(frame)
    local name = fs and fs:GetText()
    -- the client blanks the name for a frame or two while a plate is
    -- recycled; treat that as "no change" rather than hiding
    if not name or name == "" then return end

    local info = NP.LookupName(name)
    if not info then
        HidePlateMark(frame)
        return
    end

    EnsurePlateMark(frame)
    local c = ColorFor(info)
    frame.anxGlow:SetVertexColor(c.r, c.g, c.b)

    if not frame.anxGlow:IsShown() then
        -- seed the alpha only on the way in: fighting the pulse per poll
        -- reads as flicker
        frame.anxGlow:SetAlpha(GLOW_STEADY)
        frame.anxGlow:Show()
    elseif not Cfg().pulse then
        frame.anxGlow:SetAlpha(GLOW_STEADY)
    end
    activeGlows[frame] = true

    frame.anxTag:SetText(string.format("|cff%02x%02x%02x%s|r",
        c.r * 255, c.g * 255, c.b * 255, ShortText(info)))
    frame.anxTag:Show()
end
NP.UpdatePlate = UpdatePlate

local function ScanForNewPlates()
    if not (WorldFrame and WorldFrame.GetNumChildren) then return end
    local n = WorldFrame:GetNumChildren()
    if n == lastKids then return end
    lastKids = n
    local kids = { WorldFrame:GetChildren() }
    for i = 1, #kids do
        local f = kids[i]
        if f and not plates[f] and IsNameplate(f) then
            plates[f] = true
        end
    end
end
NP.ScanForNewPlates = ScanForNewPlates

local function RefreshAllPlates()
    for frame in pairs(plates) do UpdatePlate(frame) end
end
NP.RefreshAllPlates = RefreshAllPlates

-- Resolve a unit exactly and teach the name index from the answer. This is
-- how vendors get marked: their stock never appears in the zone item list,
-- but the GUID behind mouseover/target/merchant answers authoritatively.
function NP.Inspect(unit)
    if not NP.Enabled() then return nil end
    if not unit or not UnitExists(unit) or UnitIsPlayer(unit) then return nil end
    local info = NP.ScanEntry(NP.NpcID(UnitGUID(unit)))
    if info then
        Learn(UnitName(unit), info)
        RefreshAllPlates()
    end
    return info
end

-- Filters/attunes changed: everything cached is suspect
function NP.Invalidate()
    entryCache = {}
    learned = {}
    RefreshAllPlates()
    QueueRebuild(0.5)
end

function NP.OnAttune()
    if not NP.Enabled() then return end
    entryCache = {}
    learned = {}
    RefreshAllPlates()
    QueueRebuild(ATTUNE_WAIT)
end

-- normalise plate/source names the same way on both sides: trailing spaces
-- and colour codes stripped, lowercased
local function NameKey(name)
    if not name then return nil end
    name = tostring(name):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    return string.lower(name)
end
NP.NameKey = NameKey

-- ---------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------
local childAccum, plateAccum, pulse = 0, 0, 0

function NP.Init()
    -- parented to WorldFrame at TOOLTIP strata so this OnUpdate runs after
    -- the client has finished moving plates for the frame; it must own no
    -- regions or IsNameplate would consider it a plate
    local driver = CreateFrame("Frame", nil, WorldFrame)
    if driver.SetFrameStrata then driver:SetFrameStrata("TOOLTIP") end
    driver:SetScript("OnUpdate", function(self, elapsed)
        PumpZoneIndex()
        if not NP.Enabled() then return end

        childAccum = childAccum + elapsed
        if childAccum >= CHILD_POLL then
            childAccum = 0
            ScanForNewPlates()
        end

        plateAccum = plateAccum + elapsed
        if plateAccum >= PLATE_POLL then
            plateAccum = 0
            RefreshAllPlates()
        end

        -- every frame, but only over marked plates (usually a handful);
        -- stepping this on a timer is what makes a pulse look like stutter
        if Cfg().pulse then
            pulse = (pulse + elapsed) % 6.2832
            local a = 0.42 + 0.22 * math.sin(pulse * 2.4)
            for frame in pairs(activeGlows) do
                frame.anxGlow:SetAlpha(a)
            end
        end
    end)

    -- the index needs the server data, which is NOT ready at login: rebuild
    -- once it arrives (Core calls NP.OnDataReady), and also shortly after
    -- init to cover /reload with the data already live
    ANx.After(3, function() NP.RebuildZoneIndex(true) end)

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_TARGET_CHANGED")
    ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    ev:RegisterEvent("MERCHANT_SHOW")
    ev:SetScript("OnEvent", function(self, event)
        if not NP.Enabled() then return end
        if event == "PLAYER_TARGET_CHANGED" then
            NP.Inspect("target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            NP.Inspect("mouseover")
        elseif event == "MERCHANT_SHOW" then
            NP.LearnMerchant()
        end
    end)
    NP.eventFrame = ev
end

-- Zone changes arrive through Core's dispatcher
function NP.OnZone()
    if NP.Enabled() then QueueRebuild() end
end

-- The server data just became usable: the login-time rebuild bailed on
-- dataReady, so this is the one that actually builds the first index.
function NP.OnDataReady()
    if NP.Enabled() then QueueRebuild(2) end
end

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------
function NP.Report()
    local n, l, g, p = 0, 0, 0, 0
    local sample = {}
    for name in pairs(needByName) do
        n = n + 1
        if #sample < 8 then sample[#sample + 1] = name end
    end
    for _ in pairs(learned) do l = l + 1 end
    for _ in pairs(activeGlows) do g = g + 1 end
    for _ in pairs(plates) do p = p + 1 end
    ANx.Print("plates [" .. Cfg().mode .. "/" .. Cfg().scope
        .. (Cfg().pulse and "/pulse" or "") .. "] zone " .. tostring(builtZone)
        .. ": " .. n .. " NPC name(s) indexed"
        .. (zoneBuilding and " (still building)" or "")
        .. ", " .. l .. " learned by sight, " .. g .. " marked of "
        .. p .. " plate frame(s) seen.")
    if #sample > 0 then
        ANx.Print("  indexed e.g.: " .. table.concat(sample, ", "))
    end
    if p == 0 then
        ANx.Print("|cffffd100No plate frames seen at all|r - are nameplates shown? "
            .. "V toggles enemies, |cffffff00Shift-V|r toggles friendly NPCs "
            .. "(vendors need friendly plates).")
    end
end

-- /an plates why - walk the full decision for the current target/mouseover
-- and say exactly which step fails.
function NP.Why()
    local unit = (UnitExists("target") and "target")
        or (UnitExists("mouseover") and "mouseover") or nil
    if not unit then
        ANx.Print("plates why: target or mouse over the NPC first.")
        return
    end
    if UnitIsPlayer(unit) then
        ANx.Print("plates why: that is a player.")
        return
    end
    local name = UnitName(unit)
    local guid = UnitGUID(unit)
    local entry = NP.NpcID(guid)
    ANx.Print(string.format("plates why: |cffffff00%s|r  guid=%s  entry=%s  mode=%s scope=%s",
        tostring(name), tostring(guid), tostring(entry), Cfg().mode, Cfg().scope))

    local key = NP.NameKey(name)
    local zoneE = key and needByName[key]
    local learnedE = key and learned[key]
    ANx.Print(string.format("  zone index: %s   learned: %s",
        zoneE and string.format("drop=%d vend=%d", zoneE.drop or 0, zoneE.vend or 0) or "NOT IN INDEX",
        learnedE == false and "exact NOTHING" or (learnedE and string.format("drop=%d vend=%d",
            learnedE.drop or 0, learnedE.vend or 0) or "-")))

    -- what would the exact entry scan say right now?
    entryCache[entry or -1] = nil
    local info = entry and NP.ScanEntry(entry)
    ANx.Print("  exact scan: " .. (info and string.format("drop=%d vend=%d", info.drop, info.vend) or "nil"))

    -- if a merchant window is open, walk the stock item by item
    if _G.GetMerchantNumItems and (_G.GetMerchantNumItems() or 0) > 0 then
        local nItems = _G.GetMerchantNumItems()
        ANx.Print("  merchant window: " .. nItems .. " item(s)")
        local shown = 0
        for i = 1, nItems do
            local link = _G.GetMerchantItemLink and _G.GetMerchantItemLink(i)
            local id = link and tonumber(tostring(link):match("item:(%d+)"))
            if id then
                local needed = NP.StillNeeded(id)
                local why
                if needed then
                    why = "STILL NEEDED"
                elseif Cfg().mode == "filters" then
                    why = (not ANx.Engine.Eligible(id)) and "filtered by window chips" or "attuned (window scope)"
                elseif not ANx.CanCount(id) then
                    why = "this character cannot attune it"
                else
                    why = (Cfg().scope == "char") and "attuned by this character" or "attuned on the account"
                end
                shown = shown + 1
                if shown <= 10 then
                    ANx.Print(string.format("    %s: %s", tostring(link), why))
                end
            end
        end
    else
        ANx.Print("  (open the merchant window and run this again for a stock-by-stock verdict)")
    end
    ANx.Print("  verdict: " .. (NP.LookupName(name) and "|cff00ff00WOULD MARK|r" or "|cffff4040would not mark|r"))
end
