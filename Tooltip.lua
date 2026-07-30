-- =========================================================================
-- AttuneNext - Tooltip.lua
-- Adds attunement need + best-source info to item tooltips everywhere
-- (bags, bank, vendors, loot, chat links, the AttuneNext window itself).
-- Lines only appear on items you still NEED, so tooltips stay clean:
--   AttuneNext: still needed
--   best source: 42% - Captain Greenskin (The Deadmines)
-- Toggle: Interface Options -> AddOns -> AttuneNext.
-- =========================================================================
local ADDON_NAME, ANx = ...

local function ItemIdFromLink(link)
    return link and tonumber(tostring(link):match("item:(%d+)")) or nil
end

-- one-line description of the best way to get the item
local function SourceLine(itemId)
    local Engine = ANx.Engine
    if not Engine then return nil end
    local chance, srcName, srcType, _, zoneName = Engine.BestSource(itemId)
    if not srcName then return nil end
    local S = ANx.SRC
    local zone = (zoneName and zoneName ~= "" and zoneName ~= "Unknown")
        and ("  (" .. zoneName .. ")") or ""
    if srcType == S.VENDOR then
        local cost = ANx.CostString and ANx.CostString(itemId)
        return "sold by " .. srcName .. (cost and ("  -  " .. cost) or "") .. zone
    elseif srcType == S.CRAFT_TRAINER or srcType == S.CRAFT_RECIPE then
        return "crafted  -  " .. srcName
    elseif srcType == S.QUEST then
        return "quest: " .. srcName .. zone
    end
    local pct = (chance and chance > 0) and (ANx.FormatChance(chance) .. "  -  ") or ""
    return pct .. srcName .. zone
end

local function Attach(tip)
    if not (ANx.db and ANx.db.tooltip) then return end
    if not (tip and tip.GetItem) then return end
    if not ANx.LootDbLoaded() then return end
    local _, link = tip:GetItem()
    local itemId = ItemIdFromLink(link)
    if not itemId then return end
    if not ANx.IsAttunableAtAll(itemId) then return end

    local header
    if ANx.CanCharAttune(itemId) and not ANx.IsAttuned(itemId) then
        local ignored = ANx.db.anext and ANx.db.anext.ignore and ANx.db.anext.ignore[itemId]
        header = "|cff33ff99AttuneNext:|r still needed"
            .. (ignored and "  |cff888888(on your ignore list)|r" or "")
    elseif not ANx.AccountHasVariant(itemId) then
        local alts = ANx.AltsWhoCanAttune and ANx.AltsWhoCanAttune(itemId)
        if alts and #alts > 0 then
            header = "|cff33ff99AttuneNext:|r |cff00ccffneeded on the account|r - "
                .. ANx.AltListString(alts, 2) .. " can attune it"
        else
            header = "|cff33ff99AttuneNext:|r |cff00ccffneeded on the account|r (not this character)"
        end
    end
    if not header then return end   -- attuned / account-done: stay quiet

    tip:AddLine(header, 1, 1, 1)
    local src = SourceLine(itemId)
    if src then
        tip:AddLine("|cff888888best source:|r " .. src, 0.75, 0.75, 0.75)
    end
    if tip.Show then tip:Show() end   -- resize to fit the new lines
end

local function Hook(tip)
    if not tip then return end
    if tip.HookScript then
        tip:HookScript("OnTooltipSetItem", Attach)
    elseif tip.SetScript and tip.GetScript then
        local prev = tip:GetScript("OnTooltipSetItem")
        tip:SetScript("OnTooltipSetItem", function(self, ...)
            if prev then prev(self, ...) end
            Attach(self)
        end)
    end
end

Hook(_G.GameTooltip)
Hook(_G.ItemRefTooltip)
