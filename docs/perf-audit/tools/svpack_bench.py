"""SavedVariables packing bench for AttuneNext (svpack prototype).

Runs the addon headless (same stubs as harness_orig.py) until the login scan
finishes, then:
  * times Engine.ExportCache as the pump calls it at scan end
  * measures the resident size of the structural caches and of ANx.db.structCache
  * serializes ANx.db.structCache in Blizzard's SavedVariables format, reports KB
  * parses that text in a FRESH Lua runtime: compile ms, exec ms, resident KB
  * re-imports the parsed copy through Engine.ImportCache (provisional +
    validated, as at login), times it, times decoding every zone / instance
  * compares every decoded zone / instance list / summary set with the live
    tables the scan built (equivalence)
Env: ADDON, NITEMS, ZONEN, HEAVY, READY_AT, MAXFRAMES, OUT (serialized file).
"""
import os, re, sys, time
import lupa.lua51 as lupa

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.environ["ADDON"]
MAXFRAMES = int(os.environ.get("MAXFRAMES", "3000"))
OUT = os.environ.get("OUT", os.path.join(HERE, "svpack_sv.lua"))

# reuse the stub environment of the original harness verbatim
hsrc = open(os.path.join(HERE, "harness_orig.py"), encoding="utf-8").read()
STUBS = hsrc[hsrc.index("STUBS = r'''") + len("STUBS = r'''"):]
STUBS = STUBS[:STUBS.index("'''")]

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
toc = open(os.path.join(ADDON, "AttuneNext.toc"), encoding="utf-8-sig").read().splitlines()
for f in [l.strip() for l in toc if l.strip().endswith(".lua")]:
    ok, err = loader(open(os.path.join(ADDON, f), encoding="utf-8").read(), f, "AttuneNext", ns)
    if not ok: print("LOAD ERROR", f, err)

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
_EXPORT_MS, _EXPORT_N, _OLD = 0, 0, {}
-- find a module-level cache table by its upvalue name, through any Engine
-- function (two levels: Engine.fn -> local helper -> table)
function _FINDUP(ns, name)
  for _, f in pairs(ns.Engine) do
    if type(f) == "function" then
      local i = 1
      while true do
        local n, v = debug.getupvalue(f, i)
        if not n then break end
        if n == name and type(v) == "table" then return v end
        if type(v) == "function" then
          local j = 1
          while true do
            local n2, v2 = debug.getupvalue(v, j)
            if not n2 then break end
            if n2 == name and type(v2) == "table" then return v2 end
            j = j + 1
          end
        end
        i = i + 1
      end
    end
  end
  return nil
end
function _CAPTURE(ns)
  _OLD.zoneCache = _OLD.zoneCache or _FINDUP(ns, "zoneCache")
  _OLD.instDiffCache = _OLD.instDiffCache or _FINDUP(ns, "instDiffCache")
  _OLD.summaryCache = _OLD.summaryCache or _FINDUP(ns, "summaryCache")
end
function _WRAP(ns)
  local E = ns.Engine
  local orig = E.ExportCache
  _ORIG_EXPORT = orig
  _NS = ns
  E.ExportCache = function(...)
    -- keep the live tables the scan built (the release variant drops zoneCache)
    _CAPTURE(ns)
    local t0 = os.clock()
    orig(...)
    _EXPORT_MS = _EXPORT_MS + (os.clock() - t0) * 1000
    _EXPORT_N = _EXPORT_N + 1
  end
end
''')
L.eval("_WRAP")(ns)

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
  local front = E.scanJobs[1]
  return #E.scanJobs, ns.dataReady and "ready" or "notready", front and tostring(front.tag) or ""
end''')
mem = L.eval('function() return collectgarbage("count") end')

fire("ADDON_LOADED", "AttuneNext")
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
done = None
exp_frames, exp_ms, exp_max = 0, 0.0, 0.0
for i in range(1, MAXFRAMES + 1):
    nj0, rd0, front = status(ns)
    if front == "export": L.eval("_CAPTURE")(ns)
    t0 = time.perf_counter()
    tick(0.016)
    dt = (time.perf_counter() - t0) * 1000
    if front == "export":
        exp_frames += 1; exp_ms += dt; exp_max = max(exp_max, dt)
    nj, rd, _ = status(ns)
    if rd == "ready" and nj == 0:
        done = i
        break
print("scan finished at frame", done)
print("export job frames: %d, total tick time %.1f ms, max single frame %.1f ms" % (exp_frames, exp_ms, exp_max))
for _ in range(5): tick(0.016)   # settle
print("ExportCache calls at scan end: %d, total %.1f ms" % (L.eval("_EXPORT_N"), L.eval("_EXPORT_MS")))

