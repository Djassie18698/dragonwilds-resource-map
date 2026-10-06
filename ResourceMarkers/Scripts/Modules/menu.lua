local Util = require("Modules.util")
local Categories = require("Modules.categories")
local Settings = require("Modules.settings")

-- Keyboard-driven overlay menu built from plain UMG widgets.
--
-- Layout: a centred rounded panel with a title, three columns of rows
-- (General + Rocks, Ores, Plants) and a key-hint footer. Each row is a Border
-- (highlighted when selected) holding a fixed-width state label and a name.
local Menu = {}

local VISIBILITY_COLLAPSED = 1
local VISIBILITY_SELF_HIT_TEST_INVISIBLE = 4
local MOUSE_LOCK_DO_NOT_LOCK = 0
local VALIGN_CENTER = 2
local DRAW_ROUNDED_BOX = 4

local FONT_TITLE = 20
local FONT_SUBTITLE = 11
local FONT_SECTION = 13
local FONT_ROW = 12
local FONT_HINT = 11
local STATE_WIDTH = 58
local COLUMN_GAP = 34

local COLOR_PANEL = { R = 0.015, G = 0.017, B = 0.024, A = 0.92 }
local COLOR_OUTLINE = { R = 0.85, G = 0.66, B = 0.25, A = 0.55 }
local COLOR_TITLE = { R = 1.0, G = 0.8, B = 0.32, A = 1.0 }
local COLOR_SUBTITLE = { R = 0.6, G = 0.6, B = 0.62, A = 1.0 }
local COLOR_SECTION = { R = 0.95, G = 0.74, B = 0.3, A = 1.0 }
local COLOR_RULE = { R = 0.85, G = 0.66, B = 0.25, A = 0.3 }
local COLOR_ON = { R = 0.45, G = 0.9, B = 0.45, A = 1.0 }
local COLOR_OFF = { R = 0.55, G = 0.36, B = 0.36, A = 1.0 }
local COLOR_VALUE = { R = 0.45, G = 0.8, B = 1.0, A = 1.0 }
local COLOR_LABEL_ON = { R = 0.93, G = 0.93, B = 0.93, A = 1.0 }
local COLOR_LABEL_OFF = { R = 0.5, G = 0.5, B = 0.52, A = 1.0 }
local COLOR_LABEL_SELECTED = { R = 1.0, G = 0.88, B = 0.45, A = 1.0 }
local COLOR_ROW_SELECTED = { R = 1.0, G = 0.75, B = 0.2, A = 0.16 }
local COLOR_ROW_NORMAL = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
local COLOR_HINT = { R = 0.55, G = 0.55, B = 0.58, A = 1.0 }
local COLOR_ARROW = { R = 1.0, G = 0.8, B = 0.35, A = 1.0 }
local COLOR_CLOSE_BG = { R = 1.0, G = 1.0, B = 1.0, A = 0.06 }
local COLOR_TRANSPARENT = { R = 1.0, G = 1.0, B = 1.0, A = 0.0 }

local columns = nil  -- { { rows... }, ... }  (rows include section headers)
local order = nil    -- flat list of selectable rows, column by column
local selected = 1
local isOpen = false
local widget = nil
local nameCounter = 0
local clickables = {}   -- { button, action }
local closeButton = nil
local closeBackground = nil
local lookIgnored = false

Menu.on_change = nil -- set by main: function(kind) end
Menu.key_name = "F7" -- set by main: key that opens/closes the menu

