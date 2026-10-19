local Util = require("Modules.util")
local Categories = require("Modules.categories")

-- Map icons through the game's own map plugin: every icon is a MapIconComponent, which the game's world map draws
-- from the component's world position (the same way lodestones and graves are drawn). All of ours hang off one actor
-- we spawn at the world origin, so an icon's relative transform is its world position.
-- The game's map spends time on every registered icon (a widget per icon when it opens, Blueprint work per icon each
-- frame), hidden or not, so icons that aren't wanted are destroyed, not hidden.
local Icons = {}

-- Enum values as used by Resource Markers, which is known to draw correctly in this game.
local SIZE_SCREEN_SPACE = 0  -- EIconSizeUnit: pixels, whatever the zoom
local FOG_ALWAYS = 3         -- EIconFogInteraction: drawn over fog
local BACKGROUND_ALWAYS = 0  -- EIconBackgroundInteraction: no floor/background filtering
local SPAWN_ALWAYS = 1       -- ESpawnActorCollisionHandlingMethod::AlwaysSpawn
local SCALE_MULTIPLY = 1     -- ESpawnActorScaleMethod::MultiplyWithRoot

local owner, iconClass
local textures = {}  -- asset path -> texture (false = not found), for the current batch only (see Icons.fresh)
local live = {}      -- component address -> component, every icon we made that still exists
local failures = 0
local size = 24
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

local function transform(x, y, z)
    return { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = { X = x, Y = y, Z = z },
             Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
end

-- Textures by asset path. A Lua reference doesn't keep an engine object alive: only our icons referencing a texture
-- do, and once none does the garbage collector frees it. A texture cached across that point is a dangling pointer, and
-- handing it to the map crashed the game (UMaterialInstanceDynamic::SetTextureParameterValue). So the cache only lives
-- for one batch of icon changes (Icons.fresh() starts a new one), during which every texture is assigned to an icon.
function Icons.fresh()
    textures = {}
end

function Icons.texture(path)
    local cached = textures[path]
    if cached ~= nil and (cached == false or cached:IsValid()) then return cached or nil end
    local texture = StaticFindObject(path)
    if not texture:IsValid() then
        local ok, loaded = pcall(LoadAsset, path)
        texture = ok and loaded or nil
    end
    if not (texture and texture:IsValid()) then
        Util.log("Texture not found: %s", path)
        texture = path ~= Categories.PLACEHOLDER_ICON and Icons.texture(Categories.PLACEHOLDER_ICON) or nil
    end
    textures[path] = texture or false
    return texture
end

local function spawn_owner(context)
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local origin = transform(0.0, 0.0, 0.0)
    local actor = statics:BeginDeferredActorSpawnFromClass(context, StaticFindObject("/Script/Engine.Actor"), origin,
        SPAWN_ALWAYS, nil, SCALE_MULTIPLY)
    if not (actor and actor:IsValid()) then error("could not spawn the icon owner") end
    statics:FinishSpawningActor(actor, origin, SCALE_MULTIPLY)
    -- A plain root at the origin; icons attach to it with their world position as relative location.
    actor:AddComponentByClass(StaticFindObject("/Script/Engine.SceneComponent"), false, origin, false)
    return actor
end

-- New world: forget the old icons (they died with the old world) and spawn a fresh owner.
function Icons.begin(context, iconSize)
    live, owner, size, failures = {}, nil, iconSize or size, 0
    iconClass = StaticFindObject("/Script/MinimapPlugin.MapIconComponent")
    if not iconClass:IsValid() then
        Util.log("MapIconComponent class not found; is this the right game version?")
        return false
    end
    local ok, actor = pcall(spawn_owner, context)
    if not ok then
        Util.log("Icon owner: %s", tostring(actor))
        return false
    end
    owner = actor
    return true
end

function Icons.ready()
    return owner ~= nil and owner:IsValid()
end

-- The world is going away (a map load): forget our owner and icons without touching them.
function Icons.forget()
    live, owner, textures = {}, nil, {}
end

-- Our icon owner, an actor in the current world (nil before a world is set up): a world object for engine calls.
function Icons.actor()
    return Icons.ready() and owner or nil
end

-- spec: { x, y, z, texture, tip, label, color, zorder, interactable }. Configured before it registers with the map.
local function create(spec)
    local at = transform(spec.x, spec.y, spec.z)
    local comp = owner:AddComponentByClass(iconClass, false, at, true)
    comp.IconTexture = spec.texture
    comp.IconSize = size
    comp.IconSizeUnit = SIZE_SCREEN_SPACE
    comp.bIconRotates = false
    comp.IconZOrder = spec.zorder or 4
    comp.IconFogInteraction = FOG_ALWAYS
    comp.IconBackgroundInteraction = BACKGROUND_ALWAYS
    comp.IconDrawColor = spec.color or WHITE
    comp.bIconInteractable = spec.interactable == true
    comp.bIconVisible = true
    if spec.label and spec.label ~= "" then comp:SetIconLabel(spec.label) end
    if spec.tip then comp:SetIconTooltipText(FText(spec.tip)) end
    owner:FinishAddComponent(comp, false, at)
    return comp
end

-- One icon; nil if the game refused (logged, the first few times).
function Icons.make(spec)
    local ok, comp = pcall(create, spec)
    if not ok then
        failures = failures + 1
        if failures <= 3 then Util.log("Map icon failed: %s", tostring(comp)) end
        return nil
    end
    live[comp:GetAddress()] = comp
    return comp
end

-- Moves an icon (its relative location is its world position, see spawn_owner).
function Icons.move(comp, x, y, z)
    if comp and comp:IsValid() then comp:K2_SetRelativeLocation({ X = x, Y = y, Z = z }, false, {}, false) end
end

-- Removes an icon, so the map stops spending time on it.
function Icons.destroy(comp)
    if not comp then return end
    live[comp:GetAddress()] = nil
    if comp:IsValid() then comp:K2_DestroyComponent(comp) end
end

function Icons.set_size(newSize)
    size = newSize
    for _, comp in pairs(live) do
        if comp:IsValid() then comp:SetIconSize(size, SIZE_SCREEN_SPACE) end
    end
end

function Icons.count()
    local total = 0
    for _ in pairs(live) do total = total + 1 end
    return total
end

return Icons
