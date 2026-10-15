"""Build experiment copies of AttuneNext + AttuneNext-Simple.

  python3 -I patch_exp.py pace    -> exp_pace/{AttuneNext,AttuneNext-Simple}
  python3 -I patch_exp.py borrow  -> exp_borrow/{...}   (pace + Simple adopts host structure)
Every replacement must match exactly once, or the script aborts.
"""
import os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN_SRC = "/home/user/AttuneNext"
SIMPLE_SRC = "/home/user/attunenext-simple"

def rep(path, old, new, count=1):
    s = open(path, encoding="utf-8").read()
    n = s.count(old)
    assert n == count, "%s: expected %d match(es) for %r, found %d" % (path, count, old[:60], n)
    s = s.replace(old, new)
    open(path, "w", encoding="utf-8").write(s)

PUMP_OLD_HEAD = """local pumpFrame = CreateFrame("Frame")
local BUDGET_MS = 10
local GC_STEP_KB = 2048   -- collector work per scan frame (see the pump)
"""
PUMP_NEW_HEAD = """local pumpFrame = CreateFrame("Frame")
-- Pacing knobs (overridable from _G.ANX_PACE for experiments)
local P = _G.ANX_PACE or {}
local BUDGET_MS     = P.max or 10      -- hard cap on scan work + GC per frame
local BUDGET_MIN_MS = P.min or 3       -- floor so a slow machine still finishes
local BUDGET_SHARE  = P.share or 0.35  -- target share of the game's own frame time
local GC_FRACTION   = P.gc or 0.3      -- part of the budget reserved for the collector step
local GC_STEP_KB    = 2048             -- collector work per 10 ms of scan work
-- One scan budget per frame for every AttuneNext-family addon in this Lua
-- state (AttuneNext-Simple carries a copy of this engine): the first pump to
-- run in a frame records what it spent, later ones only get the remainder.
local gate = _G.AttuneNextPumpGate
if not gate then
    gate = { t = -1, used = 0, prevTotal = 0 }
    _G.AttuneNextPumpGate = gate
end
local lastOwnMs = 0   -- this pump's work + GC last frame (part of `elapsed`)
local ST = _G.ANX_PACE_STATS or { frames = 0, work = 0, gc = 0, over = 0, maxResume = 0, slowResumes = 0, resumes = 0, skipped = 0 }
_G.ANX_PACE_STATS = ST
"""

