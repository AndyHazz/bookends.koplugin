local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local Colour = require("bookends_colour")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Utf8Proc = require("ffi/utf8proc")
local PacmanSprite = require("bookends_pacman_sprite")
local Screen = Device.screen

-- Per-pacman animation frame counters keyed by screen position. Each
-- distinct pacman on screen has its own counter, incremented once per
-- paintProgressBar call (so the bar animates on every repaint regardless
-- of who's driving the paint — bookends overlay, bookshelf's hero bar,
-- or any future consumer). Different pacmans first appearing in the same
-- paint get sequential starting phases via _pacman_seq, so two pacmans
-- side-by-side animate in opposite phase rather than locked together.
-- Resets on plugin reload; no persistence needed. Table growth is
-- bounded by the number of distinct screen positions ever painted —
-- negligible in practice.
local _pacman_frames = {}
local _pacman_seq = 0

local ColorRGB32_t = ffi.typeof("ColorRGB32")

-- Helper: resolve a text/symbol colour table ({grey=N} or {hex=H}) to a
-- Blitbuffer colour object on the current screen. Returns nil when v is
-- nil/false. Uses `not v` rather than `v == nil` because under LuaJIT an
-- ffi.metatype equality check routes through __eq, and Blitbuffer's __eq
-- indexes the other operand unconditionally — so `bb_color == nil` would
-- crash. `not v` never calls __eq.
local function resolveTextColor(v)
    if not v then return nil end
    return Colour.parseColorValue(v, Screen:isColorEnabled())
end

-- Blitbuffer's plain paintRect / paintRoundedRect / paintBorder always flatten
-- their colour argument to luminance via getColor8(), so painting a ColorRGB32
-- through them renders as grey on a colour buffer. KOReader exposes parallel
-- *RGB32 variants for true-colour fills; these wrappers dispatch by colour
-- type so all the call-sites in paintProgressBar can stay shape-agnostic.
-- bbPaintRect is declared as OverlayWidget.bbPaintRect (module export) below
-- and then aliased to a local for in-file call sites.

