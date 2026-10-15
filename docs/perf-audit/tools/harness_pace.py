"""Pacing harness: harness_gap.py + frame-time emulation.

Extra env:
  FPS      nominal game frame rate (frame base cost = 1000/FPS ms)    [60]
  SLOW     CPU slowdown factor: the pump's clock runs SLOW x faster,  [1]
           so it gets 10/SLOW ms of real work per frame; reported addon
           ms are real ms x SLOW
  BASE_MS  override the game-only frame cost in ms                    [1000/FPS]
  LOGOUT   fire PLAYER_LOGOUT at the end and time it                  [1]
Per frame the emulated frame time is BASE_MS + addon_ms*SLOW; that value is
passed as `elapsed` to every OnUpdate (like the real client) and advances
GetTime().
"""
import sys, os, re, time
import lupa.lua51 as lupa

ADDON = os.environ.get("ADDON", "/home/user/AttuneNext")
FRAMES = int(os.environ.get("FRAMES", "3000"))
SKIP = set(os.environ.get("SKIP", "").split(",")) - {""}
FPS = float(os.environ.get("FPS", "60"))
SLOW = float(os.environ.get("SLOW", "1"))
BASE_MS = float(os.environ.get("BASE_MS", str(1000.0 / FPS)))
LOGOUT = os.environ.get("LOGOUT", "1") == "1"

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()

STUBS = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "gap", "harness_gap.py")).read()
STUBS = STUBS.split("STUBS = r'''", 1)[1].split("'''\nL.execute(STUBS)", 1)[0]
# clock scaling for the SLOW emulation
STUBS = STUBS.replace("function debugprofilestop() return (os.clock() - t0) * 1000 end",
                      "local SLOWF = %r\nfunction debugprofilestop() return (os.clock() - t0) * 1000 * SLOWF end" % SLOW)
L.execute(STUBS)
if os.environ.get("PACE"):
    # e.g. PACE="share=0.35,min=3,max=10,gc=0.3" -> _G.ANX_PACE read by the patched pump
    kv = ", ".join("%s = %s" % tuple(p.split("=")) for p in os.environ["PACE"].split(","))
    L.execute("ANX_PACE = { %s }" % kv)
    print("ANX_PACE:", kv)
L.execute(r'''
_MISSING = {}
setmetatable(_G, { __index = function(t, k) _MISSING[k] = (_MISSING[k] or 0) + 1 return nil end })
-- count + time collector steps (the pump calls the global by name)
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
        if f in SKIP: continue
        ok, err = loader(open(os.path.join(path, f), encoding="utf-8").read(), f, aname, ns_)
        if not ok: print("LOAD ERROR", aname, f, err)
    nss.append((aname, ns_))
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
  if E and E.scanJobs then for _, j in ipairs(E.scanJobs) do tags[#tags+1] = tostring(j.tag) end end
  return table.concat(tags, ","), ns.dataReady and "ready" or "notready"
end''')
# time the inline exports (called through the ANx / Engine tables, so a wrapper is seen)
L.execute('_TIMES = {}')
wrapt = L.eval(r'''function(ns, aname)
  local function wrap(tbl, key, label)
    local orig = tbl[key]
    if not orig then return end
    tbl[key] = function(...)
      local t = os.clock()
      local a, b, c = orig(...)
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
  local orig = ns.GetSources
  ns._GSN = 0
  ns.GetSources = function(id) ns._GSN = ns._GSN + 1 return orig(id) end
end''')
for an, n_ in nss: wrapt(n_, an)

for an, _ in nss: fire("ADDON_LOADED", an)
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
print("after login events: %.0f KB" % mem())