PUMP_OLD_BODY = """pumpFrame:SetScript("OnUpdate", function(self)
    local job = Engine.scanJobs[1]
    if not job then
        Engine.scanning = false
        self:Hide()   -- sleep until the next Enqueue (OnUpdate needs shown)
        return
    end
    Engine.scanning = true
    local start = Clock()
    while Clock() - start < BUDGET_MS do
        if coroutine.status(job.co) == "dead" then break end
        local ok, err = coroutine.resume(job.co)
        if not ok then
            ANx.Print("|cffff4040scan error:|r " .. tostring(err))
            break
        end
    end
    -- A scan churns through millions of short-lived source records. Left to
    -- its default pacing, Lua's collector let that garbage pile up to several
    -- times the live data during login; a small step per scan frame keeps it
    -- bounded (cheap: only runs while a background job is active).
    collectgarbage("step", GC_STEP_KB)
    if coroutine.status(job.co) == "dead" then
"""
PUMP_NEW_BODY = """pumpFrame:SetScript("OnUpdate", function(self, elapsed)
    local job = Engine.scanJobs[1]
    if not job then
        Engine.scanning = false
        lastOwnMs = 0
        self:Hide()   -- sleep until the next Enqueue (OnUpdate needs shown)
        return
    end
    Engine.scanning = true
    -- Frame-time aware budget. `elapsed` is the whole previous frame, which
    -- already contains what this pump spent in it; the share applies to the
    -- game's own part so a slow frame shrinks the budget instead of feeding it.
    -- (GetTime is constant within a frame: the first pump to run in a frame
    -- rolls the gate over; every pump then sees the same previous-frame total)
    local now = GetTime()
    if gate.t ~= now then gate.t = now; gate.prevTotal = gate.used; gate.used = 0 end
    local gameMs = ((elapsed or 0) * 1000) - gate.prevTotal
    if gameMs < 1 then gameMs = 1 end
    local budget = gameMs * BUDGET_SHARE / (1 - BUDGET_SHARE)
    if budget > BUDGET_MS then budget = BUDGET_MS
    elseif budget < BUDGET_MIN_MS then budget = BUDGET_MIN_MS end
    -- a sibling engine may already have spent part of this frame's budget
    budget = budget - gate.used
    if budget < 2 then lastOwnMs = 0; ST.skipped = ST.skipped + 1; return end
    local start = Clock()
    local workBudget = budget * (1 - GC_FRACTION)
    while Clock() - start < workBudget do
        if coroutine.status(job.co) == "dead" then break end
        local r0 = Clock()
        local ok, err = coroutine.resume(job.co)
        local rd = Clock() - r0
        ST.resumes = ST.resumes + 1
        if rd > ST.maxResume then ST.maxResume = rd end
        if rd > 2 then ST.slowResumes = ST.slowResumes + 1 end
        ST.byTag = ST.byTag or {}
        local bt = ST.byTag[job.tag or "?"] or { n = 0, slow = 0, max = 0, ms = 0 }
        bt.n = bt.n + 1; bt.ms = bt.ms + rd
        if rd > 2 then bt.slow = bt.slow + 1 end
        if rd > bt.max then bt.max = rd end
        ST.byTag[job.tag or "?"] = bt
        if not ok then
            ANx.Print("|cffff4040scan error:|r " .. tostring(err))
            break
        end
    end
    local work = Clock() - start
    ST.frames = ST.frames + 1; ST.work = ST.work + work
    if work > workBudget then ST.over = ST.over + (work - workBudget) end
    -- A scan churns through millions of short-lived source records; a
    -- collector step sized to the work just done keeps that garbage bounded
    -- without a fixed 2 MB step on frames that did little.
    local kb = math.floor(GC_STEP_KB * work / 10)
    if kb < 128 then kb = 128 end
    local g0 = Clock()
    collectgarbage("step", kb)
    ST.gc = ST.gc + (Clock() - g0)
    lastOwnMs = Clock() - start
    gate.used = gate.used + lastOwnMs
    if coroutine.status(job.co) == "dead" then
"""

def patch_pace(engine):
    rep(engine, PUMP_OLD_HEAD, PUMP_NEW_HEAD)
    rep(engine, PUMP_OLD_BODY, PUMP_NEW_BODY)

MY_OLD = """local yieldCheck = 0
function Engine.MaybeYield()
    yieldCheck = yieldCheck + 1
    if yieldCheck >= 25 then
        yieldCheck = 0
        if coroutine.running() then coroutine.yield() end
    end
end
"""
MY_NEW = """local yieldCheck = 0
local sliceEnd = 0     -- Clock() value at which the current pump slice ends
function Engine.SetSlice(t) sliceEnd = t end
-- Time-sliced: a resume used to run 25 calls regardless of their cost (one
-- heavy world-drop item is thousands of rows), so single resumes ran 20-40 ms
-- past the budget. Check the clock every 8 calls and stop when the slice is up.
function Engine.MaybeYield()
    yieldCheck = yieldCheck + 1
    if yieldCheck >= 8 then
        yieldCheck = 0
        if Clock() >= sliceEnd and coroutine.running() then coroutine.yield() end
    end
end
"""
def patch_pace2(engine):
    patch_pace(engine)
    rep(engine, MY_OLD, MY_NEW)

