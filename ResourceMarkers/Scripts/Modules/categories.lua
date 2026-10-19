-- Map layers. Pure Lua (no UE4SS calls) so tools/extract/layers.lua can use the same rules.
--
-- Classification, first match wins (list order is priority order):
--   within: the class or one of its parents must be one of these (nil = any class)
--   match:  plain substrings tested against the class name (nil = any)
--   extra:  exact match on the actor's extra data (anima vents: their AnimaVentData name)
--   foliage: plain substrings tested against the mesh of the game's interactable foliage (data/foliage.lua: plants and
--            trees the game scatters per map tile); not used to classify classes
-- Categories without any of these are filled from saves and live actors, not from world data.
--
-- label: the layer's name in the menu; name: one thing on the map (defaults to label).
-- icon: the game's own texture. variants: { match, icon, label } overrides icon and name per class.

local UI = "/Game/Art/UI/Icons/"
local CONCEPT = UI .. "Resources_ConceptArt/"
local ORES = UI .. "Resources_09_24/"
local UMS = UI .. "Icons_0_12_UmS/Icons/"
local DOWDUN = "/DowdunReach/Art/UI/Icons/"
local SCORNED = "/ScornedWilderness/UI/Icons/"
local MAP = "/Game/Art/UI/Map/"
local NAV = "/Game/Art/UI/NavIcons/"

local function tex(path)
    return path .. "." .. path:match("([^/]+)$")
end

local MINED = { "OreNode", "DestructibleMiningRock", "DivineRock" }
local PICKED = { "BaseInteractableResource" }
local TREES = { "FellableTree" }
local SAPLINGS = { "SaplingBase" }

local function vent(rune, default)
    return { id = "vent_" .. rune:lower(), name = rune .. " vent", label = rune .. " vents", section = "Runecrafting", default = default,
             within = { "AnimaVent" }, extra = "AVD_" .. rune, icon = tex(CONCEPT .. "T_Icon_Rune_" .. rune) }
end