peak = 0
t0 = time.time()
elapsed = BASE_MS / 1000.0
wall_ms = 0.0
ready_frame = None
done_frame = None
scan_addon = []      # emulated addon ms per frame during the scan window
scan_frame = []      # emulated frame ms during the scan window
worst = (0, 0)
gc_prev = (0, 0.0)
scan_gc_ms = 0.0
for i in range(1, FRAMES + 1):
    _t = time.perf_counter(); tick(elapsed); real_ms = (time.perf_counter() - _t) * 1000
    addon_ms = real_ms * SLOW
    frame_ms = BASE_MS + addon_ms
    wall_ms += frame_ms
    elapsed = frame_ms / 1000.0
    m = mem()
    peak = max(peak, m)
    rd_all = all(status(n_)[1] == "ready" for _, n_ in nss)
    tags_all = ",".join(status(n_)[0] for _, n_ in nss)
    if rd_all and ready_frame is None:
        ready_frame = i
    if ready_frame is not None and done_frame is None:
        scan_addon.append(addon_ms); scan_frame.append(frame_ms)
        gcn, gcms = L.eval('_GCN'), L.eval('_GCMS')
        scan_gc_ms += (gcms - gc_prev[1]) * SLOW
        gc_prev = (gcn, gcms)
        if tags_all.replace(",", "") == "":
            done_frame = i
            print("scan finished at frame %d (ready at %d): %d scan frames, emulated wall %.1f s" % (i, ready_frame, i - ready_frame, sum(scan_frame) / 1000))
    if addon_ms > worst[1]: worst = (i, addon_ms)
    if i % (FRAMES // 15 or 1) == 0:
        print("frame %5d  lua %8.0f KB  %s  jobs=[%s]" % (i, m, "ready" if rd_all else "notready", tags_all[:80]))
    if m > 1500000:
        print("RUNAWAY at frame", i, "%.0f KB" % m); break
print("peak %.0f KB, real %.1fs" % (peak, time.time() - t0))
if done_frame:
    n = len(scan_addon)
    busy = [(a, f) for a, f in zip(scan_addon, scan_frame) if a > 0.5]
    print("SCAN WINDOW fps=%g slow=%g base=%.1fms: %d frames, emulated wall %.1f s, addon ms/frame avg %.1f (busy frames %.1f), frame share avg %.0f%% (busy %.0f%%), mean emulated fps during scan %.1f, GC step ms total %.0f (%.1f/frame)" % (
        FPS, SLOW, BASE_MS, n, sum(scan_frame) / 1000, sum(scan_addon) / n,
        (sum(a for a, _ in busy) / max(1, len(busy))),
        100 * sum(scan_addon) / sum(scan_frame),
        100 * sum(a for a, _ in busy) / max(1, sum(f for _, f in busy)),
        1000 * n / sum(scan_frame), scan_gc_ms, scan_gc_ms / n))
print("worst frame %d: %.1f ms (emulated)" % worst)
tm = L.eval('_TIMES')
for k in sorted(tm.keys()):
    e = tm[k]
    print("  %-40s n=%3d total %7.1f ms  max %7.1f ms (real; x%g emulated)" % (k, e.n, e.ms, e.max, SLOW))
for an, n_ in nss:
    print("  %s GetSources calls: %d" % (an, n_._GSN))
miss = L.eval('_MISSING')
print("missing globals read:", sorted(((k, v) for k, v in miss.items()), key=lambda x: -x[1])[:12])
if LOGOUT:
    _t = time.perf_counter(); fire("PLAYER_LOGOUT"); lo = (time.perf_counter() - _t) * 1000
    print("PLAYER_LOGOUT handlers: %.1f ms real (%.1f emulated)" % (lo, lo * SLOW))
    tm = L.eval('_TIMES')
    for k in sorted(tm.keys()):
        e = tm[k]
        print("  %-40s n=%3d total %7.1f ms  max %7.1f ms" % (k, e.n, e.ms, e.max))

if os.environ.get("PROFILE"):
    prof = L.eval(r'''function(ns)
  local seen = {}
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
  seen[ns] = true; seen[ns.Engine] = true
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
  local out = {}
  for name, t in pairs(upv) do out[#out+1] = { "Engine." .. name, sz(t) } end
  for k, v in pairs(ns) do if type(v) == "table" then out[#out+1] = { "ANx." .. tostring(k), sz(v) } end end
  table.sort(out, function(a, b) return a[2] > b[2] end)
  local lines = {}
  for i = 1, 8 do if out[i] then lines[#lines+1] = string.format("%10.0f KB  %s", out[i][2] / 1024, out[i][1]) end end
  return table.concat(lines, "\n")
end''')
    L.eval('collectgarbage("collect")')
    print("after full GC: %.0f KB" % mem())
    for an, n_ in nss:
        print("--", an); print(prof(n_))
    szdb = L.eval('function(name) local t = _G[name] if not t then return 0 end local seen = {} local function sz(v) if type(v)=="string" then if seen[v] then return 0 end seen[v]=true return 24+#v end if type(v)~="table" then return 0 end if seen[v] then return 0 end seen[v]=true local n=40 for k,x in pairs(v) do n=n+40+sz(k)+sz(x) end return n end return sz(t)/1024 end')
    for name in ("AttuneNextDB", "AttuneNextSimpleDB"):
        print("  %s size: %.0f KB" % (name, szdb(name)))

st = L.eval('_G.ANX_PACE_STATS')
if st:
    print("PACE STATS: pump frames %d, work %.0f ms, gc %.0f ms, overrun %.0f ms (%.2f/frame), resumes %d, max resume %.1f ms, resumes>2ms %d, skipped %d" % (
        st.frames, st.work, st.gc, st.over, st.over / max(1, st.frames), st.resumes, st.maxResume, st.slowResumes, st.skipped))
    if st.byTag:
        for tag in sorted(st.byTag.keys()):
            b = st.byTag[tag]
            print("   tag %-18s resumes %5d  total %7.0f ms  avg %.2f ms  max %.1f ms  >2ms %d" % (tag, b.n, b.ms, b.ms / max(1, b.n), b.max, b.slow))

if os.environ.get("IMPORT_TEST"):
    imp = L.eval(r'''function(ns)
      local t = os.clock(); ns.Engine.ExportCache(); local ex = (os.clock() - t) * 1000
      t = os.clock(); local ok = ns.Engine.ImportCache(true); local im = (os.clock() - t) * 1000
      t = os.clock(); local ok2 = ns.Engine.ImportCache(); local im2 = (os.clock() - t) * 1000
      -- what the status cache restore costs (SC() decode of the packed strings)
      ns.InvalidateStatusCacheSets()
      t = os.clock(); local c = ns.CanCharAttune(10001); local sc = (os.clock() - t) * 1000
      return ex, im, im2, sc
    end''')
    for an, n_ in nss:
        ex, im, im2, sc = imp(n_)
        print("%s: ExportCache %.1f ms, ImportCache(provisional) %.1f ms, ImportCache(validated) %.1f ms, status-cache decode %.1f ms" % (an, ex, im, im2, sc))

if os.environ.get("EVENT_TEST"):
    ev = L.eval(r'''function(n)
      local out = {}
      local t = os.clock()
      for i = 1, n do _G.OnCustomGameData(11, 10001 + (i % 5000), 0, 5) end
      out.ocgd_tick = (os.clock() - t) * 1000 / n
      t = os.clock()
      for i = 1, n do _G.OnCustomGameData(11, 10005 + 5 * (i % 1000), 0, 100) end   -- id%5==0 -> progress 100 (done path)
      out.ocgd_done = (os.clock() - t) * 1000 / n
      return out
    end''')
    r = ev(20000)
    print("OnCustomGameData chain: progress tick %.1f us, completion %.1f us (per call, all links)" % (r.ocgd_tick * 1000, r.ocgd_done * 1000))
    def fire_n(name, n, arg=None):
        _t = time.perf_counter()
        for _ in range(n): fire(name, arg) if arg is not None else fire(name)
        return (time.perf_counter() - _t) * 1000 / n
    for name, arg in (("PLAYER_MONEY", None), ("ZONE_CHANGED_NEW_AREA", None), ("PLAYER_LEVEL_UP", None), ("BAG_UPDATE", 0), ("UNIT_AURA", "player"), ("QUEST_LOG_UPDATE", None), ("MERCHANT_SHOW", None)):
        print("  event %-22s %.1f us per fire (all handlers)" % (name, fire_n(name, 2000, arg) * 1000))
    # run the timers those events queued
    for _ in range(200): tick(0.016)
    print("  timers drained")
