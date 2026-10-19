-- Groups map points by world-space grid cell (areas). Pure Lua (no UE4SS calls).

local Cluster = {}

-- The grid cell a position falls in, as one number.
function Cluster.key(x, y, cell)
    return (math.floor(x / cell) + 524288) * 1048576 + math.floor(y / cell) + 524288
end

-- entities: list of { x, y, z, ... }; cell: grid size in game units. Returns groups { key, x, y, z, x0, y0, x1, y1,
-- members } with x/y/z the members' average and x0..y1 their bounds, in first-seen order. key names the grid cell, so
-- groups of different layers in the same area share it.
function Cluster.merge(entities, cell)
    local groups, byKey = {}, {}
    for _, e in ipairs(entities or {}) do
        local key = Cluster.key(e.x, e.y, cell)
        local g = byKey[key]
        if not g then
            g = { key = key, sx = 0, sy = 0, sz = 0, x0 = e.x, y0 = e.y, x1 = e.x, y1 = e.y, members = {} }
            byKey[key] = g
            groups[#groups + 1] = g
        end
        g.sx, g.sy, g.sz = g.sx + e.x, g.sy + e.y, g.sz + e.z
        g.x0, g.y0 = math.min(g.x0, e.x), math.min(g.y0, e.y)
        g.x1, g.y1 = math.max(g.x1, e.x), math.max(g.y1, e.y)
        g.members[#g.members + 1] = e
    end
    for _, g in ipairs(groups) do
        local n = #g.members
        g.x, g.y, g.z = g.sx / n, g.sy / n, g.sz / n
    end
    return groups
end

return Cluster