local function build_layout()
    local general = {
        { kind = "section", text = "General" },
        { kind = "toggle", key = "enabled", label = "Show markers" },
        { kind = "toggle", key = "hide_depleted", label = "Hide mined / harvested" },
        { kind = "range", label = "Range" },
        { kind = "size", label = "Icon size" },
    }

    local bySection = {}
    local sectionOrder = {}
    for _, category in ipairs(Categories) do
        if bySection[category.section] == nil then
            bySection[category.section] = { { kind = "section", text = category.section } }
            table.insert(sectionOrder, category.section)
        end
        table.insert(bySection[category.section], { kind = "category", category = category })
    end

    -- Column 1: General, then the short "Rocks & minerals" list underneath.
    local first = general
    local rest = {}
    for _, section in ipairs(sectionOrder) do
        if section == "Rocks & minerals" then
            table.insert(first, { kind = "spacer" })
            for _, row in ipairs(bySection[section]) do
                table.insert(first, row)
            end
        else
            table.insert(rest, bySection[section])
        end
    end

    columns = { first }
    for _, column in ipairs(rest) do
        table.insert(columns, column)
    end

    order = {}
    for _, column in ipairs(columns) do
        for _, row in ipairs(column) do
            if row.kind ~= "section" and row.kind ~= "spacer" then
                table.insert(order, row)
                row.order = #order
            end
        end
    end
end

local function construct(classPath, outer)
    nameCounter = nameCounter + 1
    local class = StaticFindObject(classPath)
    return StaticConstructObject(class, outer, FName("ResourceMarkers_" .. nameCounter))
end

local function set_text(textBlock, text, color)
    pcall(function() textBlock:SetText(FText(text)) end)
    if color ~= nil then
        pcall(function()
            textBlock:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
        end)
    end
end

local function make_text(tree, text, size, color, bold)
    local textBlock = construct("/Script/UMG.TextBlock", tree)
    pcall(function() textBlock.Font.Size = size end)
    if bold then
        pcall(function() textBlock.Font.TypefaceFontName = FName("Bold") end)
    end
    set_text(textBlock, text, color)
    return textBlock
end

local function rounded(border, color, radius, outlineColor)
    pcall(function() border:SetBrushColor(color) end)
    pcall(function()
        border.Background.DrawAs = DRAW_ROUNDED_BOX
        border.Background.OutlineSettings.RoundingType = 0
        border.Background.OutlineSettings.CornerRadii = { X = radius, Y = radius, Z = radius, W = radius }
        if outlineColor ~= nil then
            border.Background.OutlineSettings.Color = { SpecifiedColor = outlineColor, ColorUseRule = 0 }
            border.Background.OutlineSettings.Width = 1.0
        end
    end)
end

local function add_to_vbox(box, child, padding)
    local slot = box:AddChildToVerticalBox(child)
    if padding ~= nil then
        pcall(function() slot:SetPadding(padding) end)
    end
    return slot
end

local function add_to_hbox(box, child, padding)
    local slot = box:AddChildToHorizontalBox(child)
    pcall(function() slot:SetVerticalAlignment(VALIGN_CENTER) end)
    if padding ~= nil then
        pcall(function() slot:SetPadding(padding) end)
    end
    return slot
end

local function make_rule(tree, width)
    local size = construct("/Script/UMG.SizeBox", tree)
    pcall(function() size:SetHeightOverride(1.0) end)
    if width ~= nil then
        pcall(function() size:SetWidthOverride(width) end)
    end
    local line = construct("/Script/UMG.Border", tree)
    pcall(function() line:SetBrushColor(COLOR_RULE) end)
    size:SetContent(line)
    return size
end

local function row_state(row)
    if row.kind == "toggle" then
        local on = Settings[row.key]
        return on and "ON" or "OFF", on and COLOR_ON or COLOR_OFF, on
    elseif row.kind == "range" then
        return tostring(Settings.range_m) .. " m", COLOR_VALUE, true
    elseif row.kind == "size" then
        return tostring(Settings.icon_size), COLOR_VALUE, true
    elseif row.kind == "category" then
        local on = Settings.is_category_on(row.category.id)
        return on and "ON" or "OFF", on and COLOR_ON or COLOR_OFF, on
    end
    return "", COLOR_OFF, false
end

local function row_label(row)
    if row.kind == "category" then
        return row.category.label
    end
    return row.label
end