def patch_pace3(engine):
    patch_pace2(engine)
    # adaptive collector step: size the KB so the step takes ~GC_FRACTION of
    # the budget on THIS machine (ms per KB measured from the previous step)
    rep(engine, """local lastOwnMs = 0   -- this pump's work + GC last frame (part of `elapsed`)
""", """local lastOwnMs = 0   -- this pump's work + GC last frame (part of `elapsed`)
local msPerKb = 0     -- measured cost of the collector step on this machine
""")
    rep(engine, """    local kb = math.floor(GC_STEP_KB * work / 10)
    if kb < 128 then kb = 128 end
    local g0 = Clock()
    collectgarbage("step", kb)
    ST.gc = ST.gc + (Clock() - g0)
""", """    -- collector step sized to the work just done, then capped so it takes
    -- about GC_FRACTION of the budget on this machine (a fixed 2 MB step is
    -- 4 ms on a fast CPU but ~10 ms on a slow one, as much as the scan work)
    local kb = math.floor(GC_STEP_KB * work / 10)
    if msPerKb > 0 then
        local cap = math.floor(budget * GC_FRACTION / msPerKb)
        if kb > cap then kb = cap end
    end
    if kb < 256 then kb = 256 end
    local g0 = Clock()
    collectgarbage("step", kb)
    local gms = Clock() - g0
    ST.gc = ST.gc + gms
    local m = gms / kb
    msPerKb = (msPerKb == 0) and m or (msPerKb * 0.8 + m * 0.2)
""")
    rep(engine, """    local start = Clock()
    local workBudget = budget * (1 - GC_FRACTION)
    while Clock() - start < workBudget do""", """    local start = Clock()
    local workBudget = budget * (1 - GC_FRACTION)
    Engine.SetSlice(start + workBudget)
    while Clock() - start < workBudget do""")

SHARE_OLD = """-- Full manual rescan (Refresh button / "/an reset")
function Engine.ForceRescan()"""
SHARE_NEW = """-- The structural caches BY REFERENCE, for a sibling addon that runs the
-- same engine (AttuneNext-Simple) to adopt instead of scanning the loot DB
-- a second time. InvalidateAll replaces these locals rather than wiping
-- them, so an adopter keeps a consistent snapshot if this side rescans.
function Engine.ShareStructure()
    return { inst = instDiffCache, zones = zoneCache, summaries = summaryCache,
             resolved = instResolved, profs = profCache }
end

function Engine.AdoptStructure(t)
    instDiffCache = t.inst or {}
    zoneCache = t.zones or {}
    summaryCache = t.summaries or {}
    instResolved = t.resolved or {}
    profCache = t.profs or {}
    Engine.universeCache = nil
    BumpRev()
end

-- Full manual rescan (Refresh button / "/an reset")
function Engine.ForceRescan()"""

def patch_borrow_main(engine):
    rep(engine, SHARE_OLD, SHARE_NEW)

def patch_borrow_simple(core, engine, toc):
    rep(engine, SHARE_OLD, SHARE_NEW)
    # share the host's per-item flag table (item properties, filter independent)
    rep(core, "local itemFlags = {}\nlocal band, lshift, rshift = bit.band, bit.lshift, bit.rshift",
        "local itemFlags = (_G.AttuneNext and _G.AttuneNext.ItemFlags) or {}\nlocal band, lshift, rshift = bit.band, bit.lshift, bit.rshift")
    # data-ready: adopt instead of scanning when the host is loaded
    rep(core, """        for exp = 1, 3 do ANx.Engine.GetSummary(exp) end
""", """        local host = _G.AttuneNext
        if host and host.Engine and host.Engine.ShareStructure then
            local function adopt()
                local hs = host.Engine
                if (not hs.scanning) and #(hs.scanJobs or {}) == 0
                    and hs.SummariesReady and hs.SummariesReady() then
                    ANx.Engine.AdoptStructure(hs.ShareStructure())
                    ANx.Engine.InvalidateStats()
                    ANx.Engine.Enqueue(ANx.Engine.WarmPredicates, function()
                        if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end
                    end, "warmup")
                else
                    ANx.After(1, adopt)
                end
            end
            adopt()
        else
            for exp = 1, 3 do ANx.Engine.GetSummary(exp) end
        end
""")
    # provisional structure at ADDON_LOADED: take the host's, keep no SV copy
    rep(core, """        if ANx.Engine and ANx.Engine.ImportCache and ANx.Engine.ImportCache(true) then
            ANx.DebugMsg("provisional structure restored (pre-login data)")
        end
""", """        local host = _G.AttuneNext
        if host and host.Engine and host.Engine.ShareStructure then
            ANx.Engine.AdoptStructure(host.Engine.ShareStructure())
            ANx.db.structCache = nil   -- the host's SavedVariables carry it
        elseif ANx.Engine and ANx.Engine.ImportCache and ANx.Engine.ImportCache(true) then
            ANx.DebugMsg("provisional structure restored (pre-login data)")
        end
""")
    rep(core, """        if ANx.Engine then pcall(ANx.Engine.ExportCache) end
        pcall(ANx.ExportStatusCache)
""", """        if ANx.Engine and not _G.AttuneNext then pcall(ANx.Engine.ExportCache) end
        pcall(ANx.ExportStatusCache)
""")
    # also the validated import at data-ready must not clobber the adopted tables
    rep(core, """        if ANx.Engine.ImportCache() then
            ANx.DebugMsg("structural cache restored from previous session")
        end
""", """        if _G.AttuneNext and _G.AttuneNext.Engine then
            ANx.Engine.AdoptStructure(_G.AttuneNext.Engine.ShareStructure())
        elseif ANx.Engine.ImportCache() then
            ANx.DebugMsg("structural cache restored from previous session")
        end
""")
    rep(toc, "## SavedVariables: AttuneNextSimpleDB\n", "## SavedVariables: AttuneNextSimpleDB\n## OptionalDeps: AttuneNext\n")

