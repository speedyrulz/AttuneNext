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

# ---- pacing experiment knobs (patch Engine.lua source text before loading) ----
GCSTEP   = os.environ.get("GCSTEP")      # int KB, 0 = skip the step entirely
BUDGET   = os.environ.get("BUDGET")      # ms
YIELDN   = os.environ.get("YIELDN")      # MaybeYield granularity
GCMODE   = os.environ.get("GCMODE", "fixed")  # fixed | prop
PROPMULT = float(os.environ.get("PROPMULT", "1"))
PROPFLOOR= os.environ.get("PROPFLOOR", "512")
GCPAUSE  = os.environ.get("GCPAUSE")     # setpause during the scan
GCSTEPMUL= os.environ.get("GCSTEPMUL")   # setstepmul during the scan

def patch_engine(s):
    def rep(old, new, n=1):
        assert s.count(old) == n, ("patch anchor count", old, s.count(old))
        return s.replace(old, new)
    if BUDGET is not None:
        s = rep("local BUDGET_MS = 10\n", "local BUDGET_MS = %s\n" % BUDGET)
    if YIELDN is not None:
        s = rep("    if yieldCheck >= 25 then\n", "    if yieldCheck >= %s then\n" % YIELDN)
    # --- GC step block (one of three modes), wrapped in timing instrumentation ---
    if GCMODE == "fixed":
        if GCSTEP is None or int(GCSTEP) != 0:
            if GCSTEP is not None:
                s = rep("local GC_STEP_KB = 2048", "local GC_STEP_KB = %s" % GCSTEP)
            gcblock = '    collectgarbage("step", GC_STEP_KB)\n'
        else:
            gcblock = '    -- (pacing experiment: no GC step)\n'
    elif GCMODE == "prop":
        s = rep("    local start = Clock()\n    while Clock() - start < BUDGET_MS do\n",
                "    local start = Clock()\n    local memBefore = collectgarbage(\"count\")\n    while Clock() - start < BUDGET_MS do\n")
        gcblock = ('    do local alloc = collectgarbage("count") - memBefore\n'
                   '       local stepkb = math.max(alloc * %s, %s)\n'
                   '       _PROPSUM = (_PROPSUM or 0) + stepkb; _PROPN = (_PROPN or 0) + 1\n'
                   '       if stepkb > 0 then collectgarbage("step", stepkb) end end\n' % (PROPMULT, PROPFLOOR))
    elif GCMODE == "timed":
        # time-capped: small steps until GCMS ms of this frame are used (or the collector finished a cycle)
        gcblock = ('    do local g1 = Clock(); local n = 0\n'
                   '       repeat n = n + 1 until collectgarbage("step", %s) or Clock() - g1 >= %s\n'
                   '       _PROPSUM = (_PROPSUM or 0) + n * %s; _PROPN = (_PROPN or 0) + 1 end\n' % (
                       os.environ.get("TSTEP", "256"), os.environ.get("GCMS", "3"), os.environ.get("TSTEP", "256")))
    elif GCMODE == "v2":
        # the proto copies already carry the v2 pump; optional knob overrides
        for env, anchor in (("GCSHARE", "local GC_SHARE = 0.3"), ("SLICEMS", "local SLICE_MS = 2"),
                            ("GCSTEPKB", "local GC_STEP_KB = 256"), ("GCSTEPSMAX", "local GC_STEPS_MAX = 8"),
                            ("COMBATMS", "local COMBAT_BUDGET_MS = 4")):
            v = os.environ.get(env)
            if v is not None:
                s = rep(anchor, anchor.rsplit("=", 1)[0] + "= " + v)
        gcblock = None
    else:
        raise SystemExit("bad GCMODE")
    if gcblock is None:
        s = rep("    CollectSome(start, budget)\n",
                "    _LOOPMS = Clock() - start; _FRONTTAG = job.tag\n    local g0 = Clock()\n    CollectSome(start, budget)\n    _GCMS = Clock() - g0\n")
    else:
        s = rep('    collectgarbage("step", GC_STEP_KB)\n',
                "    _LOOPMS = Clock() - start; _FRONTTAG = job.tag\n    local g0 = Clock()\n" + gcblock + "    _GCMS = Clock() - g0\n")
    # instrumentation: longest single resume
    s = rep("        local ok, err = coroutine.resume(job.co)\n",
            "        local r0 = Clock()\n        local ok, err = coroutine.resume(job.co)\n"
            "        local rd = Clock() - r0; if rd > _MAXRESUME then _MAXRESUME = rd; _MAXRESUMETAG = job.tag end\n")
    if GCPAUSE is not None or GCSTEPMUL is not None:
        # apply when a scan starts, restore when the queue drains (pump goes to sleep)
        s = rep("    Engine.scanning = true\n    local start = Clock()\n",
                "    if not _GCTUNED then _GCTUNED = true\n"
                + ("        _OLDPAUSE = collectgarbage(\"setpause\", %s)\n" % GCPAUSE if GCPAUSE else "")
                + ("        _OLDSTEPMUL = collectgarbage(\"setstepmul\", %s)\n" % GCSTEPMUL if GCSTEPMUL else "")
                + "    end\n    Engine.scanning = true\n    local start = Clock()\n")
        s = rep("        Engine.scanning = false\n        self:Hide()   -- sleep until the next Enqueue (OnUpdate needs shown)\n",
                "        Engine.scanning = false\n        if _GCTUNED then _GCTUNED = nil\n"
                + ("            collectgarbage(\"setpause\", _OLDPAUSE)\n" if GCPAUSE else "")
                + ("            collectgarbage(\"setstepmul\", _OLDSTEPMUL)\n" if GCSTEPMUL else "")
                + "        end\n        self:Hide()   -- sleep until the next Enqueue (OnUpdate needs shown)\n")
    return s

