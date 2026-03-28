local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen
local Tokens = require("tokens")
local OverlayWidget = require("overlay_widget")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")

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
    self.session_pages_read = 0
    self.session_last_page = nil
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
end

function Bookends:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = G_reader_settings:readSetting("bookends_enabled", false)

    self.defaults = {
        font_face = G_reader_settings:readSetting("bookends_font_face", Font.fontmap["ffont"]),
        font_size = G_reader_settings:readSetting("bookends_font_size", footer_settings.text_font_size),
        font_bold = G_reader_settings:readSetting("bookends_font_bold", false),
        v_offset  = G_reader_settings:readSetting("bookends_v_offset", 35),
        h_offset  = G_reader_settings:readSetting("bookends_h_offset", 10),
        overlap_gap = G_reader_settings:readSetting("bookends_overlap_gap", 10),
    }

    -- Per-position settings
    -- Migrate old single-format to lines array
    self.positions = {}
    for _, pos in ipairs(self.POSITIONS) do
        local saved = G_reader_settings:readSetting("bookends_pos_" .. pos.key, {})
        -- Migration: old format string → lines array
        if saved.format and saved.format ~= "" and not saved.lines then
            saved.lines = { saved.format }
            saved.format = nil
        end
        if not saved.lines then
            saved.lines = {}
        end
        self.positions[pos.key] = saved
    end
end

function Bookends:buildPreset()
    local util = require("util")
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
    local util = require("util")
    if preset.enabled ~= nil then
        self.enabled = preset.enabled
        G_reader_settings:saveSetting("bookends_enabled", self.enabled)
    end
    if preset.defaults then
        self.defaults = util.tableDeepCopy(preset.defaults)
        G_reader_settings:saveSetting("bookends_font_face", self.defaults.font_face)
        G_reader_settings:saveSetting("bookends_font_size", self.defaults.font_size)
        G_reader_settings:saveSetting("bookends_font_bold", self.defaults.font_bold)
        G_reader_settings:saveSetting("bookends_v_offset", self.defaults.v_offset)
        G_reader_settings:saveSetting("bookends_h_offset", self.defaults.h_offset)
        G_reader_settings:saveSetting("bookends_overlap_gap", self.defaults.overlap_gap)
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
    return self.defaults[field]
end

function Bookends:isPositionActive(key)
    return self.enabled and #self.positions[key].lines > 0
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

-- Map a regular font filename to its italic variant (and vice versa)
local _italic_variants = {
    ["NotoSans-Regular.ttf"]  = "NotoSans-Italic.ttf",
    ["NotoSans-Bold.ttf"]     = "NotoSans-BoldItalic.ttf",
    ["NotoSerif-Regular.ttf"] = "NotoSerif-Italic.ttf",
    ["NotoSerif-Bold.ttf"]    = "NotoSerif-BoldItalic.ttf",
}

function Bookends:resolveLineConfig(face_name, font_size, style)
    style = style or "regular"
    local bold = (style == "bold" or style == "bolditalic")
    local resolved_face = face_name

    if style == "italic" or style == "bolditalic" then
        -- Try to find italic variant
        local italic = _italic_variants[face_name]
        if italic then
            resolved_face = italic
        end
    end

    return {
        face = Font:getFace(resolved_face, font_size),
        bold = bold,
    }
end

-- Event handlers
function Bookends:onPageUpdate()
    local current = self.ui.view.state.page
    if current and self.session_last_page then
        -- Count only forward page turns (not going back)
        if current > self.session_last_page then
            self.session_pages_read = self.session_pages_read + (current - self.session_last_page)
        end
    end
    self.session_last_page = current
    self:markDirty()
