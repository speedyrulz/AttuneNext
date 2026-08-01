-- =========================================================================
-- AttuneNext - Settings.lua
-- Interface Options panel (Esc -> Interface -> AddOns -> AttuneNext, or
-- /an settings) plus a self-contained minimap button.
-- =========================================================================
local ADDON_NAME, ANx = ...

local panel
local minimapButton

-- ---------------------------------------------------------------------
-- Interface Options panel
-- ---------------------------------------------------------------------
-- lets the in-addon Options screen refresh this panel when both are open
function ANx.SyncOptionsPanel()
    if panel and panel.refresh and panel.IsShown and panel:IsShown() then
        panel.refresh()
    end
end

local function BuildPanel()
    if panel then return end
    panel = CreateFrame("Frame", "AttuneNextOptionsPanel", InterfaceOptionsFramePanelContainer)
    panel.name = "AttuneNext"
    panel:Hide()

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("AttuneNext")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetText("Attunement planner  -  v" .. (ANx.VERSION or "?") .. "   (type /an to open)")

    local controls = {}

    -- UI scale slider
    local scale = CreateFrame("Slider", "AttuneNextScaleSlider", panel, "OptionsSliderTemplate")
    scale:SetWidth(240); scale:SetHeight(18)
    scale:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 4, -34)
    scale:SetMinMaxValues(0.5, 2.0)
    scale:SetValueStep(0.05)
    if _G["AttuneNextScaleSliderLow"] then _G["AttuneNextScaleSliderLow"]:SetText("50%") end
    if _G["AttuneNextScaleSliderHigh"] then _G["AttuneNextScaleSliderHigh"]:SetText("200%") end
    scale:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 20 + 0.5) / 20
        ANx.db.scale = value
        if _G["AttuneNextScaleSliderText"] then
            _G["AttuneNextScaleSliderText"]:SetText("Window scale: " .. math.floor(value * 100 + 0.5) .. "%")
        end
        if ANx.UI and ANx.UI.frame then ANx.UI.frame:SetScale(value) end
    end)
    controls.scale = scale

    -- checkbox helper: fixed x per column so the boxes always line up
    local function MakeCheck(name, label, x, y, getter, setter)
        local cb = CreateFrame("CheckButton", "AttuneNext" .. name .. "Check", panel,
            "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        local txt = _G[cb:GetName() .. "Text"]
        if txt then txt:SetText(label) end
        cb.tooltipText = label
        cb:SetScript("OnClick", function(self)
            setter(self:GetChecked() and true or false)
            if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
        end)
        cb._getter = getter
        return cb
    end

    -- ------------- left column: general -------------
    local genHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    genHdr:SetPoint("TOPLEFT", 16, -118)
    genHdr:SetText("General")

    local LX, LY, STEP = 16, -140, -26
    controls.minimap = MakeCheck("Minimap", "Show minimap button", LX, LY,
        function() return ANx.db.minimapShow end,
        function(v) ANx.db.minimapShow = v; ANx.UpdateMinimapButton() end)
    controls.tooltip = MakeCheck("Tooltip", "Attunement info on item tooltips", LX, LY + STEP,
        function() return ANx.db.tooltip end,
        function(v) ANx.db.tooltip = v end)
    controls.alerts = MakeCheck("Alerts", "Alert on needed drops / rolls / finished attunes", LX, LY + STEP * 2,
        function() return ANx.db.alerts end,
        function(v) ANx.db.alerts = v end)
    controls.zonewatch = MakeCheck("ZoneWatch", "Zone-entry chat note (attunables left here)", LX, LY + STEP * 3,
        function() return ANx.db.zonewatch end,
        function(v) ANx.db.zonewatch = v end)
    controls.zonehud = MakeCheck("ZoneHud", "In-instance HUD window of what's left", LX, LY + STEP * 4,
        function() return ANx.db.zoneHud end,
        function(v) ANx.db.zoneHud = v; if ANx.ZoneWatchNow then ANx.ZoneWatchNow(false) end end)
    controls.goalhud = MakeCheck("GoalHud", "On-screen goal progress window", LX, LY + STEP * 5,
        function() return ANx.db.goalHud end,
        function(v) ANx.db.goalHud = v; if ANx.GoalHudNow then ANx.GoalHudNow() end end)
    controls.classic = MakeCheck("Classic", "Classic layout (no painted art)", LX, LY + STEP * 6,
        function() return ANx.db.classicSkin end,
        function(v)
            ANx.db.classicSkin = v
            if ANx.UI and ANx.UI.ApplySkin then ANx.UI.ApplySkin() end
        end)

    controls.debug = MakeCheck("Debug", "Debug logging (chat)", LX, LY + STEP * 7,
        function() return ANx.debug end,
        function(v) ANx.debug = v end)

    -- ------------- right column: the AttuneNext button -------------
    local anHdr = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    anHdr:SetPoint("TOPLEFT", 330, -118)
    anHdr:SetText("The AttuneNext button")

    local RX, RY = 330, -140
    controls.ctx = MakeCheck("Ctx", "Context sensitive (current screen)", RX, RY,
        function() return ANx.db.anext.context end,
        function(v) ANx.db.anext.context = v end)
    controls.focus = MakeCheck("Focus", "Focus the place with the most left", RX, RY + STEP,
        function() return ANx.db.anext.focus end,
        function(v) ANx.db.anext.focus = v end)
    controls.droprate = MakeCheck("DropRate", "Factor in drop rates", RX, RY + STEP * 2,
        function() return ANx.db.anext.dropRate end,
        function(v) ANx.db.anext.dropRate = v end)
    local runBtn = CreateFrame("Button", "AttuneNextRunModeBtn", panel, "UIPanelButtonTemplate")
    runBtn:SetWidth(268); runBtn:SetHeight(22)
    runBtn:SetPoint("TOPLEFT", RX + 2, RY + STEP * 3 - 2)
    runBtn:SetScript("OnClick", function(self)
        local c = ANx.RunMode()
        for i, m in ipairs(ANx.RUN_MODES) do
            if m == c then ANx.db.anext.instance = ANx.RUN_MODES[(i % #ANx.RUN_MODES) + 1]; break end
        end
        self:SetText("Recommend whole run: " .. (ANx.RUN_MODE_LABELS[ANx.RunMode()] or "?"))
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end)

    local timeBtn = CreateFrame("Button", "AttuneNextTimeModeBtn", panel, "UIPanelButtonTemplate")
    timeBtn:SetWidth(268); timeBtn:SetHeight(22)
    timeBtn:SetPoint("TOPLEFT", RX + 2, RY + STEP * 4 - 4)
    timeBtn:SetScript("OnClick", function(self)
        local cur = ANx.TimeMode()
        for i, m in ipairs(ANx.TIME_MODES) do
            if m == cur then
                ANx.db.timeMode = ANx.TIME_MODES[(i % #ANx.TIME_MODES) + 1]
                break
            end
        end
        self:SetText("Run length: " .. (ANx.TIME_MODE_LABELS[ANx.TimeMode()] or "?"))
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end)

    local anNote = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    anNote:SetPoint("TOPLEFT", RX + 4, RY + STEP * 5 - 8)
    anNote:SetWidth(270); anNote:SetJustifyH("LEFT")
    anNote:SetText("|cff888888The category you're browsing always wins - on a Quests / Vendor / Profession screen the pick comes from it.|r")

    local function IgnoreCount()
        local n = 0
        for _ in pairs((ANx.db.anext and ANx.db.anext.ignore) or {}) do n = n + 1 end
        for _ in pairs((ANx.db.anext and ANx.db.anext.ignoreInst) or {}) do n = n + 1 end
        return n
    end

    -- ------------- bottom action row -------------
    local function MakeButton(name, label, x, w, onClick)
        local b = CreateFrame("Button", name, panel, "UIPanelButtonTemplate")
        b:SetWidth(w); b:SetHeight(22)
        b:SetPoint("BOTTOMLEFT", x, 46)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        return b
    end

    MakeButton(nil, "Open AttuneNext", 16, 138, function()
        if ANx.UI then ANx.UI.Show(false) end
        if InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
    end)
    MakeButton(nil, "Rescan loot DB", 160, 138, function()
        if ANx.Engine then ANx.Engine.ForceRescan() end
        ANx.Print("Manual rescan started.")
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end)
    MakeButton(nil, "Reset filters", 304, 138, function()
        ANx.db.scope = "char"; ANx.db.faction = "both"; ANx.db.forge = 1
        ANx.db.zoneExclusive = false; ANx.db.stockFilter = "all"
        ANx.db.vendorFilter = "all"; ANx.db.raresOnly = false; ANx.db.sort = {}
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
        ANx.Print("Filters reset to defaults.")
    end)
    local hudBtn = MakeButton("AttuneNextHudResetBtn", "Reset HUD size/pos", 448, 150, function()
        if ANx.ResetHudLayout then ANx.ResetHudLayout() end
    end)

    local ignoreBtn = MakeButton("AttuneNextIgnoreResetBtn", "Reset ignore list", 0, 160, function(self)
        ANx.db.anext.ignore = {}
        ANx.db.anext.ignoreInst = {}
        ANx.Print("AttuneNext ignore list cleared.")
        self:SetText("Reset ignore list (0)")
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end)
    ignoreBtn:ClearAllPoints()
    ignoreBtn:SetPoint("TOPLEFT", anNote, "BOTTOMLEFT", -2, -12)

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    help:SetPoint("BOTTOMLEFT", 16, 16)
    help:SetWidth(590); help:SetJustifyH("LEFT")
    help:SetText("|cff888888Minimap button: left-click opens the window, right-click opens these settings, drag to move it. /an hud toggles the instance HUD.|r")

    -- sync control states from saved variables (also called when the addon's
    -- own Options screen changes something, so the two menus mirror)
    panel.refresh = function()
        scale:SetValue(ANx.db and ANx.db.scale or 1)
        for _, cb in pairs({ controls.minimap, controls.tooltip, controls.alerts,
                             controls.zonewatch, controls.zonehud, controls.goalhud,
                             controls.classic, controls.debug, controls.ctx,
                             controls.focus, controls.droprate }) do
            cb:SetChecked(cb._getter() and true or false)
        end
        runBtn:SetText("Recommend whole run: " .. (ANx.RUN_MODE_LABELS[ANx.RunMode()] or "?"))
        timeBtn:SetText("Run length: " .. (ANx.TIME_MODE_LABELS[ANx.TimeMode()] or "?"))
        ignoreBtn:SetText("Reset ignore list (" .. IgnoreCount() .. ")")
    end
    panel.okay = function() end
    panel.cancel = function() end

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

function ANx.OpenSettings()
    BuildPanel()
    if InterfaceOptionsFrame_OpenToCategory then
        -- called twice: works around a 3.3.5 quirk where the first call
        -- doesn't scroll to the right panel
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

-- ---------------------------------------------------------------------
-- Minimap button (no external libraries)
-- ---------------------------------------------------------------------
local function UpdateMinimapPosition()
    if not minimapButton then return end
    local angle = ANx.db and ANx.db.minimapAngle or 220
    local x = cos(angle) * 80
    local y = sin(angle) * 80
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function BuildMinimapButton()
    if minimapButton or not Minimap then return end
    local b = CreateFrame("Button", "AttuneNextMinimapButton", Minimap)
    minimapButton = b
    b:SetWidth(31); b:SetHeight(31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetMovable(true)

    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("CENTER", 0, 1)
    if ANx.Art and ANx.Art.emblem and ANx.SetArt then
        ANx.SetArt(icon, "emblem")
        icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_Book_11")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53); border:SetHeight(53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ANx.OpenSettings()
        else
            if ANx.UI then ANx.UI.Toggle() end
        end
    end)

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local sc = Minimap:GetEffectiveScale()
            px, py = px / sc, py / sc
            ANx.db.minimapAngle = math.deg(math.atan2(py - my, px - mx))
            UpdateMinimapPosition()
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("AttuneNext")
        GameTooltip:AddLine("|cffffffffLeft-click|r  Open the planner", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffRight-click|r  Settings", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffDrag|r  Move around minimap", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdateMinimapPosition()
end

function ANx.UpdateMinimapButton()
    if not minimapButton then BuildMinimapButton() end
    if not minimapButton then return end
    if ANx.db and ANx.db.minimapShow == false then
        minimapButton:Hide()
    else
        minimapButton:Show()
        UpdateMinimapPosition()
    end
end

-- ---------------------------------------------------------------------
-- Init (called from Core once saved variables are ready)
-- ---------------------------------------------------------------------
function ANx.InitSettings()
    BuildPanel()
    BuildMinimapButton()
    ANx.UpdateMinimapButton()
end
