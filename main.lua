local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen
local Tokens = require("tokens")
local OverlayWidget = require("overlay_widget")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local util = require("util")

--- Remove an index from a sparse table, shifting higher indices down.
-- Unlike table.remove, this works correctly when the table has gaps.
local function sparseRemove(tbl, idx)
    if not tbl then return end
    -- Find the highest index
    local max_idx = 0
    for k in pairs(tbl) do
        if type(k) == "number" and k > max_idx then max_idx = k end
    end
    -- Shift everything above idx down by one
    for i = idx, max_idx do
        tbl[i] = tbl[i + 1]
    end
end

--- Truncate a string to max_bytes, avoiding splitting multi-byte UTF-8 characters.
local function truncateUtf8(str, max_bytes)
    if #str <= max_bytes then return str end
    local pos = 0
    local i = 1
    while i <= max_bytes do
        local b = str:byte(i)
        local char_len
        if b < 0x80 then char_len = 1
        elseif b < 0xE0 then char_len = 2
        elseif b < 0xF0 then char_len = 3
        else char_len = 4 end
        if i + char_len - 1 > max_bytes then break end
        pos = i + char_len - 1
        i = i + char_len
    end
    return str:sub(1, pos) .. "..."
end

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
    self.session_elapsed = 0
    self.session_resume_time = os.time()
    self.session_start_page = nil -- raw page, set on first onPageUpdate
    self.session_max_page = nil   -- highest raw page reached
    self.dirty = true
    self.position_cache = {}

    -- Preset system
    local Presets = require("ui/presets")
    self.preset_obj = {
        presets = G_reader_settings:readSetting("bookends_presets", {}),
        dispatcher_name = "load_bookends_preset",
        buildPreset = function() return self:buildPreset() end,
        loadPreset = function(preset) self:loadPreset(preset) end,
    }

    -- Register gesture/dispatcher actions
    self:onDispatcherRegisterActions()
end

function Bookends:onDispatcherRegisterActions()
    local Dispatcher = require("dispatcher")
    Dispatcher:registerAction("toggle_bookends", {
        category = "none",
        event = "ToggleBookends",
        title = _("Toggle bookends"),
        reader = true,
    })
end

function Bookends:onToggleBookends()
    self.enabled = not self.enabled
    G_reader_settings:saveSetting("bookends_enabled", self.enabled)
    self:markDirty()
    return true
end

function Bookends:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = G_reader_settings:readSetting("bookends_enabled", false)

    self.defaults = {
        font_face = G_reader_settings:readSetting("bookends_font_face", Font.fontmap["ffont"]),
        font_size = G_reader_settings:readSetting("bookends_font_size", footer_settings.text_font_size),
        font_bold = G_reader_settings:readSetting("bookends_font_bold", false),
        margin_top    = G_reader_settings:readSetting("bookends_margin_top", 10),
        margin_bottom = G_reader_settings:readSetting("bookends_margin_bottom", 25),
        margin_left   = G_reader_settings:readSetting("bookends_margin_left", 18),
        margin_right  = G_reader_settings:readSetting("bookends_margin_right", 18),
        font_scale = G_reader_settings:readSetting("bookends_font_scale", 100),
        overlap_gap = G_reader_settings:readSetting("bookends_overlap_gap", 50),
        truncation_priority = G_reader_settings:readSetting("bookends_truncation_priority", "center"),
    }

    -- Default position configurations (used on first run)
    local default_positions = {
        tl = { lines = { "%A \xE2\x8B\xAE %T" }, line_font_size = { [1] = 12 } },
        tc = { lines = { "%k \xC2\xB7 %a %d" }, line_font_size = { [1] = 14 }, line_style = { [1] = "bold" } },
        tr = { lines = { "%C" }, line_style = { [1] = "bold" } },
        bl = { lines = { "\xE2\x8F\xB3 %R session" } },
        bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 16 } },
        br = { lines = { "%B %W" }, line_font_size = { [1] = 10 } },
    }

    -- Per-position settings
    self.positions = {}
    for _, pos in ipairs(self.POSITIONS) do
        local saved = G_reader_settings:readSetting("bookends_pos_" .. pos.key)
        if saved then
            -- Migration: old format string → lines array
            if saved.format and saved.format ~= "" and not saved.lines then
                saved.lines = { saved.format }
                saved.format = nil
            end
            if not saved.lines then
                saved.lines = {}
            end
            self.positions[pos.key] = saved
        else
            -- First run: use default configuration
            self.positions[pos.key] = default_positions[pos.key] or { lines = {} }
        end
    end
end

function Bookends:buildPreset()

    local preset = {
        enabled = self.enabled,
        defaults = util.tableDeepCopy(self.defaults),
        positions = {},
    }
    for _, pos in ipairs(self.POSITIONS) do
        preset.positions[pos.key] = util.tableDeepCopy(self.positions[pos.key])
    end
    return preset
end

function Bookends:loadPreset(preset)

    if preset.enabled ~= nil then
        self.enabled = preset.enabled
        G_reader_settings:saveSetting("bookends_enabled", self.enabled)
    end
    if preset.defaults then
        local pd = preset.defaults
        -- Ignore old v_offset/h_offset keys from pre-v2 presets
        pd.v_offset = nil
        pd.h_offset = nil
        -- Reset margins before applying preset values
        self.defaults.margin_top = 10
        self.defaults.margin_bottom = 25
        self.defaults.margin_left = 18
        self.defaults.margin_right = 18
        for k, v in pairs(pd) do
            self.defaults[k] = v
        end
        G_reader_settings:saveSetting("bookends_font_face", self.defaults.font_face)
        G_reader_settings:saveSetting("bookends_font_size", self.defaults.font_size)
        G_reader_settings:saveSetting("bookends_font_bold", self.defaults.font_bold)
        G_reader_settings:saveSetting("bookends_font_scale", self.defaults.font_scale)
        G_reader_settings:saveSetting("bookends_margin_top", self.defaults.margin_top)
        G_reader_settings:saveSetting("bookends_margin_bottom", self.defaults.margin_bottom)
        G_reader_settings:saveSetting("bookends_margin_left", self.defaults.margin_left)
        G_reader_settings:saveSetting("bookends_margin_right", self.defaults.margin_right)
        G_reader_settings:saveSetting("bookends_overlap_gap", self.defaults.overlap_gap)
        G_reader_settings:saveSetting("bookends_truncation_priority", self.defaults.truncation_priority)
    end
    if preset.positions then
        for _, pos in ipairs(self.POSITIONS) do
            if preset.positions[pos.key] then
                self.positions[pos.key] = util.tableDeepCopy(preset.positions[pos.key])
                self:savePositionSetting(pos.key)
            end
        end
    end
    self:markDirty()
end

function Bookends:savePositionSetting(key)
    G_reader_settings:saveSetting("bookends_pos_" .. key, self.positions[key])
end

function Bookends:getPositionSetting(key, field)
    local pos = self.positions[key]
    if pos[field] ~= nil then
        return pos[field]
    end
    return self.defaults[field] or 0
end

function Bookends:getMargin(key)
    local is_top = key == "tl" or key == "tc" or key == "tr"
    local is_left = key == "tl" or key == "bl"
    local v_margin = is_top and self.defaults.margin_top or self.defaults.margin_bottom
    local h_margin = is_left and self.defaults.margin_left or self.defaults.margin_right
    return v_margin, h_margin
end

function Bookends:isPositionActive(key)
    return self.enabled and #self.positions[key].lines > 0 and not self.positions[key].disabled
end

