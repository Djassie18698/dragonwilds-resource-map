local Util = require("Modules.util")
local Categories = require("Modules.categories")

-- Persistent settings, stored as key=value lines in settings.txt next to the
-- mod's Scripts folder.
local Settings = {
    enabled = true,
    hide_depleted = true,
    range_m = 250,
    icon_size = 24,
    menu_key = "F7",
    categories = {},
}

Settings.RANGE_MIN = 50
Settings.RANGE_MAX = 1000
Settings.RANGE_STEP = 50
Settings.SIZE_MIN = 12
Settings.SIZE_MAX = 48
Settings.SIZE_STEP = 4

local PATH = Util.mod_dir() .. "/settings.txt"

for _, category in ipairs(Categories) do
    Settings.categories[category.id] = category.default
end

local function to_bool(value)
    return value == "1" or value == "true"
end

function Settings.load()
    local file = io.open(PATH, "r")
    if file == nil then
        return
    end

    for line in file:lines() do
        local key, value = line:match("^%s*([%w_%.]+)%s*=%s*(%S+)")
        if key ~= nil then
            local categoryId = key:match("^cat%.(.+)$")
            if categoryId ~= nil then
                if Categories.get(categoryId) ~= nil then
                    Settings.categories[categoryId] = to_bool(value)
                end
            elseif key == "enabled" or key == "hide_depleted" then
                Settings[key] = to_bool(value)
            elseif key == "menu_key" then
                Settings.menu_key = value
            elseif key == "range_m" or key == "icon_size" then
                Settings[key] = tonumber(value) or Settings[key]
            end
        end
    end

    file:close()
end

function Settings.save()
    local file = io.open(PATH, "w")
    if file == nil then
        Util.log("Could not save settings to " .. PATH)
        return
    end

    file:write("enabled=" .. (Settings.enabled and "1" or "0") .. "\n")
    file:write("hide_depleted=" .. (Settings.hide_depleted and "1" or "0") .. "\n")
    file:write("range_m=" .. tostring(Settings.range_m) .. "\n")
    file:write("icon_size=" .. tostring(Settings.icon_size) .. "\n")
    file:write("menu_key=" .. tostring(Settings.menu_key) .. "\n")
    for _, category in ipairs(Categories) do
        file:write("cat." .. category.id .. "=" .. (Settings.categories[category.id] and "1" or "0") .. "\n")
    end

    file:close()
end

function Settings.is_category_on(id)
    return Settings.categories[id] == true
end

return Settings
