-- =========================================================================
-- AttuneNext - TradeSkillScan.lua
-- Auto-scans every profession window you open and saves each recipe's
-- reagent list account-wide (any character's scan contributes). Powers the
-- "What's Left" crafting-materials breakdown.
-- (Reagent data isn't available offline in 3.3.5 - it can only be read from
-- an open tradeskill window, the same way the vendor scanner reads costs.)
-- =========================================================================
local ADDON_NAME, ANx = ...

local function LinkItemId(link)
    return link and tonumber(link:match("item:(%d+)")) or nil
end

function ANx.ScanTradeSkill()
    if not (ANx.db and _G.GetNumTradeSkills) then return end
    local profName = _G.GetTradeSkillLine and _G.GetTradeSkillLine()
    if not profName or profName == "UNKNOWN" then return end
    local n = _G.GetNumTradeSkills() or 0
    local stored = 0
    for i = 1, n do
        local _, skillType = _G.GetTradeSkillInfo(i)
        if skillType and skillType ~= "header" then
            local itemId = LinkItemId(_G.GetTradeSkillItemLink and _G.GetTradeSkillItemLink(i))
            if itemId then
                local rg = {}
                local numReagents = (_G.GetTradeSkillNumReagents and _G.GetTradeSkillNumReagents(i)) or 0
                for j = 1, numReagents do
                    local rid = LinkItemId(_G.GetTradeSkillReagentItemLink
                        and _G.GetTradeSkillReagentItemLink(i, j))
                    local _, _, cnt = _G.GetTradeSkillReagentInfo(i, j)
                    if rid and cnt and cnt > 0 then
                        rg[#rg + 1] = rid
                        rg[#rg + 1] = cnt
                    end
                end
                if #rg > 0 then
                    ANx.db.reagents[itemId] = rg
                    -- items produced per craft (a smelt can yield 2 bars);
                    -- store the guaranteed minimum when it's more than one
                    local minMade = _G.GetTradeSkillNumMade and _G.GetTradeSkillNumMade(i)
                    if minMade and minMade > 1 then
                        ANx.db.reagentOutput[itemId] = math.floor(minMade)
                    else
                        ANx.db.reagentOutput[itemId] = nil
                    end
                    stored = stored + 1
                end
            end
        end
    end
    if stored > 0 then
        ANx.db.reagentProfs = ANx.db.reagentProfs or {}
        ANx.db.reagentProfs[profName] = true
        ANx.DebugMsg("tradeskill scan (" .. profName .. "): reagents stored for "
            .. stored .. " recipes")
        if ANx.Engine and ANx.Engine.InvalidateRemaining then ANx.Engine.InvalidateRemaining() end
        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
    end
end

-- Debounced entry point (TRADE_SKILL_UPDATE fires in bursts while the window
-- populates; scan once things settle).
local queued = false
function ANx.QueueTradeSkillScan()
    if queued then return end
    queued = true
    ANx.After(0.5, function()
        queued = false
        ANx.ScanTradeSkill()
    end)
end
