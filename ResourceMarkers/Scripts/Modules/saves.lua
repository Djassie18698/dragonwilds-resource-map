-- Turns a world save into map points: your drops, graves and storage, plus the saved state of placed
-- things (resources left in rocks and plants, opened chests) for matching against the world data.
-- Pure Lua (no UE4SS calls), so tests/test-saves.lua can check it against the real save.

local Spud = require("Modules.spud")
local Items = require("Modules.items")

local Saves = {}

local TICKS_PER_SECOND = 10000000 -- FTimespan ticks (100 ns); all in-game times in the save use them
local PILE = 300        -- game units (3 m): drops closer than this share one icon
local MAX_LINES = 8     -- tooltip lines before "+N more"

local function short(cls)
    return cls:match("([^.]+)$") or cls
end

local function isItem(cls) return cls:find("BP_RuntimeSpawnedWorldItem", 1, true) ~= nil end
local function isGrave(cls) return cls:find("BP_PlayerGravestone_C", 1, true) ~= nil end
local STORAGE = { { "BP_BaseBuilding_Chest_Small_C", "Small chest" }, { "BP_BaseBuilding_Chest_Iron_C", "Iron chest" },
                  { "BP_BaseBuilding_PersonalChest_C", "Personal chest" }, { "BP_BaseBuilding_Chest_C", "Chest" },
                  { "BP_BaseBuilding_Crate_C", "Crate" } }
