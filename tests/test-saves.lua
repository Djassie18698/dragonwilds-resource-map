-- Host check of the save reader and the world snapshot built from it (read-only).
-- Usage: lua5.4 tests/test-saves.lua <world.sav> [--exact]
--   --exact: the fixture's known contents (tests/fixtures/Test.sav, a copy of a world save from 2026-10-03; it holds
--            players' names, so it isn't in the repository).
--   Without it: any save must parse cleanly; prints a summary.
local here = arg[0]:match("^(.*)/tests/") or "."
package.path = here .. "/ResourceMarkers/Scripts/?.lua;" .. package.path
local Items = require("Modules.items")
local Saves = require("Modules.saves")
local Snapshot = require("Modules.snapshot")
assert(Items.load(here .. "/ResourceMarkers/data/items.lua"), "data/items.lua")

local path, exact = assert(arg[1], "usage: test-saves.lua <world.sav> [--exact]"), arg[2] == "--exact"
local f = assert(io.open(path, "rb"))
local s = f:read("a")
f:close()

local t0 = os.clock()
local r = Saves.parse(s)
local ms = (os.clock() - t0) * 1000

local snap = Snapshot.build(r, dofile(here .. "/ResourceMarkers/data/world.lua"))
local entities = 0
for _, list in pairs(snap.layers) do entities = entities + #list end

local nres, ndepleted, nchest, nopened, nclasses = 0, 0, 0, 0, 0
for _, list in pairs(r.resources) do
    nclasses = nclasses + 1
    for _, e in ipairs(list) do nres = nres + 1 if e.available == 0 then ndepleted = ndepleted + 1 end end
