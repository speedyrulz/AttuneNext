"""Frame-lens harness: harness_orig.py + simulated nameplates, mouseover entries,
in-instance mode, and timing of every OnUpdate script / ANx.After callback /
event handler. Read-only against ADDON. Relative numbers only."""
import sys, os, re, time
import lupa.lua51 as lupa

ADDON = os.environ.get("ADDON", "/home/user/AttuneNext")
FRAMES = int(os.environ.get("FRAMES", "1500"))
NPLATES = int(os.environ.get("NPLATES", "0"))
OBJN = int(os.environ.get("OBJN", "0"))
INST = os.environ.get("INST") is not None
SCEN = set(os.environ.get("SCEN", "").split(",")) - {""}

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()

STUBS = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "harness_orig.py")).read()
STUBS = STUBS.split("STUBS = r'''", 1)[1].split("'''", 1)[0]
L.execute(STUBS)

# ---- lens-specific overrides -------------------------------------------
L.execute(r'''
local NITEMS = tonumber(os.getenv("NITEMS") or "") or 20000
local BASE = 10000
local INST = os.getenv("INST") ~= nil
local OBJN = tonumber(os.getenv("OBJN") or "") or 0
local NPLATES = tonumber(os.getenv("NPLATES") or "") or 0
local ZONE = os.getenv("ZONE") or (INST and "Scholomance" or "Eastern Plaguelands")
function GetRealZoneText() return ZONE end
function GetZoneText() return ZONE end
function IsInInstance() if INST then return true, "party" end return false, "none" end
function GetInstanceInfo() return ZONE, INST and "party" or "none", 1 end

-- creature entry enumeration (mouseover/target path)
function ItemLocGetObjCount(objType, entry) if objType == 0 and entry then return OBJN end return 0 end
function ItemLocGetObjAt(objType, entry, i) return 0, BASE + ((entry * 31 + i * 13) % NITEMS) end

_MO_ENTRY = 1234
function UnitExists(u) return u == "mouseover" or u == "target" or u == "player" or u == "npc" end
function UnitIsPlayer(u) return false end
function UnitGUID(u) if u == "player" then return "0x0000000000203C" end
  return string.format("0xF130%06X%06X", _MO_ENTRY, 1) end
function UnitName(u) if u == "player" then return "Speedyrulz" end return "Mob" .. _MO_ENTRY end

-- fast bit.band for the common power-of-two / low-mask cases (the stock
-- harness loops 32 times per call, which dwarfs every C-call stub)
do
  local P2 = {}
  for i = 0, 31 do P2[2 ^ i] = true end
  local slow = bit.band
  bit.band = function(a, b, ...)
    if ... then return slow(a, b, ...) end
    a = a % 4294967296; b = b % 4294967296
    if P2[b] then return (math.floor(a / b) % 2) * b end
    if P2[b + 1] then return a % (b + 1) end
    if P2[a] then return (math.floor(b / a) % 2) * a end
    if P2[a + 1] then return b % (a + 1) end
    return slow(a, b)
  end
end
-- simulated nameplate frames: PLAIN tables (the permissive FrameMT would
-- answer frame.anxNameFS etc. with a function); pass IsNameplate via the
-- border-texture path
_PLATES = {}
_SETALPHA = 0
local function region(kind, tex) return { GetObjectType = function() return kind end,
  GetTexture = function() return tex end } end
local function mkplate(i)
  local border = region("Texture", "Interface\\Tooltips\\Nameplate-Border")
  local nameFS = { GetObjectType = function() return "FontString" end,
                   GetText = function(self) return self._t end, _t = "Mob" .. ((i * 97) % 5000) }
  local junk = region("Texture")
  local f = {}
  f.GetName = function() return nil end
  f.GetRegions = function() return junk, border, junk, junk, junk, junk, nameFS, nameFS, junk, junk, junk end
  f.GetNumRegions = function() return 11 end
  f.IsShown = function() return true end
  f.HookScript = function() end
  f.CreateTexture = function() local t = CreateFrame("Texture") t.SetAlpha = function() _SETALPHA = _SETALPHA + 1 end return t end
  f.CreateFontString = function() return CreateFrame("FontString") end
  f._nameFS = nameFS
  return f
end
for i = 1, NPLATES do _PLATES[i] = mkplate(i) end
WorldFrame.GetNumChildren = function() return #_PLATES end
WorldFrame.GetChildren = function() return unpack(_PLATES) end

-- timing registry
_T = {}
function _ACC(key, dt)
  local t = _T[key]
  if not t then t = { n = 0, total = 0, max = 0 } _T[key] = t end
  t.n = t.n + 1; t.total = t.total + dt; if dt > t.max then t.max = dt end
end
function _TIMED(key, fn, ...)
  local t0 = os.clock()
  local r = { pcall(fn, ...) }
  _ACC(key, (os.clock() - t0) * 1000)
  if not r[1] then print("ERR in " .. key .. ": " .. tostring(r[2])) end
  return unpack(r, 2)
end
_SRCAT, _GSUB, _CAPT = 0, 0, false
local origAt = ItemLocGetSourceAt
ItemLocGetSourceAt = function(...) if _CAPT then _SRCAT = _SRCAT + 1 end return origAt(...) end
local origGsub = string.gsub
string.gsub = function(...) if _CAPT then _GSUB = _GSUB + 1 end return origGsub(...) end
''')

