local Util = require("Modules.util")
local Categories = require("Modules.categories")
local Settings = require("Modules.settings")
local Icons = require("Modules.icons")
local Items = require("Modules.items")
local Saves = require("Modules.saves")
local Snapshot = require("Modules.snapshot")
local Cluster = require("Modules.cluster")
local Live = require("Modules.live")
--DEBUG local Debug = require("Modules.debug")

-- Turns the world snapshot into map icons. Things from every layer that's on (your drops, graves and storage as much as
-- ores or plants) are grouped per area: a group is a row of icons hugging each other, one per kind in it
-- (rarest first), each labelled with its count; more than ROW_MAX kinds continue in another row below. The area size
-- follows the map's zoom (set_scale) so groups don't overlap on screen; it steps in doublings, and crossing a step
-- regroups.
-- Culling: only groups with things in and around the map's view have icons (set_view, cull), because the map spends
-- time on every icon that exists, on screen or not. The other groups are kept as data and get icons when the view
-- comes near.
-- Clicking a group shows every thing in it where it really is, until the map closes. Groups with a thing near the
-- player open by themselves, when the map opens and, with the minimap, as the player walks.
-- Live state: only things that are there right now count (Live.visible: not used up, picked up or gone); when some
-- change, only their areas regroup (update).
-- Callers run click(), auto_open(), relayout(), refresh(), cull() and map_closed() at an engine tick, never inside the
-- map's update.
local Layers = {}

-- Our icons draw under the game's own (lodestones, markers, players: z-order 0 and up), so those stay on top and take
-- the hover and the clicks where they overlap. Rows take Z_WORLD to Z_WORLD + 3; in an open group, your own things
-- (drops, graves, storage) draw above world things.
local Z_WORLD, Z_MINE = -10, -5
local NEAR = 2 / 3     -- groups with a thing within this share of the group distance from the player open by
                       -- themselves (100 m with the default 150 m), at the zoom the map opens with or closer...
local NEAR_STAY = NEAR * 1.25 -- ...and stay open until none is within this much (so walking along the edge doesn't
                              -- flip them). Zoomed out further, groups span too much to open: everything stays grouped.
local NEAR_BUDGET = 300 -- things shown one by one around the player at most: the nearest groups open first (every icon
                        -- costs the map time each frame; with many layers on, a forest is thousands of things)
local HUG = 0.7        -- icons in a row step by this share of an icon's width (textures have padding, so they don't touch)
local ROW_MAX = 4      -- icons per row at most; more kinds start another row below
local ROW_STEP = 1.4   -- rows are this many icon heights apart (so each row reads as its own group)
local HYSTERESIS = 0.14 -- the zoom must pass a level's band by this much (log2 of 1.1) before the area size steps
local MARGIN = 0.25    -- icons cover the view plus this share of it on each side, so small pans change nothing
local DEFAULT_VIEW = 125000 -- view width (game units) assumed until the map has been opened (it opens ~1232 m across)
local ASPECT = 9 / 16  -- view height / width assumed with it