end
for _, list in pairs(r.chests) do for _, e in ipairs(list) do nchest = nchest + 1 if e.opened then nopened = nopened + 1 end end end
print(string.format("%s: world '%s' (host %s), parsed in %.0f ms", path:match("[^/]+$"), tostring(r.worldName), tostring(r.host), ms))
print(string.format("  %d drops -> %d item piles + %d junk piles, %d graves, %d storage, %d skipped",
    #r.drops, #r.items, #r.junk, #r.graves, #r.storage, r.skipped))
print(string.format("  saved state: %d resource nodes (%d empty) in %d classes, %d chests (%d opened), in-game day %.3f",
    nres, ndepleted, nclasses, nchest, nopened, (r.clock or 0) / 864000000000))
local c = snap.counts
print(string.format("  snapshot: %d entities; %d fully taken, %d partly, %d chests opened, %d only in the save",
    entities, c.empty, c.partial, c.opened, c.saveOnly))

local fails = 0
local function check(cond, what)
    if not cond then fails = fails + 1 print("  FAIL: " .. what) end
end
check(r.skipped == 0, "nothing skipped")
check(r.worldName and r.worldName ~= "", "world name in header")
check(r.clock and r.clock > 0, "in-game clock (BP_InGameTimeActor.StoredTime)")
for _, p in ipairs(r.items) do check(p.tip and p.tip ~= "", "every pile has a tooltip") end

-- Every item in the save has a name (an "Unknown item" means data/items.lua misses one: re-extract, or a gap in
-- tools/extract/items.py). The fixture must have none; a newer save may meet an item from a game update.
local unknown = {}
local function named(it) if Items.name(it.id) == "Unknown item" then unknown[#unknown + 1] = it.id end end
for _, it in ipairs(r.drops) do named(it) end
for _, place in ipairs({ r.graves, r.storage }) do
    for _, p in ipairs(place) do for _, it in ipairs(p.items) do named(it) end end
end
if #unknown > 0 then print("  items without a name: " .. #unknown .. " (" .. table.concat(unknown, ", ", 1, math.min(#unknown, 5)) .. ")") end

if exact then
    check(#unknown == 0, "every item in the fixture has a name")
    check(#r.drops == 146, "146 drops (same as spud.js), got " .. #r.drops)
    check(#r.items == 12 and #r.junk == 63, "12 item piles and 63 junk piles")
    check(#r.graves == 1 and #r.graves[1].items == 14 and (r.graves[1].owner or "") ~= "", "a grave with 14 items and its owner's name")
    check(#r.storage == 24, "24 storage containers")
    check(nres == 3820 and ndepleted == 71 and nclasses == 131 and nchest == 82 and nopened == 7, "saved resource and chest state")
    check(math.abs(r.clock / 864000000000 - 52.756) < 0.001, "clock at in-game day 52.756")
    -- The fixture is from an older game build: 117 rocks it has state for are no longer placed there and aren't shown.
    check(entities == 10199 and c.empty == 33 and c.partial == 25 and c.opened == 7 and c.saveOnly == 36, "snapshot counts")
    -- Tooltips are the thing's name; its saved state (how much is left, when it last changed) is kept for dimming and
    -- respawns. Hours/days before the save are in-game time.
    local function at(layer, x, y)
        for _, e in ipairs(snap.layers[layer] or {}) do
            if math.floor(e.x) == x and math.floor(e.y) == y then return e end
        end
    end
    local function before(t, per) return math.floor((r.clock - t) / per + 0.5) end
    local H, D = 36000000000, 864000000000
    local copper, tin = at("copper", 80123, 131590), at("tin", 100489, 112990)
    local law, chest, flax = at("vent_law", 79542, 176380), at("chests", 80945, 153419), at("flax", 81254, 153454)
    check(copper and copper.tip == "Copper rock" and copper.state.available == 11 and copper.state.max == 13
        and before(copper.state.changed, H) == 2, "partly mined copper: 11 of 13, 2h before the save")
    check(tin and tin.tip == "Tin rock" and tin.state.available == 0 and before(tin.state.changed, H) == 25,
        "mined-out tin, 25h before the save")
    check(law and law.tip == "Law vent" and law.state.available == 0 and before(law.state.changed, D) == 17,
        "drained law vent, 17 days before the save")
    check(chest and chest.tip == "Chest" and chest.state.opened and before(chest.state.openedAt, D) == 17,
        "opened chest, 17 days before the save")
    check(flax and flax.tip == "Flax" and flax.state.available == 0 and before(flax.state.changed, D) == 16,
        "harvested flax (only in the save), 16 days before the save")
    local overdue, pending = 0, 0
    for _, list in ipairs({ r.items, r.junk }) do
        for _, p in ipairs(list) do
            if p.expiresAt then if p.expiresAt < r.clock then overdue = overdue + 1 else pending = pending + 1 end end
        end
    end
    check(overdue == 25 and pending == 6, "25 drop piles past despawn, 6 still pending")
    local pick
    for _, it in ipairs(r.drops) do if Items.name(it.id) == "Rune Pickaxe" then pick = it end end
    check(pick and math.floor(pick.x) == 95284 and math.floor(pick.y) == 123674 and math.floor(pick.z) == 383
        and pick.durability == 1964 and pick.droppedBy == r.host and r.host ~= "",
        "Rune Pickaxe at 95284/123674/383, 1964, dropped by the host (named from the save's header)")
end
-- Foliage (data/foliage.lua): a mesh gives the layer; an unknown mesh is left out; a harvested one, saved as the actor it
-- became (a class of the same layer), gives its state instead of showing twice.
do
    local foliageSnap = Snapshot.build(
        { resources = { BP_Spawner_Onion_C = { { x = 1000, y = 2000, z = 0, available = 0, changed = 5, spawned = 0 } } },
          chests = {}, items = {}, junk = {}, graves = {}, storage = {}, clock = 10 },
        { cats = {}, classes = {}, classCats = { BP_Spawner_Onion_C = "onion" } },
        { meshes = { "SM_Onion_Plant_01", "SM_FH_Ash_Tree_01", "SM_Something_Else" },
          points = { 1, 1100, 2050, 0, 2, 50000, 50000, 0, 3, 7, 7, 7, 1, 90000, 90000, 0 } })
    local onions, ash = foliageSnap.layers.onion or {}, foliageSnap.layers.ash or {}
    check(#onions == 2 and #ash == 1, "foliage into its layers by mesh, unknown meshes left out")
    check(onions[1].state and onions[1].state.available == 0 and not onions[2].state and foliageSnap.counts.saveOnly == 0,
        "a harvested plant's saved state goes to its foliage point, not a second icon")
    check(ash[1].tip == "Ash tree", "a tree's tooltip is its name")
end

print(fails == 0 and "  OK" or ("  " .. fails .. " check(s) failed"))
os.exit(fails == 0 and 0 or 1)
