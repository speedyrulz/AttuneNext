-- =========================================================================
-- AttuneNext - ZoneWatch.lua
-- Current-zone awareness:
--  * entering a zone/instance prints "N attunables left in <zone>"
--    (db.zonewatch - toggle in Interface Options)
--  * inside a dungeon/raid, a draggable, resizable HUD lists what's left
--    there with each item's source, live-updating as you attune
--    (db.zoneHud - toggle on the main menu, the HUD's X button, or /an hud)
-- =========================================================================
local ADDON_NAME, ANx = ...

local HEADER_H = 26     -- title area
local ROW_TEXT_H = 13   -- one item line
local MIN_W, MIN_H = 200, HEADER_H + 2 * ROW_TEXT_H + 8
local MAX_W, MAX_H = 600, 480
local DEFAULT_W = 240
local DEFAULT_ROWS = 8  -- auto-height row cap when the user hasn't resized

local hud
local lastZone
local sizing = false    -- true while the resize grip is being dragged
local dragStart         -- { cx, cy, es, w, h } captured at grip mouse-down

-- ---------------------------------------------------------------------
-- What's left in a named zone / instance
-- ---------------------------------------------------------------------
local function InstanceByName(zname)
    for _, inst in ipairs(ANx.Instances or {}) do
        if inst.name == zname then return inst end
    end
end

local function ZoneEntryByName(zname)
    for _, z in ipairs(ANx.Zones or {}) do
        if z.name == zname then return z end
    end
end

-- returns itemIds still left here, and "instance" | "zone" (nil if unknown)
local function LeftItems(zname)
    local Engine = ANx.Engine
    if not Engine then return nil end
    local inst = InstanceByName(zname)
    if inst then
        local seen, out = {}, {}
        for _, d in ipairs(Engine.InstanceDiffs(inst) or {}) do
            if ANx.DifficultyMatches(d.label) then
                for _, id in ipairs(d.items) do
                    if not seen[id] and Engine.Eligible(id) and not ANx.CountDone(id) then
                        seen[id] = true
                        out[#out + 1] = id
                    end
                end
            end
        end
        return out, "instance"
    end
    local z = ZoneEntryByName(zname)
    if z then
        local out = {}
        for _, id in ipairs(ANx.ItemsInZone(z.zone) or {}) do
            if Engine.Eligible(id) and not ANx.CountDone(id) then
                out[#out + 1] = id
            end
        end
        return out, "zone"
    end
    return nil
end

-- ---------------------------------------------------------------------
-- The instance HUD
-- ---------------------------------------------------------------------
local function HudSize()
    local sz = ANx.db and ANx.db.hudSize
    local w = (sz and sz[1]) or DEFAULT_W
    local h = sz and sz[2] or nil   -- nil = auto-height
    if w < MIN_W then w = MIN_W elseif w > MAX_W then w = MAX_W end
    if h then
        if h < MIN_H then h = MIN_H elseif h > MAX_H then h = MAX_H end
    end
    return w, h
end

local function SaveHudSize()
    if not (hud and hud.GetWidth and hud.GetHeight) then return end
    local w = hud:GetWidth()
    local h = hud:GetHeight()
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
        if w < MIN_W then w = MIN_W elseif w > MAX_W then w = MAX_W end
        if h < MIN_H then h = MIN_H elseif h > MAX_H then h = MAX_H end
        ANx.db.hudSize = { math.floor(w + 0.5), math.floor(h + 0.5) }
    end
end

local function SaveHudPos()
    if hud and hud.GetPoint then
        local p, _, rp, x, y = hud:GetPoint()
        if p then ANx.db.hudPos = { p, rp, x, y } end
    end
end

-- Reliable end-of-resize: an OnUpdate watcher ends the drag the moment the
-- left button is released, wherever the cursor is.
local function FinishSizing()
    if not sizing then return end
    sizing = false
    dragStart = nil
    SaveHudSize()
    SaveHudPos()
    ANx.ZoneWatchNow(false)   -- refit rows to the final size
end

local function EnsureHud()
    if hud then return hud end
    hud = CreateFrame("Frame", "AttuneNextZoneHUD", UIParent)
    hud:SetWidth(DEFAULT_W)
    hud:SetHeight(40)
    hud:SetFrameStrata("MEDIUM")
    if hud.SetClampedToScreen then hud:SetClampedToScreen(true) end
    if hud.SetBackdrop then
        hud:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
    end
    if hud.SetBackdropColor then hud:SetBackdropColor(0, 0, 0, 0.75) end
    hud:EnableMouse(true)
    hud:SetMovable(true)
    hud:RegisterForDrag("LeftButton")
    hud:SetScript("OnDragStart", function(self) self:StartMoving() end)
    hud:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self.GetPoint then
            local p, _, rp, x, y = self:GetPoint()
            ANx.db.hudPos = { p, rp, x, y }
        end
    end)

    hud.title = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hud.title:SetPoint("TOPLEFT", 8, -7)
    hud.rows = {}

    -- X: hide the HUD entirely (re-enable from the main menu or /an hud)
    hud.close = CreateFrame("Button", "AttuneNextZoneHUDClose", hud, "UIPanelCloseButton")
    hud.close:SetWidth(24); hud.close:SetHeight(24)
    hud.close:SetPoint("TOPRIGHT", 1, 1)
    hud.close:SetScript("OnClick", function()
        ANx.db.zoneHud = false
        hud:Hide()
        ANx.Print("Instance HUD hidden - turn it back on from the main menu or with /an hud.")
    end)

    -- resize grip (bottom-right)
    hud.grip = CreateFrame("Button", "AttuneNextZoneHUDGrip", hud)
    hud.grip:SetWidth(16); hud.grip:SetHeight(16)
    hud.grip:SetPoint("BOTTOMRIGHT", -1, 1)
    if hud.grip.SetNormalTexture then
        hud.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    end
    -- MANUAL resizing. The engine's StartSizing can snap the frame straight
    -- to the cursor the instant the grip is clicked (ballooning the window
    -- before the mouse even moves). Instead we record the cursor + size at
    -- mouse-down and apply pure deltas each frame: by construction the size
    -- cannot change until the cursor actually moves.
    hud.grip:SetScript("OnMouseDown", function()
        -- pin the TOP-LEFT corner so growth extends down/right
        if hud.GetLeft and hud.GetTop and hud.ClearAllPoints then
            local l, t = hud:GetLeft(), hud:GetTop()
            if l and t then
                hud:ClearAllPoints()
                hud:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
            end
        end
        local cx, cy = 0, 0
        if _G.GetCursorPosition then cx, cy = _G.GetCursorPosition() end
        dragStart = {
            cx = cx, cy = cy,
            es = (hud.GetEffectiveScale and hud:GetEffectiveScale()) or 1,
            w = (hud.GetWidth and hud:GetWidth()) or DEFAULT_W,
            h = (hud.GetHeight and hud:GetHeight()) or MIN_H,
        }
        sizing = true
    end)
    hud.grip:SetScript("OnMouseUp", FinishSizing)
    hud:SetScript("OnUpdate", function()
        if not sizing then return end
        -- end the resize whenever the button is released ANYWHERE
        if _G.IsMouseButtonDown and not _G.IsMouseButtonDown("LeftButton") then
            FinishSizing()
            return
        end
        if dragStart and _G.GetCursorPosition then
            local cx, cy = _G.GetCursorPosition()
            local es = dragStart.es or 1
            local w = dragStart.w + (cx - dragStart.cx) / es
            local h = dragStart.h - (cy - dragStart.cy) / es
            if w < MIN_W then w = MIN_W elseif w > MAX_W then w = MAX_W end
            if h < MIN_H then h = MIN_H elseif h > MAX_H then h = MAX_H end
            hud:SetWidth(w)
            hud:SetHeight(h)
        end
    end)

    local pos = ANx.db and ANx.db.hudPos
    if pos then
        hud:SetPoint(pos[1] or "CENTER", UIParent, pos[2] or "CENTER", pos[3] or 0, pos[4] or 0)
    else
        hud:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
    ANx.zoneHudFrame = hud
    return hud
end

local function HudRow(h, i, width)
    local fs = h.rows[i]
    if not fs then
        fs = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", 10, -HEADER_H + 5 - i * ROW_TEXT_H)
        fs:SetJustifyH("LEFT")
        h.rows[i] = fs
    end
    fs:SetWidth(width - 24)
    fs:SetHeight(ROW_TEXT_H)   -- clip to one line
    return fs
end

-- ---------------------------------------------------------------------
-- Update (debounced: zone events fire in bursts around loading screens)
-- ---------------------------------------------------------------------
function ANx.ZoneWatchNow(announce)
    local db = ANx.db
    local wantNote = db and db.zonewatch
    local wantHud = db and db.zoneHud
    if not (wantNote or wantHud) then
        if hud then hud:Hide() end
        return
    end
    if not ANx.LootDbLoaded() then return end
    local zname = (_G.GetRealZoneText and _G.GetRealZoneText()) or ""
    if zname == "" then
        if hud then hud:Hide() end
        return
    end
    local items, kind = LeftItems(zname)

    -- one chat note per zone entered
    if wantNote and announce and zname ~= lastZone and items and #items > 0 then
        ANx.Print(string.format("|cffffff00%d|r attunable%s left in |cffffff00%s|r",
            #items, (#items == 1) and "" or "s", zname))
    end
    if announce then lastZone = zname end

    -- mid-resize: leave the window alone (refit happens when the drag ends)
    if sizing then return end

    -- HUD: only inside a dungeon/raid
    local inInst = false
    if _G.IsInInstance then
        local a, t = _G.IsInInstance()
        inInst = (a and (t == "party" or t == "raid")) and true or false
    end
    if wantHud and inInst and kind == "instance" and items and #items > 0 then
        local h = EnsureHud()
        local w, customH = HudSize()
        -- how many item lines fit?
        local slots
        if customH then
            slots = math.floor((customH - HEADER_H - 6) / ROW_TEXT_H)
            if slots < 2 then slots = 2 end
        else
            slots = DEFAULT_ROWS + 1
        end
        h.title:SetText("|cff33ff99Attune|r|cffffffffNext|r  -  " .. zname
            .. "  |cffffff00(" .. #items .. " left)|r")
        local rows = ANx.Engine.ItemRows(items, zname, ANx.INSTANCE_DROP_SRC)
        local showItems = #rows
        local moreLine = false
        if #rows > slots then
            showItems = slots - 1
            moreLine = true
        end
        local line = 0
        for i = 1, showItems do
            line = line + 1
            local r = rows[i]
            local fs = HudRow(h, line, w)
            local name, _, quality = ANx.GetItemDisplay(r.id)
            local hex = (ITEM_QUALITY_COLORS[quality or 1] or {}).hex or "|cffffffff"
            local src = r.srcName and ("  |cffaaaaaa(" .. r.srcName .. ")|r") or ""
            fs:SetText(hex .. name .. "|r  |cff00ff88" .. ANx.FormatChance(r.chance) .. "|r" .. src)
        end
        if moreLine then
            line = line + 1
            HudRow(h, line, w):SetText("|cff888888+" .. (#rows - showItems) .. " more...|r")
        end
        for i = line + 1, #h.rows do
            h.rows[i]:SetText("")
        end
        h:SetWidth(w)
        h:SetHeight(customH or (HEADER_H + line * ROW_TEXT_H + 8))
        h:Show()
    elseif hud then
        hud:Hide()
    end
end

-- Reset the HUD's size and position to defaults (main menu: shift-click).
function ANx.ResetHudLayout()
    ANx.db.hudSize = nil
    ANx.db.hudPos = nil
    if hud then
        if hud.ClearAllPoints then hud:ClearAllPoints() end
        hud:SetPoint("TOP", UIParent, "TOP", 0, -140)
        hud:SetWidth(DEFAULT_W)
    end
    ANx.ZoneWatchNow(false)
    ANx.Print("Instance HUD size & position reset.")
end

local pending, pendingAnnounce = false, false
function ANx.ZoneWatchUpdate(announce)
    pendingAnnounce = pendingAnnounce or announce or false
    if pending then return end
    pending = true
    ANx.After(0.8, function()
        pending = false
        local a = pendingAnnounce
        pendingAnnounce = false
        ANx.ZoneWatchNow(a)
    end)
end