loader = L.eval("""function(src, name, aname, ns)
  local fn, err = loadstring(src, "@" .. aname .. "/" .. name)
  if not fn then return false, err end
  local ok, e = pcall(fn, aname, ns)
  return ok, e
end""")
L.execute('_MAXRESUME, _MAXRESUMETAG, _LOOPMS, _GCMS, _FRONTTAG = 0, "", 0, 0, ""')
nss = []
for spec in ADDONS:
    path, aname = spec.split("|")
    ns_ = L.table()
    toc = open(os.path.join(path, aname + ".toc"), encoding="utf-8-sig").read().splitlines()
    for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
        if f in SKIP: continue
        s = open(os.path.join(path, f), encoding="utf-8").read()
        if f == "Engine.lua":
            s = patch_engine(s)
            if os.environ.get("DUMP_ENGINE"): open(os.environ["DUMP_ENGINE"], "w").write(s)
        ok, err = loader(s, f, aname, ns_)
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
# tick returns: total OnUpdate ms this frame, max single OnUpdate ms this frame
tick = L.eval('''function(dt)
  _ADV(dt)
  local errs = 0
  local fr = _FRAMES()
  local clock = os.clock
  local tot, mx = 0, 0
  for i = 1, #fr do
    local f = fr[i]
    if f._shown and f._scripts.OnUpdate then
      local t0 = clock()
      local ok, e = pcall(f._scripts.OnUpdate, f, dt)
      local d = (clock() - t0) * 1000
      tot = tot + d
      if d > mx then mx = d end
      if not ok then errs = errs + 1; if errs < 3 then print("ONUPDATE ERROR", e) end end
    end
  end
  return tot, mx
end''')
status = L.eval('''function(ns)
  local E = ns.Engine
  local tags = {}
  if E and E.scanJobs then for _, j in ipairs(E.scanJobs) do tags[#tags+1] = tostring(j.tag) .. (j.extra and ("+" .. #j.extra) or "") end end
  return table.concat(tags, ","), ns.dataReady and "ready" or "notready"
end''')

if os.environ.get("SLICEPROF"):
    # record the longest stretches of coroutine work between two yield points (with the yield site)
    L.eval(r'''function(ns)
      _SLICES = {}
      local E = ns.Engine
      local clock = os.clock
      local lastResume = nil
      local function note(where)
        if lastResume then
          local d = (clock() - lastResume) * 1000
          if d > 3 then
            local info = debug.getinfo(3, "Sl")
            local key = (info and (info.short_src .. ":" .. tostring(info.currentline)) or "?")
            local r = _SLICES[key]
            if not r then r = { n = 0, max = 0, sum = 0 } _SLICES[key] = r end
            r.n = r.n + 1; r.sum = r.sum + d; if d > r.max then r.max = d; r.tb = debug.traceback("", 3) end
          end
        end
      end
      local my, yn = E.MaybeYield, E.YieldNow
      E.MaybeYield = function() note("maybe") my() lastResume = clock() end
      E.YieldNow = function() note("now") yn() lastResume = clock() end
      -- also time from coroutine start
      local cc = coroutine.create
      coroutine.create = function(fn) return cc(function(...) lastResume = clock() return fn(...) end) end
    end''')(ns)
