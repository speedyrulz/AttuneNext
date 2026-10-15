#!/usr/bin/env python3
"""Pack AttuneNext's quest-giver / quest-prereq / reagent data tables.

Reads the UNPACKED generated files (the v3.6.x layout:
  ANx.QuestGivers[questId] = "zone:x10:y10:name"
  ANx.QuestPre[questId]    = "minLevel:parent:mode:p1:p2..."
  ANx.Reagents[craftedId]  = { reagentId, count, ... }
  ANx.ReagentOutput[id]    = n)
and writes the packed layout read by ANx.QuestGiver / ANx.HasQuestGiver
(Core.lua), PreRow (QuestArrow.lua) and ANx.StaticReagents (Core.lua):

  ANx.QuestGiversPacked  sorted 9-char records: 4 hex questId + 5 hex 1-based
                         byte position of the giver record in QuestGiverBlob
  ANx.QuestGiverBlob     "ZZZZXXXYYY<name>\n" per distinct giver tuple
                         (4 hex zoneAreaId, 3 hex x10, 3 hex y10); the 3,151
                         distinct tuples are shared by the 7,318 quests
  ANx.QuestPrePacked     sorted 9-char records: 4 hex questId + 5 hex position
  ANx.QuestPreBlob       "<minLevel:parent:mode:p1:p2...>\n" per quest
  ANx.ReagentsPacked     sorted 10-char records: 4 hex craftedId + 5 hex
                         position + 1 hex reagent count
  ANx.ReagentBlob        6-char records of 4 hex reagentId + 2 hex count
  ANx.ReagentOutput      copied through as the original [craftedId]=n hash: only
                         125 entries (~3.5 KB), and the What's Left expander reads
                         it once per recipe, where a packed probe cost +5 ms/report

Every id is < 65,536 and every packed value < 2^24, so the decoders stay inside
the 3.3.5 client's 32-bit bit library and double-exact integer range. The
QuestNameBlobs / QuestZoneNames sections of Data_QuestGivers.lua are copied
through verbatim.

The script refuses to run on an already-packed file: keep the unpacked files
(the output of the Questie / DBC generators) as its input.

Usage:
  python pack_data.py --questgivers IN/Data_QuestGivers.lua \
                      --reagents IN/Data_Reagents.lua --out REPO_DIR
Options for measurement (the shipped defaults are --givers blob --reagents-fmt blob):
  --givers array      QuestGiverTuples as a Lua array of "ZZZZXXXYYYname" strings
                      indexed by a 3-hex palette index (7-char records)
  --reagents-fmt hash ANx.Reagents as a [craftedId]="rid:count,rid:count" hash
"""
import argparse, os, re, sys

LINE_STR = re.compile(r'^\[(\d+)\]="((?:[^"\\]|\\.)*)",$')
LINE_TBL = re.compile(r'^\[(\d+)\]=\{([\d,]*)\},$')
LINE_NUM = re.compile(r'^\[(\d+)\]=(\d+),$')


def lua_unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != '\\':
            out.append(c); i += 1; continue
        i += 1
        d = s[i]
        if d == 'n': out.append('\n')
        elif d == 't': out.append('\t')
        elif d == 'r': out.append('\r')
        elif d == 'a': out.append('\a')
        elif d == 'b': out.append('\b')
        elif d == 'f': out.append('\f')
        elif d == 'v': out.append('\v')
        elif d in '\\"\'\n': out.append(d)
        elif d.isdigit():
            j = i
            while j < len(s) and j < i + 3 and s[j].isdigit(): j += 1
            out.append(chr(int(s[i:j]))); i = j; continue
        else:
            raise ValueError("unknown escape \\" + d)
        i += 1
    return ''.join(out)


