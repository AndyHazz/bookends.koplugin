--[[
Bookends colour palette picker.

A grid of 25 curated swatches (5 families of 5 shades) plus a hex input for
custom values. Tap-to-preview: every swatch tap applies immediately via the
apply_callback, so the book repaints around the edges of the dialog; Apply
just closes, Cancel reverts via revert_callback, Default clears the field.

Storage shape is always {hex = "#RRGGBB"} — the palette is pure UX; changing
the palette in a future release doesn't invalidate any stored preset.
]]

local _ = require("bookends_i18n").gettext

local Blitbuffer        = require("ffi/blitbuffer")
local CenterContainer   = require("ui/widget/container/centercontainer")
local Device            = require("device")
local FocusManager      = require("ui/widget/focusmanager")
local FrameContainer    = require("ui/widget/container/framecontainer")
local Geom              = require("ui/geometry")
local GestureRange      = require("ui/gesturerange")
local HorizontalGroup   = require("ui/widget/horizontalgroup")
local HorizontalSpan    = require("ui/widget/horizontalspan")
local InputContainer    = require("ui/widget/container/inputcontainer")
local InputText         = require("ui/widget/inputtext")
local LineWidget        = require("ui/widget/linewidget")
local MovableContainer  = require("ui/widget/container/movablecontainer")
local Notification      = require("ui/widget/notification")
local Size              = require("ui/size")
local TextWidget        = require("ui/widget/textwidget")
local TitleBar          = require("ui/widget/titlebar")
local UIManager         = require("ui/uimanager")
local VerticalGroup     = require("ui/widget/verticalgroup")
local VerticalSpan      = require("ui/widget/verticalspan")
local WidgetContainer   = require("ui/widget/container/widgetcontainer")
local Font              = require("ui/font")
local Screen            = Device.screen

-- 5 rows × 5 cols: neutrals / warm dark / warm light / cool dark / cool light.
-- Luminance-separated rows so dark/light pairings survive the greyscale fallback.
local PALETTE = {
    { "#000000", "#404040", "#808080", "#BFBFBF", "#FFFFFF" },
    { "#8B1A1A", "#B8570F", "#6B3E26", "#8B6914", "#5E2B1B" },
    { "#E8A0B8", "#F4B58C", "#D4A574", "#E8D990", "#E89B8C" },
    { "#1B2A5E", "#2D4A2B", "#1F5E5E", "#4A2B5E", "#2B3A4A" },
    { "#A0C4E8", "#A0D4B8", "#C4A0E8", "#B8D4E8", "#E8A0C4" },
}

local SWATCH_SIDE  = Screen:scaleBySize(60)
local SWATCH_GAP   = Screen:scaleBySize(8)
local SWATCH_RADIUS = Size.radius.default

-- Swatch: a rounded coloured square that renders via paintRoundedRectRGB32.
-- A WidgetContainer subclass — owns its own dimen, not a CenterContainer.
local Swatch = WidgetContainer:extend{
    dimen    = nil,
    hex      = nil,
    selected = false,
    side     = nil,
}

function Swatch:init()
    local r = tonumber(self.hex:sub(2, 3), 16)
    local g = tonumber(self.hex:sub(4, 5), 16)
    local b = tonumber(self.hex:sub(6, 7), 16)
    self._fill = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

function Swatch:getSize()
    return Geom:new{ w = self.side, h = self.side }
end

function Swatch:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.side, h = self.side }
    local r = SWATCH_RADIUS
    bb:paintRoundedRectRGB32(x, y, self.side, self.side, self._fill, r)
    local bw = self.selected and Size.border.thick or Size.border.thin
    local bc = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    bb:paintBorder(x, y, self.side, self.side, bw, bc, r)
end

-- swatchTile: InputContainer wrapping a Swatch for gesture handling.
local function swatchTile(hex, selected, side, on_tap)
    local swatch = Swatch:new{ hex = hex, selected = selected, side = side }
    local container = InputContainer:new{
        dimen = Geom:new{ w = side, h = side },
        swatch,
    }
    container.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = container.dimen },
        },
    }
    function container:onTapSelect()
        on_tap(hex)
        return true
    end
    return container
