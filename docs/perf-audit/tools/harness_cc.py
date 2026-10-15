"""Client-C-call counting harness for AttuneNext.

Models the costs the stock harness stubs as free: a client item cache that
starts partially cold (CACHEPCT), tooltips whose SetHyperlink either fills
lines (cached) or emits a server query that resolves QUERY_DELAY seconds later,
GetItemCount against a modelled bag set, GetStringWidth proportional to text.
Counts every such C call per scenario phase.

Env: ADDON, NITEMS, ZONEN, HEAVY, READY_AT, FRAMES, CACHEPCT (0-100),
QUERY_DELAY (s), FILTERS (comma: bind,faction,class,bags), SCEN (comma:
ui_inst,bags,fresh,search,paint,home,fac_later,cls_later).
"""
import sys, os, re, time
import lupa.lua51 as lupa

ADDON = os.environ.get("ADDON", "/home/user/AttuneNext")
FRAMES = int(os.environ.get("FRAMES", "1500"))
CACHEPCT = int(os.environ.get("CACHEPCT", "100"))
QUERY_DELAY = float(os.environ.get("QUERY_DELAY", "0.5"))
FILTERS = set(os.environ.get("FILTERS", "").split(",")) - {""}
SCEN = set(os.environ.get("SCEN", "").split(",")) - {""}

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()

