"""Equivalence: boot BASE and PROTO on the same stub DB (harness_gap STUBS, env-driven),
run both scans to completion, compare summaries, zoneCache, BestSource, ItemRows, predicates."""
import sys, os, re, random
import lupa.lua51 as lupa
HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "harness_gap.py"), encoding="utf-8").read()
STUBS = re.search(r"STUBS = r'''(.*?)'''\n", src, re.S).group(1)
BASE, PROTO = os.environ["BASE"], os.environ["PROTO"]

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
    status = L.eval('''function(ns) return (ns.Engine.scanJobs and #ns.Engine.scanJobs or 0), ns.dataReady and "ready" or "notready" end''')
    fire("ADDON_LOADED", "AttuneNext"); fire("PLAYER_LOGIN"); fire("PLAYER_ENTERING_WORLD")
    done = None
    for i in range(1, 6000):
        tick(0.016)
        n, rd = status(ns)
        if rd == "ready" and n == 0:
            done = i; break
    print(label, "scan finished at frame", done)
    return L, ns

LB, nb = boot(BASE, "BASE")
LP, np_ = boot(PROTO, "PROTO")

summ = '''function(ns)
  local out = {}
  for exp = 1, 3 do
    local s = ns.Engine.GetSummary(exp)
    for _, c in ipairs({"D","R","Q","W","V","C"}) do local n = 0 for _ in pairs(s[c]) do n = n + 1 end out[#out+1] = exp .. c .. "=" .. n end
  end
  return table.concat(out, " ")
end'''
sb, sp = LB.eval(summ)(nb), LP.eval(summ)(np_)
print("summaries identical:", sb == sp); 
if sb != sp: print(" BASE", sb, "\n PROTO", sp)

zsig = '''function(ns)
  local E = ns.Engine
  local out = {}
  for _, z in ipairs(ns.Zones) do
    local zc = E.ZoneData(z)
    local qi, vn, vl, vid = 0, 0, 0, 0
    for _, q in ipairs(zc.questList) do qi = qi + #q.items end
    for name, l in pairs(zc.vendorByName) do vn = vn + 1; vl = vl + #l end
    for _ in pairs(zc.vendorIdByName) do vid = vid + 1 end
    -- order-sensitive digests
    local qd, wd, vd = table.concat(zc.quest, ","), table.concat(zc.world, ","), table.concat(zc.vendor, ",")
    local ql = {}
    for _, q in ipairs(zc.questList) do ql[#ql+1] = q.id .. ":" .. (q.name or "") .. ":" .. table.concat(q.items, "/") end
    out[z.zone] = { #zc.quest, #zc.world, #zc.vendor, #zc.questList, qi, vn, vl, vid, qd, wd, vd, table.concat(ql, ";") }
  end
  return out
end'''
zb, zp = LB.eval(zsig)(nb), LP.eval(zsig)(np_)
diff = 0; diffdetail = []
for zone in list(zb.keys()):
    a, b = list(zb[zone].values()), list(zp[zone].values())
    if a != b:
        diff += 1
        if len(diffdetail) < 6:
            diffdetail.append((zone, a[:8], b[:8], "arrays identical" if a[8:11] == b[8:11] else "ARRAYS DIFFER", "questList identical" if a[11] == b[11] else "questList differs"))
print("zoneCache zones differing:", diff, "of", len(zb))
for d in diffdetail: print("  ", d)

# BestSource / predicates / ItemRows comparisons
random.seed(3)
ids = [random.randint(10000, 29999) for _ in range(1500)] + list(range(29900, 30000)) + [5, 99999]
cases = [("nil", "nil"), ('"Elwynn Forest"', "ns.WORLD_DROP_SRC"), ('"Zone5"', "ns.INSTANCE_DROP_SRC"), ('"Westfall"', "nil"), ('"The Deadmines"', "ns.INSTANCE_DROP_SRC"), ('""', "nil")]
def mk(zone, filt, base):
    sixth = "(type(r6)=='table' and r6.objId) or (type(r6)~='table' and r6) or 'nil'" if base else "r6 or 'nil'"
    return '''function(ns, id)
      local E = ns.Engine
      local r1, r2, r3, r4, r5, r6 = E.BestSource(id, %s, %s)
      local six = %s
      return tostring(r1) .. "|" .. tostring(r2) .. "|" .. tostring(r3) .. "|" .. tostring(r4) .. "|" .. tostring(r5) .. "|" .. tostring(six)
    end''' % (zone, filt, sixth)
tot, mism, nonnil = 0, 0, 0
examples = []
for zone, filt in cases:
    fb, fp = LB.eval(mk(zone, filt, True)), LP.eval(mk(zone, filt, False))
    for rep in range(2):
        for i in ids:
            a, b = fb(nb, i), fp(np_, i)
            tot += 1
            if not a.startswith("nil|"): nonnil += 1
            if a != b:
                mism += 1
                if len(examples) < 5: examples.append((zone, filt, i, a, b))
print("BestSource compared %d calls (%d non-nil): %d mismatches" % (tot, nonnil, mism))
for e in examples: print("  ", e)

pred = '''function(ns, id)
  local E = ns.Engine
  return tostring(E.IsQuestOnly(id)) .. "|" .. tostring(E.ItemQuestCharBlocked(id)) .. "|" .. tostring(E.IsZoneExclusive(id)) .. "|" .. tostring(E.ItemHasRareSource(id)) .. "|" .. tostring(E.ItemHasRareSource(id, "Elwynn Forest")) .. "|" .. tostring(E.IsCraftObtained(id)) .. "|" .. tostring(E.ItemIsUniqueToZone(id, "Elwynn Forest")) .. "|" .. tostring(E.ItemQuestSide(id)) .. "|" .. tostring(E.ItemBestDropChance(id))
end'''
fb, fp = LB.eval(pred), LP.eval(pred)
pm = 0; pex = []
for i in ids:
    a, b = fb(nb, i), fp(np_, i)
    if a != b:
        pm += 1
        if len(pex) < 5: pex.append((i, a, b))
print("predicates compared %d ids: %d mismatches" % (len(ids), pm))
for e in pex: print("  ", e)

rows = '''function(ns, zoneId, zname)
  local E = ns.Engine
  local z
  for _, zz in ipairs(ns.Zones) do if zz.zone == zoneId then z = zz end end
  local zc = E.ZoneData(z)
  local r = E.ItemRows(zc.world, zname, ns.WORLD_DROP_SRC)
  local out = {}
  for _, x in ipairs(r) do out[#out+1] = table.concat({x.id, x.chance, tostring(x.srcName), tostring(x.srcType), tostring(x.attuned), tostring(x.srcZone), x.tier, tostring(x.acct), x.progress}, "|") end
  local st = E.StatsWithBest(zc.world, nil, zname, ns.WORLD_DROP_SRC)
  return #r, table.concat(out, ";"), st.attuned .. "/" .. st.total .. "/" .. (st.best and (st.best.id .. ":" .. st.best.chance .. ":" .. tostring(st.best.srcName)) or "none")
end'''
fb, fp = LB.eval(rows), LP.eval(rows)
for zid, zn in ((12, "Elwynn Forest"), (40, "Westfall"), (3483, "Hellfire Peninsula")):
    a, b = fb(nb, zid, zn), fp(np_, zid, zn)
    print("ItemRows %s: BASE %d rows PROTO %d rows identical=%s; StatsWithBest BASE %s PROTO %s identical=%s" % (zn, a[0], b[0], a[1] == b[1], a[2], b[2], a[2] == b[2]))
