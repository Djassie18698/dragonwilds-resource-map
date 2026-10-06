local Util = require("Modules.util")
local Categories = require("Modules.categories")
local Settings = require("Modules.settings")

-- Creates a MapIconComponent (the game's own minimap/world-map icon type) for
-- every enabled resource near the player, and removes icons that are out of
-- range, disabled, or depleted.
local Markers = {}

local MAX_ICONS = 900
local MAX_CREATES_PER_SCAN = 150
local FOLIAGE_REFRESH_SECONDS = 20
local ICON_Z_ORDER = 5
local FOG_ALWAYS_ABOVE = 3
local BACKGROUND_ALWAYS = 0
local SIZE_SCREEN_SPACE = 0

-- Native classes that cover every resource type (FindAllOf includes subclasses).
local ACTOR_SOURCES = {
    "OreNode",                -- metal ore nodes, rune essence geysers
    "DestructibleMiningRock", -- stone, granite, sandstone, dragon tooth, rune essence rocks
    "DivineRock",             -- divine ore rocks
    "GatherableResource",     -- pickups that exist as actors (flax, mushrooms, bones, ...)
}

local IDENTITY = {
    Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
    Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
    Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
}

local mapIconClass = nil
local textures = {}
local markers = {}          -- key -> { comp, categoryId }
local markerCount = 0
local foliageCache = {}     -- component address -> { count, time, category, positions }
local scanId = 0

local function get_map_icon_class()
    if not Util.valid(mapIconClass) then
        mapIconClass = StaticFindObject("/Script/MinimapPlugin.MapIconComponent")
    end
    return mapIconClass
end

local function load_texture(path)
    local texture = Util.safe(function() return StaticFindObject(path) end, nil)
    if not Util.valid(texture) then
        texture = Util.safe(function() return LoadAsset(path) end, nil)
    end
    if Util.valid(texture) then
        return texture
    end
    return nil
end

local function get_texture(category)
    local cached = textures[category.id]
    if cached ~= nil and Util.valid(cached) then
        return cached
    end

    local texture = nil
    if category.icon ~= nil then
        texture = load_texture(category.icon)
        if texture == nil then
            Util.log("Icon not found for " .. category.label .. ": " .. category.icon)
        end
    end
    if texture == nil then
        texture = load_texture(Categories.PLACEHOLDER_ICON)
    end

    textures[category.id] = texture
    return texture
end

local function destroy_marker(key)
    local marker = markers[key]
    if marker == nil then
        return
    end

    if Util.valid(marker.comp) then
        pcall(function()
            marker.comp:K2_DestroyComponent(marker.comp)
        end)
    end

    markers[key] = nil
    markerCount = markerCount - 1
end

local function create_marker(key, owner, location, category)
    local class = get_map_icon_class()
    if class == nil or not Util.valid(owner) then
        return false
    end

    local texture = get_texture(category)
    if texture == nil then
        return false
    end

    local comp = Util.safe(function()
        return owner:AddComponentByClass(class, false, IDENTITY, true)
    end, nil)
    if not Util.valid(comp) then
        return false
    end

    local configured = pcall(function()
        comp.IconTexture = texture
        comp.IconSize = Settings.icon_size
        comp.IconSizeUnit = SIZE_SCREEN_SPACE
        comp.bIconRotates = false
        comp.IconZOrder = ICON_Z_ORDER
        comp.IconFogInteraction = FOG_ALWAYS_ABOVE
        comp.IconBackgroundInteraction = BACKGROUND_ALWAYS
        comp.IconDrawColor = category.color or { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    end)

    pcall(function()
        owner:FinishAddComponent(comp, false, IDENTITY)
    end)

    pcall(function()
        comp:K2_SetWorldLocation(location, false, {}, false)
    end)

    pcall(function()
        comp:SetIconTooltipText(FText(category.label))
    end)

    if not configured then
        pcall(function() comp:K2_DestroyComponent(comp) end)
        return false
    end

    markers[key] = { comp = comp, categoryId = category.id, seen = scanId }
    markerCount = markerCount + 1
    return true
end

-- Is the resource still there to be gathered?
local function is_available(actor)
    local result = Util.safe(function() return actor:HasAvailableResources() end, nil)
    if type(result) == "boolean" then
        return result
    end

    result = Util.safe(function() return actor:IsResourceAvailable() end, nil)
    if type(result) == "boolean" then
        return result
    end

    local quantity = Util.safe(function()
        local respawn = actor.RespawnComponent
        if Util.valid(respawn) then
            return respawn:GetQuantityAvailable()
        end
        return nil
    end, nil)
    if type(quantity) == "number" then
        return quantity > 0
    end

    return not Util.safe(function() return actor.bHidden end, false)
end

-- Collects { key, owner, location, category } for everything wanted this scan.
local function collect_actor_resources(playerLocation, range2, wanted)
    for _, className in ipairs(ACTOR_SOURCES) do
        local actors = Util.safe(function() return FindAllOf(className) end, nil)
        if actors ~= nil then
            for _, actor in ipairs(actors) do
                local category = Categories.classify(Util.class_name(actor))
                if category ~= nil and Settings.is_category_on(category.id) then
                    local location = Util.vector(Util.safe(function()
                        return actor:K2_GetActorLocation()
                    end, nil))
                    if location ~= nil and Util.dist2_2d(location, playerLocation) <= range2
                        and (not Settings.hide_depleted or is_available(actor)) then
                        table.insert(wanted, {
                            key = "a" .. Util.address(actor),
                            owner = actor,
                            location = location,
                            category = category,
                        })
                    end
                end
            end
        end
    end
end

local function read_foliage_positions(comp, count)
    local positions = {}
    for index = 0, count - 1 do
        local transform = {}
        local ok = Util.safe(function()
            return comp:GetInstanceTransform(index, transform, true)
        end, false)
        if ok then
            local location = Util.vector(transform.Translation)
            local scale = Util.vector(transform.Scale3D)
            -- Harvested instances are hidden by shrinking them to nothing.
            local visible = scale == nil or math.abs(scale.X) > 0.01
            if location ~= nil and visible then
                positions[#positions + 1] = { index = index, location = location }
            end
        end
    end
    return positions
end

local function collect_foliage_resources(playerLocation, range2, wanted, now)
    local comps = Util.safe(function()
        return FindAllOf("InteractableFoliageISMComponent")
    end, nil)
    if comps == nil then
        return
    end

    local seenComps = {}
    for _, comp in ipairs(comps) do
        if Util.valid(comp) then
            local address = Util.address(comp)
            seenComps[address] = true

            local cache = foliageCache[address]
            if cache == nil then
                local actorClass = Util.safe(function() return Util.name(comp.ActorClass) end, nil)
                local mesh = Util.safe(function() return Util.name(comp.StaticMesh) end, nil)
                cache = {
                    category = Categories.classify((actorClass or "") .. "|" .. (mesh or "")) or false,
                    count = -1,
                    time = 0,
                    positions = {},
                }
                foliageCache[address] = cache
            end

            local category = cache.category
            if category and Settings.is_category_on(category.id) then
                local count = Util.safe(function() return comp:GetInstanceCount() end, 0) or 0
                if count ~= cache.count or now - cache.time >= FOLIAGE_REFRESH_SECONDS then
                    cache.positions = read_foliage_positions(comp, count)
                    cache.count = count
                    cache.time = now
                end

                local owner = Util.safe(function() return comp:GetOwner() end, nil)
                if Util.valid(owner) then
                    for _, instance in ipairs(cache.positions) do
                        if Util.dist2_2d(instance.location, playerLocation) <= range2 then
                            table.insert(wanted, {
                                key = "f" .. address .. ":" .. instance.index,
                                owner = owner,
                                location = instance.location,
                                category = category,
                            })
                        end
                    end
                end
            end
        end
    end

    for address in pairs(foliageCache) do
        if not seenComps[address] then
            foliageCache[address] = nil
        end
    end
end

function Markers.clear()
    for key in pairs(markers) do
        destroy_marker(key)
    end
    markers = {}
    markerCount = 0
end

-- Re-apply size to existing icons after the setting changes.
function Markers.apply_icon_size()
    for _, marker in pairs(markers) do
        if Util.valid(marker.comp) then
            pcall(function()
                marker.comp:SetIconSize(Settings.icon_size, SIZE_SCREEN_SPACE)
            end)
        end
    end
end

function Markers.count()
    return markerCount
end

function Markers.scan()
    scanId = scanId + 1

    if not Settings.enabled then
        if markerCount > 0 then
            Markers.clear()
        end
        return
    end

    local _, pawn = Util.local_player()
    if pawn == nil then
        return
    end

    local playerLocation = Util.vector(Util.safe(function() return pawn:K2_GetActorLocation() end, nil))
    if playerLocation == nil then
        return
    end

    local range = Settings.range_m * 100
    local range2 = range * range
    local now = os.time()
    local wanted = {}

    collect_actor_resources(playerLocation, range2, wanted)
    collect_foliage_resources(playerLocation, range2, wanted, now)

    -- Nearest first, so the icon cap keeps the most relevant ones.
    table.sort(wanted, function(a, b)
        return Util.dist2_2d(a.location, playerLocation) < Util.dist2_2d(b.location, playerLocation)
    end)

    local created = 0
    local kept = 0
    for _, item in ipairs(wanted) do
        local marker = markers[item.key]
        if marker ~= nil and Util.valid(marker.comp) and marker.categoryId == item.category.id then
            marker.seen = scanId
            kept = kept + 1
        elseif kept + created < MAX_ICONS and created < MAX_CREATES_PER_SCAN then
            if marker ~= nil then
                destroy_marker(item.key)
            end
            if create_marker(item.key, item.owner, item.location, item.category) then
                created = created + 1
            end
        end
    end

    for key, marker in pairs(markers) do
        if marker.seen ~= scanId or not Util.valid(marker.comp) then
            destroy_marker(key)
        end
    end
end

return Markers