local Categories = {
    -- My stuff (from saves and live actors) -------------------------------
    { id = "items", name = "Dropped items", label = "Dropped items", section = "My stuff", default = true, icon = tex(ORES .. "T_Icon_Loot_Chest_01") },
    { id = "junk", name = "Dropped junk", label = "Dropped junk", section = "My stuff", default = false, icon = tex(CONCEPT .. "T_Icon_Resource_Stone") },
    { id = "graves", name = "Grave", label = "Graves", section = "My stuff", default = true, icon = tex(NAV .. "T_NavIcons_Gravestone") },
    { id = "storage", name = "Storage", label = "Storage", section = "My stuff", default = true, icon = tex(UI .. "Furniture_Storage/T_Icon_Storage_Chest_01v2") },

    -- Runecrafting ----------------------------------------------------------
    vent("Air", false), vent("Water", false), vent("Earth", false), vent("Fire", false),
    vent("Nature", false), vent("Law", false), vent("Astral", false),
    { id = "geyser", name = "Essence geyser", label = "Essence geysers", section = "Runecrafting", default = false,
      within = { "RuneEssenceGeyser" }, icon = tex(SCORNED .. "Journal/T_Icon_Journal_Rune_Geyser") },
    { id = "essence", name = "Essence rock", label = "Essence rocks", section = "Runecrafting", default = false,
      within = MINED, match = { "RuneEssence" }, icon = tex(CONCEPT .. "T_Icon_Rune_Essence") },

    -- Ores --------------------------------------------------------------------
    { id = "copper", name = "Copper rock", label = "Copper", section = "Ores", default = false, within = MINED, match = { "Copper" },
      icon = tex(ORES .. "T_Icon_Copper_Ore_Medium_01") },
    { id = "tin", name = "Tin rock", label = "Tin", section = "Ores", default = false, within = MINED, match = { "_Tin" },
      icon = tex(ORES .. "T_Icon_Tin_Ore_Medium_01") },
    { id = "iron", name = "Iron rock", label = "Iron", section = "Ores", default = false, within = MINED, match = { "Iron" },
      icon = tex(ORES .. "T_Icon_Iron_Ore_Medium_01") },
    { id = "coal", name = "Coal rock", label = "Coal", section = "Ores", default = false, within = MINED, match = { "Coal" },
      icon = tex(CONCEPT .. "T_Icon_Coal") },
    { id = "silver", name = "Silver rock", label = "Silver", section = "Ores", default = false, within = MINED, match = { "Silver" },
      icon = tex(ORES .. "T_Icon_Silver_Ore_Medium_01") },
    { id = "gold", name = "Gold rock", label = "Gold", section = "Ores", default = false, within = MINED, match = { "Gold" },
      icon = tex(ORES .. "T_Icon_Gold_Ore_Medium_01") },
    { id = "blurite", name = "Blurite rock", label = "Blurite", section = "Ores", default = false, within = MINED, match = { "Blurite", "Bluerite" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Ore_Blurite") },
    { id = "mithril", name = "Mithril rock", label = "Mithril", section = "Ores", default = false, within = MINED, match = { "Mithril" },
      icon = tex(DOWDUN .. "T_Icon_Mithril_Ore") },
    { id = "adamantite", name = "Adamantite rock", label = "Adamantite", section = "Ores", default = false, within = MINED, match = { "Adamant" },
      icon = tex(UMS .. "T_Icon_Adamantite_Ore") },
    { id = "runite", name = "Runite rock", label = "Runite", section = "Ores", default = false, within = MINED, match = { "Runite" },
      icon = tex(SCORNED .. "Icons/T_Icon_Runite_Ore") },
    { id = "luminite", name = "Luminite rock", label = "Luminite", section = "Ores", default = false, within = MINED, match = { "Luminite" },
      icon = tex(SCORNED .. "Icons/T_Icon_Luminute_Ore") },
    { id = "dragontooth", name = "Dragon tooth rock", label = "Dragon tooth", section = "Ores", default = false, within = MINED, match = { "Dragon_Tooth", "DragonTooth", "MiningRock_Dragon" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Dragon_Tooth") },
    { id = "avisk", name = "Avisk crystal", label = "Avisk crystal", section = "Ores", default = false, within = MINED, match = { "Avisk" },
      icon = tex(NAV .. "T_Map_Icon_Ore"), color = { R = 0.8, G = 0.4, B = 1.0, A = 1.0 } },
    { id = "soulstone", name = "Soul stone", label = "Soul stone", section = "Ores", default = false, within = MINED, match = { "SoulStone" },
      icon = tex(CONCEPT .. "T_Icon_Soul_Fragment") },

    -- Rocks & minerals --------------------------------------------------------
    { id = "clay", name = "Clay rock", label = "Clay", section = "Rocks & minerals", default = false, within = MINED, match = { "Clay" },
      icon = tex(ORES .. "T_Icon_Clay_Ore_Medium_01") },
    { id = "dreamstone", name = "Dreamstone", label = "Dreamstone shard", section = "Rocks & minerals", default = false, within = MINED, match = { "Dreamstone" },
      icon = tex(DOWDUN .. "Inventory/T_Icon_Dreamstone_Shard") },
    { id = "limestone", name = "Limestone rock", label = "Limestone", section = "Rocks & minerals", default = false, within = MINED, match = { "Limestone" },
      icon = tex(DOWDUN .. "Inventory/T_Icon_Limestone") },
    { id = "gypsum", name = "Gypsum rock", label = "Gypsum", section = "Rocks & minerals", default = false, within = MINED, match = { "Gypsum" },
      icon = tex(UMS .. "T_Icon_Gypsum_Rock_2") },
    { id = "sandstone", name = "Sandstone rock", label = "Sandstone", section = "Rocks & minerals", default = false, within = MINED, match = { "Sandstone" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Sandstone_Rock") },
    { id = "granite", name = "Granite rock", label = "Granite", section = "Rocks & minerals", default = false, within = MINED, match = { "Granite" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Granite") },
    -- Stone rocks you mine; loose stones on the ground (like branches) are everywhere and left out.
    { id = "stone", name = "Stone rock", label = "Stone", section = "Rocks & minerals", default = false, within = { "OreNode", "DestructibleMiningRock" },
      match = { "Stone" }, icon = tex(CONCEPT .. "T_Icon_Resource_Stone") },

    -- Plants & materials ------------------------------------------------------
    { id = "toadflax", label = "Toadflax", section = "Plants & materials", default = false, within = PICKED, match = { "Toadflax" }, foliage = { "SM_Toadflax" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Toadflax") },
    { id = "flax", label = "Flax", section = "Plants & materials", default = false, within = PICKED, match = { "Flax" }, foliage = { "SM_Flax_" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Flax") },
    { id = "harralander", label = "Harralander", section = "Plants & materials", default = false, within = PICKED, match = { "Harralander" }, foliage = { "SM_Harralander" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Harralander") },
    { id = "marrentil", label = "Marrentil", section = "Plants & materials", default = false, within = PICKED, match = { "Marrentil" }, foliage = { "SM_Marrentil" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Marrentil") },
    { id = "snapdragon", label = "Snapdragon", section = "Plants & materials", default = false, within = PICKED, match = { "Snapdragon" }, foliage = { "SM_Snapdragon" },
      icon = tex(CONCEPT .. "T_Icons_Journal_Recipes_Resources_SnapDragon") },
    { id = "mushroom", name = "Bittercap mushroom", label = "Bittercap mushroom", section = "Plants & materials", default = false, within = PICKED, match = { "Bittercap", "Mushroom" }, foliage = { "SM_Bittercap_Mushrooms" },
      icon = tex(CONCEPT .. "T_Icon_Bittercap_Mushroom") },
    { id = "swampweed", label = "Swamp weed", section = "Plants & materials", default = false, within = PICKED, match = { "SwampWeed", "Swamp_Weed" }, foliage = { "SM_Swamp_Weed" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Swamp_Weed") },
    { id = "swamptar", label = "Swamp tar", section = "Plants & materials", default = false, within = PICKED, match = { "Swamp_Tar", "SwampTar" }, foliage = { "SM_Swamp_Tar" },
      icon = tex(ORES .. "T_Icon_Swamp_Tar_01") },
    { id = "bark", label = "Bark", section = "Plants & materials", default = false, within = PICKED, match = { "Bark" },
      icon = tex(CONCEPT .. "T_Icon_Hollow_Bark") },
    { id = "salvage", label = "Salvage", section = "Plants & materials", default = false, within = PICKED, match = { "Salvage" },
      icon = tex(DOWDUN .. "Inventory/T_Icon_Salvage_Iron") },
    { id = "desertweed", label = "Desert weed", section = "Plants & materials", default = false, within = PICKED, match = { "Desert_Weed", "DesertWeed" }, foliage = { "SM_Desert_Weed" },
      icon = tex(UMS .. "T_Icon_Desert_Weed") },
    { id = "dwellberry", name = "Dwellberry bush", label = "Dwellberries", section = "Plants & materials", default = false, within = PICKED, match = { "Dwellberry" }, foliage = { "SM_Dwellberry_Bush" },
      icon = tex(CONCEPT .. "Food_07/T_Icon_Dwellberries") },
    { id = "cadavaberry", name = "Cadavaberry bush", label = "Cadavaberries", section = "Plants & materials", default = false, within = PICKED, match = { "Cadavaberry", "Cadava" }, foliage = { "SM_Cadavaberry_Bush" },
      icon = tex(CONCEPT .. "T_Icon_Cadavaberries") },
    { id = "redberry", name = "Redberry bush", label = "Redberries", section = "Plants & materials", default = false, within = PICKED, match = { "Redberry", "Berry_Bush" }, foliage = { "SM_Berry_Bush" },
      icon = tex(CONCEPT .. "Food_07/T_Icon_Redberries") },
    { id = "onion", label = "Onion", section = "Plants & materials", default = false, within = PICKED, match = { "Onion" }, foliage = { "SM_Onion_Plant" },
      icon = tex(CONCEPT .. "T_Icon_Onion") },
    { id = "cabbage", label = "Cabbage", section = "Plants & materials", default = false, within = PICKED, match = { "Cabbage" }, foliage = { "SM_Cabbage" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Cabbage") },
    { id = "potato", label = "Potato", section = "Plants & materials", default = false, within = PICKED, match = { "Potato" }, foliage = { "SM_Potato_Plant" },
      icon = tex(CONCEPT .. "T_Icon_Resource_Potato") },
    { id = "pumpkin", label = "Pumpkin", section = "Plants & materials", default = false, within = PICKED, match = { "Pumpkin" }, foliage = { "SM_Pumpkin" },
      icon = tex(CONCEPT .. "T_Icon_Pumpkin") },
    { id = "bone", name = "Bones", label = "Bones", section = "Plants & materials", default = false, within = PICKED, match = { "Bone" },
      icon = tex(CONCEPT .. "T_Icon_Animal_Bone") },

    -- Trees: the game's interactable foliage (by mesh) and the trees, saplings and cacti placed as actors -------
    { id = "ash", name = "Ash tree", label = "Ash trees", section = "Trees", default = false, within = TREES, match = { "Ash" },
      foliage = { "Ash_Tree" }, icon = tex(CONCEPT .. "T_Icon_Ash_Logs") },
    { id = "oak", name = "Oak tree", label = "Oak trees", section = "Trees", default = false, within = TREES, match = { "Oak" },
      foliage = { "Oak_Tree" }, icon = tex(CONCEPT .. "T_Icon_Oak_Logs") },
    { id = "maple", name = "Maple tree", label = "Maple trees", section = "Trees", default = false, within = TREES, match = { "Maple" },
      foliage = { "MapleTree" }, icon = tex(DOWDUN .. "Inventory/T_Icon_Resources_Maple_Logs") },
    { id = "willow", name = "Willow tree", label = "Willow trees", section = "Trees", default = false, within = TREES, match = { "Willow" },
      foliage = { "SM_Willow_" }, icon = tex(CONCEPT .. "T_Icon_Willow_Logs") },
    { id = "yew", name = "Yew tree", label = "Yew trees", section = "Trees", default = false, within = TREES, match = { "Yew" },
      foliage = { "SM_Yew_" }, icon = tex(UMS .. "T_Icon_YewTreeLogs") },
    { id = "cactus", name = "Cactus", label = "Cacti", section = "Trees", default = false, within = SAPLINGS, match = { "Cactus" },
      foliage = { "SM_Cactus_" }, icon = tex(UMS .. "T_Icon_Fibrous_Cactus") },
    { id = "sapling", name = "Sapling", label = "Saplings", section = "Trees", default = false, within = SAPLINGS, match = { "Sapling" },
      foliage = { "Sapling" }, icon = tex(SCORNED .. "Journal/T_Icon_SM_Ash_Sapling_01") },

    -- World -------------------------------------------------------------------
    { id = "lore", name = "Lore", label = "Lore", section = "World", default = false, within = { "BP_LoreItem_C" },
      icon = tex(UI .. "Journal/T_Icon_Journal_Lore_Scraps") },
    { id = "chests", name = "Chest", label = "Chests", section = "World", default = false, within = { "WorldChest" },
      icon = tex(ORES .. "T_Icon_Loot_Chest_01"),
      variants = {
          { match = "Buried", icon = tex(UI .. "BuildingIcons/T_Icon_Chest"), label = "Buried chest" },
          { match = "Tier[5-8]", icon = tex(SCORNED .. "Icons/T_Icon_Dragon_chest"), label = "Treasure chest" },
      } },
    { id = "fishing", name = "Fishing spot", label = "Fishing spots", section = "World", default = false, within = { "FishingNodeV2" },
      icon = tex("/Game/Art/UI/Dragonwilds_RoadMap/T_Icon_Fishing") },
    { id = "entrances", name = "Entrance", label = "Entrances & portals", section = "World", default = false,
      match = { "PlayerTeleporter", "VautEntrance", "DungeonTeleport", "ExitFromDungeonDoor", "HomeTeleport" },
      icon = tex(NAV .. "T_NavIcons_DungeonEntrance") },
    { id = "shrines", name = "Shrine", label = "Shrines & altars", section = "World", default = false, within = { "HealthShrine", "BP_BaseBossAltar_C" },
      icon = tex(MAP .. "T_HealthAltar_Map_Discovered"),
      variants = { { match = "BossAltar", icon = tex(NAV .. "T_NavIcons_BossAlter"), label = "Boss altar" } } },
    { id = "agility", name = "Agility course", label = "Agility & burrows", section = "World", default = false, within = { "AgilityCourseStarter", "KebbitBurrow" },
      icon = tex(MAP .. "T_Agility_NewCourse"),
      variants = { { match = "KebbitBurrow", icon = tex("/Agility/Art/UI/Icons/KebbitBurrows/T_NavIcons_Kebbit_Tunnel"), label = "Kebbit burrow" } } },
    { id = "npcs", name = "NPC", label = "NPCs & quest objects", section = "World", default = false, within = { "InteractableNPC" },
      icon = tex(MAP .. "T_Map_Primary_Quest_Icon_NPC") },
}

Categories.PLACEHOLDER_ICON = "/MinimapPlugin/Textures/Icons/T_Icon_Placeholder.T_Icon_Placeholder"

local byId = {}
for _, category in ipairs(Categories) do
    byId[category.id] = category
    if category.within then
        local set = {}
        for _, name in ipairs(category.within) do set[name] = true end
        category.withinSet = set
    end
    category.byClass = category.within ~= nil or category.match ~= nil or category.extra ~= nil
    category.static = category.byClass or category.foliage ~= nil
end

function Categories.get(id)
    return byId[id]
end

local function matches(category, className, chain, extra)
    if category.extra and category.extra ~= extra then return false end
    if category.withinSet then
        local found = false
        for _, name in ipairs(chain) do
            if category.withinSet[name] then found = true break end
        end
        if not found then return false end
    end
    if category.match then
        for _, pattern in ipairs(category.match) do
            if className:find(pattern, 1, true) then return true end
        end
        return false
    end
    return true
end

-- chain: the class name and its parents' names, nearest first.
-- extra: optional extra data (anima vent type). Returns the category or nil.
function Categories.classify(className, chain, extra)
    for _, category in ipairs(Categories) do
        if category.byClass and matches(category, className, chain, extra) then
            return category
        end
    end
    return nil
end

-- The category of one of the game's interactable foliage meshes (data/foliage.lua), or nil.
function Categories.for_mesh(mesh)
    for _, category in ipairs(Categories) do
        for _, pattern in ipairs(category.foliage or {}) do
            if mesh:find(pattern, 1, true) then return category end
        end
    end
    return nil
end

-- Icon and name of one thing of this class (variants are Lua patterns).
function Categories.look(category, className)
    for _, variant in ipairs(category.variants or {}) do
        if className:find(variant.match) then
            return variant.icon, variant.label
        end
    end
    return category.icon, category.name or category.label
end

return Categories