ADDONS = os.environ.get("ADDONS", ADDON + "|AttuneNext").split(";")
loader = L.eval("""function(src, name, aname, ns)
  local fn, err = loadstring(src, "@" .. aname .. "/" .. name)
  if not fn then return false, err end
  local ok, e = pcall(fn, aname, ns)
  return ok, e
end""")
nss = []
for spec in ADDONS:
    path, aname = spec.split("|")
    ns_ = L.table()
    toc = open(os.path.join(path, aname + ".toc"), encoding="utf-8-sig").read().splitlines()
    for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
        ok, err = loader(open(os.path.join(path, f), encoding="utf-8").read(), f, aname, ns_)
        if not ok: print("LOAD ERROR", aname, f, err)
    nss.append((aname, ns_))
ns = nss[0][1]
mem = L.eval('function() return collectgarbage("count") end')

# wrap every OnUpdate script + ANx.After + event handlers with timing
L.execute(r'''
function _INSTRUMENT(ns)
  for _, f in ipairs(_FRAMES()) do
    local fn = (not rawget(f, '_wrapped')) and rawget(f, '_scripts').OnUpdate
    rawset(f, '_wrapped', true)
    if fn then
      local info = debug.getinfo(fn, "S")
      local key = "OnUpdate " .. info.short_src:gsub("^.*/", "") .. ":" .. info.linedefined
      if rawget(f, '_parent') == WorldFrame then key = key .. " (plates driver)" end
      f._scripts.OnUpdate = function(self, dt)
        local capt = (rawget(f, '_parent') == WorldFrame)
        if capt then _CAPT = true end
        local t0 = os.clock()
        local ok, e = pcall(fn, self, dt)
        _ACC(key, (os.clock() - t0) * 1000)
        _CAPT = false
        if not ok then error(e) end
      end
    end
    local ev = (not rawget(f, '_evwrapped')) and rawget(f, '_scripts').OnEvent
    rawset(f, '_evwrapped', true)
    if ev then
      local info = debug.getinfo(ev, "S")
      local key = "OnEvent " .. info.short_src:gsub("^.*/", "") .. ":" .. info.linedefined
      f._scripts.OnEvent = function(self, event, ...)
        local t0 = os.clock()
        local ok, e = pcall(ev, self, event, ...)
        _ACC(key .. " " .. event, (os.clock() - t0) * 1000)
        if not ok then error(e) end
      end
    end
  end
  if ns._afterWrapped then return end
  ns._afterWrapped = true
  local after = ns.After
  ns.After = function(delay, func)
    local info = debug.getinfo(func, "S")
    local key = "After " .. info.short_src:gsub("^.*/", "") .. ":" .. info.linedefined
    return after(delay, function()
      local t0, g0 = os.clock(), _GSN
      local ok, e = pcall(func)
      _ACC(key, (os.clock() - t0) * 1000)
      _T[key].gs = (_T[key].gs or 0) + (_GSN - g0)
      if not ok then error(e) end
    end)
  end
end
_GSN, _GSROWS = 0, 0
function _REPORT(title, minms)
  print("== " .. title .. string.format("   [GetSources calls=%d rows=%d]", _GSN, _GSROWS))
  local rows = {}
  for k, t in pairs(_T) do rows[#rows + 1] = { k, t } end
  table.sort(rows, function(a, b) return a[2].total > b[2].total end)
  for _, r in ipairs(rows) do
    local t = r[2]
    if t.total >= (minms or 0) then
      print(string.format("  %-62s n=%6d total=%9.2fms max=%7.3fms avg=%7.4fms%s", r[1], t.n, t.total, t.max, t.total / t.n, t.gs and (" GetSources=" .. t.gs) or ""))
    end
  end
end
function _RESET() _T = {}; _GSN, _GSROWS = 0, 0 end
''')
L.eval('_INSTRUMENT')(ns)

