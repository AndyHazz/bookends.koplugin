local Blitbuffer = require("ffi/blitbuffer")
local Colour = require("bookends_colour")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Utf8Proc = require("ffi/utf8proc")
local Screen = Device.screen

-- Helper: resolve a text/symbol colour table ({grey=N} or {hex=H}) to a
-- Blitbuffer colour object on the current screen. Returns nil when v is nil.
local function resolveTextColor(v)
    if v == nil then return nil end
    return Colour.parseColorValue(v, Device:screen():isColorEnabled())
end

local OverlayWidget = {}

-- Default TextWidget options for overlay text.
-- use_book_text_color ensures text matches the book's color scheme
-- (compatible with color theme patches like koreader-color-themes).
-- When fgcolor is provided, use it instead (disabling use_book_text_color).
local function textWidgetOpts(t, fgcolor)
    if fgcolor then
        t.fgcolor = fgcolor
    else
        t.use_book_text_color = true
    end
    return t
end

-- Cache for font variant lookups (face_name:style -> path or false)
local _variant_cache = {}

--- Find a style variant (bold, italic, bolditalic) of a font by filename patterns.
-- Searches installed fonts for variants matching common naming conventions.
-- Results are cached per (face_name, style) pair.
-- @param face_name string: path/name of the base font
-- @param style string: "bold", "italic", or "bolditalic"
-- @return string or false: path to variant font, or false if not found
function OverlayWidget.findFontVariant(face_name, style)
    local cache_key = face_name .. "\0" .. style
    if _variant_cache[cache_key] ~= nil then
        return _variant_cache[cache_key]
    end

    local ok, FontList = pcall(require, "fontlist")
    if not ok then
        _variant_cache[cache_key] = false
        return false
    end
    local all_fonts = FontList:getFontList()

    local basename = face_name:match("([^/]+)$") or face_name
    local name_no_ext = (basename:gsub("%.[^.]+$", ""))

    local candidates = {}
    if style == "italic" then
        if name_no_ext:match("[Rr]egular") then
            table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "Italic")))
        end
        if name_no_ext:match("[Bb]old") and not name_no_ext:match("[Ii]talic") then
            table.insert(candidates, (name_no_ext:gsub("[Bb]old", "BoldItalic")))
            table.insert(candidates, (name_no_ext:gsub("[Bb]old", "Bold Italic")))
        end
        table.insert(candidates, name_no_ext .. "-Italic")
        table.insert(candidates, name_no_ext .. " Italic")
        table.insert(candidates, name_no_ext .. "Italic")
    elseif style == "bold" then
        if name_no_ext:match("[Rr]egular") then
            table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "Bold")))
        end
        table.insert(candidates, name_no_ext .. "-Bold")
        table.insert(candidates, name_no_ext .. " Bold")
        table.insert(candidates, name_no_ext .. "Bold")
    elseif style == "bolditalic" then
        if name_no_ext:match("[Rr]egular") then
            table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "Bold Italic")))
            table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "BoldItalic")))
            table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "Bold-Italic")))
        end
        table.insert(candidates, name_no_ext .. "-Bold Italic")
        table.insert(candidates, name_no_ext .. "-BoldItalic")
        table.insert(candidates, name_no_ext .. " Bold Italic")
        table.insert(candidates, name_no_ext .. " BoldItalic")
        table.insert(candidates, name_no_ext .. "BoldItalic")
    end

    -- First try: filename pattern matching (handles standard naming conventions)
    for _, candidate in ipairs(candidates) do
        local pattern = candidate:lower()
        for _, font_path in ipairs(all_fonts) do
            local font_name = font_path:match("([^/]+)$") or ""
            local font_no_ext = font_name:gsub("%.[^.]+$", "")
            if font_no_ext:lower() == pattern then
                _variant_cache[cache_key] = font_path
                return font_path
            end
        end
    end

    -- Second try: fontinfo metadata (handles non-standard naming like LinBiolinum_R/_RI/_RB)
    FontList:getFontList() -- ensure fontinfo is populated
    local base_info = FontList.fontinfo[face_name]
    if base_info and base_info[1] then
        local base_name = base_info[1].name
        local want_bold = (style == "bold" or style == "bolditalic")
        local want_italic = (style == "italic" or style == "bolditalic")
        for file, info_arr in pairs(FontList.fontinfo) do
            local info = info_arr[1]
            if info and info.name == base_name
               and (info.bold == want_bold) and (info.italic == want_italic)
               and file ~= face_name then
                _variant_cache[cache_key] = file
                return file
            end
        end
    end

    _variant_cache[cache_key] = false
    return false
end

--- Backward-compatible wrapper.
function OverlayWidget.findItalicVariant(face_name)
    return OverlayWidget.findFontVariant(face_name, "italic")
end

--- Simple multi-line widget that paints TextWidgets stacked vertically.
-- Avoids VerticalGroup to ensure reliable rendering on e-ink devices.
local MultiLineWidget = {}
MultiLineWidget.__index = MultiLineWidget

function MultiLineWidget:new(o)
    return setmetatable(o or {}, self)
end

function MultiLineWidget:paintTo(bb, x, y)
    local y_offset = 0
    for _, entry in ipairs(self.lines) do
        local lx = x + (entry.h_nudge or 0)
        if self.align == "center" then
            lx = x + math.floor((self.width - entry.w) / 2) + (entry.h_nudge or 0)
        elseif self.align == "right" then
            lx = x + self.width - entry.w + (entry.h_nudge or 0)
        end
        entry.widget:paintTo(bb, lx, y + y_offset + (entry.v_nudge or 0))
        y_offset = y_offset + entry.h
    end
end

function MultiLineWidget:getSize()
    return { w = self.width, h = self.height }
end

function MultiLineWidget:free()
    for _, entry in ipairs(self.lines) do
        if entry.widget and entry.widget.free then
            entry.widget:free()
        end
    end
    self.lines = {}
end

--- A progress bar widget that renders a filled rectangle with optional chapter ticks.
-- Supports "thick" (bordered, rounded) and "thin" (flat, minimal) styles.
local BarWidget = {}
BarWidget.__index = BarWidget

function BarWidget:new(o)
    o = o or {}
    setmetatable(o, self)
    o.width = o.width or 100
    o.height = o.height or 5
    o.fraction = math.max(0, math.min(1, o.fraction or 0))
    o.ticks = o.ticks or {}
    o.style = o.style or "bordered"
    return o
end

function BarWidget:getSize()
    return { w = self.width, h = self.height }
end

function BarWidget:paintTo(bb, x, y)
    -- Delegate to paintProgressBar for consistent color handling
    OverlayWidget.paintProgressBar(bb, x, y, self.width, self.height,
        self.fraction, self.ticks, self.style, nil, false, self.colors)
