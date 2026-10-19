local Util = require("Modules.util")
local Categories = require("Modules.categories")
local Settings = require("Modules.settings")

-- On-screen layer menu built from plain UMG widgets (the approach Resource Markers uses in this game):
-- a centred panel with one column per group of sections; every row is clickable, keyboard works too.
local Menu = {}

local VISIBILITY_COLLAPSED, VISIBILITY_SELF_HIT_TEST_INVISIBLE = 1, 4
local MOUSE_LOCK_DO_NOT_LOCK, VALIGN_CENTER, DRAW_ROUNDED_BOX = 0, 2, 4

local COLUMNS = {
    { "General", "My stuff", "World" },
    { "Runecrafting", "Rocks & minerals" },
    { "Ores", "Trees" },
    { "Plants & materials" },
}

local FONT_TITLE, FONT_SUBTITLE, FONT_SECTION, FONT_ROW, FONT_HINT = 20, 11, 13, 12, 11
local STATE_WIDTH, COLUMN_GAP = 46, 30
local C = {
    panel = { R = 0.015, G = 0.017, B = 0.024, A = 0.92 }, outline = { R = 0.85, G = 0.66, B = 0.25, A = 0.55 },
    title = { R = 1.0, G = 0.8, B = 0.32, A = 1.0 }, subtitle = { R = 0.6, G = 0.6, B = 0.62, A = 1.0 },
    section = { R = 0.95, G = 0.74, B = 0.3, A = 1.0 }, rule = { R = 0.85, G = 0.66, B = 0.25, A = 0.3 },
    on = { R = 0.45, G = 0.9, B = 0.45, A = 1.0 }, off = { R = 0.55, G = 0.36, B = 0.36, A = 1.0 },
    value = { R = 0.45, G = 0.8, B = 1.0, A = 1.0 }, labelOn = { R = 0.93, G = 0.93, B = 0.93, A = 1.0 },
    labelOff = { R = 0.5, G = 0.5, B = 0.52, A = 1.0 }, labelSelected = { R = 1.0, G = 0.88, B = 0.45, A = 1.0 },
    rowSelected = { R = 1.0, G = 0.75, B = 0.2, A = 0.16 }, rowNormal = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 },
    hint = { R = 0.55, G = 0.55, B = 0.58, A = 1.0 }, arrow = { R = 1.0, G = 0.8, B = 0.35, A = 1.0 },
    closeBg = { R = 1.0, G = 1.0, B = 1.0, A = 0.06 }, transparent = { R = 1.0, G = 1.0, B = 1.0, A = 0.0 },
}

local columns, order = nil, nil  -- rows per column (with headers); selectable rows in navigation order
local selected, isOpen, widget, lookIgnored = 1, false, nil, false
local clickables = {}            -- { button, action }

Menu.on_change = nil  -- function(kind, id): kind = "layer" (id = layer) or the setting's key
Menu.key_name = "F7"
Menu.context = function() return nil end -- an object in the current world (main sets it), to find the player by

