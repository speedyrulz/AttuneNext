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

-- Engine is cached as an upvalue for speed. Bind it lazily: the standalone
-- windows can run the builders before the main frame is ever created.
local function EnsureEngine()
    if not Engine then Engine = ANx.Engine end
    return Engine
end
UI.EnsureEngine = EnsureEngine
function UI._TestClearEngine() Engine = nil end   -- regression coverage only

local ROW_H = 50          -- title line + one description line, inside a card
local VISIBLE_ROWS = 12
local FRAME_W = 700
local SIDEBAR_W = 175   -- left navigation column
local SIDE_W = 246      -- right detail column (browse screens)

-- Which views get the two-pane browse layout (list + detail column)
local SIDE_PANE_VIEWS = {
    browse = true, home = true, contentTypes = true, content = true,
    contentExp = true, instances = true, zones = true, quests = true,
    currencies = true, vendors = true, profs = true, events = true,
    items = true, search = true,
}

-- painted-art helpers (art pack by Jeff; safe no-ops when the pack is absent)
local function ArtSlug(n)
    n = tostring(n or ""):lower():gsub("'", ""):gsub(":", ""):gsub("%-", " ")
    return (n:gsub("%s+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end
local CONTENT_ART = { D = "dungeons", R = "raids", Q = "quests",
                      W = "world_drops", V = "vendors", C = "crafting" }
local EXP_ART = { [1] = "classic", [2] = "the_burning_crusade", [3] = "wrath_of_the_lich_king" }
local CX = SIDEBAR_W    -- content x-offset

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
    distance = "Distance", acct = "Account", char = "Character",
}
local SORT_SHORT = { left = "Left" }   -- chip labels that must stay narrow
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
    UI.selectedItem = nil    -- a new screen starts with nothing selected
    table.insert(UI.stack, view)
    UI.Render()
end

function UI.Pop()
    if #UI.stack > 1 then
        UI.selectedItem = nil
        table.remove(UI.stack)
        UI.Render()
    end
end

function UI.Current()
    return UI.stack[#UI.stack]
end

-- Clicking an item row selects it: its details appear in the browse pane.
function UI.SelectItem(id)
    EnsureEngine()
    UI.selectedItem = id
    UI.Render()
end

function UI.RefreshIfShown()
    if UI.frame and UI.frame:IsShown() then
        UI.Render()
    end
end

-- Debounced re-render when bag/bank contents change, for the screens that
-- read your inventory (the What's Left materials list nets out your stock).
local BAG_SENSITIVE = { whatsleftMatList = true }
local matsRefreshQueued = false
function UI.RefreshMats()
    if matsRefreshQueued then return end
    if not (UI.frame and UI.frame:IsShown()) then return end
    local cur = UI.Current()
    if not (cur and BAG_SENSITIVE[cur.type]) then return end
    matsRefreshQueued = true
    ANx.After(0.5, function()
        matsRefreshQueued = false
        if UI.frame and UI.frame:IsShown() then
            local c = UI.Current()
            if c and BAG_SENSITIVE[c.type] then UI.Render() end
        end
    end)
end

-- ---------------------------------------------------------------------
-- Frame construction
-- ---------------------------------------------------------------------
local rowButtons = {}

local function CreateMainFrame()
    Engine = ANx.Engine
    local f = CreateFrame("Frame", "AttuneNextFrame", UIParent)
    f:SetWidth(FRAME_W + SIDEBAR_W)
    f:SetHeight(ROW_H * VISIBLE_ROWS + 194)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("HIGH")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScale(ANx.db and ANx.db.scale or 1)

    -- dark, flat panel (v3 restyle)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    if f.SetBackdropColor then f:SetBackdropColor(0.045, 0.045, 0.06, 0.96) end
    if f.SetBackdropBorderColor then f:SetBackdropBorderColor(0.45, 0.38, 0.25, 1) end

    -- painted chrome (corners + border strips from the art pack)
    if ANx.Art and ANx.Art.outer_corner_nw then
        if f.SetBackdropBorderColor then f:SetBackdropBorderColor(0, 0, 0, 0) end
        local CS, ES = 34, 18   -- corner size, edge thickness
        f.anxChrome = {}
        local function ChromePiece(key)
            local t = f:CreateTexture(nil, "OVERLAY")
            ANx.SetArt(t, key)
            f.anxChrome[#f.anxChrome + 1] = t
            return t
        end
        local nw = ChromePiece("outer_corner_nw")
        nw:SetWidth(CS); nw:SetHeight(CS); nw:SetPoint("TOPLEFT", 0, 0)
        local ne = ChromePiece("outer_corner_ne")
        ne:SetWidth(CS); ne:SetHeight(CS); ne:SetPoint("TOPRIGHT", 0, 0)
        local sw = ChromePiece("outer_corner_sw")
        sw:SetWidth(CS); sw:SetHeight(CS); sw:SetPoint("BOTTOMLEFT", 0, 0)
        local se = ChromePiece("outer_corner_se")
        se:SetWidth(CS); se:SetHeight(CS); se:SetPoint("BOTTOMRIGHT", 0, 0)
        local top = ChromePiece("border_top")
        top:SetHeight(ES); top:SetPoint("TOPLEFT", CS, 0); top:SetPoint("TOPRIGHT", -CS, 0)
        local bot = ChromePiece("border_bottom")
        bot:SetHeight(ES); bot:SetPoint("BOTTOMLEFT", CS, 0); bot:SetPoint("BOTTOMRIGHT", -CS, 0)
        local lef = ChromePiece("border_left")
        lef:SetWidth(ES); lef:SetPoint("TOPLEFT", 0, -CS); lef:SetPoint("BOTTOMLEFT", 0, CS)
        local rig = ChromePiece("border_right")
        rig:SetWidth(ES); rig:SetPoint("TOPRIGHT", 0, -CS); rig:SetPoint("BOTTOMRIGHT", 0, CS)
    end

    -- sidebar column
    local side = f:CreateTexture(nil, "BORDER")
    side:SetPoint("TOPLEFT", 4, -4)
    side:SetPoint("BOTTOMLEFT", 4, 4)
    side:SetWidth(SIDEBAR_W - 8)
    side:SetTexture(0.02, 0.02, 0.035, 0.95)
    local sideLine = f:CreateTexture(nil, "BORDER")
    sideLine:SetPoint("TOPLEFT", SIDEBAR_W - 7, -8)
    sideLine:SetPoint("BOTTOMLEFT", SIDEBAR_W - 7, 8)
    f.anxDivider = sideLine
    if ANx.Art and ANx.Art.divider_vertical then
        sideLine:SetWidth(6)
        ANx.SetArt(sideLine, "divider_vertical")
    else
        sideLine:SetWidth(1)
        sideLine:SetTexture(0.45, 0.38, 0.25, 0.7)
    end

    -- branding: painted emblem + wordmark in the sidebar when available
    local navTop = -52
    if ANx.Art and ANx.Art.emblem then
        -- just the emblem up top (no wordmark), like the mockups
        local emblem = f:CreateTexture(nil, "ARTWORK")
        emblem:SetWidth(84); emblem:SetHeight(84)
        emblem:SetPoint("TOPLEFT", (SIDEBAR_W - 84) / 2, -14)
        ANx.SetArt(emblem, "emblem")   -- logo art stays in Classic too
        f.sideEmblem = emblem
        navTop = -116
    else
        local sideLogo = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        sideLogo:SetPoint("TOPLEFT", 16, -16)
        sideLogo:SetText("|cff33ff99Attune|r|cffffffffNext|r")
        f.sideLogo = sideLogo
    end
    f.navTop = navTop
    local sideVer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sideVer:SetPoint("BOTTOMLEFT", 16, 12)
    sideVer:SetText("v" .. (ANx.VERSION or "?"))

    -- ============== painted-skin helpers ==============
    -- tight UV crops for atlas cells that carry transparent padding
    local ART_TRIM = {
        logo                 = { 0.0283, 0.0625, 0.9707, 0.9375 },  -- 965x224 wordmark
        search_field         = { 0.0146, 0.5771, 0.2373, 0.6738 },  -- 228x99
        -- NOTE: this atlas cell holds TWO elements (a small teal accent tab
        -- + the chip plate). The crop must cover the chip ONLY - including
        -- the accent was what drew a detached box inside every chip.
        filter_chip_normal   = { 0.5771, 0.3447, 0.7344, 0.4053 },  -- 161x62 chip only
        filter_chip_selected = { 0.7656, 0.3408, 0.9844, 0.4092 },  -- 224x70
        icon_bezel_normal    = { 0.5166, 0.5176, 0.7324, 0.7334 },  -- 221x221
        button_hover         = { 0.2646, 0.0869, 0.4863, 0.1631 },  -- 227x78 pill
        button_normal        = { 0.0156, 0.0820, 0.2354, 0.1680 },
        button_pressed       = { 0.5146, 0.0850, 0.7344, 0.1660 },
        button_disabled      = { 0.7656, 0.0820, 0.9844, 0.1680 },
        progress_track       = { 0.0156, 0.8574, 0.2354, 0.8906 },
        progress_fill_teal   = { 0.5146, 0.8584, 0.7344, 0.8906 },
        progress_fill_gold   = { 0.2646, 0.8584, 0.4854, 0.8906 },
        progress_fill_blue   = { 0.7646, 0.8584, 0.9854, 0.8906 },
        content_card         = { 0.7656, 0.5518, 0.9854, 0.6973 },  -- 225x149
        -- per-icon tight crops (the raw cells carry uneven margins, which
        -- made sidebar/chip icons look out of line with each other)
        home                 = { 0.0161, 0.0141, 0.1157, 0.1137 },
        browse               = { 0.1366, 0.0125, 0.2362, 0.1121 },
        whats_left           = { 0.2632, 0.0157, 0.3608, 0.1133 },
        favorites            = { 0.3866, 0.0125, 0.4862, 0.1121 },
        goals                = { 0.5082, 0.0151, 0.6058, 0.1127 },
        character            = { 0.6375, 0.0128, 0.7371, 0.1124 },
        account              = { 0.7622, 0.0128, 0.8618, 0.1124 },
        faction_alliance     = { 0.0117, 0.1374, 0.1113, 0.2371 },
        faction_horde        = { 0.8871, 0.0126, 0.9867, 0.1123 },
        faction_neutral      = { 0.1368, 0.1376, 0.2364, 0.2372 },
        attunement           = { 0.3809, 0.2576, 0.4825, 0.3592 },
        bind                 = { 0.3891, 0.3896, 0.4847, 0.4852 },
        accessories          = { 0.5117, 0.3877, 0.6113, 0.4874 },
        zone_exclusive       = { 0.6360, 0.3906, 0.7296, 0.4842 },
        sort                 = { 0.2654, 0.3906, 0.3590, 0.4843 },
        difficulty           = { 0.7622, 0.3878, 0.8618, 0.4874 },
        raid_size            = { 0.8875, 0.3878, 0.9871, 0.4874 },
        currency             = { 0.2622, 0.2625, 0.3618, 0.3621 },
        stock                = { 0.5142, 0.5113, 0.6098, 0.6070 },
        affordable           = { 0.3890, 0.5103, 0.4866, 0.6080 },
        rare_spawn           = { 0.0122, 0.5128, 0.1118, 0.6124 },
        settings             = { 0.6400, 0.2655, 0.7336, 0.3591 },
        rescan               = { 0.7652, 0.2655, 0.8588, 0.3591 },
        close                = { 0.0110, 0.3904, 0.1046, 0.4840 },
        search               = { 0.5152, 0.2644, 0.6108, 0.3600 },
        filter               = { 0.1401, 0.3896, 0.2358, 0.4852 },
        vendors              = { 0.7624, 0.1378, 0.8620, 0.2374 },
        dungeons             = { 0.2621, 0.1377, 0.3617, 0.2373 },
        raids                = { 0.3872, 0.1376, 0.4868, 0.2373 },
        crafting             = { 0.8904, 0.1322, 0.9920, 0.2338 },
        quests               = { 0.5116, 0.1376, 0.6112, 0.2372 },
        events               = { 0.0117, 0.2626, 0.1113, 0.3622 },
        materials            = { 0.1383, 0.2591, 0.2359, 0.3567 },
        alchemy              = { 0.0161, 0.6405, 0.1097, 0.7341 },
        back                 = { 0.8867, 0.2625, 0.9863, 0.3621 },
        blacksmithing        = { 0.1371, 0.6377, 0.2367, 0.7373 },
        brewfest             = { 0.5143, 0.7640, 0.6099, 0.8596 },
        classic              = { 0.0154, 0.7650, 0.1090, 0.8587 },
        enchanting           = { 0.2651, 0.6405, 0.3587, 0.7341 },
        engineering          = { 0.3894, 0.6404, 0.4831, 0.7341 },
        favorite_add         = { 0.7624, 0.5127, 0.8620, 0.6123 },
        favorite_remove      = { 0.8874, 0.5125, 0.9870, 0.6121 },
        hallows_end          = { 0.3903, 0.7650, 0.4840, 0.8586 },
        ignore               = { 0.6390, 0.5114, 0.7346, 0.6070 },
        inscription          = { 0.5162, 0.6406, 0.6098, 0.7343 },
        jewelcrafting        = { 0.6368, 0.6376, 0.7364, 0.7372 },
        leatherworking       = { 0.7636, 0.6435, 0.8513, 0.7312 },
        love_is_in_the_air   = { 0.7643, 0.7642, 0.8599, 0.8599 },
        lunar_festival       = { 0.8900, 0.7651, 0.9837, 0.8587 },
        midsummer_fire_festival = { 0.6400, 0.7650, 0.7336, 0.8587 },
        noblegarden          = { 0.0150, 0.8900, 0.1086, 0.9836 },
        tailoring            = { 0.8894, 0.6407, 0.9831, 0.7343 },
        the_burning_crusade  = { 0.1401, 0.7652, 0.2337, 0.8588 },
        track_goal           = { 0.2616, 0.5128, 0.3613, 0.6124 },
        waypoint             = { 0.1368, 0.5124, 0.2365, 0.6121 },
        world_drops          = { 0.6369, 0.1375, 0.7365, 0.2371 },
        wrath_of_the_lich_king = { 0.2650, 0.7651, 0.3587, 0.8587 },
    }
    -- Classic layout: skip the painted pack (logo/emblem excepted).
    local SKINNABLE = {}          -- textures that swap with the layout
    local function RegisterSkin(tex, kind, key, w, h)
        if not tex then return tex end
        SKINNABLE[#SKINNABLE + 1] = { tex = tex, kind = kind, key = key }
        return tex
    end
    local function ArtOn() return ANx.ArtOn and ANx.ArtOn() end
    UI.ArtOn = ArtOn

    local function ArtTexCoord(tex, key)
        if not (tex and tex.SetTexCoord) then return end
        local tr = ART_TRIM[key]
        local a = ANx.Art and ANx.Art[key]
        if tr then tex:SetTexCoord(tr[1], tr[3], tr[2], tr[4])
        elseif a then tex:SetTexCoord(a[2], a[4], a[3], a[5]) end
    end
    local function SetArtTrim(tex, key, force)
        if not (ANx.Art and ANx.Art[key] and tex and tex.SetTexture) then return false end
        if not force and not ArtOn() then return false end
        tex:SetTexture(ANx.ART_PATH .. ANx.Art[key][1])
        ArtTexCoord(tex, key)
        return true
    end
    -- icon variant: center-square crop of the tight art, so every icon
    -- renders as a full, even medallion (the wide cells only add tiny side
    -- spikes, which this trims off)
    local function SetIconArt(tex, key, box)
        if not (ANx.Art and ANx.Art[key] and tex and tex.SetTexture) then return false end
        if not ArtOn() then return false end
        tex:SetTexture(ANx.ART_PATH .. ANx.Art[key][1])
        local tr = ART_TRIM[key]
        if tr and tex.SetTexCoord then
            local cu, cv = (tr[1] + tr[3]) / 2, (tr[2] + tr[4]) / 2
            local half = math.min(tr[3] - tr[1], tr[4] - tr[2]) / 2
            tex:SetTexCoord(cu - half, cu + half, cv - half, cv + half)
        else
            ArtTexCoord(tex, key)
        end
        if box then tex:SetWidth(box); tex:SetHeight(box) end
        return true
    end
    UI.SetIconArt = SetIconArt
    UI.SetArtTrimmed = SetArtTrim
    local function StripEngineSkin(b)
        -- the custom client decorates buttons with its own skin (an ornate
        -- normal texture appears on buttons that never set one). Clear and
        -- hide every engine-owned state texture; our own child textures are
        -- untouched by this.
        if b.SetNormalTexture then b:SetNormalTexture("") end
        if b.SetPushedTexture then b:SetPushedTexture("") end
        if b.SetDisabledTexture then b:SetDisabledTexture("") end
        if b.SetHighlightTexture then b:SetHighlightTexture("") end
        local function Kill(tex)
            if not tex then return end
            if tex.SetTexture then tex:SetTexture(nil) end
            if tex.Hide then tex:Hide() end
        end
        if b.GetNormalTexture then Kill(b:GetNormalTexture()) end
        if b.GetPushedTexture then Kill(b:GetPushedTexture()) end
        if b.GetDisabledTexture then Kill(b:GetDisabledTexture()) end
        if b.GetHighlightTexture then Kill(b:GetHighlightTexture()) end
        -- scorched earth: the client also ADDS its own child regions to
        -- buttons (the bracket box drawn from label-end to button-edge).
        -- Everything we create is tagged anxMine - hide everything else.
        if b.GetRegions then
            local regs = { b:GetRegions() }
            for i = 1, #regs do
                local r = regs[i]
                if r and not r.anxMine then
                    if r.SetTexture then r:SetTexture(nil) end
                    if r.SetText then r:SetText("") end
                    if r.Hide then r:Hide() end
                end
            end
        end
        -- ...and the skinner's decor lives in child FRAMES (invisible to
        -- GetRegions). None of our custom buttons own child frames, so any
        -- child frame here is the client's - keep it hidden.
        if b.GetChildren then
            local kids = { b:GetChildren() }
            for i = 1, #kids do
                local k = kids[i]
                if k and not k.anxMine then
                    if k.Hide then k:Hide() end
                    if k.SetAlpha then k:SetAlpha(0) end
                end
            end
        end
    end
    UI.StripEngineSkin = StripEngineSkin

    local function SkinFlat(b, style)
        StripEngineSkin(b)
        b:SetScript("OnShow", StripEngineSkin)   -- re-strip if reapplied
        if not b.CreateTexture then return end
        -- painted plate: a child texture pinned to the button's rect, so it
        -- always fills the button exactly (state textures don't track
        -- resizes on 3.3.5 and draw OVER child art - never use them here)
        local key = (style == "chip") and "filter_chip_normal" or "button_normal"
        if not b.anxPlate then
            local t = b:CreateTexture(nil, "BORDER")   -- same layer as row bars
            t.anxMine = true
            t:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
            b.anxPlate = t
        end
        -- explicit size: two-point texture stretching silently fails on this
        -- client (/an frames showed plates at native 1024px), so plates are
        -- sized like the row progress bars - one anchor + SetWidth/SetHeight
        b.anxPlate:SetWidth(b:GetWidth()); b.anxPlate:SetHeight(b:GetHeight())
        b.anxPlate.anxKey = key
        if ANx.Art and ANx.Art[key] and ArtOn() then
            b.anxPlate:SetTexture(ANx.ART_PATH .. ANx.Art[key][1])
            ArtTexCoord(b.anxPlate, key)
        elseif not ArtOn() then
            -- classic: the familiar Blizzard panel button
            b.anxPlate:SetTexture("Interface\\Buttons\\UI-Panel-Button-Up")
            if b.anxPlate.SetTexCoord then b.anxPlate:SetTexCoord(0, 0.625, 0, 0.6875) end
        else
            b.anxPlate:SetTexture(0.10, 0.10, 0.13, 0.9)
        end
        -- hover glow in the HIGHLIGHT layer: auto-shows on mouse-over and
        -- follows the button wherever it goes
        if not b.anxHover then
            local h = b:CreateTexture(nil, "HIGHLIGHT")
            h.anxMine = true
            h:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
            if h.SetBlendMode then h:SetBlendMode("ADD") end   -- glow, not cover
            b.anxHover = h
        end
        b.anxHover:SetWidth(b:GetWidth()); b.anxHover:SetHeight(b:GetHeight())
        if ANx.Art and ANx.Art.button_hover and ArtOn() then
            b.anxHover:SetTexture(ANx.ART_PATH .. ANx.Art.button_hover[1])
            ArtTexCoord(b.anxHover, "button_hover")
        elseif not ArtOn() then
            b.anxHover:SetTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
            if b.anxHover.SetTexCoord then b.anxHover:SetTexCoord(0, 0.625, 0, 0.6875) end
        else
            b.anxHover:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        end
        UI.skinButtons = UI.skinButtons or {}
        if not b.anxSkinReg then
            b.anxSkinReg = true
            UI.skinButtons[#UI.skinButtons + 1] = b
        end
    end
    UI.SkinFlat = SkinFlat
    local function SmallFont(b)
        local fs = b.anxLabel or (b.GetFontString and b:GetFontString())
        if fs and fs.SetFontObject and _G.GameFontHighlightSmall then
            fs:SetFontObject(_G.GameFontHighlightSmall)
        end
    end
    -- chip dressing shared by the filter chips and the Find/Filters buttons:
    -- painted plate, pack icon at the left, left-aligned label
    local function StyleChip(b, iconKey)
        SkinFlat(b, "chip")
        local ic = b:CreateTexture(nil, "OVERLAY")
        ic.anxMine = true
        ic:SetWidth(18); ic:SetHeight(18)
        ic:SetPoint("LEFT", b, "LEFT", 8, 0)
        b.anxChipIcon = ic
        b.anxIconKey = iconKey
        if not SetIconArt(ic, iconKey, 18) then ic:Hide() end
        local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl.anxMine = true
        lbl:SetPoint("LEFT", b, "LEFT", 30, 0)
        lbl:SetJustifyH("LEFT")
        b.anxLabel = lbl
    end

    -- ============== top bar ==============
    -- [wordmark = the AttuneNext button]  [search | Find | Filters]  [opt] [rescan] [x]
    local goBtn = CreateFrame("Button", "AttuneNextGoBtn", f)
    goBtn:SetWidth(148); goBtn:SetHeight(34)
    goBtn:SetPoint("TOPLEFT", CX + 16, -12)
    StripEngineSkin(goBtn)
    goBtn:SetScript("OnShow", StripEngineSkin)
    if ANx.Art and ANx.Art.logo then
        local lg = goBtn:CreateTexture(nil, "ARTWORK")
        lg.anxMine = true
        lg:SetPoint("CENTER", goBtn, "CENTER", 0, 0)
        lg:SetWidth(132); lg:SetHeight(30)   -- inset: the hover border needs air
        SetArtTrim(lg, "logo", true)   -- forced: the wordmark stays in Classic
        goBtn.anxLogo = lg
        f.logoTex = lg
    else
        local lbl = goBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        lbl.anxMine = true
        lbl:SetPoint("LEFT", goBtn, "LEFT", 0, 0)
        lbl:SetText("|cff33ff99Attune|r|cffffffffNext|r")
        goBtn.anxLabel = lbl
    end
    local glowH = goBtn:CreateTexture(nil, "HIGHLIGHT")
    glowH.anxMine = true
    glowH:SetPoint("TOPLEFT", goBtn, "TOPLEFT", 0, 0)
    glowH:SetWidth(148); glowH:SetHeight(34)
    if glowH.SetBlendMode then glowH:SetBlendMode("ADD") end
    if ANx.Art and ANx.Art.button_hover then
        glowH:SetTexture(ANx.ART_PATH .. ANx.Art.button_hover[1])
        ArtTexCoord(glowH, "button_hover")
    else
        glowH:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    end
    goBtn:SetScript("OnClick", function() UI.AttuneNextGo() end)
    goBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("AttuneNext", 1, 0.82, 0.3, 1, true)
        if GameTooltip.AddLine then
            GameTooltip:AddLine("Click: jump to a recommended next item. Configure with the gear button.", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    goBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.goBtn = goBtn


    -- small square icon button: painted bezel + glyph (text fallback)
    local function IconButton(name, iconKey, fallbackText, tip)
        -- plain Button: no template, no SetText - nothing for a client-side
        -- button skinner to grab onto (the custom client restyles template
        -- buttons around their text, which kept displacing our art)
        local b = CreateFrame("Button", name, f)
        local arted = ANx.Art and ANx.Art[iconKey]
        b:SetWidth(arted and 28 or 56); b:SetHeight(28)
        if arted then
            StripEngineSkin(b)
            b:SetScript("OnShow", StripEngineSkin)
            local bez = b:CreateTexture(nil, "BACKGROUND")
            bez.anxMine = true
            bez:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
            bez:SetWidth(28); bez:SetHeight(28)
            if not SetArtTrim(bez, "icon_bezel_normal") then
                bez:SetTexture(0.10, 0.10, 0.13, 0.9)
            end
            local ic = b:CreateTexture(nil, "ARTWORK")
            ic.anxMine = true
            ic:SetWidth(18); ic:SetHeight(18)
            ic:SetPoint("CENTER", 0, 0)
            SetIconArt(ic, iconKey, 18)
            b.anxIcon = ic
            if b.SetHighlightTexture then b:SetHighlightTexture("") end
            local h = b:CreateTexture(nil, "HIGHLIGHT")
            h.anxMine = true
            h:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
            h:SetWidth(28); h:SetHeight(28)
            if h.SetBlendMode then h:SetBlendMode("ADD") end
            if ANx.Art.button_hover then
                h:SetTexture(ANx.ART_PATH .. ANx.Art.button_hover[1])
                ArtTexCoord(h, "button_hover")
            else
                h:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            end
        else
            SkinFlat(b)
            local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl.anxMine = true
            lbl:SetPoint("CENTER", b, "CENTER", 0, 0)
            lbl:SetText(fallbackText)
            b.anxLabel = lbl
        end
        b.anxTip = tip
        b:SetScript("OnEnter", function(self)
            if not self.anxTip then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(self.anxTip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end

    -- options (gear icon): general settings + the AttuneNext button's options
    local goOptBtn = IconButton("AttuneNextGoOptBtn", "settings", "Opt", "Options")
    goOptBtn:SetPoint("TOPRIGHT", -84, -15)
    goOptBtn:SetScript("OnClick", function()
        if UI.Current().type ~= "options" then UI.Push({ type = "options" }) end
    end)
    f.goOptBtn = goOptBtn

    -- manual rescan of the loot DB (refresh icon)
    local refresh = IconButton("AttuneNextRescanBtn", "rescan", "Rescan",
        "Rescan the loot database")
    refresh:SetPoint("TOPRIGHT", -50, -15)
    refresh:SetScript("OnClick", function()
        Engine.ForceRescan()
        ANx.Print("Manual rescan started (saved cache cleared).")
        UI.Render()
    end)

    -- painted close (right rail lines up with the chips below)
    local closeBtn = IconButton("AttuneNextCloseBtn", "close", "X", "Close")
    closeBtn:SetPoint("TOPRIGHT", -16, -15)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    f.closeBtn = closeBtn

    -- search field: 3-slice painted skin so the border never distorts
    local sfW, sfX = 152, CX + 170
    f.anxFieldSlices = {}
    local function FieldSlice(x, w, u0, u1)
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetWidth(w); t:SetHeight(30)
        t:SetPoint("TOPLEFT", x, -14)
        if ANx.Art and ANx.Art.search_field and ArtOn() then
            t:SetTexture(ANx.ART_PATH .. ANx.Art.search_field[1])
            if t.SetTexCoord then t:SetTexCoord(u0, u1, 0.5771, 0.6738) end
        else
            t:SetTexture(0.10, 0.10, 0.13, 0.9)
        end
        t.anxUV = { u0, u1 }
        f.anxFieldSlices[#f.anxFieldSlices + 1] = t
        return t
    end
    f.searchBg = FieldSlice(sfX, 20, 0.0146, 0.0830)                 -- left cap
    FieldSlice(sfX + 20, sfW - 40, 0.0830, 0.1689)                   -- middle
    -- the art has no right border - mirror the left cap (flipped u coords)
    FieldSlice(sfX + sfW - 20, 20, 0.0830, 0.0146)                   -- right cap
    local searchIcon = f:CreateTexture(nil, "OVERLAY")
    searchIcon:SetWidth(16); searchIcon:SetHeight(16)
    searchIcon:SetPoint("TOPLEFT", sfX + 8, -21)
    if not SetIconArt(searchIcon, "search", 16) then
        searchIcon:Hide()
    end

    local searchPh = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchPh:SetPoint("TOPLEFT", sfX + 32, -22)
    searchPh:SetText("Search")
    f.searchPlaceholder = searchPh

    local searchBox = CreateFrame("EditBox", "AttuneNextSearchBox", f, "InputBoxTemplate")
    searchBox:SetWidth(sfW - 44); searchBox:SetHeight(20)
    searchBox:SetPoint("TOPLEFT", sfX + 34, -19)
    searchBox:SetAutoFocus(false)
    -- hide the template's own box art; the painted field is the skin
    for _, sfx in ipairs({ "Left", "Middle", "Right" }) do
        local t = _G["AttuneNextSearchBox" .. sfx]
        if t and t.Hide then t:Hide() end
    end
    searchBox:SetScript("OnEscapePressed", function(self)
        self:SetText(""); self:ClearFocus()
    end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEditFocusGained", function() searchPh:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then searchPh:Show() end
    end)
    searchBox:SetScript("OnTextChanged", function(self)
        local txt = self:GetText() or ""
        if txt == "" then searchPh:Show() else searchPh:Hide() end
        if UI._searchSetting then return end
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

    -- Find + Filters: chip-styled like the sidebar entries (icon + label)
    local findBtn = CreateFrame("Button", "AttuneNextFindBtn", f)
    findBtn:SetWidth(136); findBtn:SetHeight(30)
    findBtn:SetPoint("TOPLEFT", CX + 328, -14)
    findBtn:SetScript("OnClick", function() UI.CycleSearchType() end)
    StyleChip(findBtn, "attunement")
    SmallFont(findBtn)
    f.findBtn = findBtn

    local sfBtn = CreateFrame("Button", "AttuneNextSearchFiltersBtn", f)
    sfBtn:SetWidth(110); sfBtn:SetHeight(30)
    sfBtn:SetPoint("TOPLEFT", CX + 470, -14)
    sfBtn:SetScript("OnClick", function()
        ANx.db.searchFilters = not (ANx.db.searchFilters ~= false)
        UI.Render()
    end)
    StyleChip(sfBtn, "filter")
    SmallFont(sfBtn)
    f.searchFiltersBtn = sfBtn

    -- ============== nav row ==============
    -- Back/Home hide on the home screen (nothing to go back to).
    -- Plain buttons with our own centered labels (see IconButton note).
    local function TextButton(name, w, label, iconKey)
        local b = CreateFrame("Button", name, f)
        b:SetWidth(w); b:SetHeight(26)
        SkinFlat(b, "chip")
        local x = 0
        if iconKey and ANx.Art and ANx.Art[iconKey] then
            local ic = b:CreateTexture(nil, "OVERLAY")
            ic.anxMine = true
            ic:SetPoint("LEFT", b, "LEFT", 7, 0)
            SetIconArt(ic, iconKey, 15)
            b.anxChipIcon = ic
            x = 26
        end
        local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl.anxMine = true
        if x > 0 then
            lbl:SetPoint("LEFT", b, "LEFT", x, 0)
            lbl:SetJustifyH("LEFT")
        else
            lbl:SetPoint("CENTER", b, "CENTER", 0, 0)
        end
        lbl:SetText("|cffe3c98f" .. label .. "|r")
        b.anxLabel = lbl
        return b
    end
    local function SetBtnText(b, t)
        if b.anxLabel then b.anxLabel:SetText(t) end
    end
    UI.SetBtnText = SetBtnText

    local back = TextButton("AttuneNextBackBtn", 62, "Back", "back")
    back:SetPoint("TOPLEFT", CX + 16, -54)
    back:SetScript("OnClick", UI.Pop)
    f.back = back

    local homeBtn = TextButton("AttuneNextHomeBtn", 66, "Home", "home")
    homeBtn:SetPoint("TOPLEFT", CX + 84, -54)
    homeBtn:SetScript("OnClick", function() UI.Show(true) end)
    f.homeBtn = homeBtn

    local favBtn = TextButton("AttuneNextFavBtn", 66, "Fav +", "favorite_add")
    favBtn:SetPoint("TOPLEFT", CX + 156, -54)
    favBtn:SetScript("OnClick", function() UI.ToggleFavorite() end)
    f.favBtn = favBtn


    -- breadcrumb (slides left when Back/Home are hidden on the home screen)
    -- hidden text mirror of the breadcrumb (the visible crumb is a row of
    -- clickable segment buttons laid out at render time)
    local crumb = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    crumb:SetPoint("TOPLEFT", CX + 232, -60)
    crumb:SetWidth(FRAME_W - 232 - 24)
    crumb:SetJustifyH("LEFT")
    crumb:Hide()
    f.crumb = crumb
    f.crumbBtns, f.crumbSeps = {}, {}
    function UI.CrumbButton(n)
        local cb = f.crumbBtns[n]
        if not cb then
            cb = CreateFrame("Button", "AttuneNextCrumb" .. n, f)
            cb:SetHeight(20)
            StripEngineSkin(cb)
            cb:SetScript("OnShow", StripEngineSkin)
            local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            lbl.anxMine = true
            lbl:SetPoint("LEFT", cb, "LEFT", 0, 0)
            lbl:SetJustifyH("LEFT")
            cb.anxLabel = lbl
            cb:SetScript("OnClick", function(self)
                local target = self.anxStackIndex
                if target and #UI.stack > target then
                    for k = #UI.stack, target + 1, -1 do table.remove(UI.stack, k) end
                    UI.Render()
                end
            end)
            f.crumbBtns[n] = cb
        end
        return cb
    end

    -- ============== filter chips (v3.0.0t) ==============
    -- Every filter is a uniform painted chip: pack icon on the left, the
    -- current VALUE as the label, one color per filter (mockup style).
    -- Chips lay out in balanced, centered rows via UI.LayoutChips().
    local CHIP_H = 28
    local CHIP_TOP, CHIP_PITCH, CHIP_GAP, CHIP_PER_ROW = -88, 32, 8, 5
    local chipOrder = {}
    local function ChipTip(self)
        if not self.anxTipTitle then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(self.anxTipTitle, 1, 0.82, 0.3, 1, true)
        if self.anxTipText and GameTooltip.AddLine then
            GameTooltip:AddLine(self.anxTipText, 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end
    local function Chip(name, iconKey, tipTitle, tipText, onClick)
        local b = CreateFrame("Button", name, f)
        b:SetWidth(140); b:SetHeight(CHIP_H)       -- width set by LayoutChips
        b:SetPoint("TOPLEFT", CX + 16, CHIP_TOP)   -- real spot set by LayoutChips
        b:SetScript("OnClick", onClick)
        StyleChip(b, iconKey)
        b.anxTipTitle, b.anxTipText = tipTitle, tipText
        b:SetScript("OnEnter", ChipTip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        chipOrder[#chipOrder + 1] = b
        return b
    end

    f.scopeBtn = Chip("AttuneNextScopeBtn", "character", "Attunes scope",
        "Count attunes for this character or for the whole account.", function()
        ANx.db.scope = (ANx.db.scope == "account") and "char" or "account"
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.factionBtn = Chip("AttuneNextFactionBtn", "faction_neutral", "Faction",
        "Cycle Alliance / Horde / both factions.", function()
        local cur = ANx.db.faction or "both"
        ANx.db.faction = (cur == "both") and "A" or (cur == "A") and "H" or "both"
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.forgeBtn = Chip("AttuneNextForgeBtn", "attunement", "Forge Level",
        "Attunable / Titanforged / Warforged / Lightforged: counts show what's done at this level vs what's left. Quest rewards can't be forged, so they only ever need attuning.", function()
        ANx.db.forge = (ANx.ForgeLevel() % 4) + 1
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.bindBtn = Chip("AttuneNextBindBtn", "bind", "Bind filter",
        "Show BoP only, BoE only, or both.", function()
        local cur = ANx.db.bindFilter or "both"
        ANx.db.bindFilter = (cur == "both") and "bop" or (cur == "bop") and "boe" or "both"
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.accBtn = Chip("AttuneNextAccBtn", "accessories", "Accessories",
        "Include rings, trinkets, necks and cloaks.", function()
        ANx.db.accessories = not (ANx.db.accessories ~= false)
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.zexBtn = Chip("AttuneNextZexBtn", "zone_exclusive", "Zone-exclusive",
        "Only items that drop nowhere else.", function()
        ANx.db.zoneExclusive = not ANx.db.zoneExclusive
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.sortBtn = Chip("AttuneNextSortBtn", "sort", "Sort",
        "Change how this list is ordered.", function()
        CycleSort(UI.Current())
        UI.Render()
    end)

    f.diffBtn = Chip("AttuneNextDiffBtn", "difficulty", "Difficulty",
        "Dungeon tier: Normal / Heroic / Mythic.", function()
        local order = { "all", "normal", "heroic", "mythic" }
        local cur = ANx.db.difficulty or "all"
        for i, v in ipairs(order) do if v == cur then ANx.db.difficulty = order[(i % #order) + 1]; break end end
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.sizeBtn = Chip("AttuneNextSizeBtn", "raid_size", "Raid size",
        "10-man / 25-man raids.", function()
        local order = { "all", "10", "25" }
        local cur = ANx.db.raidSize or "all"
        for i, v in ipairs(order) do if v == cur then ANx.db.raidSize = order[(i % #order) + 1]; break end end
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.filterBtn = Chip("AttuneNextFilterBtn", "currency", "Currency type",
        "Vendors by payment: gold, honor/arena, emblems or tokens.", function()
        CycleVendorFilter()
        UI.Render()
    end)

    f.stockBtn = Chip("AttuneNextStockBtn", "stock", "Vendor stock",
        "Limited (one-time) or unlimited vendor stock.", function()
        local cur = ANx.db.stockFilter or "all"
        ANx.db.stockFilter = (cur == "all") and "limited" or (cur == "limited") and "unlimited" or "all"
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.affordBtn = Chip("AttuneNextAffordBtn", "affordable", "Affordable",
        "Only what you can buy right now.", function()
        ANx.db.affordableOnly = not ANx.db.affordableOnly
        ANx.InvalidatePlayerCurrency()
        Engine.InvalidateStats()
        UI.Render()
    end)

    f.raresBtn = Chip("AttuneNextRaresBtn", "rare_spawn", "Rare spawns",
        "Only world drops from rare mobs.", function()
        ANx.db.raresOnly = not ANx.db.raresOnly
        Engine.InvalidateStats()
        UI.Render()
    end)

    -- balanced chip grid that fills the content width: rows split evenly
    -- (6 -> 3+3, 9 -> 5+4), every chip one uniform width (sized so the
    -- fullest row spans logo-edge to rescan-edge), and rows with fewer
    -- chips stretch their gaps so every row runs edge to edge
    function UI.LayoutChips()
        local vis = {}
        for _, b in ipairs(chipOrder) do
            if b:IsShown() then vis[#vis + 1] = b end
        end
        local n = #vis
        if n == 0 then UI.lastChipLayout = { total = 0, rows = {} } return end
        local span = FRAME_W - 32                  -- CX+16 .. right edge -16
        local nrows = math.ceil(n / CHIP_PER_ROW)
        local base = math.floor(n / nrows)
        local extra = n - base * nrows
        local maxCnt = base + ((extra > 0) and 1 or 0)
        local W = math.floor((span - (maxCnt - 1) * CHIP_GAP) / maxCnt)
        UI.lastChipLayout = { total = n, rows = {}, w = W }
        local idx = 1
        for r = 1, nrows do
            local cnt = base + ((r <= extra) and 1 or 0)
            UI.lastChipLayout.rows[r] = cnt
            local gap = (cnt > 1) and ((span - cnt * W) / (cnt - 1)) or 0
            local y = CHIP_TOP - (r - 1) * CHIP_PITCH
            local x = CX + 16
            for c = 1, cnt do
                local b = vis[idx]; idx = idx + 1
                b:SetWidth(W)
                if b.anxPlate then b.anxPlate:SetWidth(W); b.anxPlate:SetHeight(CHIP_H) end
                if b.anxHover then b.anxHover:SetWidth(W); b.anxHover:SetHeight(CHIP_H) end
                if b.ClearAllPoints then b:ClearAllPoints() end
                b:SetPoint("TOPLEFT", f, "TOPLEFT", math.floor(x + 0.5), y)
                x = x + W + gap
            end
        end
    end

    -- ================= sidebar navigation =================

    local NAV_DEFS = {
        { key = "home",      label = "Home" },
        { key = "browse",    label = "Browse" },
        { key = "whatsleft", label = "What's Left" },
        { key = "favorites", label = "Favorites" },
        { key = "goals",     label = "Goals" },
        { key = "options",   label = "Options" },
    }
    local function NavGo(key)
        UI.Show(true)
        if key == "browse" then UI.Push({ type = "browse" })
        elseif key == "whatsleft" then UI.Push({ type = "whatsleft" })
        elseif key == "favorites" then UI.Push({ type = "favorites" })
        elseif key == "goals" then UI.Push({ type = "goals" })
        elseif key == "options" then UI.Push({ type = "options" })
        end
    end
    f.navButtons = {}
    local NAV_ICON = { home = "home", browse = "browse", whatsleft = "whats_left",
                       favorites = "favorites", goals = "goals", options = "settings" }
    for i, def in ipairs(NAV_DEFS) do
        local nb = CreateFrame("Button", "AttuneNextNav" .. def.key, f, "UIPanelButtonTemplate")
        nb:SetWidth(SIDEBAR_W - 20); nb:SetHeight(34)
        nb:SetPoint("TOPLEFT", 10, (f.navTop or -52) - (i - 1) * 40)
        nb:SetText(def.label)
        nb._navKey = def.key
        nb._navLabel = def.label
        nb:SetScript("OnClick", function() NavGo(def.key) end)
        -- bare rows: no button chrome; only the ACTIVE entry gets the
        -- teal-outlined chip (like the mockups)
        if nb.SetNormalTexture then nb:SetNormalTexture("") end
        if nb.SetPushedTexture then nb:SetPushedTexture("") end
        -- same additive hover glow as the filter chips (the engine
        -- highlight stretched the art into a squashed band)
        if nb.SetHighlightTexture then nb:SetHighlightTexture("") end
        local nh = nb:CreateTexture(nil, "HIGHLIGHT")
        nh.anxMine = true
        nh:SetPoint("TOPLEFT", nb, "TOPLEFT", 0, 0)
        nh:SetWidth(SIDEBAR_W - 20); nh:SetHeight(34)
        if nh.SetBlendMode then nh:SetBlendMode("ADD") end
        if ANx.Art and ANx.Art.button_hover then
            nh:SetTexture(ANx.ART_PATH .. ANx.Art.button_hover[1])
            ArtTexCoord(nh, "button_hover")
        else
            nh:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        end
        nb.anxHover = nh
        if nb.CreateTexture then
            local chip = nb:CreateTexture(nil, "BACKGROUND")
            if chip.SetAllPoints then chip:SetAllPoints(nb)
            else chip:SetPoint("TOPLEFT"); chip:SetPoint("BOTTOMRIGHT") end
            if not SetArtTrim(chip, "filter_chip_selected") then
                chip:SetTexture(0.10, 0.28, 0.24, 0.95)
            end
            chip:Hide()
            nb.anxActive = chip
        end
        -- big icon, clearly separated from left-aligned text
        if ANx.Art and ANx.Art[NAV_ICON[def.key]] then
            local ic = nb:CreateTexture(nil, "OVERLAY")
            ic.anxMine = true
            ic:SetWidth(24); ic:SetHeight(24)
            ic:SetPoint("LEFT", 10, 0)
            if not SetIconArt(ic, NAV_ICON[def.key], 24) then ic:Hide() end
            nb.anxNavIcon, nb.anxNavKey = ic, NAV_ICON[def.key]
        end
        local fs = nb.GetFontString and nb:GetFontString()
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", 44, 0)
            fs:SetJustifyH("LEFT")
        end
        f.navButtons[def.key] = nb
    end


    -- scroll area
    local scroll = CreateFrame("ScrollFrame", "AttuneNextScroll", f, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", CX + 16, -154)
    scroll:SetPoint("BOTTOMRIGHT", -36, 38)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, UI.Render)
    end)
    f.scroll = scroll

    -- rows
    for i = 1, VISIBLE_ROWS do
        local b = CreateFrame("Button", "AttuneNextRow" .. i, f)
        b:SetWidth(FRAME_W - 56)
        b.anxFullW = FRAME_W - 56
        b:SetHeight(ROW_H)
        b:SetPoint("TOPLEFT", CX + 20, -154 - (i - 1) * ROW_H)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetWidth(28); b.icon:SetHeight(28)
        b.icon:SetPoint("LEFT", 2, 0)

        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.text:SetPoint("TOPLEFT", 36, -4)
        b.text:SetJustifyH("LEFT")
        b.text:SetWidth(FRAME_W - 300)

        -- description sits under the title and may wrap to two lines
        b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.sub:SetPoint("TOPLEFT", 36, -19)
        b.sub:SetJustifyH("LEFT")
        b.sub:SetWidth(FRAME_W - 300)
        b.sub:SetTextColor(0.7, 0.7, 0.7)

        b.right = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.right:SetPoint("TOPRIGHT", -6, -4)
        b.right:SetJustifyH("RIGHT")

        b.right2 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.right2:SetPoint("BOTTOMRIGHT", -6, 4)
        b.right2:SetJustifyH("RIGHT")
        b.right2:SetTextColor(0.6, 0.6, 0.6)

        -- optional progress bar (node/goal rows): track + fill
        b.barTrack = b:CreateTexture(nil, "BACKGROUND")
        b.barTrack:SetPoint("BOTTOMLEFT", 36, 2)
        b.barTrack:SetHeight(5)
        b.anxBarW = FRAME_W - 56 - 36 - 236
        b.anxTextW = FRAME_W - 56 - 250 - 46
        b.barTrack:SetWidth(b.anxBarW)
        b.barTrack:Hide()
        b.bar = b:CreateTexture(nil, "BORDER")
        b.bar:SetPoint("BOTTOMLEFT", 36, 2)
        b.bar:SetHeight(5)
        b.bar:Hide()

        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                -- right-click an item: arrow to its best source
                if self.tooltipItem and ANx.ArrowToItem then
                    ANx.ArrowToItem(self.tooltipItem)
                end
                return
            end
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
    status:SetPoint("BOTTOMLEFT", CX + 18, 20)
    status:SetWidth(FRAME_W - 40)
    status:SetJustifyH("LEFT")
    f.status = status

    -- flat-skin the remaining text buttons (chips + icon buttons skin themselves)
    for _, b in ipairs({ back, homeBtn, favBtn }) do
        if b then SkinFlat(b) end
    end

    -- ============== home panel (cards on the root screen) ==============
    do
        local hp = CreateFrame("Frame", "AttuneNextHomePanel", f)
        hp:SetWidth(FRAME_W - 32); hp:SetHeight(544)
        hp:SetPoint("TOPLEFT", f, "TOPLEFT", CX + 16, -152)
        -- The card art is an ornate frame: stretching it inflates the corner
        -- filigree and swallows the content area, so cards are drawn 9-slice -
        -- corners stay 26px, edges stretch on one axis, the middle fills.
        local CARD_CS = 26           -- painted corner size on screen
        local CU0, CV0, CU1, CV1 = 0.7656, 0.5518, 0.9854, 0.6973
        local CDU, CDV = 34 / 1024, 34 / 1024   -- corner size in the atlas
        local CARD_PAD = 30          -- safe content inset (corner + breathing room)
        local CARD_HI = 8            -- hover wash inset (stays inside the frame)
        -- attach the 9-slice card art to an existing frame (rows use this too)
        UI.skinCards = UI.skinCards or {}
        local function AttachCard(c, cs)
            c.anxCS = cs or CARD_CS
            UI.skinCards[#UI.skinCards + 1] = c
            local art = ANx.Art and ANx.Art.content_card
            if not art then return end
            local path = ANx.ART_PATH .. art[1]
            local function Slice(u0, u1, v0, v1)
                local t = c:CreateTexture(nil, "BACKGROUND")
                t.anxMine = true
                t:SetTexture(path)
                if t.SetTexCoord then t:SetTexCoord(u0, u1, v0, v1) end
                return t
            end
            local mU0, mU1 = CU0 + CDU, CU1 - CDU
            local mV0, mV1 = CV0 + CDV, CV1 - CDV
            c.sTL = Slice(CU0, mU0, CV0, mV0)
            c.sTR = Slice(mU1, CU1, CV0, mV0)
            c.sBL = Slice(CU0, mU0, mV1, CV1)
            c.sBR = Slice(mU1, CU1, mV1, CV1)
            c.sT  = Slice(mU0, mU1, CV0, mV0)
            c.sB  = Slice(mU0, mU1, mV1, CV1)
            c.sL  = Slice(CU0, mU0, mV0, mV1)
            c.sR  = Slice(mU1, CU1, mV0, mV1)
            c.sC  = Slice(mU0, mU1, mV0, mV1)
            c.anxPlate = c.sC
        end
        local function LayoutCard(c, w, hgt)
            local CS = c.anxCS or CARD_CS
            if not c.sTL then return end
            local mid, midV = w - 2 * CS, hgt - 2 * CS
            local function Put(t, px, py, pw, ph)
                if t.ClearAllPoints then t:ClearAllPoints() end
                t:SetPoint("TOPLEFT", c, "TOPLEFT", px, -py)
                t:SetWidth(pw > 0 and pw or 1); t:SetHeight(ph > 0 and ph or 1)
            end
            Put(c.sTL, 0, 0, CS, CS)
            Put(c.sTR, w - CS, 0, CS, CS)
            Put(c.sBL, 0, hgt - CS, CS, CS)
            Put(c.sBR, w - CS, hgt - CS, CS, CS)
            Put(c.sT, CS, 0, mid, CS)
            Put(c.sB, CS, hgt - CS, mid, CS)
            Put(c.sL, 0, CS, CS, midV)
            Put(c.sR, w - CS, CS, CS, midV)
            Put(c.sC, CS, CS, mid, midV)
        end
        UI.AttachCard, UI.LayoutCard = AttachCard, LayoutCard

        local function Card(parent, name)
            local c = CreateFrame("Button", name, parent)
            StripEngineSkin(c)
            c:SetScript("OnShow", StripEngineSkin)
            UI.skinCards[#UI.skinCards + 1] = c
            local art = ANx.Art and ANx.Art.content_card
            if art then
                local path = ANx.ART_PATH .. art[1]
                local function Slice(u0, u1, v0, v1)
                    local t = c:CreateTexture(nil, "BORDER")
                    t.anxMine = true
                    t:SetTexture(path)
                    if t.SetTexCoord then t:SetTexCoord(u0, u1, v0, v1) end
                    return t
                end
                local mU0, mU1 = CU0 + CDU, CU1 - CDU
                local mV0, mV1 = CV0 + CDV, CV1 - CDV
                c.sTL = Slice(CU0, mU0, CV0, mV0)
                c.sTR = Slice(mU1, CU1, CV0, mV0)
                c.sBL = Slice(CU0, mU0, mV1, CV1)
                c.sBR = Slice(mU1, CU1, mV1, CV1)
                c.sT  = Slice(mU0, mU1, CV0, mV0)
                c.sB  = Slice(mU0, mU1, mV1, CV1)
                c.sL  = Slice(CU0, mU0, mV0, mV1)
                c.sR  = Slice(mU1, CU1, mV0, mV1)
                c.sC  = Slice(mU0, mU1, mV0, mV1)
                c.anxPlate = c.sC
            else
                local bg = c:CreateTexture(nil, "BORDER")
                bg.anxMine = true
                bg:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
                bg:SetTexture(0.08, 0.08, 0.11, 0.92)
                c.anxPlate = bg
            end
            -- hover: a flat additive wash. The painted pill art has its own
            -- frame shape, which read as a second border inside the card.
            local h = c:CreateTexture(nil, "HIGHLIGHT")
            h.anxMine = true
            h:SetPoint("TOPLEFT", c, "TOPLEFT", CARD_HI, -CARD_HI)
            if h.SetBlendMode then h:SetBlendMode("ADD") end
            h:SetTexture(0.42, 0.36, 0.20, 0.16)
            c.anxHover = h
            return c
        end
        local function SizeCard(c, w, hgt)
            c:SetWidth(w); c:SetHeight(hgt)
            local CS = CARD_CS
            if c.sTL then
                LayoutCard(c, w, hgt)
            elseif c.anxPlate then
                c.anxPlate:SetWidth(w); c.anxPlate:SetHeight(hgt)
            end
            c.anxHover:SetWidth(w - 2 * CARD_HI); c.anxHover:SetHeight(hgt - 2 * CARD_HI)
        end

        -- Recommended Next
        local rec = Card(hp, "AttuneNextHomeRec")
        SizeCard(rec, FRAME_W - 32, 124)
        rec:SetPoint("TOPLEFT", hp, "TOPLEFT", 0, 0)
        rec:SetScript("OnClick", function() UI.ShowRec() end)
        local recHdrIc = rec:CreateTexture(nil, "OVERLAY")
        recHdrIc.anxMine = true
        recHdrIc:SetPoint("TOPLEFT", rec, "TOPLEFT", CARD_PAD, -14)
        SetIconArt(recHdrIc, "attunement", 18)
        local recHdr = rec:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        recHdr.anxMine = true
        recHdr:SetPoint("LEFT", recHdrIc, "RIGHT", 8, 0)
        recHdr:SetText("|cffffd100Recommended Next|r")
        rec.icon = rec:CreateTexture(nil, "OVERLAY")
        rec.icon.anxMine = true
        rec.icon:SetWidth(60); rec.icon:SetHeight(60)
        rec.icon:SetPoint("TOPLEFT", rec, "TOPLEFT", CARD_PAD, -42)
        rec.title = rec:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        rec.title.anxMine = true
        rec.title:SetPoint("TOPLEFT", rec, "TOPLEFT", CARD_PAD + 74, -42)
        rec.title:SetJustifyH("LEFT")
        rec.line1 = rec:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        rec.line1.anxMine = true
        rec.line1:SetPoint("TOPLEFT", rec, "TOPLEFT", CARD_PAD + 74, -68)
        rec.line1:SetJustifyH("LEFT")
        rec.line2 = rec:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        rec.line2.anxMine = true
        rec.line2:SetPoint("TOPLEFT", rec, "TOPLEFT", CARD_PAD + 74, -88)
        rec.line2:SetJustifyH("LEFT")
        local showBtn = CreateFrame("Button", "AttuneNextHomeShowMe", rec)
        showBtn.anxMine = true   -- child frame of the card: exempt from the purge
        showBtn:SetWidth(110); showBtn:SetHeight(30)
        showBtn:SetPoint("TOPRIGHT", rec, "TOPRIGHT", -CARD_PAD, -46)
        SkinFlat(showBtn, "chip")
        local sbl = showBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        sbl.anxMine = true
        sbl:SetPoint("CENTER", showBtn, "CENTER", 0, 0)
        sbl:SetText("|cffffd100Show Me|r")
        showBtn.anxLabel = sbl
        showBtn:SetScript("OnClick", function() UI.ShowRec() end)
        hp.rec = rec

        -- three expansion cards
        hp.exp = {}
        local CW = math.floor((FRAME_W - 32 - 20) / 3)
        for e = 1, 3 do
            local c = Card(hp, "AttuneNextHomeExp" .. e)
            SizeCard(c, CW, 168)
            c:SetPoint("TOPLEFT", hp, "TOPLEFT", (e - 1) * (CW + 10), -136)
            c:SetScript("OnClick", function() UI.Push({ type = "content", exp = e }) end)
            c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            c.name.anxMine = true
            c.name:SetPoint("TOP", c, "TOP", 0, -18)
            c.icon = c:CreateTexture(nil, "OVERLAY")
            c.icon.anxMine = true
            c.icon:SetPoint("TOPLEFT", c, "TOPLEFT", CARD_PAD, -46)
            SetIconArt(c.icon, EXP_ART[e], 54)
            c.pct = c:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
            c.pct.anxMine = true
            c.pct:SetPoint("TOPRIGHT", c, "TOPRIGHT", -CARD_PAD, -52)
            c.pct:SetJustifyH("RIGHT")
            c.line = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            c.line.anxMine = true
            c.line:SetPoint("TOP", c, "TOP", 0, -110)
            c.line:SetJustifyH("CENTER")
            c.track = c:CreateTexture(nil, "ARTWORK")
            c.track.anxMine = true
            c.track:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", CARD_PAD, 30)
            c.track:SetWidth(CW - 2 * CARD_PAD); c.track:SetHeight(8)
            c.trackW = CW - 2 * CARD_PAD
            if not SetArtTrim(c.track, "progress_track") then
                c.track:SetTexture(0.09, 0.09, 0.12, 0.8)
            end
            c.bar = c:CreateTexture(nil, "OVERLAY")
            c.bar.anxMine = true
            c.bar:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", CARD_PAD, 30)
            c.bar:SetHeight(8)
            hp.exp[e] = c
        end

        -- active goals
        local gc = Card(hp, "AttuneNextHomeGoals")
        SizeCard(gc, FRAME_W - 32, 228)
        gc:SetPoint("TOPLEFT", hp, "TOPLEFT", 0, -316)
        gc:SetScript("OnClick", function() UI.Push({ type = "goals" }) end)
        local gHdrIc = gc:CreateTexture(nil, "OVERLAY")
        gHdrIc.anxMine = true
        gHdrIc:SetPoint("TOPLEFT", gc, "TOPLEFT", CARD_PAD, -14)
        SetIconArt(gHdrIc, "track_goal", 18)
        local gHdr = gc:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        gHdr.anxMine = true
        gHdr:SetPoint("LEFT", gHdrIc, "RIGHT", 8, 0)
        gHdr:SetText("|cffffd100Active Goals|r")
        gc.rows = {}
        for i = 1, 4 do
            local gr = {}
            local y = -40 - (i - 1) * 42
            gr.name = gc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            gr.name.anxMine = true
            gr.name:SetPoint("TOPLEFT", gc, "TOPLEFT", 40, y)
            gr.name:SetJustifyH("LEFT")
            gr.right = gc:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            gr.right.anxMine = true
            gr.right:SetPoint("TOPRIGHT", gc, "TOPRIGHT", -20, y)
            gr.right:SetJustifyH("RIGHT")
            gr.track = gc:CreateTexture(nil, "ARTWORK")
            gr.track.anxMine = true
            gr.track:SetPoint("TOPLEFT", gc, "TOPLEFT", 40, y - 18)
            gr.track:SetWidth(FRAME_W - 32 - 2 * CARD_PAD); gr.track:SetHeight(6)
            gr.trackW = FRAME_W - 32 - 2 * CARD_PAD
            if not SetArtTrim(gr.track, "progress_track") then
                gr.track:SetTexture(0.09, 0.09, 0.12, 0.8)
            end
            gr.bar = gc:CreateTexture(nil, "OVERLAY")
            gr.bar.anxMine = true
            gr.bar:SetPoint("TOPLEFT", gc, "TOPLEFT", 40, y - 18)
            gr.bar:SetHeight(6)
            gc.rows[i] = gr
        end
        hp.goals = gc
        hp.pad = CARD_PAD
        -- shared card helpers for the browse side pane
        UI.NewCard = function(parent, name, w, hgt)
            local c = Card(parent, name)
            SizeCard(c, w, hgt)
            return c
        end
        UI.CardFS = function(card, font, x, y)
            local fs = card:CreateFontString(nil, "OVERLAY", font)
            fs.anxMine = true
            fs:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
            fs:SetJustifyH("LEFT")
            return fs
        end
        UI.CardButton = function(card, name, w, label)
            local b = CreateFrame("Button", name, card)
            b.anxMine = true
            b:SetWidth(w); b:SetHeight(28)
            SkinFlat(b, "chip")
            local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            lbl.anxMine = true
            lbl:SetPoint("CENTER", b, "CENTER", 0, 0)
            lbl:SetText("|cffe3c98f" .. label .. "|r")
            b.anxLabel = lbl
            return b
        end
        UI.CARD_PAD = CARD_PAD
        hp:Hide()
        f.homePanel = hp
    end

    -- ============== What's Left dashboard ==============
    do
        local wl = CreateFrame("Frame", "AttuneNextWLPanel", f)
        local W = FRAME_W - 32
        wl:SetWidth(W); wl:SetHeight(ROW_H * VISIBLE_ROWS)
        wl:SetPoint("TOPLEFT", f, "TOPLEFT", CX + 16, -152)
        local PAD = UI.CARD_PAD or 30

        -- top row: three stat cards
        local CW3 = math.floor((W - 24) / 3)
        local function StatCard(name, x, title, iconKey)
            local c = UI.NewCard(wl, name, CW3, 132)
            c:SetPoint("TOPLEFT", wl, "TOPLEFT", x, 0)
            c.title = UI.CardFS(c, "GameFontNormal", PAD, -16)
            UI.FitText(c.title, "|cffffd100" .. title .. "|r", CW3 - 2 * PAD)
            c.icon = c:CreateTexture(nil, "OVERLAY")
            c.icon.anxMine = true
            c.icon:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -46)
            UI.SetIconArt(c.icon, iconKey, 44)
            c.num = UI.CardFS(c, "GameFontNormalHuge", PAD + 56, -48)
            c.sub = UI.CardFS(c, "GameFontHighlightSmall", PAD, -96)
            c.sub:SetWidth(CW3 - 2 * PAD)
            return c
        end
        wl.attunes = StatCard("AttuneNextWLAttunes", 0, "Attunes Left", "attunement")
        wl.attunes:SetScript("OnClick", function() UI.Push({ type = "whatsleftScope" }) end)
        wl.crafted = StatCard("AttuneNextWLCrafted", CW3 + 12, "Crafted Items Left", "crafting")
        wl.crafted:SetScript("OnClick", function() UI.Push({ type = "whatsleftMats" }) end)
        wl.currency = StatCard("AttuneNextWLCurrency", (CW3 + 12) * 2, "Currency Needed", "currency")
        wl.currency:SetScript("OnClick", function() UI.Push({ type = "whatsleftCur" }) end)

        -- middle row: remaining by expansion + active goals
        local CW2 = math.floor((W - 12) / 2)
        local exps = UI.NewCard(wl, "AttuneNextWLExps", CW2, 176)
        exps:SetPoint("TOPLEFT", wl, "TOPLEFT", 0, -144)
        exps.title = UI.CardFS(exps, "GameFontNormal", PAD, -16)
        exps.title:SetText("|cffffd100Remaining by Expansion|r")
        exps.rows = {}
        for e = 1, 3 do
            local r = {}
            local y = -52 - (e - 1) * 38
            r.icon = exps:CreateTexture(nil, "OVERLAY")
            r.icon.anxMine = true
            r.icon:SetPoint("TOPLEFT", exps, "TOPLEFT", PAD, y - 2)
            UI.SetIconArt(r.icon, EXP_ART[e], 22)
            r.name = UI.CardFS(exps, "GameFontHighlightSmall", PAD + 30, y)
            r.right = exps:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            r.right.anxMine = true
            r.right:SetPoint("TOPRIGHT", exps, "TOPRIGHT", -PAD, y)
            r.right:SetJustifyH("RIGHT")
            r.trackW = CW2 - 2 * PAD - 30 - 60
            r.track = exps:CreateTexture(nil, "ARTWORK")
            r.track.anxMine = true
            r.track:SetPoint("TOPLEFT", exps, "TOPLEFT", PAD + 30, y - 16)
            r.track:SetWidth(r.trackW); r.track:SetHeight(6)
            if not SetArtTrim(r.track, "progress_track") then
                r.track:SetTexture(0.09, 0.09, 0.12, 0.8)
            end
            r.bar = exps:CreateTexture(nil, "OVERLAY")
            r.bar.anxMine = true
            r.bar:SetPoint("TOPLEFT", exps, "TOPLEFT", PAD + 30, y - 16)
            r.bar:SetHeight(6)
            exps.rows[e] = r
        end
        exps:SetScript("OnClick", function() UI.Push({ type = "whatsleftScope" }) end)
        wl.exps = exps

        local goals = UI.NewCard(wl, "AttuneNextWLGoals", CW2, 176)
        goals:SetPoint("TOPLEFT", wl, "TOPLEFT", CW2 + 12, -144)
        goals.title = UI.CardFS(goals, "GameFontNormal", PAD, -16)
        goals.title:SetText("|cffffd100Active Goals|r")
        goals.rows = {}
        for i = 1, 3 do
            local r = {}
            local y = -52 - (i - 1) * 38
            r.name = UI.CardFS(goals, "GameFontHighlightSmall", PAD, y)
            r.right = UI.CardFS(goals, "GameFontHighlightSmall", PAD, y)
            r.right:ClearAllPoints()
            r.right:SetPoint("TOPRIGHT", goals, "TOPRIGHT", -PAD, y)
            r.right:SetJustifyH("RIGHT")
            r.trackW = CW2 - 2 * PAD
            r.track = goals:CreateTexture(nil, "ARTWORK")
            r.track.anxMine = true
            r.track:SetPoint("TOPLEFT", goals, "TOPLEFT", PAD, y - 16)
            r.track:SetWidth(r.trackW); r.track:SetHeight(6)
            if not SetArtTrim(r.track, "progress_track") then
                r.track:SetTexture(0.09, 0.09, 0.12, 0.8)
            end
            r.bar = goals:CreateTexture(nil, "OVERLAY")
            r.bar.anxMine = true
            r.bar:SetPoint("TOPLEFT", goals, "TOPLEFT", PAD, y - 16)
            r.bar:SetHeight(6)
            goals.rows[i] = r
        end
        goals:SetScript("OnClick", function() UI.Push({ type = "goals" }) end)
        wl.goals = goals

        -- bottom: top raw materials
        local mats = UI.NewCard(wl, "AttuneNextWLMats", W, 196)
        mats:SetPoint("TOPLEFT", wl, "TOPLEFT", 0, -332)
        mats.title = UI.CardFS(mats, "GameFontNormal", PAD, -16)
        mats.title:SetText("|cffffd100Top Raw Materials Needed|r")
        mats.hdrNeed = UI.CardFS(mats, "GameFontHighlightSmall", 0, -18)
        mats.hdrNeed:ClearAllPoints()
        mats.hdrNeed:SetPoint("TOPRIGHT", mats, "TOPRIGHT", -PAD - 96, -18)
        mats.hdrNeed:SetText("|cffbfae86Needed|r")
        mats.hdrOwn = UI.CardFS(mats, "GameFontHighlightSmall", 0, -18)
        mats.hdrOwn:ClearAllPoints()
        mats.hdrOwn:SetPoint("TOPRIGHT", mats, "TOPRIGHT", -PAD, -18)
        mats.hdrOwn:SetText("|cffbfae86Owned|r")
        mats.rows = {}
        for i = 1, 4 do
            local r = {}
            local y = -46 - (i - 1) * 28
            r.icon = mats:CreateTexture(nil, "OVERLAY")
            r.icon.anxMine = true
            r.icon:SetWidth(20); r.icon:SetHeight(20)
            r.icon:SetPoint("TOPLEFT", mats, "TOPLEFT", PAD, y - 1)
            r.name = UI.CardFS(mats, "GameFontHighlightSmall", PAD + 28, y)
            r.need = UI.CardFS(mats, "GameFontHighlightSmall", 0, y)
            r.need:ClearAllPoints()
            r.need:SetPoint("TOPRIGHT", mats, "TOPRIGHT", -PAD - 96, y)
            r.need:SetJustifyH("RIGHT")
            r.own = UI.CardFS(mats, "GameFontHighlightSmall", 0, y)
            r.own:ClearAllPoints()
            r.own:SetPoint("TOPRIGHT", mats, "TOPRIGHT", -PAD, y)
            r.own:SetJustifyH("RIGHT")
            mats.rows[i] = r
        end
        mats.allBtn = UI.CardButton(mats, "AttuneNextWLAllMats", 170, "See All Materials")
        mats.allBtn:SetPoint("BOTTOMRIGHT", mats, "BOTTOMRIGHT", -PAD, 22)
        mats.allBtn:SetScript("OnClick", function()
            UI.Push({ type = "whatsleftMatList" })
        end)
        wl.mats = mats

        wl:Hide()
        f.wlPanel = wl
    end

    -- ============== browse side pane (right column) ==============
    do
        local SP = f.homePanel and 30 or 30
        local sp = CreateFrame("Frame", "AttuneNextSidePane", f)
        sp.anxH = ROW_H * VISIBLE_ROWS - 6
        sp:SetWidth(SIDE_W); sp:SetHeight(sp.anxH)
        sp:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -154)

        -- item detail card (top; only when an item is selected)
        local it = UI.NewCard(sp, "AttuneNextSideItem", SIDE_W, 250)
        it:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, 0)
        it.hdr = UI.CardFS(it, "GameFontNormal", 30, -14)
        it.hdr:SetText("|cffffd100Item Details|r")
        it.icon = it:CreateTexture(nil, "OVERLAY")
        it.icon.anxMine = true
        it.icon:SetWidth(52); it.icon:SetHeight(52)
        it.icon:SetPoint("TOPLEFT", it, "TOPLEFT", 30, -40)
        it.name = UI.CardFS(it, "GameFontNormal", 90, -46)
        it.name:SetWidth(SIDE_W - 118)
        it.line1 = UI.CardFS(it, "GameFontHighlightSmall", 30, -102)
        it.line1:SetWidth(SIDE_W - 60)
        it.line2 = UI.CardFS(it, "GameFontHighlightSmall", 30, -124)
        it.line2:SetWidth(SIDE_W - 60)
        it.line3 = UI.CardFS(it, "GameFontHighlightSmall", 30, -150)
        it.line3:SetWidth(SIDE_W - 60)
        it.srcBtn = UI.CardButton(it, "AttuneNextSideSources", SIDE_W - 60, "Full details")
        it.srcBtn:SetPoint("BOTTOMLEFT", it, "BOTTOMLEFT", 30, 66)
        it.arrowBtn = UI.CardButton(it, "AttuneNextSideArrow", SIDE_W - 60, "Point the arrow")
        it.arrowBtn:SetPoint("BOTTOMLEFT", it, "BOTTOMLEFT", 30, 28)
        sp.item = it

        -- recommendation card (bottom; always)
        local rc = UI.NewCard(sp, "AttuneNextSideRec", SIDE_W, 266)
        rc:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, -262)
        rc.hdr = UI.CardFS(rc, "GameFontNormal", 30, -14)
        rc.hdr:SetText("|cffffd100Recommended Here|r")
        rc.icon = rc:CreateTexture(nil, "OVERLAY")
        rc.icon.anxMine = true
        rc.icon:SetWidth(48); rc.icon:SetHeight(48)
        rc.icon:SetPoint("TOPLEFT", rc, "TOPLEFT", 30, -40)
        rc.name = UI.CardFS(rc, "GameFontNormal", 86, -46)
        rc.name:SetWidth(SIDE_W - 116)
        rc.line1 = UI.CardFS(rc, "GameFontHighlightSmall", 30, -102)
        rc.line1:SetWidth(SIDE_W - 60)
        rc.line2 = UI.CardFS(rc, "GameFontHighlightSmall", 30, -124)
        rc.line2:SetWidth(SIDE_W - 60)
        rc.goBtn = UI.CardButton(rc, "AttuneNextSideGo", SIDE_W - 60, "Show Me")
        rc.goBtn:SetScript("OnClick", function() UI.ShowRec() end)
        rc.trackBtn = UI.CardButton(rc, "AttuneNextSideTrack", SIDE_W - 60, "Track as a goal")
        sp.rec = rc

        sp:Hide()
        f.sidePane = sp
    end

    -- each list row wears its own small card (matches the dashboard style)
    if UI.AttachCard then
        for _, b in ipairs(rowButtons) do
            b.anxNoBackdrop = true   -- classic: plain rows, no frame per row
            UI.AttachCard(b, 13)
            b.icon:ClearAllPoints()
            b.icon:SetPoint("LEFT", b, "LEFT", 12, 0)
            b.right:ClearAllPoints()
            b.right:SetPoint("TOPRIGHT", b, "TOPRIGHT", -14, -6)
            b.right2:ClearAllPoints()
            b.right2:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -14, 6)
            b.bar:ClearAllPoints()
            b.bar:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 46, 7)
            b.barTrack:ClearAllPoints()
            b.barTrack:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 46, 7)
        end
    end

    -- everything the client's button skinner must keep its hands off
    f.anxHeaderBtns = { goBtn, goOptBtn, refresh, closeBtn, findBtn, sfBtn,
        back, homeBtn, favBtn }
    for _, b in ipairs(chipOrder) do
        f.anxHeaderBtns[#f.anxHeaderBtns + 1] = b
    end

    tinsert(UISpecialFrames, "AttuneNextFrame")
    f:Hide()
    if UI.ApplySkin then
        UI.frame = f          -- ApplySkin needs the handle during the build
        UI.ApplySkin()
    end
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
        rowDesc.barPct = rowDesc._sPct   -- v3: progress bar on every node row
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

-- Set text on a fontstring, trimming it with an ellipsis if it would wrap.
-- (3.3.5 has no SetWordWrap, so the only reliable way is to measure.)
function UI.FitText(fs, text, maxW)
    if not fs then return end
    text = text or ""
    fs:SetText(text)
    if not (fs.GetStringWidth and maxW and maxW > 20) then return end
    if fs:GetStringWidth() <= maxW then return end
    local t = text
    for _ = 1, 60 do
        if #t <= 6 then break end
        t = t:sub(1, #t - 3)
        local try = t .. "..."
        local nc = select(2, try:gsub("|c%x%x%x%x%x%x%x%x", ""))
        local nr = select(2, try:gsub("|r", ""))
        if nc > nr then try = try .. "|r" end
        fs:SetText(try)
        if fs:GetStringWidth() <= maxW then break end
    end
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
    -- the two-pane list is narrower: keep this to one line by dropping the
    -- source name (the detail pane shows it anyway)
    local src = (not UI.narrowList) and best.srcName
    return string.format("|cffffd100Best:|r %s |cff00ff88(%s)|r%s",
        name, ANx.FormatChance(best.chance),
        src and (" |cff888888- " .. src .. "|r") or "")
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
-- ---- "What's Left" report helpers -----------------------------------
-- the whole What's Left tree follows the Attunes scope chip
local function WLScope()
    return (ANx.db.scope == "account") and "acct" or "char"
end
local function WLName()
    return (ANx.db.scope == "account") and "|cff00ccffaccount|r" or "|cff33ff99this character|r"
end

-- currency amount for display (Gold is stored in copper)
local function AmountStr(name, n)
    if name == "Gold" then
        local g = math.floor((n or 0) / 10000)
        if g >= 1 then return g .. "g" end
        return math.floor((n or 0) / 100) .. "s"
    end
    return tostring(n or 0)
end

-- ---- search types ----------------------------------------------------
local SEARCH_TYPES = { "items", "vendors", "dungeons", "raids", "profs", "quests" }
local SEARCH_LABELS = {
    items = "Attunables", vendors = "Vendors", dungeons = "Dungeons",
    raids = "Raids", profs = "Professions", quests = "Quests",
}

function UI.CycleSearchType()
    local cur = ANx.db.searchType or "items"
    for i, t in ipairs(SEARCH_TYPES) do
        if t == cur then
            ANx.db.searchType = SEARCH_TYPES[(i % #SEARCH_TYPES) + 1]
            break
        end
    end
    if UI.frame and UI.frame:IsShown() then UI.Render() end
end

-- ---- favorites -------------------------------------------------------
local FILTER_FIELDS = { "scope", "faction", "forge", "zoneExclusive", "bindFilter",
    "accessories", "difficulty", "raidSize", "raresOnly", "vendorFilter",
    "stockFilter", "affordableOnly" }

local function FilterSnapshot(viewType)
    local f = {}
    for _, k in ipairs(FILTER_FIELDS) do f[k] = ANx.db[k] end
    f.sort = ANx.db.sort and ANx.db.sort[viewType] or nil
    return f
end

local function FilterSummary(f)
    local p = {}
    if f.scope == "account" then p[#p + 1] = "Account" end
    if f.faction == "A" then p[#p + 1] = "Alliance" elseif f.faction == "H" then p[#p + 1] = "Horde" end
    if (f.forge or 1) > 1 then p[#p + 1] = "Forge " .. (ANx.FORGE_LABELS[f.forge] or f.forge) end
    if f.zoneExclusive then p[#p + 1] = "Zone-exclusive" end
    if f.bindFilter == "bop" then p[#p + 1] = "BoP" elseif f.bindFilter == "boe" then p[#p + 1] = "BoE" end
    if f.accessories == false then p[#p + 1] = "No accessories" end
    if f.difficulty and f.difficulty ~= "all" then p[#p + 1] = (ANx.DIFF_TIER_LABELS[f.difficulty] or f.difficulty) end
    if f.raidSize and f.raidSize ~= "all" then p[#p + 1] = (ANx.RAID_SIZE_LABELS[f.raidSize] or f.raidSize) end
    if f.raresOnly then p[#p + 1] = "Rares" end
    if f.stockFilter and f.stockFilter ~= "all" then p[#p + 1] = f.stockFilter .. " stock" end
    if f.affordableOnly then p[#p + 1] = "Affordable" end
    if #p == 0 then return "default filters" end
    return table.concat(p, ", ")
end

-- serializable descriptor of the current view (nil = can't be favorited)
function UI.SerializeView(view)
    if not view then return nil end
    local t = view.type
    local d = { type = t }
    if t == "browse" or t == "options" or t == "home" or t == "contentTypes" or t == "events" or t == "goals"
        or t == "whatsleft" or t == "whatsleftMats" or t == "whatsleftCur"
        or t == "anextConfig" or t == "favorites" then
        if t == "favorites" then return nil end
        return d
    elseif t == "content" or t == "profs" then
        d.exp = view.exp; return d
    elseif t == "contentExp" then
        d.content = view.content; return d
    elseif t == "instances" then
        d.exp = view.exp; d.kind = view.kind; return d
    elseif t == "zones" then
        d.exp = view.exp; d.mode = view.mode; return d
    elseif t == "whatsleftScope" then
        d.scope = view.scope; return d
    elseif t == "whatsleftMatList" then
        d.prof = view.prof; return d
    elseif t == "quests" or t == "currencies" then
        if not view.zoneEntry then return nil end
        d.zone = view.zoneEntry.zone; d.zoneName = view.zoneEntry.name; return d
    elseif t == "sources" then
        d.itemId = view.itemId; return d
    elseif t == "search" then
        d.query = UI.searchQuery; d.searchType = ANx.db.searchType; return d
    elseif t == "items" then
        if view.instMap and view.instName then
            d.instMap = view.instMap; d.instName = view.instName
            d.instDiff = view.instDiff; return d
        elseif view.profName then
            d.profName = view.profName; d.profExp = view.profExp; return d
        elseif view.vendorName and view.vendorZone then
            d.vendorName = view.vendorName; d.vendorZone = view.vendorZone
            d.vendorZoneName = view.vendorZoneName; d.vendorId = view.vendorId; return d
        elseif view.questId and view.questZone then
            d.questId = view.questId; d.questZone = view.questZone
            d.questZoneName = view.questZoneName; d.title = view.title; return d
        end
        return nil
    end
    return nil
end

local function DescKey(d, f)
    local parts = {}
    for k, v in pairs(d) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    table.sort(parts)
    local fp = {}
    for _, k in ipairs(FILTER_FIELDS) do fp[#fp + 1] = tostring(f[k]) end
    fp[#fp + 1] = tostring(f.sort)
    return table.concat(parts, "&") .. "|" .. table.concat(fp, ",")
end

function UI.FavIndexOfCurrent()
    local view = UI.Current()
    local d = UI.SerializeView(view)
    if not d then return nil end
    local key = DescKey(d, FilterSnapshot(view.type))
    for i, fav in ipairs(ANx.db.favorites or {}) do
        if fav.key == key then return i end
    end
    return nil
end

function UI.ToggleFavorite()
    local view = UI.Current()
    local d = UI.SerializeView(view)
    if not d then
        ANx.Print("This screen can't be saved as a favorite.")
        return
    end
    ANx.db.favorites = ANx.db.favorites or {}
    local filters = FilterSnapshot(view.type)
    local key = DescKey(d, filters)
    for i, fav in ipairs(ANx.db.favorites) do
        if fav.key == key then
            table.remove(ANx.db.favorites, i)
            ANx.Print("Favorite removed: " .. (fav.label or "?"))
            UI.Render()
            return
        end
    end
    local label = UI.Title and UI.Title(view) or (view.title or view.type)
    table.insert(ANx.db.favorites, {
        label = label, desc = d, filters = filters, key = key,
    })
    ANx.Print("|cffffd100Favorite saved:|r " .. label .. "  |cff888888(" .. FilterSummary(filters) .. ")|r")
    UI.Render()
end

function UI.RestoreFavorite(fav)
    -- apply the saved filters
    for _, k in ipairs(FILTER_FIELDS) do
        if fav.filters[k] ~= nil then ANx.db[k] = fav.filters[k] end
    end
    ANx.db.sort = ANx.db.sort or {}
    ANx.db.sort[fav.desc.type] = fav.filters.sort
    Engine.InvalidateStats()

    local d = fav.desc
    UI.Show(true)   -- reset to the main menu, then open the saved screen
    local t = d.type
    if t == "search" then
        ANx.db.searchType = d.searchType or "items"
        UI.searchQuery = d.query or ""
        if UI.frame and UI.frame.searchBox then
            UI._searchSetting = true
            UI.frame.searchBox:SetText(UI.searchQuery)
            UI._searchSetting = false
        end
        UI.Push({ type = "search" })
    elseif t == "quests" or t == "currencies" then
        UI.Push({ type = t, zoneEntry = { name = d.zoneName, zone = d.zone } })
    elseif t == "items" then
        if d.instMap then
            local inst = Engine.InstanceByMap(d.instMap)
            local items, seen = {}, {}
            if inst then
                for _, dd in ipairs(Engine.InstanceDiffs(inst) or {}) do
                    local ok = (d.instDiff and dd.label == d.instDiff)
                        or (not d.instDiff and ANx.DifficultyMatches(dd.label))
                    if ok then
                        for _, id in ipairs(dd.items) do
                            if not seen[id] then seen[id] = true; items[#items + 1] = id end
                        end
                    end
                end
            end
            UI.Push({ type = "items", title = d.instName, items = items,
                zoneName = d.instName, srcFilter = ANx.INSTANCE_DROP_SRC,
                instMap = d.instMap, instName = d.instName, instDiff = d.instDiff })
        elseif d.profName then
            local entries = Engine.ProfessionEntries(d.profName, d.profExp or 1)
            local ids = {}
            for _, e in ipairs(entries) do ids[#ids + 1] = e.id end
            UI.Push({ type = "items", title = d.profName .. " (" .. (ANx.EXP_SHORT[d.profExp or 1] or "?") .. ")",
                items = ids, craft = true, skillMap = entries,
                profName = d.profName, profExp = d.profExp })
        elseif d.vendorName then
            local zc = Engine.ZoneData({ name = d.vendorZoneName, zone = d.vendorZone })
            local vitems = (zc and zc.vendorByName and zc.vendorByName[d.vendorName]) or {}
            UI.Push({ type = "items", title = d.vendorName .. " (" .. (d.vendorZoneName or "?") .. ")",
                items = vitems, zoneName = d.vendorZoneName, showCost = true,
                vendorId = d.vendorId, vendorName = d.vendorName,
                vendorZone = d.vendorZone, vendorZoneName = d.vendorZoneName })
        elseif d.questId then
            local zc = Engine.ZoneData({ name = d.questZoneName, zone = d.questZone })
            local qitems = {}
            for _, q in ipairs((zc and zc.questList) or {}) do
                if q.id == d.questId then qitems = q.items break end
            end
            UI.Push({ type = "items", title = d.title or "Quest", items = qitems,
                zoneName = d.questZoneName, questId = d.questId,
                questZone = d.questZone, questZoneName = d.questZoneName })
        end
    else
        local v = { type = t, exp = d.exp, kind = d.kind, mode = d.mode,
            content = d.content, scope = d.scope, prof = d.prof, itemId = d.itemId }
        UI.Push(v)
    end
end

-- ---- goal tracking helpers ------------------------------------------
function UI.GoalTracked(key)
    for i, g in ipairs((ANx.db and ANx.db.goals) or {}) do
        if Engine.GoalKey(g) == key then return i end
    end
end

function UI.ToggleGoal(goal)
    ANx.db.goals = ANx.db.goals or {}
    local i = UI.GoalTracked(Engine.GoalKey(goal))
    if i then
        table.remove(ANx.db.goals, i)
        ANx.Print("Goal removed: " .. Engine.GoalName(goal))
    else
        table.insert(ANx.db.goals, goal)
        ANx.Print("|cff33ff99Goal added:|r " .. Engine.GoalName(goal)
            .. "  -  track it under |cffffd100Goals|r on the main menu")
    end
    if ANx.GoalHudUpdate then ANx.GoalHudUpdate() end
    UI.Render()
end

builders["root"] = function(view)
    -- kick off the background scans so counts are ready when you drill in
    for exp = 1, 3 do SummaryRow(exp, UI.RefreshIfShown) end
end

-- the Browse section: pick your entry point
builders["browse"] = function(view)
    for exp = 1, 3 do SummaryRow(exp, UI.RefreshIfShown) end
    AddRow({
        text = "|cffffd100Browse by Expansion|r",
        art = "browse",
        sub = "Classic / TBC / WotLK, then content",
        onClick = function() UI.Push({ type = "home" }) end,
    })
    AddRow({
        text = "|cffffd100Browse by Content Type|r",
        art = "filter",
        sub = "Dungeons / Raids / Quests first",
        onClick = function() UI.Push({ type = "contentTypes" }) end,
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
        local barPct
        if sum then
            local stB = Engine.UnionStats(Engine.AllContentSets(sum), "sum:" .. exp .. ":all:" .. DiffKey())
            if stB.total > 0 then barPct = stB.attuned / stB.total end
        end
        AddRow({
            text = ANx.EXP_COLORS[exp] .. ANx.EXP_NAMES[exp] .. "|r",
            sub = subText, right = rightText, barPct = barPct,
            art = EXP_ART[exp],
            onClick = function() UI.Push({ type = "content", exp = exp }) end,
        })
    end
end

-- ---------------------------------------------------------------------
-- "What's Left" report screens (totals only)
-- ---------------------------------------------------------------------
-- currency drill-down: every remaining item buyable with this currency
function UI.PushCurrencyLeft(name)
    local r = Engine.RemainingReport()
    local seen, list = {}, {}
    for _, scope in ipairs({ "char", "acct" }) do
        local ids = r.curItems[scope] and r.curItems[scope][name]
        for _, id in ipairs(ids or {}) do
            if not seen[id] then seen[id] = true; list[#list + 1] = id end
        end
    end
    UI.Push({ type = "items", title = name .. "  -  remaining buyables",
        items = list, showCost = true })
end

builders["whatsleft"] = function(view)
    -- the dashboard cards render this screen (see UI.UpdateWLPanel); the
    -- scans still need kicking so the totals fill in
    for exp = 1, 3 do SummaryRow(exp, UI.RefreshIfShown) end
    local r = Engine.RemainingReport()
    if not r.ready then
        AddRow({ text = "|cff888888Still scanning the item database - totals will fill in...|r" })
    end
end

builders["whatsleftCur"] = function(view)
    local r = Engine.RemainingReport()
    local sc = WLScope()
    local names = {}
    for _, n in ipairs(r.curNames) do
        if (r[sc].cur[n] or 0) > 0 then names[#names + 1] = n end
    end
    table.sort(names, function(a, b)
        if (a == "Gold") ~= (b == "Gold") then return b == "Gold" end -- Gold last
        local ka, kb = r[sc].cur[a] or 0, r[sc].cur[b] or 0
        if ka ~= kb then return ka > kb end
        return a < b
    end)
    for _, name in ipairs(names) do
        AddRow({
            text = name,
            right = "|cffffff00" .. AmountStr(name, r[sc].cur[name] or 0) .. "|r",
            sub = "you have " .. AmountStr(name, ANx.PlayerCurrency(name)) .. "  -  click for the item list",
            onClick = function() UI.PushCurrencyLeft(name) end,
        })
    end
    if #names == 0 then
        AddRow({ text = "|cff00ff00Nothing left to buy - no currency needed!|r" })
    end
end

builders["whatsleftScope"] = function(view)
    local scope = WLScope()
    local b = Engine.RemainingByCategory(scope)
    AddRow({ text = "|cffffd100By expansion|r" })
    for exp = 1, 3 do
        AddRow({
            text = ANx.EXP_COLORS[exp] .. ANx.EXP_NAMES[exp] .. "|r",
            right = "|cffffff00" .. (b.exps[exp] or 0) .. "|r",
            onClick = function() UI.Push({ type = "content", exp = exp }) end,
        })
    end
    AddRow({ text = "|cffffd100By content type|r" })
    for _, def in ipairs({ { "D", "Dungeons" }, { "R", "Raids" }, { "Q", "Quests" },
                           { "W", "World Drops" }, { "V", "Vendors" }, { "C", "Crafting" } }) do
        AddRow({
            text = def[2],
            right = "|cffffff00" .. (b.cats[def[1]] or 0) .. "|r",
            onClick = function() UI.Push({ type = "contentExp", content = def[1] }) end,
        })
    end
    if b.events > 0 then
        AddRow({
            text = "Events & Holidays",
            right = "|cffffff00" .. b.events .. "|r",
            onClick = function() UI.Push({ type = "events" }) end,
        })
    end
    AddRow({ text = "|cff888888Remaining counts only. Click a row to browse it with the full filters.|r" })
end

builders["whatsleftMats"] = function(view)
    local per = Engine.RemainingCraftByProf()
    local sc = WLScope()
    local any = false
    for _, p in ipairs(ANx.ProfessionOrder or {}) do
        local t = per[p]
        if t and (t[sc] or 0) > 0 then any = true break end
    end
    if not any then
        AddRow({ text = "|cff00ff00Nothing crafted left to attune!|r" })
        return
    end
    AddRow({
        text = "|cffffd100Raw materials needed (everything crafted)|r",
        sub = "Every reagent totalled across all professions. Sortable.",
        onClick = function() UI.Push({ type = "whatsleftMatList" }) end,
    })
    AddRow({ text = "|cffffd100Crafted items left by profession|r" })
    for _, p in ipairs(ANx.ProfessionOrder or {}) do
        local t = per[p]
        if t and (t[sc] or 0) > 0 then
            AddRow({
                text = p,
                right = "|cffffff00" .. t[sc] .. "|r",
                sub = "Click for just this profession's materials.",
                onClick = function() UI.Push({ type = "whatsleftMatList", prof = p }) end,
            })
        end
    end
end

builders["whatsleftMatList"] = function(view)
    local prof = view.prof
    local rows, left, unscanned = Engine.RemainingMaterials(prof)
    local sc = WLScope()
    table.sort(rows, function(a, b)
        if (a[sc] or 0) ~= (b[sc] or 0) then return (a[sc] or 0) > (b[sc] or 0) end
        return a.id < b.id
    end)
    for _, m in ipairs(rows) do
        if (m[sc] or 0) > 0 then
        local name, _, quality, tex = ANx.GetItemDisplay(m.id)
        local userList = m.users
        AddRow({
            text = QualityHex(quality or 1) .. name .. "|r",
            icon = tex,
            itemId = m.id,
            right = "|cffffff00" .. m[sc] .. "|r",
            sub = "click: the remaining items that need this",
            onClick = function()
                UI.Push({ type = "items", title = name .. "  -  needed by",
                    items = userList or {}, craft = true })
            end,
        })
        end
    end
    if #displayRows == 0 and (left[sc] or 0) > 0 then
        AddRow({ text = "|cffff8040No reagent data for these recipes|r",
            sub = "Custom recipes: open that crafting window once to record them." })
    elseif (unscanned[sc] or 0) > 0 then
        AddRow({ text = "|cffff8040" .. (unscanned[sc] or 0)
            .. " remaining recipe(s) missing reagent data|r",
            sub = "Custom recipes: open that crafting window once to add them." })
    end
    if (left[sc] or 0) == 0 then
        AddRow({ text = "|cff00ff00Nothing crafted left to attune here!|r" })
    elseif #rows > 0 then
        AddRow({ text = "|cff888888Already counted: your bags, bank and resource bank|r",
            sub = "What's missing after your stock, broken down to raw materials." })
    end
end

builders["favorites"] = function(view)
    local favs = (ANx.db and ANx.db.favorites) or {}
    if #favs == 0 then
        AddRow({ text = "|cff888888No favorites yet|r",
            sub = "Set your filters, then press Fav + up top." })
        return
    end
    for i, fav in ipairs(favs) do
        local favIndex = i
        AddRow({
            text = fav.label or "?",
            sub = "|cff888888" .. FilterSummary(fav.filters or {}) .. "|r  -  click: open, shift-click: remove",
            onClick = function()
                if IsShiftKeyDown() then
                    table.remove(ANx.db.favorites, favIndex)
                    ANx.Print("Favorite removed: " .. (fav.label or "?"))
                    UI.Render()
                else
                    UI.RestoreFavorite(fav)
                end
            end,
        })
    end
end

builders["goals"] = function(view)
    for exp = 1, 3 do SummaryRow(exp, UI.RefreshIfShown) end
    local goals = (ANx.db and ANx.db.goals) or {}
    if #goals == 0 then
        AddRow({ text = "|cff888888No goals yet|r",
            sub = "Use 'Track as a goal' on any dungeon or raid list." })
        return
    end
    for i, goal in ipairs(goals) do
        local st = Engine.GoalStatus(goal)
        local complete = st.total > 0 and st.left == 0
        if complete and not goal.congratulated then
            goal.congratulated = true
            ANx.Print("|cff00ff00Goal complete:|r " .. st.name .. "!")
        elseif not complete then
            goal.congratulated = nil
        end
        local sub
        if complete then
            sub = "Done! Shift-click to remove it."
        else
            local clears = (st.clears and st.clears > 0)
                and ("  -  ~" .. st.clears .. " clear" .. (st.clears == 1 and "" or "s") .. " to go") or ""
            local noDrop = (st.noDrop and st.noDrop > 0)
                and ("  |cff888888(+" .. st.noDrop .. " with no drop rate)|r") or ""
            sub = st.left .. " left" .. clears .. noDrop .. "  -  click: browse, shift-click: untrack"
        end
        local goalIndex = i
        AddRow({
            text = (complete and ("|cff00ff00" .. st.name .. "  -  COMPLETE!|r")
                or st.name),
            right = ANx.StatsString(st.done, st.total),
            sub = sub,
            barPct = st.pct,
            onClick = function()
                if IsShiftKeyDown() then
                    table.remove(ANx.db.goals, goalIndex)
                    ANx.Print("Goal removed: " .. st.name)
                    if ANx.GoalHudUpdate then ANx.GoalHudUpdate() end
                    UI.Render()
                elseif goal.kind == "inst" then
                    UI.Push({ type = "items", title = st.name, items = st.items or {},
                        zoneName = goal.name, srcFilter = ANx.INSTANCE_DROP_SRC,
                        instMap = goal.map, instName = goal.name, instDiff = goal.diff })
                else
                    UI.Push({ type = "instances", exp = goal.exp, kind = goal.content })
                end
            end,
        })
    end
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
            art = CONTENT_ART[def.key],
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
art = CONTENT_ART[def.key],
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
            art = EXP_ART[exp],
            right = rightText,
            onClick = function() PushContentNode(cat, exp) end,
        })
    end
end

builders["instances"] = function(view)
    local list = Engine.InstancesFor(view.exp, view.kind)
    local mode = CurrentSort(view)
    -- goal tracking for this whole content set
    do
        local label = (ANx.EXP_SHORT[view.exp] or "?") .. " "
            .. (view.kind == "D" and "Dungeons" or "Raids")
        local tracked = UI.GoalTracked("c" .. view.exp .. view.kind)
        AddRow({
            text = tracked and "|cff33ff99Tracking this set|r"
                or "|cffffd100Track this set as a goal|r",
            sub = tracked and "Click to untrack." or "Tracked under Goals.",
            onClick = function()
                UI.ToggleGoal({ kind = "content", exp = view.exp, content = view.kind })
            end,
        })
    end
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
                barPct = (st.total > 0) and (st.attuned / st.total) or nil,
                art = "thumb_" .. ArtSlug(inst.name),
                onClick = function()
                    UI.Push({ type = "items", title = title, items = d.items,
                        zoneName = inst.name, srcFilter = ANx.INSTANCE_DROP_SRC,
                        instMap = inst.map, instName = inst.name, instDiff = d.label })
                end,
            }
        else
            group.rows[1] = { text = "|cffffd100" .. inst.name .. "|r", header = true,
                art = "thumb_" .. ArtSlug(inst.name) }
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
                    barPct = (st.total > 0) and (st.attuned / st.total) or nil,
                    onClick = function()
                        UI.Push({ type = "items", title = inst.name .. " (" .. label .. ")",
                            items = d.items, zoneName = inst.name, srcFilter = ANx.INSTANCE_DROP_SRC,
                            instMap = inst.map, instName = inst.name, instDiff = d.label })
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
      if ANx.QuestNodeAllowed(q.id) then
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
                        zoneName = z.name, srcFilter = nil,
                        questId = q.id, questZone = z.zone, questZoneName = z.name })
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
                    vendorId = v.id, vendorName = v.name, vendorZone = z.zone,
                    vendorZoneName = z.name })
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
                art = ArtSlug(prof),
                onClick = function()
                    UI.Push({ type = "items", title = prof .. " (" .. ANx.EXP_SHORT[exp] .. ")",
                        items = ids, zoneName = nil, srcFilter = nil, craft = true,
                        skillMap = entries, profName = prof, profExp = exp })
                end,
            })
        end
    end
    FlushNodeRows(CurrentSort(view))
    if #displayRows == 0 then
        AddRow({ text = "|cff888888No attunable crafted items for this expansion|r" })
    end
end

-- full Options screen (gear button): mirrors the Interface Options panel,
-- then appends the AttuneNext button's own options below
builders["options"] = function(view)
    local function Sync()
        if ANx.SyncOptionsPanel then ANx.SyncOptionsPanel() end
    end
    local function optToggle(label, sub, get, set)
        local on = get() and true or false
        AddRow({
            text = label .. ":  " .. (on and "|cff00ff00On|r" or "|cffaaaaaaOff|r"),
            sub = sub,
            onClick = function() set(not on); Sync(); UI.Render() end,
        })
    end
    AddRow({ text = "|cffffd100General|r" })
    local SCALE_STEPS = { 0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0 }
    AddRow({
        text = "Window scale:  |cffffd100" .. math.floor((ANx.db.scale or 1) * 100 + 0.5) .. "%|r",
        sub = "Click to cycle 50% - 200% (also a slider in Interface Options).",
        onClick = function()
            local cur = ANx.db.scale or 1
            local nxt = SCALE_STEPS[1]
            for i, v in ipairs(SCALE_STEPS) do
                if math.abs(v - cur) < 0.01 then nxt = SCALE_STEPS[(i % #SCALE_STEPS) + 1]; break end
                if v > cur + 0.01 then nxt = v; break end
            end
            ANx.db.scale = nxt
            if UI.frame then UI.frame:SetScale(nxt) end
            Sync(); UI.Render()
        end,
    })
    optToggle("Minimap button", "The AttuneNext emblem on your minimap (drag to move it).",
        function() return ANx.db.minimapShow end,
        function(v) ANx.db.minimapShow = v; if ANx.UpdateMinimapButton then ANx.UpdateMinimapButton() end end)
    optToggle("Tooltip info", "Item tooltips show 'still needed' with the best source.",
        function() return ANx.db.tooltip end,
        function(v) ANx.db.tooltip = v end)
    optToggle("Alerts", "Warns on needed loot drops / group rolls, and when a worn item finishes attuning.",
        function() return ANx.db.alerts end,
        function(v) ANx.db.alerts = v end)
    optToggle("Zone-entry chat note", "Prints 'N attunables left in <zone>' when you change zones.",
        function() return ANx.db.zonewatch end,
        function(v) ANx.db.zonewatch = v end)
    optToggle("Instance HUD", "The what's-left window inside dungeons/raids (/an hud works too).",
        function() return ANx.db.zoneHud end,
        function(v) ANx.db.zoneHud = v; if ANx.ZoneWatchNow then ANx.ZoneWatchNow(false) end end)
    optToggle("Goal window", "On-screen progress bars for your goals (shows while you have goals).",
        function() return ANx.db.goalHud end,
        function(v) ANx.db.goalHud = v; if ANx.GoalHudNow then ANx.GoalHudNow() end end)
    do
        local mode = ANx.TimeMode()
        AddRow({
            text = "Run length:  |cffffd100" .. (ANx.TIME_MODE_LABELS[mode] or "?") .. "|r",
            sub = (mode == "off")
                and "Recommendations ignore how long a run takes."
                or ((mode == "personal")
                    and "Only instances your speed buff (or a challenge time) tells us about."
                    or ((mode == "builtin")
                        and "Uses the built-in clear-time estimates for every instance."
                        or "Built-in estimates, scaled by the speed buff you have earned there.")),
            onClick = function()
                local cur = ANx.TimeMode()
                for i, m in ipairs(ANx.TIME_MODES) do
                    if m == cur then
                        ANx.db.timeMode = ANx.TIME_MODES[(i % #ANx.TIME_MODES) + 1]
                        break
                    end
                end
                Engine.InvalidateStats()
                if ANx.SyncOptionsPanel then ANx.SyncOptionsPanel() end
                UI.Render()
            end,
        })
    end
    optToggle("Unskinned layout", "Plain frames instead of the painted art (the logo stays).",
        function() return ANx.db.classicSkin end,
        function(v)
            ANx.db.classicSkin = v
            if UI.ApplySkin then UI.ApplySkin() end
        end)
    optToggle("Debug logging", "Extra chat output for troubleshooting.",
        function() return ANx.debug end,
        function(v) ANx.debug = v end)
    AddRow({
        text = "Reset the HUD size & position",
        sub = "Puts the instance HUD back at its default spot and size.",
        onClick = function()
            if ANx.ResetHudLayout then ANx.ResetHudLayout() end
            UI.Render()
        end,
    })
    AddRow({
        text = "Reset all filters",
        sub = "All filters and sorting back to defaults.",
        onClick = function()
            ANx.db.scope = "char"; ANx.db.faction = "both"; ANx.db.forge = 1
            ANx.db.zoneExclusive = false; ANx.db.stockFilter = "all"
            ANx.db.vendorFilter = "all"; ANx.db.raresOnly = false; ANx.db.sort = {}
            Engine.InvalidateStats()
            ANx.Print("Filters reset to defaults.")
            UI.Render()
        end,
    })
    AddRow({ text = "|cffffd100The AttuneNext button|r" })
    builders["anextConfig"](view)
    AddRow({ text = "|cffffd100On-screen recommendations|r" })
    builders["recConfig"](view)
end

-- One options shape, two features: the button ("btn") and the cards ("rec").
local function ConfigRows(which)
    local a = ANx.Cfg(which)
    local isBtn = (which == "btn")
    local function toggleRow(label, key, subOn, subOff)
        local on = a[key] == true
        AddRow({
            text = label .. ":  " .. (on and "|cff00ff00On|r" or "|cffaaaaaaOff|r"),
            sub = on and subOn or subOff,
            onClick = function()
                a[key] = not on
                Engine.InvalidateStats()
                if ANx.SyncOptionsPanel then ANx.SyncOptionsPanel() end
                UI.Render()
            end,
        })
    end
    AddRow({
        text = isBtn and "|cff888888Global:|r picks from everything, wherever you are."
            or "|cff888888Context sensitive:|r follows the screen you are looking at.",
        sub = isBtn and "The button never narrows to the current screen - the cards do that."
            or "The Recommended card always draws from the category you have open.",
    })
    toggleRow("Focus the place with the most left", "focus",
        "Aims at the zone / instance / profession / currency with the most items left.",
        "Off: doesn't prioritise any one place.")
    toggleRow("Factor in drop rates", "dropRate",
        "Easiest (highest drop-rate) item first; Ignore steps to the next best.",
        "Off: every obtainable item is equally likely.")
    toggleRow("Current level filter", "level",
        "Only dungeons/raids/zones your level supports, and only items you can equip (level "
            .. ANx.CharLevel() .. ").",
        "Off: content of every level is considered.")
    do
        local cur = ANx.RunMode(which)
        AddRow({
            text = "Recommend a whole dungeon/raid/zone:  |cffffd100"
                .. (ANx.RUN_MODE_LABELS[cur] or "?") .. "|r",
            sub = (cur == "off") and ((isBtn and "Off: the AttuneNext button recommends a single item."
                    or "Off: the card recommends a single item."))
                or ((cur == "Z") and "Points you at the best ZONE to sweep (quests + world drops), with expected new attunes."
                or "Points you at the best run for this mode, with expected new attunes per clear."),
            onClick = function()
                local modes = ANx.RUN_MODES
                local c = ANx.RunMode(which)
                for i, m in ipairs(modes) do
                    if m == c then a.instance = modes[(i % #modes) + 1]; break end
                end
                Engine.InvalidateStats()
                if ANx.SyncOptionsPanel then ANx.SyncOptionsPanel() end
                UI.Render()
            end,
        })
    end
    if isBtn then
        local n = 0
        for _ in pairs(ANx.db.anext.ignore or {}) do n = n + 1 end
        for _ in pairs(ANx.db.anext.ignoreInst or {}) do n = n + 1 end
        if n > 0 then
            AddRow({
                text = "|cffff6060Reset the ignore list|r  (" .. n .. ")",
                sub = "Clears every skipped item and instance (shared with the cards).",
                onClick = function()
                    ANx.db.anext.ignore = {}
                    ANx.db.anext.ignoreInst = {}
                    Engine.InvalidateStats()
                    ANx.Print("AttuneNext ignore list cleared.")
                    UI.Render()
                end,
            })
        else
            AddRow({
                text = "|cff777777Reset the ignore list  (empty)|r",
                sub = "Nothing skipped right now.",
            })
        end
        AddRow({
            text = "|cff888888How it works|r",
            sub = "Use Ignore on a result to skip it and get the next pick.",
        })
    end
end

builders["anextConfig"] = function(view)
    ConfigRows("btn")
end

builders["recConfig"] = function(view)
    ConfigRows("rec")
end

builders["events"] = function(view)
    for _, ev in ipairs(ANx.EventList or {}) do
        local items = Engine.EventItems(ev)
        local st = Engine.StatsWithBest(items, "ev:" .. ev.name, nil, nil)
        if st.total > 0 then
            AddNodeRow(ev.name, st, {
                art = ArtSlug(ev.name),
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
    -- AttuneNext "recommend a run" header + ignore action
    if view.fromAttuneNextRun then
        AddRow({
            text = "|cffffd100" .. (view.title or "?") .. "|r",
            right = string.format("|cff00ff88~%.1f|r%s", view.runExpected or 0,
                view.zoneRun and "" or "|cff888888/clear|r"),
            sub = string.format("Recommended %s: ~%.1f new attunes%s%s  -  click: ignore",
                view.zoneRun and "zone" or "run", view.runExpected or 0,
                view.zoneRun and "" or " per clear",
                view.runTime and (", " .. string.format("%.2gx avg run", view.runTime)) or ""),
            onClick = function() UI.AttuneNextIgnoreInstance(view.instKey, view.launchedFrom, view.recCfg) end,
        })
    end
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
        elseif view.showCost then
            rightText = ""   -- vendor lists: the price is in the sub line; a drop % is meaningless
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
                elseif UI.selectedItem == r.id then
                    UI.Push({ type = "sources", itemId = r.id })  -- again = full page
                else
                    UI.SelectItem(r.id)
                end
            end,
        })
    end
    if view.instMap and view.instName then
        local inst = Engine.InstanceByMap and Engine.InstanceByMap(view.instMap)
        local diffCount = inst and #(Engine.InstanceDiffs(inst) or {}) or 1
        local dlabel = view.instDiff
        -- this exact difficulty (only meaningful on multi-difficulty instances)
        if dlabel and dlabel ~= "" then
            local pretty = DIFF_LABELS[dlabel] or dlabel
            local g = { kind = "inst", map = view.instMap, name = view.instName,
                        diff = dlabel, diffText = pretty }
            local tracked = UI.GoalTracked(Engine.GoalKey(g))
            AddRow({
                text = tracked and ("|cff33ff99Tracking (" .. pretty .. ")|r")
                    or ("|cffffd100Track " .. pretty .. " as a goal|r"),
                sub = tracked and "Click to untrack."
                    or (view.instName .. " - this difficulty only."),
                onClick = function() UI.ToggleGoal(g) end,
            })
        end
        -- the whole instance
        if diffCount > 1 or not (dlabel and dlabel ~= "") then
            local g = { kind = "inst", map = view.instMap, name = view.instName }
            local tracked = UI.GoalTracked(Engine.GoalKey(g))
            local allTag = (diffCount > 1) and " (all difficulties)" or ""
            AddRow({
                text = tracked and "|cff33ff99Tracking the whole instance|r"
                    or "|cffffd100Track the whole instance|r",
                sub = tracked and "Click to untrack."
                    or (view.instName .. allTag),
                onClick = function() UI.ToggleGoal(g) end,
            })
        end
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
        elseif ANx.ForgeLevel() <= 1 then
            AddRow({ text = "|cff00ff00Nothing left here - everything is attuned!|r" })
        else
            AddRow({ text = "|cff00ff00Everything here is already " .. (ANx.FORGE_LABELS[ANx.ForgeLevel()] or "") .. " (or can't be forged)!|r" })
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
    if not ANx.IsAttunableAtAll(itemId) then
        headParts[#headParts + 1] = "|cffff6060can't be attuned by anyone|r"
    elseif not ANx.CanCharAttune(itemId) then
        local alts = ANx.AltsWhoCanAttune and ANx.AltsWhoCanAttune(itemId)
        if alts and #alts > 0 then
            headParts[#headParts + 1] = "|cffff6060not for this character|r - |cff00ccff"
                .. ANx.AltListString(alts, 3) .. " can attune it|r"
        else
            headParts[#headParts + 1] = "|cffff6060not attunable by this character (class/armor/faction)|r"
        end
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

    -- when reached via the AttuneNext button, offer to skip this pick
    if view.fromAttuneNext then
        AddRow({
            text = "|cffff8000Ignore this item and pick another|r",
            sub = "Skips it for future AttuneNext picks (clear the list in Opt).",
            onClick = function() UI.AttuneNextIgnore(itemId) end,
        })
    end

    local sources = Engine.Sources(itemId)
    local sorted = {}
    for _, s in ipairs(sources) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b) return a.chance > b.chance end)
    for _, s in ipairs(sorted) do
        local subText = SrcTypeLabel(s.srcType) .. (s.zoneName ~= "" and ("  -  " .. s.zoneName) or "")
        local rightText = "|cff00ff88" .. ANx.FormatChance(s.chance) .. "|r"
        local rowText, rowClick = s.objName, nil
        if s.srcType == ANx.SRC.VENDOR then
            -- vendors: show price + stock instead of a drop chance
            local cost2 = ANx.CostString(itemId)
            local stockText, limited = ANx.StockString and ANx.StockString(itemId, s.objId)
            if stockText then
                subText = subText .. (limited and "  -  |cffff8000Stock: " or "  -  |cff888888Stock: ")
                    .. stockText .. "|r"
            end
            rightText = cost2 and ("|cffffd100" .. cost2 .. "|r") or "|cff888888vendor|r"
        elseif s.srcType == ANx.SRC.QUEST and s.objId then
            -- quests: click the row to drop a waypoint arrow to the quest giver
            -- (or to the next quest in the chain if this one isn't available yet).
            local hasArrow = ANx.QuestGivers and ANx.QuestGivers[s.objId] ~= nil
            local lock = ANx.GetQuestLockInfo and ANx.GetQuestLockInfo(s.objId)
            local prefix, hint = "", "click: waypoint arrow to the quest giver"
            if lock == "locked" then
                prefix = "|cffff8040[chain] |r"
                hint = "click: arrow to the next quest in the chain"
            elseif lock == "inlog" then
                prefix = "|cffffff00[in log] |r"
                hint = "click: it's already in your quest log"
            elseif lock == "completed" then
                prefix = "|cff00ff00[done] |r"
                hint = "already completed on this character"
            end
            if not ANx.CharCanDoQuest(s.objId) then
                prefix = "|cffff6060[not your race/class] |r" .. prefix
            end
            rowText = prefix .. s.objName .. (hasArrow and "  |cff33ff99>|r" or "")
            subText = subText .. "  |cff888888- " .. hint .. "|r"
            rowClick = function() ANx.SetQuestWaypoint(s.objId, s.objName) end
        elseif (s.srcType == ANx.SRC.CREATURE or s.srcType == ANx.SRC.MYTHIC_CREATURE)
            and s.objId and ANx.RareNPCs and ANx.RareNPCs[s.objId] then
            -- rare spawns: click to drop an arrow on a spawn point (cycles)
            rowText = "|cffff8000[rare]|r " .. s.objName
            if ANx.HasRareLoc and ANx.HasRareLoc(s.objId) then
                local npcId, npcName = s.objId, s.objName
                rowText = rowText .. "  |cff33ff99>|r"
                subText = subText .. "  |cff888888- click: arrow to its spawn point (click again to cycle)|r"
                rowClick = function() ANx.SetRareWaypoint(npcId, npcName) end
            end
        end
        AddRow({
            text = rowText,
            sub = subText,
            right = rightText,
            onClick = rowClick,
        })
    end
    if #sorted == 0 then
        AddRow({ text = "|cff888888No source data (loot DB not loaded?)|r" })
    end
end

-- name-search over instances (dungeons or raids), one row per difficulty
local function SearchInstances(q, kind, respect)
    local shown = 0
    for _, inst in ipairs(ANx.Instances or {}) do
        if inst.kind == kind and inst.name:lower():find(q, 1, true) then
            for _, d in ipairs(Engine.InstanceDiffs(inst) or {}) do
                if (not respect) or ANx.DifficultyMatches(d.label) then
                    local st = Engine.StatsWithBest(d.items, "i:" .. inst.map .. ":" .. d.diff,
                        inst.name, ANx.INSTANCE_DROP_SRC)
                    if st.total > 0 or not respect then
                        shown = shown + 1
                        local label = (d.label ~= "") and (DIFF_LABELS[d.label] or d.label) or nil
                        local title = inst.name .. (label and (" (" .. label .. ")") or "")
                        AddRow({
                            text = title .. "  |cff888888- " .. ANx.EXP_SHORT[inst.exp] .. "|r",
                            right = ANx.StatsString(st.attuned, st.total),
                            onClick = function()
                                UI.Push({ type = "items", title = title, items = d.items,
                                    zoneName = inst.name, srcFilter = ANx.INSTANCE_DROP_SRC,
                                    instMap = inst.map, instName = inst.name, instDiff = d.label })
                            end,
                        })
                    end
                end
            end
        end
    end
    return shown
end

local function SearchProfs(q, respect)
    local shown = 0
    for _, prof in ipairs(ANx.ProfessionOrder or {}) do
        if prof:lower():find(q, 1, true) then
            for exp = 1, 3 do
                local entries = Engine.ProfessionEntries(prof, exp)
                if #entries > 0 then
                    local ids = {}
                    for _, e in ipairs(entries) do ids[#ids + 1] = e.id end
                    local st = Engine.Stats(ids, "prof:" .. prof .. ":" .. exp)
                    if st.total > 0 or not respect then
                        shown = shown + 1
                        AddRow({
                            text = prof .. " (" .. ANx.EXP_SHORT[exp] .. ")",
                            right = ANx.StatsString(st.attuned, st.total),
                            onClick = function()
                                UI.Push({ type = "items", title = prof .. " (" .. ANx.EXP_SHORT[exp] .. ")",
                                    items = ids, craft = true, skillMap = entries,
                                    profName = prof, profExp = exp })
                            end,
                        })
                    end
                end
            end
        end
    end
    return shown
end

local function SearchVendors(q, respect)
    local shown = 0
    for _, z in ipairs(ANx.Zones or {}) do
        if shown >= 40 then break end
        local zc = Engine.ZoneData(z)
        for vname, vitems in pairs((zc and zc.vendorByName) or {}) do
            if vname:lower():find(q, 1, true) then
                local vid = zc.vendorIdByName and zc.vendorIdByName[vname]
                if (not respect) or ANx.NodeFactionAllowed("vendor", vid) then
                    local st = Engine.StatsWithBest(vitems, "sv:" .. z.zone .. ":" .. vname, z.name, nil)
                    if st.total > 0 or not respect then
                        shown = shown + 1
                        AddRow({
                            text = vname .. "  |cff888888- " .. z.name .. "|r",
                            right = ANx.StatsString(st.attuned, st.total),
                            sub = (ANx.HasVendorLoc and ANx.HasVendorLoc(vid))
                                and "click: waypoint arrow + item list" or nil,
                            onClick = function()
                                if ANx.SetVendorWaypoint then ANx.SetVendorWaypoint(vid, vname) end
                                UI.Push({ type = "items", title = vname .. " (" .. z.name .. ")",
                                    items = vitems, zoneName = z.name, showCost = true,
                                    vendorId = vid, vendorName = vname, vendorZone = z.zone,
                                    vendorZoneName = z.name })
                            end,
                        })
                    end
                end
            end
        end
    end
    return shown
end

local function SearchQuests(q, respect)
    local shown = 0
    for _, z in ipairs(ANx.Zones or {}) do
        if shown >= 40 then break end
        local zc = Engine.ZoneData(z)
        for _, qq in ipairs((zc and zc.questList) or {}) do
            if qq.name and qq.name:lower():find(q, 1, true)
                and ((not respect) or ANx.QuestNodeAllowed(qq.id)) then
                local st = Engine.Stats(qq.items, "q:" .. z.zone .. ":" .. qq.id)
                if st.total > 0 or not respect then
                    shown = shown + 1
                    local qid, qname, qitems, zref = qq.id, qq.name, qq.items, z
                    AddRow({
                        text = qname .. "  |cff888888- " .. z.name .. "|r",
                        right = ANx.StatsString(st.attuned, st.total),
                        sub = "click: waypoint arrow + rewards",
                        onClick = function()
                            ANx.SetQuestWaypoint(qid, qname)
                            UI.Push({ type = "items", title = qname, items = qitems,
                                zoneName = zref.name, questId = qid,
                                questZone = zref.zone, questZoneName = zref.name })
                        end,
                    })
                end
            end
        end
    end
    return shown
end

builders["search"] = function(view)
    local q = (UI.searchQuery or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #q < 2 then
        AddRow({ text = "|cff888888Type at least 2 letters to search...|r" })
        return
    end
    local stype = ANx.db.searchType or "items"
    if stype ~= "items" then
        local _, ready = Engine.Universe()
        if not ready then
            for exp = 1, 3 do Engine.GetSummary(exp, UI.RefreshIfShown) end
            AddRow({ text = "|cff888888Indexing in the background - try again in a moment...|r" })
            return
        end
        local respect = ANx.db.searchFilters ~= false
        local shown = 0
        if stype == "dungeons" then shown = SearchInstances(q, "D", respect)
        elseif stype == "raids" then shown = SearchInstances(q, "R", respect)
        elseif stype == "profs" then shown = SearchProfs(q, respect)
        elseif stype == "vendors" then shown = SearchVendors(q, respect)
        elseif stype == "quests" then shown = SearchQuests(q, respect)
        end
        if shown == 0 then
            AddRow({ text = "|cff888888No matches. (The Find button switches what you're searching.)|r" })
        end
        return
    end

    local universe, ready = Engine.Universe()
    if not ready then
        for exp = 1, 3 do Engine.GetSummary(exp, UI.RefreshIfShown) end
    end

    -- name matches, split by whether they pass the active filters (the same gate
    -- the item lists use) so search stays consistent with the rest of the addon:
    -- faction, bind, accessories, zone-exclusive, scope (can this char/account
    -- attune it) and the Show/forge tier.
    local respectItems = ANx.db.searchFilters ~= false
    local matches, hidden = {}, 0
    for _, id in ipairs(universe) do
        local name = ANx.GetItemDisplay(id)
        if name and name:lower():find(q, 1, true) then
            if (not respectItems) or (Engine.Eligible(id) and ANx.ForgeAllowed(id)) then
                matches[#matches + 1] = { id = id, name = name }
            else
                hidden = hidden + 1
            end
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
        local rightText
        if attuned then rightText = "|cff00ff00Attuned|r"
        elseif chance and chance > 0 then rightText = "|cff00ff88" .. ANx.FormatChance(chance) .. "|r"
        else rightText = "" end
        local subParts = {}
        if srcName then
            subParts[#subParts + 1] = SrcTypeLabel(srcType) .. ": " .. srcName
                .. (zone and zone ~= "" and (" (" .. zone .. ")") or "")
        end
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
        elseif hidden > 0 then
            AddRow({ text = "|cffff8040" .. hidden .. " item(s) match \"" .. q
                .. "\" but are hidden by your current filters (faction, bind, scope, Show, etc.).|r",
                sub = "Widen a filter to see them." })
        else
            AddRow({ text = "|cff888888No attunable items match \"" .. q .. "\"|r" })
        end
    else
        if #matches > CAP then
            AddRow({ text = "|cff888888...and " .. (#matches - CAP) .. " more - type more letters to narrow it down|r" })
        end
        if hidden > 0 then
            AddRow({ text = "|cff888888(" .. hidden .. " more match but are hidden by your current filters)|r" })
        end
    end
end

-- ---------------------------------------------------------------------
-- Breadcrumb titles
-- ---------------------------------------------------------------------
local CONTENT_LABELS = { D = "Dungeons", R = "Raids", Q = "Quests", W = "World Drops", V = "Vendors", C = "Crafting" }

local function ViewTitle(view)
    local t = view.type
    if t == "root" then return "Home" end
    if t == "options" then return "Options" end
    if t == "browse" then return "Browse"
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
    elseif t == "anextConfig" then return "AttuneNext button  -  Options"
    elseif t == "events" then return "Events & Holidays  -  Which Event?"
    elseif t == "whatsleft" then return "What's Left?  -  totals only"
    elseif t == "whatsleftScope" then
        return (view.scope == "char" and "This Character" or "Account") .. "  -  remaining by category"
    elseif t == "whatsleftMats" then
        return "Crafting  -  what's left"
    elseif t == "whatsleftMatList" then
        return (view.prof or "All professions") .. "  -  raw materials needed"
    elseif t == "whatsleftCur" then
        return "Currency needed  -  totals only"
    elseif t == "goals" then return "Goals  -  progress & estimated clears"
    elseif t == "profs" then return ANx.EXP_SHORT[view.exp] .. "  -  Which Profession?"
    elseif t == "items" then return view.title or "Items"
    elseif t == "sources" then return "Item Sources"
    elseif t == "search" then
        local lbl = ({ items = "Attunables", vendors = "Vendors", dungeons = "Dungeons",
            raids = "Raids", profs = "Professions", quests = "Quests" })[ANx.db.searchType or "items"]
        return "Search " .. (lbl or "?") .. " for \"" .. (UI.searchQuery or "") .. "\""
    elseif t == "favorites" then return "Favorites  -  saved screens & filters"
    end
    return ""
end

-- ---------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------
function UI.Render()
    EnsureEngine()
    -- a standalone simple window can own the navigation stack
    if UI.renderTarget and UI.renderTarget.Render then
        return UI.renderTarget.Render()
    end
    local f = UI.frame
    if not f or not f:IsShown() then return end
    local view = UI.Current()
    if not view then return end

    -- keep the client's injected button skin dead (see StripEngineSkin)
    if UI.StripEngineSkin and f.anxHeaderBtns then
        for _, b in ipairs(f.anxHeaderBtns) do UI.StripEngineSkin(b) end
    end

    -- the root screen is the card dashboard; everything else is the list
    if f.homePanel then
        if view.type == "root" then
            f.homePanel:Show()
            if UI.UpdateHomePanel then UI.UpdateHomePanel() end
        else
            f.homePanel:Hide()
        end
    end

    -- What's Left is its own dashboard
    if f.wlPanel then
        if view.type == "whatsleft" then
            f.wlPanel:Show()
            if UI.UpdateWLPanel then UI.UpdateWLPanel() end
        else
            f.wlPanel:Hide()
        end
    end

    -- browse screens get the detail column beside the list
    local wantPane = SIDE_PANE_VIEWS[view.type] and true or false
    if f.sidePane then
        if wantPane then
            f.sidePane:Show()
            if UI.UpdateSidePane then UI.UpdateSidePane() end
        else
            f.sidePane:Hide()
        end
    end
    UI.ApplyListWidth(wantPane)

    ResetRows()
    local builder = builders[view.type]
    if builder then builder(view) end

    UI.Title = ViewTitle
    -- breadcrumb: short path through the stack, current segment in gold
    local NAV_SHORT = {
        root = "Home", browse = "Browse", home = "Expansions",
        contentTypes = "Content Types",
        whatsleft = "What's Left", whatsleftScope = "Breakdown",
        whatsleftMats = "Crafting", whatsleftMatList = "Materials",
        whatsleftCur = "Currency", favorites = "Favorites", goals = "Goals",
        options = "Options", anextConfig = "AttuneNext Options", search = "Search",
        sources = "Item", events = "Events",
    }
    local function CrumbLabel(v)
        local t = v.type
        if NAV_SHORT[t] then return NAV_SHORT[t] end
        if t == "content" then return ANx.EXP_SHORT[v.exp] or "?" end
        if t == "contentExp" then return CONTENT_LABELS[v.content] or "Content" end
        if t == "instances" then
            return (ANx.EXP_SHORT[v.exp] or "?") .. " " .. (v.kind == "D" and "Dungeons" or "Raids")
        end
        if t == "zones" then
            return (v.mode == "Q" and "Quests") or (v.mode == "W" and "World Drops") or "Zones"
        end
        if t == "quests" or t == "currencies" then
            return (v.zoneEntry and v.zoneEntry.name) or "Zone"
        end
        if t == "vendors" then return v.currency or "Vendors" end
        if t == "profs" then return "Crafting" end
        if t == "items" then return v.title or "Items" end
        return ViewTitle(v)
    end
    do
        local parts, idxs = {}, {}
        for i, v in ipairs(UI.stack) do
            local lbl = CrumbLabel(v)
            if #lbl > 26 then lbl = lbl:sub(1, 24) .. "..." end   -- keep segments short
            parts[#parts + 1] = lbl
            idxs[#idxs + 1] = i
        end
        local trimmed = false
        while #parts > 4 do
            table.remove(parts, 1); table.remove(idxs, 1); trimmed = true
        end
        -- and drop leading segments until the row actually fits the frame
        local budget = FRAME_W - 232 - 30
        local function CrumbWidth()
            local w = 0
            for i = 1, #parts do w = w + #parts[i] * 6.2 + 24 end
            return w + (trimmed and 34 or 0)
        end
        while #parts > 1 and CrumbWidth() > budget do
            table.remove(parts, 1); table.remove(idxs, 1); trimmed = true
        end
        -- text mirror (hidden; kept for tests/debug)
        do
            local mirror = {}
            for i = 1, #parts do mirror[i] = parts[i] end
            f.crumb:SetText((trimmed and "... > " or "") .. table.concat(mirror, " > "))
        end
        -- clickable segments: click any level to jump straight back to it
        local x = (#UI.stack > 1) and (CX + 232) or (CX + 16)
        for i = 1, #parts do
            local cb = UI.CrumbButton(i)
            local last = (i == #parts)
            local label = (i == 1 and trimmed) and ("... > " .. parts[i]) or parts[i]
            cb.anxLabel:SetText(last and ("|cffffd100" .. label .. "|r")
                or ("|cffbfae86" .. label .. "|r"))
            local w = (cb.anxLabel.GetStringWidth and cb.anxLabel:GetStringWidth())
                or (#label * 7)
            cb:SetWidth(math.max(w, 8))
            if cb.ClearAllPoints then cb:ClearAllPoints() end
            cb:SetPoint("TOPLEFT", f, "TOPLEFT", math.floor(x + 0.5), -58)
            cb.anxStackIndex = idxs[i]
            if last then cb:Disable() else cb:Enable() end
            cb:Show()
            x = x + w
            local sep = f.crumbSeps[i]
            if not last then
                if not sep then
                    sep = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                    sep:SetJustifyH("LEFT")
                    f.crumbSeps[i] = sep
                end
                sep:SetText("|cff8a7a55>|r")
                if sep.ClearAllPoints then sep:ClearAllPoints() end
                sep:SetPoint("LEFT", cb, "RIGHT", 6, 0)
                if sep.Show then sep:Show() end
                x = x + 18
            elseif sep and sep.Hide then
                sep:Hide()
            end
        end
        for i = #parts + 1, #f.crumbBtns do
            f.crumbBtns[i]:Hide()
            if f.crumbSeps[i] and f.crumbSeps[i].Hide then f.crumbSeps[i]:Hide() end
        end
    end

    -- sidebar: highlight the active section
    local NAV_OF = {
        root = "home", browse = "browse", home = "browse", content = "browse",
        contentTypes = "browse",
        contentExp = "browse", instances = "browse", zones = "browse", quests = "browse",
        currencies = "browse", vendors = "browse", profs = "browse", events = "browse",
        items = "browse", sources = "browse", search = "browse",
        anextConfig = "options", options = "options",
        whatsleft = "whatsleft", whatsleftScope = "whatsleft", whatsleftMats = "whatsleft",
        whatsleftMatList = "whatsleft", whatsleftCur = "whatsleft",
        favorites = "favorites", goals = "goals",
    }
    local activeNav = NAV_OF[view.type] or "browse"
    for key, nb in pairs(f.navButtons or {}) do
        local active = (key == activeNav)
        if nb.anxActive then
            if active then nb.anxActive:Show() else nb.anxActive:Hide() end
        end
        nb:SetText((active and "|cff33ff99" or "|cffe3c98f") .. nb._navLabel .. "|r")
    end
    -- Back/Home do nothing on the home screen - hide them there and let
    -- the breadcrumb slide to the left edge
    if #UI.stack > 1 then
        f.back:Show(); f.homeBtn:Show()
    else
        f.back:Hide(); f.homeBtn:Hide()
    end

    -- favorite button: only on screens that can be saved
    if UI.SerializeView(view) then
        local isFav = UI.FavIndexOfCurrent()
        UI.SetBtnText(f.favBtn, isFav and "|cff33ff99Fav -|r" or "|cffe3c98fFav +|r")
        if f.favBtn.anxChipIcon and UI.SetIconArt then
            UI.SetIconArt(f.favBtn.anxChipIcon, isFav and "favorite_remove" or "favorite_add", 15)
        end
        f.favBtn:Show()
    else
        f.favBtn:Hide()
    end
    -- ---------- chips: value-first labels, one color per filter ----------
    local function SetChip(b, iconKey, text)
        if b.anxIconKey ~= iconKey then
            b.anxIconKey = iconKey
            if b.anxChipIcon then
                if UI.SetIconArt and UI.SetIconArt(b.anxChipIcon, iconKey, 18) then
                    b.anxChipIcon:Show()
                else
                    b.anxChipIcon:Hide()
                end
            end
        end
        if b.anxLabel then b.anxLabel:SetText(text) end
    end

    -- Find/Filters by the search bar: sidebar-style icon + warm label,
    -- the Find icon follows the search type
    local sType = ANx.db.searchType or "items"
    local FIND_ICON = { items = "attunement", vendors = "vendors",
        dungeons = "dungeons", raids = "raids", profs = "crafting", quests = "quests" }
    SetChip(f.findBtn, FIND_ICON[sType] or "attunement",
        "|cffe3c98fFind: " .. (({ items = "Attunables", vendors = "Vendors",
        dungeons = "Dungeons", raids = "Raids", profs = "Professions",
        quests = "Quests" })[sType] or "?") .. "|r")
    SetChip(f.searchFiltersBtn, "filter", (ANx.db.searchFilters ~= false)
        and "|cffe3c98fFilters: |cff33ff99On|r" or "|cffe3c98fFilters: |cffff8000Off|r")

    -- always available
    if ANx.db.scope == "account" then
        SetChip(f.scopeBtn, "account", "|cff7fd4ffAccount|r")
    else
        SetChip(f.scopeBtn, "character", "|cfff2e2c4Character|r")
    end
    local fac = ANx.db.faction or "both"
    if fac == "A" then
        SetChip(f.factionBtn, "faction_alliance", "|cff6f9fffAlliance|r")
    elseif fac == "H" then
        SetChip(f.factionBtn, "faction_horde", "|cffff5545Horde|r")
    else
        SetChip(f.factionBtn, "faction_neutral", "|cffd8c8a8Both factions|r")
    end
    SetChip(f.forgeBtn, "attunement",
        "|cff2ee6c8" .. (ANx.FORGE_LABELS[ANx.ForgeLevel()] or "?") .. "|r")
    local bf = ANx.db.bindFilter or "both"
    SetChip(f.bindBtn, "bind", "|cffab8aff" .. ((bf == "bop") and "BoP only"
        or (bf == "boe") and "BoE only" or "Both binds") .. "|r")
    SetChip(f.accBtn, "accessories", "|cff58dd66" .. (ANx.db.accessories ~= false
        and "Accessories On" or "Accessories Off") .. "|r")
    SetChip(f.zexBtn, "zone_exclusive", "|cffff9d45" .. (ANx.db.zoneExclusive
        and "Zone-excl. On" or "Zone-excl. Off") .. "|r")

    -- per-view chips
    if ViewSortModes(view) then
        local sm = CurrentSort(view)
        SetChip(f.sortBtn, "sort",
            "|cff62b8ffSort: " .. (SORT_SHORT[sm] or SORT_LABELS[sm] or "?") .. "|r")
        f.sortBtn:Show()
    else
        f.sortBtn:Hide()
    end
    if ViewHasDifficulty(view) then
        local d = ANx.db.difficulty or "all"
        SetChip(f.diffBtn, "difficulty", "|cffffd24a" .. ((d == "all")
            and "Any difficulty" or (ANx.DIFF_TIER_LABELS[d] or "?")) .. "|r")
        f.diffBtn:Show()
    else
        f.diffBtn:Hide()
    end
    if ViewHasRaidSize(view) then
        local sz = ANx.db.raidSize or "all"
        SetChip(f.sizeBtn, "raid_size", "|cffff87c8" .. ((sz == "all")
            and "Any raid size" or (ANx.RAID_SIZE_LABELS[sz] or "?")) .. "|r")
        f.sizeBtn:Show()
    else
        f.sizeBtn:Hide()
    end
    if ViewHasVendorFilter(view) then
        local vf = ANx.db.vendorFilter or "all"
        local VC = { all = "All currencies", gold = "Gold vendors",
            points = "Honor & Arena", emblem = "Emblem vendors", token = "Token vendors" }
        SetChip(f.filterBtn, "currency", "|cffffd24a" .. (VC[vf] or "?") .. "|r")
        f.filterBtn:Show()
    else
        f.filterBtn:Hide()
    end
    if ViewIsWorldDrop(view) then
        SetChip(f.raresBtn, "rare_spawn", "|cffff6a70" .. (ANx.db.raresOnly
            and "Rares only" or "All spawns") .. "|r")
        f.raresBtn:Show()
    else
        f.raresBtn:Hide()
    end
    if ViewHasStockFilter(view) then
        local sf = ANx.db.stockFilter or "all"
        SetChip(f.stockBtn, "stock", "|cffff87c8" .. ((sf == "limited")
            and "Limited stock" or (sf == "unlimited") and "Unlimited stock"
            or "All stock") .. "|r")
        f.stockBtn:Show()
        SetChip(f.affordBtn, "affordable", "|cffc9f05a" .. (ANx.db.affordableOnly
            and "Affordable only" or "Any price") .. "|r")
        f.affordBtn:Show()
    else
        f.stockBtn:Hide()
        f.affordBtn:Hide()
    end
    UI.LayoutChips()

    if not ANx.LootDbLoaded() then
        f.status:SetText("|cffff4040Loot DB not loaded - lists will be empty (see /an help)|r")
    elseif Engine.scanning then
        f.status:SetText("|cffffd100Scanning loot database...|r")
    else
        f.status:SetText("")
    end

    local total = #displayRows
    FauxScrollFrame_Update(f.scroll, total, VISIBLE_ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(f.scroll)

    for i = 1, VISIBLE_ROWS do
        local b = rowButtons[i]
        local r = displayRows[i + offset]
        if r then
            UI.FitText(b.text, r.text or "", b.anxTextW)
            UI.FitText(b.sub, r.sub or "", (b.anxTextW or 200) * 2 - 16)
            b.right:SetText(r.right or "")
            b.right2:SetText(r.right2 or "")
            local tx = 46
            if r.art and UI.SetIconArt and UI.SetIconArt(b.icon, r.art, 26) then
                b.icon:Show()
            elseif r.icon then
                if ANx.ClearArtCoords then ANx.ClearArtCoords(b.icon) end
                b.icon:SetTexture(r.icon)
                b.icon:SetWidth(26); b.icon:SetHeight(26)
                b.icon:Show()
            else
                b.icon:Hide()
                tx = 16
            end
            if (r.sub or "") == "" then
                b.text:SetPoint("TOPLEFT", tx, -16)
            else
                b.text:SetPoint("TOPLEFT", tx, -6)
                b.sub:SetPoint("TOPLEFT", tx, -22)
            end
            if r.barPct then
                local w = math.floor((r.barPct or 0) * (b.anxBarW or (FRAME_W - 200)) + 0.5)
                b.bar:SetWidth(w > 1 and w or 1)
                local fillKey = (r.barPct >= 1) and "progress_fill_gold" or "progress_fill_teal"
                if not (UI.SetArtTrimmed and UI.SetArtTrimmed(b.bar, fillKey)) then
                    b.bar:SetTexture(0.15, 0.85, 0.5, 0.45)
                end
                if not (UI.SetArtTrimmed and UI.SetArtTrimmed(b.barTrack, "progress_track")) then
                    b.barTrack:SetTexture(0.09, 0.09, 0.12, 0.8)
                end
                b.barTrack:SetWidth(b.anxBarW or (FRAME_W - 200))
                b.barTrack:Show()
                b.bar:Show()
            else
                b.bar:Hide()
                b.barTrack:Hide()
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
    if ANx.CloseSimpleWindows then ANx.CloseSimpleWindows() end
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

-- AttuneNext: pick a recommended next item (per the button's config) and open
-- its source detail. (WoW's Lua has no math.randomseed; math.random is already
-- seeded by the client.)
-- format a difficulty label suffix, e.g. " (25 Heroic)"
-- "0.3x avg run" / "2.5x avg run": how long this clear takes vs the average
function UI.TimeTag(r)
    if ANx.TimeMode and ANx.TimeMode() == "off" then return "" end
    local t = r and r.time
    if not t or t <= 0 then return "" end
    local map = r.inst and r.inst.map
    local lbl = r.d and r.d.label
    local measured = map and ANx.MeasuredRunSeconds and ANx.MeasuredRunSeconds(map, lbl)
    if measured then
        local pct = ANx.SpeedPct and ANx.SpeedPct(map, lbl)
        if pct then
            return string.format("~%s at %d%% speed", ANx.FormatRunTime(measured), pct)
        end
        return string.format("challenge %s", ANx.FormatRunTime(measured))
    end
    return string.format("%.2gx avg run", t)
end

local function RunLabel(d)
    if not d or d.label == "" then return "" end
    return " (" .. (DIFF_LABELS[d.label] or d.label) .. ")"
end

-- Rows and the scroll frame shrink when the detail column is visible.
function UI.ApplyListWidth(withPane)
    local f = UI.frame
    if not f then return end
    local side = withPane and (SIDE_W + 14) or 0
    local rowW = FRAME_W - 56 - side
    if f.anxListSide == side then return end
    f.anxListSide = side
    local reserve = withPane and 158 or 250   -- room for the right-hand stats
    for _, b in ipairs(rowButtons) do
        b:SetWidth(rowW)
        b.anxTextW = rowW - reserve - 46
        b.text:SetWidth(rowW - reserve)
        b.sub:SetWidth(rowW - reserve)
        b.anxBarW = rowW - 46 - (reserve - 14)
        b.barTrack:SetWidth(b.anxBarW)
        if UI.LayoutCard then UI.LayoutCard(b, rowW, ROW_H - 2) end
    end
    UI.narrowList = withPane
    if f.scroll and f.scroll.ClearAllPoints then
        f.scroll:ClearAllPoints()
        f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", CX + 16, -154)
        f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36 - side, 38)
    end
end

-- ---------------------------------------------------------------------
-- Home panel: live "what would AttuneNext do" + expansion stats + goals
-- ---------------------------------------------------------------------
function UI.UpdateHomePanel()
    local f = UI.frame
    local hp = f and f.homePanel
    if not hp then return end
    local rec, view = hp.rec, UI.Current()

    -- recommendation preview (never navigates - Show Me / clicking does)
    local mode = ANx.RunMode("rec")
    local have = false
    if mode ~= "off" then
        -- cached ranking if we have one, otherwise rank in the background and
        -- refresh when it lands (opening a screen must never hitch)
        local runs = Engine.RunsCached(view, mode, "rec")
        if not runs then
            -- ranking before the scans finish would be redone every time a
            -- summary lands, which is what made login sluggish
            if Engine.SummariesReady() then
                Engine.RankRunsAsync(view, mode, function() UI.RefreshIfShown() end, "rec")
            end
            runs = {}
        end
        local r = runs[1]
        if r then
            have = true
            if r.zone then
                rec.anxIconKey = EXP_ART[r.zone.exp or 1]
                UI.SetIconArt(rec.icon, rec.anxIconKey, 68)
                rec.title:SetText("|cffffd100" .. r.zone.name .. "|r")
                rec.line1:SetText("|cffbfae86Zone sweep|r  -  quests + world drops")
                rec.line2:SetText(string.format("|cff00ff88~%.1f new attunes|r  -  %d items left",
                    r.expected, r.count))
            else
                local thumb = "thumb_" .. ArtSlug(r.inst.name)
                rec.anxIconKey = (ANx.Art and ANx.Art[thumb]) and thumb or "dungeons"
                UI.SetIconArt(rec.icon, rec.anxIconKey, 68)
                rec.title:SetText("|cffffd100" .. r.inst.name .. RunLabel(r.d) .. "|r")
                rec.line1:SetText("|cffbfae86Best run|r  -  "
                    .. string.format("|cff00ff88~%.1f per clear|r  |cff888888(%s)|r",
                        r.expected, UI.TimeTag(r)))
                rec.line2:SetText(r.count .. " items left in there")
            end
            rec.icon:Show()
        end
    else
        local id = Engine.AttuneNextPick(view, { cfg = "rec" })
        if id then
            have = true
            local name, _, quality, tex = ANx.GetItemDisplay(id)
            rec.anxIconKey = nil
            if ANx.ClearArtCoords then ANx.ClearArtCoords(rec.icon) end
            rec.icon:SetTexture(tex)
            rec.icon:SetWidth(68); rec.icon:SetHeight(68)
            rec.icon:Show()
            rec.title:SetText(QualityHex(quality or 1) .. name .. "|r")
            local chance, srcName, srcType, _, zname = Engine.BestSource(id)
            rec.line1:SetText("|cffbfae86Source:|r  " .. (zname and zname ~= "" and zname or "?")
                .. (srcName and ("  -  " .. srcName) or ""))
            if chance and chance > 0 then
                rec.line2:SetText("|cffbfae86Drop chance:|r  |cff00ff88" .. ANx.FormatChance(chance) .. "|r")
            else
                rec.line2:SetText("|cffbfae86" .. (SrcTypeLabel(srcType) or "Source") .. "|r")
            end
        end
    end
    if not have then
        rec.icon:Hide()
        rec.anxIconKey = nil
        if mode ~= "off" and not Engine.RunsCached(view, mode, "rec") then
            rec.title:SetText(Engine.SummariesReady()
                and "|cff888888Finding the best run...|r"
                or "|cff888888Scanning the item database...|r")
            rec.line1:SetText("")
            rec.line2:SetText("")
        elseif Engine.scanning then
            rec.title:SetText("|cff888888Scanning the item database...|r")
            rec.line1:SetText("Recommendations appear when the scan finishes.")
        else
            rec.title:SetText("|cff888888Nothing to recommend|r")
            rec.line1:SetText("Try loosening the filters or the AttuneNext options (gear).")
        end
        rec.line2:SetText("")
    end

    -- expansion cards
    for e = 1, 3 do
        local c = hp.exp[e]
        c.name:SetText(ANx.EXP_COLORS[e] .. ANx.EXP_NAMES[e] .. "|r")
        local sum = SummaryRow(e, UI.RefreshIfShown)
        if sum then
            local st = Engine.UnionStats(Engine.AllContentSets(sum), "sum:" .. e .. ":all:" .. DiffKey())
            local pct = (st.total > 0) and (st.attuned / st.total) or 0
            c.pct:SetText(ANx.EXP_COLORS[e] .. math.floor(pct * 100 + 0.5) .. "%|r")
            c.line:SetText("|cff33ff99" .. st.attuned .. "|r attuned  -  |cffffff00"
                .. (st.total - st.attuned) .. "|r left")
            local w = math.floor(pct * (c.trackW or 100) + 0.5)
            c.bar:SetWidth(w > 1 and w or 1)
            local fillKey = (pct >= 1) and "progress_fill_gold" or "progress_fill_teal"
            if not (UI.SetArtTrimmed and UI.SetArtTrimmed(c.bar, fillKey)) then
                c.bar:SetTexture(0.15, 0.85, 0.5, 0.45)
            end
            c.bar:Show()
        else
            c.pct:SetText("|cff888888...|r")
            c.line:SetText("|cff888888Scanning...|r")
            c.bar:Hide()
        end
    end

    -- goals
    local gc = hp.goals
    local goals = (ANx.db and ANx.db.goals) or {}
    -- compact rows (44px pitch), the block centered in the card's body so
    -- one or two goals sit balanced instead of drifting apart
    local shown = math.min(#goals, 4)
    if shown == 0 then shown = 1 end
    local BODY, PITCH = 176, 44
    local top = -44 - math.floor((BODY - shown * PITCH) / 2)
    local PAD = hp.pad or 30
    local function PlaceGoalRow(gr, i)
        local y = top - (i - 1) * PITCH
        gr.name:SetPoint("TOPLEFT", gc, "TOPLEFT", PAD, y)
        gr.right:SetPoint("TOPRIGHT", gc, "TOPRIGHT", -PAD, y)
        gr.track:SetPoint("TOPLEFT", gc, "TOPLEFT", PAD, y - 19)
        gr.bar:SetPoint("TOPLEFT", gc, "TOPLEFT", PAD, y - 19)
    end
    local n = 0
    for i, goal in ipairs(goals) do
        if n >= 4 then break end
        local st = Engine.GoalStatus(goal)
        n = n + 1
        local gr = gc.rows[n]
        PlaceGoalRow(gr, n)
        local complete = st.total > 0 and st.left == 0
        gr.name:SetText((complete and "|cff00ff00" or "|cffffffff") .. st.name .. "|r")
        if #goals > 4 and n == 4 then
            gr.right:SetText("|cffbfae86+" .. (#goals - 3) .. " more...|r")
        else
            gr.right:SetText(complete and "|cff00ff00done!|r"
                or (st.done .. " / " .. st.total))
        end
        local pct = st.pct or 0
        local w = math.floor(pct * (gr.trackW or 100) + 0.5)
        gr.bar:SetWidth(w > 1 and w or 1)
        if not (UI.SetArtTrimmed and UI.SetArtTrimmed(gr.bar, complete and "progress_fill_gold" or "progress_fill_teal")) then
            gr.bar:SetTexture(0.15, 0.85, 0.5, 0.45)
        end
        if gr.track.Show then gr.track:Show() end
        gr.bar:Show()
    end
    if n == 0 then
        local gr = gc.rows[1]
        PlaceGoalRow(gr, 1)
        gr.name:SetText("|cff888888No goals tracked yet - use 'Track as a goal' on any dungeon or raid list.|r")
        gr.right:SetText("")
        gr.bar:Hide()
        if gr.track.Hide then gr.track:Hide() end
        n = 1
    end
    for i = n + 1, 4 do
        local gr = gc.rows[i]
        gr.name:SetText(""); gr.right:SetText("")
        gr.bar:Hide()
        if gr.track.Hide then gr.track:Hide() end
    end
end

-- ---------------------------------------------------------------------
-- Public helpers for the standalone "simple" windows (/an browse etc.):
-- they reuse the very same builders and filters as the main window.
-- ---------------------------------------------------------------------
function UI.BuildRows(view)
    EnsureEngine()
    ResetRows()
    local builder = builders[view.type]
    if builder then builder(view) end
    local out = {}
    for i, r in ipairs(displayRows) do out[i] = r end
    return out
end

-- Filter buttons that apply to a view: { label = , click = }
function UI.FilterDefs(view)
    EnsureEngine()
    local out = {}
    local function add(label, fn)
        out[#out + 1] = { label = label, click = function()
            fn()
            Engine.InvalidateStats()
        end }
    end
    add("Attunes: " .. ((ANx.db.scope == "account") and "Account" or "Character"), function()
        ANx.db.scope = (ANx.db.scope == "account") and "char" or "account"
    end)
    local fac = ANx.db.faction or "both"
    add("Faction: " .. ((fac == "A") and "Alliance" or (fac == "H") and "Horde" or "Both"), function()
        local c = ANx.db.faction or "both"
        ANx.db.faction = (c == "both") and "A" or (c == "A") and "H" or "both"
    end)
    add("Forge: " .. (ANx.FORGE_LABELS[ANx.ForgeLevel()] or "?"), function()
        ANx.db.forge = (ANx.ForgeLevel() % 4) + 1
    end)
    local bf = ANx.db.bindFilter or "both"
    add("Bind: " .. ((bf == "bop") and "BoP" or (bf == "boe") and "BoE" or "Both"), function()
        local c = ANx.db.bindFilter or "both"
        ANx.db.bindFilter = (c == "both") and "bop" or (c == "bop") and "boe" or "both"
    end)
    add("Accessories: " .. ((ANx.db.accessories ~= false) and "On" or "Off"), function()
        ANx.db.accessories = not (ANx.db.accessories ~= false)
    end)
    add("Zone-excl: " .. (ANx.db.zoneExclusive and "On" or "Off"), function()
        ANx.db.zoneExclusive = not ANx.db.zoneExclusive
    end)
    if ViewHasDifficulty(view) then
        local d = ANx.db.difficulty or "all"
        add("Difficulty: " .. (ANx.DIFF_TIER_LABELS[d] or "All"), function()
            local order = { "all", "normal", "heroic", "mythic" }
            local c = ANx.db.difficulty or "all"
            for i, v in ipairs(order) do
                if v == c then ANx.db.difficulty = order[(i % #order) + 1]; break end
            end
        end)
    end
    if ViewHasRaidSize(view) then
        local sz = ANx.db.raidSize or "all"
        add("Size: " .. (ANx.RAID_SIZE_LABELS[sz] or "All"), function()
            local order = { "all", "10", "25" }
            local c = ANx.db.raidSize or "all"
            for i, v in ipairs(order) do
                if v == c then ANx.db.raidSize = order[(i % #order) + 1]; break end
            end
        end)
    end
    if ViewHasVendorFilter(view) then
        add("Currency: " .. (VENDOR_FILTER_LABELS[ANx.db.vendorFilter or "all"] or "All"),
            CycleVendorFilter)
    end
    if ViewHasStockFilter(view) then
        local sf = ANx.db.stockFilter or "all"
        add("Stock: " .. ((sf == "limited") and "Limited" or (sf == "unlimited") and "Unlimited" or "All"), function()
            local c = ANx.db.stockFilter or "all"
            ANx.db.stockFilter = (c == "all") and "limited" or (c == "limited") and "unlimited" or "all"
        end)
        add("Affordable: " .. (ANx.db.affordableOnly and "On" or "Off"), function()
            ANx.db.affordableOnly = not ANx.db.affordableOnly
            ANx.InvalidatePlayerCurrency()
        end)
    end
    if ViewIsWorldDrop(view) then
        add("Rares only: " .. (ANx.db.raresOnly and "On" or "Off"), function()
            ANx.db.raresOnly = not ANx.db.raresOnly
        end)
    end
    if ViewSortModes(view) then
        add("Sort: " .. (SORT_LABELS[CurrentSort(view)] or "?"), function()
            CycleSort(view)
        end)
    end
    return out
end

function UI.ViewTitleOf(view)
    return (UI.Title and UI.Title(view)) or (view and view.title) or "?"
end

-- ---------------------------------------------------------------------
-- Layout switch: painted (default) <-> unskinned (plain frames, no art).
-- The AttuneNext logo and sidebar emblem stay painted in both.
-- ---------------------------------------------------------------------
local CLASSIC_BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

function UI.ApplySkin()
    local f = UI.frame
    if not f then return end
    local painted = UI.ArtOn and UI.ArtOn()

    -- window chrome: painted corners vs the plain gold border
    for _, t in ipairs(f.anxChrome or {}) do
        if painted then t:Show() else t:Hide() end
    end
    if f.SetBackdropBorderColor then
        if painted and #(f.anxChrome or {}) > 0 then
            f:SetBackdropBorderColor(0, 0, 0, 0)
        else
            f:SetBackdropBorderColor(0.45, 0.38, 0.25, 1)
        end
    end
    if f.anxDivider then
        if painted and ANx.Art and ANx.Art.divider_vertical then
            f.anxDivider:SetWidth(6)
            ANx.SetArt(f.anxDivider, "divider_vertical")
        else
            if ANx.ClearArtCoords then ANx.ClearArtCoords(f.anxDivider) end
            f.anxDivider:SetWidth(1)
            f.anxDivider:SetTexture(0.45, 0.38, 0.25, 0.7)
        end
    end

    -- search field
    for _, t in ipairs(f.anxFieldSlices or {}) do
        if painted and ANx.Art and ANx.Art.search_field then
            t:SetTexture(ANx.ART_PATH .. ANx.Art.search_field[1])
            if t.SetTexCoord and t.anxUV then
                t:SetTexCoord(t.anxUV[1], t.anxUV[2], 0.5771, 0.6738)
            end
        else
            if ANx.ClearArtCoords then ANx.ClearArtCoords(t) end
            t:SetTexture(0.10, 0.10, 0.13, 0.9)
        end
    end

    -- buttons + chips: painted plates vs Blizzard panel buttons
    for _, b in ipairs(UI.skinButtons or {}) do
        if b.anxPlate then
            local key = b.anxPlate.anxKey or "button_normal"
            if painted and ANx.Art and ANx.Art[key] then
                b.anxPlate:SetTexture(ANx.ART_PATH .. ANx.Art[key][1])
                if UI.SetArtTrimmed then UI.SetArtTrimmed(b.anxPlate, key) end
            else
                if ANx.ClearArtCoords then ANx.ClearArtCoords(b.anxPlate) end
                b.anxPlate:SetTexture("Interface\\Buttons\\UI-Panel-Button-Up")
                if b.anxPlate.SetTexCoord then b.anxPlate:SetTexCoord(0, 0.625, 0, 0.6875) end
            end
        end
        if b.anxHover then
            if painted and ANx.Art and ANx.Art.button_hover then
                b.anxHover:SetTexture(ANx.ART_PATH .. ANx.Art.button_hover[1])
                if UI.SetArtTrimmed then UI.SetArtTrimmed(b.anxHover, "button_hover") end
            else
                if ANx.ClearArtCoords then ANx.ClearArtCoords(b.anxHover) end
                b.anxHover:SetTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
                if b.anxHover.SetTexCoord then b.anxHover:SetTexCoord(0, 0.625, 0, 0.6875) end
            end
        end
        -- pack icons on chips/buttons disappear in classic
        for _, ic in ipairs({ b.anxChipIcon, b.anxIcon }) do
            if ic then
                if painted and b.anxIconKey and UI.SetIconArt then
                    if UI.SetIconArt(ic, b.anxIconKey, ic.anxBox or 18) then ic:Show() else ic:Hide() end
                elseif painted then
                    ic:Show()
                else
                    ic:Hide()
                end
            end
        end
    end

    -- nav entries: icons + the active chip are art
    for _, nb in pairs(f.navButtons or {}) do
        if nb.anxNavIcon then
            if painted and UI.SetIconArt and nb.anxNavKey
               and UI.SetIconArt(nb.anxNavIcon, nb.anxNavKey, 24) then
                nb.anxNavIcon:Show()
            else
                nb.anxNavIcon:Hide()
            end
        end
    end

    -- cards (dashboards, side pane, list rows): 9-slice art vs a plain frame
    for _, c in ipairs(UI.skinCards or {}) do
        if c.sTL then
            for _, t in ipairs({ c.sTL, c.sTR, c.sBL, c.sBR, c.sT, c.sB, c.sL, c.sR, c.sC }) do
                if painted then t:Show() else t:Hide() end
            end
        end
        if c.SetBackdrop then
            if painted or c.anxNoBackdrop then
                c:SetBackdrop(nil)
            else
                c:SetBackdrop(CLASSIC_BACKDROP)
                if c.SetBackdropColor then c:SetBackdropColor(0.05, 0.05, 0.07, 0.92) end
                if c.SetBackdropBorderColor then c:SetBackdropBorderColor(0.45, 0.38, 0.25, 1) end
            end
        end
    end
    UI.RefreshIfShown()
end

function UI.ToggleUnskinned()
    ANx.db.classicSkin = not ANx.db.classicSkin
    if ANx.SyncOptionsPanel then ANx.SyncOptionsPanel() end
    UI.ApplySkin()
    ANx.Print(ANx.db.classicSkin and "Unskinned layout enabled."
        or "Painted layout enabled.")
end

-- ---------------------------------------------------------------------
-- What's Left dashboard
-- ---------------------------------------------------------------------
function UI.UpdateWLPanel()
    local f = UI.frame
    local wl = f and f.wlPanel
    if not wl then return end
    -- building the report walks every profession, vendor and item, so do it on
    -- the background pump the first time and fill the cards in when it lands
    if not Engine.RemainingReady() then
        wl.attunes.num:SetText("|cff888888...|r")
        wl.crafted.num:SetText("|cff888888...|r")
        wl.currency.num:SetText("|cff888888...|r")
        UI.FitText(wl.attunes.sub, "|cffbfae86working it out...|r", 200)
        wl.crafted.sub:SetText(""); wl.currency.sub:SetText("")
        for e = 1, 3 do
            wl.exps.rows[e].right:SetText("|cff888888...|r")
            wl.exps.rows[e].bar:Hide()
        end
        for i = 1, 4 do
            local row = wl.mats.rows[i]
            row.icon:Hide(); row.name:SetText(""); row.need:SetText(""); row.own:SetText("")
        end
        UI.FitText(wl.mats.rows[1].name, "|cff888888Adding up your materials...|r", 300)
        Engine.RemainingAsync(function() UI.RefreshIfShown() end)
        return
    end
    local r = Engine.RemainingReport()
    local sc = (ANx.db.scope == "account") and "acct" or "char"
    local scName = (sc == "acct") and "account-wide" or "this character"

    -- stat cards
    wl.attunes.num:SetText("|cffffff00" .. (r[sc].attunes or 0) .. "|r")
    UI.FitText(wl.attunes.sub, "|cffbfae86" .. scName .. " - click for a breakdown|r", 200)
    wl.crafted.num:SetText("|cffffff00" .. (r[sc].crafted or 0) .. "|r")
    UI.FitText(wl.crafted.sub, "|cffbfae86click: raw materials per profession|r", 200)
    local nCur, curTotal = 0, 0
    for _, n in ipairs(r.curNames or {}) do
        local v = (r[sc].cur and r[sc].cur[n]) or 0
        if v > 0 then nCur = nCur + 1; curTotal = curTotal + 1 end
    end
    wl.currency.num:SetText("|cffffff00" .. nCur .. "|r")
    UI.FitText(wl.currency.sub, "|cffbfae86currencies still needed - click for totals|r", 200)

    -- remaining by expansion
    local byCat = Engine.RemainingByCategory(sc)
    for e = 1, 3 do
        local row = wl.exps.rows[e]
        UI.FitText(row.name, ANx.EXP_COLORS[e] .. ANx.EXP_NAMES[e] .. "|r", row.trackW)
        local left = (byCat.exps and byCat.exps[e]) or 0
        row.right:SetText("|cffffff00" .. left .. "|r|cff888888 left|r")
        local sum = SummaryRow(e, UI.RefreshIfShown)
        local pct = 0
        if sum then
            local st = Engine.UnionStats(Engine.AllContentSets(sum), "sum:" .. e .. ":all:" .. DiffKey())
            if st.total > 0 then pct = st.attuned / st.total end
        end
        local w = math.floor(pct * row.trackW + 0.5)
        row.bar:SetWidth(w > 1 and w or 1)
        if not (UI.SetArtTrimmed and UI.SetArtTrimmed(row.bar, (pct >= 1) and "progress_fill_gold" or "progress_fill_teal")) then
            row.bar:SetTexture(0.15, 0.85, 0.5, 0.45)
        end
        row.bar:Show()
    end

    -- active goals
    local gl = (ANx.db and ANx.db.goals) or {}
    local n = 0
    for i, goal in ipairs(gl) do
        if n >= 3 then break end
        local st = Engine.GoalStatus(goal)
        n = n + 1
        local row = wl.goals.rows[n]
        local complete = st.total > 0 and st.left == 0
        UI.FitText(row.name, (complete and "|cff00ff00" or "|cffffffff") .. st.name .. "|r",
            row.trackW - 70)
        if complete then
            row.right:SetText("|cff00ff00done!|r")
        else
            row.right:SetText(st.done .. "/" .. st.total
                .. ((st.clears and st.clears > 0) and ("  |cff888888~" .. st.clears .. "|r") or ""))
        end
        local w = math.floor((st.pct or 0) * row.trackW + 0.5)
        row.bar:SetWidth(w > 1 and w or 1)
        if not (UI.SetArtTrimmed and UI.SetArtTrimmed(row.bar, complete and "progress_fill_gold" or "progress_fill_teal")) then
            row.bar:SetTexture(0.15, 0.85, 0.5, 0.45)
        end
        row.bar:Show()
        if row.track.Show then row.track:Show() end
    end
    if n == 0 then
        local row = wl.goals.rows[1]
        UI.FitText(row.name, "|cff888888No goals tracked yet|r", row.trackW)
        row.right:SetText("")
        row.bar:Hide()
        if row.track.Hide then row.track:Hide() end
        n = 1
    end
    for i = n + 1, 3 do
        local row = wl.goals.rows[i]
        row.name:SetText(""); row.right:SetText("")
        row.bar:Hide()
        if row.track.Hide then row.track:Hide() end
    end

    -- top raw materials
    local rows = Engine.RemainingMaterials(nil)
    table.sort(rows, function(a, b)
        if (a[sc] or 0) ~= (b[sc] or 0) then return (a[sc] or 0) > (b[sc] or 0) end
        return a.id < b.id
    end)
    local shown = 0
    for _, m in ipairs(rows) do
        if shown >= 4 then break end
        if (m[sc] or 0) > 0 then
            shown = shown + 1
            local row = wl.mats.rows[shown]
            local name, _, quality, tex = ANx.GetItemDisplay(m.id)
            if ANx.ClearArtCoords then ANx.ClearArtCoords(row.icon) end
            row.icon:SetTexture(tex)
            row.icon:Show()
            UI.FitText(row.name, QualityHex(quality or 1) .. name .. "|r", 260)
            row.need:SetText("|cffffff00" .. (m[sc] or 0) .. "|r")
            row.own:SetText("|cff33ff99" .. (Engine.HaveCount and Engine.HaveCount(m.id) or 0) .. "|r")
        end
    end
    if shown == 0 then
        local row = wl.mats.rows[1]
        row.icon:Hide()
        UI.FitText(row.name, "|cff00ff00Nothing crafted left to attune!|r", 300)
        row.need:SetText(""); row.own:SetText("")
        shown = 1
    end
    for i = shown + 1, 4 do
        local row = wl.mats.rows[i]
        row.icon:Hide()
        row.name:SetText(""); row.need:SetText(""); row.own:SetText("")
    end
end

-- ---------------------------------------------------------------------
-- Browse side pane: selected-item details + a context recommendation
-- ---------------------------------------------------------------------
function UI.UpdateSidePane()
    local f = UI.frame
    local sp = f and f.sidePane
    if not sp then return end
    local view = UI.Current()

    -- ---------- item details (only when a row is selected) ----------
    local id = UI.selectedItem
    local it = sp.item
    if id then
        local name, link, quality, tex = ANx.GetItemDisplay(id)
        if ANx.ClearArtCoords then ANx.ClearArtCoords(it.icon) end
        it.icon:SetTexture(tex)
        it.icon:Show()
        UI.FitText(it.name, QualityHex(quality or 1) .. name .. "|r", (SIDE_W - 118) * 2)
        local chance, srcName, srcType, _, zname = Engine.BestSource(id,
            view and view.zoneName, view and view.srcFilter)
        UI.FitText(it.line1, "|cffbfae86" .. (SrcTypeLabel(srcType) or "Source") .. ":|r "
            .. (srcName or "?"), SIDE_W - 66)
        UI.FitText(it.line2, (zname and zname ~= "" and ("|cffbfae86in|r " .. zname) or "")
            .. ((chance and chance > 0) and ("   |cff00ff88" .. ANx.FormatChance(chance) .. "|r") or ""),
            SIDE_W - 66)
        local prog = ANx.Progress(id) or 0
        local tier = ANx.CurrentTier(id)
        local state
        if tier >= 2 then
            state = "|cffff8000" .. (ANx.FORGE_SHORT[tier] or "forged") .. "|r"
        elseif tier == 1 then
            state = "|cff00ff00attuned|r"
        else
            state = "|cffffff00" .. math.floor(prog + 0.5) .. "% attuned|r"
        end
        local extra = ""
        if not ANx.CanCharAttune(id) and ANx.AltListString then
            local alts = ANx.AltListString(id)
            if alts and alts ~= "" then extra = "  |cff888888(" .. alts .. ")|r" end
        end
        it.line3:SetText(state .. extra)
        it.srcBtn:SetScript("OnClick", function()
            UI.Push({ type = "sources", itemId = id })
        end)
        it.arrowBtn:SetScript("OnClick", function()
            if ANx.ArrowToItem then ANx.ArrowToItem(id) end
        end)
        it:Show()
        -- two cards: split the column so the pair fills it (12px gap)
        local total = (sp.anxH or 500) - 12
        local ih = math.floor(total * 0.46)
        local rh = total - ih
        it:SetHeight(ih)
        UI.LayoutCard(it, SIDE_W, ih)
        sp.rec:ClearAllPoints()
        sp.rec:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, -(ih + 12))
        sp.rec:SetHeight(rh)
        UI.LayoutCard(sp.rec, SIDE_W, rh)
    else
        it:Hide()
        local rh = math.min(320, sp.anxH or 320)
        sp.rec:ClearAllPoints()
        sp.rec:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, 0)
        sp.rec:SetHeight(rh)
        UI.LayoutCard(sp.rec, SIDE_W, rh)
    end

    -- ---------- context recommendation for THIS screen ----------
    local rc = sp.rec
    local mode = ANx.RunMode("rec")
    local runs
    if mode ~= "off" then
        runs = Engine.RunsCached(view, mode, "rec")
        if not runs and Engine.SummariesReady() then
            Engine.RankRunsAsync(view, mode, function() UI.RefreshIfShown() end, "rec")
        end
    end
    local pending = (mode ~= "off") and not runs
    local r = runs and runs[1]
    local trackGoal
    if r then
        if r.zone then
            UI.SetIconArt(rc.icon, EXP_ART[r.zone.exp or 1], 48)
            UI.FitText(rc.name, "|cffffd100" .. r.zone.name .. "|r", (SIDE_W - 116) * 2)
            rc.line1:SetText("|cffbfae86Zone sweep|r")
        else
            local thumb = "thumb_" .. ArtSlug(r.inst.name)
            UI.SetIconArt(rc.icon, (ANx.Art and ANx.Art[thumb]) and thumb or "dungeons", 48)
            UI.FitText(rc.name, "|cffffd100" .. r.inst.name .. RunLabel(r.d) .. "|r", (SIDE_W - 116) * 2)
            rc.line1:SetText("|cffbfae86Best run here|r")
            trackGoal = { kind = "inst", map = r.inst.map, name = r.inst.name,
                          diff = r.d.label,
                          diffText = ANx.DIFF_LABEL_TEXT and ANx.DIFF_LABEL_TEXT[r.d.label] }
        end
        rc.line2:SetText(string.format("|cff00ff88~%.1f new attunes|r  -  %d left%s",
            r.expected, r.count, r.time and ("  |cff888888" .. UI.TimeTag(r) .. "|r") or ""))
        rc.icon:Show()
    elseif pending then
        rc.icon:Hide()
        rc.name:SetText(Engine.SummariesReady()
            and "|cff888888Finding the best run...|r"
            or "|cff888888Scanning...|r")
        rc.line1:SetText("")
        rc.line2:SetText("")
    else
        local pick = Engine.AttuneNextPick(view, { cfg = "rec" })
        if pick then
            local name, _, quality, tex = ANx.GetItemDisplay(pick)
            if ANx.ClearArtCoords then ANx.ClearArtCoords(rc.icon) end
            rc.icon:SetTexture(tex)
            rc.icon:Show()
            UI.FitText(rc.name, QualityHex(quality or 1) .. name .. "|r", (SIDE_W - 116) * 2)
            local chance, srcName, _, _, zname = Engine.BestSource(pick,
                view and view.zoneName, view and view.srcFilter)
            UI.FitText(rc.line1, "|cffbfae86" .. (srcName or "?") .. "|r", SIDE_W - 66)
            rc.line2:SetText((zname and zname ~= "" and zname or "")
                .. ((chance and chance > 0) and ("   |cff00ff88" .. ANx.FormatChance(chance) .. "|r") or ""))
        else
            rc.icon:Hide()
            rc.name:SetText(Engine.scanning and "|cff888888Scanning...|r" or "|cff888888Nothing left here|r")
            rc.line1:SetText("")
            rc.line2:SetText("")
        end
    end

    -- track-goal button: instance screens + instance recommendations
    local goal
    if view.type == "items" and view.instMap then
        goal = { kind = "inst", map = view.instMap, name = view.instName,
                 diff = view.instDiff,
                 diffText = ANx.DIFF_LABEL_TEXT and ANx.DIFF_LABEL_TEXT[view.instDiff or ""] }
    elseif view.type == "instances" then
        goal = { kind = "content", exp = view.exp, content = view.kind }
    elseif trackGoal then
        goal = trackGoal
    end
    -- buttons ride the bottom of the card, stacked
    rc.goBtn:ClearAllPoints()
    rc.trackBtn:ClearAllPoints()
    if goal then
        rc.goBtn:SetPoint("BOTTOMLEFT", rc, "BOTTOMLEFT", 30, 66)
        rc.trackBtn:SetPoint("BOTTOMLEFT", rc, "BOTTOMLEFT", 30, 28)
    else
        rc.goBtn:SetPoint("BOTTOMLEFT", rc, "BOTTOMLEFT", 30, 28)
    end
    if goal then
        local tracked = UI.GoalTracked and UI.GoalTracked(goal)
        rc.trackBtn.anxLabel:SetText(tracked and "|cff33ff99Tracked - remove|r"
            or "|cffe3c98fTrack as a goal|r")
        rc.trackBtn:SetScript("OnClick", function()
            if UI.ToggleGoal then UI.ToggleGoal(goal) end
            UI.Render()
        end)
        rc.trackBtn:Show()
    else
        rc.trackBtn:Hide()
    end
end

-- Is the screen we launched from a non-dungeon/raid category (Quests, Vendors,
-- Currencies, Professions, Events, World-drop zones)? If so, that category
-- overrides "Recommend a whole dungeon/raid" - we recommend an item from it.
local function IsNonInstanceCategory(from)
    if not from then return false end
    local t = from.type
    if t == "quests" or t == "currencies" or t == "vendors"
        or t == "profs" or t == "events" or t == "zones" then
        return true
    end
    if t == "contentExp" and from.content and from.content ~= "D" and from.content ~= "R" then
        return true
    end
    return false
end

-- The button's pick is global: it never narrows to the current screen (the
-- on-screen recommendation cards are the context-sensitive feature).
local function PickFrom(from)
    return Engine.AttuneNextPick(nil, { cfg = "btn" })
end

local function PushRun(r, from, which)
    if r.zone then
        ANx.Print(string.format("Best zone: |cffffff00%s|r  -  ~%.1f expected new attunes (%d left)",
            r.zone.name, r.expected, r.count))
        UI.Push({ type = "items", title = r.zone.name, items = r.items,
            zoneName = r.zone.name, worldDrop = true,
            fromAttuneNextRun = true, zoneRun = true,
            runExpected = r.expected, runCount = r.count, runTime = r.time,
            instKey = r.instKey, launchedFrom = from, recCfg = which })
    else
        local lbl = RunLabel(r.d)
        ANx.Print(string.format("Best run: |cffffff00%s%s|r  -  ~%.1f expected new attunes (%d left, %s)",
            r.inst.name, lbl, r.expected, r.count, UI.TimeTag(r)))
        UI.Push({ type = "items", title = r.inst.name .. lbl, items = r.d.items,
            zoneName = r.inst.name, srcFilter = ANx.INSTANCE_DROP_SRC,
            fromAttuneNextRun = true, runExpected = r.expected, runCount = r.count,
            runTime = r.time, instKey = r.instKey, launchedFrom = from, recCfg = which,
            instMap = r.inst.map, instName = r.inst.name, instDiff = r.d.label })
    end
end

-- "Show Me" on a recommendation card: opens what the card is showing, using
-- the cards' own (context sensitive) config.
function UI.ShowRec()
    EnsureEngine()
    local from = UI.Current()
    if from and (from.type == "sources" or from.type == "items") and from.launchedFrom then
        from = from.launchedFrom
    end
    for exp = 1, 3 do Engine.GetSummary(exp, UI.RefreshIfShown) end
    local mode = ANx.RunMode("rec")
    if mode ~= "off" then
        local runs = Engine.RunsCached(from, mode, "rec")
            or Engine.RankRuns(from, mode, nil, "rec")
        if runs and #runs > 0 then
            PushRun(runs[1], from, "rec")
            return
        end
    end
    local id = Engine.AttuneNextPick(from, { cfg = "rec" })
    if id then
        UI.Push({ type = "sources", itemId = id, fromAttuneNext = true,
                  launchedFrom = from, recCfg = "rec" })
    elseif Engine.scanning then
        ANx.Print("Still building the item database - try again in a moment.")
    else
        ANx.Print("Nothing to recommend here with the current filters/options.")
    end
end

function UI.AttuneNextGo()
    EnsureEngine()
    -- the button is global: the current screen is only remembered for Back
    local from = UI.Current()
    if from and (from.type == "sources" or from.type == "items") and from.launchedFrom then
        from = from.launchedFrom
    end
    -- make sure the summaries are being built so wide contexts have data
    for exp = 1, 3 do Engine.GetSummary(exp, UI.RefreshIfShown) end

    -- Whole-run mode (global: the button doesn't follow the current screen).
    local runMode = ANx.RunMode("btn")
    if runMode ~= "off" then
        local runs = Engine.RankRuns(nil, runMode, nil, "btn")
        if #runs > 0 then
            PushRun(runs[1], from, "btn")
        elseif Engine.scanning then
            ANx.Print("Still building the item database - try AttuneNext again in a moment.")
        else
            ANx.Print("Nothing to recommend for this run mode with the current filters.")
        end
        return
    end

    local id = PickFrom(from)
    if id then
        UI.Push({ type = "sources", itemId = id, fromAttuneNext = true, launchedFrom = from })
    elseif Engine.scanning then
        ANx.Print("Still building the item database - try AttuneNext again in a moment.")
    else
        ANx.Print("Nothing to recommend here with the current filters/options.")
    end
end

-- Ignore an instance run and show the next best one.
function UI.AttuneNextIgnoreInstance(instKey, from, which)
    which = which or "btn"
    ANx.db.anext.ignoreInst = ANx.db.anext.ignoreInst or {}
    ANx.db.anext.ignoreInst[instKey] = true
    Engine.InvalidateStats()
    UI.Pop()
    local view = (which == "rec") and (from or UI.Current()) or nil
    local runs = Engine.RankRuns(view, ANx.RunMode(which), nil, which)
    if #runs > 0 then
        PushRun(runs[1], from, which)
    else
        ANx.Print("No more runs to recommend.")
    end
end

-- Ignore the current item and pick the next one.
function UI.AttuneNextIgnore(itemId)
    ANx.db.anext.ignore = ANx.db.anext.ignore or {}
    ANx.db.anext.ignore[itemId] = true
    local name = ANx.GetItemDisplay(itemId)
    ANx.Print("Ignoring |cffffff00" .. name .. "|r - picking another.")
    -- pop the current sources view, then re-pick from where we launched
    local cur = UI.Current()
    local from = (cur and cur.launchedFrom) or nil
    local which = (cur and cur.recCfg) or "btn"
    UI.Pop()
    local id
    if which == "rec" then
        id = Engine.AttuneNextPick(from or UI.Current(), { cfg = "rec" })
    else
        id = PickFrom()
    end
    if id then
        UI.Push({ type = "sources", itemId = id, fromAttuneNext = true,
                  launchedFrom = from, recCfg = which })
    else
        ANx.Print("Nothing left to recommend with the current filters/options.")
    end
end