STUBS = r'''
local now = 0
_CC = {}
local CC = _CC
local function N(k) CC[k] = (CC[k] or 0) + 1 end
_N = N
_PENDING = {}
_CACHED = {}
_QUERIES = 0
function _ADV(dt)
  now = now + dt
  local i = 1
  while i <= #_PENDING do
    local p = _PENDING[i]
    if now >= p.at then _CACHED[p.id] = true; table.remove(_PENDING, i) else i = i + 1 end
  end
end
function GetTime() return now end
local t0 = os.clock()
function debugprofilestop() return (os.clock() - t0) * 1000 end
function time() return 1790000000 + math.floor(now) end
date = os.date

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

ITEM_BIND_ON_PICKUP = "Binds when picked up"
ITEM_SOULBOUND = "Soulbound"
ITEM_BIND_ON_EQUIP = "Binds when equipped"
ITEM_BIND_ON_USE = "Binds when used"
ITEM_CLASSES_ALLOWED = "Classes: %s"
LOCALIZED_CLASS_NAMES_MALE = { WARRIOR="Warrior", PALADIN="Paladin", HUNTER="Hunter", ROGUE="Rogue",
  PRIEST="Priest", DEATHKNIGHT="Death Knight", SHAMAN="Shaman", MAGE="Mage", WARLOCK="Warlock", DRUID="Druid" }
LOCALIZED_CLASS_NAMES_FEMALE = {}

-- the modelled item cache
local NITEMS = tonumber(os.getenv("NITEMS") or "") or 20000
local BASE = 10000
local CACHEPCT = tonumber(os.getenv("CACHEPCT") or "") or 100
local QUERY_DELAY = tonumber(os.getenv("QUERY_DELAY") or "") or 0.5
local function attunable(id) return id >= BASE and id < BASE + NITEMS end
for id = BASE, BASE + NITEMS - 1 do
  if (id * 37) % 100 < CACHEPCT then _CACHED[id] = true end
end
local function cached(id) return _CACHED[id] == true end
local function query(id)
  if cached(id) then return end
  _QUERIES = _QUERIES + 1
  _PENDING[#_PENDING + 1] = { id = id, at = now + QUERY_DELAY }
end
function _NCACHED() local n = 0 for _ in pairs(_CACHED) do n = n + 1 end return n end

-- tooltip text model per item
local function fillTip(tip, id)
  local name = tip._name
  local lines = {}
  lines[1] = { "Item" .. id }
  local m = id % 3
  lines[2] = { (m == 0) and ITEM_BIND_ON_PICKUP or (m == 1) and ITEM_BIND_ON_EQUIP or "Unique" }
  lines[3] = { "Chest", "Plate" }
  lines[4] = { (id % 7 == 0) and "Classes: Warrior, Paladin" or "120 Armor" }
  lines[5] = { (id % 11 == 0) and "Faction:" or "+10 Strength", (id % 11 == 0) and "Alliance" or nil }
  lines[6] = { "+10 Stamina" }
  lines[7] = { "Durability 100 / 100" }
  lines[8] = { "Requires Level 70" }
  for i = 1, 8 do
    local l = _G[name .. "TextLeft" .. i]
    local r = _G[name .. "TextRight" .. i]
    if l then l._text = lines[i][1] end
    if r then r._text = lines[i][2] end
  end
  tip._n = 8
end

-- permissive frame objects
local FrameMT = {}
local frames = {}
local NUM = { GetWidth=200, GetHeight=20, GetScale=1, GetEffectiveScale=1, GetLeft=0, GetRight=200,
  GetTop=500, GetBottom=0, GetFrameLevel=1, GetNumPoints=0, GetStringHeight=12, GetNumRegions=0, GetNumChildren=0,
  GetValue=0, GetVerticalScroll=0, GetHorizontalScroll=0, GetNumLines=0, GetAlpha=1, GetID=0,
  GetVerticalScrollRange=0, GetFrameStrata="MEDIUM" }
local function newframe(name)
  local f = { _scripts = {}, _shown = true, _name = name, _events = {} }
  setmetatable(f, FrameMT)
  frames[#frames+1] = f
  if name then _G[name] = f end
  return f
end
local function visibleLen(t)
  t = tostring(t or "")
  t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return #t
end
FrameMT.__index = function(f, k)
  -- addon-owned fields are lowercase / underscore; WoW methods are CapitalCase
  if type(k) ~= "string" or not string.find(k, "^%u") then return nil end
  if k == "GetRegions" or k == "GetChildren" then return function() return nil end end
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
  if k == "GetText" then return function(self) N("GetText") return self._text end end
  if k == "SetText" then return function(self, t) N("SetText") self._text = t end end
  if k == "GetStringWidth" then return function(self) N("GetStringWidth") return 6.5 * visibleLen(self._text) end end
  if k == "SetHyperlink" then return function(self, link)
      N("SetHyperlink")
      local nm = self._name or "?"
      CC["SetHyperlink@" .. nm] = (CC["SetHyperlink@" .. nm] or 0) + 1
      local id = tonumber(tostring(link):match("item:(%d+)"))
      self._item = id
      if id and attunable(id) and cached(id) then fillTip(self, id)
      else
        self._n = 0
        if id then query(id) end
        CC["SetHyperlink_uncached"] = (CC["SetHyperlink_uncached"] or 0) + 1
      end
    end end
  if k == "NumLines" then return function(self) N("NumLines") return self._n or 0 end end
  if k == "ClearLines" then return function(self) N("ClearLines") self._n = 0 end end
  if k == "GetObjectType" then return function() return "Frame" end end
  if k == "GetParent" then return function(self) return self._parent end end
  if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
  if k == "GetChecked" then return function(self) return self._checked end end
  if k == "SetChecked" then return function(self, v) self._checked = v end end
  if k == "GetMinMaxValues" then return function() return 0, 1 end end
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
function CreateFrame(kind, name, parent)
  local f = newframe(name) f._parent = parent
  if kind == "GameTooltip" and name then
    for i = 1, 12 do newframe(name .. "TextLeft" .. i); newframe(name .. "TextRight" .. i) end
  end
  return f
end
UIParent = newframe("UIParent"); WorldFrame = newframe("WorldFrame"); Minimap = newframe("Minimap")
GameTooltip = CreateFrame("GameTooltip", "GameTooltip"); ItemRefTooltip = CreateFrame("GameTooltip", "ItemRefTooltip")
WorldMapFrame = newframe("WorldMapFrame"); WorldMapFrame._shown = false
UIErrorsFrame = newframe("UIErrorsFrame"); DEFAULT_CHAT_FRAME = newframe("DEFAULT_CHAT_FRAME")
_CHAT = {}
DEFAULT_CHAT_FRAME.AddMessage = function(self, msg)
  msg = tostring(msg)
  _CHAT[msg] = (_CHAT[msg] or 0) + 1
  if _CHAT[msg] <= 3 then print("CHAT: " .. msg) end
end
InterfaceOptionsFrame = newframe("InterfaceOptionsFrame")
GameFontHighlightSmall = newframe(); GameFontNormal = newframe(); GameFontHighlight = newframe()
GameFontNormalSmall = newframe(); GameFontNormalLarge = newframe(); GameFontDisableSmall = newframe()
GameFontNormalHuge = GameFontNormal
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
ITEM_QUALITY_COLORS = setmetatable({}, {__index=function() return {r=1,g=1,b=1,hex="|cffffffff"} end})
NUM_BAG_SLOTS = 4
FauxScrollFrame_Update = function() end
FauxScrollFrame_GetOffset = function(f) return f._offset or 0 end
FauxScrollFrame_OnVerticalScroll = function(self, offset, h, fn) self._offset = math.floor(offset / h) fn() end

function _FRAMES() return frames end

function UnitName() return "Speedyrulz" end
function UnitClass() return "Warrior", "WARRIOR" end
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

-- bag model: 30 owned attunable ids spread over the universe, 5 bags x 16 slots
_OWNED = {}
_BAGS = {}
do
  local k = 0
  for b = 0, 4 do
    _BAGS[b] = {}
    for s = 1, 16 do
      if (s % 3) == 0 and k < 30 then
        local id = BASE + k * 613
        _OWNED[id] = true; _BAGS[b][s] = id; k = k + 1
      end
    end
  end
end
function GetItemCount(id, bank) N("GetItemCount") return _OWNED[id] and 1 or 0 end
function GetInventoryItemLink(unit, slot) N("GetInventoryItemLink") return nil end
function GetContainerNumSlots(bag) N("GetContainerNumSlots") if bag == -1 then return 28 end if _BAGS[bag] then return 16 end return 0 end
function GetContainerItemLink(bag, slot)
  N("GetContainerItemLink")
  local id = _BAGS[bag] and _BAGS[bag][slot]
  if id then return "|cffa335ee|Hitem:" .. id .. ":0|h[Item" .. id .. "]|h|r" end
  return nil
end
function GetContainerItemID(bag, slot) N("GetContainerItemID") return _BAGS[bag] and _BAGS[bag][slot] end
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
  N("GetItemInfo")
  if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) end
  if not id or not attunable(id) or not cached(id) then return nil end
  return "Item" .. id, "|cffa335ee|Hitem:" .. id .. ":0|h[Item" .. id .. "]|h|r", 4, 200, 70,
    "Armor", "Plate", 1, "INVTYPE_CHEST", "Interface\\Icons\\INV_Misc_QuestionMark", 1000
end
function GetItemInfoCustom(id) N("GetItemInfoCustom") return GetItemInfo(id) end
'''
L.execute(STUBS)

