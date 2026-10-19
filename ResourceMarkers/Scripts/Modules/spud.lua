-- SPUD save reader (Dragonwilds world saves and SpudCache level files). Pure Lua 5.4, no UE4SS calls.
--
-- Layout (SPUD, the save system the game uses: github.com/sinbad/SPUD):
--   SAVE > INFO, GLOB, LVLS > LEVL*        (a SpudCache .lvl file is one bare LEVL chunk)
--   LEVL = FString name, 8 bytes engine version, META{CNIX,CLST,PNIX}, LATS{LEVA*}, SATS{SPWN*}, DATS
--   actor chunk = u32 classId, ..., CORA (transform), PROP (properties)
--   PROP = i32 n, n x u32 offsets, i32 len, data; offsets follow the class's property list in CLST.
--   Nested objects use the same layout prefixed by a u32 classId. A classId is the class index (CNIX) in the low
--   24 bits and the version of its definition (CLST) in the top 8.
-- All offsets below are 0-based, like the file format; string.unpack wants 1-based positions.

local Spud = {}

local unpack, sub, find = string.unpack, string.sub, string.find
local NO_PREFIX = 0xFFFFFFFF

local function u8(s, o) return (unpack("B", s, o + 1)) end
local function u16(s, o) return (unpack("<I2", s, o + 1)) end
local function u32(s, o) return (unpack("<I4", s, o + 1)) end
local function i32(s, o) return (unpack("<i4", s, o + 1)) end
local function i64(s, o) return (unpack("<i8", s, o + 1)) end
local function f64(s, o) return (unpack("<d", s, o + 1)) end
local function magic(s, o) return sub(s, o + 1, o + 4) end
Spud.u8, Spud.u32, Spud.i32, Spud.i64, Spud.f64 = u8, u32, i32, i64, f64

-- 0-based offset of `m` in [from, to), or nil.
local function seek(s, m, from, to)
    local at = find(s, m, from + 1, true)
    if at and at - 1 + #m <= to then return at - 1 end
    return nil
end
Spud.seek = seek

