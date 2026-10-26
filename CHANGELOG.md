# Changelog

All notable changes to AttuneNext, newest first. Usage documentation lives in the [Wiki](https://github.com/speedyrulz/AttuneNext/wiki).

## v4.1.0

- Added a **Stats** filter. Click the new *Stats* chip to pick any of 21 stats (primary stats, attack and spell power, hit, crit, haste, expertise, armor and spell penetration, the tank stats, resilience, MP5, HP5 and gem sockets) and every list, count, recommendation and filtered nameplate shows only gear carrying them. Match **any** picked stat or **all** of them. Stats are read with the client's own `GetItemStats` and cached for the session; the first time you pick a stat, a background sweep reads the whole item list.
- When the filter chips need a third row (a prestige character on a vendor screen, or now a raid screen), the list moves down one row instead of the chips overlapping it.

## v4.0.0

*The login scan is rebuilt around reading the server's loot database without copying it. On the Oct 14 in-game reading the old scan read 42 million source rows (for 2.2 million real ones), built a Lua table for each, ran for three minutes at 36 ms a frame with one 3.8-second freeze, and re-read 40,000 item tooltips. Each of those has a fix below. Your saved scan is rebuilt once on first login (the version changed).*

- **Source rows are streamed, never copied.** Every scan, count and filter now reads rows straight off the server API and stops at the first row that decides it. Each item is classified **once per scan** into a compact memo that every zone reads, instead of once per zone that lists it. In the headless harness the heavy-tail scan went from 602 frames and 33.7 s to 81 frames and under 1 s, peak memory from 109 MB to 37 MB, with results verified identical to the previous version (summaries, every zone's data, 19,224 best-source lookups, all filter predicates).
- **The background pump keeps to its frame budget.** Scan slices yield after 2 ms of work instead of every 25th item, the garbage collector gets small bounded steps inside the same 10 ms budget instead of one unbounded step after it, and the budget drops to 4 ms in combat. The scan-end status export runs as a background job instead of one 60-200 ms frame.
- **Tooltip results are remembered across sessions.** Bind type, faction lock and class lock are read from item tooltips; with a Bind or Faction filter saved, every login used to re-read 18-22 thousand of them. They are now saved at scan end and logout and restored at load. *Rescan loot DB* clears them.
- **"In bags: Hide" no longer asks the client about every item on every render.** One owned-items set is built per bag, bank or equipment change by walking your containers.
- **The zone-entry note no longer freezes the frame at login.** While caches are cold its item walk runs in the background and the note and instance HUD appear when it finishes (803 ms on the main thread in the Oct 14 reading).
- **Cached logins warm their caches too.** A login that restores the saved structure runs no scan, so the first screen used to compute every filter predicate cold.
- **The zone-fetch API is called once per zone per session.** On the live client `ItemLocGetAllItemsInZone` costs 60-140 ms per call; the first v4.0 test reading spent 24 s of a 40 s scan in 400 such calls, and 7 s of a cached relog in 74. Each zone and instance difficulty is now fetched once, and each uncached instance fetch gets its own frame instead of three in one resume.
- **Best-source lookups come from a per-item index.** Zone lists, rankings and the instance HUD ask "best source of this item in this zone" once per zone, and each call used to walk the item's whole row list (4.3 million rows for one run ranking). One walk per item now builds a small index that answers every zone and filter question. Results verified identical.
- **More telemetry in `/an perf`:** zone-fetch timing, which yield site ended the longest resume and how the heap moved inside it, peak Lua memory, streamed row counts, and every deferred timer now has a name.

## v3.6.3

- Measurement-only release, no behaviour changes. `/an perf` now reports what the login scan actually did on your client: source rows read per item and the heaviest item, how often the source cache flushed, how many items were classified by zone name versus the localized fallback (with samples of unknown zone names), pump time per frame with the worst frame and its job, garbage-collector time, the slowest deferred callback, tooltip scans and cache requests, and the cost of the two exports. `/an perf reset` zeroes the counters.
- New `/an srcstats`: a background walk of the loot database that prints rows-per-item buckets, the heaviest items and how many zones list them. One reading of these two commands after a fresh-scan login (`/an reset` first) sizes the cache limits for the performance work planned for v3.7.0 (see `docs/perf-audit/REPORT.md`).
- The version bump rebuilds the saved scan once on first login.

## v3.6.2

- Fixed an out-of-memory crash at login ("Not enough memory resources", with *Universe* named as the current function). The background scan rebuilds every item's source list, and world-drop items can list thousands of creatures. The source cache was capped by item count only, so it could hold millions of records, and the scan's short-lived garbage was left to pile up. The cache is now capped by record count too, a redundant pre-load of every item's sources was removed, and the collector gets a small step each scan frame. In testing this roughly halved peak memory during login.
- Running AttuneNext and AttuneNext-Simple together scans the loot database twice. They work side by side, but if you only use one, disabling the other saves a lot of memory.

## v3.6.1

- Added an **In bags: Show / Hide** toggle (toolbar chip and right-click filter menu). Set to Hide, it drops items you already have in your bags, bank, or equipped from every list, count, recommendation and nameplate filter — they're looted, they just aren't attuned yet. Refreshes automatically on loot, bank and equipment changes. Requested by a user who couldn't find such an option.

## v3.6.0

*A maintenance release: about half the addon's memory footprint removed, a faster login, and a batch of bugs found by a full audit. Your saved scan is rebuilt once on first login (the version changed), so expect one short "Scanning…" pass.*

**Memory — roughly halved.** Measured against the previous version on an identical 20,000-item database: **-49%** of the addon's data memory, both at login and after the background scan. Where it came from:
- The **quest faction table was deleted outright** — all 4,819 entries turned out to be exactly derivable from the quest race data the addon already ships (verified entry-by-entry), so it was pure duplication.
- The big static tables — quest givers, quest names, quest requirements, vendor costs, bind types, spawn counts, vendor locations, profession recipes — are now **packed strings and parallel arrays** instead of tens of thousands of small Lua tables. Same data, a fraction of the overhead: `Data_QuestReq` went from 5,904 lines to 80, `Data_Faction` from 9,231 to 58, `Data_Professions` from 2,850 to 562.
- The **item display cache no longer hoards item links** (a unique ~100-byte string per item). One search used to pull the entire item universe into memory permanently.
- **Eight separate per-item caches became one packed table.** Each was a sparse hash holding a single flag per item, and each rounded up to roughly half a megabyte.
- **Saved-variables hygiene**: vendor prices and stock are stored only for *attunable* items (opening any vendor used to permanently record its entire inventory — food, reagents, grey trash), "unlimited stock" markers are no longer written at all, alt snapshots are stored as one compact string per character with a 60-day expiry for characters you no longer play, and the login status snapshot is string-encoded. Existing saved data is cleaned up automatically, once.

**Login and general speed.** Also measured against the previous version: **-37%** to parse the addon's files, **-15%** on the background scan, **-16%** overall.
- The background warm-up is now **filter-aware**. It only pre-computes the things your *active* filters actually read — with default settings that skips bind types, accessories, quest-side and item levels for the whole database, including thousands of hidden tooltip scans that nothing was going to consult. Switch one of those filters on and it tops the missing data up in the background instead of stalling the next screen.
- **Scrolling a list no longer rebuilds it.** Every mouse-wheel notch used to re-run the whole view builder — re-walking, re-sorting and re-allocating the entire list to repaint twelve rows. Scrolling now only repaints. Dragging the browse window's resize corner did the same thing on every frame; it doesn't any more.
- **Searching is debounced and no longer hammers the server.** Typing rendered synchronously on *every keystroke*, walking the whole item universe, and asked the server to cache every item it couldn't resolve — re-asking for the same items on every keystroke. It now waits for you to stop typing, and each unresolved item is requested at most once per session.
- **Distance sorting no longer hijacks your world map.** Ranking by distance asked the client for your position once per row — and in the arrow router, once per sort *comparison* — each of which yanked an open world map back to your current zone. Position is now read at most once a second, and never while your map is open.
- **Attunement progress no longer wipes every cache.** The server reports progress on essentially every kill while wearing attuning gear; each report cleared the stat caches, rebuilt the screen and refreshed every nameplate. That work now happens only when an item actually *completes*.
- Merchant, profession-window, currency and aura events now check whether anything really changed before invalidating anything, so re-opening a known vendor or batch-crafting no longer triggers a full recompute every half second.

**Fixes**
- **Fixed a Lua error when selecting an item your character can't attune.** The detail pane was passing an item id where a list of characters was expected, which errored mid-draw and left the window half-painted, repeating on every redraw.
- **Fixed `/an reset` (and the Refresh button) not clearing the item-level cache.** A scoping slip meant it cleared a stray global instead. Items the client hadn't cached yet stayed hidden by the level filter for the rest of the session with no way to recover short of a `/reload`.
- **Fixed the addon getting stuck with no data after a `/reload`.** The fallback that polls for the server's data was written so it could never run on Synastria; if the reload landed at the wrong moment, the addon served stale login data for the whole session.
- **Fixed nameplate marking being silently dead for ElvUI and KuiNameplates users.** Both blank the texture AttuneNext used to recognise a nameplate, so it never found any — no glow, no tag, no error. It now falls back to recognising plates by their structure.
- **Fixed new settings not appearing for players upgrading from an older version.** Defaults were only filled in for settings groups that didn't exist yet, so options added inside an existing group (such as the nameplate glow pulse) stayed switched off with no way to enable them.
- **Fixed the BoP/BoE filter permanently hiding items.** Items the client hadn't cached during the first moments of login were recorded as "unknown bind type" forever, and the filter hides unknowns. It now re-checks once the client knows the item.
- **Fixed an alt's forged item counting as done for a character that has never attuned it** under Character scope (forge level is account-wide; progress is not).
- **Fixed "Reset all filters" not resetting all filters.** Bind, accessories, difficulty, raid size and affordable-only survived it — and the copy of the button in the Interface panel reset a different set again. Both now share one implementation.
- **Fixed three checkboxes in the Interface panel never showing their real state**, including "In an instance, show only that difficulty", which is on by default and therefore displayed wrongly for everyone.
- **Fixed the affordable-only filter reading zero** for any currency sitting under a collapsed header in your currency panel.
- **Fixed disabled (unobtainable) items counting toward account totals**, which could stop a category ever reaching 100%.
- **Fixed a single malformed quest row being able to wedge the whole background scan**, leaving an expansion permanently "scanning".
- **Fixed same-named NPCs blanking each other's nameplate marks** — checking one that had nothing left un-marked every other mob sharing its name.
- Smaller fixes: the "What's Left" breakdown header always claimed *Account* even in Character scope; recommendation cards could keep a previous item's icon in the unskinned layout; errors inside delayed callbacks were swallowed unless debug logging was on, so a failure looked like "the list just didn't refresh".

## v3.5.1
- **Prestige mode** (Options toggle, off by default). After prestiging you attune as two classes at once, so this unlocks a **Class filter chip** on every list: pick a class and everything narrows to gear it can use - its armor types, learnable weapon types, its relic, and explicit "Classes: ..." tooltip locks (which always win). Cloaks, rings, necks and trinkets count for every class; items the client hasn't seen yet are never hidden. Counts, What's Left, recommendations and nameplates (respect-filters mode) all follow it. Turning the toggle off resets the filter.
- **"Class filter means"** (second option, shown while Prestige mode is on): *The class's own gear* (default - a Warrior does not pass cloth) or *Anything it can equip* (physical equip rules - a Warrior passes cloth too). Weapons, shields, relics and class locks stay strict in both.

## v3.5.0
- **Large memory-use reduction.** The addon was retaining the raw source data (heavy multi-field records) for *every* attunable item in the database for the whole session - hundreds of MB on big accounts. It now keeps only a small bounded working set of sources (the handful you actually view/rank), releasing the full set once the background scan has distilled everything into the compact filter caches that counts and filters actually use. Also stopped storing a per-zone item list that was never read again, and made the recommendation's "has a source?" check count-only instead of building the full record. `/an perf` shows the numbers; `/an flush` reclaims the source cache on demand.

## v3.4.7
- **Fixed Quests, World Drops and Vendors showing 0 in What's Left (and empty zone browsing) on non-English clients.** Those categories classified each item by matching its source's zone name against the addon's English zone names, so a localized client (e.g. Russian) never matched and zeroed all three - while dungeons/raids (matched by numeric map id) worked fine. Zone items are now attributed by the loot DB's own per-zone list, falling back to the item's source types when the source zone names aren't recognized. English clients are unaffected.

## v3.4.6
- **New "Match my instance difficulty" option** (Options, the Interface panel; on by default): while you are standing inside a dungeon or raid, that instance's list shows only the difficulty you are actually in - e.g. only the 10-man in Ulduar-10, hiding the 25-man. It switches with you if you change difficulty in-game, only affects the instance you are physically in (other instances still show every difficulty), and turns off the moment you pick a manual Difficulty or Size filter. The instance HUD and the recommendation for that run follow the same narrowing.

## v3.4.5
- **New "My quests" filter on quest pages** (chip on the quest screens, default on): hides quests your character's class or race can never take - like the class-locked ring trios - under either scope; flip it to *All classes* to see everything. Under Character scope, a reward obtainable ONLY through quests you can't take (e.g. *Band of Eternity* behind a warrior/paladin quest, seen by a Hunter) is also filtered from every list, count and recommendation; Account scope keeps it, since an alt can do the quest. The old always-on race/class hiding under Character scope moved into this filter.
- Synastria's custom quests are not in the generated class data: masks for them can be added to `ANx.QuestClassExtra` / `ANx.QuestRaceExtra` (Core.lua). With `/an debug` on, quest rows show their quest id to make collecting these easy.

## v3.4.4
- **Fixed the ~5s freeze on the first window open after a reload and on first visits to screens.** The counts on every screen were computed inline against cold per-item caches - the first pass resolved faction and bind by scanning item tooltips and enumerated every item's sources on the spot. A background warm-up now walks every item once right after the login scans (same 10ms-per-frame pump), so first renders find everything cached; until it finishes, the home cards show placeholders instead of stalling. `/an perf` now reports whether the caches are warm.
- **Quest CHAINS pick your faction's steps too**: when a neutral quest (e.g. *Enraged Spirits of Air*) is unlocked by either faction's copy of a chain step (*The Hand of Gul'dan*), the chain resolver now walks the version your character can take - a Horde player is sent to the Horde chain giver. If every alternative belongs to the other faction, it stops at the quest instead of routing somewhere unusable.
- **Dual-faction quests route to YOUR faction's version.** Quests like *Besieged!* exist as an Alliance copy and a Horde copy sharing the same reward; the arrow, the *best source* line and the item's source list all used to pick whichever came first. They now prefer the version your character can actually take - a Horde player is arrowed to the Horde quest giver - the other faction's copy is tagged (*[Alliance quest]*) and sorted below, and if an item's only quest is truly the other faction's, the arrow says so instead of pointing at an unusable giver.
- The **Horde/Alliance filter now gates quests properly**: quest rows for the other faction are hidden (quests missing from the curated faction data derive their side from their race requirements), and items obtainable **only** from the other faction's quests are filtered out of every list, count and recommendation. Items that also drop or are sold somewhere are unaffected, and neutral quests always pass.

## v3.4.3
- **The recommendation cards now derive WHAT to recommend from the screen itself** - their run-mode option is gone (the AttuneNext button keeps its own). Raid screens recommend the best raid run, dungeon screens the best dungeon, zone lists the best zone sweep, and vendors, quests, professions and item lists get a single item pick from what you are looking at; overview screens (Home, an expansion) recommend the best of everything, falling back to an item when nothing is runnable. Thanks to the user who suggested it.
- **Fixed the multi-second freezes when clicking around the addon, and the memory errors.** Three causes: the recommendation cards were re-walking every attunable item **inline on every render** (the run *rankings* went to the background in 3.2.1, but the single-item pick never did); the structural cache was being re-serialized into SavedVariables after **every** filter click instead of only when a scan changed something; and cached run lists kept full per-screen copies forever. Picks are now computed on the background pump and cached per screen (cards show *Finding a pick...* for a moment), the AttuneNext button's pick is precomputed so pressing it is instant, exports only happen when the data really changed, and cached lists are capped. `/an perf` shows live memory and cache numbers.

## v3.4.2
- Recommendation cards now respect both context dimensions with run mode *All* or *Zones*: no zones from the wrong expansion (Hellfire while in Classic), and no zone sweeps at all while browsing dungeons or raids (Silithus while in Classic raids) - the expansion overview screen still offers its zones. The button still considers everything, as intended.

## v3.4.1
- **Nameplate marking**: mobs that still drop something you have not attuned glow **green** on their nameplate (*drops N*), and vendors selling something unattuned glow **blue** (*sells N*). Mobs mark from the zone's loot data automatically; vendors mark when you point at them or open their shop. Options under Options > Nameplates: **Mark nameplates** (Off / On / Respect filters - only items passing the window's filter chips), **Attunes counted** (this character / whole account), and **Pulse the glow**. Vendors only glow if friendly nameplates are on (**Shift-V**) - the addon reminds you if they're off. `/an plates` cycles the mode, `/an plates report` and `/an plates why` diagnose.
- The cards' **Current level filter** now filters the whole window: every list, count and card hides items whose required level you don't meet - vendor stock included - and it re-checks when you level up. The button's own level filter still only affects the button's picks.

## v3.4.0
- **The AttuneNext button and the on-screen recommendation cards are now separate features with their own options.** Each has its own Focus, Drop rates, Current level filter and whole-run mode (Options screen has a section for each; `/an settings` carries the button's). The defining difference: the **cards are always context sensitive** - they follow the screen you are looking at - while the **button is always global**, recommending from everything you still need no matter where you are. The old "Context sensitive" toggle and "category overrides" rule are gone; the ignore list stays shared.
- **New Current level filter** (off by default, per feature): recommendations only include content the current character's level supports - dungeons, raids and zones whose minimum recommended level is at or below your level, and vendor/crafted items whose required level you meet. Built-in level data covers all 74 instances and 72 zones.

## v3.3.0
- **Run length can now weigh in on recommendations**, off by default. The **Run length** setting (Options, the Interface panel, or `/an timemode`) offers **Off** (ignore how long a run takes), **Built-in estimates** (shipped clear times for all 73 dungeons and raids, per difficulty), **Personal times only** (just the instances you have a Dungeon Challenge time for - anything else stays neutral), and **Built-in + personal** (estimates, replaced by challenge times where known). Times are measured against a **1.00x = 15:00** baseline, so a 7:30 clear reads as 0.50x.
- **Personal times are derived from your Speed Buff.** The speed you have earned in an instance is a direct function of how fast your account cleared it - Synastria's thresholds are linear with 70% as the ceiling - so an earned buff of P% implies a clear in `estimate x (1 - P/70)`. The buff is read off your auras when you enter, which also works when the challenge itself fails because you out-level it; the Dungeon Challenge target is a fallback where no buff is known yet. Nothing is timed or recorded by the addon. Each difficulty is tracked separately, times are account-wide, and `/an times` lists them (`/an times reset` clears them).
- Recommendations show the run length they used - *"0.3x avg run"*, or *"~4:30 at 50% speed"* once your speed buff there is known.
- **Performance**: opening a screen no longer hitches. Run rankings and the What's Left report are built on a background pump (10ms per frame) and cached until something actually changes, and ranking waits for the item scans to finish rather than being redone every time one lands.
- Fixed goal names showing as *"Instance 603"* - they now resolve from the instance and difficulty, so two difficulties of the same raid are told apart.

## v3.2.1
- **Performance**: the first click on a menu entry no longer hitches. Run rankings and the What's Left report are now built on the background pump (10ms per frame) and cached until something actually changes, instead of being recomputed inline on every render - screens paint immediately and fill in a moment later. Per-clear drop odds are memoized, and two callers waiting on the same background job both get their result.

## v3.2.0
- Recommendations now factor in **how long a run takes** and **how many of each mob you actually kill**. Clear times for all 73 dungeons and raids (per difficulty - mythic and each raid size have their own) are built in, and static spawn counts for ~4,900 loot-bearing creatures turn a per-kill drop chance into a realistic per-clear chance: 2.5% off 40 trash spawns is now correctly rated above 20% off a single boss. Runs are ranked by **expected new attunes per unit of time**, so a 15-minute dungeon can beat a 2-hour raid, and every recommendation shows its run length (e.g. *0.3x avg run*). Goal clear estimates use the same math.

## v3.1.2
- Fixed the *"Fully attuned - swap it for the next one!"* alert firing on every attune **progress tick** for an equipped item instead of only when it actually finishes. It now checks real progress and announces once per item.

## v3.1.1
- Fixed a crash opening the simple browse window before the main window had ever been opened (the engine reference is now bound lazily).

## v3.1.0
- Added an **Unskinned layout** toggle (Options, the Interface panel, or `/an unskinned`): plain dark frames and standard Blizzard buttons instead of the painted art pack, for players who prefer the older look. The AttuneNext logo and sidebar emblem stay painted either way, and the switch applies instantly - no reload needed.
- New **simple browse window** (`/an browse`, `/anbrowse`, or `/run AttuneNextBrowse()` in a macro): a plain standard-WoW window with just the wordmark, the browse menus and their filters - no sidebar, goals, favorites or recommendation button. It shares the main window's data and filter settings, so lists match exactly, and it's **resizable** - drag the bottom-right corner; a taller window simply shows more rows.

## v3.0.0

*What's still needed*
- New **What's Left** section: a dashboard of everything you still need — attunes left, crafted items left, currency required, remaining per expansion, active goals, and your biggest raw-material needs. Drill into any card for the full breakdown; every total follows the Attunes (character/account) filter.
- **Raw-materials calculator** with built-in reagent data for all eleven professions: craftable parts are expanded down the whole chain (Casing → Bars → Ore) and your bags, bank and resource bank are subtracted, so you see the true raw materials still missing. A profession-window scanner records any server-custom recipes. Click a material to see which items need it.

*Better recommendations*
- The **AttuneNext button** can recommend a whole run, not just an item: **Off / Dungeons only / Raids only / Dungeons & raids / Zones / All**. Zone mode ranks open-world zones by expected attunes from quests and world drops. Results name the dungeon, raid or zone and show expected new attunes per clear, with Ignore to step to the next best.
- **Goal tracker**: track a dungeon set, a single instance, or one specific difficulty, then watch progress bars and estimated clears remaining — in the addon, on the home dashboard, or in a small on-screen window.
- The **Show filter is now Forge Level**: **Attunable / Titanforged / Warforged / Lightforged**, each showing what's done at that level versus what's left. Quest rewards can't be forged, so they count as complete once attuned.
- Under character scope, quest lists hide quests your **race or class can never complete** (4,800+ race and 1,000+ class restrictions mapped).

*Getting there*
- **Right-click any item** for an arrow to its best source: the highest-drop-rate mob (ties go to the closest zone), a rare's spawn points, the quest start, or the nearest vendor — and craft-only items open their profession window.
- **Quests that start from a dropped item** now have arrows too, pointing at whatever drops the starter (141 previously arrow-less quests), and **356 rare spawns** are mapped with multiple patrol points.
- **Tooltips** show *"still needed"* with an item's best source anywhere in the game, including an *"needed on the account"* note naming which of your characters can attune it.
- **Alerts** warn you when an item you need appears in a loot window or group roll, and when gear you're wearing finishes attuning.
- **Zone awareness**: entering a zone reports how many attunables are left there, and inside a dungeon or raid a resizable HUD lists them with their sources.

*Interface*
- Rebuilt in a **painted card style** (art by Jeff): a home dashboard with a live *Recommended Next* card, expansion progress and goals; a two-pane Browse with item details and a context recommendation beside the list; painted filter chips, sidebar navigation, clickable breadcrumbs, search with type filters, and Favorites for any screen plus its filters.
- **One Options screen** behind the gear button, mirrored by the Interface Options panel.
- **Instant data at login**: the addon saves every item's status on logout and shows real numbers immediately, then refreshes in the background and announces when it's current.

## v2.11.1
- **Profession screens now show crafted items only.** Some items sit in the profession data because a quest *requires* the profession (e.g. the Light's Hope Chapel "Polar Tunic/Gloves/Bracers" turn-ins need Leatherworking 300) — those were wrongly listed on the crafting screens with a skill level. They now appear only under Quests, where they're actually obtained.
- **Items nobody can attune are excluded everywhere.** If the server flags an item as not attunable at all (the tooltip's "Can't be Attuned" note), it no longer counts or shows in any list, even if the per-character check disagrees.
- The item detail page now shows a red note when an item **can't be attuned by anyone** or is **not attunable by this character** (wrong class/armor/faction), so an ineligible recommendation is visible at a glance.

## v2.11.0
- **Fixed missing event gear and added Noblegarden.** Some holiday gear drops from a loot *object* rather than the boss itself — e.g. Frost Lord Ahune's cloaks come from his **Ice Chest**, and Noblegarden's **Spring Circlet** comes from **Brightly Colored Eggs** — and those weren't being picked up. AttuneNext now reads gameobject loot too (including the heroic Ice Chest), added **Noblegarden** as an event, and ships a verified backbone list of each event's attunable gear so nothing slips through. Every event was reviewed: Hallow's End (Headless Horseman), Brewfest (Coren Direbrew), Midsummer (Ahune), Love is in the Air (Apothecary Hummel), Lunar Festival, and Noblegarden.

## v2.10.0
- **Quest sources are now clickable on the item detail page.** When AttuneNext (or any item you open) is obtained from a quest, click the quest's row under **Sources** to drop a waypoint arrow straight to the quest giver — and if you can't pick the quest up yet, the arrow points to the next quest in the chain instead (the row is tagged **[chain]**, **[in log]** or **[done]** so you know its state). Same behaviour as the quest lists, now available right where AttuneNext sends you.

## v2.9.4
- Fixed the AttuneNext **Opt** menu descriptions overlapping each other. The option descriptions are now short one-liners, with the "category you're browsing wins" note on its own line.

## v2.9.3
- **The category you're browsing now overrides the AttuneNext options.** If you open AttuneNext from a Quests, Vendor, Currency, Profession, Event or world-drop Zone screen, it recommends an item from *that* category even when *Recommend a whole dungeon/raid* is on (previously it always jumped to a raid) and even when *Factor in drop rates* is on (previously it hid quest/vendor/crafted items, which have no drop rate, and could dead-end with "nothing left"). Drop-rate ranking still applies normally on dungeon/raid/world-drop screens where items actually have drop rates.
- Added a **Reset the ignore list** option in the AttuneNext **Opt** menu (always visible now, shows the count) that clears both ignored items and ignored dungeon/raid runs in one click.

## v2.9.2
- **Fixed the Faction filter for good.** The previous versions tried to read faction from the item tooltip, which doesn't work for raid loot on the live client (the server's "Faction:" line isn't present on a hidden scanning tooltip). The addon now ships the server-authoritative faction list (3,600+ items, the same data behind the in-game "Faction:" tooltip line), so faction-locked raid loot — including all the Trial of the Crusader Alliance/Horde items — is hidden correctly under the opposite faction with no tooltip, cache, or rescan needed.

## v2.9.1
- Fixed the **Faction** filter still showing faction-locked raid loot (e.g. Trial of the Crusader's Alliance items): it now reads the tooltip's "Faction: Alliance/Horde" line, not just race restrictions.
- Added a **Recommend a whole dungeon/raid** option to the AttuneNext button: it points you at the best instance to run and estimates the expected number of new attunes per clear from the drop rates.

## v2.9.0
- Reworked the **Random** button into a smarter **AttuneNext** button (random by default) with an **Opt** menu: *Context sensitive*, *Focus the place with the most left*, and *Factor in drop rates* (which gives the easiest item and excludes vendor/quest/crafted items). The result page has an **Ignore** button to skip a pick (e.g. a rare-spawn or seasonal item) and get the next one.

## v2.8.1
- Fixed the **Faction** filter missing raid/dungeon drops: it now reads an item's Alliance/Horde race restriction from the tooltip when it isn't in the built-in vendor data, so faction-locked raid loot (e.g. Trial of the Crusader's Alliance items) is correctly hidden under the opposite faction. (Needs the item cached, like the Bind filter; Rescan re-checks.)
- Fixed the **Random** button erroring on live realms (`math.randomseed` doesn't exist in the WoW client).

## v2.8.0
- The main menu now starts with **Filter by Expansion** and **Filter by Content Type** — the second lets you pick the content type first (e.g. all Raids) and then the expansion.
- Added a **Difficulty** filter (All / Normal / Heroic / Mythic) and a **Size** filter (All / 10-man / 25-man) for dungeons and raids, available from any dungeon/raid selection screen. Both adjust the counts at every level; raids can combine tier + size (e.g. Heroic 25).
- Added a context-sensitive **Random** button that jumps to a random unattuned item to obtain, picked from whatever you're currently browsing and respecting your active filters.

## v2.7.0
- Added an **Accessories** On/Off toggle. Cloaks, rings, necklaces and trinkets can be attuned by any character account-wide, so turning this off hides them and lets each character focus on its class-specific gear. It's global — the counts update at every level. Reorganized the toolbar into three compact rows to fit and brought the window width back down.

## v2.6.1
- The **Bind** filter is now global — it updates the counts at every level of the menu (not just the final item list), so you can see each dungeon/zone/vendor's BoP or BoE totals from the list.

## v2.6.0
- Added a **Bind** filter (Both / BoP only / BoE only). Bind type comes from built-in data for vendor gear and from the item tooltip for everything else (so an item may not classify until it's been cached).

## v2.5.0
- Added an **Affordable** toggle on every vendor screen: only shows items you can currently pay for with your gold, honor, arena points, and emblems/tokens. Counts update at each level and refresh as your balances change.

## v2.4.0
- Added an **Events & Holidays** category on the main menu, next to the expansions. It lists seasonal events (Hallow's End, Brewfest, Midsummer, Love is in the Air, Lunar Festival) and their attunable gear, pulled live from each event boss's loot table. Events with no attunable gear are hidden.

## v2.3.0
- Added a **settings panel** in the Interface Options AddOns list (also `/an settings`): window scale, minimap-button toggle, debug logging, and Reset-filters / Rescan buttons.
- Added a **minimap button**: left-click to open, right-click for settings, draggable around the minimap. Toggle it with `/an minimap` or in settings.

## v2.2.0
- The **Stock** filter now works on every vendor screen (zone list, currency list, vendor list, and item list), not just a single vendor's items — counts update at each level.

## v2.1.0
- The **Show** (forge) filter is now a proper target: the **Left** count on every screen updates to match it (e.g. with Warforged selected, Left = everything not yet Lightforged), instead of only filtering the item list.
- **Zone-exclusive only** is now a global toggle that updates the counts on every level, so you can see each zone's exclusive-item count from the list without clicking in.
- Added a **Stock** filter on vendor item lists (All / Limited / Unlimited).

## v2.0.0
- Added a **Show** (forge-tier) filter that sets which attunement/forge tiers appear in item lists — Unattuned / Attuned / Titanforged / Warforged / Lightforged, as a "this tier or below" threshold. Forged items are tagged TF / WF / LF. This replaces the old "Show attuned items" checkbox.
- Added a **Zone-exclusive only** toggle on item lists that shows only items obtainable nowhere but the current zone/instance.
- Vendor rows and item pages now show **stock** (unlimited vs. limited "N at a time"), from built-in TrinityCore data plus live vendor scans.
- Reorganized the controls into two toolbar rows and widened the window to fit.

## v1.9.0
- Added a **Rare spawns only** toggle on the World Drops screens that limits the list to gear dropping from rare / rare-elite spawns (505 rare NPCs, from the Questie 3.3.5 data). Zone counts respect it and active zones are tagged `(rares)`.

## v1.8.0
- Added a **Search** box (on every screen) to find any attunable item by name; clicking a result opens its full detail page (sources, drop rates, progress, cost).
- Added a **Distance** option to the Sort button that orders lists by how close things are to your current position (current zone → current continent → elsewhere).

## v1.7.0
- Added **Attunes: Character / Account** toggle. Character scope (default) counts what the current character can attune and marks items done at 100% progress; Account scope counts every attunable item and marks it done if any character attuned any variant.
- Added **Faction: Both / Alliance / Horde** filter that hides faction-locked quests, faction vendors, and faction-restricted gear.
- Reorganized the controls into a single toolbar row (Attunes / Faction / Sort / Currency).
- Rewrote this README for first-time users.

## v1.6.0
- Clicking a **vendor** now sets a waypoint arrow to that vendor's location (Carbonite/TomTom), the same way quests already did. ~1,050 equipment vendors have known locations (green `>`).

## v1.5.0
- The vendor **Currency** filter can now be set **before** choosing a zone: zone rows count only items buyable with the selected currency type, zones with no match are hidden, and the filter carries through as you drill in.

## v1.4.0
- The loot-DB scan is now **saved between sessions** (keyed to the server data version + addon version), so the window opens instantly after the first login. Attunement progress is still read live. Added the **Rescan** button for a manual rebuild.
- Added per-screen **Sort** (Name / Attuned % / Attunes Left; item lists by Drop % / Name / Progress).
- Added the vendor-screen currency-type **filter**.

## v1.3.0
- Built-in **vendor prices** for ~5,400 items / 6,800+ cost variants (gold, honor, arena, emblems, badges, tokens) from TrinityCore 3.3.5 data, so currencies and costs appear without visiting vendors. Live vendor scans take precedence. Cost strings now show every purchase option.

## v1.2.0
- Quest arrows are now **chain-aware**: if you can't pick a quest up yet, the arrow points to the next prerequisite quest you *can* do, using your server-side completed-quest history. Quest rows are tagged `[chain]`, `[in log]`, or `[done]`.

## v1.1.0
- Clicking a **quest** sets a waypoint arrow to its quest giver (Carbonite → TomTom → chat fallback). ~7,300 quests have known giver locations, from the Questie 3.3.5 database.

## v1.0.1
- Fixed dungeon/raid item lists coming up empty (the instance zone-ID the addon sent to the loot database was encoded incorrectly).

## v1.0.0
- First release: browse attunements by Expansion → Content type → Dungeon/Raid (per difficulty), Quest zone, World-drop zone, Vendor (per currency), or Profession. Item lists sorted by drop rate with click-to-see-sources. Counts and drop rates read live from Synastria's attunement and loot APIs.
