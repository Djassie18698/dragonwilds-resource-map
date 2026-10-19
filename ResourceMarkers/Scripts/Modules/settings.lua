local Util = require("Modules.util")
local Categories = require("Modules.categories")

-- Persistent settings: key=value lines in settings.txt in the mod folder, plus cat.<id>=1|0 per layer (the 1.x
-- format: a 1.x settings.txt keeps its layer choices; its other keys are ignored).
local KEYS = { -- in file order: { key, kind, default }
    { "enabled", "bool", true },
    { "counts", "bool", true },      -- count labels on group icons
    { "clickable", "bool", true },   -- group icons open their area when clicked
    { "icon_size", "number", 24 },
    { "group_m", "number", 150 },    -- markers within this many metres are one group, at the zoom the map opens with
                                     -- (zooming out or in doubles or halves it, so groups keep their size on screen)
    { "minimap", "bool", true },     -- the minimap in the HUD's top-right corner
    { "minimap_m", "number", 300 },  -- how much of the world it shows across (metres)
    { "minimap_px", "number", 250 }, -- its size on screen
    { "minimap_frames", "number", 5 }, -- it updates once every this many frames (1: every frame)
    { "menu_key", "string", "F7" },
    { "world_save", "string", "" },  -- save slot to read (SaveGames/<name>.sav); empty = ask the game
}

local Settings = { layers = {} }
local kindOf = {}
for _, k in ipairs(KEYS) do
    Settings[k[1]] = k[3]
    kindOf[k[1]] = k[2]
end
for _, category in ipairs(Categories) do
    Settings.layers[category.id] = category.default
end

-- Number settings the menu can step through: { min, max, step }.
Settings.RANGES = { icon_size = { 12, 48, 4 }, group_m = { 50, 600, 50 }, minimap_m = { 100, 800, 50 } }

local PATH = Util.mod_dir() .. "/settings.txt"

local PARSE = {
    bool = function(value) return value == "1" or value == "true" end,
    number = function(value, current) return tonumber(value) or current end,
    string = function(value) return value end,
}
local FORMAT = {
    bool = function(value) return value and "1" or "0" end,
    number = tostring,
    string = tostring,
}

-- Unknown keys (settings that no longer exist, layers that were removed) are ignored.
function Settings.load()
    local file = io.open(PATH, "r")
    if not file then return end
    for line in file:lines() do
        local key, value = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        local id = key and key:match("^cat%.(.+)$")
        if id then
            if Categories.get(id) then Settings.layers[id] = PARSE.bool(value) end
        elseif key and kindOf[key] then
            Settings[key] = PARSE[kindOf[key]](value, Settings[key])
        end
    end
    file:close()
end

function Settings.save()
    local file = io.open(PATH, "w")
    if not file then
        Util.log("Could not save settings to %s", PATH)
        return
    end
    for _, k in ipairs(KEYS) do
        file:write(k[1], "=", FORMAT[k[2]](Settings[k[1]]), "\n")
    end
    for _, category in ipairs(Categories) do
        file:write("cat.", category.id, "=", FORMAT.bool(Settings.layers[category.id]), "\n")
    end
    file:close()
end

function Settings.layer_on(id)
    return Settings.enabled and Settings.layers[id] == true
end

return Settings