# ---------- resident sizes (same accounting as the harness PROFILE sz) ----------
L.execute(r'''
function _SZ(v, seen)
  seen = seen or {}
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
  local E = ns.Engine
  local names = { "zoneCache", "zonePacked", "instDiffCache", "instPacked", "summaryCache" }
  local out, seen = {}, {}
  for _, n in ipairs(names) do
    local t = _FINDUP(ns, n)
    if t then
      local cnt = 0
      for _ in pairs(t) do cnt = cnt + 1 end
      out[#out+1] = string.format("%-14s %8.0f KB  (%d keys)", n, _SZ(t, seen) / 1024, cnt)
    end
  end
  -- db.structCache beyond what the live caches already hold (aliases cost 0)
  local extra = _SZ(ns.db.structCache, seen)
  out[#out+1] = string.format("%-14s %8.0f KB  (extra over live caches)", "db.structCache", extra / 1024)
  out[#out+1] = string.format("%-14s %8.0f KB  (standalone)", "db.structCache", _SZ(ns.db.structCache, {}) / 1024)
  return table.concat(out, "\n")
end
''')
L.eval('collectgarbage("collect")')
print("after full GC: %.0f KB" % mem())
print(L.eval("_RESIDENT")(ns))

# ---------- Blizzard-style SavedVariables serializer ----------
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
      if type(v) == "table" then
        write(v, indent + 1)
        n = n + 1; buf[n] = ", -- [" .. i .. "]\n"
      else
        n = n + 1; buf[n] = val(v) .. ", -- [" .. i .. "]\n"
      end
    end
    for k, v in pairs(t) do
      if not (type(k) == "number" and k >= 1 and k <= cnt and k == math.floor(k)) then
        n = n + 1; buf[n] = pad .. key(k) .. " = "
        if type(v) == "table" then
          write(v, indent + 1)
          n = n + 1; buf[n] = ",\n"
        else
          n = n + 1; buf[n] = val(v) .. ",\n"
        end
      end
    end
    n = n + 1; buf[n] = string.rep("\t", indent) .. "}"
  end
  n = n + 1; buf[n] = name .. " = "
  write(t, 0)
  n = n + 1; buf[n] = "\n"
  return table.concat(buf)
end
''')
t0 = time.time()
text = L.eval("_SERIALIZE")("_SVTEST", L.eval("function(ns) return { structCache = ns.db.structCache } end")(ns))
ser_ms = (time.time() - t0) * 1000
with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(text)
size = os.path.getsize(OUT)
lines = text.count("\n")
print("serialized structCache: %d bytes = %.0f KB, %d lines (serializer %.0f ms)" % (size, size / 1024, lines, ser_ms))
del text

# ---------- parse in a FRESH runtime (what the client does at login) ----------
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
src = open(OUT, encoding="utf-8").read()
parse = L2.eval(r'''function(src)
  _SRC = src
  _SVTEST = nil
  collectgarbage("collect")
  local m0 = collectgarbage("count")
  local t0 = os.clock()
  local f, err = loadstring(_SRC, "=sv")
  if not f then return nil, err end
  local t1 = os.clock()
  f()
  local t2 = os.clock()
  f = nil
  collectgarbage("collect")
  local m1 = collectgarbage("count")
  return (t1 - t0) * 1000, (t2 - t1) * 1000, m1 - m0