local function refresh()
    if order == nil then
        return
    end

    for index, row in ipairs(order) do
        local w = row.widgets
        if w ~= nil and Util.valid(w.state) then
            local isSelected = index == selected
            local stateText, stateColor, on = row_state(row)
            local labelColor = isSelected and COLOR_LABEL_SELECTED
                or (on and COLOR_LABEL_ON or COLOR_LABEL_OFF)
            set_text(w.state, stateText, stateColor)
            set_text(w.label, row_label(row), labelColor)
            pcall(function()
                w.border:SetBrushColor(isSelected and COLOR_ROW_SELECTED or COLOR_ROW_NORMAL)
            end)
        end
    end
end

-- A Button with invisible chrome, so our own Border provides the look.
local function make_button(tree, content)
    local button = construct("/Script/UMG.Button", tree)
    pcall(function() button:SetBackgroundColor(COLOR_TRANSPARENT) end)
    pcall(function() button.IsFocusable = false end)
    pcall(function()
        local none = { Left = 0, Top = 0, Right = 0, Bottom = 0 }
        button.WidgetStyle.NormalPadding = none
        button.WidgetStyle.PressedPadding = none
    end)
    button:SetContent(content)
    return button
end

local function add_clickable(button, action)
    table.insert(clickables, { button = button, action = action })
end

local function build_row(tree, row, index)
    local border = construct("/Script/UMG.Border", tree)
    rounded(border, COLOR_ROW_NORMAL, 4)
    pcall(function() border:SetPadding({ Left = 6, Top = 2, Right = 10, Bottom = 2 }) end)

    local line = construct("/Script/UMG.HorizontalBox", tree)
    border:SetContent(line)

    local stateBox = construct("/Script/UMG.SizeBox", tree)
    pcall(function() stateBox:SetWidthOverride(STATE_WIDTH) end)
    local state = make_text(tree, "", FONT_ROW, COLOR_ON, true)

    local valueRow = row.kind == "range" or row.kind == "size"
    if valueRow then
        -- [<] value [>]: the arrows are their own buttons.
        pcall(function() stateBox:SetWidthOverride(STATE_WIDTH + 34) end)
        local controls = construct("/Script/UMG.HorizontalBox", tree)
        local minus = make_button(tree, make_text(tree, " < ", FONT_ROW, COLOR_ARROW, true))
        local plus = make_button(tree, make_text(tree, " > ", FONT_ROW, COLOR_ARROW, true))
        add_to_hbox(controls, minus)
        add_to_hbox(controls, state, { Left = 2, Top = 0, Right = 2, Bottom = 0 })
        add_to_hbox(controls, plus)
        stateBox:SetContent(controls)
        add_clickable(minus, function() selected = index; Menu.change(-1) end)
        add_clickable(plus, function() selected = index; Menu.change(1) end)
    else
        stateBox:SetContent(state)
    end
    add_to_hbox(line, stateBox)

    local label = make_text(tree, row_label(row), FONT_ROW, COLOR_LABEL_ON, false)
    add_to_hbox(line, label)

    if valueRow then
        row.widgets = { border = border, state = state, label = label, hover = border }
        return border
    end

    -- The whole row is clickable.
    local button = make_button(tree, border)
    add_clickable(button, function() selected = index; Menu.change(0) end)
    row.widgets = { border = border, state = state, label = label, hover = button }
    return button
end

local function build_column(tree, rows)
    local box = construct("/Script/UMG.VerticalBox", tree)
    local first = true
    for _, row in ipairs(rows) do
        if row.kind == "section" then
            local top = first and 0 or 4
            add_to_vbox(box, make_text(tree, row.text:upper(), FONT_SECTION, COLOR_SECTION, true),
                { Left = 6, Top = top, Right = 0, Bottom = 3 })
            add_to_vbox(box, make_rule(tree, nil), { Left = 6, Top = 0, Right = 6, Bottom = 5 })
        elseif row.kind == "spacer" then
            local spacer = construct("/Script/UMG.Spacer", tree)
            pcall(function() spacer:SetSize({ X = 1.0, Y = 14.0 }) end)
            add_to_vbox(box, spacer)
        else
            add_to_vbox(box, build_row(tree, row, row.order), { Left = 0, Top = 1, Right = 0, Bottom = 1 })
        end
        first = false
    end
    return box