function Bookends:markDirty()
    self.dirty = true
    UIManager:setDirty(self.ui, "ui")
end

-- Style constants and helpers
Bookends.STYLES = { "regular", "bold", "italic", "bolditalic" }
Bookends.STYLE_LABELS = {
    regular = _("Regular"),
    bold = _("Bold"),
    italic = _("Italic"),
    bolditalic = _("Bold Italic"),
}

-- Cache for italic font variant lookups
local _italic_cache = {}

-- Find the italic variant of a font by searching for common naming patterns
local function findItalicVariant(face_name)
    if _italic_cache[face_name] ~= nil then
        return _italic_cache[face_name] -- may be false (no variant found)
    end

    local ok, FontList = pcall(require, "fontlist")
    if not ok then
        _italic_cache[face_name] = false
        return false
    end
    local all_fonts = FontList:getFontList()

    -- Extract the directory and base name without extension
    local dir = face_name:match("^(.*/)") or ""
    local basename = face_name:match("([^/]+)$") or face_name
    local name_no_ext = (basename:gsub("%.[^.]+$", ""))

    -- Common patterns: "Regular" -> "Italic", "Bold" -> "BoldItalic",
    -- or just append "Italic" / "-Italic" / " Italic"
    local candidates = {}
    -- Replace Regular/regular with Italic/italic
    if name_no_ext:match("[Rr]egular") then
        table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "Italic")))
        table.insert(candidates, (name_no_ext:gsub("[Rr]egular", "italic")))
    end
    -- Replace Bold with BoldItalic
    if name_no_ext:match("[Bb]old") and not name_no_ext:match("[Ii]talic") then
        table.insert(candidates, (name_no_ext:gsub("[Bb]old", "BoldItalic")))
        table.insert(candidates, (name_no_ext:gsub("[Bb]old", "Bolditalic")))
    end
    -- Append -Italic, Italic, _Italic, " Italic"
    table.insert(candidates, name_no_ext .. "-Italic")
    table.insert(candidates, name_no_ext .. "Italic")
    table.insert(candidates, name_no_ext .. " Italic")
    table.insert(candidates, name_no_ext .. "-italic")

    -- Search available fonts
    for _, candidate in ipairs(candidates) do
        local pattern = candidate:lower()
        for _, font_path in ipairs(all_fonts) do
            local font_name = font_path:match("([^/]+)$") or ""
            local font_no_ext = font_name:gsub("%.[^.]+$", "")
            if font_no_ext:lower() == pattern then
                _italic_cache[face_name] = font_path
                return font_path
            end
        end
    end

    _italic_cache[face_name] = false
    return false
end

function Bookends:resolveLineConfig(face_name, font_size, style)
    style = style or "regular"
    local bold = (style == "bold" or style == "bolditalic")
    local resolved_face = face_name

    if style == "italic" or style == "bolditalic" then
        local italic = findItalicVariant(face_name)
        if italic then
            resolved_face = italic
        end
    end

    -- Apply font scale
    local scale = self.defaults.font_scale or 100
    local scaled_size = math.max(6, math.floor(font_size * scale / 100 + 0.5))

    return {
        face = Font:getFace(resolved_face, scaled_size),
        bold = bold,
    }
end

-- Event handlers
function Bookends:onPageUpdate()
    local current = self.ui.view.state.page
    if current then
        if not self.session_start_page then
            self.session_start_page = current
            self.session_max_page = current
        elseif current > self.session_max_page then
            self.session_max_page = current
        end
    end
    self:markDirty()
end
function Bookends:onPosUpdate() self:markDirty() end
function Bookends:onReaderFooterVisibilityChange() self:markDirty() end
function Bookends:onSetDimensions() self:markDirty() end

-- Repaint after events that cause the footer to refresh over us
function Bookends:delayedRepaint()
    UIManager:nextTick(function()
        self:markDirty()
    end)
end
Bookends.onFrontlightStateChanged = Bookends.delayedRepaint
Bookends.onCharging               = Bookends.delayedRepaint
Bookends.onNotCharging            = Bookends.delayedRepaint
Bookends.onNetworkConnected       = Bookends.delayedRepaint
Bookends.onNetworkDisconnected    = Bookends.delayedRepaint
Bookends.onAnnotationsModified = Bookends.delayedRepaint
function Bookends:getSessionElapsed()
    local elapsed = self.session_elapsed or 0
    if self.session_resume_time then
        elapsed = elapsed + (os.time() - self.session_resume_time)
    end
    return elapsed
end
function Bookends:onSuspend()
    self:stopRefreshTimer()
end
function Bookends:onResume()
    -- Each wake from suspend starts a new reading session
    self.session_elapsed = 0
    self.session_resume_time = os.time()
    self.session_start_page = self.session_max_page
    self:markDirty()
    -- Repaint after the footer's async resume refresh paints over us
    UIManager:scheduleIn(1.5, function()
        self:markDirty()
    end)
end

