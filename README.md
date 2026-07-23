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

## The basics

Type **`/an`** to open or close the window. You'll see three expansions:

- **Classic**
- **The Burning Crusade**
- **Wrath of the Lich King**

Each row shows how many items you've attuned, how many are left, and the percentage. Click one to choose a **content type**:

| Content type | What it lists |
|---|---|
| **Dungeons** | Every dungeon. TBC/WotLK dungeons split into Normal / Heroic / Mythic, each counted separately. |
| **Raids** | Every raid. WotLK raids split into 10/25 (and 10N/25N/10H/25H where the raid has them). |
| **Quests** | Zones that have quests giving gear you still need. |
| **Zone World Drops** | Open-world zones where gear drops off mobs/chests. A **Rare spawns only** toggle here limits the list to gear that drops from rare / rare-elite spawns. |
| **Vendors** | Zones and cities with vendors, grouped by the currency they charge. |
| **Crafting** | Professions with gear you can craft. |

Keep clicking to drill down. Dungeon, raid, and world-drop screens also show you the **single best item to chase** — the highest-drop-rate thing you're still missing — right on the row.

The final screen is always a list of the actual items left, **sorted by drop rate** (most likely first). On an item:

- **Click** it to see everything that drops it and the drop rate for each source.
- **Shift-click** it to link it in chat.
- **Hover** for the normal item tooltip.

### Searching for a specific item

There's a **Search** box under the toolbar, available on every screen. Type part of an item's name and AttuneNext lists every attunable item that matches, with its best source right on the row. Click a result to jump straight to its detail page — where it drops (every source and drop rate), its attune progress, and its vendor cost if it has one. Clear the box to go back to where you were.

### Waypoint arrows

- On a **quest** screen, clicking a quest points an arrow at its quest giver. If you can't pick the quest up yet, the arrow points at the **next quest in the chain** you *can* do, and chat tells you what unlocks what.
- On a **vendor** screen, clicking a vendor points an arrow at that vendor.

Arrows use **Carbonite** if you have it, otherwise **TomTom**. With neither installed, AttuneNext just prints the location and coordinates in chat. Rows that have a known location show a small green `>`.

---

## The toolbar (buttons under the title)

- **Attunes: Character / Account** — switch between *what this character can attune* (the default) and *your whole account*. Character scope respects your class, armor type, and level; account scope counts an item as done if **any** of your characters has attuned any version of it.
- **Faction: Both / Alliance / Horde** — hide content locked to the other faction. Affects faction-only quests, faction vendors, and faction-restricted gear (heirlooms, tabards, PvP sets, etc.). Neutral content always shows.
- **Sort** — cycles the current list: Default → Name → Attuned % → Attunes Left → **Distance** (on item lists: Drop % → Name → Progress → Distance). *Distance* puts things in or near your current zone first (same zone, then same continent, then the rest), so it surfaces what you can go do right now. Your choice is remembered per screen.
- **Currency** — on vendor screens only. Filter to a currency type (Gold / Honor & Arena / Emblems & Marks / Other Tokens). You can set this **before** picking a zone, so you can, say, see only the zones that sell things for Emblems of Triumph.
- **Rare spawns only** — on World Drops screens only. When On, only shows gear that can drop from a rare or rare-elite spawn, and the zone list counts/hides accordingly. Handy if you're hunting rares specifically. Zones are tagged `(rares)` while it's active.

The **Show attuned items** checkbox (bottom right, on item lists) also lists things you've already finished, if you want to review them.

---

## Vendors, currencies, and prices

Prices for about 5,400 vendor items are **built in**, so currencies and costs show up immediately — you don't have to physically find each vendor first. An item you can buy several ways is listed under each currency, and costs show every option (e.g. *"50 Emblem of Triumph or 340g"*).

AttuneNext also quietly records prices from any vendor you actually open, and those live prices win over the built-in data — that keeps Synastria's custom vendors and any price changes accurate.

---

## Speed and refreshing

The first time you run it, AttuneNext scans the server's loot database in the background (a "Scanning…" note, a second or two). **That scan is saved between sessions**, so from your next login onward the window opens instantly. Your attunement progress is always read live, so the numbers are never stale.

Press **Rescan** (top right) to throw the saved scan away and rebuild it — handy after a big server content patch. A new server data version also triggers a rebuild automatically.

---

## Commands

| Command | What it does |
|---|---|
| `/an` or `/attunenext` | Open / close the window |
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
- **Quest givers, quest chains, faction, vendor & NPC locations** — extracted from the **Questie** 3.3.5 database (widxwer/Questie).
- **Vendor prices** — from **TrinityCore** TDB 3.3.5 world data (the workbook you provided).
- **Profession recipe lists** — from **AtlasLoot** 3.3.5.
- Structure and API usage inspired by TheJournal, synastrialoot, and VendorForgeList.

Instance and zone lists live in plain `Data_*.lua` files if you ever want to tweak them.
