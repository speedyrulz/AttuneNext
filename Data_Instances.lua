-- AttuneNext static instance data
-- exp: 1=Classic 2=TBC 3=WotLK   kind: "D"=Dungeon "R"=Raid
-- diffs: list of { label, itemlocDifficultyId }
--   ItemLoc difficulty ids: 0=all 1=normal 2=heroic 3=10man 4=25man
--                           5=10normal 6=25normal 7=10heroic 8=25heroic 9=mythic
-- altDiffs: fallback difficulty set tried automatically if the primary set returns no items
local _, ANx = ...
ANx = ANx or _G.AttuneNext

local D_CLASSIC = { { "", 0 } }
local D_NHM     = { { "N", 1 }, { "H", 2 }, { "M", 9 } }
local R_SINGLE  = { { "", 0 } }
local R_10_25   = { { "10", 3 }, { "25", 4 } }
local R_10_25b  = { { "10", 5 }, { "25", 6 } }
local R_FOUR    = { { "10N", 5 }, { "25N", 6 }, { "10H", 7 }, { "25H", 8 } }
local R_FOURb   = { { "10", 3 }, { "25", 4 } }

ANx.Instances = {
    -- ============================ CLASSIC DUNGEONS ============================
    { name = "Ragefire Chasm",          map = 389, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "The Deadmines",           map = 36,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Wailing Caverns",         map = 43,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Shadowfang Keep",         map = 33,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Blackfathom Deeps",       map = 48,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "The Stockade",            map = 34,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Gnomeregan",              map = 90,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Razorfen Kraul",          map = 47,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Scarlet Monastery",       map = 189, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Razorfen Downs",          map = 129, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Uldaman",                 map = 70,  exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Zul'Farrak",              map = 209, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Maraudon",                map = 349, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Sunken Temple",           map = 109, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Blackrock Depths",        map = 230, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Blackrock Spire",         map = 229, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Dire Maul",               map = 429, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Scholomance",             map = 289, exp = 1, kind = "D", diffs = D_CLASSIC },
    { name = "Stratholme",              map = 329, exp = 1, kind = "D", diffs = D_CLASSIC },

    -- ============================ CLASSIC RAIDS ============================
    { name = "Molten Core",             map = 409, exp = 1, kind = "R", diffs = R_SINGLE },
    { name = "Blackwing Lair",          map = 469, exp = 1, kind = "R", diffs = R_SINGLE },
    { name = "Zul'Gurub",               map = 309, exp = 1, kind = "R", diffs = R_SINGLE },
    { name = "Ruins of Ahn'Qiraj",      map = 509, exp = 1, kind = "R", diffs = R_SINGLE },
    { name = "Temple of Ahn'Qiraj",     map = 531, exp = 1, kind = "R", diffs = R_SINGLE },

    -- ============================ TBC DUNGEONS ============================
    { name = "Hellfire Ramparts",       map = 543, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Blood Furnace",       map = 542, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Shattered Halls",     map = 540, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Slave Pens",          map = 547, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Underbog",            map = 546, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Steamvault",          map = 545, exp = 2, kind = "D", diffs = D_NHM },
    { name = "Mana-Tombs",              map = 557, exp = 2, kind = "D", diffs = D_NHM },
    { name = "Auchenai Crypts",         map = 558, exp = 2, kind = "D", diffs = D_NHM },
    { name = "Sethekk Halls",           map = 556, exp = 2, kind = "D", diffs = D_NHM },
    { name = "Shadow Labyrinth",        map = 555, exp = 2, kind = "D", diffs = D_NHM },
    { name = "Old Hillsbrad Foothills", map = 560, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Black Morass",        map = 269, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Mechanar",            map = 554, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Botanica",            map = 553, exp = 2, kind = "D", diffs = D_NHM },
    { name = "The Arcatraz",            map = 552, exp = 2, kind = "D", diffs = D_NHM },
    { name = "Magisters' Terrace",      map = 585, exp = 2, kind = "D", diffs = D_NHM },

    -- ============================ TBC RAIDS ============================
    { name = "Karazhan",                map = 532, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "Gruul's Lair",            map = 565, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "Magtheridon's Lair",      map = 544, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "Serpentshrine Cavern",    map = 548, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "The Eye",                 map = 550, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "Battle for Mount Hyjal",  map = 534, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "Black Temple",            map = 564, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "Zul'Aman",                map = 568, exp = 2, kind = "R", diffs = R_SINGLE },
    { name = "Sunwell Plateau",         map = 580, exp = 2, kind = "R", diffs = R_SINGLE },

    -- ============================ WOTLK DUNGEONS ============================
    { name = "Utgarde Keep",            map = 574, exp = 3, kind = "D", diffs = D_NHM },
    { name = "The Nexus",               map = 576, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Azjol-Nerub",             map = 601, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Ahn'kahet: The Old Kingdom", map = 619, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Drak'Tharon Keep",        map = 600, exp = 3, kind = "D", diffs = D_NHM },
    { name = "The Violet Hold",         map = 608, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Gundrak",                 map = 604, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Halls of Stone",          map = 599, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Halls of Lightning",      map = 602, exp = 3, kind = "D", diffs = D_NHM },
    { name = "The Oculus",              map = 578, exp = 3, kind = "D", diffs = D_NHM },
    { name = "The Culling of Stratholme", map = 595, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Utgarde Pinnacle",        map = 575, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Trial of the Champion",   map = 650, exp = 3, kind = "D", diffs = D_NHM },
    { name = "The Forge of Souls",      map = 632, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Pit of Saron",            map = 658, exp = 3, kind = "D", diffs = D_NHM },
    { name = "Halls of Reflection",     map = 668, exp = 3, kind = "D", diffs = D_NHM },

    -- ============================ WOTLK RAIDS ============================
    { name = "Naxxramas",               map = 533, exp = 3, kind = "R", diffs = R_10_25, altDiffs = R_10_25b },
    { name = "The Obsidian Sanctum",    map = 615, exp = 3, kind = "R", diffs = R_10_25, altDiffs = R_10_25b },
    { name = "The Eye of Eternity",     map = 616, exp = 3, kind = "R", diffs = R_10_25, altDiffs = R_10_25b },
    { name = "Vault of Archavon",       map = 624, exp = 3, kind = "R", diffs = R_10_25, altDiffs = R_10_25b },
    { name = "Ulduar",                  map = 603, exp = 3, kind = "R", diffs = R_10_25, altDiffs = R_10_25b },
    { name = "Trial of the Crusader",   map = 649, exp = 3, kind = "R", diffs = R_FOUR, altDiffs = R_FOURb },
    { name = "Onyxia's Lair",           map = 249, exp = 3, kind = "R", diffs = R_10_25, altDiffs = R_10_25b },
    { name = "Icecrown Citadel",        map = 631, exp = 3, kind = "R", diffs = R_FOUR, altDiffs = R_FOURb },
    { name = "The Ruby Sanctum",        map = 724, exp = 3, kind = "R", diffs = R_FOUR, altDiffs = R_FOURb },
}
