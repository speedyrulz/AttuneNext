#!/usr/bin/env python3
"""AttuneNext headless harness (consolidated).

Runs the real addon files in Lua 5.1 (python `lupa`) with stubbed WoW frames
and APIs plus a synthetic Synastria loot DB, fires the login events, ticks
OnUpdate frames and reports Lua memory, scan frames, per-frame cost, the C
calls the stubs model, and the addon's own `/an perf` counters. All numbers
are RELATIVE: 64-bit lupa on a desktop CPU vs the 32-bit client (tables ~30%
smaller there, CPU 2-3x slower).

    python3 -I harness.py                         # SCENARIO=fresh-scan
    SCENARIO=heavy-tail python3 -I harness.py
    SCENARIO=stock PROFILE=1 python3 -I harness.py
    ADDON=/path/to/copy SCENARIO=30fps python3 -I harness.py

Scenarios (presets; any variable you set explicitly wins over the preset):
  fresh-scan      20k items, 600 per zone, every 10th item 200 rows, data ready at
                  5 s. Source rows name REAL zones consistently (ZNAMES=2): an item
                  listed in zone Z has a row naming Z, like an English client.
  mismatch-names  same DB, rows name 'Zone0..59' (ZNAMES=0). No row names a zone the
                  addon knows, so ZoneData's localized-client fallback classifies
                  EVERY row of EVERY item into EVERY zone that lists it. This was the
                  stock harness's only mode; it inflates zoneCache (46 MB) and the
                  structCache SavedVariables far beyond the English-client case.
  heavy-tail      fresh-scan plus WDROP=100 world-drop ids listed in every open-world
                  zone with WROWS=2000 creature rows each; gap-lens row naming
                  (ZNAMES=1, rows name real zones by row index).
  two-addons      fresh-scan with a renamed copy of the same repo loaded second as
                  AttuneNext-Simple (SIMPLE=1): both engines scan the DB.
  30fps           fresh-scan with frame pacing emulated (PACE=1 FPS=30): each frame's
                  `elapsed` is the game's base frame cost plus the addon's cost.
  cached-login    phase 1 runs fresh-scan in a child process and saves AttuneNextDB at
                  PLAYER_LOGOUT in SavedVariables format; phase 2 relogs on that file
                  and reports parse ms, ImportCache ms, whether a rescan ran.
  ui              fresh-scan, then opens the window and renders the main screens.
  stock           the pre-consolidation stub set (ZNAMES=0, 32-iteration bit library,
                  truthy frame stub, no cost model): reproduces harness_orig.py.

Variables (default):
  ADDON (this repo)  ADDONS ("path|AttuneNext;path2|AttuneNext-Simple")  SKIP (files)
  NITEMS 20000  ZONEN 600  HEAVY 200  READY_AT 5  FRAMES 1500
  ZNAMES 2 (0 mismatch / 1 by row index / 2 consistent)  WDROP 0  WROWS 2000
  BITLIB fast|stock   FRAMESTUB nil|stock   PACE 0|1  FPS 60  SLOW 1 (CPU slowdown:
     the pump's clock runs SLOW x faster, so it gets 10/SLOW ms of real work per frame)
  Cost models (0 = free, like the stock stubs): USEC_HYPERLINK, USEC_ITEMCOUNT,
     USEC_STRWIDTH microseconds charged per call; CACHEPCT 100 (share of items the
     client has cached: GetItemInfo returns nil and SetHyperlink gives 0 lines for the
     rest, resolving QUERY_DELAY=0.5 s later); OWNED 0 (ids GetItemCount reports).
  NPLATES 0 (simulated nameplates under WorldFrame)  INST (in an instance)  ZONE name
  SVFILE (SavedVariables to load)  SAVE (write SavedVariables at the end)  LOGOUT 1
  UI 1  BENCH predicates  PROFILE 1  ALLOC 1  CHAT 1 (echo all addon chat)
"""
import sys, os, re, time, shutil, subprocess
import lupa.lua51 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
BASEPRESET = dict(NITEMS="20000", ZONEN="600", HEAVY="200", READY_AT="5", FRAMES="1500", ZNAMES="2")
SCENARIOS = {
    "fresh-scan":     dict(BASEPRESET),
    "mismatch-names": dict(BASEPRESET, ZNAMES="0"),
    "heavy-tail":     dict(BASEPRESET, ZNAMES="1", WDROP="100", WROWS="2000"),
    "two-addons":     dict(BASEPRESET, SIMPLE="1"),
    "30fps":          dict(BASEPRESET, PACE="1", FPS="30", FRAMES="2000"),
    "cached-login":   dict(BASEPRESET, CACHED="1"),
    "ui":             dict(BASEPRESET, UI="1"),
    "stock":          dict(BASEPRESET, ZNAMES="0", BITLIB="stock", FRAMESTUB="stock"),
}
SCEN = os.environ.get("SCENARIO", "fresh-scan")
if SCEN not in SCENARIOS:
    sys.exit("unknown SCENARIO %r; one of %s" % (SCEN, ", ".join(SCENARIOS)))
for k, v in SCENARIOS[SCEN].items():
    os.environ.setdefault(k, v)

def env(k, d=None): return os.environ.get(k, d)
ADDON = env("ADDON", "/home/user/AttuneNext")
FRAMES = int(env("FRAMES"))
SKIP = set(env("SKIP", "").split(",")) - {""}
PACE = env("PACE", "0") == "1"
FPS = float(env("FPS", "60"))
SLOW = float(env("SLOW", "1"))
BASE_MS = 1000.0 / FPS
LOGOUT = env("LOGOUT", "1") == "1"
SVFILE = env("SVFILE")
SAVE = env("SAVE")