fire = L.eval('''function(ev, ...)
  for _, f in ipairs(_FRAMES()) do
    if f._events[ev] and f._scripts.OnEvent then
      local ok, e = pcall(f._scripts.OnEvent, f, ev, ...)
      if not ok then print("EVENT ERROR", ev, e) end
    end
  end
end''')
tick = L.eval('''function(dt)
  _ADV(dt)
  local fr = _FRAMES()
  for i = 1, #fr do
    local f = fr[i]
    if f._shown and f._scripts.OnUpdate then
      local ok, e = pcall(f._scripts.OnUpdate, f, dt)
      if not ok then print("ONUPDATE ERROR", e) end
    end
  end
end''')
status = L.eval('''function(ns)
  local E = ns.Engine
  local tags = {}
  if E and E.scanJobs then for _, j in ipairs(E.scanJobs) do tags[#tags+1] = tostring(j.tag) end end
  return table.concat(tags, ","), ns.dataReady and "ready" or "notready"
end''')

for an, _ in nss: fire("ADDON_LOADED", an)
L.execute(r'''
  local ns = AttuneNext
  local orig = ns.GetSources
  ns.GetSources = function(id) _GSN = _GSN + 1; local r = orig(id); _GSROWS = _GSROWS + #r; return r end
''')
L.eval('_INSTRUMENT')(ns)   # the plates driver + event frame are created inside ADDON_LOADED
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
print("after login events: %.0f KB" % mem())
done = None
for i in range(1, FRAMES + 1):
    tick(0.016)
    tg, rd = status(ns)
    if rd == "ready" and tg == "" and done is None:
        done = i; print("scan finished at frame", i, "lua %.0f KB" % mem())
print("login phase: frames=%d lua %.0f KB" % (FRAMES, mem()))
L.eval('_REPORT')("login phase (frames 1..%d)" % FRAMES, 0.5)
print("plates driver: ItemLocGetSourceAt calls=%d string.gsub calls=%d" % (L.eval('_SRCAT'), L.eval('_GSUB')))
rep = L.eval('function(ns) if ns.Plates then ns.Plates.Report() end end')
rep(ns)

def run(n):
    for _ in range(n): tick(0.016)

reset = L.eval('_RESET')
report = L.eval('_REPORT')

if "steady" in SCEN:
    reset(); L.execute('_SRCAT, _GSUB = 0, 0')
    run(600)
    report("steady state, 600 frames (~10 s), NPLATES=%d" % NPLATES, 0)
    print("plates driver: ItemLocGetSourceAt=%d gsub=%d SetAlpha=%d" % (L.eval('_SRCAT'), L.eval('_GSUB'), L.eval('_SETALPHA')))
    rep(ns)

if "zone" in SCEN:
    reset(); L.execute('_SRCAT, _GSUB = 0, 0')
    fire("ZONE_CHANGED_NEW_AREA")
    run(300)
    report("zone change + 300 frames", 0.05)
    print("plates driver: ItemLocGetSourceAt=%d gsub=%d" % (L.eval('_SRCAT'), L.eval('_GSUB')))

if "attune" in SCEN:
    reset()
    L.execute('OnCustomGameData(11, 10005, 50, 100)')   # 10005 % 5 == 0 -> Progress 100 -> "done" path
    run(800)
    report("attune completion + 800 frames", 0.05)