def lua_escape(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == '"': out.append('\\"')
        elif ch == '\\': out.append('\\\\')
        elif ch == '\n': out.append('\\n')
        elif o < 32 or o > 126: out.append('\\%03d' % o)
        else: out.append(ch)
    return ''.join(out)


def read_block(lines, header, parser):
    """Return (dict, start, end) for the `header` ... `}` block; every line must parse."""
    try:
        start = lines.index(header)
    except ValueError:
        sys.exit("input has no %r block - is it already packed?" % header)
    d, i = {}, start + 1
    while lines[i] != '}':
        m = parser.match(lines[i])
        if not m:
            sys.exit("cannot parse line %d: %r" % (i + 1, lines[i]))
        k = int(m.group(1))
        if k in d: sys.exit("duplicate id %d" % k)
        d[k] = m.group(2)
        i += 1
    return d, start, i


def hexw(v, w):
    assert 0 <= v < 16 ** w, (v, w)
    return '%0*X' % (w, v)


def emit_string(name, pieces, max_pieces=60):
    """ANx.<name> = "..." .. "..." with at most max_pieces operands (Lua 5.1's
    expression nesting limit is 200 levels, concat is right-associative)."""
    total = sum(len(p) for p in pieces)
    target = max(3000, -(-total // max_pieces))
    lines, cur = [], ''
    for p in pieces:
        if cur and len(cur) + len(p) > target:
            lines.append(cur); cur = ''
        cur += p
    if cur or not lines: lines.append(cur)
    assert len(lines) <= max_pieces + 1
    out = ['ANx.%s =' % name]
    for i, l in enumerate(lines):
        out.append('    %s"%s"' % ('' if i == 0 else '.. ', lua_escape(l)))
    return '\n'.join(out)


# ---------------------------------------------------------------- QuestGivers
def pack_quest_givers(qg, mode):
    tuples = {}                       # decoded tuple -> record string
    per_quest = {}
    for qid, raw in qg.items():
        s = lua_unescape(raw)
        m = re.match(r'^(\d+):(\d+):(\d+):(.*)$', s, re.S)
        if not m: sys.exit("bad QuestGivers value for %d: %r" % (qid, s))
        zone, x, y, name = int(m[1]), int(m[2]), int(m[3]), m[4]
        if '\n' in name: sys.exit("newline in giver name of quest %d" % qid)
        rec = hexw(zone, 4) + hexw(x, 3) + hexw(y, 3) + name
        tuples.setdefault(rec, None)
        per_quest[qid] = rec
    order = sorted(tuples)            # deterministic palette order
    if mode == 'blob':
        pos, blob = {}, []
        p = 1
        for rec in order:
            pos[rec] = p
            blob.append(rec + '\n')
            p += len(rec) + 1
        idx = [hexw(q, 4) + hexw(pos[per_quest[q]], 5) for q in sorted(per_quest)]
        return idx, blob, None
    else:
        pal = {rec: i + 1 for i, rec in enumerate(order)}
        idx = [hexw(q, 4) + hexw(pal[per_quest[q]], 3) for q in sorted(per_quest)]
        return idx, None, order


def decode_quest_giver_py(idx_s, blob, tuples, qid):
    """Reference decoder (mirrors ANx.QuestGiver) for the self-check."""
    rw = 9 if blob is not None else 7
    lo, hi = 0, len(idx_s) // rw - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        p = mid * rw
        v = int(idx_s[p:p + 4], 16)
        if v == qid:
            val = int(idx_s[p + 4:p + rw], 16)
            rec = blob[val - 1:blob.index('\n', val - 1)] if blob is not None else tuples[val - 1]
            zone, x, y, name = int(rec[0:4], 16), int(rec[4:7], 16), int(rec[7:10], 16), rec[10:]
            return zone, x, y, (name or None)
        if v < qid: lo = mid + 1
        else: hi = mid - 1
    return None


# ------------------------------------------------------------------- QuestPre
def pack_quest_pre(qp):
    blob, idx = [], []
    p = 1
    for qid in sorted(qp):
        s = lua_unescape(qp[qid])
        if not re.match(r'^-?\d+(:-?\d+)*$', s): sys.exit("bad QuestPre value %d: %r" % (qid, s))
        idx.append(hexw(qid, 4) + hexw(p, 5))
        blob.append(s + '\n')
        p += len(s) + 1
    return idx, blob


def packed_find_py(idx_s, rw, qid):
    lo, hi = 0, len(idx_s) // rw - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        p = mid * rw
        v = int(idx_s[p:p + 4], 16)
        if v == qid: return int(idx_s[p + 4:p + rw], 16)
        if v < qid: lo = mid + 1
        else: hi = mid - 1
    return None


# ------------------------------------------------------------------- Reagents
def pack_reagents(rg, fmt):
    rows = {}
    for cid, raw in rg.items():
        nums = [int(x) for x in raw.split(',')] if raw else []
        if len(nums) % 2 or not nums: sys.exit("odd reagent list for %d" % cid)
        rows[cid] = nums
    if fmt == 'hash':
        lines = ['[%d]="%s",' % (cid, ','.join('%d:%d' % (nums[i], nums[i + 1])
                                                 for i in range(0, len(nums), 2)))
                 for cid in sorted(rows) for nums in [rows[cid]]]
        return lines, None, rows
    idx, blob, p = [], [], 1
    for cid in sorted(rows):
        nums = rows[cid]
        n = len(nums) // 2
        if n > 15: sys.exit("more than 15 reagents for %d" % cid)
        idx.append(hexw(cid, 4) + hexw(p, 5) + hexw(n, 1))
        rec = ''.join(hexw(nums[i], 4) + hexw(nums[i + 1], 2) for i in range(0, len(nums), 2))
        blob.append(rec)
        p += len(rec)
    return idx, blob, rows


def decode_reagents_py(idx_s, blob, cid):
    v = packed_find_py(idx_s, 10, cid)
    if v is None: return None
    n, p = v % 16, v // 16
    out = []
    for i in range(n):
        r = blob[p - 1 + 6 * i:p - 1 + 6 * i + 6]
        out += [int(r[0:4], 16), int(r[4:6], 16)]
    return out


# ---------------------------------------------------------------- size model
def est32(kind, **kw):
    """Rough 32-bit client retained bytes: TValue 12, hash node 28, string 24+len,
    table header 32, array slot 12; hash parts round up to a power of two."""
    def pow2(n):
        p = 1
        while p < n: p *= 2
        return p
    if kind == 'hash_str':   # [id]=string hash, strings interned
        return pow2(kw['n']) * 28 + sum(24 + len(s) for s in kw['distinct'])
    if kind == 'hash_num':
        return pow2(kw['n']) * 28
    if kind == 'hash_tbl':   # [id]={numbers}
        return pow2(kw['n']) * 28 + sum(32 + 12 * len(t) for t in kw['tables'])
    if kind == 'string':
        return 24 + kw['len']
    if kind == 'array_str':
        return 32 + 12 * kw['n'] + sum(24 + len(s) for s in kw['items'])
    raise ValueError(kind)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--questgivers', required=True)
    ap.add_argument('--reagents', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--givers', choices=['blob', 'array'], default='blob')
    ap.add_argument('--reagents-fmt', choices=['blob', 'hash'], default='blob')
    a = ap.parse_args()

    # ---------------------------------------------------------- QuestGivers
    src = open(a.questgivers, encoding='utf-8', newline='').read()
    if '\r' in src: sys.exit("input has CR line endings; expected LF")
    lines = src.split('\n')
    qg, qg0, qg1 = read_block(lines, 'ANx.QuestGivers = {', LINE_STR)
    qp, qp0, qp1 = read_block(lines, 'ANx.QuestPre = {', LINE_STR)
    try:
        rest_at = lines.index('ANx.QuestNameBlobs = {')
    except ValueError:
        sys.exit("no QuestNameBlobs block")
    assert qp1 + 1 == rest_at, "unexpected text between QuestPre and QuestNameBlobs"
    assert qg1 + 1 == qp0, "unexpected text between QuestGivers and QuestPre"

    idx, blob, tuples = pack_quest_givers(qg, a.givers)
    idx_s = ''.join(idx)
    blob_s = ''.join(blob) if blob else None
    # self-check: every quest decodes to the old value
    for qid, raw in qg.items():
        s = lua_unescape(raw)
        z, x, y, n = re.match(r'^(\d+):(\d+):(\d+):(.*)$', s, re.S).groups()
        exp = (int(z), int(x), int(y), n or None)
        got = decode_quest_giver_py(idx_s, blob_s, tuples, qid)
        assert got == exp, (qid, exp, got)
    for probe in (0, 1, max(qg) + 1, 65535):
        if probe not in qg: assert decode_quest_giver_py(idx_s, blob_s, tuples, probe) is None

    pidx, pblob = pack_quest_pre(qp)
    pidx_s, pblob_s = ''.join(pidx), ''.join(pblob)
    for qid, raw in qp.items():
        p = packed_find_py(pidx_s, 9, qid)
        assert pblob_s[p - 1:pblob_s.index('\n', p - 1)] == lua_unescape(raw), qid

    ndist = len(blob) if blob else len(tuples)
    out = []
    out.append('''-- AttuneNext quest-giver locations and prerequisite chains (generated from
-- the Questie 3.3.5 database, packed by tools/pack_data.py - re-run that on
-- the unpacked generator output instead of editing this file).
--
-- QuestGiversPacked: sorted 9-char records of 4 hex questId + 5 hex 1-based
-- byte position into QuestGiverBlob, whose records are 4 hex zoneAreaId,
-- 3 hex x10, 3 hex y10 (zone percent *10), the giver name and "\\n". The
-- %d quests share %d distinct giver records. Read with ANx.QuestGiver /
-- ANx.HasQuestGiver (Core.lua). Quests that only start from a dropped item are
-- merged in by Data_QuestItemStarts (ANx.QuestGiversExtra).
--
-- QuestPrePacked: sorted 9-char records of 4 hex questId + 5 hex position into
-- QuestPreBlob ("minLevel:parentQuest:mode:prereq1:prereq2...\\n" per quest),
-- decoded on demand in QuestArrow.lua (chain walking is click/row driven).
--
-- QuestNameBlobs = a few big strings of "\\n<questId>=<name>" records,
-- scanned by ANx.QuestNameOf (Core.lua) - quest names are only needed for
-- click-time chat/arrow labels, so a per-id hash (~440 KB) was resident RAM
-- for a value read a handful of times per session.
local _, ANx = ...
ANx = ANx or _G.AttuneNext''' % (len(qg), ndist))
    out.append('-- %d quests with a known giver' % len(qg))
    out.append(emit_string('QuestGiversPacked', idx))
    if blob is not None:
        out.append('-- %d distinct giver records' % len(blob))
        out.append(emit_string('QuestGiverBlob', blob))
    else:
        out.append('-- %d distinct giver records (1-based palette)' % len(tuples))
        out.append('ANx.QuestGiverTuples = {')
        out.extend('"%s",' % lua_escape(t) for t in tuples)
        out.append('}')
    out.append('-- %d quests with prerequisite data' % len(qp))
    out.append(emit_string('QuestPrePacked', pidx))
    out.append(emit_string('QuestPreBlob', pblob))
    out.extend(lines[rest_at:])
    text = '\n'.join(out)
    if not text.endswith('\n'): text += '\n'
    qg_path = os.path.join(a.out, 'Data_QuestGivers.lua')
    open(qg_path, 'w', encoding='utf-8', newline='\n').write(text)

    old_qg = est32('hash_str', n=len(qg), distinct=set(lua_unescape(v) for v in qg.values()))
    old_qp = est32('hash_str', n=len(qp), distinct=set(lua_unescape(v) for v in qp.values()))
    if blob is not None:
        new_qg = est32('string', len=len(idx_s)) + est32('string', len=len(blob_s))
    else:
        new_qg = est32('string', len=len(idx_s)) + est32('array_str', n=len(tuples), items=tuples)
    new_qp = est32('string', len=len(pidx_s)) + est32('string', len=len(pblob_s))
    print("Data_QuestGivers.lua: %d bytes -> %s" % (len(src.encode('utf-8')), qg_path))
    print("  QuestGivers %d quests, %d distinct records; index %d chars, %s %d chars"
          % (len(qg), ndist, len(idx_s), 'blob' if blob else 'palette',
             len(blob_s) if blob else sum(len(t) for t in tuples)))
    print("  QuestPre %d quests; index %d chars, blob %d chars" % (len(qp), len(pidx_s), len(pblob_s)))
    print("  est. 32-bit retained: QuestGivers %d -> %d KB, QuestPre %d -> %d KB"
          % (old_qg // 1024, new_qg // 1024, old_qp // 1024, new_qp // 1024))

    # ------------------------------------------------------------- Reagents
    src = open(a.reagents, encoding='utf-8', newline='').read()
    if '\r' in src: sys.exit("input has CR line endings; expected LF")
    lines = src.split('\n')
    rg, rg0, rg1 = read_block(lines, 'ANx.Reagents = {', LINE_TBL)
    ro, ro0, ro1 = read_block(lines, 'ANx.ReagentOutput = {', LINE_NUM)
    assert rg1 + 1 == ro0
    assert all(l == '' for l in lines[ro1 + 1:]), "unexpected text after ReagentOutput"
    ridx, rblob, rows = pack_reagents(rg, a.reagents_fmt)
    if rblob is not None:
        ridx_s, rblob_s = ''.join(ridx), ''.join(rblob)
        for cid, nums in rows.items():
            assert decode_reagents_py(ridx_s, rblob_s, cid) == nums, cid
        for probe in (0, 1, max(rows) + 1, 65535):
            if probe not in rows: assert decode_reagents_py(ridx_s, rblob_s, probe) is None

    out = ['''-- AttuneNext static reagent data (generated from the 3.3.5a DBC craft dump,
-- packed by tools/pack_data.py - re-run that on the unpacked generator output
-- instead of editing this file). Covers the attunable gear AND every craftable
-- intermediate its recipes reach, so demands can be expanded down to true raw
-- materials. A live profession-window scan overrides these (Synastria customs).
--''']
    if rblob is not None:
        out.append('''-- ReagentsPacked: sorted 10-char records of 4 hex craftedItemId + 5 hex 1-based
-- position into ReagentBlob + 1 hex reagent count; ReagentBlob holds 6-char
-- records of 4 hex reagentId + 2 hex count. Decoded by ANx.StaticReagents
-- (Core.lua) into a { reagentId1, count1, ... } array, memoized per id by
-- Engine.ReagentsOf.
-- ANx.ReagentOutput: [craftedItemId] = items produced per craft (only >1).
local _, ANx = ...
ANx = ANx or _G.AttuneNext''')
        out.append('-- %d craftable items, %d reagent records' % (len(rows), sum(len(r) // 6 for r in rblob)))
        out.append(emit_string('ReagentsPacked', ridx))
        out.append(emit_string('ReagentBlob', rblob))
    else:
        out.append('''-- ANx.Reagents: [craftedItemId] = "reagentId:count,reagentId:count,..."
-- decoded by ANx.StaticReagents (Core.lua) into a fresh array.
-- ANx.ReagentOutput: [craftedItemId] = items produced per craft (only >1).
local _, ANx = ...
ANx = ANx or _G.AttuneNext''')
        out.append('ANx.Reagents = {')
        out.extend(ridx)
        out.append('}')
    out.extend(lines[ro0:ro1 + 1])          # ANx.ReagentOutput block, verbatim
    text = '\n'.join(out) + '\n'
    rg_path = os.path.join(a.out, 'Data_Reagents.lua')
    open(rg_path, 'w', encoding='utf-8', newline='\n').write(text)

    old_rg = est32('hash_tbl', n=len(rows), tables=list(rows.values()))
    if rblob is not None:
        new_rg = est32('string', len=len(ridx_s)) + est32('string', len=len(rblob_s))
    else:
        strs = [l.split('=', 1)[1].strip('",') for l in ridx]
        new_rg = est32('hash_str', n=len(rows), distinct=set(strs))
    print("Data_Reagents.lua: %d bytes -> %s" % (len(src.encode('utf-8')), rg_path))
    if rblob is not None:
        print("  Reagents %d items; index %d chars, blob %d chars" % (len(rows), len(ridx_s), len(rblob_s)))
    else:
        print("  Reagents %d items as strings" % len(rows))
    print("  ReagentOutput %d items kept as a hash (est. %d KB on 32-bit)" % (len(ro), est32('hash_num', n=len(ro)) // 1024))
    print("  est. 32-bit retained: Reagents %d -> %d KB" % (old_rg // 1024, new_rg // 1024))


if __name__ == '__main__':
    main()
