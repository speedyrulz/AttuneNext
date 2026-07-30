-- =========================================================================
-- AttuneNext - AltCache.lua
-- Alt awareness: each character you log snapshots which items IT can attune
-- (account-wide). Item detail pages and tooltips can then say
-- "not for this character - Roguey (Rogue) can attune it".
-- The snapshot refreshes every login, so class/level changes stay current.
-- =========================================================================
local ADDON_NAME, ANx = ...

local CHUNK = 1500   -- helper calls per step; spread over the timer

local function CharName()
    return (_G.UnitName and _G.UnitName("player")) or "Unknown"
end

-- runtime membership sets per cached record (weak keys: never saved)
local setCache = setmetatable({}, { __mode = "k" })

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
    local className, classFile
    if _G.UnitClass then
        local ln, f = _G.UnitClass("player")
        className, classFile = ln, f
    end
    local rec = {
        class = classFile,
        className = className,
        level = (_G.UnitLevel and _G.UnitLevel("player")) or 0,
        items = {},
    }
    local i = 1
    local function step()
        local n = 0
        while i <= #universe and n < CHUNK do
            local id = universe[i]
            if ANx.CanCharAttune(id) then
                rec.items[#rec.items + 1] = id
            end
            i = i + 1
            n = n + 1
        end
        if i <= #universe then
            ANx.After(0.1, step)
        else
            ANx.db.altCan = ANx.db.altCan or {}
            ANx.db.altCan[CharName()] = rec
            snapshotting = false
            ANx.DebugMsg("alt snapshot: " .. CharName() .. " can attune "
                .. #rec.items .. " of " .. #universe .. " items")
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
    for cname, rec in pairs((ANx.db and ANx.db.altCan) or {}) do
        if cname ~= me and type(rec) == "table" and rec.items then
            local set = setCache[rec]
            if not set then
                set = {}
                for _, id in ipairs(rec.items) do set[id] = true end
                setCache[rec] = set
            end
            if set[itemId] then
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