end

local function widget_alive()
    return Util.valid(widget) and Util.safe(function() return widget:IsInViewport() end, false)
end

local function build_widget()
    local controller = Util.local_player()
    if controller == nil then
        Util.log("Menu: no local player yet.")
        return false
    end

    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local userWidgetClass = StaticFindObject("/Script/UMG.UserWidget")

    local created = Util.safe(function()
        return library:Create(controller, userWidgetClass, controller)
    end, nil)
    if not Util.valid(created) then
        Util.log("Menu: could not create the widget.")
        return false
    end

    local tree = Util.safe(function() return created.WidgetTree end, nil)
    if not Util.valid(tree) then
        tree = construct("/Script/UMG.WidgetTree", created)
        created.WidgetTree = tree
    end

    local canvas = construct("/Script/UMG.CanvasPanel", tree)
    tree.RootWidget = canvas

    -- Panel, centred on screen.
    local panel = construct("/Script/UMG.Border", tree)
    rounded(panel, COLOR_PANEL, 10, COLOR_OUTLINE)
    pcall(function() panel:SetPadding({ Left = 22, Top = 16, Right = 22, Bottom = 14 }) end)

    local slot = canvas:AddChildToCanvas(panel)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    end)
    pcall(function() slot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    pcall(function() slot:SetPosition({ X = 0.0, Y = 0.0 }) end)

    local main = construct("/Script/UMG.VerticalBox", tree)
    panel:SetContent(main)

    clickables = {}

    -- Header: title block on the left, Close button on the right.
    local header = construct("/Script/UMG.HorizontalBox", tree)
    local titles = construct("/Script/UMG.VerticalBox", tree)
    add_to_vbox(titles, make_text(tree, "Resource Markers", FONT_TITLE, COLOR_TITLE, true),
        { Left = 6, Top = 0, Right = 0, Bottom = 0 })
    add_to_vbox(titles, make_text(tree, "Choose what shows up on your map and minimap",
        FONT_SUBTITLE, COLOR_SUBTITLE, false), { Left = 6, Top = 0, Right = 0, Bottom = 0 })
    local titleSlot = add_to_hbox(header, titles)
    pcall(function() titleSlot:SetSize({ SizeRule = 1, Value = 1.0 }) end) -- fill

    closeBackground = construct("/Script/UMG.Border", tree)
    rounded(closeBackground, COLOR_CLOSE_BG, 4)
    pcall(function() closeBackground:SetPadding({ Left = 10, Top = 3, Right = 10, Bottom = 3 }) end)
    closeBackground:SetContent(make_text(tree, "Close", FONT_HINT + 1, COLOR_LABEL_ON, true))
    closeButton = make_button(tree, closeBackground)
    add_to_hbox(header, closeButton)
    add_clickable(closeButton, function() Menu.toggle() end)

    add_to_vbox(main, header, { Left = 0, Top = 0, Right = 0, Bottom = 10 })
    add_to_vbox(main, make_rule(tree, nil), { Left = 0, Top = 0, Right = 0, Bottom = 12 })

    -- Columns
    local columnsBox = construct("/Script/UMG.HorizontalBox", tree)
    for index, rows in ipairs(columns) do
        local column = build_column(tree, rows)
        local columnSlot = columnsBox:AddChildToHorizontalBox(column)
        pcall(function()
            columnSlot:SetPadding({ Left = 0, Top = 0, Right = index < #columns and COLUMN_GAP or 0, Bottom = 0 })
        end)
        pcall(function() columnSlot:SetVerticalAlignment(0) end) -- top
    end
    add_to_vbox(main, columnsBox)

    -- Footer
    add_to_vbox(main, make_rule(tree, nil), { Left = 0, Top = 12, Right = 0, Bottom = 8 })
    add_to_vbox(main, make_text(tree,
        "Click to change      or  Up / Down + Enter / Left / Right      " .. Menu.key_name .. "  close",
        FONT_HINT, COLOR_HINT, false), { Left = 6, Top = 0, Right = 0, Bottom = 0 })

    widget = created
    refresh()

    pcall(function() widget:AddToViewport(500) end)
    return true
end

local function move(delta)
    local count = #order
    selected = ((selected - 1 + delta) % count) + 1
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- direction: -1 = left, 1 = right, 0 = enter
function Menu.change(direction)
    local row = order[selected]
    if row == nil then
        return
    end

    local kind = "category"
    if row.kind == "toggle" then
        Settings[row.key] = not Settings[row.key]
        kind = row.key
    elseif row.kind == "range" then
        local step = direction == 0 and Settings.RANGE_STEP or direction * Settings.RANGE_STEP
        local value = Settings.range_m + step
        if direction == 0 and value > Settings.RANGE_MAX then
            value = Settings.RANGE_MIN
        end
        Settings.range_m = clamp(value, Settings.RANGE_MIN, Settings.RANGE_MAX)
        kind = "range"
    elseif row.kind == "size" then
        local step = direction == 0 and Settings.SIZE_STEP or direction * Settings.SIZE_STEP
        local value = Settings.icon_size + step
        if direction == 0 and value > Settings.SIZE_MAX then
            value = Settings.SIZE_MIN
        end
        Settings.icon_size = clamp(value, Settings.SIZE_MIN, Settings.SIZE_MAX)
        kind = "size"
    elseif row.kind == "category" then
        local id = row.category.id
        Settings.categories[id] = not Settings.categories[id]
    else
        return
    end

    Settings.save()
    refresh()
    if Menu.on_change ~= nil then
        Menu.on_change(kind)
    end
end

-- Show the cursor and route clicks to the menu; freeze camera look so moving
-- the mouse doesn't spin the view. Undone when the menu closes.
local function set_mouse_mode(on)
    local controller = Util.local_player()
    if controller == nil then
        return
    end

    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    pcall(function() controller.bShowMouseCursor = on end)

    if on then
        pcall(function()
            library:SetInputMode_GameAndUIEx(controller, widget, MOUSE_LOCK_DO_NOT_LOCK, false, false)
        end)
        if not lookIgnored then
            pcall(function() controller:SetIgnoreLookInput(true) end)
            lookIgnored = true
        end
    else
        pcall(function() library:SetInputMode_GameOnly(controller, false) end)
        if lookIgnored then
            pcall(function() controller:SetIgnoreLookInput(false) end)
            lookIgnored = false
        end
    end
end

function Menu.refresh()
    refresh()
end

function Menu.toggle()
    if isOpen then
        isOpen = false
        if Util.valid(widget) then
            pcall(function() widget:SetVisibility(VISIBILITY_COLLAPSED) end)
        end
        set_mouse_mode(false)
        return
    end

    if columns == nil then
        build_layout()
    end

    if not widget_alive() then
        widget = nil
        if not build_widget() then
            return
        end
    end

    pcall(function() widget:SetVisibility(VISIBILITY_SELF_HIT_TEST_INVISIBLE) end)
    refresh()
    isOpen = true
    set_mouse_mode(true)
end

local function hovered(w)
    return Util.safe(function() return w:IsHovered() end, false) == true
end

-- Left mouse button pressed (called on the game thread): act on whichever
-- button is under the cursor. No background polling: running Lua on a timer
-- thread while the game thread also runs Lua corrupts the Lua state.
function Menu.click()
    if not isOpen or order == nil then
        return
    end

    for _, clickable in ipairs(clickables) do
        if hovered(clickable.button) then
            clickable.action()
            return
        end
    end
end

function Menu.is_open()
    return isOpen
end

function Menu.up()
    if isOpen then
        move(-1)
        refresh()
    end
end

function Menu.down()
    if isOpen then
        move(1)
        refresh()
    end
end

function Menu.left()
    if isOpen then
        Menu.change(-1)
    end
end

function Menu.right()
    if isOpen then
        Menu.change(1)
    end
end

function Menu.enter()
    if isOpen then
        Menu.change(0)
    end
end

return Menu
