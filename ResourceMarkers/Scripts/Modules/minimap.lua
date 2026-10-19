local Util = require("Modules.util")
local Settings = require("Modules.settings")
--DEBUG local Debug = require("Modules.debug")

-- The minimap: a second copy of the game's own map widget (the one the world map is), in the HUD's top-right corner,
-- north up, looking through a map view attached to the player. The game draws everything on it as on the world map
-- (terrain, its own icons and ours) and moves the view with the player itself. The widget costs time per icon on every
-- update, so it sits in a RetainerBox that renders it, and so updates it, every minimap_frames-th frame (5; 1 = every
-- frame, no RetainerBox); it's hidden while the world map is open. It shows no fog (we show everything anyway; the
-- game feeds the revealed regions only to its world map). The game's day/night clock lives in that corner: it moves
-- into the minimap's canvas (so both share one coordinate system), onto the rim at the upper left as the MiniMap mod
-- has it, drawn over the minimap, and goes back to the HUD when the minimap is switched off.
local Minimap = {}

local MAP_ASSET = "/Game/UI/HUD/ModifiedMinimapPlugin/WBP_DominionMinimap.WBP_DominionMinimap"
local MAP_CLASS = MAP_ASSET .. "_C"
local ICON_SCALE = 1.0     -- icons on the minimap: the same size as on the world map
local EDGE = 24            -- screen units from the screen's top-right corner
local SEARCH_DISABLED = 4  -- EMapViewSearchOption::Disabled: we hand it its view (as the game does for the world map)
local FIXED_ROTATION = 0   -- EMapViewRotationMode::UseFixedRotation: yaw 0, north up like the world map
local VISIBLE_NO_HIT = 3   -- ESlateVisibility::HitTestInvisible: drawn, never takes the mouse
local COLLAPSED = 1
local NO_COLLISION = 0     -- ECollisionEnabled::NoCollision (the view is a box component)
local BEHIND_HUD = -50     -- viewport z-order: under the game's HUD
local CLOCK_CLASS = "WBP_HUD_DayAndNight_C"
local CLOCK_PATH = "/Game/UI/HUD/DayAndNight/WBP_HUD_DayAndNight.WBP_HUD_DayAndNight_C"
local CLOCK_AT = { X = -0.83, Y = -0.71 } -- the clock's centre from the minimap's centre, in minimap radii (as the
                                          -- MiniMap mod has it: overlapping the rim at the upper left)

local holder, canvas, map, mapAddress, pawnAddress = nil, nil, nil, nil, nil
local shown = false
local clock = nil          -- the clock we moved: { address, widget, parent, anchors, alignment, offsets, autoSize, zOrder }
local clockWatched = false

Minimap.ICON_SCALE = ICON_SCALE

-- Since the game's October update its map widget draws a vignette: an image, ShadowFrame (MI_Vignette_Rectangular),
-- over the terrain and the icons, always (nothing in the widget's Blueprint changes it). Sized for the full-screen
-- world map, it darkens most of a small minimap. Hidden on both (map: a map widget), once per widget.
-- It isn't a Blueprint variable, and UserWidget has no lookup by name that scripts can call, so it's found by its
-- object path: the widgets of a user widget are objects inside its WidgetTree, whose own name gets a number at runtime
-- (WidgetTree_2147455860), so the tree is read from the widget. If a game update renames or drops it, one warning.
local vignetteMissing = false
function Minimap.hide_vignette(map)
    local tree = map.WidgetTree
    local frame = tree:IsValid() and StaticFindObject(tree:GetFullName():match("^%S+ (.+)$") .. ".ShadowFrame")
    local found = frame and frame:IsValid()
    if found then
        frame:SetVisibility(COLLAPSED)
    elseif not vignetteMissing then
        vignetteMissing = true
        Util.log("The map's vignette (ShadowFrame) was not found, so it stays: a game update changed the map widget")
    end
    --DEBUG Debug.log("vignette on %s: %s", Debug.name(map), found and "hidden" or "not found")
end

local function half_extent()
    return (Settings.minimap_m or 300) * 50
end

local function struct2(v) return { X = v.X, Y = v.Y } end

local function margin(v) return { Left = v.Left, Top = v.Top, Right = v.Right, Bottom = v.Bottom } end

-- Moves the game's day/night clock (widget, else the one there is) from its HUD canvas into ours, centred at CLOCK_AT
-- from the minimap's centre.
function Minimap.place_clock(widget)
    if not holder then return end
    widget = widget or FindFirstOf(CLOCK_CLASS)
    if not (widget and widget:IsValid()) then return end
    if clock and clock.address == widget:GetAddress() then return end
    -- A new clock replaces the one we moved (the HUD rebuilt itself): the old one is in our canvas, so it's ours to drop.
    if clock and clock.widget and clock.widget:IsValid() then clock.widget:RemoveFromParent() end
    clock = nil
    local slot = widget.Slot
    local kind = slot and slot:IsValid() and slot:GetClass():GetFName():ToString() or "none"
    if kind ~= "CanvasPanelSlot" then
        Util.log("Minimap: the day/night clock is in a %s, left where it is", kind)
        clock = { address = widget:GetAddress() }
        return
    end
    local a = slot:GetAnchors()
    local offsets = margin(slot:GetOffsets())
    clock = { address = widget:GetAddress(), widget = widget, parent = slot.Parent, offsets = offsets,
              anchors = { Minimum = struct2(a.Minimum), Maximum = struct2(a.Maximum) },
              alignment = struct2(slot:GetAlignment()), autoSize = slot:GetAutoSize(), zOrder = slot:GetZOrder() }
    local r = (Settings.minimap_px or 250) / 2
    local mine = canvas:AddChildToCanvas(widget)
    mine:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
    mine:SetAlignment({ X = 0.5, Y = 0.5 })
    local point = a.Minimum.X == a.Maximum.X and a.Minimum.Y == a.Maximum.Y -- else offsets are margins, not a size
    if clock.autoSize or not point then
        mine:SetAutoSize(true)
    else
        mine:SetSize({ X = offsets.Right, Y = offsets.Bottom })
    end
    mine:SetPosition({ X = -(EDGE + r) + CLOCK_AT.X * r, Y = EDGE + r + CLOCK_AT.Y * r })
end

-- When the HUD makes a clock (it can rebuild itself), place it at the next tick, when it's in its canvas.
local function watch_clock()
    if clockWatched then return end
    clockWatched = pcall(NotifyOnNewObject, CLOCK_PATH, function(widget)
        ExecuteInGameThread(function() Util.try("Minimap clock", Minimap.place_clock, widget) end)
    end)
end

-- Puts the clock back into its HUD canvas, as it was.
local function restore_clock()
    local c = clock
    clock = nil
    if not (c and c.widget and c.widget:IsValid() and c.parent and c.parent:IsValid()) then return end
    local slot = c.parent:AddChildToCanvas(c.widget)
    slot:SetAnchors(c.anchors)
    slot:SetAlignment(c.alignment)
    slot:SetAutoSize(c.autoSize)
    slot:SetOffsets(c.offsets)
    slot:SetZOrder(c.zOrder)
end

-- A map view on the player: follows them, north up, no collision.
local function add_view(pawn)
    local at = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 }, Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
                 Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local view = pawn:AddComponentByClass(StaticFindObject("/Script/MinimapPlugin.MapViewComponent"), false, at, true)
    view.RotationMode = FIXED_ROTATION
    view:SetCollisionEnabled(NO_COLLISION)
    view:SetGenerateOverlapEvents(false)
    pawn:FinishAddComponent(view, false, at)
    view:SetViewExtent(half_extent(), half_extent())
    return view
