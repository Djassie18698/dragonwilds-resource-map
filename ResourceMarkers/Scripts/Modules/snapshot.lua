-- One snapshot of the world: every placed thing from the world data and every plant and tree of the game's
-- interactable foliage (data/foliage.lua), merged with what the save knows about them, plus the save's own things
-- (drops, graves, storage). All state is as of the save's in-game clock.
-- Pure Lua (no UE4SS calls), so tests can check it against a fixture save.
--
-- entity = { layer, class, x, y, z, label, icon, tip, state?, readyAt?, items? }
--   state (resources) = { available, max, changed, spawned }    -- max: the most seen for this class in the save
--   state (chests)    = { opened, openedAt }
--   readyAt: used up (nothing left, chest opened): the in-game time it's back (when it changed + its class's respawn
--            time from world.respawn; math.huge if nothing says). Live.lua keeps it current.
--   items (drops): the pile's items { id, x, y, z, count, durability, expiresAt }

local Categories = require("Modules.categories")

local Snapshot = {}

local TICKS = 10000000 -- FTimespan ticks per second (all in-game times)
local MATCH = 500 -- game units: a saved actor and a world-data point within 5 m are the same thing

local function index(byClass)
    local idx = {}
    for cls, list in pairs(byClass or {}) do
        local grid = {}
        for _, e in ipairs(list) do
            local key = math.floor(e.x / MATCH) .. "|" .. math.floor(e.y / MATCH)
            local cell = grid[key]
            if not cell then cell = {} grid[key] = cell end
            cell[#cell + 1] = e
        end
        idx[cls] = grid
    end
    return idx
end

-- Nearest saved entry of this class within MATCH; marks it used so leftovers can be added on their own.
local function take(idx, cls, x, y)
    local grid = idx[cls]
    if not grid then return nil end
    local gx, gy = math.floor(x / MATCH), math.floor(y / MATCH)
    local best, bestD = nil, MATCH * MATCH
    for dx = -1, 1 do
        for dy = -1, 1 do
            for _, e in ipairs(grid[(gx + dx) .. "|" .. (gy + dy)] or {}) do
                local d = (e.x - x) ^ 2 + (e.y - y) ^ 2
                if not e.used and d < bestD then best, bestD = e, d end
            end
        end
    end
    if best then best.used = true end
    return best
end

-- The respawn time most classes of each layer have (seconds): for foliage, which the save knows only as the actor it
-- turned into, of a class that may not be in world.respawn.
local function layer_respawn(world)
    local counts = {}
    for cls, s in pairs(world.respawn or {}) do
        local id = world.classCats and world.classCats[cls]
        if id then
            counts[id] = counts[id] or {}
            counts[id][s] = (counts[id][s] or 0) + 1
        end
    end
    local out = {}
    for id, c in pairs(counts) do
        local best, n = nil, 0
        for s, k in pairs(c) do
            if k > n or (k == n and s > best) then best, n = s, k end
        end
        out[id] = best
    end
    return out
end

-- saved: Saves.parse() result (or nil: world data only). world: data/world.lua. foliage: data/foliage.lua (or nil).
function Snapshot.build(saved, world, foliage)
    local snap = { clock = saved and saved.clock, worldName = saved and saved.worldName, host = saved and saved.host,
                   layers = {}, counts = { empty = 0, partial = 0, opened = 0, saveOnly = 0 },
                   layerRespawn = layer_respawn(world) }
    local respawn = world.respawn or {}

    -- When a used-up thing is back: when it changed plus its respawn time.
    local function ready_at(category, cls, state)
        if not state then return nil end
        local s = respawn[cls] or snap.layerRespawn[category.id]
        if state.available ~= nil and state.available <= 0 then
            return (s and state.changed and state.changed > 0) and (state.changed + s * TICKS) or math.huge
        elseif state.opened then
            return (s and state.openedAt) and (state.openedAt + s * TICKS) or math.huge
        end
        return nil
    end
    for _, byClass in ipairs({ saved and saved.resources or {}, saved and saved.chests or {} }) do
        for _, list in pairs(byClass) do
            for _, e in ipairs(list) do e.used = nil end
        end
    end
    local resources = index(saved and saved.resources)
    local chests = index(saved and saved.chests)

    -- Full amount per class: untouched nodes are saved at their maximum, so the largest value seen is it.
    local max = {}
    for cls, list in pairs(saved and saved.resources or {}) do
        for _, e in ipairs(list) do
            if not max[cls] or e.available > max[cls] then max[cls] = e.available end
        end
    end

    local function add(category, cls, x, y, z, state)
        local icon, label = Categories.look(category, cls)
        local e = { layer = category.id, class = cls, x = x, y = y, z = z, label = label, icon = icon, state = state,
                    tip = label, readyAt = ready_at(category, cls, state) }
        if state then
            if state.available ~= nil and state.available <= 0 then
                snap.counts.empty = snap.counts.empty + 1
            elseif state.available and state.max and state.available < state.max then
                snap.counts.partial = snap.counts.partial + 1
            elseif state.opened then
                snap.counts.opened = snap.counts.opened + 1
            end
        end
        local list = snap.layers[category.id]
        if not list then list = {} snap.layers[category.id] = list end
        list[#list + 1] = e
        return e
    end

    local function stateFor(cls, x, y)
        local r = take(resources, cls, x, y)
        if r then
            return { available = r.available, max = max[cls], changed = r.changed, spawned = r.spawned }
        end
        local c = take(chests, cls, x, y)
        if c then return { opened = c.opened, openedAt = c.openedAt } end
        return nil
    end

    -- Placed things from the world data, with their saved state.
    for _, category in ipairs(Categories) do
        local list = category.static and world.cats[category.id]
        if list then
            for i = 1, #list, 4 do
                local cls = world.classes[list[i]]
                local x, y, z = list[i + 1], list[i + 2], list[i + 3]
                add(category, cls, x, y, z, stateFor(cls, x, y))
            end
        end
    end

    -- The game's interactable foliage, its mesh telling the layer. A harvested one is in the save as the actor it
    -- turned into, of a class of the same layer, so saved states of known classes are matched by layer and place.
    if foliage then
        local byLayer = {}
        for cls, list in pairs(saved and saved.resources or {}) do
            local id = world.classCats and world.classCats[cls]
            if id then
                local into = byLayer[id] or {}
                byLayer[id] = into
                for _, e in ipairs(list) do
                    e.cls = cls
                    into[#into + 1] = e
                end
            end
        end
        local layerIndex = index(byLayer)
        local categoryOf = {}
        for i, mesh in ipairs(foliage.meshes) do categoryOf[i] = Categories.for_mesh(mesh) or false end
        local points = foliage.points
        for i = 1, #points, 4 do
            local category = categoryOf[points[i]]
            if category then
                local x, y, z = points[i + 1], points[i + 2], points[i + 3]
                local r = take(layerIndex, category.id, x, y)
                local state = r and { available = r.available, max = max[r.cls], changed = r.changed, spawned = r.spawned }
                local e = add(category, foliage.meshes[points[i]], x, y, z, state)
                if r then e.readyAt = ready_at(category, r.cls, state) end
            end
        end
    end

    -- Saved things neither has: spawned ones (harvested plants elsewhere, felled trees), which the game brings back from
    -- the save. A placed one is a level actor this game build no longer has there (an update moved or removed it), so
    -- the game drops its state; so do we.
    for cls, list in pairs(saved and saved.resources or {}) do
        local category = Categories.get(world.classCats and world.classCats[cls] or "")
        if category then
            for _, r in ipairs(list) do
                if not r.used and r.spawned then
                    add(category, cls, r.x, r.y, r.z, { available = r.available, max = max[cls], changed = r.changed, spawned = r.spawned })
                    snap.counts.saveOnly = snap.counts.saveOnly + 1
                end
            end
        end
    end

    -- Your things, straight from the save.
    for _, id in ipairs({ "items", "junk", "graves", "storage" }) do
        local category = Categories.get(id)
        local list = {}
        for _, p in ipairs(saved and saved[id] or {}) do
            list[#list + 1] = { layer = id, x = p.x, y = p.y, z = p.z, label = category.label, icon = category.icon, tip = p.tip,
                                items = (id == "items" or id == "junk") and p.items or nil }
        end
        snap.layers[id] = list
    end
    return snap
end

return Snapshot