# saved settings per FILTERS
db = []
if "bind" in FILTERS: db.append('bindFilter = "bop"')
if "faction" in FILTERS: db.append('faction = "A"')
if "class" in FILTERS: db.append('prestige = true, classFilter = "WARRIOR"')
if "bags" in FILTERS: db.append('hideInBags = true')
L.execute("AttuneNextDB = { %s }" % ", ".join(db))

L.execute(r'''
_MISSING = {}
setmetatable(_G, { __index = function(t, k) _MISSING[k] = (_MISSING[k] or 0) + 1 return nil end })
''')

loader = L.eval("""function(src, name, aname, ns)
  local fn, err = loadstring(src, "@" .. aname .. "/" .. name)
  if not fn then return false, err end
  local ok, e = pcall(fn, aname, ns)
  return ok, e
end""")
ns = L.table()
toc = open(os.path.join(ADDON, "AttuneNext.toc"), encoding="utf-8-sig").read().splitlines()
for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
    ok, err = loader(open(os.path.join(ADDON, f), encoding="utf-8").read(), f, "AttuneNext", ns)
    if not ok: print("LOAD ERROR", f, err)
mem = L.eval('function() return collectgarbage("count") end')

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

fire("ADDON_LOADED", "AttuneNext")
# wrap Lua-side hot functions with counters
L.execute(r'''
  local ns = AttuneNext
  local N = _N
  local function wrap(tbl, key, label)
    local orig = tbl[key]
    if not orig then print("no fn", key) return end
    tbl[key] = function(...) N(label) return orig(...) end
  end
  wrap(ns.Engine, "Eligible", "L:Eligible")
  wrap(ns.Engine, "IsOwned", "L:IsOwned")
  wrap(ns.Engine, "ScopeLeft", "L:ScopeLeft")
  wrap(ns.Engine, "ItemMinLevel", "L:ItemMinLevel")
  wrap(ns, "BindType", "L:BindType")
  wrap(ns, "ItemFactionOf", "L:ItemFactionOf")
  wrap(ns, "ClassLock", "L:ClassLock")
  wrap(ns, "ItemUsableByClass", "L:ItemUsableByClass")
  wrap(ns, "RequestItemCache", "L:RequestItemCache")
  wrap(ns, "GetItemDisplay", "L:GetItemDisplay")
  wrap(ns, "GetItemName", "L:GetItemName")
  wrap(ns.UI, "Render", "L:UI.Render")
  wrap(ns.UI, "PaintVisibleRows", "L:UI.PaintVisibleRows")
  wrap(ns.UI, "FitText", "L:UI.FitText")
  wrap(ns.Engine, "WarmPredicates", "L:WarmPredicates")
''')

