"""Cached-login replay for the svpack prototype.

Loads a structCache serialized by svpack_bench.py (as the client would load
SavedVariables), then runs the login sequence: ADDON_LOADED (provisional
import), PLAYER_LOGIN, data ready (validated import), background jobs until
idle. Reports SV parse ms, ImportCache ms per call, whether a rescan ran,
frames to idle, peak Lua KB, and resident KB per cache after a full GC.
Env: ADDON, SVFILE, NITEMS, ZONEN, HEAVY, READY_AT, MAXFRAMES, OPENZONES=1
(also decode every zone afterwards, as browsing every zone screen would).
"""
import os, sys, time
import lupa.lua51 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.environ["ADDON"]
SVFILE = os.environ["SVFILE"]
MAXFRAMES = int(os.environ.get("FRAMES", "1500"))

hsrc = open(os.path.join(HERE, "harness_orig.py"), encoding="utf-8").read()
STUBS = hsrc[hsrc.index("STUBS = r'''") + len("STUBS = r'''"):]
STUBS = STUBS[:STUBS.index("'''")]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
L.execute(STUBS)

if os.environ.get("FASTBIT"):
    L.execute(r"""
    local mfloor = math.floor
    local P2 = {} for i = 0, 31 do P2[2^i] = true end
    local slow = bit.band
    function bit.band(a, b, ...)
      if ... then return bit.band(bit.band(a, b), ...) end
      a = a % 4294967296; b = b % 4294967296
      if P2[b + 1] then return a % (b + 1) end
      if P2[b] then return (mfloor(a / b) % 2) * b end
      return slow(a, b)
    end
    """)
    print("FASTBIT: fast bit.band installed")
mem = L.eval('function() return collectgarbage("count") end')

# --- SavedVariables load, as the client does it at login ---
src = open(SVFILE, encoding="utf-8").read()
r = L.eval(r'''function(src)
  collectgarbage("collect")
  local m0 = collectgarbage("count")
  local t0 = os.clock()
  local f = assert(loadstring(src, "=sv"))
  local t1 = os.clock()
  f()
  local t2 = os.clock()
  f = nil
  AttuneNextDB = { structCache = _SVTEST.structCache }
  _SVTEST = nil
  collectgarbage("collect")
  return (t1 - t0) * 1000, (t2 - t1) * 1000, collectgarbage("count") - m0
end''')(src)
del src
print("SV parse: compile %.1f ms, exec %.1f ms, parsed structCache resident %.0f KB" % r)
L.execute(r'''setmetatable(_G, { __index = function(t, k) return nil end })''')

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

L.execute(r'''
_IMPORTS = {}
function _WRAP(ns)
  local E = ns.Engine
  local orig = E.ImportCache
  E.ImportCache = function(prov)
    local t0 = os.clock()
    local ok = orig(prov)
    _IMPORTS[#_IMPORTS + 1] = string.format("%s=%s %.1f ms", prov and "provisional" or "validated", tostring(ok), (os.clock() - t0) * 1000)
    return ok
  end
end
_TAGS = {}
function _NOTE_TAGS(ns)
  for _, j in ipairs(ns.Engine.scanJobs) do _TAGS[tostring(j.tag)] = true end
end
''')
L.eval("_WRAP")(ns)
L.execute(r"""
_GS = 0
function _WRAPGS(ns) local o = ns.GetSources ns.GetSources = function(id) _GS = _GS + 1 return o(id) end end
function _COLDRENDER(ns)
  local E = ns.Engine
  local out = {}
  out[#out+1] = "cachesWarm=" .. tostring(E.CachesWarm()) .. " WarmupIncomplete=" .. tostring(E.WarmupIncomplete())
  E.InvalidateStats(); E.FlushSources(); collectgarbage("collect")
  local sum = E.GetSummary(3)
  local g0, t0, m0 = _GS, os.clock(), collectgarbage("count")
  local r = E.UnionStats(E.AllContentSets(sum), "probe")
  out[#out+1] = string.format("first expansion-overview stats (WotLK, all 6 sets): %.1f ms, GetSources=%d, alloc %.0f KB, total=%d", (os.clock()-t0)*1000, _GS-g0, collectgarbage("count")-m0, r.total)
  g0, t0 = _GS, os.clock()
  local r2 = E.UnionStats(E.AllContentSets(sum), "probe2")
  out[#out+1] = string.format("same stats again (flags now warm): %.1f ms, GetSources=%d", (os.clock()-t0)*1000, _GS-g0)
  E.InvalidateStats(); E.FlushSources(); collectgarbage("collect")
  local items = ns.ItemsInZone(ns.Zones[1].zone)
  g0, t0 = _GS, os.clock()
  local r3 = E.StatsWithBest(items, "probe3", ns.Zones[1].name, ns.WORLD_DROP_SRC)
  out[#out+1] = string.format("one zone screen StatsWithBest (%d items): %.1f ms, GetSources=%d", #items, (os.clock()-t0)*1000, _GS-g0)
  return table.concat(out, "\n")
end
""")
L.eval("_WRAPGS")(ns)
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
  _NOTE_TAGS(ns)
  return #ns.Engine.scanJobs, ns.dataReady and "ready" or "notready"