function Bookends:paintTo(bb, x, y)
    if not self.enabled then return end

    local screen_size = Screen:getSize()
    local screen_w = screen_size.w
    local screen_h = screen_size.h

    -- Phase 1: Expand tokens for all active positions
    -- Filter lines by page parity, join with \n, then expand tokens
    local pageno = self.ui.view.state.page or 0
    local is_odd_page = (pageno % 2) == 1
    local expanded = {}
    local active_line_indices = {} -- key -> { original indices of visible lines }
    for _, pos in ipairs(self.POSITIONS) do
        if self:isPositionActive(pos.key) then
            local pos_settings = self.positions[pos.key]
            local visible_lines = {}
            local visible_indices = {}
            for i, line in ipairs(pos_settings.lines) do
                local filter = pos_settings.line_page_filter and pos_settings.line_page_filter[i]
                if not filter
                    or (filter == "odd" and is_odd_page)
                    or (filter == "even" and not is_odd_page) then
                    table.insert(visible_lines, line)
                    table.insert(visible_indices, i)
                end
            end
            if #visible_lines > 0 then
                local session_elapsed = self:getSessionElapsed()
                local session_pages = math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0))
                local expanded_lines = {}
                local final_indices = {}
                for j, line in ipairs(visible_lines) do
                    local result, is_empty = Tokens.expand(line, self.ui, session_elapsed, session_pages)
                    if not is_empty then
                        table.insert(expanded_lines, result)
                        table.insert(final_indices, visible_indices[j])
                    end
                end
                if #expanded_lines > 0 then
                    expanded[pos.key] = table.concat(expanded_lines, "\n")
                    active_line_indices[pos.key] = final_indices
                end
            end
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
            for key in pairs(self.position_cache) do
                if not expanded[key] then
                    changed = true
                    break
                end
            end
        end
        if not changed then
            for _, pos in ipairs(self.POSITIONS) do
                local entry = self.widget_cache and self.widget_cache[pos.key]
                if entry then
                    entry.widget:paintTo(bb, x + entry.x, y + entry.y)
                end
            end
            return
        end
    end

    -- Phase 2: Build per-line rendering configs and build widgets for measurement
    local pre_built = {} -- key -> { widget, w, h, line_configs, pos_def }
    for key, text in pairs(expanded) do
        local pos_settings = self.positions[key]
        local default_face_name = self:getPositionSetting(key, "font_face")
        local default_font_size = self:getPositionSetting(key, "font_size")

        local line_configs = {}
        local indices = active_line_indices[key] or {}
        for _, i in ipairs(indices) do
            local face_name = (pos_settings.line_font_face and pos_settings.line_font_face[i])
                or default_face_name
            local font_size = (pos_settings.line_font_size and pos_settings.line_font_size[i])
                or default_font_size
            local style = (pos_settings.line_style and pos_settings.line_style[i])
                or "regular"
            local cfg = self:resolveLineConfig(face_name, font_size, style)
            cfg.v_nudge = (pos_settings.line_v_nudge and pos_settings.line_v_nudge[i]) or 0
            cfg.h_nudge = (pos_settings.line_h_nudge and pos_settings.line_h_nudge[i]) or 0
            cfg.uppercase = (pos_settings.line_uppercase and pos_settings.line_uppercase[i]) or false
            table.insert(line_configs, cfg)
        end

        local pos_def
        for _, p in ipairs(self.POSITIONS) do
            if p.key == key then pos_def = p; break end
        end

        -- Build without truncation to measure natural width
        local widget, w, h = OverlayWidget.buildTextWidget(text, line_configs, pos_def.h_anchor, nil)
        pre_built[key] = { widget = widget, w = w, h = h, line_configs = line_configs, pos_def = pos_def }
    end

    -- Phase 3: Calculate overlap limits per row
    local gap = self.defaults.overlap_gap

    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
    end
    self.widget_cache = {}

    for _, row in ipairs({"top", "bottom"}) do
        local left_key = row == "top" and "tl" or "bl"
        local center_key = row == "top" and "tc" or "bc"
        local right_key = row == "top" and "tr" or "br"

        local left_w = pre_built[left_key] and pre_built[left_key].w or nil
        local center_w = pre_built[center_key] and pre_built[center_key].w or nil
        local right_w = pre_built[right_key] and pre_built[right_key].w or nil

        local _, left_h_margin = self:getMargin(left_key)
        local _, right_h_margin = self:getMargin(right_key)
        local left_h_offset = self:getPositionSetting(left_key, "h_offset") + left_h_margin
        local right_h_offset = self:getPositionSetting(right_key, "h_offset") + right_h_margin
        local max_h_offset = math.max(left_h_offset, right_h_offset)

        local limits = OverlayWidget.calculateRowLimits(
            left_w, center_w, right_w, screen_w, gap, max_h_offset,
            self.defaults.truncation_priority)

        -- Phase 4: Reuse pre-built widgets or rebuild with truncation
        local row_keys = {
            { key = left_key, limit_key = "left" },
            { key = center_key, limit_key = "center" },
            { key = right_key, limit_key = "right" },
        }
        for _, rk in ipairs(row_keys) do
            local key = rk.key
            local pb = pre_built[key]
            if pb then
                local max_width = limits[rk.limit_key]
                local widget, w, h

                if max_width then
                    -- Truncation needed: free pre-built widget and rebuild with limit
                    if pb.widget and pb.widget.free then pb.widget:free() end
                    widget, w, h = OverlayWidget.buildTextWidget(
                        expanded[key], pb.line_configs, pb.pos_def.h_anchor, max_width)
                else
                    -- No truncation: reuse pre-built widget
                    widget, w, h = pb.widget, pb.w, pb.h
                end

                if widget then
                    local v_margin, h_margin = self:getMargin(key)
                    local v_off = self:getPositionSetting(key, "v_offset") + v_margin
                    local h_off = self:getPositionSetting(key, "h_offset") + h_margin
                    local px, py = OverlayWidget.computeCoordinates(
                        pb.pos_def.h_anchor, pb.pos_def.v_anchor,
                        w, h, screen_w, screen_h, v_off, h_off)

                    -- Apply first line's nudge for single-line widgets
                    -- (MultiLineWidget handles per-line nudges internally)
                    local cfg1 = pb.line_configs[1]
                    if cfg1 and not widget.lines then -- not a MultiLineWidget
                        px = px + (cfg1.h_nudge or 0)
                        py = py + (cfg1.v_nudge or 0)
                    end

                    self.widget_cache[key] = { widget = widget, x = px, y = py }
                    widget:paintTo(bb, x + px, y + py)
                else
                    -- Widget wasn't used (truncated to zero); free it
                    if pb.widget and pb.widget.free then pb.widget:free() end
                end
            end
        end
    end

    self.position_cache = {}
    for key, text in pairs(expanded) do
        self.position_cache[key] = text
    end
    self.dirty = false
    self:startRefreshTimer()
end

function Bookends:onCloseWidget()
    self:stopRefreshTimer()
    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
        self.widget_cache = nil
    end
end

function Bookends:startRefreshTimer()
    if self.refresh_timer_active then return end
    self.refresh_timer_active = true
    self.refresh_timer_func = function()
        if not self.refresh_timer_active then return end
        self:markDirty()
        UIManager:scheduleIn(60, self.refresh_timer_func)
    end
    UIManager:scheduleIn(60, self.refresh_timer_func)
end

function Bookends:stopRefreshTimer()
    if self.refresh_timer_func then
        UIManager:unschedule(self.refresh_timer_func)
    end
    self.refresh_timer_active = false
    self.refresh_timer_func = nil
end

-- ─── Menu ────────────────────────────────────────────────

function Bookends:addToMainMenu(menu_items)
    menu_items.bookends = {
        text = _("Bookends"),
        sorting_hint = "typeset",
        sub_item_table = self:buildMainMenu(),
    }
end

function Bookends:buildMainMenu()
    local menu = {
        {
            text = _("Enable bookends"),
            checked_func = function()
                return self.enabled
            end,
            callback = function()
                self.enabled = not self.enabled
                G_reader_settings:saveSetting("bookends_enabled", self.enabled)
                self:markDirty()
            end,
        },
    }

    -- Per-position submenus
    for _, pos in ipairs(self.POSITIONS) do
        table.insert(menu, {
            text_func = function()
                local lines = self.positions[pos.key].lines
                if #lines == 0 then
                    return pos.label
                end
                local session_elapsed = self:getSessionElapsed()
                local session_pages = math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0))
                local previews = {}
                for _, line in ipairs(lines) do
                    table.insert(previews, (Tokens.expandPreview(line, self.ui, session_elapsed, session_pages)))
                end
                local preview = table.concat(previews, " \xC2\xB7 ")
                if #preview > 38 then
                    preview = truncateUtf8(preview, 35)
                end
                return pos.label .. " \xE2\x80\x94 " .. preview
            end,
            enabled_func = function() return self.enabled end,
            checked_func = function()
                return #self.positions[pos.key].lines > 0 and not self.positions[pos.key].disabled
            end,
            hold_callback = function(touchmenu_instance)
                if #self.positions[pos.key].lines == 0 then return end
                self.positions[pos.key].disabled = not self.positions[pos.key].disabled or nil
                self:savePositionSetting(pos.key)
                self:markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
            sub_item_table_func = function()
                return self:buildPositionMenu(pos)
            end,
        })
    end

    -- Add separator after last position entry
    menu[#menu].separator = true

    -- Presets
    table.insert(menu, {
        text = _("Presets"),
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            return self:buildPresetsMenu()
        end,
    })

    -- Settings submenu
    table.insert(menu, {
        text = _("Settings"),
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        local name = self.defaults.font_face:match("([^/]+)$"):gsub("%.%w+$", "")
                        return _("Default font") .. " (" .. name .. ")"
                    end,
                    sub_item_table = self:buildFontMenu(function() return self.defaults.font_face end,
                        function(face)
                            self.defaults.font_face = face
                            G_reader_settings:saveSetting("bookends_font_face", face)
                            self:markDirty()
                        end),
                },
                {
                    text_func = function()
                        return _("Font scale") .. " (" .. self.defaults.font_scale .. "%)"
                    end,
                    callback = function()
                        self:showFontScaleDialog()
                    end,
                },
                {
                    text_func = function()
                        local m = self.defaults
                        return _("Adjust margins") .. " (" .. m.margin_top .. "/" .. m.margin_bottom .. "/" .. m.margin_left .. "/" .. m.margin_right .. ")"
                    end,
                    callback = function()
                        self:showMarginAdjuster()
                    end,
                },
                {
                    text_func = function()
                        return _("Truncation gap between regions") .. " (" .. self.defaults.overlap_gap .. ")"
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showSpinner(_("Truncation gap between regions (px)"), self.defaults.overlap_gap, 0, 999, 50,
                            function(val)
                                self.defaults.overlap_gap = val
                                G_reader_settings:saveSetting("bookends_overlap_gap", val)
                                self:markDirty()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end)
                    end,
                },
                {
                    text = _("Prioritise left/right and truncate long center text"),
                    keep_menu_open = true,
                    checked_func = function()
                        return self.defaults.truncation_priority == "sides"
                    end,
                    callback = function()
                        if self.defaults.truncation_priority == "sides" then
                            self.defaults.truncation_priority = "center"
                        else
                            self.defaults.truncation_priority = "sides"
                        end
                        G_reader_settings:saveSetting("bookends_truncation_priority", self.defaults.truncation_priority)
                        self:markDirty()
                    end,
                    separator = true,
                },
                {
                    text = _("Check for updates"),
                    keep_menu_open = true,
                    callback = function()
                        self:checkForUpdates()
                    end,
                },
            }
        end,
    })

    return menu