snap = {}
def snapshot():
    cc = L.eval('_CC')
    return {k: v for k, v in cc.items()}
def report(title, base):
    cur = snapshot()
    keys = sorted(set(cur) | set(base))
    rows = []
    for k in keys:
        d = cur.get(k, 0) - base.get(k, 0)
        if d: rows.append("%-32s %8d" % (k, d))
    print("== %s   [queries=%d cached=%d pending=%d lua=%.0fKB]" % (title, L.eval('_QUERIES'), L.eval('_NCACHED()'), L.eval('#_PENDING'), mem()))
    for r in rows: print("   " + r)
    return cur

def run(n):
    for _ in range(n): tick(0.016)

base = snapshot()
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
ready_frame = scan_frame = warm_frame = None
seen_warm = False
for i in range(1, FRAMES + 1):
    tick(0.016)
    tg, rd = status(ns)
    if rd == "ready" and ready_frame is None:
        ready_frame = i
        base = report("phase: until data ready (frame %d)" % i, base)
    if rd == "ready" and "warmup" in tg and not seen_warm:
        seen_warm = True; scan_frame = i
        base = report("phase: summaries scan (frames %d..%d)" % (ready_frame, i), base)
    if rd == "ready" and tg == "" and warm_frame is None:
        warm_frame = i
        base = report("phase: warmup + pick (frames %d..%d)" % (scan_frame or ready_frame, i), base)
        break
    if os.environ.get("DEBUGJOBS") and i % 25 == 0 and rd == "ready":
        print("   frame %d jobs=[%s] WarmPredicates=%s" % (i, tg[:100], snapshot().get("L:WarmPredicates", 0)))
if warm_frame is None:
    base = report("phase: warmup NOT finished by frame %d (jobs=%s)" % (FRAMES, status(ns)[0][:80]), base)
print("login done: ready=%s scan=%s idle=%s  FILTERS=%s CACHEPCT=%d" % (ready_frame, scan_frame, warm_frame, sorted(FILTERS), CACHEPCT))
run(60)   # let pending queries resolve
base = report("phase: 60 idle frames after login", base)

