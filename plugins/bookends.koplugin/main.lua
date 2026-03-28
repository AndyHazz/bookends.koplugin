local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen
local Tokens = require("tokens")
local OverlayWidget = require("overlay_widget")

local Bookends = WidgetContainer:extend{
    name = "bookends",
    is_doc_only = true,
}

-- Position keys and their properties
Bookends.POSITIONS = {
    { key = "tl", label = _("Top-left"),      row = "top",    h_anchor = "left",   v_anchor = "top" },
    { key = "tc", label = _("Top-center"),     row = "top",    h_anchor = "center", v_anchor = "top" },
    { key = "tr", label = _("Top-right"),      row = "top",    h_anchor = "right",  v_anchor = "top" },
    { key = "bl", label = _("Bottom-left"),    row = "bottom", h_anchor = "left",   v_anchor = "bottom" },
    { key = "bc", label = _("Bottom-center"),  row = "bottom", h_anchor = "center", v_anchor = "bottom" },
    { key = "br", label = _("Bottom-right"),   row = "bottom", h_anchor = "right",  v_anchor = "bottom" },
}

function Bookends:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self.ui.view:registerViewModule("bookends", self)
    self.session_start_time = os.time()
    self.dirty = true
    self.position_cache = {} -- cached expanded text per position key
end

function Bookends:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = G_reader_settings:readSetting("bookends_enabled", false)

    -- Global defaults
    self.defaults = {
        font_face = G_reader_settings:readSetting("bookends_font_face", Font.fontmap["ffont"]),
        font_size = G_reader_settings:readSetting("bookends_font_size", footer_settings.text_font_size),
        font_bold = G_reader_settings:readSetting("bookends_font_bold", false),
        v_offset  = G_reader_settings:readSetting("bookends_v_offset", 35),
        h_offset  = G_reader_settings:readSetting("bookends_h_offset", 10),
        overlap_gap = G_reader_settings:readSetting("bookends_overlap_gap", 10),
    }

    -- Per-position settings (table with format, font_face, font_size, etc.)
    self.positions = {}
    for _, pos in ipairs(self.POSITIONS) do
        self.positions[pos.key] = G_reader_settings:readSetting("bookends_pos_" .. pos.key, {
            format = "",
        })
    end
end

function Bookends:savePositionSetting(key)
    G_reader_settings:saveSetting("bookends_pos_" .. key, self.positions[key])
end

function Bookends:getPositionSetting(key, field)
    local pos = self.positions[key]
    if pos[field] ~= nil then
        return pos[field]
    end
    return self.defaults[field]
end

function Bookends:isPositionActive(key)
    return self.enabled and self.positions[key].format ~= ""
end

function Bookends:markDirty()
    self.dirty = true
    UIManager:setDirty(self.ui, "ui")
end

-- Event handlers
function Bookends:onPageUpdate() self:markDirty() end
function Bookends:onPosUpdate() self:markDirty() end
function Bookends:onReaderFooterVisibilityChange() self:markDirty() end
function Bookends:onSetDimensions() self:markDirty() end
function Bookends:onResume() self:markDirty() end

function Bookends:paintTo(bb, x, y)
    if not self.enabled then return end

    local screen_size = Screen:getSize()
    local screen_w = screen_size.w
    local screen_h = screen_size.h

    -- Phase 1: Expand tokens for all active positions
    local expanded = {} -- key -> expanded text string
    for _, pos in ipairs(self.POSITIONS) do
        if self:isPositionActive(pos.key) then
            local fmt = self.positions[pos.key].format
            -- Convert literal backslash-n to real newline for line splitting
            fmt = fmt:gsub("\\n", "\n")
            expanded[pos.key] = Tokens.expand(fmt, self.ui, self.session_start_time)
        end
    end

    -- Check if anything changed
    if not self.dirty then
        local changed = false
        for key, text in pairs(expanded) do
            if text ~= self.position_cache[key] then
                changed = true
                break
            end
        end
        if not changed then
            -- Repaint existing widgets at their cached positions
            for _, pos in ipairs(self.POSITIONS) do
                local entry = self.widget_cache and self.widget_cache[pos.key]
                if entry then
                    entry.widget:paintTo(bb, x + entry.x, y + entry.y)
                end
            end
            return
        end
    end

    -- Phase 2: Measure all active positions (no truncation yet)
    local measurements = {} -- key -> { width, face, bold }
    for key, text in pairs(expanded) do
        local face = Font:getFace(
            self:getPositionSetting(key, "font_face"),
            self:getPositionSetting(key, "font_size"))
        local bold = self:getPositionSetting(key, "font_bold")
        local w = OverlayWidget.measureTextWidth(text, face, bold)
        measurements[key] = { width = w, face = face, bold = bold }
    end

    -- Phase 3: Calculate overlap limits per row
    local gap = self.defaults.overlap_gap

    -- Free old widgets
    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
    end
    self.widget_cache = {}

    for _, row in ipairs({"top", "bottom"}) do
        local left_key = row == "top" and "tl" or "bl"
        local center_key = row == "top" and "tc" or "bc"
        local right_key = row == "top" and "tr" or "br"

        local left_w = measurements[left_key] and measurements[left_key].width or nil
        local center_w = measurements[center_key] and measurements[center_key].width or nil
        local right_w = measurements[right_key] and measurements[right_key].width or nil

        local left_h_offset = self:getPositionSetting(left_key, "h_offset")
        local right_h_offset = self:getPositionSetting(right_key, "h_offset")
        -- Use the larger h_offset for overlap calc to be safe
        local max_h_offset = math.max(left_h_offset or 0, right_h_offset or 0)

        local limits = OverlayWidget.calculateRowLimits(
            left_w, center_w, right_w, screen_w, gap, max_h_offset)

        -- Phase 4: Build widgets with truncation limits applied
        local row_keys = {
            { key = left_key, limit_key = "left" },
            { key = center_key, limit_key = "center" },
            { key = right_key, limit_key = "right" },
        }
        for _, rk in ipairs(row_keys) do
            local key = rk.key
            if expanded[key] then
                local m = measurements[key]
                local pos_def = nil
                for _, p in ipairs(self.POSITIONS) do
                    if p.key == key then pos_def = p; break end
                end

                local max_width = limits[rk.limit_key] -- nil if no truncation needed
                local widget, w, h = OverlayWidget.buildTextWidget(
                    expanded[key], m.face, m.bold, pos_def.h_anchor, max_width)

                if widget then
                    local v_off = self:getPositionSetting(key, "v_offset")
                    local h_off = self:getPositionSetting(key, "h_offset")
                    local px, py = OverlayWidget.computeCoordinates(
                        pos_def.h_anchor, pos_def.v_anchor,
                        w, h, screen_w, screen_h, v_off, h_off)

                    self.widget_cache[key] = { widget = widget, x = px, y = py }
                    widget:paintTo(bb, x + px, y + py)
                end
            end
        end
    end

    -- Update cache
    self.position_cache = {}
    for key, text in pairs(expanded) do
        self.position_cache[key] = text
    end
    self.dirty = false
end

function Bookends:onCloseWidget()
    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
        self.widget_cache = nil
    end
end

function Bookends:addToMainMenu(menu_items)
    -- Will be implemented in Task 5
    menu_items.bookends = {
        text = _("Bookends"),
        sorting_hint = "setting",
        sub_item_table = {},
    }
end

return Bookends
