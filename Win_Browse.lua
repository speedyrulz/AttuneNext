-- =========================================================================
-- AttuneNext - Win_Browse.lua
-- A standalone, deliberately plain browse window: the AttuneNext wordmark,
-- the two browse entry points, the filters for whatever you're looking at,
-- and the lists themselves. No sidebar, no goals, no favorites, no
-- recommendation button - just browsing, in standard WoW styling.
--   /an browse   (or /anbrowse) - handy as a macro:  /run AttuneNextBrowse()
-- It reuses the main window's builders, so lists and filters stay identical.
-- Drag the bottom-right grip to resize; a taller window shows more rows.
-- =========================================================================
local ADDON_NAME, ANx = ...

local W = {}
ANx.WinBrowse = W

local ROW_H = 24
local MAX_ROWS = 40                      -- row frames created up front
local DEF_W, DEF_H = 540, 536
local MIN_W, MIN_H = 420, 300
local MAX_W, MAX_H = 1000, 1000
local FOOTER_H = 40

local frame
local curW, curH = DEF_W, DEF_H
local listTop = -128                     -- recomputed per render (below filters)
local visibleRows = 15
local sizing, dragStart

-- ---------------------------------------------------------------------
-- Sizing (manual cursor deltas: the engine's StartSizing snaps the frame
-- to the cursor on this client - same fix as the instance HUD)
-- ---------------------------------------------------------------------
local function ApplySize(w, h)
    if w < MIN_W then w = MIN_W elseif w > MAX_W then w = MAX_W end
    if h < MIN_H then h = MIN_H elseif h > MAX_H then h = MAX_H end
    curW, curH = w, h
    if not frame then return end
    frame:SetWidth(w)
    frame:SetHeight(h)
    for _, b in ipairs(frame.rows or {}) do b:SetWidth(w - 52) end
    if frame.title then frame.title:SetWidth(w - 130) end
    if frame.status then frame.status:SetWidth(w - 40) end
end

local function FinishSizing()
    if not sizing then return end
    sizing = false
    dragStart = nil
    ANx.db.browseWinSize = { math.floor(curW + 0.5), math.floor(curH + 0.5) }
    W.Render()
end

