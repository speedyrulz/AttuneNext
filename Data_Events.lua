-- AttuneNext holiday / world-event data.
-- Attunable gear that's only obtainable during an event comes from the event's
-- boss creature, a loot gameobject it leaves (a chest or egg), or a container.
-- We pull each source's loot live from the server loot DB:
--   npcs  = creature ids   (queried as creature + mythic-creature loot)
--   gos   = gameobject ids (queried as gameobject + mythic-gameobject loot)
-- `items` is a verified backbone list of that event's attunable gear so the
-- items always appear even when the live source can't be enumerated; anything
-- in it that the server doesn't actually flag attunable is filtered back out.
-- (Ids verified against the Questie/pfQuest 3.3.5 DB and AtlasLoot loot tables.)
local _, ANx = ...
ANx = ANx or _G.AttuneNext

ANx.EventList = {
    -- Headless Horseman (loot via the Loot-Filled Pumpkin container)
    { name = "Hallow's End", npcs = { 23682 },
      items = { 49121, 49123, 49124, 49126, 49128, 33292 } },
    -- Coren Direbrew (loot via the Keg-Shaped Treasure Chest container)
    { name = "Brewfest", npcs = { 23872 },
      items = { 49078, 49118, 49116, 49080, 49074, 49076, 49120, 48663 } },
    -- Frost Lord Ahune (gear drops from the Ice Chest: normal + heroic)
    { name = "Midsummer Fire Festival", npcs = { 25740 }, gos = { 187892, 188124 },
      items = { 54801, 54802, 54803, 54804, 54805, 54806 } },
    -- Apothecary Hummel (loot via the Heart-Shaped Box container)
    { name = "Love is in the Air", npcs = { 36296 },
      items = { 51804, 51805, 51806, 51807, 51808, 49715, 50741 } },
    -- Omen + Lunar Festival vendors (festive dresses / pant suits)
    { name = "Lunar Festival", npcs = { 15467 },
      items = { 21157, 21538, 21539, 21541, 21543, 21544 } },
    -- Noblegarden (gear drops from Brightly Colored Egg gameobjects)
    { name = "Noblegarden", gos = { 113768, 113769, 113770, 113771, 113772 },
      items = { 44803, 19028, 44800, 6833, 6835 } },
}
