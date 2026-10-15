# AttuneNext performance audit (v3.6.2)

Scope: every file in this repository, plus the AttuneNext-Simple engine copy where it matters. Nothing in the addon itself was changed. All numbers come from the headless harness (Lua 5.1 through Python `lupa`) and from measured prototypes in scratch copies. Nothing has been tested in the real game client.

Contents of this folder:
- `REPORT.md`: this report.
- `prototypes/`: six measured diffs that each apply with `git apply`, the data generator `pack_data.py`, and `MEASUREMENTS.md` with every before/after number and equivalence check.
- `tools/`: the harness variants and equivalence checkers the audit used.

## 1. Summary

The addon's biggest cost is how it reads the server's loot database (DB). The login scan and the per-item filter checks build one Lua table per source row, and a world drop listed in many zones is rebuilt once per zone. One login scan builds about 1.36 million throwaway tables for 24 thousand items in the harness. Reading the rows straight off the server API instead cut peak memory from 145 to 84 MB and the scan from about 410 to 187 frames, with identical results. At a heavier synthetic load the peak fell from 211 to 154 MB and the scan by 48%.

The second group of costs comes from client calls the harness cannot see. With a Bind, Faction or Class filter saved, every login re-reads 17 to 22 thousand item tooltips. With "In bags: Hide" on, every render calls `GetItemCount` 19 to 36 thousand times. Switching the Faction or Class filter on reads 12 to 13 thousand tooltips inside one frame. Saving the tooltip results, building one owned-items set per bag event, and moving the sweep into the background remove nearly all of that from the player's frames.

The third group is pacing. The background pump spends 10 ms of work plus an unbounded garbage collector (GC) step per frame, so real frames reached 16 ms on average and single frames reached 52 ms. A time-capped pump brought the worst resume to 15 ms, and to 11 ms on top of the streaming change. The status-cache export at the end of login is one 60 to 200 ms frame and should run as a background job.

With AttuneNext-Simple enabled, the whole scan runs twice in the same Lua state. Letting Simple reuse the main addon's structure brings the pair's peak from 252-275 MB down to the single-addon 145 MB in the harness.

Two harness artefacts inflated earlier numbers and must be kept in mind. The stock harness's pure-Lua `bit.band` is 3 to 13 times slower than the client's C version, so predicate-heavy timings were too high. The stock harness also names zones so that nothing matches, which forces every item into the localized-client fallback path. That alone produced the 46 MB zone cache and the 27 MB saved structure; with matching names the zone cache is 5.4 MB, consistent with the real 2 MB SavedVariables file.

Much is already in good shape and should stay as it is:

- Packed itemFlags bit fields and F_* accessors (extend with F_KIND/F_NOLOCK/F_REQ, do not replace)
- Packed-string statusCache and sort saved caches keeping SavedVariables near 2 MB
- Filter-aware NeededPredicates/WarmPredicates design (extend coverage, keep the shape)
- Coroutine pump with Enqueue tag dedupe and the SRC_ROW_BUDGET row-bounded source cache (the v3.6.2 crash fix)
- 60-row search cap and the 0.5 s bag-event debounce
- Nameplates.lua streaming ItemLocGetSourceAt without row tables (the model for db-02)
- ANx.ZoneLower memoized lower-case zone names (export and reuse it)
- ItemIsUniqueToZone: no callers, no rewrite
- ReagentOutput as a plain hash (datapack measured packing it as not worth it)
- collectgarbage setpause/setstepmul untouched (global to every addon in the Lua state)
- No GetFramerate-based budget rule; the share-of-game-time rule was rejected
- Two-generation dispCache (cc-07a) and the FitText proportional first cut: measured no gain
- AltCache SnapshotAltCan stays on its 0.1 s timer chunks, not in the pump
- ANx.QuestGiver stays unmemoized (tens of calls per render at ~3-4 us per probe)
- Lazy frame creation: only the timer, event and pump frames exist at load

## 2. Measurements

| Metric | v3.6.2 baseline | After change | Change measured |
| --- | --- | --- | --- |
| Peak Lua memory during login (stock harness) | 142-147 MB | 84 MB | streaming scan + predicates (`prototype_stream.diff`) |
| Login scan length after data-ready | ~400-420 frames | 187 frames | same |
| Source-row tables built per login | 1,357,213 | 21,384 | same |
| Resident after full GC | 72.5 MB | 68.2 MB | same, mostly from not exporting at scan end |
| Heavy load (1,000 items/zone, 500-row items): peak / scan | 211 MB / 1,496 frames | 154 MB / 780 frames | same |
| Heavy tail, 100 world drops x 1,000 rows: peak / scan / worst frame | 116.5 MB / 635 frames / 141 ms | 41.5 MB / 373 frames / 33 ms | gap-real-db-shape-01/02 |
| First zone-list render after a cached relog | 2,275 ms | 138 ms | gap-real-db-shape-02 |
| First Classic World-Drops zone list | 720-865 ms | 105-110 ms | gap-real-db-shape-04 |
| `BestSource` over 600 items with 200 rows each (cold) | 202 ms, 85 MB garbage | 80 ms, 0.3 MB | `proto_bestsource.diff` |
| Data_QuestGivers + Data_Reagents compile / retained | 10.4 ms / 2.6 MB | 1.5 ms / 0.8 MB | `proto_datapack_code_only.diff` |
| Saved structure on disk (synthetic) / login parse | 26.8 MB / 265 ms | 7.1 MB / 19 ms | `proto_svpack.diff` |
| Resident after a cached login | 65.2 MB | 20.6 MB | same, zones decoded lazily |
| Pump cost per scan frame / worst single resume | 16.5 ms / 52 ms | 11.0 ms / 15-17 ms | `proto_pacing.diff` |
| Same, on top of streaming | 13.5 ms / 30 ms | 10.1 ms / 11-12 ms, no frame over 25 ms | same |
| `GetItemCount` per render with In bags on | 19,200-36,497 | 0 (104 container calls per bag change) | gap-client-c-costs-04 |
| Tooltip reads in one render after switching Faction on | 12,428 | 0 inline | gap-client-c-costs-05 |
| AttuneNext + Simple peak | 252-275 MB | 145 MB | gap-two-addons-pacing-01 |
| Per-file compile at login (all files) | 32.6 ms | not re-measured | `tools/harness.py LOADPROF=only` |
| Textures folder | 31 MB of uncompressed 32-bit TGA | not measured | textures bundle |

How to read these against the real client: the client's tables are about 30% smaller and its CPU about 2 to 3 times slower per operation. The harness charges nothing for tooltips, `GetItemCount`, text measuring or server item queries, so client-call savings are larger in game than the table shows. Treat every row as a before/after ratio, not an absolute figure.

## 3. Ranked optimizations

Each entry names the finding id, tags it as load (login and scan time), cpu (per-frame and per-event work) or memory, and gives its bundle. Entries absorb duplicate findings from other analysts; those ids are listed at the end of each entry. The text in each entry comes from the analyst's finding and the verifier's assessment; file paths starting `scratch/` refer to working files that are not in this repository.

### Tier 1: Do first (17 items)

High impact. Instrumentation comes first because one in-game reading sizes every cache below.

#### gap-telemetry-and-harness-fidelity-01: Add /an perf GetSources call/row counters, largest item, srcCache flush count
Tags: load, cpu, memory | Bundle: instrumentation | Impact: high | Effort: small
Files: `Core.lua:1557-1577`, `Engine.lua:447-462`, `Engine.lua:1597-1612`, `Core.lua:1994-2002`, `Core.lua:260-279`

**What happens now.** Engine.PerfStats reports only entry counts (srcCache items, zones, jobs) and the printer prints three lines, so nothing in game says how many source rows the real loot DB returns per item, how heavy its tail is, or how often the 60,000-row budget flushes the whole srcCache (Engine.lua:452-455). Every memory figure in the audit therefore rests on the synthetic DB's shape (every 10th item 200 rows, 1.36M rows per login). The prototype adds a counter table ANx.Perf owned by Core (it loads first; Engine re-creates it if absent so AttuneNext-Simple's Core still loads), increments gsCalls/gsEmpty/gsRows/gsMaxRows/gsMaxItem inside ANx.GetSources (3 integer ops per call, before the zero-row early return so the count matches the harness wrapper), srcFlush/srcTooBig in Engine.Sources, and exposes srcCacheRows, #universeCache and the itemFlags count in PerfStats, with Engine.PerfReset behind '/an p...

**Change.** Do now. Apply the Core/Engine hunks of scratch/gap_telemetry/telemetry.diff that add the ANx.Perf table (Core, created in Engine if absent), the gsCalls/gsEmpty/gsRows/gsMaxRows/gsMaxItem increments in ANx.GetSources placed after the LootDbLoaded guard and before the n==0 early return, srcFlush/srcTooBig in Engine.Sources, srcRows/universe/flags in PerfStats, Engine.PerfReset and the 'sources:' printer line. Read after one fresh-scan login: gsRows/gsCalls (real rows per item), gsMaxRows (is the tail 200 or 2,000+ rows), srcFlush (does the 60,000-row wholesale flush fire at all with real data; it fires 23-25 times per synthetic login). That single reading decides whether the other lenses' srcCache streaming/row-bound proposals are weighed in the fresh-scan (1.4M rows) or heavy-tail (16M rows) scenario. This is the prerequisite for findings 03, 05 and 12.

**Expected effect.** Re-ran the A/B myself (SCENARIO=fresh-scan, 2 runs each, ADDON=repo vs ADDON=gap_telemetry/exp_tele): repo scan-end frames 617/609, peak 97.9/99.7 MB, after-GC 30,913 KB; patched 626/610, peak 95.7/100.6 MB, after-GC 30,929 KB. Run-to-run spread of the repo alone is 8 frames / 1.8 MB, so the patch is inside noise. The addon's own line printed 'GetSources 67171 calls (4357 empty) / 1432187 rows, biggest 200 rows (item 10780); srcCache 0 items / 0 rows, 25 flushes, 0 too big', identical to the harness wrapper (67,171 / 1,432,187). In mismatch-names mode it printed 66,609 / 1,357,213 / 23 flushes (= the stock baseline). On a cached login it printed 24,746 calls / 458,461 rows / 8 flushes, which exposes that the default-filter warmup (ItemQuestCharBlocked, Engine.lua:703-710) fetches sources for every universe item.

**Risk.** Counters are session-cumulative (a /an reset rescan adds; '/an perf reset' zeroes). Lua 5.1 string.format('%d') truncates doubles, so large gsRows is fine on 3.3.5. Apply the Core and Engine hunks together: the printer formats Engine-owned fields (pumpFrames, srcFlush...) with %d and would raise on nil if only Core were patched. On AttuneNext-Simple (older v3.6.0 engine) port the Engine hunks too or the Simple /an perf will print nothing new.

#### gap-telemetry-and-harness-fidelity-02: Add /an perf zone-name telemetry: fallback count, unknown and unmatched samples
Tags: load, memory | Bundle: instrumentation | Impact: high | Effort: small
Files: `Engine.lua:816-826`, `Engine.lua:862-867`, `Engine.lua:1597-1612`

**What happens now.** ZoneData classifies each item by the rows that name this zone, but when no row names ANY zone the addon knows it falls back to every row (Engine.lua:825). The stock harness names rows 'Zone0..59', so every item took the fallback and every quest/vendor/world row was classified into every zone that lists the item: this is why zoneCache is 46 MB, the structCache SavedVariables 27 MB and the scan 410 frames in the audit, versus 5.4 MB / 8.3 MB / 292 frames with consistent real names. Whether the English client ever takes that path, and whether a few zones are spelled differently by the server (so their items never match), is only resolvable in the client.

**Change.** Do now, with 01 (same diff). Apply the ZoneData hunks: zMatched counter, perf.zoneItems/zoneFallback/zoneUnmatched increments per (item, zone), the unknown-name sample in the elseif of 'if known[zl]', the unmatched-zone sample before 'zoneCache[zoneEntry.zone] = zc', and the 'zones:' printer line. Reading rules: zoneFallback == 0 means the English client is in the fresh-scan regime and the 46 MB zoneCache / 27 MB structCache problem does not exist there (re-weight the svpack and zoneCache-packing lenses to the 5 MB / 8 MB figures); zoneUnmatched > 0 with names listed means Data_Zones.lua spellings to fix, which is cheaper than any cache packing; zoneFallback == zoneItems means the localized-client fallback is live and finding 09's conditional fix applies.

**Expected effect.** Ran the patched copy in SCENARIO=mismatch-names: 'zones: 43200 items classified, 43200 by fallback, 0 recognised-unmatched; unknown names: zone1..zone8; zones with no match: Elwynn Forest, Westfall, Redridge Mountains, Duskwood, Stranglethorn Vale, Swamp of Sorrows, Blasted Lands, Deadwind Pass'; in fresh-scan: '43200 classified, 0 by fallback, 0 recognised-unmatched; unknown names: none; zones with no match: none'. Cost of the extra elseif in the row loop: mismatch-names patched 720 scan-end frames / 142.7 MB peak / avg 16.6 ms per busy frame versus the unpatched 695 / 150.2 MB / 16.5 ms (run_all B) and the stock-stub 724 / 149.9 MB (run_all A); within the +/-25-frame spread of that mode. In fresh-scan the branch never executes (every row names a known zone). The same scenario pair shows what the reading decides: zoneCache 46,134 KB vs 5,356 KB, after-GC 72.5 MB vs 30.9 MB.

**Risk.** Samples are capped at 8 each (perf.unk, perf.unmatched). ZoneData only runs on a fresh scan: on a cached login zoneItems stays 0 (my cached-login run printed zoneItems=0), so the author must read it after '/an reset' or a loot-DB version bump. The 'zones with no match' test (zMatched == 0 for a zone) can also fire legitimately for a zone whose rows all carry empty zone names; treat it as a list to inspect, not a bug list.

#### gap-telemetry-and-harness-fidelity-03: Add /an perf pump, GC-step, longest-resume, scan-wall and export timings
Tags: load, cpu | Bundle: instrumentation | Impact: high | Effort: small
Files: `Engine.lua:273-298`, `Engine.lua:158-180`, `Core.lua:611-640`, `Core.lua:1632-1637`, `Core.lua:1994-2002`

**What happens now.** BUDGET_MS=10 bounds only the resume loop: the collectgarbage('step', 2048) after it, the end-of-queue ExportCache and a single long resume (25 MaybeYield calls in ZoneData can mean 25 items x 200-2000 rows) are outside it, and none of it is measured in game. The pump already calls Clock() once per loop iteration; the patch restructures the loop to keep that count, adds one Clock() after the GC step and accumulates pumpFrames, pumpMs, pumpMaxMs(+job tag), pumpOver (> 2 x budget), resumeMaxMs(+tag), gcMs, gcMaxMs and exportMs; Core times ExportStatusCache (statusExportMs, x count) and stamps readyAt = GetTime() at data-ready so summariesS (first cacheDirty export) and idleS (queue empty) are frame-granular wall clocks immune to another addon calling debugprofilestart().

**Change.** Do now, with 01 (depends on ANx.Perf and the Core readyAt stamp). Apply the pump hunks (keep the cached 'now' so the clock count stays N+2 per frame), the readyAt/readyN stamp in AttuneNext_OnDataReady, the ExportStatusCache timing, and the 'fps ... scan:' and 'pump:' printer lines. One /an perf after a fresh-scan login yields the client slowdown factor to apply to every lens's ms figures (pumpMs/pumpFrames versus the harness's 14.6 ms per frame), the GC-step share (if it is 25-30% on the client too, the GC_STEP_KB pacing lens has its number), the worst frame and its job, and the real cost of the two exports. Pair the reading with GetFramerate() as the patch prints it.

**Expected effect.** Patched fresh-scan runs printed 'pump: 312 frames, 4645ms (max 44.8ms in summary2, 46 over 20ms); resume max 37.4ms in summary2; gc step 1103ms (max 25.0ms)' and '296 frames, 4231ms (max 36.4ms in summary1, 29 over 20ms); resume max 30.2ms in summary1; gc step 936ms (max 21.1ms)', plus 'scan: summaries 3.3s/3.2s, idle 5.0s/4.7s after data-ready' and 'exports: struct 33/29ms, status 70/68ms x1'. So the GC step is 21-24% of pump time in fresh-scan and 29% in mismatch mode (1,926 of 6,552 ms, max 62.9 ms), and 10-15% of pump frames exceed 2x the budget. Clock-call count: the restructured loop reads Clock() once per resume plus one at start (same as before: N+1) and adds exactly one read after the GC step; A/B inside noise (see 01).

**Risk.** debugprofilestop() is reset by any addon calling debugprofilestart(); one frame's delta can then be negative or huge. Clamp samples outside 0..10,000 ms if ever seen; the GetTime-based summariesS/idleS are unaffected. resumeMaxMs conflates a heavy 25-item slice with sort/concat tails and automatic GC debt paid inside the resume; it names the job, not the function.

#### gap-telemetry-and-harness-fidelity-08: Adopt the consolidated harness; quote the scenario name with every number
Tags: load, cpu, memory | Bundle: instrumentation | Impact: high | Effort: small
Files: `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/harness.py`, `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/run_all.sh`, `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/run_all_output.txt`

**What happens now.** Nine lenses patched the stock harness privately and inconsistently: three different fast bit.band implementations (power-of-two fast path in harness_frame/harness_load/cachedlogin, a set-bit loop in mb_addon/mb_login2, a byte table in ui_bench3), the frame __index nil fix in four files, two different ZNAMES namings (gap's REALZ by row index, lens's by id), WDROP/WROWS, NPLATES/INST, FPS/SLOW pacing, and the cc lens's cost models, so their numbers were taken on different stub sets.

**Change.** Do now (it is written; copy scratch/gap_telemetry/harness.py to C:\coding\Attunenext\tools\harness.py, keeping harness_orig.py beside it for one release). Quote the scenario name with every number from now on; fresh-scan is the baseline (601-626 scan-end frames, 96-101 MB peak, 30.9 MB after GC, 67,171 calls / 1,432,187 rows) and SCENARIO=stock reproduces the audit. Change the ADDON default to the author's checkout path, and for two-addons pass the real AttuneNext-Simple clone through ADDONS so the pair reflects the v3.6.0 engine actually installed. Fill USEC_*/CACHEPCT once finding 05 supplies in-game counts.

**Expected effect.** run_all_output.txt verified against the audit figures: SCENARIO=stock reproduces harness_orig byte-for-byte on the memory profile (zoneCache 46,134 KB, ANx.db 7,440 KB, summaryCache 7,015 KB, GetSources 66,609 / 1,357,213) and lands inside the frame window (724 vs 704-748); heavy-tail, 30fps, two-addons, cached-login, ui and predicate scenarios all land within the quoted brackets. My own fresh-scan re-runs on the stock repo gave 617/609 scan-end frames and 97.9/99.7 MB peak versus the file's 601-609 / 97-100 MB. bitbench and stubcrash re-run clean (see 10 and 11). harness.py is 1,016 lines (vs 411 for harness_orig.py), self-contained apart from the lupa and luaparser packages; the AttuneNext-Simple stand-in is generated by renaming the repo's own globals (make_simple at harness.py:596-614), i.e. it models two copies of v3.6.2, not the real Simple fork whose Engine is v3.6.0.

**Risk.** Defaults changed: SCENARIO=fresh-scan with ZNAMES=2, the fast bit library and the nil frame stub, so new numbers are not comparable to v3.6.2's 134 MB figure (that is SCENARIO=stock). ZNAMES=2 bumps rows so every listing zone has a row (1.43M vs 1.36M) and drops 11 items from the universe (24,346 vs 24,357).

#### gap-telemetry-and-harness-fidelity-10: Use the bit-exact fast bit stub; divide stock-stub predicate figures by 3-5
Tags: cpu | Bundle: instrumentation | Impact: high | Effort: small
Files: `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/tools/harness_orig.py:24-45`, `Core.lua:1402`, `Core.lua:427-437`, `Engine.lua:477`, `Engine.lua:1800`, `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/bitbench.py`

**What happens now.** IsAttunableAtAll does two bit.band calls per item (Core.lua:1402) and every flag accessor does band(rshift(f, shift), mask) (Core.lua:429, Engine.lua:477-1800); the stock stub loops 32 times with four floor/modulo ops per iteration for each call, so a 0.1 us C call cost 3.4 us. The consolidated stub answers the addon's operand shapes (single-bit test, low masks 3/7/1023) in two arithmetic ops and everything else from a 256x256 byte table, with bor as a+b-band(a,b).

**Change.** Do now: use harness.py's default bit library and pass BITLIB=stock only to reproduce old numbers. Re-state the pred, ui and pacing lenses' per-render and per-universe-walk numbers with the fast stub (they are 3-13x lower) before ranking those proposals; the memory and scan-frame conclusions stand.

