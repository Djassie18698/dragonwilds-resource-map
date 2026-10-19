-- Resource Markers: everything on the whole map, drawn by the game's own world map.
-- Icons are created when the world loads (or when a layer is switched on) and drawn by the game. Besides that we react
-- to the map opening (areas near the player open), its zoom (groups fitted to it), its view (icons only around it),
-- clicks on groups and the map closing (regroup), and to the game's own events (live state: harvests, destroyed
-- rocks and trees, chests, drops appearing and picked up, graves); the icon changes happen at the next engine tick
-- (ExecuteInGameThread runs on EngineTick), never inside the map's own update or an event's hook. No timers.
-- F7 (configurable in settings.txt) opens the layer menu.

local Util = require("Modules.util")
local Settings = require("Modules.settings")
local Icons = require("Modules.icons")
local Layers = require("Modules.layers")
local Menu = require("Modules.menu")
local Minimap = require("Modules.minimap")
local Live = require("Modules.live")
--DEBUG local Debug = require("Modules.debug")

Settings.load()
Layers.init()

local builtWorld = nil  -- address of the world our icons belong to

-- Clicked groups are only noted here; they open at the next engine tick.
local clicked, clickQueued = {}, false
local function open_clicked()
    clickQueued = false
    local list = clicked
    clicked = {}
    for _, owner in ipairs(list) do Layers.click(owner) end
end

