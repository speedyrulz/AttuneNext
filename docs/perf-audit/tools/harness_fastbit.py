"""Headless AttuneNext runner: stub WoW API + fake loot DB, track Lua memory."""
import sys, os, re, time
import lupa.lua51 as lupa

ADDON = os.environ.get("ADDON", r"C:\World of Warcraft\AttuneNext")
SV = r"C:\World of Warcraft\WTF\Account\SPEEDYRULZ\SavedVariables\AttuneNext.lua"
FRAMES = int(os.environ.get("FRAMES", "3000"))
SKIP = set(os.environ.get("SKIP", "").split(",")) - {""}
USE_SV = os.environ.get("NOSV") is None

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()

STUBS = r'''
local now = 0
function _ADV(dt) now = now + dt end
function GetTime() return now end
local t0 = os.clock()
function debugprofilestop() return (os.clock() - t0) * 1000 end
function time() return 1790000000 + math.floor(now) end
date = os.date

-- bit library: 8-bit lookup tables (4 table reads per op), stands in for the client's C LuaBitOp
bit = {}
local M32 = 4294967296
local OR8, AND8, XOR8 = {}, {}, {}
for x = 0, 255 do
  OR8[x], AND8[x], XOR8[x] = {}, {}, {}
  for y = 0, 255 do
    local o, a, e, p, xx, yy = 0, 0, 0, 1, x, y
    for i = 1, 8 do
      local bx, by = xx % 2, yy % 2
      if bx == 1 or by == 1 then o = o + p end
      if bx == 1 and by == 1 then a = a + p end
      if bx ~= by then e = e + p end
      xx, yy, p = (xx - bx) / 2, (yy - by) / 2, p * 2
    end
    OR8[x][y], AND8[x][y], XOR8[x][y] = o, a, e
  end
end
local floor = math.floor
local function op2(T, a, b)
  a, b = a % M32, b % M32
  local r, p = 0, 1
  for i = 1, 4 do
    local ca, cb = a % 256, b % 256
    r = r + T[ca][cb] * p
    a, b, p = (a - ca) / 256, (b - cb) / 256, p * 256
  end
  return r
end
function bit.band(a, b, ...) local r = op2(AND8, a, b) if ... then return bit.band(r, ...) end return r end
function bit.bor(a, b, ...) local r = op2(OR8, a, b) if ... then return bit.bor(r, ...) end return r end
function bit.bxor(a, b) return op2(XOR8, a, b) end
function bit.bnot(a) return 4294967295 - (a % M32) end
function bit.lshift(a, n) return (a * 2^n) % M32 end
function bit.rshift(a, n) return floor((a % M32) / 2^n) end

-- string / table helpers from the WoW env
strsplit = function(sep, s, n)
  local out, i = {}, 1
  for piece in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out+1] = piece end
  return unpack(out)
end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strlower, strupper, strfind, strsub, strlen, format, gsub = string.lower, string.upper, string.find, string.sub, string.len, string.format, string.gsub
tinsert, tremove, wipe = table.insert, table.remove, function(t) for k in pairs(t) do t[k] = nil end return t end
cos, sin, sqrt, atan2 = math.cos, math.sin, math.sqrt, math.atan2
floor, ceil, abs, max, min, mod = math.floor, math.ceil, math.abs, math.max, math.min, math.fmod
sort = table.sort
hooksecurefunc = function() end
issecurevariable = function() return false end

-- permissive frame objects
local FrameMT = {}
local frames = {}
local NUM = { GetWidth=200, GetHeight=20, GetScale=1, GetEffectiveScale=1, GetLeft=0, GetRight=200,
  GetTop=500, GetBottom=0, GetFrameLevel=1, GetNumPoints=0, GetStringWidth=50, GetStringHeight=12,
  GetValue=0, GetVerticalScroll=0, GetHorizontalScroll=0, GetNumLines=0, GetAlpha=1, GetID=0,
  GetVerticalScrollRange=0, GetFrameStrata="MEDIUM" }
local function newframe(name)
  local f = { _scripts = {}, _shown = true, _name = name, _events = {} }
  setmetatable(f, FrameMT)
  frames[#frames+1] = f
  if name then _G[name] = f end
  return f
end
FrameMT.__index = function(f, k)
  if k == "SetScript" then return function(self, s, fn) self._scripts[s] = fn end end
  if k == "GetScript" then return function(self, s) return self._scripts[s] end end
  if k == "HookScript" then return function(self, s, fn)
      local old = self._scripts[s]
      self._scripts[s] = function(...) if old then old(...) end return fn(...) end end end
  if k == "Show" then return function(self) self._shown = true end end
  if k == "Hide" then return function(self) self._shown = false end end
  if k == "IsShown" or k == "IsVisible" then return function(self) return self._shown end end
  if k == "SetShown" then return function(self, v) self._shown = v and true or false end end
  if k == "RegisterEvent" then return function(self, e) self._events[e] = true end end
  if k == "UnregisterEvent" then return function(self, e) self._events[e] = nil end end
  if k == "GetName" then return function(self) return self._name end end
  if k == "GetText" then return function(self) return self._text or "" end end
  if k == "SetText" then return function(self, t) self._text = t end end
  if k == "GetObjectType" then return function() return "Frame" end end
  if k == "GetParent" then return function(self) return self._parent end end
  if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
  if k == "GetChecked" then return function(self) return self._checked end end
  if k == "SetChecked" then return function(self, v) self._checked = v end end
  if k == "GetMinMaxValues" then return function() return 0, 1 end end
  if k == "NumLines" then return function() return 0 end end
  if k == "IsOwned" then return function() return false end end
  if NUM[k] ~= nil then local v = NUM[k] return function() return v end end
  if type(k) == "string" and (k:match("^Create") or k:match("Region") or k:match("^Get.*Texture$")
      or k:match("^Get.*FontString$") or k=="GetFontObject" or k=="GetScrollChild"
      or k=="GetNormalTexture" or k=="GetHighlightTexture" or k=="GetPushedTexture") then
    return function(self, name) return newframe(name) end
  end
  if type(k) == "string" and k:match("^Get") then return function() return nil end end
  if type(k) == "string" and k:match("^Is") then return function() return false end end
  return function() end
end
function CreateFrame(kind, name, parent) local f = newframe(name) f._parent = parent return f end
UIParent = newframe("UIParent"); WorldFrame = newframe("WorldFrame"); Minimap = newframe("Minimap")
GameTooltip = newframe("GameTooltip"); ItemRefTooltip = newframe("ItemRefTooltip")
WorldMapFrame = newframe("WorldMapFrame"); WorldMapFrame._shown = false
UIErrorsFrame = newframe("UIErrorsFrame"); DEFAULT_CHAT_FRAME = newframe("DEFAULT_CHAT_FRAME")
InterfaceOptionsFrame = newframe("InterfaceOptionsFrame")
GameFontHighlightSmall = newframe(); GameFontNormal = newframe(); GameFontHighlight = newframe()
GameFontNormalSmall = newframe(); GameFontNormalLarge = newframe(); GameFontDisableSmall = newframe()
UISpecialFrames = {}
SlashCmdList = {}
StaticPopupDialogs = {}
InterfaceOptions_AddCategory = function() end
InterfaceOptionsFrame_OpenToCategory = function() end
PlaySound = function() end
ChatEdit_InsertLink = function() end
IsShiftKeyDown = function() return false end
IsControlKeyDown = function() return false end
IsAltKeyDown = function() return false end
IsMouseButtonDown = function() return false end
GetCursorPosition = function() return 0, 0 end
EnumerateFrames = function() return nil end
GetScreenWidth = function() return 1920 end
GetScreenHeight = function() return 1080 end
RAID_CLASS_COLORS = setmetatable({}, {__index=function() return {r=1,g=1,b=1} end})
LOCALIZED_CLASS_NAMES_MALE = {}; LOCALIZED_CLASS_NAMES_FEMALE = {}
ITEM_QUALITY_COLORS = setmetatable({}, {__index=function() return {r=1,g=1,b=1,hex="|cffffffff"} end})
NUM_BAG_SLOTS = 4

function _FRAMES() return frames end

-- player / world
function UnitName() return "Speedyrulz" end
function UnitClass() return "Death Knight", "DEATHKNIGHT" end
function UnitRace() return "Human", "Human" end
function UnitLevel() return 80 end
function UnitFactionGroup() return "Alliance", "Alliance" end
function UnitBuff() return nil end
function UnitGUID() return "0x0000000000203C" end
function GetRealZoneText() return "Eastern Plaguelands" end
function GetZoneText() return "Eastern Plaguelands" end
function GetSubZoneText() return "Eastwall Tower" end
function IsInInstance() return false, "none" end
function GetInstanceInfo() return "Eastern Plaguelands", "none", 0 end
function GetInstanceDifficulty() return 1 end
function GetCurrentMapContinent() return 2 end
function GetCurrentMapZone() return 1 end
function GetPlayerMapPosition() return 0.5, 0.5 end
function SetMapToCurrentZone() end
function GetMoney() return 1000000 end
function GetHonorCurrency() return 0 end
function GetArenaCurrency() return 0 end
function GetCurrencyListSize() return 0 end
function GetItemCount() return 0 end
function GetInventoryItemLink() return nil end
function GetContainerNumSlots() return 0 end
function GetMerchantNumItems() return 0 end
function GetNumLootItems() return 0 end
function GetNumTradeSkills() return 0 end
function GetLocale() return "enGB" end
function GetCVar() return "0" end
function GetBuildInfo() return "3.3.5", "12340", "Jun 24 2010", 30300 end
function InCombatLockdown() return false end
function GetFramerate() return 60 end
function GetNetStats() return 0,0,50 end
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage() return 0 end
function IsAddOnLoaded() return false end
function GetNumAddOns() return 0 end

-- ===== fake Synastria item / loot DB =====
local NITEMS = tonumber(os.getenv and os.getenv("NITEMS") or "") or 20000
local BASE = 10000
local function attunable(id) return id >= BASE and id < BASE + NITEMS end
function GetItemTagsCustom(id) if attunable(id) then return 64 end return 0 end
function IsAttunableBySomeone(id) return attunable(id) and 1 or 0 end
function CanAttuneItemHelper(id) return (attunable(id) and id % 3 ~= 0) and 1 or 0 end
function GetItemAttuneProgress(id) if not attunable(id) then return 0 end return (id % 5 == 0) and 100 or (id % 7) * 10 end
function HasAttunedAnyVariantOfItem(id) return attunable(id) and id % 4 == 0 end
function GetItemAttuneForge(id) return 0 end
local READY_AT = tonumber(os.getenv("READY_AT") or "") or 0
function GetCustomGameData(a, b) if a == 41 then return (now >= READY_AT) and 1 or 0 end return 0 end
function SynastriaSafeInvoke(fname) end
function ItemLocIsLoaded() return 1 end
local function zoneItems(zoneId)
  -- deterministic slice of the item space for each zone/map id
  local out, start = {}, (zoneId * 7919) % NITEMS
  for i = 0, (tonumber(os.getenv("ZONEN") or "") or 150) - 1 do out[#out+1] = BASE + (start + i * 13) % NITEMS end
  return out
end
-- GAP experiment: WDROP "world drop" ids listed in EVERY open-world zone
-- (zoneId < 32768), each with WROWS creature rows (heavy tail).
local WDROP = tonumber(os.getenv("WDROP") or "") or 0
local WROWS = tonumber(os.getenv("WROWS") or "") or 2000
local WTOP = BASE + NITEMS - 1
local function isWdrop(id) return WDROP > 0 and id > WTOP - WDROP and id <= WTOP end
function ItemLocGetAllItemsInZone(zoneId)
  local out = zoneItems(zoneId)
  if WDROP > 0 and zoneId < 32768 then
    for k = 0, WDROP - 1 do out[#out+1] = WTOP - k end
  end
  return out
end
_WD = { calls = 0, rows = 0, maxms = 0 }
local HEAVY = tonumber(os.getenv("HEAVY") or "") or 0
function ItemLocGetSourceCount(id) if isWdrop(id) then return WROWS end if attunable(id) then if HEAVY > 0 and id % 10 == 0 then return HEAVY end return 1 + id % 3 end return 0 end
local types = {0, 1, 2, 9, 0, 6}
local ZNAMES = os.getenv("ZNAMES") == "1"
local REALZ = {"Elwynn Forest","Westfall","Redridge Mountains","Duskwood","Stranglethorn Vale","Swamp of Sorrows","Blasted Lands","Deadwind Pass","Burning Steppes","Searing Gorge","Badlands","Loch Modan","Dun Morogh","Wetlands","Arathi Highlands","Hillsbrad Foothills","Alterac Mountains","Silverpine Forest","Tirisfal Glades","Western Plaguelands","Eastern Plaguelands","The Hinterlands","Durotar","The Barrens","Mulgore","Stonetalon Mountains","Ashenvale","Teldrassil","Darkshore","Azshara","Felwood","Winterspring","Moonglade","Desolace","Feralas","Dustwallow Marsh","Thousand Needles","Tanaris","Un'Goro Crater","Silithus","Stormwind City","Ironforge","Darnassus","Orgrimmar","Thunder Bluff","Undercity","Eversong Woods","Ghostlands","Azuremyst Isle","Bloodmyst Isle","Hellfire Peninsula","Zangarmarsh","Terokkar Forest","Nagrand","Blade's Edge Mountains","Netherstorm","Shadowmoon Valley","Isle of Quel'Danas","Silvermoon City","The Exodar","Shattrath City","Borean Tundra","Howling Fjord","Dragonblight","Grizzly Hills","Zul'Drak","Sholazar Basin","Crystalsong Forest","The Storm Peaks","Icecrown","Wintergrasp","Dalaran"}
local function zname(i) if ZNAMES then return REALZ[(i % #REALZ) + 1] end return "Zone" .. (i % 60) end
function ItemLocGetSourceAt(id, i)
  if isWdrop(id) then return 0, 0, 1000 + (i % 5000), 0.5, 5, "Mob" .. (i % 5000), zname(i), 1 end
  local st = types[(id + i) % #types + 1]
  return st, 0, 1000 + ((id + i) % 5000), 5 + (id % 20), 50, "Mob" .. ((id + i) % 5000), zname(i), 1
end
function ItemLocGetObjCount() return 0 end
function ItemLocGetObjAt() return nil end
function GetItemInfo(id)
  if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) end
  if not id or not attunable(id) then return nil end
  return "Item" .. id, "|cffa335ee|Hitem:" .. id .. ":0|h[Item" .. id .. "]|h|r", 4, 200, 70,
    "Armor", "Plate", 1, "INVTYPE_CHEST", "Interface\\Icons\\INV_Misc_QuestionMark", 1000
end
function GetItemInfoCustom(id) return GetItemInfo(id) end
'''
L.execute(STUBS)