def patch_seq_simple(core):
    # cheapest mitigation: Simple scans AFTER the host is idle instead of in the same frames
    rep(core, """        for exp = 1, 3 do ANx.Engine.GetSummary(exp) end
""", """        local host = _G.AttuneNext
        local function scan() for exp = 1, 3 do ANx.Engine.GetSummary(exp) end end
        if host and host.Engine then
            local function whenIdle()
                local hs = host.Engine
                if (not hs.scanning) and #(hs.scanJobs or {}) == 0 then scan()
                else ANx.After(1, whenIdle) end
            end
            whenIdle()
        else
            scan()
        end
""")

def build(variant):
    dst = os.path.join(HERE, "exp_" + variant)
    if os.path.exists(dst): shutil.rmtree(dst)
    m = os.path.join(dst, "AttuneNext"); s = os.path.join(dst, "AttuneNext-Simple")
    shutil.copytree(MAIN_SRC, m, ignore=shutil.ignore_patterns(".git", "Textures"))
    shutil.copytree(SIMPLE_SRC, s, ignore=shutil.ignore_patterns(".git", "Textures"))
    if variant in ("pace", "borrow"):
        patch_pace(os.path.join(m, "Engine.lua")); patch_pace(os.path.join(s, "Engine.lua"))
    if variant == "pace2":
        patch_pace2(os.path.join(m, "Engine.lua")); patch_pace2(os.path.join(s, "Engine.lua"))
    if variant == "pace3":
        patch_pace3(os.path.join(m, "Engine.lua")); patch_pace3(os.path.join(s, "Engine.lua"))
    if variant == "borrow":
        patch_borrow_main(os.path.join(m, "Engine.lua"))
        patch_borrow_simple(os.path.join(s, "Core.lua"), os.path.join(s, "Engine.lua"), os.path.join(s, "AttuneNext-Simple.toc"))
    if variant == "seq":
        patch_seq_simple(os.path.join(s, "Core.lua"))
    if variant == "best":
        patch_pace3(os.path.join(m, "Engine.lua")); patch_pace3(os.path.join(s, "Engine.lua"))
        patch_borrow_main(os.path.join(m, "Engine.lua"))
        patch_borrow_simple(os.path.join(s, "Core.lua"), os.path.join(s, "Engine.lua"), os.path.join(s, "AttuneNext-Simple.toc"))
    if variant == "borrow_only":   # borrow without the pacing change
        patch_borrow_main(os.path.join(m, "Engine.lua"))
        patch_borrow_simple(os.path.join(s, "Core.lua"), os.path.join(s, "Engine.lua"), os.path.join(s, "AttuneNext-Simple.toc"))
    from luaparser import ast
    for p in (m, s):
        for f in ("Core.lua", "Engine.lua"):
            ast.parse(open(os.path.join(p, f), encoding="utf-8").read())
    print("built", dst)

if __name__ == "__main__":
    build(sys.argv[1])
