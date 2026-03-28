local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local Device = require("device")
local Screen = Device.screen

local OverlayWidget = {}

--- Build a TextWidget or VerticalGroup for a single line or multi-line string.
-- @param text string: the expanded text (may contain newlines)
-- @param face font face object
-- @param bold boolean
-- @param h_anchor string: "left", "center", or "right" — controls VerticalGroup alignment
-- @param max_width number or nil: if set, truncate lines to this pixel width
-- @return widget, width, height
function OverlayWidget.buildTextWidget(text, face, bold, h_anchor, max_width)
    -- Split on newlines
    local lines = {}
    for line in text:gmatch("([^\n]*)\n?") do
        if line ~= "" or #lines > 0 then
            table.insert(lines, line)
        end
    end
    -- Remove trailing empty entry from gmatch
    if #lines > 1 and lines[#lines] == "" then
        table.remove(lines)
    end
    if #lines == 0 then
        return nil, 0, 0
    end

    local align = "center"
    if h_anchor == "left" then
        align = "left"
    elseif h_anchor == "right" then
        align = "right"
    end

    if #lines == 1 then
        local tw = TextWidget:new{
            text = lines[1],
            face = face,
            bold = bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        }
        local size = tw:getSize()
        return tw, size.w, size.h
    end

    -- Multi-line: VerticalGroup of TextWidgets
    local group = VerticalGroup:new{ align = align }
    local max_w = 0
    local total_h = 0
    for _, line in ipairs(lines) do
        local tw = TextWidget:new{
            text = line,
            face = face,
            bold = bold,
            max_width = max_width,
            truncate_with_ellipsis = max_width ~= nil,
        }
        table.insert(group, tw)
        local size = tw:getSize()
        if size.w > max_w then max_w = size.w end
        total_h = total_h + size.h
    end
    return group, max_w, total_h
end

--- Measure the width of the widest line in a text string, without building a persistent widget.
-- Used for overlap calculation before truncation is applied.
-- @param text string
-- @param face font face
-- @param bold boolean
-- @return number: pixel width of widest line
function OverlayWidget.measureTextWidth(text, face, bold)
    local max_w = 0
    for line in text:gmatch("([^\n]*)") do
        if line ~= "" then
            local tw = TextWidget:new{
                text = line,
                face = face,
                bold = bold,
            }
            local w = tw:getSize().w
            tw:free()
            if w > max_w then max_w = w end
        end
    end
    return max_w
end

--- Calculate max_width for each position in a row, applying overlap prevention.
-- Center gets priority. Returns a table { left=max_w|nil, center=max_w|nil, right=max_w|nil }.
-- nil means no truncation needed.
function OverlayWidget.calculateRowLimits(left_w, center_w, right_w, screen_w, gap, h_offset)
    local limits = { left = nil, center = nil, right = nil }

    -- Center gets priority: only truncate if it exceeds full screen width minus margins
    if center_w then
        local center_max = screen_w - 2 * gap
        if center_w > center_max then
            limits.center = center_max
            center_w = center_max
        end
    end

    if center_w then
        -- Side positions share the space not used by center
        local available_side = math.floor((screen_w - center_w) / 2) - gap
        if left_w and left_w > available_side - h_offset then
            limits.left = math.max(0, available_side - h_offset)
        end
        if right_w and right_w > available_side - h_offset then
            limits.right = math.max(0, available_side - h_offset)
        end
    else
        -- No center: left and right split the screen
        if left_w and right_w then
            local half = math.floor(screen_w / 2) - math.floor(gap / 2)
            if left_w > half - h_offset then
                limits.left = math.max(0, half - h_offset)
            end
            if right_w > half - h_offset then
                limits.right = math.max(0, half - h_offset)
            end
        end
        -- If only one side active, it gets full width minus its offset
        if left_w and not right_w then
            local max = screen_w - h_offset
            if left_w > max then
                limits.left = max
            end
        end
        if right_w and not left_w then
            local max = screen_w - h_offset
            if right_w > max then
                limits.right = max
            end
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
    else -- "right"
        x = screen_w - text_w - h_offset
    end

    if v_anchor == "top" then
        y = v_offset
    else -- "bottom"
        y = screen_h - text_h - v_offset
    end

    return x, y
end

--- Free all widgets in a cache table.
function OverlayWidget.freeWidgets(widget_cache)
    for key, entry in pairs(widget_cache) do
        if entry.widget and entry.widget.free then
            entry.widget:free()
        end
        widget_cache[key] = nil
    end
end

return OverlayWidget
