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

function ANx.ScanMerchant()
    if not ANx.db then return end
    local n = GetMerchantNumItems()
    if not n or n == 0 then return end
    local scanned = 0
    for i = 1, n do
        local link = GetMerchantItemLink(i)
        local itemId = link and tonumber(link:match("item:(%d+)"))
        if itemId then
            local _, _, price, _, _, _, extendedCost = GetMerchantItemInfo(i)
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
            if #costs > 0 then
                ANx.db.merchant[itemId] = costs
                scanned = scanned + 1
            end
        end
    end
    if scanned > 0 then
        ANx.DebugMsg("merchant scan: stored costs for " .. scanned .. " items")
        -- currency groupings may have changed
        if ANx.Engine then ANx.Engine.InvalidateStats() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
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