end''')

print("after load: %.0f KB" % mem())
fire("ADDON_LOADED", "AttuneNext")
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
peak = 0
lastBusy = 0
t0 = time.time()
for i in range(1, MAXFRAMES + 1):
    tick(0.016)
    m = mem()
    peak = max(peak, m)
    nj, rd = status(ns)
    if nj > 0: lastBusy = i
    if i % 250 == 0: print("frame %5d  lua %8.0f KB  %s  jobs=%d" % (i, m, rd, nj))
tags = sorted(L.eval("_TAGS").keys())
print("last busy frame %d of %d, wall %.1fs, peak %.0f KB, job tags seen: %s" % (lastBusy, MAXFRAMES, time.time() - t0, peak, ",".join(tags)))
print("ImportCache calls:", "; ".join(L.eval("_IMPORTS").values()))
print("rescan ran:", any(t.startswith("summary") for t in tags))
print("warmup job ran:", any(t == "warmup" for t in tags), "| GetSources during login+idle:", L.eval("_GS"))
print(L.eval("_COLDRENDER")(ns))

L.execute(r'''
function _GETUP(fn, name)
  local i = 1
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then return nil end
    if n == name then return v end
    i = i + 1
  end
end
function _SZ(v, seen)
  local function sz(v)
    local t = type(v)
    if t == "string" then if seen[v] then return 0 end seen[v] = true return 24 + #v end
    if t ~= "table" then return 0 end
    if seen[v] then return 0 end
    seen[v] = true
    local n = 40
    for k, x in pairs(v) do n = n + 40 + sz(k) + sz(x) end
    return n
  end
  return sz(v)
end
function _RESIDENT(ns)
  local f = _GETUP(ns.Engine.ImportCache, "orig") or ns.Engine.ImportCache
  local out, seen = {}, {}
  for _, n in ipairs({ "zoneCache", "zonePacked", "instDiffCache", "instPacked", "summaryCache" }) do
    local t = _GETUP(f, n)
    if t then
      local cnt = 0
      for _ in pairs(t) do cnt = cnt + 1 end
      out[#out+1] = string.format("  %-14s %8.0f KB  (%d keys)", n, _SZ(t, seen) / 1024, cnt)
    end
  end
  out[#out+1] = string.format("  %-14s %8.0f KB  (extra over live caches)", "db.structCache", _SZ(ns.db.structCache, seen) / 1024)
  return table.concat(out, "\n")
end
function _OPENZONES(ns)
  local t0 = os.clock()
  local n = 0
  for _, z in ipairs(ns.Zones) do ns.Engine.ZoneData(z); n = n + 1 end
  for _, inst in ipairs(ns.Instances) do ns.Engine.InstanceDiffs(inst) end
  return n, (os.clock() - t0) * 1000
end
''')
L.eval('collectgarbage("collect")')
print("after full GC: %.0f KB" % mem())
print(L.eval("_RESIDENT")(ns))
if os.environ.get("OPENZONES"):
    n, ms = L.eval("_OPENZONES")(ns)
    print("decode every zone + instance list (as if every screen were opened): %d zones, %.1f ms" % (n, ms))
    L.eval('collectgarbage("collect")')
    print("after full GC: %.0f KB" % mem())
    print(L.eval("_RESIDENT")(ns))