local function bbPaintRoundedRect(bb, x, y, w, h, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintRoundedRectRGB32(x, y, w, h, c, r)
    else
        bb:paintRoundedRect(x, y, w, h, c, r)
    end
end

local function bbPaintBorder(bb, x, y, w, h, bw, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintBorderRGB32(x, y, w, h, bw, c, r)
    else
        bb:paintBorder(x, y, w, h, bw, c, r)
    end
end

local OverlayWidget = {}

--- Dispatch a filled rectangle paint to the correct Blitbuffer variant.
--- Blitbuffer's plain paintRect flattens its colour to luminance via
--- getColor8(), so a ColorRGB32 painted through it renders as grey on a
--- colour buffer. KOReader's *RGB32 variants preserve true colour; this
--- wrapper dispatches by colour type so callers stay shape-agnostic.
--- Exported as OverlayWidget.bbPaintRect so main.lua can call it directly.

function OverlayWidget.bbPaintRect(bb, x, y, w, h, c)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintRectRGB32(x, y, w, h, c)
    else
        bb:paintRect(x, y, w, h, c)
    end
end
local bbPaintRect = OverlayWidget.bbPaintRect

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

-- Cache for [font=NAME] resolution (display name -> file path, or false if the
-- font isn't installed). Resolving goes through bookends_utils, which asks CRE
-- (matching KOReader's font menu); cache to keep the per-segment render cheap.
local _font_file_cache = {}
local function resolveSegFontFile(name)
    local cached = _font_file_cache[name]
    if cached ~= nil then
        return cached or nil
    end
    local file
    local ok, Utils = pcall(require, "bookends_utils")
    if ok and Utils and Utils.resolveFontNameToFile then
        local ok2, res = pcall(Utils.resolveFontNameToFile, name)
        if ok2 and type(res) == "string" and res ~= "" then
            file = res
        end
    end
    _font_file_cache[name] = file or false
    return file
end

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
    o.reverse = o.reverse or false
    -- o.unread_height stays nil for symmetric thickness
    return o
end

function BarWidget:getSize()
    return { w = self.width, h = self.height }
end

function BarWidget:paintTo(bb, x, y)
    -- Delegate to paintProgressBar for consistent color handling.
    -- unread_height piggybacks on `colors` so paintProgressBar's existing
    -- asymmetric-thickness path (which reads colors.unread_height) picks it
    -- up without changing its signature. Inheriting via metatable keeps the
    -- caller's colors table immutable.
    local colors = self.colors
    if self.unread_height and (not colors or colors.unread_height ~= self.unread_height) then
        if colors then
            colors = setmetatable({ unread_height = self.unread_height }, { __index = colors })
        else
            colors = { unread_height = self.unread_height }
        end
    end
    OverlayWidget.paintProgressBar(bb, x, y, self.width, self.height,
        self.fraction, self.ticks, self.style, nil, self.reverse, colors, self.markers)
    -- Skim-gesture parity (#83): register this paint rect the same way
    -- full-width bars do in main.lua's _renderProgressBars, so onHoldBookends
    -- finds inline bars too.
    if self.hold_rects_owner then
        table.insert(self.hold_rects_owner._hold_rects, { x = x, y = y, w = self.width, h = self.height })
    end
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

-- U+FFF9 INTERLINEAR ANNOTATION ANCHOR — placeholder for %spacer, the elastic
-- gap that pushes everything after it to the far end of the line. A separate
-- codepoint from the bar's so a line carrying both can still be told apart,
-- and both are non-printing so a leak is visible as nothing rather than as a
-- stray glyph.
local SPACER_PLACEHOLDER = "\xEF\xBF\xB9"
OverlayWidget.SPACER_PLACEHOLDER = SPACER_PLACEHOLDER

--- A blank, non-painting widget of a given width. %spacer is a gap, not an
--- object: it exists only to consume the leftover width so the text after it
--- lands hard against the far edge. Same role BarWidget plays for %bar, minus
--- the painting.
local GapWidget = {}
GapWidget.__index = GapWidget

function GapWidget:new(o)
    o = o or {}
    setmetatable(o, self)
    o.width = o.width or 0
    o.height = o.height or 0
    return o
end

function GapWidget:getSize() return { w = self.width, h = self.height } end
function GapWidget:paintTo() end   -- deliberately nothing
function GapWidget:free() end

--- Build a HorizontalRowWidget for a line containing %spacer.
-- Same split-and-measure shape as buildBarLine below: the text either side is
-- measured, and the gap takes whatever width is left so the trailing text sits
-- flush with the far edge. Unlike the bar there is no config to consult and
-- nothing to paint, so this stays short.
-- @return widget, width, height
local function buildSpacerLine(text, cfg, available_w, max_width)
    local effective_w = max_width or available_w
    local before, after = text:match("^(.-)" .. SPACER_PLACEHOLDER .. "(.*)$")
    if not before then
        before, after = text, ""
    end

    local segments = {}
    local text_total_w = 0
    local max_h = 0

    local function addTextSegment(t)
        if t == "" then return end
        local display = cfg.uppercase and Utf8Proc.uppercase_dumb(t) or t
        local tw = TextWidget:new(textWidgetOpts({
            text = display,
            face = cfg.face,
            bold = cfg.bold,
        }, resolveTextColor(cfg.text_color)))
        local size = tw:getSize()
        table.insert(segments, { widget = tw, w = size.w, h = size.h })
        text_total_w = text_total_w + size.w
        if size.h > max_h then max_h = size.h end
    end

    addTextSegment(before)
    local gap_slot = #segments + 1
    addTextSegment(after)

    -- Keep the row the height of a text line even when the line is all gap,
    -- so an empty side does not collapse the row and shift its neighbours.
    if max_h == 0 and cfg.face then
        local ref = TextWidget:new(textWidgetOpts({
            text = " ", face = cfg.face, bold = cfg.bold }))
        max_h = ref:getSize().h
        ref:free()
    end

    local gap_w = math.max(0, effective_w - text_total_w)
    if gap_w < 1 then
        -- Text already fills the line: render it with no gap rather than
        -- returning nothing, so the content still shows.
        if #segments == 0 then return nil, 0, 0 end
        local row = HorizontalRowWidget:new{
            segments = segments, width = text_total_w, height = max_h }
        return row, text_total_w, max_h
    end

    table.insert(segments, gap_slot,
        { widget = GapWidget:new{ width = gap_w, height = max_h },
          w = gap_w, h = max_h })
    local total_w = text_total_w + gap_w
    local row = HorizontalRowWidget:new{
        segments = segments, width = total_w, height = max_h }
    return row, total_w, max_h
end

--- Build a HorizontalRowWidget for a line that contains a bar token.
-- Text is split on the BAR_PLACEHOLDER to preserve before/after segments.
-- @param text string: text with BAR_PLACEHOLDER where the bar goes
-- @param cfg table: line config with .bar = {kind, pct, ticks}, .face, .bold, etc.
-- @param available_w number: total available width for this line
-- @param max_width number or nil: truncation limit
-- @return widget, width, height
local function buildBarLine(text, cfg, available_w, max_width)
    local bar_info = cfg.bar
    -- Height precedence: inline %bar{v…} overrides the line's bar_height
    -- setting, which overrides the global read_height_pct-scaled font size,
    -- which overrides the raw font-size default.
    local read_pct = cfg.bar_colors and cfg.bar_colors.read_height_pct
    local font_h = cfg.face and cfg.face.size
    local font_scaled = (font_h and read_pct) and math.floor(font_h * read_pct / 100) or font_h
    local bar_h = (bar_info and bar_info.height)
        or cfg.bar_height or font_scaled or 5
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
        markers = bar_info.markers,
        style = bar_style,
        colors = cfg.bar_colors,
        reverse = cfg.bar_reverse or false,
        unread_height = cfg.bar_unread_height,
        hold_rects_owner = cfg.hold_rects_owner,
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
-- buildTextWidget takes line_texts as an ARRAY (one entry per config-line).
-- Each entry may itself contain embedded \n which expand to additional visual
-- rows that share the same config — that distinction matters: a literal \n
-- inside a single config-line's format string MUST keep that line's config
-- (font, bar flag, nudges, etc.) for every row it produces. Joining with \n
-- and splitting again loses that boundary, which is exactly what caused
-- bar-from-line-N to render onto the wrap-row of line-N-1 (the original bug
-- this signature change addresses).
function OverlayWidget.buildTextWidget(line_texts, line_configs, h_anchor, max_width, available_w)
    if max_width and max_width <= 0 then
        return nil, 0, 0
    end

    -- Walk per-config-line so each visual row carries its own config.
    -- Fallback to last config if fewer configs than texts; cfont as last-ditch
    -- since TextWidget crashes in font.lua's getAdjustedFace on a nil face.
    local lines = {}        -- visual row strings
    local lines_cfg = {}    -- 1:1 with lines, the config for that row
    local default_cfg = { face = Font:getFace("cfont"), bold = false }
    for ci, cfg_text in ipairs(line_texts) do
        local cfg = line_configs[ci] or line_configs[#line_configs] or default_cfg
        for row in cfg_text:gmatch("([^\n]+)") do
            table.insert(lines, row)
            table.insert(lines_cfg, cfg)
        end
    end
    if #lines == 0 then
        return nil, 0, 0
    end

    if #lines == 1 then
        local cfg = lines_cfg[1]
        -- Try styled segments (BBCode tags or bar placeholder)
        local segments, has_tags = OverlayWidget.parseStyledSegments(
            lines[1], cfg.bold, cfg.italic or false, cfg.uppercase,
            cfg.symbol_color)
        if segments then
            return OverlayWidget.buildStyledLine(segments, cfg, available_w or Screen:getWidth(), max_width)
        end
        -- Bar line without tags. Only when the row actually carries the
        -- placeholder — cfg.bar can be true for any visual row of a
        -- config-line that uses %bar, including rows that don't contain it.
        if cfg.bar and lines[1]:find(BAR_PLACEHOLDER, 1, true) then
            return buildBarLine(lines[1], cfg, available_w or Screen:getWidth(), max_width)
        end
        -- %spacer needs no cfg: it is a gap, not a configured object.
        if lines[1]:find(SPACER_PLACEHOLDER, 1, true) then
            return buildSpacerLine(lines[1], cfg, available_w or Screen:getWidth(), max_width)
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
        local cfg = lines_cfg[i]
        local widget, w, h
        -- Try styled segments (BBCode tags or bar placeholder)
        local segments, has_tags = OverlayWidget.parseStyledSegments(
            line, cfg.bold, cfg.italic or false, cfg.uppercase,
            cfg.symbol_color)
        if segments then
            widget, w, h = OverlayWidget.buildStyledLine(segments, cfg, available_w or Screen:getWidth(), max_width)
        elseif cfg.bar and line:find(BAR_PLACEHOLDER, 1, true) then
            -- Only treat as a bar row if it actually carries the placeholder.
            -- A config-line whose format string contains %bar plus literal \n
            -- produces multiple visual rows; only one of them holds the
            -- placeholder, the rest must render as plain text.
            widget, w, h = buildBarLine(line, cfg, available_w or Screen:getWidth(), max_width)
        elseif line:find(SPACER_PLACEHOLDER, 1, true) then
            widget, w, h = buildSpacerLine(line, cfg, available_w or Screen:getWidth(), max_width)
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
function OverlayWidget.buildAndMeasure(line_texts, line_configs, h_anchor)
    return OverlayWidget.buildTextWidget(line_texts, line_configs, h_anchor, nil)
end

--- Measure the text-only pixel width of a position's content (bar lines excluded).
-- Used for overlap prevention so bars don't inflate width calculations.
-- line_texts is an array (one per config-line); embedded \n inside a config-
-- line's text expands to additional visual rows that all share that config —
-- mirroring the buildTextWidget contract so bar-flag config doesn't leak to
-- wrap-rows of preceding lines.
--- Does this position contain anything that has no natural width?
---
--- %bar and %spacer are both ELASTIC: buildTextWidget sizes them from the
--- available width, so built unconstrained they are as wide as the screen.
--- That makes the widget's own width useless for any question of the form
--- "how much room does this position need" - the answer comes back as the
--- whole screen no matter what the position actually contains. Callers use
--- this to decide whether to trust the widget width or measure the text.
---
--- The bar case cost a release-blocking bug on its own; the spacer case cost
--- a worse one, because an unmeasured centre spacer reported 1248px of
--- content and calculateRowLimits truncated both its neighbours to zero, so
--- the left and right positions vanished from the row entirely.
function OverlayWidget.hasElasticWidth(line_texts)
    for _i, text in ipairs(line_texts or {}) do
        if text:find(BAR_PLACEHOLDER, 1, true)
        or text:find(SPACER_PLACEHOLDER, 1, true) then
            return true
        end
    end
    return false
end

function OverlayWidget.measureTextWidth(line_texts, line_configs)
    local max_w = 0
    local default_cfg = { face = Font:getFace("cfont"), bold = false }
    for ci, cfg_text in ipairs(line_texts) do
        local cfg = line_configs[ci] or line_configs[#line_configs] or default_cfg
        for row in cfg_text:gmatch("([^\n]+)") do
            -- The spacer is an elastic gap with no intrinsic width, on ANY
            -- line: buildTextWidget distributes the slack itself. Stripping it
            -- only for bar lines left the placeholder in the measurement
            -- everywhere else, where TextWidget sized it as a notdef glyph and
            -- inflated the overlap width, truncating the opposite position on
            -- that row for no reason.
            local measure_text = row:gsub(SPACER_PLACEHOLDER, "")
            if cfg.bar then
                measure_text = measure_text:gsub(BAR_PLACEHOLDER, "")
            end
            -- Strip BBCode tags so they don't inflate the overlap-prevention
            -- width and falsely trigger the truncation path for bar lines.
            measure_text = measure_text:gsub("%[[/]?[biu]%]", ""):gsub("%[/?c[^%]]*%]", ""):gsub("%[icon=[^%]]*%]", "")
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
function OverlayWidget.parseStyledSegments(text, base_bold, base_italic, base_uppercase, symbol_color)
    -- Fast path: no BBCode tags AND no icon-colour to apply -> caller renders
    -- the whole line as plain text with base style.  When symbol_color is set
    -- we still walk the string so PUA icon glyphs can be emitted as their own
    -- colour-bearing segments (see emitPua below).
    if not text:find("%[") and not symbol_color then
        return nil, false
    end

    local segments = {}
    local stack = {}  -- style stack: each entry is "b", "i", or "u"
    local color_stack = {}  -- color stack: each entry is a {grey=N} or {hex=H} table
    local font_stack = {}  -- font stack: each entry is a font display name (string)
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

    local function currentFont()
        if #font_stack == 0 then return nil end
        return font_stack[#font_stack]
    end

    local function flushPending()
        if pending == "" then return end
        local bold, italic, uppercase = currentStyle()
        local seg = { text = pending, bold = bold, italic = italic, uppercase = uppercase }
        local clr = currentColor()
        if clr then seg.color = clr end
        local fnt = currentFont()
        if fnt then seg.font = fnt end
        table.insert(segments, seg)
        pending = ""
    end

    -- Emit a single PUA (Nerd Font / FontAwesome icon) glyph as its own
    -- segment, using either the active user-authored [c=...] colour or the
    -- global icon colour (symbol_color). This is the replacement for the
    -- old Tokens.expand [c=…]PUA[/c] auto-wrap: by deciding per-segment at
    -- parse time, no ghost tags exist in any intermediate string that might
    -- be rendered if the line has an unclosed user tag and the parser
    -- falls back to plain-text.
    local function emitPua(pua)
        flushPending()
        local bold, italic, uppercase = currentStyle()
        local seg = { text = pua, bold = bold, italic = italic, uppercase = uppercase }
        local clr = currentColor()
        if clr then
            seg.color = clr
        elseif symbol_color then
            seg.color = symbol_color
            found_tags = true  -- parser applied meaningful colouring, not just plain text
        end
        local fnt = currentFont()
        if fnt then seg.font = fnt end
        table.insert(segments, seg)
    end

    local len = #text
    while pos <= len do
        -- Check for bar placeholder (3-byte UTF-8: \xEF\xBF\xBC)
        if text:sub(pos, pos + 2) == BAR_PLACEHOLDER then
            flushPending()
            table.insert(segments, { bar = true })
            pos = pos + 3
        elseif text:sub(pos, pos + 2) == SPACER_PLACEHOLDER then
            flushPending()
            table.insert(segments, { spacer = true })
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
        -- Check for closing font tag [/font]
        elseif text:match("^%[/font%]", pos) then
            if #font_stack > 0 then
                flushPending()
                table.remove(font_stack)
                found_tags = true
                pos = pos + 7  -- [/font] = 7 chars
            else
                -- Mismatched close — render entire line as plain text
                return nil, false
            end
        -- Check for opening font tag [font=NAME]. NAME is read verbatim up to the
        -- first ']' and trimmed, so font display names with spaces work
        -- (e.g. [font=BIZ UDPMincho]). Resolution to an actual face happens in
        -- buildStyledLine; an unknown name there falls back to the line font.
        elseif text:match("^%[font=[^%]]*%]", pos) then
            local raw, end_pos = text:match("^%[font=([^%]]*)()%]", pos)
            local name = (raw or ""):gsub("^%s*(.-)%s*$", "%1")
            flushPending()
            table.insert(font_stack, name)
            found_tags = true
            pos = end_pos + 1  -- skip past the ']'
        -- Check for self-closing icon tag [icon=NAME]. NAME is an icon
        -- filename without extension, resolved at build time via KOReader's
        -- IconWidget (koreader/icons/ first, then built-in mdlight). Atomic:
        -- one tag = one image segment, no closing tag. NAME is read verbatim
        -- up to the first ']' and trimmed, mirroring the [font=NAME] branch.
        elseif text:match("^%[icon=[^%]]*%]", pos) then
            local raw, end_pos = text:match("^%[icon=([^%]]*)()%]", pos)
            local name = (raw or ""):gsub("^%s*(.-)%s*$", "%1")
            if name ~= "" then
                flushPending()
                table.insert(segments, { icon = name })
                found_tags = true
            end
            pos = end_pos + 1  -- skip past the ']'
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
        -- Check for opening hex colour tag [c=#RRGGBB] or short [c=#RGB].
        -- Store the normalised long form on color_stack so downstream
        -- consumers (parseColorValue, getting the segment colour) see a
        -- single canonical shape regardless of which form the user typed.
        elseif text:match("^%[c=#%x%x%x%x%x%x%]", pos) or text:match("^%[c=#%x%x%x%]", pos) then
            local raw, end_pos = text:match("^%[c=(#%x%x%x%x%x%x)()%]", pos)
            if not raw then
                raw, end_pos = text:match("^%[c=(#%x%x%x)()%]", pos)
            end
            if raw then
                local hex = require("bookends_colour").normaliseHex(raw)
                if hex then
                    flushPending()
                    table.insert(color_stack, { hex = hex })
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
        -- Check for opening colour tag [c=N] where N is 0-100 (greyscale percent)
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
            -- PUA icon glyph? 0xEE[80-BF][80-BF] covers U+E000-U+EFFF;
            -- 0xEF[80-A3][80-BF] covers U+F000-U+F8FF (Nerd Fonts land
            -- in both ranges, FontAwesome sits in the second). If one is
            -- found AND we're not already inside a user-authored [c=...],
            -- emit it as its own coloured segment so the icon colour
            -- applies without needing to exist as a [c=...] tag in the
            -- expanded line.
            local b1 = text:byte(pos)
            local pua
            if b1 == 0xEE then
                pua = text:match("^\xEE[\x80-\xBF][\x80-\xBF]", pos)
            elseif b1 == 0xEF then
                pua = text:match("^\xEF[\x80-\xA3][\x80-\xBF]", pos)
            end
            if pua then
                emitPua(pua)
                pos = pos + 3
            else
                pending = pending .. text:sub(pos, pos)
                pos = pos + 1
            end
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
    if #font_stack > 0 then
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
    local spacer_slot = nil  -- index where the elastic gap goes

    for _, seg in ipairs(segments) do
        if seg.bar then
            -- Remember bar position, insert later after measuring text
            bar_slot = #widgets + 1
        elseif seg.spacer then
            -- Same deal for the elastic gap.
            spacer_slot = #widgets + 1
        elseif seg.icon then
            local IconWidget = require("ui/widget/iconwidget")
            -- Square, sized to the line's font size so it sits inline on the
            -- text baseline. cfg.face.size is the scaled pixel size.
            local icon_size = math.floor((cfg.face and cfg.face.size) or 20)
            -- Respect the line's truncation limit. An icon is atomic -- it
            -- can't be ellipsis-truncated like text -- so if the available
            -- width is already used up, stop adding segments (mirrors the
            -- text branch's `remaining <= 0 then break`).
            if max_width then
                local remaining = max_width - total_w
                if remaining <= 0 then break end
            end
            local icon_w = IconWidget:new{
                icon = seg.icon,
                width = icon_size,
                height = icon_size,
                alpha = true,   -- keep SVG/PNG own colours (render as-is)
            }
            -- Missing-file guard: IconWidget resolves to the built-in
            -- "icon-not-found" glyph when NAME exists in neither
            -- koreader/icons/ nor the built-in set. Render nothing instead,
            -- so a shared preset referencing an icon the recipient lacks
            -- degrades silently (mirrors unknown [font=...] falling back).
            if icon_w.file and icon_w.file:find("icon-not-found", 1, true) then
                if icon_w.free then icon_w:free() end
            else
                local size = icon_w:getSize()
                table.insert(widgets, { widget = icon_w, w = size.w, h = size.h })
                total_w = total_w + size.w
                -- Count icon width as non-bar width so a same-line %bar is
                -- sized against the remaining space (text_total_w drives bar_w).
                text_total_w = text_total_w + size.w
                if size.h > max_h then max_h = size.h end
            end
        else
            local display = seg.uppercase and Utf8Proc.uppercase_dumb(seg.text) or seg.text
            if display ~= "" then
                -- Resolve the segment's base font family. A [font=NAME] span
                -- (seg.font) overrides the line's family for this segment only;
                -- if NAME can't be resolved (font not installed) we silently keep
                -- the line font, so shared presets degrade gracefully.
                local base_face = cfg.face
                local base_face_name = cfg.face_name
                if seg.font then
                    local file = resolveSegFontFile(seg.font)
                    if file then
                        base_face_name = file
                        base_face = Font:getFace(file, cfg.font_size)
                    end
                end

                -- Resolve font face and synthetic bold for this segment
                local seg_face = base_face
                local seg_synthetic_bold = false
                if base_face_name and (seg.bold or seg.italic) then
                    local style = (seg.bold and seg.italic and "bolditalic")
                        or (seg.bold and "bold") or "italic"
                    local variant = OverlayWidget.findFontVariant(base_face_name, style)
                    if variant then
                        seg_face = Font:getFace(variant, cfg.font_size)
                    elseif style == "bolditalic" then
                        -- Fallback: italic file + synthetic bold
                        local italic = OverlayWidget.findFontVariant(base_face_name, "italic")
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
                    seg_fgcolor = resolveTextColor(seg.color)
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

    -- Handle the elastic gap if present. Placed before the bar block so a
    -- styled line carrying both still gives the remaining width to the bar,
    -- matching the token pass which drops %spacer when %bar is present.
    if spacer_slot and not (bar_slot and cfg.bar) then
        local gap_w = math.max(0, effective_w - text_total_w)
        if gap_w >= 1 then
            table.insert(widgets, spacer_slot,
                { widget = GapWidget:new{ width = gap_w, height = max_h },
                  w = gap_w, h = max_h })
            total_w = total_w + gap_w
        end
    end

    -- Handle bar segment if present
    if bar_slot and cfg.bar then
        local bar_info = cfg.bar
        -- Height precedence: inline %bar{v…} overrides the line's bar_height
        -- setting, which overrides the global read_height_pct-scaled font size,
        -- which overrides the raw font-size default.
        local read_pct = cfg.bar_colors and cfg.bar_colors.read_height_pct
        local font_h = cfg.face and cfg.face.size
        local font_scaled = (font_h and read_pct) and math.floor(font_h * read_pct / 100) or font_h
        local bar_h = (bar_info and bar_info.height)
            or cfg.bar_height or font_scaled or 5
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
                markers = bar_info.markers,
                style = bar_style,
                colors = cfg.bar_colors,
                reverse = cfg.bar_reverse or false,
                unread_height = cfg.bar_unread_height,
                hold_rects_owner = cfg.hold_rects_owner,
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
-- @param left_offset number or nil: the left side's horizontal offset+margin.
-- @param right_offset number or nil: the right side's horizontal offset+margin.
--   When supplied, a lone side is capped to the true content width
--   (screen minus BOTH offsets) so it can't run to the screen edge and
--   collapse the opposite margin (issue #43). Omitted → fall back to the
--   symmetric 2*h_offset reservation.
-- Returns { left=max_w|nil, center=max_w|nil, right=max_w|nil }.
--- The widest a line can be before it overflows bookends' own margins (#108).
---
--- calculateRowLimits only caps a line that COLLIDES with a neighbour, so a
--- line alone on its row was never measured against the screen at all and a
--- long chapter title ran off the edge. This is the fallback cap for that
--- case, and it depends on the anchor:
---
---   left    x = ml + off            -> room = screen - ml - off - mr
---   right   x = screen - w - mr - off -> room = screen - mr - off - ml
---   center  x = (screen - w)/2 + off -> symmetric about the middle, so
---           both margins bind at once and the tighter one wins:
---           x >= ml       gives w <= screen - 2*(ml - off)
---           x + w <= s-mr gives w <= screen - 2*(mr + off)
---
--- Doing this inline with the position's OWN margin doubled was only right for
--- a centred line on symmetric margins: getMargin hands back margin_right for
--- tc/tr/bc/br, so the near margin was counted twice and the far one not at
--- all, and a left-anchored line lost twice its h_offset instead of once.
--- @return number  a non-negative width
function OverlayWidget.marginRoom(h_anchor, screen_w, margin_left, margin_right, h_offset)
    screen_w     = tonumber(screen_w) or 0
    margin_left  = tonumber(margin_left) or 0
    margin_right = tonumber(margin_right) or 0
    h_offset     = tonumber(h_offset) or 0
    local room
    if h_anchor == "center" then
        room = screen_w - 2 * math.max(margin_left - h_offset, margin_right + h_offset)
    elseif h_anchor == "right" then
        room = screen_w - margin_right - h_offset - margin_left
    else
        room = screen_w - margin_left - h_offset - margin_right
    end
    return math.max(0, room)
end

function OverlayWidget.calculateRowLimits(left_w, center_w, right_w, screen_w, gap, h_offset, priority, left_offset, right_offset)
    local limits = { left = nil, center = nil, right = nil }

    -- No centre, both sides: flex layout regardless of priority. The priority
    -- toggle only matters when a centre exists (it decides who gets truncated
    -- first when content overflows). When there's no centre, both modes
    -- should produce identical results: a small side lets the other side use
    -- the full remaining width, with symmetric half/half as the fallback.
    if not center_w and left_w and right_w then
        local half = math.floor(screen_w / 2) - math.floor(gap / 2)
        local effective_half = math.max(0, half - h_offset)
        if left_w <= effective_half and right_w <= effective_half then
            -- Both fit naturally; no caps needed.
        elseif left_w <= effective_half then
            limits.right = math.max(0, screen_w - gap - 2 * h_offset - left_w)
        elseif right_w <= effective_half then
            limits.left = math.max(0, screen_w - gap - 2 * h_offset - right_w)
        else
            limits.left = effective_half
            limits.right = effective_half
        end
        return limits
    end

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
        -- No centre, both sides handled by the early-return flex block above.
        -- This branch only handles the left-only and right-only cases.
        -- A lone side is anchored at its own offset and must still leave the
        -- opposite margin intact, so cap to screen minus BOTH offsets. When the
        -- per-side offsets aren't supplied, reserve the (max) margin on both
        -- sides via 2*h_offset rather than the near side alone (issue #43).
        local lo = left_offset or h_offset
        local ro = right_offset or h_offset
        if left_w and not right_w then
            local max = math.max(0, screen_w - lo - ro)
            if left_w > max then limits.left = max end
        end
        if right_w and not left_w then
            local max = math.max(0, screen_w - lo - ro)
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

-- Canonical list of styles paintProgressBar dispatches on. Exported so
-- downstream consumers (bookshelf's hero bar picker, third-party themes,
-- etc.) can enumerate the available styles without grepping the
-- if/elseif chain inside paintProgressBar. Order = the order the styles
-- were introduced; readers that want a stable cycle should follow this
-- ordering. Add new entries here when paintProgressBar gains a new
-- branch — the source of truth for "does bookends support style X?".
OverlayWidget.BAR_STYLES = {
    "bordered", "solid", "rounded", "metro", "wavy",
    "radial", "radial_hollow", "pacman",
}

--- Paint a progress bar directly to a blitbuffer.
-- @param orientation "horizontal" (default) or "vertical"
-- @param reverse boolean: flip fill direction
-- @param colors table or nil: { fill = Blitbuffer color, bg = Blitbuffer color }
function OverlayWidget.paintProgressBar(bb, x, y, w, h, fraction, ticks, style, orientation, reverse, colors, markers)
    if w < 1 or h < 1 then return end
    fraction = math.max(0, math.min(1, fraction or 0))
    local vertical = orientation == "vertical"
    -- Custom colors: nil = not set (use default), false = transparent (skip paint)
    local custom_fill = colors and colors.fill
    local custom_bg = colors and colors.bg
    local custom_tick = colors and colors.tick
    local invert_read_ticks = colors and colors.invert_read_ticks
    local tick_height_pct = colors and colors.tick_height_pct or 100
    local custom_border = colors and colors.border
    local custom_invert = colors and colors.invert

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
            bbPaintRect(bb, ry, rx, rh, rw, color)
        else
            bbPaintRect(bb, rx, ry, rw, rh, color)
        end
    end

    -- Work in abstract coordinates: length = progress axis, thickness = cross axis
    local length = vertical and h or w
    local thickness = vertical and w or h
    local ox = vertical and y or x  -- origin along progress axis
    local oy = vertical and x or y  -- origin along cross axis

    -- Asymmetric thickness: read side = full `thickness`, unread side = a
    -- separate value (centred on the same midline). nil/equal = symmetric,
    -- and the per-style code paths collapse back to the existing render.
    -- Resolution order for unread thickness:
    --   1. colors.unread_height (per-bar absolute px) — wins if set
    --   2. colors.unread_height_pct (global %)        — fallback
    --   3. read_thick                                 — symmetric default
    local read_thick = thickness
    local unread_thick
    if colors and colors.unread_height then
        unread_thick = colors.unread_height
    elseif colors and colors.unread_height_pct then
        unread_thick = math.floor(read_thick * colors.unread_height_pct / 100)
    else
        unread_thick = read_thick
    end
    if unread_thick < 0 then unread_thick = 0 end
    if unread_thick > read_thick then unread_thick = read_thick end
    local unread_oy = oy + math.floor((read_thick - unread_thick) / 2)

    if style == "metro" then
        -- Metro style: start ring, trunk line, position dot, ticks above/below
        local line_thick = math.max(3, math.floor(thickness * 0.2))
        local start_r = math.floor(thickness / 2)  -- full height circle
        local dot_r = math.max(4, math.floor(thickness * 0.35))
        local line_y = oy + math.floor((thickness - line_thick) / 2)
        local unread_line_thick = unread_thick == read_thick and line_thick
            or math.max(1, math.floor(line_thick * unread_thick / read_thick))
        local unread_line_y = oy + math.floor((thickness - unread_line_thick) / 2)
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

        -- Metro reads fill/bg like every other style now. Defaults match the
        -- previous all-dark-grey trunk so an unconfigured metro bar is
        -- visually unchanged. The legacy track/metro_fill fields are aliased
        -- to bg/fill upstream by Colour.resolveBarColors (back-compat shim).
        local metro_read   = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local metro_unread = resolveColor(custom_bg,   Blitbuffer.COLOR_DARK_GRAY)
        -- Trunk: read portion at full line_thick, unread portion at unread_line_thick.
        -- Both centred on the bar's cross-axis. When symmetric they coincide.
        local read_trunk_start = reverse and (line_len - line_fill) or 0
        local unread_trunk_start = reverse and 0 or line_fill
        local unread_trunk_len = line_len - line_fill
        if line_fill > 0 then
            pr(line_ox + read_trunk_start, line_y, line_fill, line_thick, metro_read)
        end
        if unread_trunk_len > 0 and unread_line_thick > 0 and unread_thick > 0 then
            pr(line_ox + unread_trunk_start, unread_line_y, unread_trunk_len, unread_line_thick, metro_unread)
        end

        -- Chapter ticks: depth 1 above line (connected to trunk), depth 2 below.
        -- When reversed, flip tick sides so the visual hierarchy mirrors the direction.
        -- Tick height is uniform across both halves — derived from the read
        -- thickness so unread-half ticks don't shrink with the trunk.
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
                -- Tick recolouring: ticks within the read portion paint in metro_read
                local is_read
                if reverse then
                    is_read = tick_pos >= line_len - line_fill
                else
                    is_read = tick_pos <= line_fill
                end
                local tick_color = is_read and metro_read or metro_unread
                -- Anchor ticks at the bar's vertical centre so they always cross
                -- the trunk regardless of read/unread thickness asymmetry.
                local centre_y = oy + math.floor(thickness / 2)
                if tick_above then
                    pr(line_ox + tick_pos, centre_y - metro_tick_h, line_thick, metro_tick_h, tick_color)
                else
                    pr(line_ox + tick_pos, centre_y, line_thick, metro_tick_h, tick_color)
                end
            end
        end

        -- Helper for circles
        local function paintCircle(cx, cy, r, color)
            if not color then return end
            if vertical then
                bbPaintRoundedRect(bb, cy, cx, r * 2, r * 2, color, r)
            else
                bbPaintRoundedRect(bb, cx, cy, r * 2, r * 2, color, r)
            end
        end

        -- Start circle (empty ring; read colour when set, else trunk colour)
        local start_cx = reverse and (line_ox + line_len - start_r) or (line_ox - start_r)
        paintCircle(start_cx, oy, start_r, metro_read or metro_unread)
        local ring_border = line_thick
        local inner_r = start_r - ring_border
        if inner_r > 0 then
            -- Inner ring is paper-coloured. KOReader's night-mode framebuffer
            -- inversion maps COLOR_WHITE → COLOR_BLACK at refresh time, so the
            -- ring stays visually correct on inverted reads. Previously this
            -- read colors.invert, overloading that field (also used for tick
            -- inversion). Decoupled here so "Tick inversion colour" in the
            -- menu only describes tick behaviour.
            paintCircle(start_cx + ring_border, oy + ring_border, inner_r,
                Blitbuffer.COLOR_WHITE)
        end

        -- End circle (filled, trunk colour, same size as start)
        local end_cx = reverse and (line_ox - start_r) or (line_ox + line_len - start_r)
        paintCircle(end_cx, oy, start_r, metro_unread)

        -- Current position dot (uses tick colour, default black)
        local pos_on_line = reverse and (line_len - line_fill) or line_fill
        local dot_cx = line_ox + pos_on_line - dot_r
        local dot_cy = oy + math.floor((thickness - dot_r * 2) / 2)
        paintCircle(dot_cx, dot_cy, dot_r, resolveColor(custom_tick, Blitbuffer.COLOR_BLACK))

    elseif style == "wavy" then
        -- Wavy ribbon: the entire bar follows a sine wave path.
        -- Two-toned fill with a position dot riding the curve.
        local wave_fill  = resolveColor(custom_fill, Blitbuffer.COLOR_DARK_GRAY)
        local wave_track = resolveColor(custom_bg,   Blitbuffer.COLOR_GRAY)
        local wave_dot = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)

        local amplitude = math.floor(thickness * 0.35)
        local ribbon_h = math.max(3, math.floor(thickness * 0.4))
        local half_ribbon = math.floor(ribbon_h / 2)
        local unread_ribbon_h = unread_thick == read_thick and ribbon_h
            or math.max(1, math.floor(ribbon_h * unread_thick / read_thick))
        local unread_half_ribbon = math.floor(unread_ribbon_h / 2)
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
                bbPaintRoundedRect(bb, ry, rx, d, d, color, cap_r)
            else
                bbPaintRoundedRect(bb, rx, ry, d, d, color, cap_r)
            end
        end
        paintCap(ox, wave_y(0), start_color)
        paintCap(ox + length - 1, wave_y(length - 1), end_color)

        -- Paint ribbon column by column. Read columns use full ribbon_h;
        -- unread columns use the (possibly thinner) unread_ribbon_h, centred
        -- on the same wave path. Symmetric configs collapse to the prior render.
        for i = 0, length - 1 do
            local cy = wave_y(i)
            local in_fill = i >= fill_start and i < fill_end
            local color = in_fill and wave_fill or wave_track
            if not in_fill and unread_thick == 0 then color = nil end
            local h_local = in_fill and ribbon_h or unread_ribbon_h
            local half_local = in_fill and half_ribbon or unread_half_ribbon
            local ry = cy - half_local
            if color then
                if vertical then
                    bbPaintRect(bb, ry, ox + i, h_local, 1, color)
                else
                    bbPaintRect(bb, ox + i, ry, 1, h_local, color)
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
                local in_fill = tick_pos >= fill_start and tick_pos < fill_end
                -- Tick height scales to local ribbon thickness (read or unread).
                local local_ribbon_h = in_fill and ribbon_h or unread_ribbon_h
                local th = math.max(1, math.floor(local_ribbon_h * tick_height_pct / 100))
                local ty = cy - math.floor(th / 2)
                local base_tick = wave_dot
                if base_tick then
                    local tick_color
                    if invert_read_ticks ~= false and in_fill then
                        tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                    else
                        tick_color = base_tick
                    end
                    if vertical then
                        bbPaintRect(bb, ty, ox + tick_pos, th, tick_w, tick_color)
                    else
                        bbPaintRect(bb, ox + tick_pos, ty, tick_w, th, tick_color)
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
                bbPaintRoundedRect(bb, dot_dy, dot_cx, dot_r * 2, dot_r * 2, wave_dot, dot_r)
            else
                bbPaintRoundedRect(bb, dot_cx, dot_dy, dot_r * 2, dot_r * 2, wave_dot, dot_r)
            end
        end

    elseif style == "pacman" then
        -- Pacman bar: read portion is empty, pacman sprite at the read
        -- fraction, dot strip and power pellet in the unread region.
        --
        -- Mouth animation: each pacman is keyed by its top-left screen
        -- position. First sighting at a position seeds its counter from
        -- a monotonic sequence (so two pacmans appearing side-by-side in
        -- the same paint start in opposite mouth phase). Every subsequent
        -- paintProgressBar call increments that pacman's own counter, so
        -- the animation advances on each repaint regardless of how many
        -- pacmans are on screen or who is driving the paint (bookends
        -- overlay, bookshelf, etc.).
        local pacman_key = math.floor(x) .. "_" .. math.floor(y)
        local frame = _pacman_frames[pacman_key]
        if frame == nil then
            _pacman_seq = _pacman_seq + 1
            frame = _pacman_seq
        end
        _pacman_frames[pacman_key] = frame + 1
        local mouth_open = (frame % 2) == 1

        -- Resolve colours. Authentic arcade hex on colour-enabled devices;
        -- strong greyscale defaults on B&W. Custom overrides via the existing
        -- per-bar colors table flow through resolveColor as elsewhere.
        local is_colour = Screen and Screen.isColorEnabled and Screen:isColorEnabled()
        local default_fill, default_dot
        if is_colour then
            default_fill = Colour.parseColorValue({ hex = "#FFCC00" }, true)
            default_dot  = Colour.parseColorValue({ hex = "#FFB897" }, true)
        else
            -- On greyscale screens, lean into "softer than black" — a hard
            -- black silhouette reads harsh next to text. Pacman sits a
            -- couple of shades darker than the dots so it still leads
            -- visually. Explicit Color8 bytes so the values don't drift
            -- if Blitbuffer renames its named constants.
            default_fill = Blitbuffer.Color8(0x22)
            default_dot  = Blitbuffer.COLOR_DARK_GRAY
        end
        local pac_fill = resolveColor(custom_fill, default_fill)
        local pac_dot  = resolveColor(custom_bg, default_dot)

        -- Pick frame + rotation. Direction "ltr"/"rtl" map to right/left;
        -- "ttb"/"btt" map to down/up.
        local dir_map = { ltr = "right", rtl = "left", ttb = "down", btt = "up" }
        local facing = dir_map[orientation == "vertical"
            and (reverse and "btt" or "ttb")
            or (reverse and "rtl" or "ltr")] or "right"
        local frame_name = mouth_open and "open" or "closed"
        local sprite = PacmanSprite.rotate(
            PacmanSprite.getFrame(frame_name),
            PacmanSprite.directionToSteps(facing))

        -- Block scale: minimum 2 device px per arcade pixel so the sprite
        -- stays legible — at thickness=14 (typical inline) a block=1 sprite
        -- is only 13 px, which is too small to read. Block=2 gives 26 px,
        -- which slightly overflows the bar in both directions (see
        -- `feedback_tick_overflow_intentional`) but is the right minimum.
        local block = math.max(2, math.floor(thickness / 10))
        local sprite_px = 13 * block

        -- `length` and `thickness` are already in scope from the function preamble.
        local fraction_px = math.floor(fraction * length)

        -- We track two positions on the fill axis:
        --   * `pacman_canonical_start` — canonical (un-mirrored) leading-edge
        --     of pacman. Grows from 0 to length-sprite_px regardless of
        --     direction. Used to decide which dots are still ahead of the
        --     reader.
        --   * `sprite_start` — the actual paint coordinate. Same as the
        --     canonical position for forward bars; mirrored about the bar's
        --     centre for reversed bars.
        local pacman_canonical_start = math.floor(fraction_px - sprite_px / 2)
        pacman_canonical_start = math.max(0, math.min(length - sprite_px, pacman_canonical_start))
        local pacman_canonical_lead = pacman_canonical_start + sprite_px
        local sprite_start = reverse
            and (length - sprite_px - pacman_canonical_start)
            or pacman_canonical_start

        -- Perpendicular axis: centre the sprite on the bar midline.
        local cross_offset = math.floor((thickness - sprite_px) / 2)

        -- Paint sprite. For each "on" cell in the 13x13 grid, draw a
        -- block-sized rect.
        --
        -- Horizontal bars: sprite col maps to the bar's progress axis
        --   (the wedge sits on the right edge of the right-facing base sprite).
        -- Vertical bars: the sprite is rotated so its wedge ends up on the
        --   row axis (top or bottom of the grid), so row maps to the bar's
        --   progress axis instead.
        if pac_fill then
            for row = 0, 12 do
                for col = 0, 12 do
                    local mask = 2 ^ col
                    if (math.floor(sprite[row + 1] / mask) % 2) == 1 then
                        local axis_off, cross_off
                        if vertical then
                            axis_off = sprite_start + row * block
                            cross_off = cross_offset + col * block
                        else
                            axis_off = sprite_start + col * block
                            cross_off = cross_offset + row * block
                        end
                        -- `ox` is the progress-axis origin, `oy` the cross-axis
                        -- origin: in vertical mode `ox` == screen y and `oy` ==
                        -- screen x, so `rect_x` gets `oy` and `rect_y` gets `ox`.
                        local rect_x, rect_y
                        if vertical then
                            rect_x = oy + cross_off
                            rect_y = ox + axis_off
                        else
                            rect_x = ox + axis_off
                            rect_y = oy + cross_off
                        end
                        bbPaintRect(bb, rect_x, rect_y, block, block, pac_fill)
                    end
                end
            end
        end

        -- Dot strip + pellet. Dots sit at FIXED canonical positions on
        -- the bar (independent of pacman). On each paint we filter to the
        -- dots still ahead of pacman's leading edge — the rest are
        -- "eaten". This keeps dots anchored to the bar instead of
        -- shifting around as pacman moves.
        local dot_block = math.max(3, math.floor(thickness / 6))
        local pellet_block = dot_block * 2

        if pac_dot then
            local layout = PacmanSprite.layoutDots(length, dot_block, pellet_block)
            local dot_cross = math.floor((thickness - dot_block) / 2)
            local pellet_cross = math.floor((thickness - pellet_block) / 2)

            -- Map a canonical bar position (0..length) to its actual
            -- paint coord. For reversed bars, mirror about the bar centre
            -- so the pellet lands at the far end (opposite pacman's start).
            local function toActual(canonical_pos, element_block)
                if reverse then
                    return length - canonical_pos - element_block
                else
                    return canonical_pos
                end
            end

            -- Paint each marker until the leading edge has crossed its
            -- entire footprint. Vanishing the marker the moment the
            -- leading edge first reaches it goes by too fast to read at
            -- typical page-turn cadence; holding it through dot_block
            -- pixels of overlap gives a couple of frames where the
            -- contact is visible before it disappears.
            for _idx, canonical_dot in ipairs(layout.dots) do
                if canonical_dot + dot_block > pacman_canonical_lead then
                    local axis = toActual(canonical_dot, dot_block)
                    local rect_x, rect_y
                    if vertical then
                        rect_x = oy + dot_cross
                        rect_y = ox + axis
                    else
                        rect_x = ox + axis
                        rect_y = oy + dot_cross
                    end
                    bbPaintRect(bb, rect_x, rect_y, dot_block, dot_block, pac_dot)
                end
            end

            -- Pellet at the far canonical end of the bar; paint until
            -- pacman has reached it.
            if layout.pellet and layout.pellet >= pacman_canonical_lead then
                local axis = toActual(layout.pellet, pellet_block)
                local rect_x, rect_y
                if vertical then
                    rect_x = oy + pellet_cross
                    rect_y = ox + axis
                else
                    rect_x = ox + axis
                    rect_y = oy + pellet_cross
                end
                bbPaintRect(bb, rect_x, rect_y, pellet_block, pellet_block, pac_dot)
            end
        end

        -- Chapter ticks intentionally not rendered for pacman (the strip is
        -- already dot-dense and tick markers don't read at this density).

    elseif style == "radial" or style == "radial_hollow" then
        -- Radial (pie-chart) style: a circle filled clockwise from 12 o'clock.
        -- Two distinct asymmetric models:
        --   solid:  unread arc draws as a smaller pie wedge (scaled diameter),
        --           with radial connector lines at the angular boundaries.
        --   hollow: unread arc keeps the read band's diameter but uses a
        --           thinner ring centred on the read band's midline.
        local diameter = math.min(vertical and h or w, vertical and w or h)
        local radius = math.floor(diameter / 2)
        if radius < 2 then radius = 2 end
        -- Center the circle in the allocated rectangle
        local cx = x + math.floor(w / 2)
        local cy = y + math.floor(h / 2)

        local radial_bg = resolveColor(custom_bg, Blitbuffer.COLOR_GRAY)
        -- Match solid bar's GRAY_5 (0x55) read default. DARK_GRAY (0x88) was
        -- only 0x22 darker than the GRAY (0xAA) unread bg — too washed-out
        -- on e-ink to read as a clear progress indicator.
        local radial_fill = resolveColor(custom_fill, Blitbuffer.COLOR_GRAY_5)
        local radial_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
        local radial_border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)

        local hollow = style == "radial_hollow"
        local inner_radius = hollow and math.floor(radius * 0.55) or 0

        local r2 = radius * radius
        local inner_r2 = inner_radius * inner_radius
        local two_pi = 2 * math.pi

        -- Asymmetric geometry differs by style.
        -- For solid: unread radii scale down (smaller pie wedge).
        -- For hollow: unread band is thinner, centred on read band's midline.
        local unread_radius, unread_inner_radius, unread_r2, unread_inner_r2
        local mid_r, band_half, unread_band_half, unread_outer_band_r, unread_inner_band_r
        if hollow then
            mid_r = (radius + inner_radius) / 2
            band_half = (radius - inner_radius) / 2
            unread_band_half = unread_thick == read_thick and band_half
                or band_half * unread_thick / read_thick
            unread_outer_band_r = mid_r + unread_band_half
            unread_inner_band_r = mid_r - unread_band_half
            unread_radius = unread_outer_band_r
            unread_inner_radius = unread_inner_band_r
            unread_r2 = unread_outer_band_r * unread_outer_band_r
            unread_inner_r2 = unread_inner_band_r * unread_inner_band_r
        else
            -- Solid: scale full radius
            unread_radius = unread_thick == read_thick and radius
                or math.floor(radius * unread_thick / read_thick)
            unread_inner_radius = 0
            unread_r2 = unread_radius * unread_radius
            unread_inner_r2 = 0
        end

        -- Paint the pie/donut pixel by pixel.
        for py = -radius, radius - 1 do
            for px = -radius, radius - 1 do
                local dx = px + 0.5
                local dy = py + 0.5
                local d2 = dx * dx + dy * dy
                local angle = math.atan2(dx, -dy)
                if angle < 0 then angle = angle + two_pi end
                local pixel_frac = angle / two_pi
                local in_fill = pixel_frac <= fraction
                if in_fill then
                    if d2 <= r2 and d2 > inner_r2 then
                        if radial_fill then
                            bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_fill)
                        end
                    end
                else
                    if d2 <= unread_r2 and d2 > unread_inner_r2 then
                        if radial_bg then
                            bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_bg)
                        end
                    end
                end
            end
        end

        -- Chapter tick marks: radial lines at each chapter boundary.
        -- Per-half: read ticks span the read band; unread ticks span the unread band
        -- (which for solid is a smaller-radius pie, for hollow is a thinner ring).
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            local tick_angle = tick_frac * two_pi
            local cos_a = math.cos(tick_angle - math.pi / 2)
            local sin_a = math.sin(tick_angle - math.pi / 2)
            local in_fill = tick_frac <= fraction
            local local_outer = in_fill and radius or unread_radius
            local local_inner = in_fill and inner_radius or unread_inner_radius
            if local_outer > 0 and local_outer > local_inner then
                local span = local_outer - local_inner
                local inner_r_for_tick = math.floor(local_outer - span * tick_height_pct / 100)
                if inner_r_for_tick < local_inner then inner_r_for_tick = local_inner end
                for t = inner_r_for_tick, local_outer do
                    local lx = cx + math.floor(t * cos_a)
                    local ly = cy + math.floor(t * sin_a)
                    local pix_angle = math.atan2(t * cos_a, -(t * sin_a))
                    if pix_angle < 0 then pix_angle = pix_angle + two_pi end
                    local pix_frac = pix_angle / two_pi
                    local pix_in_fill = pix_frac <= fraction
                    local tick_color
                    if invert_read_ticks ~= false and pix_in_fill then
                        tick_color = resolveColor(custom_invert, Blitbuffer.COLOR_WHITE)
                    else
                        tick_color = radial_tick
                    end
                    if tick_color then
                        bbPaintRect(bb, lx, ly, tick_w, tick_w, tick_color)
                    end
                end
            end
        end

        -- Border ring(s). Read arc uses full radii; unread arc uses style-specific
        -- radii (smaller pie for solid, thinner band for hollow).
        if radial_border_color then
            local border = (colors and colors.border_thickness) or 1
            if border < 0 then border = 0 end
            if border > 0 then
                local read_b = math.min(border, radius)
                local r_outer_r2 = radius * radius
                local r_inner_r2 = (radius - read_b) * (radius - read_b)
                -- Unread border bounds: outer ring at unread_radius, with thickness
                -- min(border, band_width). For hollow, "band_width" is the unread
                -- ring band; for solid, it's just the unread radius (so border eats
                -- inward from the smaller circle's edge).
                local unread_b_outer = math.min(border, unread_radius)
                local u_outer_outer_r2 = unread_radius * unread_radius
                local u_outer_inner_r2 = (unread_radius - unread_b_outer) * (unread_radius - unread_b_outer)
                for py = -radius, radius - 1 do
                    for px = -radius, radius - 1 do
                        local dx = px + 0.5
                        local dy = py + 0.5
                        local d2 = dx * dx + dy * dy
                        local angle = math.atan2(dx, -dy)
                        if angle < 0 then angle = angle + two_pi end
                        local pixel_frac = angle / two_pi
                        local in_fill = pixel_frac <= fraction
                        if in_fill then
                            if read_b > 0 and d2 <= r_outer_r2 and d2 > r_inner_r2 then
                                bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                            end
                        else
                            if unread_b_outer > 0 and unread_radius > 0 and d2 <= u_outer_outer_r2 and d2 > u_outer_inner_r2 then
                                bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                            end
                        end
                    end
                end
                -- Inner border ring(s): for hollow only.
                if hollow then
                    local read_ib = math.min(border, inner_radius)
                    local rib_outer_r2 = inner_radius * inner_radius
                    local rib_inner_r2 = (inner_radius - read_ib) * (inner_radius - read_ib)
                    -- Unread inner band edge for hollow uses unread_inner_radius
                    -- (= mid_r - unread_band_half). Border inset goes outward from
                    -- there toward mid_r.
                    local unread_b_inner = math.min(border, unread_inner_radius)
                    local uib_outer_r2 = unread_inner_radius * unread_inner_radius
                    local uib_inner_r2 = (unread_inner_radius - unread_b_inner) * (unread_inner_radius - unread_b_inner)
                    -- Loop must cover both read inner_radius AND unread_inner_radius
                    -- (which can be larger when the unread band is centred on the
                    -- read midline and shrinks toward it). Use ceil to avoid
                    -- truncating the unread band's outermost pixels.
                    local loop_r = math.max(inner_radius, math.ceil(unread_inner_radius))
                    for py = -loop_r, loop_r - 1 do
                        for px = -loop_r, loop_r - 1 do
                            local dx = px + 0.5
                            local dy = py + 0.5
                            local d2 = dx * dx + dy * dy
                            local angle = math.atan2(dx, -dy)
                            if angle < 0 then angle = angle + two_pi end
                            local pixel_frac = angle / two_pi
                            local in_fill = pixel_frac <= fraction
                            if in_fill then
                                if read_ib > 0 and d2 <= rib_outer_r2 and d2 > rib_inner_r2 then
                                    bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                                end
                            else
                                if unread_b_inner > 0 and unread_inner_radius > 0 and d2 <= uib_outer_r2 and d2 > uib_inner_r2 then
                                    bbPaintRect(bb, cx + px, cy + py, 1, 1, radial_border_color)
                                end
                            end
                        end
                    end
                end
                -- Connector radial lines at the angular boundaries. For solid:
                -- bridge the read disk's outer edge to the unread (smaller) disk's
                -- outer edge. For hollow: bridge the band's outer edges AND the
                -- band's inner edges (read band extends from inner_radius to
                -- radius; unread band extends from unread_inner_band_r to
                -- unread_outer_band_r — both shorter than the read band).
                if read_thick ~= unread_thick and fraction > 0 and fraction < 1 then
                    local function paintRadialConnector(angle_at, r_a, r_b)
                        -- Paint border-thickness radial line from r_a to r_b at the
                        -- given angle. Caller passes any pair; ordering doesn't matter.
                        if r_a == r_b then return end
                        local cos_a = math.cos(angle_at - math.pi / 2)
                        local sin_a = math.sin(angle_at - math.pi / 2)
                        local r_lo = math.min(r_a, r_b)
                        local r_hi = math.max(r_a, r_b)
                        local half_b = math.floor(border / 2)
                        for t = r_lo, r_hi do
                            local lx = cx + math.floor(t * cos_a)
                            local ly = cy + math.floor(t * sin_a)
                            bbPaintRect(bb, lx - half_b, ly - half_b,
                                math.max(1, border), math.max(1, border),
                                radial_border_color)
                        end
                    end
                    if hollow then
                        -- Bridge outer band edges (radius vs unread_outer_band_r)
                        paintRadialConnector(0, radius, unread_outer_band_r)
                        paintRadialConnector(fraction * two_pi, radius, unread_outer_band_r)
                        -- Bridge inner band edges (inner_radius vs unread_inner_band_r)
                        paintRadialConnector(0, inner_radius, unread_inner_band_r)
                        paintRadialConnector(fraction * two_pi, inner_radius, unread_inner_band_r)
                    else
                        -- Solid: just one connector per boundary, from outer disk
                        -- (radius) down to unread disk (unread_radius).
                        paintRadialConnector(0, unread_radius, radius)
                        paintRadialConnector(fraction * two_pi, unread_radius, radius)
                    end
                end
            end
        end

    elseif style == "solid" then
        local solid_fill = resolveColor(custom_fill, Blitbuffer.COLOR_GRAY_5)
        local solid_bg = resolveColor(custom_bg, Blitbuffer.COLOR_GRAY)
        if unread_thick > 0 then
            pr(ox, unread_oy, length, unread_thick, solid_bg)
        end
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
                    -- Tick height scales to the local thickness (read or unread half).
                    local local_thick = in_fill and read_thick or unread_thick
                    local th = math.max(1, math.floor(local_thick * tick_height_pct / 100))
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
        -- Asymmetric path: paint two adjacent segments (read at read_thick,
        -- unread at unread_thick centred on the same midline). Each segment
        -- is fully bordered. Symmetric configs fall through to the legacy
        -- single-rect render below to keep that pixel output unchanged.
        if unread_thick ~= read_thick then
            local read_len = math.floor(length * fraction)
            local unread_len = length - read_len
            local read_seg_ox = reverse and (length - read_len) or 0
            local unread_seg_ox = reverse and 0 or read_len

            -- Paints one segment: outer bg + optional inner fill + border outline
            -- with one inner-facing edge optionally skipped (for stepped boundary).
            -- skip_side: "left" omits the rect's left edge in abstract coords (the
            -- progress-axis low end), "right" omits the high end. nil = paint all.
            local function paintSeg(seg_ox, seg_oy, seg_len, seg_thick, outer_color, inner_color, skip_side)
                if seg_len <= 0 or seg_thick <= 0 then return end
                local rx = vertical and seg_oy or seg_ox
                local ry = vertical and seg_ox or seg_oy
                local rw = vertical and seg_thick or seg_len
                local rh = vertical and seg_len or seg_thick
                local seg_radius = radius
                if seg_radius > math.floor(math.min(rw, rh) / 2) then
                    seg_radius = math.floor(math.min(rw, rh) / 2)
                end
                -- Outer bg fill
                if outer_color then
                    if seg_radius > 0 then
                        bbPaintRoundedRect(bb, rx, ry, rw, rh, outer_color, seg_radius)
                    else
                        bbPaintRect(bb, rx, ry, rw, rh, outer_color)
                    end
                end
                -- Inner fill, inset by border + padding
                if inner_color then
                    local padding = math.max(1, math.floor(seg_thick * 0.1))
                    local inset = border + padding
                    local inner_rx = rx + inset
                    local inner_ry = ry + inset
                    local inner_rw = rw - 2 * inset
                    local inner_rh = rh - 2 * inset
                    if inner_rw > 0 and inner_rh > 0 then
                        if seg_radius > 0 then
                            local inner_r = math.max(0, seg_radius - inset)
                            bbPaintRoundedRect(bb, inner_rx, inner_ry, inner_rw, inner_rh, inner_color, inner_r)
                        else
                            bbPaintRect(bb, inner_rx, inner_ry, inner_rw, inner_rh, inner_color)
                        end
                    end
                end
                -- Border. For rounded, bbPaintBorder traces all four sides; we
                -- can't selectively skip a single curved edge from that helper,
                -- so for rounded we still paint the full bordered outline (the
                -- connectors will overpaint the boundary area). For square
                -- (non-rounded) borders we paint as four explicit rects and
                -- omit the side specified by skip_side.
                local seg_border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)
                if seg_border_color and border > 0 then
                    if seg_radius > 0 then
                        bbPaintBorder(bb, rx, ry, rw, rh, border, seg_border_color, seg_radius)
                    else
                        local seg_b = border
                        if seg_b > math.floor(seg_thick / 2) then seg_b = math.floor(seg_thick / 2) end
                        if seg_b < 0 then seg_b = 0 end
                        if seg_b > 0 then
                            -- Map abstract skip_side to the rect's actual edge.
                            -- For horizontal bars: "left" = small-x edge, "right" = large-x edge.
                            -- For vertical bars: "left" (small progress-axis) = small-y edge,
                            --                    "right" (large progress-axis) = large-y edge.
                            local skip_low_x = (not vertical) and skip_side == "left"
                            local skip_high_x = (not vertical) and skip_side == "right"
                            -- Top edge
                            bbPaintRect(bb, rx, ry, rw, seg_b, seg_border_color)
                            -- Bottom edge
                            bbPaintRect(bb, rx, ry + rh - seg_b, rw, seg_b, seg_border_color)
                            -- Left edge (small-x)
                            if not skip_low_x then
                                bbPaintRect(bb, rx, ry, seg_b, rh, seg_border_color)
                            end
                            -- Right edge (large-x)
                            if not skip_high_x then
                                bbPaintRect(bb, rx + rw - seg_b, ry, seg_b, rh, seg_border_color)
                            end
                            -- For vertical bars the top/bottom paints above already
                            -- cover the cross-axis edges. The progress-axis-low/high
                            -- edges are handled by the small-x/large-x overpaint
                            -- the "Top" and "Bottom" lines do (since axes were
                            -- swapped via rx/ry/rw/rh). The skip_low_y/skip_high_y
                            -- decisions therefore translate as: if true, undo the
                            -- corresponding top/bottom paint by overpainting bg.
                            -- We don't undo here; vertical bars use horizontal-style
                            -- skip_side semantics in the call sites and the swap
                            -- below makes it work out: the call sites pass skip_side
                            -- referring to abstract progress-axis low/high, and for
                            -- vertical bars that maps to the screen-y top/bottom of
                            -- the segment — already handled by skipping the right
                            -- "corner" via the unread top/bottom not existing, but
                            -- ASCII border still paints. Since vertical asymmetric
                            -- bars are uncommon and this comment is already too long,
                            -- skip vertical-axis skip handling for now.
                        end
                    end
                end
            end

            -- Read segment: skip the inner-facing border edge (boundary side).
            -- Unread segment: same. Connectors below bridge the step in the outline.
            local read_skip = reverse and "left" or "right"
            local unread_skip = reverse and "right" or "left"
            paintSeg(ox + read_seg_ox, oy, read_len, read_thick, border_bg, border_fill, read_skip)
            paintSeg(ox + unread_seg_ox, unread_oy, unread_len, unread_thick, border_bg, nil, unread_skip)

            -- Rounded asymmetric: paintSeg painted both segments as fully-rounded
            -- pills. The inner-facing rounded corners create a "two separate pills"
            -- look that breaks the stepped flow. Overpaint each segment's inner
            -- side: erase the inner-facing border, fill the corner indents with bg
            -- to square them, then re-paint straight top/bottom borders extending
            -- to the boundary.
            if radius > 0 and read_thick ~= unread_thick then
                local seg_border_color = resolveColor(custom_border, Blitbuffer.COLOR_BLACK)

                -- Per-segment inner radius (clamped to half the segment thickness,
                -- matching paintSeg's clamp).
                local read_r = radius
                if read_r > math.floor(read_thick / 2) then read_r = math.floor(read_thick / 2) end
                local unread_r = radius
                if unread_r > math.floor(unread_thick / 2) then unread_r = math.floor(unread_thick / 2) end

                local function squareInnerSide(seg_ox, seg_oy, seg_len, seg_thick, seg_r, side)
                    -- side: "right" (square the right end) or "left" (square left end)
                    if seg_len <= 0 or seg_thick <= 0 then return end
                    local inner_x  -- abstract x of the inner-facing edge (boundary side)
                    if side == "right" then
                        inner_x = seg_ox + seg_len - seg_r
                    else
                        inner_x = seg_ox
                    end
                    -- Erase inner-facing border: full segment height, border-thick.
                    if border > 0 then
                        local erase_ox = (side == "right")
                            and (seg_ox + seg_len - border)
                            or seg_ox
                        pr(erase_ox, seg_oy, border, seg_thick, border_bg)
                    end
                    -- Fill the two inner-side corner indents (square them).
                    pr(inner_x, seg_oy, seg_r, seg_r, border_bg)
                    pr(inner_x, seg_oy + seg_thick - seg_r, seg_r, seg_r, border_bg)
                    -- Re-paint top and bottom borders straight across the squared
                    -- corner area so the segment outline is continuous along the
                    -- top and bottom edges.
                    if seg_border_color and border > 0 then
                        pr(inner_x, seg_oy, seg_r, border, seg_border_color)
                        pr(inner_x, seg_oy + seg_thick - border, seg_r, border, seg_border_color)
                    end
                end

                -- Only square the unread segment's inner end. Read keeps its
                -- rounded inner end so the read pill ends with a clean rounded
                -- "tip" at the boundary.
                squareInnerSide(ox + unread_seg_ox, unread_oy, unread_len, unread_thick, unread_r,
                    reverse and "right" or "left")
            end

            -- Boundary connectors: bridge between read and unread heights so the
            -- bordered outline is closed and "flows" from thick to thin. Only paint
            -- for bordered (radius == 0); rounded keeps its rounded inner end on the
            -- read pill and a vertical connector here would clash with that look.
            if border > 0 and read_thick ~= unread_thick and radius == 0 then
                local boundary_x = ox + (reverse and unread_seg_ox + unread_len or read_seg_ox + read_len)
                local b_x = boundary_x - math.floor(border / 2)
                -- Top connector: from read top (oy) down to unread top (unread_oy),
                -- inclusive of corner overlap on the unread side.
                local top_y = oy
                local top_h = unread_oy - oy + border
                if top_h > 0 then
                    pr(b_x, top_y, border, top_h, resolveColor(custom_border, Blitbuffer.COLOR_BLACK))
                end
                -- Bottom connector: from unread bottom up to read bottom.
                local bot_y = unread_oy + unread_thick - border
                local bot_h = (oy + read_thick) - bot_y
                if bot_h > 0 then
                    pr(b_x, bot_y, border, bot_h, resolveColor(custom_border, Blitbuffer.COLOR_BLACK))
                end
            end

            -- Ticks (read-thickness, centred on read midline). Mirrors the
            -- symmetric tick logic below, simplified — the asymmetric segments
            -- already carry their own borders, so no inner-rect inset is needed.
            local tick_ox = ox
            local tick_len = length
            local tick_thick = read_thick
            local fill_len_for_ticks = read_len
            local fill_start_for_ticks = read_seg_ox
            for _, tick in ipairs(ticks or {}) do
                local tick_frac = type(tick) == "table" and tick[1] or tick
                local tick_w = type(tick) == "table" and tick[2] or 1
                if reverse then tick_frac = 1 - tick_frac end
                local tick_pos = math.floor(tick_len * tick_frac)
                if tick_pos > 0 and tick_pos < tick_len then
                    local base_tick = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
                    if base_tick then
                        local in_fill = tick_pos >= fill_start_for_ticks
                            and tick_pos < fill_start_for_ticks + fill_len_for_ticks
                        local tick_color
                        if invert_read_ticks ~= false and in_fill then
                            tick_color = resolveColor(custom_invert, border_bg)
                        else
                            tick_color = base_tick
                        end
                        -- Tick height scales to local thickness (read or unread).
                        local local_thick = in_fill and read_thick or unread_thick
                        local th = math.max(1, math.floor(local_thick * tick_height_pct / 100))
                        local t_oy = oy + math.floor((tick_thick - th) / 2)
                        pr(tick_ox + tick_pos, t_oy, tick_w, th, tick_color)
                    end
                end
            end
            return
        end
        -- Background (use real coordinates for rounded rect API)
        if radius > 0 then
            if border_bg then
                bbPaintRoundedRect(bb, x, y, w, h, border_bg, radius)
            end
        else
            if border_bg then
                bbPaintRect(bb, x, y, w, h, border_bg)
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
                    bbPaintRoundedRect(bb, inner_x, inner_y, inner_w, inner_h, border_bg, inner_r)
                end
                -- Fill (read portion) on top — its rounded corners overlay the background
                if fill_len > 0 and border_fill then
                    if vertical then
                        if reverse then
                            bbPaintRoundedRect(bb, inner_x, inner_y + inner_h - fill_len, inner_w, fill_len, border_fill, inner_r)
                        else
                            bbPaintRoundedRect(bb, inner_x, inner_y, inner_w, fill_len, border_fill, inner_r)
                        end
                    else
                        if reverse then
                            bbPaintRoundedRect(bb, inner_x + inner_w - fill_len, inner_y, fill_len, inner_h, border_fill, inner_r)
                        else
                            bbPaintRoundedRect(bb, inner_x, inner_y, fill_len, inner_h, border_fill, inner_r)
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
                bbPaintBorder(bb, x, y, w, h, border, border_color, radius)
            end
        else
            if border_color then
                bbPaintRect(bb, x, y, w, border, border_color)
                bbPaintRect(bb, x, y + h - border, w, border, border_color)
                bbPaintRect(bb, x, y, border, h, border_color)
                bbPaintRect(bb, x + w - border, y, border, h, border_color)
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
                        local in_fill = tick_pos >= fill_start and tick_pos < fill_start + fill_len
                        if invert_read_ticks ~= false and in_fill then
                            -- Use `invert` if set, otherwise fall back to `bg`
                            -- (the legacy bordered behaviour — preserves pre-v4.3 presets).
                            tick_color = resolveColor(custom_invert, border_bg)
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

    -- Session / book-open markers (#77): style-agnostic triangle overlays drawn
    -- on top of the bar with NO layout reservation (approach 3). The top marker
    -- points down at the bar from above; the bottom marker points up from below.
    -- Each carries its own fraction, size (% of a fixed screen-scaled base), pixel offset from
    -- the bar edge, and colour. Drawn in abstract coords via pr(), so vertical
    -- bars and reverse fill are handled for free. Rows outside the buffer are
    -- skipped; bbPaintRect clips the horizontal span of the rest.
    if markers and (markers.top or markers.bottom) then
        local cross_limit = vertical and bb:getWidth() or bb:getHeight()
        local default_marker = resolveColor(custom_tick, Blitbuffer.COLOR_BLACK)
        -- Marker size is relative to a FIXED screen-scaled base, NOT the bar
        -- thickness — otherwise a thin bar (e.g. 4px) yields invisible markers.
        -- 100% ≈ a clearly visible caret on any bar; Size% scales from there.
        local marker_base = Screen:scaleBySize(20)
        local RenderText = require("ui/rendertext")
        local function drawMarker(m, is_top)
            if not m then return end
            local fracs = m.fracs or (m.frac and { m.frac })
            if not fracs or #fracs == 0 then return end
            local color = m.color or default_marker
            if not color then return end
            local mh = math.max(2, math.floor(marker_base * (m.size or 50) / 100))
            local offset = m.offset or 0
            local style = m.style or "chevron"
            for _, raw_frac in ipairs(fracs) do
                local frac = math.max(0, math.min(1, raw_frac))
                if reverse then frac = 1 - frac end
                local pos = math.floor(length * frac)
                if style ~= "solid" then
                    local cp
                    if vertical then cp = is_top and 0xE841 or 0xE840
                    else cp = is_top and 0xE83F or 0xE842 end
                    local g = RenderText:getGlyph(Font:getFace("symbols", math.max(8, mh)), cp)
                    if g and g.bb then
                        local gw, gh = g.bb:getWidth(), g.bb:getHeight()
                        local ink_x, ink_y
                        if vertical then
                            ink_y = ox + pos - math.floor(gh / 2)
                            ink_x = is_top and (oy - offset - gw) or (oy + thickness + offset)
                        else
                            ink_x = ox + pos - math.floor(gw / 2)
                            ink_y = is_top and (oy - offset - gh) or (oy + thickness + offset)
                        end
                        if ffi.istype(ColorRGB32_t, color) and bb.colorblitFromRGB32 then
                            bb:colorblitFromRGB32(g.bb, ink_x, ink_y, 0, 0, gw, gh, color)
                        else
                            bb:colorblitFrom(g.bb, ink_x, ink_y, 0, 0, gw, gh, color)
                        end
                    end
                else
                    local denom = (mh > 1) and (mh - 1) or 1
                    for r = 0, mh - 1 do
                        local taper = is_top and ((mh - 1 - r) / denom) or (r / denom)
                        local half = math.floor(mh / 2 * taper)
                        local cross_y = is_top
                            and (oy - offset - mh + r)
                            or  (oy + thickness + offset + r)
                        if cross_y >= 0 and cross_y < cross_limit then
                            pr(ox + pos - half, cross_y, half * 2 + 1, 1, color)
                        end
                    end
                end
            end
        end
        drawMarker(markers.top, true)
        drawMarker(markers.bottom, false)
    end
end

--- Compute per-end fill extents for the Background colour feature.
--- @param positions_data table: keyed by tl/tc/tr/bl/bc/br. Each entry has:
---   { disabled = bool, height_px = H, v_offset = V, v_margin = M,
---     first_line_h = F, last_line_h = L }
---   where height_px is the configured pixel height of the position's rendered
---   block (composite line stack). first_line_h / last_line_h are the per-line
---   heights of the top / bottom lines in the stack, used to derive the
---   EPUB-facing breathing-room padding. Both default to 0 when missing.
--- @param screen_h number: pixel screen height
--- @return table { top_y, bottom_y, top_any_enabled, bottom_any_enabled }
---   top_any_enabled / bottom_any_enabled are true only when the position is
---   not disabled AND its configured height_px > 0. top_y / bottom_y are
---   extended by 0.5 × line-height of the propping position's inner-edge line
---   (last line for top, first line for bottom) so the text doesn't sit
---   flush against the EPUB content area.
function OverlayWidget.computeEndFillExtents(positions_data, screen_h)
    local function inner_edge_top(p)
        return p.v_offset + p.v_margin + p.height_px
    end
    local function inner_edge_bottom(p)
        return screen_h - p.v_offset - p.v_margin - p.height_px
    end

    local top_keys = { "tl", "tc", "tr" }
    local bottom_keys = { "bl", "bc", "br" }

    local top_y, bottom_y = 0, screen_h
    -- Inner-edge line height of whichever position is propping the bar open.
    -- On a tie at the same edge, take the larger basis so padding is sized
    -- for the more visually substantial line.
    local top_pad_basis, bottom_pad_basis = 0, 0
    local top_any_enabled, bottom_any_enabled = false, false

    for _, k in ipairs(top_keys) do
        local p = positions_data[k]
        if p then
            local edge = inner_edge_top(p)
            local llh = p.last_line_h or 0
            if edge > top_y then
                top_y = edge
                top_pad_basis = llh
            elseif edge == top_y and llh > top_pad_basis then
                top_pad_basis = llh
            end
            if not p.disabled and p.height_px > 0 then top_any_enabled = true end
        end
    end
    for _, k in ipairs(bottom_keys) do
        local p = positions_data[k]
        if p then
            local edge = inner_edge_bottom(p)
            local flh = p.first_line_h or 0
            if edge < bottom_y then
                bottom_y = edge
                bottom_pad_basis = flh
            elseif edge == bottom_y and flh > bottom_pad_basis then
                bottom_pad_basis = flh
            end
            if not p.disabled and p.height_px > 0 then bottom_any_enabled = true end
        end
    end

    local top_pad = math.floor(top_pad_basis * 0.5 + 0.5)
    local bottom_pad = math.floor(bottom_pad_basis * 0.5 + 0.5)

    return {
        top_y = top_y + top_pad,
        bottom_y = bottom_y - bottom_pad,
        top_any_enabled = top_any_enabled,
        bottom_any_enabled = bottom_any_enabled,
    }
end

return OverlayWidget