end
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
    -- Join lines with \n, then expand tokens
    local expanded = {}
    for _, pos in ipairs(self.POSITIONS) do
        if self:isPositionActive(pos.key) then
            local lines = self.positions[pos.key].lines
            local joined = table.concat(lines, "\n")
            expanded[pos.key] = Tokens.expand(joined, self.ui, self.session_start_time, self.session_pages_read)
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

    -- Phase 2: Build per-line rendering configs and measure
    local measurements = {}
    for key, text in pairs(expanded) do
        local pos_settings = self.positions[key]
        local default_face_name = self:getPositionSetting(key, "font_face")
        local default_font_size = self:getPositionSetting(key, "font_size")
        local default_bold = self:getPositionSetting(key, "font_bold")

        -- Build per-line config: { {face=, bold=, smallcaps=}, ... }
        local line_configs = {}
        for i = 1, #pos_settings.lines do
            local face_name = (pos_settings.line_font_face and pos_settings.line_font_face[i])
                or default_face_name
            local font_size = (pos_settings.line_font_size and pos_settings.line_font_size[i])
                or default_font_size
            local style = (pos_settings.line_style and pos_settings.line_style[i])
                or "regular"
            table.insert(line_configs, self:resolveLineConfig(face_name, font_size, style))
        end

        local w = OverlayWidget.measureTextWidth(text, line_configs)
        measurements[key] = { width = w, line_configs = line_configs }
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

        local left_w = measurements[left_key] and measurements[left_key].width or nil
        local center_w = measurements[center_key] and measurements[center_key].width or nil
        local right_w = measurements[right_key] and measurements[right_key].width or nil

        local left_h_offset = self:getPositionSetting(left_key, "h_offset")
        local right_h_offset = self:getPositionSetting(right_key, "h_offset")
        local max_h_offset = math.max(left_h_offset or 0, right_h_offset or 0)

        local limits = OverlayWidget.calculateRowLimits(
            left_w, center_w, right_w, screen_w, gap, max_h_offset)

        -- Phase 4: Build widgets with truncation limits
        local row_keys = {
            { key = left_key, limit_key = "left" },
            { key = center_key, limit_key = "center" },
            { key = right_key, limit_key = "right" },
        }
        for _, rk in ipairs(row_keys) do
            local key = rk.key
            if expanded[key] then
                local m = measurements[key]
                local pos_def
                for _, p in ipairs(self.POSITIONS) do
                    if p.key == key then pos_def = p; break end
                end

                local max_width = limits[rk.limit_key]
                local widget, w, h = OverlayWidget.buildTextWidget(
                    expanded[key], m.line_configs, pos_def.h_anchor, max_width)

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
                else
                    -- Expand tokens for preview
                    local preview = Tokens.expandPreview(lines[1], self.ui, self.session_start_time, self.session_pages_read)
                    if #lines > 1 then
                        preview = preview .. " ..."
                    end
                    if #preview > 40 then
                        preview = preview:sub(1, 37) .. "..."
                    end
                    return pos.label .. ": " .. preview
                end
            end,
            enabled_func = function() return self.enabled end,
            sub_item_table_func = function()
                return self:buildPositionMenu(pos)
            end,
        })
    end

    -- Separator
    table.insert(menu, {
        text = "\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80",
        enabled_func = function() return false end,
    })

    -- Global defaults
    table.insert(menu, {
        text = _("Default font"),
        enabled_func = function() return self.enabled end,
        sub_item_table = self:buildFontMenu(function() return self.defaults.font_face end,
            function(face)
                self.defaults.font_face = face
                G_reader_settings:saveSetting("bookends_font_face", face)
                self:markDirty()
            end),
    })
    table.insert(menu, {
        text = _("Default font size"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Default font size"), self.defaults.font_size, 8, 36,
                self.ui.view.footer.settings.text_font_size,
                function(val)
                    self.defaults.font_size = val
                    G_reader_settings:saveSetting("bookends_font_size", val)
                    self:markDirty()
                end)
        end,
    })
    table.insert(menu, {
        text = _("Default vertical offset"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Default vertical offset (px)"), self.defaults.v_offset, 0, 200, 35,
                function(val)
                    self.defaults.v_offset = val
                    G_reader_settings:saveSetting("bookends_v_offset", val)
                    self:markDirty()
                end)
        end,
    })
    table.insert(menu, {
        text = _("Default horizontal offset"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Default horizontal offset (px)"), self.defaults.h_offset, 0, 200, 10,
                function(val)
                    self.defaults.h_offset = val
                    G_reader_settings:saveSetting("bookends_h_offset", val)
                    self:markDirty()
                end)
        end,
    })
    table.insert(menu, {
        text = _("Overlap gap"),
        keep_menu_open = true,
        enabled_func = function() return self.enabled end,
        callback = function()
            self:showSpinner(_("Minimum gap between texts (px)"), self.defaults.overlap_gap, 0, 100, 10,
                function(val)
                    self.defaults.overlap_gap = val
                    G_reader_settings:saveSetting("bookends_overlap_gap", val)
                    self:markDirty()
                end)
        end,
    })

    -- Presets
    table.insert(menu, {
        text = "\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80",
        enabled_func = function() return false end,
    })
    table.insert(menu, {
        text = _("Presets"),
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            local Presets = require("ui/presets")
            return Presets.genPresetMenuItemTable(self.preset_obj)
        end,
    })

    return menu
end

