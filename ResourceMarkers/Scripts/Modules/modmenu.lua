-- Optional Mod Menu integration + safe timers. Works fine without Mod Menu.
--
-- Mod Menu publishes each setting as a UE4SS shared variable
-- ("ModMenu.<id>.<key>") and bumps "ModMenu.<id>.rev" on every change.
local MM = {}
MM.__index = MM

local function shared(name)
    local ok, value = pcall(function() return ModRef:GetSharedVariable(name) end)
    if ok then
        return value
    end
    return nil
end

function MM.new(id)
    return setmetatable({
        id = id,
        rev = nil,
        last = {},
        -- Remember the current button action so an old click isn't replayed.
        lastAction = shared("ModMenu." .. id .. ".action"),
    }, MM)
end

-- Calls apply(key, value) for each of `keys` whose published value changed
-- since the last poll. Only changed keys are applied, so settings changed
-- elsewhere (e.g. a mod's own in-game menu) aren't overwritten with stale ones.
-- Returns true if anything was applied.
function MM:poll(keys, apply)
    local rev = shared("ModMenu." .. self.id .. ".rev")
    if type(rev) ~= "number" or rev == self.rev then
        return false
    end
    self.rev = rev

    local changed = false
    for _, key in ipairs(keys) do
        local value = shared("ModMenu." .. self.id .. "." .. key)
        if value ~= nil and value ~= self.last[key] then
            self.last[key] = value
            local ok = pcall(apply, key, value)
            changed = changed or ok
        end
    end
    return changed
end

-- Name of a button clicked in Mod Menu since the last call, or nil.
function MM:action()
    local value = shared("ModMenu." .. self.id .. ".action")
    if value ~= nil and value ~= self.lastAction then
        self.lastAction = value
        return tostring(value):match("^(.-)#") or tostring(value)
    end
    return nil
end

-- Repeating timer on the GAME THREAD. LoopAsync runs Lua on a second thread
-- without a lock, which can corrupt the mod's Lua state when it also does
-- game-thread work; LoopInGameThreadWithDelay avoids that. Falls back to the
-- old way on UE4SS versions that don't have it.
function MM.every(milliseconds, callback, onError)
    local function run()
        local ok, err = pcall(callback)
        if not ok and onError then
            onError(err)
        end
    end
    local ok = pcall(LoopInGameThreadWithDelay, milliseconds, run)
    if not ok then
        local queued = false
        LoopAsync(milliseconds, function()
            if not queued then
                queued = true
                ExecuteInGameThread(function()
                    queued = false
                    run()
                end)
            end
            return false
        end)
    end
end

-- UE4SS key from a name like "F7", "DEL", "PAGE_UP". "none"/"" -> nil.
function MM.key(name)
    if type(name) ~= "string" then
        return nil
    end
    local upper = name:upper()
    if upper == "" or upper == "NONE" then
        return nil
    end
    local ok, key = pcall(function() return Key[upper] end)
    if ok then
        return key
    end
    return nil
end

return MM