show = L.eval('function(ns) ns.UI.Show(true) end')
push = L.eval('function(ns, t) ns.UI.Push(t) end')
pushv = L.eval('function(ns, ty, exp, kind) ns.UI.Push({ type = ty, exp = exp, kind = kind }) end')
render = L.eval('function(ns) ns.UI.Render() end')
inval = L.eval('function(ns) ns.Engine.InvalidateStats() end')
setq = L.eval('function(ns, q) ns.UI.searchQuery = q; ns.UI.Push({ type = "search" }) end')

if "home" in SCEN or "ui_inst" in SCEN or "bags" in SCEN or "fac_later" in SCEN or "cls_later" in SCEN:
    show(ns)
    base = report("UI.Show(true): root screen render", base)
    run(5)
    base = report("  +5 frames (async picks etc)", base)

if "home" in SCEN:
    inval(ns); render(ns)
    base = report("root screen re-render after InvalidateStats (whole-universe counts)", base)
    run(60)
    base = report("  +60 frames", base)

if "ui_inst" in SCEN:
    push(ns, L.table(type="content", exp=3))
    base = report("push content exp=3", base)
    pushv(ns, "instances", 3, "D")
    base = report("push instances exp=3 D (first render, stats cold)", base)
    run(5); base = report("  +5 frames", base)
    render(ns)
    base = report("re-render instances (stats cached)", base)
    inval(ns); render(ns)
    base = report("InvalidateStats + re-render instances", base)
    run(60); base = report("  +60 frames", base)

if "bags" in SCEN:
    L.execute('AttuneNext.db.hideInBags = true; AttuneNext.Engine.InvalidateOwned(); AttuneNext.Engine.InvalidateStats()')
    if "ui_inst" not in SCEN:
        push(ns, L.table(type="content", exp=3)); pushv(ns, "instances", 3, "D")
    render(ns)
    base = report("hideInBags ON, instances exp=3 D render", base)
    run(5); base = report("  +5 frames", base)
    # 20-event loot burst, 6 frames (~0.1 s) apart
    for k in range(20):
        fire("BAG_UPDATE", k % 5)
        run(6)
    base = report("20 BAG_UPDATE spaced 0.1 s (loot burst) incl. frames", base)
    run(60)
    base = report("  +60 frames after burst (debounced refresh fires)", base)
    # a slow trickle: 20 events each 0.6 s apart (every one past the debounce)
    for k in range(20):
        fire("BAG_UPDATE", k % 5)
        run(38)
    base = report("20 BAG_UPDATE spaced 0.6 s (each past the 0.5 s debounce)", base)

if "fac_later" in SCEN:
    # faction filter switched on AFTER the login warmup (not warmed by WarmIfNeeded)
    L.execute('AttuneNext.db.faction = "A"; AttuneNext.Engine.InvalidateStats()')
    render(ns)
    base = report("faction filter switched on later: root re-render (inline ItemFactionOf)", base)
    run(200); base = report("  +200 frames (WarmIfNeeded top-up)", base)
    render(ns); base = report("  root re-render again", base)

if "cls_later" in SCEN:
    L.execute('AttuneNext.db.prestige = true; AttuneNext.db.classFilter = "WARRIOR"; AttuneNext.Engine.InvalidateStats()')
    render(ns)
    base = report("class filter switched on later: root re-render (inline ClassLock)", base)
    run(200); base = report("  +200 frames", base)
    render(ns); base = report("  root re-render again", base)

if "fresh" in SCEN:
    show(ns)
    base = report("fresh: UI.Show(true)", base)
    # a whole-expansion item list: every D item of exp 3
    L.execute(r'''
      local ns = AttuneNext
      local sum = ns.Engine.GetSummary(3)
      local ids = {}
      for id in pairs(sum.D) do ids[#ids+1] = id end
      table.sort(ids)
      _BIGLIST = ids
      ns.UI.Push({ type = "items", title = "all WotLK dungeon items", items = ids })
    ''')
    print("   biglist size", L.eval('#_BIGLIST'))
    base = report("fresh: push items view with every exp-3 dungeon item", base)
    run(60)
    base = report("  +60 frames (queries resolve; does anything re-render?)", base)
    render(ns)
    base = report("  manual re-render after resolve", base)
    render(ns)
    base = report("  manual re-render again (display cache warm?)", base)

