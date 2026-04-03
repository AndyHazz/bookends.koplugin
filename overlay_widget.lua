local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen

local OverlayWidget = {}

-- Default TextWidget options for overlay text.
-- use_book_text_color ensures text matches the book's color scheme
-- (compatible with color theme patches like koreader-color-themes).
local function textWidgetOpts(t)
    t.use_book_text_color = true
    return t
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

--- Build a HorizontalRowWidget for a line that contains a bar token.
-- Text is split on the BAR_PLACEHOLDER to preserve before/after segments.
-- @param text string: text with BAR_PLACEHOLDER where the bar goes
-- @param cfg table: line config with .bar = {kind, pct, ticks}, .face, .bold, etc.
-- @param available_w number: total available width for this line
-- @param max_width number or nil: truncation limit
-- @return widget, width, height
local function buildBarLine(text, cfg, available_w, max_width)
    local bar_info = cfg.bar
    -- Default bar height matches the line's font size
    local bar_h = cfg.bar_height or (cfg.face and cfg.face.size) or 5
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
        local display = cfg.uppercase and t:upper() or t
        local tw = TextWidget:new(textWidgetOpts{
            text = display,
            face = cfg.face,
            bold = cfg.bold,
        })
        local size = tw:getSize()
        table.insert(segments, { widget = tw, w = size.w, h = size.h })
        total_w = total_w + size.w
        text_total_w = text_total_w + size.w
        if size.h > max_h then max_h = size.h end
    end

    -- Before text
    addTextSegment(before)

    -- Bar (placeholder slot)
    local bar_manual_w = cfg.bar_width or 0
    local bar_slot = #segments + 1  -- remember where to insert bar

    -- After text
    addTextSegment(after)

    -- Ensure row height matches font line height for consistent vertical alignment
    if text_total_w == 0 and cfg.face then
        local ref_tw = TextWidget:new(textWidgetOpts{ text = " ", face = cfg.face, bold = cfg.bold })
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

    -- Get config for line i (fall back to last config if fewer configs than lines)
    local function getConfig(i)
        return line_configs[i] or line_configs[#line_configs] or { face = nil, bold = false }
    end

    if #lines == 1 then
        local cfg = getConfig(1)
        if cfg.bar then
            return buildBarLine(lines[1], cfg, available_w or Screen:getWidth(), max_width)
        end
        local display_text = cfg.uppercase and lines[1]:upper() or lines[1]
        local tw = TextWidget:new(textWidgetOpts{
            text = display_text,
            face = cfg.face,
            bold = cfg.bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        })
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
        if cfg.bar then
            widget, w, h = buildBarLine(line, cfg, available_w or Screen:getWidth(), max_width)
        else
            local display_text = cfg.uppercase and line:upper() or line
            widget = TextWidget:new(textWidgetOpts{
                text = display_text,
                face = cfg.face,
                bold = cfg.bold,
                max_width = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            })
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
        local cfg = line_configs[i] or line_configs[#line_configs] or { face = nil, bold = false }
        -- For bar lines, measure only the text portions (strip placeholder)
        local measure_text = line
        if cfg.bar then
            measure_text = line:gsub(BAR_PLACEHOLDER, "")
        end
        if measure_text ~= "" then
            local display_text = cfg.uppercase and measure_text:upper() or measure_text
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
    -- Custom colors
    local custom_fill = colors and colors.fill
    local custom_bg = colors and colors.bg
    local custom_track = colors and colors.track
    local custom_tick = colors and colors.tick
    local invert_read_ticks = colors and colors.invert_read_ticks

    -- Helper: paint a rect, swapping axes for vertical
    local function pr(rx, ry, rw, rh, color)
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

        -- Inset the line so start/end circles don't clip
        local inset = start_r
        local line_ox = ox + inset
        local line_len = length - 2 * inset  -- room for start + end circles
        if line_len < 1 then line_len = length; line_ox = ox; inset = 0 end

        local line_fill = math.floor(line_len * fraction)
        local line_fill_start = reverse and (line_len - line_fill) or 0

        local metro_fill = custom_fill or Blitbuffer.COLOR_DARK_GRAY
        local metro_bg = custom_bg or Blitbuffer.COLOR_GRAY
        local metro_track = custom_track or metro_fill
        local metro_tick = metro_track  -- ticks are part of the track
        -- Background line (lighter)
        pr(line_ox, line_y, line_len, line_thick, metro_bg)
        -- Filled line (darker)
        if line_fill > 0 then
            pr(line_ox + line_fill_start, line_y, line_fill, line_thick, metro_fill)
        end

        -- Chapter ticks: depth 1 above line (connected to trunk), depth 2 below
        for _, tick in ipairs(ticks or {}) do
            local tick_frac = type(tick) == "table" and tick[1] or tick
            local tick_w = type(tick) == "table" and tick[2] or 1
            local tick_depth = type(tick) == "table" and tick[3] or 1
            if reverse then tick_frac = 1 - tick_frac end
            local tick_pos = math.floor(line_len * tick_frac)
            if tick_pos > 0 and tick_pos < line_len then
                if tick_depth <= 1 then
                    -- From top of bar down through trunk
                    pr(line_ox + tick_pos, oy, line_thick, line_y + line_thick - oy, metro_tick)
                else
                    -- Below trunk (same thickness as trunk)
                    local below_y = line_y + line_thick
                    local below_h = oy + thickness - below_y
                    if below_h > 0 then
                        pr(line_ox + tick_pos, below_y, line_thick, below_h, metro_tick)
                    end
                end
            end
        end

        -- Helper for circles
        local function paintCircle(cx, cy, r, color)
            if vertical then
                bb:paintRoundedRect(cy, cx, r * 2, r * 2, color, r)
            else
                bb:paintRoundedRect(cx, cy, r * 2, r * 2, color, r)
            end
        end

        -- Start circle (empty ring, trunk colour)
        local start_cx = reverse and (line_ox + line_len - start_r) or (line_ox - start_r)
        paintCircle(start_cx, oy, start_r, metro_track)
        local ring_border = line_thick
        local inner_r = start_r - ring_border
        if inner_r > 0 then
            paintCircle(start_cx + ring_border, oy + ring_border, inner_r, Blitbuffer.COLOR_WHITE)
        end

        -- End circle (filled, trunk colour, same size as start)
        local end_cx = reverse and (line_ox - start_r) or (line_ox + line_len - start_r)
        paintCircle(end_cx, oy, start_r, metro_track)

        -- Current position dot (uses tick colour, default black)
        local pos_on_line = reverse and (line_len - line_fill) or line_fill
        local dot_cx = line_ox + pos_on_line - dot_r
        local dot_cy = oy + math.floor((thickness - dot_r * 2) / 2)
        paintCircle(dot_cx, dot_cy, dot_r, custom_tick or Blitbuffer.COLOR_BLACK)

    elseif style == "solid" then
        local solid_fill = custom_fill or Blitbuffer.COLOR_GRAY_5
        local solid_bg = custom_bg or Blitbuffer.COLOR_GRAY
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
                local tick_color
                if custom_tick then
                    tick_color = custom_tick
                elseif invert_read_ticks == false then
                    tick_color = Blitbuffer.COLOR_BLACK
                else
                    tick_color = in_fill and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                end
                pr(ox + tick_pos, oy, tick_w, thickness, tick_color)
            end
        end
    else
        local border_fill = custom_fill or Blitbuffer.COLOR_DARK_GRAY
        local border_bg = custom_bg or Blitbuffer.COLOR_WHITE
        local border = 1
        local margin_h = math.max(3, math.floor(thickness * 0.2))
        local margin_v = math.max(1, math.floor(thickness * 0.1))
        local min_dim = vertical and w or h
        local radius = style == "rounded" and math.floor(min_dim / 2) or 0
        -- Background + border (use real coordinates for rounded rect API)
        if radius > 0 then
            bb:paintRoundedRect(x, y, w, h, border_fill, radius)
        else
            bb:paintRect(x, y, w, h, border_bg)
        end
        local h_inset = radius > 0 and radius or (border + margin_h)
        local v_inset = border + margin_v
        local inner_ox = ox + h_inset
        local inner_oy = oy + v_inset
        local inner_len = length - 2 * h_inset
        local inner_thick = thickness - 2 * v_inset
        if inner_len > 0 and inner_thick > 0 then
            local fill_len = math.floor(inner_len * fraction)
            if radius > 0 then
                -- Rounded: fill already painted as background, erase unfilled
                local unfilled = inner_len - fill_len
                if unfilled > 0 then
                    if reverse then
                        pr(inner_ox, inner_oy, unfilled, inner_thick, border_bg)
                    else
                        pr(inner_ox + fill_len, inner_oy, unfilled, inner_thick, border_bg)
                    end
                end
            else
                -- Bordered: paint fill on white background
                if fill_len > 0 then
                    if reverse then
                        pr(inner_ox + inner_len - fill_len, inner_oy, fill_len, inner_thick, border_fill)
                    else
                        pr(inner_ox, inner_oy, fill_len, inner_thick, border_fill)
                    end
                end
            end
        end
        -- Border on top
        if radius > 0 then
            bb:paintBorder(x, y, w, h, border, Blitbuffer.COLOR_BLACK, radius)
        else
            bb:paintRect(x, y, w, border, Blitbuffer.COLOR_BLACK)
            bb:paintRect(x, y + h - border, w, border, Blitbuffer.COLOR_BLACK)
            bb:paintRect(x, y, border, h, Blitbuffer.COLOR_BLACK)
            bb:paintRect(x + w - border, y, border, h, Blitbuffer.COLOR_BLACK)
        end
        -- Chapter ticks
        if inner_len > 0 and inner_thick > 0 then
            for _, tick in ipairs(ticks or {}) do
                local tick_frac = type(tick) == "table" and tick[1] or tick
                local tick_w = type(tick) == "table" and tick[2] or 1
                if reverse then tick_frac = 1 - tick_frac end
                local tick_pos = math.floor(inner_len * tick_frac)
                if tick_pos > 0 and tick_pos < inner_len then
                    pr(inner_ox + tick_pos, inner_oy, tick_w, inner_thick, custom_tick or Blitbuffer.COLOR_BLACK)
                end
            end
        end
    end
end

return OverlayWidget