end

function BarWidget:free()
    -- Nothing to free — pure blitbuffer painting
end

--- A horizontal row of widgets (text + bar segments) painted left-to-right.
-- Each segment is vertically centered within the row height.
local HorizontalRowWidget = {}
HorizontalRowWidget.__index = HorizontalRowWidget

function HorizontalRowWidget:new(o)
    o = o or {}
    setmetatable(o, self)
    o.segments = o.segments or {}
    o.width = o.width or 0
    o.height = o.height or 0
    return o
end

function HorizontalRowWidget:getSize()
    return { w = self.width, h = self.height }
end

function HorizontalRowWidget:paintTo(bb, x, y)
    local x_offset = 0
    for _, seg in ipairs(self.segments) do
        local seg_y = y + math.floor((self.height - seg.h) / 2)
        seg.widget:paintTo(bb, x + x_offset, seg_y)
        x_offset = x_offset + seg.w
    end
end

function HorizontalRowWidget:free()
    for _, seg in ipairs(self.segments) do
        if seg.widget and seg.widget.free then
            seg.widget:free()
        end
    end
    self.segments = {}
end

-- U+FFFC OBJECT REPLACEMENT CHARACTER — placeholder for bar position in text
local BAR_PLACEHOLDER = "\xEF\xBF\xBC"
OverlayWidget.BAR_PLACEHOLDER = BAR_PLACEHOLDER

--- Build a HorizontalRowWidget for a line that contains a bar token.
-- Text is split on the BAR_PLACEHOLDER to preserve before/after segments.
-- @param text string: text with BAR_PLACEHOLDER where the bar goes
-- @param cfg table: line config with .bar = {kind, pct, ticks}, .face, .bold, etc.
-- @param available_w number: total available width for this line
-- @param max_width number or nil: truncation limit
-- @return widget, width, height
local function buildBarLine(text, cfg, available_w, max_width)
    local bar_info = cfg.bar
    -- Height precedence: inline %bar{v…} overrides the line's bar_height setting,
    -- which in turn overrides the line-font-size default.
    local bar_h = (bar_info and bar_info.height)
        or cfg.bar_height or (cfg.face and cfg.face.size) or 5
    local bar_style = cfg.bar_style or "bordered"
    local effective_w = max_width or available_w

    -- Split text on placeholder to get before/after segments
    local before, after = text:match("^(.-)" .. BAR_PLACEHOLDER .. "(.*)$")
    if not before then
        before = text
        after = ""
    end

    -- Build text segments and measure total text width
    local segments = {}
    local total_w = 0
    local max_h = 0
    local text_total_w = 0

    local function addTextSegment(t)
        if t == "" then return end
        local display = cfg.uppercase and Utf8Proc.uppercase_dumb(t) or t
        local text_fgcolor = resolveTextColor(cfg.text_color)
        local tw = TextWidget:new(textWidgetOpts({
            text = display,
            face = cfg.face,
            bold = cfg.bold,
        }, text_fgcolor))
        local size = tw:getSize()
        table.insert(segments, { widget = tw, w = size.w, h = size.h })
        total_w = total_w + size.w
        text_total_w = text_total_w + size.w
        if size.h > max_h then max_h = size.h end
    end

    -- Before text
    addTextSegment(before)

    -- Bar (placeholder slot)
    local bar_manual_w = (bar_info and bar_info.width) or 0
    local bar_slot = #segments + 1  -- remember where to insert bar

    -- After text
    addTextSegment(after)

    -- Ensure row height matches font line height for consistent vertical alignment
    if text_total_w == 0 and cfg.face then
        local ref_tw = TextWidget:new(textWidgetOpts({ text = " ", face = cfg.face, bold = cfg.bold }))
        local ref_h = ref_tw:getSize().h
        ref_tw:free()
        if ref_h > max_h then max_h = ref_h end
    end

    -- Calculate bar width
    local bar_w
    if bar_manual_w > 0 then
        bar_w = math.min(bar_manual_w, math.max(0, effective_w - text_total_w))
    else
        bar_w = math.max(0, effective_w - text_total_w)
    end
    -- Radial bars are circular — clamp width to height so they stay square
    if bar_style == "radial" or bar_style == "radial_hollow" then
        bar_w = math.min(bar_w, bar_h)
    end

    if bar_w < 1 then
        -- No room for bar
        if #segments > 0 then
            local row = HorizontalRowWidget:new{
                segments = segments,
                width = total_w,
                height = max_h,
            }
            return row, total_w, max_h
        end
        return nil, 0, 0
    end

    local bar_widget = BarWidget:new{
        width = bar_w,
        height = bar_h,
        fraction = bar_info.pct or 0,
        ticks = bar_info.ticks or {},
        style = bar_style,
        colors = cfg.bar_colors,
    }

    table.insert(segments, bar_slot, { widget = bar_widget, w = bar_w, h = bar_h })
    total_w = total_w + bar_w
    if bar_h > max_h then max_h = bar_h end

    local row = HorizontalRowWidget:new{
        segments = segments,
        width = total_w,
        height = max_h,
    }
    return row, total_w, max_h
end