if "search" in SCEN:
    if "fresh" not in SCEN: show(ns)
    setq(ns, "item1")
    base = report("search 'item1' first render", base)
    L.execute('AttuneNext.UI.searchQuery = "item10"'); render(ns)
    base = report("search 'item10' re-render", base)
    L.execute('AttuneNext.UI.searchQuery = "item100"'); render(ns)
    base = report("search 'item100' re-render", base)

if "paint" in SCEN:
    if not any(s in SCEN for s in ("ui_inst", "bags", "fresh", "search", "home")): show(ns)
    L.execute(r'''
      local ns = AttuneNext
      ns.UI.Push({ type = "content", exp = 1 }); ns.UI.Push({ type = "instances", exp = 1, kind = "D" })
    ''')
    base = report("paint: instances exp=1 D render", base)
    L.execute('AttuneNext.UI.PaintVisibleRows()')
    base = report("paint: one PaintVisibleRows (scroll notch)", base)
    # per-FitText iteration profile
    L.execute(r'''
      local ns = AttuneNext
      local fs = CreateFrame("Frame"):CreateFontString()
      local samples = {
        { "|cffffd100Utgarde Keep|r", 348 },
        { "    |cffccccccHeroic|r", 348 },
        { "      Best: 12.3% - Mob1234 (Zone12)", 680 },
        { "      Best: 12.3% - Prince Keleseth the Unbearably Long Named (Utgarde Keep)", 348 },
        { "Drop: Mob1234 (Zone12)   |cffffd100Skill 375|r  and a long tail of text to force trimming here", 348 },
      }
      for _, s in ipairs(samples) do
        local c0 = _CC.GetStringWidth or 0
        ns.UI.FitText(fs, s[1], s[2])
        print(string.format("   FitText len=%3d maxW=%3d -> GetStringWidth calls %d, result len %d", #s[1], s[2], (_CC.GetStringWidth or 0) - c0, #(fs._text or "")))
      end
    ''')

if "pane" in SCEN:
    show(ns)
    L.execute(r'''
      local ns = AttuneNext
      -- realistic names: long, mixed, like real loot
      local names = { "Breastplate of the Lost Vanquisher", "Girdle of the Frozen Reach", "Band of the Eternal Champion",
        "Ring", "Shoulderpads of the Intruder", "Wand of the Archlich", "Cloak of Burning Dusk", "Hammer of the Astral Plane",
        "Legplates of the Silver Hand", "Sabatons of Deathlike Gloom", "Idol of the Plainstalker", "Ulduar Memorial Plate" }
      local sum = ns.Engine.GetSummary(3)
      local ids = {}
      for id in pairs(sum.D) do ids[#ids+1] = id end
      table.sort(ids)
      local orig = ns.GetItemDisplay
      ns.GetItemDisplay = function(id, nr)
        local n, l, q, t = orig(id, nr)
        return names[(id % #names) + 1] .. " " .. id, l, q, t
      end
      ns.UI.Push({ type = "items", title = "all WotLK dungeon items", items = ids, zoneName = "Utgarde Keep" })
      ns.UI.SelectItem(ids[1])
    ''')
    base = report("pane: items view + selected item (side pane layout, title 180 px)", base)
    L.execute('AttuneNext.UI.PaintVisibleRows()')
    base = report("pane: one PaintVisibleRows (scroll notch) in side-pane layout", base)
    L.execute(r'''
      local ns = AttuneNext
      local b = nil
      for _, f in ipairs(_FRAMES()) do if f.anxTextW then b = f break end end
      print("   row anxTextW =", b and b.anxTextW, " sub maxW =", b and (b.anxTextW * 2 - 16))
    ''')

miss = L.eval('_MISSING')
print("missing globals read:", sorted(((k, v) for k, v in miss.items()), key=lambda x: -x[1])[:15])
print("final lua %.0f KB" % mem())