local function storageLabel(cls)
    for _, e in ipairs(STORAGE) do
        if cls:sub(-#e[1]) == e[1] then return e[2] end
    end
    return nil
end

local function lines(header, entries, footer)
    local out = { header }
    for i, entry in ipairs(entries) do
        if i > MAX_LINES then
            out[#out + 1] = string.format("+%d more", #entries - MAX_LINES)
            break
        end
        out[#out + 1] = Items.describe(entry)
    end
    if footer then out[#out + 1] = footer end
    return table.concat(out, "\n")
end

-- A pile's tooltip: its first item, then the rest.
function Saves.pile_tip(items)
    return lines(Items.describe(items[1]), { table.unpack(items, 2) })
end

-- Gear first (full durability), then bigger stacks.
local function byValue(catalogFull)
    return function(a, b)
        local fa, fb = catalogFull(a.id) or 0, catalogFull(b.id) or 0
        if fa ~= fb then return fa > fb end
        return (a.count or 1) > (b.count or 1)
    end
end

-- Grave owners: GameplayObjectRegistry entries (UE tagged properties) hold OwningCharGuid{InnerGuid} and
-- Identifier (= the grave's GameplayObjectRegistryIdentifier). Returns registry id -> character guid.
local function graveOwners(s)
    local owners = {}
    local tag = "\x0f\x00\x00\x00OwningCharGuid\x00"
    local marker = "/Script/CoreUObject\0"
    local function guidAfter(field, from, to)
        local f = s:find(field .. "\0", from, true)
        local m = f and f <= to and s:find(marker, f, true)
        if not m or m > to then return nil end
        return Spud.guid(s, m - 1 + #marker + 9) -- skip u32 0, u32 size, u8 flags
    end
    local at = s:find(tag, 1, true)
    while at do
        local nxt = s:find(tag, at + 1, true)
        local stop = nxt or math.min(at + 4000, #s)
        local ok, id = pcall(guidAfter, "Identifier", at, stop)
        if ok and id then
            local okOwner, who = pcall(guidAfter, "InnerGuid", at, stop)
            owners[id] = okOwner and who or nil
        end
        at = nxt
    end
    return owners
end

-- Character guid -> name: guests are cached in the world as JSON (char_guid comes shortly before char_name).
local function characterNames(s)
    local names, init = {}, 1
    while true do
        local at, stop, guid = s:find('"char_guid":%s*"(%x+)"', init)
        if not at then break end
        local name = s:sub(stop, stop + 4000):match('"char_name":%s*"([^"]*)"')
        if name then names[guid] = name end
        init = stop + 1
    end
    return names
end

-- Saved state of world things (rocks, plants, vents, geysers, chests) and the world clock. Spawned actors count too:
-- harvested foliage plants (flax, herbs) are saved as spawned actors, which is the only place their positions exist.
local RESPAWN_FIELDS = { "RespawnComponent", "ResourceRespawnComponent" }
local function placedState(out, s, level, name, x, y, z, f, spawned)
    for _, field in ipairs(RESPAWN_FIELDS) do
        local at = f[field]
        if at then
            local r = Spud.nested(s, at, level.meta)
            if r.ResourcesAvailable then
                local list = out.resources[name] or {}
                out.resources[name] = list
                list[#list + 1] = { x = x, y = y, z = z, spawned = spawned, available = Spud.i32(s, r.ResourcesAvailable),
                    changed = r.PersistedTimeOfLastResourceChange and Spud.i64(s, r.PersistedTimeOfLastResourceChange) or 0 }
            end
            break
        end
    end
    if f.ChestState then
        local list = out.chests[name] or {}
        out.chests[name] = list
        local started = f.RespawnTimerInGameTimeStartTicks and Spud.i64(s, f.RespawnTimerInGameTimeStartTicks) or -1
        list[#list + 1] = { x = x, y = y, z = z, opened = Spud.u8(s, f.ChestState) ~= 0, openedAt = started > 0 and started or nil }
    end
    if f.StoredTime and name == "BP_InGameTimeActor_C" then
        out.clock = math.floor(string.unpack("<f", s, f.StoredTime + 1) * 60 * TICKS_PER_SECOND) -- stored in in-game minutes
    end
end

-- s: the save file's bytes. Returns { items, junk, graves, storage, resources, chests, skipped } where the first
-- four are lists of map points { x, y, z, tip } and resources/chests map a class name to saved states.
function Saves.parse(s)
    local fullDurability = Items.full
    local out = { items = {}, junk = {}, graves = {}, storage = {}, resources = {}, chests = {}, skipped = 0 }
    local drops = {}
    for _, lv in ipairs(Spud.levels(s)) do
        local ok, level = pcall(Spud.level, s, lv)
        if not ok then
            out.skipped = out.skipped + 1
        else
            for _, a in ipairs(level.placed) do
                local okA, cls, x, y, z, f = pcall(Spud.actor, s, level, a)
                if okA and f and x then placedState(out, s, level, short(cls), x, y, z, f, false) end
            end
            for _, a in ipairs(level.spawned) do
                local okA, cls, x, y, z, f, prop = pcall(Spud.actor, s, level, a)
                local label = okA and storageLabel(cls)
                if okA and f and x then placedState(out, s, level, short(cls), x, y, z, f, true) end
                if not okA or not f or not x then
                    if okA and (isItem(cls) or isGrave(cls) or label) then out.skipped = out.skipped + 1 end
                elseif isItem(cls) then
                    local okI, it = pcall(Spud.item, s, level, f)
                    if okI then
                        it.x, it.y, it.z = x, y, z
                        drops[#drops + 1] = it
                    else
                        out.skipped = out.skipped + 1
                    end
                elseif isGrave(cls) or label then
                    local stop = prop + 8 + Spud.u32(s, prop + 4)
                    local contents = Spud.jsonItems(s, prop + 8, stop)
                    table.sort(contents, byValue(fullDurability))
                    local point = { x = x, y = y, z = z, items = contents }
                    if label then
                        point.tip = lines(label, contents, #contents == 0 and "Empty" or nil)
                        out.storage[#out.storage + 1] = point
                    else
                        point.registryId = f.GameplayObjectRegistryIdentifier and Spud.guid(s, f.GameplayObjectRegistryIdentifier) or ""
                        out.graves[#out.graves + 1] = point
                    end
                end
            end
        end
    end

    -- Who's who. The host isn't cached like guests are; the one character guid nobody claims
    -- is the host, whom the header names.
    local names, owners = characterNames(s), graveOwners(s)
    local header = Spud.info(s)
    out.worldName, out.host = header.worldName, header.owner
    local NOBODY = string.rep("0", 32) -- world drops (enemy loot, felled logs)
    local unknown = {}
    for _, it in ipairs(drops) do
        local guid = it.dropperGuid
        if it.droppedBy == "" and guid ~= "" and guid ~= NOBODY and not names[guid] then unknown[guid] = true end
    end
    for _, guid in pairs(owners) do
        if not names[guid] then unknown[guid] = true end
    end
    local first, extra = next(unknown)
    extra = first and next(unknown, first)
    if first and not extra and header.owner and header.owner ~= "" then names[first] = header.owner end
    for _, it in ipairs(drops) do
        if it.droppedBy == "" then it.droppedBy = names[it.dropperGuid] or "" end
    end
    for _, g in ipairs(out.graves) do
        local who = names[owners[g.registryId] or ""]
        g.owner = who
        g.tip = lines(who and ("Grave of " .. who) or "Grave", g.items)
    end

    -- Piles: each drop joins the first pile within PILE of it.
    local piles = {}
    for _, it in ipairs(drops) do
        local home
        for _, p in ipairs(piles) do
            local dx, dy, dz = p.x - it.x, p.y - it.y, p.z - it.z
            if dx * dx + dy * dy + dz * dz <= PILE * PILE then home = p break end
        end
        if not home then
            home = { x = it.x, y = it.y, z = it.z, items = {}, junk = true }
            piles[#piles + 1] = home
        end
        home.items[#home.items + 1] = it
        home.junk = home.junk and Items.isJunk(it.id)
    end
    for _, p in ipairs(piles) do
        table.sort(p.items, byValue(fullDurability))
        -- World drops (enemy loot, felled logs) expire; player drops never do. The soonest expiry is the pile's.
        local expires
        for _, it in ipairs(p.items) do
            if it.expiresAt and (not expires or it.expiresAt < expires) then expires = it.expiresAt end
        end
        p.expiresAt = expires
        p.tip = Saves.pile_tip(p.items)
        local layer = p.junk and out.junk or out.items
        layer[#layer + 1] = p
    end
    out.drops = drops
    return out
end

return Saves
