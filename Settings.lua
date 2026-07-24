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

    -- checkbox helper
    local function MakeCheck(name, label, anchor, dy, getter, setter)
        local cb = CreateFrame("CheckButton", "AttuneNext" .. name .. "Check", panel,
            "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -2, dy or -12)
        local txt = _G[cb:GetName() .. "Text"]
        if txt then txt:SetText(label) end
        cb.tooltipText = label
        cb:SetScript("OnClick", function(self)
            setter(self:GetChecked() and true or false)
        end)
        cb._getter = getter
        return cb
    end

    controls.minimap = MakeCheck("Minimap", "Show minimap button", scale, -20,
        function() return ANx.db.minimapShow end,
        function(v) ANx.db.minimapShow = v; ANx.UpdateMinimapButton() end)

    controls.debug = MakeCheck("Debug", "Debug logging (chat)", controls.minimap, -4,
        function() return ANx.debug end,
        function(v) ANx.debug = v end)

    -- buttons
    local function MakeButton(label, anchor, dx, dy, onClick)
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetWidth(150); b:SetHeight(22)
        b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", dx or 0, dy or -16)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        return b
    end

    local openBtn = MakeButton("Open AttuneNext", controls.debug, 0, -20, function()
        if ANx.UI then ANx.UI.Show(false) end
        if InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
    end)

    local rescanBtn = MakeButton("Rescan loot DB", openBtn, 160, 0, function()
        if ANx.Engine then ANx.Engine.ForceRescan() end
        ANx.Print("Manual rescan started.")
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end)

    local resetBtn = MakeButton("Reset filters", openBtn, 0, -8, function()
        ANx.db.scope = "char"; ANx.db.faction = "both"; ANx.db.forge = 0
        ANx.db.zoneExclusive = false; ANx.db.stockFilter = "all"
        ANx.db.vendorFilter = "all"; ANx.db.raresOnly = false; ANx.db.sort = {}
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
        ANx.Print("Filters reset to defaults.")
    end)

    local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -20)
    help:SetWidth(420); help:SetJustifyH("LEFT")
    help:SetText("|cff888888Minimap button: left-click to open, right-click for these settings. "
        .. "Drag it around the minimap to reposition.|r")

    -- sync control states from saved variables
    panel.refresh = function()
        scale:SetValue(ANx.db and ANx.db.scale or 1)
        for _, cb in pairs({ controls.minimap, controls.debug }) do
            cb:SetChecked(cb._getter() and true or false)
        end
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
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_11")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

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
