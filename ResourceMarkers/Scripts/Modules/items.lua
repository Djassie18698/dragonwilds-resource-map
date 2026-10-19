-- Item names, junk rules and durability, from data/items.lua (extracted from the game's item assets). Pure Lua.
local Items = {}

local catalog = {} -- persistence id -> { name, kind ("Fuel", "Seed" or nil), full durability or nil }

function Items.load(path)
    local ok, data = pcall(dofile, path)
    catalog = ok and type(data) == "table" and type(data.items) == "table" and data.items or {}
    return ok
end

function Items.name(id)
    local e = catalog[id]
    return e and e[1] or "Unknown item"
end

-- Junk: starter tools, raw materials and other things nobody goes back for.
local JUNK_PREFIX = { "Raw ", "Burnt " }
local JUNK_NAMES = {}
for _, name in ipairs({
    "Torch", "Egg", "Stone", "Weeds", "Animal Bone", "Animal Hide", "Animal Hide Scraps", "Coarse Animal Fur",
    "Small Animal Fang", "Poison Ichor", "Rune Essence", "Feather", "Feathers", "Cabbage", "Onion", "Fleece",
    "Clay Vessel", "Bronze Arrow",
    "Stone Pickaxe", "Stone Logging Axe", "Stone Hatchet", "Stone Spear", "Stone Club", "Stone Hammer", "Stone Knife",
    "Bone Pickaxe", "Bone Logging Axe", "Bone Hatchet", "Bone Spear", "Bone Club", "Bone Knife",
}) do JUNK_NAMES[name] = true end

function Items.full(id)
    local e = catalog[id]
    return e and e[3] or nil
end

function Items.isJunk(id)
    local e = catalog[id]
    if not e then return false end
    if e[2] == "Fuel" or e[2] == "Seed" or JUNK_NAMES[e[1]] then return true end
    for _, prefix in ipairs(JUNK_PREFIX) do
        if e[1]:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- "Rune Pickaxe ×1 (98%)" — durability only when the item has a known full durability.
function Items.describe(it)
    local e = catalog[it.id]
    local text = (e and e[1] or "Unknown item") .. " \u{00D7}" .. tostring(it.count or 1)
    local full = e and e[3]
    if full and it.durability and it.durability >= 0 then
        text = text .. string.format(" (%d%%)", math.floor(100 * it.durability / full + 0.5))
    end
    return text
end

return Items
