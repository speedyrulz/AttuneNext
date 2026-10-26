# AttuneNext

**A "what should I attune next?" planner for the Synastria WoW server.**

AttuneNext looks at everything your character still needs to attune and lets you browse it the way you actually play: pick an expansion, pick the kind of content (dungeon, raid, quest, world drop, vendor or profession), and drill down to a clean list of the exact items you're missing, sorted by drop rate. Or press the **AttuneNext** button and let it pick for you: a single item, or the dungeon, raid or zone with the most expected new attunes for your time.

📖 **Full documentation: [the AttuneNext Wiki](https://github.com/speedyrulz/AttuneNext/wiki)** · 📝 **[Changelog](CHANGELOG.md)**

---

## Features

- **Browse what's left** by expansion → content type → dungeon/raid (per difficulty and size), quest zone, world-drop zone, vendor (per currency) or profession. Every level shows attuned / total.
- **Global filters** that update the counts at every level: Character/Account scope, faction, forge level, bind type, accessories, zone-exclusive, in bags, stats (any or all of 21), difficulty, raid size, currency, stock, affordable, rare spawns, and a Prestige class filter.
- **Recommendations**: a global AttuneNext button plus context-sensitive cards. Optional drop-rate weighting, focus on the place with the most left, whole-run ranking by expected attunes per clear, and run length derived from your Speed Buff.
- **What's Left** report: remaining attunes, currency needed to buy everything out, and a raw-materials calculator that breaks crafts down the whole chain and subtracts your bags, bank and resource bank.
- **Waypoint arrows** (Carbonite or TomTom) to quest givers (chain- and faction-aware), vendors, rare spawn points, or an item's best source with a right-click.
- **Goals** with estimated clears remaining, **favorites** that save a screen together with its filters, and search across items, vendors, dungeons, raids, professions and quests.
- **In-game helpers**: tooltip lines, loot/roll alerts, a "fully attuned, swap it" alert, zone-entry notes, an in-instance HUD, a goal window, nameplate marking of mobs and vendors with unattuned items, and alt awareness.
- **Fast**: the loot-DB scan is saved between sessions, and all heavy work runs on a background pump.

## Installing

1. Download and unzip the addon.
2. Copy the **`AttuneNext`** folder into `Interface\AddOns\`. The result should be `Interface\AddOns\AttuneNext\AttuneNext.toc`. If the folder is named `AttuneNext-main`, rename it.
3. Start WoW (or `/reload`) and make sure **AttuneNext** is ticked in the AddOns list.
4. In game, type **`/an`**.

It works on the **Synastria client only**: it reads the server's built-in attunement and loot data. Carbonite or TomTom are optional, for arrows. More in [Installation](https://github.com/speedyrulz/AttuneNext/wiki/Installation).

## Quick start

- **`/an`** opens the window, or left-click the minimap emblem. Right-click the emblem for settings.
- **Browse** in the sidebar → *Browse by Expansion* or *Browse by Content Type* → drill down to an item list.
- **Click** an item for details, click again for every source and drop rate, **shift-click** to link it, **right-click** for an arrow to its best source.
- Click the painted **AttuneNext** wordmark for a recommendation. The ⚙ gear opens Options.

New to it? Start with [Getting Started](https://github.com/speedyrulz/AttuneNext/wiki/Getting-Started).

## Common commands

| Command | What it does |
|---|---|
| `/an` | Open / close the window |
| `/an browse` | The simple, resizable browse-only window |
| `/an settings` | Interface Options panel |
| `/an src <itemId>` | Print every source + drop rate for an item (handy for reporting data issues) |
| `/an reset` | Full rescan, including the saved scan |
| `/an help` | List every command |

See [Slash Commands](https://github.com/speedyrulz/AttuneNext/wiki/Slash-Commands) for the full list.

## Help and feedback

- [FAQ and Troubleshooting](https://github.com/speedyrulz/AttuneNext/wiki/FAQ-and-Troubleshooting)
- Found a data problem or a bug? [Open an issue](https://github.com/speedyrulz/AttuneNext/issues) with the item/quest ID and the output of `/an src <itemId>`.

## Credits

Attunement and loot data are read live from Synastria's APIs, as documented by **meh321** and the **SynastriaCoreLib** wiki by **imevul**. Built-in data comes from **Questie** 3.3.5, **TrinityCore** TDB 3.3.5 and **AtlasLoot** 3.3.5. Inspired by TheJournal, synastrialoot and VendorForgeList; nameplate marking is adapted from AttuneMaster. The painted art pack is by **Jeff**. Full details: [Data Sources and Credits](https://github.com/speedyrulz/AttuneNext/wiki/Data-Sources-and-Credits).

Contributors: see [Developer Notes](https://github.com/speedyrulz/AttuneNext/wiki/Developer-Notes) for the file layout and how the generated data files work.
