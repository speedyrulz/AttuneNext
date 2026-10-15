"""Load-time lens harness: per-frame timing by OnUpdate owner, pre-data-ready
work attribution, status-cache export/decode cost, GoalHud inline cost.
Reuses harness_orig.py's stubs. Env: ADDON, NITEMS, ZONEN, HEAVY, READY_AT, FRAMES.
"""
import os, sys, time
import lupa.lua51 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.environ.get("ADDON", "/home/user/AttuneNext")
FRAMES = int(os.environ.get("FRAMES", "1500"))

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
L.execute(r'''setmetatable(_G, { __index = function(t, k) return nil end })''')
mem = L.eval('function() return collectgarbage("count") end')

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
L.execute('collectgarbage("collect")')
print("after load + full GC: %.0f KB" % mem())

# ---- instrumentation: wrap named entry points, count GetSources per wrapper ----
L.execute(r'''
_LOG = {}
_GS = 0
_CUR = nil
function _WRAP_ALL(ns)
  local orig = ns.GetSources
  ns.GetSources = function(id) _GS = _GS + 1 return orig(id) end
  local function wrap(tbl, name, label)
    local f = tbl[name]
    if not f then return end
    tbl[name] = function(...)
      local prev = _CUR
      _CUR = label
      local g0, t0, m0 = _GS, os.clock(), collectgarbage("count")
      local r = { f(...) }
      local dt = (os.clock() - t0) * 1000
      _LOG[#_LOG + 1] = string.format("t=%5.2fs %-22s %7.2f ms  GetSources=%5d  alloc=%6.0f KB", GetTime(), label, dt, _GS - g0, collectgarbage("count") - m0)
      _CUR = prev
      return unpack(r)
    end
  end
  wrap(ns, "ZoneWatchNow", "ZoneWatchNow")
  wrap(ns, "GoalHudNow", "GoalHudNow")
  wrap(ns, "ExportStatusCache", "ExportStatusCache")
  wrap(ns, "SnapshotAltCan", "SnapshotAltCan(step0)")
  wrap(ns, "TrimMerchantDb", "TrimMerchantDb")
  wrap(ns, "UpdateCurrentInstance", "UpdateCurrentInstance")
  wrap(ns.Engine, "ExportCache", "Engine.ExportCache")
  wrap(ns.Engine, "ImportCache", "Engine.ImportCache")
  wrap(ns.Engine, "InvalidateAll", "Engine.InvalidateAll")
  wrap(ns.Plates, "RebuildZoneIndex", "Plates.RebuildZoneIndex")
  wrap(ns, "InitSettings", "InitSettings")
  wrap(ns.Plates, "Init", "Plates.Init")
end
''')
L.eval("_WRAP_ALL")(ns)

fire = L.eval('''function(ev, ...)
  local t0 = os.clock()
  for _, f in ipairs(_FRAMES()) do
    if f._events[ev] and f._scripts.OnEvent then
      local ok, e = pcall(f._scripts.OnEvent, f, ev, ...)
      if not ok then print("EVENT ERROR", ev, e) end
    end
  end
  return (os.clock() - t0) * 1000
end''')

# per-OnUpdate-owner timing
L.execute(r'''
_OWNER_MS = {}      -- [frameIndex] = total ms
_OWNER_MAX = {}     -- [frameIndex] = max ms in one frame
_FRAME_MS = {}      -- [frameNo] = total ms
_FRAME_TOP = {}     -- [frameNo] = index of the slowest owner that frame
function _TICK(dt, frameNo)
  _ADV(dt)
  local fr = _FRAMES()
  local total, top, topms = 0, nil, 0
  for i = 1, #fr do
    local f = fr[i]
    if f._shown and f._scripts.OnUpdate then
      local t0 = os.clock()
      local ok, e = pcall(f._scripts.OnUpdate, f, dt)
      local ms = (os.clock() - t0) * 1000
      if not ok then print("ONUPDATE ERROR", e) end
      _OWNER_MS[i] = (_OWNER_MS[i] or 0) + ms
      if ms > (_OWNER_MAX[i] or 0) then _OWNER_MAX[i] = ms end
      total = total + ms
      if ms > topms then top, topms = i, ms end
    end
  end
  _FRAME_MS[frameNo] = total
  _FRAME_TOP[frameNo] = top
end
function _OWNER_NAME(i)
  local f = _FRAMES()[i]
  if not f then return "?" end
  local n = rawget(f, "_name") or ("frame#" .. i)
  if rawget(f, "_parent") == WorldFrame then n = n .. "(parent=WorldFrame: plates driver)" end
  return n
end
''')
tick = L.eval("_TICK")
status = L.eval('''function(ns)
  local E = ns.Engine
  local tags = {}
  if E and E.scanJobs then for _, j in ipairs(E.scanJobs) do tags[#tags+1] = tostring(j.tag) end end
  return table.concat(tags, ","), ns.dataReady and "ready" or "notready"
end''')

m0 = mem()
print("ADDON_LOADED: %.2f ms" % fire("ADDON_LOADED", "AttuneNext"))
print("PLAYER_LOGIN: %.2f ms" % fire("PLAYER_LOGIN"))
print("PLAYER_ENTERING_WORLD: %.2f ms" % fire("PLAYER_ENTERING_WORLD"))
print("login events allocated %.0f KB (no GC)" % (mem() - m0))