def missing_global_tracker():
    L.execute(r'''
    _MISSING = {}
    setmetatable(_G, { __index = function(t, k)
        _MISSING[k] = (_MISSING[k] or 0) + 1
        return nil
    end })
    ''')

if USE_SV and os.path.exists(SV):
    L.execute(open(SV, encoding="utf-8", errors="replace").read())
    print("loaded SavedVariables:", SV)

missing_global_tracker()


ADDONS = os.environ.get("ADDONS", ADDON + "|AttuneNext").split(";")
SIMPLE_SV = r"C:\World of Warcraft\WTF\Account\SPEEDYRULZ\SavedVariables\AttuneNext-Simple.lua"
loader = L.eval("""function(src, name, aname, ns)
  local fn, err = loadstring(src, "@" .. aname .. "/" .. name)
  if not fn then return false, err end
  local ok, e = pcall(fn, aname, ns)
  return ok, e
end""")
nss = []
for spec in ADDONS:
    path, aname = spec.split("|")
    if aname == "AttuneNext-Simple" and USE_SV and os.path.exists(SIMPLE_SV):
        L.execute(open(SIMPLE_SV, encoding="utf-8", errors="replace").read())
    ns_ = L.table()
    toc = open(os.path.join(path, aname + ".toc"), encoding="utf-8-sig").read().splitlines()
    for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
        if f in SKIP: continue
        ok, err = loader(open(os.path.join(path, f), encoding="utf-8").read(), f, aname, ns_)
        if not ok: print("LOAD ERROR", aname, f, err)
    nss.append((aname, ns_))
