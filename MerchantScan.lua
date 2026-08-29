-- =========================================================================
-- AttuneNext - MerchantScan.lua
-- Auto-scans every merchant window you open and saves item costs
-- (gold / honor / arena / token items) account-wide, powering the
-- Vendor -> Currency browsing layer.
-- =========================================================================
local ADDON_NAME, ANx = ...

local function CurrencyNameFromLink(link, fallback)
    if link then
        local name = GetItemInfo(link)
        if name then return name end
        name = link:match("%[(.-)%]")
        if name then return name end
    end
    return fallback or "Token"
end

-- element-wise compare of two cost arrays ({name=,count=} entries)
local function SameCosts(a, b)
    if not a or #a ~= #b then return false end
    for i = 1, #b do
        local x, y = a[i], b[i]
        if not x or x.name ~= y.name or x.count ~= y.count then return false end
    end
    return true
end

function ANx.ScanMerchant()
    if not ANx.db then return end
    local n = GetMerchantNumItems()
    if not n or n == 0 then return end
    local changed = 0
    for i = 1, n do
        local link = GetMerchantItemLink(i)
        local itemId = link and tonumber(link:match("item:(%d+)"))
        -- Only track items the addon can ever list (attunables). Storing
        -- every vendor's full inventory - food, reagents, grays - grew
        -- db.merchant/db.stock without bound, and no consumer ever reads
        -- costs for non-attunable items. Before the server data is live we
        -- can't tell, so store as before and let TrimMerchantDb clean up.
        if itemId and ((not ANx.dataReady) or ANx.IsAttunableAtAll(itemId)) then
            -- 3.3.5: name, texture, price, quantity, numAvailable, isUsable, extendedCost
            local _, _, price, _, numAvailable, _, extendedCost = GetMerchantItemInfo(i)
            -- stock: only real limits matter; -1 (unlimited, the common case)
            -- used to add one dead SavedVariables entry per item forever
            local newStock = (numAvailable and numAvailable >= 0) and numAvailable or nil
            if ANx.db.stock[itemId] ~= newStock then
                ANx.db.stock[itemId] = newStock
                changed = changed + 1
            end
            local costs = {}
            if price and price > 0 then
                costs[#costs + 1] = { name = "Gold", count = price } -- copper
            end
            if extendedCost then
                local honor, arena, tokenCount = GetMerchantItemCostInfo(i)
                if honor and honor > 0 then
                    costs[#costs + 1] = { name = "Honor Points", count = honor }
                end
                if arena and arena > 0 then
                    costs[#costs + 1] = { name = "Arena Points", count = arena }
                end
                for j = 1, (tokenCount or 0) do
                    local _, value, costLink = GetMerchantItemCostItem(i, j)
                    if value and value > 0 then
                        costs[#costs + 1] = {
                            name = CurrencyNameFromLink(costLink),
                            count = value,
                        }
                    end
                end
            end
            -- keep the old table when identical: revisiting a known vendor
            -- used to wipe every engine cache and re-render for nothing
            if #costs > 0 and not SameCosts(ANx.db.merchant[itemId], costs) then
                ANx.db.merchant[itemId] = costs
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        ANx.DebugMsg("merchant scan: " .. changed .. " cost/stock change(s) stored")
        -- currency groupings may have changed
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end
end

-- One-time SavedVariables trim (runs once per account, after server data is
-- live): drop -1 "unlimited" stock entries and merchant costs for items that
-- are not attunable - both were pure dead weight written by older versions.
function ANx.TrimMerchantDb()
    if not (ANx.db and ANx.dataReady) then return end
    if ANx.db.dbTrim1 then return end
    local stock, merchant = ANx.db.stock or {}, ANx.db.merchant or {}
    local removed = 0
    for id, v in pairs(stock) do
        if type(v) ~= "number" or v < 0 or not ANx.IsAttunableAtAll(id) then
            stock[id] = nil
            removed = removed + 1
        end
    end
    for id in pairs(merchant) do
        if not ANx.IsAttunableAtAll(id) then
            merchant[id] = nil
            removed = removed + 1
        end
    end
    ANx.db.dbTrim1 = true
    if removed > 0 then
        ANx.DebugMsg("merchant db trim: removed " .. removed .. " dead entries")
    end
end

-- Pretty string for one cost variant, e.g. "25 Emblem of Triumph" or "12g 50s"
local function OneCostString(costs)
    local parts = {}
    for _, c in ipairs(costs) do
        if c.name == "Gold" then
            local g = math.floor(c.count / 10000)
            local s = math.floor((c.count % 10000) / 100)
            if g > 0 then
                parts[#parts + 1] = g .. "g" .. (s > 0 and (" " .. s .. "s") or "")
            else
                parts[#parts + 1] = s .. "s " .. (c.count % 100) .. "c"
            end
        else
            parts[#parts + 1] = c.count .. " " .. c.name
        end
    end
    return table.concat(parts, " + ")
end

-- Stock for an item at a given vendor (npcId optional).
-- Returns: label string, isLimited(bool)
--   static per-vendor limit (xlsx) wins; else last live merchant numAvailable;
--   else assumed unlimited.
function ANx.StockString(itemId, npcId)
    if npcId and ANx.VendorStock and ANx.VendorStock[npcId] then
        local c = ANx.VendorStock[npcId][itemId]
        if c then
            return (c == 1) and "1 at a time" or (c .. " at a time"), true
        end
    end
    local live = ANx.db and ANx.db.stock and ANx.db.stock[itemId]
    if live ~= nil and live >= 0 then
        return (live == 1) and "1 at a time" or (live .. " in stock"), true
    end
    return "unlimited", false
end

-- All known purchase options for an item, e.g. "50 Emblem of Triumph or 340g"
function ANx.CostString(itemId)
    local all = ANx.Engine and ANx.Engine.ItemAllCosts(itemId)
    if not all then return nil end
    local parts = {}
    for i, cost in ipairs(all) do
        if i > 2 then
            parts[#parts + 1] = "+" .. (#all - 2) .. " more"
            break
        end
        parts[#parts + 1] = OneCostString(cost)
    end
    return table.concat(parts, " |cff888888or|r ")
end