end

function Bookends:buildPositionMenu(pos)
    local is_corner = pos.h_anchor ~= "center"
    local menu = {}
    local lines = self.positions[pos.key].lines

    -- Enable/disable toggle (only shown when position has lines)
    if #lines > 0 then
        table.insert(menu, {
            text = _("Enabled"),
            checked_func = function()
                return not self.positions[pos.key].disabled
            end,
            callback = function()
                self.positions[pos.key].disabled = not self.positions[pos.key].disabled or nil
                self:savePositionSetting(pos.key)
                self:markDirty()
            end,
            separator = true,
        })
    end

    -- Line entries (no keep_menu_open so menu refreshes after editing)
    for i, line in ipairs(lines) do
        table.insert(menu, {
            text_func = function()
                local ps = self.positions[pos.key]
                local filter = ps.line_page_filter and ps.line_page_filter[i]
                local tag = ""
                if filter == "odd" then tag = " [odd]"
                elseif filter == "even" then tag = " [even]" end
                local preview = (Tokens.expandPreview(ps.lines[i] or "", self.ui, self:getSessionElapsed(), math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0))))
                if #preview > 42 then
                    preview = truncateUtf8(preview, 39)
                end
                return _("Line") .. " " .. i .. tag .. ": " .. preview
            end,
            callback = function()
                self:editLineString(pos, i)
            end,
            hold_callback = function(touchmenu_instance)
                self:showLineManageDialog(pos, i, touchmenu_instance)
            end,
        })
    end

    -- Add line
    table.insert(menu, {
        text = "+ " .. _("Add line") .. "  (" .. _("long press lines to manage") .. ")",
        callback = function()
            local idx = #self.positions[pos.key].lines + 1
            table.insert(self.positions[pos.key].lines, "")
            self:savePositionSetting(pos.key)
            self:editLineString(pos, idx)
        end,
        separator = true,
    })

    -- Per-position extra margins with nudge buttons
    local is_top = pos.v_anchor == "top"
    local v_label = is_top and _("Extra top margin") or _("Extra bottom margin")
    table.insert(menu, {
        text_func = function()
            local val = self.positions[pos.key].v_offset
            if val then return v_label .. " (" .. val .. ")" end
            return v_label
        end,
        callback = function()
            self:showNudgeDialog(pos, "v_offset", v_label)
        end,
    })

    if is_corner then
        local is_left = pos.h_anchor == "left"
        local h_label = is_left and _("Extra left margin") or _("Extra right margin")
        table.insert(menu, {
            text_func = function()
                local val = self.positions[pos.key].h_offset
                if val then return h_label .. " (" .. val .. ")" end
                return h_label
            end,
            callback = function()
                self:showNudgeDialog(pos, "h_offset", h_label)
            end,
        })
    end

    return menu
end

-- ─── Presets ─────────────────────────────────────────────

Bookends.BUILT_IN_PRESETS = {
    -- Nerd Font icon references used in presets:
    -- U+F017 = \xEF\x80\x97 clock
    -- U+F024 = \xEF\x80\xA4 flag
    -- U+F02D = \xEF\x80\xAD book
    -- U+F06E = \xEF\x81\xAE eye
    -- U+F097 = \xEF\x82\x97 bookmark
    -- U+F0EB = \xEF\x83\xAB lightbulb
    -- U+F185 = \xEF\x86\x85 sun
    {
        name = _("Classic alternating"),
        preset = {
            enabled = true,
            defaults = {
                margin_top = 10, margin_bottom = 50,
                margin_left = 18, margin_right = 18,
            },
            positions = {
                tl = { lines = { "%T" }, line_font_size = { [1] = 18 }, line_style = { [1] = "bolditalic" }, line_page_filter = { [1] = "even" } },
                tc = { lines = {} },
                tr = { lines = { "%C" }, line_font_size = { [1] = 18 }, line_style = { [1] = "bolditalic" }, line_page_filter = { [1] = "odd" } },
                bl = { lines = {} },
                bc = { lines = { "p%c" }, line_font_size = { [1] = 18 } },
                br = { lines = {} },
            },
        },
    },
    {
        name = _("Rich detail"),
        preset = {
            enabled = true,
            defaults = {
                margin_top = 10, margin_bottom = 25,
                margin_left = 18, margin_right = 18,
            },
            positions = {
                tl = { lines = { "%A \xE2\x8B\xAE %T", "%S" }, line_font_size = { [1] = 12 } },
                tc = { lines = { "%k \xC2\xB7 %a %d" }, line_font_size = { [1] = 14 }, line_style = { [1] = "bold" } },
                tr = { lines = { "%C", "%x Bookmark(s) \xEF\x82\x97" } },
                bl = { lines = { "\xEF\x83\xAB %F", "\xEF\x86\x85 %f", "\xE2\x8F\xB3 %R \xC2\xBB %s page session" } },
                bc = { lines = { "Page %c of %t" }, v_offset = 30, line_font_size = { [1] = 18 } },
                br = { lines = { "%B", "%W", "%q highlight(s) \xEF\x80\xA4" } },
            },
        },
    },
    {
        name = _("Speed reader"),
        preset = {
            enabled = true,
            defaults = {
                margin_top = 10, margin_bottom = 25,
                margin_left = 18, margin_right = 18,
            },
            positions = {
                tl = { lines = { "\xEF\x80\x97 %k" }, line_font_size = { [1] = 16 }, line_style = { [1] = "bold" } },
                tc = { lines = { "\xE2\x8F\xB3 %R \xC2\xBB %s page(s) read this session", "\xEF\x83\xA4 %r page(s)/hr" }, line_font_size = { [1] = 16 }, line_style = { [1] = "bold" } },
                tr = { lines = { "%B %b" }, line_font_size = { [1] = 16 }, line_style = { [1] = "bold" } },
                bl = { lines = { "%p", "\xEF\x81\xAE %E reading this book" } },
                bc = { lines = { "Page %c of %t", "\xEF\x80\xAD %L pages ~ %H left in book" },
                    v_offset = 4, line_font_size = { [1] = 18 }, line_style = { [1] = "italic", [2] = "bold" },
                    line_v_nudge = { [1] = -14 } },
                br = { lines = { "%P", "%l page(s) ~ %h left in chapter" }, line_font_size = { [2] = 12 } },
            },
        },
    },
}