ns = nss[0][1]
mem = L.eval('function() return collectgarbage("count") end')
print("after load: %.0f KB" % mem())

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
  local errs = 0
  local fr = _FRAMES()
  for i = 1, #fr do
    local f = fr[i]
    if f._shown and f._scripts.OnUpdate then
      local ok, e = pcall(f._scripts.OnUpdate, f, dt)
      if not ok then errs = errs + 1; if errs < 3 then print("ONUPDATE ERROR", e) end end
    end
  end
end''')
status = L.eval('''function(ns)
  local E = ns.Engine
  local tags = {}
  if E and E.scanJobs then for _, j in ipairs(E.scanJobs) do tags[#tags+1] = tostring(j.tag) .. (j.extra and ("+" .. #j.extra) or "") end end
  return table.concat(tags, ","), ns.dataReady and "ready" or "notready"
end''')

if os.environ.get("ALLOC"):
    L.execute(r'''
    _ALLOC = {}
    local last = collectgarbage("count")
    local function hook()
      local c = collectgarbage("count")
      local d = c - last
      last = c
      if d > 0 then
        local info = debug.getinfo(2, "Sl")
        local key = info and (info.short_src .. ":" .. (info.currentline or 0)) or "?"
        _ALLOC[key] = (_ALLOC[key] or 0) + d
      end
    end
    function _HOOKON() debug.sethook(hook, "", 200) end
    ''')
if os.environ.get("PROBE_RESUME"):
    L.execute(r'''
    local orig = coroutine.resume
    _SLOWRES = {}
    coroutine.resume = function(co, ...)
      local t0 = os.clock()
      local a, b, c = orig(co, ...)
      local ms = (os.clock() - t0) * 1000
      if ms > tonumber(os.getenv("PROBE_RESUME")) then
        local tb = debug.traceback(co, "", 1):gsub("\n%s*", " <- "):sub(1, 400)
        _SLOWRES[#_SLOWRES+1] = string.format("%.0f ms at t=%.1fs %s", ms, GetTime(), tb)
      end
      return a, b, c
    end
    ''')
for an, _ in nss: fire("ADDON_LOADED", an)
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
print("after login events: %.0f KB" % mem())
L.execute(r'''
  _GSN, _GSU, _GSROWS = 0, {}, 0
''')
L.execute(r'''
  _GSTAG = {}   -- tag -> {calls, rows}
  _FLUSH = 0
''')
wrap = L.eval(r'''function(ns)
  local orig = ns.GetSources
  local E = ns.Engine
  ns.GetSources = function(id)
    _GSN = _GSN + 1; _GSU[id] = true
    local r = orig(id); _GSROWS = _GSROWS + #r
    local tag = (coroutine.running() and E.scanJobs[1] and tostring(E.scanJobs[1].tag)) or "main"
    local t = _GSTAG[tag]; if not t then t = {0, 0}; _GSTAG[tag] = t end
    t[1] = t[1] + 1; t[2] = t[2] + #r
    return r
  end
end''')
for _, n_ in nss: wrap(n_)
peak = 0
t0 = time.time()
if os.environ.get("ALLOC"):
    # hooks are per-coroutine in 5.1: wrap coroutine.create so jobs inherit it
    L.execute(r'''
    local cc = coroutine.create
    coroutine.create = function(fn) return cc(function(...) _HOOKON() return fn(...) end) end
    _HOOKON()
    ''')
_ft = []
_frows = []
_ftag = []
_prevrows = 0
SIMUI = int(os.environ.get("SIMUI", "0"))
SRCSTATS = int(os.environ.get("SRCSTATS", "0"))
EXTRA = int(os.environ.get("EXTRA", "0"))
RELOGIN = int(os.environ.get("RELOGIN", "0"))
PICKDROP = int(os.environ.get("PICKDROP", "0"))
pickdrop = L.eval(r'''function(ns)
  ns.db.anext.dropRate = true
  ns.Engine.InvalidateStats()
  local t0, r0, n0 = os.clock(), _GSROWS, _GSN
  local id, n = ns.Engine.AttuneNextPick(nil, { cfg = "btn" })
  return (os.clock() - t0) * 1000, _GSROWS - r0, _GSN - n0, tostring(id), n or -1
end''')
extra_rank = L.eval(r'''function(ns)
  local E = ns.Engine
  local t0, r0, n0 = os.clock(), _GSROWS, _GSN
  local runs = E.RankZoneRuns(nil, false, "btn")
  local top = runs[1] and (runs[1].zone.name .. "=" .. string.format("%.2f", runs[1].expected)) or "none"
  return (os.clock() - t0) * 1000, _GSROWS - r0, _GSN - n0, #runs, top
end''')
extra_sources = L.eval(r'''function(ns, id)
  local t0, r0, n0 = os.clock(), _GSROWS, _GSN
  local rows = ns.UI.BuildRows({ type = "sources", itemId = id })
  return (os.clock() - t0) * 1000, _GSROWS - r0, _GSN - n0, #rows
end''')
extra_tip = L.eval(r'''function(ns, id)
  ns.Engine.FlushSources()
  local t0, r0, n0 = os.clock(), _GSROWS, _GSN
  local c = ns.Engine.BestSource(id)
  return (os.clock() - t0) * 1000, _GSROWS - r0, _GSN - n0
end''')
g["_NS"] = ns     # frame at which to simulate the Classic zone-list (W) render
ZW_AT = int(os.environ.get("ZONEWATCH", "0")) # frame at which to call ANx.ZoneWatchNow(true) inline
simui = L.eval(r'''function(ns, exp)
  local E = ns.Engine
  local t0 = os.clock()
  local r0 = _GSROWS
  local n0 = _GSN
  local zones, ready, tot = E.ZonesFor(exp, false), 0, 0
  for _, z in ipairs(zones) do
    if E.ZoneReady(z) then
      ready = ready + 1
      local zc = E.ZoneData(z)
      local st = E.StatsWithBest(zc.world, "zw:" .. z.zone .. ":A", z.name, ns.WORLD_DROP_SRC)
      tot = tot + st.total
    end
  end
  return (os.clock() - t0) * 1000, #zones, ready, tot, _GSROWS - r0, _GSN - n0
end''')
zonewatch = L.eval(r'''function(ns)
  local t0 = os.clock()
  local r0 = _GSROWS
  local n0 = _GSN
  ns.ZoneWatchNow(true)
  return (os.clock() - t0) * 1000, _GSROWS - r0, _GSN - n0
end''')
for i in range(1, FRAMES + 1):
    _t = time.perf_counter(); tick(0.016); _ft.append((time.perf_counter() - _t) * 1000)
    _r = L.eval('_GSROWS'); _frows.append(_r - _prevrows); _prevrows = _r
    _ftag.append(status(ns)[0][:40])
    if SIMUI and i == SIMUI:
        for exp in (1, 2, 3):
            ms, nz, nready, tot, rows, calls = simui(ns, exp)
            print("SIMUI frame %d exp%d: zone-list W render %.0f ms, zones %d ready %d, total items %d, rows built %d, GetSources calls %d" % (i, exp, ms, nz, nready, tot, rows, calls))
        ms, nz, nready, tot, rows, calls = simui(ns, 1)
        print("SIMUI frame %d exp1 AGAIN (statsCache warm): %.0f ms, rows built %d" % (i, ms, rows))
    if SRCSTATS and i == SRCSTATS:
        L.execute('_NS.Print = function(s) print("CHAT: " .. tostring(s)) end')
        L.eval('function() SlashCmdList.ATTUNENEXT("srcstats") end')()
        print("SRCSTATS enqueued at frame", i)
    if RELOGIN and i == RELOGIN:
        L.execute('_RL_ROWS, _RL_N = _GSROWS, _GSN')
        L.eval('function() AttuneNext_OnDataReady() end')()
        _rl_tags = set(); _rl_busy = 0; _rl_ms = 0.0
        print("RELOGIN fired at frame %d (structCache present: %s)" % (i, L.eval('function(ns) return ns.db.structCache ~= nil end')(ns)))
    if RELOGIN and i > RELOGIN:
        tg = status(ns)[0]
        if tg: _rl_tags.update(tg.split(",")); _rl_busy += 1; _rl_ms += _ft[-1]
        if i == RELOGIN + 200:
            print("RELOGIN +200 frames: busy frames %d, %.0f ms, job tags %s, rows built %d, GetSources calls %d" % (_rl_busy, _rl_ms, sorted(_rl_tags), L.eval('_GSROWS - _RL_ROWS'), L.eval('_GSN - _RL_N')))
    if PICKDROP and i == PICKDROP:
        ms, rows, calls, pick, n = pickdrop(ns)
        print("PICKDROP frame %d: AttuneNextPick(dropRate) %.0f ms, rows built %d, GetSources calls %d, pick %s pool %d" % (i, ms, rows, calls, pick, n))
    if EXTRA and i == EXTRA:
        ms, rows, calls, nruns, top = extra_rank(ns)
        print("RANKZONES frame %d: RankZoneRuns %.0f ms, rows built %d, GetSources calls %d, runs %d, top %s" % (i, ms, rows, calls, nruns, top))
        ms, rows, calls, nruns, top = extra_rank(ns)
        print("RANKZONES AGAIN (memo warm): %.0f ms, rows built %d, GetSources calls %d" % (ms, rows, calls))
        for wid in (29999, 29998):
            ms, rows, calls, n = extra_sources(ns, wid)
            print("SOURCES SCREEN item %d: build %.0f ms, rows built %d, GetSources calls %d, display rows %d" % (wid, ms, rows, calls, n))
        ms, rows, calls = extra_tip(ns, 29997)
        print("TOOLTIP BestSource cold item 29997: %.2f ms, rows built %d, GetSources calls %d" % (ms, rows, calls))
    if ZW_AT and i == ZW_AT:
        ms, rows, calls = zonewatch(ns)
        print("ZONEWATCH frame %d: ZoneWatchNow %.0f ms, rows built %d, GetSources calls %d, jobs=[%s]" % (i, ms, rows, calls, status(ns)[0][:60]))
    m = mem()
    peak = max(peak, m)
    if i % (FRAMES // 30 or 1) == 0:
        tags, rd = status(ns)
        print("frame %5d  lua %8.0f KB  %s  jobs=[%s]" % (i, m, rd, tags[:150]))
    tg, rd = status(ns)
    if rd == "ready" and tg == "" and not globals().get("_done"):
        globals()["_done"] = i; print("scan finished at frame", i)
    if m > 1500000:
        print("RUNAWAY at frame", i, "%.0f KB" % m)
        break
print("peak %.0f KB, %.1fs" % (peak, time.time() - t0))
_d = globals().get("_done") or FRAMES
_scan = [x for x in _ft[:_d] if x > 1.0]
print("frames>1ms during scan: %d  avg %.1f ms  max %.1f ms  total %.0f ms; worst frame index %d" % (len(_scan), sum(_scan)/max(1,len(_scan)), max(_ft), sum(_ft), _ft.index(max(_ft))+1))
if os.environ.get("ALLOC"):
    a = L.eval('_ALLOC')
    rows = sorted(((k, v) for k, v in a.items()), key=lambda x: -x[1])[:25]
    tot = sum(v for _, v in a.items())
    print("total allocated ~%.0f MB" % (tot / 1024))
    for k, v in rows: print("%9.0f KB  %s" % (v, k))
_top = sorted(range(len(_ft)), key=lambda k: -_ft[k])[:6]
print("top frames by ms:", ", ".join("f%d %.0fms/%drows[%s]" % (k+1, _ft[k], _frows[k], _ftag[k][:14]) for k in _top))
_topr = sorted(range(len(_frows)), key=lambda k: -_frows[k])[:6]
print("top frames by rows:", ", ".join("f%d %drows/%.0fms[%s]" % (k+1, _frows[k], _ft[k], _ftag[k][:14]) for k in _topr))
_w = [k for k in range(len(_ftag)) if _ftag[k].startswith("warmup")]
if _w: print("warmup job frames %d..%d (%d frames), rows built in them %d, ms %.0f" % (_w[0]+1, _w[-1]+1, len(_w), sum(_frows[k] for k in _w), sum(_ft[k] for k in _w)))
_s = [k for k in range(len(_ftag)) if _ftag[k].startswith("summary")]
if _s: print("summary job frames %d..%d (%d frames), rows built in them %d, ms %.0f, max frame %.0f ms" % (_s[0]+1, _s[-1]+1, len(_s), sum(_frows[k] for k in _s), sum(_ft[k] for k in _s), max(_ft[k] for k in _s)))
_gt = L.eval('_GSTAG')
print("GetSources by job tag:", "; ".join("%s: %d calls / %d rows" % (k, v[1], v[2]) for k, v in sorted(_gt.items(), key=lambda kv: -kv[1][2])))
try:
    ps = L.eval('function(ns) local p = ns.Engine.PerfStats() local out = {} for k, v in pairs(p) do out[#out+1] = tostring(k) .. "=" .. tostring(v) end table.sort(out) return table.concat(out, " ") end')(ns)
    print("PerfStats:", ps)
except Exception as e:
    print("PerfStats err", e)
if os.environ.get("PROBE_RESUME"):
    sl = L.eval('_SLOWRES')
    print("slow resumes (%d):" % len(sl))
    for k in range(1, min(len(sl), 25) + 1): print("  ", sl[k])
print("GetSources calls:", L.eval('_GSN'), "unique items:", L.eval('(function() local n=0 for _ in pairs(_GSU) do n=n+1 end return n end)()'), "rows built:", L.eval('_GSROWS'))
miss = L.eval('_MISSING')
print("missing globals read:", sorted(((k, v) for k, v in miss.items()), key=lambda x: -x[1])[:40])

if os.environ.get("PROFILE"):
    prof = L.eval(r'''function(ns)
  local seen = {}
  local function sz(v)
    local t = type(v)
    if t == "string" then if seen[v] then return 0 end seen[v] = true return 24 + #v end
    if t == "function" then
      if seen[v] then return 0 end seen[v] = true
      local n, i = 40, 1
      while true do local name, uv = debug.getupvalue(v, i) if not name then break end n = n + sz(uv) i = i + 1 end
      return n
    end
    if t ~= "table" then return 0 end
    if seen[v] then return 0 end
    seen[v] = true
    local n = 40
    for k, x in pairs(v) do n = n + 40 + sz(k) + sz(x) end
    return n
  end
  seen[ns] = true
  seen[ns.Engine] = true
  if ns.UI then seen[ns.UI] = true end
  for k, f in pairs(ns.Engine) do if type(f) == 'function' then seen[f] = true end end
  local out = {}
  -- Engine upvalues first (private caches), largest wins attribution
  local E = ns.Engine
  local upv = {}
  for k, f in pairs(E) do
    if type(f) == "function" then
      local i = 1
      while true do
        local name, uv = debug.getupvalue(f, i)
        if not name then break end
        if type(uv) == "table" and not upv[name] then upv[name] = uv end
        i = i + 1
      end
    end
  end
  upv.Engine = nil; upv.ANx = nil
  for name, t in pairs(upv) do out[#out+1] = { "Engine." .. name, sz(t) } end
  for k, v in pairs(ns) do out[#out+1] = { "ANx." .. tostring(k), sz(v) } end
  out[#out+1] = { "AttuneNextDB", sz(AttuneNextDB) }
  table.sort(out, function(a, b) return a[2] > b[2] end)
  local lines = {}
  for i = 1, 25 do if out[i] then lines[#lines+1] = string.format("%10.0f KB  %s", out[i][2] / 1024, out[i][1]) end end
  return table.concat(lines, "\n")
end''')
    L.eval('collectgarbage("collect")')
    print("after full GC: %.0f KB" % mem())
    print(prof(ns))