local function utf16(s, a, b)
    local out, i = {}, a
    while i + 1 < b do
        local c = u16(s, i)
        i = i + 2
        if c >= 0xD800 and c < 0xDC00 and i + 1 < b then
            c = 0x10000 + ((c - 0xD800) << 10) + (u16(s, i) - 0xDC00)
            i = i + 2
        end
        if c ~= 0 then out[#out + 1] = utf8.char(c) end
    end
    return table.concat(out)
end

-- UE FString: i32 length including the NUL; negative = UTF-16. Returns string, next offset.
local function str(s, o)
    local n = i32(s, o)
    if n >= 0 then
        return n > 0 and sub(s, o + 5, o + 3 + n) or "", o + 4 + n
    end
    return utf16(s, o + 4, o + 4 - 2 * n), o + 4 - 2 * n
end
Spud.str = str

-- FGuid the way the game prints it: four little-endian u32s in hex.
function Spud.guid(s, o)
    local a, b, c, d = unpack("<I4I4I4I4", s, o + 1)
    return string.format("%08X%08X%08X%08X", a, b, c, d)
end

-- Sibling chunks in [start, stop): list of { magic, start, stop } (payload bounds).
local function chunks(s, start, stop)
    local out, p = {}, start
    while p + 8 <= stop do
        local len = u32(s, p + 4)
        out[#out + 1] = { magic = magic(s, p), start = p + 8, stop = p + 8 + len }
        p = p + 8 + len
    end
    if p ~= stop then error("unexpected save layout (chunk overrun)") end
    return out
end
Spud.chunks = chunks

local function child(list, m)
    for _, c in ipairs(list) do
        if c.magic == m then return c end
    end
    return nil
end

local function stringIndex(s, c)
    local out, p = {}, c.start + 4
    for i = 1, i32(s, c.start) do
        out[i], p = str(s, p)
    end
    return out
end

-- Class names (by class index, 0-based) and each class's ordered property names ("Prefix.Name" for struct members)
-- per layout version: classProps[name][version]. A class gets a new version when a game update changes its
-- properties; a level saved before keeps the old one for the records written with it.
local function parseMeta(s, meta)
    local kids = chunks(s, meta.start, meta.stop)
    local classNames = stringIndex(s, child(kids, "CNIX"))
    local propNames = stringIndex(s, child(kids, "PNIX"))
    local classProps = {}
    local function classDef(version, o)   -- o: a CDEF payload
        local name, p = str(s, o)
        local props, q = {}, p + 2
        for i = 1, u16(s, p) do
            local id, prefix = u32(s, q), u32(s, q + 4)
            props[i] = prefix == NO_PREFIX and propNames[id + 1] or (propNames[prefix + 1] .. "." .. propNames[id + 1])
            q = q + 10
        end
        classProps[name] = classProps[name] or {}
        classProps[name][version] = props
    end
    local clst = child(kids, "CLST")
    for _, c in ipairs(chunks(s, clst.start, clst.stop)) do
        if c.magic == "CDVE" then
            -- Dragonwilds wraps a class's definitions in a CDVE chunk: u8 version + CDEF chunk for each version
            -- (none: a placeholder).
            local q = c.start
            while q + 9 <= c.stop do
                classDef(u8(s, q), q + 9)
                q = q + 9 + u32(s, q + 5)
            end
        else
            classDef(0, c.start)
        end
    end
    return { classNames = classNames, classProps = classProps }
end

-- classId -> class name, layout version (the id's top byte; the rest is the class index).
local function className(meta, id)
    return meta.classNames[(id & 0xFFFFFF) + 1], id >> 24
end

-- Property block at o -> { propName = absolute offset of its value }.
local function fields(s, o, meta, cls, version)
    local n, names, out = i32(s, o), (meta.classProps[cls] or {})[version or 0] or {}, {}
    local base = o + 4 + 4 * n + 4
    for i = 1, math.min(n, #names) do
        out[names[i]] = base + u32(s, o + 4 * i)
    end
    return out
end
local function nested(s, o, meta)
    local cls, version = className(meta, u32(s, o))
    return fields(s, o + 4, meta, cls, version)
end
Spud.fields, Spud.nested = fields, nested

-- Levels in a buffer: a whole .sav (SAVE chunk) or one SpudCache .lvl (bare LEVL chunk).
function Spud.levels(s)
    if #s < 16 then error("file too small") end
    local m = magic(s, 0)
    if m == "LEVL" then
        return { { start = 8, stop = 8 + u32(s, 4) } }
    elseif m ~= "SAVE" then
        error("not a SPUD save")
    end
    if 8 + u32(s, 4) ~= #s then error("incomplete save (still being written?)") end
    local lvls = child(chunks(s, 8, #s), "LVLS")
    return lvls and chunks(s, lvls.start, lvls.stop) or {}
end

-- One level: name, meta, and its actor chunks (placed = LATS, spawned = SATS).
function Spud.level(s, lv)
    local name, p = str(s, lv.start)
    local kids = chunks(s, seek(s, "META", p, lv.stop), lv.stop)
    local level = { name = name, meta = parseMeta(s, child(kids, "META")), placed = {}, spawned = {} }
    local lats, sats = child(kids, "LATS"), child(kids, "SATS")
    if lats then level.placed = chunks(s, lats.start, lats.stop) end
    if sats then level.spawned = chunks(s, sats.start, sats.stop) end
    return level
end

-- Actor chunk -> class name, position (x, y, z or nil), property offsets (or nil).
function Spud.actor(s, level, a)
    local meta = level.meta
    local cls, version = className(meta, u32(s, a.start))
    cls = cls or ""
    local cora = seek(s, "CORA", a.start + 4, a.stop)
    local prop = seek(s, "PROP", cora or a.start + 4, a.stop)
    local x, y, z
    if cora then
        -- CORA payload: i32 len, u16 version, u8 hidden, rotation quat (4 x f64), location (3 x f64)
        x, y, z = unpack("<ddd", s, cora + 8 + 39 + 1)
    end
    return cls, x, y, z, prop and fields(s, prop + 8, meta, cls, version) or nil, prop
end

-- Dropped item record (BP_RuntimeSpawnedWorldItem*): what, how many, who dropped it.
function Spud.item(s, level, f)
    local meta = level.meta
    local it = nested(s, nested(s, f.MagneticComponentGrantItem, meta).SpawnedItem, meta)
    local expiry = f.ExpirationTimeInGameEndTicks and i64(s, f.ExpirationTimeInGameEndTicks) or -1
    return {
        id = (str(s, it.ItemDataPersistenceId)),
        count = i32(s, it.Count),
        durability = i32(s, it.Durability),
        masterwork = it.NumMasterworkUpgradesApplied and u8(s, it.NumMasterworkUpgradesApplied) or 0,
        expiresAt = expiry > 0 and expiry or nil, -- in-game ticks; player drops never expire
        droppedBy = f.NameOfPlayerCharacterThatDroppedItem and (str(s, f.NameOfPlayerCharacterThatDroppedItem)) or "",
        dropperGuid = f["GuidOfPlayerCharacterThatDroppedItem.InnerGuid"] and Spud.guid(s, f["GuidOfPlayerCharacterThatDroppedItem.InnerGuid"]) or "",
    }
end

-- World header (CINF table in INFO): { worldName, owner } — owner is the host's character name.
function Spud.info(s)
    if magic(s, 0) ~= "SAVE" then return {} end
    local info = child(chunks(s, 8, #s), "INFO")
    local at = info and seek(s, "CINF", info.start, info.stop)
    if not at then return {} end
    local p, names, offs = at + 8, {}, {}
    local n = i32(s, p)
    p = p + 4
    for i = 1, n do names[i], p = str(s, p) end
    n = i32(s, p)
    p = p + 4
    for i = 1, n do offs[i] = u32(s, p) p = p + 4 end
    local base, out = p + 4, {}
    for i, name in ipairs(names) do
        if name == "WorldName" then out.worldName = (str(s, base + offs[i])) end
        if name == "WorldNameOwner" then out.owner = (str(s, base + offs[i])) end
    end
    return out
end

-- Inventories saved as JSON text inside the properties (gravestones, storage): list of { id, count, durability }.
function Spud.jsonItems(s, a, b)
    local text, items = sub(s, a + 1, b), {}
    for id, rest in text:gmatch('"ItemData":%s*"([^"]+)"([^}]*)') do
        items[#items + 1] = {
            id = id,
            count = tonumber(rest:match('"Count":%s*(%-?%d+)')) or 1,
            durability = tonumber(rest:match('"Durability":%s*(%-?%d+)')) or -1,
        }
    end
    return items
end

return Spud
