-- =========================================================================
-- AttuneNext - UI.lua
-- Menu-driven browser:
--   Expansion -> Content type -> Dungeon/Raid (w/ difficulty) or
--   Zone (Quest / World Drop / Vendor->Currency->Vendor) or Profession
--   -> remaining item lists sorted by drop rate -> item source detail
-- =========================================================================
local ADDON_NAME, ANx = ...
local Engine
local UI = {}
ANx.UI = UI

local ROW_H = 34
local VISIBLE_ROWS = 13
local FRAME_W = 700

local DIFF_LABELS = {
    [""] = "Browse", ["N"] = "Normal", ["H"] = "Heroic", ["M"] = "Mythic",
    ["10"] = "10 Player", ["25"] = "25 Player",
    ["10N"] = "10 Normal", ["25N"] = "25 Normal",
    ["10H"] = "10 Heroic", ["25H"] = "25 Heroic",
}

local CONTENT_DEFS = {
    { key = "D", label = "Dungeons" },
    { key = "R", label = "Raids" },
    { key = "Q", label = "Quests" },
    { key = "W", label = "Zone World Drops" },
    { key = "V", label = "Vendors" },
    { key = "C", label = "Crafting" },
}

-- suffix for stats-cache keys so difficulty/size changes don't collide
local function DiffKey()
    return (ANx.db.difficulty or "all") .. (ANx.db.raidSize or "all")
end

-- ---------------------------------------------------------------------
-- Sorting configuration
-- ---------------------------------------------------------------------
local NODE_SORTS = { "default", "name", "pct", "left", "distance" }
local ITEM_SORTS = { "chance", "name", "progress", "distance" }
local SEARCH_SORTS = { "name", "distance" }
local SORT_LABELS = {
    default = "Default", name = "Name", pct = "Attuned %",
    left = "Attunes Left", chance = "Drop %", progress = "Progress",
    distance = "Distance",
}
local SORTABLE_NODE_VIEWS = {
    instances = true, zones = true, quests = true,
    currencies = true, vendors = true, profs = true, events = true,
}

local function ViewSortModes(view)
    if not view then return nil end
    if view.type == "items" then return ITEM_SORTS end
    if view.type == "search" then return SEARCH_SORTS end
    if SORTABLE_NODE_VIEWS[view.type] then return NODE_SORTS end
    return nil
end

local function CurrentSort(view)
    local modes = ViewSortModes(view)
    if not modes then return nil end
    local m = ANx.db and ANx.db.sort and ANx.db.sort[view.type]
    for _, mm in ipairs(modes) do
        if mm == m then return m end
    end
    return modes[1]
end

