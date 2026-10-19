-- Debug builds only (./install.sh debug): verbose logging and inspection. It lives outside the mod folder, so a copy
-- of ResourceMarkers/ is a release build: the lines that use it are "--DEBUG " comments there, and tools/debug-build.sh
-- uncomments them and copies this file in as Scripts/Modules/debug.lua (like #ifdef).
-- Everything here only reads, except F9 (the layer hunt), and fails quietly: a debug line must never break the mod.
local Util = require("Modules.util")

local Debug = {}

local COLLAPSED = 1
local MANY = 24          -- a panel with more children than this (icons, terrain tiles) is summed up, not listed
local MAX_DEPTH = 12

function Debug.log(fmt, ...)
    local ok, message = pcall(string.format, fmt, ...)
    Util.log("dbg: %s", ok and message or (tostring(fmt) .. " (format failed)"))
end

-- Milliseconds since t0 (os.clock is wall time under the game's C runtime).
function Debug.ms(t0) return (os.clock() - t0) * 1000 end

-- A UObject's short name, or "?". (Only valid objects are asked: reading from a null one crashes, past any pcall.)
function Debug.name(obj)
    local ok, name = pcall(function() return obj:IsValid() and obj:GetFName():ToString() or "null" end)
    return ok and name or "?"
end

-- What a material or texture is: its name, and its parent's for a material instance.
local function asset(obj)
    if not (obj and obj:IsValid()) then return "none" end
    local text = Debug.name(obj)
    pcall(function()
        local parent = obj.Parent
        if parent and parent:IsValid() then text = text .. " (of " .. Debug.name(parent) .. ")" end
    end)
    return text
end

-- The keys of a table, sorted and joined ("live, near").
function Debug.keys_of(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return table.concat(keys, ", ")
end

local function class_name(w) return w:GetClass():GetFName():ToString() end

local function children(w)
    local ok, n = pcall(function() return w:GetChildrenCount() end)
    return ok and type(n) == "number" and n or 0
end

local function inner_root(w)
    local ok, root = pcall(function()
        local tree = w.WidgetTree
        return tree and tree:IsValid() and tree.RootWidget
    end)
    return ok and root and root:IsValid() and root or nil
end

-- One widget as a line: name, class, visibility, opacity, and what it draws (an image's brush, a retainer's effect).
local function describe(w, cls)
    local parts = { Debug.name(w), cls }
    pcall(function() parts[#parts + 1] = "vis " .. tostring(w:GetVisibility()) end)
    pcall(function() parts[#parts + 1] = string.format("opacity %.2f", w:GetRenderOpacity()) end)
    if cls == "Image" then
        pcall(function() parts[#parts + 1] = "brush " .. asset(w.Brush.ResourceObject) end)
        pcall(function() parts[#parts + 1] = string.format("alpha %.2f", w.ColorAndOpacity.A) end)
    elseif cls == "RetainerBox" then
        pcall(function() parts[#parts + 1] = "effect " .. asset(w:GetEffectMaterial()) end)
        pcall(function() parts[#parts + 1] = "retain " .. tostring(w.bRetainRender) end)
    end
    return table.concat(parts, "  ")
end

-- The hunt (F9): the map widgets' images and retainers, switched off one at a time on every map widget seen.
local maps = {}        -- address -> widget, the map widgets dumped so far
local suspects = {}    -- in tree order: { name, cls }
local known = {}       -- name -> true
local current = 0      -- the suspect switched off now (0: none)

local function walk(w, depth, label)
    if depth > MAX_DEPTH or not (w and w:IsValid()) then return end
    local ok, cls = pcall(class_name, w)
    cls = ok and cls or "?"
    local okD, line = pcall(describe, w, cls)
    local n = children(w)
    Debug.log("%s %s%s%s", label, string.rep("  ", depth), okD and line or Debug.name(w),
        n > MANY and string.format("  (%d children, not listed)", n) or "")
    local name = Debug.name(w)
    if (cls == "Image" or cls == "RetainerBox") and not known[name] then
        known[name] = true
        suspects[#suspects + 1] = { name = name, cls = cls }
    end
    if n > 0 and n <= MANY then
        for i = 0, n - 1 do
            local okC, child = pcall(function() return w:GetChildAt(i) end)
            if okC then walk(child, depth + 1, label) end
        end
    end
    local root = inner_root(w)
    if root then walk(root, depth + 1, label) end
end

-- Logs a map widget's whole tree (once per widget and label) and adds its images to the hunt.
local dumped = {}
function Debug.widgets(widget, label)
    local ok, address = pcall(function() return widget:GetAddress() end)
    if not ok or dumped[tostring(address) .. label] then return end
    dumped[tostring(address) .. label] = true
    maps[address] = widget
    Debug.log("%s: %s", label, select(2, pcall(function() return widget:GetFullName() end)))
    walk(inner_root(widget), 1, label)
end

-- The widgets named name in every map widget seen (found by walking their trees again: cheap, debug only).
local function find_all(name)
    local out = {}
    local function search(w, depth)
        if depth > MAX_DEPTH or not (w and w:IsValid()) then return end
        if Debug.name(w) == name then out[#out + 1] = w end
        local n = children(w)
        if n > 0 and n <= MANY then
            for i = 0, n - 1 do
                local ok, child = pcall(function() return w:GetChildAt(i) end)
                if ok then search(child, depth + 1) end
            end
        end
        local root = inner_root(w)
        if root then search(root, depth + 1) end
    end
    for _, m in pairs(maps) do
        if m:IsValid() then search(inner_root(m), 1) end
    end
    return out
end

local function switch(s, off)
    for _, w in ipairs(find_all(s.name)) do
        pcall(function()
            if s.cls == "RetainerBox" then
                w:SetRetainRendering(not off)          -- off: drawn directly, without its effect material
            elseif off then
                s.was = s.was or w:GetVisibility()
                w:SetVisibility(COLLAPSED)
            else
                w:SetVisibility(s.was or 4)
            end
        end)
    end
end

local function hunt_next()
    if suspects[current] then switch(suspects[current], false) end
    current = current + 1
    if current > #suspects then
        current = 0
        Debug.log("F9: everything back on (%d suspects; open the world map once to add its own)", #suspects)
        return
    end
    local s = suspects[current]
    switch(s, true)
    Debug.log("F9: %d/%d off: %s (%s)", current, #suspects, s.name,
        s.cls == "RetainerBox" and "retain rendering off: no effect material" or "collapsed")
end

function Debug.keys()
    pcall(RegisterKeyBind, Key.F9, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(hunt_next)
            if not ok then Debug.log("F9 failed: %s", tostring(err)) end
        end)
    end)
end

return Debug