local function build_layout()
    local bySection = { General = { { kind = "toggle", key = "enabled", label = "Show icons" },
                                    { kind = "value", key = "icon_size", label = "Icon size" },
                                    { kind = "value", key = "group_m", label = "Group distance", unit = " m" },
                                    { kind = "toggle", key = "minimap", label = "Minimap" },
                                    { kind = "value", key = "minimap_m", label = "Minimap range", unit = " m" },
                                    { kind = "toggle", key = "counts", label = "Counts on groups" },
                                    { kind = "toggle", key = "clickable", label = "Clickable groups" } } }
    for _, category in ipairs(Categories) do
        local rows = bySection[category.section] or {}
        bySection[category.section] = rows
        rows[#rows + 1] = { kind = "layer", category = category }
    end
    columns, order = {}, {}
    for _, sections in ipairs(COLUMNS) do
        local column = {}
        for i, section in ipairs(sections) do
            if i > 1 then column[#column + 1] = { kind = "spacer" } end
            column[#column + 1] = { kind = "section", text = section }
            for _, row in ipairs(bySection[section] or {}) do column[#column + 1] = row end
        end
        columns[#columns + 1] = column
        for _, row in ipairs(column) do
            if row.kind == "toggle" or row.kind == "value" or row.kind == "layer" then
                order[#order + 1] = row
                row.order = #order
            end
        end
    end
end

local construct = Util.construct

local function set_text(textBlock, text, color)
    textBlock:SetText(FText(text))
    if color then textBlock:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end
end

local function make_text(tree, text, size, color, bold)
    local textBlock = construct("/Script/UMG.TextBlock", tree)
    textBlock.Font.Size = size
    if bold then pcall(function() textBlock.Font.TypefaceFontName = FName("Bold") end) end -- cosmetic
    set_text(textBlock, text, color)
    return textBlock
end

local function rounded(border, color, radius, outline)
    border:SetBrushColor(color)
    pcall(function() -- cosmetic: rounded corners and outline
        border.Background.DrawAs = DRAW_ROUNDED_BOX
        border.Background.OutlineSettings.RoundingType = 0
        border.Background.OutlineSettings.CornerRadii = { X = radius, Y = radius, Z = radius, W = radius }
        if outline then
            border.Background.OutlineSettings.Color = { SpecifiedColor = outline, ColorUseRule = 0 }
            border.Background.OutlineSettings.Width = 1.0
        end
    end)
end

local function add_v(box, child, padding)
    local slot = box:AddChildToVerticalBox(child)
    if padding then slot:SetPadding(padding) end
    return slot
end

local function add_h(box, child, padding)
    local slot = box:AddChildToHorizontalBox(child)
    slot:SetVerticalAlignment(VALIGN_CENTER)
    if padding then slot:SetPadding(padding) end
    return slot
end

local function pad(l, t, r, b) return { Left = l, Top = t, Right = r, Bottom = b } end

local function make_rule(tree)
    local box = construct("/Script/UMG.SizeBox", tree)
    box:SetHeightOverride(1.0)
    local line = construct("/Script/UMG.Border", tree)
    line:SetBrushColor(C.rule)
    box:SetContent(line)
    return box
end

local function row_state(row)
    if row.kind == "toggle" then
        local on = Settings[row.key]
        return on and "ON" or "OFF", on and C.on or C.off, on
    elseif row.kind == "value" then
        return tostring(Settings[row.key]) .. (row.unit or ""), C.value, true
    end
    local on = Settings.layers[row.category.id] == true
    return on and "ON" or "OFF", on and C.on or C.off, on
end

local function refresh()
    if not order then return end
    for index, row in ipairs(order) do
        local w = row.widgets
        if w and w.state:IsValid() then
            local text, color, on = row_state(row)
            set_text(w.state, text, color)
            set_text(w.label, row.label or row.category.label,
                index == selected and C.labelSelected or (on and C.labelOn or C.labelOff))
            w.border:SetBrushColor(index == selected and C.rowSelected or C.rowNormal)
        end
    end
end

-- A Button with invisible chrome, so our own Border provides the look.
local function make_button(tree, content)
    local button = construct("/Script/UMG.Button", tree)
    button:SetBackgroundColor(C.transparent)
    button.IsFocusable = false
    button.WidgetStyle.NormalPadding = pad(0, 0, 0, 0)
    button.WidgetStyle.PressedPadding = pad(0, 0, 0, 0)
    button:SetContent(content)
    return button
end

local function build_row(tree, row)
    local border = construct("/Script/UMG.Border", tree)
    rounded(border, C.rowNormal, 4)
    border:SetPadding(pad(6, 2, 10, 2))
    local line = construct("/Script/UMG.HorizontalBox", tree)
    border:SetContent(line)

    local stateBox = construct("/Script/UMG.SizeBox", tree)
    stateBox:SetWidthOverride(STATE_WIDTH)
    local state = make_text(tree, "", FONT_ROW, C.on, true)
    local index = row.order
    if row.kind == "value" then
        -- [<] value [>]
        stateBox:SetWidthOverride(STATE_WIDTH + 52)
        local controls = construct("/Script/UMG.HorizontalBox", tree)
        local minus = make_button(tree, make_text(tree, " < ", FONT_ROW, C.arrow, true))
        local plus = make_button(tree, make_text(tree, " > ", FONT_ROW, C.arrow, true))
        add_h(controls, minus)
        add_h(controls, state, pad(2, 0, 2, 0))
        add_h(controls, plus)
        stateBox:SetContent(controls)
        clickables[#clickables + 1] = { button = minus, action = function() selected = index Menu.change(-1) end }
        clickables[#clickables + 1] = { button = plus, action = function() selected = index Menu.change(1) end }
    else
        stateBox:SetContent(state)
    end
    add_h(line, stateBox)
    local label = make_text(tree, row.label or row.category.label, FONT_ROW, C.labelOn, false)
    add_h(line, label)
    row.widgets = { border = border, state = state, label = label }
    if row.kind == "value" then return border end
    local button = make_button(tree, border)
    clickables[#clickables + 1] = { button = button, action = function() selected = index Menu.change(0) end }
    return button
end

local function build_column(tree, rows)
    local box = construct("/Script/UMG.VerticalBox", tree)
    for i, row in ipairs(rows) do
        if row.kind == "section" then
            add_v(box, make_text(tree, row.text:upper(), FONT_SECTION, C.section, true), pad(6, i == 1 and 0 or 4, 0, 3))
            add_v(box, make_rule(tree), pad(6, 0, 6, 5))
        elseif row.kind == "spacer" then
            local spacer = construct("/Script/UMG.Spacer", tree)
            spacer:SetSize({ X = 1.0, Y = 12.0 })
            add_v(box, spacer)
        else
            add_v(box, build_row(tree, row), pad(0, 1, 0, 1))
        end
    end
    return box
end

local function build_widget()
    local controller = Util.local_player(Menu.context())
    if not controller then return false end
    local created, tree, canvas = Util.canvas_widget(controller)
    if not created then return false end

    local panel = construct("/Script/UMG.Border", tree)
    rounded(panel, C.panel, 10, C.outline)
    panel:SetPadding(pad(22, 16, 22, 14))
    local slot = canvas:AddChildToCanvas(panel)
    slot:SetAutoSize(true)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetPosition({ X = 0.0, Y = 0.0 })

    local main = construct("/Script/UMG.VerticalBox", tree)
    panel:SetContent(main)
    clickables = {}

    local header = construct("/Script/UMG.HorizontalBox", tree)
    local titles = construct("/Script/UMG.VerticalBox", tree)
    add_v(titles, make_text(tree, "Map layers", FONT_TITLE, C.title, true), pad(6, 0, 0, 0))
    add_v(titles, make_text(tree, "Choose what shows on your map and minimap", FONT_SUBTITLE, C.subtitle, false), pad(6, 0, 0, 0))
    add_h(header, titles):SetSize({ SizeRule = 1, Value = 1.0 })
    local closeBg = construct("/Script/UMG.Border", tree)
    rounded(closeBg, C.closeBg, 4)
    closeBg:SetPadding(pad(10, 3, 10, 3))
    closeBg:SetContent(make_text(tree, "Close", FONT_HINT + 1, C.labelOn, true))
    local close = make_button(tree, closeBg)
    add_h(header, close)
    clickables[#clickables + 1] = { button = close, action = function() Menu.toggle() end }
    add_v(main, header, pad(0, 0, 0, 10))
    add_v(main, make_rule(tree), pad(0, 0, 0, 12))

    local row = construct("/Script/UMG.HorizontalBox", tree)
    for index, rows in ipairs(columns) do
        local columnSlot = row:AddChildToHorizontalBox(build_column(tree, rows))
        columnSlot:SetPadding(pad(0, 0, index < #columns and COLUMN_GAP or 0, 0))
        columnSlot:SetVerticalAlignment(0)
    end
    add_v(main, row)
    add_v(main, make_rule(tree), pad(0, 12, 0, 8))
    add_v(main, make_text(tree, "Click to change      or  arrows + Enter      " .. Menu.key_name .. "  close",
        FONT_HINT, C.hint, false), pad(6, 0, 0, 0))

    widget = created
    refresh()
    widget:AddToViewport(500)
    return true
end

-- direction: -1 = left, 1 = right, 0 = enter / click
function Menu.change(direction)
    local row = order and order[selected]
    if not row then return end
    local kind, id = row.kind, nil
    if row.kind == "toggle" then
        Settings[row.key] = not Settings[row.key]
        kind = row.key
    elseif row.kind == "value" then
        local lo, hi, step = table.unpack(Settings.RANGES[row.key])
        local value = Settings[row.key] + (direction == 0 and step or direction * step)
        if direction == 0 and value > hi then value = lo end
        Settings[row.key] = math.max(lo, math.min(hi, value))
        kind = row.key
    else
        id = row.category.id
        Settings.layers[id] = not Settings.layers[id]
    end
    Settings.save()
    refresh()
    if Menu.on_change then Menu.on_change(kind, id) end
end

-- Cursor on and clicks to the menu while it's open; camera look frozen so moving the mouse doesn't spin the view.
local function set_mouse_mode(on)
    local controller = Util.local_player(Menu.context())
    if not controller then return end
    local library = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    controller.bShowMouseCursor = on
    if on then
        library:SetInputMode_GameAndUIEx(controller, widget, MOUSE_LOCK_DO_NOT_LOCK, false, false)
        if not lookIgnored then controller:SetIgnoreLookInput(true) lookIgnored = true end
    else
        library:SetInputMode_GameOnly(controller, false)
        if lookIgnored then controller:SetIgnoreLookInput(false) lookIgnored = false end
    end
end

function Menu.toggle()
    if isOpen then
        isOpen = false
        if widget and widget:IsValid() then widget:SetVisibility(VISIBILITY_COLLAPSED) end
        set_mouse_mode(false)
        return
    end
    if not columns then build_layout() end
    if not (widget and widget:IsValid() and widget:IsInViewport()) then
        widget = nil
        if not build_widget() then
            Util.log("Menu: not available yet (no local player).")
            return
        end
    end
    widget:SetVisibility(VISIBILITY_SELF_HIT_TEST_INVISIBLE)
    refresh()
    isOpen = true
    set_mouse_mode(true)
end

function Menu.is_open() return isOpen end

-- Left click while open: act on whichever button is under the cursor.
function Menu.click()
    for _, c in ipairs(clickables) do
        if c.button:IsHovered() then
            c.action()
            return
        end
    end
end

local function move(delta)
    selected = ((selected - 1 + delta) % #order) + 1
    refresh()
end
function Menu.up() move(-1) end
function Menu.down() move(1) end
function Menu.left() Menu.change(-1) end
function Menu.right() Menu.change(1) end
function Menu.enter() Menu.change(0) end

return Menu