local function CycleSort(view)
    local modes = ViewSortModes(view)
    if not modes then return end
    local cur = CurrentSort(view)
    for i, m in ipairs(modes) do
        if m == cur then
            ANx.db.sort[view.type] = modes[(i % #modes) + 1]
            return
        end
    end
    ANx.db.sort[view.type] = modes[1]
end

-- ---------------------------------------------------------------------
-- Vendor currency-category filter
-- ---------------------------------------------------------------------
local VENDOR_FILTERS = { "all", "gold", "points", "emblem", "token" }
local VENDOR_FILTER_LABELS = {
    all = "All", gold = "Gold", points = "Honor/Arena",
    emblem = "Emblems", token = "Tokens",
}

-- true if the currency-type filter button applies to this view
local function ViewHasVendorFilter(view)
    if not view then return false end
    return view.type == "currencies" or (view.type == "zones" and view.mode == "V")
end

-- true if the "rare spawns only" toggle applies to this view (World Drops)
local function ViewIsWorldDrop(view)
    if not view then return false end
    if view.type == "zones" and view.mode == "W" then return true end
    if view.type == "items" and view.worldDrop then return true end
    return false
end

-- true if the difficulty (tier) filter is relevant (a dungeon/raid screen)
local function ViewHasDifficulty(view)
    if not view then return false end
    local t = view.type
    if t == "content" or t == "contentTypes" or t == "instances" then return true end
    if t == "contentExp" and (view.content == "D" or view.content == "R") then return true end
    return false
end

-- true if the raid-size filter is relevant (raids are in scope)
local function ViewHasRaidSize(view)
    if not view then return false end
    local t = view.type
    if t == "content" or t == "contentTypes" then return true end
    if t == "contentExp" and view.content == "R" then return true end
    if t == "instances" and view.kind == "R" then return true end
    return false
end

-- true if the vendor stock filter applies to this view (any vendor screen)
local function ViewHasStockFilter(view)
    if not view then return false end
    if view.type == "currencies" or view.type == "vendors" then return true end
    if view.type == "zones" and view.mode == "V" then return true end
    if view.type == "items" and view.showCost then return true end
    return false
end

local function CycleVendorFilter()
    local cur = ANx.db.vendorFilter or "all"
    for i, f in ipairs(VENDOR_FILTERS) do
        if f == cur then
            ANx.db.vendorFilter = VENDOR_FILTERS[(i % #VENDOR_FILTERS) + 1]
            return
        end
    end
    ANx.db.vendorFilter = "all"
end

-- ---------------------------------------------------------------------
-- Navigation stack
-- ---------------------------------------------------------------------
UI.stack = {}

function UI.Push(view)
    table.insert(UI.stack, view)
    UI.Render()
end

function UI.Pop()
    if #UI.stack > 1 then
        table.remove(UI.stack)
        UI.Render()
    end
end

function UI.Current()
    return UI.stack[#UI.stack]
end

function UI.RefreshIfShown()
    if UI.frame and UI.frame:IsShown() then
        UI.Render()
    end
end

-- ---------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------
local rowButtons = {}

local function CreateMainFrame()
    Engine = ANx.Engine
    local f = CreateFrame("Frame", "AttuneNextFrame", UIParent)
    f:SetWidth(FRAME_W)
    f:SetHeight(ROW_H * VISIBLE_ROWS + 194)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScale(ANx.db and ANx.db.scale or 1)

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    -- title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cff33ff99Attune|r|cffffffffNext|r")
    f.title = title

    -- close
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -8)

    -- back button
    local back = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    back:SetWidth(60); back:SetHeight(20)
    back:SetPoint("TOPLEFT", 16, -14)
    back:SetText("< Back")
    back:SetScript("OnClick", UI.Pop)
    f.back = back

    -- refresh button (full manual rescan of the loot DB)
    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetWidth(60); refresh:SetHeight(20)
    refresh:SetPoint("TOPRIGHT", -30, -14)
    refresh:SetText("Rescan")
    refresh:SetScript("OnClick", function()
        Engine.ForceRescan()
        ANx.Print("Manual rescan started (saved cache cleared).")
        UI.Render()
    end)

    -- Random button (context-sensitive): jump to a random unattuned item
    local randomBtn = CreateFrame("Button", "AttuneNextRandomBtn", f, "UIPanelButtonTemplate")
    randomBtn:SetWidth(80); randomBtn:SetHeight(20)
    randomBtn:SetPoint("TOPRIGHT", -95, -14)
    randomBtn:SetText("Random")
    randomBtn:SetScript("OnClick", function() UI.RandomPick() end)
    f.randomBtn = randomBtn

    -- breadcrumb
    local crumb = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    crumb:SetPoint("TOP", 0, -38)
    crumb:SetWidth(FRAME_W - 60)
    crumb:SetJustifyH("CENTER")
    f.crumb = crumb

    -- ================= toolbar =================
    -- Row A: scope / faction / forge / sort
    local scopeBtn = CreateFrame("Button", "AttuneNextScopeBtn", f, "UIPanelButtonTemplate")
    scopeBtn:SetWidth(150); scopeBtn:SetHeight(20)
    scopeBtn:SetPoint("TOPLEFT", 16, -56)
    scopeBtn:SetText("Attunes: Character")
    scopeBtn:SetScript("OnClick", function()
        ANx.db.scope = (ANx.db.scope == "account") and "char" or "account"
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.scopeBtn = scopeBtn

    local factionBtn = CreateFrame("Button", "AttuneNextFactionBtn", f, "UIPanelButtonTemplate")
    factionBtn:SetWidth(138); factionBtn:SetHeight(20)
    factionBtn:SetPoint("TOPLEFT", 172, -56)
    factionBtn:SetText("Faction: Both")
    factionBtn:SetScript("OnClick", function()
        local cur = ANx.db.faction or "both"
        ANx.db.faction = (cur == "both") and "A" or (cur == "A") and "H" or "both"
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.factionBtn = factionBtn

    local forgeBtn = CreateFrame("Button", "AttuneNextForgeBtn", f, "UIPanelButtonTemplate")
    forgeBtn:SetWidth(164); forgeBtn:SetHeight(20)
    forgeBtn:SetPoint("TOPLEFT", 316, -56)
    forgeBtn:SetText("Show: Unattuned")
    forgeBtn:SetScript("OnClick", function()
        ANx.db.forge = ((ANx.db.forge or 0) + 1) % 5
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.forgeBtn = forgeBtn

    local sortBtn = CreateFrame("Button", "AttuneNextSortBtn", f, "UIPanelButtonTemplate")
    sortBtn:SetWidth(150); sortBtn:SetHeight(20)
    sortBtn:SetPoint("TOPLEFT", 486, -56)
    sortBtn:SetText("Sort: Default")
    sortBtn:SetScript("OnClick", function()
        CycleSort(UI.Current())
        UI.Render()
    end)
    f.sortBtn = sortBtn

    -- Row B: global item filters (zone-exclusive / bind / accessories)
    local zexBtn = CreateFrame("Button", "AttuneNextZexBtn", f, "UIPanelButtonTemplate")
    zexBtn:SetWidth(180); zexBtn:SetHeight(20)
    zexBtn:SetPoint("TOPLEFT", 16, -80)
    zexBtn:SetText("Zone-exclusive: Off")
    zexBtn:SetScript("OnClick", function()
        ANx.db.zoneExclusive = not ANx.db.zoneExclusive
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.zexBtn = zexBtn

    local bindBtn = CreateFrame("Button", "AttuneNextBindBtn", f, "UIPanelButtonTemplate")
    bindBtn:SetWidth(150); bindBtn:SetHeight(20)
    bindBtn:SetPoint("TOPLEFT", 202, -80)
    bindBtn:SetText("Bind: Both")
    bindBtn:SetScript("OnClick", function()
        local cur = ANx.db.bindFilter or "both"
        ANx.db.bindFilter = (cur == "both") and "bop" or (cur == "bop") and "boe" or "both"
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.bindBtn = bindBtn

    local accBtn = CreateFrame("Button", "AttuneNextAccBtn", f, "UIPanelButtonTemplate")
    accBtn:SetWidth(185); accBtn:SetHeight(20)
    accBtn:SetPoint("TOPLEFT", 358, -80)
    accBtn:SetText("Accessories: On")
    accBtn:SetScript("OnClick", function()
        ANx.db.accessories = not (ANx.db.accessories ~= false)
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.accBtn = accBtn

    -- Row C: vendor / world-drop context filters
    local filterBtn = CreateFrame("Button", "AttuneNextFilterBtn", f, "UIPanelButtonTemplate")
    filterBtn:SetWidth(190); filterBtn:SetHeight(20)
    filterBtn:SetPoint("TOPLEFT", 16, -104)
    filterBtn:SetText("Currency: All")
    filterBtn:SetScript("OnClick", function()
        CycleVendorFilter()
        UI.Render()
    end)
    f.filterBtn = filterBtn

    -- world-drop "rares only" toggle (shares the currency slot; never both)
    local raresBtn = CreateFrame("Button", "AttuneNextRaresBtn", f, "UIPanelButtonTemplate")
    raresBtn:SetWidth(190); raresBtn:SetHeight(20)
    raresBtn:SetPoint("TOPLEFT", 16, -104)
    raresBtn:SetText("Rares only: Off")
    raresBtn:SetScript("OnClick", function()
        ANx.db.raresOnly = not ANx.db.raresOnly
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.raresBtn = raresBtn

    local stockBtn = CreateFrame("Button", "AttuneNextStockBtn", f, "UIPanelButtonTemplate")
    stockBtn:SetWidth(150); stockBtn:SetHeight(20)
    stockBtn:SetPoint("TOPLEFT", 212, -104)
    stockBtn:SetText("Stock: All")
    stockBtn:SetScript("OnClick", function()
        local cur = ANx.db.stockFilter or "all"
        ANx.db.stockFilter = (cur == "all") and "limited" or (cur == "limited") and "unlimited" or "all"
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.stockBtn = stockBtn

    local affordBtn = CreateFrame("Button", "AttuneNextAffordBtn", f, "UIPanelButtonTemplate")
    affordBtn:SetWidth(185); affordBtn:SetHeight(20)
    affordBtn:SetPoint("TOPLEFT", 368, -104)
    affordBtn:SetText("Affordable: Off")
    affordBtn:SetScript("OnClick", function()
        ANx.db.affordableOnly = not ANx.db.affordableOnly
        ANx.InvalidatePlayerCurrency()
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.affordBtn = affordBtn

    -- difficulty tier filter (shares pos1 with currency/rares; D/R screens)
    local diffBtn = CreateFrame("Button", "AttuneNextDiffBtn", f, "UIPanelButtonTemplate")
    diffBtn:SetWidth(190); diffBtn:SetHeight(20)
    diffBtn:SetPoint("TOPLEFT", 16, -104)
    diffBtn:SetText("Difficulty: All")
    diffBtn:SetScript("OnClick", function()
        local order = { "all", "normal", "heroic", "mythic" }
        local cur = ANx.db.difficulty or "all"
        for i, v in ipairs(order) do if v == cur then ANx.db.difficulty = order[(i % #order) + 1]; break end end
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.diffBtn = diffBtn

    -- raid-size filter (shares pos2 with stock; raid screens)
    local sizeBtn = CreateFrame("Button", "AttuneNextSizeBtn", f, "UIPanelButtonTemplate")
    sizeBtn:SetWidth(150); sizeBtn:SetHeight(20)
    sizeBtn:SetPoint("TOPLEFT", 212, -104)
    sizeBtn:SetText("Size: All")
    sizeBtn:SetScript("OnClick", function()
        local order = { "all", "10", "25" }
        local cur = ANx.db.raidSize or "all"
        for i, v in ipairs(order) do if v == cur then ANx.db.raidSize = order[(i % #order) + 1]; break end end
        Engine.InvalidateStats()
        UI.Render()
    end)
    f.sizeBtn = sizeBtn

    -- ---------- search row ----------
    local searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", 20, -134)
    searchLabel:SetText("Search:")

    local searchBox = CreateFrame("EditBox", "AttuneNextSearchBox", f, "InputBoxTemplate")
    searchBox:SetWidth(300); searchBox:SetHeight(18)
    searchBox:SetPoint("TOPLEFT", 74, -130)
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText(""); self:ClearFocus()
    end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        if UI._searchSetting then return end
        local txt = self:GetText() or ""
        UI.searchQuery = txt
        local cur = UI.Current()
        if txt ~= "" then
            if not cur or cur.type ~= "search" then
                UI.Push({ type = "search" })
            else
                UI.Render()
            end
        else
            if cur and cur.type == "search" then UI.Pop() else UI.Render() end
        end
    end)
    f.searchBox = searchBox

    local searchHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
    searchHint:SetText("find any attunable item by name")
    f.searchHint = searchHint

    -- scroll area
    local scroll = CreateFrame("ScrollFrame", "AttuneNextScroll", f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -154)
    scroll:SetPoint("BOTTOMRIGHT", -36, 38)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, UI.Render)
    end)
    f.scroll = scroll

    -- rows
    for i = 1, VISIBLE_ROWS do
        local b = CreateFrame("Button", "AttuneNextRow" .. i, f)
        b:SetWidth(FRAME_W - 56)
        b:SetHeight(ROW_H)
        b:SetPoint("TOPLEFT", 20, -154 - (i - 1) * ROW_H)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetWidth(28); b.icon:SetHeight(28)
        b.icon:SetPoint("LEFT", 2, 0)

        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.text:SetPoint("TOPLEFT", 36, -3)
        b.text:SetJustifyH("LEFT")
        b.text:SetWidth(FRAME_W - 300)

        b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.sub:SetPoint("BOTTOMLEFT", 36, 3)
        b.sub:SetJustifyH("LEFT")
        b.sub:SetWidth(FRAME_W - 300)
        b.sub:SetTextColor(0.7, 0.7, 0.7)

        b.right = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.right:SetPoint("TOPRIGHT", -6, -3)
        b.right:SetJustifyH("RIGHT")

        b.right2 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.right2:SetPoint("BOTTOMRIGHT", -6, 3)
        b.right2:SetJustifyH("RIGHT")
        b.right2:SetTextColor(0.6, 0.6, 0.6)

        b:SetScript("OnClick", function(self)
            if self.onClick then self.onClick(self) end
        end)
        b:SetScript("OnEnter", function(self)
            if self.tooltipItem then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.tooltipItem)
                if not ok then GameTooltip:SetText("Item #" .. self.tooltipItem) end
                GameTooltip:Show()
            elseif self.tooltipText then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.tooltipText, 1, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)

        rowButtons[i] = b
    end

    -- footer: status text (attuned-visibility now lives on the Show: forge button)
    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("BOTTOMLEFT", 18, 20)
    status:SetWidth(FRAME_W - 40)
    status:SetJustifyH("LEFT")
    f.status = status

    tinsert(UISpecialFrames, "AttuneNextFrame")
    f:Hide()
    return f
end

-- ---------------------------------------------------------------------
-- Row helpers
-- ---------------------------------------------------------------------
local displayRows = {}   -- flattened row descriptors for current view

local function AddRow(r)
    displayRows[#displayRows + 1] = r
end

local function ResetRows()
    for i = #displayRows, 1, -1 do displayRows[i] = nil end
end

-- Sortable node rows: builders collect via AddNodeRow, then FlushNodeRows
-- applies the page's sort mode (name asc / attuned% desc / left desc).
local nodeRows = {}

local function AddNodeRow(sortName, st, rowDesc, loc)
    rowDesc._sName = (sortName or ""):lower()
    if st and st.total and st.total > 0 then
        rowDesc._sPct = st.attuned / st.total
        rowDesc._sLeft = st.total - st.attuned
    else
        rowDesc._sPct, rowDesc._sLeft = -1, -1
    end
    rowDesc._loc = loc
    nodeRows[#nodeRows + 1] = rowDesc
end

local function FlushNodeRows(mode)
    if mode == "name" then
        table.sort(nodeRows, function(a, b) return a._sName < b._sName end)
    elseif mode == "pct" then
        table.sort(nodeRows, function(a, b)
            if a._sPct ~= b._sPct then return a._sPct > b._sPct end
            return a._sName < b._sName
        end)
    elseif mode == "left" then
        table.sort(nodeRows, function(a, b)
            if a._sLeft ~= b._sLeft then return a._sLeft > b._sLeft end
            return a._sName < b._sName
        end)
    elseif mode == "distance" then
        for _, r in ipairs(nodeRows) do r._sDist = ANx.DistanceRank(r._loc) end
        table.sort(nodeRows, function(a, b)
            if a._sDist ~= b._sDist then return a._sDist < b._sDist end
            return a._sName < b._sName
        end)
    end
    for _, r in ipairs(nodeRows) do AddRow(r) end
    for i = #nodeRows, 1, -1 do nodeRows[i] = nil end
end

local QUALITY_HEX = {}
local function QualityHex(q)
    if not QUALITY_HEX[q] then
        local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
        QUALITY_HEX[q] = c and c.hex or "|cffffffff"
    end
    return QUALITY_HEX[q]
end

local function BestLine(best)
    if not best then return "" end
    local name = ANx.GetItemDisplay(best.id)
    return string.format("|cffffd100Best:|r %s |cff00ff88(%s)|r%s",
        name, ANx.FormatChance(best.chance),
        best.srcName and (" |cff888888- " .. best.srcName .. "|r") or "")
end

local function SrcTypeLabel(t)
    local S = ANx.SRC
    if t == S.QUEST then return "Quest"
    elseif t == S.VENDOR then return "Vendor"
    elseif t == S.CRAFT_TRAINER then return "Craft (trainer)"
    elseif t == S.CRAFT_RECIPE then return "Craft (recipe)"
    elseif t == S.OBJECT or t == S.MYTHIC_GO then return "Chest"
    elseif t == S.ITEM then return "Container"
    elseif t == S.FISHING or t == S.FISHING_NODE then return "Fishing"
    elseif t == S.PICKPOCKET then return "Pickpocket"
    elseif t == S.ACHIEVEMENT then return "Achievement"
    elseif t == S.PLAYER then return "Player"
    end
    return "Drop"
end

-- ---------------------------------------------------------------------
-- View builders (each fills displayRows)
-- ---------------------------------------------------------------------
local builders = {}

local function SummaryRow(exp, onReady)
    local sum = Engine.GetSummary(exp, onReady)
    if not sum then return nil end
    return sum
end

-- Root menu: choose how to browse.
builders["root"] = function(view)
    -- kick off the background scans so counts are ready when you drill in
    for exp = 1, 3 do SummaryRow(exp, UI.RefreshIfShown) end
    AddRow({
        text = "|cffffd100Filter by Expansion|r",
        sub = "Pick Classic / TBC / WotLK first, then the content type",
        onClick = function() UI.Push({ type = "home" }) end,
    })
    AddRow({
        text = "|cffffd100Filter by Content Type|r",
        sub = "Pick Dungeons / Raids / Quests / etc. first, then the expansion",
        onClick = function() UI.Push({ type = "contentTypes" }) end,
    })
    local evItems = Engine.AllEventItems()
    if #evItems > 0 then
        local est = Engine.Stats(evItems, "events:all")
        AddRow({
            text = "|cffff77ffEvents & Holidays|r",
            sub = "Gear only available during seasonal events",
            right = ANx.StatsString(est.attuned, est.total),
            onClick = function() UI.Push({ type = "events" }) end,
        })
    end
    AddRow({
        text = "|cff888888How it works|r",
        sub = "Use the Random button (top) any time to jump to a random item to attune.",
        tooltipText = "Character scope: counts every item the current character can attune. Account scope: counts every attunable item (any character).\n\nThe global filters (Faction, Show/forge, Zone-exclusive, Bind, Accessories, Difficulty) adjust the counts at every level.\n\nRandom picks a random unattuned item from whatever you're currently looking at.",
    })
end

builders["home"] = function(view)
    for exp = 1, 3 do
        local sum = SummaryRow(exp, UI.RefreshIfShown)
        local rightText, subText
        if sum then
            local st = Engine.UnionStats(Engine.AllContentSets(sum), "sum:" .. exp .. ":all:" .. DiffKey())
            rightText = ANx.StatsString(st.attuned, st.total)
            subText = ""
        else
            rightText = "|cff888888Scanning...|r"
            subText = "Building item database for this expansion"
        end
        AddRow({
            text = ANx.EXP_COLORS[exp] .. ANx.EXP_NAMES[exp] .. "|r",
            sub = subText, right = rightText,
            onClick = function() UI.Push({ type = "content", exp = exp }) end,
        })
    end
    local scopeText = (ANx.db.scope == "account")
        and "Counts are ACCOUNT-wide (any character). Use the Attunes button to switch."
        or "Counts are for items THIS character can attune. Use the Attunes button to switch."
    -- Events / holidays category (attunable gear only obtainable during events)
    AddRow({
        text = "|cff888888" .. scopeText .. "|r",
    })
end

builders["content"] = function(view)
    local exp = view.exp
    local sum = SummaryRow(exp, UI.RefreshIfShown)
    for _, def in ipairs(CONTENT_DEFS) do
        local rightText = "|cff888888Scanning...|r"
        if sum then
            local st = Engine.SetStats(Engine.ContentSet(sum, def.key),
                "sum:" .. exp .. ":" .. def.key .. ":" .. DiffKey())
            rightText = ANx.StatsString(st.attuned, st.total)
        end
        AddRow({
            text = def.label,
            right = rightText,
            onClick = function()
                if def.key == "D" or def.key == "R" then
                    UI.Push({ type = "instances", exp = exp, kind = def.key })
                elseif def.key == "Q" then
                    UI.Push({ type = "zones", exp = exp, mode = "Q" })
                elseif def.key == "W" then
                    UI.Push({ type = "zones", exp = exp, mode = "W" })
                elseif def.key == "V" then
                    UI.Push({ type = "zones", exp = exp, mode = "V" })
                else
                    UI.Push({ type = "profs", exp = exp })
                end
            end,
        })
    end
end

-- content-first: list the content types (totals across all expansions)
local function PushContentNode(cat, exp)
    if cat == "D" or cat == "R" then UI.Push({ type = "instances", exp = exp, kind = cat })
    elseif cat == "Q" then UI.Push({ type = "zones", exp = exp, mode = "Q" })
    elseif cat == "W" then UI.Push({ type = "zones", exp = exp, mode = "W" })
    elseif cat == "V" then UI.Push({ type = "zones", exp = exp, mode = "V" })
    else UI.Push({ type = "profs", exp = exp }) end
end

builders["contentTypes"] = function(view)
    for _, def in ipairs(CONTENT_DEFS) do
        local sets, ready = {}, true
        for exp = 1, 3 do
            local sum = SummaryRow(exp, UI.RefreshIfShown)
            if sum then sets[#sets + 1] = Engine.ContentSet(sum, def.key) else ready = false end
        end
        local rightText = "|cff888888Scanning...|r"
        if ready then
            local st = Engine.UnionStats(sets, "ct:" .. def.key .. ":" .. DiffKey())
            rightText = ANx.StatsString(st.attuned, st.total)
        end
        AddRow({
            text = def.label,
            right = rightText,
            onClick = function() UI.Push({ type = "contentExp", content = def.key }) end,
        })
    end
end

-- content-first: after a content type, pick the expansion (or use Random for any)
builders["contentExp"] = function(view)
    local cat = view.content
    for exp = 1, 3 do
        local sum = SummaryRow(exp, UI.RefreshIfShown)
        local rightText = "|cff888888Scanning...|r"
        if sum then
            local st = Engine.SetStats(Engine.ContentSet(sum, cat),
                "ce:" .. exp .. ":" .. cat .. ":" .. DiffKey())
            rightText = ANx.StatsString(st.attuned, st.total)
        end
        AddRow({
            text = ANx.EXP_COLORS[exp] .. ANx.EXP_NAMES[exp] .. "|r",
            right = rightText,
            onClick = function() PushContentNode(cat, exp) end,
        })
    end
end

builders["instances"] = function(view)
    local list = Engine.InstancesFor(view.exp, view.kind)
    local mode = CurrentSort(view)
    -- build one group per instance (header + difficulty rows stay together),
    -- sorted by the instance's aggregate stats
    local groups = {}
    local shownInstances = 0
    for _, inst in ipairs(list) do
        -- apply the difficulty / raid-size filter to the shown difficulty rows
        local diffs = {}
        for _, d in ipairs(Engine.InstanceDiffs(inst)) do
            if ANx.DifficultyMatches(d.label) then diffs[#diffs + 1] = d end
        end
        if #diffs == 0 then
            -- nothing matches the difficulty filter for this instance; skip it
        else
        shownInstances = shownInstances + 1
        local group = { name = inst.name:lower(), rows = {}, att = 0, tot = 0 }
        if #diffs == 1 then
            local d = diffs[1]
            local key = "i:" .. inst.map .. ":" .. d.diff
            local st = Engine.StatsWithBest(d.items, key, inst.name, ANx.INSTANCE_DROP_SRC)
            group.att, group.tot = st.attuned, st.total
            -- show the difficulty label when a filter has collapsed this to one row
            local nameText = inst.name
            local title = inst.name
            if d.label ~= "" then
                local dl = DIFF_LABELS[d.label] or d.label
                nameText = inst.name .. "  |cffcccccc(" .. dl .. ")|r"
                title = inst.name .. " (" .. dl .. ")"
            end
            group.rows[1] = {
                text = nameText,
                sub = BestLine(st.best),
                right = ANx.StatsString(st.attuned, st.total),
                onClick = function()
                    UI.Push({ type = "items", title = title, items = d.items,
                        zoneName = inst.name, srcFilter = ANx.INSTANCE_DROP_SRC })
                end,
            }
        else
            group.rows[1] = { text = "|cffffd100" .. inst.name .. "|r", header = true }
            for _, d in ipairs(diffs) do
                local key = "i:" .. inst.map .. ":" .. d.diff
                local st = Engine.StatsWithBest(d.items, key, inst.name, ANx.INSTANCE_DROP_SRC)
                group.att = group.att + st.attuned
                group.tot = group.tot + st.total
                local label = DIFF_LABELS[d.label] or d.label
                group.rows[#group.rows + 1] = {
                    text = "    |cffcccccc" .. label .. "|r",
                    sub = "      " .. BestLine(st.best),
                    right = ANx.StatsString(st.attuned, st.total),
                    onClick = function()
                        UI.Push({ type = "items", title = inst.name .. " (" .. label .. ")",
                            items = d.items, zoneName = inst.name, srcFilter = ANx.INSTANCE_DROP_SRC })
                    end,
                }
            end
        end
        groups[#groups + 1] = group
        end
    end
    if mode == "name" or mode == "distance" then
        -- instances have no world coordinates; Distance falls back to name order
        table.sort(groups, function(a, b) return a.name < b.name end)
    elseif mode == "pct" then
        table.sort(groups, function(a, b)
            local pa = a.tot > 0 and a.att / a.tot or -1
            local pb = b.tot > 0 and b.att / b.tot or -1
            if pa ~= pb then return pa > pb end
            return a.name < b.name
        end)
    elseif mode == "left" then
        table.sort(groups, function(a, b)
            local la, lb = a.tot - a.att, b.tot - b.att
            if la ~= lb then return la > lb end
            return a.name < b.name
        end)
    end
    for _, group in ipairs(groups) do
        for _, r in ipairs(group.rows) do AddRow(r) end
    end
    if #list == 0 then
        AddRow({ text = "|cff888888No instances found|r" })
    elseif shownInstances == 0 then
        AddRow({ text = "|cff888888No instances at this difficulty (change the Difficulty filter)|r" })
    end
end

builders["zones"] = function(view)
    local exp, mode = view.exp, view.mode
    local zones = Engine.ZonesFor(exp, mode == "V", false)
    if mode == "V" then zones = Engine.ZonesFor(exp, true) end

    -- make sure zone data is being built in the background
    local pendingCount = 0
    for _, z in ipairs(zones) do
        if not Engine.ZoneReady(z) then pendingCount = pendingCount + 1 end
    end
    if pendingCount > 0 then
        Engine.Enqueue(function()
            for _, z in ipairs(zones) do
                Engine.ZoneData(z, true)
            end
        end, UI.RefreshIfShown, "zones" .. exp .. mode)
    end

    local sortMode = CurrentSort(view)
    for _, z in ipairs(zones) do
        if not Engine.ZoneReady(z) then
            AddNodeRow(z.name, nil, { text = z.name, right = "|cff888888Scanning...|r" })
        else
            local zc = Engine.ZoneData(z)
            local zloc = { zoneName = z.name }
            if mode == "Q" and not z.city then
                local st = Engine.Stats(zc.quest, "zq:" .. z.zone)
                if st.total > 0 then
                    AddNodeRow(z.name, st, {
                        text = z.name,
                        right = ANx.StatsString(st.attuned, st.total),
                        onClick = function() UI.Push({ type = "quests", zoneEntry = z }) end,
                    }, zloc)
                end
            elseif mode == "W" and not z.city then
                local rares = ANx.db.raresOnly
                local worldItems = rares and Engine.FilterRareItems(zc.world, z.name) or zc.world
                local st = Engine.StatsWithBest(worldItems, "zw:" .. z.zone .. (rares and ":R" or ":A"),
                    z.name, ANx.WORLD_DROP_SRC)
                if st.total > 0 then
                    AddNodeRow(z.name, st, {
                        text = z.name .. (rares and "  |cffff8000(rares)|r" or ""),
                        sub = BestLine(st.best),
                        right = ANx.StatsString(st.attuned, st.total),
                        onClick = function()
                            UI.Push({ type = "items", title = z.name .. " - World Drops",
                                items = zc.world, zoneName = z.name, srcFilter = ANx.WORLD_DROP_SRC,
                                worldDrop = true })
                        end,
                    }, zloc)
                end
            elseif mode == "V" then
                local filter = ANx.db.vendorFilter or "all"
                local ids = Engine.VendorItemsMatchingCategory(z, filter)
                ids = Engine.FilterByStock(ids, ANx.db.stockFilter, nil)
                if ANx.db.affordableOnly then ids = Engine.FilterAffordable(ids) end
                local st = Engine.Stats(ids, "zv:" .. z.zone .. ":" .. filter .. ":" .. (ANx.db.stockFilter or "all")
                    .. (ANx.db.affordableOnly and ":aff" or ""))
                if st.total > 0 then
                    AddNodeRow(z.name, st, {
                        text = z.name .. (z.city and " |cffffd100(city)|r" or ""),
                        right = ANx.StatsString(st.attuned, st.total),
                        onClick = function() UI.Push({ type = "currencies", zoneEntry = z }) end,
                    }, zloc)
                end
            end
        end
    end
    FlushNodeRows(sortMode)
    if #displayRows == 0 then
        AddRow({ text = "|cff888888Nothing found for this content type|r" })
    end
end

builders["quests"] = function(view)
    local z = view.zoneEntry
    local zc = Engine.ZoneData(z)
    local shown = 0
    for _, q in ipairs(zc.questList) do
      if ANx.NodeFactionAllowed("quest", q.id) then
        local st = Engine.Stats(q.items, "q:" .. z.zone .. ":" .. q.id)
        local left = st.total - st.attuned
        if st.total > 0 and (left > 0 or ANx.ShowAttunedItems()) then
            shown = shown + 1
            local hasArrow = ANx.QuestGivers and ANx.QuestGivers[q.id] ~= nil
            local lock = ANx.GetQuestLockInfo and ANx.GetQuestLockInfo(q.id)
            local prefix, hint = "", "click: waypoint arrow + rewards"
            if lock == "locked" then
                prefix = "|cffff8040[chain] |r"
                hint = "click: arrow to next quest in the chain + rewards"
            elseif lock == "inlog" then
                prefix = "|cffffff00[in log] |r"
            elseif lock == "completed" then
                prefix = "|cff00ff00[done] |r"
            end
            local qloc = { zoneName = z.name }
            local ge = ANx.QuestGivers and ANx.QuestGivers[q.id]
            if ge then qloc = { zoneName = ANx.QuestZoneNames and ANx.QuestZoneNames[ge[1]] or z.name,
                x = ge[2] / 10, y = ge[3] / 10 } end
            AddNodeRow(q.name, st, {
                text = prefix .. q.name .. (hasArrow and "  |cff33ff99>|r" or ""),
                sub = #q.items .. " attunable reward(s)"
                    .. (hasArrow and ("  |cff888888- " .. hint .. "|r") or ""),
                right = ANx.StatsString(st.attuned, st.total),
                onClick = function()
                    ANx.SetQuestWaypoint(q.id, q.name)
                    UI.Push({ type = "items", title = q.name, items = q.items,
                        zoneName = z.name, srcFilter = nil })
                end,
            }, qloc)
        end
      end
    end
    FlushNodeRows(CurrentSort(view))
    if shown == 0 then
        AddRow({ text = "|cff00ff00All quest items attuned in this zone!|r" })
    end
end

builders["currencies"] = function(view)
    local z = view.zoneEntry
    local groups = Engine.CurrenciesForZone(z)
    local filter = ANx.db.vendorFilter or "all"
    local hidden = 0
    for _, g in ipairs(groups) do
        local cat = Engine.CurrencyCategory(g.name)
        local visible = (filter == "all") or (cat == filter)
        if not visible then
            hidden = hidden + 1
        else
            local gitems = Engine.FilterByStock(g.items, ANx.db.stockFilter, nil)
            if ANx.db.affordableOnly then gitems = Engine.FilterAffordable(gitems) end
            local st = Engine.Stats(gitems, "cur:" .. z.zone .. ":" .. g.name .. ":" .. (ANx.db.stockFilter or "all")
                .. (ANx.db.affordableOnly and ":aff" or ""))
            if st.total > 0 then
                AddNodeRow(g.name, st, {
                    text = g.name,
                    sub = g.name == ANx.UNKNOWN_CURRENCY
                        and "Open these vendors once to record their prices" or nil,
                    right = ANx.StatsString(st.attuned, st.total),
                    onClick = function()
                        UI.Push({ type = "vendors", zoneEntry = z, currency = g.name, items = g.items })
                    end,
                }, { zoneName = z.name })
            end
        end
    end
    FlushNodeRows(CurrentSort(view))
    if #displayRows == 0 then
        if hidden > 0 then
            AddRow({ text = "|cff888888No currencies match the filter (" .. hidden .. " hidden) - use the Filter button below|r" })
        else
            AddRow({ text = "|cff888888No vendor items found in " .. z.name .. "|r" })
        end
    end
end

builders["vendors"] = function(view)
    local z = view.zoneEntry
    local vendors = Engine.VendorsForItems(z, view.items)
    for _, v in ipairs(vendors) do
      local vitems = Engine.FilterByStock(v.items, ANx.db.stockFilter, v.id)
      if ANx.db.affordableOnly then vitems = Engine.FilterAffordable(vitems) end
      if ANx.NodeFactionAllowed("vendor", v.id) and #vitems > 0 then
        local st = Engine.Stats(vitems, "ven:" .. z.zone .. ":" .. v.name .. ":" .. view.currency .. ":" .. (ANx.db.stockFilter or "all")
            .. (ANx.db.affordableOnly and ":aff" or ""))
        local hasLoc = ANx.HasVendorLoc and ANx.HasVendorLoc(v.id)
        local vloc = { zoneName = z.name }
        local vle = v.id and ANx.VendorLocs and ANx.VendorLocs[v.id]
        if vle then vloc = { zoneName = ANx.VendorZoneNames and ANx.VendorZoneNames[vle[1]] or z.name,
            x = vle[2] / 10, y = vle[3] / 10 } end
        AddNodeRow(v.name, st, {
            text = v.name .. (hasLoc and "  |cff33ff99>|r" or ""),
            sub = z.name .. (hasLoc and "  |cff888888- click: waypoint arrow + items|r" or ""),
            right = ANx.StatsString(st.attuned, st.total),
            onClick = function()
                if ANx.SetVendorWaypoint then ANx.SetVendorWaypoint(v.id, v.name) end
                UI.Push({ type = "items", title = v.name .. " (" .. z.name .. ")",
                    items = v.items, zoneName = z.name, srcFilter = nil, showCost = true,
                    vendorId = v.id })
            end,
        }, vloc)
      end
    end
    FlushNodeRows(CurrentSort(view))
    if #vendors == 0 then
        AddRow({ text = "|cff888888No specific vendor recorded - open the items list instead|r",
            onClick = function()
                UI.Push({ type = "items", title = view.currency .. " (" .. z.name .. ")",
                    items = view.items, zoneName = z.name, srcFilter = nil, showCost = true })
            end })
    end
end

builders["profs"] = function(view)
    local exp = view.exp
    for _, prof in ipairs(ANx.ProfessionOrder or {}) do
        local entries = Engine.ProfessionEntries(prof, exp)
        local ids = {}
        for _, e in ipairs(entries) do ids[#ids + 1] = e.id end
        local st = Engine.Stats(ids, "prof:" .. prof .. ":" .. exp)
        if st.total > 0 then
            AddNodeRow(prof, st, {
                text = prof,
                right = ANx.StatsString(st.attuned, st.total),
                onClick = function()
                    UI.Push({ type = "items", title = prof .. " (" .. ANx.EXP_SHORT[exp] .. ")",
                        items = ids, zoneName = nil, srcFilter = nil, craft = true,
                        skillMap = entries })
                end,
            })
        end
    end
    FlushNodeRows(CurrentSort(view))
    if #displayRows == 0 then
        AddRow({ text = "|cff888888No attunable crafted items for this expansion|r" })
    end
end

builders["events"] = function(view)
    for _, ev in ipairs(ANx.EventList or {}) do
        local items = Engine.EventItems(ev)
        local st = Engine.StatsWithBest(items, "ev:" .. ev.name, nil, nil)
        if st.total > 0 then
            AddNodeRow(ev.name, st, {
                text = ev.name,
                sub = BestLine(st.best),
                right = ANx.StatsString(st.attuned, st.total),
                onClick = function()
                    UI.Push({ type = "items", title = ev.name, items = items,
                        zoneName = nil, srcFilter = nil })
                end,
            })
        end
    end
    FlushNodeRows(CurrentSort(view))
    if #displayRows == 0 then
        AddRow({ text = "|cff888888No attunable event gear found (is the loot DB loaded?)|r" })
    end
end

builders["items"] = function(view)
    local itemList = view.items
    if view.worldDrop and ANx.db.raresOnly then
        itemList = Engine.FilterRareItems(itemList, view.zoneName)
    end
    -- zone-exclusive is applied globally inside Engine.Eligible / ItemRows.
    -- vendor stock + affordability filters on vendor item lists:
    if view.showCost then
        itemList = Engine.FilterByStock(itemList, ANx.db.stockFilter, view.vendorId)
        if ANx.db.affordableOnly then itemList = Engine.FilterAffordable(itemList) end
    end
    local rows = Engine.ItemRows(itemList, view.zoneName, view.srcFilter)
    local skillFor
    if view.skillMap then
        skillFor = {}
        for _, e in ipairs(view.skillMap) do skillFor[e.id] = e.skill end
    end
    -- page sort (default "chance" order comes pre-sorted from the engine)
    local sortMode = CurrentSort(view)
    if sortMode == "name" then
        table.sort(rows, function(a, b)
            return (ANx.GetItemDisplay(a.id) or ""):lower() < (ANx.GetItemDisplay(b.id) or ""):lower()
        end)
    elseif sortMode == "progress" then
        table.sort(rows, function(a, b)
            local pa = a.attuned and 101 or a.progress
            local pb = b.attuned and 101 or b.progress
            if pa ~= pb then return pa > pb end
            return a.chance > b.chance
        end)
    elseif sortMode == "distance" then
        for _, r in ipairs(rows) do
            r._sDist = ANx.DistanceRank(r.srcZone and { zoneName = r.srcZone } or nil)
        end
        table.sort(rows, function(a, b)
            if a._sDist ~= b._sDist then return a._sDist < b._sDist end
            return a.chance > b.chance
        end)
    end
    for _, r in ipairs(rows) do
        local name, link, quality, tex = ANx.GetItemDisplay(r.id)
        local rightText
        if r.tier and r.tier >= 2 then
            rightText = "|cffff8000" .. (ANx.FORGE_SHORT[r.tier] or "") .. "|r"   -- TF / WF / LF
        elseif r.attuned then
            rightText = "|cff00ff00Attuned|r"
        elseif view.craft then
            rightText = skillFor and skillFor[r.id] and ("|cffffd100Skill " .. skillFor[r.id] .. "|r") or ""
        else
            rightText = "|cff00ff88" .. ANx.FormatChance(r.chance) .. "|r"
        end
        local subParts = {}
        if r.srcName then
            subParts[#subParts + 1] = SrcTypeLabel(r.srcType) .. ": " .. r.srcName
        end
        if view.showCost then
            local cost = ANx.CostString(r.id)
            if cost then subParts[#subParts + 1] = "|cffffd100" .. cost .. "|r" end
            if ANx.StockString then
                local stockText, limited = ANx.StockString(r.id, view.vendorId)
                subParts[#subParts + 1] = (limited and "|cffff8000Stock: " or "|cff888888Stock: ")
                    .. stockText .. "|r"
            end
        end
        local right2 = ""
        if r.acct then right2 = "|cff00ccffaccount has variant|r"
        elseif not r.attuned and r.progress > 0 then right2 = string.format("|cffaaaaaa%d%% progress|r", r.progress) end

        AddRow({
            text = QualityHex(quality or 1) .. name .. "|r",
            sub = table.concat(subParts, "  "),
            right = rightText,
            right2 = right2,
            icon = tex,
            itemId = r.id,
            onClick = function(selfBtn)
                if IsShiftKeyDown() then
                    local _, l = ANx.GetItemDisplay(r.id)
                    if l then ChatEdit_InsertLink(l) end
                else
                    UI.Push({ type = "sources", itemId = r.id })
                end
            end,
        })
    end
    if #rows == 0 then
        if (ANx.db.bindFilter or "both") ~= "both" then
            AddRow({ text = "|cff888888No " .. (ANx.db.bindFilter == "bop" and "Bind-on-Pickup" or "Bind-on-Equip")
                .. " items here (change the Bind filter, or the item may not be cached yet)|r" })
        elseif view.showCost and ANx.db.affordableOnly then
            AddRow({ text = "|cff888888Nothing here you can afford right now (toggle 'Affordable' off to see all)|r" })
        elseif view.showCost and (ANx.db.stockFilter or "all") ~= "all" then
            AddRow({ text = "|cff888888No " .. ANx.db.stockFilter .. "-stock items here (change the Stock filter)|r" })
        elseif ANx.db.zoneExclusive then
            AddRow({ text = "|cff888888Nothing zone-exclusive left here (toggle 'Zone-exclusive only' off to see all)|r" })
        elseif view.worldDrop and ANx.db.raresOnly then
            AddRow({ text = "|cff888888No rare-spawn world drops left here (toggle 'Rare spawns only' off to see all)|r" })
        elseif (ANx.db.forge or 0) == 0 then
            AddRow({ text = "|cff00ff00Nothing left here - everything is attuned!|r" })
        else
            AddRow({ text = "|cff00ff00Everything here is past the '" .. (ANx.FORGE_LABELS[ANx.db.forge] or "") .. "' target!|r" })
        end
    end
end

builders["sources"] = function(view)
    local itemId = view.itemId
    local name, link, quality, tex = ANx.GetItemDisplay(itemId)
    local progress = ANx.Progress(itemId)
    local headParts = {}
    if progress >= 100 then headParts[#headParts + 1] = "|cff00ff00Attuned|r"
    elseif progress > 0 then headParts[#headParts + 1] = progress .. "% progress"
    else headParts[#headParts + 1] = "|cffff8040Not attuned|r" end
    if ANx.AccountHasVariant(itemId) and progress < 100 then
        headParts[#headParts + 1] = "|cff00ccffaccount has a variant|r"
    end
    local cost = ANx.CostString(itemId)
    if cost then headParts[#headParts + 1] = cost end

    AddRow({
        text = QualityHex(quality or 1) .. name .. "|r",
        sub = table.concat(headParts, "  -  "),
        icon = tex,
        itemId = itemId,
        onClick = function()
            if IsShiftKeyDown() then
                local _, l = ANx.GetItemDisplay(itemId)
                if l then ChatEdit_InsertLink(l) end
            end
        end,
    })

    local sources = Engine.Sources(itemId)
    local sorted = {}
    for _, s in ipairs(sources) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b) return a.chance > b.chance end)
    for _, s in ipairs(sorted) do
        local subText = SrcTypeLabel(s.srcType) .. (s.zoneName ~= "" and ("  -  " .. s.zoneName) or "")
        local rightText = "|cff00ff88" .. ANx.FormatChance(s.chance) .. "|r"
        if s.srcType == ANx.SRC.VENDOR then
            -- vendors: show price + stock instead of a drop chance
            local cost2 = ANx.CostString(itemId)
            local stockText, limited = ANx.StockString and ANx.StockString(itemId, s.objId)
            if stockText then
                subText = subText .. (limited and "  -  |cffff8000Stock: " or "  -  |cff888888Stock: ")
                    .. stockText .. "|r"
            end
            rightText = cost2 and ("|cffffd100" .. cost2 .. "|r") or "|cff888888vendor|r"
        end
        AddRow({
            text = s.objName,
            sub = subText,
            right = rightText,
        })
    end
    if #sorted == 0 then
        AddRow({ text = "|cff888888No source data (loot DB not loaded?)|r" })
    end
end

builders["search"] = function(view)
    local q = (UI.searchQuery or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #q < 2 then
        AddRow({ text = "|cff888888Type at least 2 letters to search for an item...|r" })
        return
    end

    local universe, ready = Engine.Universe()
    if not ready then
        for exp = 1, 3 do Engine.GetSummary(exp, UI.RefreshIfShown) end
    end

    local matches = {}
    for _, id in ipairs(universe) do
        local name = ANx.GetItemDisplay(id)
        if name and name:lower():find(q, 1, true) then
            matches[#matches + 1] = { id = id, name = name }
        end
    end

    local mode = CurrentSort(view)
    if mode == "distance" then
        for _, m in ipairs(matches) do
            local _, _, _, _, zone = Engine.BestSource(m.id)
            m._d = ANx.DistanceRank(zone and zone ~= "" and { zoneName = zone } or nil)
        end
        table.sort(matches, function(a, b)
            if a._d ~= b._d then return a._d < b._d end
            return a.name:lower() < b.name:lower()
        end)
    else
        table.sort(matches, function(a, b) return a.name:lower() < b.name:lower() end)
    end

    local CAP = 60
    local shown = 0
    for _, m in ipairs(matches) do
        if shown >= CAP then break end
        shown = shown + 1
        local name, _, quality, tex = ANx.GetItemDisplay(m.id)
        local chance, srcName, srcType, _, zone = Engine.BestSource(m.id)
        local attuned = ANx.CountAttuned(m.id)
        local canC = ANx.CanCount(m.id)
        local rightText
        if attuned then rightText = "|cff00ff00Attuned|r"
        elseif chance and chance > 0 then rightText = "|cff00ff88" .. ANx.FormatChance(chance) .. "|r"
        else rightText = "" end
        local subParts = {}
        if srcName then
            subParts[#subParts + 1] = SrcTypeLabel(srcType) .. ": " .. srcName
                .. (zone and zone ~= "" and (" (" .. zone .. ")") or "")
        end
        if not canC then subParts[#subParts + 1] = "|cffff6060other faction/class|r" end
        AddRow({
            text = QualityHex(quality or 1) .. name .. "|r",
            sub = table.concat(subParts, "  "),
            right = rightText,
            icon = tex,
            itemId = m.id,
            onClick = function() UI.Push({ type = "sources", itemId = m.id }) end,
        })
    end

    if shown == 0 then
        if not ready then
            AddRow({ text = "|cff888888Indexing items in the background - try again in a moment...|r" })
        else
            AddRow({ text = "|cff888888No attunable items match \"" .. q .. "\"|r" })
        end
    elseif #matches > CAP then
        AddRow({ text = "|cff888888...and " .. (#matches - CAP) .. " more - type more letters to narrow it down|r" })
    end
end

-- ---------------------------------------------------------------------
-- Breadcrumb titles
-- ---------------------------------------------------------------------
local CONTENT_LABELS = { D = "Dungeons", R = "Raids", Q = "Quests", W = "World Drops", V = "Vendors", C = "Crafting" }

local function ViewTitle(view)
    local t = view.type
    if t == "root" then return "How do you want to browse?"
    elseif t == "contentTypes" then return "Filter by Content Type  -  Which Content?"
    elseif t == "contentExp" then return (CONTENT_LABELS[view.content] or "Content") .. "  -  Which Expansion?"
    elseif t == "home" then return "Select Expansion"
    elseif t == "content" then return ANx.EXP_NAMES[view.exp] .. "  -  Select Content"
    elseif t == "instances" then
        return ANx.EXP_SHORT[view.exp] .. "  -  " .. (view.kind == "D" and "Which Dungeon?" or "Which Raid?")
    elseif t == "zones" then
        local m = view.mode
        return ANx.EXP_SHORT[view.exp] .. "  -  " ..
            (m == "Q" and "Quests: Which Zone?" or m == "W" and "World Drops: Which Zone?" or "Vendors: Which Zone?")
    elseif t == "quests" then return view.zoneEntry.name .. "  -  Quests with attunables"
    elseif t == "currencies" then return view.zoneEntry.name .. "  -  Which Currency?"
    elseif t == "vendors" then return view.zoneEntry.name .. "  -  " .. view.currency .. "  -  Vendors"
    elseif t == "events" then return "Events & Holidays  -  Which Event?"
    elseif t == "profs" then return ANx.EXP_SHORT[view.exp] .. "  -  Which Profession?"
    elseif t == "items" then return view.title or "Items"
    elseif t == "sources" then return "Item Sources"
    elseif t == "search" then return "Search results for \"" .. (UI.searchQuery or "") .. "\""
    end
    return ""
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------
function UI.Render()
    local f = UI.frame
    if not f or not f:IsShown() then return end
    local view = UI.Current()
    if not view then return end

    ResetRows()
    local builder = builders[view.type]
    if builder then builder(view) end

    f.crumb:SetText("|cffffd100" .. ViewTitle(view) .. "|r")
    f.back[#UI.stack > 1 and "Enable" or "Disable"](f.back)

    -- scope + faction buttons: always available
    f.scopeBtn:SetText(ANx.db.scope == "account" and "Attunes: |cff00ccffAccount|r" or "Attunes: Character")
    local fac = ANx.db.faction or "both"
    if fac == "A" then
        f.factionBtn:SetText("Faction: |cff6699ffAlliance|r")
    elseif fac == "H" then
        f.factionBtn:SetText("Faction: |cffcc4444Horde|r")
    else
        f.factionBtn:SetText("Faction: Both")
    end

    -- forge-tier visibility: always available
    local forgeTier = ANx.db.forge or 0
    local forgeCol = (forgeTier >= 2) and "|cffff8000" or (forgeTier == 1) and "|cff00ff00" or ""
    f.forgeBtn:SetText("Show: " .. forgeCol .. (ANx.FORGE_LABELS[forgeTier] or "?") .. (forgeCol ~= "" and "|r" or ""))

    -- sort button: only on sortable pages
    if ViewSortModes(view) then
        f.sortBtn:SetText("Sort: " .. (SORT_LABELS[CurrentSort(view)] or "?"))
        f.sortBtn:Show()
    else
        f.sortBtn:Hide()
    end

    -- zone-exclusive + bind + accessories: global (affect counts on every level)
    f.zexBtn:SetText(ANx.db.zoneExclusive and "Zone-exclusive: |cffffd100On|r" or "Zone-exclusive: Off")
    local bf = ANx.db.bindFilter or "both"
    local bl = (bf == "bop") and "|cffff6060BoP only|r" or (bf == "boe") and "|cff40a0ffBoE only|r" or "Both"
    f.bindBtn:SetText("Bind: " .. bl)
    f.accBtn:SetText(ANx.db.accessories ~= false and "Accessories: On" or "Accessories: |cffffd100Off|r")

    -- row C pos1: currency (vendor node) / rares (world drop) / difficulty (D/R)
    local hasDiff = ViewHasDifficulty(view)
    if ViewHasVendorFilter(view) then
        f.filterBtn:SetText("Currency: " .. (VENDOR_FILTER_LABELS[ANx.db.vendorFilter or "all"] or "All"))
        f.filterBtn:Show()
    else
        f.filterBtn:Hide()
    end
    if ViewIsWorldDrop(view) then
        f.raresBtn:SetText(ANx.db.raresOnly and "Rares only: |cffff8000On|r" or "Rares only: Off")
        f.raresBtn:Show()
    else
        f.raresBtn:Hide()
    end
    if hasDiff then
        local d = ANx.db.difficulty or "all"
        local dcol = (d ~= "all") and "|cffffd100" or ""
        f.diffBtn:SetText("Difficulty: " .. dcol .. (ANx.DIFF_TIER_LABELS[d] or "All") .. (dcol ~= "" and "|r" or ""))
        f.diffBtn:Show()
    else
        f.diffBtn:Hide()
    end
    -- row C pos2: stock (vendor) / raid size (raid)
    if ViewHasStockFilter(view) then
        local sf = ANx.db.stockFilter or "all"
        local sfLabel = (sf == "limited") and "|cffff8000Limited|r" or (sf == "unlimited") and "Unlimited" or "All"
        f.stockBtn:SetText("Stock: " .. sfLabel)
        f.stockBtn:Show()
        f.affordBtn:SetText(ANx.db.affordableOnly and "Affordable: |cff00ff00On|r" or "Affordable: Off")
        f.affordBtn:Show()
    else
        f.stockBtn:Hide()
        f.affordBtn:Hide()
    end
    if ViewHasRaidSize(view) then
        local sz = ANx.db.raidSize or "all"
        local zcol = (sz ~= "all") and "|cffffd100" or ""
        f.sizeBtn:SetText("Size: " .. zcol .. (ANx.RAID_SIZE_LABELS[sz] or "All") .. (zcol ~= "" and "|r" or ""))
        f.sizeBtn:Show()
    else
        f.sizeBtn:Hide()
    end

    if not ANx.LootDbLoaded() then
        f.status:SetText("|cffff4040Loot DB not loaded - lists will be empty (see /an help)|r")
    elseif Engine.scanning then
        f.status:SetText("|cffffd100Scanning loot database...|r")
    else
        f.status:SetText("|cff888888'Show' sets the forge target - Left counts items at that tier or below. Zone-exclusive affects every level.|r")
    end

    local total = #displayRows
    FauxScrollFrame_Update(f.scroll, total, VISIBLE_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.scroll)

    for i = 1, VISIBLE_ROWS do
        local b = rowButtons[i]
        local r = displayRows[i + offset]
        if r then
            b.text:SetText(r.text or "")
            b.sub:SetText(r.sub or "")
            b.right:SetText(r.right or "")
            b.right2:SetText(r.right2 or "")
            if r.icon then
                b.icon:SetTexture(r.icon)
                b.icon:Show()
                b.text:SetPoint("TOPLEFT", 36, -3)
                b.sub:SetPoint("BOTTOMLEFT", 36, 3)
            else
                b.icon:Hide()
                b.text:SetPoint("TOPLEFT", 6, -3)
                b.sub:SetPoint("BOTTOMLEFT", 6, 3)
            end
            if (r.sub or "") == "" then
                b.text:SetPoint("TOPLEFT", r.icon and 36 or 6, -9)
            end
            b.onClick = r.onClick
            b.tooltipItem = r.itemId
            b.tooltipText = r.tooltipText
            if r.onClick then b:Enable() else b:Disable() end
            b:Show()
        else
            b:Hide()
        end
    end
end

-- ---------------------------------------------------------------------
-- Show / toggle
-- ---------------------------------------------------------------------
function UI.Show(reset)
    Engine = ANx.Engine
    if not UI.frame then
        UI.frame = CreateMainFrame()
    end
    if reset or #UI.stack == 0 then
        UI.stack = { { type = "root" } }
        UI.searchQuery = ""
        if UI.frame.searchBox then
            UI._searchSetting = true
            UI.frame.searchBox:SetText("")
            UI._searchSetting = false
        end
    end
    UI.frame:Show()
    UI.Render()
end

function UI.Toggle()
    if UI.frame and UI.frame:IsShown() then
        UI.frame:Hide()
    else
        UI.Show(false)
    end
end

-- Random: pick a random eligible, unattuned item from the current context and
-- open its source detail. (WoW's Lua has no math.randomseed; math.random is
-- already seeded by the client, so we just call it directly.)
function UI.RandomPick()
    -- make sure the summaries are being built so wide contexts have data
    for exp = 1, 3 do Engine.GetSummary(exp, UI.RefreshIfShown) end
    local id = Engine.RandomUnattuned(UI.Current())
    if id then
        local name = ANx.GetItemDisplay(id)
        ANx.Print("Random pick: |cffffff00" .. name .. "|r")
        UI.Push({ type = "sources", itemId = id, fromRandom = true })
    elseif Engine.scanning then
        ANx.Print("Still building the item database - try Random again in a moment.")
    else
        ANx.Print("Nothing unattuned to pick here with the current filters.")
    end
end
