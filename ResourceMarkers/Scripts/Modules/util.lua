local Util = {}

Util.MOD_NAME = "ResourceMarkers"
Util.VERSION = "2.0.0"

function Util.log(fmt, ...)
    local message = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
    print("[" .. Util.MOD_NAME .. "] " .. message .. "\n")
end

-- For cold paths only (load, hooks, menu): one pcall per operation, not per property.
function Util.try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        Util.log("%s failed: %s", what, tostring(err))
    end
    return ok, err
end

-- Folder of this mod (…/Mods/ResourceMarkers), independent of the working directory.
function Util.mod_dir()
    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
    return source:match("^(.*)/Scripts/") or "."
end

-- The game's Saved folder (Windows path; under Proton this is inside the prefix).
function Util.saved_dir()
    local base = os.getenv("LOCALAPPDATA")
    return base and (base .. "\\RSDragonwilds\\Saved\\") or nil
end

-- Each element of an array the game returns: UE4SS gives a Lua table for some (function results) and a TArray for
-- others (properties), whose elements need :get().
function Util.each(list, fn)
    if type(list) == "table" then
        for i, e in ipairs(list) do fn(i, e) end
    else
        list:ForEach(function(i, e) fn(i, e:get()) end)
    end
end

function Util.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("a")
    f:close()
    return data
end

-- A new engine object of this class inside outer, under a name of ours (unique: a counter).
local constructed = 0
function Util.construct(classPath, outer)
    constructed = constructed + 1
    return StaticConstructObject(StaticFindObject(classPath), outer, FName("ResourceMarkers_" .. constructed))
end

-- A blank UserWidget for this player with a CanvasPanel as its root: widget, its widget tree, the canvas (nil if the
-- game refused).
function Util.canvas_widget(controller)
    local widget = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller,
        StaticFindObject("/Script/UMG.UserWidget"), controller)
    if not (widget and widget:IsValid()) then return nil end
    local tree = widget.WidgetTree
    if not (tree and tree:IsValid()) then
        tree = Util.construct("/Script/UMG.WidgetTree", widget)
        widget.WidgetTree = tree
    end
    local canvas = Util.construct("/Script/UMG.CanvasPanel", tree)
    tree.RootWidget = canvas
    return widget, tree, canvas
end

-- The local player's controller and pawn, from the engine (player 0's controller, GameplayStatics), given any object
-- in the current world: an engine hook's context or our own icon owner. nil, nil while loading.
function Util.local_player(context)
    if not (context and context:IsValid()) then return nil, nil end
    local controller = StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(context, 0)
    if not (controller and controller:IsValid()) then return nil, nil end
    local pawn = controller.Pawn
    return controller, (pawn and pawn:IsValid()) and pawn or nil
end

return Util