-- ---------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------
local function Ensure()
    if frame then return frame end
    local sz = ANx.db and ANx.db.browseWinSize
    curW = (sz and sz[1]) or DEF_W
    curH = (sz and sz[2]) or DEF_H
    if curW < MIN_W then curW = MIN_W elseif curW > MAX_W then curW = MAX_W end
    if curH < MIN_H then curH = MIN_H elseif curH > MAX_H then curH = MAX_H end

    local f = CreateFrame("Frame", "AttuneNextBrowseFrame", UIParent)
    f:SetWidth(curW)
    f:SetHeight(curH)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self.GetPoint then
            local p, _, rp, x, y = self:GetPoint()
            ANx.db.browseWinPos = { p, rp, x, y }
        end
    end)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end
    if ANx.db and ANx.db.scale then f:SetScale(ANx.db.scale) end

    -- the wordmark, centered up top (art only - not a button)
    if ANx.Art and ANx.Art.logo and ANx.ART_PATH then
        local lg = f:CreateTexture(nil, "ARTWORK")
        lg:SetWidth(150); lg:SetHeight(28)
        lg:SetPoint("TOP", f, "TOP", 0, -16)
        lg:SetTexture(ANx.ART_PATH .. ANx.Art.logo[1])
        if lg.SetTexCoord then lg:SetTexCoord(0.2783, 0.9697, 0.2852, 0.7852) end
        f.logo = lg
    else
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        t:SetPoint("TOP", f, "TOP", 0, -18)
        t:SetText("|cff33ff99Attune|r|cffffffffNext|r")
        f.logoText = t
    end

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)

    -- Back + the current level's name
    f.back = CreateFrame("Button", "AttuneNextBrowseBack", f, "UIPanelButtonTemplate")
    f.back:SetWidth(60); f.back:SetHeight(20)
    f.back:SetPoint("TOPLEFT", 16, -50)
    f.back:SetText("Back")
    f.back:SetScript("OnClick", function() ANx.UI.Pop() end)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("LEFT", f.back, "RIGHT", 10, 0)
    f.title:SetJustifyH("LEFT")
    f.title:SetWidth(curW - 130)

    -- filter buttons (built on demand, wrapped over as many rows as needed)
    f.filters = {}

    -- list rows
    f.rows = {}
    for i = 1, MAX_ROWS do
        local b = CreateFrame("Button", "AttuneNextBrowseRow" .. i, f)
        b:SetWidth(curW - 52); b:SetHeight(ROW_H)
        b:SetPoint("TOPLEFT", 20, listTop - (i - 1) * ROW_H)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetWidth(18); b.icon:SetHeight(18)
        b.icon:SetPoint("LEFT", 2, 0)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        b.text:SetPoint("LEFT", 26, 0)
        b.text:SetJustifyH("LEFT")
        b.right = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.right:SetPoint("RIGHT", -4, 0)
        b.right:SetJustifyH("RIGHT")
        b:SetScript("OnClick", function(self)
            if self.anxItem then
                ANx.UI.Push({ type = "sources", itemId = self.anxItem })
            elseif self.anxClick then
                self.anxClick(self)
            end
        end)
        b:SetScript("OnEnter", function(self)
            if self.anxItem then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.anxItem)
                if not ok then GameTooltip:SetText("Item #" .. self.anxItem) end
                GameTooltip:Show()
            elseif self.anxTip and self.anxTip ~= "" then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.anxTip, 1, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:Hide()
        f.rows[i] = b
    end

    f.scroll = CreateFrame("ScrollFrame", "AttuneNextBrowseScroll", f, "FauxScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", 16, listTop)
    f.scroll:SetPoint("BOTTOMRIGHT", -34, FOOTER_H)
    f.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, W.Render)
    end)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.status:SetPoint("BOTTOMLEFT", 20, 18)
    f.status:SetWidth(curW - 40)
    f.status:SetJustifyH("LEFT")

    -- resize grip (bottom-right)
    f.grip = CreateFrame("Button", "AttuneNextBrowseGrip", f)
    f.grip:SetWidth(16); f.grip:SetHeight(16)
    f.grip:SetPoint("BOTTOMRIGHT", -6, 6)
    if f.grip.SetNormalTexture then
        f.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    end
    if f.grip.SetHighlightTexture then
        f.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    end
    f.grip:SetScript("OnMouseDown", function()
        -- pin the top-left so the window grows down/right
        if f.GetLeft and f.GetTop and f.ClearAllPoints then
            local l, t = f:GetLeft(), f:GetTop()
            if l and t then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
            end
        end
        local cx, cy = 0, 0
        if _G.GetCursorPosition then cx, cy = _G.GetCursorPosition() end
        dragStart = {
            cx = cx, cy = cy,
            es = (f.GetEffectiveScale and f:GetEffectiveScale()) or 1,
            w = curW, h = curH,
        }
        sizing = true
    end)
    f.grip:SetScript("OnMouseUp", FinishSizing)
    f:SetScript("OnUpdate", function()
        if not sizing then return end
        -- releasing the button anywhere ends the drag
        if _G.IsMouseButtonDown and not _G.IsMouseButtonDown("LeftButton") then
            FinishSizing()
            return
        end
        if dragStart and _G.GetCursorPosition then
            local cx, cy = _G.GetCursorPosition()
            local es = dragStart.es
            if es == 0 then es = 1 end
            ApplySize(dragStart.w + (cx - dragStart.cx) / es,
                      dragStart.h + (dragStart.cy - cy) / es)
            W.Render()
        end
    end)

    local pos = ANx.db and ANx.db.browseWinPos
    if pos then
        f:ClearAllPoints()
        f:SetPoint(pos[1] or "CENTER", UIParent, pos[2] or "CENTER", pos[3] or 0, pos[4] or 40)
    end

    tinsert(UISpecialFrames, "AttuneNextBrowseFrame")
    f:Hide()
    f:SetScript("OnHide", function() W.OnHide() end)
    frame = f
    ApplySize(curW, curH)
    return f
end

-- ---------------------------------------------------------------------
-- Filter buttons: rebuilt each render from UI.FilterDefs
-- ---------------------------------------------------------------------
local FILTER_W, FILTER_H, FILTER_GAP = 118, 20, 4