function Bookends:buildPositionMenu(pos)
    local is_corner = pos.h_anchor ~= "center"
    local menu = {}
    local lines = self.positions[pos.key].lines

    -- Line entries (no keep_menu_open so menu refreshes after editing)
    for i, line in ipairs(lines) do
        table.insert(menu, {
            text_func = function()
                local preview = Tokens.expandPreview(self.positions[pos.key].lines[i] or "", self.ui, self.session_start_time, self.session_pages_read)
                if #preview > 45 then
                    preview = preview:sub(1, 42) .. "..."
                end
                return _("Line") .. " " .. i .. ": " .. preview
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
        text = _("Add line"),
        callback = function()
            local idx = #self.positions[pos.key].lines + 1
            table.insert(self.positions[pos.key].lines, "")
            self:savePositionSetting(pos.key)
            self:editLineString(pos, idx)
        end,
    })

    -- Separator
    table.insert(menu, {
        text = "\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80",
        enabled_func = function() return false end,
    })

    -- Per-position overrides (offsets only — font/size/style are per-line)
    table.insert(menu, {
        text_func = function()
            if self.positions[pos.key].v_offset then
                return _("Override vertical offset") .. " (" .. self.positions[pos.key].v_offset .. ")"
            end
            return _("Override vertical offset")
        end,
        keep_menu_open = true,
        callback = function()
            self:showSpinner(_("Vertical offset for " .. pos.label),
                self:getPositionSetting(pos.key, "v_offset"), 0, 200,
                self.defaults.v_offset,
                function(val)
                    self.positions[pos.key].v_offset = val
                    self:savePositionSetting(pos.key)
                    self:markDirty()
                end)
        end,
    })

    if is_corner then
        table.insert(menu, {
            text_func = function()
                if self.positions[pos.key].h_offset then
                    return _("Override horizontal offset") .. " (" .. self.positions[pos.key].h_offset .. ")"
                end
                return _("Override horizontal offset")
            end,
            keep_menu_open = true,
            callback = function()
                self:showSpinner(_("Horizontal offset for " .. pos.label),
                    self:getPositionSetting(pos.key, "h_offset"), 0, 200,
                    self.defaults.h_offset,
                    function(val)
                        self.positions[pos.key].h_offset = val
                        self:savePositionSetting(pos.key)
                        self:markDirty()
                    end)
            end,
        })
    end

    table.insert(menu, {
        text = _("Reset all overrides"),
        callback = function()
            local lines_copy = self.positions[pos.key].lines
            self.positions[pos.key] = { lines = lines_copy }
            self:savePositionSetting(pos.key)
            self:markDirty()
        end,
    })

    return menu
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

    local line_style = pos_settings.line_style[line_idx] or "regular"
    local line_size = pos_settings.line_font_size[line_idx] -- nil = use default
    local line_face = pos_settings.line_font_face[line_idx] -- nil = use default

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

    local format_dialog

    style_button.callback = function()
        -- Cycle through styles
        local styles = self.STYLES
        for idx, s in ipairs(styles) do
            if s == line_style then
                line_style = styles[(idx % #styles) + 1]
                break
            end
        end
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
                format_dialog:reinit()
            end,
        })
    end

    font_button.callback = function()
        format_dialog:onCloseKeyboard()
        self:showFontPicker(line_face or self:getPositionSetting(pos.key, "font_face"), function(font_filename)
            line_face = font_filename
            format_dialog:reinit()
        end)
    end

    format_dialog = InputDialog:new{
        title = pos.label .. " \xE2\x80\x94 " .. _("Line") .. " " .. line_idx,
        input = current_text,
        buttons = {
            -- Row 1: style controls
            { style_button, size_button, font_button },
            -- Row 2: main actions
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        -- Restore original text if this was an edit (not a new line)
                        if current_text ~= "" then
                            pos_settings.lines[line_idx] = current_text
                            self:savePositionSetting(pos.key)
                        else
                            -- New empty line: remove it
                            table.remove(pos_settings.lines, line_idx)
                            if pos_settings.line_style then table.remove(pos_settings.line_style, line_idx) end
                            if pos_settings.line_font_size then table.remove(pos_settings.line_font_size, line_idx) end
                            if pos_settings.line_font_face then table.remove(pos_settings.line_font_face, line_idx) end
                            self:savePositionSetting(pos.key)
                        end
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
                            table.remove(pos_settings.lines, line_idx)
                            if pos_settings.line_style then table.remove(pos_settings.line_style, line_idx) end
                            if pos_settings.line_font_size then table.remove(pos_settings.line_font_size, line_idx) end
                            if pos_settings.line_font_face then table.remove(pos_settings.line_font_face, line_idx) end
                        else
                            pos_settings.lines[line_idx] = new_text
                            pos_settings.line_style = pos_settings.line_style or {}
                            pos_settings.line_style[line_idx] = line_style ~= "regular" and line_style or nil
                            pos_settings.line_font_size[line_idx] = line_size
                            pos_settings.line_font_face[line_idx] = line_face
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
    local ConfirmBox = require("ui/widget/confirmbox")
    local ps = self.positions[pos.key]
    local num_lines = #ps.lines
    local T = require("ffi/util").template

    local function refreshMenu()
        if touchmenu_instance then
            touchmenu_instance.item_table = self:buildPositionMenu(pos)
            touchmenu_instance:updateItems()
        end
    end

    local function removeLine()
        table.remove(ps.lines, line_idx)
        if ps.line_style then table.remove(ps.line_style, line_idx) end
        if ps.line_font_size then table.remove(ps.line_font_size, line_idx) end
        if ps.line_font_face then table.remove(ps.line_font_face, line_idx) end
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
        { "%R", _("Session reading time") },
        { "%s", _("Session pages read") },
    }},
    { _("Device"), {
        { "%b", _("Battery level") },
        { "%B", _("Battery icon (dynamic)") },
        { "%W", _("Wi-Fi icon (dynamic)") },
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