function Bookends:buildPresetsMenu()
    local items = {
        {
            text = _("Built-in presets"),
            enabled_func = function() return false end,
            separator = true,
        },
    }

    -- Built-in presets (sorted alphabetically)
    local sorted_builtins = {}
    for _, bp in ipairs(self.BUILT_IN_PRESETS) do
        table.insert(sorted_builtins, bp)
    end
    table.sort(sorted_builtins, function(a, b) return a.name < b.name end)
    for _i, bp in ipairs(sorted_builtins) do
        table.insert(items, {
            text = bp.name,
            keep_menu_open = true,
            callback = function()
                self:loadPreset(bp.preset)
                UIManager:show(InfoMessage:new{
                    text = T(_("Preset '%1' loaded."), bp.name),
                    timeout = 2,
                })
            end,
        })
    end
    items[#items].separator = true

    -- Custom presets submenu (fully managed by Presets module)
    table.insert(items, {
        text = _("Custom presets"),
        sub_item_table_func = function()
            local Presets = require("ui/presets")
            local user_items = Presets.genPresetMenuItemTable(self.preset_obj)
            table.insert(user_items, {
                text = _("Long press presets to edit"),
                enabled_func = function() return false end,
            })
            return user_items
        end,
    })

    return items
end

-- ─── Line editing ────────────────────────────────────────

function Bookends:editLineString(pos, line_idx)
    local IconPicker = require("icon_picker")

    local pos_settings = self.positions[pos.key]

    local current_text = pos_settings.lines[line_idx] or ""

    -- Per-line style state
    pos_settings.line_style = pos_settings.line_style or {}
    pos_settings.line_font_size = pos_settings.line_font_size or {}
    pos_settings.line_font_face = pos_settings.line_font_face or {}
    pos_settings.line_v_nudge = pos_settings.line_v_nudge or {}
    pos_settings.line_h_nudge = pos_settings.line_h_nudge or {}
    pos_settings.line_uppercase = pos_settings.line_uppercase or {}
    pos_settings.line_page_filter = pos_settings.line_page_filter or {}

    -- Snapshot for cancel/restore
    local original_settings = util.tableDeepCopy(pos_settings)

    local line_style = pos_settings.line_style[line_idx] or "regular"
    local line_size = pos_settings.line_font_size[line_idx] -- nil = use default
    local line_face = pos_settings.line_font_face[line_idx] -- nil = use default
    local line_v_nudge = pos_settings.line_v_nudge[line_idx] or 0
    local line_h_nudge = pos_settings.line_h_nudge[line_idx] or 0
    local line_uppercase = pos_settings.line_uppercase[line_idx] or false
    local line_page_filter = pos_settings.line_page_filter[line_idx] -- nil = all pages

    -- Live preview: write current local state to settings and repaint
    local function applyLivePreview()
        pos_settings.line_style[line_idx] = line_style ~= "regular" and line_style or nil
        pos_settings.line_font_size[line_idx] = line_size
        pos_settings.line_font_face[line_idx] = line_face
        pos_settings.line_v_nudge[line_idx] = line_v_nudge ~= 0 and line_v_nudge or nil
        pos_settings.line_h_nudge[line_idx] = line_h_nudge ~= 0 and line_h_nudge or nil
        pos_settings.line_uppercase[line_idx] = line_uppercase or nil
        pos_settings.line_page_filter[line_idx] = line_page_filter
        self:markDirty()
    end

    -- Style cycle button
    local style_button = {
        text_func = function()
            return self.STYLE_LABELS[line_style] or _("Regular")
        end,
        callback = function() end,
    }
    local size_button = {
        text_func = function()
            return _("Size") .. ": " .. (line_size or self:getPositionSetting(pos.key, "font_size"))
        end,
        callback = function() end,
    }
    local font_button = {
        text_func = function()
            if line_face then
                return _("Font") .. " \xE2\x9C\x93"
            end
            return _("Font...")
        end,
        callback = function() end,
    }
    local case_button = {
        text_func = function()
            return line_uppercase and "AA" or "Aa"
        end,
        callback = function() end,
    }
    local PAGE_FILTERS = { nil, "odd", "even" }
    local PAGE_FILTER_LABELS = {
        [1] = _("All"),
        [2] = _("Odd"),
        [3] = _("Even"),
    }
    local page_filter_button = {
        text_func = function()
            if line_page_filter == "odd" then return _("Odd pg")
            elseif line_page_filter == "even" then return _("Even pg")
            else return _("All pg") end
        end,
        callback = function() end,
    }

    local format_dialog

    case_button.callback = function()
        line_uppercase = not line_uppercase
        applyLivePreview()
        format_dialog:reinit()
    end

    page_filter_button.callback = function()
        if line_page_filter == nil then
            line_page_filter = "odd"
        elseif line_page_filter == "odd" then
            line_page_filter = "even"
        else
            line_page_filter = nil
        end
        applyLivePreview()
        format_dialog:reinit()
    end

    style_button.callback = function()
        local styles = self.STYLES
        for idx, s in ipairs(styles) do
            if s == line_style then
                line_style = styles[(idx % #styles) + 1]
                break
            end
        end
        applyLivePreview()
        format_dialog:reinit()
    end

    size_button.callback = function()
        local current = line_size or self:getPositionSetting(pos.key, "font_size")
        UIManager:show(SpinWidget:new{
            value = current,
            value_min = 8,
            value_max = 36,
            default_value = self:getPositionSetting(pos.key, "font_size"),
            title_text = _("Font size for line") .. " " .. line_idx,
            ok_text = _("Set"),
            callback = function(spin)
                line_size = spin.value
                applyLivePreview()
                format_dialog:reinit()
            end,
        })
    end

    font_button.callback = function()
        format_dialog:onCloseKeyboard()
        self:showFontPicker(line_face or self:getPositionSetting(pos.key, "font_face"), function(font_filename)
            line_face = font_filename
            applyLivePreview()
            format_dialog:reinit()
        end)
    end

    -- Nudge buttons (1px per tap)
    local nudge_step = 1
    local nudge_up = {
        text = "\xE2\x96\xB2",  -- ▲
        callback = function() end,
    }
    local nudge_down = {
        text = "\xE2\x96\xBC",  -- ▼
        callback = function() end,
    }
    local nudge_left = {
        text = "\xE2\x97\x80",  -- ◀
        callback = function() end,
    }
    local nudge_right = {
        text = "\xE2\x96\xB6",  -- ▶
        callback = function() end,
    }
    local nudge_label = {
        text_func = function()
            if line_v_nudge == 0 and line_h_nudge == 0 then
                return _("Position")
            end
            return line_h_nudge .. "," .. line_v_nudge
        end,
        callback = function() end,  -- reset, wired below
    }

    nudge_up.callback = function()
        format_dialog:onCloseKeyboard()
        line_v_nudge = line_v_nudge - nudge_step
        applyLivePreview()
        format_dialog:reinit()
    end
    nudge_down.callback = function()
        format_dialog:onCloseKeyboard()
        line_v_nudge = line_v_nudge + nudge_step
        applyLivePreview()
        format_dialog:reinit()
    end
    nudge_left.callback = function()
        format_dialog:onCloseKeyboard()
        line_h_nudge = line_h_nudge - nudge_step
        applyLivePreview()
        format_dialog:reinit()
    end
    nudge_right.callback = function()
        format_dialog:onCloseKeyboard()
        line_h_nudge = line_h_nudge + nudge_step
        applyLivePreview()
        format_dialog:reinit()
    end
    nudge_label.callback = function()
        format_dialog:onCloseKeyboard()
        line_v_nudge = 0
        line_h_nudge = 0
        applyLivePreview()
        format_dialog:reinit()
    end

    format_dialog = InputDialog:new{
        title = pos.label .. " \xE2\x80\x94 " .. _("Line") .. " " .. line_idx,
        input = current_text,
        edited_callback = function()
            -- Live preview of text changes (guard: fires during init before format_dialog is assigned)
            if not format_dialog then return end
            local live_text = format_dialog:getInputText()
            if live_text and live_text ~= "" then
                pos_settings.lines[line_idx] = live_text
                self:markDirty()
            end
        end,
        buttons = {
            -- Row 1: style controls
            { style_button, size_button, font_button, case_button, page_filter_button },
            -- Row 2: position nudge (L/R on left, label center, U/D on right)
            { nudge_left, nudge_right, nudge_label, nudge_up, nudge_down },
            -- Row 3: main actions
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        -- Restore all original settings
                        self.positions[pos.key] = util.tableDeepCopy(original_settings)
                        self:savePositionSetting(pos.key)
                        UIManager:close(format_dialog)
                        self:markDirty()
                    end,
                },
                {
                    text = _("Icons"),
                    callback = function()
                        format_dialog:onCloseKeyboard()
                        IconPicker:show(function(value)
                            format_dialog:addTextToInput(value)
                        end)
                    end,
                },
                {
                    text = _("Tokens"),
                    callback = function()
                        format_dialog:onCloseKeyboard()
                        self:showTokenPicker(function(token)
                            format_dialog:addTextToInput(token)
                        end)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_text = format_dialog:getInputText()
                        if new_text == "" then
                            -- Empty text: remove the line entirely
                            table.remove(pos_settings.lines, line_idx)
                            sparseRemove(pos_settings.line_style, line_idx)
                            sparseRemove(pos_settings.line_font_size, line_idx)
                            sparseRemove(pos_settings.line_font_face, line_idx)
                            sparseRemove(pos_settings.line_v_nudge, line_idx)
                            sparseRemove(pos_settings.line_h_nudge, line_idx)
                            sparseRemove(pos_settings.line_uppercase, line_idx)
                            sparseRemove(pos_settings.line_page_filter, line_idx)
                        else
                            -- Save the text (style/font/nudge already applied via live preview)
                            pos_settings.lines[line_idx] = new_text
                            applyLivePreview()
                        end
                        self:savePositionSetting(pos.key)
                        UIManager:close(format_dialog)
                        self:markDirty()
                    end,
                },
            },
        },
    }
    UIManager:show(format_dialog)
    format_dialog:onShowKeyboard()
end

function Bookends:showLineManageDialog(pos, line_idx, touchmenu_instance)

    local ps = self.positions[pos.key]
    local num_lines = #ps.lines


    local function refreshMenu()
        if touchmenu_instance then
            touchmenu_instance.item_table = self:buildPositionMenu(pos)
            touchmenu_instance:updateItems()
        end
    end

    local function removeLine()
        table.remove(ps.lines, line_idx)
        sparseRemove(ps.line_style, line_idx)
        sparseRemove(ps.line_font_size, line_idx)
        sparseRemove(ps.line_font_face, line_idx)
        sparseRemove(ps.line_v_nudge, line_idx)
        sparseRemove(ps.line_h_nudge, line_idx)
        sparseRemove(ps.line_uppercase, line_idx)
        sparseRemove(ps.line_page_filter, line_idx)
        self:savePositionSetting(pos.key)
        self:markDirty()
        refreshMenu()
    end

    local function swapLines(a, b)
        ps.lines[a], ps.lines[b] = ps.lines[b], ps.lines[a]
        if ps.line_style then
            ps.line_style[a], ps.line_style[b] = ps.line_style[b], ps.line_style[a]
        end
        if ps.line_font_size then
            ps.line_font_size[a], ps.line_font_size[b] = ps.line_font_size[b], ps.line_font_size[a]
        end
        if ps.line_font_face then
            ps.line_font_face[a], ps.line_font_face[b] = ps.line_font_face[b], ps.line_font_face[a]
        end
        if ps.line_v_nudge then
            ps.line_v_nudge[a], ps.line_v_nudge[b] = ps.line_v_nudge[b], ps.line_v_nudge[a]
        end
        if ps.line_h_nudge then
            ps.line_h_nudge[a], ps.line_h_nudge[b] = ps.line_h_nudge[b], ps.line_h_nudge[a]
        end
        if ps.line_uppercase then
            ps.line_uppercase[a], ps.line_uppercase[b] = ps.line_uppercase[b], ps.line_uppercase[a]
        end
        if ps.line_page_filter then
            ps.line_page_filter[a], ps.line_page_filter[b] = ps.line_page_filter[b], ps.line_page_filter[a]
        end
        self:savePositionSetting(pos.key)
        self:markDirty()
        refreshMenu()
    end

    local other_buttons = {}
    if line_idx > 1 then
        table.insert(other_buttons, {
            {
                text = _("Move up"),
                callback = function()
                    swapLines(line_idx, line_idx - 1)
                end,
            },
        })
    end
    if line_idx < num_lines then
        table.insert(other_buttons, {
            {
                text = _("Move down"),
                callback = function()
                    swapLines(line_idx, line_idx + 1)
                end,
            },
        })
    end

    -- Move to another region
    local function moveToRegion(target_key)
        local target = self.positions[target_key]
        target.lines = target.lines or {}
        target.line_style = target.line_style or {}
        target.line_font_size = target.line_font_size or {}
        target.line_font_face = target.line_font_face or {}
        target.line_v_nudge = target.line_v_nudge or {}
        target.line_h_nudge = target.line_h_nudge or {}
        target.line_uppercase = target.line_uppercase or {}

        -- Append to target
        local ti = #target.lines + 1
        target.lines[ti] = ps.lines[line_idx]
        target.line_style[ti] = ps.line_style and ps.line_style[line_idx] or nil
        target.line_font_size[ti] = ps.line_font_size and ps.line_font_size[line_idx] or nil
        target.line_font_face[ti] = ps.line_font_face and ps.line_font_face[line_idx] or nil
        target.line_v_nudge[ti] = ps.line_v_nudge and ps.line_v_nudge[line_idx] or nil
        target.line_h_nudge[ti] = ps.line_h_nudge and ps.line_h_nudge[line_idx] or nil
        target.line_uppercase[ti] = ps.line_uppercase and ps.line_uppercase[line_idx] or nil

        -- Remove from source
        removeLine()

        self:savePositionSetting(target_key)
    end

    -- Build "Move to" buttons — one row per available region (excluding current)
    for _i, p in ipairs(self.POSITIONS) do
        if p.key ~= pos.key then
            table.insert(other_buttons, {
                {
                    text = _("Move to") .. " " .. p.label,
                    callback = function()
                        moveToRegion(p.key)
                    end,
                },
            })
        end
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Line %1: %2"), line_idx, ps.lines[line_idx]),
        icon = "notice-question",
        ok_text = _("Delete"),
        ok_callback = function()
            removeLine()
        end,
        cancel_text = _("Cancel"),
        other_buttons_first = true,
        other_buttons = other_buttons,
    })
