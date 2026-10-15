"""Micro-benchmark + equivalence check for the streaming Engine.BestSource prototype.
Boots two addon copies (BASE, PROTO) in separate Lua runtimes with the SAME stub DB
(the STUBS block is lifted verbatim from harness_orig.py), runs each scan to completion,
then times StatsWithBest / ItemRows cold, measures allocation, and compares BestSource
results on sampled item ids."""
import sys, os, re, time, random
import lupa.lua51 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "harness_orig.py"), encoding="utf-8").read()
STUBS = re.search(r"STUBS = r'''(.*?)'''\n", src, re.S).group(1)

os.environ.setdefault("NITEMS", "20000"); os.environ.setdefault("ZONEN", "600")
os.environ.setdefault("HEAVY", "200"); os.environ.setdefault("READY_AT", "5")
BASE = os.environ["BASE"]; PROTO = os.environ["PROTO"]
REPS = int(os.environ.get("REPS", "5"))
NSAMPLE = int(os.environ.get("NSAMPLE", "2000"))

def boot(path, label):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(STUBS)
    L.execute(r'''setmetatable(_G, { __index = function(t, k) return nil end })''')
    loader = L.eval("""function(src, name, aname, ns)
      local fn, err = loadstring(src, "@" .. aname .. "/" .. name)
      if not fn then return false, err end
      local ok, e = pcall(fn, aname, ns)
      return ok, e
    end""")
    ns = L.table()
    toc = open(os.path.join(path, "AttuneNext.toc"), encoding="utf-8-sig").read().splitlines()
    for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
        ok, err = loader(open(os.path.join(path, f), encoding="utf-8").read(), f, "AttuneNext", ns)
        if not ok: print("LOAD ERROR", label, f, err)
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
      return (E.scanJobs and #E.scanJobs or 0), ns.dataReady and "ready" or "notready"
    end''')
    fire("ADDON_LOADED", "AttuneNext"); fire("PLAYER_LOGIN"); fire("PLAYER_ENTERING_WORLD")
    done = None
    for i in range(1, 3000):
        tick(0.016)
        nj, rd = status(ns)
        if rd == "ready" and nj == 0:
            done = i; break
    L.eval('collectgarbage("collect")')
    print("%s: scan finished at frame %s, lua %.0f KB after full GC" % (label, done, L.eval('collectgarbage("count")')))
    return L, ns

LB, nsB = boot(BASE, "BASE")
LP, nsP = boot(PROTO, "PROTO")

BENCH = r'''
function(ns, ids, zoneName, srcFilter, what, reps, warm)
  local E = ns.Engine
  local times, allocs = {}, {}
  for r = 1, reps do
    if not warm then
      E.InvalidateStats()      -- statsCache / clearChance / best-source memo
      E.FlushSources()         -- raw source working set
      collectgarbage("collect")
    end
    collectgarbage("stop")
    local m0 = collectgarbage("count")
    local t0 = os.clock()
    local out
    if what == "stats" then out = E.StatsWithBest(ids, nil, zoneName, srcFilter)
    else out = E.ItemRows(ids, zoneName, srcFilter) end
    local t1 = os.clock()
    local m1 = collectgarbage("count")
    collectgarbage("restart")
    times[r] = (t1 - t0) * 1000
    allocs[r] = m1 - m0
  end
  local st, sa = 0, 0
  for r = 1, reps do st = st + times[r]; sa = sa + allocs[r] end
  return st / reps, sa / reps, table.concat(times, ",")
end
'''
benchB, benchP = LB.eval(BENCH), LP.eval(BENCH)

MKLIST = r'''
function(ns, kind, zoneId, n)
  if kind == "zone" then return ns.ItemsInZone(zoneId) end
  local t = {}
  if kind == "heavy" then for i = 0, n - 1 do t[#t+1] = 10000 + i * 10 end       -- every id%10==0: HEAVY rows
  elseif kind == "light" then for i = 0, n - 1 do t[#t+1] = 10001 + (i * 10) % 19990 end end
  return t
end
'''
mkB, mkP = LB.eval(MKLIST), LP.eval(MKLIST)
zoneId = int(LB.eval('function(ns) return ns.Zones[1].zone end')(nsB))
zoneNm = LB.eval('function(ns) return ns.Zones[1].name end')(nsB)
print("zone used: id=%d name=%s, items=%d" % (zoneId, zoneNm, len(mkB(nsB, "zone", zoneId, 0))))

def run(label, kind, n, zone, filt):
    lb = mkB(nsB, kind, zoneId, n); lp = mkP(nsP, kind, zoneId, n)
    fB = LB.eval('function(ns, f) return f and ns[f] or nil end')(nsB, filt)
    fP = LP.eval('function(ns, f) return f and ns[f] or nil end')(nsP, filt)
    for what in ("stats", "rows"):
        tb, ab, rb = benchB(nsB, lb, zone, fB, what, REPS, False)
        tp, ap, rp = benchP(nsP, lp, zone, fP, what, REPS, False)
        tw, aw, rw = benchP(nsP, lp, zone, fP, what, REPS, True)
        print("%-44s %-5s cold BASE %7.2f ms (%s) alloc %7.0f KB | cold PROTO %7.2f ms (%s) alloc %6.0f KB | warm PROTO %6.2f ms alloc %5.0f KB"
              % (label, what, tb, rb, ab, tp, rp, ap, tw, aw))

print("\n== timing (ms per call, %d reps averaged; raw per-rep in parens) ==" % REPS)
run("(1) zone list, zone=nil, filter=nil", "zone", 0, None, None)
run("(1) zone list, zone='Zone5', WORLD_DROP_SRC", "zone", 0, "Zone5", "WORLD_DROP_SRC")
run("(1) zone list, zone=zone name (no row match)", "zone", 0, zoneNm, None)
run("(2) 600 heavy items, zone=nil, filter=nil", "heavy", 600, None, None)
run("(2) 600 heavy items, zone='Zone5', INSTANCE_DROP_SRC", "heavy", 600, "Zone5", "INSTANCE_DROP_SRC")
run("(2b) 600 light items, zone=nil, filter=nil", "light", 600, None, None)

# (3) memory delta for ONE StatsWithBest call (no collection in between)
ONE = r'''
function(ns, ids, zoneName, srcFilter)
  local E = ns.Engine
  E.InvalidateStats(); E.FlushSources(); collectgarbage("collect")
  local m0 = collectgarbage("count")
  E.StatsWithBest(ids, nil, zoneName, srcFilter)
  local m1 = collectgarbage("count")
  collectgarbage("collect")
  local m2 = collectgarbage("count")
  return m1 - m0, m2 - m0
end
'''
oneB, oneP = LB.eval(ONE), LP.eval(ONE)
print("\n== (3) collectgarbage('count') delta across ONE StatsWithBest call (no collect in between; then retained after a full collect) ==")
for label, kind, n in (("zone list", "zone", 0), ("600 heavy items", "heavy", 600)):
    lb = mkB(nsB, kind, zoneId, n); lp = mkP(nsP, kind, zoneId, n)
    db, rb = oneB(nsB, lb, None, None); dp, rp = oneP(nsP, lp, None, None)
    print("%-18s BASE delta %8.0f KB (retained %6.0f KB) | PROTO delta %7.0f KB (retained %5.0f KB)" % (label, db, rb, dp, rp))

# equivalence: first 5 returns + objId of old vs new BestSource on sampled ids
GET = r'''
function(ns, id, zoneName, filt)
  local f = filt and ns[filt] or nil
  local c, n, t, r, z, s = ns.Engine.BestSource(id, zoneName, f)
  local oid = (type(s) == "table") and s.objId or s
  return tostring(c), tostring(n), tostring(t), tostring(r), tostring(z), tostring(oid)
end
'''
getB, getP = LB.eval(GET), LP.eval(GET)
random.seed(1)
ids = random.sample(range(10000, 30000), NSAMPLE - 50) + random.sample(range(1, 10000), 25) + random.sample(range(30000, 40000), 25)
cases = [(None, None), ("Zone5", None), (None, "WORLD_DROP_SRC"), ("Zone17", "INSTANCE_DROP_SRC"), ("Elwynn Forest", None), ("", None)]
print("\n== equivalence on %d sampled ids x %d (zone, filter) cases ==" % (len(ids), len(cases)))
LP.eval('function(ns) ns.Engine.InvalidateStats(); ns.Engine.FlushSources() end')(nsP)
LB.eval('function(ns) ns.Engine.InvalidateStats(); ns.Engine.FlushSources() end')(nsB)
tot = bad = nonnil = restricted = blockedWins = 0
for zone, filt in cases:
    for id in ids:
        for pas in (1, 2):   # second pass hits the prototype memo
            b = getB(nsB, id, zone, filt); p = getP(nsP, id, zone, filt)
            tot += 1
            if b != p:
                bad += 1
                if bad <= 10: print("MISMATCH id=%d zone=%r filt=%r pass=%d base=%r proto=%r" % (id, zone, filt, pas, b, p))
            if pas == 1 and b[0] != "nil": nonnil += 1
            if pas == 1 and b[3] == "true": restricted += 1
print("compared %d calls: %d mismatches; %d non-nil results, %d zone-restricted results" % (tot, bad, nonnil, restricted))
# also compare whole ItemRows output + StatsWithBest best pick on the zone list and the heavy list
ROWS = r'''
function(ns, ids, zoneName, filt)
  local f = filt and ns[filt] or nil
  ns.Engine.InvalidateStats(); ns.Engine.FlushSources()
  local rows = ns.Engine.ItemRows(ids, zoneName, f)
  local parts = {}
  for i, r in ipairs(rows) do parts[i] = table.concat({r.id, r.chance, tostring(r.srcName), tostring(r.srcType), tostring(r.attuned), tostring(r.srcZone), r.tier, tostring(r.acct), tostring(r.progress)}, ":") end
  local st = ns.Engine.StatsWithBest(ids, nil, zoneName, f)
  local b = st.best
  return #rows, table.concat(parts, ";"), st.attuned .. "/" .. st.total .. "/" .. (b and (b.id .. ":" .. b.chance .. ":" .. tostring(b.srcName)) or "none")
end
'''
rowsB, rowsP = LB.eval(ROWS), LP.eval(ROWS)
for label, kind, n, zone, filt in (("zone list", "zone", 0, None, None), ("zone list Zone5/WORLD", "zone", 0, "Zone5", "WORLD_DROP_SRC"), ("heavy 600", "heavy", 600, "Zone17", "INSTANCE_DROP_SRC"), ("light 600", "light", 600, None, None)):
    nb, sb, stb = rowsB(nsB, mkB(nsB, kind, zoneId, n), zone, filt)
    np_, sp, stp = rowsP(nsP, mkP(nsP, kind, zoneId, n), zone, filt)
    print("ItemRows %-22s BASE %d rows, PROTO %d rows, identical=%s | StatsWithBest BASE %s PROTO %s identical=%s" % (label, nb, np_, sb == sp, stb, stp, stb == stp))
print("\nPerfStats PROTO:", dict(LP.eval('function(ns) return ns.Engine.PerfStats() end')(nsP)))
