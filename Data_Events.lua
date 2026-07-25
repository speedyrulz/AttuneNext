-- AttuneNext holiday / world-event data.
-- Attunable gear that's only obtainable during an event mostly comes from that
-- event's boss; we pull each boss's loot live from the server loot DB by NPC id.
-- (Boss NPC ids verified against the Questie 3.3.5 database.)
-- `items` is an optional list of extra fixed item ids for events without a boss.
local _, ANx = ...
ANx = ANx or _G.AttuneNext

ANx.EventList = {
    { name = "Hallow's End",             npcs = { 23682 } },  -- Headless Horseman
    { name = "Brewfest",                 npcs = { 23872 } },  -- Coren Direbrew
    { name = "Midsummer Fire Festival",  npcs = { 25740 } },  -- Ahune
    { name = "Love is in the Air",       npcs = { 36296 } },  -- Apothecary Hummel
    { name = "Lunar Festival",           npcs = { 15467 } },  -- Omen
}