if "mouseover" in SCEN:
    reset()
    for k in range(20):
        L.execute('_MO_ENTRY = %d' % (1000 + k))
        fire("UPDATE_MOUSEOVER_UNIT")
    run(5)
    report("20 distinct mouseovers, OBJN=%d items per entry" % OBJN, 0)
    reset()
    for k in range(20):
        L.execute('_MO_ENTRY = %d' % (1000 + k))
        fire("UPDATE_MOUSEOVER_UNIT")
    report("same 20 mouseovers again (entryCache hits)", 0)

if "tooltip" in SCEN:
    reset()
    L.execute(r'''
      GameTooltip.GetItem = function() return "Item10010", "|cffa335ee|Hitem:10010:0|h[Item10010]|h|r" end
      _TIMED("tooltip heavy item (10010, cold srcCache)", GameTooltip._scripts.OnTooltipSetItem, GameTooltip)
      _TIMED("tooltip heavy item (10010, warm)", GameTooltip._scripts.OnTooltipSetItem, GameTooltip)
      GameTooltip.GetItem = function() return "Item10011", "|cffa335ee|Hitem:10011:0|h[Item10011]|h|r" end
      _TIMED("tooltip light item (10011)", GameTooltip._scripts.OnTooltipSetItem, GameTooltip)
      GameTooltip.GetItem = function() return "Junk", "|cffa335ee|Hitem:5:0|h[Junk]|h|r" end
      _TIMED("tooltip non-attunable item", GameTooltip._scripts.OnTooltipSetItem, GameTooltip)
    ''')
    report("tooltip", 0)

if "zonewatch" in SCEN:
    reset()
    L.execute(r'''
      local ns = AttuneNext
      ns.Engine.FlushSources()
      _TIMED("ZoneWatchNow(true) cold srcCache", ns.ZoneWatchNow, true)
      _TIMED("ZoneWatchNow(true) warm", ns.ZoneWatchNow, true)
    ''')
    report("ZoneWatchNow in %s" % ("instance" if INST else "zone"), 0)

if "goalhud" in SCEN:
    reset()
    L.execute(r'''
      local ns = AttuneNext
      ns.db.goals = { { kind = "content", exp = 3, content = "R" }, { kind = "content", exp = 1, content = "D" }, { kind = "inst", map = 289 } }
      ns.db.goalHud = true
      ns.Engine.FlushSources()
      _TIMED("GoalHudNow cold (3 goals: WotLK raids, Classic dungeons, Scholomance)", ns.GoalHudNow)
      _TIMED("GoalHudNow warm (clearChanceCache hit)", ns.GoalHudNow)
      ns.Engine.InvalidateStats()
      _TIMED("GoalHudNow after InvalidateStats (srcCache warm)", ns.GoalHudNow)
    ''')
    report("GoalHud", 0)

if "platesoff" in SCEN:
    reset(); L.execute('AttuneNext.db.plates.mode = "off"; AttuneNext.Plates.Invalidate()')
    run(600)
    report("plates mode OFF, 600 frames, NPLATES=%d" % NPLATES, 0)
    L.execute('AttuneNext.db.plates.mode = "on"; AttuneNext.Plates.Invalidate()')
    run(200)

if "filters" in SCEN:
    reset(); L.execute('_SRCAT, _GSUB = 0, 0; AttuneNext.db.plates.mode = "filters"; AttuneNext.Plates.Invalidate()')
    run(400)
    report("plates mode FILTERS: Invalidate + rebuild, 400 frames", 0)
    print("plates driver: ItemLocGetSourceAt=%d gsub=%d" % (L.eval('_SRCAT'), L.eval('_GSUB')))
    L.execute('AttuneNext.db.plates.mode = "on"')

if "aura" in SCEN:
    reset()
    for k in range(2000):
        fire("UNIT_AURA", "raid%d" % (k % 25 + 1))
    run(200)
    report("2000 UNIT_AURA for raid units + 200 frames", 0)

if "bags" in SCEN:
    reset()
    L.execute('AttuneNext.db.hideInBags = true')
    for k in range(40):
        fire("BAG_UPDATE", k % 5)
    run(60)
    report("40 BAG_UPDATE with hideInBags + 60 frames", 0)

print("final lua %.0f KB" % mem())
