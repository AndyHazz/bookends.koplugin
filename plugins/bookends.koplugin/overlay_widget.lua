local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Device = require("device")
local Screen = Device.screen

local OverlayWidget = {}

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
        local lx = x
        if self.align == "center" then
            lx = x + math.floor((self.width - entry.w) / 2)
        elseif self.align == "right" then
            lx = x + self.width - entry.w
        end
        entry.widget:paintTo(bb, lx, y + y_offset)
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

--- Build a TextWidget or MultiLineWidget for a single line or multi-line string.
-- @param text string: the expanded text (may contain newlines)
-- @param line_configs table: array of {face=, bold=} per line
-- @param h_anchor string: "left", "center", or "right"
-- @param max_width number or nil: if set, truncate lines to this pixel width
-- @return widget, width, height
function OverlayWidget.buildTextWidget(text, line_configs, h_anchor, max_width)
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
        local tw = TextWidget:new{
            text = lines[1],
            face = cfg.face,
            bold = cfg.bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        }
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
        local tw = TextWidget:new{
            text = line,
            face = cfg.face,
            bold = cfg.bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        }
        local size = tw:getSize()
        table.insert(line_entries, { widget = tw, w = size.w, h = size.h })
        if size.w > max_w then max_w = size.w end
        total_h = total_h + size.h
    end

    local mlw = MultiLineWidget:new{
        lines = line_entries,
        width = max_w,
        height = total_h,
        align = align,
    }
    return mlw, max_w, total_h
end

--- Measure the width of the widest line in a text string.
-- @param line_configs table: array of {face=, bold=} per line
function OverlayWidget.measureTextWidth(text, line_configs)
    local max_w = 0
    local i = 0
    for line in text:gmatch("([^\n]+)") do
        i = i + 1
        local cfg = line_configs[i] or line_configs[#line_configs] or { face = nil, bold = false }
        local tw = TextWidget:new{
            text = line,
            face = cfg.face,
            bold = cfg.bold,
        }
        local w = tw:getSize().w
        tw:free()
        if w > max_w then max_w = w end
    end
    return max_w
end

--- Calculate max_width for each position in a row, applying overlap prevention.
-- Center gets priority. Returns { left=max_w|nil, center=max_w|nil, right=max_w|nil }.
function OverlayWidget.calculateRowLimits(left_w, center_w, right_w, screen_w, gap, h_offset)
    local limits = { left = nil, center = nil, right = nil }

    if center_w then
        local center_max = screen_w - 2 * gap
        if center_w > center_max then
            limits.center = center_max
            center_w = center_max
        end
    end

    if center_w then
        local available_side = math.floor((screen_w - center_w) / 2) - gap
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
            local max = screen_w - h_offset
            if left_w > max then limits.left = max end
        end
        if right_w and not left_w then
            local max = screen_w - h_offset
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
