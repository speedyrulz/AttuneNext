# AttuneNext Handoff

Oct 15, 2026 · @Jeff

This updates the Oct 14 handoff (v3.6.2). Everything in that document still holds unless this one says otherwise: file locations on Jeff's PC, the code map, the nine-step "adding a new filter" checklist, the release workflow and the gotchas. This document covers what changed since: a full performance audit and the v3.6.3 telemetry release.

## Current state

| Item | State |
| --- | --- |
| Latest code | **v3.6.3**, on branch `claude/youthful-lamport-z0zec3` of [speedyrulz/AttuneNext](https://github.com/speedyrulz/AttuneNext). Not merged to `main`. No pull request opened. |
| Released | v3.6.2 is still the latest GitHub release and the installed copy. v3.6.3 has no zip, no release and is not installed. |
| Addon behaviour | Unchanged since v3.6.2. v3.6.3 only adds measurement. |
| Tested in game | Nothing from this session. The v3.6.2 crash fix and the In bags toggle are also still unconfirmed in game. |

Branch commits on top of v3.6.2 (`3757547`):

| Commit | What |
| --- | --- |
| `a97e49e` | `docs/perf-audit/`: six prototype diffs, measurements, harness tools |
| `450af5f` | `docs/perf-audit/REPORT.md`: the ranked audit report |
| `66e25c0` | v3.6.3: `/an perf` telemetry and `/an srcstats` |

To work locally: `git fetch origin claude/youthful-lamport-z0zec3`, then check it out in `C:\World of Warcraft\AttuneNext`.

## What v3.6.3 adds

Files touched: `Core.lua`, `Engine.lua`, `AttuneNext.toc`, `README.md` (changelog entry written).

- **`/an perf`** prints six new lines after the existing memory and cache lines:
  - `fps ... scan:` frame rate, universe size, seconds from data-ready to summaries done and to idle.
  - `pump:` scan frames, total ms, worst frame and its job, frames over 2x budget, longest single resume, GC step time.
  - `sources:` `GetSources` calls and rows, the heaviest item, source-cache flushes, items too big to cache.
  - `zones:` items classified, how many took the localized fallback path, samples of unknown zone names, addon zones no row ever named.
  - `client:` tooltip scans per scraper, empty tooltips, item-cache requests, `GetItemCount` calls.
  - `timers:` deferred callbacks, the slowest by name, and the time of the structure and status exports.
- **`/an perf reset`** zeroes the counters.
- **`/an srcstats`** walks the loot DB as a background job and prints rows-per-item buckets, items with 1000+ rows, how many zones list each, and the source-type mix of the heaviest twenty.
- `ANx.After(delay, func, name)` takes an optional third argument; the main login timers now pass names so `/an perf` can report them.
- Counters live in `ANx.Perf` (created in Core, extended in Engine; Engine re-creates it if absent so AttuneNext-Simple's older Core still loads).

Headless check: identical scan work to v3.6.2 (66,609 `GetSources` calls, 1,357,213 rows), peak memory within noise, both commands driven through the slash handler, including a run with 1,500-row items.

## Immediate next steps

1. **Release v3.6.3** with the usual seven steps (version is already bumped; changelog is written). Merge or fast-forward the branch into `main` first.
2. **Take one reading in game.** Type `/an reset`, wait for the "data has been refreshed" toast, then `/an perf` and `/an srcstats`. Paste the full output into the next chat. Also do one plain relog and run `/an perf` again.
3. Two numbers decide the plan:
   - `zones: ... N by fallback`. If 0, the English client never takes the slow path, so the saved-structure packing (`proto_svpack`) drops in priority. If it equals the item count, the fallback is live and is the main memory cost.
   - `sources: biggest N rows`. Sets `SRC_ROW_BUDGET`, the BestSource index cap and the per-scan memo size for v3.7.0.
4. The older open items from the Oct 14 handoff still stand (confirm the crash fix with and without Simple, confirm In bags, tell the requesting player).

## The performance audit

Read `docs/perf-audit/REPORT.md` first. It ranks 75 verified optimizations into three tiers and ten bundles, with file and line references, measurements, an implementation order, 28 rejected findings with reasons, and a plain-language summary.

Top findings, in short:
- **Streaming source rows.** The login scan and the per-item filter checks build one 9-field table per source row, and rebuild a world drop once per zone that lists it: ~1.36 million throwaway tables per login in the harness. Reading `ItemLocGetSourceAt` directly instead gave identical results with peak memory 145 to 84 MB and the scan 410 to 187 frames.
- **Client-call costs.** With Bind/Faction/Class filters saved, every login re-reads 17-22k tooltips. With In bags on, every render calls `GetItemCount` 19-36k times. Switching Faction or Class on reads 12-13k tooltips in one frame.
- **Pacing.** The pump's 10 ms budget excludes its GC step and lets single resumes run 52 ms. A time-capped pump brings the worst resume to 11-15 ms. The status-cache export at scan end is one 60-200 ms frame.
- **Two addons.** With Simple enabled the scan runs twice; Simple adopting the host's structure would bring the pair from 252-275 MB to 145 MB.

Prototypes in `docs/perf-audit/prototypes/` (each applies with `git apply` against v3.6.2; measured, equivalence-checked, never run in game; `MEASUREMENTS.md` has every number):

| Diff | What |
| --- | --- |
| `prototype_stream.diff` | Streaming `ZoneData` and the quest/zone predicates, memoized pick sort, export only at logout |
| `proto_bestsource.diff` | Streaming `BestSource` with a memo; sixth return becomes `objId` |
| `proto_svpack.diff` | Packed SavedVariables structure, lazy zone decode, scan-end export as a pump job. Supersedes the "export only at logout" part of `prototype_stream.diff` |
| `proto_pacing.diff` | Time-capped pump: 2 ms slices, GC steps capped by time, combat budget |
| `proto_datapack_code_only.diff` + `pack_data.py` | QuestGivers, QuestPre and Reagents as index + blob; the generator needs the *unpacked* data files as input |
| `telemetry_an_perf.diff` | Already applied in v3.6.3 |

Suggested v3.7.0 contents, after the in-game reading: streaming source rows, the time-capped pump with the status export as a job, warmup on cached logins, the render memos (GoalStatus, clear-chance cache, What's Left), and the filter client-cost fixes. Later: packed saved structure, Simple adopting the host, packed data, texture conversion to BLP. Every engine change also needs porting to AttuneNext-Simple until it adopts the host's structure.

## Harness and testing

The audit found two flaws in the original `harness.py`; numbers taken with it need correcting:
- Its pure-Lua `bit.band` is 3-13x slower than the client's C version, inflating predicate-heavy timings.
- Its zone names (`Zone0..59`) never match the addon's, forcing every item into the localized fallback path. That alone produced the 46 MB zone cache and 27 MB saved structure; with matching names the zone cache is 5.4 MB.

`docs/perf-audit/tools/` holds the improved harnesses:
- `harness_scenarios.py`: named scenarios (`fresh-scan`, `mismatch-names`, `heavy-tail`, `two-addons`, `30fps`, `cached-login`, `ui`, `stock`), fast bit library and matching zone names by default. Use it from now on and quote the scenario with every number.
- `harness.py`: the original plus `LOADPROF=only` (per-file compile time) and `CALLERS=1` (who calls `GetSources`).
- `harness_cc.py` (tooltip, `GetItemCount` and item-cache costs), `harness_pace.py` (two addons, frame rate), `harness_gapx.py` + `equiv_gap.py` (heavy tail and equivalence), plus benches and patch generators.

Several scripts still default `ADDON` to `C:\World of Warcraft\AttuneNext` and a few reference scratch paths from the cloud session; set `ADDON` explicitly. Needs `pip install lupa luaparser`.

## Gotchas added this session

- AttuneNext-Simple's `Engine.lua` is a copy of the v3.6.2 engine minus the In bags block, not v3.6.0 as the old handoff said.
- Both addons create tooltip scraper frames with the same global names, so one addon's scrape can feed the other's. Fix before ever sharing flags between them.
- On a cached login, nothing enqueues the predicate warmup or the button pick, so the first screen computes everything cold.
- Lua 5.1 cannot yield across `pcall`, `table.sort` or metamethods; never call `MaybeYield` from inside `ItemBestDropChance` (it runs inside a sort comparator).
- `collectgarbage("setpause"/"setstepmul")` is global to every addon in the client; the audit rejected touching it.