end

function Minimap.create(controller, pawn)
    if holder then return true end
    local class = StaticFindObject(MAP_CLASS)
    if not class:IsValid() then
        pcall(LoadAsset, MAP_ASSET)
        class = StaticFindObject(MAP_CLASS)
    end
    if not class:IsValid() then
        Util.log("Minimap: the game's map widget class wasn't found")
        return false
    end
    local phases = math.max(1, Settings.minimap_frames or 5)
    local root, tree, rootCanvas = Util.canvas_widget(controller)
    if not root then return false end

    local m = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(controller, class, controller)
    m.AutoLocateMapView = SEARCH_DISABLED
    m.bIsCircular = true
    m.bEnableBoxSelect = false
    m.IconScale = ICON_SCALE
    m.bShouldShowFog = false
    local content = m
    if phases > 1 then
        content = Util.construct("/Script/UMG.RetainerBox", tree)
        content:SetRenderingPhase(0, phases)
        content:SetContent(m)
    end

    local size = Settings.minimap_px or 250
    local slot = rootCanvas:AddChildToCanvas(content)
    slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
    slot:SetAlignment({ X = 1.0, Y = 0.0 })
    slot:SetPosition({ X = -EDGE, Y = EDGE })
    slot:SetSize({ X = size, Y = size })

    root:SetVisibility(VISIBLE_NO_HIT)
    root:AddToViewport(BEHIND_HUD)
    m:SetMapView(add_view(pawn))
    m:ShowFog(false)
    --DEBUG Debug.log("minimap made: %d px, rendered every %d frames", size, phases)
    --DEBUG Debug.widgets(m, "minimap at creation")
    holder, canvas, map, mapAddress, pawnAddress, shown = root, rootCanvas, m, m:GetAddress(), pawn:GetAddress(), true
    Minimap.hide_vignette(m)
    watch_clock()          -- clocks the HUD makes from now on
    Minimap.place_clock()  -- and the one it has now (one look)
    return true
end

-- The player's pawn changed (respawn): the old view went with the old pawn, so give the new one a view.
function Minimap.attach(pawn)
    if not map or pawn:GetAddress() == pawnAddress then return end
    pawnAddress = pawn:GetAddress()
    map:SetMapView(add_view(pawn))
end

-- Switched off: off the screen, and the view off the player.
function Minimap.destroy()
    if not holder then return end
    restore_clock()
    if holder:IsValid() then
        local view = map.MapViewComp
        if view and view:IsValid() then view:K2_DestroyComponent(view) end
        holder:RemoveFromParent()
    end
    holder, canvas, map, mapAddress, pawnAddress, shown = nil, nil, nil, nil, nil, false
end

-- New world: the old minimap went with the old world (the engine removes its widgets), so only forget it.
function Minimap.forget()
    holder, canvas, map, mapAddress, pawnAddress, shown, clock = nil, nil, nil, nil, nil, false, nil
end

function Minimap.set_shown(on)
    if not (holder and holder:IsValid()) or shown == on then return end
    shown = on
    holder:SetVisibility(on and VISIBLE_NO_HIT or COLLAPSED)
end

function Minimap.set_range()
    if not (map and map:IsValid()) then return end
    local view = map.MapViewComp
    if view and view:IsValid() then view:SetViewExtent(half_extent(), half_extent()) end
end

-- Whether a map widget (by address) is the minimap.
function Minimap.is(address)
    return mapAddress ~= nil and address == mapAddress
end

function Minimap.exists()
    return holder ~= nil
end

function Minimap.is_shown()
    return holder ~= nil and shown
end

-- Its size on screen (screen units) and in the world (game units across).
function Minimap.size_px()
    return Settings.minimap_px or 250
end

function Minimap.view_size()
    return half_extent() * 2
end

return Minimap