end

function Bookends:showFontPicker(current_face, on_select)
    local Menu = require("ui/widget/menu")
    local cre = require("document/credocument"):engineInit()
    local FontList = require("fontlist")
    local face_list = cre.getFontFaces()
    local items = {}
    for _, face_name in ipairs(face_list) do
        local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name)
        if not font_filename then
            font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name, nil, true)
        end
        if font_filename then
            local display_name = FontList:getLocalizedFontName(font_filename, font_faceindex) or face_name
            local prefix = (font_filename == current_face) and "\xE2\x9C\x93 " or "   " -- ✓
            table.insert(items, {
                text = prefix .. display_name,
                font_filename = font_filename,
            })
        end
    end

    local menu
    menu = Menu:new{
        title = _("Select font"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.8),
        height = math.floor(Screen:getHeight() * 0.8),
        onMenuChoice = function(_, item)
            UIManager:close(menu)
            if item.font_filename then
                on_select(item.font_filename)
            end
        end,
    }
    local x = math.floor((Screen:getWidth() - menu.dimen.w) / 2)
    local y = math.floor((Screen:getHeight() - menu.dimen.h) / 2)
    UIManager:show(menu, nil, nil, x, y)
end

-- ─── Token picker ────────────────────────────────────────

Bookends.TOKEN_CATALOG = {
    { _("Metadata"), {
        { "%T", _("Document title") },
        { "%A", _("Author(s)") },
        { "%S", _("Series with index") },
        { "%C", _("Chapter title") },
        { "%N", _("File name") },
        { "%i", _("Book language") },
        { "%o", _("Document format (EPUB, PDF, etc.)") },
        { "%q", _("Number of highlights") },
        { "%Q", _("Number of notes") },
        { "%x", _("Number of bookmarks") },
    }},
    { _("Page / Progress"), {
        { "%c", _("Current page number") },
        { "%t", _("Total pages") },
        { "%p", _("Book percentage read") },
        { "%P", _("Chapter percentage read") },
        { "%g", _("Pages read in chapter") },
        { "%G", _("Total pages in chapter") },
        { "%l", _("Pages left in chapter") },
        { "%L", _("Pages left in book") },
    }},
    { _("Time / Date"), {
        { "%k", _("12-hour clock") },
        { "%K", _("24-hour clock") },
        { "%d", _("Date short (28 Mar)") },
        { "%D", _("Date long (28 March 2026)") },
        { "%n", _("Date numeric (28/03/2026)") },
        { "%w", _("Weekday (Friday)") },
        { "%a", _("Weekday short (Fri)") },
    }},
    { _("Reading"), {
        { "%h", _("Time left in chapter") },
        { "%H", _("Time left in book") },
        { "%E", _("Total reading time for book") },
        { "%R", _("Session reading time") },
        { "%s", _("Session pages read") },
        { "%r", _("Reading speed (pages/hour)") },
    }},
    { _("Device"), {
        { "%b", _("Battery level") },
        { "%B", _("Battery icon (dynamic)") },
        { "%W", _("Wi-Fi icon (dynamic)") },
        { "%f", _("Frontlight brightness") },
        { "%F", _("Frontlight warmth") },
        { "%m", _("RAM used %") },
    }},
}

