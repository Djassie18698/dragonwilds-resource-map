-- Smoke test on the host: runs the mod against a fake UE4SS (every object answers every call) to catch Lua
-- mistakes before the game does: world load; layers on/off (a row of icons per area, one per kind); the map opening
-- (areas near the player open), zooming (rows re-spaced), panning (icons only around the view), clicking a group,
-- closing (regrouped for the next opening); the minimap; changing worlds; settings;
-- textures freed by the garbage collector never being reused. Icon changes must happen at engine ticks, not in hooks.
-- It doesn't prove the game accepts the calls; UE4SS.log does that.
-- Usage: lua5.4 tests/mock-run.lua <world.sav>
-- The mod: the source (a release build), or the copy DW_MOD names (tests/run.sh: a debug build).
local here = os.getenv("DW_MOD") or ((arg[0]:match("^(.*)/tests/") or ".") .. "/ResourceMarkers")
local SAV = assert(arg[1], "usage: mock-run.lua <world.sav>")

-- A permissive fake UObject: every field is another fake, fakes can be called like methods, and each has an address.
local created, destroyed, moved, nextAddress = 0, 0, 0, 0x1000
local make_map_view -- set below: a map view component (the minimap's), following the player
local staleTextures = 0  -- freed textures handed to icons (that crashed the game)
local function fake(name, props)
    nextAddress = nextAddress + 8
    local obj = { __name = name, __props = props or {}, __address = nextAddress }
    return setmetatable(obj, {
        __index = function(t, k)
            if type(k) == "number" then return nil end -- as an array a fake is empty (ipairs ends at once)
            if k == "IsValid" then return function() return not rawget(t, "__freed") end end
            if k == "GetFName" then return function() return { ToString = function() return name end } end end
            if k == "GetFullName" or k == "ToString" then return function() return name end end
            if k == "GetAddress" then return function() return t.__address end end
            if k == "IsLocalController" then return function() return true end end
            if k == "GetWorld" then return function() return WORLD end end
            if k == "AddComponentByClass" then return function(_, class)
                if make_map_view and type(class) == "table" and tostring(rawget(class, "__name")):find("MapViewComponent", 1, true) then
                    return make_map_view()
                end
                created = created + 1
                return fake("MapIconComponent")
            end end
            if k == "K2_DestroyComponent" then return function() destroyed = destroyed + 1 end end
            if k == "K2_SetRelativeLocation" then return function() moved = moved + 1 end end
            if k == "IsInViewport" then return function() return true end end
            if k == "IsHovered" then return function() return false end end
            if t.__props[k] ~= nil then return t.__props[k] end
            return fake(name .. "." .. k) -- works as a property (an object) and as a method (callable)
        end,
        __newindex = function(t, k, v)
            if k == "IconTexture" and type(v) == "table" and rawget(v, "__freed") then staleTextures = staleTextures + 1 end
            t.__props[k] = v
        end,
        __call = function() return fake(name .. "()") end,
    })
end

WORLD = fake("L_World") -- one world for the whole run, like the game (global: fake() refers to it)
local hooks, keys, queue = {}, {}, {}
-- Textures behave like loaded assets: one object per path until the "garbage collector" frees it (collect()), after
-- which StaticFindObject finds nothing and LoadAsset loads a new one.
local textures = {}
local function texture_like(path)
    return (path:find("/Game/", 1, true) or path:find("Icons/", 1, true)) and not path:find("WBP_", 1, true)
end
-- The game's map widget, as the game showed it: its vignette image, ShadowFrame, isn't a Blueprint variable, and
-- UserWidget's GetWidgetFromName isn't a UFunction in this game build (calling it raises, as in UE4SS). Its widgets
-- are objects inside its WidgetTree, whose runtime name has a number, so only that path finds ShadowFrame.
-- vignettes: widget -> { visibility, sets (SetVisibility calls) }.
local vignettes, vignettePaths, treeNumber = {}, {}, 2147455860
local function as_map_widget(w)
    w.GetWidgetFromName = function() error("GetWidgetFromName: not a UFunction in this game build") end
    treeNumber = treeNumber + 1
    local tree = "/Engine/Transient.WBP_DominionMinimap_C_" .. treeNumber .. ".WidgetTree_" .. treeNumber
    local v = { visibility = 4, sets = 0 }
    vignettes[w] = v
    vignettePaths[tree .. ".ShadowFrame"] = fake("ShadowFrame",
        { SetVisibility = function(_, vis) v.visibility, v.sets = vis, v.sets + 1 end })
    w.WidgetTree = fake("WidgetTree " .. tree)
    return w
end
-- The widget library: the game's map widget class gives the minimap widget (kept, to drive its updates).
local minimapWidget = nil
local function widget_library()
    return fake("WidgetBlueprintLibrary", { Create = function(_, _, class)
        if tostring(rawget(class, "__name")):find("WBP_DominionMinimap", 1, true) then
            minimapWidget = as_map_widget(fake("WBP_DominionMinimap_C (minimap)"))
            minimapWidget.SetMapView = function(self, view) rawget(self, "__props").MapViewComp = view end
            return minimapWidget
        end
        return fake("UserWidget")
    end })
end
-- World time in seconds (GameplayStatics:GetTimeSeconds), for the in-game clock.
local gameSeconds = 0
_G.StaticFindObject = function(path)
    if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return widget_library() end
    if path == "/Script/Engine.Default__GameplayStatics" then
        return fake(path, { GetTimeSeconds = function() return gameSeconds end })
    end
    if path:find("%.ShadowFrame$") then -- only the real path finds it
        local found = vignettePaths[path]
        if found then return found end
        local none = fake(path)
        rawset(none, "__freed", true)
        return none
    end
    if not texture_like(path) then return fake(path) end
    if textures[path] then return textures[path] end
    local gone = fake(path)
    rawset(gone, "__freed", true)
    return gone
end
local function collect()
    for path, t in pairs(textures) do rawset(t, "__freed", true) textures[path] = nil end
end
-- Canvases record where children go: child address -> { slot = its slot's settings, canvas = the canvas }.
local placed = {}
local function canvas_fake(name)
    local c = fake(name)
    c.AddChildToCanvas = function(self, child)
        local entry = { canvas = self }
        placed[child:GetAddress()] = entry
        return fake("CanvasPanelSlot", {
            SetAnchors = function(_, v) entry.anchors = v end, SetAlignment = function(_, v) entry.alignment = v end,
            SetPosition = function(_, v) entry.position = v end, SetSize = function(_, v) entry.size = v end,
            SetAutoSize = function(_, v) entry.autoSize = v end, SetOffsets = function(_, v) entry.offsets = v end,
            SetZOrder = function(_, v) entry.zOrder = v end,
        })
    end
    return c
end
_G.StaticConstructObject = function(class)
    if tostring(rawget(class, "__name")):find("CanvasPanel", 1, true) then return canvas_fake("constructed canvas") end
    return fake("constructed")
end
-- The HUD's day/night clock, in a canvas slot (top-right).
local clockSlot = { anchors = { Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } }, alignment = { X = 1, Y = 0 },
                    position = { X = -20, Y = 20 } }
local hudCanvas = canvas_fake("HUD canvas")
local clockSlotObj = fake("CanvasPanelSlot", {
    GetClass = function() return fake("CanvasPanelSlot") end,
    GetAnchors = function() return clockSlot.anchors end,
    GetAlignment = function() return clockSlot.alignment end,
    GetOffsets = function() return { Left = -20, Top = 20, Right = 64, Bottom = 64 } end,
    GetAutoSize = function() return false end,
    GetZOrder = function() return 3 end,
    Parent = hudCanvas,
})
local clockWidget = fake("WBP_HUD_DayAndNight_C", { Slot = clockSlotObj })
clockWidget.RemoveFromParent = function(self) rawget(self, "__props").RemovedFromParent = true end
local clockLookups = 0
-- The game's registry of graves (the save's one grave to begin with) and its in-game clock (the save's time; a day
-- takes 24 real minutes).
local registryGraves = { { Location = { X = 40455, Y = 175606, Z = -4234 }, OwningCharDisplayName = "Someone" } }
local registry = fake("GameplayObjectRegistry", { Gravestones = registryGraves })
local timeActor = fake("BP_InGameTimeActor_C", { StoredTime = 52.756 * 1440, RealTimeMinutesPerInGameDay = 24,
                                                 LastSyncTime = 0, bIsTimePaused = false })