# ---------------------------------------------------------------- cached-login phase 1
if env("CACHED") == "1" and not SVFILE:
    tmp = os.path.join(HERE, "cached_login_sv.lua")
    child = dict(os.environ, SCENARIO="fresh-scan", SAVE=tmp, LOGOUT="1")
    child.pop("CACHED", None)
    print("== cached-login phase 1: fresh scan in a child process, saving", tmp)
    out = subprocess.run([sys.executable, "-I", os.path.abspath(__file__)], env=child,
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if re.match(r"(scan finished|peak|saved SavedVariables|PLAYER_LOGOUT)", line):
            print("   phase 1:", line)
    SVFILE = tmp
    print("== cached-login phase 2: relog on the saved file")

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()

STUBS = r'''
local now = 0
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
local SLOWF = tonumber(os.getenv("SLOW") or "") or 1
function debugprofilestop() return (os.clock() - t0) * 1000 * SLOWF end
function debugprofilestart() t0 = os.clock() end
function time() return 1790000000 + math.floor(now) end
date = os.date

-- ===== bit library (WoW provides it in C; Lua 5.1 does not) =====
-- The stock harness looped 32 times per band/bor, which made every
-- IsAttunableAtAll/FlagGet-heavy number 3-5x too slow (bit.band 3.4 us vs
-- 0.5 us). The fast version answers the addon's shapes (single-bit tests
-- and low masks 3/7/1023) in two arithmetic ops and everything else from a
-- 256x256 byte table; it matches the 32-iteration reference bit for bit.
bit = {}
local function tobits(n) return n % 4294967296 end
local stockbit = {}
function stockbit.band(a, b, ...)
  a, b = tobits(a), tobits(b)
  local r, p = 0, 1
  for i = 1, 32 do
    if a % 2 == 1 and b % 2 == 1 then r = r + p end
    a, b, p = math.floor(a/2), math.floor(b/2), p*2
  end
  if ... then return stockbit.band(r, ...) end
  return r
end
function stockbit.bor(a, b, ...)
  a, b = tobits(a), tobits(b)
  local r, p = 0, 1
  for i = 1, 32 do
    if a % 2 == 1 or b % 2 == 1 then r = r + p end
    a, b, p = math.floor(a/2), math.floor(b/2), p*2
  end
  if ... then return stockbit.bor(r, ...) end
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
if os.getenv("BITLIB") == "stock" then
  bit.band, bit.bor = stockbit.band, stockbit.bor
else
  local floor = math.floor
  local T = {}
  for a = 0, 255 do
    T[a] = {}
    for b = 0, 255 do
      local r, p, x, y = 0, 1, a, b
      for i = 1, 8 do if x % 2 == 1 and y % 2 == 1 then r = r + p end x, y, p = floor(x/2), floor(y/2), p*2 end
      T[a][b] = r
    end
  end
  local function band2(a, b)
    a, b = a % 4294967296, b % 4294967296
    local r, m = 0, 1
    for i = 1, 4 do
      local x, y = a % 256, b % 256
      r = r + T[x][y] * m
      a, b, m = floor(a / 256), floor(b / 256), m * 256
    end
    return r
  end
  local P2 = {}
  for i = 0, 31 do P2[2 ^ i] = true end
  local function bandn(a, b, ...)
    local r = band2(a, b)
    if ... then return bandn(r, ...) end
    return r
  end
  function bit.band(a, b, ...)
    if ... then return bandn(a, b, ...) end
    a = a % 4294967296; b = b % 4294967296
    if P2[b + 1] then return a % (b + 1) end           -- low mask (3, 7, 1023)
    if P2[b] then return (floor(a / b) % 2) * b end     -- single bit (32, 64)
    return band2(a, b)
  end
  function bit.bor(a, b, ...)
    a, b = a % 4294967296, b % 4294967296
    local r = a + b - band2(a, b)
    if ... then return bit.bor(r, ...) end
    return r
  end
end

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
ITEM_BIND_ON_PICKUP = "Binds when picked up"
ITEM_SOULBOUND = "Soulbound"
ITEM_BIND_ON_EQUIP = "Binds when equipped"
ITEM_BIND_ON_USE = "Binds when used"
ITEM_CLASSES_ALLOWED = "Classes: %s"

-- ===== C-call counters and cost models =====
_CC = {}
local CC = _CC
local function N(k) CC[k] = (CC[k] or 0) + 1 end
_N = N
local USEC_HL = tonumber(os.getenv("USEC_HYPERLINK") or "") or 0
local USEC_IC = tonumber(os.getenv("USEC_ITEMCOUNT") or "") or 0
local USEC_SW = tonumber(os.getenv("USEC_STRWIDTH") or "") or 0
_CHARGED_US = 0
local function charge(us)
  if us > 0 then
    local t = os.clock() + us / 1e6
    while os.clock() < t do end
    _CHARGED_US = _CHARGED_US + us
  end
end

-- the client item cache: GetItemInfo is nil and tooltips are empty for
-- items the client has not seen; a SetHyperlink on one is a server query
-- that resolves QUERY_DELAY seconds later
local NITEMS = tonumber(os.getenv("NITEMS") or "") or 20000
local BASE = 10000
local CACHEPCT = tonumber(os.getenv("CACHEPCT") or "") or 100
local QUERY_DELAY = tonumber(os.getenv("QUERY_DELAY") or "") or 0.5
local function attunable(id) return id >= BASE and id < BASE + NITEMS end
_CACHED, _PENDING, _QUERIES = {}, {}, 0
if CACHEPCT < 100 then
  for id = BASE, BASE + NITEMS - 1 do if (id * 37) % 100 < CACHEPCT then _CACHED[id] = true end end
end
local function cached(id) return CACHEPCT >= 100 or _CACHED[id] == true end
local function query(id)
  if cached(id) then return end
  _QUERIES = _QUERIES + 1
  _PENDING[#_PENDING + 1] = { id = id, at = now + QUERY_DELAY }
end

-- ===== frames =====
-- Addon-owned fields on frames are lowercase or underscored (anxPlate,
-- rows, _scripts); WoW methods are CapitalCase. The stock stub answered
-- EVERY unknown key with a no-op function, so `if not b.anxPlate` was never
-- true and UI.Show crashed at the first real render (UI.lua:489/521). The
-- fixed stub returns nil for non-CapitalCase keys. FRAMESTUB=stock restores
-- the old behaviour for exact reproductions.
local STOCKSTUB = os.getenv("FRAMESTUB") == "stock"
local FrameMT = {}
local frames = {}
_CHAT = {}
local NUM = { GetWidth=200, GetHeight=20, GetScale=1, GetEffectiveScale=1, GetLeft=0, GetRight=200,
  GetTop=500, GetBottom=0, GetFrameLevel=1, GetNumPoints=0, GetStringWidth=50, GetStringHeight=12,
  GetValue=0, GetVerticalScroll=0, GetHorizontalScroll=0, GetNumLines=0, GetAlpha=1, GetID=0,
  GetVerticalScrollRange=0, GetFrameStrata="MEDIUM", GetNumRegions=0, GetNumChildren=0 }
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
-- tooltip text model: the lines the three scrapers (bind, class lock,
-- faction) look for, keyed off the item id so counts are deterministic
local function fillTip(tip, id)
  local nm = tip._name or "AnonTip"
  local m = id % 3
  local lines = {
    { "Item" .. id },
    { (m == 0) and ITEM_BIND_ON_PICKUP or (m == 1) and ITEM_BIND_ON_EQUIP or "Unique" },
    { "Chest", "Plate" },
    { (id % 7 == 0) and "Classes: Warrior, Paladin" or "120 Armor" },
    { (id % 11 == 0) and "Faction:" or "+10 Strength", (id % 11 == 0) and ((id % 22 == 0) and "Alliance" or "Horde") or nil },
    { "+10 Stamina" }, { "Durability 100 / 100" },
  }
  for i, l in ipairs(lines) do
    local lf = _G[nm .. "TextLeft" .. i] or { GetText = function(s) return s._t end }
    lf._t = l[1]; _G[nm .. "TextLeft" .. i] = lf
    local rf = _G[nm .. "TextRight" .. i] or { GetText = function(s) return s._t end }
    rf._t = l[2]; _G[nm .. "TextRight" .. i] = rf
  end
  tip._n = #lines
end
FrameMT.__index = function(f, k)
  if not STOCKSTUB then
    if type(k) ~= "string" or not string.find(k, "^%u") then return nil end
    if k == "GetRegions" or k == "GetChildren" then return function() return nil end end
    if k == "GetStringWidth" then return function(self) N("GetStringWidth") charge(USEC_SW) return 6.5 * visibleLen(self._text) end end
    if k == "SetHyperlink" then return function(self, link)
        N("SetHyperlink") charge(USEC_HL)
        local id = tonumber(tostring(link):match("item:(%d+)"))
        if id and attunable(id) and cached(id) then fillTip(self, id) N("SetHyperlink_cached")
        else self._n = 0; if id then query(id) end; N("SetHyperlink_uncached") end
      end end
    if k == "NumLines" then return function(self) return self._n or 0 end end
    if k == "ClearLines" then return function(self) self._n = 0 end end
    if k == "AddMessage" then return function(self, m) _CHAT[#_CHAT+1] = tostring(m) end end
  end
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
GameFontNormalHuge = GameFontNormal
UISpecialFrames = {}
SlashCmdList = {}
StaticPopupDialogs = {}
InterfaceOptions_AddCategory = function() end
InterfaceOptionsFrame_OpenToCategory = function() end
FauxScrollFrame_Update = function() end
FauxScrollFrame_GetOffset = function() return 0 end
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
LOCALIZED_CLASS_NAMES_MALE = { WARRIOR="Warrior", PALADIN="Paladin", HUNTER="Hunter", ROGUE="Rogue",
  PRIEST="Priest", DEATHKNIGHT="Death Knight", SHAMAN="Shaman", MAGE="Mage", WARLOCK="Warlock", DRUID="Druid" }
LOCALIZED_CLASS_NAMES_FEMALE = {}
ITEM_QUALITY_COLORS = setmetatable({}, {__index=function() return {r=1,g=1,b=1,hex="|cffffffff"} end})
NUM_BAG_SLOTS = 4
function _FRAMES() return frames end

-- simulated nameplates (frame lens): plain tables, found through
-- WorldFrame:GetChildren and the border-texture path
local NPLATES = tonumber(os.getenv("NPLATES") or "") or 0
_PLATES, _SETALPHA = {}, 0
do
  local function region(kind, tex) return { GetObjectType = function() return kind end, GetTexture = function() return tex end } end
  local function mkplate(i)
    local border = region("Texture", "Interface\\Tooltips\\Nameplate-Border")
    local nameFS = { GetObjectType = function() return "FontString" end, GetText = function(self) return self._t end, _t = "Mob" .. ((i * 97) % 5000) }
    local junk = region("Texture")
    local f = {}
    f.GetName = function() return nil end
    f.GetRegions = function() return junk, border, junk, junk, junk, junk, nameFS, nameFS, junk, junk, junk end
    f.GetNumRegions = function() return 11 end
    f.IsShown = function() return true end
    f.HookScript = function() end
    f.CreateTexture = function() local t = CreateFrame("Texture") t.SetAlpha = function() _SETALPHA = _SETALPHA + 1 end return t end
    f.CreateFontString = function() return CreateFrame("FontString") end
    return f
  end
  for i = 1, NPLATES do _PLATES[i] = mkplate(i) end
  if NPLATES > 0 then
    WorldFrame.GetNumChildren = function() return #_PLATES end
    WorldFrame.GetChildren = function() return unpack(_PLATES) end
  end
end

-- player / world
local INST = os.getenv("INST") ~= nil
local ZONE = os.getenv("ZONE") or (INST and "Scholomance" or "Eastern Plaguelands")
function UnitName() return "Speedyrulz" end
function UnitClass() return "Death Knight", "DEATHKNIGHT" end
function UnitRace() return "Human", "Human" end
function UnitLevel() return 80 end
function UnitFactionGroup() return "Alliance", "Alliance" end
function UnitBuff() return nil end
function UnitGUID() return "0x0000000000203C" end
function GetRealZoneText() return ZONE end
function GetZoneText() return ZONE end
function GetSubZoneText() return "Eastwall Tower" end
function IsInInstance() if INST then return true, "party" end return false, "none" end
function GetInstanceInfo() return ZONE, INST and "party" or "none", 1 end
function GetInstanceDifficulty() return 1 end
function GetCurrentMapContinent() return 2 end
function GetCurrentMapZone() return 1 end
function GetPlayerMapPosition() return 0.5, 0.5 end
function SetMapToCurrentZone() end
function GetMoney() return 1000000 end
function GetHonorCurrency() return 0 end
function GetArenaCurrency() return 0 end
function GetCurrencyListSize() return 0 end
local OWNED = tonumber(os.getenv("OWNED") or "") or 0
_OWNED = {}
for k = 0, OWNED - 1 do _OWNED[BASE + (k * 613) % NITEMS] = true end
function GetItemCount(id, bank) N("GetItemCount") charge(USEC_IC) return _OWNED[id] and 1 or 0 end
function GetInventoryItemLink() N("GetInventoryItemLink") return nil end
function GetContainerNumSlots() return 0 end
function GetMerchantNumItems() return 0 end
function GetNumLootItems() return 0 end
function GetNumTradeSkills() return 0 end
function GetLocale() return "enGB" end
function GetCVar() return "0" end
function GetBuildInfo() return "3.3.5", "12340", "Jun 24 2010", 30300 end
function InCombatLockdown() return false end
function GetFramerate() return tonumber(os.getenv("FPS") or "") or 60 end
function GetNetStats() return 0,0,50 end
function UpdateAddOnMemoryUsage() end
function GetAddOnMemoryUsage() return 0 end
function IsAddOnLoaded() return false end
function GetNumAddOns() return 0 end

-- ===== fake Synastria item / loot DB =====
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
local ZONEN = tonumber(os.getenv("ZONEN") or "") or 150
local function zoneItems(zoneId)
  -- deterministic slice of the item space for each zone/map id
  local out, start = {}, (zoneId * 7919) % NITEMS
  for i = 0, ZONEN - 1 do out[#out+1] = BASE + (start + i * 13) % NITEMS end
  return out
end
-- heavy tail (gap lens): WDROP "world drop" ids listed in EVERY open-world
-- zone (zoneId < 32768), each with WROWS creature rows
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
local HEAVY = tonumber(os.getenv("HEAVY") or "") or 0
-- zone naming of source rows:
--   0  "Zone0..59": nothing the addon knows -> ZoneData's fallback (localized client)
--   1  real zone names by ROW index (gap lens): recognised, rarely this zone
--   2  consistent: row i of an item names the i-th zone whose list holds it,
--      built from ANx.Zones after load (_BUILD_HOME); rows are bumped so every
--      listing zone has a row, like the server's own scoping
local ZNAMES = tonumber(os.getenv("ZNAMES") or "") or 2
local REALZ = {"Elwynn Forest","Westfall","Redridge Mountains","Duskwood","Stranglethorn Vale","Swamp of Sorrows","Blasted Lands","Deadwind Pass","Burning Steppes","Searing Gorge","Badlands","Loch Modan","Dun Morogh","Wetlands","Arathi Highlands","Hillsbrad Foothills","Alterac Mountains","Silverpine Forest","Tirisfal Glades","Western Plaguelands","Eastern Plaguelands","The Hinterlands","Durotar","The Barrens","Mulgore","Stonetalon Mountains","Ashenvale","Teldrassil","Darkshore","Azshara","Felwood","Winterspring","Moonglade","Desolace","Feralas","Dustwallow Marsh","Thousand Needles","Tanaris","Un'Goro Crater","Silithus","Stormwind City","Ironforge","Darnassus","Orgrimmar","Thunder Bluff","Undercity","Eversong Woods","Ghostlands","Azuremyst Isle","Bloodmyst Isle","Hellfire Peninsula","Zangarmarsh","Terokkar Forest","Nagrand","Blade's Edge Mountains","Netherstorm","Shadowmoon Valley","Isle of Quel'Danas","Silvermoon City","The Exodar","Shattrath City","Borean Tundra","Howling Fjord","Dragonblight","Grizzly Hills","Zul'Drak","Sholazar Basin","Crystalsong Forest","The Storm Peaks","Icecrown","Wintergrasp","Dalaran"}
_HOME = nil
function _BUILD_HOME(zones)
  _HOME = {}
  local nz = 0
  for _, z in ipairs(zones) do
    nz = nz + 1
    for _, id in ipairs(ItemLocGetAllItemsInZone(z.zone)) do
      local h = _HOME[id]
      if not h then h = {} _HOME[id] = h end
      h[#h + 1] = z.name
    end
  end
  return nz
end
local function zname(id, i)
  if ZNAMES == 0 then return "Zone" .. (i % 60) end
  if ZNAMES == 1 then return REALZ[(i % #REALZ) + 1] end
  local h = _HOME and _HOME[id]
  if h and h[i] then return h[i] end
  return REALZ[((id + i) % #REALZ) + 1]
end
function ItemLocGetSourceCount(id)
  local n
  if isWdrop(id) then n = WROWS
  elseif attunable(id) then n = (HEAVY > 0 and id % 10 == 0) and HEAVY or (1 + id % 3)
  else return 0 end
  if ZNAMES == 2 and _HOME then
    local h = _HOME[id]
    if h and #h > n then n = #h end
  end
  return n
end
local types = {0, 1, 2, 9, 0, 6}
function ItemLocGetSourceAt(id, i)
  -- one fresh string per row ("Mob<n>") on purpose: the client interns a
  -- name string per call too
  if isWdrop(id) then return 0, 0, 1000 + (i % 5000), 0.5, 5, "Mob" .. (i % 5000), zname(id, i), 1 end
  local st = types[(id + i) % #types + 1]
  return st, 0, 1000 + ((id + i) % 5000), 5 + (id % 20), 50, "Mob" .. ((id + i) % 5000), zname(id, i), 1
end
function ItemLocGetObjCount() return 0 end
function ItemLocGetObjAt() return nil end
function GetItemInfo(id)
  N("GetItemInfo")
  if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) end
  if not id or not attunable(id) or not cached(id) then N("GetItemInfo_nil") return nil end
  return "Item" .. id, "|cffa335ee|Hitem:" .. id .. ":0|h[Item" .. id .. "]|h|r", 4, 200, 70,
    "Armor", "Plate", 1, "INVTYPE_CHEST", "Interface\\Icons\\INV_Misc_QuestionMark", 1000
end
function GetItemInfoCustom(id) return GetItemInfo(id) end

-- GC step accounting (the pump calls the global by name)
_GCN, _GCMS = 0, 0
local cg = collectgarbage
collectgarbage = function(op, arg)
  if op == "step" then
    _GCN = _GCN + 1
    local t = os.clock()
    local r = cg(op, arg)
    _GCMS = _GCMS + (os.clock() - t) * 1000
    return r
  end
  return cg(op, arg)
end
'''
L.execute(STUBS)
mem = L.eval('function() return collectgarbage("count") end')

# ---------------------------------------------------------------- SavedVariables
if SVFILE:
    src = open(SVFILE, encoding="utf-8", errors="replace").read()
    r = L.eval(r'''function(src)
      collectgarbage("collect")
      local m0 = collectgarbage("count")
      local t0 = os.clock()
      local f = assert(loadstring(src, "=sv"))
      local t1 = os.clock()
      f()
      local t2 = os.clock()
      f = nil
      collectgarbage("collect")
      return (t1 - t0) * 1000, (t2 - t1) * 1000, collectgarbage("count") - m0
    end''')(src)
    print("loaded SavedVariables %s: %.0f KB on disk, compile %.1f ms, exec %.1f ms, resident %.0f KB" % (SVFILE, os.path.getsize(SVFILE) / 1024, r[0], r[1], r[2]))
    del src

L.execute(r'''
_MISSING = {}
setmetatable(_G, { __index = function(t, k) _MISSING[k] = (_MISSING[k] or 0) + 1 return nil end })
''')

# ---------------------------------------------------------------- addons
def make_simple(src, dst):
    """A stand-in for AttuneNext-Simple: the same code with its globals renamed
    (AttuneNextSimple, AttuneNextSimpleDB, AttuneNextSimple_OnDataReady, frame
    names), so the two addons coexist like the real pair. The real Simple
    carries v3.6.0's Engine; this measures 'two engines scanning', not Simple."""
    if os.path.isdir(dst): shutil.rmtree(dst)
    os.makedirs(dst)
    for f in os.listdir(src):
        if f.endswith(".lua"):
            s = open(os.path.join(src, f), encoding="utf-8").read()
            s = s.replace("AttuneNext", "AttuneNextSimple").replace("AddOns\\\\AttuneNextSimple", "AddOns\\\\AttuneNext-Simple")
            open(os.path.join(dst, f), "w", encoding="utf-8", newline="\n").write(s)
    toc = open(os.path.join(src, "AttuneNext.toc"), encoding="utf-8-sig").read()
    toc = toc.replace("AttuneNextDB", "AttuneNextSimpleDB").replace("## Title: AttuneNext", "## Title: AttuneNext-Simple")
    open(os.path.join(dst, "AttuneNext-Simple.toc"), "w", encoding="utf-8", newline="\n").write(toc)
    return dst

ADDONS = env("ADDONS", ADDON + "|AttuneNext").split(";")
if env("SIMPLE") == "1" and not any("AttuneNext-Simple" in a for a in ADDONS):
    ADDONS.append(make_simple(ADDON, os.path.join(HERE, "AttuneNext-Simple")) + "|AttuneNext-Simple")
loader = L.eval("""function(src, name, aname, ns)
  local t0 = os.clock()
  local fn, err = loadstring(src, "@" .. aname .. "/" .. name)
  if not fn then return false, err end
  local t1 = os.clock()
  local ok, e = pcall(fn, aname, ns)
  return ok, e, (t1 - t0) * 1000, (os.clock() - t1) * 1000
end""")
nss = []
compile_ms = exec_ms = 0.0
for spec in ADDONS:
    path, aname = spec.split("|")
    ns_ = L.table()
    toc = open(os.path.join(path, aname + ".toc"), encoding="utf-8-sig").read().splitlines()
    for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
        if f in SKIP: continue
        ok, err, cms, ems = loader(open(os.path.join(path, f), encoding="utf-8").read(), f, aname, ns_)
        compile_ms += cms; exec_ms += ems
        if not ok: print("LOAD ERROR", aname, f, err)
    nss.append((aname, ns_))
    if len(nss) == 1:
        L.execute('_SLASH1 = SlashCmdList["ATTUNENEXT"]')   # the first addon's /an, before a second overwrites it
ns = nss[0][1]
print("== %s  addon=%s  items=%s zonen=%s heavy=%s wdrop=%s/%s znames=%s ready_at=%s frames=%d  pace=%d fps=%g slow=%g  bitlib=%s framestub=%s  cachepct=%s owned=%s usec hyperlink/itemcount/strwidth=%s/%s/%s  nplates=%s%s" % (
    SCEN, ADDON, env("NITEMS"), env("ZONEN"), env("HEAVY"), env("WDROP", "0"), env("WROWS", "2000"), env("ZNAMES"), env("READY_AT"), FRAMES,
    PACE, FPS, SLOW, env("BITLIB", "fast"), env("FRAMESTUB", "nil"), env("CACHEPCT", "100"), env("OWNED", "0"),
    env("USEC_HYPERLINK", "0"), env("USEC_ITEMCOUNT", "0"), env("USEC_STRWIDTH", "0"), env("NPLATES", "0"),
    ("  addons=" + ";".join(a.split("|")[1] for a in ADDONS)) if len(ADDONS) > 1 else ""))
print("after load: %.0f KB  (compile %.1f ms, exec %.1f ms)" % (mem(), compile_ms, exec_ms))
if int(env("ZNAMES")) == 2:
    nz = L.eval('_BUILD_HOME')(ns.Zones)
    print("ZNAMES=2: consistent zone names built from %d zones" % nz)

# ---------------------------------------------------------------- instrumentation
L.execute(r'''
_GSN, _GSU, _GSROWS = 0, {}, 0
_AFTER, _TIMES = {}, {}
function _INSTR(ns, aname)
  local orig = ns.GetSources
  ns.GetSources = function(id)
    _GSN = _GSN + 1; _GSU[id] = true
    local r = orig(id); _GSROWS = _GSROWS + #r
    return r
  end
  local after = ns.After
  ns.After = function(delay, func, name)
    local key = name
    if not key then local info = debug.getinfo(func, "S") key = info.short_src:gsub("^.*/", "") .. ":" .. info.linedefined end
    key = aname .. ":" .. key
    return after(delay, function()
      local t = os.clock()
      local ok, e = pcall(func)
      local ms = (os.clock() - t) * 1000
      local a = _AFTER[key] or { n = 0, ms = 0, max = 0 }
      a.n = a.n + 1; a.ms = a.ms + ms; if ms > a.max then a.max = ms end
      _AFTER[key] = a
      if not ok then error(e, 0) end
    end, name)
  end
  local function wrap(tbl, key, label)
    local o = tbl[key]
    if not o then return end
    tbl[key] = function(...)
      local t = os.clock()
      local a, b, c = o(...)
      local ms = (os.clock() - t) * 1000
      local k = aname .. ":" .. label
      local e = _TIMES[k] or { n = 0, ms = 0, max = 0 }
      e.n = e.n + 1; e.ms = e.ms + ms; if ms > e.max then e.max = ms end
      _TIMES[k] = e
      return a, b, c
    end
  end
  wrap(ns, "ExportStatusCache", "ExportStatusCache")
  wrap(ns.Engine, "ExportCache", "ExportCache")
  wrap(ns.Engine, "ImportCache", "ImportCache")
  wrap(ns.Engine, "Universe", "Universe")
  wrap(ns, "SnapshotAltCan", "SnapshotAltCan")
  wrap(ns, "TrimMerchantDb", "TrimMerchantDb")
end
''')
for an, n_ in nss: L.eval('_INSTR')(n_, an)

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

if env("ALLOC"):
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
    local cc = coroutine.create
    coroutine.create = function(fn) return cc(function(...) _HOOKON() return fn(...) end) end
    _HOOKON()
    ''')

for an, _ in nss: fire("ADDON_LOADED", an)
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
print("after login events: %.0f KB" % mem())

# ---------------------------------------------------------------- frame loop
peak = 0
t0 = time.time()
elapsed = BASE_MS / 1000.0
ft = []            # real ms per frame
ready_frame = summaries_frame = done_frame = None
rescan_seen = False
gc_at_ready = (0, 0.0)
for i in range(1, FRAMES + 1):
    _t = time.perf_counter(); tick(elapsed if PACE else 0.016); real_ms = (time.perf_counter() - _t) * 1000
    ft.append(real_ms)
    if PACE: elapsed = (BASE_MS + real_ms * SLOW) / 1000.0
    m = mem()
    peak = max(peak, m)
    sts = [status(n_) for _, n_ in nss]
    rd_all = all(s[1] == "ready" for s in sts)
    tags_all = ",".join(s[0] for s in sts if s[0])
    if "summary" in tags_all: rescan_seen = True
    if rd_all and ready_frame is None:
        ready_frame = i
        gc_at_ready = (L.eval('_GCN'), L.eval('_GCMS'))
    if ready_frame and summaries_frame is None and "warmup" in tags_all: summaries_frame = i
    if i % (FRAMES // 30 or 1) == 0:
        print("frame %5d  lua %8.0f KB  %s  jobs=[%s]" % (i, m, "ready" if rd_all else "notready", tags_all[:150]))
    if rd_all and tags_all == "" and done_frame is None:
        done_frame = i; print("scan finished at frame %d (data ready at frame %d)" % (i, ready_frame))
    if m > 1500000:
        print("RUNAWAY at frame", i, "%.0f KB" % m)
        break
print("peak %.0f KB, %.1fs real" % (peak, time.time() - t0))
if ready_frame:
    end = done_frame or len(ft)
    win = ft[ready_frame - 1:end]
    busy = [x for x in win if x > 1.0]
    gcn, gcms = L.eval('_GCN'), L.eval('_GCMS')
    gcn -= gc_at_ready[0]; gcms -= gc_at_ready[1]
    emul = sum(BASE_MS + x * SLOW for x in win) / 1000.0
    print("scan window: %d frames (ready %d -> %s), addon %.0f ms real (busy frames %d: avg %.1f, max %.1f ms; %d over 2x budget), GC steps %d / %.0f ms (%.1f per step)" % (
        len(win), ready_frame, ("idle %d" % done_frame) if done_frame else "NOT DONE", sum(win), len(busy),
        sum(busy) / max(1, len(busy)), max(win) if win else 0, sum(1 for x in win if x * SLOW > 20), gcn, gcms, gcms / max(1, gcn)))
    print("   emulated wall at %g fps, slow x%g: scan %.1f s%s; summaries done at frame %s" % (
        FPS, SLOW, emul, "" if PACE else " (pacing not fed to the addon; PACE=1 does)", summaries_frame))
print("GetSources calls: %d  unique items: %d  rows built: %d" % (L.eval('_GSN'), L.eval('(function() local n=0 for _ in pairs(_GSU) do n=n+1 end return n end)()'), L.eval('_GSROWS')))

def dump_times(title, tbl, top=10):
    rows = sorted(((k, tbl[k]) for k in tbl.keys()), key=lambda kv: -kv[1].ms)
    if not rows: return
    print(title)
    for k, e in rows[:top]:
        print("   %-44s n=%4d  total %8.1f ms  max %7.1f ms" % (k, e.n, e.ms, e.max))
dump_times("ANx.After callbacks (real ms):", L.eval('_AFTER'))
dump_times("wrapped calls (real ms):", L.eval('_TIMES'))
cc = L.eval('_CC')
ccs = sorted(((k, cc[k]) for k in cc.keys()), key=lambda kv: -kv[1])
print("modelled C calls: " + "  ".join("%s=%d" % kv for kv in ccs) + "  (charged %.0f ms; queries %d, pending %d)" % (L.eval('_CHARGED_US') / 1000.0, L.eval('_QUERIES'), L.eval('#_PENDING')))
if SVFILE:
    print("cached login: rescan ran: %s; ImportCache: %s" % (rescan_seen, ", ".join("%.1f ms" % e.max for k, e in L.eval('_TIMES').items() if k.endswith("ImportCache"))))

def perfstats(label=""):
    r = L.eval(r'''function(ns)
      if not (ns.Engine and ns.Engine.PerfStats) then return nil end
      local p = ns.Engine.PerfStats()
      local out = {}
      for k, v in pairs(p) do out[#out+1] = tostring(k) .. "=" .. (type(v) == "number" and string.format("%.4g", v) or tostring(v)) end
      table.sort(out)
      return table.concat(out, "  ")
    end''')(ns)
    print("Engine.PerfStats%s: %s" % (label, r))
    L.execute('_CHAT = {}')
    L.eval('function() if _SLASH1 then _SLASH1("perf") end end')()
    chat = L.eval('_CHAT')
    lines = [re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", chat[i]) for i in range(1, len(chat) + 1)]
    if lines:
        print("/an perf%s:" % label)
        for l in lines: print("   " + l)
perfstats()

# ---------------------------------------------------------------- UI render scenario
if env("UI") == "1":
    print(L.eval(r'''function(ns)
      local out = {}
      local function M(label, fn)
        collectgarbage("collect")
        local m0 = collectgarbage("count")
        local c0 = {} for k, v in pairs(_CC) do c0[k] = v end
        local t = os.clock()
        local ok, e = pcall(fn)
        local ms = (os.clock() - t) * 1000
        local d = {}
        for k, v in pairs(_CC) do if v - (c0[k] or 0) > 0 then d[#d+1] = k .. "=" .. (v - (c0[k] or 0)) end end
        table.sort(d)
        out[#out+1] = string.format("   %-46s %8.1f ms  alloc~%5.0f KB  %s%s", label, ms, collectgarbage("count") - m0, table.concat(d, " "), ok and "" or ("  ERR " .. tostring(e)))
      end
      M("UI.Show(true) root screen", function() ns.UI.Show(true) end)
      M("push content exp1", function() ns.UI.Push({ type = "content", exp = 1 }) end)
      M("push instances exp1 D (cold)", function() ns.UI.Push({ type = "instances", exp = 1, kind = "D" }) end)
      M("re-render instances", function() ns.UI.Render() end)
      M("InvalidateStats + re-render", function() ns.Engine.InvalidateStats() ns.UI.Render() end)
      M("push zones exp1 W", function() ns.UI.Push({ type = "zones", exp = 1, kind = "W" }) end)
      M("push zone screen (first zone)", function() local z = ns.Engine.ZonesFor(1, true)[1] ns.UI.Push({ type = "zone", exp = 1, zone = z, kind = "W" }) end)
      M("items (instance 1, first diff)", function()
        local inst = ns.Instances[1]
        local d = ns.Engine.InstanceDiffs(inst)[1]
        ns.UI.Push({ type = "items", title = inst.name, items = d.items, zoneName = inst.name,
          srcFilter = ns.INSTANCE_DROP_SRC, instMap = inst.map, instName = inst.name, instDiff = d.label })
      end)
      M("items re-render (same rev)", function() ns.UI.Render() end)
      M("search 'item1' (whole universe)", function() ns.db.searchType = "items" ns.UI.searchQuery = "item1" ns.UI.Push({ type = "search" }) end)
      M("search re-render", function() ns.UI.Render() end)
      M("PaintVisibleRows (scroll notch)", function() ns.UI.PaintVisibleRows() end)
      M("RemainingReport inline", function() ns.Engine.RemainingReport(false) end)
      local d = {}
      for k, v in pairs(_CC) do d[#d+1] = k .. "=" .. v end
      table.sort(d)
      out[#out+1] = "   modelled C calls after UI: " .. table.concat(d, " ") .. string.format("  (charged %.0f ms)", _CHARGED_US / 1000)
      return "UI renders (real ms, lupa):\n" .. table.concat(out, "\n")
    end''')(ns))

if env("BENCH") == "predicates":
    print(L.eval(r'''function(ns)
      local E = ns.Engine
      local N = 20000
      local ids = {}
      for i = 1, N do ids[i] = 10000 + ((i * 13) % 20000) end
      local out = {}
      local function T(name, fn)
        collectgarbage("collect"); collectgarbage("stop")
        local m0 = collectgarbage("count")
        local t = os.clock()
        for i = 1, N do fn(ids[i]) end
        local ms = (os.clock() - t) * 1000
        local kb = collectgarbage("count") - m0
        collectgarbage("restart")
        out[#out+1] = string.format("   %-26s %7.1f ms /20k = %5.2f us each  %7.0f KB", name, ms, ms * 1000 / N, kb)
      end
      T("bit.band(x,255)", function(id) return bit.band(id, 255) end)
      T("Engine.Eligible", function(id) return E.Eligible(id) end)
      T("ANx.IsAttunableAtAll", function(id) return ns.IsAttunableAtAll(id) end)
      T("ANx.CanCount", function(id) return ns.CanCount(id) end)
      T("Engine.ScopeLeft char", function(id) return E.ScopeLeft(id, "char") end)
      T("Engine.BestSource", function(id) return E.BestSource(id) end)
      local t = os.clock() E.RemainingByCategory("char") out[#out+1] = string.format("   %-26s %7.1f ms", "RemainingByCategory", (os.clock() - t) * 1000)
      return "predicate costs (BITLIB=" .. (os.getenv("BITLIB") or "fast") .. "):\n" .. table.concat(out, "\n")
    end''')(ns))

if env("ALLOC"):
    a = L.eval('_ALLOC')
    rows = sorted(((k, v) for k, v in a.items()), key=lambda x: -x[1])[:25]
    tot = sum(v for _, v in a.items())
    print("total allocated ~%.0f MB" % (tot / 1024))
    for k, v in rows: print("%9.0f KB  %s" % (v, k))
miss = L.eval('_MISSING')
print("missing globals read:", sorted(((k, v) for k, v in miss.items()), key=lambda x: -x[1])[:20])
if env("CHAT") == "1":
    chat = L.eval('_CHAT')
    for i in range(1, len(chat) + 1): print("   chat:", re.sub(r"\|c[0-9a-fA-F]{8}|\|r", "", chat[i]))

if env("PROFILE"):
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
  for i = 1, 20 do if out[i] then lines[#lines+1] = string.format("%10.0f KB  %s", out[i][2] / 1024, out[i][1]) end end
  return table.concat(lines, "\n")
end''')
    L.eval('collectgarbage("collect")')
    print("after full GC: %.0f KB" % mem())
    print(prof(ns))

# ---------------------------------------------------------------- logout / save
if LOGOUT:
    _t = time.perf_counter(); fire("PLAYER_LOGOUT"); lo = (time.perf_counter() - _t) * 1000
    print("PLAYER_LOGOUT handlers: %.1f ms real" % lo)
    for k, e in sorted(L.eval('_TIMES').items()):
        if "Export" in k: print("   %-44s n=%4d  total %8.1f ms  max %7.1f ms" % (k, e.n, e.ms, e.max))
if SAVE:
    L.execute(r'''
    function _SERIALIZE(name, t)
      local buf, n = {}, 0
      local esc = { ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r", ['"'] = '\\"', ["\\"] = "\\\\" }
      local function qstr(s)
        local r = s:gsub('[%c"\\]', function(c) return esc[c] or string.format("\\%03d", c:byte()) end)
        return '"' .. r .. '"'
      end
      local function val(v)
        local tv = type(v)
        if tv == "string" then return qstr(v)
        elseif tv == "number" then
          if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
          return string.format("%.14g", v)
        elseif tv == "boolean" then return tostring(v) end
        return "nil"
      end
      local function key(k)
        if type(k) == "string" then return "[" .. qstr(k) .. "]" end
        return "[" .. val(k) .. "]"
      end
      local function write(t, indent)
        n = n + 1; buf[n] = "{\n"
        local pad = string.rep("\t", indent + 1)
        local cnt = #t
        for i = 1, cnt do
          local v = t[i]
          n = n + 1; buf[n] = pad
          if type(v) == "table" then write(v, indent + 1); n = n + 1; buf[n] = ", -- [" .. i .. "]\n"
          else n = n + 1; buf[n] = val(v) .. ", -- [" .. i .. "]\n" end
        end
        for k, v in pairs(t) do
          if not (type(k) == "number" and k >= 1 and k <= cnt and k == math.floor(k)) and type(v) ~= "function" then
            n = n + 1; buf[n] = pad .. key(k) .. " = "
            if type(v) == "table" then write(v, indent + 1); n = n + 1; buf[n] = ",\n"
            else n = n + 1; buf[n] = val(v) .. ",\n" end
          end
        end
        n = n + 1; buf[n] = string.rep("\t", indent) .. "}"
      end
      n = n + 1; buf[n] = name .. " = "
      write(t, 0)
      n = n + 1; buf[n] = "\n"
      return table.concat(buf)
    end''')
    ser = L.eval('_SERIALIZE')
    parts = []
    for gname in ("AttuneNextDB", "AttuneNextSimpleDB"):
        t = L.eval(gname)
        if t is not None: parts.append(ser(gname, t))
    text = "".join(parts)
    with open(SAVE, "w", encoding="utf-8", newline="\n") as fh: fh.write(text)
    print("saved SavedVariables %s: %.0f KB, %d lines" % (SAVE, len(text) / 1024, text.count("\n")))
