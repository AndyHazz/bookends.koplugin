--[[
Central colour-value helpers.

Every colour setting in Bookends (text_color, symbol_color, bar_colors.{fill,
bg, track, tick, border, invert, metro_fill}) can be stored in one of three
shapes:

  - table with .hex = "#RRGGBB"    -- v4.3+ colour-picker authoring
  - table with .grey = 0xNN        -- v2+ greyscale nudge (text/symbol)
  - raw byte 0..0xFF               -- legacy bar_colors shape (pre-v4)

parseColorValue folds all three into a Blitbuffer colour object:
  * Colour-enabled screens: hex → ColorRGB32, grey/byte → Color8.
  * Greyscale screens: hex → Color8 of the Rec.601 luminance (so presets
    authored on colour devices still render sensibly on Kindle/older Kobo).

The hex → colour conversion is memoised in a module-local table; toggling
KOReader's colour-rendering mode at runtime must call flushCache() to drop
stale ColorRGB32 values cached from the previous mode (ColorRGB32 on a now-
greyscale screen would go through Blitbuffer's default 32→8 converter rather
than our Rec.601 luminance helper, which looks subtly different on photos).
]]

local Blitbuffer = require("ffi/blitbuffer")

local Colour = {}

local _hex_cache = {}

-- Default hex for each field when the user taps "Default" in the picker.
-- nil means "clear the setting entirely" (fall back to the field's own
-- default-colour logic in the render path).
local DEFAULT_HEX = {
    fill        = "#404040",  -- matches the 75%-black greyscale default
    bg          = "#BFBFBF",  -- matches the 25%-black greyscale default
    track       = "#404040",
    tick        = "#000000",
    border      = "#000000",
    invert      = "#FFFFFF",
    metro_fill  = "#000000",
    text_color  = nil,        -- "book text colour" — clear rather than default
    symbol_color = nil,       -- "match text" — clear rather than default
}

function Colour.defaultHexFor(field) return DEFAULT_HEX[field] end

--- Parse a stored colour value into a Blitbuffer colour object.
--- Returns nil if v is nil, false if v is false (transparent).
function Colour.parseColorValue(v, is_color_enabled)
    if v == nil then return nil end
    if v == false then return false end

    if type(v) == "table" and v.hex then
        local key = v.hex .. (is_color_enabled and ":c" or ":g")
        local cached = _hex_cache[key]
        if cached then return cached end
        local hex = v.hex
        if hex:sub(1, 1) ~= "#" or #hex ~= 7 then return nil end
        local r = tonumber(hex:sub(2, 3), 16)
        local g = tonumber(hex:sub(4, 5), 16)
        local b = tonumber(hex:sub(6, 7), 16)
        if not (r and g and b) then return nil end
        local out
        if is_color_enabled then
            out = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
        else
            -- Rec.601 luminance, rounded to 0..255.
            local lum = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
            out = Blitbuffer.Color8(lum)
        end
        _hex_cache[key] = out
        return out
    end

    if type(v) == "table" and v.grey then
        if v.grey >= 0xFF then return false end
        return Blitbuffer.Color8(v.grey)
    end

    if type(v) == "number" then
        if v >= 0xFF then return false end
        return Blitbuffer.Color8(v)
    end

    return nil
end

function Colour.flushCache()
    _hex_cache = {}
end

return Colour
