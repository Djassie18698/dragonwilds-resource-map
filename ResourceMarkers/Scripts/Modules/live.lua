local Util = require("Modules.util")
local Items = require("Modules.items")
local Saves = require("Modules.saves")
local Categories = require("Modules.categories")

-- Live state: the snapshot (world data + save) kept up to date from the game's own events.
-- The hooks in main.lua call the note_* functions, which read the plain facts at once (class, position, state: the
-- object is certainly alive inside its hook) and queue them; apply() turns the queue into entity changes at the next
-- engine tick. No game object is kept past the call that handed it over (a reference Lua holds doesn't keep it
-- alive), so new drops are noted by address and found again with one FindAllOf when they're checked.
--
-- An entity is hidden while it's used up (readyAt: the in-game time it's ready again) or gone (picked up, expired, a
-- grave no longer in the game's registry). Times are FTimespan ticks of in-game time, like the save's.
local Live = {}

local TICKS = 10000000      -- per second
local MATCH = 300           -- game units: an event and a thing of its layer within 3 m are the same thing
local ITEM_MATCH = 150      -- a dropped item and a known drop of the same item within 1.5 m are the same drop
local SETTLE = 3.0          -- seconds a new drop must last to count (harvest drops fly into your bag at once)
local NEARBY = 10000        -- game units: drops within this of the player are checked against the world on map open
local LYING = 300           -- a known drop and an item lying in the world within 3 m are the same
local FORGET = 20.0         -- pending drops older than this are dropped unchecked
local NEVER = math.huge     -- used up and nothing says when it comes back: hidden for the session

local snap, world = nil, nil
local index = {}            -- layer -> grid cell -> entities, for matching events to things
local queue = {}            -- facts noted by hooks, for apply()
local pending = {}          -- new drops: { address, at = os.clock() }
local timed = {}            -- entities with readyAt (to sweep)
local now = nil             -- in-game time of the current batch
local timeActor, registry = nil, nil  -- this world's (found once, checked before each use, forgotten on map load)

local function cell(x, y) return math.floor(x / MATCH) .. "|" .. math.floor(y / MATCH) end

local function add_index(e)
    local grid = index[e.layer]
    if not grid then grid = {} index[e.layer] = grid end
    local key = cell(e.x, e.y)
    local list = grid[key]
    if not list then list = {} grid[key] = list end
    list[#list + 1] = e
end

-- The nearest thing of this layer within MATCH of (x, y).
local function find(layer, x, y)
    local grid = index[layer]
    if not grid then return nil end
    local gx, gy = math.floor(x / MATCH), math.floor(y / MATCH)
    local best, bestD = nil, MATCH * MATCH
    for dx = -1, 1 do
        for dy = -1, 1 do
            for _, e in ipairs(grid[(gx + dx) .. "|" .. (gy + dy)] or {}) do
                local d = (e.x - x) ^ 2 + (e.y - y) ^ 2
                if not e.gone and d <= bestD then best, bestD = e, d end
            end
        end
    end
    return best
end

-- Whether a thing is on the map right now.
function Live.visible(e)
    if e.gone then return false end
    if e.readyAt then return now ~= nil and now >= e.readyAt end
    return true
end

-- Respawn time of a class (seconds of in-game time) in ticks, or nil if nothing says.
local function respawn_ticks(cls, layer)
    local s = world.respawn and world.respawn[cls] or (snap.layerRespawn and snap.layerRespawn[layer])
    return s and s * TICKS or nil
end

local function set_used(e, cls, changed)
    local d = respawn_ticks(cls, e.layer)
    e.readyAt = (d and now) and (now + d) or NEVER
    timed[e] = true
    changed[#changed + 1] = e
end

local function set_ready(e, changed)
    if not e.readyAt then return end
    e.readyAt = nil
    timed[e] = nil
    changed[#changed + 1] = e
end

-- New world: its snapshot and data (world.respawn by class). Entities that start used up are swept from now on.
function Live.attach(snapshot, worldData)
    snap, world, index, queue, pending, timed = snapshot, worldData, {}, {}, {}, {}
    for _, list in pairs(snap.layers) do
        for _, e in ipairs(list) do
            add_index(e)
            if e.readyAt then timed[e] = true end
        end
    end
end

function Live.forget()
    snap, world, index, queue, pending, timed, timeActor, registry, now = nil, nil, {}, {}, {}, {}, nil, nil, nil
end

function Live.attached() return snap ~= nil end

-- The in-game time now: the time actor's stored time plus the world time since it stored it, at its day length; the
-- save's clock if there's no time actor (yet).
local function read_clock()
    if not (timeActor and timeActor:IsValid()) then
        timeActor = FindFirstOf("InGameTimeActor")
        if not (timeActor and timeActor:IsValid()) then
            timeActor = nil
            return snap and snap.clock
        end
    end
    local minutes = timeActor.StoredTime
    local dayMinutes = timeActor.RealTimeMinutesPerInGameDay
    if not timeActor.bIsTimePaused and dayMinutes and dayMinutes > 0 then
        local t = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetTimeSeconds(timeActor)
        local since = t - timeActor.LastSyncTime
        -- The stored time is synced every few minutes; a longer gap means the times aren't what we think: stay with
        -- the stored time (minutes off at worst, against respawn times of hours).
        if since > 0 and since < 3600 then minutes = minutes + since * 1440 / (dayMinutes * 60) end
    end
    return math.floor(minutes * 60 * TICKS)
end

-- Start of a batch of changes: read the clock once.
function Live.tick()
    local ok, t = pcall(read_clock)
    now = ok and t or (snap and snap.clock)
    return now
end

function Live.now() return now end

-- Hooks: note what happened, reading it now (the object is alive inside its hook). Each returns true if it noted
-- something for apply().
local function location(obj)
    local p = obj:K2_GetActorLocation()
    return p.X, p.Y, p.Z
end

local function class_name(obj)
    return obj:GetClass():GetFName():ToString()
end

local function fstring(v)
    if v == nil or type(v) == "string" then return v end
    return v:ToString()
end

-- A resource was harvested (or, on a guest, its state replicated): used up if nothing's left.
function Live.note_resource(obj)
    if not snap then return false end
    local comp = obj.RespawnComponent
    if not (comp and comp:IsValid()) then return false end
    local x, y = location(obj)
    queue[#queue + 1] = { kind = "resource", cls = class_name(obj), x = x, y = y, left = comp.ResourcesAvailable }
    return true
end

-- A rock, tree or sapling was destroyed. (Ore nodes aren't destroyed and have no event of their own for running out:
-- they follow the save and their respawn time.)
function Live.note_destroyed(obj)
    if not snap then return false end
    local x, y = location(obj)
    queue[#queue + 1] = { kind = "resource", cls = class_name(obj), x = x, y = y, left = 0 }
    return true
end

function Live.note_chest(obj)
    if not snap then return false end
    local x, y = location(obj)
    queue[#queue + 1] = { kind = "chest", cls = class_name(obj), x = x, y = y, opened = (obj.ChestState or 0) ~= 0 }
    return true
end

local function item_id(obj)
    local data = obj.ItemData
    if not (data and data:IsValid()) then return nil end
    return fstring(data.PersistenceID)
end

function Live.note_pickup(obj)
    if not snap then return false end
    local x, y, z = location(obj)
    queue[#queue + 1] = { kind = "pickup", id = item_id(obj), x = x, y = y, z = z }
    return true
end

-- Whether an item from FindAllOf is really lying there: a destroyed actor stays in memory (and in FindAllOf) until
-- the garbage collector runs, and one flying to a player is as good as picked up.
local function lying(obj)
    if not obj:IsValid() or obj.bActorIsBeingDestroyed or obj.bHidden then return false end
    local magnet = obj:GetMagneticComponent()
    if magnet and magnet:IsValid() then
        local target = magnet.Target
        if target and target:IsValid() then return false end
    end
    return true
end

-- A new dropped item (also one loaded with its area): checked once it has lasted SETTLE seconds.
function Live.note_spawn(obj)
    if not snap then return false end
    pending[#pending + 1] = { address = obj:GetAddress(), at = os.clock() }
    return false
end

function Live.note_graves()
    if not snap then return false end
    queue[#queue + 1] = { kind = "graves" }
    return true
end

-- Whether new drops are waiting to be checked (pure Lua: callable from a hook).
function Live.settle_due()
    local first = pending[1]
    return first ~= nil and os.clock() - first.at >= SETTLE
end

-- Drops ---------------------------------------------------------------------------------------------------------

local function drop_label(e)
    local category = Categories.get(e.layer)
    e.label, e.icon = category.label, category.icon
    e.tip = Saves.pile_tip(e.items)
end

-- The known drop holding this item (same item within ITEM_MATCH), and the item's index in it.
local function find_item(id, x, y)
    for _, layer in ipairs({ "items", "junk" }) do
        local grid = index[layer]
        if grid then
            local gx, gy = math.floor(x / MATCH), math.floor(y / MATCH)
            for dx = -2, 2 do
                for dy = -2, 2 do
                    for _, e in ipairs(grid[(gx + dx) .. "|" .. (gy + dy)] or {}) do
                        if not e.gone then
                            for i, it in ipairs(e.items or {}) do
                                if (id == nil or it.id == id) and (it.x - x) ^ 2 + (it.y - y) ^ 2 <= ITEM_MATCH * ITEM_MATCH then
                                    return e, i
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function remove_item(e, i, changed)
    table.remove(e.items, i)
    if #e.items == 0 then e.gone = true else drop_label(e) end
    changed[#changed + 1] = e
end

-- New drops that lasted: added (unless it's one we know, e.g. a saved drop whose area just loaded).
local function settle(changed, added)
    local older, keep = {}, {}
    local clock = os.clock()
    for _, p in ipairs(pending) do
        local age = clock - p.at
        if age >= FORGET then
            -- too old to trust its address any more
        elseif age >= SETTLE then
            older[#older + 1] = p
        else
            keep[#keep + 1] = p
        end
    end
    pending = keep
    if #older == 0 then return end
    local byAddress = {}
    Util.each(FindAllOf("RuntimeSpawnedWorldItem") or {}, function(_, obj)
        if lying(obj) then byAddress[obj:GetAddress()] = obj end
    end)
    for _, p in ipairs(older) do
        local obj = byAddress[p.address]
        if obj then
            local id = item_id(obj)
            local x, y, z = location(obj)
            if id and not find_item(id, x, y) then
                local expires = obj.bCanExpire and obj.ExpirationTimeInGameEndTicks or nil
                local it = { id = id, x = x, y = y, z = z, count = 1, expiresAt = expires and expires > 0 and expires or nil }
                local e = { layer = Items.isJunk(id) and "junk" or "items", x = x, y = y, z = z, items = { it } }
                drop_label(e)
                local list = snap.layers[e.layer]
                if not list then list = {} snap.layers[e.layer] = list end
                list[#list + 1] = e
                add_index(e)
                added[#added + 1] = e
            end
        end
    end
end

-- Graves: the game's registry is the truth (it's what its own map shows, and guests have it too). A grave the save
-- also has keeps the save's tooltip (what's in it).
local function read_graves()
    if not (registry and registry:IsValid()) then
        registry = FindFirstOf("GameplayObjectRegistry")
        if not (registry and registry:IsValid()) then
            registry = nil
            return nil
        end
    end
    local list = {}
    Util.each(registry.Gravestones, function(_, g)
        local loc = g.Location
        if loc.X == nil then loc = loc:get() end
        list[#list + 1] = { x = loc.X, y = loc.Y, z = loc.Z, name = fstring(g.OwningCharDisplayName) }
    end)
    return list
end

local function refresh_graves(changed, added)
    local ok, list = pcall(read_graves)
    if not ok or not list then return end
    local category = Categories.get("graves")
    local old = snap.layers.graves or {}
    local keep, matched = {}, {}
    for _, g in ipairs(list) do
        local found
        for _, e in ipairs(old) do
            if not e.gone and not matched[e] and (e.x - g.x) ^ 2 + (e.y - g.y) ^ 2 <= MATCH * MATCH then found = e break end
        end
        if found then
            matched[found] = true
        else
            local e = { layer = "graves", x = g.x, y = g.y, z = g.z, label = category.label, icon = category.icon,
                        tip = (g.name and g.name ~= "") and ("Grave of " .. g.name) or "Grave" }
            old[#old + 1] = e
            add_index(e)
            added[#added + 1] = e
            matched[e] = true
        end
    end
    for _, e in ipairs(old) do
        if not matched[e] and not e.gone then
            e.gone = true
            changed[#changed + 1] = e
        end
    end
    snap.layers.graves = old
end

-- The queued events, applied: returns the entities that changed and the ones that are new.
function Live.apply()
    local changed, added = {}, {}
    if not snap then return changed, added end
    Live.tick()
    local list = queue
    queue = {}
    local graves = false
    for _, q in ipairs(list) do
        if q.kind == "resource" or q.kind == "chest" then
            local layer = world.classCats and world.classCats[q.cls]
            local e = layer and find(layer, q.x, q.y)
            if e then
                local used = (q.kind == "chest" and q.opened) or (q.kind == "resource" and (q.left or 1) <= 0)
                if used then set_used(e, q.cls, changed) else set_ready(e, changed) end
            end
        elseif q.kind == "pickup" then
            local e, i = find_item(q.id, q.x, q.y)
            if e then remove_item(e, i, changed) end
        elseif q.kind == "graves" then
            graves = true
        end
    end
    if Live.settle_due() then settle(changed, added) end
    if graves then refresh_graves(changed, added) end
    return changed, added
end

-- Drops near the player (p) that aren't lying in the world any more: picked up some way we didn't see (a magnet, a
-- guest), or despawned. Only near the player, where the world is loaded.
local function check_drops(p, changed)
    local lyingItems = {}
    Util.each(FindAllOf("RuntimeSpawnedWorldItem") or {}, function(_, obj)
        if lying(obj) then
            local x, y = location(obj)
            lyingItems[#lyingItems + 1] = { id = item_id(obj), x = x, y = y }
        end
    end)
    for _, layer in ipairs({ "items", "junk" }) do
        for _, e in ipairs(snap.layers[layer] or {}) do
            if not e.gone and e.items and (e.x - p.x) ^ 2 + (e.y - p.y) ^ 2 <= NEARBY * NEARBY then
                for i = #e.items, 1, -1 do
                    local it, found = e.items[i], false
                    for _, l in ipairs(lyingItems) do
                        if l.id == it.id and (l.x - it.x) ^ 2 + (l.y - it.y) ^ 2 <= LYING * LYING then found = true break end
                    end
                    if not found then remove_item(e, i, changed) end
                end
            end
        end
    end
end

-- When the map opens: what came back (respawn time passed), drops that expired or aren't there any more (near the
-- player, p), the registry's graves.
function Live.sweep(p)
    local changed, added = {}, {}
    if not snap then return changed, added end
    Live.tick()
    if now then
        for e in pairs(timed) do
            if e.readyAt ~= NEVER and now >= e.readyAt then set_ready(e, changed) end
        end
        for _, layer in ipairs({ "items", "junk" }) do
            for _, e in ipairs(snap.layers[layer] or {}) do
                if not e.gone and e.items then
                    for i = #e.items, 1, -1 do
                        local at = e.items[i].expiresAt
                        if at and now >= at then remove_item(e, i, changed) end
                    end
                end
            end
        end
    end
    settle(changed, added)
    if p then pcall(check_drops, p, changed) end
    refresh_graves(changed, added)
    return changed, added
end

return Live
