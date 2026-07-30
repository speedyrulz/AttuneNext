-- =========================================================================
-- AttuneNext - GoalHud.lua
-- A small draggable window on the game UI showing every tracked goal as a
-- progress bar - check your goals without opening the addon.
-- (db.goalHud - toggle on the main menu or the window's X; it only appears
-- while you have goals tracked.)
-- =========================================================================
local ADDON_NAME, ANx = ...

local W = 250
local HEADER_H = 22
local ROW_H = 16
local MAX_GOALS = 10

local hudG

local function Ensure()
    if hudG then return hudG end
    hudG = CreateFrame("Frame", "AttuneNextGoalHUD", UIParent)
    hudG:SetWidth(W)
    hudG:SetHeight(60)
    hudG:SetFrameStrata("MEDIUM")
    if hudG.SetClampedToScreen then hudG:SetClampedToScreen(true) end
    if hudG.SetBackdrop then
        hudG:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
    end
    if hudG.SetBackdropColor then hudG:SetBackdropColor(0, 0, 0, 0.75) end
    hudG:EnableMouse(true)
    hudG:SetMovable(true)
    hudG:RegisterForDrag("LeftButton")
    hudG:SetScript("OnDragStart", function(self) self:StartMoving() end)
    hudG:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if self.GetPoint then
            local p, _, rp, x, y = self:GetPoint()
            ANx.db.goalHudPos = { p, rp, x, y }
        end
    end)

    if ANx.Art and ANx.Art.logo and ANx.ART_PATH then
        -- painted wordmark (text-only crop) instead of plain text
        local lg = hudG:CreateTexture(nil, "ARTWORK")
        lg:SetWidth(72); lg:SetHeight(13)   -- wordmark text region is 5.53:1
        lg:SetPoint("TOPLEFT", 8, -5)
        lg:SetTexture(ANx.ART_PATH .. ANx.Art.logo[1])
        if lg.SetTexCoord then lg:SetTexCoord(0.2783, 0.9697, 0.2852, 0.7852) end
        hudG.logo = lg
        hudG.title = hudG:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hudG.title:SetPoint("LEFT", lg, "RIGHT", 5, 0)
        hudG.title:SetText("-  Goals")
    else
        hudG.title = hudG:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hudG.title:SetPoint("TOPLEFT", 8, -6)
        hudG.title:SetText("|cff33ff99Attune|r|cffffffffNext|r  -  Goals")
    end
    hudG.rows = {}

    hudG.close = CreateFrame("Button", "AttuneNextGoalHUDClose", hudG, "UIPanelCloseButton")
    hudG.close:SetWidth(24); hudG.close:SetHeight(24)
    hudG.close:SetPoint("TOPRIGHT", 1, 1)
    hudG.close:SetScript("OnClick", function()
        ANx.db.goalHud = false
        hudG:Hide()
        ANx.Print("Goal window hidden - turn it back on from the main menu.")
    end)

    local pos = ANx.db and ANx.db.goalHudPos
    if pos then
        hudG:SetPoint(pos[1] or "CENTER", UIParent, pos[2] or "CENTER", pos[3] or 0, pos[4] or 0)
    else
        hudG:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -30, -200)
    end
    ANx.goalHudFrame = hudG
    return hudG
end

local function Row(i)
    local r = hudG.rows[i]
    if not r then
        local y = -HEADER_H - (i - 1) * ROW_H
        local bar = hudG:CreateTexture(nil, "BORDER")
        bar:SetPoint("TOPLEFT", 6, y - 1)
        bar:SetHeight(ROW_H - 3)
        local text = hudG:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", 8, y - 2)
        text:SetJustifyH("LEFT")
        text:SetWidth(W - 78)
        text:SetHeight(ROW_H - 4)
        local right = hudG:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        right:SetPoint("TOPRIGHT", -8, y - 2)
        right:SetJustifyH("RIGHT")
        r = { bar = bar, text = text, right = right }
        hudG.rows[i] = r
    end
    return r
end

function ANx.GoalHudNow()
    local db = ANx.db
    local goals = (db and db.goals) or {}
    if not (db and db.goalHud) or not ANx.LootDbLoaded() then
        if hudG then hudG:Hide() end
        return
    end
    local h = Ensure()
    if #goals == 0 then
        -- window stays up with a hint on how to add a goal
        local r1, r2 = Row(1), Row(2)
        r1.bar:Hide(); r2.bar:Hide()
        r1.text:SetText("|cff888888No goals tracked yet.|r"); r1.right:SetText("")
        r2.text:SetText("|cff888888Use 'Track as a goal' on any|r"); r2.right:SetText("")
        local r3 = Row(3)
        r3.bar:Hide()
        r3.text:SetText("|cff888888dungeon/raid list to add one.|r"); r3.right:SetText("")
        for i = 4, #h.rows do
            h.rows[i].bar:Hide(); h.rows[i].text:SetText(""); h.rows[i].right:SetText("")
        end
        h:SetWidth(W)
        h:SetHeight(HEADER_H + 3 * ROW_H + 8)
        h:Show()
        return
    end
    local n = 0
    for i, goal in ipairs(goals) do
        if i > MAX_GOALS then break end
        local st = ANx.Engine.GoalStatus(goal)
        n = n + 1
        local r = Row(n)
        local complete = st.total > 0 and st.left == 0
        r.bar:SetWidth((st.pct and st.pct > 0)
            and math.floor(st.pct * (W - 12) + 0.5) or 1)
        if not (ANx.SetArt and ANx.SetArt(r.bar, complete and "progress_fill_gold" or "progress_fill_teal")) then
            r.bar:SetTexture(0.15, 0.85, 0.5, complete and 0.55 or 0.30)
        end
        r.bar:Show()
        r.text:SetText((complete and "|cff00ff00" or "|cffffffff") .. st.name .. "|r")
        if complete then
            r.right:SetText("|cff00ff00done!|r")
        else
            r.right:SetText(st.done .. "/" .. st.total
                .. ((st.clears and st.clears > 0) and ("  |cffaaaaaa~" .. st.clears .. "|r") or ""))
        end
    end
    for i = n + 1, #h.rows do
        h.rows[i].bar:Hide()
        h.rows[i].text:SetText("")
        h.rows[i].right:SetText("")
    end
    h:SetWidth(W)
    h:SetHeight(HEADER_H + n * ROW_H + 8)
    h:Show()
end

local pending = false
function ANx.GoalHudUpdate()
    if pending then return end
    pending = true
    ANx.After(1, function()
        pending = false
        ANx.GoalHudNow()
    end)
end
