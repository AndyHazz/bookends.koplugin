--[[
Monkey-patch KOReader's TextWidget.paintTo so a ColorRGB32 `fgcolor` renders
as true colour on a BBRGB32 buffer.

Why this exists: TextWidget hardcodes `bb:colorblitFrom(...)`, which flattens
ColorRGB32 to Color8A(luminance) before blitting. TextBoxWidget already does
the right thing — see textboxwidget.lua, which dispatches to
`colorblitFromRGB32` when `color_fg` is set — but TextWidget never got the
same treatment. Bookends needs coloured overlay text on colour devices, so we
add the dispatch here.

The patch is strictly additive: the only callers passing a ColorRGB32 today
were already getting silent luminance flattening, so changing their output to
true colour is never a regression. When `fgcolor` is not a ColorRGB32 we fall
through to the original implementation unchanged.

Remove this patch once upstream TextWidget gains RGB32 dispatch natively.
]]

local ffi = require("ffi")
local logger = require("logger")
local TextWidget = require("ui/widget/textwidget")
local RenderText = require("ui/rendertext")
local ColorRGB32_t = ffi.typeof("ColorRGB32")

-- Feature-probe: abort the patch if the underlying primitive is missing
-- (very old KOReader versions). Falling through to upstream is safe — text
-- just renders as luminance grey like before.
local _bb_probe = require("ffi/blitbuffer").new(1, 1)
if type(_bb_probe.colorblitFromRGB32) ~= "function" then
    logger.info("bookends: colorblitFromRGB32 not available, skipping TextWidget patch")
    return
end

local orig_paintTo = TextWidget.paintTo

function TextWidget:paintTo(bb, x, y)
    -- Fast path: not a ColorRGB32 → upstream behaviour unchanged.
    if not (self.fgcolor and ffi.istype(ColorRGB32_t, self.fgcolor)) then
        return orig_paintTo(self, bb, x, y)
    end

    if self._is_empty then return end

    -- Non-xtext fallback: upstream calls RenderText:renderUtf8Text which
    -- bottoms out in colorblitFrom. We don't touch that path — modern
    -- KOReader defaults use_xtext=true, and non-xtext rendering of overlay
    -- text is vanishingly rare. If it fires, text renders as luminance grey
    -- (same as before this patch).
    if not self.use_xtext then
        return orig_paintTo(self, bb, x, y)
    end

    -- xtext glyph-shaped path — replicate upstream's loop but blit via
    -- colorblitFromRGB32 so the ColorRGB32 fgcolor lands intact on a
    -- BBRGB32 buffer (or through its RGB32-aware setter on other buffer
    -- types, which still does the right luminance thing on Color8 buffers).
    if not self._xshaping then
        self._xshaping = self._xtext:shapeLine(
            self._shape_start, self._shape_end,
            self._shape_idx_to_substitute_with_ellipsis)
    end

    local text_width = bb:getWidth() - x
    if self.max_width and self.max_width < text_width then
        text_width = self.max_width
    end
    local pen_x = 0
    local baseline = self.forced_baseline or self._baseline_h
    for _i, xglyph in ipairs(self._xshaping) do
        if pen_x >= text_width then break end
        local face = self.face.getFallbackFont(xglyph.font_num)
        local glyph = RenderText:getGlyphByIndex(face, xglyph.glyph, self.bold)
        bb:colorblitFromRGB32(
            glyph.bb,
            x + pen_x + glyph.l + xglyph.x_offset,
            y + baseline - glyph.t - xglyph.y_offset,
            0, 0,
            glyph.bb:getWidth(), glyph.bb:getHeight(),
            self.fgcolor)
        pen_x = pen_x + xglyph.x_advance
    end
end