--- Build a TextWidget or MultiLineWidget for a single line or multi-line string.
-- @param text string: the expanded text (may contain newlines)
-- @param line_configs table: array of {face=, bold=} per line
-- @param h_anchor string: "left", "center", or "right"
-- @param max_width number or nil: if set, truncate lines to this pixel width
-- @param available_w number or nil: total available width (used for bar lines)
-- @return widget, width, height
function OverlayWidget.buildTextWidget(text, line_configs, h_anchor, max_width, available_w)
    if max_width and max_width <= 0 then
        return nil, 0, 0
    end

    local lines = {}
    for line in text:gmatch("([^\n]+)") do
        table.insert(lines, line)
    end
    if #lines == 0 then
        return nil, 0, 0
    end

    -- Get config for line i (fall back to last config if fewer configs than lines).
    -- Last-ditch fallback uses cfont explicitly: TextWidget crashes in
    -- font.lua's getAdjustedFace if face is nil, which has bitten us when
    -- a user's configured font failed to load at freetype level.
    local function getConfig(i)
        return line_configs[i] or line_configs[#line_configs]
            or { face = Font:getFace("cfont"), bold = false }
    end

    if #lines == 1 then
        local cfg = getConfig(1)
        -- Try styled segments (BBCode tags or bar placeholder)
        local segments, has_tags = OverlayWidget.parseStyledSegments(
            lines[1], cfg.bold, cfg.italic or false, cfg.uppercase)
        if segments then
            return OverlayWidget.buildStyledLine(segments, cfg, available_w or Screen:getWidth(), max_width)
        end
        -- Bar line without tags
        if cfg.bar then
            return buildBarLine(lines[1], cfg, available_w or Screen:getWidth(), max_width)
        end
        -- Plain text — fast path
        local display_text = cfg.uppercase and Utf8Proc.uppercase_dumb(lines[1]) or lines[1]
        local text_fgcolor = resolveTextColor(cfg.text_color)
        local tw = TextWidget:new(textWidgetOpts({
            text = display_text,
            face = cfg.face,
            bold = cfg.bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        }, text_fgcolor))
        local size = tw:getSize()
        return tw, size.w, size.h
    end

    local align = "center"
    if h_anchor == "left" then
        align = "left"
    elseif h_anchor == "right" then
        align = "right"
    end

    local line_entries = {}
    local max_w = 0
    local total_h = 0
    for i, line in ipairs(lines) do
        local cfg = getConfig(i)
        local widget, w, h
        -- Try styled segments (BBCode tags or bar placeholder)
        local segments, has_tags = OverlayWidget.parseStyledSegments(
            line, cfg.bold, cfg.italic or false, cfg.uppercase)
        if segments then
            widget, w, h = OverlayWidget.buildStyledLine(segments, cfg, available_w or Screen:getWidth(), max_width)
        elseif cfg.bar then
            widget, w, h = buildBarLine(line, cfg, available_w or Screen:getWidth(), max_width)
        else
            local display_text = cfg.uppercase and Utf8Proc.uppercase_dumb(line) or line
            local text_fgcolor = resolveTextColor(cfg.text_color)
            widget = TextWidget:new(textWidgetOpts({
                text = display_text,
                face = cfg.face,
                bold = cfg.bold,
                max_width = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            }, text_fgcolor))
            local size = widget:getSize()
            w, h = size.w, size.h
        end
        if widget then
            table.insert(line_entries, {
                widget = widget, w = w, h = h,
                v_nudge = cfg.v_nudge or 0, h_nudge = cfg.h_nudge or 0,
            })
            if w > max_w then max_w = w end
            total_h = total_h + h
        end
    end

    local mlw = MultiLineWidget:new{
        lines = line_entries,
        width = max_w,
        height = total_h,
        align = align,
    }
    return mlw, max_w, total_h
end

--- Build a widget with no truncation (for measurement), returning it for potential reuse.
-- @return widget, width, height
function OverlayWidget.buildAndMeasure(text, line_configs, h_anchor)
    return OverlayWidget.buildTextWidget(text, line_configs, h_anchor, nil)
end

--- Measure the text-only pixel width of a position's content (bar lines excluded).
-- Used for overlap prevention so bars don't inflate width calculations.
function OverlayWidget.measureTextWidth(text, line_configs)
    local max_w = 0
    local i = 0
    for line in text:gmatch("([^\n]+)") do
        i = i + 1
        local cfg = line_configs[i] or line_configs[#line_configs]
            or { face = Font:getFace("cfont"), bold = false }
        -- For bar lines, measure only the text portions (strip placeholder)
        local measure_text = line
        if cfg.bar then
            measure_text = line:gsub(BAR_PLACEHOLDER, "")
        end
        if measure_text ~= "" then
            local display_text = cfg.uppercase and Utf8Proc.uppercase_dumb(measure_text) or measure_text
            local tw = TextWidget:new(textWidgetOpts{
                text = display_text, face = cfg.face, bold = cfg.bold,
            })
            local w = tw:getSize().w
            tw:free()
            if w > max_w then max_w = w end
        end
    end
    return max_w
end

--- Apply per-token pixel-width limits encoded as \x01N\x02value\x03 markers.
-- Measures each marked value with the given font; if wider than N pixels,
-- truncates to the longest UTF-8 prefix that fits and appends "...".
-- @param text string: text potentially containing markers
-- @param face table: font face for measurement
-- @param bold boolean: bold flag for measurement
-- @param uppercase boolean: whether text will be rendered uppercase
-- @return string: text with markers replaced by (possibly truncated) values
function OverlayWidget.applyTokenLimits(text, face, bold, uppercase)
    if not text:find("\x01") then return text end
    local util = require("util")
    return text:gsub("\x01(%d+)\x02(.-)\x03", function(limit_str, value)
        local max_px = tonumber(limit_str)
        if not max_px or max_px <= 0 or value == "" then return value end
        local display = uppercase and Utf8Proc.uppercase_dumb(value) or value
        -- Measure full value
        local tw = TextWidget:new(textWidgetOpts{
            text = display, face = face, bold = bold,
        })
        local w = tw:getSize().w
        tw:free()
        if w <= max_px then return value end
        -- Need to truncate — measure ellipsis width
        local ellipsis = "\xE2\x80\xA6" -- U+2026 …
        local ew = TextWidget:new(textWidgetOpts{
            text = ellipsis, face = face, bold = bold,
        })
        local ellipsis_w = ew:getSize().w
        ew:free()
        local target_px = max_px - ellipsis_w
        if target_px <= 0 then return ellipsis end
        -- Split into UTF-8 characters and binary search for max fitting prefix
        local chars = util.splitToChars(display)
        local lo, hi = 0, #chars
        while lo < hi do
            local mid = math.ceil((lo + hi) / 2)
            local sub = table.concat(chars, "", 1, mid)
            local stw = TextWidget:new(textWidgetOpts{
                text = sub, face = face, bold = bold,
            })
            local sw = stw:getSize().w
            stw:free()
            if sw <= target_px then
                lo = mid
            else
                hi = mid - 1
            end
        end
        if lo == 0 then return ellipsis end
        -- If uppercase was applied for measurement, we need to return the
        -- original-case prefix (same char count) so buildTextWidget can
        -- apply uppercase again without double-transforming.
        local orig_chars = util.splitToChars(value)
        return table.concat(orig_chars, "", 1, lo) .. ellipsis
    end)
end

--- Parse BBCode-style formatting tags into styled text segments.
-- Supports [b], [i], [u] tags with proper nesting via a style stack.
-- Bar placeholder characters become special bar segments.
-- If tags are improperly nested or unclosed, returns nil (render as plain text).
-- @param text string: text potentially containing [b], [i], [u] tags and bar placeholder
-- @param base_bold boolean: base bold state from line config
-- @param base_italic boolean: base italic state from line config
-- @param base_uppercase boolean: base uppercase state from line config
-- @return table or nil: array of segments, or nil if no valid tags found
-- @return boolean: true if tags were found and parsed
function OverlayWidget.parseStyledSegments(text, base_bold, base_italic, base_uppercase)
    -- Quick check: no tags present
    if not text:find("%[") then
        return nil, false
    end

    local segments = {}
    local stack = {}  -- style stack: each entry is "b", "i", or "u"
    local color_stack = {}  -- color stack: each entry is a {grey=N} table
    local pos = 1
    local pending = ""  -- accumulates text between tags
    local found_tags = false

    -- Current style: base style when stack is empty, stack-derived when inside tags.
    -- Tags override base (not combine): [i] inside a Bold line = italic only.
    local function currentStyle()
        if #stack == 0 then
            return base_bold, base_italic, base_uppercase
        end
        local bold, italic, uppercase = false, false, false
        for _, tag in ipairs(stack) do
            if tag == "b" then bold = true
            elseif tag == "i" then italic = true
            elseif tag == "u" then uppercase = true
            end
        end
        return bold, italic, uppercase
    end

    local function currentColor()
        if #color_stack == 0 then return nil end
        return color_stack[#color_stack]
    end

    local function flushPending()
        if pending == "" then return end
        local bold, italic, uppercase = currentStyle()
        local seg = { text = pending, bold = bold, italic = italic, uppercase = uppercase }
        local clr = currentColor()
        if clr then seg.color = clr end
        table.insert(segments, seg)
        pending = ""
    end

    local len = #text
    while pos <= len do
        -- Check for bar placeholder (3-byte UTF-8: \xEF\xBF\xBC)
        if text:sub(pos, pos + 2) == BAR_PLACEHOLDER then
            flushPending()
            table.insert(segments, { bar = true })
            pos = pos + 3
        -- Check for closing tag [/b], [/i], [/u]
        elseif text:match("^%[/[biu]%]", pos) then
            local tag = text:sub(pos + 2, pos + 2)  -- the letter after /
            if #stack > 0 and stack[#stack] == tag then
                flushPending()
                table.remove(stack)
                found_tags = true
                pos = pos + 4  -- [/b] = 4 chars
            else
                -- Mismatched close — render entire line as plain text
                return nil, false
            end
        -- Check for opening tag [b], [i], [u]
        elseif text:match("^%[[biu]%]", pos) then
            flushPending()
            local tag = text:sub(pos + 1, pos + 1)  -- the letter
            table.insert(stack, tag)
            found_tags = true
            pos = pos + 3  -- [b] = 3 chars
        -- Check for closing colour tag [/c]
        elseif text:match("^%[/c%]", pos) then
            if #color_stack > 0 then
                flushPending()
                table.remove(color_stack)
                found_tags = true
                pos = pos + 4  -- [/c] = 4 chars
            else
                -- Mismatched close — render entire line as plain text
                return nil, false
            end
        -- Check for opening colour tag [c=N] where N is 0-100
        elseif text:match("^%[c=%d+%]", pos) then
            local val_str, end_pos = text:match("^%[c=(%d+)()%]", pos)
            if val_str then
                local pct = tonumber(val_str)
                if pct and pct >= 0 and pct <= 100 then
                    flushPending()
                    local grey = 0xFF - math.floor(pct * 0xFF / 100 + 0.5)
                    table.insert(color_stack, { grey = grey })
                    found_tags = true
                    pos = end_pos + 1  -- skip past the ']'
                else
                    pending = pending .. text:sub(pos, pos)
                    pos = pos + 1
                end
            else
                pending = pending .. text:sub(pos, pos)
                pos = pos + 1
            end
        else
            pending = pending .. text:sub(pos, pos)
            pos = pos + 1
        end
    end

    flushPending()

    -- Unclosed tags — return nil to signal: render entire line as plain text
    if #stack > 0 then
        return nil, false
    end
    if #color_stack > 0 then
        return nil, false
    end

    if not found_tags then
        return nil, false
    end

    return segments, true
end

--- Build a HorizontalRowWidget from styled segments (text and bar).
-- Replaces both buildBarLine and single-TextWidget path for styled lines.
-- @param segments table: array from parseStyledSegments
-- @param cfg table: line config with .face, .face_name, .font_size, .bold, .bar, .bar_height, .bar_style, .bar_colors
-- @param available_w number: total available width
-- @param max_width number or nil: truncation limit for the whole line
-- @return widget, width, height
function OverlayWidget.buildStyledLine(segments, cfg, available_w, max_width)
    local effective_w = max_width or available_w
    local widgets = {}
    local total_w = 0
    local text_total_w = 0
    local max_h = 0
    local bar_slot = nil  -- index where bar widget should be inserted

    for _, seg in ipairs(segments) do
        if seg.bar then
            -- Remember bar position, insert later after measuring text
            bar_slot = #widgets + 1
        else
            local display = seg.uppercase and Utf8Proc.uppercase_dumb(seg.text) or seg.text
            if display ~= "" then
                -- Resolve font face and synthetic bold for this segment
                local seg_face = cfg.face
                local seg_synthetic_bold = false
                if cfg.face_name and (seg.bold or seg.italic) then
                    local style = (seg.bold and seg.italic and "bolditalic")
                        or (seg.bold and "bold") or "italic"
                    local variant = OverlayWidget.findFontVariant(cfg.face_name, style)
                    if variant then
                        seg_face = Font:getFace(variant, cfg.font_size)
                    elseif style == "bolditalic" then
                        -- Fallback: italic file + synthetic bold
                        local italic = OverlayWidget.findFontVariant(cfg.face_name, "italic")
                        if italic then
                            seg_face = Font:getFace(italic, cfg.font_size)
                        end
                        seg_synthetic_bold = true
                    elseif seg.bold then
                        seg_synthetic_bold = true
                    end
                end

                -- If a truncation limit is set, cap this segment to remaining space
                local seg_max_width = nil
                if max_width then
                    local remaining = max_width - total_w
                    if remaining <= 0 then break end
                    seg_max_width = remaining
                end

                -- Resolve segment colour: BBCode [c] tag → global text_color → nil (book colour)
                local seg_fgcolor = nil
                if seg.color then
                    seg_fgcolor = Blitbuffer.Color8(seg.color.grey)
                elseif cfg.text_color then
                    seg_fgcolor = resolveTextColor(cfg.text_color)
                end

                local tw = TextWidget:new(textWidgetOpts({
                    text = display,
                    face = seg_face,
                    bold = seg_synthetic_bold,
                    max_width = seg_max_width,
                    truncate_with_ellipsis = seg_max_width ~= nil,
                }, seg_fgcolor))
                local size = tw:getSize()
                table.insert(widgets, { widget = tw, w = size.w, h = size.h })
                total_w = total_w + size.w
                text_total_w = text_total_w + size.w
                if size.h > max_h then max_h = size.h end
            end
        end
    end

    -- Ensure row height from font even if no text segments
    if text_total_w == 0 and cfg.face then
        local ref_tw = TextWidget:new(textWidgetOpts({ text = " ", face = cfg.face, bold = cfg.bold }))
        local ref_h = ref_tw:getSize().h
        ref_tw:free()
        if ref_h > max_h then max_h = ref_h end
    end

    -- Handle bar segment if present
    if bar_slot and cfg.bar then
        local bar_info = cfg.bar
        local bar_h = (bar_info and bar_info.height)
            or cfg.bar_height or (cfg.face and cfg.face.size) or 5
        local bar_style = cfg.bar_style or "bordered"
        local bar_manual_w = (bar_info and bar_info.width) or 0

        local bar_w
        if bar_manual_w > 0 then
            bar_w = math.min(bar_manual_w, math.max(0, effective_w - text_total_w))
        else
            bar_w = math.max(0, effective_w - text_total_w)
        end
        -- Radial bars are circular — clamp width to height so they stay square
        if bar_style == "radial" or bar_style == "radial_hollow" then
            bar_w = math.min(bar_w, bar_h)
        end

        if bar_w >= 1 then
            local bar_widget = BarWidget:new{
                width = bar_w,
                height = bar_h,
                fraction = bar_info.pct or 0,
                ticks = bar_info.ticks or {},
                style = bar_style,
                colors = cfg.bar_colors,
            }
            table.insert(widgets, bar_slot, { widget = bar_widget, w = bar_w, h = bar_h })
            total_w = total_w + bar_w
            if bar_h > max_h then max_h = bar_h end
        end
    end

    if #widgets == 0 then
        return nil, 0, 0
    end

    local row = HorizontalRowWidget:new{
        segments = widgets,
        width = total_w,
        height = max_h,
    }
    return row, total_w, max_h
end

--- Calculate max_width for each position in a row, applying overlap prevention.
-- @param priority string: "center" (default) = center gets priority;
--                         "sides" = left/right get priority, center is truncated first.
-- Returns { left=max_w|nil, center=max_w|nil, right=max_w|nil }.
function OverlayWidget.calculateRowLimits(left_w, center_w, right_w, screen_w, gap, h_offset, priority)
    local limits = { left = nil, center = nil, right = nil }

    if priority == "sides" then
        -- Sides-first: left and right claim their natural width, center gets the remainder.
        -- Center is positioned symmetrically, so its max width is constrained by
        -- whichever side is wider (not the sum of both).
        local left_actual = left_w and math.min(left_w, math.max(0, screen_w - h_offset)) or 0
        local right_actual = right_w and math.min(right_w, math.max(0, screen_w - h_offset)) or 0
        if left_actual > 0 and right_actual > 0 then
            -- Both sides: each gets at most half minus gap
            local half = math.max(0, math.floor(screen_w / 2) - math.floor(gap / 2) - h_offset)
            if left_actual > half then
                limits.left = half
                left_actual = half
            end
            if right_actual > half then
                limits.right = half
                right_actual = half
            end
        end
        if center_w then
            local wider_side = math.max(left_actual, right_actual)
            local center_max = math.max(0, screen_w - 2 * (wider_side + h_offset + gap))
            if center_w > center_max then
                limits.center = center_max
            end
        end
        return limits
    end

    -- Default: center-first priority
    if center_w then
        local center_max = math.max(0, screen_w - 2 * gap)
        if center_w > center_max then
            limits.center = center_max
            center_w = center_max
        end
    end

    if center_w then
        local available_side = math.max(0, math.floor((screen_w - center_w) / 2) - gap)
        if left_w and left_w > available_side - h_offset then
            limits.left = math.max(0, available_side - h_offset)
        end
        if right_w and right_w > available_side - h_offset then
            limits.right = math.max(0, available_side - h_offset)
        end
    else
        if left_w and right_w then
            local half = math.floor(screen_w / 2) - math.floor(gap / 2)
            if left_w > half - h_offset then
                limits.left = math.max(0, half - h_offset)
            end
            if right_w > half - h_offset then
                limits.right = math.max(0, half - h_offset)
            end
        end
        if left_w and not right_w then
            local max = math.max(0, screen_w - h_offset)
            if left_w > max then limits.left = max end
        end
        if right_w and not left_w then
            local max = math.max(0, screen_w - h_offset)
            if right_w > max then limits.right = max end
        end
    end

    return limits
end

--- Compute the (x, y) paint coordinates for a position.
function OverlayWidget.computeCoordinates(h_anchor, v_anchor, text_w, text_h, screen_w, screen_h, v_offset, h_offset)
    local x, y

    if h_anchor == "left" then
        x = h_offset
    elseif h_anchor == "center" then
        x = math.floor((screen_w - text_w) / 2)
    else
        x = screen_w - text_w - h_offset
    end

    if v_anchor == "top" then
        y = v_offset
    else
        y = screen_h - text_h - v_offset
    end

    return x, y
end

--- Free all widgets in a cache table.
function OverlayWidget.freeWidgets(widget_cache)
    local keys = {}
    for key in pairs(widget_cache) do
        table.insert(keys, key)
    end
    for _, key in ipairs(keys) do
        local entry = widget_cache[key]
        if entry.widget and entry.widget.free then
            entry.widget:free()
        end
        widget_cache[key] = nil
    end
end

--- Paint a progress bar directly to a blitbuffer.
-- @param orientation "horizontal" (default) or "vertical"
-- @param reverse boolean: flip fill direction
-- @param colors table or nil: { fill = Blitbuffer color, bg = Blitbuffer color }
function OverlayWidget.paintProgressBar(bb, x, y, w, h, fraction, ticks, style, orientation, reverse, colors)
    if w < 1 or h < 1 then return end
    fraction = math.max(0, math.min(1, fraction or 0))
    local vertical = orientation == "vertical"
    -- Custom colors: nil = not set (use default), false = transparent (skip paint)
    local custom_fill = colors and colors.fill
    local custom_bg = colors and colors.bg
    local custom_track = colors and colors.track
    local custom_tick = colors and colors.tick
    local invert_read_ticks = colors and colors.invert_read_ticks
    local tick_height_pct = colors and colors.tick_height_pct or 100
    local custom_border = colors and colors.border
    local custom_invert = colors and colors.invert
    local custom_metro_fill = colors and colors.metro_fill

    -- Resolve custom color: false → nil (transparent/skip), nil → default, else custom.
    -- Must use type() checks to avoid triggering Blitbuffer's __eq metamethod.
    local function resolveColor(custom, default)
        local t = type(custom)
        if t == "nil" then return default end      -- not set: use default
        if t == "boolean" then return nil end      -- false = transparent
        return custom                               -- Color8 value
    end

    -- Helper: paint a rect, swapping axes for vertical.
    -- Skips painting if color is nil (transparent).
    local function pr(rx, ry, rw, rh, color)
        if not color then return end
        if vertical then
            bb:paintRect(ry, rx, rh, rw, color)
        else
            bb:paintRect(rx, ry, rw, rh, color)
        end
    end

    -- Work in abstract coordinates: length = progress axis, thickness = cross axis
    local length = vertical and h or w
    local thickness = vertical and w or h
    local ox = vertical and y or x  -- origin along progress axis
    local oy = vertical and x or y  -- origin along cross axis

    if style == "metro" then
        -- Metro style: start ring, trunk line, position dot, ticks above/below
        local line_thick = math.max(3, math.floor(thickness * 0.2))
        local start_r = math.floor(thickness / 2)  -- full height circle
        local dot_r = math.max(4, math.floor(thickness * 0.35))
        local line_y = oy + math.floor((thickness - line_thick) / 2)
        -- Metro ticks default shorter — the thin trunk looks better with
        -- compact ticks.  Scale the user's tick_height_pct relative to 60%
        -- so 100% (default) → 60%, 200% → 120%, etc.
        tick_height_pct = math.floor(tick_height_pct * 0.35)

        -- Inset the line so start/end circles don't clip
        local inset = start_r
        local line_ox = ox + inset
        local line_len = length - 2 * inset  -- room for start + end circles
        if line_len < 1 then line_len = length; line_ox = ox; inset = 0 end

        local line_fill = math.floor(line_len * fraction)
        local line_fill_start = reverse and (line_len - line_fill) or 0

        local metro_track = resolveColor(custom_track, Blitbuffer.COLOR_DARK_GRAY)
        -- metro_fill: nil when user has not set a distinct fill (or set it to false/transparent)
        local metro_fill = resolveColor(custom_metro_fill, nil)
        -- Track line full length
        pr(line_ox, line_y, line_len, line_thick, metro_track)
        -- Optional fill overlay on the read portion
        if metro_fill then
            pr(line_ox + line_fill_start, line_y, line_fill, line_thick, metro_fill)
        end

        -- Chapter ticks: depth 1 above line (connected to trunk), depth 2 below
        -- When reversed, flip tick sides so the visual hierarchy mirrors the direction
        local metro_tick_h = math.max(1, math.floor(thickness * tick_height_pct / 100))
        for _i, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            local tick_depth = type(tick) == "table" and tick[3] or 1
            if reverse then tick_frac = 1 - tick_frac end
            local tick_pos = math.floor(line_len * tick_frac)
            if tick_pos > 0 and tick_pos < line_len then
                local tick_above
                if reverse then
                    tick_above = tick_depth > 1
                else
                    tick_above = tick_depth <= 1
                end
                -- Vertical (side-anchored) bars: flip tick sides
                if vertical then tick_above = not tick_above end
                -- Tick recolouring: ticks within the read portion paint in metro_fill
                local is_read
                if reverse then
                    is_read = tick_pos >= line_len - line_fill
                else
                    is_read = tick_pos <= line_fill
                end
                local tick_color = (metro_fill and is_read) and metro_fill or metro_track
                if tick_above then
                    pr(line_ox + tick_pos, line_y - metro_tick_h, line_thick, metro_tick_h, tick_color)
                else
                    pr(line_ox + tick_pos, line_y + line_thick, line_thick, metro_tick_h, tick_color)
                end
            end
        end

        -- Helper for circles
        local function paintCircle(cx, cy, r, color)
            if not color then return end
            if vertical then
                bb:paintRoundedRect(cy, cx, r * 2, r * 2, color, r)
            else
                bb:paintRoundedRect(cx, cy, r * 2, r * 2, color, r)
            end
        end

        -- Start circle (empty ring; read colour when set, else trunk colour)
        local start_cx = reverse and (line_ox + line_len - start_r) or (line_ox - start_r)
        paintCircle(start_cx, oy, start_r, metro_fill or metro_track)
        local ring_border = line_thick
        local inner_r = start_r - ring_border
        if inner_r > 0 then
            paintCircle(start_cx + ring_border, oy + ring_border, inner_r, resolveColor(custom_invert, Blitbuffer.COLOR_WHITE))
        end

        -- End circle (filled, trunk colour, same size as start)
        local end_cx = reverse and (line_ox - start_r) or (line_ox + line_len - start_r)
        paintCircle(end_cx, oy, start_r, metro_track)

        -- Current position dot (uses tick colour, default black)
        local pos_on_line = reverse and (line_len - line_fill) or line_fill
        local dot_cx = line_ox + pos_on_line - dot_r
        local dot_cy = oy + math.floor((thickness - dot_r * 2) / 2)
        paintCircle(dot_cx, dot_cy, dot_r, resolveColor(custom_tick, Blitbuffer.COLOR_BLACK))

    elseif style == "wavy" then
        -- Wavy ribbon: the entire bar follows a sine wave path.
        -- Two-toned fill with a position dot riding the curve.
        local wave_fill = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local wave_track = resolveColor(custom_track, Blitbuffer.COLOR_GRAY)
        local wave_dot = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)

        local amplitude = math.floor(thickness * 0.35)
        local ribbon_h = math.max(3, math.floor(thickness * 0.4))
        local half_ribbon = math.floor(ribbon_h / 2)
        local mid = oy + math.floor(thickness / 2)
        local two_pi = 2 * math.pi

        -- Phase-lock: adjust wavelength so both ends land on zero crossings.
        -- Force odd half-cycles so the wave starts going one way and ends
        -- going the other ('W' shape). Reversed bars negate the sine ('M').
        local target_wl = math.max(20, math.floor(thickness * 2.5))
        local half_cycles = math.max(1, math.floor((length - 1) / (target_wl / 2) + 0.5))
        if half_cycles % 2 == 0 then half_cycles = half_cycles + 1 end
        local wavelength = 2 * (length - 1) / half_cycles
        local wave_sign = reverse and 1 or -1

        local fill_len = math.floor(length * fraction)
        local fill_start = reverse and (length - fill_len) or 0
        local fill_end = fill_start + fill_len

        -- Helper: wave center y at position i
        local function wave_y(i)
            return mid + math.floor(amplitude * wave_sign * math.sin(two_pi * i / wavelength))
        end

        -- End cap circles (behind the ribbon, same size and color as the wave)
        local cap_r = half_ribbon
        local start_color = (0 >= fill_start and 0 < fill_end) and wave_fill or wave_track
        local end_color = ((length - 1) >= fill_start and (length - 1) < fill_end) and wave_fill or wave_track
        local function paintCap(cx, cy, color)
            if not color then return end
            local rx, ry = cx - cap_r, cy - cap_r
            local d = cap_r * 2
            if vertical then
                bb:paintRoundedRect(ry, rx, d, d, color, cap_r)
            else
                bb:paintRoundedRect(rx, ry, d, d, color, cap_r)
            end
        end
        paintCap(ox, wave_y(0), start_color)
        paintCap(ox + length - 1, wave_y(length - 1), end_color)

        -- Paint ribbon column by column
        for i = 0, length - 1 do
            local cy = wave_y(i)
            local ry = cy - half_ribbon
            local in_fill = i >= fill_start and i < fill_end
            local color = in_fill and wave_fill or wave_track
            if color then
                if vertical then
                    bb:paintRect(ry, ox + i, ribbon_h, 1, color)
                else
                    bb:paintRect(ox + i, ry, 1, ribbon_h, color)
                end
            end
        end

        -- Chapter ticks — vertical lines through the ribbon at each chapter boundary
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            if reverse then tick_frac = 1 - tick_frac end
            local tick_pos = math.floor(length * tick_frac)
            if tick_pos > 0 and tick_pos < length then
                local cy = wave_y(tick_pos)
                local th = math.max(1, math.floor(ribbon_h * tick_height_pct / 100))
                local ty = cy - math.floor(th / 2)
                local in_fill = tick_pos >= fill_start and tick_pos < fill_end
                local base_tick = wave_dot
                if base_tick then
                    local tick_color
                    if invert_read_ticks ~= false and in_fill then
                        tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                    else
                        tick_color = base_tick
                    end
                    if vertical then
                        bb:paintRect(ty, ox + tick_pos, th, tick_w, tick_color)
                    else
                        bb:paintRect(ox + tick_pos, ty, tick_w, th, tick_color)
                    end
                end
            end
        end

        -- Position dot riding the wave
        if wave_dot then
            local dot_r = math.max(4, math.floor(thickness * 0.35))
            local pos_i = reverse and (length - fill_len) or fill_len
            pos_i = math.max(0, math.min(length - 1, pos_i))
            local dot_cy = wave_y(pos_i)
            local dot_cx = ox + pos_i - dot_r
            local dot_dy = dot_cy - dot_r
            if vertical then
                bb:paintRoundedRect(dot_dy, dot_cx, dot_r * 2, dot_r * 2, wave_dot, dot_r)
            else
                bb:paintRoundedRect(dot_cx, dot_dy, dot_r * 2, dot_r * 2, wave_dot, dot_r)
            end
        end

    elseif style == "radial" or style == "radial_hollow" then
        -- Radial (pie-chart) style: a circle filled clockwise from 12 o'clock.
        local diameter = math.min(vertical and h or w, vertical and w or h)
        local radius = math.floor(diameter / 2)
        if radius < 2 then radius = 2 end
        -- Center the circle in the allocated rectangle
        local cx = x + math.floor(w / 2)
        local cy = y + math.floor(h / 2)

        local radial_bg = resolveColor(custom_bg, Blitbuffer.COLOR_GRAY)
        local radial_fill = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local radial_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
        local radial_border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)

        local r2 = radius * radius
        local hollow = style == "radial_hollow"
        local inner_radius = hollow and math.floor(radius * 0.55) or 0
        local inner_r2 = inner_radius * inner_radius
        local two_pi = 2 * math.pi

        -- Paint the pie circle pixel by pixel.
        -- Angle 0 = 12 o'clock (top), increasing clockwise.
        for py = -radius, radius - 1 do
            for px = -radius, radius - 1 do
                -- Offset to pixel center for smoother circle
                local dx = px + 0.5
                local dy = py + 0.5
                local d2 = dx * dx + dy * dy
                if d2 <= r2 and d2 > inner_r2 then
                    -- Compute angle from top, clockwise: atan2(dx, -dy) mapped to [0, 2π)
                    local angle = math.atan2(dx, -dy)
                    if angle < 0 then angle = angle + two_pi end
                    local pixel_frac = angle / two_pi

                    local in_fill = pixel_frac <= fraction
                    local color = in_fill and radial_fill or radial_bg
                    if color then
                        bb:paintRect(cx + px, cy + py, 1, 1, color)
                    end
                end
            end
        end

        -- Chapter tick marks: radial lines from center to edge at each chapter boundary
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1

            local tick_angle = tick_frac * two_pi - math.pi / 2  -- 0 = top (12 o'clock)
            -- Adjusted: tick at fraction 0 points up. tick_angle measured from 3 o'clock.
            -- Recalculate: from 12 o'clock clockwise
            tick_angle = tick_frac * two_pi
            local cos_a = math.cos(tick_angle - math.pi / 2)
            local sin_a = math.sin(tick_angle - math.pi / 2)

            -- Draw tick as a line from 60% of radius to the edge
            local inner_r = math.floor(radius * (1 - tick_height_pct / 100))
            if inner_r < inner_radius then inner_r = inner_radius end
            for t = inner_r, radius do
                local lx = cx + math.floor(t * cos_a)
                local ly = cy + math.floor(t * sin_a)
                -- Determine if this tick position is in the filled region
                local pix_angle = math.atan2(t * cos_a, -(t * sin_a))
                if pix_angle < 0 then pix_angle = pix_angle + two_pi end
                local pix_frac = pix_angle / two_pi
                local in_fill = pix_frac <= fraction
                local tick_color
                if invert_read_ticks ~= false and in_fill then
                    tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                else
                    tick_color = radial_tick
                end
                if tick_color then
                    bb:paintRect(lx, ly, tick_w, tick_w, tick_color)
                end
            end
        end

        -- Optional border circle (1px ring at the outer edge)
        if radial_border_color then
            local border_r2_outer = radius * radius
            local border_r2_inner = (radius - 1) * (radius - 1)
            for py = -radius, radius - 1 do
                for px = -radius, radius - 1 do
                    local dx = px + 0.5
                    local dy = py + 0.5
                    local d2 = dx * dx + dy * dy
                    if d2 <= border_r2_outer and d2 > border_r2_inner then
                        bb:paintRect(cx + px, cy + py, 1, 1, radial_border_color)
                    end
                end
            end
            -- Inner border ring for hollow variant
            if hollow then
                local ib_r2_outer = inner_radius * inner_radius
                local ib_r2_inner = (inner_radius - 1) * (inner_radius - 1)
                for py = -inner_radius, inner_radius - 1 do
                    for px = -inner_radius, inner_radius - 1 do
                        local dx = px + 0.5
                        local dy = py + 0.5
                        local d2 = dx * dx + dy * dy
                        if d2 <= ib_r2_outer and d2 > ib_r2_inner then
                            bb:paintRect(cx + px, cy + py, 1, 1, radial_border_color)
                        end
                    end
                end
            end
        end

    elseif style == "solid" then
        local solid_fill = resolveColor(custom_fill, Blitbuffer.COLOR_GRAY_5)
        local solid_bg = resolveColor(custom_bg, Blitbuffer.COLOR_GRAY)
        pr(ox, oy, length, thickness, solid_bg)
        local fill_len = math.floor(length * fraction)
        local fill_start = reverse and (length - fill_len) or 0
        if fill_len > 0 then
            pr(ox + fill_start, oy, fill_len, thickness, solid_fill)
        end
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            if reverse then tick_frac = 1 - tick_frac end
            local tick_pos = math.floor(length * tick_frac)
            if tick_pos > 0 and tick_pos < length then
                local in_fill = tick_pos >= fill_start and tick_pos < fill_start + fill_len
                local base_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
                if base_tick then
                    local tick_color
                    if invert_read_ticks ~= false and in_fill then
                        tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                    else
                        tick_color = base_tick
                    end
                    local th = math.max(1, math.floor(thickness * tick_height_pct / 100))
                    local t_oy = oy + math.floor((thickness - th) / 2)
                    pr(ox + tick_pos, t_oy, tick_w, th, tick_color)
                end
            end
        end
    else
        local border_fill = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local border_bg = resolveColor(custom_bg, Blitbuffer.COLOR_WHITE)
        local border = (colors and colors.border_thickness) or 1
        if border < 0 then border = 0 end
        if border > math.floor(thickness / 2) then border = math.floor(thickness / 2) end
        local min_dim = vertical and w or h
        local radius = style == "rounded" and math.floor(min_dim / 2) or 0
        -- Background (use real coordinates for rounded rect API)
        if radius > 0 then
            if border_bg then
                bb:paintRoundedRect(x, y, w, h, border_bg, radius)
            end
        else
            if border_bg then
                bb:paintRect(x, y, w, h, border_bg)
            end
        end
        local padding = math.max(1, math.floor(thickness * 0.1))
        local h_inset = border + padding
        local v_inset = border + padding
        if radius > 0 then
            -- Rounded: paint fill as a rounded rect, then overpaint the unfilled
            -- portion with a background rounded rect so both ends keep curved edges.
            local inset = h_inset
            local inner_r = math.max(0, radius - inset)
            local inner_x = x + inset
            local inner_y = y + inset
            local inner_w = w - 2 * inset
            local inner_h = h - 2 * inset
            if inner_w > 0 and inner_h > 0 then
                local inner_len = vertical and inner_h or inner_w
                local fill_len = math.floor(inner_len * fraction)
                -- Background (unfilled) first as full rounded rect
                if border_bg then
                    bb:paintRoundedRect(inner_x, inner_y, inner_w, inner_h, border_bg, inner_r)
                end
                -- Fill (read portion) on top — its rounded corners overlay the background
                if fill_len > 0 and border_fill then
                    if vertical then
                        if reverse then
                            bb:paintRoundedRect(inner_x, inner_y + inner_h - fill_len, inner_w, fill_len, border_fill, inner_r)
                        else
                            bb:paintRoundedRect(inner_x, inner_y, inner_w, fill_len, border_fill, inner_r)
                        end
                    else
                        if reverse then
                            bb:paintRoundedRect(inner_x + inner_w - fill_len, inner_y, fill_len, inner_h, border_fill, inner_r)
                        else
                            bb:paintRoundedRect(inner_x, inner_y, fill_len, inner_h, border_fill, inner_r)
                        end
                    end
                end
            end
        end
        local inner_ox = ox + h_inset
        local inner_oy = oy + v_inset
        local inner_len = length - 2 * h_inset
        local inner_thick = thickness - 2 * v_inset
        if inner_len > 0 and inner_thick > 0 and radius == 0 then
            -- Bordered (non-rounded): rectangular fill
            local fill_len = math.floor(inner_len * fraction)
            if fill_len > 0 then
                if reverse then
                    pr(inner_ox + inner_len - fill_len, inner_oy, fill_len, inner_thick, border_fill)
                else
                    pr(inner_ox, inner_oy, fill_len, inner_thick, border_fill)
                end
            end
        end
        -- Border on top
        local border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)
        if radius > 0 then
            if border_color then
                bb:paintBorder(x, y, w, h, border, border_color, radius)
            end
        else
            if border_color then
                bb:paintRect(x, y, w, border, border_color)
                bb:paintRect(x, y + h - border, w, border, border_color)
                bb:paintRect(x, y, border, h, border_color)
                bb:paintRect(x + w - border, y, border, h, border_color)
            end
        end
        -- Chapter ticks
        if inner_len > 0 and inner_thick > 0 then
            local fill_len = math.floor(inner_len * fraction)
            local fill_start = reverse and (inner_len - fill_len) or 0
            -- For rounded bars, compute the inner radius for tick clipping
            local clip_r = radius > 0 and math.max(0, radius - h_inset) or 0
            for _, tick in ipairs(ticks or {}) do
                local tick_frac = type(tick) == "table" and tick[1] or tick
                local tick_w = type(tick) == "table" and tick[2] or 1
                if reverse then tick_frac = 1 - tick_frac end
                local tick_pos = math.floor(inner_len * tick_frac)
                if tick_pos > 0 and tick_pos < inner_len then
                    local base_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
                    if base_tick then
                        local tick_color
                        if invert_read_ticks ~= false then
                            local in_fill = tick_pos >= fill_start and tick_pos < fill_start + fill_len
                            tick_color = in_fill and border_bg or base_tick
                        else
                            tick_color = base_tick
                        end
                        local th = math.max(1, math.floor(inner_thick * tick_height_pct / 100))
                        -- Clip tick height near rounded ends so ticks don't exceed the curve
                        if clip_r > 0 then
                            local dist_from_left = tick_pos
                            local dist_from_right = inner_len - tick_pos
                            local dist_from_edge = math.min(dist_from_left, dist_from_right)
                            if dist_from_edge < clip_r then
                                local avail = 2 * math.floor(math.sqrt(math.max(0, clip_r * clip_r - (clip_r - dist_from_edge) * (clip_r - dist_from_edge))))
                                th = math.min(th, avail)
                            end
                        end
                        if th > 0 then
                            local t_oy = inner_oy + math.floor((inner_thick - th) / 2)
                            pr(inner_ox + tick_pos, t_oy, tick_w, th, tick_color)
                        end
                    end
                end
            end
        end
    end
end

return OverlayWidget