local level = nil      -- area size in game units chosen for the map's zoom (nil: the group distance itself)
local refUnit = nil    -- game units per screen unit at the zoom the map first opened with (the group distance's zoom)
local function area_size() return level or Settings.group_m * 100 end

local world    -- data/world.lua, loaded once
local foliage  -- data/foliage.lua, loaded once (false: none)
local snap   -- Snapshot.build() for the current world
local areas = {}   -- area key -> { g, icons = row | nil, slots, comps = things | nil }; no icons at all = culled
local cells = {}   -- area key -> every thing of the layers that are on in that cell, there or not, in group order
local rank = {}    -- layer id -> its place in group order (rarest layer first), as of the last build
local owners = {}  -- row icon address -> area key (for clicks)
local open = {}    -- area key -> "click" (until the map closes) | "auto" (around the player); kept while culled
local spacing = 1000 -- game units between icons in a row; follows the map's zoom (set_scale)
local rowStep = 1750 -- game units between rows
local view = nil     -- the map's view { x0, y0, x1, y1 }: as last seen, or a guess around the player
local live = nil     -- groups centred inside this rect have icons; nil = every group
local opening = nil  -- the map on its first frame the last time it opened: { level, spacing, rowStep, w, h }
local builtSize = nil -- the area size the groups were last built with

-- The map data is extracted from one game build (its stamp: the size of the game's main container file). A game
-- update can move or add things, so a different container is worth one line in the log.
local function check_game(stamp)
    if not (stamp and stamp.utoc_size) then return end
    local f = io.open(Util.mod_dir() .. "/../../../../../Content/Paks/RSDragonwilds-Windows.utoc", "rb")
    if not f then return end
    local size = f:seek("end")
    f:close()
    if size ~= stamp.utoc_size then
        Util.log("The game was updated after this map data was made (game build %s): new or moved things may be "
            .. "missing until the data is rebuilt (tools/extract)", tostring(stamp.buildid or "?"))
    end
end

local function load_world()
    if world then return world end
    local ok, data = pcall(dofile, Util.mod_dir() .. "/data/world.lua")
    world = ok and data or { classes = {}, cats = {}, classCats = {} }
    if not ok then Util.log("data/world.lua: %s", tostring(data)) end
    check_game(world.game)
    return world
end

local function load_foliage()
    if foliage == nil then
        local ok, data = pcall(dofile, Util.mod_dir() .. "/data/foliage.lua")
        foliage = ok and data or false
        if not ok then Util.log("data/foliage.lua: %s", tostring(data)) end
    end
    return foliage or nil
end

-- This world's save slot: settings.txt's world_save if set, else the game's own record of the loaded world (its
-- persistence subsystem's WorldSlotName; context: any object in the world). Only a host or single player has the
-- world's save, so a guest gets none; so does a world that hasn't been saved yet (its file doesn't exist).
local function save_slot(context)
    if Settings.world_save ~= "" then return Settings.world_save end
    local ok, slot = pcall(function()
        if not StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):IsServer(context) then return nil end
        local persistence = StaticFindObject("/Script/Engine.Default__SubsystemBlueprintLibrary")
            :GetGameInstanceSubsystem(context, StaticFindObject("/Script/Dominion.PersistenceSubsystem"))
        if not (persistence and persistence:IsValid()) then return nil end
        local name = persistence.WorldSaveSettings.WorldSlotName
        return type(name) == "string" and name or name:ToString()
    end)
    return ok and slot and slot ~= "" and slot or nil
end
Layers.save_slot = save_slot

-- The world's save, parsed; nil for a guest or a world without a save yet (map data and live state only then).
local function read_save(context)
    local slot = save_slot(context)
    --DEBUG Debug.log("save slot: %s", tostring(slot))
    if not slot then return nil end
    local dir = Util.saved_dir()
    if not dir then
        Util.log("No Saved folder (LOCALAPPDATA isn't set), so no save is read")
        return nil
    end
    local path = dir .. "SaveGames\\" .. slot .. ".sav"
    local data = Util.read_file(path)
    if not data then return nil end -- not saved yet
    local ok, result = pcall(Saves.parse, data)
    if not ok then
        Util.log("Could not read %s: %s", path, tostring(result))
        return nil
    end
    return result
end

local function make(spec, owner)
    local comp = Icons.make(spec)
    if comp and owner then owners[comp:GetAddress()] = owner end
    return comp
end

local function drop(comp)
    if comp then
        owners[comp:GetAddress()] = nil
        Icons.destroy(comp)
    end
end

local function drop_all(comps)
    for _, comp in ipairs(comps or {}) do drop(comp) end
end

local function make_thing(e)
    local category = Categories.get(e.layer)
    return make({ x = e.x, y = e.y, z = e.z, texture = Icons.texture(e.icon), tip = e.tip, color = category.color,
                  zorder = category.static and Z_WORLD or Z_MINE })
end

-- Where the icon in a group's slot ({ col, cols, row, rows }) goes, around the group's centre.
local function slot_xy(g, slot)
    return g.x + (slot.col - (slot.cols + 1) / 2) * spacing, g.y + (slot.row - (slot.rows + 1) / 2) * rowStep
end

-- A group as rows of icons, one per kind (members come rarest kind first), each labelled with its count, at most
-- ROW_MAX per row. Within a row the left icon is drawn on top, so each icon's count (lower right) stays visible over
-- its neighbour. A thing that's alone keeps its own position and tooltip. Returns icons and their slots.
local function make_group(g)
    if #g.members == 1 then return { make_thing(g.members[1]) }, nil end
    local kinds, byLayer = {}, {}
    for _, e in ipairs(g.members) do
        local k = byLayer[e.layer]
        if not k then
            k = { first = e, n = 0 }
            byLayer[e.layer] = k
            kinds[#kinds + 1] = k
        end
        k.n = k.n + 1
    end
    local rows = math.ceil(#kinds / ROW_MAX)
    local icons, slots = {}, {}
    for i, k in ipairs(kinds) do
        local row = math.ceil(i / ROW_MAX)
        local cols = row < rows and ROW_MAX or #kinds - (rows - 1) * ROW_MAX
        local slot = { col = i - (row - 1) * ROW_MAX, cols = cols, row = row, rows = rows }
        local x, y = slot_xy(g, slot)
        local e = k.first
        local category = Categories.get(e.layer)
        local tip = k.n > 1 and string.format("%s \u{00D7}%d", e.label, k.n) or e.tip
        icons[i] = make({ x = x, y = y, z = g.z, texture = Icons.texture(e.icon), tip = tip,
                          label = (Settings.counts and k.n > 1) and tostring(k.n) or "", color = category.color,
                          zorder = Z_WORLD + ROW_MAX - slot.col, interactable = Settings.clickable }, g.key)
        slots[i] = slot
    end
    return icons, slots
end

local function around(p, w, h)
    return { x0 = p.x - w / 2, y0 = p.y - h / 2, x1 = p.x + w / 2, y1 = p.y + h / 2 }
end

-- The rect whose groups get icons: the view and a margin around it (nil without a view: every group).
local function fit_live()
    if not view then
        live = nil
        return
    end
    local mx, my = (view.x1 - view.x0) * MARGIN, (view.y1 - view.y0) * MARGIN
    live = { x0 = view.x0 - mx, y0 = view.y0 - my, x1 = view.x1 + mx, y1 = view.y1 + my }
end

-- Whether any of a group's things can be in the rect (its bounds overlap it; a closed group's row sits inside them).
local function in_live(g)
    return not live or (g.x1 >= live.x0 and g.x0 <= live.x1 and g.y1 >= live.y0 and g.y0 <= live.y1)
end

local function shown(a)
    return a.icons ~= nil or a.comps ~= nil
end

-- An area's icons as its state says: every thing in it if it's open, else its group.
local function show(key)
    local a = areas[key]
    if open[key] then
        a.comps = {}
        for _, e in ipairs(a.g.members) do a.comps[#a.comps + 1] = make_thing(e) end
    else
        a.icons, a.slots = make_group(a.g)
    end
end

local function hide(key)
    local a = areas[key]
    drop_all(a.icons)
    drop_all(a.comps)
    a.icons, a.slots, a.comps = nil, nil, nil
end

-- Open or close an area; its icons change only if it has any (a culled area comes back as it was left).
local function set_open(key, reason)
    local was = open[key]
    open[key] = reason
    if not was and shown(areas[key]) then
        hide(key)
        show(key)
    end
end

local function set_closed(key)
    local was = open[key]
    open[key] = nil
    if was and areas[key] and shown(areas[key]) then
        hide(key)
        show(key)
    end
end

-- Groups for every layer that's on, rarest kinds first (a row lists kinds in member order). Groups that were open stay
-- open if the area size is the same (an area key names the same grid cell then).
local function build_world_icons()
    for key, a in pairs(areas) do
        if shown(a) then hide(key) end
    end
    areas = {}
    if area_size() ~= builtSize then open = {} end
    builtSize = area_size()
    fit_live()
    local layers = {}
    for _, category in ipairs(Categories) do
        if Settings.layer_on(category.id) and snap.layers[category.id] then
            layers[#layers + 1] = { id = category.id, list = snap.layers[category.id] }
        end
    end
    table.sort(layers, function(a, b) return #a.list < #b.list end)
    local all, size = {}, area_size()
    cells, rank = {}, {}
    for r, layer in ipairs(layers) do
        rank[layer.id] = r
        for _, e in ipairs(layer.list) do
            local key = Cluster.key(e.x, e.y, size)
            local c = cells[key]
            if not c then c = {} cells[key] = c end
            c[#c + 1] = e
            if Live.visible(e) then all[#all + 1] = e end
        end
    end
    for _, g in ipairs(Cluster.merge(all, size)) do
        areas[g.key] = { g = g }
        if in_live(g) then show(g.key) end
    end
end

-- What a clicked icon is: its area key (nil if it isn't one of our groups).
function Layers.clicked(comp)
    return owners[comp:GetAddress()]
end

-- Show every thing in a clicked group (one opened by being near the player stays open from now on).
function Layers.click(key)
    local a = areas[key]
    if not a or #a.g.members < 2 then return end
    if open[key] then
        open[key] = "click"
        return
    end
    Icons.fresh()
    set_open(key, "click")
end

-- How far a point is from a group's nearest thing, as far as its bounds tell (0 inside them).
local function distance_to(g, p)
    local dx = math.max(g.x0 - p.x, 0, p.x - g.x1)
    local dy = math.max(g.y0 - p.y, 0, p.y - g.y1)
    return math.sqrt(dx * dx + dy * dy)
end

-- The areas that should be open around these points ({ x, y }): groups with a thing within NEAR of the group distance
-- (a fixed distance in the world, whatever the zoom), or NEAR_STAY for ones already open that way; none when zoomed out
-- beyond the group distance. Nearest first, while fewer than NEAR_BUDGET things are open (an open group counts a bit
-- nearer, so two groups at the budget's edge don't take turns). A group's things are all in its grid cell, so the cells
-- within reach of a point cover it.
local function near_wanted(points)
    local want = {}
    local base, size = Settings.group_m * 100, area_size()
    if size > base then return want end
    local span = math.ceil(base * NEAR_STAY / size) + 1
    local candidates, seen = {}, {}
    for _, p in ipairs(points) do
        local cx, cy = math.floor(p.x / size), math.floor(p.y / size)
        for dx = -span, span do
            for dy = -span, span do
                local key = Cluster.key((cx + dx + 0.5) * size, (cy + dy + 0.5) * size, size)
                local a = areas[key]
                if a and not seen[key] and #a.g.members >= 2 then
                    local isOpen = open[key] == "auto"
                    local d = distance_to(a.g, p)
                    if d <= base * (isOpen and NEAR_STAY or NEAR) then
                        seen[key] = true
                        candidates[#candidates + 1] = { key = key, rank = isOpen and d * 0.8 or d, n = #a.g.members }
                    end
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.rank < b.rank end)
    local total = 0
    for _, c in ipairs(candidates) do
        if total >= NEAR_BUDGET then break end
        want[c.key] = true
        total = total + c.n
    end
    return want
end

-- Areas near these points (the player) open by themselves; ones opened that way that are no longer near close again.
-- Clicked groups stay open.
function Layers.auto_open(points)
    if not (Icons.ready() and snap) then return end
    local want = near_wanted(points)
    Icons.fresh()
    local closing = {}
    for key, reason in pairs(open) do
        if reason == "auto" and not want[key] then closing[#closing + 1] = key end
    end
    for _, key in ipairs(closing) do set_closed(key) end
    for key in pairs(want) do
        if not open[key] then set_open(key, "auto") end
    end
end

-- The group distance setting changed: regroup now at the new distance (what the map's opening zoom shows); other
-- zooms follow from it when the map reads its zoom.
function Layers.group_distance_changed()
    level = nil
    if opening then opening.level = nil end
    Layers.refresh()
end

-- The map's scale: how many game units one screen unit covers. The area size is the group distance at the zoom the map
-- opened with, doubled for each doubling of the zoom out and halved for each one in (down to a quarter of it), so
-- groups keep their size on screen. Returns "regroup" when the area size should step (the zoom left the level's band
-- by more than a tenth, so it doesn't flicker), "relayout" when only the rows' spacing changed by more than a tenth,
-- or nil.
function Layers.set_scale(worldPerUnit)
    if not worldPerUnit or worldPerUnit <= 0 then return nil end
    local icon = (Settings.icon_size or 24) * worldPerUnit
    refUnit = refUnit or worldPerUnit
    local smallest = Settings.group_m * 100 / 4
    local k = math.max(0, math.log(Settings.group_m * 100 * worldPerUnit / refUnit / smallest, 2))
    local result = nil
    if not level or math.abs(k - math.log(level / smallest, 2)) > 0.5 + HYSTERESIS then
        local step = smallest * 2 ^ math.floor(k + 0.5)
        if step ~= area_size() then result = "regroup" end
        level = step
    end
    local hug = HUG * icon
    if math.abs(hug - spacing) > spacing * 0.1 then
        spacing, rowStep = hug, ROW_STEP * icon
        result = result or "relayout"
    end
    return result
end

-- The map's view this frame (game units; nil if it can't be read). Returns true when the icons should be re-fitted:
-- the view left the rect they cover, or is under a third of it (zoomed in), or can't be read while groups are culled.
-- first: the map's first frame since it opened (how it opens is remembered for map_closed).
function Layers.set_view(x0, y0, x1, y1, first)
    if not x0 then
        view = nil
        return live ~= nil
    end
    view = view or {}
    view.x0, view.y0, view.x1, view.y1 = x0, y0, x1, y1
    if first then opening = { level = level, spacing = spacing, rowStep = rowStep, w = x1 - x0, h = y1 - y0 } end
    if not live then return true end
    return x0 < live.x0 or y0 < live.y0 or x1 > live.x1 or y1 > live.y1 or (x1 - x0) * 3 < live.x1 - live.x0
end

-- Rows spaced for another map's scale (the minimap: its game units per screen unit and icon scale), the area size
-- unchanged. Returns "relayout" when the spacing changed by more than a tenth.
function Layers.set_row_scale(worldPerUnit, iconScale)
    if not worldPerUnit or worldPerUnit <= 0 then return nil end
    local icon = (Settings.icon_size or 24) * (iconScale or 1) * worldPerUnit
    if math.abs(HUG * icon - spacing) > spacing * 0.1 then
        spacing, rowStep = HUG * icon, ROW_STEP * icon
        return "relayout"
    end
    return nil
end

-- Whether auto_open at the player (x, y) would open or close anything. Pure Lua: callable from a hook.
function Layers.near_changed(x, y)
    local want = near_wanted({ { x = x, y = y } })
    for key in pairs(want) do
        if not open[key] then return true end
    end
    for key, reason in pairs(open) do
        if reason == "auto" and not want[key] then return true end
    end
    return false
end

-- Icons for the groups around the view: groups that came near get theirs, groups that went far lose theirs.
function Layers.cull()
    if not (Icons.ready() and snap) then return end
    Icons.fresh()
    fit_live()
    for key, a in pairs(areas) do
        local near = in_live(a.g)
        if near and not shown(a) then
            show(key)
        elseif not near and shown(a) then
            hide(key)
        end
    end
end

-- Map closed: clicked groups close (ones open because the player is near stay open), and the icons are fitted around
-- the player: to how the map opened last time (that's how it opens, so the next opening has nothing to rebuild), or to
-- size ({ w, h }: the minimap's view) if given.
function Layers.map_closed(p, size)
    if not (Icons.ready() and snap) then return end
    Icons.fresh()
    local respace = false
    if opening and p then
        if (opening.level or Settings.group_m * 100) ~= area_size() then
            level, spacing, rowStep = opening.level, opening.spacing, opening.rowStep
            view = around(p, size and size.w or opening.w, size and size.h or opening.h)
            build_world_icons()
            return
        end
        respace = opening.spacing ~= spacing
        spacing, rowStep = opening.spacing, opening.rowStep
        view = around(p, size and size.w or opening.w, size and size.h or opening.h)
    elseif p and size then
        view = around(p, size.w, size.h)
    end
    fit_live()
    local keys = {}
    for key, reason in pairs(open) do
        if reason == "click" then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do
        open[key] = nil
        local a = areas[key]
        if a and shown(a) then
            hide(key)
            if in_live(a.g) then show(key) end
        end
    end
    if respace then Layers.relayout() end
    Layers.cull()
end

function Layers.area_m()
    return area_size() / 100
end

-- Move every row's icons to the current spacing (icons are moved, not recreated).
function Layers.relayout()
    for _, a in pairs(areas) do
        if a.icons and a.slots then
            for i, comp in ipairs(a.icons) do
                local x, y = slot_xy(a.g, a.slots[i])
                Icons.move(comp, x, y, a.g.z)
            end
        end
    end
end

function Layers.row_spacing()
    return spacing
end

-- Our icons right now (for the tests).
function Layers.stats()
    local s = { icons = Icons.count(), counts = 0, clickable = 0, areas = 0, groups = 0, shown = 0 }
    for _ in pairs(owners) do
        if Settings.counts then s.counts = s.counts + 1 end
        if Settings.clickable then s.clickable = s.clickable + 1 end
    end
    for _ in pairs(open) do s.areas = s.areas + 1 end
    for _, a in pairs(areas) do
        s.groups = s.groups + 1
        if shown(a) then s.shown = s.shown + 1 end
    end
    return s
end

-- New world: read its save once (context: any object in the world), build the snapshot, and make icons for every
-- layer that's on: world groups only around near (the player; the map opens on them), as big as the map opened last
-- time or a guess.
function Layers.build_world(near, context)
    --DEBUG local t0 = os.clock()
    local saved = read_save(context)
    --DEBUG Debug.log("save read at %.0f ms (%s)", Debug.ms(t0), saved and "found" or "none")
    snap = Snapshot.build(saved, load_world(), load_foliage())
    --DEBUG Debug.log("snapshot at %.0f ms", Debug.ms(t0))
    Live.attach(snap, load_world())
    Live.tick()
    areas, owners, open, builtSize = {}, {}, {}, nil
    view = near and around(near, opening and opening.w or DEFAULT_VIEW, opening and opening.h or DEFAULT_VIEW * ASPECT)
    Icons.fresh()
    build_world_icons()
    --DEBUG Debug.log("world icons at %.0f ms: %d", Debug.ms(t0), Icons.count())
end

-- Things changed (used up, back, picked up, expired) or are new (drops, graves): only their areas regroup. A culled
-- area stays culled (its group is ready for when the view comes near).
function Layers.update(changed, added)
    if not (Icons.ready() and snap) then return end
    local size, dirty = builtSize or area_size(), {} -- the size the cells were built with
    for _, e in ipairs(added or {}) do
        if Settings.layer_on(e.layer) then
            local key = Cluster.key(e.x, e.y, size)
            local c = cells[key]
            if not c then c = {} cells[key] = c end
            local r = rank[e.layer] or 0
            local at = #c + 1
            for i, o in ipairs(c) do
                if (rank[o.layer] or 0) > r then at = i break end
            end
            table.insert(c, at, e)
            dirty[key] = true
        end
    end
    for _, e in ipairs(changed or {}) do
        if Settings.layer_on(e.layer) then dirty[Cluster.key(e.x, e.y, size)] = true end
    end
    if not next(dirty) then return end
    Icons.fresh()
    for key in pairs(dirty) do
        local members = {}
        for _, e in ipairs(cells[key] or {}) do
            if Live.visible(e) then members[#members + 1] = e end
        end
        local a = areas[key]
        if a and shown(a) then hide(key) end
        if #members == 0 then
            areas[key] = nil
        else
            local g = Cluster.merge(members, size)[1]
            areas[key] = { g = g }
            if in_live(g) then show(key) end
        end
    end
end

-- Rebuild the groups of every layer that's on: after a layer or display setting changed, or the zoom stepped to another
-- area size (groups open by click close then; areas near the player are the caller's to reopen).
function Layers.refresh()
    if not (Icons.ready() and snap) then return end
    Icons.fresh()
    build_world_icons()
end

-- The world is going away (a map load): forget all of it without touching it.
function Layers.forget()
    snap, areas, cells, owners, open, builtSize, view, live = nil, {}, {}, {}, {}, nil, nil, nil
end

function Layers.init()
    Items.load(Util.mod_dir() .. "/data/items.lua")
    load_world()
end

return Layers