end

-- Footer button: plain text in a tappable InputContainer, matching the
-- preset-library modal's Close | Manage… | Apply row (no bezel, just text
-- plus a vertical LineWidget divider between buttons — see preset_manager_modal.lua).
local function makeFooterBtn(text, width, height, on_tap)
    local label = TextWidget:new{
        text     = text,
        face     = Font:getFace("cfont", 18),
        bold     = true,
        fgcolor  = Blitbuffer.COLOR_BLACK,
    }
    local ic = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, label },
    }
    ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
    ic.onTapSelect = function() on_tap(); return true end
    return ic
end

local ColourPaletteWidget = FocusManager:extend{
    title            = nil,
    selected_hex     = nil,
    apply_callback   = nil,
    default_callback = nil,
    revert_callback  = nil,
    ok_callback      = nil,
}

function ColourPaletteWidget:init()
    self.screen_width  = Screen:getWidth()
    self.screen_height = Screen:getHeight()

    -- Dialog inner width: palette grid + outer padding on each side.
    self.palette_width = SWATCH_SIDE * 5 + SWATCH_GAP * 4
    self.inner_width   = self.palette_width + Size.padding.large * 2
    self.dialog_width  = self.inner_width + 2 * Size.border.thin

    if Device:isTouchDevice() then
        self.ges_events = {
            TapOutside = {
                GestureRange:new{
                    ges   = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height,
                    },
                },
            },
        }
    end

    self:update()
end

function ColourPaletteWidget:onTapOutside()
    -- Silently consume taps outside the dialog frame (non-dismissable).
    return true
end

