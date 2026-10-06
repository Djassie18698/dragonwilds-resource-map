local Util = {}

Util.MOD_NAME = "ResourceMarkers"

function Util.log(message)
    print("[" .. Util.MOD_NAME .. "] " .. tostring(message) .. "\n")
end

function Util.safe(callback, fallback)
    local ok, result = pcall(callback)
    if ok then
        return result
    end
    return fallback
end

function Util.valid(object)
    if object == nil then
        return false
    end
    local ok, result = pcall(function()
        return object:IsValid()
    end)
    return ok and result == true
end

function Util.name(object)
    if not Util.valid(object) then
        return nil
    end
    return Util.safe(function()
        return object:GetFName():ToString()
    end, nil)
end

function Util.class_name(object)
    if not Util.valid(object) then
        return nil
    end
    return Util.safe(function()
        return object:GetClass():GetFName():ToString()
    end, nil)
end

function Util.address(object)
    return Util.safe(function()
        return string.format("%x", object:GetAddress())
    end, tostring(object))
end

function Util.vector(value)
    if value == nil then
        return nil
    end
    return Util.safe(function()
        local x, y, z = tonumber(value.X), tonumber(value.Y), tonumber(value.Z)
        if x == nil or y == nil or z == nil then
            return nil
        end
        return { X = x, Y = y, Z = z }
    end, nil)
end

function Util.dist2_2d(a, b)
    local dx, dy = a.X - b.X, a.Y - b.Y
    return dx * dx + dy * dy
end

-- Folder of this mod (…/Mods/ResourceMarkers), independent of the working dir.
function Util.mod_dir()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", ""):gsub("\\", "/")
    return source:match("^(.*)/Scripts/") or "."
end

function Util.local_player()
    local controllers = Util.safe(function()
        return FindAllOf("PlayerController")
    end, nil)
    if controllers == nil then
        return nil, nil
    end

    for _, controller in ipairs(controllers) do
        if Util.valid(controller)
            and Util.safe(function() return controller:IsLocalController() end, false) then
            local pawn = Util.safe(function() return controller.Pawn end, nil)
            if Util.valid(pawn) then
                return controller, pawn
            end
            return controller, nil
        end
    end

    return nil, nil
end

return Util
