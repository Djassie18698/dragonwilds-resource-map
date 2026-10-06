-- Resource categories shown on the map.
--
-- `match` patterns are plain substrings tested against the resource's class
-- name (for world objects) or "<spawner class>|<mesh>" (for foliage pickups).
-- The FIRST category that matches wins, so specific names (Toadflax,
-- Sandstone, ...) must come before generic ones (Flax, Stone, ...).
--
-- `icon` is the game's own inventory icon. `color` tints the placeholder icon
-- for resources that have no suitable icon in the game files.

local UI = "/Game/Art/UI/Icons/"
local CONCEPT = UI .. "Resources_ConceptArt/"
local ORES = UI .. "Resources_09_24/"
local UMS = UI .. "Icons_0_12_UmS/Icons/"
local DOWDUN = "/DowdunReach/Art/UI/Icons/"

local function tex(path)
    local name = path:match("([^/]+)$")
    return path .. "." .. name
end

local Categories = {
    -- Ores ---------------------------------------------------------------
    { id = "copper", label = "Copper", section = "Ores", default = true,
      match = { "Copper" }, icon = tex(ORES .. "T_Icon_Copper_Ore_Medium_01") },
    { id = "tin", label = "Tin", section = "Ores", default = true,
      match = { "_Tin" }, icon = tex(ORES .. "T_Icon_Tin_Ore_Medium_01") },
    { id = "iron", label = "Iron", section = "Ores", default = true,
      match = { "Iron" }, icon = tex(ORES .. "T_Icon_Iron_Ore_Medium_01") },
    { id = "coal", label = "Coal", section = "Ores", default = true,
      match = { "Coal" }, icon = tex(CONCEPT .. "T_Icon_Coal") },
    { id = "silver", label = "Silver", section = "Ores", default = true,
      match = { "Silver" }, icon = tex(ORES .. "T_Icon_Silver_Ore_Medium_01") },
    { id = "gold", label = "Gold", section = "Ores", default = true,
      match = { "Gold" }, icon = tex(ORES .. "T_Icon_Gold_Ore_Medium_01") },
    { id = "blurite", label = "Blurite", section = "Ores", default = true,
      match = { "Blurite", "Bluerite" }, icon = tex(CONCEPT .. "T_Icon_Resource_Ore_Blurite") },
    { id = "mithril", label = "Mithril", section = "Ores", default = true,
      match = { "Mithril" }, icon = tex(DOWDUN .. "T_Icon_Mithril_Ore") },
    { id = "adamantite", label = "Adamantite", section = "Ores", default = true,
      match = { "Adamant" }, icon = tex(UMS .. "T_Icon_Adamantite_Ore") },
    { id = "runite", label = "Runite", section = "Ores", default = true,
      match = { "Runite" }, icon = tex("/ScornedWilderness/UI/Icons/Icons/T_Icon_Runite_Ore") },
    { id = "luminite", label = "Luminite", section = "Ores", default = true,
      match = { "Luminite" }, color = { R = 0.4, G = 1.0, B = 1.0, A = 1.0 } },
    { id = "essence", label = "Rune essence", section = "Ores", default = true,
      match = { "RuneEssence" }, icon = tex(CONCEPT .. "T_Icon_Rune_Essence") },
    { id = "dragontooth", label = "Dragon tooth", section = "Ores", default = true,
      match = { "Dragon_Tooth", "DragonTooth" }, icon = tex(CONCEPT .. "T_Icon_Resource_Dragon_Tooth") },
    { id = "avisk", label = "Avisk crystal", section = "Ores", default = true,
      match = { "Avisk" }, color = { R = 0.8, G = 0.4, B = 1.0, A = 1.0 } },
    { id = "soulstone", label = "Soul stone", section = "Ores", default = true,
      match = { "SoulStone" }, icon = tex(CONCEPT .. "T_Icon_Soul_Fragment") },

    -- Rocks & minerals ---------------------------------------------------
    { id = "clay", label = "Clay", section = "Rocks & minerals", default = true,
      match = { "Clay" }, icon = tex(ORES .. "T_Icon_Clay_Ore_Medium_01") },
    { id = "dreamstone", label = "Dreamstone shard", section = "Rocks & minerals", default = true,
      match = { "Dreamstone" }, icon = tex(DOWDUN .. "Inventory/T_Icon_Dreamstone_Shard") },
    { id = "limestone", label = "Limestone", section = "Rocks & minerals", default = false,
      match = { "Limestone" }, icon = tex(DOWDUN .. "Inventory/T_Icon_Limestone") },
    { id = "gypsum", label = "Gypsum", section = "Rocks & minerals", default = false,
      match = { "Gypsum" }, icon = tex(UMS .. "T_Icon_Gypsum_Rock_2") },
    { id = "sandstone", label = "Sandstone", section = "Rocks & minerals", default = false,
      match = { "Sandstone" }, icon = tex(CONCEPT .. "T_Icon_Resource_Sandstone_Rock") },
    { id = "granite", label = "Granite", section = "Rocks & minerals", default = false,
      match = { "Granite" }, icon = tex(CONCEPT .. "T_Icon_Resource_Granite") },
    { id = "stone", label = "Stone", section = "Rocks & minerals", default = false,
      match = { "Stone" }, icon = tex(CONCEPT .. "T_Icon_Resource_Stone") },

    -- Plants & materials -------------------------------------------------
    { id = "toadflax", label = "Toadflax", section = "Plants & materials", default = true,
      match = { "Toadflax" }, icon = tex(CONCEPT .. "T_Icon_Resource_Toadflax") },
    { id = "flax", label = "Flax", section = "Plants & materials", default = true,
      match = { "Flax" }, icon = tex(CONCEPT .. "T_Icon_Resource_Flax") },
    { id = "harralander", label = "Harralander", section = "Plants & materials", default = true,
      match = { "Harralander" }, icon = tex(CONCEPT .. "T_Icon_Resource_Harralander") },
    { id = "marrentil", label = "Marrentil", section = "Plants & materials", default = true,
      match = { "Marrentil" }, icon = tex(CONCEPT .. "T_Icon_Resource_Marrentil") },
    { id = "snapdragon", label = "Snapdragon", section = "Plants & materials", default = true,
      match = { "Snapdragon" }, color = { R = 1.0, G = 0.5, B = 0.7, A = 1.0 } },
    { id = "mushroom", label = "Bittercap mushroom", section = "Plants & materials", default = true,
      match = { "Bittercap", "Mushroom" }, icon = tex(CONCEPT .. "T_Icon_Bittercap_Mushroom") },
    { id = "swampweed", label = "Swamp weed", section = "Plants & materials", default = true,
      match = { "SwampWeed", "Swamp_Weed" }, icon = tex(CONCEPT .. "T_Icon_Resource_Swamp_Weed") },
    { id = "swamptar", label = "Swamp tar", section = "Plants & materials", default = true,
      match = { "Swamp_Tar", "SwampTar" }, icon = tex(ORES .. "T_Icon_Swamp_Tar_01") },
    { id = "bark", label = "Bark", section = "Plants & materials", default = true,
      match = { "Bark" }, icon = tex(CONCEPT .. "T_Icon_Hollow_Bark") },
    { id = "salvage", label = "Salvage metal", section = "Plants & materials", default = true,
      match = { "Salvage" }, icon = tex(DOWDUN .. "Inventory/T_Icon_Salvage_Iron") },
    { id = "desertweed", label = "Desert weed", section = "Plants & materials", default = false,
      match = { "Desert_Weed", "DesertWeed" }, icon = tex(UMS .. "T_Icon_Desert_Weed") },
    { id = "dwellberry", label = "Dwellberries", section = "Plants & materials", default = false,
      match = { "Dwellberry" }, icon = tex(CONCEPT .. "Food_07/T_Icon_Dwellberries") },
    { id = "cadavaberry", label = "Cadavaberries", section = "Plants & materials", default = false,
      match = { "Cadavaberry", "Cadava" }, icon = tex(CONCEPT .. "T_Icon_Cadavaberries") },
    { id = "redberry", label = "Redberries", section = "Plants & materials", default = false,
      match = { "Redberry", "Berry_Bush" }, icon = tex(CONCEPT .. "Food_07/T_Icon_Redberries") },
    { id = "onion", label = "Onion", section = "Plants & materials", default = false,
      match = { "Onion" }, icon = tex(CONCEPT .. "T_Icon_Onion") },
    { id = "cabbage", label = "Cabbage", section = "Plants & materials", default = false,
      match = { "Cabbage" }, icon = tex(CONCEPT .. "T_Icon_Resource_Cabbage") },
    { id = "potato", label = "Potato", section = "Plants & materials", default = false,
      match = { "Potato" }, icon = tex(CONCEPT .. "T_Icon_Resource_Potato") },
    { id = "pumpkin", label = "Pumpkin", section = "Plants & materials", default = false,
      match = { "Pumpkin" }, icon = tex(CONCEPT .. "T_Icon_Pumpkin") },
    { id = "bone", label = "Bones", section = "Plants & materials", default = false,
      match = { "Bone" }, icon = tex(CONCEPT .. "T_Icon_Animal_Bone") },
    { id = "branches", label = "Branches", section = "Plants & materials", default = false,
      match = { "Branch" }, icon = tex(CONCEPT .. "T_Icon_Ash_Logs") },
}

Categories.PLACEHOLDER_ICON = "/MinimapPlugin/Textures/Icons/T_Icon_Placeholder.T_Icon_Placeholder"

local byId = {}
for _, category in ipairs(Categories) do
    byId[category.id] = category
end

function Categories.get(id)
    return byId[id]
end

-- Returns the category for a class/mesh name, or nil if it isn't a resource
-- we mark. Results are cached because class names repeat a lot.
local cache = {}
function Categories.classify(name)
    if name == nil then
        return nil
    end

    local cached = cache[name]
    if cached ~= nil then
        return cached or nil
    end

    for _, category in ipairs(Categories) do
        for _, pattern in ipairs(category.match) do
            if name:find(pattern, 1, true) then
                cache[name] = category
                return category
            end
        end
    end

    cache[name] = false
    return nil
end

return Categories