function Bookends:showTokenPicker(on_select)
    local Menu = require("ui/widget/menu")
    local items = {}
    for _, category in ipairs(self.TOKEN_CATALOG) do
        local label = category[1]
        local tokens = category[2]
        table.insert(items, {
            text = "\xE2\x94\x80\xE2\x94\x80 " .. label .. " \xE2\x94\x80\xE2\x94\x80",
            dim = true,
            callback = function() end,
        })
        for _, token_entry in ipairs(tokens) do
            table.insert(items, {
                text = token_entry[1] .. "  " .. token_entry[2],
                insert_value = token_entry[1],
            })
        end
    end

    local menu
    menu = Menu:new{
        title = _("Insert token"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.8),
        height = math.floor(Screen:getHeight() * 0.8),
        items_per_page = 14,
        onMenuChoice = function(_, item)
            if item.insert_value then
                UIManager:close(menu)
                on_select(item.insert_value)
            end
        end,
    }
    local x = math.floor((Screen:getWidth() - menu.dimen.w) / 2)
    local y = math.floor((Screen:getHeight() - menu.dimen.h) / 2)
    UIManager:show(menu, nil, nil, x, y)
end

-- ─── Helpers ─────────────────────────────────────────────

function Bookends:buildFontMenu(get_current, on_select)
    local cre = require("document/credocument"):engineInit()
    local FontList = require("fontlist")
    local face_list = cre.getFontFaces()
    local menu = {}
    for _, face_name in ipairs(face_list) do
        local font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name)
        if not font_filename then
            font_filename, font_faceindex = cre.getFontFaceFilenameAndFaceIndex(face_name, nil, true)
        end
        if font_filename then
            local display_name = FontList:getLocalizedFontName(font_filename, font_faceindex) or face_name
            table.insert(menu, {
                text = display_name,
                checked_func = function()
                    return get_current() == font_filename
                end,
                callback = function()
                    on_select(font_filename)
                end,
            })
        end
    end
    return menu
end

function Bookends:checkForUpdates()

    local DataStorage = require("datastorage")
    local meta = dofile("plugins/bookends.koplugin/_meta.lua")
    local installed_version = meta and meta.version or "unknown"

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is not enabled."),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Checking for updates..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        local http = require("socket/http")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")
        local json = require("json")

        local function githubGet(url)
            local body = {}
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local code = socket.skip(1, http.request({
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "KOReader-Bookends/" .. installed_version,
                    ["Accept"] = "application/vnd.github.v3+json",
                },
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            if code ~= 200 then return nil end
            local ok, data = pcall(json.decode, table.concat(body))
            return ok and data or nil
        end

        local function parseVersion(v)
            local parts = {}
            for part in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
                table.insert(parts, tonumber(part) or 0)
            end
            return parts
        end
        local function isNewer(v1, v2)
            local a, b = parseVersion(v1), parseVersion(v2)
            for i = 1, math.max(#a, #b) do
                local x, y = a[i] or 0, b[i] or 0
                if x > y then return true end
                if x < y then return false end
            end
            return false
        end

        -- Fetch all releases to gather notes between installed and latest
        local releases = githubGet("https://api.github.com/repos/AndyHazz/bookends.koplugin/releases")
        if not releases or #releases == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Could not check for updates."),
                timeout = 3,
            })
            return
        end

        -- Collect releases newer than installed version
        local new_releases = {}
        local latest_zip_url
        for _, rel in ipairs(releases) do
            if rel.draft or rel.prerelease then goto continue end
            local ver = rel.tag_name:gsub("^v", "")
            if isNewer(ver, installed_version) then
                table.insert(new_releases, rel)
                -- Find ZIP asset from the newest release
                if not latest_zip_url and rel.assets then
                    for _, asset in ipairs(rel.assets) do
                        if asset.name:match("%.zip$") then
                            latest_zip_url = asset.browser_download_url
                            break
                        end
                    end
                end
            end
            ::continue::
        end

        if #new_releases == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Bookends is up to date.") .. "\n\n" ..
                    _("Version: ") .. "v" .. installed_version,
                timeout = 3,
            })
            return
        end

        -- Build combined release notes (newest first)
        local latest_version = new_releases[1].tag_name:gsub("^v", "")
        local function stripMarkdown(text)
            text = text:gsub("#+%s*", "")        -- strip heading markers
            text = text:gsub("%*%*(.-)%*%*", "%1") -- strip bold
            text = text:gsub("%*(.-)%*", "%1")     -- strip italic
            text = text:gsub("`(.-)`", "%1")       -- strip inline code
            return text
        end
        local notes = {}
        for _, rel in ipairs(new_releases) do
            local header = "v" .. rel.tag_name:gsub("^v", "")
            local body = stripMarkdown(rel.body or "")
            table.insert(notes, header .. "\n" .. body)
        end
        local all_notes = table.concat(notes, "\n\n")

        local TextViewer = require("ui/widget/textviewer")
        local viewer
        local buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
                {
                    text = _("Update and restart"),
                    callback = function()
                        UIManager:close(viewer)
                        if not latest_zip_url then
                            UIManager:show(InfoMessage:new{
                                text = _("No download available for this release."),
                                timeout = 3,
                            })
                            return
                        end
                        self:installUpdate(latest_zip_url, installed_version, latest_version)
                    end,
                },
            },
        }
        viewer = TextViewer:new{
            title = _("Update available!"),
            text = _("Installed: ") .. "v" .. installed_version .. "\n" ..
                _("Latest: ") .. "v" .. latest_version .. "\n\n" ..
                all_notes,
            buttons_table = buttons,
            add_default_buttons = false,
        }
        UIManager:show(viewer)
    end)
