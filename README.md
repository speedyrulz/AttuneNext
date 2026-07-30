# AttuneNext

**A "what should I attune next?" planner for the Synastria WoW server.**

AttuneNext looks at everything your character still needs to attune and lets you browse it the same way you actually play — pick an expansion, pick the kind of content (dungeon, raid, quest, world drop, vendor, or profession), and drill down to a clean list of the exact items you're missing, sorted by drop rate. Click a dungeon to see what drops there; click a quest or a vendor and it drops a waypoint arrow on your map to the quest giver or the vendor.

If you've never used it before, just install it and type `/an`. Everything below is optional detail.

---

## Installing

1. Download and unzip the addon.
2. Copy the **`AttuneNext`** folder into your WoW folder under `Interface\AddOns\`.
   The result should look like `Interface\AddOns\AttuneNext\AttuneNext.toc`.
3. Start WoW (or type `/reload` if you're already logged in) and make sure **AttuneNext** is ticked on the character-select AddOns list.
4. In game, type **`/an`** to open it.

It works on the Synastria client only — it reads the server's built-in attunement and loot data. Nothing to configure.

---

There's also a **minimap button** (the book icon): **left-click** to open the planner, **right-click** for settings, and drag it around the minimap edge to reposition. A **settings panel** lives under Esc → Interface → AddOns → AttuneNext (or type `/an settings`) with window scale, a minimap-button toggle, debug logging, and Reset-filters / Rescan buttons.

## The basics

Type **`/an`** to open or close the window. The first screen asks how you want to browse:

- **Filter by Expansion** — pick Classic / TBC / WotLK first, then a content type. (The classic flow.)
- **Filter by Content Type** — pick the content type first (Dungeons, Raids, Quests, …), then the expansion. Handy when you just want, say, "all the raids I still need."
- **Events & Holidays** — seasonal event gear (see below).

Either way you end up at the same item lists. There's also an **AttuneNext** button (top of the window) that jumps you to a recommended item to go attune — random by default, with options for context, "most left," and drop-rate weighting (see below).

Under **Filter by Expansion** you'll see three expansions plus events:

- **Classic**
- **The Burning Crusade**
- **Wrath of the Lich King**
- **Events & Holidays** — attunable gear that's only obtainable during seasonal events (Hallow's End, Brewfest, the Midsummer Fire Festival, Love is in the Air, Lunar Festival). Click it to pick an event, then browse its items just like anywhere else. The gear is pulled live from the event boss's loot table, so it stays accurate.

Each expansion row shows how many items you've attuned, how many are left, and the percentage. Click one to choose a **content type**:

| Content type | What it lists |
|---|---|
| **Dungeons** | Every dungeon. TBC/WotLK dungeons split into Normal / Heroic / Mythic, each counted separately. |
| **Raids** | Every raid. WotLK raids split into 10/25 (and 10N/25N/10H/25H where the raid has them). |
| **Quests** | Zones that have quests giving gear you still need. |
| **Zone World Drops** | Open-world zones where gear drops off mobs/chests. A **Rare spawns only** toggle here limits the list to gear that drops from rare / rare-elite spawns. |

Item lists across all of these also respond to the **Show** (forge tier) and **Zone-exclusive only** buttons described under "The toolbar" below.
| **Vendors** | Zones and cities with vendors, grouped by the currency they charge. |
| **Crafting** | Professions with gear you can craft. |

Keep clicking to drill down. Dungeon, raid, and world-drop screens also show you the **single best item to chase** — the highest-drop-rate thing you're still missing — right on the row.

The final screen is always a list of the actual items left, **sorted by drop rate** (most likely first). On an item:

- **Click** it to see everything that drops it and the drop rate for each source.
- **Shift-click** it to link it in chat.
- **Hover** for the normal item tooltip.

### The AttuneNext button

The **AttuneNext** button (top of the window) jumps you to a recommended item to attune next and opens its detail page (where it drops, drop rates, cost, etc.). By default it's **completely random** across everything you still need. The small **Opt** button next to it opens its options:

- **Context sensitive** — when on, it only picks from the screen you launched it from (Classic → Crafting gives a Classic craft; drill into Leatherworking first and it's leatherworking-only; Filter by Content Type → Quests with no expansion picked gives a quest reward from any expansion). Off by default.
- **Focus the place with the most left** — aims at the single zone / instance / profession / currency that has the most items remaining, so you get the biggest haul in one trip. Respects your filters and the Context-sensitive setting.
- **Factor in drop rates** — gives you the *easiest* (highest drop-rate) item, and the Ignore button then steps you to the next best. It prefers drop items over vendor / quest / crafted ones (which have no drop rate) — but see the category note below.
- **Recommend a whole dungeon/raid** — instead of one item, it points you at the best *instance* to run and tells you the **expected number of new attunes per clear** (it adds up the drop chances of everything you still need there). Respects your filters and the Difficulty/Size settings, and Ignore steps to the next-best run.

**The category you're browsing wins.** If you open AttuneNext from a Quests, Vendor, Currency, Profession, Event or world-drop Zone screen, it recommends an item from *that* category — even if *Recommend a whole dungeon/raid* or *Factor in drop rates* is on. (Those options only apply where they make sense: on dungeon/raid/world-drop screens, or when you launch from a broad screen.) So browsing quests always gives you quests, and Ignore keeps stepping through them instead of dead-ending.

All of these respect your active filters (faction, forge target, difficulty, bind, accessories, etc.). Whatever item it gives you, the detail page has an **Ignore this item** button — handy if the "best" pick is a rare spawn or seasonal boss you'd rather skip; it drops that item from future picks. Use **Reset the ignore list** in the Opt menu to clear every skipped item and run at once.

### Searching

There's a **Search** box under the toolbar, available on every screen, with a **Filters On/Off** button that decides whether results respect your active filters (turn it Off to find things your faction/bind/difficulty filters would hide), and a **Find** button that switches what you're searching: **Attunables** (default — items by name), **Vendors** (by vendor name), **Dungeons**, **Raids**, **Professions**, or **Quests**. Searching a name jumps you straight to the right screen — a dungeon result opens that dungeon's item list (one result per difficulty), a vendor result drops the waypoint arrow and opens their stock, a quest result sets the arrow and opens its rewards — no clicking through menus. Item results open the detail page with every source and drop rate. Clear the box to go back to where you were.

### The v3 look

The window uses a dark panel dressed in the **painted AttuneNext art pack** (art by Jeff): an ornate painted border and corners, the AttuneNext **emblem and wordmark** in the left sidebar, painted buttons, and **painted thumbnails for all 74 dungeons and raids** plus custom icons for every expansion, content type, profession, event and navigation entry. The **top bar** carries the painted **AttuneNext wordmark** on the left, the **search field at the very top** (painted, with a magnifier and a "Search" hint) with its **Find:** type selector and **Filters:** toggle right beside it, and the **AttuneNext** button plus **gear** (AttuneNext options) and **refresh** (rescan) icon buttons at the top right. Below it, every filter is a **uniform painted chip** — one shared size per screen, in balanced rows that always fill the frame edge-to-edge — showing its **current value first** ("Character", "Horde", "Unattuned", "Both binds"...) in **its own color with a matching pack icon**, with a hover tooltip explaining what each chip cycles. The **left sidebar** — Home, Browse, What's Left, Favorites, Goals — jumps between sections from anywhere: the emblem sits alone up top, entries are roomy rows with large icons and left-aligned labels, and only the active section wears the teal-outlined chip, a **breadcrumb path** shows where you are, and every row carries a **teal progress bar** (gold when complete) under its text. Item and material icons come from the game client itself. The minimap button wears the emblem too.

### Favorites & getting around

- A **Home** button (top left) returns to the main menu from any screen.
- The **Fav +** button (top left) saves the current screen **together with your active filters** as a favorite; on a screen that's already saved with those filters it reads **Fav -** and removes it. The main menu's **Favorites** entry lists everything saved — each shows its filter set, **click** jumps straight to that page with those filters re-applied, **shift-click** removes it.

### What's Left? (totals-only report)

The main menu's **What's Left?** entry opens a deliberately simple report — every number on it is a *remaining* total, never "attuned" counts or percentages:

- **Attunes left** for **this character** and for the **account**, side by side. Click either to break the number down by expansion and content type (again, remaining counts only); click any row there to jump into the normal browser with its full filters.
- **Crafted items left** (character / account). Click it for the **raw materials** still needed to craft everything remaining — each with a character column and an account column, sorted by biggest need. Click a profession to see just its materials, and click any material to see **which remaining items need it**. The numbers are true *raw* materials: craftable parts are broken down the whole chain (a Mithril Casing becomes bars, bars become ore), and everything the current character already has — **bags, bank and resource bank** — is subtracted at every level. So if you need 2 casings and hold 1 casing and 1 bar, the list just says *2 Mithril Ore*.
- **Currency needed to buy out everything left** — each currency with the character/account totals and how much you currently have. Click a currency for the list of remaining items it buys.

Reagent lists for all eleven professions are built in (from the 3.3.5a client craft data), so the materials calculator works out of the box. Synastria-custom recipes aren't in that data — AttuneNext records those whenever you open a profession's crafting window (on any character, shared account-wide), and the materials screen says how many remaining recipes are still missing data.

The report respects your Faction / Bind / Accessories / Zone-exclusive filters. It counts base attunes (the forge target doesn't change it).

### Waypoint arrows

- On a **quest** screen, clicking a quest points an arrow at its quest giver. If you can't pick the quest up yet, the arrow points at the **next quest in the chain** you *can* do, and chat tells you what unlocks what. Quests that **start from a dropped item** arrow to the creature or chest that drops the starter instead.
- Under **Attunes: Character**, quests your character's race/class can never complete are hidden from quest lists (switch to Account scope to see them all).
- On any **item's detail page** (including whatever AttuneNext recommends), a quest listed under **Sources** is clickable too — same arrow, same chain redirect, with a **[chain]** / **[in log]** / **[done]** tag showing its state.
- On a **vendor** screen, clicking a vendor points an arrow at that vendor.
- On an item's detail page, a **[rare]**-tagged source is clickable: the arrow points at the rare's spawn point, and clicking again **cycles through its other camps**.

Arrows use **Carbonite** if you have it, otherwise **TomTom**. With neither installed, AttuneNext just prints the location and coordinates in chat. Rows that have a known location show a small green `>`.

---

## The toolbar (buttons under the title)

- **Attunes: Character / Account** — switch between *what this character can attune* (the default) and *your whole account*. Character scope respects your class, armor type, and level; account scope counts an item as done if **any** of your characters has attuned any version of it.
- **Faction: Both / Alliance / Horde** — hide content locked to the other faction (faction-locked quests, vendors and gear, including raid/dungeon drops read from the item tooltip). Affects faction-only quests, faction vendors, and faction-restricted gear (heirlooms, tabards, PvP sets, etc.). Neutral content always shows.
- **Sort** — cycles the current list: Default → Name → Attuned % → Attunes Left → **Distance** (on item lists: Drop % → Name → Progress → Distance). *Distance* puts things in or near your current zone first (same zone, then same continent, then the rest), so it surfaces what you can go do right now. Your choice is remembered per screen.
- **Show** (forge target) — sets a forge target and everything follows it. Pick a tier and an item counts as "left" until it's pushed **past** that tier; the **Left** number on every screen updates to match. *Unattuned* (default) = only truly unattuned items are left; *Warforged* = everything that isn't Lightforged yet is left; *Lightforged* = everything is left (nothing is beyond it). Item lists show exactly those "left" items, with forged ones tagged TF / WF / LF. (This replaces the old "Show attuned items" checkbox.)
- **Bind** — a global filter (Both / BoP only / BoE only) that updates the counts at every level, so you can see, e.g., how many Bind-on-Equip pieces each dungeon still has without drilling in. Bind type is read from the item (built-in for vendor gear, from the tooltip otherwise); an item that isn't cached yet may not classify until you've seen it once, and Rescan re-checks after items cache.
- **Difficulty** — on dungeon/raid screens (available before you pick a specific instance). Cycles All / Normal / Heroic / Mythic and adjusts the counts at every level — so you can see, e.g., only your Heroic totals. On a dungeon this collapses each entry to the matching difficulty.
- **Size** — on raid screens, alongside Difficulty. Cycles All / 10-man / 25-man to filter out the size you don't want. Combine them (Heroic + 25) to see only 25-man Heroic. Dungeons and single-difficulty raids ignore it.
- **Accessories** — a global On/Off toggle. Cloaks, rings, necklaces and trinkets aren't restricted by armor type, so *any* of your characters can attune them account-wide. Turn Accessories **Off** to hide those and focus each character on the class-specific gear (armor of its type and its weapons) — the counts at every level drop accordingly. (Built-in for vendor gear, from the item's equip slot otherwise; uncached items are assumed non-accessory and re-checked on Rescan.)
- **Zone-exclusive only** — a global toggle. When On, every level only counts and shows items that drop **nowhere but a single zone** — so you can see, right from the dungeon/zone list, how many exclusive items each place still has without clicking in. Great for prioritising a lockout.
- **Currency** — on vendor screens only. Filter to a currency type (Gold / Honor & Arena / Emblems & Marks / Other Tokens). You can set this **before** picking a zone, so you can, say, see only the zones that sell things for Emblems of Triumph.
- **Rare spawns only** — on World Drops screens only. When On, only shows gear that can drop from a rare or rare-elite spawn, and the zone list counts/hides accordingly. Handy if you're hunting rares specifically. Zones are tagged `(rares)` while it's active.
- **Stock** — on every vendor screen (the zone list, currency list, vendor list, and item list). Filters to All / Limited / Unlimited so you can find the limited-stock items (the ones that sell a few at a time and restock on a timer) or ignore them — counts update at each level. On a specific vendor it uses that vendor's exact stock; on the broader lists it flags an item as limited if any vendor sells it that way.
- **Affordable** — on every vendor screen. When On, only shows items you can pay for **right now** with your current gold, honor, arena points, and emblems/tokens (an item counts if you can afford it any one of the ways it's sold). Counts update at each level, and it refreshes automatically as your balances change.

The **Show attuned items** checkbox (bottom right, on item lists) also lists things you've already finished, if you want to review them.

---

## Vendors, currencies, and prices

Prices for about 5,400 vendor items are **built in**, so currencies and costs show up immediately — you don't have to physically find each vendor first. An item you can buy several ways is listed under each currency, and costs show every option (e.g. *"50 Emblem of Triumph or 340g"*).

AttuneNext also quietly records prices from any vendor you actually open, and those live prices win over the built-in data — that keeps Synastria's custom vendors and any price changes accurate.

Vendor item rows and item detail pages also show **stock**: most vendors sell in unlimited supply, but some sell a limited number (e.g. "1 at a time") that restock on a timer — those are highlighted so you know to come back. Stock comes from the built-in data and is updated from any vendor you open.

---

## Speed and refreshing

The first time you run it, AttuneNext scans the server's loot database in the background (a "Scanning…" note, a second or two). **That scan is saved between sessions**, so from your next login onward the window opens instantly. Your attunement progress is always read live, so the numbers are never stale.

Press **Rescan** (top right) to throw the saved scan away and rebuild it — handy after a big server content patch. A new server data version also triggers a rebuild automatically.

---

## Commands

| Command | What it does |
|---|---|
| `/an` or `/attunenext` | Open / close the window |
| `/an settings` | Open the settings panel |
| `/an minimap` | Show / hide the minimap button |
| `/an src <itemId>` | Print every source + drop rate for an item (handy for reporting data issues) |
| `/an scale <0.5–2.0>` | Resize the window |
| `/an reset` | Full rescan — clears every cache including the saved scan |
| `/an debug` | Toggle verbose logging |

---

## FAQ / troubleshooting

**Lists are empty and it says the loot DB isn't loaded.** AttuneNext needs Synastria's loot database, which loads with the client. If it was deleted or failed to load, item lists can't be built. Try `/reload`; if it persists, the server data files may need reinstalling.

**A dungeon or raid shows no items.** Difficulty data varies. Run `/an src <itemId>` on a drop you know comes from there and check what zone/difficulty it reports — that tells us what to adjust.

**A quest arrow stops early in a chain.** The quest chain data (from Questie) occasionally misses a cross-zone link. Give the quest name/ID and it can be patched.

**A quest or vendor has no arrow.** Some quests start from a dropped item (no fixed giver), and a small number of vendors are event-only; those have no location to point at, and chat will say so.

**Numbers differ between characters.** That's expected in Character scope — a lower-level or different-class character can attune fewer items. Switch to **Account** scope to see the account-wide picture.

---

## Changelog
**v3.1.1**
- Fixed a crash opening the simple browse window before the main window had ever been opened (the engine reference is now bound lazily).

**v3.1.0**
- Added an **Unskinned layout** toggle (Options, the Interface panel, or `/an unskinned`): plain dark frames and standard Blizzard buttons instead of the painted art pack, for players who prefer the older look. The AttuneNext logo and sidebar emblem stay painted either way, and the switch applies instantly - no reload needed.
- New **simple browse window** (`/an browse`, `/anbrowse`, or `/run AttuneNextBrowse()` in a macro): a plain standard-WoW window with just the wordmark, the browse menus and their filters - no sidebar, goals, favorites or recommendation button. It shares the main window'''s data and filter settings, so lists match exactly, and it'''s **resizable** - drag the bottom-right corner; a taller window simply shows more rows.

**v3.0.0**

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

**v2.11.1**
- **Profession screens now show crafted items only.** Some items sit in the profession data because a quest *requires* the profession (e.g. the Light's Hope Chapel "Polar Tunic/Gloves/Bracers" turn-ins need Leatherworking 300) — those were wrongly listed on the crafting screens with a skill level. They now appear only under Quests, where they're actually obtained.
- **Items nobody can attune are excluded everywhere.** If the server flags an item as not attunable at all (the tooltip's "Can't be Attuned" note), it no longer counts or shows in any list, even if the per-character check disagrees.
- The item detail page now shows a red note when an item **can't be attuned by anyone** or is **not attunable by this character** (wrong class/armor/faction), so an ineligible recommendation is visible at a glance.

**v2.11.0**
- **Fixed missing event gear and added Noblegarden.** Some holiday gear drops from a loot *object* rather than the boss itself — e.g. Frost Lord Ahune's cloaks come from his **Ice Chest**, and Noblegarden's **Spring Circlet** comes from **Brightly Colored Eggs** — and those weren't being picked up. AttuneNext now reads gameobject loot too (including the heroic Ice Chest), added **Noblegarden** as an event, and ships a verified backbone list of each event's attunable gear so nothing slips through. Every event was reviewed: Hallow's End (Headless Horseman), Brewfest (Coren Direbrew), Midsummer (Ahune), Love is in the Air (Apothecary Hummel), Lunar Festival, and Noblegarden.

**v2.10.0**
- **Quest sources are now clickable on the item detail page.** When AttuneNext (or any item you open) is obtained from a quest, click the quest's row under **Sources** to drop a waypoint arrow straight to the quest giver — and if you can't pick the quest up yet, the arrow points to the next quest in the chain instead (the row is tagged **[chain]**, **[in log]** or **[done]** so you know its state). Same behaviour as the quest lists, now available right where AttuneNext sends you.

**v2.9.4**
- Fixed the AttuneNext **Opt** menu descriptions overlapping each other. The option descriptions are now short one-liners, with the "category you're browsing wins" note on its own line.

**v2.9.3**
- **The category you're browsing now overrides the AttuneNext options.** If you open AttuneNext from a Quests, Vendor, Currency, Profession, Event or world-drop Zone screen, it recommends an item from *that* category even when *Recommend a whole dungeon/raid* is on (previously it always jumped to a raid) and even when *Factor in drop rates* is on (previously it hid quest/vendor/crafted items, which have no drop rate, and could dead-end with "nothing left"). Drop-rate ranking still applies normally on dungeon/raid/world-drop screens where items actually have drop rates.
- Added a **Reset the ignore list** option in the AttuneNext **Opt** menu (always visible now, shows the count) that clears both ignored items and ignored dungeon/raid runs in one click.

**v2.9.2**
- **Fixed the Faction filter for good.** The previous versions tried to read faction from the item tooltip, which doesn't work for raid loot on the live client (the server's "Faction:" line isn't present on a hidden scanning tooltip). The addon now ships the server-authoritative faction list (3,600+ items, the same data behind the in-game "Faction:" tooltip line), so faction-locked raid loot — including all the Trial of the Crusader Alliance/Horde items — is hidden correctly under the opposite faction with no tooltip, cache, or rescan needed.

**v2.9.1**
- Fixed the **Faction** filter still showing faction-locked raid loot (e.g. Trial of the Crusader's Alliance items): it now reads the tooltip's "Faction: Alliance/Horde" line, not just race restrictions.
- Added a **Recommend a whole dungeon/raid** option to the AttuneNext button: it points you at the best instance to run and estimates the expected number of new attunes per clear from the drop rates.

**v2.9.0**
- Reworked the **Random** button into a smarter **AttuneNext** button (random by default) with an **Opt** menu: *Context sensitive*, *Focus the place with the most left*, and *Factor in drop rates* (which gives the easiest item and excludes vendor/quest/crafted items). The result page has an **Ignore** button to skip a pick (e.g. a rare-spawn or seasonal item) and get the next one.

**v2.8.1**
- Fixed the **Faction** filter missing raid/dungeon drops: it now reads an item's Alliance/Horde race restriction from the tooltip when it isn't in the built-in vendor data, so faction-locked raid loot (e.g. Trial of the Crusader's Alliance items) is correctly hidden under the opposite faction. (Needs the item cached, like the Bind filter; Rescan re-checks.)
- Fixed the **Random** button erroring on live realms (`math.randomseed` doesn't exist in the WoW client).

**v2.8.0**
- The main menu now starts with **Filter by Expansion** and **Filter by Content Type** — the second lets you pick the content type first (e.g. all Raids) and then the expansion.
- Added a **Difficulty** filter (All / Normal / Heroic / Mythic) and a **Size** filter (All / 10-man / 25-man) for dungeons and raids, available from any dungeon/raid selection screen. Both adjust the counts at every level; raids can combine tier + size (e.g. Heroic 25).
- Added a context-sensitive **Random** button that jumps to a random unattuned item to obtain, picked from whatever you're currently browsing and respecting your active filters.

**v2.7.0**
- Added an **Accessories** On/Off toggle. Cloaks, rings, necklaces and trinkets can be attuned by any character account-wide, so turning this off hides them and lets each character focus on its class-specific gear. It's global — the counts update at every level. Reorganized the toolbar into three compact rows to fit and brought the window width back down.

**v2.6.1**
- The **Bind** filter is now global — it updates the counts at every level of the menu (not just the final item list), so you can see each dungeon/zone/vendor's BoP or BoE totals from the list.

**v2.6.0**
- Added a **Bind** filter (Both / BoP only / BoE only). Bind type comes from built-in data for vendor gear and from the item tooltip for everything else (so an item may not classify until it's been cached).

**v2.5.0**
- Added an **Affordable** toggle on every vendor screen: only shows items you can currently pay for with your gold, honor, arena points, and emblems/tokens. Counts update at each level and refresh as your balances change.

**v2.4.0**
- Added an **Events & Holidays** category on the main menu, next to the expansions. It lists seasonal events (Hallow's End, Brewfest, Midsummer, Love is in the Air, Lunar Festival) and their attunable gear, pulled live from each event boss's loot table. Events with no attunable gear are hidden.

**v2.3.0**
- Added a **settings panel** in the Interface Options AddOns list (also `/an settings`): window scale, minimap-button toggle, debug logging, and Reset-filters / Rescan buttons.
- Added a **minimap button**: left-click to open, right-click for settings, draggable around the minimap. Toggle it with `/an minimap` or in settings.

**v2.2.0**
- The **Stock** filter now works on every vendor screen (zone list, currency list, vendor list, and item list), not just a single vendor's items — counts update at each level.

**v2.1.0**
- The **Show** (forge) filter is now a proper target: the **Left** count on every screen updates to match it (e.g. with Warforged selected, Left = everything not yet Lightforged), instead of only filtering the item list.
- **Zone-exclusive only** is now a global toggle that updates the counts on every level, so you can see each zone's exclusive-item count from the list without clicking in.
- Added a **Stock** filter on vendor item lists (All / Limited / Unlimited).

**v2.0.0**
- Added a **Show** (forge-tier) filter that sets which attunement/forge tiers appear in item lists — Unattuned / Attuned / Titanforged / Warforged / Lightforged, as a "this tier or below" threshold. Forged items are tagged TF / WF / LF. This replaces the old "Show attuned items" checkbox.
- Added a **Zone-exclusive only** toggle on item lists that shows only items obtainable nowhere but the current zone/instance.
- Vendor rows and item pages now show **stock** (unlimited vs. limited "N at a time"), from built-in TrinityCore data plus live vendor scans.
- Reorganized the controls into two toolbar rows and widened the window to fit.

**v1.9.0**
- Added a **Rare spawns only** toggle on the World Drops screens that limits the list to gear dropping from rare / rare-elite spawns (505 rare NPCs, from the Questie 3.3.5 data). Zone counts respect it and active zones are tagged `(rares)`.

**v1.8.0**
- Added a **Search** box (on every screen) to find any attunable item by name; clicking a result opens its full detail page (sources, drop rates, progress, cost).
- Added a **Distance** option to the Sort button that orders lists by how close things are to your current position (current zone → current continent → elsewhere).

**v1.7.0**
- Added **Attunes: Character / Account** toggle. Character scope (default) counts what the current character can attune and marks items done at 100% progress; Account scope counts every attunable item and marks it done if any character attuned any variant.
- Added **Faction: Both / Alliance / Horde** filter that hides faction-locked quests, faction vendors, and faction-restricted gear.
- Reorganized the controls into a single toolbar row (Attunes / Faction / Sort / Currency).
- Rewrote this README for first-time users.

**v1.6.0**
- Clicking a **vendor** now sets a waypoint arrow to that vendor's location (Carbonite/TomTom), the same way quests already did. ~1,050 equipment vendors have known locations (green `>`).

**v1.5.0**
- The vendor **Currency** filter can now be set **before** choosing a zone: zone rows count only items buyable with the selected currency type, zones with no match are hidden, and the filter carries through as you drill in.

**v1.4.0**
- The loot-DB scan is now **saved between sessions** (keyed to the server data version + addon version), so the window opens instantly after the first login. Attunement progress is still read live. Added the **Rescan** button for a manual rebuild.
- Added per-screen **Sort** (Name / Attuned % / Attunes Left; item lists by Drop % / Name / Progress).
- Added the vendor-screen currency-type **filter**.

**v1.3.0**
- Built-in **vendor prices** for ~5,400 items / 6,800+ cost variants (gold, honor, arena, emblems, badges, tokens) from TrinityCore 3.3.5 data, so currencies and costs appear without visiting vendors. Live vendor scans take precedence. Cost strings now show every purchase option.

**v1.2.0**
- Quest arrows are now **chain-aware**: if you can't pick a quest up yet, the arrow points to the next prerequisite quest you *can* do, using your server-side completed-quest history. Quest rows are tagged `[chain]`, `[in log]`, or `[done]`.

**v1.1.0**
- Clicking a **quest** sets a waypoint arrow to its quest giver (Carbonite → TomTom → chat fallback). ~7,300 quests have known giver locations, from the Questie 3.3.5 database.

**v1.0.1**
- Fixed dungeon/raid item lists coming up empty (the instance zone-ID the addon sent to the loot database was encoded incorrectly).

**v1.0.0**
- First release: browse attunements by Expansion → Content type → Dungeon/Raid (per difficulty), Quest zone, World-drop zone, Vendor (per currency), or Profession. Item lists sorted by drop rate with click-to-see-sources. Counts and drop rates read live from Synastria's attunement and loot APIs.

---

## Where the data comes from

- **Attunement status, drop rates, item sources, per-difficulty loot** — read live from Synastria's own APIs (`ItemLoc*`, `GetItemAttuneProgress`, `CanAttuneItemHelper`, `HasAttunedAnyVariantOfItem`, `GetItemTagsCustom`), as documented by **meh321** in the Synastria Discord and the **SynastriaCoreLib** wiki by imevul.
- **Quest givers, quest chains, faction, vendor & NPC locations, event bosses** — extracted from / verified against the **Questie** 3.3.5 database (widxwer/Questie). Event gear itself is read live from the loot DB by boss id.
- **Vendor prices** — from **TrinityCore** TDB 3.3.5 world data (the workbook you provided).
- **Profession recipe lists** — from **AtlasLoot** 3.3.5.
- Structure and API usage inspired by TheJournal, synastrialoot, and VendorForgeList.

Instance and zone lists live in plain `Data_*.lua` files if you ever want to tweak them.
