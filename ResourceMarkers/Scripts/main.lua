-- ResourceMarkers: shows ores, rocks and gatherable plants/materials on the
-- game's map and on the MiniMap mod. Press F7 (configurable) to open the settings
-- menu, or change settings in game with Mod Menu (Esc > MODS).

local Util = require("Modules.util")
local Settings = require("Modules.settings")
local Markers = require("Modules.markers")
local Menu = require("Modules.menu")
local Categories = require("Modules.categories")
local MM = require("Modules.modmenu")

local SCAN_INTERVAL_MS = 1500

Settings.load()

local function run_scan()
    local ok, err = pcall(Markers.scan)
    if not ok then
        Util.log("Scan failed: " .. tostring(err))
    end
end

-- Called on the game thread from the menu, so rescan right away.
Menu.on_change = function(kind)
    if kind == "size" then
        Markers.apply_icon_size()
    else
        run_scan()
    end
end

-- Mod Menu: apply settings changed in Esc > MODS right away.
local modMenu = MM.new("ResourceMarkers")
local LIVE_KEYS = { "enabled", "hide_depleted", "range_m", "icon_size" }
for _, category in ipairs(Categories) do
    table.insert(LIVE_KEYS, "cat." .. category.id)
end

local function to_bool(value)
    return value == true or value == 1 or value == "1" or value == "true"
end

local function apply_mod_menu()
    local sizeChanged, otherChanged = false, false
    modMenu:poll(LIVE_KEYS, function(key, value)
        local categoryId = key:match("^cat%.(.+)$")
        if categoryId then
            Settings.categories[categoryId] = to_bool(value)
            otherChanged = true
        elseif key == "icon_size" or key == "range_m" then
            Settings[key] = tonumber(value) or Settings[key]
            sizeChanged = sizeChanged or key == "icon_size"
            otherChanged = otherChanged or key ~= "icon_size"
        else
            Settings[key] = to_bool(value)
            otherChanged = true
        end
    end)
    if sizeChanged then
        Markers.apply_icon_size()
    end
    if sizeChanged or otherChanged then
        Menu.refresh()
    end
    return otherChanged
end

MM.every(SCAN_INTERVAL_MS, function()
    apply_mod_menu()
    run_scan()
end)

local function on_game_thread(callback)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(callback)
            if not ok then
                Util.log("Menu error: " .. tostring(err))
            end
        end)
    end
end

local menuKey = MM.key(Settings.menu_key) or Key.F7
Menu.key_name = tostring(Settings.menu_key or "F7"):upper():gsub("_", " ")
RegisterKeyBind(menuKey, on_game_thread(Menu.toggle))
RegisterKeyBind(Key.UP_ARROW, on_game_thread(Menu.up))
RegisterKeyBind(Key.DOWN_ARROW, on_game_thread(Menu.down))
RegisterKeyBind(Key.LEFT_ARROW, on_game_thread(Menu.left))
RegisterKeyBind(Key.RIGHT_ARROW, on_game_thread(Menu.right))
RegisterKeyBind(Key.RETURN, on_game_thread(Menu.enter))

-- Mouse clicks on the menu.
local clickHandler = on_game_thread(Menu.click)
RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
    if Menu.is_open() then
        clickHandler()
    end
end)

Util.log("Loaded. Press " .. Menu.key_name .. " for the menu.")