end

function Bookends:installUpdate(zip_url, old_version, new_version)

    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    UIManager:show(InfoMessage:new{
        text = _("Downloading update..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        local http = require("socket/http")
        local ltn12 = require("ltn12")
        local socket = require("socket")
        local socketutil = require("socketutil")

        -- Download ZIP to temp location
        local cache_dir = DataStorage:getSettingsDir() .. "/bookends_cache"
        if lfs.attributes(cache_dir, "mode") ~= "directory" then
            lfs.mkdir(cache_dir)
        end
        local zip_path = cache_dir .. "/bookends.koplugin.zip"

        local file = io.open(zip_path, "wb")
        if not file then
            UIManager:show(InfoMessage:new{
                text = _("Could not save download."),
                timeout = 3,
            })
            return
        end

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code = socket.skip(1, http.request({
            url = zip_url,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-Bookends/" .. old_version,
            },
            sink = ltn12.sink.file(file),
            redirect = true,
        }))
        socketutil:reset_timeout()

        if code ~= 200 then
            pcall(os.remove, zip_path)
            UIManager:show(InfoMessage:new{
                text = _("Download failed."),
                timeout = 3,
            })
            return
        end

        -- Extract to plugin directory (strip root folder from ZIP)
        local plugin_path = DataStorage:getDataDir() .. "/plugins/bookends.koplugin"
        local ok, err = Device:unpackArchive(zip_path, plugin_path, true)
        pcall(os.remove, zip_path)

        if not ok then
            UIManager:show(InfoMessage:new{
                text = _("Installation failed: ") .. tostring(err),
                timeout = 5,
            })
            return
        end

        -- Restart KOReader to load the new version
    
        UIManager:show(ConfirmBox:new{
            text = _("Bookends updated to v") .. new_version .. ".\n\n" ..
                _("Restart KOReader now?"),
            ok_text = _("Restart"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        })
    end)
end

function Bookends:showNudgeDialog(pos, field, label)
    local pos_settings = self.positions[pos.key]
    local original = pos_settings[field]
    local dialog

    local function nudge(delta)
        local val = math.max(0, (pos_settings[field] or 0) + delta)
        pos_settings[field] = val > 0 and val or nil
        self:markDirty()
        dialog:reinit()
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    dialog = ButtonDialog:new{
        title = label,
        buttons = {
            {
                { text = "-10", callback = function() nudge(-10) end },
                { text = "-1", callback = function() nudge(-1) end },
                { text_func = function() return tostring(pos_settings[field] or 0) end, enabled = false },
                { text = "+1", callback = function() nudge(1) end },
                { text = "+10", callback = function() nudge(10) end },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        pos_settings[field] = original
                        self:markDirty()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        self:savePositionSetting(pos.key)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Bookends:showFontScaleDialog()
    local original = self.defaults.font_scale
    local dialog

    local function nudge(delta)
        self.defaults.font_scale = math.max(25, math.min(300, self.defaults.font_scale + delta))
        self:markDirty()
        dialog:reinit()
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    dialog = ButtonDialog:new{
        title = _("Font scale"),
        buttons = {
            {
                { text = "-10", callback = function() nudge(-10) end },
                { text = "-1", callback = function() nudge(-1) end },
                { text_func = function() return self.defaults.font_scale .. "%" end, enabled = false },
                { text = "+1", callback = function() nudge(1) end },
                { text = "+10", callback = function() nudge(10) end },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        self.defaults.font_scale = original
                        self:markDirty()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Reset"),
                    callback = function()
                        self.defaults.font_scale = 100
                        self:markDirty()
                        dialog:reinit()
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        G_reader_settings:saveSetting("bookends_font_scale", self.defaults.font_scale)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Bookends:showMarginAdjuster(touchmenu_instance)
    local original = {
        margin_top = self.defaults.margin_top,
        margin_bottom = self.defaults.margin_bottom,
        margin_left = self.defaults.margin_left,
        margin_right = self.defaults.margin_right,
    }

    local margin_dialog

    local function nudge(field, delta)
        self.defaults[field] = math.max(0, self.defaults[field] + delta)
        self:markDirty()
        margin_dialog:reinit()
    end

    local function makeRow(label, field)
        return {
            { text = "-10", callback = function() nudge(field, -10) end },
            { text = "-1", callback = function() nudge(field, -1) end },
            { text_func = function()
                return label .. ": " .. self.defaults[field]
            end, enabled = false },
            { text = "+1", callback = function() nudge(field, 1) end },
            { text = "+10", callback = function() nudge(field, 10) end },
        }
    end

    local buttons = {
        makeRow(_("Top"), "margin_top"),
        makeRow(_("Bottom"), "margin_bottom"),
        makeRow(_("Left"), "margin_left"),
        makeRow(_("Right"), "margin_right"),
        {
            {
                text = _("Cancel"),
                callback = function()
                    for k, v in pairs(original) do
                        self.defaults[k] = v
                    end
                    self:markDirty()
                    UIManager:close(margin_dialog)
                end,
            },
            {
                text = _("Reset"),
                callback = function()
                    self.defaults.margin_top = 10
                    self.defaults.margin_bottom = 25
                    self.defaults.margin_left = 18
                    self.defaults.margin_right = 18
                    self:markDirty()
                    margin_dialog:reinit()
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    G_reader_settings:saveSetting("bookends_margin_top", self.defaults.margin_top)
                    G_reader_settings:saveSetting("bookends_margin_bottom", self.defaults.margin_bottom)
                    G_reader_settings:saveSetting("bookends_margin_left", self.defaults.margin_left)
                    G_reader_settings:saveSetting("bookends_margin_right", self.defaults.margin_right)
                    UIManager:close(margin_dialog)
                end,
            },
        },
    }

    local ButtonDialog = require("ui/widget/buttondialog")
    margin_dialog = ButtonDialog:new{
        title = _("Adjust margins"),
        buttons = buttons,
    }
    UIManager:show(margin_dialog)
end

function Bookends:showSpinner(title, value, min, max, default, on_set)
    UIManager:show(SpinWidget:new{
        value = value,
        value_min = min,
        value_max = max,
        default_value = default,
        title_text = title,
        ok_text = _("Set"),
        callback = function(spin)
            on_set(spin.value)
        end,
    })
end

return Bookends