**Expected effect.** Re-ran bitbench.py: 0 mismatches for all variants over 20,000 random pairs x 6 checks (band, reversed band, bor, 3-arg band, rshift, lshift); addon-hot shape stock 12.76 us/iter vs fastC 0.375 us (34x), general-operand band 4.0 vs 0.58 us. Predicate bench from run_all (stock -> fast): bit.band(x,255) 3.22 -> 0.12 us, Engine.Eligible 9.29 -> 1.37 us, IsAttunableAtAll 6.27 -> 0.49, CanCount 6.48 -> 0.85, ScopeLeft 6.79 -> 1.17, RemainingByCategory 686 -> 138 ms; ExportStatusCache 205-222 -> 65-100 ms; UI.Show root 553 -> 145 ms, RemainingReport 349 -> 73 ms. The login scan moves 656-670 -> 607-626 scan-end frames (~7%, a little more than the finding's 3%) because it is GetSources/table-bound. Static bit call sites in the addon: 12 (Core 8, Engine 4), but FlagGet's band(rshift(f,shift),mask) runs per predicate per item, which is why predicate figures moved 5-13x.

**Risk.** None for the addon. The WoW client's bit library is C, so even the fast stub is pessimistic; any ms figure the pred/ui/pacing/status-cache lenses took on the stock stub must be divided by 3-5 before applying the 2-3x client factor. Memory and scan-frame figures are unaffected either way.

#### gap-telemetry-and-harness-fidelity-09: Relabel stock-harness memory figures as fallback mode; re-weight packing by tf-02
Tags: memory | Bundle: instrumentation | Impact: high | Effort: small
Files: `Engine.lua:816-825`, `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/tools/harness_orig.py:215-219`

**What happens now.** harness_orig.py's ItemLocGetSourceAt names every row 'Zone<i%60>'; Engine.KnownZoneNameSet never contains those, so ZoneData's fallback (Engine.lua:825) classifies every row of every item into every zone that lists it (43,200 of 43,200 items by fallback). The synthetic source types cycle {0,1,2,9,0,6}, so a third of those rows are quest or vendor rows that become questList/vendorByName entries in zoneCache, which ExportCache stores by reference into ANx.db.structCache and the client serializes at logout. All of v3.6.2's memory numbers (235 to 134 MB) and the other lenses' zoneCache/structCache findings were taken in this mode.

**Change.** Do now as a bookkeeping change: label every number the audit quoted so far as SCENARIO=stock (localized-client fallback mode) and re-weight the svpack and zoneCache-packing lenses by the real zoneFallback/zoneItems ratio once 02 is read. If zoneUnmatched > 0, fix the spellings listed under 'zones with no match' in Data_Zones.lua. Only if the client reports fallback for everything: change ZoneData so that in fallback mode isQuest/isVendor/isWorld are set from srcType alone and questList/vendorByName entries are not created (that is what makes the 46 MB), which cuts zoneCache back to the 5 MB regime without any packing work.

**Expected effect.** Same DB, only row naming differs: stock/mismatch-names versus fresh-scan: Engine.zoneCache 46,134 KB vs 5,356 KB (8.6x), resident after full GC 72,527 vs 30,894 KB, peak 149.9 vs 98.2 MB, scan 410 vs 292 frames; my re-run of mismatch-names on the patched copy: 720 scan-end frames, 142.7 MB peak, 73.6 MB after GC versus fresh-scan 610-626 / 96-101 MB / 30.9 MB. The telemetry prints 43,200 of 43,200 items classified by fallback in mismatch mode and 0 in fresh-scan, so the mechanism (Engine.lua:825 fallback attributing every quest/vendor row of an item to every zone that lists it) is confirmed as the whole difference. Real-data scale from the handoff: ~2 MB structCache on disk, so the English-client zoneCache is nearer the 5 MB harness figure than 46 MB.

**Risk.** A measurement correction, no addon change by itself; the conditional code fix (classify fallback items by the item's own source types without indexing quest/vendor rows of other zones into questList/vendorByName) must wait for finding 02's zoneFallback reading, because on an English client it would never execute. The ZNAMES=2 construction is itself synthetic (rows bumped so each listing zone has a row).

#### micro-03: Cache GoalStatus per goal key, one pass per goal instead of two walks per render
Tags: cpu | Bundle: UI render caching | Impact: high | Effort: small
Files: `Engine.lua:2311-2332`, `Engine.lua:2336-2376`, `UI.lua:4345-4347`, `UI.lua:4706-4708`, `UI.lua:2404-2405`, `GoalHud.lua:129-131`

**What happens now.** GoalStatus(goal) walks every difficulty of every instance in the goal, calling Engine.Eligible + ANx.CountDone per item in `addItem`, then calls InstanceClears(inst) which walks the SAME items again with Eligible + CountDone + ClearChance. Nothing is memoized: UI.UpdateHomePanel calls it for up to 4 goals on every UI.Render of the root screen (every RefreshIfShown from timers, every chip click while on Home), UI.UpdateWLPanel for up to 3, the goals builder and GoalHudNow for all goals (GoalHudUpdate fires after every attune completion). A content goal (e.g. 'WotLK Raids') covers ~20k item-visits, so one render does ~40k Eligible calls plus, when clearChanceCache was wiped (micro-02), a GetSources rebuild for every item - all on the main thread.

**Change.** Do now, together with pred-02 (which makes the ClearChance part a hash hit across revisions) and before/with pred-01. Sketch: `local goalCache = {}` cleared in InvalidateStats/InvalidateAll; in GoalStatus `local gk = Engine.GoalKey(goal); local c = goalCache[gk]; if c then return c end`, then one pass: for each instance of the goal keep per-instance leftDrop/expected/noDrop with a per-instance seenInst and the goal-wide seen for total/done; per item call Eligible once, CountDone once, and ClearChance only when left; after each instance add math.ceil(leftDrop/expected) exactly as InstanceClears does; store `goalCache[gk] = st`. Delete the second walk (InstanceClears has no other caller). Move the HUD repaint behind the 2 s InvalidateStats (MarkAttuneDirty callback) so the memo is never stale. ~40 lines in Engine.lua, 3 in Core.lua. Later, optional (ui-03/frame-01 c): compute cold statuses in an Engine.Enqueue job tagged 'goals' with MaybeYield in the item loop and paint '...' until it lands; not needed once the memo makes the cold pass once-per-revision.

**Expected effect.** cd scratchpad/verify_engcache && ADDON=/home/user/AttuneNext ZONEN=100 HEAVY=0 NITEMS=20000 python3 -I bench.py (fast table bit stub, 18,266-id universe, 100 items per difficulty): 'GoalStatus WotLK D (16 inst x 3 diffs) [cold] 71.69 ms alloc~5880 KB' (9,525 Eligible, 6,329 CountDone, 2,557 ClearChance -> 2,557 GetSources) and '[same rev] 34.23 ms' (the double walk alone); Classic D 37.3 / 20.8 ms; inst goal 1.4 / 0.9 ms; 'root render, 0 goals [cold] 74.50 ms' vs 'root render, 3 content goals [cold] 187.82 ms alloc~11566 KB'; same-rev root render 1.80 ms (0 goals) vs 67.42 ms (3 goals); 'ANx.GoalHudNow() 3 content goals [cold] 145.62 ms alloc~10756 KB', '[same rev] 102.94 ms'. Stock ZONEN=600 HEAVY=200: WotLK D goal 346 / 194 ms, root 3 goals 886 / 372 ms, GoalHudNow 787 / 367 ms.

**Risk.** Timing hazard for ANY per-rev memo: GoalHudUpdate fires 1 s after a completion (Core.lua:1698 -> GoalHud.lua:163) but MarkAttuneDirty's InvalidateStats fires at 2 s (Core.lua:1789-1791) and nothing repaints the HUD afterwards, so a memoized GoalStatus would show the pre-completion count until the next completion.

Also reported as: ui-03, pred-04, frame-01, load-11.

#### pred-02: Key clearChanceCache by filter and zone so it survives InvalidateStats
Tags: cpu, memory | Bundle: UI render caching | Impact: high | Effort: small
Files: `Engine.lua:69`, `Engine.lua:1991`, `Engine.lua:1992`, `Engine.lua:2008`, `Engine.lua:2065`, `Engine.lua:2127`

**What happens now.** Engine.ClearChance(item, zone, filter) = f(BestSource(item, zone, filter), SpawnCount(objId)). BestSource depends only on the loot DB rows, the zone, the constant source-type filter and ANx.CharCanDoQuest (race/class, fixed per character); SpawnCount is static data. Nothing in it reads db.scope/forge/faction/bind or attunement state. Yet Engine.InvalidateStats (line 72) sets clearChanceCache = {} on every filter click / attune completion / bag event, so the next RankRunsAsync (home panel and side pane request it on every screen, UI.AttuneNextGo inline) re-walks all 153 instance-difficulty rows and all 72 zones, and for every LEFT item calls BestSource -> Engine.Sources -> ANx.GetSources, which with srcCacheCap=800 (post-warmup) thrashes wholesale and rebuilds one 9-field table per source row. The key `itemId .. '|' ..

**Change.** Do now (ride with proto:bestsource if it ships: its sixth return already becomes objId). Sketch: `local ccByFilter, ccN, CC_CAP = {}, 0, 60000`; in ClearChance: `local f = ccByFilter[srcFilter or false]; if not f then f = {}; ccByFilter[srcFilter or false] = f end; local z = f[zoneName or ''] ; if not z then z = {}; f[zoneName or ''] = z end; local hit = z[itemId]; if hit then return hit end` (0 is truthy in Lua, so a cached 0 hits), compute `out` as today, `if ccN >= CC_CAP then ccByFilter = {}; ccN = 0; f = {}; ... end; z[itemId] = out; ccN = ccN + 1; return out`. Delete line 72; `Engine.InvalidateClearChance()` resets the tables and is called from InvalidateAll and ANx.InvalidateQuestDoable. ~30 lines, one file plus a one-line Core hook.

**Expected effect.** bench.py ZONEN=100 HEAVY=0: 'RankRuns(nil,'all') after InvalidateStats (clearChanceCache wiped) 197.12 ms alloc~25166 KB' with 'E.ClearChance=11999 A.GetSources(miss)=11792 ItemLocGetSourceAt=29487' - identical work to the first ranking ('first 213.77 ms ... GetSources(miss)=11792'), i.e. every re-rank is a cold one; 'clearChance entries after one ranking = 11999'. Stock ZONEN=600 HEAVY=200: 1,275.6 ms / 150 MB / 70,400 misses / 176,006 rows per re-rank, 72,007 entries. Memo layout microbench in the same run (64-bit lupa): '11999 entries: string key + {out,name}: build 12.8 ms, resident 2267 KB, 11999 hits 7.9 ms | [zone][id]=number: build 2.7 ms, resident 640 KB, hits 0.9 ms' (stock 72k: 5,002 KB vs 1,280 KB; hits 100 ms vs 5.9 ms).

**Risk.** Keep the wipe in InvalidateAll (data refresh; OnDataReady calls it at Core.lua:1641, which also heals any zeros cached before the loot DB loaded) and add Engine.InvalidateClearChance() to ANx.InvalidateQuestDoable (Core.lua:1354; only reachable via InvalidatePlayerIdentity, which nothing calls today - the hook keeps it correct).

Also reported as: mem-04, micro-02, gc-10.

#### ui-02: Cache What's Left per rev; derive byCat from left sets, not predicate walks
Tags: cpu | Bundle: UI render caching | Impact: high | Effort: small
Files: `UI.lua:4683`, `UI.lua:2271`, `UI.lua:2237`, `UI.lua:4744`, `Engine.lua:1082-1108`, `Engine.lua:1027-1080`

**What happens now.** UI.UpdateWLPanel (4683) and builders.whatsleftScope (2271) call Engine.RemainingByCategory(scope) on every render; it has no cache and iterates every id of every summary set for all three expansions (plus events) calling Engine.ScopeLeft per id (6-8 predicate calls each). builders.whatsleft (2237) calls Engine.RemainingReport() synchronously; after any InvalidateStats remainingCache is nil, so the builder rebuilds the full report inline on the main thread even though UpdateWLPanel has just queued RemainingAsync for the same work. UpdateWLPanel also re-runs RemainingMaterials(nil) + a table.sort every render (4744).

**Change.** Do now. Sketch: (1) in RemainingReport's universe loop use pred-11's ScopeLeftBoth and record `leftChar[id] = true` / `leftAcct[id] = true`; after the loop compute `r.byCat = { char = ..., acct = ... }` by iterating each summary set per expansion (pairs over s[cat], MaybeYield every 256 ids) and testing the left sets - hash lookups, no predicate calls - plus AllEventItems; (2) `Engine.RemainingByCategory(scope)` returns `remainingCache and remainingCache.byCat[scope]` and only builds inline as a fallback when asked before the report exists; (3) UI.lua:2237 becomes `if not Engine.RemainingReady() then Engine.RemainingAsync(UI.RefreshIfShown); AddRow(placeholder); return end`, and UpdateWLPanel/whatsleftScope read byCat from the cache (placeholders when nil); (4) `matsCache[prof or '*']` for RemainingMaterials cleared in InvalidateRemaining/InvalidateStats and from the bag-event handler; fold micro-13(a) (hoisted scope literal). ~80 lines in Engine.lua, ~15 in UI.lua, 1 in Core.lua.

**Expected effect.** bench.py ZONEN=100 HEAVY=0: 'whatsleft render [2nd same rev: RemainingByCategory+UnionStats+Materials inline] 183.24 ms alloc~1986 KB', '[3rd same rev] 77.24 ms alloc~1021 KB' with 'E.ScopeLeft=24546 GetItemTagsCustom=24546 CanAttuneItemHelper=24203 GetItemAttuneProgress=17440 GetItemCount=551'; 'RemainingByCategory('char') alone 55.07 ms' (23,860 ScopeLeft), 'acct' 50.6 ms, 'RemainingMaterials(nil) alone 8.26 ms alloc~445 KB' (547 GetItemCount), 'whatsleftScope render [same rev] 51.25 ms', cold render 124 ms (inline report). Stock: 230-477 ms per render, 104k ScopeLeft. pred prototype byCatCache: 'RemainingByCategory('char') alone 0.0 ms'. Client x2-3 plus the real GetItemCount cost (est. 2-10 us x ~550 = 1-5 ms): ~0.2 s per What's Left repaint at steady state and ~0.3-0.5 s after each revision bump, repeated on every refresh while the screen is open.

**Risk.** Counts lag one background pass after a filter change (the stat cards already behave this way). RemainingMaterials reads bags/bank: its memo must be dropped on BAG_UPDATE/PLAYERBANKSLOTS_CHANGED (Core.lua:1733-1738 already calls UI.RefreshMats there; add Engine.InvalidateMaterials() beside it) and in InvalidateRemaining (TradeSkillScan). RemainingByCategory needs a `yielding` flag with MaybeYield per ~256 ids when run inside the job.

Also reported as: pred-05, micro-04.

#### gap-client-c-costs-04: Build one owned-items set per bag event by walking containers, not GetItemCount
Tags: cpu | Bundle: filter client costs | Impact: high | Effort: small
Files: `Engine.lua:729-753`, `Engine.lua:755-757`, `Engine.lua:994`, `Core.lua:1733-1752`, `UI.lua:970-975`, `UI.lua:4454-4457`

**What happens now.** Engine.IsOwned (Engine.lua:746-753) answers each query with pcall(GetItemCount, id, true), a C walk over every bag and bank slot, and it is called from Engine.Eligible (757) and ScopeLeft (994) for every item that passes CanCount/FactionAllowed. Only the 19 equipped slots are memoized (EquippedSet, 729-743); the bag/bank answer is never cached, so one render of the instances screen asks the C side about every item in every listed instance, the root screen about the whole universe, and the two pick jobs that InvalidateStats triggers (Engine.lua:306-309, PickAsync for 'btn' and 'rec') walk the universe again. BAG_UPDATE (Core.lua:1733-1752) debounces 0.5 s then calls InvalidateOwned + InvalidateStats + RefreshIfShown, so every bag event past the debounce repeats the whole thing; looting fires one BAG_UPDATE per stack moved.

**Change.** Do now, exactly as the exp_04 patch (~45 lines replacing EquippedSet/InvalidateOwned/IsOwned in Engine.lua): lazy `OwnedSet()` walking 19 slots + bags 0..NUM_BAG_SLOTS (GetContainerItemID if present, else link:match) + merging a `bankSet`; `Engine.InvalidateOwned()` sets ownedSet=nil; `Engine.IsOwned(id) = OwnedSet()[id] == true`. Add the bank walk (-1, 5..11) under pcall inside OwnedSet and refresh bankSet on BANKFRAME_OPENED / PLAYERBANKSLOTS_CHANGED (register BANKFRAME_OPENED in Core.lua next to BAG_UPDATE). Callers (Eligible, ScopeLeft, Nameplates, ZoneWatch) unchanged. This removes most of the per-event C cost that finding 12 multiplies.

**Expected effect.** Patched copy (ownedSet built per generation from 19 inventory slots + GetContainerNumSlots/GetContainerItemID over bags 0..4), FILTERS=bags SCEN=ui_inst,bags: instances exp=3 D render GetItemCount 19,200 -> 0, replaced by 5 GetContainerNumSlots + 80 GetContainerItemID + 19 GetInventoryItemLink = 104 C calls per bag generation; root render 36,497 -> 0; 20-event 0.1 s loot burst 98,269 GetItemCount -> 2,392 container calls (~23 rebuilds, because InvalidateOwned fires on every event and background pick jobs rebuild between events); 20 events at 0.6 s spacing 671,365 -> 4,160. Eligible/IsOwned call counts and results unchanged. Not measured: GetItemCount(id,true)'s C cost (a scan over ~100-250 slots, est. 2-10 us), which puts today's 19k-36k calls per render at ~40-360 ms and the replacement at <1 ms.

**Risk.** Bank parity is the open question: whether GetItemCount(id,true) and GetContainerItemLink(-1 / 5..11) agree while the bank is closed on 3.3.5 should be verified in game with a one-off /script comparing both over the universe; taking the bank snapshot on BANKFRAME_OPENED / PLAYERBANKSLOTS_CHANGED is correct either way.

Also reported as: pred-09.

#### gap-client-c-costs-05: Sweep faction and class-lock in the warmup; front-enqueue it, placeholder counts
Tags: cpu | Bundle: filter client costs | Impact: high | Effort: small
Files: `Engine.lua:333-348`, `Engine.lua:358-400`, `Engine.lua:401-409`, `Engine.lua:69-80`, `Core.lua:1143-1192`, `Core.lua:1059-1099`

**What happens now.** NeededPredicates (Engine.lua:333-348) lists bind/acc/qside/lvl/zex/qchar. The faction ITEM flag (F_FAC via ANx.FactionAllowed -> ItemFactionOf) is not in it; WarmPredicates calls FactionAllowed(id) only under `if first then` (375), which is a no-op while db.faction == 'both'. So if the Faction filter is switched on after login, WarmIfNeeded (401-409, called from InvalidateStats at 79) tops up qside (ItemQuestSide) but never ItemFactionOf, and the next render resolves every unseeded item's faction by tooltip inline.

**Change.** Do now, but with the two extra pieces the measurement showed are required: (1) NeededPredicates gets `fac = (db.faction or 'both') ~= 'both'` and `cls = db.prestige == true and (db.classFilter or 'all') ~= 'all'`; WarmPredicates gets doFac -> ANx.ItemFactionOf(id) and doCls -> ANx.ClassLock(id) (both behind the 02 GetItemInfo gate, skipped when ItemMinLevel(id) == nil) and sets warmed.fac/warmed.cls; drop the `if first then FactionAllowed(id)` branch. (2) Engine.Enqueue(fn, onDone, tag, front) with `table.insert(Engine.scanJobs, 1, job)` when front, used by WarmIfNeeded. (3) `warmPending = true` in WarmIfNeeded, cleared at the end of WarmPredicates; `Engine.CachesWarm()` returns `cachesWarm and not warmPending`, which the root render (UI.lua:4306) already turns into placeholders; apply the same check in the instances/zones count paths.

**Expected effect.** Baseline: switching the faction filter on after login made the next root render do ItemFactionOf 36,497 with 12,428 SetHyperlink, 12,428 NumLines and 192,086 GetText inline; switching the class filter on: ClassLock 35,166 with 12,854 SetHyperlink, 95,532 GetText and 30,175 GetItemInfo inline. Patched copy v1 (fac/cls added to NeededPredicates and doFac/doCls to WarmPredicates, as proposed): NO change on the first render (still 12,428 inline), and a debug trace showed why: the chip handler renders synchronously right after InvalidateStats, and the enqueued top-up sat BEHIND a 'runs:rec|all|root' ranking job for ~200 frames before WarmPredicates started (the same reason the baseline shows no top-up in +200 frames).

**Risk.** The background sweep scrapes the whole universe (22k here) rather than only the screen's candidates (12.4k), so total work rises while the render freeze disappears; with finding 01 the sweep is PackedFind/flag hits after the first login. Counts show placeholders until the top-up lands (12-22k x 50-300 us = 1-7 s in the client).

#### gap-real-db-shape-02: Stream source rows in the six yes/no predicates instead of building arrays
Tags: load, cpu, memory | Bundle: streaming source rows | Impact: high | Effort: medium
Files: `Engine.lua:475-493`, `Engine.lua:703-718`, `Engine.lua:677-697`, `Engine.lua:654-671`, `Engine.lua:604-616`, `Engine.lua:628-643`

**What happens now.** Defaults are scope='char' and questClass='mine' (Core.lua:161,175), so Engine.Eligible consults ItemQuestCharBlocked for every item (Engine.lua:767-768); NeededPredicates therefore marks qchar as needed (Engine.lua:349) and WarmPredicates calls ItemQuestCharBlocked for every universe item (388). ItemQuestCharBlocked calls IsQuestOnly (708), which calls Engine.Sources(itemId) (480) and then ipairs over the array looking for the first non-quest row (484-487). For a world drop the first row is a creature, so the answer is known after one row, yet ANx.GetSources has already built 1,000-5,000 nine-field tables and Engine.Sources has possibly flushed the whole cache to make room. The same pattern repeats in ItemQuestSide (686), ItemQuestCharBlocked's own loop (710), IsZoneExclusive (661), ItemHasRareSource (607), ItemIsUniqueToZone (633) and IsCraftObtained (943).

**Change.** DO NOW, bundled with findings 11 and 03(2). Rewrite the seven predicates to stream _G.ItemLocGetSourceCount/_G.ItemLocGetSourceAt via a shared SrcApi() guard (patch_gap.py sections 6-9 are usable as written), early-exit on the decisive row, use the memoized ANx.ZoneLower, and take an optional yielding argument that only WarmPredicates passes. Keep the itemFlags write (FSet) as the only side effect so Eligible stays a flag read once warm. This is the single change that most improves the common case (cached login, zone change, nameplates in filter mode) because it turns every cold predicate from 'materialize the item' into one or two C calls.

**Expected effect.** Call sites: 10 Engine.Sources consumers in Engine.lua (lines 480, 531, 607, 633, 661, 686, 710, 809, 943, 1761), of which the seven predicates are 480/607/633/661/686/710/943 (grep). Prototype diff is +393/-131 lines in Engine.lua in total; sections 6-9 alone are roughly 150 new lines across 7 functions in one file, so by the stated scale this is medium, not small, though mechanical. Warmup job per login-with-scan: stock 98-104 frames / 1.4-1.6 s / 474k row tables at 100x1000 (my run and the author's), prototype 37 frames / 486 ms / 0 rows; with the C-like bit library 10 frames / 163 ms (the stock warmup also writes flags with bit ops, it went 98 -> 81 frames). Cached relogin (author's RELOGIN probe, consistent with my data): first zone-list render 2,275 ms / 1.14M rows / 1,986 GetSources on stock vs 138 ms / 0 rows on the prototype.

**Risk.** Semantics preserved by construction: IsQuestOnly = seen-a-row and all rows QUEST (rows with srcType nil skipped exactly as GetSources does); ItemQuestSide/ItemQuestCharBlocked only walk when quest-only (few rows); IsCraftObtained keeps 'no rows -> true'.

**Prototype.** `proto:stream-D`, diff `prototypes/prototype_stream.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: scan-02, gc-02, mem-05.

#### gap-real-db-shape-01: Classify each item once per scan in ZoneData with a packed scan-lifetime memo
Tags: load, cpu, memory | Bundle: streaming source rows | Impact: high | Effort: medium
Files: `Engine.lua:788-864`, `Engine.lua:809`, `Engine.lua:442-466`, `Engine.lua:28`, `Core.lua:1557-1577`, `Engine.lua:1565-1572`

**What happens now.** BuildSummary (Engine.lua:1565-1572) calls Engine.ZoneData(z, true) for all 72 open-world zones; ZoneData walks ANx.ItemsInZone(zone) and calls Engine.Sources(itemId) (809) for every listed item, then makes two passes over the named-field row tables (816-856) just to derive three bits (quest/world/vendor) and the quest/vendor index rows. A BoE world drop is listed in many zones (every zone whose creatures carry it), so its rows are re-materialized once per listing. Engine.Sources caches arrays only while srcCacheRows + rows <= SRC_ROW_BUDGET (60,000, Engine.lua:28, 454-457) and otherwise flushes the WHOLE cache to {}; one zone's working set with 100 world drops x 1,000 rows is 100,000 rows, so under the heavy tail the cache never holds a zone and every (zone, world drop) pair is a fresh ANx.GetSources call building one 9-field table per row (Core.lua:1562-1573).

**Change.** DO NOW (first functional change after finding 09 ships). Implement the prototype's one-walk-per-item memo (patch_gap.py sections 1, 2, 4, 10) but replace the m[zoneLower] hash keys with a packed layout so it is bounded by universe size: m = { d1..d5 (base-8 digits, 17 per double, ordinal = index of the zone in ANx.Zones), fallbackBits, recognized, Q = flat {objId|false, name, zoneLower,...} capped at 256 rows, V = same }. Set bit b for ordinal o with: k = floor(o/17)+1; p = POW8[o%17]; cur = floor(m[k]/p) % 8; if floor(cur/b) % 2 == 0 then m[k] = m[k] + b*p end (exact in doubles, no bit library). ZoneData reads bits = floor(m[k]/p) % 8, applies the same nil/recognized/fallback rule, appends to zc.quest/world/vendor in universe order and indexes Q/V rows filtered by zoneLower (fallback: capped, finding 07). Create the memo only when inCoroutine, store it in a local dropped in InvalidateAll and the pump's queue-drained branch, and never flush it mid-scan (a flush reintroduces the per-listing re-walks). Fold finding 05's row yields into BuildZoneMemo.

**Expected effect.** Re-ran harness_gapx at WDROP=100 WROWS=1000 ZNAMES=1 (files scratch/assess/confirm_stock_w100.txt and confirm_gap_w100.txt): stock summary jobs 507 frames / 16.7 s harness CPU / 8.30M row tables built, peak 105.6 MB; prototype (exp_gap, findings 01+02+04+05 together) 300 frames / 4.3 s / 0 rows, peak 41.5 MB. CALIBRATION: the harness bit library is pure Lua (bit.bor measured 3.64 us/call) and BuildZoneMemo calls it up to twice per row, which is harness-only overhead (the client's LuaBitOp is C). With a lookup-table bit library (0.40 us/op, verified against the reference on 20k random pairs; scratch/assess/harness_fastbit.py) stock is unchanged (501 frames / 16.5 s, it does no bit ops per row) while the prototype drops to 87 frames / 1.1 s, max summary frame 16 ms, warmup 10 frames / 163 ms (fastbit_stock_w100.txt, fastbit_gap_w100.txt).

**Risk.** Equivalence is the author's equiv_gap (summaries and all 72 zoneCache entries identical in English mode; only fallback-mode questList/vendorByName counts differ, by design of finding 07's cap). The hash-keyed memo as prototyped is unbounded in memory: on a real tail of 5-10k world drops naming 40-70 zones it would be 20-40 MB transient on the client (hash parts of 64-128 nodes per item), which violates the handoff rule even though it is scan-life...

**Prototype.** `proto:stream-A`, diff `prototypes/prototype_stream.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: scan-01, gc-01, scan-03.

#### gap-real-db-shape-04: Replace BestSource Sources walks with a per-item zone-best index returning objId
Tags: cpu, memory | Bundle: streaming source rows | Impact: high | Effort: medium
Files: `Engine.lua:527-557`, `Engine.lua:1258-1281`, `Engine.lua:1283-1308`, `UI.lua:2674-2676`, `UI.lua:3182`, `Engine.lua:1991-2010`

**What happens now.** builders['zones'] in W mode calls Engine.StatsWithBest(zc.world, 'zw:'..zone, z.name, WORLD_DROP_SRC) for every zone of the expansion (UI.lua:2674-2676); StatsWithBest calls Engine.BestSource for every eligible unattuned item (1268) and BestSource does ipairs over Engine.Sources(itemId) (531), i.e. the full row array. The same world drop is in every zone's list, so a 40-zone list walks each world drop 40 times (and materializes it 40 times when the zone's working set exceeds SRC_ROW_BUDGET). statsCache keys the result per zone but Engine.InvalidateStats (62-77) clears statsCache, clearChanceCache and pickCache, and it is called 2 s after every attune completion (MarkAttuneDirty, Core.lua:1786-1794), on every filter chip, on level-up, on bag events with hideInBags, and by WatchRefreshDone, so the whole walk recurs.

**Change.** DO NOW, after 01/02. Build the index lazily in BestSource with one streamed pass per item: q = {} of quads (zoneOrd, srcType or srcType+100 when a quest row is blocked, chance, rowIndex), one quad per (zone, type) keeping the higher chance and, on ties, the lower rowIndex; also a quad with zoneOrd = -1 for 'anywhere'. BestSource(item, zone, filter): scan quads for ord(zone) then for -1, usable (type < 100) beats blocked, then higher chance, then lower rowIndex; fetch the winner's row with ItemLocGetSourceAt(item, rowIndex) for objName/objId/zoneName and return chance, name, type, restricted, zoneName, objId. Bound by items (6,000) and slots (500k, re-sized from /an srcstats), flush wholesale on overflow. Route ItemBestDropChance through it (finding 08). This subsumes finding 10 and makes the srcCache cold for every hot path (finding 06).

**Expected effect.** BestSource callers: 10 sites (Engine.lua:1268 StatsWithBest, 1291 ItemRows, 1772, 1995 ClearChance; Tooltip.lua:20; UI.lua:3616/3633/4267/4796/4903). First Classic World-Drops zone list after the scan: stock 720 ms / 53,874 rows built (my run; author 865 ms), prototype 105 ms / 0 rows, 58 ms with the C-like bit library; mismatch mode 2,685 -> 520 ms; 500x2000 37.5 s -> 0.7 s; RankZoneRuns 5,202 ms / 1.70M rows -> 1,264 ms / 0 rows with the same top result; 0 mismatches over 19,224 BestSource calls (author's equivalence). MEMORY, measured directly (mb_memo.py, mb_packed.py): the prototype's hash-of-6-slot-lists costs 9.2 KB per 40-zone single-type world drop on 64-bit and 19.7 KB per synthetic 72-zone/5-type heavy item; the estimator's 2.9 MB for 371 items (7.8 KB/item) is therefore roughly right only because it charges table headers.

**Risk.** Index memory scales with eligible world drops x zones named x source types; if one render's working set exceeds the slot cap the index flushes mid-render and degrades to per-zone re-walks (author measured 18.9 s at a 400k cap with 11-slot records; 695 ms at 1M with 6-slot). Flat quads hold ~2.2x more items per slot, so a 500k cap (8 MB client) covers ~3,000 40-zone world drops.

**Prototype.** `proto:bestsource`, diff `prototypes/proto_bestsource.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: gc-03, frame-06, pred-03, micro-11.

#### gap-client-c-costs-03: Rate-limit item-cache requests through a queue with a drain hook and flag retry
Tags: cpu | Bundle: filter client costs | Impact: high | Effort: medium
Files: `Core.lua:533-546`, `Core.lua:479-510`, `Core.lua:276-279`, `UI.lua:3215`, `UI.lua:3632`, `UI.lua:4260`

**What happens now.** ANx.RequestItemCache (Core.lua:538-546) fires cacheTip:SetHyperlink immediately, once per id per session. ANx.GetItemDisplay (479-510) calls it for every unresolved id, and the view builders call GetItemDisplay for EVERY row they build, not just the 12 visible ones (UI.lua:3215 items, 3632 search, 2340 materials, 4260/4791/4898 picks and side pane). A universe-wide list on a fresh client cache therefore emits thousands of item queries in a single frame with no pacing, and because 3.3.5 has no GET_ITEM_INFO_RECEIVED nothing re-renders when the replies land: rows keep showing 'Item #id' until the user clicks something.

**Change.** Do now, together with 02 and 08. In Core.lua: `local cacheQueue, cacheQueued, draining = {}, {}, false`; RequestItemCache: `if cacheRequested[id] or cacheQueued[id] then return end; cacheQueued[id] = true; cacheQueue[#cacheQueue+1] = id; if not draining then draining = true; ANx.After(0, Drain) end`. Drain: pop up to CACHE_BATCH ids from the FRONT, cacheRequested[id]=true, cacheTip:SetHyperlink each; if the queue is non-empty ANx.After(0.1, Drain) else draining=false and ANx.After(0.5, OnCacheDrained). OnCacheDrained: pairs(itemFlags) clearing F_BIND==1 (f - 1) and F_MINLVL==1 (f - 32768) counting cleared; ANx.BumpNameMiss(); if cleared > 0 and (ANx.LevelGate('rec') or ANx.LevelGate('btn') or bindFilter ~= 'both') then Engine.InvalidateStats() end; ANx.UI.RefreshIfShown(). PaintVisibleRows inserts the <=12 visible ids at index 1. With 07(b) the per-render fan-out drops to the visible rows.

**Expected effect.** Harness, CACHEPCT=30, fresh scenario: pushing the 15,969-id items view (8,518 rows built) emitted RequestItemCache 5,965 = 5,965 uncached cacheTip SetHyperlink = 5,965 server queries in ONE frame; over the next 60 frames all 5,965 resolved and UI.Render ran 0 times, so 'Item #id' rows stayed until a manual re-render (which then paid 8,221 + 8,221 GetItemInfo-family calls). With the faction filter and a cold cache the warmup queued 16,661 ids in one sweep. Drain-hook cost: one pairs() pass over 20,000 itemFlags entries clearing F_BIND==1 / F_MINLVL==1 with arithmetic field extraction = 2.0 ms on this box (~5 ms client). Not measured: client/server packet handling; the burst of 6k-17k CMSG_ITEM_QUERY_SINGLE in one frame is the thing a TrinityCore-style anti-DOS policy can kick for.

**Risk.** The proposed 2,000-id cap with drop-oldest is too small for the 16k-id cold warmup (14k would be dropped and re-queued by every later render); hold the queue as a plain numeric array (16k numbers = ~64 KB on 32-bit, transient) or cap at ~8k. 20 ids per 0.1 s = 200/s drains 16k ids in 80 s; make CACHE_BATCH a local constant and start at 50.

#### gap-client-c-costs-01: Persist bind/faction/class-lock scrape results in AttuneNextDB as packed strings
Tags: load, cpu | Bundle: filter client costs | Impact: high | Effort: medium
Files: `Core.lua:857-862`, `Core.lua:867-910`, `Core.lua:1059-1099`, `Core.lua:1143-1192`, `Core.lua:396-450`, `Core.lua:612-637`

**What happens now.** ANx.BindType (Core.lua:867-910), ANx.ClassLock (1059-1099) and ANx.ItemFactionOf (1143-1192) each resolve an item by bindTip/factionTip:ClearLines + SetHyperlink('item:'..id) + NumLines + per-line GetText (BindType reads <=6 left lines; ItemFactionOf reads EVERY line, left AND right, and runs 4 gsub per string in clean(); ClassLock reads every left line). The static seeds cover only 5,401 bind ids (Data_ItemBind) and 3,624 faction ids (Data_Faction) of a ~20-25k universe; there is no class-lock seed at all. The results go only into the session-scoped itemFlags table (Core.lua:396-450) and the classLockCache hash (1059), neither of which is saved, so WarmPredicates (Engine.lua:358-400, doBind at 382-383 and FactionAllowed at 375) redoes the scrape of every unseeded item at every login, and ForceRescan (Engine.lua:226-233) wipes them again.

**Change.** Do now, simplified: instead of adding Saved-string probes to BindType/ItemFactionOf/ClassLock, decode the blob EAGERLY into itemFlags at ADDON_LOADED right after ApplyDefaults (6.7 ms here / ~20 ms client for 19k records: for each 5-char record FlagSet(id, F_BIND, 7, code) / FlagSet(id, F_FAC, 3, code)). The lookups then need no code change, WarmPredicates' doBind/doFac become flag hits, and the memory is the same itemFlags the warmup builds anyway. Export = one pairs() walk over itemFlags using arithmetic (f % 8, floor(f/8) % 4): emit bind codes >= 2 for every id < 65536 (skip the bind seed exclusion: +27 KB, saves ~110 ms), emit faction code 1 unconditionally and codes 2/3 only when PackedFind(ANx.ItemFactionPacked, id, 1) is nil; collect ids into arrays, table.sort, string.format('%04X%X'), table.concat. Class locks: pairs(classLockCache) tables only, '%04X%03X' mask over ANx.CLASS_ORDER, decoded back into classLockCache at import. Store as ANx.db.tipCache = {ver, locale, rev, bind, fac, cls}; run at PLAYER_LOGOUT next to ExportStatusCache.

**Expected effect.** Harness login (warm client cache, bind+faction filters saved, NITEMS=20000 ZONEN=600): the warmup issued SetHyperlink 40,431 (18,573 on BindTip + 21,858 on FactionTip), GetText 343,794, and took 427 frames (584..1011) vs 160-170 frames with no filters, even with free stub tooltips. After the sweep itemFlags held 24,357 entries: bind known for all 24,357 (18,956 NOT answered by the static seed), faction known for 20,750 (18,632 unseeded, nearly all code 1 = neutral). Seeds confirmed by counting the packed strings: Data_ItemBind 5,401 records; Data_Faction ItemFactionPacked 3,624 (+776 vendor records). Blob sizes: bind 94,780 B (unseeded only) or 121,785 B (all known ids), faction 93,160 B.

**Risk.** Bind/faction strings are locale-dependent and item properties can change with the server's item DB, so key the blob on GetLocale(), ItemLocIsLoaded() and ANx.VERSION (every addon update discards it, acceptable). Ids >= 65536 cannot be packed in 4 hex chars (fall back to the live scrape). Never export bind code 1 (retry) or faction code 0; neutral (code 1) MUST be exported, it is the bulk of the saving.

#### gap-two-addons-pacing-01: Let AttuneNext-Simple adopt the host's structure by reference instead of rescanning
Tags: load, cpu, memory | Bundle: two addons | Impact: high | Effort: medium
Files: `AttuneNext-Simple/Engine.lua:1`, `AttuneNext-Simple/Core.lua:1624`, `AttuneNext-Simple/Core.lua:1639`, `AttuneNext-Simple/Core.lua:1662`, `AttuneNext-Simple/Core.lua:1722`, `AttuneNext-Simple/Core.lua:415`

**What happens now.** The real sister repo (speedyrulz/AttuneNext-Simple v1.0.1, cloned to /home/user/attunenext-simple) carries a byte-for-byte copy of this repo's v3.6.2 Engine.lua (diff: 36 lines, all the hideInBags gate) and a Core.lua that differs only in names, removed events and slash commands (275 lines). Both addons therefore run AttuneNextSimple_OnDataReady / AttuneNext_OnDataReady from identical 1 s GetCustomGameData(41,0) polls in the same second, both enqueue GetSummary(1..3), both walk every instance and zone through ItemsInZone + GetSources, both run WarmPredicates (which, with the default questClass='mine', calls Engine.ItemQuestCharBlocked -> Engine.Sources for every item in the universe), and both keep a private zoneCache, instDiffCache, summaryCache, itemFlags, srcCache and a ~2 MB structCache SavedVariable. Nothing is shared except _G.OnCustomGameData and the tooltip frame names.

**Change.** Do now; it is the only change in this area that matters for pair users and it makes 06/07/09/10 almost free. Host Engine.lua (after ImportCache): `function Engine.ShareStructure() return { inst = instDiffCache, zones = zoneCache, summaries = summaryCache, resolved = instResolved, profs = profCache, flagsFormat = ANx.FLAGS_FORMAT } end` and `Engine.AdoptStructure(t)` assigning those locals, `Engine.universeCache = nil`, BumpRev(); in the pump's queue-empty branch (Engine.lua:294-310) after the warmup enqueue: `for _, fn in ipairs(_G.AttuneNextStructureListeners or {}) do pcall(fn) end` (fire again from the warmup job's onDone so listeners see warmed flags).

**Expected effect.** Pair baseline re-run today (gap2/harness_pace.py, fps60 slow1, NITEMS=20000 ZONEN=600 HEAVY=200): peak 265 MB, 34.1 ms addon time per scan frame (67% of a 60 fps frame, 19.7 fps during the scan), 140.1 MB resident after full GC, GetSources 66,609 host + 66,209 Simple, both SavedVariables estimators 57 MB (each holds a zoneCache reference). Alone: peak 144 MB, 16.3 ms/frame, 72.5 MB resident. Prior-lens experiments I verified in gap2/: exp_borrow_only (Simple adopts the host structure, nothing else) pair scan 427 frames / 14.1 s (alone 413 / 13.5), peak 145 MB, Simple GetSources = 0, resident 74.2 MB, AttuneNextSimpleDB 424 KB; matrix_borrow_pair (adopt + pacing): peak 141 MB at 60 fps, 133 MB at 30 fps/slow 2.5, Simple GetSources = 0.

**Risk.** (1) Shared ItemFlags: finding 08's tooltip-name collision means a wrong BOP/BOE or faction scraped by either addon would now be cached for BOTH; fix 08 first and guard with ANx.FLAGS_FORMAT. (2) Simple's warmup is only free when the host warmed the same predicates: with differing filters (e.g.

### Tier 2: Worth doing (32 items)

Medium impact, or high impact that depends on a Tier 1 change.

#### gap-telemetry-and-harness-fidelity-04: Add /an perf slowest ANx.After callback by name
Tags: cpu | Bundle: instrumentation | Impact: medium | Effort: small
Files: `Core.lua:260-279`, `Core.lua:1625`, `Core.lua:1649-1657`, `Core.lua:1720-1761`

**What happens now.** ANx.After callbacks run inline in timerFrame's OnUpdate (29 call sites in 8 files) with no timing, and the 3.3.5 client has no debug.getinfo to name a slow one afterwards. The patch gives ANx.After an optional name argument, times each callback with two debugprofilestop reads (a handful of callbacks per second at most) into afterN/afterMs/afterMaxMs/afterMaxName, and names the nine login-path sites (login-poll, WatchRefreshDone, SnapshotAltCan, TrimMerchantDb, GoalHudUpdate, ScanMerchant, ScanSpeedAuras, bags-refresh); unnamed sites report 'anon'.

**Change.** Do now, with 01. Apply the timer hunks and additionally name ZoneWatch.lua:328 ('ZoneWatchNow'), Nameplates.lua:268/679 ('RebuildZoneIndex'), AltCache.lua:83 ('alt-step') and UI.lua:768/775 ('search-debounce'), since ZoneWatchNow is already the second-slowest callback headless and scales with the real DB's row counts. Consider keeping a small per-name {n,total,max} table instead of a single max: 28 sites x 3 numbers is negligible memory and gives the author the whole table in one reading instead of the single worst.

**Expected effect.** grep: 28 ANx.After call sites in 8 files (the finding's '29' counts the definition line). Patched runs print 'timers: 35 callbacks, 101ms, slowest 69.8ms (WatchRefreshDone)' in fresh-scan and 'slowest 74.4ms (WatchRefreshDone)' in mismatch mode, matching the harness's own per-site table (Core.lua:1615 max 85-100 ms with the fast bit stub, 207 ms with the stock stub). Overhead: two debugprofilestop reads per callback, 35 callbacks in a 1,500-frame session. In the prototype where finding 06 is applied the line becomes 'slowest 19.4ms (anon)': that anonymous site is ZoneWatch.lua:328 (ANx.ZoneWatchNow), 17-43 ms per run in lupa and 240 ms in heavy-tail, i.e. the next hitch this telemetry would locate, and it is unnamed in the diff.

**Risk.** None functionally; the third argument is optional so every unnamed site keeps working and reports 'anon'. afterMaxName is the max of the session, so a single slow callback early on hides later ones until '/an perf reset'.

#### gap-telemetry-and-harness-fidelity-05: Add /an perf tooltip-scrape, cache-request and GetItemCount counters
Tags: cpu | Bundle: instrumentation | Impact: medium | Effort: small
Files: `Core.lua:538-547`, `Core.lua:884-893`, `Core.lua:1066-1073`, `Core.lua:1160-1166`, `Engine.lua:748-749`, `Engine.lua:1143-1144`

**What happens now.** Each bind/class/faction scrape is a SetHyperlink (a server query for an uncached item) plus NumLines and up to six GetText calls; RequestItemCache is another SetHyperlink; the hideInBags gate calls GetItemCount per eligible item and HaveCount per material. The harness stubs all of them free and resolves every item, so the warmup's scrape cost, the uncached-item share (NumLines==0 bakes 'unknown' for the session or retries) and the hideInBags cost are unknown. The patch adds tipBind/tipClass/tipFac/tipEmpty/cacheReq/ownedCalls increments at the existing call sites (ownedCalls covers both IsOwned and HaveCount).

**Change.** Do now, with 01 (trivial, and it is the only way to price the three client-only costs). Apply the scraper/RequestItemCache/IsOwned/HaveCount hunks and the 'client:' printer line. For the harness side, add one step to the UI scenario's push list that sets db.bindFilter (and later hideInBags) and re-runs WarmPredicates so tipBind/tipEmpty are non-zero headless and the cost model (finding 12) has something to charge.

**Expected effect.** Counters verified in the diff at the existing call sites (RequestItemCache, BindType/class/faction scrapers, IsOwned and HaveCount). Smoke run of the patched copy with SCENARIO=ui CACHEPCT=60 USEC_HYPERLINK=20 USEC_ITEMCOUNT=5: the harness modelled 133 uncached SetHyperlink (all from RequestItemCache during list renders) and 49,958 nil GetItemInfo across the renders, but the addon's 'client:' line read 'tooltip scans bind 0 / class 0 / faction 0 (empty 0), cache requests 0, GetItemCount 0' because the UI scenario never toggles the bind/faction/class/hideInBags filters and the warmup is filter-aware; headless the scrapers simply do not run with default filters. Overhead: one increment per scrape, nothing measurable.

**Risk.** cacheReq printed 0 even though 133 SetHyperlink were modelled: the harness counts the C call while the addon counts RequestItemCache entries, so check whether the harness's SetHyperlink count comes from a different caller (the Tooltip hook or the scrapers' cacheTip) before trusting the two side by side.

#### gap-telemetry-and-harness-fidelity-11: Keep the fixed frame stub; use per-render C-call counts as the regression signal
Tags: cpu | Bundle: instrumentation | Impact: medium | Effort: small
Files: `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/tools/harness_orig.py:87-116`, `UI.lua:489`, `UI.lua:507-521`, `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/stubcrash.py`

**What happens now.** FrameMT.__index's last line returns a no-op function for any key, so addon-owned fields like b.anxPlate (UI.lua:512) or rows tables are truthy before assignment, `for i = 1, f:GetNumRegions()` gets nil (489), SetHyperlink/NumLines are free and GetText returns ''. The consolidated stub returns nil for any key that is not CapitalCase (WoW methods are), gives GetNumRegions/GetNumChildren 0, GetRegions/GetChildren nil, defines FauxScrollFrame_Update/GetOffset and GameFontNormalHuge, and models SetHyperlink/NumLines/GetText/GetStringWidth.

**Change.** Do now (it is the default in the consolidated harness; FRAMESTUB=stock reproduces). Extend the UI scenario's push list as screens change and treat the printed per-render C-call counts (GetItemInfo, GetItemInfo_nil, GetStringWidth, SetHyperlink) as the regression signal, since they are deterministic while ms are not.

**Expected effect.** Re-ran stubcrash.py: FIX=0 fails with "UI.lua:489: 'for' limit must be a number" (f:GetNumRegions() returns a no-op function under the stock __index), FIX=1 gives UI.Show(true) true and Render true. With the fixed stub the ui scenario rendered every screen and reproduced the pred lens within its spread: items (instance, 600 ids) 13.0 ms / 1.4 MB (pred 12.4), search 'item1' 178 ms / 5.7 MB with 28,426 GetItemInfo of which 8,714 nil (pred 134-190), RemainingReport 349 ms (pred 425), PaintVisibleRows 0.2 ms, 27-28 GetStringWidth per list render, UI.Show root 553 ms on the stock bit stub (145 ms fast).

**Risk.** A frame field the addon reads before assigning under a CapitalCase name would still receive a no-op function; none surfaced in the UI/pred runs. GetStringWidth returns a constant 50 so FitText loops are not realistic until USEC_STRWIDTH and a width model are set.

#### gap-telemetry-and-harness-fidelity-12: Calibrate harness client-call cost models from the tf-05 in-game reading
Tags: cpu | Bundle: instrumentation | Impact: medium | Effort: small
Files: `/tmp/claude-0/-home-user-AttuneNext/220b827c-c7aa-520c-bfdc-f183263ba2f0/scratchpad/gap_telemetry/harness.py`, `Core.lua:884-905`, `Core.lua:1160-1180`, `Engine.lua:748-749`, `UI.lua`

**What happens now.** Headless, the warmup's bind/faction/class scrapes, RequestItemCache, the hideInBags GetItemCount gate and FitText's GetStringWidth loops cost nothing and every item resolves, so the cc lens's thousands of calls per filter toggle have no price and the 'uncached item' branches (NumLines==0 baking 'unknown', retry when GetItemInfo resolves) never execute. harness.py charges USEC_HYPERLINK/USEC_ITEMCOUNT/USEC_STRWIDTH microseconds per call (busy-wait, so SLOW scales them like addon code), fills tooltip lines keyed by item id so the three scrapers parse real bind/class/'Faction:' lines, models the client cache with CACHEPCT (GetItemInfo nil and 0-line tooltips for the rest, resolving QUERY_DELAY later), an OWNED set for GetItemCount, counts every modelled call per phase and per render, and keeps ItemLocGetSourceAt's per-call string allocation as is.

**Change.** Do later, after one in-game /an perf with the bind filter on (finding 05): set USEC_HYPERLINK = pumpMs delta / tipBind delta, CACHEPCT = 100 x (1 - tipEmpty/tipBind), USEC_ITEMCOUNT from a hideInBags render, then rerun SCENARIO=ui and quote the values with the numbers. Before that, add a push step to the UI scenario that enables db.bindFilter and re-runs WarmPredicates so the scrape path is charged headless; otherwise USEC_HYPERLINK only prices RequestItemCache.

**Expected effect.** Smoke run SCENARIO=ui CACHEPCT=60 USEC_HYPERLINK=20 USEC_ITEMCOUNT=5 on the patched copy: the model executed (header prints the charges; 'modelled C calls after UI: GetItemInfo=62013 GetItemInfo_nil=49958 GetStringWidth=250 SetHyperlink=133 SetHyperlink_uncached=133 (charged 3 ms)'); items render SetHyperlink=127 uncached, search 'item1' 36,553 GetItemInfo of which 24,702 nil (63 ms fast bit), search re-render 24,702 nil lookups (35 ms), so the uncached-item branches now execute headless. The three tooltip scrapers were not exercised (tipBind/tipClass/tipFac = 0) because the UI scenario leaves the bind/faction/class filters off and the warmup is filter-aware; the 133 charged calls are RequestItemCache only. Absolute per-call costs are not measured: they are exactly the unknowns findings 05's in-game counters supply.

**Risk.** Until calibrated the charges are 0 (stock behaviour) and every number stays comparable. Busy-wait charges are CPU time and scale with SLOW like addon code, which is right for a C call but ignores the client's asynchronous server round-trip for uncached items (QUERY_DELAY models only the resolve time). The tooltip line layout is a model of the English client, so the scrapers' pattern matches are not proof the real strings parse.

#### micro-01: Drop the three never-read fields from GetSources rows (9 -> 6 fields)
Tags: memory, cpu | Bundle: streaming source rows | Impact: medium | Effort: small
Files: `Core.lua:1557-1577`, `Core.lua:1563`, `Core.lua:1565-1573`, `Core.lua:1852`, `Engine.lua:442-462`, `Engine.lua:28`

**What happens now.** ANx.GetSources builds one table per source row with 9 named fields: srcType, objType, objId, chance, perMille, objName, zoneName, zoneLower, spawned. Lua 5.1 sizes a hash part to the next power of two, so 9 fields need a 16-node hash; on the 32-bit client that is 16 x 28 B + 32 B header = ~480 B per row. `perMille` and `spawned` are never read anywhere (grep: only written at Core.lua:1569/1572); `objType` is read only by the `/an src` debug dump (Core.lua:1852, with an `or -1` fallback). Dropping those three leaves 6 fields = 8 nodes = ~256 B per row (-47%), with zero consumer changes. The row builder also looks up `_G.ItemLocGetSourceAt` through the global table on every row and uses `out[#out + 1]`.

**Change.** Do now (independent, ~12 lines, zero behavioural risk) and keep it when the streaming prototypes land: it still cuts every remaining row build (sources screen, QuestArrow.ArrowToItem, the srcCache fast paths) by 44% in bytes and ~2.5x in build time. Sketch (Core.lua:1557-1577): `local out, k = {}, 0; local getAt = _G.ItemLocGetSourceAt; for i = 1, n do local srcType, _, objId, chance, _, objName, zoneName = getAt(itemId, i); if srcType ~= nil then k = k + 1; out[k] = { srcType = srcType, objId = objId, chance = chance or 0, objName = objName or "?", zoneName = zoneName or "", zoneLower = ZoneLower(zoneName) } end end; return out`; in the `/an src` branch (Core.lua:1842-1853) fetch objType with `select(2, _G.ItemLocGetSourceAt(id, i))` or print only srcType/objId/chance/obj/zone; update the comment at 1542. Apply the identical change to attunenext-simple/Core.lua.

**Expected effect.** harness_orig.py (NOSV=1 NITEMS=20000 ZONEN=600 HEAVY=200 READY_AT=5 FRAMES=1500): stock /home/user/AttuneNext `scan finished at frame 734`, `peak 141257 KB`, `GetSources calls: 66609 ... rows built: 1357213`; tools/exp_rows (6-field row only) `scan finished at frame 674`, `peak 108750 KB`, same 66609 calls / 1357213 rows (-8% scan frames, -23% peak; stock harness = localized fallback mode, 64-bit). lupa.lua51 micro (skp/mb_rows.py, 200k rows, GC stopped): `9 named (stock) 138.3 MB 122.9 ms 725 B/row`, `6 named 77.2 MB 43.5 ms 405 B/row` (-44% bytes, -65% build time), `6-slot array 34.5 MB 27.1 ms 181 B/row`; 8/7/6/5 named all 405 B (the 16->8 node step). Client scaling (32-bit Node 32 B, header 32 B): ~544 -> ~288 B/row, same -47%. Not measured: the real DB's rows per item (unknown; heavy tail makes the absolute larger).

**Risk.** No consumer reads the dropped fields, so behaviour is unchanged; the `/an src` dump must either read objType via _G.ItemLocGetSourceAt(id, i) itself or drop it from the format string. If prototype D (EachSourceRow) is applied too, its srcCache fast path (prototype_stream.diff lines 37-58) passes s.objType/s.perMille/s.spawned to the callback: those become nil (no callback uses them) - drop them from the callback signature to keep both paths ident...

Also reported as: scan-10.

#### gap-real-db-shape-05: Yield by rows (ROW_YIELD) inside the streamed walks; ships inside db-01/db-02
Tags: cpu | Bundle: streaming source rows | Impact: medium | Effort: small
Files: `Engine.lua:250-257`, `Engine.lua:273-281`, `Engine.lua:800`, `Engine.lua:1568-1574`

**What happens now.** Engine.MaybeYield (250-257) yields on every 25th call; ZoneData calls it once per item (800) before Engine.Sources, and BuildSummary once per zone (1574). The pump (273-281) checks Clock() - start < BUDGET_MS only between resumes, so a resume that happens to cover 25 world drops of 1,000-4,000 rows each runs 25,000-100,000 row-table builds uninterrupted. The pacing lens's time-sliced MaybeYield bounds the gap between items but cannot interrupt a single item's GetSources loop, which for a 4,000-row item is one un-yieldable allocation burst.

**Change.** Fold into 01 and 02 (patch_gap.py section 3 plus the i % ROW_YIELD lines): Engine.YieldRows(n) accumulator that yields after ROW_YIELD rows across small items and resets yieldCheck, and 'if yielding and i % ROW_YIELD == 0 then Engine.YieldNow() end' inside BuildZoneMemo and the warmup predicates. Optionally replace the fixed count with a Clock() check every 256 rows against a 2 ms slice so the granularity self-tunes on the client (debugprofilestop is cheap). Do not ship as a separate change.

**Expected effect.** Stock summary frames: max 97-141 ms with 85,900-100,900-row frames at 100x1000 (my run and the author's), 201 ms at 30x3000, 223 ms at 500x2000, because MaybeYield counts items (Engine.lua:250-257) and the pump only checks its 10 ms budget between resumes (273-281). Prototype with ROW_YIELD=1000 inside BuildZoneMemo plus YieldRows: max summary frame 33 ms at 100x1000 and 16 ms with the C-like bit library (the remaining tall frames are the 2048 KB GC step and the professions slice). Client estimate for one 1,000-row chunk: 1,000 x (C call ~0.5 us + ~0.3 us Lua) x 2.5 ~ 2 ms, so ROW_YIELD=1000 sits comfortably inside the 10 ms budget.

**Risk.** A yield inside any streamed loop is only legal when the caller is the job coroutine and not inside pcall/table.sort/metamethods; the explicit 'yielding' flag pattern of the prototype is the right guard. ItemBestDropChance (sort comparator) and BestSource (called from StatsWithBest inline) must never yield. Slightly more coroutine switches per scan, negligible at 1,000-row granularity.

#### gap-real-db-shape-11: Factor Engine.EnsureWarm; call it after a validated ImportCache on cached logins
Tags: cpu, load | Bundle: streaming source rows | Impact: medium | Effort: small
Files: `Engine.lua:299-311`, `Engine.lua:403-411`, `Engine.lua:1617-1622`, `Core.lua:1632-1660`, `Engine.lua:86-106`

**What happens now.** WarmPredicates is enqueued only in the pump's queue-drained branch (Engine.lua:299-311, after some job finishes) or by WarmIfNeeded, which returns immediately while cachesWarm is false (404). AttuneNext_OnDataReady (Core.lua:1632-1660) calls Engine.InvalidateAll (which sets cachesWarm = false and clears the Engine flag fields, 86-106), then ImportCache, then GetSummary x3; with a valid structCache GetSummary returns the ready summaries (1617-1619) and enqueues nothing, so the pump never runs and the warmup never starts until a pick job (UI open or button) drains. Until then Eligible computes ItemQuestCharBlocked cold inline (full array builds on stock) in ZoneWatch (every zone change / attune completion), GoalHud (InstanceClears at +6 s), nameplates in respect-filters mode, tooltips' Eligible-free path excepted, and the first zone list.

**Change.** Do now with finding 02: at the end of AttuneNext_OnDataReady, after the GetSummary loop, add 'if ANx.Engine.scanJobs and #ANx.Engine.scanJobs == 0 and (not ANx.Engine.CachesWarm() or ANx.Engine.WarmupIncomplete()) then ANx.Engine.Enqueue(ANx.Engine.WarmPredicates, function() if ANx.UI and ANx.UI.RefreshIfShown then ANx.UI.RefreshIfShown() end end, "warmup") end' (3-5 lines). Equivalent alternative: enqueue it from Engine.ImportCache when it returns true. Combined with 03(2) this means no consumer ever computes predicates cold inline on a cached login.

**Expected effect.** Enqueue call sites by grep: Engine.lua:304 (queue-drained branch), 408 (WarmIfNeeded, which returns while cachesWarm is false), 1019, 1621 (GetSummary, only when a summary is not ready), 1959 (PickAsync), 2256 (RankRunsAsync), UI.lua:2649 (zones builder, only for unready zones). AttuneNext_OnDataReady (Core.lua:1632-1660) calls InvalidateAll then ImportCache then GetSummary x3 and never enqueues directly; WatchRefreshDone's InvalidateStats -> WarmIfNeeded is gated off by cachesWarm=false. Author's RELOGIN probe: zero busy frames and no job tags for 200 frames after a cached data-ready, then the first zone list costs 2,275 ms / 1.14M rows on stock (vs 865 ms with warm flags) and 138 ms / 0 rows on the prototype.

**Risk.** Running the warmup at every login was the intent of the v3.6.0 filter-aware design; the 'warmup' tag prevents double enqueue. The job also calls Engine.Universe() (a 12-13 ms un-yieldable slice) and FlushSources. Without finding 02 the per-login background cost is non-trivial on a heavy tail and churns the 60k-row cache, so order the two together.

Also reported as: load-01, scan-07.

#### gap-telemetry-and-harness-fidelity-07: One change with db-11: enqueue warmup and button pick on cached login; port to Simple
Tags: cpu, load | Bundle: streaming source rows | Impact: medium | Effort: small
Files: `Engine.lua:286-311`, `Engine.lua:404-411`, `Core.lua:1641-1649`, `Engine.lua:1615-1617`, `UI.lua:4303-4306`

**What happens now.** On every login after the first (same addon version and loot-DB version), AttuneNext_OnDataReady calls InvalidateAll (cachesWarm=false, scanJobs={}), ImportCache succeeds, and GetSummary(1..3) returns the imported summaries without enqueueing anything (Engine.lua:1615-1616). The only code that enqueues WarmPredicates and PickAsync(nil,'btn') is the pump's end-of-queue branch (Engine.lua:302-311), which never runs because no job was queued and pumpFrame stays hidden; Engine.WarmIfNeeded returns immediately while cachesWarm is false (406). UI.lua:4306 blanks the home cards while not CachesWarm(). So the first window open pays a PickAsync job (cards say 'Finding a pick...'), whose completion finally enqueues the full-universe warmup, during which the cards show placeholders; any list opened before that computes cold predicates inline, exactly what the warmup was added to prevent.

**Change.** Do now. Engine.lua: add function Engine.EnsureWarm() { if not Engine.SummariesReady() then return end; if not cachesWarm or Engine.WarmupIncomplete() then Enqueue(WarmPredicates, RefreshIfShown callback, 'warmup') end; if Engine.PickCached(nil,'btn') == nil then Engine.PickAsync(nil,'btn') end } and replace the pump's end-of-queue block with a call to it. Core.lua AttuneNext_OnDataReady: local restored = ANx.Engine.ImportCache(); ... after the GetSummary loop: if restored and ANx.Engine.EnsureWarm then ANx.Engine.EnsureWarm() end. Also call ANx.Engine.EnsureWarm() in WatchRefreshDone right after InvalidateStats() so the button pick survives the rev bump (tag-deduped, so it is free when a job is already queued). Port to AttuneNext-Simple's engine as well.

**Expected effect.** Confirmed in code: the only paths that enqueue WarmPredicates are the pump's end-of-queue block (Engine.lua:304) and Engine.WarmIfNeeded (which returns while cachesWarm is false); the only PickAsync(nil,'btn') is the same block; GetSummary returns imported summaries without enqueueing. Baseline cached-login (run_all G): scan window 1 frame, warm=false after 1,500 idle frames, after-GC 24.7 MB, peak 50.1 MB. Prototype at scratch/exp_g07 (end-of-queue block factored into Engine.EnsureWarm() guarded by Engine.SummariesReady(); Core calls it right after a successful validated ImportCache): warmup ran at data-ready, 'pump: 94 frames, 1273ms (max 30.8ms in warmup, 7 over 20ms); resume max 13.7ms', caches warm at frame 408, after-GC 26.0 MB (+1.3 MB), peak 83.6 MB (+33 MB of transient garbage because the default-filter warmup fetches sources for every item: GetSources 24,746 calls / 458,461 row...

**Risk.** Enqueue only after the validated import (not the provisional one at ADDON_LOADED) so the sweep sees live attunement data; the EnsureWarm guard on SummariesReady() also prevents a premature sweep over a partial universe on the fresh path. The warmup's FlushSources lowers srcCacheCap to 800 as on the fresh path.

#### gap-real-db-shape-03: Gate ZoneWatchNow on dataReady; run LeftItems as a job while caches are cold
Tags: cpu | Bundle: streaming source rows | Impact: medium | Effort: small
Files: `ZoneWatch.lua:40-68`, `ZoneWatch.lua:233-249`, `ZoneWatch.lua:324-334`, `Core.lua:1757-1760`, `Core.lua:1697`, `Core.lua:1641`

**What happens now.** Core.lua:1757-1760 handles ZONE_CHANGED_NEW_AREA and PLAYER_ENTERING_WORLD by calling ANx.ZoneWatchUpdate(true), which fires ANx.ZoneWatchNow 0.8 s later (ZoneWatch.lua:324-334). ZoneWatchNow is gated only by ANx.LootDbLoaded() (241), not by ANx.dataReady, so at login it runs before the attunement data is ready. LeftItems (61-66) walks ANx.ItemsInZone(z.zone) and calls Engine.Eligible for every item; Eligible -> ItemQuestCharBlocked -> IsQuestOnly -> Engine.Sources materializes every world drop listed in the zone, synchronously, in one frame. The itemFlags it fills are then wiped by AttuneNext_OnDataReady -> Engine.InvalidateAll -> ANx.FlagClearMask (Core.lua:1641, Engine.lua:97-103), so the work is thrown away and redone. Core.lua:1697 calls ZoneWatchUpdate(false) after every attune completion, and inside instances ZoneWatchNow also calls Engine.ItemRows (282) -> BestSource per item.

**Change.** Do (2) now: add 'if not ANx.dataReady then return end' after the LootDbLoaded check in ZoneWatchNow (1 line) and let OnDataReady's existing paths trigger the first real update (ZoneWatchUpdate is already called from PLAYER_ENTERING_WORLD; add a ZoneWatchUpdate(true) call at the end of AttuneNext_OnDataReady so the login line still appears). Do (3) only while not Engine.CachesWarm(): wrap the ItemsInZone loop of LeftItems in Engine.Enqueue(function() ... Engine.MaybeYield() per item ... end, function() paint(items) end, 'zonewatch') (~25 lines), keeping the inline path when caches are warm. Finding 02 is the real fix; without it the job merely moves the materialization off the frame.

**Expected effect.** Stock frame 50 (PLAYER_ENTERING_WORLD + 0.8 s, before data is ready at frame 312): 204 ms / 75,900 rows in my run (the author saw 136-476 ms depending on GC state), 462 ms at 30x3000 and 1,969 ms at 500x2000 (the worst frame of the whole run); the flags it fills are cleared by AttuneNext_OnDataReady -> Engine.InvalidateAll -> ANx.FlagClearMask (Core.lua:1641, Engine.lua:97-103), so the work is discarded. ZoneWatchNow is gated on ANx.LootDbLoaded() only (ZoneWatch.lua:241), and the harness stub returns ItemLocIsLoaded()=1 from frame 0. With finding 02 alone the same probe costs 14 ms (4 ms with the C-like bit library) and builds 0 rows. Not measured: whether ItemLocIsLoaded() precedes GetCustomGameData(41,0) readiness in the real client; if it does not, the pre-ready run never happens there and only the zone-change/attune-completion cases remain.

**Risk.** Gating on ANx.dataReady changes nothing visible (the pre-ready run could only print a count computed against the status cache, which lacks quest-side data). Moving LeftItems into a job delays the zone-entry chat line by a few frames and must not be done for the instance HUD refresh while 'sizing' is true (the function returns early there today).

Also reported as: load-04, mem-07, scan-12, frame-03, micro-05, gc-08.

#### gap-real-db-shape-06: Shrink srcCache to 5,000 rows / 16 items with a two-generation pair, after db-01/02/04
Tags: memory | Bundle: streaming source rows | Impact: medium | Effort: small
Files: `Engine.lua:14-28`, `Engine.lua:442-466`, `Engine.lua:471-475`, `UI.lua:3365`, `QuestArrow.lua:280-281`, `Core.lua:1845-1853`

**What happens now.** Engine.Sources (442-466) caches whole arrays up to srcCacheCap items and SRC_ROW_BUDGET=60,000 rows and, on overflow, assigns srcCache = {} (454-457), dropping every item including the ones the current loop will ask for again a moment later. FlushSources (471-475) lowers the item cap to 800 after the warmup but keeps the 60,000-row budget, so a working set of 60 world drops x 1,000 rows (each a 9-field table of ~350-400 B on the client) stays resident all session. Under the heavy tail the cache is simultaneously useless (30 x 2,000-row items overflow it, so the 500x2000 run ends with 1 cached item and 5x call redundancy) and expensive (the flush churn is what multiplies GetSources calls 3-5x).

**Change.** Do after 01/02/04 (same release): SRC_ROW_BUDGET = 5000, srcCacheCap = 16, remove the 3000/800 cap juggling in InvalidateAll/FlushSources, and replace the wholesale 'srcCache = {}' with a two-generation pair (move current to old on overflow, look up both) so two viewed items coexist; keep 'an item larger than the budget is never cached'. ~20 lines. Report rows held in /an perf (PerfStats) alongside the index slot count.

**Expected effect.** A GetSources row table allocates 721 B on 64-bit (measured with GC stopped; 9 named fields round the hash part up to 16 nodes), so the PROFILE estimator's 23 MB for a full 60,000-row srcCache (it charges a flat 40 B per entry, harness_gapx.py:521-575) undercounts: the real figure is ~43 MB, consistent with the 'after full GC' totals of 59.3 MB (stock) vs 22.8 MB (prototype, srcCache=0). Client estimate at ~500-544 B/row (MSVC x86 Node = 32 B): ~30 MB resident for a full cache, plus the 3-5x GetSources redundancy from wholesale flushes (76,372 calls for 24,357 items at 100x1000; 122,379 at 500x2000 ending with 1 cached item). After 01/02/04 the only Engine.Sources/GetSources consumers are UI.lua:3365 (sources screen), QuestArrow.lua:280-281 and Core.lua:1848 (/an src) - 3 call sites by grep.

**Risk.** Only safe once 01, 02 and 04 are in; shrinking the cache before that multiplies scan and render refetches (the scan path currently depends on it). The sources screen of two large items viewed alternately would thrash a 1-item cache, hence the two-generation eviction. AttuneNext-Simple shares Engine.lua. Frees memory only in sessions that touched world drops, so the headline is 'bounded worst case', not an always-on saving.

Also reported as: gc-04, mem-01, scan-09.

#### gap-two-addons-pacing-04: Make MaybeYield time-sliced (2 ms); add yields in Universe and InstanceDiffs
Tags: cpu | Bundle: pump pacing | Impact: medium | Effort: small
Files: `Engine.lua:247`, `Engine.lua:274`, `Engine.lua:808`, `Engine.lua:1559`, `Engine.lua:370`, `Engine.lua:114`

**What happens now.** Engine.MaybeYield (Engine.lua:247-254) counts calls and yields on the 25th. In ZoneData (Engine.lua:808) one call is one item, and an item's Engine.Sources can be thousands of rows (world drops), so 25 items can be 2.5 heavy items plus 22 light ones or 25 heavy ones; in BuildSummary (Engine.lua:1559) one call is one whole instance difficulty; the warmup (Engine.lua:370) makes one call per universe item with a Sources walk behind ItemQuestCharBlocked; Engine.Universe (Engine.lua:114-137) never yields. The pump loop only checks the clock between resumes (Engine.lua:274), so the 10 ms budget is a soft bound: the last resume of each frame overruns it by whatever the current 25-call batch costs.

**Change.** Do now; ~25 lines in Engine.lua. `local sliceEnd = 0; function Engine.SetSlice(t) sliceEnd = t end; function Engine.MaybeYield() yieldCheck = yieldCheck + 1; if yieldCheck >= 8 then yieldCheck = 0; if Clock() >= sliceEnd and coroutine.running() then coroutine.yield() end end end`; pump: `Engine.SetSlice(start + BUDGET_MS)` before the loop (with 02: start + workBudget). Also make Engine.YieldNow slice-aware (`if coroutine.running() and Clock() >= sliceEnd then ... yield`) since RankInstanceRuns/RankZoneRuns (Engine.lua:2079, 2146) yield unconditionally per instance. Add `Engine.MaybeYield()` after each category loop in Engine.Universe and after each FetchInstDiff in Engine.InstanceDiffs (exact text in exp_gaplens/build.py UNIV_NEW/INST_NEW). This is also what makes 02's small budgets real: a 3 ms budget with 25-call batches would overrun by 20 ms.

**Expected effect.** Instrumented stock pump (exp_gaplens/v_base): 3,691 resumes per scan, overrun past the 10 ms budget 1.45 ms/frame (slow 1) and 3.20 ms/frame (slow 2.5), max single resume 36.5 / 56.2 ms; by tag: summary2 max 36.5 ms, warmup max 23.6 ms, pick 975 resumes of 0.23 ms. Time-sliced MaybeYield alone, fixed budget (v_slice): overrun 0.62 / 1.38 ms per frame, resumes 436 / 1,090 (one per frame), per-frame cost 16.3 -> 15.2 ms (slow 1) and 24.1 -> 21.9 ms (slow 2.5), wall 14.0 -> 13.9 s / 39.6 -> 42.1 s (the removed overrun work moves to later frames), peak 144 -> 133 MB / 127 -> 131 MB (noise). Max single resume did NOT drop with slicing alone (37.9 / 65.5 ms).

**Risk.** Jobs run synchronously on the main thread (ZoneData inCoroutine=false, RankRuns yielding=false) are unaffected since MaybeYield only yields inside a coroutine; Universe()/InstanceDiffs called synchronously likewise. If 05's status job calls Universe(), the new yields fire inside that job, which is fine (the universe array is only published at the end). A slice that is already expired yields on the 8th call, as intended.

**Prototype.** `proto:pacing`, diff `prototypes/proto_pacing.diff`; numbers in `prototypes/MEASUREMENTS.md`.

#### gap-client-c-costs-11: Run ExportStatusCache as a yielding pump job, skip when clean, chunk the concat
Tags: cpu, load | Bundle: pump pacing | Impact: medium | Effort: small
Files: `Core.lua:612-637`, `Core.lua:1613-1625`, `Core.lua:1766-1768`

**What happens now.** WatchRefreshDone (Core.lua:1613-1625) polls every second after login and, when the job queue is empty, calls InvalidateStats, RefreshIfShown and `pcall(ANx.ExportStatusCache)` inline. ExportStatusCache (612-637) loops ipairs(universe) calling IsAttunableAtAll (GetItemTagsCustom), CanCharAttune (CanAttuneItemHelper), AccountHasVariant (HasAttunedAnyVariantOfItem), Progress (GetItemAttuneProgress) and GetItemAttuneForge per item, plus math.floor/string.format for every item with progress, then concatenates five strings: ~5 x 24k C calls and ~10-20k formats in one frame, on the main thread, right when the UI re-renders.

**Change.** Do now: move the loop body of ExportStatusCache into an Engine.Enqueue job that calls Engine.MaybeYield() every 25 items and assembles the five strings in onDone; WatchRefreshDone enqueues it (tag 'statuscache') instead of calling it inline; keep the PLAYER_LOGOUT call synchronous. Run finding 01's mid-session export the same way.

**Expected effect.** Harness after login (universe 24,357): ANx.ExportStatusCache = 208-216 ms per call of pure Lua on this box with free stubs (output strings: tags 120 KB, can 80 KB, acct 30 KB, prog 199 KB; the synthetic DB has 6/7 of items in progress, which inflates the prog formatting, real data far less). On the client: 2-3x slower Lua plus ~120k real C calls (5 per item) -> est. 0.4-0.8 s single-frame stall at the moment WatchRefreshDone fires, in the same frame as InvalidateStats + RefreshIfShown. Callers: Core.lua:1621 (WatchRefreshDone) and Core.lua:1775 (PLAYER_LOGOUT).

**Risk.** If the game closes before the job finishes, the previous logout's snapshot stays (same as today before the export ran). Tag-dedupe the job ('statuscache') so a refresh during a pending export does not queue a second one; the job must build into locals and assign ANx.db.statusCache only in onDone so a half-built snapshot is never saved.

Also reported as: load-02, scan-05, frame-04, micro-10.

#### gap-two-addons-pacing-05: One change with cc-11: status export job; Simple reads the host's statusCache
Tags: cpu, load | Bundle: pump pacing | Impact: medium | Effort: small
Files: `Core.lua:611`, `Core.lua:1615`, `Core.lua:1621`, `Core.lua:1775`, `Core.lua:1684`, `AttuneNext-Simple/Core.lua:1613`

**What happens now.** ANx.ExportStatusCache (Core.lua:611-638) loops over the whole Engine.Universe() calling IsAttunableAtAll, CanCharAttune, AccountHasVariant, Progress and GetItemAttuneForge per item and builds five concatenated strings. It is called synchronously from WatchRefreshDone (Core.lua:1615-1625, an ANx.After(1) timer that fires on the first 1 s tick after the scan queue empties) and from PLAYER_LOGOUT (Core.lua:1775), unconditionally, even when no attunement changed since the last export. This is a long loop inline in a timer callback, which the handoff rules forbid. AttuneNext-Simple has the identical code (Core.lua:1613, 1723) and its own independent timer, so with both addons the two 200 ms walks can fall in the same frame, and both run again at logout/reload.

**Change.** Do now (the six edits in exp_gaplens/build.py ST_OLD/ST_NEW): `ANx.ExportStatusCache(yielding)` returns early unless ANx.statusDirty, calls `ANx.Engine.MaybeYield()` per item when yielding, clears the flag after writing; WatchRefreshDone enqueues `Engine.Enqueue(function() ANx.ExportStatusCache(true) end, nil, 'status')`; set statusDirty = true at data-ready, in the typeId 11 chain, and on PLAYER_LEVEL_UP; logout keeps `pcall(ANx.ExportStatusCache)`. Simple: SC() falls back to `_G.AttuneNextDB.statusCache` when `_G.AttuneNext` exists and ExportStatusCache returns early then (plus `ANx.db.statusCache = nil` once). Bonus with the same pattern: AltCache's SnapshotAltCan (a Universe walk from an 8 s timer, 10.8 ms harness) can become a 'altcan' job.

**Expected effect.** Baseline today: ExportStatusCache 201-212 ms per call at 24,357 universe items; it is the worst frame of every run (203 ms at slow 1, 551 ms emulated at slow 2.5; pair 452 ms when both timers land together), and PLAYER_LOGOUT = 243 ms (status 205 + ExportCache 38). It runs from WatchRefreshDone 2 s after data-ready on EVERY login, including cached logins that run no scan, so unlike 02-04 this stall is per login. Prototype (exp_gaplens/v_status: job with MaybeYield per item under the time-sliced pump + statusDirty flag set at data-ready / every OnCustomGameData typeId 11 / PLAYER_LEVEL_UP): worst scan-window frame 203 -> 56 ms (slow 1) and 551 -> 152 ms (slow 2.5); the job took 23 resumes / 241 ms of pump time (322 ms total CPU vs 201 inline, +60% for the per-item yield check at 8-call granularity, acceptable); PLAYER_LOGOUT 243 -> 38.6 ms with the export skipped because nothing changed.

**Risk.** The snapshot carries progress, so dirty must be set on every typeId 11 tick, not only completions; in an active play session the logout export will therefore still run (205 ms), the skip pays only on /reload-after-login and idle sessions. The logout path must stay synchronous. Set dirty at data-ready so the first export per character always happens (the export keys on UnitName).

#### gap-telemetry-and-harness-fidelity-06: One change with cc-11: removes the 60-200 ms scan-end status-export hitch
Tags: cpu | Bundle: pump pacing | Impact: medium | Effort: small
Files: `Core.lua:1613-1623`, `Core.lua:611-640`, `Core.lua:1773-1780`

**What happens now.** WatchRefreshDone (ANx.After, 1-2 s after the queue empties) calls pcall(ANx.ExportStatusCache) synchronously. ExportStatusCache walks the whole universe (24,346 ids) doing IsAttunableAtAll, CanCharAttune, AccountHasVariant, Progress and GetItemAttuneForge (five C calls and two bit ops per item), string.format per item with progress, then five table.concat, all in one frame, right when the 'data has been refreshed' toast appears. The handoff rule says long loops belong in an Engine.Enqueue job.

**Change.** Do now (follows the handoff rule that whole-universe loops run in an Engine.Enqueue job). Sketch: ANx.ExportStatusCache(yielding): keep locals tags/can/acct/prog/forge but add chunk arrays (tagsC, canC, acctC) and inside the loop, after 'if yielding then ANx.Engine.MaybeYield() end', flush each array to its chunk list with table.concat when it reaches 2,048 entries; at the end concat the remaining entries, then join the chunk lists with ',' and assign ANx.db.statusCache once (leading/trailing ',' as today). WatchRefreshDone: replace pcall(ANx.ExportStatusCache) with ANx.Engine.Enqueue(function() ANx.ExportStatusCache(true) end, nil, 'statuscache'). PLAYER_LOGOUT keeps pcall(ANx.ExportStatusCache) (no yield outside a coroutine; MaybeYield is already safe on the main thread). Verify with finding 03's statusExportMs and resumeMaxMs before/after.

**Expected effect.** Baseline (fresh-scan, fast bit): ExportStatusCache 68-100 ms inside the WatchRefreshDone timer callback in every run (85.2, 100.2, 69.8, 67.6 ms in my four A/B runs), the slowest single-frame stall outside the pump; 205-222 ms with the stock bit stub. Prototype at scratch/exp_g06 (ExportStatusCache(yielding) calling Engine.MaybeYield() per item, WatchRefreshDone enqueuing it as job 'statuscache', logout still synchronous): WatchRefreshDone 0.0 ms; the export took 109 ms spread over 13 extra pump frames (303 vs 290), scan-end frame 604 (inside noise), after-GC 30,901 KB (unchanged), but 'pump: max 29.8ms in statuscache; resume max 23.0ms in statuscache'.

**Risk.** If the job is still queued at logout the synchronous PLAYER_LOGOUT export runs anyway (idempotent). A second OnDataReady mid-job drops the coroutine via InvalidateAll (scanJobs = {}); the old statusCache stays and WatchRefreshDone re-enqueues after the new scan. The 'data has been refreshed' toast now fires before the snapshot is written (harmless: the snapshot is only read at the next login). Keep the ANx.dataReady guard.

#### gap-two-addons-pacing-03: Time-cap the GC step: 8 x 256 KB with count cap and allocation floor; with pacing-02
Tags: cpu, memory | Bundle: pump pacing | Impact: medium | Effort: small
Files: `Engine.lua:239`, `Engine.lua:286`, `AttuneNext-Simple/Engine.lua:286`

**What happens now.** collectgarbage('step', 2048) (Engine.lua:286) lowers the GC threshold by 2 MB and runs luaC_step until the debt is paid, so it does a fixed amount of mark/sweep work per frame no matter how much the 10 ms of scan actually allocated. Its time scales with CPU speed while the scan budget is fixed in ms: on the fast harness CPU it is 4.3 ms per frame (27% of the pump's 16 ms), on a 2.5x slower CPU 9.7 ms emulated (as much as the 10 ms of work), and with two pumps 10.0 / 22.0 ms per frame. In the pair both pumps step the one global collector.

**Change.** Do only together with 02 (never alone with the fixed 10 ms budget): `local kb = math.floor(GC_STEP_KB * work / 10)`, cap by `math.floor(budget * GC_FRACTION / msPerKb)` from an EWMA of (step ms / kb), floor 256 KB, PLUS an allocation floor so memory cannot run away: `local alloc = collectgarbage('count') - lastCount; if kb < alloc * 0.4 then kb = alloc * 0.4 end; collectgarbage('step', kb); lastCount = collectgarbage('count')`. Exact text for the first part is gap2/patch_exp.py patch_pace3; the floor is my addition and should be checked with PROFILE=1 at SLOW=2.5 before shipping (expect peak within 5% of baseline). Port to Simple's Engine.lua.

**Expected effect.** Baseline GC step (collectgarbage wrapped): 4.5 ms per scan frame at slow 1 (28% of the pump's 16.3 ms), 10.2 ms at slow 2.5 (as much as the 10 ms of work), 10.8 ms/frame in the pair. Standalone prototype exactly as proposed for the fixed-budget case (exp_gaplens/v_gc: kb = min(2048, floor(3 ms / EWMA ms-per-KB)), floor 256 KB, 10 ms budget unchanged): step 4.5 -> 3.6 ms (slow 1) and 10.2 -> 4.3 ms (slow 2.5, -5.9 ms/frame, 24.5 -> 28.7 fps, wall 39.6 -> 34.2 s) BUT peak Lua rose 143.8 -> 154.0 MB (+7%) and 127.1 -> 147.6 MB (+16%); with 04 added (v_slicegc) 149 / 145 MB. The 'allocation and collection scale together' claim only holds in pace3 because the WORK per frame shrank too (7 ms); with a fixed 10 ms of work (~3.6 MB allocated per frame, 1.36 M row tables over 420 frames) a 0.6-1.4 MB step lets garbage pile up and the automatic collector catches up later.

**Risk.** Standalone, on exactly the slow 32-bit machines it targets, it raises peak memory 10-20 MB (harness; ~7-14 MB client) during the one phase that already crashed v3.6.2 at 1.9 GB; the handoff's rules prefer memory over frame time. Safe only when the step is proportional to the work actually done and the work is itself bounded by 02, or with an allocation floor. collectgarbage('step', n) semantics are plain Lua 5.1 on the client.

**Prototype.** `proto:pacing`, diff `prototypes/proto_pacing.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: scan-04, gc-05.

#### frame-11: Skip InvalidateStats on bag events when the owned-attunable signature is unchanged
Tags: cpu | Bundle: filter client costs | Impact: medium | Effort: small
Files: `Core.lua:1733-1752`, `Engine.lua:742-752`, `Engine.lua:69-80`

**What happens now.** BAG_UPDATE / PLAYERBANKSLOTS_CHANGED / PLAYER_EQUIPMENT_CHANGED (Core.lua:1733) call Engine.InvalidateOwned() and, once per 0.5 s burst, Engine.InvalidateStats() + UI.RefreshIfShown(). InvalidateStats wipes statsCache, runsCache, pickCache, remainingCache and clearChanceCache and may enqueue a warmup; the next render recomputes every count and the button pick is recomputed. Looting a grey, moving a stack or selling junk triggers exactly the same full recompute as looting an attunable.

**Change.** Do now, on top of gap-cc-04 and cc-12 (~20 lines). Engine: `function Engine.OwnedAttunableSig() local a = {} for id in pairs(OwnedSet()) do if ANx.IsAttunableAtAll(id) then a[#a+1] = id end end table.sort(a) return table.concat(a, ',') end`. Core.lua:1746-1751 debounced callback: `ANx.Engine.InvalidateOwned(); local sig = ANx.Engine.OwnedAttunableSig(); if sig == ANx.lastOwnedSig then return end; ANx.lastOwnedSig = sig; ANx.Engine.InvalidateStats(); RefreshIfShown()`. Keep the immediate InvalidateOwned and RefreshMats calls as they are; reset lastOwnedSig to nil in InvalidateAll/ForceRescan and when hideInBags is toggled (UI.lua:973-974, 4455-4456) so the first burst after a toggle always recomputes.

**Expected effect.** python3 -I scratch/verify_clp/bench.py: 'frame-11 signature of 200 owned ids (sort+concat) x 100 9.13 ms alloc 413 KB' -> 0.09 ms and ~4 KB garbage per burst; plus cc-04's OwnedSet walk (5 GetContainerNumSlots + ~80 GetContainerItemID + 19 GetInventoryItemLink, free in the harness, ~0.1 ms client) and ~100-250 IsAttunableAtAll (GetItemTagsCustom) C calls. Not measured: the in-game fraction of bursts that change the attunable-owned set (by construction only attunable loot/equip/sell events). Baseline cost avoided per unchanged burst: cc-12's 182 frames x 10 ms (harness, bit-stub and HEAVY=200 inflated; client est. 1-3 s of background CPU) with the window open, or one cold pick on the next button press with it closed.

**Risk.** Bank contents are readable only while the bank is open: keep PLAYERBANKSLOTS_CHANGED unconditional until cc-04's bankSet exists, then include bankSet in the signature. Use IsAttunableAtAll (scope-independent, one C call) rather than CanCount for the filter so a scope change cannot make a stale signature match. Stack-count changes of an owned attunable correctly do not trigger (IsOwned is boolean).

#### gap-client-c-costs-02: Gate ItemFactionOf/ClassLock/BindType on GetItemInfo so uncached items never scrape
Tags: cpu | Bundle: filter client costs | Impact: medium | Effort: small
Files: `Core.lua:1160-1165`, `Core.lua:1068-1073`, `Core.lua:875-895`, `Core.lua:538-546`, `Engine.lua:755-781`, `Engine.lua:358-400`

**What happens now.** BindType has a negative marker: on NumLines()==0 it stores F_BIND=1 and later retries only once GetItemInfo(id) is truthy (Core.lua:875-895). ItemFactionOf (1160-1165) and ClassLock (1068-1073) have no such marker: on 0 lines they 'return nil, retry later' without touching the flag or classLockCache, so the next Engine.Eligible (Engine.lua:755-781, via FactionAllowed at 756 and ItemUsableByClass at 773-774) on the same item rebuilds the tooltip again. On the 3.3.5 client SetHyperlink('item:N') for an uncached N is also what triggers the item query to the server (the addon's own RequestItemCache at Core.lua:538-546 relies on exactly that), so each repeat is both a tooltip build and a network packet, outside the cacheRequested dedupe.

**Change.** Do now, paired with 03. Four lines in each of ItemFactionOf and ClassLock (after the seed/cache check, before ClearLines): `if GetItemInfo and not GetItemInfo(itemId) then if ANx.RequestItemCache then ANx.RequestItemCache(itemId) end return nil end`. Put the same gate in BindType ahead of its c==1 path so uncached items never build a tooltip there either. In WarmPredicates skip FactionAllowed/ItemFactionOf/ClassLock for ids where Engine.ItemMinLevel(id) == nil (already computed for doLvl/doBind) so the sweep pays nothing at all for uncached items. No new flag bits needed.

**Expected effect.** Patched copy (GetItemInfo gate before ClearLines in ItemFactionOf and ClassLock, uncached ids routed to RequestItemCache), FILTERS=faction CACHEPCT=30. Normal server (QUERY_DELAY 0.5 s): warmup faction tooltip builds 30,573 -> 14,179 (the 16,394 uncached builds became 16,394 GetItemInfo + queued requests); server queries UNCHANGED at 16,661 in both runs, because the warmup's uncached scans were already ~1 per id (16,394 scans -> 16,661 queries), so the finding's 'removes 16-17k queries' does not hold for the warmup.

**Risk.** The gate removes repeats and the uncached tooltip build, not the unique queries: with 03 absent, RequestItemCache still fires immediately, so a cold warmup still emits ~16k packets in one sweep (same as today, just one per id). After ClassLock's gate, ItemUsableByClass calls GetItemInfo a second time for the same uncached id (2 cheap C calls per Eligible) until finding 06 lands.

#### gap-client-c-costs-08: Remember GetItemName misses with a generation bumped from the cache drain
Tags: cpu | Bundle: filter client costs | Impact: medium | Effort: small
Files: `Core.lua:524-531`, `UI.lua:3597-3610`, `UI.lua:3195`, `UI.lua:760-775`

**What happens now.** ANx.GetItemName (Core.lua:524-531) caches positive results in itemNameCache but not misses: for an id the client has not cached it calls GetItemInfoCustom and then GetItemInfo every time. The search builder (UI.lua:3597-3610) walks Engine.Universe() (~24k ids) calling GetItemName per id on every debounced render (0.25 s after the last keystroke, 760-775), so each render pays two C calls per still-unresolved id. It deliberately never calls RequestItemCache, so an item the client has never seen can neither be found by search nor become findable later in the session.

**Change.** Do now (8 lines, as patched): `local nameMiss, missGen = {}, 0; function ANx.BumpNameMiss() missGen = missGen + 1; nameMiss = {} end`; in GetItemName return nil early when `nameMiss[id] == missGen`, record the miss otherwise. Call BumpNameMiss from 03's OnCacheDrained and from a 30 s ANx.After fallback. Optionally push the first ~200 misses per search render into the 03 queue so names become findable on a fresh client cache.

**Expected effect.** Cold cache (CACHEPCT=30) search renders, baseline: GetItemInfo 24,784 + GetItemInfoCustom 12,392 on EVERY re-render for the 12,392 unresolved ids (renders 2 and 3 identical), 0 server requests. Patched copy (miss generation in GetItemName): first render 42,774 + 24,417 (includes the view's own probes), second and third renders 0 GetItemInfo-family calls (GetItemName still 24,357 hash lookups per render). Warm cache: 8,714 + 4,357 per render for the 4,357 non-attunable universe ids (VendorCosts/event ids the client never resolves) -> 0.

**Risk.** An item cached later is invisible to search until the generation bumps, so the bump must be wired to 03's drain hook AND a periodic fallback (e.g. every 30 s while the search view is open) for items cached by other means (hovering in bags). The miss hash can reach ~12k entries (~340 KB on 32-bit); wipe it on bump (`nameMiss = {}`) so it never outlives a drain. Sort-by-name callers share GetItemName and benefit too.

#### gap-client-c-costs-06: Store the item kind in itemFlags (F_KIND); replace classLockCache false with F_NOLOCK
Tags: cpu, memory | Bundle: filter client costs | Impact: medium | Effort: small
Files: `Core.lua:1101-1122`, `Core.lua:1059-1062`, `Core.lua:1124-1127`, `Engine.lua:773-774`, `Engine.lua:998-999`, `Core.lua:419-420`

**What happens now.** ANx.ItemUsableByClass (Core.lua:1101-1122) is the prestige class gate called from Eligible (Engine.lua:773-774) and ScopeLeft (998-999). It consults ClassLock (a hash hit after the first scan) and then unconditionally calls `_G.GetItemInfo(itemId)` (1105) to get itype/isub/equipLoc and evaluates CLASS_ARMOR/CLASS_WEAPON sets; nothing memoizes the verdict, so every count/list/pick re-pays one C call (11 return values pushed) per item. classLockCache (1059) is a plain Lua hash holding `false` for nearly every item scanned (only tier-style items have a lock), ~20k entries x 28-40 bytes on the 32-bit client.

**Change.** Do now, as a KIND code rather than a per-class verdict: F_KIND = 5 bits at shift 25 holding an index into a fixed list of the 9 armor subtypes + 15 weapon subtypes in CLASS_ARMOR/CLASS_WEAPON, plus 'cloak' and 'not gear / unknown -> pass' (~27 values). ItemUsableByClass: read the field; on 0 call GetItemInfo once, FlagSet the kind; then return CLASS_OK[mode][kind][token] from two small precomputed tables (attune vs equip mode). The kind is a static item property, so nothing is cleared on class/mode change (only InvalidateAll/ForceRescan). Replace classLockCache's `false` entries with a 1-bit F_NOLOCK at shift 30 and keep the hash only for the few hundred real locks. Warm F_KIND in the 05 sweep (ItemMinLevel already pays the GetItemInfo there).

**Expected effect.** Harness with the class filter switched on: root render GetItemInfo 30,175 for ItemUsableByClass 35,166; the following 200 frames (pick jobs + renders) GetItemInfo 35,781 for 42,781 calls; with all three filters saved at login the per-screen renders show GetItemInfo 508-651 per render, one per ItemUsableByClass survivor. classLockCache after the sweep: 12,854 entries almost all `false` = 640 KB measured in 64-bit lupa (collectgarbage delta), ~450 KB on the 32-bit client, ~0.7-0.9 MB for a real 20-25k universe. Not measured: GetItemInfo's C cost (11 return values + cache lookup, est. 1-3 us), i.e. ~30-100 ms per root render and per pick job while the filter is on.

**Risk.** Only bits 25-30 are safely free (F_MINLVL ends at bit 24; bit 31 is unsafe with a signed 32-bit bit library). The proposal's per-class verdict field must be cleared whenever classFilter or classFilterMode changes (two chip handlers at UI.lua ~982-993 and ~4434-4448, the Settings panel, ForceRescan) or stale verdicts show the wrong class's gear; storing the item KIND instead has no such invalidation.

Also reported as: pred-12.

#### gap-client-c-costs-12: Coalesce the post-InvalidateStats job chain with a 1 s tag-deduped re-enqueue
Tags: cpu | Bundle: filter client costs | Impact: medium | Effort: small
Files: `Engine.lua:306-309`, `Engine.lua:1946-1967`, `Engine.lua:1838-1848`, `Engine.lua:69-80`, `Core.lua:1744-1751`, `UI.lua:4254-4256`

**What happens now.** Engine.InvalidateStats (69-80) clears pickCache; the pump re-enqueues PickAsync(nil,'btn') whenever the queue drains and the cache is empty (306-309), and the screens request PickAsync(view,'rec') on render (UI.lua:4254-4256, 4890-4892). AttuneNextPick (1838-1848) walks its item pool calling Engine.Eligible + CountDone + HasAnySource (ItemLocGetSourceCount) + ItemLevelOk per item; for 'btn' the pool is the whole universe. So each bag event past the debounce (Core.lua:1744-1751), each filter chip and each drain of the cache queue (finding 03) costs ~2 x 24k Eligible in the background, and with hideInBags / Class filter on that is 2 x ~16k GetItemCount or 2 x ~35k GetItemInfo per event.

**Change.** Do now, broader than proposed: coalesce the whole post-InvalidateStats job chain, not just the picks. In InvalidateStats record lastInvalidate = GetTime() and schedule the re-enqueue of the 'btn' pick and any pending RankRunsAsync/PickAsync through ANx.After(1, ...) tag-deduped, so a burst of bag events or chip clicks runs runs/pick jobs once; let the root 'rec' pick reuse the 'btn' pool; inside AttuneNextPick cache the Eligible verdict per id for the job's duration (the seen[] table already exists) and skip HasAnySource for items whose flags show a known source. Pairs with 03's drain hook (which must not InvalidateStats without a reason) and with 04/06.

**Expected effect.** Harness with the root screen shown: one InvalidateStats -> job queue drained after 182 frames of 10 ms budget (189 with hideInBags) = ~1.8 s of CPU, Eligible 152,783 (6+ universe passes) and GetItemCount 100,747 with hideInBags. Debug trace of the queue after a filter switch: 'runs:rec|all|root' (RankRunsAsync, rev-keyed, cleared by every InvalidateStats) ~200 frames, pick:btn ~40-60 frames, a warmup top-up 20-160 frames; with a front-inserted top-up the whole chain after one chip click was ~380 frames (6.3 s at 60 fps). HEAVY=200 synthetic sources inflate the runs job (Engine.Sources per item), real data is lighter but the client is 2-3x slower.

**Risk.** A debounce delays the button pick / cards after a filter click by the chosen window (1-2 s); the UI's onDone callbacks must still fire once. Reusing the 'btn' pool for the root 'rec' pick changes nothing visible. 04 and 06 remove most of the C cost of these jobs; this finding is about the repeated Lua passes and the runs job, which the proposal underweights.

#### gap-two-addons-pacing-08: Capture tooltip font strings per scraper frame; rename Simple's scraper frames
Tags: cpu | Bundle: filter client costs | Impact: medium | Effort: small
Files: `AttuneNext-Simple/Core.lua:883`, `AttuneNext-Simple/Core.lua:898`, `AttuneNext-Simple/Core.lua:1066`, `AttuneNext-Simple/Core.lua:1082`, `AttuneNext-Simple/Core.lua:1158`, `AttuneNext-Simple/Core.lua:1172`

**What happens now.** Simple's Core.lua was renamed for its DB, slash commands and window frames, but not for the hidden GameTooltips: both addons lazily call CreateFrame('GameTooltip', 'AttuneNextBindTip', nil, 'GameTooltipTemplate') (Core.lua:883/1066 in both) and 'AttuneNextFactionTip' (1158), and 'AttuneNextCacheTip' (542). The scrapers keep the frame in a local (bindTip/factionTip) but read the lines back through the TEMPLATE's global names: _G['AttuneNextBindTipTextLeft'..i] (898, 1082) and _G['AttuneNextFactionTipTextLeft/Right'..i] (1172-1175). When the second addon creates its frame, the client rebinds those globals to the new frame's font strings; the first addon still fills its own frame with SetHyperlink but then reads the sibling's lines, i.e. whatever item the sibling scraped last (or empty lines).

**Change.** Do now in both repos: capture the lines once after creation (`tip.L = {}; tip.R = {}; for i = 1, 30 do tip.L[i] = _G[name .. 'TextLeft' .. i]; tip.R[i] = _G[name .. 'TextRight' .. i] end`) and read `bindTip.L[i]:GetText()` / `factionTip.L[i]`, `factionTip.R[i]` in BindType, ClassLock and ItemFactionOf; in Simple also rename the three frames to AttuneNextSimpleCacheTip/BindTip/FactionTip so the globals never collide even with old versions. About 20 lines per repo.

**Expected effect.** Not measurable in the harness (stub tooltips return 0 lines). Static counts: both repos create the same three global names (Core.lua:542 AttuneNextCacheTip, 883/1066 AttuneNextBindTip, 1158 AttuneNextFactionTip) and read lines back by global name at four sites (898, 1082, 1172-1175) while holding the frame in a local; per scraped line that is 1 global lookup + 1 string concat for bind/class-lock and 4 + 4 for faction (left and right are each fetched twice). Scrapes are reached from BindAllowed (Core.lua:955), the class-lock gate (1103), ItemFactionOf (1200) and the warmup (Engine.lua:383) whenever a bind/faction/class filter is on, up to the universe size (24k items x up to 6 lines). Every other frame name in Simple was renamed (AttuneNextSimpleBrowseFrame etc.); only these tooltips were missed.

**Risk.** Rename: none. Reading through cached font-string references requires the template children to exist at CreateFrame time (they do for GameTooltipTemplate). Interaction: with 01's shared ItemFlags a wrong scrape result would be shared by both addons, so this is a prerequisite for sharing flags. Only affects sessions where both addons scrape (bind/faction/class filter on in either).

#### ui-01: Dedupe RefreshIfShown callbacks in Enqueue; render once from ANx.After(0)
Tags: cpu | Bundle: UI render caching | Impact: medium | Effort: small
Files: `Engine.lua:413-434`, `UI.lua:1903-1906`, `UI.lua:2170`, `UI.lua:2175`, `UI.lua:2192`, `UI.lua:2450`

**What happens now.** Engine.Enqueue dedupes jobs by tag but appends EVERY onDone it is handed to j.extra (Engine.lua:418-424) with no identity check. UI.Render on the root screen calls SummaryRow(exp, UI.RefreshIfShown) six times (builders.root x3 at 2170 and UpdateHomePanel x3 at 4302); home/content/contentTypes/contentExp/goals/whatsleft do it 3-9 times; UpdateHomePanel/UpdateSidePane hand RankRunsAsync and PickAsync a FRESH closure per render (4224, 4256, 4858, 4892), as does UpdateWLPanel for RemainingAsync (4662). While a summary is pending, each render therefore adds +2 callbacks to each pending summary job; when a job finishes it fires onDone plus all extras, each of which is a full UI.Render that appends to the still-pending jobs. The count grows geometrically across the three summary jobs and again on the runs job, and all the renders of one job fire inside a single frame.

**Change.** Do now, ~20 lines, exactly as prototyped: in Engine.Enqueue skip onDone when rawequal to j.onDone or already in j.extra; replace `function() UI.RefreshIfShown() end` with `UI.RefreshIfShown` at UI.lua:4224/4256/4662/4858/4892; make UI.RefreshIfShown set a pending flag and render once from ANx.After(0). The real multiplier is GoalStatus-per-render on the root screen (ui-03, not in this batch): with ui-01 fixed a root render with 2 goals still costs 236 ms stock harness, so cache GoalStatus per Engine.rev next. Ride with gap-cc-12's post-InvalidateStats job coalescing.

**Expected effect.** cd scratchpad/tools && ADDON=<copy> ... MODE=fanout python3 -I ui_bench.py: stock 'TOTAL UI.Render calls: 32, total render ms 1186, max renders in one frame: 18'; patched copy (scratchpad/exp_skeptic_ui: Enqueue identity dedupe, UI.RefreshIfShown passed by identity at the 5 closure sites, RefreshIfShown coalesced through ANx.After(0)) 'TOTAL UI.Render calls: 9, total render ms 1220, max renders in one frame: 1'; OPEN_AT=350: 48 -> 8 renders. skeptic_fanout.py (root open from frame 1): goals=0 stock 30 renders / 574 ms total / worst frame 560 ms vs patched 7 / 552 / 548; goals=2 stock 30 renders / 12,990 ms / worst frame 6,631 ms vs patched 7 / 4,268 / 978. The per-render ms are bit-stub inflated (GoalStatus/UnionStats run Eligible); the x18 multiplier is not.

**Risk.** (c) delays a refresh by at most one frame; every RefreshIfShown caller (Core.lua:62-1878, Settings.lua, Engine.lua:305/409) is already asynchronous. PickAsync/RemainingAsync pass an argument that RefreshIfShown ignores. Keep the first onDone as j.onDone so ShowRec's PushRun closures (UI.lua:5020/5038) are never dropped; identity dedupe only skips a callback already in the list.

#### ui-09: Add UI.Reset so sidebar navigation and favorites render once, not twice
Tags: cpu | Bundle: UI render caching | Impact: medium | Effort: small
Files: `UI.lua:1103-1111`, `UI.lua:4122-4139`, `UI.lua:2074-2083`, `UI.lua:182-186`

**What happens now.** NavGo calls UI.Show(true) which resets the stack and calls UI.Render (a full root render: UpdateHomePanel with its GoalStatus/UnionStats/RankRunsAsync, builders.root, chips, crumb) and then UI.Push(target), which renders again. UI.RestoreFavorite does the same (Show(true) then Push). Every sidebar click therefore pays the root screen's cost (ui-03/ui-04 sized) for a frame nobody sees.

**Change.** Do now (~15 lines): add UI.Reset() = CloseSimpleWindows + ensure frame + stack = {{type='root'}} + search reset + frame:Show() with no Render; call it from NavGo and RestoreFavorite, then Push the target (one render). Saves one cold root render and a wasted universe-wide 'runs:rec|all|root' job per sidebar click / favorite open; pairs with gap-cc-12's debounce of the post-InvalidateStats job chain.

**Expected effect.** scratchpad/tools/skeptic_ui.py (stock, scan finished, after Engine.InvalidateStats): 'Show(true)+Push: renders=2, 666.0 ms inline, jobs after Show=[runs:rec|all|root::|] after Push=[runs:rec|all|root::|,runs:rec|all|browse::|]; frames to drain the queue: 449, callback renders after: 3' vs 'stack reset+Push: renders=1, 4.0 ms inline, jobs=[runs:rec|all|browse::|]; frames to drain: 302, callback renders: 1'. ui_bench.py: 'sidebar click Browse -> UI.Render calls: 2'; 'root render with 2 goals (warm stats): 236.1 ms, 4 goals: 388.2 ms'.

**Risk.** None: UI.Show(true) keeps rendering root for the home button (UI.lua:855), slash (Core.lua:1866) and minimap paths. UI.Reset must still call ANx.CloseSimpleWindows, clear UI.searchQuery and the search box with the _searchSetting guard, create the frame if missing, and Show it before Push renders.

#### pred-07: Run RankRuns async from the AttuneNextGo click; use the cached result when present
Tags: cpu | Bundle: UI render caching | Impact: medium | Effort: small
Files: `UI.lua:5066`, `Engine.lua:2192`, `Engine.lua:2246`, `UI.lua:5020`

**What happens now.** UI.AttuneNextGo (the AttuneNext button) calls `Engine.RankRuns(nil, runMode, nil, 'btn')` synchronously (yielding=nil) whenever ANx.RunMode('btn') ~= 'off'. RankRuns is a full pass over every instance x difficulty x item (and every zone x item for 'Z'/'all') with Eligible, CountDone and ClearChance (BestSource -> Sources) per item; it is only cached per RunsKey and Engine.rev, so after any InvalidateStats the click recomputes everything on the main thread. UI.ShowRec and the cards already use RankRunsAsync; the button does not. This violates the handoff rule 'long loops go in an Engine.Enqueue job'.

**Change.** Do now (~12 lines): in AttuneNextGo replace the inline call with `local runs = Engine.RunsCached(nil, runMode, 'btn'); if not runs then Engine.RankRunsAsync(nil, runMode, function(got) if got and #got > 0 then PushRun(got[1], from, 'btn') else ANx.Print('Nothing to recommend ...') end end, 'btn'); ANx.Print('Finding your next run - one moment...'); return end`. Optionally pre-warm it in the pump's queue-drain block next to PickAsync(nil,'btn') when RunMode('btn') ~= 'off', behind the same debounce gap-cc-12 adds. Rides on proto:bestsource / gap-04 for the per-item cost.

**Expected effect.** skeptic_ui.py (stock harness, after InvalidateStats): 'mode DR cold 1662 ms, cached 0.01 ms, 25 runs; mode all cold 2707 ms'; 'UI.AttuneNextGo with run mode DR, cold: 1644 ms inline -> view items'. Pred lens measured 856 ms in its run. Both stub- and data-inflated; a cached click is ~0 ms.

**Risk.** The click answers asynchronously when cold (same UX as Show Me). Keep the 'runs:'..key tag so repeated clicks chain (identity-deduped after ui-01). A pump-side pre-warm must respect gap-cc-12's post-InvalidateStats debounce or it becomes one more universe-wide job per chip click.

#### frame-05: Cap NP.ScanEntry row walks at 1,000 rows; one pcall per item, not per row
Tags: cpu | Bundle: nameplates | Impact: medium | Effort: small
Files: `Nameplates.lua:103-122`, `Nameplates.lua:124-166`, `Nameplates.lua:580-592`, `Nameplates.lua:595-601`, `Nameplates.lua:606-618`, `Nameplates.lua:681-694`

**What happens now.** UPDATE_MOUSEOVER_UNIT and PLAYER_TARGET_CHANGED (Nameplates.lua:685) call NP.Inspect -> NP.ScanEntry (124). On an entryCache miss it enumerates ItemLocGetObjCount/At for the creature and, for each still-needed item, calls SourceInfoFor (103), which walks every source row of the item (pcall(ItemLocGetSourceAt) per row) just to find rows whose objId equals this entry. Cost is O(items x rows): a trash mob associated with a few world-drop items pays thousands of pcall'd C calls per item. The cache is per entry with a 120 s TTL, but NP.OnAttune (606) and NP.Invalidate (595) wipe entryCache and learned wholesale, so after every attune completion every mob under the cursor is rescanned. MERCHANT_SHOW -> LearnMerchant (404) does the same scan for the vendor.

**Change.** Do now, in the same Nameplates.lua pass as frame-02. Sketch: in SourceInfoFor read getCount/getAt into locals, after the count `if n > EXACT_ROW_CAP (1000) then return nil end` (falls into the existing 'rows silent -> drop' branch at :147-153), and wrap the row loop in a single pcall(function() ... end) with no per-row pcall. In ScanEntry also record info.ids[itemId] = kind for vend-only items. Change Core.lua:1696 to pass the id; in NP.OnAttune(id) collect ids into a pending set, and in the debounced callback wipe entryCache only when a nil id was seen, otherwise remove entries whose ids[] intersect the pending set; keep `learned = {}`, the indexGen bump, RefreshAllPlates and QueueRebuild(ATTUNE_WAIT) as today. Prototype of the cap/pcall half: scratch/exp_np05/Nameplates.lua.

**Expected effect.** harness_frame.py mouseover scenario (OBJN=50 items per entry, HEAVY=2000 so ~5 still-needed items per entry carry 2,000 rows): base 20 new entries = 61.24 ms total, 3.06 ms avg, 4.67 ms max per UPDATE_MOUSEOVER_UNIT (second base run 60.32 / 3.02 / 4.38; lens 3.3 / 6.8); same 20 again (cache hits) 0.011 ms avg. Experiment copy exp_np05 (locals + one pcall around the loop): no cap 54.41 ms / 2.72 avg / 3.69 max (-11%); EXACT_ROW_CAP=1000 7.34 ms / 0.37 avg / 0.56 max (-88%). Micro: pcall per row 0.314 vs 0.240 us/row. Client: ~2-3x on the Lua side, C call cost unmeasured; the lens's 10-20 ms client estimate per heavy entry is plausible but rests on the unmeasured real association count per creature and rows per item (gap-telemetry-01).

**Risk.** The cap classifies a vendor-sold item with more rows than the cap as 'drops' for that vendor (green, 'drops N') until MERCHANT_SHOW, where LearnMerchant's vendExact (:428-429) overrides; attunable gear sold by more than ~1,000 vendors is essentially nonexistent, so use 1000, not the lens's 300.

#### pred-01: Memoize Engine.Eligible and CountDone per Engine.rev (EligibleRaw split)
Tags: cpu | Bundle: UI render caching | Impact: medium | Effort: medium
Files: `Engine.lua:755`, `Engine.lua:1241`, `Engine.lua:1258`, `Engine.lua:1283`, `Engine.lua:1625`, `Engine.lua:1639`

**What happens now.** Engine.Eligible(id) has no per-item memo: every call runs ANx.CanCount (GetItemTagsCustom + CanAttuneItemHelper C calls, 2 bit.band), FactionAllowed, ~10 ANx.db global-table reads, BindAllowed/AccessoryAllowed, ANx.LevelGate('rec')->ANx.Cfg, and callers then run ANx.CountDone -> CurrentTier (GetItemAttuneForge + Progress->GetItemAttuneProgress) + ItemForgeTarget. Results are only cached per NODE key in statsCache, so the same item id is recomputed by every node that contains it within one revision: the home panel (UnionStats over all content sets per expansion), the content screen (SetStats per category, items in D and Q counted twice), the instances screen (StatsWithBest per difficulty row, an item in N/H/M evaluated 3x), the item list (ItemRows on EVERY render, uncached), search (per match per render), RankInstanceRuns/RankZoneRuns (every instance x difficulty x item, plus every zone x...

**Change.** Do now, as the foundation that micro-03, pred-08 and ui-02 build on (gap-cc-12's job-scoped memo becomes unnecessary). Sketch: `local eligMemo, doneMemo = {}, {}` cleared in InvalidateStats/InvalidateAll (eligMemo also in InvalidateOwned); rename the current body to `local function EligibleRaw(id)`; `function Engine.Eligible(id) local v = eligMemo[id]; if v == nil then v = EligibleRaw(id) and true or false; eligMemo[id] = v end; return v end`; `function Engine.EligDone(id)` returns (eligible, done) with `doneMemo[id]` = 1/2 filled from ANx.CountDone on first ask; `Engine.Left(id)`; use EligDone in Stats/SetStats/StatsWithBest/GoalStatus/rankers/pick/ZoneWatch.LeftItems/NP.StillNeeded, and Engine.Left in ItemRows and UI search (Eligible and ForgeAllowed == Left); add `Engine.NoteAttuneChange(id)` = `doneMemo[id] = nil; goalCache = {}` called from Core.lua:1694. ~150 lines over Engine.lua, Core.lua, ZoneWatch.lua, Nameplates.lua, UI.lua; keep the lens's equivalence script as the regression test.

**Expected effect.** bench.py ZONEN=100 HEAVY=0: 'root render, 0 goals [cold] 74.50 ms' with 'E.Eligible=18834 A.CountDone=12717 ... GetItemTagsCustom=18834 CanAttuneItemHelper=18834 GetItemAttuneProgress=12717 GetItemAttuneForge=12717'; structure line: '3 unions total=18834 vs universe=18266 (x1.03)' (stock run: 'x2.24'); further passes in the same revision: 'contentTypes render difficulty=all [cold] 76.13 ms' (21,239 Eligible), 'RankRuns(nil,'all') ... E.Eligible=22500', each content goal 4.7-9.5k, pick ~universe (18k): ~80k Eligible per revision for 18k unique ids on the root screen with two goals. Per-item cost (run_proto2.txt, fast bit): 'Eligible+CountDone x universe 18.5 ms' for 24,357 vs 'memo lookup x universe (table read) 4.1 ms'.

**Risk.** (1) Eligible reads nothing attune-dependent (CanCount/FactionAllowed/IsOwned/quest flags/bind/accessory/class/level), so a per-rev eligibility memo is exact; CountDone reads live progress, and ZoneWatchUpdate (Core.lua:1697, 0.8 s) and GoalHudUpdate (1698, 1 s) fire BEFORE MarkAttuneDirty's 2 s InvalidateStats (1789): a done-memo would feed both HUDs the pre-completion state and nothing repaints them afterwards (the instance HUD would keep listin...

#### ui-04: Fill cold node-list stats in a tagged job; re-measure after db-04 with the fast stub
Tags: cpu | Bundle: UI render caching | Impact: medium | Effort: medium
Files: `UI.lua:2537-2543`, `UI.lua:2557-2569`, `UI.lua:2635-2663`, `UI.lua:2192-2201`, `UI.lua:2451-2458`, `UI.lua:2487-2498`

**What happens now.** builders.instances calls Engine.StatsWithBest per instance per difficulty; builders.zones per zone; builders.home/UpdateHomePanel/contentTypes call UnionStats over whole expansion sets. These are memoized in statsCache, but InvalidateStats wipes it on every chip click, every attune completion (MarkAttuneDirty), bag updates with hideInBags, money changes with affordableOnly, level-up and instance change. The next render then runs BestSource -> Engine.Sources -> ANx.GetSources for every unattuned item in the category inline (srcCache cap is 800 after warmup, so most are rebuilt as one table per source row), producing tens of MB of garbage in one frame. Only RankRuns/Pick/Remaining got the async treatment; Stats did not.

**Change.** Later, after gap-real-db-shape-04 / proto:bestsource land; re-measure the cold root and instance renders with the fast bit stub. If the root/home/contentTypes cold render is still >50 ms harness, add Engine.StatsCached(key) and one tagged 'stats:'..viewkey job that fills the missing keys with MaybeYield per item, onDone = UI.RefreshIfShown (identity-deduped by ui-01); start with the expansion-wide UnionStats on root/home/contentTypes, which are universe-sized, and leave instance/zone lists inline unless they measure >30 ms. A cheaper partial fix for root: keep the per-expansion union set (AllContentSets union) across InvalidateStats since it depends on rows, not filters, so a cold UnionStats is a flat Eligible pass with no 8k-entry table build.

**Expected effect.** ui_bench.py MODE=views (stock stub): cold/warm ms: instances C/D 174.2 / 7.8 (9,926 KB cold), instances W/R 238.9 / 10.4 (14.7 MB), zones C/W 344.9 / 12.1 (19.1 MB), root 566.5 / 0.6, home 546.8, contentTypes 746.2 (2.5 MB), contentExp D 411.8. ui_bench3.py FASTBIT=1: 'UnionStats exp1 cold (home card) 56.3 ms 512 KB', 'StatsWithBest C/D instances cold 73.2 ms 10,666 KB', Engine.Eligible 2.32 us, CountDone 0.57 us. Not measured after gap-04: estimate root cold ~170 ms harness fast stub (3 x 8k Eligible + union build), instance list ~35 ms.

**Risk.** Placeholder flicker ('...') for 1-2 frames after every chip click; pct/left sort modes must re-sort when the stats land (just re-render). Keys must keep today's filter signature. Win_Browse shares the builders. Do not start before gap-04 / proto:bestsource: they change what StatsWithBest costs and remove most of the garbage, which is the part that made this 'high'.

#### gap-client-c-costs-07: Resolve quality/icon at paint time for the 12 visible rows; SelectItem repaints only
Tags: cpu | Bundle: filter client costs | Impact: medium | Effort: medium
Files: `Core.lua:471-510`, `UI.lua:3215`, `UI.lua:3632`, `UI.lua:2340`, `UI.lua:4058-4070`, `UI.lua:202-206`

**What happens now.** The items builder (UI.lua:3215) loops over every row returned by Engine.ItemRows and calls ANx.GetItemDisplay(r.id) to compose text/icon; the same pattern at 3632 (search, capped at 60) and 2340 (materials). GetItemDisplay (Core.lua:479-510) hits only when both itemNameCache and dispCache have the id; dispCache is capped at 3000 entries and reset wholesale (`dispCache, dispN = {}, 0` at 498), so any list longer than 3000 rows evicts itself every render, and each miss costs GetItemInfoCustom + GetItemInfo (two C calls when the custom one returns nil, as it does for ordinary items). Only 12 rows are ever painted (PaintVisibleRows, 4058-4070); UI.SelectItem (202-206) re-runs the whole builder just to show the side pane.

**Change.** Skip (a). Do (b) in its cheapest form: builders compose r.text from ANx.GetItemName(id) (one hash hit once cached) and leave quality/icon to paint time (icon = nil, itemId set); PaintVisibleRows and Win_Browse.Paint call ANx.GetItemDisplay(r.itemId) only for the <=12 rows on screen to prepend QualityHex(q) and set the icon (<=24 C calls per paint instead of ~17k per render); UI.SelectItem calls UI.UpdateSidePane() + UI.PaintVisibleRows() when the current view is unchanged instead of UI.Render(). dispCache then only ever holds screenfuls and DISP_CAP can drop to ~500. If a quality colour is wanted in the composed text without a C call, keep it in 3 free flag bits (F_QUAL) filled at paint time.

**Expected effect.** Items view with 15,969 ids / 8,518 rows, warm cache: every render GetItemDisplay 8,518 -> GetItemInfoCustom 8,518 + GetItemInfo 8,518 (renders 2 and 3 identical, 0% dispCache hits). Patched copy with the proposed two-generation cache (part a): renders 2 and 3 STILL 8,518 + 8,518, 0% hits; a simulation confirms the scheme hits 100% only for lists <= 2 x DISP_CAP = 6,000 rows and 0% above it (8,518 rows, and the ZONEN=150 list of 6,973 rows, are both above). Side-pane scenario: selecting a row = 3 renders = 17,037 GetItemDisplay. Only 12 rows are ever painted; builder rows already carry itemId (UI.lua:3251), which makes part (b) smaller than described.

**Risk.** (b) touches the items/search/materials builders and three painters (UI.PaintVisibleRows, Win_Browse.Paint, ZoneWatch); 'Item #id' fallback and name sorting (already via GetItemName) must keep working; on a cold cache only visible rows get requested, which is the intended interaction with 03. (a) is behaviour-safe but measured useless for the lists that matter.

Also reported as: ui-05, gc-13.

#### gap-real-db-shape-09: Add /an srcstats, a yielding histogram of the real loot DB's shape
Tags: load, cpu, memory | Bundle: instrumentation | Impact: medium | Effort: medium
Files: `Core.lua:1845-1853`, `Engine.lua:28`, `Engine.lua:504-514`, `README.md:161`

**What happens now.** The only shape tool today is '/an src <itemId>' (Core.lua:1845-1853), one item at a time. SRC_ROW_BUDGET, the item caps, the index slot cap, FALLBACK caps and ROW_YIELD are all tuned against a synthetic DB whose total is 435,837 rows (audit) or 533,657 rows (WDROP=100). The crash signature in the handoff (1.9-2.3 GB with a 3,000-item srcCache capped by count only) implies the cached working set alone held several million rows, i.e. the real DB has a tail 10-20x heavier than the audit DB's 100 x 1,000. Which findings matter most changes with that shape (see notes), and whether an English client is partly in fallback mode (unrecognised instance/zone spellings) is unknowable without sampling rows.

**Change.** Do FIRST and ship it in the next build before re-tuning any cap: '/an srcstats [sample]' exactly as prototyped, plus two extra lines: distinct known zones named per item for items >= 1,000 rows (bucketed 1 / 2-5 / 6-20 / 21-40 / 41+, drives the memo and index sizing) and the count of items with at least one quest or vendor row (drives the Q/V arrays and finding 07). Ask the author to paste the output; then set SRC_ROW_BUDGET, the index slot cap and ROW_YIELD from it.

**Expected effect.** Prototype Engine.SourceStats (patch_gap.py section 14, ~85 lines in Engine.lua plus the slash hook in Core.lua, so medium by the stated line scale, trivial risk) runs as a yielding job in 93-98 ms on the audit/100x1000 shapes and 208 ms in mismatch mode in the harness, printing rows-per-item buckets, rows x listings for items >= 1,000 rows, a zone-multiplicity histogram and the top unknown zone names (gap_w100_en.txt, gap_w100_mm.txt). Every cache cap in this set is currently tuned against a 435k-534k-row synthetic DB while the handoff's 1.9-2.3 GB crash with a 3,000-item count-capped cache implies a tail 10-20x heavier; my memo/index sizing (202 B/item packed memo, 4.2 KB per 40-zone world drop flat index) depends on the distinct-zones-per-heavy-item distribution this command reports.

**Risk.** Chat output only; 25-row sampling can miss unknown names that appear deep in an item's rows (acceptable for a one-off; let a second argument raise the sample). Must run after data is ready. One ItemLocGetAllItemsInZone pass over 72 zones plus one ItemLocGetSourceCount per universe item is the same work the scan does, so it is cheap on the client too.

#### gap-two-addons-pacing-02: Frame-time-aware pump budget with a shared cross-engine gate; last, with pacing-03
Tags: cpu | Bundle: pump pacing | Impact: medium | Effort: medium
Files: `Engine.lua:238`, `Engine.lua:265`, `Engine.lua:274`, `Engine.lua:286`, `AttuneNext-Simple/Engine.lua:265`

**What happens now.** pumpFrame's OnUpdate (Engine.lua:265) ignores its `elapsed` argument: it resumes the front job until Clock()-start >= BUDGET_MS (10, Engine.lua:238/274) and then always calls collectgarbage('step', 2048) (Engine.lua:286). The cost per frame is therefore constant in milliseconds, not in share of the frame: on a 60 fps machine 16.1 ms of a 16.7 ms frame (49%), on a 2.5x slower CPU 23.4 ms emulated (58%; the fixed GC step costs 9.7 ms there, see finding 03). With AttuneNext-Simple loaded a second identical pump runs in the same frame on the same global collector, so the pair costs 33.9 ms per frame (67% of a 60 fps frame, 19.8 fps during the scan) and 49.6 ms on the slow CPU (75%, 15 fps). Neither pump knows the other exists.

**Change.** Do later, after 01/04/03, and with the threshold rule rather than the share rule: `local frameMs = (elapsed or 0) * 1000; local budget = BUDGET_MS; if frameMs > 22 then local f = math.min(1, (frameMs - 22) / 45); budget = BUDGET_MS - f * (BUDGET_MS - BUDGET_MIN_MS) end` (22 ms = 45 fps, 67 ms = 15 fps), then `budget = budget - gate.used; if budget < 2 then return end`, run resumes for the whole budget when frameMs <= 22 (no GC reservation on short frames) and for budget*(1-GC_FRACTION) otherwise, then the 03 step. Keep the ten-line shared gate (`_G.AttuneNextPumpGate = {t, used, prevTotal}` rolled over when GetTime() changes) so two engines never exceed one budget per frame; with 01 Simple's pump only ever runs warmup/pick jobs so the gate is cheap insurance. Optional 'scan: smoother/faster' setting = BUDGET_MIN_MS 3 vs 6. Re-check /an perf peak after a forced rescan on the slow machine.

**Expected effect.** Baseline today: alone 60 fps 16.3 ms/frame (49% of the frame), slow 2.5 24.1 ms (59%, 24.5 fps); pair 34.1 ms (67%, 19.7 fps). Prior pace3 (share 0.35 of game time, clamp 3..10 ms, one gate per frame, with 03+04): alone 60 fps 10.0 ms (37.5 fps) but wall 18.3 s vs 13.5; alone slow 2.5 11.5 ms (35.5 fps) wall 45.6 vs 38.2 s; pair 30 fps slow 2.5 13.3 ms (21.5 vs 12.0 fps) wall 154 vs 82 s. NEW vsync/fps-cap emulation (exp_gaplens/harness_vs.py: frame = max(16.7 ms, game CPU + addon CPU)): with 6.7 ms of game CPU the stock pump already drops to 43 fps and pace3 holds 56.8 fps at 19.2 s wall (a fair trade); but with 1 ms of game CPU (headroom, stock pump 51.8 fps, 7.9 s wall) the share rule still collapses the budget to 6.7 ms/frame and takes 18.7 s (2.4x) for +6 fps, because a capped frame reports 16.7 ms regardless of CPU load and the rule reads the idle wait as 'game time'.

**Risk.** The share-of-game-time formula is wrong for fps-capped or vsync clients (common on laptops and in WoW's own settings): it doubles the scan time with no fps gain; use a frame-length threshold instead. All budget rules lengthen the scan (toast later, first screens cold longer): 35-90% more frames alone, up to 2.4x in the pair unless 01 removes the second scan. Only matters on rescan logins (cached logins run no scan).

**Prototype.** `proto:pacing`, diff `prototypes/proto_pacing.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: scan-11.

#### gap-two-addons-pacing-06: Land proto:svpack: packed structCache, lazy zone decode, yielding scan-end export job
Tags: load, memory | Bundle: saved structure | Impact: low | Effort: small
Files: `Engine.lua:158`, `Engine.lua:186`, `Engine.lua:294`, `Core.lua:1679`, `Core.lua:1643`, `Core.lua:1774`

**What happens now.** Each addon does Engine.ImportCache(true) at ADDON_LOADED (ArrayToSet of every summary array, Core.lua:1679 / Simple 1662), ImportCache() again at data-ready (Core.lua:1643), Engine.ExportCache inline in the pump when the queue empties (Engine.lua:294-297: SetToArray of every set), and ExportCache again at PLAYER_LOGOUT (Core.lua:1774) even when cacheDirty is false and ANx.db.structCache is already current. The client also compiles two ~2 MB SavedVariables files at login.

**Change.** Do later, bundled with 05 as one 'persist' job: at scan end enqueue `Engine.ExportCache(true)` (MaybeYield between SetToArray calls, abort if rev ~= startRev, clear cacheDirty only on completion) followed by the status export; Core.lua:1774: `if ANx.Engine and (ANx.Engine.CacheDirty() or not (ANx.db.structCache and ANx.db.structCache.summaries)) then pcall(ANx.Engine.ExportCache) end` with `function Engine.CacheDirty() return cacheDirty end`. Skip the Simple side once 01 is in (it has no structCache then).

**Expected effect.** IMPORT_TEST today: ExportCache 31-39 ms per call, ImportCache(provisional) 24-38 ms, ImportCache(validated) 24-55 ms (noisy; the finding's 73.6 ms provisional figure is the top of that range). PLAYER_LOGOUT = 243 ms of which ExportCache is 38 ms (the rest is finding 05). Scan-end inline ExportCache 32-39 ms in one frame. Cached-login check: the validated import nils sc.summaries (Engine.lua:214), so after the common cached login the logout export is still required and the proposed condition correctly keeps it; the -38 ms applies only to sessions that rescanned, where the pump already wrote structCache. Pair: Simple's two imports (24+24 ms), two exports (38+38 ms) and its ~2 MB SavedVariables compile (lupa 24 ms per 1.45 MB; x2-3 client) vanish entirely with finding 01.

**Risk.** The `not sc.summaries` clause is load-bearing: without it a session that only imported would log out with no summaries and the next provisional import would show empty lists until data-ready. If the scan-end export becomes a yielding job, InvalidateAll (which wipes Engine.scanJobs) can kill it mid-way: keep cacheDirty true until the export completes, and abort the write if Engine.rev changed while yielding so a half-built summaries table is never...

**Prototype.** `proto:svpack`, diff `prototypes/proto_svpack.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: scan-06, load-06, gc-07, mem-02, load-05, scan-08, load-07, mem-06.

#### ui-07: Convert the ten TGA atlases to BLP2 DXT5 with mips; then downscale icons/emblem/logo
Tags: memory, load | Bundle: textures | Impact: medium | Effort: medium
Files: `Textures/`, `Data_Art.lua:5-190`, `UI.lua:264-293`, `UI.lua:400-432`, `UI.lua:2579`, `UI.lua:2588`

**What happens now.** All ten atlases are TGA type 2, 32 bpp, uncompressed (icons/ui_chrome/ui_controls/thumbnails_01-05 at 1024x1024 = 4,194,348 bytes each; emblem 512x512 and logo 1024x256 = 1,048,620 each). TGA cannot carry mip levels, so the client uploads the raw 4 MB image per atlas (D3D9 managed-pool textures also keep a system-memory copy in the 32-bit address space) and samples icons drawn at 15-24 px from 128 px cells, and thumbnails drawn at 26-68 px from 256x192 cells, with no mips. First CreateMainFrame binds ui_chrome (corners/borders/divider/bezel), ui_controls (chip/button plates, hover, search field, cards, progress), icons (nav/chip/header icons) and the logo: 13 MB of decode on the first /an; the emblem is bound at ADDON_LOADED by the minimap button (Settings.lua:285 via Core.lua:1673) and the logo again by GoalHud 6 s after data ready (goalHud defaults true).

**Change.** Do now, in two steps. Step 1 (no code change): convert all ten TGAs to BLP2 DXT5 with full mip chains at their current dimensions and keep the same base names; verify each sheet in-client (chrome/controls edges and gradients, icon alpha); this alone cuts 31 -> ~12 MB and fixes the minification shimmer. Step 2: downscale icons to 512^2, emblem to 128^2 and logo to 512x128 (UVs are normalized, so still no Data_Art change), and optionally regenerate the thumbnails as 128x96 cells in two 1024^2 sheets with regenerated thumb_* UVs (needs the art manifest). Do not change GoalHud's zero-goals behaviour for this; it is moot once the logo sheet is ~90 KB.

**Expected effect.** not measured: the harness has no texture decode/upload path and no client. File/pixel arithmetic from the headers: TGA 31.4 MB on disk = decoded size; BLP2 DXT5 with mips at the same dimensions: 8 x 1.40 MB + 0.35 + 0.35 = ~11.9 MB; with the proposed downscale (icons 512, thumbnails 512, emblem 128, logo 512x128, chrome/controls kept at 1024): ~5.0 MB. Login-bound bytes drop from 2.1 MB (emblem + logo) to ~0.1 MB. First-open bound bytes from ~12.6 MB (3 sheets) to ~3.2 MB (same-size DXT5) or ~1.7 MB (icons downscaled).

**Risk.** DXT5 block compression can band the painted plates/gradients in ui_chrome/ui_controls (preview in-client; fall back to uncompressed BLP2 at 512 for any sheet that bands). Needs an offline converter (BLPConverter / BLP Lab / a python BLP2 writer) - no tooling in the repo.

Also reported as: load-10.

### Tier 3: Small wins and housekeeping (26 items)

Low impact or narrow scope. Do them when the code is open anyway.

#### micro-07: Hoist SRC constants and use numeric for in row loops, inside the streaming patches
Tags: cpu | Bundle: streaming source rows | Impact: low | Effort: small
Files: `Engine.lua:485-486`, `Engine.lua:522-525`, `Engine.lua:531-547`, `Engine.lua:607-608`, `Engine.lua:633`, `Engine.lua:661`

**What happens now.** Every per-row loop in Engine (BestSource, IsQuestOnly, ItemQuestSide, ItemQuestCharBlocked, IsZoneExclusive, ItemHasRareSource, ItemIsUniqueToZone, IsCraftObtained, ItemBestDropChance, ZoneData) uses `for _, s in ipairs(...)`, which in Lua 5.1 is a C iterator call per element, and compares `s.srcType == ANx.SRC.QUEST` (upvalue + two table indexes per row) or `ANx.WORLD_DROP_SRC[s.srcType]`; SourceUsable adds a Lua call per row inside BestSource. ZoneData walks each item's rows once to decide matchedThisZone/recognized and a second time to classify, although the second pass only differs when NOTHING matched and nothing was recognised (localized client). These loops run over every source row during the scan (~880k row-visits x2 in ZoneData for the harness DB), the warm-up and every cold render.

**Change.** Later / ride with the prototypes: do not land this as a separate change. Fold its three ingredients into the streaming patches where they are not already present: (1) file-level `local SRC = ANx.SRC; local SRC_QUEST, SRC_VENDOR, SRC_CREATURE, SRC_MYTHIC_CREATURE, SRC_CRAFT_TRAINER, SRC_CRAFT_RECIPE = ...; local WORLD = ANx.WORLD_DROP_SRC` at the top of Engine.lua (prototype A/bestsource define them locally per function today), (2) `for i = 1, #srcs do local s = srcs[i] ... end` in the loops the prototypes leave materialized (ItemHasRareSource 607, IsCraftObtained 945, the srcCache fast paths in EachSourceRow/ItemBestDropChance, UI.lua:3367 copy), and (3) AddSet (1546) as `for i = 1, #ids do set[ids[i]] = true end`. Delete ItemIsUniqueToZone/FilterZoneExclusive (628-651) or leave them; nothing calls them. If the prototypes are NOT shipped, the standalone version is still worth its ~30 lines for ~4% scan frames and a ~2x BestSource, but it is the smallest win in this area.

**Expected effect.** lupa.lua51 micro (skp/mb_rows.py, 1,000-row array x1000, 1M row visits): `ipairs + ANx.SRC.QUEST (stock) 67.8 / 59.7 ms`, `numeric for + local const 36.6 / 35.4 ms`, `ipairs + local const 47.0 ms`, `numeric for + ANx.SRC.QUEST 44.3 ms` (1.7-1.9x; both effects contribute about equally). `AddSet ipairs (stock) 3M ids 106.4 ms` vs `AddSet numeric for 3M ids 58.7 ms` (-48 ms once per fresh scan = ~4 of ~400 scan frames). harness_orig.py: tools/exp_micro (rows + numeric BestSource at its Engine.lua:532, SRC_QUEST/SRC_VENDOR local at 521, WORLD local in ZoneData, plus unrelated memo changes) `scan finished at frame 644`, `peak 115291 KB` vs exp_rows 674 / 108,750 KB (-4% frames; the higher peak is its retained ClearChance memo, not the loops).

**Risk.** Mechanical and semantics-preserving on the dense arrays GetSources returns (numeric for over #srcs stops where ipairs stops). Keep the `zl ~= ""` guard if ZoneData is fused on stock so the localized-client fallback is unchanged. Hoisted locals must stay below the `ANx.SRC` definition in load order (they are).

#### gap-real-db-shape-08: Compute the drop chance once per pool item before sorting; route via the db-04 index
Tags: cpu | Bundle: streaming source rows | Impact: low | Effort: small
Files: `Engine.lua:1855-1862`, `Engine.lua:1879-1886`, `Engine.lua:1759-1767`

**What happens now.** With anext.dropRate on (default off, Core.lua:186), AttuneNextPick first calls ItemBestDropChance for every pool item (1858) and then sorts the pool with a comparator that calls ItemBestDropChance(x) and (y) again (1884). ItemBestDropChance iterates Engine.Sources (1761), so each of the ~P log2 P comparisons re-reads two arrays and, because the post-warmup srcCache holds only 800 items / 60,000 rows and the pool is thousands of items including world drops, re-materializes them through ANx.GetSources. table.sort is a C function, so no yield can happen inside however 'yielding' the job is.

**Change.** Do now (trivial): in the a.dropRate branch (Engine.lua:1856-1861) store dropOf[id] = Engine.ItemBestDropChance(id) while filtering, and sort with function(x, y) return (dropOf[x] or 0) > (dropOf[y] or 0) end (patch_gap.py section 12). When finding 04 lands, route ItemBestDropChance through the index so the one computation per pool item is an index hit for items already seen by a zone list or tooltip.

**Expected effect.** Author's PICKDROP probe at 100x1000 (dropRate forced on): stock 901 ms, 258,053 row tables, 57,437 GetSources calls for a 7,979-item pool (the comparator makes ~2 P log2 P ~ 200k ItemBestDropChance calls, each an ipairs over a possibly re-materialized array); prototype 371 ms, 0 rows, identical pick 14579 and pool size. The remaining 371 ms is Eligible/ItemBucket work shared by both. Default is off (Core.lua:186), so this is opt-in only. Not re-measured: the fix is a 10-line local change whose effect is bounded above by the stock comparator cost.

**Risk.** None functionally: the pick is identical on the synthetic DB; table.sort is unstable either way. Keep the sort inside the existing job (AttuneNextPick runs under PickAsync) and never yield from the comparator. With finding 04 ItemBestDropChance becomes BestSource(id, nil, DROP_SRC) and must preserve 'nil when no drop-type source has chance > 0'.

**Prototype.** `proto:stream-B`, diff `prototypes/prototype_stream.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: pred-06, mem-08, gc-09.

#### load-13: Poll data-ready at 0.2 s; replace WatchRefreshDone's poll with the status job's onDone
Tags: load | Bundle: pump pacing | Impact: low | Effort: small
Files: `Core.lua:1706-1727`, `Core.lua:1615-1626`, `Core.lua:1649`

**What happens now.** PLAYER_LOGIN starts poll(), which checks GetCustomGameData(41,0) once per second (ANx.After(1, poll)) for up to 600 tries; the SynastriaSafeInvoke callback may fire earlier but the handoff says that queue is cleared on /reload, so the poll is the effective trigger there. WatchRefreshDone likewise re-arms every second until the job queue is empty before toasting and exporting the status cache. The polls themselves cost nothing measurable; the cost is latency: the whole scan starts up to 1 s (mean 0.5 s) after the server is ready.

**Change.** Do now the one-line part: `ANx.After(tries <= 300 and 0.2 or 1, poll)` in both re-arm sites (Core.lua:1721, 1726). Fold the WatchRefreshDone replacement into gap-pacing-05/tf-07 instead of a standalone change: once the status export is an Engine.Enqueue job, WatchRefreshDone can enqueue it once at +2 s (FIFO puts it after summary1-3; it uses only live C APIs, not the warmup) with onDone = InvalidateStats + EnsureWarm + RefreshIfShown + Toast, and the 1 s poll disappears. Alternative if pacing-05 is not taken: an Engine.idleHooks list fired in the pump's end-of-queue block (Engine.lua:289-310) after the warmup/pick conditionals when scanJobs is still empty (~8 lines).

**Expected effect.** cd scratchpad/tools && ADDON=/home/user/AttuneNext NOSV=1 NITEMS=20000 ZONEN=600 HEAVY=200 READY_AT=5.3 FRAMES=420 python3 -I harness_orig.py (harness stubs SynastriaSafeInvoke as a no-op = the /reload case): 'frame 364 lua 10737 KB notready jobs=[]' then 'frame 378 lua 8406 KB ready jobs=[summary1,summary2,summary3]' -> ready at 5.3 s detected at 6.0-6.3 s, i.e. 0.7-1.0 s late; a 0.2 s poll bounds that at 0.2 s (mean 0.1 s). WatchRefreshDone latency not separately measured: <= 1 s by construction on rescan logins, 0 on cached logins.

**Risk.** None: the lastDataReadyAt guard (Core.lua:1630-1633) collapses a double fire from the invoke and the poll; GetCustomGameData(41,0) is one C call five times a second for at most 60 s. The idle-callback half must not run before the summary jobs (ExportStatusCache needs Engine.Universe() ready).

#### gc-06: Drain the collector for a few frames after the queue empties (rider on the status job)
Tags: memory | Bundle: pump pacing | Impact: low | Effort: small
Files: `Engine.lua:265-270`, `Engine.lua:287-310`

**What happens now.** pumpFrame's OnUpdate hides the frame as soon as scanJobs is empty (Engine.lua:269), so the per-frame collector steps stop at the exact moment the scan-end work (ExportCache copies, ExportStatusCache string building, the pick's pool/seen tables) has just produced its last garbage. Lua 5.1's incremental collector then only advances in proportion to NEW allocation (pause 200 = next cycle starts at 2x the live estimate), and an idle addon allocates almost nothing, so that garbage stays resident until other addons' allocation drives the cycle to completion.

**Change.** Later, as a ~12-line rider on two other changes, never standalone as written. Prerequisite: gap-two-addons-pacing-05 / gap-telemetry-and-harness-fidelity-06 (ExportStatusCache as an Enqueue'd 'statuscache' job) so that the only scan-end garbage producer runs INSIDE the pump; also pair with gap-client-c-costs-12, because today WatchRefreshDone's InvalidateStats (Core.lua:1619) nils the 'btn' pick and the end-of-queue block re-runs the whole pick after the status job, which is what incidentally sweeps most of the export garbage in my statusjob run. Implementation inside proto:pacing's pump (proto_pacing.diff keeps the `if not job` branch unchanged): add `local drainFrames = 0`; in the end-of-queue block (Engine.lua:296-298) set `drainFrames = 40`; make CollectSome return true when a step reports cycle end; in the `if not job` branch do `if drainFrames > 0 then drainFrames = drainFrames - 1; if CollectSome(Clock(), PumpBudget() * GC_SHARE) then drainFrames = 0 end; if drainFrames > 0 then return end end` before Hide().

**Expected effect.** cd scratchpad/gc06; for v in orig drain1 drain2 drain1_statusjob drain2_statusjob: ADDON=$PWD/exp_$v NOSV=1 NITEMS=20000 ZONEN=600 HEAVY=200 READY_AT=5 FRAMES=1100 GCMODE=orig TRACE=1 python3 -I gc_harness06.py > run_$v.log (copies at scratchpad/gc06/exp_*; setup script gc06/setup.py). orig: 'GC06 job dead tag=pick:btn|global t=12.272 mem=74699 KB' -> 'GC06 pump hide t=12.288 mem=74702 KB' -> 'GC06 WatchRefreshDone t=13.088 inv+refresh +1 KB export +4470 KB now 79260 KB' (plateau for the rest of the run). drain1 (as proposed): poll landed 1 frame after job death, 'GC06 drain cycle end #1 t=12.144 mem=74566 KB framesLeft=35' (all 4.6 MB recovered). drain2: 'drain cycle end #1 t=12.368 mem=73797' / '#2 t=12.560 mem=73794' then 'WatchRefreshDone t=13.088 ... now 78328 KB' (drain recovered 0; 2nd cycle recovered 0).

**Risk.** The drain's only real cost is moving one atomic-phase frame (14-23 ms harness, ~30-60 ms client for a ~50 MB heap) to immediately after the scan instead of an unpredictable later moment; bounded by the frame cap. collectgarbage('step', n) returning true at cycle end is plain Lua 5.1 lbaselib (lua_pushboolean(res)) and works on the 3.3.5 client. Do not drain for more than one cycle (measured 0 KB gain, +2 atomic frames).

#### frame-07: Guard SnapshotAltCan on SummariesReady so it stops re-polling Universe every 5 s
Tags: cpu, load | Bundle: pump pacing | Impact: low | Effort: small
Files: `AltCache.lua:27-34`, `Engine.lua:114-136`, `Engine.lua:2222-2235`, `Core.lua:1653`

**What happens now.** ANx.SnapshotAltCan is scheduled 8 s after data ready (Core.lua:1653). It calls Engine.Universe() (Engine.lua:114), which, while any summary is not ready, builds a set of every id in the ready summaries + VendorCosts + AllEventItems, converts it to an array, does not cache it (allReady false) and returns it; SnapshotAltCan then discards it and re-arms a 5 s timer. On a slow login scan this repeats several times, each time allocating ~1-2 MB of transient table data and sweeping tens of thousands of entries.

**Change.** Do now: the 5-line guard in scratch/exp_f07/AltCache.lua (before calling Universe(): `if not ANx.Engine.SummariesReady() then ANx.After(5, ANx.SnapshotAltCan) return end`), keeping the existing `#universe == 0` check. Keep the snapshot on its 0.1 s timer chunks rather than moving it into Engine.Enqueue: it is a C-call loop, not table work, and in the pump it would only compete with the warmup and pick jobs for the 10 ms budget. If gap-telemetry-and-harness-fidelity-07's Engine.EnsureWarm refactor lands, kick SnapshotAltCan from that same scan-done point and drop the 5 s re-arm entirely. Independent of prototypes A-D, bestsource, datapack, svpack and pacing (none touch Universe's not-ready path or AltCache); gap-two-addons-pacing-04's MaybeYield inside Universe only helps the coroutine caller and does nothing for this main-thread timer, so the two are complementary. Name the AltCache.lua:32 site per gap-telemetry-04 so /an perf shows it if it ever reappears.

**Expected effect.** Instrumented harness (copy of harness_timers.py logging every AltCache callback and wrapping Engine.Universe): scratch/f07/harness_f07.py. Stock, `ADDON=/home/user/AttuneNext NOSV=1 NITEMS=20000 ZONEN=600 HEAVY=200 READY_AT=5 FRAMES=1500`: 'scan finished at frame 800'; Universe calls: '25.31 ms +1190 KB n=24357 ready=true caller Engine.lua:360 t=9.8' then '0.00 ms +0 KB n=24357 ready=true caller AltCache.lua:30 t=13.0' (0 wasted polls). Stock HEAVY=2000 FRAMES=3000: 'scan finished at frame 2458'; '2.51 ms +454 KB n=5401 ready=false caller AltCache.lua:30 t=13.0', '14.18 ms n=5401 ready=false t=18.0', '8.23 ms +1185 KB n=22063 ready=false t=23.1', '10.31 ms +1185 KB n=24074 ready=false t=28.1', '0.00 ms n=24357 ready=true t=33.1' (4 wasted polls, 35 ms, ~4 MB garbage).

**Risk.** None functional. Engine.SummariesReady (Engine.lua:2222-2235) ignores the 'warmup'/'pick' tags, so the snapshot still starts as soon as the three summaries land; the one-off Universe() build (10-12 ms) is then paid by whichever of the warmup (Engine.lua:360) or the snapshot runs first and cached for the other, never twice.

#### mem-09: Fold cacheRequested and cacheQueued into one itemFlags bit inside cc-03's rewrite
Tags: memory | Bundle: filter client costs | Impact: low | Effort: small
Files: `Core.lua:534-546`, `Core.lua:394-456`, `Engine.lua:41-44`

**What happens now.** ANx.RequestItemCache marks each unresolved item id in its own hash (Core.lua:534-541). On a fresh client cache most of the universe is unresolved on the first renders/searches, so the set grows to one hash node per universe item. itemFlags already holds one packed number per universe item (bits 0-24 used: F_MINLVL at 15 + 10 bits), and the 3.3.5 bit library handles 32-bit values, so bits 25-31 are free.

**Change.** Do later, as part of gap-cc-03 (which rewrites RequestItemCache anyway, so the marginal cost is ~10 lines): narrow F_MINLVL to 8 bits (mask 255, clamp 253), add `ANx.F_REQ = 23`, and use that one bit for BOTH cc-03's cacheQueued and cacheRequested ('asked or queued this session'), so only the numeric cacheQueue array remains: `if ANx.FlagGet(id, F_REQ, 1) == 1 then return end; ANx.FlagSet(id, F_REQ, 1, 1); cacheQueue[#cacheQueue+1] = id`. Not worth a standalone change.

**Expected effect.** python3 -I scratch/verify_clp/bench.py (Lua 5.1): 'mem-09 cacheRequested hash, 20,000 SPARSE ids (64-bit lupa) 3.02 ms alloc 1280 KB' (the lens's 672 KB was for dense harness ids in the array part; real sparse ids are hash-backed: ~1 MB on 32-bit); 'extra alloc for setting a flag bit on 20k entries: 0 KB'. Saving applies only in cold-cache sessions (first login after install/patch/cache wipe), which are also the sessions with the most tooltip-scrape and request pressure.

**Risk.** Layout change touches five mask constants and ANx.FLAGS_FORMAT if cc-01's tipCache or pacing-01's sharing keys on it; a custom item with requiredLevel > 253 would clamp to 253 (still above any 3.3.5 character, so no behavioural change).

#### pred-14: Add IsQuestOnly (qonly) to NeededPredicates/WarmPredicates as a rider on cc-05
Tags: cpu | Bundle: filter client costs | Impact: low | Effort: small
Files: `Engine.lua:333`, `Engine.lua:476`, `Core.lua:826`, `Core.lua:838`

**What happens now.** ANx.ItemForgeTarget calls Engine.IsQuestOnly(itemId) whenever ForgeLevel() > 1; IsQuestOnly is flag-cached (F_QONLY) but a cold entry walks Engine.Sources(itemId). The warm-up only sweeps bind/acc/qside/lvl/zex/qchar; F_QONLY is filled as a side effect of ItemQuestCharBlocked, which is only swept when db.scope ~= 'account' and questClass ~= 'all'. Under account scope (or All classes) with Forge Level >= 2 the first stats pass computes IsQuestOnly inline for every counted item (one GetSources per item, thrashing the 800-entry source cache).

**Change.** Later, as a rider on gap-client-c-costs-05's NeededPredicates/WarmPredicates extension (same two functions, ~8 lines): add `qonly = ANx.ForgeLevel and ANx.ForgeLevel() > 1 or false` to NeededPredicates (Engine.lua:333-348), `local doQOnly = need.qonly and not warmed.qonly` and `if doQOnly then Engine.IsQuestOnly(id) end` in the sweep loop (358-396), `if doQOnly then warmed.qonly = true end`; keep it after doQChar so the qchar sweep's side effect makes it a flag hit. Pair it with cc-05's deferral (`Engine.CachesWarm()` returning `cachesWarm and not Engine.WarmupIncomplete()` and the home/content builders rendering placeholders while a top-up is queued) so the forge-chip render under account scope waits for the sweep instead of filling inline. Ship prototype D first: it shrinks the cold cost 10x regardless of this change, which then only matters for the account-scope / All-classes minority.

**Expected effect.** skp/harness_pred14.py (harness.py + db injection, CALLERS=1, stock bit stub): default config `24357 calls 436000 rows Engine.lua:449 < Engine.lua:480 < Engine.lua:708 < Engine.lua:388` (F_QONLY filled by the qchar sweep at login, as the finding says). ACCT=1 FORGE=2 (scope=account, forge 2 saved): `20000 calls 436000 rows Engine.lua:449 < Engine.lua:480 < Core.lua:828 < Core.lua:839 < Engine.lua:1845` - filled by the background pick job, scan 864 vs 850 frames, no inline cost.

**Risk.** Same predicate computed earlier on the pump; no saved data changes. warmed.qonly needs no explicit reset: F_QONLY is only cleared by InvalidateAll (Engine.lua:96-103), which also resets `warmed`. The sweep adds up to one IsQuestOnly per universe item to the warmup when forge >= 2 under account scope (free under the default scope because the qchar sweep already fills it).

#### gap-client-c-costs-09: Memoize FitText on (text, width); strip colour codes once per call
Tags: cpu | Bundle: filter client costs | Impact: low | Effort: small
Files: `UI.lua:1843-1861`, `UI.lua:4058-4070`, `UI.lua:1175-1177`, `UI.lua:4180-4190`, `Win_Browse.lua:319`, `UI.lua:4795-4800`

**What happens now.** UI.FitText (UI.lua:1843-1861) sets the text, measures it, and if too wide loops up to 60 times: drop 3 chars, run two gsub counts over the whole string to balance colour codes, SetText, GetStringWidth. PaintVisibleRows (4058-4070) calls it twice per visible row (12 rows) on every render AND on every scroll notch (OnVerticalScroll at 1175-1177), Win_Browse.Paint once per row, UpdateSidePane 3-5 times. In the side-pane layout anxTextW is 180 px (4180-4190: rowW 384 - reserve 158 - 46) so most item names (~30-40 chars at ~6.5 px) must be trimmed by 10+ chars. In the client each SetText invalidates and each GetStringWidth forces a FontString layout (est. 10-40 us each).

**Change.** Do later, memo only: `if fs.anxFitSrc == text and fs.anxFitW == maxW then return end` at the top of UI.FitText and set both at the end; strip colour codes once into a plain string and rebuild lead..plain:sub(1,k)..'...'..'|r' per iteration instead of running two gsub counts each step. Skip the proportional first cut and the module-level fitMemo table.

**Expected effect.** Harness paint counts: instances screen full render = 3 paints, GetStringWidth 45, SetText 196; one scroll notch 24 GetStringWidth / 48 SetText; side-pane layout (anxTextW 180 px) one notch 44 / 68, full render 121 / 253. Micro-benchmark of the proposed FitText (memo + proportional cut + <=3 refinement steps) vs the current loop over 7 realistic lines: with the uniform 6.5 px/char model totals fall 35 -> 22 layouts (the 76/82-char lines 10-12 -> 4, 34-char titles at 180 px 5 -> 4); with a varied glyph-width model the current loop already converges in 1-7 steps and the totals are 20 -> 19, i.e. the proportional cut gains ~nothing on item-name-length strings; the memo gives 0 layouts on repaint of unchanged text (measured 0/0). Not measured: client SetText/GetStringWidth cost (est. 10-40 us each -> ~1-3 ms per scroll notch today).

**Risk.** Colour-code reconstruction must keep the trailing '|r' or the row colour leaks; the proportional cut can overshoot by a glyph (the +-2 refinement handles it); the memo key must include maxW because the side pane changes anxTextW.

Also reported as: ui-10.

#### pred-10: Snapshot filter config into upvalues inside pred-01's EligibleRaw rewrite
Tags: cpu | Bundle: UI render caching | Impact: low | Effort: small
Files: `Engine.lua:755`, `Engine.lua:778`, `Engine.lua:779`, `Engine.lua:1817`, `Core.lua:682`, `Core.lua:771`

**What happens now.** Engine.Eligible re-reads ANx.db (a global-table field) up to 10 times per call, calls ANx.LevelGate('rec') -> ANx.Cfg -> db.rec per item, and when the window level gate is on calls Engine.ItemLevelOk(itemId, true) without a charLvl so ANx.CharLevel() -> _G.UnitLevel('player') runs per item. ANx.IsAttunableAtAll evaluates `bit.band(t,64) ~= 0 and bit.band(t,32) == 0` (two C bit calls) where `bit.band(t, 96) == 64` is one. This is the first-pass cost that remains after the pred-01 memo.

**Change.** Later, folded into pred-01's EligibleRaw rewrite (same lines). At the end of InvalidateStats/InvalidateAll set upvalues fAcct = db.scope == 'account', fFac = db.faction (nil when 'both'), fBags, fQChar = scope=='char' and questClass~='all', fZex, fBind = bindFilter ~= 'both', fAccOff = accessories == false, fClass = prestige and classFilter~='all' and classFilter, fLevel = ANx.LevelGate('rec'), fCharLvl = ANx.CharLevel(); EligibleRaw reads them and passes fCharLvl to ItemLevelOk; change Core.lua:1402 to `band(t, 96) == 64` with the file-local band (and the other four global-bit sites). ~30 lines.

**Expected effect.** Not re-measured here. Micro lens (scratchpad/tools/mb_addon.py, FASTBIT, 24,357 items x3): Engine.Eligible 161 ms vs the snapshot variant with identical predicates 132 ms, i.e. ~0.4 us/item of wrapper overhead, 18% of Eligible's lupa cost; the remaining 82% is the stubbed C calls. Converting: ~8 ms per 20k-item pass in lupa, ~15-25 ms on the client, once per revision after pred-01, plus one UnitLevel C call per item avoided when the level gate is on (36,501 per cold root render in the stock harness).

**Risk.** The snapshot must be refreshed at the end of InvalidateStats/InvalidateAll; every filter change already calls InvalidateStats (chips UI.lua:930-1052, ResetFilters/RestoreFavorite 5093/5119, Settings.lua 104-162, ApplyDefaults path Core.lua:252) and PLAYER_LEVEL_UP does too (Core.lua:1770) which refreshes charLvl.

Also reported as: micro-12.

#### pred-11: Add ScopeLeftBoth so RemainingReport runs the gate chain once per item (in ui-02)
Tags: cpu | Bundle: UI render caching | Impact: low | Effort: small
Files: `Engine.lua:1027`, `Engine.lua:1050`, `Engine.lua:985`

**What happens now.** For every universe item the report loops `for _, scope in ipairs({'char','acct'})` and calls Engine.ScopeLeft(id, scope); ScopeLeft starts with ANx.IsAttunableAtAll (GetItemTagsCustom) and ends with FactionAllowed/IsOwned/IsZoneExclusive/BindAllowed/AccessoryAllowed/ItemUsableByClass, all of which are scope-independent and therefore computed twice per item; the `{ 'char', 'acct' }` table is also allocated per item.

**Change.** Later, inside the ui-02 change (same function): add `local function ScopeLeftBoth(id)` that returns (char, acct): `if not IsAttunableAtAll(id) then return false, false end; if not <gate chain once> then return false, false end; return CanCharAttune(id) and not IsAttuned(id), not AccountHasVariant(id)`; hoist `local SCOPES = { 'char', 'acct' }` to file scope for the remaining literals (121, 1088, 1195, 1555). ~15 lines.

**Expected effect.** bench.py ZONEN=100 HEAVY=0: 'RemainingReport() sync rebuild alone 78.87 ms alloc~3876 KB' with 'A.IsAttunableAtAll=36532 E.ScopeLeft=36532 GetItemTagsCustom=36532' for an 18,266-id universe (exactly 2x), 'CanCharAttune=13909 HasAttunedAnyVariantOfItem=13909'; 'whatsleft render [cold: builder runs RemainingReport inline] 124.02 ms'. Stock: 107.6 ms / 5.1 MB, 48,714 for 24,357 ids. Dedupe removes ~18k GetItemTagsCustom calls, ~18k gate chains and ~1.2 MB of throwaway tables per report (client ~2-3x: ~50-80 ms less per report build).

**Risk.** Pure refactor: all predicates are side-effect-free apart from idempotent flag caching, so evaluating the shared gates once before the two scope tests yields identical results; keep Engine.ScopeLeft's public form for RemainingByCategory/RemainingCraftByProf/RemainingMaterials. The inline-build problem itself is ui-02's fix (remove the synchronous call at UI.lua:2237), not this finding's.

#### pred-08: Read forge/progress once per ItemRows row via a TierFrom helper (with pred-01)
Tags: cpu | Bundle: UI render caching | Impact: low | Effort: small
Files: `Engine.lua:1283`, `Engine.lua:1289`, `Engine.lua:1290`, `Engine.lua:1295`, `Engine.lua:1297`, `Core.lua:802`

**What happens now.** Per row ItemRows calls Engine.Eligible (GetItemTagsCustom + CanAttuneItemHelper), ANx.ForgeAllowed -> CurrentTier (GetItemAttuneForge + IsAttuned -> Progress), ANx.CountAttuned -> Progress again, ANx.CurrentTier again (forge + progress again), AccountHasVariant, and ANx.Progress a fourth time. ItemRows is not cached: builders['items'] rebuilds it on every UI.Render (every chip click, selection, 2 s progress-tick refresh) and ZoneWatch rebuilds it for the HUD.

**Change.** Later, bundled with pred-01 (EligDone supplies eligible+done for the ForgeAllowed test): per row read `local progress = ANx.Progress(id)` and `local forge = GetItemAttuneForge(id)` once, derive the tier through a small `ANx.TierFrom(forge, progress, acctHas)` helper used for both `tier` and the ForgeAllowed decision, call AccountHasVariant only when needed; ZoneWatch inherits it. ~25 lines across Engine.lua and Core.lua.

**Expected effect.** bench.py ZONEN=100 HEAVY=0: 'ItemRows 100 ids [same rev] 0.61 ms' with 'E.Eligible=100 A.CurrentTier=119 A.Progress=225 ... GetItemAttuneProgress=225 HasAttunedAnyVariantOfItem=53 GetItemAttuneForge=119' for 53 output rows (cold 0.92 ms with 53 GetSources); stock 600 ids: forge 720 / progress 1,360 for 320 rows, 3.63 ms same rev. pred prototype (stock, old stub): 320/320/320 calls, 4.0-5.2 ms vs 7.9-9.7 ms, rows identical per the lens. Client: real lists are ~30-300 rows, so ~100-1,200 redundant Synastria C calls per render; at an unmeasured ~1-3 us each that is ~0.5-3 ms per render, every 2 s while attuning with a list open, and on the combat-time HUD refresh.

**Risk.** Under account scope isAtt must be written `if acctScope then AccountHasVariant(id) else progress >= 100 end` (the and/or idiom silently changes results when AccountHasVariant is false and progress is 100, as the pred lens found). A CurrentTier(id, knownProgress) argument must only skip the Progress read, never the forge read. Keep the row field set and sort identical.

#### gc-11: Memoize the difficulty/size union per exp.cat.diff; probe statsCache before building
Tags: cpu, memory | Bundle: UI render caching | Impact: low | Effort: small
Files: `Engine.lua:1639-1669`, `UI.lua:2195`, `UI.lua:2204`, `UI.lua:2493-2497`, `UI.lua:4308`, `UI.lua:4692`

**What happens now.** Engine.ContentSet(sum, 'D'/'R') (Engine.lua:1654-1665) returns sum[cat] directly when no difficulty filter is active, but with ANx.DifficultyFilterActive() it allocates a fresh union table of all matching label sets on every call. UI code calls `Engine.UnionStats(Engine.AllContentSets(sum), key)` (UI.lua:2195, 2204, 4308, 4692) and `Engine.SetStats(Engine.ContentSet(...), key)` (2454, 2516): the argument - six sets, two of them freshly built unions of thousands of ids - is evaluated before UnionStats/SetStats can return the cached result for `key`, so the unions are garbage on every repaint of the home/content/contentTypes screens.

**Change.** Later, small, and the natural home for mem-03 part 1: in ContentSet `sum._union = sum._union or {}; local k = cat .. (ANx.db.difficulty or 'all') .. (ANx.db.raidSize or 'all'); local u = sum._union[k]; if not u then <build>; sum._union[k] = u end; return u`; add `Engine.CachedStats(key)` so builders probe statsCache before building set arguments (or a thunk form `Engine.UnionStatsKeyed(key, function() return Engine.AllContentSets(sum) end)`). ~25 lines in Engine.lua plus the UI call sites.

**Expected effect.** bench.py ZONEN=100 HEAVY=0 with ANx.db.difficulty='heroic': 'AllContentSets x3 exps, difficulty=heroic 0.51 ms alloc~201 KB (avg of 5)' vs 'difficulty=all 0.01 ms alloc~1 KB'; 'root render difficulty=heroic [2nd same rev] 1.80 ms alloc~292 KB' vs 90 KB with 'all'; 'contentTypes render difficulty=heroic [2nd same rev] 1.84 ms alloc~302 KB' (18 ContentSet calls) vs 102 KB. Label-set sizes: 'exp1 Dl=1716/1 labels Rl=500/1; exp2 Dl=4800/3 Rl=900/1; exp3 Dl=4800/3 Rl=2400/6'. Stock: 2.21 ms / 801 KB per call-set, ~900 KB per repaint. Client: ~0.1-0.3 MB garbage and ~1-2 ms per repaint of home/content screens, only while a difficulty or raid-size filter is set.

**Risk.** Memoized unions must be dropped in InvalidateAll (summaries rebuild there) and keyed by the DiffKey (difficulty..raidSize); the label sets are immutable after BuildSummary so a per-summary `_union[cat .. diffKey]` table is enough. ContentSet calls DifficultyMatches(label) without instMap (1661), so the in-instance auto-narrow (Core.lua:75-84) does not affect it. Fix the duplicate UnionStats at UI.lua:2204 by reusing `st`.

Also reported as: pred-15.

#### gc-14: Return Engine.Universe() directly from ContextItems instead of copying it
Tags: cpu, memory | Bundle: UI render caching | Impact: low | Effort: small
Files: `Engine.lua:1697-1748`, `Engine.lua:114-135`, `Engine.lua:594-600`, `Engine.lua:870-883`, `Engine.lua:1530-1536`

**What happens now.** Engine.ContextItems for root/home views (Engine.lua:1745-1747) builds a new `list` and `seen` table from Engine.Universe() (already cached, Engine.lua:131) plus Engine.AllEventItems() (whose ids are already part of the universe, Engine.lua:127), i.e. a 20 K-entry array and a 20 K-entry hash per pick. InstancesFor/ZonesFor allocate arrays of at most a few dozen entries and BuildSummary's `ipairs({ 'D', 'R' })` one 2-slot table per summary - measurable only in principle.

**Change.** Later, trivial: replace lines 1745-1748 with `return (Engine.Universe())` plus a comment (Universe already includes every event item via line 131); optionally memoize AllEventItems (micro-13 g). 3 lines.

**Expected effect.** bench.py ZONEN=100 HEAVY=0: 'ContextItems({type='root'}) 5.23 ms alloc~1793 KB (avg of 5)' for an 18,266-id universe (stock: 4.53 ms / 1,185 KB); 'Engine.AllEventItems() 0.00 ms alloc~1 KB' (the harness has no events, so its real cost is untested). The copy runs before AttuneNextPick's first MaybeYield, so it is one ~5 ms (lupa; ~10-15 ms client) un-yielded slice at job start plus ~1 MB of garbage per pick; nothing user-visible.

**Risk.** Document that ContextItems may return the shared cached universe array; AttuneNextPick must keep treating it as read-only (it does). Keep the copying/union paths for the other view types. If AllEventItems is memoized, invalidate it with eventItemsCache (InvalidateAll resets both).

#### micro-13: Hoist literals, memoize AllEventItems, guard SetIconArt/SetArtTrim, drop type guards
Tags: cpu, memory | Bundle: UI render caching | Impact: low | Effort: small
Files: `Engine.lua:1050`, `Engine.lua:121`, `Engine.lua:1088`, `Engine.lua:1195`, `Engine.lua:1555`, `Engine.lua:1629`

**What happens now.** (a) Engine.lua:1050 `for _, scope in ipairs({ "char", "acct" })` sits INSIDE the per-universe-item loop of RemainingReport: one 2-slot table per item per report build (the same literal at 121, 1088, 1195, 1555 is per call and harmless). (b) `type(id) == "number"` guards in SetStats (1629), UnionStats (1644) and AddSetToList (1686) are dead: the sets only ever receive numeric keys (ArrayToSet 152-156, AddSet 1546-1548). (c) Engine.HasAnySource (436-440) does LootDbLoaded + pcall(ItemLocGetSourceCount) per item inside AttuneNextPick's universe loop (1845), and Engine.IsOwned (749) pcalls GetItemCount per Eligible call when Hide-in-bags is on, though both C functions' existence is checked once already.

**Change.** Later, as a cleanup riding with the related changes: hoist `local SCOPES = { 'char', 'acct' }` (ships with ui-02/pred-11), memoize AllEventItems by eventItemsCache identity (with gc-14), let gap-cc-04 remove the IsOwned pcall, guard SetIconArt/SetArtTrim with `if tex.anxArtKey == key and tex.anxArtOn == on then return true end` (~6 lines), drop the three type guards; skip (f) unless /an perf (gap-tf-04) shows list renders as a top timer, and skip (h).

**Expected effect.** bench.py ZONEN=100 HEAVY=0: 'RemainingReport() sync rebuild alone 78.87 ms alloc~3876 KB' - (a) accounts for ~1.2 MB of that (18,266 x ~64 B; the micro lens measured the hoist alone taking the cold report from 5.1 to 2.8 MB at stock size); 'ContextItems({type='root'}) 5.23 ms alloc~1793 KB' (gc-14); 'Engine.AllEventItems() 0.00 ms' (no events in the harness). (e) and (f) not re-measured; the micro lens's standalone numbers (closure per row 3.9 ms / 5 MB per 20k rows, ART_PATH concat 0.06 us) are accepted, and the C SetTexture/SetTexCoord cost per paint is unknown (likely tens of us per call, <1 ms per paint).

**Risk.** Nothing functional. (e) needs a per-texture `anxArtKey` guard that also keys on ArtOn() (UI.lua:428, 438) and is reset by ClearArtCoords (4077) so a skin toggle or an icon row following an art row still repaints. (b) is cosmetic; keep if the author prefers the defensive form. (c) HasAnySource's pcall is cheap and the API has thrown before (comment at 434-435): leave it.

#### gc-12: Cache lowered item names for search; store matches as ids sorted by the cache
Tags: cpu, memory | Bundle: UI render caching | Impact: low | Effort: small
Files: `UI.lua:3597-3611`, `UI.lua:3613-3625`, `Core.lua:522-531`

**What happens now.** builders['search'] loops over the whole Engine.Universe() and for each id with a resolved name evaluates `name:lower():find(q, 1, true)` (UI.lua:3604), creating a short-lived lowered string per item per render, and `name:lower()` again for every match stored as `{ id = id, name = name, lname = ... }` (3606); the matches are then sorted by lname. The search is debounced at 0.25 s, but every debounced keystroke and every RefreshIfShown while the search view is open re-runs the full lowering pass.

**Change.** Do now (~25 lines in UI.lua, optional 5 in Core.lua): `local lowerName = {}` filled in the search loop (`ln = lowerName[id]; if ln == nil then local nm = ANx.GetItemName(id); if nm then ln = nm:lower(); lowerName[id] = ln end end`), matches stored as ids, sorted by lowerName, plus ui-06's top-60 bounded insertion when the sort mode is name; expose ANx.ClearLowerNames() and call it from gap-cc-08's BumpNameMiss. Ship together with gap-cc-08, which removes the C-call side of the same loop.

**Expected effect.** skeptic_ui.py (stock harness, 24,357 ids): stock GetItemName+lower+find+{tbl}+sort-all: 'zzz' 11.99 ms / 664 KB, 'item15' 14.91 ms / 899 KB, 'item1' 35.98 ms / 3,108 KB; gc-12 lowerCache find (count) 4.56 / 4.56 / 4.76 ms, 0 KB; ids list + sort by cache 4.64 / 5.85 / 16.33 ms, 0-256 KB; resident lowered cache 844 KB for 20,000 names (64-bit, 9-char synthetic) and 512 KB for 24,000 realistic 17.7-char names. Client estimate ~0.4-0.6 MB resident.

**Risk.** The cache must be wiped when gap-cc-08's name-miss generation bumps (a newly cached item gets a name) and on InvalidateAll; it must never store an entry for an id whose name is nil. Sort-by-name callers elsewhere still lower() per compare and would benefit from the same table. Distance sort still calls BestSource per match (see ui-06).

#### ui-06: Bounded top-60 selection for name-sorted search; cap distance-sort BestSource work
Tags: cpu | Bundle: UI render caching | Impact: low | Effort: small
Files: `UI.lua:3597-3622`, `UI.lua:3603-3604`, `UI.lua:3625-3637`, `UI.lua:3497-3528`, `UI.lua:3530-3560`

**What happens now.** builders.search iterates Engine.Universe() (24,357 ids in the synthetic DB) calling ANx.GetItemName(id) and then name:lower() (a fresh string per item) :find(q) per render, allocates a {id,name,lname} table per match and table.sorts ALL matches with a closure comparator before capping at 60. Typing one more letter repeats the whole walk although the new result set is a subset of the previous one. SearchVendors/SearchQuests likewise lower() every vendor/quest name per render.

**Change.** Do the top-60 partial selection (bounded insertion by lname, count the remainder for the 'more' line) and ride the per-name part on gc-12's lowered-name cache; skip the incremental-narrowing cache (same speed as a cached full walk, more state to invalidate). Separately cap the distance-sort BestSource work (compute distance only for the first N name-sorted matches or memoize via gap-04's index).

**Expected effect.** skeptic_ui.py (stock harness, 24,357 universe ids / 20,000 resolved 9-char names): stock loop 'zzz' 12.0 ms / 664 KB, 'item15' 14.9 ms / 899 KB, 'item1' (10k matches) 36.0 ms / 3,108 KB; incremental narrow prev('item1')->'item15' + sort 4.74 ms / 16 KB; re-narrow same query 18.7 ms (sort dominated); sort-all 10k by lname 15.8 ms / 256 KB vs top-60 bounded insertion 3.24 ms / 1 KB; gc-12 full walk with lowered cache 4.56 ms / 0 KB.

**Risk.** Incremental state must be keyed on query prefix, searchType, searchFilters and Engine.rev; the partial selection only applies to the name sort (distance sort needs BestSource per match anyway). Nothing else behavioral.

#### frame-12: Re-render on progress ticks only when the open view shows a changed item
Tags: cpu | Bundle: UI render caching | Impact: low | Effort: small
Files: `Core.lua:1693-1701`, `Core.lua:1796-1806`, `UI.lua:207-211`

**What happens now.** Every ATTUNE_HAS tick (OnCustomGameData typeId 11, roughly once per kill while wearing attuning gear) that is not a completion calls ANx.MarkProgressDirty, which 2 s later calls UI.RefreshIfShown -> UI.Render() if the main window is shown. v3.6 already stopped wiping caches on ticks, but the trigger still forces a full render of whatever screen is open (list rebuild, sort, repaint) even when the screen does not display that item.

**Change.** Later, cheap (~15 lines in Core.lua + UI.lua): MarkProgressDirty(id) adds id to a pending set; the 2 s callback calls UI.RefreshIfShowsItems(set), which renders only if the current view is 'sources' with view.itemId in the set, an item list whose displayRows contain a matching itemId (a walk of <= a few hundred rows), or UI.selectedItem is in the set; otherwise it clears the set and returns. No per-row repaint hook is needed because the row text is built by the builder anyway.

**Expected effect.** skeptic_ui.py: MarkProgressDirty -> render observed; warm render ms of the view rebuilt: items inst(600) 23.0 ms (ui_bench warm 16.7 ms / 464 KB), items inst(150) 8.0 ms, instances C/D 4.3-7.8 ms, sources 0.6 ms, root 0.6 ms (stock stub; ItemRows uses Eligible so ~3x inflated). Frequency not measurable in the harness (<= 1 per 2 s by the debounce).

**Risk.** Must not drop refreshes for views that do show the item: sources view (view.itemId), item lists (displayRows[i].itemId), the selected item card (UI.selectedItem), and Win_Browse's renderTarget. A completion still goes through MarkAttuneDirty -> full render.

#### frame-08: Drive the plate glow pulse with an AnimationGroup instead of per-frame SetAlpha
Tags: cpu | Bundle: nameplates | Impact: low | Effort: small
Files: `Nameplates.lua:634-674`, `Nameplates.lua:660-673`, `Nameplates.lua:471-499`

**What happens now.** The driver OnUpdate (Nameplates.lua:642) computes a sine each frame and loops over activeGlows calling frame.anxGlow:SetAlpha(a) for every marked plate (660-666). In a trash pack where most mobs drop something unattuned that is up to 40 C calls per frame, 60 times a second, for a purely cosmetic breathing effect.

**Change.** Later, optional: fold it into the Nameplates.lua pass only if an in-game check of the animation is cheap; on its own it is not worth a release. Sketch: in EnsurePlateMark (:471-499) create `glow.anxAnim = glow:CreateAnimationGroup(); local a = glow.anxAnim:CreateAnimation('Alpha'); a:SetChange(-0.44); a:SetDuration(1.31); a:SetSmoothing('IN_OUT'); glow.anxAnim:SetLooping('BOUNCE')`; in UpdatePlate when the glow is shown (:541-548) SetAlpha(0.64) and Play() when Cfg().pulse, else SetAlpha(GLOW_STEADY) with the group stopped; in HidePlateMark call anxAnim:Stop(); delete the per-frame block :658-673 and the `pulse` accumulator (:634).

**Expected effect.** harness_frame.py steady state, NPLATES=40 all marked, 600 frames: plates driver 21.06 ms total = 35 us/frame in lupa (includes the 0.2 s RefreshAllPlates and 0.1 s ScanForNewPlates passes), max 0.102 ms; SetAlpha stub count 50,623 over the 2,100 frames since login = ~40 per frame once marked (lens: 27,761/600). Plates OFF for comparison: 0.81 ms/600 frames. The SetAlpha stub is a Lua closure increment, so the client cost is a reasoned estimate: a real texture SetAlpha is ~1-3 us, giving ~0.05-0.15 ms/frame at 40 marked plates and ~0.01-0.04 ms at a typical 5-15, i.e. 0.1-1% of a 16.7 ms frame.

**Risk.** 3.3.5 Alpha animations are relative to the region's alpha at Play() and the region snaps back to its pre-play alpha on Stop()/finish, so: seed SetAlpha(0.64) before Play(), Stop() the group in HidePlateMark (:450-454) and PlateOnHide (:460-463) because plates are pooled, and on the pulse toggle (UI.lua:3126-3128 -> RefreshAllPlates) Stop() every group and SetAlpha(GLOW_STEADY), replacing the `_pulseWas` settle branch (:667-672).

#### micro-08: Memoize CurrencyCategory; scan the packed VendorCosts string directly for category hits
Tags: cpu | Bundle: static data | Impact: low | Effort: small
Files: `Engine.lua:1383-1399`, `Engine.lua:1401-1406`, `Engine.lua:1410-1429`, `Engine.lua:1438-1448`, `Engine.lua:1452-1475`, `Engine.lua:1360-1379`

**What happens now.** StaticCosts gmatch-decodes VendorCosts[itemId] into one table per variant plus one table per cost pair on every call; ItemAllCosts then builds CostSignature (a parts table, table.sort, table.concat) for each variant to dedupe against the scanned cost. Callers invoke it per item per render: VendorItemsMatchingCategory for every vendor item of every zone of the expansion whenever vendorFilter ~= all (zones V builder, UI.lua:2691, before the Stats cache key is even checked), FilterAffordable/CanAfford per item when Affordable is on, CurrenciesForZone per render of the currencies screen, CostString per visible row, RemainingReport per left item. Engine.CurrencyCategory runs up to 8 string.find patterns per call and is itself called per cost per item in VendorItemsMatchingCategory.

**Change.** Later: (1) `local catMemo = {}` in CurrencyCategory (381 names); (2) in VendorItemsMatchingCategory: `local scanned = db.merchant and db.merchant[itemId]; if scanned then <current path> else local raw = ANx.VendorCosts[itemId]; if raw then for idx in raw:gmatch('(%d+):') do if catByIdx[tonumber(idx)] == category then hit = true break end end elseif category == 'unknown' then hit = true end end`; (3) in ItemAllCosts build `seen` and signatures only when `scanned` exists; (4) optional 512-entry bounded decode cache for CostString bursts. ~40 lines in Engine.lua.

**Expected effect.** cd scratchpad/verify_engcache && python3 -I costs.py (real Data_VendorCosts.lua loaded, Engine.lua lines 1312-1313 and 1383-1448 executed as-is): 'VendorCosts ids=5401 currencies=381', 'variants=6843 cost pairs=8017 (1.27 variants, 1.48 pairs per item)'; 'ItemAllCosts(id) over every id 22.24 ms 4823 KB per pass (4.12 us / 914 B per item)'; 'VendorItemsMatchingCategory-style ... 25.09 ms (4.64 us per item)'; 'proposed: gmatch over the packed string + catByIdx (no tables) 4.19 ms 465 KB per pass (0.77 us / 88 B per item)'; 'equivalence over 5 categories x 5401 ids: mismatches=0'; 'StaticCosts only (= ItemAllCosts minus CostSignature) 9.46 ms (1.75 us / 604 B)' so CostSignature is ~57% of ItemAllCosts; CurrencyCategory 20.55 ms for 38,100 calls = 0.54 us each.

**Risk.** Live merchant scans keep precedence: check ANx.db.merchant[itemId] first and take the old path for scanned items; the packed-string classification must use the same CurrencyCategory per currency index (catByIdx built once from the static VendorCurrencyNames); skip CostSignature only when no scanned cost exists (dedupe is only needed between scanned and static variants).

#### data-03: Land proto:datapack (QuestGivers/QuestPre/Reagents index+blob); add QuestNameOf index
Tags: load, memory | Bundle: static data | Impact: low | Effort: small
Files: `Data_QuestGivers.lua:12065`, `Core.lua:1258`, `QuestArrow.lua:232`, `QuestArrow.lua:430`, `QuestArrow.lua:457`

**What happens now.** ANx.QuestNameOf builds a pattern "\n<id>=([^\n]*)" and runs blob:match over up to 24 blobs (161 KB of text) until a hit; Lua's matcher tries the pattern at every byte position, so a hit costs ~0.5 ms and a miss (quest not in blobs, e.g. a dropped-item starter that then falls through to QuestNamesExtra) ~1 ms in lupa (2-3x on the client). SetQuestWaypoint calls QuestName up to three times per click (title, target, blocker), i.e. ~1.5-3 ms lupa / 3-9 ms client of pure string scanning per click. Memory is already fine (153 KB, strings).

**Change.** Do now, but only as part of proto:datapack (do not open a separate change). Extend tools/pack_data.py to emit ANx.QuestNameIdx (sorted 9-char records: 4 hex questId + 5 hex 1-based offset) and ANx.QuestNameBlob ("name\n" records, starters merged where the blob has no entry), replacing QuestNameBlobs and the QuestNamesExtra assignment. Core.lua QuestNameOf becomes: local p = ANx.PackedFind(ANx.QuestNameIdx, qid, 5); if not p then return nil end; local e = strfind(ANx.QuestNameBlob, "\n", p, true); return strsub(ANx.QuestNameBlob, p, e - 1). Add the same Python self-check pack_data.py runs for QuestGivers (decode every id through a replica, plus miss probes). Lookup drops from 0.5-1.1 ms to ~4 us per call for +6 KB resident; zero load-time change.

**Expected effect.** skeptic_static/bench_static.py (lupa 5.1 64-bit, real blobs): 'data-03 QuestNameOf blob scan: hit 481 us, miss 1090 us (per call)'; index+blob built from the 24 blobs plus QuestNamesExtra: '6046 names, idx 54414 B, blob 124611 B = 175 KB' (vs 153 KB blobs + 16 KB QuestNamesExtra today, i.e. +6 KB), 'packed lookup: hit 3.96 us, miss 3.05 us'; 'equivalence: 6140 ids checked, 0 mismatches'. measure_data.py: QuestNameBlobs 153 KB true retained, 0.49 ms compile. Per click: 1-3 calls x 0.5-1.1 ms -> 1.5-3.3 ms lupa, estimated 2-5 ms client.

**Risk.** Behavioural: none if the generator keeps precedence (blob name wins, starter name only fills gaps) - fold QuestItemStartNames into the sorted index at generation time and delete ANx.QuestNamesExtra (Data_QuestItemStarts.lua:303). Names contain quotes/apostrophes: emit the blob as a long-bracket literal or escaped pieces as pack_data.py already does; assert no '\n' inside a name. Quest ids max 26,034 fit the 4-hex id width.

**Prototype.** `proto:datapack`, diff `prototypes/proto_datapack_code_only.diff`; numbers in `prototypes/MEASUREMENTS.md`.

Also reported as: data-01, mem-13, data-02, data-05, mem-12, data-10.

#### data-07: Pack VendorLocs into one fixed-width 14-char string read via PackedFind
Tags: memory, load | Bundle: static data | Impact: low | Effort: small
Files: `Data_VendorLocs.lua:7`, `Core.lua:1246`, `QuestArrow.lua:393`, `UI.lua:2806`, `UI.lua:3512`

**What happens now.** Values were packed in v3.6.0 but the container is a 2,048-node hash (1,046 keys > 1,024) = 82 KB (64-bit) / 64 KB (32-bit) plus ~1,000 short strings; 117 KB resident for 24 KB of source. Every value is exactly three bounded numbers (zone <= 4987, x,y <= 999), so a fixed-width record needs no blob at all. Readers: ANx.VendorLoc (click/render), ANx.HasVendorLoc (per vendor row render).

**Change.** Do later with the pack_data.py batch (cheapest of the set: ~25 lines of Lua). Generator emits ANx.VendorLocsPacked (sorted 14-char records: 4 hex npc + 4 hex zone + 3 hex x10 + 3 hex y10). Core.lua VendorLoc: local v = ANx.PackedFind(ANx.VendorLocsPacked, npcId, 10); if not v then return nil end; local y = v % 4096; v = (v - y) / 4096; local x = v % 4096; return (v - x) / 4096, x, y. QuestArrow.HasVendorLoc: return npcId ~= nil and ANx.PackedFind(ANx.VendorLocsPacked, npcId, 10) ~= nil. Drop the VendorLocs hash.

**Expected effect.** bench_static.py: 'VendorLocs: 1046 ids; hash node-copy 79 KB; packed 14644 B'; 'old decode (hash+match) 0.59 us; packed decode 3.06 us; mismatches 0' (every key decoded both ways, plus miss probes). measure_data.py: VendorLocs 125 KB true retained (hash + ~1,000 interned value strings), 0.71 ms compile, 100 KB transient proto. harness.py LOADPROF: 0.63 ms / 181 KB ret. Client estimate: ~-90 KB Lua heap, ~-1.5 ms loading-screen compile; +~8 us per vendor row rendered (tens of rows per screen, <1 ms per render).

**Risk.** Trivial. Generator asserts npc < 65536, zone < 65536, x/y < 4096. HasVendorLoc becomes PackedFind(s, npcId, 10) ~= nil (same probe cost as the decode). The decode returns the same (zone, x10, y10) triple, so ArrowToPoint callers are unchanged. The generator for this file is not in the repo (README.md:432 says regenerate rather than hand-edit), so this rides on tools/pack_data.py.

#### data-08: Pack RareLocs into index + blob decoded at click time
Tags: memory, load | Bundle: static data | Impact: low | Effort: small
Files: `Data_RareLocs.lua:6`, `QuestArrow.lua:403`, `QuestArrow.lua:408`, `UI.lua:3419`

**What happens now.** One array subtable per rare (up to 18 numbers), 356 of them + a 512-node hash = 75 KB resident. Read only by ANx.SetRareWaypoint on a row click (cycles spawn points) and ANx.HasRareLoc per rare-creature source row at render time.

**Change.** Do later, only as a ride-along in tools/pack_data.py alongside data-07 (same reader shape as the datapack QuestGivers decode). Generator emits ANx.RareLocsIdx (sorted 9-char: 4 hex npc + 5 hex offset) + ANx.RareLocsBlob ('z,x,y,z,x,y\n' per rare). QuestArrow.SetRareWaypoint: p = PackedFind(idx, npcId, 5); record = strsub(blob, p, strfind(blob, '\n', p, true) - 1); fill a module-level scratch array with gmatch('%d+') + tonumber; the rest of the function is unchanged.

**Expected effect.** bench_static.py: 'RareLocs deep-copy KB: 92' (analyst: 72-75 KB; measure_data.py: 72 KB true retained, Data_RareLocs.lua 0.44 ms compile, harness LOADPROF 0.44 ms / 119 KB ret). Packed target (analyst's pack_experiment, not re-run): index 3.2 KB + blob ~8 KB = 11 KB, 0.05 ms compile. Client estimate: ~-50-60 KB Lua heap, ~-1 ms compile; +~8 us per rare row rendered.

**Risk.** None functional: data is static, not saved, click-only. SetRareWaypoint must decode the record into a scratch table (gmatch('%d+') from the offset to the newline) and keep n = count/3; HasRareLoc = PackedFind(idx, npcId, 5) ~= nil. The saving is ~50 KB on the client - only worth the diff as a ride-along in the generator batch, never as its own change.

#### gap-real-db-shape-07: Cap fallback-mode quest/vendor indexing at 8 per item per zone; defer id attribution
Tags: memory | Bundle: streaming source rows | Impact: low | Effort: medium
Files: `Engine.lua:816-856`, `Engine.lua:504-514`, `Engine.lua:158-183`, `Core.lua:1236-1244`, `Core.lua:1247-1253`, `Data_QuestGivers.lua:3-5`

**What happens now.** ZoneData computes recognized = any row names a zone in Engine.KnownZoneNameSet (Data_Zones + Data_Instances names, 504-514); when false, fallback makes every row count for this zone (826), so each quest row is indexed into zc.questList (831-837) and each vendor row into zc.vendorByName (842-851) of EVERY zone whose ItemsInZone list contains the item. Engine.ExportCache (158-183) stores zoneCache by reference into ANx.db.structCache.zones, so the inflated questList/vendorByName tables are serialized to SavedVariables and re-parsed at every login. Any localized client lands in this mode permanently, and so does an English client for any item whose rows all use a server zone/instance spelling that differs from the addon's names.

**Change.** Do (2) and (3) now because they are free with finding 01 (the cap is 3 lines inside the memo-based ZoneData). Defer (1) until /an srcstats from a real client shows unrecognised zone names; if it does, attribute a fallback quest/vendor row to a zone only when ANx.QuestGiver/ANx.VendorLoc decode to a non-city entry of ANx.Zones equal to zoneEntry.zone, and otherwise keep the capped all-zones rule. Decode once per Q/V row inside BuildZoneMemo (store the zoneAreaId as a fourth slot) so the string match does not run per zone listing.

**Expected effect.** Author's PROFILE (estimator figures, so real sizes are ~1.5x): mismatch mode zoneCache 46.3 MB stock vs 1.5 MB English; with the memo's FALLBACK_INDEX_CAP=8 it is 21.9 MB and questList/vendorByName per zone fall from ~1,314 to ~600 entries while quest/world/vendor arrays stay identical (equiv_mm.txt). The synthetic DB types cycle {0,1,2,9,0,6} so 1/6 of every item's rows are quests and 1/6 vendors (8,667 of 20,000 items carry Q rows and 7,999 V rows in my memo measurement), which inflates fallback mode far beyond real data where a reward has 1-3 quest rows. Data_QuestGivers has 12,123 keyed entries and Data_VendorLocs 1,121 (regex count), both using AreaTable zone ids, the same id space as ANx.Zones[].zone.

**Risk.** Part (1) changes what localized clients see: a quest handed out in a capital city (city=true zones are vendor-only) for a zone elsewhere would be attributed to the city and vanish from every zone's quest list, which is worse than today's duplicate-everywhere behaviour; rows without location data keep the old rule. The cap (2) can hide a quest from a zone if an item is rewarded by more than 8 quests and no row names a known zone (rare).

#### mem-03: Drop Dl/Rl from summaries (with gc-11), then convert D/R/Q/W/V/C sets to arrays
Tags: memory | Bundle: saved structure | Impact: low | Effort: medium
Files: `Engine.lua:1546-1583`, `Engine.lua:1625-1651`, `Engine.lua:1654-1676`, `Engine.lua:1684-1688`, `Engine.lua:114-140`, `Engine.lua:1082-1105`

**What happens now.** BuildSummary (Engine.lua:1550-1583) stores each category as [id]=true sets and, for D/R, a second copy per difficulty label (Dl/Rl). Every reader iterates with pairs: SetStats, UnionStats, AddSetToList, Universe, RemainingByCategory, ContentSet; the only indexed access is the write sum.C[e.id]=true (grep over all files: no `.D[`/`.Q[` reads). With a difficulty or raid-size filter active, ContentSet (1654-1668) builds a fresh union table of all matching Dl/Rl sets on every call, and the content/contentTypes/contentExp builders call it 6-18 times per render (UI.lua:2454, 2493, 2516). Real item ids are sparse (38..54,797), so these sets live in the hash part: 32 B per node on 32-bit plus power-of-two rounding, versus 16 B per array slot.

**Change.** Later, in two parts. Part 1 (small, with gc-11): drop Dl/Rl from BuildSummary/ExportCache/ImportCache and build the difficulty-filtered union from Engine.InstancesFor(exp, kind) x InstanceDiffs(inst).items for labels passing DifficultyMatches, memoized per exp..cat..DiffKey and cleared in InvalidateAll (~30 lines; removes ~15k nodes and the SavedVariables duplicate). Part 2 (medium): convert D/R/Q/W/V/C to deduped id arrays and switch the eight readers to ipairs - only as part of proto:svpack, which rewrites the export/import anyway; on its own ~1 MB on the client is not worth a medium refactor.

**Expected effect.** bench.py ZONEN=100 HEAVY=0 structure lines: 'exp1 union=5873 (sum of 6 cats=8111); exp2 union=6151 (7297); exp3 union=6810 (8445)' = 23,853 set entries; 'exp1 Dl=1716 Rl=500; exp2 Dl=4800 Rl=900; exp3 Dl=4800 Rl=2400' = 15,116 label entries; ~39k hash nodes at ~36-40 B on the 32-bit client = 1.3-1.6 MB resident (arrays of the same ids ~0.6 MB at 16 B per TValue; without Dl/Rl ~0.4 MB). The per-render union cost is gc-11's 0.2-0.3 MB per repaint with a difficulty filter. Not measured: the array conversion itself (no prototype); the mem lens's 2,234 KB vs 5,622 KB is the stock synthetic.

**Risk.** Universe() must keep deduping across categories (it uses a scratch set); UnionStats/AddSetToList already dedupe; the UI only passes ContentSet/AllContentSets results (verified by grep). Changing the saved form invalidates the struct cache (ANx.VERSION check at Engine.lua:189 already forces a rescan on version bump).

#### data-04: Pack VendorCosts into index + palette blob; enumerate universe ids from the index
Tags: memory, load | Bundle: static data | Impact: low | Effort: medium
Files: `Data_VendorCosts.lua:393`, `Engine.lua:1383`, `Engine.lua:128`, `Engine.lua:1055`, `Engine.lua:1360`, `Engine.lua:1373`

**What happens now.** Yes, the hash itself is the cost: 5,401 keys -> 8,192 nodes = 320 KB (64-bit) / 256 KB (32-bit) while the 1,354 distinct value strings total only 46 KB (max 47 chars; '4:50' alone is shared by 118 items). StaticCosts (Engine.lua:1383) already decodes the string with gmatch on every call, so a packed source is a drop-in. Two consumers need the key SET: Engine.Universe (Engine.lua:128-129, `for id in pairs(ANx.VendorCosts)`), and nothing else. Hot-ish consumers: Engine.RemainingReport (Engine.lua:1055) calls ItemCurrencies for every universe item (~20k, 95% misses) inside an Enqueue job with MaybeYield; FilterAffordable / VendorItemsMatchingCategory / CurrenciesForZone run per UI view over a zone's item list (render path, <= a few hundred items).

**Change.** Do later, bundled with the pack_data.py generator work (proto:datapack), not standalone. Generator emits ANx.VendorCostsIdx (sorted 4-hex id + 5-hex offset) + ANx.VendorCostsBlob (dedup, '\n'-terminated). StaticCosts: local p = PackedFind(idx, itemId, 5); if not p then return nil end; raw = strsub(blob, p, strfind(blob, '\n', p, true) - 1) then the existing gmatch decode. Engine.Universe: stride the index (for p = 1, #idx, 9 do set[hex4(idx, p)] = true end, ~0.9 ms once) and keep that set as Engine.vendorCostIds; RemainingReport: `if costs == nil then costs = (vendorCostIds[id] or (db.merchant and db.merchant[id])) and Engine.ItemCurrencies(id) or false end`. Keep VendorCurrencyNames as is.

**Expected effect.** bench_static.py: 'VendorCosts: 5401 ids; hash node-copy 317 KB (values shared); idx 48609 B + blob 12082 B = 59 KB' (dedup blob of 1,354 values); 'pairs() over hash: 228 us; stride over idx (with HEXV decode): 921 us' (the finding's 32 us stride figure is wrong, but Universe is cached after summaries are ready so it is irrelevant); 'hash hit 0.038 us / miss 0.039 us; packed hit 3.22 us / miss 3.38 us'; 'equivalence mismatches: 0' over every key and every third id in 0..65535. measure_data.py: VendorCosts 372 KB true retained, 2.26 ms compile, 282 KB transient proto. harness.py LOADPROF: Data_VendorCosts.lua 2.25 ms compile / 631 KB ret (proto included). RemainingReport regression without a guard: ~20k misses x 3.4 us = ~68 ms lupa in the job.

**Risk.** Must ship with a membership guard or RemainingReport and the affordable/currency filters regress: either keep the id set Engine.Universe already builds from the index (Engine.vendorCostIds) and test it before ItemCurrencies in RemainingReport (5 lines, no bitset needed), or add the 8 KB bitset the finding proposes.

#### data-06: Pack Professions into fixed-width rows plus a packed item->profession reverse index
Tags: memory, load | Bundle: static data | Impact: low | Effort: medium
Files: `Data_Professions.lua:8`, `Engine.lua:959`, `Core.lua:729`, `Engine.lua:1777`, `Engine.lua:1039`, `QuestArrow.lua:345`

**What happens now.** v3.6.0 moved from one subtable per recipe to 4 parallel arrays, but every element is still a 16-byte TValue (on both 64-bit and the 32-bit MSVC client), so 2,827 recipes x 4 fields = 181 KB resident and 1.9 ms compile for 51 KB of source. Engine.ProfessionEntries (Engine.lua:959) scans a whole profession's rows filtering by exp and caches the result per prof-exp (profCache), so it reads each row a handful of times per session. ANx.ProfessionOfItem (Core.lua:729) lazily builds a SECOND structure, the profOfItem reverse hash (2,827 keys -> 4,096 nodes = ~164 KB 64-bit / 131 KB 32-bit), used by Engine.ItemBucket (focus mode), QuestArrow.lua:345 and RemainingReport.

**Change.** Do later, with the generator batch (after data-04/data-07). Generator emits ANx.ProfessionPacked[prof][exp] = '<13-char rows: 5 hex itemId + 5 hex spellId + 3 hex skill>' sorted by skill, and ANx.ProfOfItemPacked = sorted 6-char records (5 hex itemId + 1 hex profession ordinal into ANx.ProfessionOrder). ProfessionEntries decodes the one prof-exp string with a strbyte/HEXV loop (no exp filter, no sort) and still builds the same {id, spell, skill} entries it caches today. ProfessionOfItem = ANx.ProfessionOrder[PackedFind5(ANx.ProfOfItemPacked, itemId, 1)]; delete profOfItem/InvalidateProfOfItem.

**Expected effect.** bench_static.py: 'Professions rows 2827, parallel arrays KB 246 (deep copy incl. per-prof hash), profOfItem reverse hash KB 160 (2824 keys)'; measure_data.py: ProfessionItems 181 KB true retained, Data_Professions.lua 2.65 ms compile; harness.py LOADPROF: 4.82 ms compile / 370 KB ret (proto included). Packed form (analyst's pack_experiment.py, not re-run here): 57 KB resident, 0.19 ms compile. Decode cost in a packed ProfessionEntries: 2,827 rows x 3 exps x ~2 us = ~17 ms lupa once per scan unless rows are grouped by prof+exp at generation time (then ~6 ms). ItemBucket's +3.5 us per item is dwarfed by the BestSource walk it also does (Engine.lua:1772).

**Risk.** Needs a 5-hex id width (new PackedFind5 or an idw parameter) and generator range asserts (skill <= 4095, exp <= 15, spell < 2^20). Sort rows by skill at generation time so ProfessionEntries' table.sort (Engine.lua:969) can go, and group by prof+exp so the exp filter disappears. ProfessionEntries runs inside BuildSummary on the scan; proto:pacing adds a MaybeYield per row there, which also covers the decode loop.


## 4. Interactions and ordering

Bundles in implementation order:

1. **instrumentation** (after: nothing). Ship first as v3.6.3; one /an perf + /an srcstats reading sets SRC_ROW_BUDGET, the db-01/04/06 caps, ROW_YIELD and says whether the English client is in fallback mode.
2. **streaming source rows** (after: instrumentation). Engine scan and cached-login path: db-02(+db-05), db-11/tf-07, db-03, db-01(+db-07 cap), db-04, db-08, micro-01/07, then db-06 only after db-01/02/04; caps from the readings; port to Simple until two addons lands.
3. **pump pacing** (after: streaming source rows). proto:pacing was measured on top of streaming; the status-export job (cc-11/pacing-05/tf-06) rides with the pump change and carries load-13/gc-06/frame-07; pacing-02+03 are the last step, after the pacing-04 and two-addons readings.
4. **UI render caching** (after: streaming source rows). Render-path memos (pred-01 foundation, micro-03, pred-02, ui-02, ui-01/09, pred-07) are independent in principle but land after db-04/proto:bestsource so pred-02 keys on the objId return and ui-04 is re-measured with the fast bit stub.
5. **filter client costs** (after: streaming source rows, UI render caching). pacing-08 first; cc-02+cc-03(+mem-09)+cc-08 together; cc-04 then frame-11; cc-05(+pred-14) warms cc-06 F_KIND; cc-12 pairs with pred-01 and the drain hook; cc-01 last turns the sweep into flag hits; shares WarmPredicates/EnsureWarm lines with streaming.
6. **saved structure** (after: streaming source rows, pump pacing, instrumentation). proto:svpack's scan-end export job runs in the pump after streaming; the tf-02/tf-09 fallback reading re-weights its value (real file ~2 MB); mem-03 part 1 rides gc-11, part 2 changes the same export/import.
7. **two addons** (after: streaming source rows, pump pacing, saved structure, filter client costs). Simple adopts the host engine structure, flags and statusCache, so every engine change above must be final first; pacing-08 is a hard prerequisite before flags are shared.
8. **nameplates** (after: nothing). One Nameplates.lua pass (frame-05 row cap + single pcall, optional frame-08 animation); independent of the engine work, any time.
9. **static data** (after: nothing). proto:datapack hunks do not overlap the streaming diff; extend tools/pack_data.py for QuestNameOf, VendorLocs, RareLocs, VendorCosts, Professions in one generator batch with micro-08; any time.
10. **textures** (after: nothing). No code change: BLP2 DXT5 conversion with mips, then downscale; verified in client only, any time.

Release plan:
- **v3.6.3, instrumentation only.** Apply `prototypes/telemetry_an_perf.diff` (the `/an perf` counters) and add `/an srcstats`. Run one fresh-scan login after `/an reset` and one cached relog, then read `/an perf`. Those readings set `SRC_ROW_BUDGET`, the index and memo caps, and say whether the English client ever takes the zone-name fallback path. If it never does, the saved-structure packing drops in priority.
- **v3.7.0.** Streaming source rows (start from `prototype_stream.diff` and `proto_bestsource.diff`), the time-capped pump (`proto_pacing.diff`) with the status export as a background job, the warmup on cached logins, the render memos, and the filter client-cost fixes.
- **Later.** The packed saved structure (`proto_svpack.diff`; take its scan-end export job rather than the plain "export only at logout" change in `prototype_stream.diff`, which it supersedes), Simple adopting the main addon's structure, the packed data files (`proto_datapack_code_only.diff` plus `pack_data.py`), nameplate tweaks and texture conversion.
- AttuneNext-Simple carries a copy of the engine. Every engine change needs porting there until Simple adopts the main addon's structure.
- The prototypes are measured starting points with equivalence checks, not reviewed patches. None was run in the game client.

## 5. Rejected or not worth it

Findings already covered by a verified finding or a prototype (folded into the entries above):

- scan-01 + gc-01: covered by proto:stream-A, gap-real-db-shape-01.
- scan-03: covered by gap-real-db-shape-01.
- scan-02 + gc-02, mem-05: covered by proto:stream-D, gap-real-db-shape-02.
- gc-03 + frame-06: covered by proto:bestsource, gap-real-db-shape-04.
- pred-03 + micro-11: covered by proto:bestsource, gap-real-db-shape-04.
- pred-06 + mem-08, gc-09: covered by proto:stream-B, gap-real-db-shape-08.
- gc-04 + mem-01: covered by gap-real-db-shape-06.
- scan-09: covered by gap-real-db-shape-06.
- scan-04: covered by proto:pacing, gap-two-addons-pacing-03.
- gc-05: covered by proto:pacing, gap-two-addons-pacing-03.
- scan-11: covered by proto:pacing, gap-two-addons-pacing-02.
- load-02 + scan-05, frame-04, micro-10: covered by gap-telemetry-and-harness-fidelity-06, gap-two-addons-pacing-05, gap-client-c-costs-11.
- scan-06 + load-06, gc-07: covered by proto:stream-C, proto:svpack, gap-two-addons-pacing-06.
- mem-02: covered by proto:svpack.
- load-05 + scan-08: covered by proto:svpack.
- load-01 + scan-07: covered by gap-real-db-shape-11, gap-telemetry-and-harness-fidelity-07.
- load-07 + mem-06: covered by proto:svpack, gap-telemetry-and-harness-fidelity-09.
- pred-09: covered by gap-client-c-costs-04.
- pred-12: covered by gap-client-c-costs-06.
- ui-05 + gc-13: covered by gap-client-c-costs-07.
- ui-10: covered by gap-client-c-costs-09.
- load-04 + mem-07, scan-12, frame-03, micro-05, gc-08: covered by gap-real-db-shape-03, proto:stream-D.
- data-01 + mem-13: covered by proto:datapack.
- data-02: covered by proto:datapack.
- data-05 + mem-12: covered by proto:datapack.
- data-10: covered by proto:datapack.

Rejected after verification:

- **mem-14**: not worth it: Skip. If someone wants the 223 KB anyway: in AttuneNext_OnDataReady after InvalidateStatusCacheSets() set `ANx.db.statusCache = nil; ANx.statusDirty = true`, delete the Core.lua:1621 export, and make the PLAYER_LOGOUT export ignore the dirty flag when db.statusCache is nil so a snapshot always exist
- **load-03**: refuted: The decode exists and the trigger chain is real, but the proposal does not reduce the cost in the scenario the status cache exists for, and the trigger is being removed elsewhere. Trace: Core.lua:1757-1759 PLAYER_ENTERING_WORLD -> ZoneWatch.lua:322-332 ZoneWatchUpdate -> ANx.After(0.8) -> ZoneWatchN
- **frame-10**: not worth it: Skip as a performance change. If the handler is edited for another reason, move the UNIT_AURA branch to the top as `if event == 'UNIT_AURA' then if arg1 == 'player' and ANx.QueueSpeedAuraScan then ANx.QueueSpeedAuraScan() end return end` (3 lines, zero risk).
- **mem-10**: refuted: The premise that arbitrary non-universe ids flow in from tooltips and loot alerts is false, so the proposed cap and noCache flag would never do anything. Core.lua:524-531 GetItemName is called only from UI.lua:3195 (name sort) and UI.lua:3603 (search over Engine.Universe()), i.e. bounded by the univ
- **load-12**: not worth it: Skip; it is below any user-perceivable threshold. If someone touches Settings.lua anyway: `panel = CreateFrame('Frame', 'AttuneNextOptionsPanel', InterfaceOptionsFramePanelContainer); panel.name = 'AttuneNext'; panel:SetScript('OnShow', function(p) if not p.built then p.built = true; BuildControls(p
- **micro-09**: not worth it: Skip in favour of gc-12. If a zero-resident-memory option is ever required, the pattern is correct and garbage-free but costs ~60% more CPU per render than today's lower()+find.
- **ui-08**: not worth it: Skip. Made moot by ui-01 (no more 18-render bursts). If in-client profiling ever shows the strip, throttle it by time (at most one strip pass per 0.5 s of renders, plus the existing OnShow strips) rather than probing region counts.
- **ui-11**: not worth it: Skip. If memory ever matters, the cheaper cut is the 12 list rows' 9-slice card borders (108 textures) -> 3 slices, which changes nothing in render code; leave the panels as they are.
- **ui-12**: not worth it: Skip as a standalone item; moot once ui-01 removes the render bursts. If someone is in SetChip anyway, the two-line `if b.anxLastText ~= text then b.anxLastText = text; b.anxLabel:SetText(text) end` guard and passing the SerializeView result into FavIndexOfCurrent are free.
- **ui-14**: not worth it: Skip, except the four-line cleanup of moving SetScript('OnUpdate') into the grip's OnMouseDown and nil-ing it in FinishSizing if the file is touched. Rows-on-demand and one-time filter defs are not worth the churn.
- **ui-15**: not worth it: Skip unless in-client profiling shows SetTexture on scroll; if done, put the guard inside SetIconArt/SetArtTrim (tex.anxKey/anxBox) and clear it in ClearArtCoords and SetRecIcon, ~10 lines.
- **load-14**: not worth it: Skip as a performance item: ~128-256 KB resident and one packet per login is not worth a visible first-open flicker plus an extra render. If the author wants it for tidiness anyway it is ~10 lines in QuestArrow.lua: delete the PLAYER_LOGIN timer (:45-46), add `function ANx.EnsureCompletedQuests() if
- **frame-02** (also micro-06): no verdict returned
- **frame-09**: refuted: The mechanism is exactly as described (driver OnUpdate at Nameplates.lua:642-644 runs every frame when mode is 'off': PumpZoneIndex returns at :272 on `not zoneBuilding`, NP.Enabled (:67-69) does two table lookups through Cfg (:63-65); the event frame (:681-694) stays registered and returns at :686)
- **frame-13**: refuted: Mechanism as described: ScanForNewPlates (Nameplates.lua:557-569) adds every WorldFrame child that passes IsNameplate to `plates` and never removes it (:52); RefreshAllPlates (:572-574) iterates all of them every PLATE_POLL=0.2 s (:36, :652-656); UpdatePlate returns at :502 after one IsShown call fo
- **mem-15**: refuted: Mechanism confirmed: NP.ScanEntry stores `{drop, vend, count, best, at, dropIds}` per entry id (Nameplates.lua:131-132, :164); the TTL is only checked on read (:127, which rescans and overwrites) and expired entries are pruned only at the end of a zone-index build (:294-297); OnAttune (:612) and Inv
- **data-09**: not worth it: Skip. If the generator batch is done anyway, the only piece worth taking is ANx.LimitedItemsPacked (85 sorted 4-hex ids, 340 chars) replacing limitedItemsSet with PackedFind(set, itemId, 0) - a 5-line change - and leave VendorStock's nested tables alone (34 KB).
- **data-11**: not worth it: Skip. 40 KB (64-bit) / ~28 KB client is below the noise of the 30-150 MB heap, and both readers are membership tests on paths that can run thousands of times per render or warmup. If anything, the gap-real-db-shape-02 streaming rewrite of ItemHasRareSource makes RareNPCs an even hotter per-row read,
- **data-12**: not worth it: Skip both halves. If Art is ever regenerated (e.g. for the thumbnail repack in ui-07), the generator may emit strings then, with ANx.ArtCoords(key) as the single reader, but do not open the 30-site refactor for this saving alone.
- **data-13**: not worth it: Skip as its own change (a ~5 KB saving). If data-07 lands and pack_data.py grows a VendorLocs pass, have it emit one ANx.ZoneNameById union in Data_VendorLocs.lua (loaded before Data_QuestGivers? no: the TOC loads Data_QuestGivers.lua first at AttuneNext.toc:12, so emit it there) and point UI.lua:27
- **load-08** (also data-14): not worth it: Skip for now; ship proto:datapack instead (it removes ~85% of the same bytes and compile with no packaging change). Revisit LoadOnDemand only if the author later wants load-09's UI module too, in which case both ride one 'AttuneNext_Extra' sub-addon with a single EnsureLoaded() shim called from UI.S
- **load-09** (also ui-13): not worth it: Skip. Only reconsider together with load-08 if the author decides to split the addon anyway; then UI.lua + Win_Browse.lua go in the same sub-addon behind ANx.OpenUI() (LoadAddOn once, then UI.Show/Toggle), with the slash command and minimap/options handlers calling the shim instead of testing ANx.UI
- **mem-11**: not worth it: Skip. The resident and on-disk cost is proportional to vendors visited and sits in the tens-to-low-hundreds of KB for real accounts; the migration and name-palette handling are more code and risk than that buys. If the SavedVariables file is ever the target again after svpack, revisit this as 'store
- **gap-client-c-costs-10**: Skip if 01 is adopted; otherwise do later as a 20-line rewrite of the loop: compare raw left/right against the exact strings first, call clean() only when byte 1 == 124 ('|'), fetch TextRight only when left is 'Faction:' (raw or cleaned), run the race fallback only on lines containing 'Races' / the ITEM_RACES_ALLOWED prefix, cap at 12 lines, and in...
- **gap-real-db-shape-10**: Skip as a standalone change; it is subsumed by 01 (scan stops using the array cache) and 04 (renders stop using it). Only if 01/04 are rejected: in builders['zones'] show 'Scanning...' for every zone while Engine.scanning is true and rely on the summary onDone refresh (~5 lines in UI.lua:2657-2676).
- **gap-two-addons-pacing-07**: Skip for now (optional later): the measured win is ~1 MB resident and ~1.5 ms of load, well under the noise of 01. If done, emit the guard from the generator in every Simple Data_* file except Data_Art: `do local host = _G.AttuneNext; if host and host.DATA_FORMAT == ANx.DATA_FORMAT and host.<FirstTable> then ANx.A, ANx.B = host.A, host.B; return en...
- **gap-two-addons-pacing-09**: Skip; superseded by 01. Keep only as the fallback inside 01's data-ready poll (if the host exists but lacks ShareStructure, wait for its idle queue, cap at 120 polls, then scan).
- **gap-two-addons-pacing-10**: Skip as a performance item. If 01's Simple rework is done anyway, let Simple skip ScanMerchant/TrimMerchantDb and QueryQuestsCompleted when _G.AttuneNext exists and read the host's CostString/StockString/completed-quest table through the host ANx functions, which saves one server query at login and a few hundred KB of duplicate vendor records in Si...

## 6. How to measure

Harness (copy `tools/` next to the repo; `pip install lupa luaparser`; run with `python -I`; set `ADDON` to the addon folder and `NOSV=1` to skip SavedVariables):
- **Baseline and scan path:** `NITEMS=20000 ZONEN=600 HEAVY=200 READY_AT=5 FRAMES=1500 python -I harness.py`. Watch "scan finished at frame", "peak", and the "GetSources calls ... rows built" line. Add `PROFILE=1` for resident memory per cache, `ALLOC=1` for allocation by line, `CALLERS=1` for who calls `GetSources`, and `LOADPROF=only FRAMES=1` for per-file compile time.
- **Named scenarios:** `SCENARIO=fresh-scan|mismatch-names|heavy-tail|two-addons|30fps|cached-login|ui|stock python -I harness_scenarios.py`. It uses a fast bit library and matching zone names by default; `stock` reproduces the old numbers. Quote the scenario with every number.
- **Heavy tail and equivalence:** `harness_gapx.py` with `WDROP`/`WROWS`, and `equiv_gap.py`, which must report identical summaries and zero `BestSource` mismatches.
- **Client-call costs:** `FILTERS=bind,faction,class python -I harness_cc.py` (add `CACHEPCT=30 QUERY_DELAY=5` for a cold item cache, `FILTERS=bags` for In bags). Watch tooltip, `GetItemInfo` and `GetItemCount` counts per render.
- **Pacing and the two addons:** `harness_pace.py` with `ADDONS` listing both addons, `FPS` and `SLOW`. Watch addon ms per frame, worst frame and peak.

In game:
- `/an perf` after one fresh-scan login (`/an reset` first) and after one cached relog. Read rows per item, largest item, flush count, fallback count, pump ms per frame, worst frame and the export times.
- The SavedVariables file size after a relog.
- The first-open time of a zone list and of What's Left after a relog.
- The `Errors` folder after a forced rescan with both addons enabled. Out-of-memory remains the one failure the harness cannot rule out.

## 7. Plain-language summary

When you log in, AttuneNext reads the server's loot list to work out where every item comes from. Today it copies each line of that list into its own little record, uses it once, and throws it away. It does this over a million times per login, and again for every zone an item appears in. That is what makes the login scan long and what pushed memory toward the crash limit in September and October.

The top fix is to read each line directly and keep only the answer. In testing this halved the login scan and cut the memory spike by about 40%, with identical results.

The second fix stops repeating slow game calls. With some filters on, the addon re-reads thousands of item tooltips every login and counts your bags thousands of times per screen. Remembering those answers removes most of that work.

The third fix makes the background work politer. Today it can take a whole frame or more at a time, which shows up as stutter. Capping it keeps every frame of the scan under one sixtieth of a second in testing.

If you run AttuneNext-Simple too, it currently repeats the entire scan. Letting it borrow the main addon's results would roughly halve the combined memory.

Everything here was measured in a test program that imitates the game, not in the game itself. The numbers show direction and rough size, not exact in-game figures. The first step is a small update that only adds measurement, so one login in the real game can confirm the numbers before the larger changes go in.