function ColourPaletteWidget:update()
    local side = SWATCH_SIDE
    local gap  = SWATCH_GAP
    local iw   = self.inner_width

    -- Palette grid: explicit VerticalSpan + HorizontalGroup rows. NB. KOReader's
    -- VerticalSpan uses `width` as its extent along the group's axis — using
    -- `height` gives a zero-extent span, collapsing the row gap.
    local palette_vgroup = VerticalGroup:new{ align = "center" }
    for row_idx, row_hexes in ipairs(PALETTE) do
        local hgroup = HorizontalGroup:new{ align = "center" }
        for col_idx, hex in ipairs(row_hexes) do
            if col_idx > 1 then
                hgroup[#hgroup + 1] = HorizontalSpan:new{ width = gap }
            end
            local is_selected = (hex == self.selected_hex)
            hgroup[#hgroup + 1] = swatchTile(hex, is_selected, side, function(tapped_hex)
                self.selected_hex = tapped_hex
                if self.apply_callback then self.apply_callback(tapped_hex) end
                self:update()
            end)
        end
        if row_idx > 1 then
            palette_vgroup[#palette_vgroup + 1] = VerticalSpan:new{ width = gap }
        end
        palette_vgroup[#palette_vgroup + 1] = hgroup
    end

    -- Hex row: card-like FrameContainer around the InputText, with a "Hex:" label
    -- outside on the left and a plain "Set" tap target on the right.
    local hex_face = Font:getFace("cfont", 18)
    local hex_label = TextWidget:new{
        text    = _("Hex:"),
        face    = hex_face,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    self.hex_input = InputText:new{
        text           = self.selected_hex or "",
        hint           = "#RRGGBB",
        input_type     = "string",
        width          = Screen:scaleBySize(140),
        face           = hex_face,
        focused        = false,
        parent         = self,
        enter_callback = function() self:onHexSubmit() end,
    }
    local hex_input_frame = FrameContainer:new{
        bordersize = Size.border.thin,
        radius     = Size.radius.default,
        padding    = Size.padding.small,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.hex_input,
    }
    local set_btn_w = Screen:scaleBySize(60)
    local set_btn_h = Screen:scaleBySize(36)
    local set_btn = makeFooterBtn(_("Set"), set_btn_w, set_btn_h, function() self:onHexSubmit() end)
    local hex_row = HorizontalGroup:new{
        align = "center",
        hex_label,
        HorizontalSpan:new{ width = Size.padding.default },
        hex_input_frame,
        HorizontalSpan:new{ width = Size.padding.small },
        set_btn,
    }

    -- Footer row: Cancel | Default | Apply, matching the preset-library modal's
    -- Close | Manage… | Apply pattern (no button borders, LineWidget dividers).
    local footer_h = Screen:scaleBySize(44)
    local btn_w    = math.floor(iw / 3)
    local cancel_btn  = makeFooterBtn(_("Cancel"),  btn_w, footer_h,
        function() if self.revert_callback  then self.revert_callback()  end end)
    local default_btn = makeFooterBtn(_("Default"), btn_w, footer_h,
        function() if self.default_callback then self.default_callback() end end)
    local apply_btn   = makeFooterBtn(_("Apply"),   btn_w, footer_h,
        function() if self.ok_callback      then self.ok_callback()      end end)

    local vdiv_inset = Screen:scaleBySize(10)
    local vdiv = function() return CenterContainer:new{
        dimen = Geom:new{ w = Size.line.thin, h = footer_h },
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{ w = Size.line.thin, h = footer_h - 2 * vdiv_inset },
        },
    } end

    local footer_row = HorizontalGroup:new{
        cancel_btn, vdiv(), default_btn, vdiv(), apply_btn,
    }
    local footer_separator = LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen      = Geom:new{ w = iw, h = Size.line.thin },
    }

    local title_bar = TitleBar:new{
        width            = self.dialog_width,
        title            = self.title or _("Pick a color"),
        with_bottom_line = true,
        show_parent      = self,
    }

    local vgroup = VerticalGroup:new{
        align = "center",
        title_bar,
        VerticalSpan:new{ width = Size.padding.large },
        CenterContainer:new{
            dimen = Geom:new{ w = iw, h = side * 5 + gap * 4 },
            palette_vgroup,
        },
        VerticalSpan:new{ width = Size.padding.large },
        CenterContainer:new{
            dimen = Geom:new{ w = iw, h = Screen:scaleBySize(48) },
            hex_row,
        },
        VerticalSpan:new{ width = Size.padding.default },
        footer_separator,
        footer_row,
    }

    local frame = FrameContainer:new{
        radius     = Size.radius.window,
        bordersize = Size.border.thin,
        padding    = 0,
        margin     = 0,
        background = Blitbuffer.COLOR_WHITE,
        vgroup,
    }

    local movable = MovableContainer:new{ frame }

    -- CenterContainer dimen is set once at construction and never reassigned
    -- post-paint (see feedback_centercontainer_dimen.md).
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            x = 0, y = 0,
            w = self.screen_width, h = self.screen_height,
        },
        movable,
    }

    UIManager:setDirty(self, "ui")
end

function ColourPaletteWidget:onHexSubmit()
    local txt = self.hex_input:getText()
    if not txt then return end
    local hex = txt:match("^%s*(#?%x%x%x%x%x%x)%s*$")
    if not hex then
        Notification:notify(_("Invalid hex colour (use #RRGGBB)"))
        return
    end
    if hex:sub(1, 1) ~= "#" then hex = "#" .. hex end
    hex = hex:upper()
    self.selected_hex = hex
    if self.apply_callback then self.apply_callback(hex) end
    self:update()
end

function ColourPaletteWidget:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

-- Public entry point.
local function showColourPicker(bookends, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance)
    local restoreMenu = bookends:hideMenu(touchmenu_instance)

    local closed = false
    local function finish()
        if closed then return end
        closed = true
        restoreMenu()
    end

    local widget
    widget = ColourPaletteWidget:new{
        title            = title or _("Pick a color"),
        selected_hex     = current_hex,
        apply_callback   = on_apply,
        default_callback = function()
            UIManager:close(widget)
            if on_default then on_default() end
            finish()
        end,
        revert_callback  = function()
            UIManager:close(widget)
            if on_revert then on_revert() end
            finish()
        end,
        ok_callback      = function()
            UIManager:close(widget)
            finish()
        end,
    }
    UIManager:show(widget)
end

local M = {}
function M.attach(Bookends)
    function Bookends:showColourPicker(title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance)
        showColourPicker(self, title, current_hex, default_hex, on_apply, on_default, on_revert, touchmenu_instance)
    end
end
return M