_G.FindFirstOf = function(name)
    if name == "WBP_HUD_DayAndNight_C" then
        clockLookups = clockLookups + 1
        return clockWidget
    end
    if name == "GameplayObjectRegistry" then return registry end
    if name == "InGameTimeActor" then return timeActor end
    return fake(name)
end
-- Like UE4SS: a callback when an object of a class is made.
local onNew = {}
_G.NotifyOnNewObject = function(path, fn) onNew[path] = fn end
local worldItems = {} -- dropped items lying in the world right now
_G.FindAllOf = function(name)
    if name == "RuntimeSpawnedWorldItem" then return worldItems end
    return { fake(name) }
end
-- Real seconds can be skipped ahead (a new drop is checked once it has lasted a few seconds).
local realClock, skipped = os.clock, 0
os.clock = function() return realClock() + skipped end
_G.LoadAsset = function(path)
    local t = fake(path)
    if texture_like(path) then textures[path] = t end
    return t
end
_G.FText = function(s) return s end
_G.FName = function(s) return s end
-- Like UE4SS, several hooks can be registered on one function; calling hooks[path](...) runs them all.
_G.RegisterHook = function(path, fn, post)
    local list = hooks[path]
    if not list then
        list = setmetatable({}, { __call = function(self, ...) for _, f in ipairs(self) do f(...) end end })
        hooks[path] = list
    end
    list[#list + 1] = fn
    if post then list[#list + 1] = post end -- native functions: a post-callback, run after the call
end
_G.RegisterLoadMapPostHook = function(fn) hooks.loadmap = fn end
-- Like UE4SS, several map-load hooks can be registered; calling hooks.loadmappre() runs them all.
hooks.loadmappre = setmetatable({}, { __call = function(self, ...) for _, f in ipairs(self) do f(...) end end })
_G.RegisterLoadMapPreHook = function(fn) table.insert(hooks.loadmappre, fn) end
_G.RegisterKeyBind = function(key, fn) keys[key] = fn end
-- Like UE4SS with DefaultExecuteInGameThreadMethod = EngineTick: queued, run at the next engine tick (tick()).
_G.ExecuteInGameThread = function(fn) queue[#queue + 1] = fn end
local function tick()
    local pending = queue
    queue = {}
    for _, fn in ipairs(pending) do fn() end
end
_G.Key = setmetatable({}, { __index = function(_, k) return k end })
local problems, createdInsideHooks = 0, 0
_G.print = function(s)
    -- (a debug build's lines report what it looked at, not problems of the mod)
    if not s:find(" dbg: ", 1, true) and (s:find("failed", 1, true) or s:find("not found", 1, true) or s:find("unavailable", 1, true)) then problems = problems + 1 end
    io.write(s)
end

-- Point the mod at a temp Saved folder holding a copy of the save, and keep its settings out of the project.
local tmp = os.tmpname()
os.remove(tmp)
os.execute("mkdir -p '" .. tmp .. "/RSDragonwilds/Saved/SaveGames'")
os.execute("cp '" .. SAV .. "' '" .. tmp .. "/RSDragonwilds/Saved/SaveGames/Test.sav'")
local realOpen = io.open
io.open = function(p, m) return realOpen((p:gsub("\\", "/")), m) end -- saves are read with Windows separators

package.path = here .. "/Scripts/?.lua;" .. package.path
local Util = require("Modules.util")
Util.mod_dir = function() return here end
local player = { X = 0, Y = 0, Z = 0 }
-- A corner as UE4SS 3.0.1 returns it from GetWorldCorners: a struct wrapper without fields of its own; :get() gives
-- the vector.
local function corner(x, y)
    return setmetatable({}, { __index = function(_, k) if k == "get" then return function() return { X = x, Y = y } end end end })
end
make_map_view = function()
    local extent = 15000
    return fake("MapViewComponent", {
        SetViewExtent = function(_, x) extent = x end,
        GetWorldCorners = function()
            return { corner(player.X - extent, player.Y - extent), corner(player.X + extent, player.Y + extent) }
        end,
    })
end
Util.saved_dir = function() return tmp .. "/RSDragonwilds/Saved/" end
-- The player stands at a given spot.
-- The player's own map icon, which the game labels with their name.
local playerIcon = fake("MapIconComponent (player)")
playerIcon.SetIconLabel = function(self, text) rawget(self, "__props").label = text end
playerIcon.__props.label = "Player Name"
local pawn = fake("Pawn", { K2_GetActorLocation = function() return player end,
    K2_GetComponentsByClass = function() return { playerIcon } end }) -- a function result: a Lua table, as in game
local controller = fake("PlayerController")
Util.local_player = function() return controller, pawn end
local Settings = require("Modules.settings")
Settings.save = function() end            -- don't write settings.txt into the project
Settings.world_save = "Test"

dofile(here .. "/Scripts/main.lua")
local Menu = require("Modules.menu")
local Icons = require("Modules.icons")
local Layers = require("Modules.layers")
local Minimap = require("Modules.minimap")

local fails = 0
local function check(cond, what)
    if not cond then fails = fails + 1 print("[mock] FAIL: " .. what .. "\n") end
end

local function upvalue(fn, wanted)
    for i = 1, 80 do
        local name, value = debug.getupvalue(fn, i)
        if name == wanted then return value end
        if not name then return nil end
    end
end
-- A function a profiler wrapped (discovery builds): look inside the wrapper.
local function unwrapped(fn)
    local inner = upvalue(fn, "fn")
    return type(inner) == "function" and inner or fn
end
local function current_areas() return upvalue(Layers.cull, "areas") end
local function shown(a) return a.icons ~= nil or a.comps ~= nil end
local function overlaps(g, r) return g.x1 >= r.x0 and g.x0 <= r.x1 and g.y1 >= r.y0 and g.y0 <= r.y1 end
local function dist(g, p)
    local dx = math.max(g.x0 - p.x, 0, p.x - g.x1)
    local dy = math.max(g.y0 - p.y, 0, p.y - g.y1)
    return math.sqrt(dx * dx + dy * dy)
end
-- Groups (however big) with a thing within 2/3 of the group distance (100 m) of the player are open, nearest first,
-- until 300 things are; none further than 1.25 times that is open because of the player; zoomed out beyond the group
-- distance, none is.
local NEAR, BUDGET = 2 / 3, 300
local function near_right()
    local base, p = Settings.group_m * 100, { x = player.X, y = player.Y }
    local zoomedOut = Layers.area_m() > Settings.group_m
    local open = upvalue(Layers.auto_open, "open")
    local closedWithin, openThings, nearestClosed, biggest = {}, 0, math.huge, 0
    for key, a in pairs(current_areas()) do
        local n, d = #a.g.members, dist(a.g, p)
        if open[key] == "auto" then
            if zoomedOut or d > base * NEAR * 1.25 then return false, "open at " .. math.floor(d) end
            openThings, biggest = openThings + n, math.max(biggest, n)
        elseif not zoomedOut and n >= 2 and d <= base * NEAR then
            nearestClosed = math.min(nearestClosed, d)
        end
    end
    if nearestClosed < math.huge and openThings < BUDGET then
        return false, "closed at " .. math.floor(nearestClosed) .. " with only " .. openThings .. " things open"
    end
    if openThings - biggest >= BUDGET then return false, "over the budget: " .. openThings .. " things open" end
    return true
end
local function kinds_of(g)
    local kinds, n = {}, 0
    for _, e in ipairs(g.members) do if not kinds[e.layer] then kinds[e.layer] = true n = n + 1 end end
    return n
end

-- World loads: the layers that are on by default (your drops, graves, storage) are grouped like every other layer.
hooks["/Script/Engine.PlayerController:ClientRestart"]({ get = function() return controller end })
tick()
local atLoad = Icons.count()
local mineStats = Layers.stats()
-- The save's drops lie in the world as items (what FindAllOf finds), as in the game: not hidden, not being destroyed,
-- not flying to anyone.
local function lying_item(id, x, y, z, props)
    local p = { ItemData = fake("ItemData", { PersistenceID = id }), K2_GetActorLocation = function() return { X = x, Y = y, Z = z } end,
                bCanExpire = false, bHidden = false, bActorIsBeingDestroyed = false,
                GetMagneticComponent = function() return fake("MagneticComponent_GrantItem", { Target = false }) end }
    for k, v in pairs(props or {}) do p[k] = v end
    return fake("BP_RuntimeSpawnedWorldItem_C", p)
end
for _, layer in ipairs({ "items", "junk" }) do
    for _, pile in ipairs(upvalue(unwrapped(Layers.update), "snap").layers[layer]) do
        for _, it in ipairs(pile.items) do worldItems[#worldItems + 1] = lying_item(it.id, it.x, it.y, it.z) end
    end
end
check(mineStats.groups > 0 and atLoad < 12 + 1 + 24,
      string.format("drops, graves and storage are grouped at load (%d icons, %d groups)", atLoad, mineStats.groups))
check(playerIcon.__props.label == "", "the player's own map icon has no name on it")
check(created == atLoad + 1, "one component per icon, plus the root")

-- Stone and copper on: grouped per the group distance (150 m), icons only around the player (the map opens there).
Settings.layers.stone, Settings.layers.copper = true, true
Menu.on_change("layer", "stone")
Menu.on_change("layer", "copper")
local areas = current_areas()
local s0 = Layers.stats()
check(s0.groups > 20 and s0.shown < s0.groups, string.format("before the map opens, only groups around you have icons (%d of %d)", s0.shown, s0.groups))
local mixed
for _, a in pairs(areas) do
    local kinds = {}
    for _, e in ipairs(a.g.members) do kinds[e.layer] = true end
    if kinds.stone and kinds.copper then mixed = a break end
end
check(mixed and mixed.g.members[1].layer == "copper", "a mixed area lists copper (rarer) before stone")

-- The player stands in the busiest area.
local busy, most = nil, 0
for _, a in pairs(areas) do
    if #a.g.members > most then busy, most = a.g, #a.g.members end
end
player.X, player.Y = busy.x, busy.y

-- The minimap is made at world load, north up, its view on the player. Its updates (the world map closed) decide which
-- groups have icons (around its view) and open the areas around the player; nothing changes inside its hook.
local MINIMAP = "/Game/UI/HUD/ModifiedMinimapPlugin/WBP_DominionMinimap.WBP_DominionMinimap_C:"
check(Minimap.exists() and Minimap.is_shown() and minimapWidget and minimapWidget.__props.MapViewComp,
    "the minimap is made at world load, with its view")
check(minimapWidget and minimapWidget.__props.AutoLocateMapView == 4 and minimapWidget.__props.bIsCircular == true
    and minimapWidget.__props.bShouldShowFog == false, "the minimap: its view handed to it, round, no fog")
check(vignettes[minimapWidget].visibility == 1, "the minimap's vignette is hidden")
local clockAt = placed[clockWidget:GetAddress()]
check(clockAt and clockAt.canvas ~= hudCanvas and clockAt.alignment.X == 0.5 and clockAt.size.X == 64
    and math.abs(clockAt.position.X - (-(24 + 125) - 0.83 * 125)) < 1 and math.abs(clockAt.position.Y - (24 + 125 - 0.71 * 125)) < 1,
    "the day/night clock moved into the minimap's canvas, onto its upper-left rim")
local miniParam = { get = function() return minimapWidget end }
local function minimap_updates()
    local before, beforeMoved = created, moved
    for _ = 1, 5 do hooks[MINIMAP .. "TickMap"](miniParam) end
    if created ~= before or moved ~= beforeMoved then createdInsideHooks = createdInsideHooks + 1 end
    tick()
end
local function minimap_culled()
    local live = upvalue(Layers.set_view, "live")
    local half = Minimap.view_size() / 2
    if not live or live.x1 - live.x0 > Minimap.view_size() * 1.6 then return false end
    local seen = { x0 = player.X - half, y0 = player.Y - half, x1 = player.X + half, y1 = player.Y + half }
    for _, a in pairs(current_areas()) do
        if shown(a) and not overlaps(a.g, live) then return false end
        if not shown(a) and overlaps(a.g, seen) then return false end
    end
    return true
end
minimap_updates()
check(minimap_culled(), "with the minimap, icons only around its view")
local nearOk, nearWhy = near_right()
check(nearOk, "the minimap opens the groups near the player (" .. tostring(nearWhy) .. ")")
local spacingMini = Layers.row_spacing()
check(math.abs(spacingMini - 0.7 * Settings.icon_size * Minimap.ICON_SCALE * Minimap.view_size() / Minimap.size_px()) < 1,
    "rows spaced for the minimap")
-- Walking somewhere else: the minimap's icons follow.
local elsewhere
for _, a in pairs(current_areas()) do
    if math.abs(a.g.x - player.X) > Minimap.view_size() * 3 then elsewhere = a.g break end
end
player.X, player.Y = elsewhere.x, elsewhere.y
minimap_updates()
check(minimap_culled(), "walking elsewhere: the minimap's icons follow")
nearOk, nearWhy = near_right()
check(nearOk, "walking elsewhere: the groups near the player open, the ones left behind close (" .. tostring(nearWhy) .. ")")
-- Walking a little within the same place keeps it all as is, and checking again changes nothing (no flapping).
local c1, d1 = created, destroyed
minimap_updates()
check(created == c1 and destroyed == d1, "standing still changes nothing")
-- Stepping just past the reach of an open group (between 1 and 1.25 area sizes) keeps it open.
local size = Layers.area_m() * 100
local keep
for key, reason in pairs(upvalue(Layers.auto_open, "open")) do
    if reason == "auto" then keep = key break end
end
if keep then
    local g = current_areas()[keep].g
    local cx = (g.x0 + g.x1) / 2
    local base = Settings.group_m * 100
    player.X, player.Y = g.x1 + base * NEAR * 1.1, (g.y0 + g.y1) / 2
    minimap_updates()
    check(upvalue(Layers.auto_open, "open")[keep] == "auto", "just past the reach, an open group stays open")
    player.X = g.x1 + base * NEAR * 1.4
    minimap_updates()
    check(upvalue(Layers.auto_open, "open")[keep] ~= "auto", "well past it, it closes")
end
player.X, player.Y = busy.x, busy.y
minimap_updates()

-- The HUD makes a new clock (it rebuilt itself): the minimap places it at the next tick, from the event alone.
local newClockSlot = fake("CanvasPanelSlot", {
    GetClass = function() return fake("CanvasPanelSlot") end,
    GetAnchors = function() return { Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } } end,
    GetAlignment = function() return { X = 1, Y = 0 } end,
    GetOffsets = function() return { Left = -20, Top = 20, Right = 64, Bottom = 64 } end,
    GetAutoSize = function() return false end, GetZOrder = function() return 3 end, Parent = canvas_fake("new HUD canvas"),
})
local newClock = fake("WBP_HUD_DayAndNight_C (new)", { Slot = newClockSlot })
local lookupsBefore = clockLookups
local watch = onNew["/Game/UI/HUD/DayAndNight/WBP_HUD_DayAndNight.WBP_HUD_DayAndNight_C"]
check(watch ~= nil, "the minimap watches for new clocks")
if watch then
    watch(newClock)
    check(placed[newClock:GetAddress()] == nil, "a new clock isn't moved inside the game's event")
    tick()
    local at = placed[newClock:GetAddress()]
    check(at and at.alignment.X == 0.5 and clockLookups == lookupsBefore, "a new clock goes onto the rim, without a search")
    check(clockWidget.__props.RemovedFromParent == true, "the old clock we had moved is dropped")
end
clockWidget = newClock -- the HUD's clock from now on

-- Which save is this world's: settings.txt's world_save, else the game's record of the loaded world (host only).
local isServer, slotName = true, "Test"
local realFind = _G.StaticFindObject
_G.StaticFindObject = function(path)
    if path == "/Script/Engine.Default__KismetSystemLibrary" then
        return fake("KismetSystemLibrary", { IsServer = function() return isServer end })
    end
    if path == "/Script/Engine.Default__SubsystemBlueprintLibrary" then
        return fake("SubsystemBlueprintLibrary", { GetGameInstanceSubsystem = function()
            return fake("PersistenceSubsystem", { WorldSaveSettings = { WorldSlotName = slotName } })
        end })
    end
    return realFind(path)
end
local savedSetting = Settings.world_save
Settings.world_save = ""
check(Layers.save_slot(controller) == "Test", "the host reads the save of the world the game has loaded")
isServer = false
check(Layers.save_slot(controller) == nil, "a guest reads no save (the host's world isn't on this computer)")
isServer, slotName = true, ""
check(Layers.save_slot(controller) == nil, "a world without a slot yet reads no save")
Settings.world_save = "Other"
check(Layers.save_slot(controller) == "Other", "world_save in settings.txt picks the save")
Settings.world_save = savedSetting
_G.StaticFindObject = realFind

-- The world map: the widget (named like the game's runtime instance, owned by the map tab) and its view, a 16:9
-- rectangle of the world around (viewX, viewY).
local MAP_TAB = "/Game/UI/Map/WBP_TopNav_Map.WBP_TopNav_Map_C:"
local viewWidth, viewX, viewY = 200000, busy.x, busy.y -- game units across the map (2 km), centred on the player
local viewComp = fake("MapViewComponent", { GetWorldCorners = function()
    local w, h = viewWidth / 2, viewWidth * 9 / 32
    return { corner(viewX - w, viewY - h), corner(viewX + w, viewY - h), corner(viewX + w, viewY + h),
             corner(viewX - w, viewY + h) }
end })
local mapTab = fake("MapPanel", { GetClass = function() return fake("WBP_TopNav_Map_C") end })
local widgetTree = fake("WidgetTree", { GetOuter = function() return mapTab end })
local widget = fake("WBP_DominionMinimap_C /Engine/Transient.WBP_InGameTopNav_InGame_C_1.WidgetTree.MapPanel.WidgetTree.Map",
    { MapViewComp = viewComp, GetOuter = function() return widgetTree end, InitialMapSize = { X = 1600, Y = 900 } })
as_map_widget(widget)
local param = { get = function() return widget end }
-- One map frame: the map's update (our hook inside it), then the next engine tick.
local function frame()
    local before, beforeMoved = created, moved
    hooks[MINIMAP .. "TickMap"](param)
    if created ~= before or moved ~= beforeMoved then createdInsideHooks = createdInsideHooks + 1 end
    tick()
end
check(hooks[MAP_TAB .. "BP_OnMapMaximised"] and hooks[MAP_TAB .. "BP_OnMapMinimised"] and hooks[MINIMAP .. "TickMap"], "map hooks registered")

-- Icons only in and around the view: every group with icons is inside the covered rect, every group in view has icons.
local function culled_right()
    local live = upvalue(Layers.set_view, "live")
    local h = viewWidth * 9 / 32
    local seen = { x0 = viewX - viewWidth / 2, y0 = viewY - h, x1 = viewX + viewWidth / 2, y1 = viewY + h }
    for _, a in pairs(current_areas()) do
        if shown(a) and not overlaps(a.g, live) then return false end
        if not shown(a) and overlaps(a.g, seen) then return false end
    end
    return true
end
local function closed_count()
    local n = 0
    for _, a in pairs(current_areas()) do
        if a.icons then n = n + #a.icons elseif a.comps then n = n + (#a.g.members == 1 and 1 or kinds_of(a.g)) end
    end
    return n
end
local function per_unit() return viewWidth / 1600 end

-- Open the map: nothing changes inside the hooks; at the next ticks areas near the player open (not dense ones), the
-- groups are the group distance (this is the zoom the map opens with) and only groups around the view have icons.
local before = created
hooks[MAP_TAB .. "BP_OnMapMaximised"]()
check(created == before, "opening the map changes nothing by itself")
tick()
check(not Minimap.is_shown(), "the minimap hides while the world map is open")
frame()
check(vignettes[widget].visibility == 1, "the world map's vignette is hidden after its first frame")
areas = current_areas()
local level1 = Layers.area_m()
check(level1 == Settings.group_m, "at the zoom the map opens with, groups are the group distance (" .. level1 .. " m)")
-- (rows are re-spaced when the spacing they need is off by more than a tenth, so within that they stay as they were)
local hug = 0.7 * Settings.icon_size * per_unit()
check(math.abs(Layers.row_spacing() - hug) <= hug * 0.1, "row icons hug (0.7 icon widths, within a tenth)")
check(culled_right(), "icons only in and around the view")
local s1 = Layers.stats()
check(s1.shown > 5 and s1.shown < s1.groups, string.format("some groups in view, not all (%d of %d)", s1.shown, s1.groups))
local nearNow, nearWhy0 = near_right()
check(nearNow, "opening the map opens the groups near the player, dense ones too (" .. tostring(nearWhy0) .. ")")
-- Every group with icons: one per kind, at most 4 per row (more kinds continue below), no "+N" marker.
local rowsOk = true
for _, a in pairs(areas) do
    if a.icons and #a.g.members > 1 then
        if #a.icons ~= kinds_of(a.g) then rowsOk = false end
        local perRow = {}
        for _, slot in ipairs(a.slots) do perRow[slot.row] = (perRow[slot.row] or 0) + 1 end
        for _, n in pairs(perRow) do if n > 4 then rowsOk = false end end
    end
end
check(rowsOk, "one icon per kind, no row longer than 4")

-- A tiny zoom change: nothing. A modest one: rows re-spaced by moving icons, not rebuilt.
local madeBefore, movedBefore = created, moved
viewWidth = viewWidth * 1.05
frame()
check(created == madeBefore and moved == movedBefore, "a tiny zoom change changes nothing")
viewWidth = viewWidth * 1.3 / 1.05
frame()
check(Layers.area_m() == level1 and created == madeBefore and moved > movedBefore, "a modest zoom change only re-spaces rows")
-- Zooming far out: bigger groups, none opened for being near the player (they'd spill hundreds of things); back in: the
-- original grouping.
viewWidth = 200000 * 8
frame()
check(Layers.area_m() > level1 and Layers.stats().groups < s1.groups, "zooming out: bigger groups (" .. Layers.area_m() .. " m)")
local autoOpen = 0
for _, reason in pairs(upvalue(Layers.auto_open, "open")) do if reason == "auto" then autoOpen = autoOpen + 1 end end
check(autoOpen == 0, "zoomed out: nothing opens near the player (" .. autoOpen .. ")")
viewWidth = 200000
frame()
check(Layers.area_m() == level1 and culled_right(), "zooming back in: the original grouping, culled again")
-- The group distance from the menu: twice the distance, the next map frame groups twice as wide; back again.
Settings.group_m = Settings.group_m * 2
Menu.on_change("group_m", nil)
check(Layers.area_m() == 2 * level1, "a bigger group distance regroups wider at once (" .. Layers.area_m() .. " m)")
frame()
check(Layers.area_m() == 2 * level1, "and stays so at this zoom (" .. Layers.area_m() .. " m)")
Settings.group_m = Settings.group_m / 2
Menu.on_change("group_m", nil)
frame()
check(Layers.area_m() == level1, "the group distance back: the original grouping")

-- Panning a little (inside the margin) changes nothing.
local c0, d0 = created, destroyed
viewX = viewX + viewWidth * 0.1
frame()
check(created == c0 and destroyed == d0, "a small pan changes nothing")
viewX = busy.x
frame()

-- Click the busiest closed group: one click shows every thing in it.
areas = current_areas()
busy, most = nil, 0
for _, a in pairs(areas) do
    if a.icons and #a.g.members > most then busy, most = a.g, #a.g.members end
end
hooks["/Script/MinimapPlugin.MapIconComponent:ReceiveClicked"]({ get = function() return areas[busy.key].icons[1] end })
check(not areas[busy.key].comps, "a click changes nothing by itself")
tick()
check(areas[busy.key].comps and #areas[busy.key].comps == most, "one click shows every thing in the group (" .. most .. ")")

-- Panning far away (to another busy place): groups there get icons at the next tick, the ones left behind lose
-- theirs; the clicked group keeps its state and is open again when the view comes back.
local far, farMost = nil, 0
for _, a in pairs(areas) do
    if math.abs(a.g.x - busy.x) > viewWidth * 2 and #a.g.members > farMost then far, farMost = a.g, #a.g.members end
end
c0, d0 = created, destroyed
viewX, viewY = far.x, far.y
frame()
check(created > c0 and destroyed > d0 and culled_right(), "panning far re-fits: icons there, none left behind")
check(not shown(areas[busy.key]) and upvalue(Layers.auto_open, "open")[busy.key] == "click",
    "a clicked group out of view has no icons but stays open")
viewX, viewY = busy.x, busy.y
frame()
check(areas[busy.key].comps and #areas[busy.key].comps == most, "back in view, the clicked group is still open")

-- A while with the map open: frames with nothing changing change nothing.
local steadyMade, steadyMoved = created, moved
for _ = 1, 200 do frame() end
check(created == steadyMade and moved == steadyMoved, "an open map that doesn't move changes nothing")

-- Zoomed in when the map closes: everything regroups as the map opened (its zoom, around the player).
viewWidth = 200000 / 4
frame()
check(Layers.area_m() < level1, "zoomed in: smaller groups")
hooks[MAP_TAB .. "BP_OnMapMinimised"]()
tick()
viewWidth, viewX, viewY = 200000, player.X, player.Y
local clickedOpen = false
for _, reason in pairs(upvalue(Layers.auto_open, "open")) do if reason == "click" then clickedOpen = true end end
check(not clickedOpen and Icons.count() == closed_count(), "closing the map regroups (" .. Icons.count() .. ")")
check(Layers.area_m() == level1 and minimap_culled() and Minimap.is_shown(),
    "closing the map: its zoom, icons around the minimap's view, the minimap back")
-- Without the minimap, closing prepares the next opening (its zoom and size, around you): nothing to rebuild then.
Settings.minimap = false
Menu.on_change("minimap", nil)
check(not Minimap.exists(), "minimap off: gone")
local clockBack = placed[clockWidget:GetAddress()]
check(clockBack and clockBack.canvas == clockWidget.__props.Slot.__props.Parent and clockBack.offsets.Left == -20
    and clockBack.offsets.Right == 64 and clockBack.alignment.X == 1 and clockBack.zOrder == 3,
    "minimap off: the clock back in its HUD canvas as it was")
check(clockLookups == 1, "the clock was looked for once, when the minimap was made (" .. clockLookups .. ")")
hooks[MAP_TAB .. "BP_OnMapMaximised"]()
tick()
frame()
hooks[MAP_TAB .. "BP_OnMapMinimised"]()
tick()
check(culled_right(), "without the minimap, closing prepares the next opening")
c0 = created
hooks[MAP_TAB .. "BP_OnMapMaximised"]()
tick()
frame()
check(created == c0, "the next opening has nothing to rebuild")
check(vignettes[widget].sets == 1, "the world map's vignette is hidden once, not at every opening")
Settings.minimap = true
Menu.on_change("minimap", nil)
check(Minimap.exists() and vignettes[minimapWidget].visibility == 1, "minimap on again, its vignette hidden")
grouped = Icons.count()

-- Display switches rebuild the layers that are on.
Settings.counts = false
Menu.on_change("counts", nil)
check(Icons.count() == grouped and Layers.stats().counts == 0, "counts off: same icons, no labels")
Settings.counts, Settings.clickable = true, false
Menu.on_change("clickable", nil)
check(Layers.stats().clickable == 0 and Layers.stats().counts > 0, "clickable off")
Settings.clickable = true
Menu.on_change("clickable", nil)

-- Master switch off, the garbage collector frees the now unused textures, switch on: no freed texture may be reused.
Settings.enabled = false
Menu.on_change("enabled", nil)
check(Icons.count() == 0, "everything off: no icons")
collect()
Settings.enabled = true
Menu.on_change("enabled", nil)
check(Icons.count() == grouped, "everything on again")
check(staleTextures == 0, "no freed texture handed to an icon (" .. staleTextures .. ")")

-- Icon size and the menu.
Menu.on_change("icon_size", nil)
keys[Key.F7]()
tick()
keys[Key.F7]()
tick()

-- Changing worlds (another world, the main menu, joining someone): when the map load starts, everything of this world
-- is forgotten without being touched; the next world's HUD makes its clock before its player gets a pawn, and that
-- event must not reach the old minimap; then the new world is set up from scratch.
local touchedOld = false
local oldCanvas = placed[clockWidget:GetAddress()] and placed[clockWidget:GetAddress()].canvas
if oldCanvas then
    local add = oldCanvas.AddChildToCanvas
    oldCanvas.AddChildToCanvas = function(...) touchedOld = true return add(...) end
end
hooks.loadmappre()
check(not Minimap.exists() and Icons.count() == 0 and next(current_areas()) == nil, "a map load forgets the old world")
local nextClock = fake("WBP_HUD_DayAndNight_C (next world)", { Slot = newClockSlot })
onNew["/Game/UI/HUD/DayAndNight/WBP_HUD_DayAndNight.WBP_HUD_DayAndNight_C"](nextClock)
tick()
check(not touchedOld and placed[nextClock:GetAddress()] == nil, "the next world's clock doesn't touch the old minimap")
clockWidget = nextClock
hooks["/Script/Engine.PlayerController:ClientRestart"]({ get = function() return controller end })
tick()
check(Minimap.exists() and Icons.count() > 0 and placed[nextClock:GetAddress()] ~= nil,
    "the next world is set up from scratch, its clock on the new minimap")

-- Live state ------------------------------------------------------------------------------------------------------
local Live = require("Modules.live")
local Cluster = require("Modules.cluster")
local liveSnap = upvalue(unwrapped(Layers.update), "snap")
local function area_of(e) return current_areas()[Cluster.key(e.x, e.y, Layers.area_m() * 100)] end
local function in_area(e)
    local a = area_of(e)
    for _, m in ipairs(a and a.g.members or {}) do if m == e then return true end end
    return false
end
local function obj(name, props) return { get = function() return fake(name, props) end } end
local function class_of(cls) return function() return { GetFName = function() return { ToString = function() return cls end } end } end end
local function at(x, y, z) return function() return { X = x, Y = y, Z = z } end end
local function first(layer, test)
    for _, e in ipairs(liveSnap.layers[layer] or {}) do if Live.visible(e) and (not test or test(e)) then return e end end
end
local DOM = "/Script/Dominion."

-- Graves come from the game's registry: the save's grave stays (with its contents), a new grave appears when the game
-- makes one, and a grave gone from the registry is gone when the map opens.
check(#liveSnap.layers.graves == 1 and liveSnap.layers.graves[1].tip:find("\n", 1, true),
    "the registry's grave is the save's grave, with the save's tooltip (what's in it)")
registryGraves[2] = { Location = { X = busy.x + 3000, Y = busy.y, Z = 0 }, OwningCharDisplayName = "Visitor" }
onNew[DOM .. "Gravestone"](fake("BP_PlayerGravestone_C"))
tick()
local visitor = first("graves", function(e) return e.tip == "Grave of Visitor" end)
check(visitor and in_area(visitor), "a new grave in the registry gets an icon at once")
table.remove(registryGraves, 1)
hooks[MAP_TAB .. "BP_OnMapMaximised"]()
tick()
check(liveSnap.layers.graves[1].gone and Live.visible(visitor), "a grave gone from the registry is gone when the map opens")
hooks[MAP_TAB .. "BP_OnMapMinimised"]()
tick()

-- A harvest that leaves nothing hides the thing (its area regroups); it's back once its respawn time has passed.
Settings.layers.copper = true
Menu.on_change("layer", "copper")
local copper = first("copper")
hooks[DOM .. "BaseInteractableResource:OnInteraction"](obj("BP_OreNode_Copper", {
    GetClass = class_of(copper.class), K2_GetActorLocation = at(copper.x, copper.y, copper.z),
    RespawnComponent = fake("ResourceRespawnComponent", { ResourcesAvailable = 0 }) }))
check(Live.visible(copper), "nothing changes inside the hook")
tick()
check(not Live.visible(copper) and not in_area(copper) and copper.readyAt > Live.now(),
    "harvested to nothing: hidden until its respawn time")
timeActor.__props.StoredTime = timeActor.__props.StoredTime + 4 * 1440
hooks[MAP_TAB .. "BP_OnMapMaximised"]()
tick()
check(Live.visible(copper) and in_area(copper), "four in-game days later, the map shows it again")
hooks[MAP_TAB .. "BP_OnMapMinimised"]()
tick()

-- A chest opened is hidden; a pickup takes its item out of the pile.
Settings.layers.chests = true
Menu.on_change("layer", "chests")
local chest = first("chests")
hooks[DOM .. "WorldChest:HandleInteraction"](obj("BP_LootChest", { GetClass = class_of(chest.class),
    K2_GetActorLocation = at(chest.x, chest.y, chest.z), ChestState = 1 }))
tick()
check(not Live.visible(chest), "an opened chest is hidden")
local pile = first("items", function(e) return e.items and #e.items >= 2 end)
local before, item = #pile.items, pile.items[1]
hooks[DOM .. "RuntimeSpawnedWorldItem:HandleInteraction"](obj("BP_RuntimeSpawnedWorldItem_C", {
    ItemData = fake("ItemData", { PersistenceID = item.id }), K2_GetActorLocation = at(item.x, item.y, item.z) }))
tick()
check(#pile.items == before - 1 and Live.visible(pile), "picking up an item takes it out of its pile")

-- A new drop counts once it has lasted a few seconds (a harvest's drops fly into your bag at once).
local kept = lying_item(item.id, busy.x + 5000, busy.y + 5000, 0)
local flew = fake("BP_RuntimeSpawnedWorldItem_C")
local destroyed = lying_item(item.id, busy.x - 5000, busy.y, 0, { bActorIsBeingDestroyed = true })
onNew[DOM .. "RuntimeSpawnedWorldItem"](kept)
onNew[DOM .. "RuntimeSpawnedWorldItem"](flew)
onNew[DOM .. "RuntimeSpawnedWorldItem"](destroyed)
worldItems[#worldItems + 1] = kept      -- flew is already in your bag
worldItems[#worldItems + 1] = destroyed -- picked up too: destroyed, but still in memory until the garbage collector
local itemsBefore = #liveSnap.layers.items
skipped = skipped + 5
for _ = 1, 5 do hooks[MINIMAP .. "TickMap"]({ get = function() return minimapWidget end }) end
tick()
local keptDrop = liveSnap.layers.items[#liveSnap.layers.items]
check(#liveSnap.layers.items == itemsBefore + 1 and Live.visible(keptDrop),
    "a drop that lasted is added; one that vanished or is being destroyed isn't")

-- When the map opens, drops near you that aren't lying there any more are gone (picked up some way we didn't see).
local nearPile = first("junk")
player.X, player.Y = nearPile.x, nearPile.y
for i = #worldItems, 1, -1 do
    local p = worldItems[i]:K2_GetActorLocation()
    if (p.X - nearPile.x) ^ 2 + (p.Y - nearPile.y) ^ 2 < 500 * 500 then table.remove(worldItems, i) end
end
hooks[MAP_TAB .. "BP_OnMapMaximised"]()
tick()
check(nearPile.gone, "a drop near you that isn't lying there any more is gone when the map opens")
hooks[MAP_TAB .. "BP_OnMapMinimised"]()
tick()

-- The view can't be read (the hook gives up): every group gets icons, so nothing becomes unreachable.
viewComp.__props.GetWorldCorners = function() error("no corners") end
local problemsBefore = problems
frame()
check(problems == problemsBefore + 1, "view unreadable: logged once")
problems = problemsBefore
local s9 = Layers.stats()
check(s9.shown == s9.groups, string.format("view unreadable: every group shows (%d of %d)", s9.shown, s9.groups))

check(createdInsideHooks == 0, "no icons created or moved inside a map hook (" .. createdInsideHooks .. ")")
os.execute("rm -rf '" .. tmp .. "'")
local total = fails + problems
print(total == 0 and "[mock] OK\n" or string.format("[mock] %d failed check(s), %d problem(s) logged\n", fails, problems))
os.exit(total == 0 and 0 or 1)