end''')
best = None
for rep_ in range(3):
    r = parse(src)
    if r[0] is None: print("PARSE ERROR", r[1]); sys.exit(1)
    best = r if best is None else tuple(min(a, b) for a, b in zip(best, r))
    print("parse run %d: compile %.1f ms, exec %.1f ms, parsed table resident %.0f KB" % (rep_ + 1, r[0], r[1], r[2]))
print("PARSE best: compile %.1f ms, exec %.1f ms, resident %.0f KB" % best)
del L2

# ---------- re-import through the addon in the scan runtime + equivalence ----------
L.execute(r'''
function _REIMPORT(ns, src)
  local E = ns.Engine
  local f = assert(loadstring(src, "=sv"))
  f()
  src = nil
  ns.db.structCache = _SVTEST.structCache
  _SVTEST = nil
  E.InvalidateAll()
  local t0 = os.clock()
  local ok1 = E.ImportCache(true)
  local t1 = os.clock()
  local ok2 = E.ImportCache()
  local t2 = os.clock()
  local nz = 0
  for _, z in ipairs(ns.Zones) do E.ZoneData(z); nz = nz + 1 end
  local t3 = os.clock()
  local ni = 0
  for _, inst in ipairs(ns.Instances) do E.InstanceDiffs(inst); ni = ni + 1 end
  local t4 = os.clock()
  return tostring(ok1) .. "/" .. tostring(ok2), (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, nz, (t4 - t3) * 1000, ni
end
function _COMPARE(ns)
  local E = ns.Engine
  local old = _OLD
  local checked, bad = 0, {}
  local function fail(msg) if #bad < 25 then bad[#bad + 1] = msg end end
  local function cmpArr(a, b, label)
    if type(b) ~= "table" then fail(label .. " missing") return end
    if #a ~= #b then fail(label .. " len " .. #a .. " vs " .. #b) return end
    for i = 1, #a do
      checked = checked + 1
      if a[i] ~= b[i] then fail(label .. "[" .. i .. "] " .. tostring(a[i]) .. " vs " .. tostring(b[i])) return end
    end
  end
  local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
  local function cmpSet(a, b, label)
    if type(b) ~= "table" then fail(label .. " missing") return end
    for k in pairs(a) do checked = checked + 1; if b[k] ~= true then fail(label .. " missing id " .. tostring(k)) return end end
    if count(a) ~= count(b) then fail(label .. " size " .. count(a) .. " vs " .. count(b)) end
  end
  -- zones: every zone the scan built, through the public accessor
  local zonesOld, zonesCmp, quests, vendors = count(old.zoneCache), 0, 0, 0
  local seen = {}
  for _, z in ipairs(ns.Zones) do
    local o = old.zoneCache[z.zone]
    if o and not seen[z.zone] then
      seen[z.zone] = true
      zonesCmp = zonesCmp + 1
      local n = E.ZoneData(z)
      local lb = "zone" .. z.zone
      cmpArr(o.quest, n.quest, lb .. ".quest")
      cmpArr(o.world, n.world, lb .. ".world")
      cmpArr(o.vendor, n.vendor, lb .. ".vendor")
      if #o.questList ~= #n.questList then fail(lb .. ".questList len " .. #o.questList .. " vs " .. #n.questList)
      else
        for i, q in ipairs(o.questList) do
          local nq = n.questList[i]
          quests = quests + 1
          checked = checked + 2
          if q.id ~= nq.id then fail(lb .. ".questList[" .. i .. "].id " .. tostring(q.id) .. " vs " .. tostring(nq.id)) end
          if (q.name or "") ~= (nq.name or "") then fail(lb .. ".questList[" .. i .. "].name " .. tostring(q.name) .. " vs " .. tostring(nq.name)) end
          cmpArr(q.items, nq.items, lb .. ".questList[" .. i .. "].items")
        end
      end
      for name, list in pairs(o.vendorByName) do
        vendors = vendors + 1
        cmpArr(list, n.vendorByName[name], lb .. ".vendorByName[" .. name .. "]")
      end
      if count(o.vendorByName) ~= count(n.vendorByName) then fail(lb .. ".vendorByName count") end
      for name, id in pairs(o.vendorIdByName or {}) do
        checked = checked + 1
        if (n.vendorIdByName or {})[name] ~= id then fail(lb .. ".vendorIdByName[" .. name .. "]") end
      end
      if count(o.vendorIdByName or {}) ~= count(n.vendorIdByName or {}) then fail(lb .. ".vendorIdByName count") end
    end
  end
  -- instances: force every list through InstanceDiffs, then compare the cache
  for _, inst in ipairs(ns.Instances) do E.InstanceDiffs(inst) end
  local newInst = _FINDUP(ns, "instDiffCache")
  local instCmp = 0
  for key, items in pairs(old.instDiffCache) do
    instCmp = instCmp + 1
    cmpArr(items, newInst[key], "inst[" .. key .. "]")
  end
  if count(old.instDiffCache) ~= count(newInst) then fail("inst key count " .. count(old.instDiffCache) .. " vs " .. count(newInst)) end
  -- summaries
  local newSum = _FINDUP(ns, "summaryCache")
  local sets = 0
  for exp, s in pairs(old.summaryCache) do
    local n = newSum[exp]
    if not n then fail("summary " .. exp .. " missing") else
      for _, cat in ipairs({ "D", "R", "Q", "W", "V", "C" }) do sets = sets + 1; cmpSet(s[cat], n[cat], "sum" .. exp .. "." .. cat) end
      for label, set in pairs(s.Dl or {}) do sets = sets + 1; cmpSet(set, (n.Dl or {})[label], "sum" .. exp .. ".Dl[" .. label .. "]") end
      for label, set in pairs(s.Rl or {}) do sets = sets + 1; cmpSet(set, (n.Rl or {})[label], "sum" .. exp .. ".Rl[" .. label .. "]") end
      if count(s.Dl or {}) ~= count(n.Dl or {}) or count(s.Rl or {}) ~= count(n.Rl or {}) then fail("sum" .. exp .. " label count") end
      if n.ready ~= true then fail("sum" .. exp .. " not ready") end
    end
  end
  return string.format("zones %d/%d compared, %d quest entries, %d vendor lists, %d instance lists, %d summary sets, %d values checked, %d mismatches",
    zonesCmp, zonesOld, quests, vendors, instCmp, sets, checked, #bad), table.concat(bad, "\n")
end
''')
r = L.eval("_REIMPORT")(ns, src)
print("ImportCache ok=%s: provisional %.1f ms, validated %.1f ms; ZoneData for all %d zones %.1f ms; InstanceDiffs for all %d instances %.1f ms" % (r[0], r[1], r[2], r[4], r[3], r[6], r[5]))
summary, bad = L.eval("_COMPARE")(ns)
print("EQUIVALENCE:", summary)
if bad: print(bad)
