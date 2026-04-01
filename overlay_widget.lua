local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local Screen = Device.screen
local Tokens = require("tokens")

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

-- ─── BarWidget ─────────────────────────────────────────────────────────────
-- Rounded-bordered progress bar with a dark-gray fill and optional tick marks.

local BarWidget = {}
BarWidget.__index = BarWidget

function BarWidget:new(o)
    return setmetatable(o or {}, self)
end

function BarWidget:paintTo(bb, x, y)
    local w          = self.width
    local h          = self.height
    local fraction   = math.max(0, math.min(1, self.fraction or 0))
    local ticks      = self.ticks or {}
    local Blitbuffer = require("ffi/blitbuffer")

    local border  = 2
    local radius  = 2
    local padding = 4

    bb:paintRoundedRect(x, y, w, h, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(x, y, w, h, border, Blitbuffer.COLOR_BLACK, radius)

    local inset   = border + padding
    local inner_w = w - 2 * inset
    local inner_h = h - 2 * inset
    local fill_w  = math.max(0, math.ceil(inner_w * fraction))
    if fill_w > 0 and inner_h > 0 then
        bb:paintRect(x + inset, y + inset, fill_w, inner_h, Blitbuffer.COLOR_DARK_GRAY)
    end

    local tick_inset   = 1
    local tick_inner_w = w - 2 * tick_inset
    local tix          = x + tick_inset
    local tiy          = y + tick_inset
    for _, frac in ipairs(ticks) do
        if frac > 0 and frac < 1 then
            local tx = tix + math.floor(tick_inner_w * frac)
            tx = math.max(tix, math.min(tx, tix + tick_inner_w - 1))
            bb:paintRect(tx, tiy, 1, h - 2 * tick_inset, Blitbuffer.COLOR_BLACK)
        end
    end
end

function BarWidget:getSize()
    return { w = self.width, h = self.height }
end

function BarWidget:free() end

-- ─── HorizontalRowWidget ───────────────────────────────────────────────────
-- Paints text and bar segments left-to-right, vertically centred in the row.

local HorizontalRowWidget = {}
HorizontalRowWidget.__index = HorizontalRowWidget

function HorizontalRowWidget:new(o)
    return setmetatable(o or {}, self)
end

function HorizontalRowWidget:paintTo(bb, x, y)
    local row_h    = self.height
    local x_cursor = x
    for _, seg in ipairs(self.segments) do
        local seg_y = y + math.floor((row_h - seg.h) / 2)
        seg.widget:paintTo(bb, x_cursor, seg_y)
        x_cursor = x_cursor + seg.w
    end
end

function HorizontalRowWidget:getSize()
    return { w = self.width, h = self.height }
end

function HorizontalRowWidget:free()
    for _, seg in ipairs(self.segments) do
        if seg.widget and seg.widget.free then seg.widget:free() end
    end
    self.segments = {}
end

-- ─── Internal helpers ─────────────────────────────────────────────────────

local function buildBarWidget(info, bar_w, bar_h)
    bar_h = math.max(bar_h or 16, 16)
    bar_w = math.max(4, bar_w or Screen:getWidth())
    return BarWidget:new{
        width    = bar_w,
        height   = bar_h,
        fraction = info.pct or 0,
        ticks    = info.ticks or {},
    }
end

-- Build a HorizontalRowWidget from text/bar segments.
-- full_w: uncapped slot width used for auto bar sizing.
-- max_width: text truncation limit (nil = none).
local function buildHorizontalRow(segments, cfg, full_w, max_width)
    local bar_h     = cfg.bar_height or math.max(cfg.face and cfg.face.size or 16, 16)
    local fixed_bar_w = (cfg.bar_manual_width and cfg.bar_manual_width > 0) and cfg.bar_manual_width or nil
    local built    = {}
    local used_w   = 0
    local auto_bars = 0

    for _, seg in ipairs(segments) do
        if seg.kind == "text" and seg.text ~= "" then
            local tw = TextWidget:new(textWidgetOpts{
                text                   = seg.text,
                face                   = cfg.face,
                bold                   = cfg.bold,
                max_width              = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            })
            local sz = tw:getSize()
            table.insert(built, { widget = tw, w = sz.w, h = sz.h })
            used_w = used_w + sz.w
        elseif seg.kind == "bar" then
            if fixed_bar_w then
                local bar = buildBarWidget(seg.info, fixed_bar_w, bar_h)
                table.insert(built, { widget = bar, w = fixed_bar_w, h = bar_h })
                used_w = used_w + fixed_bar_w
            else
                table.insert(built, { _bar_auto = true, info = seg.info, w = 0, h = bar_h })
                auto_bars = auto_bars + 1
            end
        end
    end

    if auto_bars > 0 then
        local each = math.max(4, math.floor(
            math.max(0, (full_w or Screen:getWidth()) - used_w) / auto_bars))
        for _, entry in ipairs(built) do
            if entry._bar_auto then
                entry.widget    = buildBarWidget(entry.info, each, bar_h)
                entry.w         = each
                entry._bar_auto = nil
            end
        end
    end

    local total_w = 0
    local row_h   = 0
    for _, entry in ipairs(built) do
        total_w = total_w + entry.w
        if entry.h > row_h then row_h = entry.h end
    end

    if #built == 0 then return nil, 0, 0 end
    return HorizontalRowWidget:new{ segments = built, width = total_w, height = row_h },
           total_w, row_h
end

--- Build a widget for a possibly multi-line, possibly bar-containing string.
-- @param text          expanded string (may contain bar sentinels)
-- @param line_configs  per-line configs with face, bold, v_nudge, h_nudge, uppercase
-- @param h_anchor      "left"|"center"|"right"
-- @param max_width     number|nil  text truncation cap
-- @param _available_w  (unused, accepted for API compatibility)
-- @param full_w        number|nil  uncapped slot width for auto bar sizing
-- @return widget, width, height
function OverlayWidget.buildTextWidget(text, line_configs, h_anchor, max_width, _available_w, full_w)
    full_w = full_w or Screen:getWidth()
    if max_width and max_width <= 0 then return nil, 0, 0 end

    local lines = {}
    for line in text:gmatch("([^\n]+)") do
        table.insert(lines, line)
    end
    if #lines == 0 then return nil, 0, 0 end

    local function getConfig(i)
        return line_configs[i] or line_configs[#line_configs]
               or { face = nil, bold = false }
    end

    local align = "center"
    if h_anchor == "left"  then align = "left"  end
    if h_anchor == "right" then align = "right" end

    -- Fast path: single plain text line
    if #lines == 1 and not Tokens.lineHasBar(lines[1]) then
        local cfg         = getConfig(1)
        local display_text = cfg.uppercase and lines[1]:upper() or lines[1]
        local tw = TextWidget:new(textWidgetOpts{
            text                   = display_text,
            face                   = cfg.face,
            bold                   = cfg.bold,
            max_width              = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        })
        local size = tw:getSize()
        return tw, size.w, size.h
    end

    -- Fast path: single bar-containing line
    if #lines == 1 then
        local cfg = getConfig(1)
        local row, rw, rh = buildHorizontalRow(
            Tokens.splitLineSegments(lines[1]), cfg, full_w, max_width)
        return row, rw, rh
    end

    -- Multi-line
    local line_entries = {}
    local max_w        = 0
    local total_h      = 0
    for i, line in ipairs(lines) do
        local cfg = getConfig(i)
        if Tokens.lineHasBar(line) then
            local row, rw, rh = buildHorizontalRow(
                Tokens.splitLineSegments(line), cfg, full_w, max_width)
            if row then
                table.insert(line_entries, {
                    widget  = row, w = rw, h = rh,
                    v_nudge = cfg.v_nudge or 0, h_nudge = cfg.h_nudge or 0,
                })
                if rw > max_w then max_w = rw end
                total_h = total_h + rh
            end
        else
            local display_text = cfg.uppercase and line:upper() or line
            local tw = TextWidget:new(textWidgetOpts{
                text                   = display_text,
                face                   = cfg.face,
                bold                   = cfg.bold,
                max_width              = max_width,
                truncate_with_ellipsis = max_width ~= nil,
            })
            local sz = tw:getSize()
            table.insert(line_entries, {
                widget  = tw, w = sz.w, h = sz.h,
                v_nudge = cfg.v_nudge or 0, h_nudge = cfg.h_nudge or 0,
            })
            if sz.w > max_w then max_w = sz.w end
            total_h = total_h + sz.h
        end
    end

    if #line_entries == 0 then return nil, 0, 0 end
    local reported_w = math.max(max_w, 4)
    return MultiLineWidget:new{
        lines = line_entries, width = reported_w, height = total_h, align = align,
    }, reported_w, total_h
end

--- Measure only the text-portion pixel width (bar lines excluded).
-- Used for overlap-prevention so bars don't inflate the available limits.
function OverlayWidget.measureTextWidth(text, line_configs)
    local max_w = 0
    local i     = 0
    for line in text:gmatch("([^\n]+)") do
        i = i + 1
        if not Tokens.lineHasBar(line) then
            local cfg = line_configs[i] or line_configs[#line_configs]
                        or { face = nil, bold = false }
            local tw = TextWidget:new(textWidgetOpts{
                text = line, face = cfg.face, bold = cfg.bold,
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

return OverlayWidget
