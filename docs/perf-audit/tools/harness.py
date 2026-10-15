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

-- bit library (WoW provides it; lua 5.1 does not)
bit = {}
local function tobits(n) n = n % 4294967296 return n end
function bit.band(a, b, ...)
  a, b = tobits(a), tobits(b)
  local r, p = 0, 1
  for i = 1, 32 do
    if a % 2 == 1 and b % 2 == 1 then r = r + p end
    a, b, p = math.floor(a/2), math.floor(b/2), p*2
  end
  if ... then return bit.band(r, ...) end
  return r
end
function bit.bor(a, b, ...)
  a, b = tobits(a), tobits(b)
  local r, p = 0, 1
  for i = 1, 32 do
    if a % 2 == 1 or b % 2 == 1 then r = r + p end
    a, b, p = math.floor(a/2), math.floor(b/2), p*2
  end
  if ... then return bit.bor(r, ...) end
  return r
end
function bit.bxor(a, b)
  a, b = tobits(a), tobits(b)
  local r, p = 0, 1
  for i = 1, 32 do
    if (a % 2) ~= (b % 2) then r = r + p end
    a, b, p = math.floor(a/2), math.floor(b/2), p*2
  end
  return r
end
function bit.bnot(a) return 4294967295 - tobits(a) end
function bit.lshift(a, n) return tobits(a * 2^n) end
function bit.rshift(a, n) return math.floor(tobits(a) / 2^n) end

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
function ItemLocGetAllItemsInZone(zoneId) return zoneItems(zoneId) end
local HEAVY = tonumber(os.getenv("HEAVY") or "") or 0
function ItemLocGetSourceCount(id) if attunable(id) then if HEAVY > 0 and id % 10 == 0 then return HEAVY end return 1 + id % 3 end return 0 end
local types = {0, 1, 2, 9, 0, 6}
function ItemLocGetSourceAt(id, i)
  local st = types[(id + i) % #types + 1]
  return st, 0, 1000 + ((id + i) % 5000), 5 + (id % 20), 50, "Mob" .. ((id + i) % 5000), "Zone" .. (i % 60), 1
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
  collectgarbage("collect")
  local m0 = collectgarbage("count")
  local c0 = os.clock()
  local fn, err = loadstring(src, "@" .. aname .. "/" .. name)
  if not fn then return false, err end
  local c1 = os.clock()
  local ok, e = pcall(fn, aname, ns)
  local c2 = os.clock()
  collectgarbage("collect")
  local m1 = collectgarbage("count")
  return ok, e, (c1 - c0) * 1000, (c2 - c1) * 1000, m1 - m0
end""")
_ROWS = []
nss = []
for spec in ADDONS:
    path, aname = spec.split("|")
    if aname == "AttuneNext-Simple" and USE_SV and os.path.exists(SIMPLE_SV):
        L.execute(open(SIMPLE_SV, encoding="utf-8", errors="replace").read())
    ns_ = L.table()
    toc = open(os.path.join(path, aname + ".toc"), encoding="utf-8-sig").read().splitlines()
    for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
        if f in SKIP: continue
        _r = loader(open(os.path.join(path, f), encoding="utf-8").read(), f, aname, ns_)
        ok, err = _r[0], _r[1]
        if not ok: print("LOAD ERROR", aname, f, err)
        else: _ROWS.append((f, _r[2], _r[3], _r[4], os.path.getsize(os.path.join(path, f))))
    nss.append((aname, ns_))
ns = nss[0][1]
mem = L.eval('function() return collectgarbage("count") end')
if os.environ.get("LOADPROF"):
    print("%-26s %8s %8s %8s %9s" % ("file", "compile", "exec ms", "ret KB", "bytes"))
    for f, c, e, m, b in sorted(_ROWS, key=lambda r: -(r[1]+r[2])):
        print("%-26s %8.2f %8.2f %8.0f %9d" % (f, c, e, m, b))
    print("TOTAL compile %.1f ms, exec %.1f ms, retained %.0f KB" % (sum(r[1] for r in _ROWS), sum(r[2] for r in _ROWS), sum(r[3] for r in _ROWS)))
    if os.environ.get("LOADPROF") == "only": sys.exit(0)
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
for an, _ in nss: fire("ADDON_LOADED", an)
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
print("after login events: %.0f KB" % mem())
L.execute(r'''
  _GSN, _GSU, _GSROWS = 0, {}, 0
''')
wrap = L.eval(r'''function(ns)
  local orig = ns.GetSources
  _GSCALLERS = {}
  ns.GetSources = function(id)
    _GSN = _GSN + 1; _GSU[id] = true
    local r = orig(id); _GSROWS = _GSROWS + #r
    if os.getenv("CALLERS") then
      local parts = {}
      for lvl = 2, 6 do
        local info = debug.getinfo(lvl, "Sl")
        if not info then break end
        parts[#parts+1] = info.short_src:match("[^/]*$") .. ":" .. (info.currentline or 0)
      end
      local key = table.concat(parts, " < ")
      local c = _GSCALLERS[key] or {0, 0}
      c[1] = c[1] + 1; c[2] = c[2] + #r
      _GSCALLERS[key] = c
    end
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
for i in range(1, FRAMES + 1):
    tick(0.016)
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
if os.environ.get("ALLOC"):
    a = L.eval('_ALLOC')
    rows = sorted(((k, v) for k, v in a.items()), key=lambda x: -x[1])[:25]
    tot = sum(v for _, v in a.items())
    print("total allocated ~%.0f MB" % (tot / 1024))
    for k, v in rows: print("%9.0f KB  %s" % (v, k))
if os.environ.get("CALLERS"):
    cs = L.eval('_GSCALLERS')
    for k, v in sorted(((k, v) for k, v in cs.items()), key=lambda x: -x[1][2])[:15]:
        print("%7d calls %9d rows  %s" % (v[1], v[2], k))
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