local function on_icon_clicked(param)
    local owner = Layers.clicked(param:get())
    if not owner then return end
    clicked[#clicked + 1] = owner
    if not clickQueued then
        clickQueued = true
        ExecuteInGameThread(function() Util.try("Opening a group", open_clicked) end)
    end
end

-- When the map opens, areas around the player open by themselves; when it closes, everything regroups. While it's
-- open, each frame we read its view (the corners of the world it shows): group sizes follow the zoom so groups don't
-- overlap, a group's row of icons keeps hugging, and only groups around the view have icons. The hooks only note
-- things; icons change at the next engine tick.
-- While the world map is closed the minimap (same widget class) drives the same thing at its updates: only groups
-- around its view have icons, areas around the player open as they move, rows are spaced for its scale. The area size
-- stays the world map's, so opening the world map only has to add the groups around its bigger view.
local MAP_TAB = "/Game/UI/Map/WBP_TopNav_Map.WBP_TopNav_Map_C:"
local MAP_WIDGET = "/Game/UI/HUD/ModifiedMinimapPlugin/WBP_DominionMinimap.WBP_DominionMinimap_C:"
local mapHooked = false
local isWorldMap = {}       -- widget address -> whether it's the world map (the MiniMap mod uses the same widget class)
local mapUnits = nil        -- the world map's width in screen units, read once per opening
local pending = nil          -- for the next tick: { regroup, relayout, cull, near = { x, y } }
local MINIMAP_EVERY = 5      -- the minimap's view is checked on every this many of its updates
local minimapUpdates = 0
local scaleFailed, framesSeen = false, false
local minimapFailed = false  -- the minimap's view couldn't be read (logged once per world)

local function player_point()
    local _, pawn = Util.local_player(Icons.actor())
    if not pawn then return nil end
    local p = pawn:K2_GetActorLocation()
    return { x = p.X, y = p.Y }
end

local function open_near_player()
    local p = player_point()
    if p then Layers.auto_open({ p }) end
end

-- When the map opens: what came back or expired since (live sweep), then the areas near the player.
local function on_map_opened()
    --DEBUG Debug.log("world map opened")
    mapUnits, framesSeen = nil, false
    ExecuteInGameThread(function()
        Util.try("Opening areas near you", function()
            Minimap.set_shown(false)
            local changed, added = Live.sweep(player_point())
            --DEBUG Debug.log("map-open sweep: %d changed, %d new", #changed, #added)
            Layers.update(changed, added)
            open_near_player()
        end)
    end)
end

local function on_map_closed()
    --DEBUG Debug.log("world map closed")
    ExecuteInGameThread(function()
        Util.try("Regrouping", function()
            local size = Minimap.exists() and { w = Minimap.view_size(), h = Minimap.view_size() } or nil
            Layers.map_closed(player_point(), size)
            Minimap.set_shown(true)
        end)
    end)
end

-- The world map is the WBP_DominionMinimap inside the map tab. Runtime widgets are named after their slot
-- (…MapPanel.WidgetTree_2147455860.Map), so check the class of the widget that owns it: widget -> WidgetTree -> owner.
local function is_world_map(widget)
    local ok, owner = pcall(function()
        local tree = widget:GetOuter()
        local tab = tree:IsValid() and tree:GetOuter()
        return tab and tab:IsValid() and tab:GetClass():GetFName():ToString()
    end)
    return ok and owner == "WBP_TopNav_Map_C"
end

-- The part of the world a map view shows: the bounds of its corners, or nil while there's no view to read (not set up
-- yet, or a degenerate one). A call that fails raises, and the hook gives up (see hook_map). Runs every map frame.
-- GetWorldCorners returns a Lua table whose elements are UE4SS struct wrappers: a wrapper has no X of its own, its
-- :get() gives the vector (reading .X off the wrapper gives nil, which broke the map in v0.5.0).
-- A null object can't even be asked for a property (UE4SS dereferences it, which no pcall catches), so every view is
-- checked first: the minimap's view dies with the player's character and the minimap keeps updating until the respawn.
local function view_bounds(view)
    if not (view and view:IsValid()) then return nil end
    local corners = view:GetWorldCorners()
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #corners do
        local c = corners[i]
        if c.X == nil then c = c:get() end
        local x, y = c.X, c.Y
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    if not (x1 - x0 > 0) then return nil end
    return x0, y0, x1, y1
end

-- The map widget's width in screen units: its own size when known, else the viewport's.
local function initial_size(widget) return widget.InitialMapSize.X end
local function map_width_units(widget)
    local ok, w = pcall(initial_size, widget)
    if ok and w and w > 100 then return w end
    local layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    return layout:GetViewportSize(widget).X / layout:GetViewportScale(widget)
end

local function apply_pending()
    local what = pending
    pending = nil
    if not what then return end -- a map load came in between
    --DEBUG local t0, icons0 = os.clock(), Icons.count()
    if what.vignette and what.vignette:IsValid() then Minimap.hide_vignette(what.vignette) end
    --DEBUG if what.vignette then Debug.widgets(what.vignette, "world map") end
    --DEBUG if what.dump then Debug.widgets(what.dump, "minimap running") end
    if what.live then
        local changed, added = Live.apply()
        --DEBUG Debug.log("live: %d changed, %d new", #changed, #added)
        Layers.update(changed, added)
    end
    if what.regroup then
        Layers.refresh()
        open_near_player()
    else
        if what.relayout then Layers.relayout() end
        if what.near then Layers.auto_open({ what.near }) end -- first: groups coming into view then show open at once
        if what.cull then Layers.cull() end
    end
    --DEBUG local ms, icons1 = Debug.ms(t0), Icons.count()
    --DEBUG if ms >= 1 or icons1 ~= icons0 or what.regroup or what.relayout or what.live then Debug.log("tick: %s in %.1f ms, icons %d -> %d", Debug.keys_of(what), ms, icons0, icons1) end
end

local function want(what, value)
    if not pending then
        pending = {}
        ExecuteInGameThread(function() Util.try("Fitting the map icons", apply_pending) end)
    end
    pending[what] = value or true
end

-- A minimap update (every fifth frame): every few of them, its view (centred on the player) decides which groups have
-- icons and which groups near the player are open, and its scale the rows' spacing. Reads only.
local function on_minimap_tick(widget)
    minimapUpdates = minimapUpdates + 1
    if minimapUpdates % MINIMAP_EVERY ~= 0 then return end
    --DEBUG if minimapUpdates == MINIMAP_EVERY then want("dump", widget) end
    if Live.settle_due() then want("live") end
    local x0, y0, x1, y1 = view_bounds(widget.MapViewComp)
    if not x0 then return end
    if Layers.set_row_scale((x1 - x0) / Minimap.size_px(), Minimap.ICON_SCALE) then want("relayout") end
    if Layers.set_view(x0, y0, x1, y1) then want("cull") end
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if Layers.near_changed(cx, cy) then want("near", { x = cx, y = cy }) end
end

-- Every map frame (after the map's own update): reads only, then maybe queues icon changes for the next tick.
local function on_map_tick(param)
    local widget = param:get()
    local address = widget:GetAddress()
    if Minimap.is(address) then
        local ok, err = pcall(on_minimap_tick, widget)
        if not ok and not minimapFailed then
            minimapFailed = true
            Util.log("Minimap view unavailable, icons around it aren't refitted: %s", tostring(err))
        end
        return
    end
    local known = isWorldMap[address]
    if known == nil then
        known = is_world_map(widget)
        isWorldMap[address] = known
        if known then want("vignette", widget) end -- its vignette, hidden at the next tick (once per widget)
    end
    if not known then return end
    if not mapUnits then mapUnits = map_width_units(widget) end
    local x0, y0, x1, y1 = view_bounds(widget.MapViewComp)
    if not x0 or mapUnits <= 0 then return end
    local first = not framesSeen
    framesSeen = true
    --DEBUG if first then Debug.log("world map first frame: %.0f units wide, view %.0f x %.0f m", mapUnits, (x1 - x0) / 100, (y1 - y0) / 100) end
    if Live.settle_due() then want("live") end
    local what = Layers.set_scale((x1 - x0) / mapUnits)
    if what then want(what) end
    if Layers.set_view(x0, y0, x1, y1, first) then want("cull") end
end

-- The map's Blueprint classes exist once a world is loaded. If reading the world map fails (a game update changed it),
-- the hook gives up for this world: logged once, and every group gets icons so nothing becomes unreachable.
local function hook_map()
    if mapHooked then return end
    mapHooked = true
    local hooks = {
        { MAP_TAB .. "BP_OnMapMaximised", on_map_opened },
        { MAP_TAB .. "BP_OnMapMinimised", on_map_closed },
        { MAP_WIDGET .. "TickMap", function(param)
            if scaleFailed then return end
            local ok, err = pcall(on_map_tick, param)
            if not ok then
                scaleFailed = true
                Util.log("Map view unavailable, rows keep a fixed spacing and every group shows: %s", tostring(err))
                ExecuteInGameThread(function()
                    Util.try("Showing every group", function() if Layers.set_view(nil) then Layers.cull() end end)
                end)
            end
        end },
    }
    for _, h in ipairs(hooks) do
        if not pcall(RegisterHook, h[1], h[2]) then Util.log("Map hook missing: %s", h[1]:match("[^:]+$")) end
    end
    --DEBUG Debug.log("map hooks registered")
end

-- The game labels the player's own map icon with their name; it's cleared (on the map and the minimap).
local function clear_player_label(pawn)
    Util.each(pawn:K2_GetComponentsByClass(StaticFindObject("/Script/MinimapPlugin.MapIconComponent")), function(_, icon)
        if icon:IsValid() then icon:SetIconLabel("") end
    end)
end

-- Builds the map for the current world once (context: any object in it, to ask the engine for the local player).
-- Every trigger below calls this; it returns at once if there's nothing to do (already built, still loading, or the
-- main menu).
local function ensure_built(context)
    local controller, pawn = Util.local_player(context)
    if not pawn then return end
    local world = controller:GetWorld()
    if not world:IsValid() then return end
    local address, name = world:GetAddress(), world:GetFName():ToString()
    if builtWorld == address and Icons.ready() then -- the same world: a respawn
        --DEBUG Debug.log("respawn in %s", name)
        Util.try("Minimap", Minimap.attach, pawn)
        Util.try("Player label", clear_player_label, pawn)
        return
    end
    if name:find("FrontEnd", 1, true) then return end
    builtWorld = address
    --DEBUG local t0 = os.clock()
    --DEBUG Debug.log("building world %s", name)
    isWorldMap = {}
    Minimap.forget()
    if not Icons.begin(controller, Settings.icon_size) then return end
    local p = pawn:K2_GetActorLocation()
    Layers.build_world({ x = p.X, y = p.Y }, controller)
    --DEBUG Debug.log("world built at %.0f ms: %d icons", Debug.ms(t0), Icons.count())
    local changed, added = Live.sweep() -- the game's registry of graves replaces the save's
    --DEBUG Debug.log("world sweep: %d changed, %d new", #changed, #added)
    Layers.update(changed, added)
    hook_map()
    if Settings.minimap then Util.try("Minimap", Minimap.create, controller, pawn) end
    Util.try("Player label", clear_player_label, pawn)
    --DEBUG Debug.log("world %s ready at %.0f ms: %d icons", name, Debug.ms(t0), Icons.count())
end

local function soon(fn)
    return function() ExecuteInGameThread(function() Util.try("ResourceMarkers", fn) end) end
end

local function hook(path, fn)
    local ok, err = pcall(RegisterHook, path, fn)
    if not ok then Util.log("Hook %s unavailable: %s", path, tostring(err)) end
end
-- A map is about to load (another world, the main menu, joining someone): everything we hold of this world is
-- forgotten now, before the next world's objects, and events about them, arrive. Nothing is touched (the objects may
-- already be on their way out); the next world is set up from scratch when its player gets a pawn.
local function forget_world()
    --DEBUG Debug.log("a map is loading: world forgotten")
    builtWorld, isWorldMap, mapUnits, pending, clicked = nil, {}, nil, nil, {}
    Live.forget()
    scaleFailed, framesSeen, minimapUpdates, minimapFailed = false, false, 0, false
    Minimap.forget()
    Layers.forget()
    Icons.forget()
end
if not pcall(RegisterLoadMapPreHook, forget_world) then
    Util.log("Map load hook unavailable: changing worlds may leave the old world's icons referenced")
end

-- "A world is ready": a player got a pawn (after loading, respawning, or joining a server). The hook's context is that
-- player's controller (on a host it can be a guest's), an object in the world to ask the engine for the local player.
hook("/Script/Engine.PlayerController:ClientRestart", function(controller)
    local context = controller:get()
    ExecuteInGameThread(function() Util.try("ResourceMarkers", ensure_built, context) end)
end)
-- Clicks on our group icons (the only interactable icons we make).
hook("/Script/MinimapPlugin.MapIconComponent:ReceiveClicked", on_icon_clicked)

-- The game's events for live state. Each hook reads what it needs from the object at once (Live.note_*) and asks for
-- the next tick; nothing changes inside the hook. The events are rare (a harvest, a chest, a pickup), so this costs
-- nothing while nothing happens. Post: the state after the call (what's left after a harvest).
local liveFailed = {}
local function live(path, note, post)
    local name = path:match("[^:]+$")
    local function on(self)
        local ok, noted = pcall(note, self:get())
        --DEBUG Debug.log("live %s on %s: %s", name, Debug.name(self:get()), ok and tostring(noted) or ("failed: " .. tostring(noted)))
        if ok and noted then
            want("live")
        elseif not ok and not liveFailed[name] then
            liveFailed[name] = true
            Util.log("Live update %s failed: %s", name, tostring(noted))
        end
    end
    local ok, err
    if post then
        ok, err = pcall(RegisterHook, path, function() end, on)
    else
        ok, err = pcall(RegisterHook, path, on)
    end
    if not ok then Util.log("Hook %s unavailable: %s", path, tostring(err)) end
    --DEBUG if ok then Debug.log("hooked %s", name) end
end
local DOMINION = "/Script/Dominion."
live(DOMINION .. "BaseInteractableResource:OnInteraction", Live.note_resource, true)
live(DOMINION .. "BaseInteractableResource:OnRep_ResourceState", Live.note_resource)
live(DOMINION .. "DestructibleWorldActor:Multicast_InstantaneousDestruction", Live.note_destroyed)
live(DOMINION .. "WorldChest:HandleInteraction", Live.note_chest, true)
live(DOMINION .. "WorldChest:OnRep_ChestState", Live.note_chest)
live(DOMINION .. "RuntimeSpawnedWorldItem:HandleInteraction", Live.note_pickup)
-- New dropped items and graves: noted when made (also when their area loads), checked a few seconds later.
for _, n in ipairs({ { DOMINION .. "RuntimeSpawnedWorldItem", Live.note_spawn },
                     { DOMINION .. "Gravestone", Live.note_graves } }) do
    if not pcall(NotifyOnNewObject, n[1], function(obj)
        local ok, noted = pcall(n[2], obj)
        --DEBUG Debug.log("new %s %s: %s", n[1]:match("[^.]+$"), Debug.name(obj), ok and tostring(noted) or ("failed: " .. tostring(noted)))
        if ok and noted then want("live") end
    end) then
        Util.log("New-object notice for %s unavailable", n[1])
    end
end

Menu.on_change = function(kind)
    --DEBUG Debug.log("menu: %s", tostring(kind))
    if kind == "icon_size" then
        Icons.set_size(Settings.icon_size)
    elseif kind == "group_m" then
        Layers.group_distance_changed()
    elseif kind == "minimap" then
        if Settings.minimap then
            local controller, pawn = Util.local_player(Icons.actor())
            if pawn then Minimap.create(controller, pawn) end
        else
            Minimap.destroy()
        end
    elseif kind == "minimap_m" then
        Minimap.set_range()
    else -- a layer, the master switch, counts or clickable: rebuild the groups
        Layers.refresh()
    end
end

local menuKey = Key[tostring(Settings.menu_key):upper()] or Key.F7
Menu.key_name = tostring(Settings.menu_key):upper()
Menu.context = Icons.actor
RegisterKeyBind(menuKey, soon(function()
    -- The world is normally set up already (our icon owner is in it); if the mod started mid-game, after the player
    -- got their pawn, one look for a player controller stands in for the hook.
    ensure_built(Icons.actor() or FindFirstOf("PlayerController"))
    Menu.toggle()
end))
-- Menu navigation: these return straight away unless the menu is open.
local function while_open(fn)
    local run = soon(fn)
    return function()
        if Menu.is_open() then run() end
    end
end
RegisterKeyBind(Key.UP_ARROW, while_open(Menu.up))
RegisterKeyBind(Key.DOWN_ARROW, while_open(Menu.down))
RegisterKeyBind(Key.LEFT_ARROW, while_open(Menu.left))
RegisterKeyBind(Key.RIGHT_ARROW, while_open(Menu.right))
RegisterKeyBind(Key.RETURN, while_open(Menu.enter))
RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, while_open(Menu.click))

Util.log("v%s loaded (%s: map layers).", Util.VERSION, Menu.key_name)
--DEBUG Debug.log("debug build: verbose logging; F9 switches the map widgets' layers off one at a time")
--DEBUG Debug.keys()
