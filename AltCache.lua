-- =========================================================================
-- AttuneNext - AltCache.lua
-- Alt awareness: each character you log snapshots which items IT can attune
-- (account-wide). Item detail pages and tooltips can then say
-- "not for this character - Roguey (Rogue) can attune it".
-- The snapshot refreshes every login, so class/level changes stay current.
--
-- Storage: rec.items is ONE ",id,id,...," string per character; membership
-- is a plain substring find. The old per-alt id ARRAY (thousands of numbers
-- resident + serialized per alt) plus the runtime [id]=true sets built from
-- it held up to ~1.5 MB on multi-alt accounts - and the sets could never be
-- collected (weak-keyed by rec tables the DB itself holds strongly).
-- =========================================================================
local ADDON_NAME, ANx = ...

local CHUNK = 1500     -- helper calls per step; spread over the timer
local KEEP_DAYS = 60   -- drop snapshots of characters not seen for this long

local function CharName()
    return (_G.UnitName and _G.UnitName("player")) or "Unknown"
end

-- ---------------------------------------------------------------------
-- Login snapshot of what THIS character can attune
-- ---------------------------------------------------------------------
local snapshotting = false
function ANx.SnapshotAltCan()
    if snapshotting then return end
    if not (ANx.db and ANx.Engine) then return end
    local universe, ready = ANx.Engine.Universe()
    if not ready or #universe == 0 then
        ANx.After(5, ANx.SnapshotAltCan)   -- item database still building
        return
    end
    snapshotting = true

    -- one cheap pass per login: migrate array-form records to the packed
    -- string, stamp un-stamped records (starts their clock), and prune
    -- characters not seen for KEEP_DAYS days (deleted/renamed alts used to
    -- keep their snapshot forever)
    ANx.db.altCan = ANx.db.altCan or {}
    local now = (_G.time and _G.time()) or 0
    for cname, rec in pairs(ANx.db.altCan) do
        if type(rec) ~= "table" then
            ANx.db.altCan[cname] = nil
        else
            if type(rec.items) == "table" then
                rec.items = "," .. table.concat(rec.items, ",") .. ","
            end
            if now > 0 then
                rec.seenAt = rec.seenAt or now
                if (now - rec.seenAt) > KEEP_DAYS * 86400 then
                    ANx.db.altCan[cname] = nil
                end
            end
        end
    end

    local className, classFile
    if _G.UnitClass then
        local ln, f = _G.UnitClass("player")
        className, classFile = ln, f
    end
    local rec = {
        class = classFile,
        className = className,
        level = (_G.UnitLevel and _G.UnitLevel("player")) or 0,
        seenAt = (now > 0) and now or nil,
    }
    local ids = {}
    local i = 1
    local function step()
        local n = 0
        while i <= #universe and n < CHUNK do
            local id = universe[i]
            if ANx.CanCharAttune(id) then
                ids[#ids + 1] = id
            end
            i = i + 1
            n = n + 1
        end
        if i <= #universe then
            ANx.After(0.1, step)
        else
            rec.items = "," .. table.concat(ids, ",") .. ","
            ANx.db.altCan[CharName()] = rec
            snapshotting = false
            ANx.DebugMsg("alt snapshot: " .. CharName() .. " can attune "
                .. #ids .. " of " .. #universe .. " items")
        end
    end
    step()
end

-- ---------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------
-- Other cached characters (not the current one) that can attune this item.
-- Returns { { name=, className= }, ... } sorted by name.
function ANx.AltsWhoCanAttune(itemId)
    local me = CharName()
    local out = {}
    local needle = "," .. itemId .. ","
    for cname, rec in pairs((ANx.db and ANx.db.altCan) or {}) do
        if cname ~= me and type(rec) == "table" and rec.items then
            local items = rec.items
            local hit = false
            if type(items) == "string" then
                hit = items:find(needle, 1, true) ~= nil
            else
                -- pre-migration array form (until this alt's next snapshot)
                for _, id in ipairs(items) do
                    if id == itemId then hit = true break end
                end
            end
            if hit then
                out[#out + 1] = { name = cname, className = rec.className or rec.class or "?" }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- "Roguey (Rogue), Magey (Mage), +2 more"
function ANx.AltListString(alts, max)
    max = max or 3
    local parts = {}
    local n = (#alts < max) and #alts or max
    for i = 1, n do
        parts[#parts + 1] = alts[i].name .. " (" .. (alts[i].className or "?") .. ")"
    end
    if #alts > max then
        parts[#parts + 1] = "+" .. (#alts - max) .. " more"
    end
    return table.concat(parts, ", ")
end