if os.environ.get("COMBAT_WINDOW"):
    a, b = [float(x) for x in os.environ["COMBAT_WINDOW"].split(",")]
    L.execute("local a, b = %f, %f; _COMBATN = 0; function InCombatLockdown() local c = GetTime() >= a and GetTime() < b; if c then _COMBATN = _COMBATN + 1 end return c end" % (a, b))
L.eval(r'''function(ns)
  _EXPORTMS, _EXPORTN = 0, 0
  local orig = ns.Engine.ExportCache
  if orig then ns.Engine.ExportCache = function(...)
    local t0 = os.clock(); local r = orig(...); local d = (os.clock() - t0) * 1000
    _EXPORTN = _EXPORTN + 1; if d > _EXPORTMS then _EXPORTMS = d end
    return r end end
end''')(ns)
for an, _ in nss: fire("ADDON_LOADED", an)
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
print("after login events: %.0f KB" % mem())
L.execute(r'''
  _GSN, _GSU, _GSROWS = 0, {}, 0
''')
wrap = L.eval(r'''function(ns)
  local orig = ns.GetSources
  ns.GetSources = function(id)
    _GSN = _GSN + 1; _GSU[id] = true
    local r = orig(id); _GSROWS = _GSROWS + #r
    return r
  end
end''')
for _, n_ in nss: wrap(n_)
peak = 0
t0 = time.time()
ready_frame = None
done = None
scan_ms = 0.0          # sum of per-frame OnUpdate ms from ready until scan finished
scan_frames = 0
max_frame_ms = 0.0
max_frame_at = 0
over12 = over16 = over20 = over25 = 0
frame_ms = []
loop_ms_sum = gc_ms_sum = 0.0; gc_ms_max = 0.0; loop_ms_max = 0.0; max_frame_tag = ""
readpump = L.eval('function() local l, g, t = _LOOPMS, _GCMS, _FRONTTAG; _LOOPMS, _GCMS = 0, 0; return l, g, t end')
for i in range(1, FRAMES + 1):
    tot, mx = tick(0.016)
    lms, gms, ftag = readpump()
    m = mem()
    peak = max(peak, m)
    tg, rd = status(ns)
    if rd == "ready" and ready_frame is None: ready_frame = i
    if ready_frame is not None and done is None:
        scan_ms += tot; scan_frames += 1
        frame_ms.append(tot)
        if tot > max_frame_ms: max_frame_ms, max_frame_at, max_frame_tag = tot, i, ftag
        loop_ms_sum += lms; gc_ms_sum += gms
        if gms > gc_ms_max: gc_ms_max = gms
        if lms > loop_ms_max: loop_ms_max = lms
        if tot > 12: over12 += 1
        if tot > 16: over16 += 1
        if tot > 20: over20 += 1
        if tot > 25: over25 += 1
    if i % (FRAMES // 30 or 1) == 0:
        print("frame %5d  lua %8.0f KB  %s  jobs=[%s]" % (i, m, rd, tg[:150]))
    if rd == "ready" and tg == "" and done is None:
        done = i; print("scan finished at frame", i)
    if m > 1500000:
        print("RUNAWAY at frame", i, "%.0f KB" % m)
        break
end_kb = mem()
print("peak %.0f KB, %.1fs" % (peak, time.time() - t0))
print("GetSources calls:", L.eval('_GSN'), "unique items:", L.eval('(function() local n=0 for _ in pairs(_GSU) do n=n+1 end return n end)()'), "rows built:", L.eval('_GSROWS'))
# equivalence: summary set sizes
sizes = L.eval(r'''function(ns)
  local out = {}
  for exp = 1, 3 do
    local s = ns.Engine.GetSummary(exp)
    if s then
      local parts = {}
      for _, k in ipairs({"D","R","Q","W","V","C"}) do
        local n = 0 for _ in pairs(s[k] or {}) do n = n + 1 end
        parts[#parts+1] = k .. "=" .. n
      end
      local dl, rl = 0, 0
      for _, arr in pairs(s.Dl or {}) do for _ in pairs(arr) do dl = dl + 1 end end
      for _, arr in pairs(s.Rl or {}) do for _ in pairs(arr) do rl = rl + 1 end end
      parts[#parts+1] = "Dl=" .. dl .. " Rl=" .. rl
      out[#out+1] = "exp" .. exp .. "{" .. table.concat(parts, " ") .. "}"
    else out[#out+1] = "exp" .. exp .. "{NOT READY}" end
  end
  return table.concat(out, " ")
end''')(ns)
print("summary sets:", sizes)
print("ExportCache calls during run: %d, longest %.1f ms" % (L.eval('_EXPORTN'), L.eval('_EXPORTMS')))
if os.environ.get("COMBAT_WINDOW"): print("InCombatLockdown() returned true %d times" % L.eval('_COMBATN'))
if os.environ.get("SLICEPROF"):
    sl = L.eval('_SLICES')
    rows = sorted(((k, v) for k, v in sl.items()), key=lambda x: -x[1]['max'])[:8]
    for k, v in rows:
        print("SLICE max %.1f ms  n=%d  mean %.1f ms  at %s" % (v['max'], v['n'], v['sum']/v['n'], k))
        print("   " + str(v['tb']).strip().replace("\n", "\n   ")[:600])
if os.environ.get("POSTGC"):
    # micro-benchmark: drive one full GC cycle with 1 KB steps after the scan and
    # time every single step call -> the longest one is the non-incremental atomic phase
    print("POSTGC:", L.eval(r'''(function()
      local clock = os.clock
      collectgarbage("collect")                 -- start from a clean pause state
      local live = collectgarbage("count")
      -- allocate garbage so the heap looks like mid-scan (~40% garbage), then step a cycle
      local junk = {}
      for i = 1, 150000 do junk[i] = { a = i, b = "x", c = i * 2 } end
      junk = nil
      local total, n, mx, mxi, big = 0, 0, 0, 0, {}
      local t0 = clock()
      -- lower the threshold until the collector starts, then 1 KB steps until the cycle ends
      while true do
        local s0 = clock()
        local done = collectgarbage("step", 1)
        local d = (clock() - s0) * 1000
        n = n + 1; total = total + d
        if d > mx then mx = d; mxi = n end
        if d > 1 then big[#big+1] = string.format("%d:%.1f", n, d) end
        if done then break end
        if n > 2000000 then break end
      end
      return string.format("live %.0f KB; cycle: %d step(1) calls, %.1f ms total, max single call %.2f ms (call #%d), calls>1ms: %s",
        live, n, total, mx, mxi, table.concat(big, " "))
    end)()'''))
L.eval('collectgarbage("collect")')
retained = mem()
if GCMODE in ("prop", "timed"):
    print("prop/timed step: mean %.0f KB over %d frames" % (L.eval('_PROPSUM or 0') / max(1, L.eval('_PROPN or 0')), L.eval('_PROPN or 0')))
import statistics
fm = sorted(frame_ms) if frame_ms else [0]
p50 = fm[len(fm)//2]; p95 = fm[int(len(fm)*0.95)]; p99 = fm[int(len(fm)*0.99)]
sf = (done - ready_frame) if (done and ready_frame) else -1
print("RESULT cfg=%s ready=%s done=%s scan_frames=%d peak_kb=%.0f end_kb=%.0f retained_kb=%.0f scan_cpu_ms=%.0f ms_per_frame=%.2f p50=%.2f p95=%.2f p99=%.2f max_frame_ms=%.2f at=%d tag=%s over12=%d over16=%d over20=%d over25=%d loop_ms_mean=%.2f loop_ms_max=%.2f gc_ms_mean=%.2f gc_ms_max=%.2f max_resume_ms=%.2f max_resume_tag=%s" % (
    os.environ.get("CFG", "?"), ready_frame, done, sf, peak, end_kb, retained, scan_ms, scan_ms / max(1, scan_frames), p50, p95, p99, max_frame_ms, max_frame_at, max_frame_tag, over12, over16, over20, over25,
    loop_ms_sum / max(1, scan_frames), loop_ms_max, gc_ms_sum / max(1, scan_frames), gc_ms_max, L.eval('_MAXRESUME'), L.eval('_MAXRESUMETAG')))
