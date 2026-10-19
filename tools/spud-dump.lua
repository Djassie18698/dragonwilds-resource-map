-- Explore a SPUD file: classes matching a pattern, how often they occur, their properties and one sample.
-- Usage: lua5.4 tools/spud-dump.lua <file.sav|file.lvl> [lua pattern] [max samples]

local here = arg[0]:match("^(.*)/tools/") or "."
package.path = here .. "/ResourceMarkers/Scripts/?.lua;" .. package.path
local Spud = require("Modules.spud")

local f = assert(io.open(arg[1], "rb"))
local s = f:read("a")
f:close()
local pattern, maxSamples = arg[2] or ".", tonumber(arg[3] or "1")

local seen = {}
for _, lv in ipairs(Spud.levels(s)) do
    local ok, level = pcall(Spud.level, s, lv)
    if ok then
        for _, kind in ipairs({ "placed", "spawned" }) do
            for _, a in ipairs(level[kind]) do
                local cls, x, y, z, fields, prop = Spud.actor(s, level, a)
                if cls:find(pattern) then
                    local e = seen[cls]
                    if not e then
                        e = { n = 0, kind = kind, props = (level.meta.classProps[cls] or {})[0] or {}, samples = {} }
                        seen[cls] = e
                    end
                    e.n = e.n + 1
                    if #e.samples < maxSamples then
                        e.samples[#e.samples + 1] = { level = level.name, x = x, y = y, z = z, fields = fields,
                            head = s:sub(a.start + 1, math.min(a.stop, a.start + 48)), len = a.stop - a.start }
                    end
                end
            end
        end
    end
end

local names = {}
for cls in pairs(seen) do names[#names + 1] = cls end
table.sort(names)
local function hex(b) return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
for _, cls in ipairs(names) do
    local e = seen[cls]
    print(string.format("== %s  x%d (%s)  props: %s", cls, e.n, e.kind, table.concat(e.props, ", ")))
    for _, smp in ipairs(e.samples) do
        print(string.format("   %s at %s, %s, %s  len %d  head %s", smp.level, tostring(smp.x), tostring(smp.y), tostring(smp.z), smp.len, hex(smp.head)))
        if smp.fields then
            local keys = {}
            for k in pairs(smp.fields) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return smp.fields[a] < smp.fields[b] end)
            for i, k in ipairs(keys) do
                local o = smp.fields[k]
                local nxt = keys[i + 1] and smp.fields[keys[i + 1]] or o + 16
                local raw = s:sub(o + 1, math.min(o + 1 + (nxt - o) - 1, o + 64))
                local printable = raw:gsub("[^%g ]", ".")
                print(string.format("     %-48s @%d [%d] %s  %s", k, o, nxt - o, hex(raw:sub(1, 24)), printable))
            end
        end
    end
end