local function LayoutFilters(f, view)
    local defs = ANx.UI.FilterDefs(view)
    local perRow = math.max(1, math.floor((curW - 32 + FILTER_GAP) / (FILTER_W + FILTER_GAP)))
    for i, d in ipairs(defs) do
        local b = f.filters[i]
        if not b then
            b = CreateFrame("Button", "AttuneNextBrowseFilter" .. i, f, "UIPanelButtonTemplate")
            b:SetWidth(FILTER_W); b:SetHeight(FILTER_H)
            local fs = b.GetFontString and b:GetFontString()
            if fs and fs.SetFontObject and _G.GameFontHighlightSmall then
                fs:SetFontObject(_G.GameFontHighlightSmall)
            end
            f.filters[i] = b
        end
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        if b.ClearAllPoints then b:ClearAllPoints() end
        b:SetPoint("TOPLEFT", f, "TOPLEFT",
            16 + col * (FILTER_W + FILTER_GAP), -76 - row * (FILTER_H + FILTER_GAP))
        b:SetText(d.label)
        b:SetScript("OnClick", function()
            d.click()
            W.Render()
        end)
        b:Show()
    end
    for i = #defs + 1, #f.filters do f.filters[i]:Hide() end
    local rows = math.max(1, math.ceil(#defs / perRow))
    return -76 - rows * (FILTER_H + FILTER_GAP) - 8
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------
function W.Render()
    local f = frame
    if not f or not f:IsShown() then return end
    local view = ANx.UI.Current()
    if not view then return end

    listTop = LayoutFilters(f, view)
    -- how many rows fit at the current height
    visibleRows = math.floor((curH + listTop - FOOTER_H) / ROW_H)
    if visibleRows < 3 then visibleRows = 3 end
    if visibleRows > MAX_ROWS then visibleRows = MAX_ROWS end
    W.visibleRows = visibleRows

    if f.scroll and f.scroll.ClearAllPoints then
        f.scroll:ClearAllPoints()
        f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 16, listTop)
        f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, FOOTER_H)
    end

    local rows = ANx.UI.BuildRows(view)
    ANx.UI.FitText(f.title, "|cffffd100" .. ANx.UI.ViewTitleOf(view) .. "|r", curW - 140)
    if #ANx.UI.stack > 1 then f.back:Enable() else f.back:Disable() end

    FauxScrollFrame_Update(f.scroll, #rows, visibleRows, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.scroll)
    for i = 1, MAX_ROWS do
        local b = f.rows[i]
        local r = (i <= visibleRows) and rows[i + offset] or nil
        if r then
            if b.ClearAllPoints then b:ClearAllPoints() end
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 20, listTop - (i - 1) * ROW_H)
            ANx.UI.FitText(b.text, r.text or "", curW - 200)
            b.right:SetText(r.right or "")
            if r.icon then
                if ANx.ClearArtCoords then ANx.ClearArtCoords(b.icon) end
                b.icon:SetTexture(r.icon)
                b.icon:Show()
            else
                b.icon:Hide()
            end
            b.anxClick = r.onClick
            b.anxItem = r.itemId
            b.anxTip = r.sub
            if r.onClick or r.itemId then b:Enable() else b:Disable() end
            b:Show()
        else
            b:Hide()
        end
    end

    if not ANx.LootDbLoaded() then
        f.status:SetText("|cffff4040Loot DB not loaded - lists will be empty|r")
    elseif ANx.Engine.scanning then
        f.status:SetText("|cffffd100Scanning loot database...|r")
    else
        f.status:SetText("|cff888888Click a row to open it - drag the corner to resize.|r")
    end
end

-- ---------------------------------------------------------------------
-- Show / hide: this window owns the navigation stack while it is open
-- ---------------------------------------------------------------------
function W.IsShown()
    return frame ~= nil and frame:IsShown()
end

function W.Show()
    if ANx.UI.EnsureEngine then ANx.UI.EnsureEngine() end
    local f = Ensure()
    if f:IsShown() then return end
    -- the main window and this one share one stack, so only one may drive it
    if ANx.UI.frame and ANx.UI.frame:IsShown() then ANx.UI.frame:Hide() end
    W.savedStack = ANx.UI.stack
    ANx.UI.stack = { { type = "browse" } }
    ANx.UI.renderTarget = W
    if ANx.db and ANx.db.scale then f:SetScale(ANx.db.scale) end
    for exp = 1, 3 do ANx.Engine.GetSummary(exp, W.Render) end
    f:Show()
    W.Render()
end

function W.OnHide()
    sizing = false
    dragStart = nil
    if ANx.UI.renderTarget == W then
        ANx.UI.renderTarget = nil
        ANx.UI.stack = W.savedStack or { { type = "root" } }
        W.savedStack = nil
    end
end

function W.Hide()
    if frame and frame:IsShown() then frame:Hide() end
    W.OnHide()   -- guarded + idempotent: also covers clients that skip OnHide
end

function W.Toggle()
    if W.IsShown() then W.Hide() else W.Show() end
end

function W.ResetLayout()
    ANx.db.browseWinSize = nil
    ANx.db.browseWinPos = nil
    if frame then
        ApplySize(DEF_W, DEF_H)
        if frame.ClearAllPoints then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
        end
        W.Render()
    end
    ANx.Print("Browse window size and position reset.")
end

-- every simple window registers here so the main window can close them
ANx.simpleWindows = ANx.simpleWindows or {}
ANx.simpleWindows[#ANx.simpleWindows + 1] = W

function ANx.CloseSimpleWindows()
    for _, win in ipairs(ANx.simpleWindows or {}) do
        if win.IsShown and win.IsShown() then win.Hide() end
    end
end

-- macro-friendly globals
function _G.AttuneNextBrowse() W.Toggle() end
SLASH_ATTUNENEXTBROWSE1 = "/anbrowse"
SlashCmdList["ATTUNENEXTBROWSE"] = function() W.Toggle() end