peak = 0
done = None
ready_frame = None
checkpoints = {}
for i in range(1, FRAMES + 1):
    tick(0.016, i)
    m = mem()
    peak = max(peak, m)
    tg, rd = status(ns)
    if rd == "ready" and ready_frame is None: ready_frame = i
    if rd == "ready" and tg == "" and done is None:
        done = i
    if i in (49, 50, 51, 60):
        checkpoints[i] = m
    if i == 60:
        L.execute('collectgarbage("collect")')
        checkpoints["60gc"] = mem()
    if done and i >= done + 200:
        break
print("data ready at frame", ready_frame, "scan+warmup idle at frame", done, "peak %.0f KB" % peak)
print("mem at frames 49/50/51/60:", {k: "%.0f KB" % v for k, v in checkpoints.items()})

# frame timing summary
fm = L.eval("_FRAME_MS"); ft = L.eval("_FRAME_TOP")
rows = sorted(((k, v) for k, v in fm.items()), key=lambda x: -x[1])[:12]
oname = L.eval("_OWNER_NAME")
print("slowest frames (frameNo: total ms, slowest owner):")
for k, v in rows:
    print("   frame %4d  %7.2f ms   owner=%s" % (k, v, oname(ft[k]) if ft[k] else "-"))
om = L.eval("_OWNER_MS"); ox = L.eval("_OWNER_MAX")
print("OnUpdate owners (total ms over run / max in one frame):")
for k, v in sorted(((k, v) for k, v in om.items()), key=lambda x: -x[1])[:8]:
    print("   %-60s %8.1f ms total  %6.2f ms max" % (oname(k), v, ox[k]))
# pre-ready frames only
pre = [(k, v) for k, v in fm.items() if ready_frame and k < ready_frame]
print("frames before data-ready: %d, total OnUpdate ms %.1f, max %.2f" % (len(pre), sum(v for _, v in pre), max((v for _, v in pre), default=0)))
# plates driver: per-frame cost between ready and done
drv = [i for i in om.keys() if "plates driver" in oname(i)]
if drv:
    print("plates driver index", drv)

print("event log:")
for line in L.eval("_LOG").values():
    print("  ", line)

# ---- status cache: export size, decode cost on 'next login', scSets size ----
L.execute('collectgarbage("collect")')
r = L.eval(r'''function(ns)
  local sc = ns.db.statusCache
  if not sc then return "no statusCache" end
  local sizes = string.format("statusCache strings: tags=%d can=%d acct=%d prog=%d forge=%d bytes",
     #sc.tags, #sc.can, #sc.acct, #sc.prog, #sc.forge)
  -- simulate next login: dataReady=false, sets dropped
  ns.dataReady = false
  ns.InvalidateStatusCacheSets()
  collectgarbage("collect")
  local m0 = collectgarbage("count")
  local t0 = os.clock()
  local v = ns.IsAttunableAtAll(10001)   -- first call decodes all five
  local dt = (os.clock() - t0) * 1000
  local m1 = collectgarbage("count")
  collectgarbage("collect")
  local m2 = collectgarbage("count")
  -- 1000 further lookups
  local t1 = os.clock()
  for i = 1, 1000 do ns.IsAttunableAtAll(10000 + i) end
  local dl = (os.clock() - t1) * 1000
  ns.dataReady = true
  ns.InvalidateStatusCacheSets()
  return sizes .. string.format("\nSC() first-call decode: %.1f ms, transient alloc %.0f KB, scSets retained %.0f KB; 1000 lookups after: %.2f ms", dt, m1 - m0, m2 - m0, dl)
end''')(ns)
print(r)

# ---- GoalHud inline cost with one content goal, caches cold ----
r = L.eval(r'''function(ns)
  ns.db.goals = { { kind = "content", exp = 3, content = "D" } }
  ns.db.goalHud = true
  ns.Engine.InvalidateStats()
  ns.Engine.FlushSources()
  collectgarbage("collect")
  local g0 = _GS
  local t0 = os.clock()
  ns.GoalHudNow()
  local dt = (os.clock() - t0) * 1000
  local t1 = os.clock()
  ns.GoalHudNow()
  local dt2 = (os.clock() - t1) * 1000
  return string.format("GoalHudNow, 1 content goal (WotLK dungeons), cold caches: %.1f ms, GetSources=%d; warm repeat: %.1f ms", dt, _GS - g0, dt2)
end''')(ns)
print(r)
r = L.eval(r'''function(ns)
  ns.db.goals = { { kind = "inst", map = 576, diff = "N" } }   -- The Nexus
  ns.Engine.InvalidateStats()
  ns.Engine.FlushSources()
  collectgarbage("collect")
  local g0 = _GS
  local t0 = os.clock()
  ns.GoalHudNow()
  return string.format("GoalHudNow, 1 instance goal (map 576 N), cold: %.1f ms, GetSources=%d", (os.clock() - t0) * 1000, _GS - g0)
end''')(ns)
print(r)

# ---- comparison: same cold-render probe on the fresh-scan path (after warmup) ----
r = L.eval(r'''function(ns)
  local E = ns.Engine
  E.InvalidateStats(); E.FlushSources(); collectgarbage("collect")
  local sum = E.GetSummary(3)
  local g0, t0 = _GS, os.clock()
  local r = E.UnionStats(E.AllContentSets(sum), "probe")
  return string.format("fresh-scan path, cachesWarm=%s: first expansion-overview stats (WotLK): %.1f ms, GetSources=%d, total=%d", tostring(E.CachesWarm()), (os.clock()-t0)*1000, _GS-g0, r.total)
end''')(ns)
print(r)
