local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local OverlayWidget = require("overlay_widget")
local Tokens = require("tokens")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("i18n").gettext
local Screen = Device.screen
local T = require("ffi/util").template

--- Show an error on-screen and log it, instead of crashing.
local _error_dialog_shown = false
local function bookends_error(context, err)
    local tb = debug.traceback(tostring(err), 2)
    local msg = "Bookends error in " .. context .. ":\n" .. tb
    -- Log to stderr (appears in crash.log on next launch)
    io.stderr:write(msg .. "\n")
    -- Show only one error dialog at a time
    if _error_dialog_shown then return end
    _error_dialog_shown = true
    UIManager:scheduleIn(0, function()
        UIManager:show(ConfirmBox:new{
            text = msg,
            icon = "notice-warning",
            ok_text = _("Restart"),
            cancel_text = _("Dismiss"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
            cancel_callback = function()
                _error_dialog_shown = false
            end,
            other_buttons_first = true,
        })
    end)
end

--- Wrap a function with error handling; on error show message instead of crash.
local function safe(context, fn)
    return function(...)
        local ok, result = xpcall(fn, debug.traceback, ...)
        if not ok then
            bookends_error(context, result)
            return true  -- still consume the event to prevent propagation
        end
        return result
    end
end

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
    -- Install custom icons (chevron.down) into KOReader's user icons dir
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local icons_dst = DataStorage:getDataDir() .. "/icons"
    if lfs.attributes(icons_dst, "mode") ~= "directory" then
        lfs.mkdir(icons_dst)
    end
    local plugin_icons = self.path .. "/icons"
    if lfs.attributes(plugin_icons, "mode") == "directory" then
        for f in lfs.dir(plugin_icons) do
            if f:match("%.svg$") then
                local src = plugin_icons .. "/" .. f
                local dst = icons_dst .. "/" .. f
                if lfs.attributes(dst, "mode") ~= "file" then
                    local fin = io.open(src, "r")
                    if fin then
                        local fout = io.open(dst, "w")
                        if fout then
                            fout:write(fin:read("*a"))
                            fout:close()
                        end
                        fin:close()
                    end
                end
            end
        end
    end

    self:openSettings()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self.ui.view:registerViewModule("bookends", self)
    self.session_elapsed = 0
    self.session_resume_time = os.time()
    self.session_start_page = nil -- set on first onPageUpdate (stable or raw per setting)
    self.session_max_page = nil   -- highest page reached (stable or raw per setting)
    self.dirty = true
    self.position_cache = {}

    -- Migrate embedded presets to individual files (one-time)
    self:migratePresetsToFiles()

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
    Dispatcher:registerAction("cycle_bookends_preset", {
        category = "none",
        event = "CycleBookendsPreset",
        title = _("Cycle bookends preset"),
        reader = true,
    })
    Dispatcher:registerAction("set_bookends", {
        category = "string",
        event = "SetBookends",
        title = _("Set bookends"),
        reader = true,
        args = {true, false},
        toggle = {_("on"), _("off")},
    })
end

function Bookends:onToggleBookends()
    self.enabled = not self.enabled
    self.settings:saveSetting("enabled", self.enabled)
    self:markDirty()
    return true
end

function Bookends:onSetBookends(new_state)
    self.enabled = new_state
    self.settings:saveSetting("enabled", self.enabled)
    self:markDirty()
    return true
end

function Bookends:onCycleBookendsPreset()
    local presets = self:readPresetFiles()
    if #presets == 0 then return true end

    local idx = 1
    local last = self.settings:readSetting("last_cycled_preset")
    if last then
        for i, entry in ipairs(presets) do
            if entry.name == last then
                idx = (i % #presets) + 1
                break
            end
        end
    end

    self.settings:saveSetting("last_cycled_preset", presets[idx].name)
    local ok, err = pcall(self.loadPreset, self, presets[idx].preset)
    if not ok then
        local Notification = require("ui/widget/notification")
        Notification:notify(T(_("Preset error: %1"), tostring(err)))
    end
    self:markDirty()
    return true
end

function Bookends:openSettings()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local settings_path = DataStorage:getSettingsDir() .. "/bookends.lua"
    self.settings = LuaSettings:open(settings_path)

    -- One-time migration from G_reader_settings
    if not self.settings:has("migrated") then
        local old_keys = {
            "enabled", "font_face", "font_size", "font_bold", "font_scale",
            "margin_top", "margin_bottom", "margin_left", "margin_right",
            "overlap_gap", "truncation_priority", "presets", "last_cycled_preset",
        }
        for _, key in ipairs(old_keys) do
            local val = G_reader_settings:readSetting("bookends_" .. key)
            if val ~= nil then
                self.settings:saveSetting(key, val)
                G_reader_settings:delSetting("bookends_" .. key)
            end
        end
        for _, pos in ipairs(self.POSITIONS) do
            local val = G_reader_settings:readSetting("bookends_pos_" .. pos.key)
            if val ~= nil then
                self.settings:saveSetting("pos_" .. pos.key, val)
                G_reader_settings:delSetting("bookends_pos_" .. pos.key)
            end
        end
        self.settings:saveSetting("migrated", true)
        self.settings:flush()
    end
end

function Bookends:loadSettings()
    local footer_settings = self.ui.view.footer.settings
    self.enabled = self.settings:readSetting("enabled", false)
    self.defaults = {
        font_face = self.settings:readSetting("font_face", Font.fontmap["ffont"]),
        font_size = self.settings:readSetting("font_size", footer_settings.text_font_size),
        font_bold = self.settings:readSetting("font_bold", false),
        margin_top    = self.settings:readSetting("margin_top", 10),
        margin_bottom = self.settings:readSetting("margin_bottom", 25),
        margin_left   = self.settings:readSetting("margin_left", 18),
        margin_right  = self.settings:readSetting("margin_right", 18),
        font_scale = self.settings:readSetting("font_scale", 100),
        overlap_gap = self.settings:readSetting("overlap_gap", 50),
        truncation_priority = self.settings:readSetting("truncation_priority", "center"),
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
        local saved = self.settings:readSetting("pos_" .. pos.key)
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

    -- Full-width progress bars
    local bar_defaults = {
        enabled = false, type = "book", style = "solid", height = 20,
        v_anchor = "bottom", margin_v = 0, margin_left = 0, margin_right = 0,
        chapter_ticks = "off",
    }
    self.progress_bars = {}
    for i = 1, 4 do
        local default = util.tableDeepCopy(bar_defaults)
        if i == 1 then default.chapter_ticks = "all" end
        if i == 2 then default.type = "chapter" end
        self.progress_bars[i] = self.settings:readSetting("progress_bar_" .. i, default)
    end
end

function Bookends:buildPreset()

    local preset = {
        enabled = self.enabled,
        defaults = util.tableDeepCopy(self.defaults),
        positions = {},
    }
    -- Exclude default font so presets adapt to the user's installed font
    preset.defaults.font_face = nil
    for _, pos in ipairs(self.POSITIONS) do
        preset.positions[pos.key] = util.tableDeepCopy(self.positions[pos.key])
    end
    preset.progress_bars = util.tableDeepCopy(self.progress_bars)
    preset.bar_colors = self.settings:readSetting("bar_colors")
    preset.tick_width_multiplier = self.settings:readSetting("tick_width_multiplier")
    preset.tick_height_pct = self.settings:readSetting("tick_height_pct")
    return preset
end

function Bookends:loadPreset(preset)

    if preset.enabled ~= nil then
        self.enabled = preset.enabled
        self.settings:saveSetting("enabled", self.enabled)
    end
    if preset.defaults then
        local pd = preset.defaults
        -- Ignore old v_offset/h_offset keys from pre-v2 presets
        pd.v_offset = nil
        pd.h_offset = nil
        -- Never override the user's default font from a preset
        pd.font_face = nil
        -- Reset margins before applying preset values
        self.defaults.margin_top = 10
        self.defaults.margin_bottom = 25
        self.defaults.margin_left = 18
        self.defaults.margin_right = 18
        for k, v in pairs(pd) do
            self.defaults[k] = v
        end
        self.settings:saveSetting("font_face", self.defaults.font_face)
        self.settings:saveSetting("font_size", self.defaults.font_size)
        self.settings:saveSetting("font_bold", self.defaults.font_bold)
        self.settings:saveSetting("font_scale", self.defaults.font_scale)
        self.settings:saveSetting("margin_top", self.defaults.margin_top)
        self.settings:saveSetting("margin_bottom", self.defaults.margin_bottom)
        self.settings:saveSetting("margin_left", self.defaults.margin_left)
        self.settings:saveSetting("margin_right", self.defaults.margin_right)
        self.settings:saveSetting("overlap_gap", self.defaults.overlap_gap)
        self.settings:saveSetting("truncation_priority", self.defaults.truncation_priority)
    end
    if preset.positions then
        for _, pos in ipairs(self.POSITIONS) do
            if preset.positions[pos.key] then
                self.positions[pos.key] = util.tableDeepCopy(preset.positions[pos.key])
                self:savePositionSetting(pos.key)
            end
        end
    end
    local bar_defaults = {
        enabled = false, type = "book", style = "solid", height = 20,
        v_anchor = "bottom", margin_v = 0, margin_left = 0, margin_right = 0,
        chapter_ticks = "off",
    }
    if preset.progress_bars then
        self.progress_bars = util.tableDeepCopy(preset.progress_bars)
    else
        self.progress_bars = {}
    end
    -- Always ensure exactly 4 bar slots exist
    for i = 1, 4 do
        if not self.progress_bars[i] then
            self.progress_bars[i] = util.tableDeepCopy(bar_defaults)
        end
    end
    for i = 1, 4 do
        self.settings:saveSetting("progress_bar_" .. i, self.progress_bars[i])
    end
    if preset.bar_colors then
        self.settings:saveSetting("bar_colors", preset.bar_colors)
    else
        self.settings:delSetting("bar_colors")
    end
    if preset.tick_width_multiplier then
        self.settings:saveSetting("tick_width_multiplier", preset.tick_width_multiplier)
    else
        self.settings:delSetting("tick_width_multiplier")
    end
    if preset.tick_height_pct then
        self.settings:saveSetting("tick_height_pct", preset.tick_height_pct)
    else
        self.settings:delSetting("tick_height_pct")
    end
    self._tick_cache = nil
    self:markDirty()
end

function Bookends:presetDir()
    if not self._preset_dir then
        local DataStorage = require("datastorage")
        self._preset_dir = DataStorage:getSettingsDir() .. "/bookends_presets"
    end
    return self._preset_dir
end

function Bookends:sanitizePresetFilename(name)
    local sanitized = name:lower()
        :gsub("[^%w_]", "_")
        :gsub("_+", "_")
        :gsub("^_", "")
        :gsub("_$", "")
    if sanitized == "" then sanitized = "preset" end
    return sanitized .. ".lua"
end

function Bookends.serializeTable(tbl, indent)
    indent = indent or ""
    local next_indent = indent .. "    "
    local parts = {}
    table.insert(parts, "{\n")

    local int_keys = {}
    local str_keys = {}
    for k in pairs(tbl) do
        if type(k) == "number" and k == math.floor(k) and k >= 1 then
            table.insert(int_keys, k)
        else
            table.insert(str_keys, tostring(k))
        end
    end
    table.sort(int_keys)
    table.sort(str_keys)

    local function serializeValue(v)
        if type(v) == "table" then
            return Bookends.serializeTable(v, next_indent)
        elseif type(v) == "string" then
            return string.format("%q", v)
        elseif type(v) == "boolean" then
            return tostring(v)
        elseif type(v) == "number" then
            return tostring(v)
        else
            return string.format("%q", tostring(v))
        end
    end

    -- Detect sparse integer arrays (gaps in keys) — must use explicit [N] = syntax
    local is_contiguous = #int_keys > 0 and int_keys[#int_keys] == #int_keys
    for _, k in ipairs(int_keys) do
        if is_contiguous then
            table.insert(parts, next_indent .. serializeValue(tbl[k]) .. ",\n")
        else
            table.insert(parts, next_indent .. "[" .. k .. "] = " .. serializeValue(tbl[k]) .. ",\n")
        end
    end
    for _, k in ipairs(str_keys) do
        local key_str
        if k:match("^[%a_][%w_]*$") then
            key_str = k
        else
            key_str = string.format("[%q]", k)
        end
        table.insert(parts, next_indent .. key_str .. " = " .. serializeValue(tbl[k]) .. ",\n")
    end

    table.insert(parts, indent .. "}")
    return table.concat(parts)
end

function Bookends:ensurePresetDir()
    local lfs = require("libs/libkoreader-lfs")
    local dir = self:presetDir()
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

--- Load a preset .lua file in a sandboxed environment.
--- The file can only return a plain data table — no access to os, io, require, etc.
function Bookends.loadPresetFile(path)
    local fn, err = loadfile(path)
    if not fn then return nil, "parse error: " .. tostring(err) end

    -- Sandbox: empty environment — only basic value types and table constructors work
    setfenv(fn, {})

    local ok, result = pcall(fn)
    if not ok then return nil, "runtime error: " .. tostring(result) end
    if type(result) ~= "table" then return nil, "expected table, got " .. type(result) end
    return result
end

--- Validate that a preset table has the expected structure.
--- Returns the (possibly cleaned) table, or nil + error string.
function Bookends.validatePreset(data)
    -- Allow only known top-level keys (ignore unknown ones silently for forward compat)
    local EXPECTED_TYPES = {
        name = "string",
        enabled = "boolean",
        defaults = "table",
        positions = "table",
        progress_bars = "table",
        bar_colors = "table",
        tick_width_multiplier = "number",
        tick_height_pct = "number",
    }

    for key, val in pairs(data) do
        local expected = EXPECTED_TYPES[key]
        if expected and type(val) ~= expected then
            return nil, "field '" .. key .. "' should be " .. expected .. ", got " .. type(val)
        end
    end

    -- Validate positions keys if present
    if data.positions then
        local VALID_POS = { tl=true, tc=true, tr=true, bl=true, bc=true, br=true }
        for key, val in pairs(data.positions) do
            if not VALID_POS[key] then
                return nil, "unknown position key: " .. tostring(key)
            end
            if type(val) ~= "table" then
                return nil, "position '" .. key .. "' should be table, got " .. type(val)
            end
            -- Each position must have a lines array
            if val.lines and type(val.lines) ~= "table" then
                return nil, "position '" .. key .. "'.lines should be table"
            end
        end
    end

    return data
end

function Bookends:readPresetFiles()
    local lfs = require("libs/libkoreader-lfs")
    local logger = require("logger")
    local dir = self:presetDir()
    local presets = {}

    if lfs.attributes(dir, "mode") ~= "directory" then
        return presets
    end

    for f in lfs.dir(dir) do
        if f:match("%.lua$") then
            local path = dir .. "/" .. f
            local data, err = Bookends.loadPresetFile(path)
            if not data then
                logger.warn("bookends: skipping preset", f, "—", err)
            else
                data, err = Bookends.validatePreset(data)
                if not data then
                    logger.warn("bookends: invalid preset", f, "—", err)
                else
                    local name = data.name or f:gsub("%.lua$", ""):gsub("_", " ")
                    table.insert(presets, {
                        name = name,
                        filename = f,
                        preset = data,
                    })
                end
            end
        end
    end

    table.sort(presets, function(a, b) return a.name < b.name end)
    return presets
end

function Bookends:writePresetFile(name, preset_data)
    local dir = self:ensurePresetDir()
    local lfs = require("libs/libkoreader-lfs")

    preset_data.name = name

    local base = self:sanitizePresetFilename(name)
    local filename = base
    local counter = 2
    while lfs.attributes(dir .. "/" .. filename, "mode") == "file" do
        filename = base:gsub("%.lua$", "_" .. counter .. ".lua")
        counter = counter + 1
    end

    local path = dir .. "/" .. filename
    local fout = io.open(path, "w")
    if fout then
        fout:write("-- Bookends preset: " .. name .. "\n")
        fout:write("return " .. Bookends.serializeTable(preset_data) .. "\n")
        fout:close()
    end
    return filename
end

function Bookends:deletePresetFile(filename)
    local path = self:presetDir() .. "/" .. filename
    os.remove(path)
end

function Bookends:renamePresetFile(old_filename, new_name)
    local dir = self:presetDir()
    local old_path = dir .. "/" .. old_filename

    local data = Bookends.loadPresetFile(old_path)
    if not data then return nil end

    local new_filename = self:writePresetFile(new_name, data)

    if new_filename ~= old_filename then
        os.remove(old_path)
    end

    return new_filename
end

function Bookends:updatePresetFile(filename, name)
    local dir = self:presetDir()
    local path = dir .. "/" .. filename
    local preset_data = self:buildPreset()
    preset_data.name = name

    local fout = io.open(path, "w")
    if fout then
        fout:write("-- Bookends preset: " .. name .. "\n")
        fout:write("return " .. Bookends.serializeTable(preset_data) .. "\n")
        fout:close()
    end
end

function Bookends:migratePresetsToFiles()
    local embedded = self.settings:readSetting("presets")
    if not embedded or not next(embedded) then return end

    self:ensurePresetDir()

    for name, preset_data in pairs(embedded) do
        self:writePresetFile(name, preset_data)
    end

    self.settings:delSetting("presets")
    self.settings:delSetting("last_cycled_preset")
    self.settings:flush()
end

function Bookends:savePositionSetting(key)
    self.settings:saveSetting("pos_" .. key, self.positions[key])
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

function Bookends:markDirty(refresh_mode)
    self.dirty = true
    self._tick_cache = nil
    if not self._error_disabled then
        self.enabled = self.settings:isTrue("enabled")
    end
    -- Debounce: coalesce multiple markDirty calls within the same tick.
    -- Skip if a KOReader paint cycle already consumed the dirty flag.
    if not self._repaint_scheduled then
        self._repaint_scheduled = true
        local mode = refresh_mode or "ui"
        UIManager:nextTick(function()
            self._repaint_scheduled = false
            if self.dirty then
                UIManager:setDirty(self.ui, mode)
            end
        end)
    end
end

--- Compute chapter tick fractions for book progress bars (cached per dirty cycle).
function Bookends:_computeTickCache()
    local doc = self.ui.document
    if not doc or not self.ui.toc then return {} end
    local raw_total = doc:getPageCount()
    if not raw_total or raw_total <= 0 then return {} end
    local toc_ticks = self.ui.toc:getTocTicks() or {}
    local max_depth = self.ui.toc:getMaxDepth() or 1
    local ticks = {}
    -- Use page-based fractions (matches KOReader's footer progress bar)
    for depth, pages in ipairs(toc_ticks) do
        local tick_m = self.settings:readSetting("tick_width_multiplier", 2)
        local tick_w = math.max(1, (max_depth - depth + 1) * tick_m - 1)
        for _, page in ipairs(pages) do
            if page > 1 then
                local tick_frac = page / raw_total
                if tick_frac > 0 and tick_frac < 1 then
                    table.insert(ticks, { tick_frac, tick_w, depth })
                end
            end
        end
    end
    return ticks
end

-- Style constants and helpers
Bookends.STYLES = { "regular", "bold", "italic", "bolditalic" }
Bookends.STYLE_LABELS = {
    regular = _("Regular"),
    bold = _("Bold"),
    italic = _("Italic"),
    bolditalic = _("Bold italic"),
}

function Bookends:resolveLineConfig(face_name, font_size, style)
    style = style or "regular"
    local bold = (style == "bold" or style == "bolditalic")
    local resolved_face = face_name

    if style == "italic" or style == "bolditalic" then
        local italic = OverlayWidget.findItalicVariant(face_name)
        if italic then
            resolved_face = italic
        end
    end

    -- Apply font scale
    local scale = self.defaults.font_scale or 100
    local scaled_size = math.max(1, math.floor(font_size * scale / 100 + 0.5))

    return {
        face = Font:getFace(resolved_face, scaled_size),
        bold = bold,
        italic = (style == "italic" or style == "bolditalic"),
    }
end

-- Event handlers
function Bookends:onPageUpdate()
    local current = self:getSessionPageNumber()
    if current then
        if not self.session_start_page then
            self.session_start_page = current
            self.session_max_page = current
        elseif current > self.session_max_page then
            self.session_max_page = current
        end
    end
    -- Re-enable after paint error disable
    if self._error_disabled then
        self._error_disabled = false
        self.enabled = self.settings:isTrue("enabled")
    end
    -- Mark dirty but don't request a repaint — KOReader's own page-turn
    -- paint cycle will call our paintTo, which picks up the dirty flag.
    -- Calling setDirty here would cause a second e-ink refresh (visible flicker).
    self.dirty = true
    self._tick_cache = nil
end
function Bookends:onPosUpdate()
    self.dirty = true
    self._tick_cache = nil
end
function Bookends:onReaderFooterVisibilityChange()
    -- Just set dirty; KOReader's own paint cycle for the visibility change
    -- will call our paintTo.  Avoid markDirty() which requests a full-screen
    -- "ui" e-ink refresh that causes a visible flash in dark mode.
    self.dirty = true
    self._tick_cache = nil
end
function Bookends:onSetDimensions() self:markDirty() end

-- Repaint after system events that change token values (battery, frontlight, etc.).
-- These events don't trigger a ReaderView repaint on their own, so we need
-- markDirty() to request one.  Use a nextTick to avoid interrupting the
-- event's own processing.
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
function Bookends:getSessionPageNumber()
    local pageno = self.ui.view.state.page
    if not pageno then return nil end
    -- Use stable page numbers when available (pagemap index or flow-aware)
    if self.ui.pagemap and self.ui.pagemap:wantsPageLabels() then
        local _label, idx, _count = self.ui.pagemap:getCurrentPageLabel(true)
        if idx then return idx end
    end
    local doc = self.ui.document
    if doc and doc:hasHiddenFlows() then
        return doc:getPageNumberInFlow(pageno)
    end
    return pageno
end
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
    -- (only needed when the stock footer is visible)
    if self.ui.view.footer_visible then
        UIManager:scheduleIn(1.5, function()
            self:markDirty()
        end)
    end
end

function Bookends:paintTo(bb, x, y)
    if not self.enabled then return end
    local ok, err = xpcall(self._paintToInner, debug.traceback, self, bb, x, y)
    if not ok then
        self._paint_error_count = (self._paint_error_count or 0) + 1
        if self._paint_error_count >= 3 then
            -- Disable rendering to break error loop; re-enabled on next page turn
            self.enabled = false
            self._error_disabled = true
            self._paint_error_count = 0
            bookends_error("paintTo (disabled until page turn)", err)
        else
            local now = os.time()
            if not self._last_paint_error or (now - self._last_paint_error) >= 10 then
                self._last_paint_error = now
                bookends_error("paintTo", err)
            end
        end
    else
        self._paint_error_count = 0
    end
end

function Bookends:_paintToInner(bb, x, y)

    local screen_size = Screen:getSize()
    local screen_w = screen_size.w
    local screen_h = screen_size.h

    -- Render full-width progress bars (behind text)
    -- Cache tick fractions (static for the document, expensive to compute on CRE)
    if self.dirty then
        self._tick_cache = nil
    end
    local function resolveColors(bc)
        local Blitbuffer = require("ffi/blitbuffer")
        local function colorOrTransparent(v)
            if not v then return nil end
            if v >= 0xFF then return false end
            return Blitbuffer.Color8(v)
        end
        return {
            fill = colorOrTransparent(bc.fill),
            bg = colorOrTransparent(bc.bg),
            track = colorOrTransparent(bc.track),
            tick = colorOrTransparent(bc.tick),
            invert_read_ticks = bc.invert_read_ticks,
            tick_height_pct = bc.tick_height_pct,
        }
    end
    -- Progress bar colors from settings
    local global_tick_height_pct = self.settings:readSetting("tick_height_pct")
    local bar_colors
    local bc = self.settings:readSetting("bar_colors") or {}
    bc.tick_height_pct = global_tick_height_pct or bc.tick_height_pct
    if bc.fill or bc.bg or bc.track or bc.tick or bc.invert_read_ticks ~= nil or bc.tick_height_pct then
        bar_colors = resolveColors(bc)
    end
    for bar_idx, bar_cfg in ipairs(self.progress_bars or {}) do
        if bar_cfg.enabled then
            local anchor = bar_cfg.v_anchor or "bottom"
            local vertical = anchor == "left" or anchor == "right"
            local bar_thickness = bar_cfg.height or 20
            local bar_w, bar_h, bar_x, bar_y
            if vertical then
                -- Vertical: tall narrow bar on left/right edge
                -- margin_left/right reinterpreted as top/bottom insets
                bar_w = bar_thickness
                bar_h = screen_h - (bar_cfg.margin_left or 0) - (bar_cfg.margin_right or 0)
                bar_y = y + (bar_cfg.margin_left or 0)
                if anchor == "left" then
                    bar_x = x + (bar_cfg.margin_v or 0)
                else
                    bar_x = x + screen_w - bar_thickness - (bar_cfg.margin_v or 0)
                end
            else
                -- Horizontal: wide bar along top/bottom edge
                bar_w = screen_w - (bar_cfg.margin_left or 0) - (bar_cfg.margin_right or 0)
                bar_h = bar_thickness
                bar_x = x + (bar_cfg.margin_left or 0)
                if anchor == "top" then
                    bar_y = y + (bar_cfg.margin_v or 0)
                else
                    bar_y = y + screen_h - bar_thickness - (bar_cfg.margin_v or 0)
                end
            end
            if bar_w > 0 and bar_h > 0 then

                local pct = 0
                local ticks = {}
                local pageno_local = self.ui.view.state.page or 0
                local doc = self.ui.document
                local is_cre = self.ui.rolling ~= nil

                if bar_cfg.type == "book" then
                    -- Use page-based progress to match KOReader's footer bar
                    local raw_total = doc:getPageCount()
                    if raw_total and raw_total > 0 then
                        if doc:hasHiddenFlows() then
                            local flow = doc:getPageFlow(pageno_local)
                            local flow_total = doc:getTotalPagesInFlow(flow)
                            local flow_page = doc:getPageNumberInFlow(pageno_local)
                            pct = flow_total > 0 and (flow_page / flow_total) or 0
                        else
                            pct = pageno_local / raw_total
                        end
                        pct = math.max(0, math.min(1, pct))
                    end
                    -- Chapter tick marks (cached — static for the document)
                    local tick_level = bar_cfg.chapter_ticks
                    -- Migrate old boolean
                    if bar_cfg.show_chapter_ticks ~= nil then
                        tick_level = bar_cfg.show_chapter_ticks and "level1" or "off"
                    end
                    if tick_level and tick_level ~= "off" then
                        if not self._tick_cache then
                            self._tick_cache = self:_computeTickCache()
                        end
                        if tick_level == "all" then
                            ticks = self._tick_cache or {}
                        else
                            local max_tick_depth = tick_level == "level2" and 2 or 1
                            ticks = {}
                            for _, tick in ipairs(self._tick_cache or {}) do
                                if type(tick) == "table" and tick[3] and tick[3] <= max_tick_depth then
                                    table.insert(ticks, tick)
                                end
                            end
                        end
                    end
                    -- Per-bar tick width override: recompute widths if this bar has a custom multiplier
                    local per_bar_tw = bar_cfg.colors and bar_cfg.colors.tick_width_multiplier
                    if per_bar_tw and ticks and #ticks > 0 then
                        local max_depth = self.ui.toc and self.ui.toc:getMaxDepth() or 1
                        local remapped = {}
                        for _, tick in ipairs(ticks) do
                            local d = type(tick) == "table" and tick[3] or 1
                            local tw = math.max(1, (max_depth - d + 1) * per_bar_tw - 1)
                            table.insert(remapped, { tick[1], tw, d })
                        end
                        ticks = remapped
                    end
                elseif bar_cfg.type == "chapter" then
                    if is_cre and doc.getCurrentPos and self.ui.toc then
                        local cur_pos = doc:getCurrentPos()
                        local chapter_start = self.ui.toc:getPreviousChapter(pageno_local)
                        if self.ui.toc:isChapterStart(pageno_local) then
                            chapter_start = pageno_local
                        end
                        local next_chapter = self.ui.toc:getNextChapter(pageno_local)
                        if chapter_start then
                            local start_xp = doc:getPageXPointer(chapter_start)
                            local start_pos = start_xp and doc:getPosFromXPointer(start_xp) or 0
                            local end_pos
                            if next_chapter then
                                local next_xp = doc:getPageXPointer(next_chapter)
                                end_pos = next_xp and doc:getPosFromXPointer(next_xp) or (doc.info and doc.info.doc_height or 0)
                            else
                                end_pos = doc.info and doc.info.doc_height or 0
                            end
                            local range = end_pos - start_pos
                            if range > 0 then
                                pct = math.max(0, math.min(1, (cur_pos - start_pos) / range))
                            end
                        end
                    elseif self.ui.toc then
                        local done = self.ui.toc:getChapterPagesDone(pageno_local)
                        local total = self.ui.toc:getChapterPageCount(pageno_local)
                        if done and total and total > 0 then
                            pct = math.max(0, math.min(1, (done + 1) / total))
                        end
                    end
                end

                local direction = bar_cfg.direction or (vertical and "ttb" or "ltr")
                local paint_vertical = direction == "ttb" or direction == "btt"
                local paint_reverse = direction == "rtl" or direction == "btt"
                local colors = bar_cfg.colors and resolveColors(bar_cfg.colors) or bar_colors
                -- Ensure global tick_height_pct is always available
                if colors and not colors.tick_height_pct and global_tick_height_pct then
                    colors.tick_height_pct = global_tick_height_pct
                elseif not colors and global_tick_height_pct then
                    colors = { tick_height_pct = global_tick_height_pct }
                end
                OverlayWidget.paintProgressBar(bb, bar_x, bar_y, bar_w, bar_h, pct, ticks,
                    bar_cfg.style or "solid", paint_vertical and "vertical" or nil, paint_reverse, colors)
            end
        end
    end

    -- Phase 1: Expand tokens for all active positions
    -- Filter lines by page parity, join with \n, then expand tokens
    local pageno = self.ui.view.state.page or 0
    local is_odd_page = (pageno % 2) == 1
    local expanded = {}
    local active_line_indices = {} -- key -> { original indices of visible lines }
    local bar_data = {} -- key -> sparse table { [expanded_line_index] = bar_info }
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
                local position_bars = {}
                for j, line in ipairs(visible_lines) do
                    local result, is_empty, line_bar = Tokens.expand(line, self.ui, session_elapsed, session_pages,
                        nil, self.settings:readSetting("tick_width_multiplier", 2))
                    if not is_empty then
                        table.insert(expanded_lines, result)
                        table.insert(final_indices, visible_indices[j])
                        if line_bar then
                            position_bars[#expanded_lines] = line_bar
                        end
                    end
                end
                if #expanded_lines > 0 then
                    expanded[pos.key] = table.concat(expanded_lines, "\n")
                    active_line_indices[pos.key] = final_indices
                    if next(position_bars) then
                        bar_data[pos.key] = position_bars
                    end
                end
            end
        end
    end

    -- Check if anything changed
    -- Bar positions depend on page number; only rebuild when page changes
    local has_any_bars = next(bar_data) ~= nil
    local bar_page_changed = has_any_bars and (self._last_bar_page ~= pageno)
    if has_any_bars then
        self._last_bar_page = pageno
    end
    if not self.dirty then
        local changed = bar_page_changed
        if not changed then
            for key, text in pairs(expanded) do
                if text ~= self.position_cache[key] then
                    changed = true
                    break
                end
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
            cfg.face_name = face_name
            cfg.font_size = math.max(1, math.floor(font_size * (self.defaults.font_scale or 100) / 100 + 0.5))
            cfg.v_nudge = (pos_settings.line_v_nudge and pos_settings.line_v_nudge[i]) or 0
            cfg.h_nudge = (pos_settings.line_h_nudge and pos_settings.line_h_nudge[i]) or 0
            cfg.uppercase = (pos_settings.line_uppercase and pos_settings.line_uppercase[i]) or false
            -- Bar data (keyed by expanded line index, same order as line_configs)
            local expanded_idx = #line_configs + 1
            if bar_data[key] and bar_data[key][expanded_idx] then
                local all_bars = bar_data[key][expanded_idx]
                local bar_type = (pos_settings.line_bar_type and pos_settings.line_bar_type[i]) or "chapter"
                if bar_type == "book_ticks_all" then
                    local book = all_bars.book
                    cfg.bar = { kind = book.kind, pct = book.pct, ticks = book.ticks }
                elseif bar_type == "book_ticks" or bar_type == "book_ticks2" then
                    local max_tick_depth = bar_type == "book_ticks" and 1 or 2
                    local book = all_bars.book
                    local filtered_ticks = {}
                    for _, tick in ipairs(book.ticks) do
                        if type(tick) == "table" and tick[3] and tick[3] <= max_tick_depth then
                            table.insert(filtered_ticks, tick)
                        end
                    end
                    cfg.bar = { kind = book.kind, pct = book.pct, ticks = filtered_ticks }
                elseif bar_type == "book" then
                    local book = all_bars.book
                    cfg.bar = { kind = book.kind, pct = book.pct, ticks = {} }
                else
                    local ch = all_bars.chapter
                    cfg.bar = { kind = ch.kind, pct = ch.pct, ticks = ch.ticks }
                end
                if all_bars.width then
                    cfg.bar.width = all_bars.width
                end
                cfg.bar_height = (pos_settings.line_bar_height and pos_settings.line_bar_height[i]) or nil
                cfg.bar_style = (pos_settings.line_bar_style and pos_settings.line_bar_style[i]) or nil
                cfg.bar_colors = bar_colors
            end
            table.insert(line_configs, cfg)
        end

        local pos_def
        for _, p in ipairs(self.POSITIONS) do
            if p.key == key then pos_def = p; break end
        end

        -- Apply per-token pixel limits (markers from tokens.lua) using resolved font.
        -- Must happen before widget building so text is clean.
        local limited_text = text
        if text:find("\x01") then
            local limited_lines = {}
            local li = 0
            for line in text:gmatch("([^\n]+)") do
                li = li + 1
                local cfg = line_configs[li] or line_configs[#line_configs]
                local cleaned = OverlayWidget.applyTokenLimits(line, cfg.face, cfg.bold, cfg.uppercase)
                table.insert(limited_lines, cleaned)
            end
            limited_text = table.concat(limited_lines, "\n")
        end

        -- Build without truncation to measure natural text width.
        -- For bar positions, Phase 4 will rebuild with the correct row-aware available_w.
        local pos_available_w = screen_w
        local widget, w, h = OverlayWidget.buildTextWidget(limited_text, line_configs, pos_def.h_anchor, nil, pos_available_w)
        pre_built[key] = { widget = widget, w = w, h = h, line_configs = line_configs, pos_def = pos_def, text = limited_text }
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

        local function getOverlapWidth(key)
            local pb = pre_built[key]
            if not pb then return nil end
            if bar_data[key] then
                return OverlayWidget.measureTextWidth(pb.text, pb.line_configs)
            end
            return pb.w
        end
        local left_w = getOverlapWidth(left_key)
        local center_w = getOverlapWidth(center_key)
        local right_w = getOverlapWidth(right_key)

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
                        pb.text, pb.line_configs, pb.pos_def.h_anchor, max_width, max_width)
                elseif bar_data[key] then
                    -- Bar position without truncation: rebuild with row-aware available width
                    -- so auto-fill bars don't exceed the space overlap prevention would allow
                    if pb.widget and pb.widget.free then pb.widget:free() end
                    local _, hm = self:getMargin(key)
                    local ho = self:getPositionSetting(key, "h_offset") + hm
                    local bar_avail
                    if pb.pos_def.h_anchor == "center" then
                        local lw = getOverlapWidth(left_key) or 0
                        local rw = getOverlapWidth(right_key) or 0
                        local _, lhm = self:getMargin(left_key)
                        local _, rhm = self:getMargin(right_key)
                        local lho = self:getPositionSetting(left_key, "h_offset") + lhm
                        local rho = self:getPositionSetting(right_key, "h_offset") + rhm
                        local left_m = self.defaults.margin_left or 0
                        local right_m = self.defaults.margin_right or 0
                        local left_inset = lw > 0 and (lw + lho + gap) or left_m
                        local right_inset = rw > 0 and (rw + rho + gap) or right_m
                        -- Use wider inset for both sides to keep centering correct
                        local wider = math.max(left_inset, right_inset)
                        bar_avail = math.max(0, screen_w - 2 * wider)
                    else
                        -- Use the same logic as calculateRowLimits for side positions
                        local other_side_w = 0
                        if rk.limit_key == "left" then
                            other_side_w = getOverlapWidth(right_key) or 0
                        else
                            other_side_w = getOverlapWidth(left_key) or 0
                        end
                        local cw = getOverlapWidth(center_key) or 0
                        -- For bars, use actual opposite content width (not half-screen assumption)
                        local other_ho = 0
                        if rk.limit_key == "left" then
                            local _, rhm = self:getMargin(right_key)
                            other_ho = self:getPositionSetting(right_key, "h_offset") + rhm
                        else
                            local _, lhm = self:getMargin(left_key)
                            other_ho = self:getPositionSetting(left_key, "h_offset") + lhm
                        end
                        if cw > 0 then
                            bar_avail = math.max(0, math.floor((screen_w - cw) / 2) - gap - ho)
                        elseif other_side_w > 0 then
                            bar_avail = math.max(0, screen_w - other_side_w - other_ho - gap - ho)
                        else
                            -- Alone on row: fill width minus both margins
                            local left_m = self.defaults.margin_left or 0
                            local right_m = self.defaults.margin_right or 0
                            bar_avail = math.max(0, screen_w - left_m - right_m)
                        end
                    end
                    widget, w, h = OverlayWidget.buildTextWidget(
                        pb.text, pb.line_configs, pb.pos_def.h_anchor, nil, bar_avail)
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

    -- Repaint the bookmark dog-ear on top of Bookends so it isn't hidden
    if self.ui.view.dogear_visible and self.ui.view.dogear then
        self.ui.view.dogear:paintTo(bb, x, y)
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
    if self.settings then
        self.settings:flush()
    end
end

function Bookends:onFlushSettings()
    if self.settings then
        self.settings:flush()
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
        sub_item_table_func = function()
            return self:buildMainMenu()
        end,
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
                self.settings:saveSetting("enabled", self.enabled)
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
                    table.insert(previews, (Tokens.expandPreview(line, self.ui, session_elapsed, session_pages,
                        self.settings:readSetting("tick_width_multiplier", 2))))
                end
                local preview = table.concat(previews, " \xC2\xB7 ")
                preview = preview:gsub("%s+", " "):match("^%s*(.-)%s*$")
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

    -- Progress bars submenu
    table.insert(menu, {
        text = _("Full width progress bars"),
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            return self:buildProgressBarMenu()
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
                        local ok, FontChooser = pcall(require, "ui/widget/fontchooser")
                        local name
                        if ok and FontChooser and FontChooser.getFontNameText then
                            name = FontChooser.getFontNameText(self.defaults.font_face)
                        end
                        if not name then
                            name = self.defaults.font_face:match("([^/]+)$"):gsub("%.%w+$", "")
                        end
                        return _("Default font") .. " (" .. name .. ")"
                    end,
                    callback = function()
                        -- Remember which positions are using the current default
                        local inheriting = {}
                        for _, p in ipairs(self.POSITIONS) do
                            local ps = self.positions[p.key]
                            if ps.font_face == nil or ps.font_face == self.defaults.font_face then
                                inheriting[p.key] = true
                            end
                        end
                        self:showFontPicker(self.defaults.font_face, function(face)
                            self.defaults.font_face = face
                            self.settings:saveSetting("font_face", face)
                            -- Cascade: clear per-position font_face for positions that were inheriting
                            for _, p in ipairs(self.POSITIONS) do
                                if inheriting[p.key] then
                                    self.positions[p.key].font_face = nil
                                    self:savePositionSetting(p.key)
                                end
                            end
                            self:markDirty()
                        end, Font.fontmap["ffont"])
                    end,
                },
                {
                    text_func = function()
                        return _("Font scale") .. " (" .. self.defaults.font_scale .. "%)"
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showNudgeDialog(_("Font scale"), self.defaults.font_scale, 25, 300, 100, "%",
                            function(val)
                                self.defaults.font_scale = val
                                self:markDirty()
                            end,
                            function()
                                self.settings:saveSetting("font_scale", self.defaults.font_scale)
                            end, nil, nil, touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        local m = self.defaults
                        return _("Adjust margins") .. " (" .. m.margin_top .. "/" .. m.margin_bottom .. "/" .. m.margin_left .. "/" .. m.margin_right .. ")"
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showMarginAdjuster(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        return _("Truncation gap between regions") .. " (" .. self.defaults.overlap_gap .. ")"
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showNudgeDialog(_("Truncation gap"), self.defaults.overlap_gap, 0, 999, 50, "px",
                            function(val)
                                self.defaults.overlap_gap = val
                                self.settings:saveSetting("overlap_gap", val)
                                self:markDirty()
                            end,
                            nil, nil, nil, touchmenu_instance)
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
                        self.settings:saveSetting("truncation_priority", self.defaults.truncation_priority)
                        self:markDirty()
                    end,
                },
                {
                    text = _("Progress bar colours and tick marks"),
                    sub_item_table_func = function()
                        return self:buildBarColorsMenu()
                    end,
                    separator = true,
                },
                {
                    text_func = function()
                        if self.ui.view.footer_visible then
                            return _("Disable stock status bar") .. " (" .. _("recommended") .. ")"
                        end
                        return _("Disable stock status bar")
                    end,
                    keep_menu_open = true,
                    help_text = _("Hides KOReader's built-in status bar. This simplifies the render pipeline and can reduce e-ink flicker on some devices. All status bar features are available as Bookends tokens."),
                    checked_func = function()
                        return not self.ui.view.footer_visible
                    end,
                    callback = function()
                        local footer = self.ui.view.footer
                        if self.ui.view.footer_visible then
                            footer:applyFooterMode(footer.mode_list.off)
                            G_reader_settings:saveSetting("reader_footer_mode", footer.mode_list.off)
                        else
                            footer:applyFooterMode(footer.mode_list.page_progress)
                            G_reader_settings:saveSetting("reader_footer_mode", footer.mode_list.page_progress)
                        end
                        self:markDirty()
                    end,
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

    -- Presets (at bottom)
    table.insert(menu, {
        text = _("Presets"),
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            return self:buildPresetsMenu()
        end,
    })

    return menu
end

function Bookends:buildProgressBarMenu()
    local items = {}
    for idx, bar_cfg in ipairs(self.progress_bars) do
        local label = _("Bar") .. " " .. idx
        table.insert(items, {
            text_func = function()
                if bar_cfg.enabled then
                    local type_label = bar_cfg.type == "chapter" and _("chapter") or _("book")
                    local anchor_labels = { top = _("top"), bottom = _("bottom"), left = _("left"), right = _("right") }
                    local orient = anchor_labels[bar_cfg.v_anchor or "bottom"]
                    return label .. " (" .. type_label .. ", " .. orient .. ")"
                end
                return label
            end,
            checked_func = function() return bar_cfg.enabled end,
            sub_item_table_func = function()
                return self:buildSingleBarMenu(idx, bar_cfg)
            end,
        })
    end
    table.insert(items, {
        text = _("Inline progress bars can be added via the line editor"),
        enabled_func = function() return false end,
    })
    return items
end

function Bookends:buildSingleBarMenu(bar_idx, bar_cfg)
    local function saveBar()
        self.settings:saveSetting("progress_bar_" .. bar_idx, bar_cfg)
        self:markDirty()
    end

    local function isEnabled() return bar_cfg.enabled end

    return {
        {
            text = _("Enable"),
            checked_func = function() return bar_cfg.enabled end,
            callback = function()
                bar_cfg.enabled = not bar_cfg.enabled
                saveBar()
            end,
        },
        {
            text_func = function()
                return _("Type") .. ": " .. (bar_cfg.type == "chapter" and _("Chapter") or _("Book"))
            end,
            enabled_func = isEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                bar_cfg.type = bar_cfg.type == "book" and "chapter" or "book"
                saveBar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                if bar_cfg.show_chapter_ticks ~= nil then
                    bar_cfg.chapter_ticks = bar_cfg.show_chapter_ticks and "level1" or "off"
                    bar_cfg.show_chapter_ticks = nil
                end
                local labels = {
                    off = _("Chapter ticks: off"),
                    all = _("Chapter ticks: all levels"),
                    level1 = _("Chapter ticks: top level"),
                    level2 = _("Chapter ticks: top 2 levels"),
                }
                return labels[bar_cfg.chapter_ticks or "off"]
            end,
            enabled_func = function() return bar_cfg.enabled and bar_cfg.type == "book" end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local cycle = { "off", "level1", "level2", "all" }
                local cur = bar_cfg.chapter_ticks or "off"
                for idx, v in ipairs(cycle) do
                    if v == cur then
                        bar_cfg.chapter_ticks = cycle[(idx % #cycle) + 1]
                        break
                    end
                end
                saveBar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                local style_labels = { solid = _("Solid"), bordered = _("Bordered"), rounded = _("Rounded"), metro = _("Metro") }
                return _("Style") .. ": " .. (style_labels[bar_cfg.style] or _("Solid"))
            end,
            enabled_func = isEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local cycle = { "solid", "bordered", "rounded", "metro" }
                local cur = bar_cfg.style or "solid"
                for idx, s in ipairs(cycle) do
                    if s == cur then
                        bar_cfg.style = cycle[(idx % #cycle) + 1]
                        break
                    end
                end
                saveBar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                local labels = { top = _("Top"), bottom = _("Bottom"), left = _("Left"), right = _("Right") }
                return _("Anchor") .. ": " .. (labels[bar_cfg.v_anchor or "bottom"])
            end,
            enabled_func = isEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local cycle = { "top", "bottom", "left", "right" }
                local cur = bar_cfg.v_anchor or "bottom"
                for idx, v in ipairs(cycle) do
                    if v == cur then
                        local new_anchor = cycle[(idx % #cycle) + 1]
                        bar_cfg.v_anchor = new_anchor
                        local new_vert = new_anchor == "left" or new_anchor == "right"
                        local cur_dir = bar_cfg.direction or "ltr"
                        local cur_is_vert = cur_dir == "ttb" or cur_dir == "btt"
                        if new_vert and not cur_is_vert then
                            bar_cfg.direction = "btt"
                        elseif not new_vert and cur_is_vert then
                            bar_cfg.direction = nil
                        end
                        break
                    end
                end
                saveBar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                local labels = {
                    ltr = _("Fill: left to right"),
                    rtl = _("Fill: right to left"),
                    ttb = _("Fill: top to bottom"),
                    btt = _("Fill: bottom to top"),
                }
                local is_side = bar_cfg.v_anchor == "left" or bar_cfg.v_anchor == "right"
                local default_dir = is_side and "ttb" or "ltr"
                return labels[bar_cfg.direction or default_dir]
            end,
            enabled_func = isEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local is_side = bar_cfg.v_anchor == "left" or bar_cfg.v_anchor == "right"
                local is_metro = (bar_cfg.style or "solid") == "metro"
                local cycle
                if is_metro and is_side then
                    cycle = { "ttb", "btt" }
                elseif is_metro then
                    cycle = { "ltr", "rtl" }
                else
                    cycle = { "ltr", "rtl", "ttb", "btt" }
                end
                local default_dir = is_side and "ttb" or "ltr"
                local cur = bar_cfg.direction or default_dir
                local found = false
                for idx, v in ipairs(cycle) do
                    if v == cur then
                        local next_dir = cycle[(idx % #cycle) + 1]
                        bar_cfg.direction = next_dir ~= default_dir and next_dir or nil
                        found = true
                        break
                    end
                end
                if not found then
                    -- Stale direction not in allowed cycle — snap to default
                    bar_cfg.direction = nil
                end
                saveBar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Thickness") .. ": " .. (bar_cfg.height or 20) .. "px"
            end,
            enabled_func = isEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showNudgeDialog(_("Bar thickness"), bar_cfg.height or 20, 1, 60, 20, "px",
                    function(val)
                        bar_cfg.height = val
                        saveBar()
                    end,
                    nil, nil, nil, touchmenu_instance)
            end,
        },
        {
            text_func = function()
                return _("Adjust margins") .. " (" ..
                    (bar_cfg.margin_v or 0) .. "/" ..
                    (bar_cfg.margin_left or 0) .. "/" ..
                    (bar_cfg.margin_right or 0) .. ")"
            end,
            enabled_func = isEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showBarMarginAdjuster(bar_cfg, bar_idx, touchmenu_instance)
            end,
        },
        {
            text_func = function()
                if bar_cfg.colors then
                    return _("Custom colours and tick marks") .. " (\u{2713})"
                end
                return _("Custom colours and tick marks")
            end,
            enabled_func = isEnabled,
            sub_item_table_func = function()
                local custom_items = {}

                -- Toggle
                table.insert(custom_items, {
                    text = _("Use custom colors"),
                    checked_func = function() return bar_cfg.colors ~= nil end,
                    callback = function()
                        if bar_cfg.colors then
                            bar_cfg.colors = nil
                        else
                            bar_cfg.colors = {}
                        end
                        saveBar()
                    end,
                    separator = true,
                })

                -- Color items (only functional when custom colors enabled)
                local bc = bar_cfg.colors or {}
                local color_items = self:_buildColorItems(bc, function()
                    bar_cfg.colors = bc
                    saveBar()
                end)
                for _, item in ipairs(color_items) do
                    local orig_enabled = item.enabled_func
                    item.enabled_func = function()
                        if not bar_cfg.colors then return false end
                        return orig_enabled == nil or orig_enabled()
                    end
                    table.insert(custom_items, item)
                end

                -- Per-bar tick height override
                table.insert(custom_items, {
                    text_func = function()
                        return _("Tick height") .. ": " .. (bc.tick_height_pct or 100) .. "%"
                    end,
                    enabled_func = function() return bar_cfg.colors ~= nil end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showNudgeDialog(_("Tick height"), bc.tick_height_pct or 100, 1, 400, 100, "%",
                            function(val)
                                bc.tick_height_pct = val ~= 100 and val or nil
                                bar_cfg.colors = bc
                                saveBar()
                            end,
                            nil, nil, nil, touchmenu_instance)
                    end,
                    hold_callback = function(touchmenu_instance)
                        bc.tick_height_pct = nil
                        bar_cfg.colors = bc
                        saveBar()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })

                -- Per-bar tick width override
                table.insert(custom_items, {
                    text_func = function()
                        local m = bc.tick_width_multiplier
                        if m then
                            return _("Tick width") .. ": " .. m .. "x"
                        end
                        return _("Tick width") .. ": " .. _("default") .. " (" .. self.settings:readSetting("tick_width_multiplier", 2) .. "x)"
                    end,
                    enabled_func = function() return bar_cfg.colors ~= nil end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local current = bc.tick_width_multiplier or self.settings:readSetting("tick_width_multiplier", 2)
                        self:showNudgeDialog(_("Tick width"), current, 1, 5, self.settings:readSetting("tick_width_multiplier", 2), "x",
                            function(val)
                                bc.tick_width_multiplier = val
                                bar_cfg.colors = bc
                                self._tick_cache = nil
                                saveBar()
                            end,
                            nil, 1, false, touchmenu_instance)
                    end,
                    hold_callback = function(touchmenu_instance)
                        bc.tick_width_multiplier = nil
                        bar_cfg.colors = bc
                        self._tick_cache = nil
                        saveBar()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })

                -- Reset custom to defaults
                table.insert(custom_items, {
                    text = _("Reset custom to defaults"),
                    enabled_func = function() return bar_cfg.colors ~= nil end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        bar_cfg.colors = {}
                        self._tick_cache = nil
                        saveBar()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })

                return custom_items
            end,
        },
    }
end

function Bookends:showBarMarginAdjuster(bar_cfg, bar_idx, touchmenu_instance)
    local restoreMenu = self:hideMenu(touchmenu_instance)
    local original = {
        margin_v = bar_cfg.margin_v or 0,
        margin_left = bar_cfg.margin_left or 0,
        margin_right = bar_cfg.margin_right or 0,
    }

    local margin_dialog
    local vert = bar_cfg.v_anchor == "left" or bar_cfg.v_anchor == "right"

    local function nudge(field, delta)
        bar_cfg[field] = math.max(0, (bar_cfg[field] or 0) + delta)
        self.settings:saveSetting("progress_bar_" .. bar_idx, bar_cfg)
        self:markDirty()
        margin_dialog:reinit()
    end

    local function makeRow(label, field)
        return {
            { text = "-10", callback = function() nudge(field, -10) end },
            { text = "-1", callback = function() nudge(field, -1) end },
            { text_func = function()
                return label .. ": " .. (bar_cfg[field] or 0)
            end, enabled = false },
            { text = "+1", callback = function() nudge(field, 1) end },
            { text = "+10", callback = function() nudge(field, 10) end },
        }
    end

    local edge_label = vert and _("Edge") or _("Vertical")
    local start_label = vert and _("Top") or _("Left")
    local end_label = vert and _("Bottom") or _("Right")

    local ButtonDialog = require("ui/widget/buttondialog")
    margin_dialog = ButtonDialog:new{
        dismissable = false,
        title = _("Adjust margins"),
        tap_close_callback = function()
            for k, v in pairs(original) do
                bar_cfg[k] = v
            end
            self.settings:saveSetting("progress_bar_" .. bar_idx, bar_cfg)
            self:markDirty()
            restoreMenu()
        end,
        buttons = {
            makeRow(edge_label, "margin_v"),
            makeRow(start_label, "margin_left"),
            makeRow(end_label, "margin_right"),
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        for k, v in pairs(original) do
                            bar_cfg[k] = v
                        end
                        self.settings:saveSetting("progress_bar_" .. bar_idx, bar_cfg)
                        self:markDirty()
                        UIManager:close(margin_dialog)
                        restoreMenu()
                    end,
                },
                {
                    text = _("Default") .. " 0",
                    callback = function()
                        bar_cfg.margin_v = 0
                        bar_cfg.margin_left = 0
                        bar_cfg.margin_right = 0
                        self.settings:saveSetting("progress_bar_" .. bar_idx, bar_cfg)
                        self:markDirty()
                        margin_dialog:reinit()
                    end,
                },
                {
                    text = _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        self.settings:saveSetting("progress_bar_" .. bar_idx, bar_cfg)
                        UIManager:close(margin_dialog)
                        restoreMenu()
                    end,
                },
            },
        },
    }
    UIManager:show(margin_dialog)
end

--- Hide the touch menu so the user can see live changes on the page,
--- then return a function that re-shows it at the same position.
function Bookends:hideMenu(touchmenu_instance)
    if not touchmenu_instance then return function() end end
    -- The UIManager stack holds show_parent (a CenterContainer), not the TouchMenu itself.
    local container = touchmenu_instance.show_parent or touchmenu_instance
    UIManager:close(container, "ui")
    return function()
        UIManager:show(container)
        touchmenu_instance:updateItems()
    end
end

function Bookends:showNudgeDialog(title, value, min_val, max_val, default_val, unit, on_change, on_close, small_step, large_step, touchmenu_instance)
    local ButtonDialog = require("ui/widget/buttondialog")
    local restoreMenu = self:hideMenu(touchmenu_instance)
    local orig_on_close = on_close
    on_close = function()
        restoreMenu()
        if orig_on_close then orig_on_close() end
    end
    local dialog
    local original_value = value
    small_step = small_step or 1
    if large_step == nil then large_step = 10 end

    local function update(delta)
        value = math.max(min_val, math.min(max_val, value + delta))
        on_change(value)
        dialog:reinit()
    end

    local nudge_buttons = {}
    if large_step then
        table.insert(nudge_buttons, { text = "-" .. large_step, callback = function() update(-large_step) end })
    end
    table.insert(nudge_buttons, { text = "-" .. small_step, callback = function() update(-small_step) end })
    table.insert(nudge_buttons, { text_func = function() return tostring(value) .. unit end, enabled = false })
    table.insert(nudge_buttons, { text = "+" .. small_step, callback = function() update(small_step) end })
    if large_step then
        table.insert(nudge_buttons, { text = "+" .. large_step, callback = function() update(large_step) end })
    end

    dialog = ButtonDialog:new{
        dismissable = false,
        title = title .. ": " .. value .. unit,
        tap_close_callback = function()
            -- Revert to original value on tap-outside
            if value ~= original_value then
                value = original_value
                on_change(value)
            end
            if on_close then on_close() end
        end,
        buttons = {
            nudge_buttons,
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        if value ~= original_value then
                            value = original_value
                            on_change(value)
                        end
                        UIManager:close(dialog)
                        if on_close then on_close() end
                    end,
                },
                { text = _("Default") .. " " .. default_val .. unit, callback = function() value = default_val; on_change(value); dialog:reinit() end },
                {
                    text = _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        if on_close then on_close() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Bookends:_buildColorItems(bc, saveColors)
    local function colorNudge(title, field, default_pct, touchmenu_instance)
        local current = bc[field] and math.floor((0xFF - bc[field]) * 100 / 0xFF + 0.5) or default_pct
        self:showNudgeDialog(title, current, 0, 100, default_pct, "%",
            function(val)
                bc[field] = 0xFF - math.floor(val * 0xFF / 100 + 0.5)
                saveColors()
            end,
            nil, nil, nil, touchmenu_instance)
    end

    local function pctLabel(field, default_pct)
        if bc[field] then
            local pct = math.floor((0xFF - bc[field]) * 100 / 0xFF + 0.5)
            if pct == 0 then return _("transparent") end
            return pct .. "%"
        end
        return _("default") .. " (" .. default_pct .. "%)"
    end

    return {
        {
            text_func = function()
                return _("Read color") .. ": " .. pctLabel("fill", 75)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                colorNudge(_("Read color (% black)"), "fill", 75, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.fill = nil; saveColors()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Unread color") .. ": " .. pctLabel("bg", 25)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                colorNudge(_("Unread color (% black)"), "bg", 25, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.bg = nil; saveColors()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Metro track color") .. ": " .. pctLabel("track", 75)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                colorNudge(_("Metro track color (% black)"), "track", 75, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.track = nil; saveColors()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Tick color") .. ": " .. pctLabel("tick", 100)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                colorNudge(_("Tick color (% black)"), "tick", 100, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.tick = nil; saveColors()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text = _("Invert tick color on read portion"),
            checked_func = function() return bc.invert_read_ticks ~= false end,
            callback = function()
                if bc.invert_read_ticks == false then
                    bc.invert_read_ticks = nil
                else
                    bc.invert_read_ticks = false
                end
                saveColors()
            end,
        },
    }
end

function Bookends:buildBarColorsMenu()
    local bc = self.settings:readSetting("bar_colors") or {}

    local function saveColors()
        if not bc.fill and not bc.bg and not bc.track and not bc.tick and bc.invert_read_ticks == nil and not bc.tick_height_pct then
            self.settings:delSetting("bar_colors")
        else
            self.settings:saveSetting("bar_colors", bc)
        end
        self:markDirty()
    end

    local items = self:_buildColorItems(bc, saveColors)

    -- Tick width multiplier
    table.insert(items, {
        text_func = function()
            local m = self.settings:readSetting("tick_width_multiplier", 2)
            return _("Tick width") .. ": " .. m .. "x"
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showNudgeDialog(_("Tick width"), self.settings:readSetting("tick_width_multiplier", 2), 1, 5, 2, "x",
                function(val)
                    self.settings:saveSetting("tick_width_multiplier", val)
                    self._tick_cache = nil
                    self:markDirty()
                end,
                nil, 1, false, touchmenu_instance)
        end,
        hold_callback = function(touchmenu_instance)
            self.settings:delSetting("tick_width_multiplier")
            self._tick_cache = nil
            self:markDirty()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    -- Tick height
    table.insert(items, {
        text_func = function()
            local h = self.settings:readSetting("tick_height_pct", 100)
            return _("Tick height") .. ": " .. h .. "%"
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showNudgeDialog(_("Tick height"), self.settings:readSetting("tick_height_pct", 100), 1, 400, 100, "%",
                function(val)
                    if val == 100 then
                        self.settings:delSetting("tick_height_pct")
                    else
                        self.settings:saveSetting("tick_height_pct", val)
                    end
                    self:markDirty()
                end,
                nil, nil, nil, touchmenu_instance)
        end,
        hold_callback = function(touchmenu_instance)
            self.settings:delSetting("tick_height_pct")
            self:markDirty()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    -- Reset all
    table.insert(items, {
        text = _("Reset all to defaults"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            bc = {}
            self.settings:delSetting("bar_colors")
            self.settings:delSetting("tick_width_multiplier")
            self.settings:delSetting("tick_height_pct")
            self._tick_cache = nil
            self:markDirty()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })

    return items
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

    -- Line entries
    for i, line in ipairs(lines) do
        table.insert(menu, {
            text_func = function()
                local ps = self.positions[pos.key]
                local filter = ps.line_page_filter and ps.line_page_filter[i]
                local tag = ""
                if filter == "odd" then tag = " [odd]"
                elseif filter == "even" then tag = " [even]" end
                local preview = (Tokens.expandPreview(ps.lines[i] or "", self.ui, self:getSessionElapsed(), math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0)),
                    self.settings:readSetting("tick_width_multiplier", 2)))
                preview = preview:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if #preview > 42 then
                    preview = truncateUtf8(preview, 39)
                end
                return _("Line") .. " " .. i .. tag .. ": " .. preview
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editLineString(pos, i, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                self:showLineManageDialog(pos, i, touchmenu_instance)
            end,
        })
    end

    -- Add line
    table.insert(menu, {
        text = "+ " .. _("Add line") .. "  (" .. _("long press lines to manage") .. ")",
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local idx = #self.positions[pos.key].lines + 1
            table.insert(self.positions[pos.key].lines, "")
            self:savePositionSetting(pos.key)
            self:editLineString(pos, idx, touchmenu_instance)
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
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local ps = self.positions[pos.key]
            self:showNudgeDialog(v_label, ps.v_offset or 0, 0, 999, 0, "px",
                function(val)
                    ps.v_offset = val > 0 and val or nil
                    self:markDirty()
                end,
                function()
                    self:savePositionSetting(pos.key)
                end, nil, nil, touchmenu_instance)
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
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local ps = self.positions[pos.key]
                self:showNudgeDialog(h_label, ps.h_offset or 0, 0, 999, 0, "px",
                    function(val)
                        ps.h_offset = val > 0 and val or nil
                        self:markDirty()
                    end,
                    function()
                        self:savePositionSetting(pos.key)
                    end, nil, nil, touchmenu_instance)
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
    -- U+F0A0 = \xEF\x82\xA0 HDD
    -- U+F0EB = \xEF\x83\xAB lightbulb
    -- U+F185 = \xEF\x86\x85 sun
    -- U+EA5A = \xEE\xA9\x9A memory chip
    -- U+ECA8 = \xEE\xB2\xA8 wifi on (dynamic via %W)
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
    {
        name = _("SimpleUI status bar"),
        preset = {
            enabled = true,
            defaults = {
                margin_top = 22, margin_bottom = 50,
                margin_left = 35, margin_right = 35,
            },
            positions = {
                tl = { lines = { "%k" }, line_font_size = { [1] = 15 } },
                tc = { lines = {} },
                tr = { lines = { "%W  %B%b  \xEF\x82\xA0 %v  \xEE\xA9\x9A %M  \xE2\x98\x80 %f" }, line_font_size = { [1] = 15 } },
                bl = { lines = {} },
                bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 18 } },
                br = { lines = {} },
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

    -- Custom presets (file-based)
    table.insert(items, {
        text = _("Custom presets"),
        sub_item_table_func = function()
            return self:buildCustomPresetsMenu()
        end,
    })

    return items
end

function Bookends:buildCustomPresetsMenu()
    local items = {
        {
            text = _("Save current as preset…"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local restoreMenu = self:hideMenu(touchmenu_instance)
                local input_dialog
                input_dialog = InputDialog:new{
                    title = _("Enter preset name"),
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(input_dialog)
                                    restoreMenu()
                                end,
                            },
                            {
                                text = _("Save"),
                                is_enter_default = true,
                                callback = function()
                                    local name = input_dialog:getInputText()
                                    if name == "" or name:match("^%s*$") then
                                        UIManager:show(InfoMessage:new{
                                            text = _("Please enter a name for the preset."),
                                            timeout = 2,
                                        })
                                        return
                                    end
                                    local preset_data = self:buildPreset()
                                    self:writePresetFile(name, preset_data)
                                    UIManager:close(input_dialog)
                                    restoreMenu()
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Preset '%1' saved."), name),
                                        timeout = 2,
                                    })
                                end,
                            },
                        },
                    },
                }
                UIManager:show(input_dialog)
                input_dialog:onShowKeyboard()
            end,
            separator = true,
        },
    }

    -- Load preset files from directory
    local presets = self:readPresetFiles()
    for _i, entry in ipairs(presets) do
        table.insert(items, {
            text = entry.name,
            keep_menu_open = true,
            callback = function()
                local load_ok, load_err = pcall(self.loadPreset, self, entry.preset)
                if not load_ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Failed to load preset '%1':\n%2"), entry.name, tostring(load_err)),
                    })
                    return
                end
                UIManager:show(InfoMessage:new{
                    text = T(_("Preset '%1' loaded."), entry.name),
                    timeout = 2,
                })
            end,
            hold_callback = function(touchmenu_instance)
                self:showPresetEditDialog(entry, touchmenu_instance)
            end,
        })
    end

    if #presets > 0 then
        table.insert(items, {
            text = _("Long press presets to edit"),
            enabled_func = function() return false end,
        })
    end

    -- Show presets folder path
    table.insert(items, {
        text = _("Open presets folder"),
        keep_menu_open = true,
        callback = function()
            self:ensurePresetDir()
            UIManager:show(InfoMessage:new{
                text = T(_("Preset files are stored in:\n%1\n\nCopy .lua files here to import presets from other users."), self:presetDir()),
            })
        end,
        separator = true,
    })

    return items
end

function Bookends:showPresetEditDialog(entry, touchmenu_instance)
    UIManager:show(ConfirmBox:new{
        text = T(_("What would you like to do with preset '%1'?"), entry.name),
        icon = "notice-question",
        ok_text = _("Update"),
        ok_callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Overwrite preset '%1' with current settings?"), entry.name),
                ok_callback = function()
                    self:updatePresetFile(entry.filename, entry.name)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Preset '%1' updated."), entry.name),
                        timeout = 2,
                    })
                end,
            })
        end,
        other_buttons_first = true,
        other_buttons = {
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Delete preset '%1'? This cannot be undone."), entry.name),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                self:deletePresetFile(entry.filename)
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Preset '%1' deleted."), entry.name),
                                    timeout = 2,
                                })
                            end,
                        })
                    end,
                },
                {
                    text = _("Rename"),
                    callback = function()
                        local input_dialog
                        input_dialog = InputDialog:new{
                            title = _("Enter new preset name"),
                            input = entry.name,
                            buttons = {
                                {
                                    {
                                        text = _("Cancel"),
                                        id = "close",
                                        callback = function()
                                            UIManager:close(input_dialog)
                                        end,
                                    },
                                    {
                                        text = _("Rename"),
                                        is_enter_default = true,
                                        callback = function()
                                            local new_name = input_dialog:getInputText()
                                            if new_name == "" or new_name:match("^%s*$") or new_name == entry.name then
                                                UIManager:close(input_dialog)
                                                return
                                            end
                                            self:renamePresetFile(entry.filename, new_name)
                                            UIManager:close(input_dialog)
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("Preset renamed to '%1'."), new_name),
                                                timeout = 2,
                                            })
                                        end,
                                    },
                                },
                            },
                        }
                        UIManager:show(input_dialog)
                        input_dialog:onShowKeyboard()
                    end,
                },
            },
        },
    })
end

-- ─── Line editing ────────────────────────────────────────

function Bookends:editLineString(pos, line_idx, touchmenu_instance)
    local restoreMenu = self:hideMenu(touchmenu_instance)
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
    pos_settings.line_bar_type = pos_settings.line_bar_type or {}
    pos_settings.line_bar_height = pos_settings.line_bar_height or {}
    pos_settings.line_bar_style = pos_settings.line_bar_style or {}

    -- Snapshot for cancel/restore
    local original_settings = util.tableDeepCopy(pos_settings)

    local line_style = pos_settings.line_style[line_idx] or "regular"
    local line_size = pos_settings.line_font_size[line_idx] -- nil = use default
    local line_face = pos_settings.line_font_face[line_idx] -- nil = use default
    local line_v_nudge = pos_settings.line_v_nudge[line_idx] or 0
    local line_h_nudge = pos_settings.line_h_nudge[line_idx] or 0
    local line_uppercase = pos_settings.line_uppercase[line_idx] or false
    local line_page_filter = pos_settings.line_page_filter[line_idx] -- nil = all pages
    local line_bar_type = pos_settings.line_bar_type[line_idx] -- nil = "chapter"
    local line_bar_height = pos_settings.line_bar_height[line_idx] -- nil = use font size
    local line_bar_style = pos_settings.line_bar_style[line_idx] -- nil = "bordered"

    -- Live preview: write current local state to settings and repaint.
    local function applyLivePreview()
        pos_settings.line_style[line_idx] = line_style ~= "regular" and line_style or nil
        pos_settings.line_font_size[line_idx] = line_size
        pos_settings.line_font_face[line_idx] = line_face
        pos_settings.line_v_nudge[line_idx] = line_v_nudge ~= 0 and line_v_nudge or nil
        pos_settings.line_h_nudge[line_idx] = line_h_nudge ~= 0 and line_h_nudge or nil
        pos_settings.line_uppercase[line_idx] = line_uppercase or nil
        pos_settings.line_page_filter[line_idx] = line_page_filter
        pos_settings.line_bar_type[line_idx] = line_bar_type
        pos_settings.line_bar_height[line_idx] = line_bar_height
        pos_settings.line_bar_style[line_idx] = line_bar_style
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
        format_dialog:onCloseKeyboard()
        line_uppercase = not line_uppercase
        applyLivePreview()
        format_dialog:reinit()
    end

    page_filter_button.callback = function()
        format_dialog:onCloseKeyboard()
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

    -- Bar row: [+ Bar] [Ch./Book/Book+] [Bdr/Sld]
    local function hasBarToken()
        if not format_dialog then return current_text:find("%%bar") ~= nil end
        local t = format_dialog:getInputText()
        return t and t:find("%%bar") ~= nil
    end

    local BAR_TYPE_CYCLE = { "chapter", "book", "book_ticks", "book_ticks2", "book_ticks_all" }
    local BAR_TYPE_LABELS = { chapter = _("Chapter"), book = _("Book"), book_ticks = _("Book+"), book_ticks2 = _("Book++"), book_ticks_all = _("Book+++") }

    local bar_insert_button = {
        text_func = function()
            return hasBarToken() and _("- Progress bar") or _("+ Progress bar")
        end,
        callback = function() end,
    }
    local bar_type_button = {
        text_func = function()
            if not hasBarToken() then return "" end
            return BAR_TYPE_LABELS[line_bar_type or "chapter"] or _("Ch.")
        end,
        enabled_func = hasBarToken,
        callback = function() end,
    }
    local bar_style_button = {
        text_func = function()
            if not hasBarToken() then return "" end
            local labels = { bordered = _("Border"), solid = _("Solid"), rounded = _("Round"), metro = _("Metro") }
            return labels[line_bar_style or "bordered"] or _("Border")
        end,
        enabled_func = hasBarToken,
        callback = function() end,
    }

    bar_insert_button.callback = function()
        format_dialog:onCloseKeyboard()
        if hasBarToken() then
            local t = format_dialog:getInputText()
            t = t:gsub("%s*%%bar%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
            format_dialog._input_widget:setText(t)
            pos_settings.lines[line_idx] = t
            self:markDirty()
        else
            format_dialog:addTextToInput("%bar")
            -- Ensure single space before/after %bar (but not at string edges)
            local t = format_dialog:getInputText() or ""
            t = t:gsub("(%S)(%%bar)", "%1 %%bar")   -- space before if touching text
            t = t:gsub("(%%bar)(%S)", "%%bar %2")    -- space after if touching text
            t = t:gsub("%s+%%bar", " %%bar")          -- collapse multiple spaces before
            t = t:gsub("%%bar%s+", "%%bar ")           -- collapse multiple spaces after
            t = t:gsub("^%s+", ""):gsub("%s+$", "")  -- trim edges
            format_dialog._input_widget:setText(t)
            pos_settings.lines[line_idx] = t
            self:markDirty()
        end
        format_dialog:reinit()
    end

    bar_type_button.callback = function()
        format_dialog:onCloseKeyboard()
        local cur = line_bar_type or "chapter"
        for idx, t in ipairs(BAR_TYPE_CYCLE) do
            if t == cur then
                local next_type = BAR_TYPE_CYCLE[(idx % #BAR_TYPE_CYCLE) + 1]
                line_bar_type = next_type ~= "chapter" and next_type or nil
                break
            end
        end
        applyLivePreview()
        format_dialog:reinit()
    end

    bar_style_button.callback = function()
        format_dialog:onCloseKeyboard()
        local style_cycle = { "bordered", "solid", "rounded", "metro" }
        local cur = line_bar_style or "bordered"
        for idx, s in ipairs(style_cycle) do
            if s == cur then
                local next_style = style_cycle[(idx % #style_cycle) + 1]
                line_bar_style = next_style ~= "bordered" and next_style or nil
                break
            end
        end
        applyLivePreview()
        format_dialog:reinit()
    end

    style_button.callback = function()
        format_dialog:onCloseKeyboard()
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
        format_dialog:onCloseKeyboard()
        local current = line_size or self:getPositionSetting(pos.key, "font_size")
        self:showNudgeDialog(_("Font size") .. " " .. _("line") .. " " .. line_idx,
            current, 1, 36, self:getPositionSetting(pos.key, "font_size"), "px",
            function(val)
                line_size = val
                applyLivePreview()
            end,
            function()
                format_dialog:reinit()
            end, 1, false)
    end

    font_button.callback = function()
        format_dialog:onCloseKeyboard()
        self:showFontPicker(
            line_face or self:getPositionSetting(pos.key, "font_face"),
            function(font_filename)
                line_face = font_filename
                applyLivePreview()
                format_dialog:reinit()
            end,
            self:getPositionSetting(pos.key, "font_face")
        )
    end

    -- Nudge buttons (1px per tap)
    local nudge_step = 1
    local nudge_up = {
        icon = "chevron.up",
        callback = function() end,
    }
    local nudge_down = {
        icon = "chevron.down",
        callback = function() end,
    }
    local nudge_left = {
        icon = "chevron.left",
        callback = function() end,
    }
    local nudge_right = {
        icon = "chevron.right",
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

    local function doNudge(axis, delta)
        format_dialog:onCloseKeyboard()
        if axis == "v" then
            line_v_nudge = line_v_nudge + delta
        else
            line_h_nudge = line_h_nudge + delta
        end
        applyLivePreview()
        format_dialog:reinit()
    end
    nudge_up.callback = function() doNudge("v", -1) end
    nudge_up.hold_callback = function() doNudge("v", -10) end
    nudge_down.callback = function() doNudge("v", 1) end
    nudge_down.hold_callback = function() doNudge("v", 10) end
    nudge_left.callback = function() doNudge("h", -1) end
    nudge_left.hold_callback = function() doNudge("h", -10) end
    nudge_right.callback = function() doNudge("h", 1) end
    nudge_right.hold_callback = function() doNudge("h", 10) end
    nudge_label.callback = function()
        format_dialog:onCloseKeyboard()
        line_v_nudge = 0
        line_h_nudge = 0
        applyLivePreview()
        format_dialog:reinit()
    end

    local function buildDialogButtons()
        local rows = {
            { style_button, size_button, font_button, case_button, page_filter_button },
            { nudge_left, nudge_right, nudge_label, nudge_up, nudge_down },
            { bar_style_button, bar_insert_button, bar_type_button },
        }
        table.insert(rows, {
            {
                text = _("Cancel"),
                callback = function()
                    self.positions[pos.key] = util.tableDeepCopy(original_settings)
                    self:savePositionSetting(pos.key)
                    UIManager:close(format_dialog)
                    self:markDirty()
                    if touchmenu_instance then
                        touchmenu_instance.item_table = self:buildPositionMenu(pos)
                    end
                    restoreMenu()
                end,
            },
            {
                text = _("Symbols"),
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
                        sparseRemove(pos_settings.line_style, line_idx)
                        sparseRemove(pos_settings.line_font_size, line_idx)
                        sparseRemove(pos_settings.line_font_face, line_idx)
                        sparseRemove(pos_settings.line_v_nudge, line_idx)
                        sparseRemove(pos_settings.line_h_nudge, line_idx)
                        sparseRemove(pos_settings.line_uppercase, line_idx)
                        sparseRemove(pos_settings.line_page_filter, line_idx)
                        sparseRemove(pos_settings.line_bar_type, line_idx)
                        sparseRemove(pos_settings.line_bar_height, line_idx)
                        sparseRemove(pos_settings.line_bar_style, line_idx)
                    else
                        pos_settings.lines[line_idx] = new_text
                        applyLivePreview()
                    end
                    self:savePositionSetting(pos.key)
                    UIManager:close(format_dialog)
                    self:markDirty()
                    if touchmenu_instance then
                        touchmenu_instance.item_table = self:buildPositionMenu(pos)
                    end
                    restoreMenu()
                end,
            },
        })
        return rows
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
                -- Mark dirty and request repaint immediately (not via nextTick)
                -- so it merges into the InputDialog's own paint cycle.  A deferred
                -- repaint causes a *separate* e-ink refresh that briefly flashes
                -- book text through the Bookends area.
                self.dirty = true
                self._tick_cache = nil
                UIManager:setDirty(self.ui, "fast")
            end
        end,
        buttons = buildDialogButtons(),
    }
    -- Allow tap-outside to hide keyboard, but never close dialog
    function format_dialog:onTap(arg, ges)
        if self:isKeyboardVisible() then
            if self._input_widget.keyboard and self._input_widget.keyboard.dimen
                    and ges.pos:notIntersectWith(self._input_widget.keyboard.dimen) then
                self:onCloseKeyboard()
            end
        end
        -- Never close the dialog on tap-outside
    end
    -- Always report keyboard as visible so dialog layout stays in upper portion.
    -- But track real keyboard state to avoid reopening it on reinit.
    local real_kb_visible = false
    local orig_isKeyboardVisible = format_dialog.isKeyboardVisible
    function format_dialog:isKeyboardVisible()
        return true  -- layout always reserves keyboard space
    end
    local orig_onShowKeyboard = format_dialog.onShowKeyboard
    function format_dialog:onShowKeyboard(...)
        real_kb_visible = true
        return orig_onShowKeyboard(self, ...)
    end
    local orig_onCloseKeyboard = format_dialog.onCloseKeyboard
    function format_dialog:onCloseKeyboard(...)
        real_kb_visible = false
        return orig_onCloseKeyboard(self, ...)
    end
    local orig_reinit = format_dialog.reinit
    function format_dialog:reinit(...)
        -- reinit checks isKeyboardVisible (returns true for layout),
        -- then calls onShowKeyboard if true. Suppress that when kb was actually hidden.
        local was_visible = real_kb_visible
        orig_reinit(self, ...)
        if not was_visible then
            self._input_widget:onCloseKeyboard()
            real_kb_visible = false
        end
        if self.movable then
            self.movable.ges_events.MovableHold = nil
            self.movable.ges_events.MovableHoldPan = nil
            self.movable.ges_events.MovableHoldRelease = nil
        end
    end
    if format_dialog.movable then
        format_dialog.movable.ges_events.MovableHold = nil
        format_dialog.movable.ges_events.MovableHoldPan = nil
        format_dialog.movable.ges_events.MovableHoldRelease = nil
    end
    UIManager:show(format_dialog)
    -- Hide keyboard after show — dialog is already positioned for keyboard-open,
    -- so it stays in the upper portion of screen, clear of the keyboard when reopened.
    format_dialog:onCloseKeyboard()
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
        sparseRemove(ps.line_bar_type, line_idx)
        sparseRemove(ps.line_bar_height, line_idx)
        sparseRemove(ps.line_bar_style, line_idx)
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
        if ps.line_bar_type then
            ps.line_bar_type[a], ps.line_bar_type[b] = ps.line_bar_type[b], ps.line_bar_type[a]
        end
        if ps.line_bar_height then
            ps.line_bar_height[a], ps.line_bar_height[b] = ps.line_bar_height[b], ps.line_bar_height[a]
        end
        if ps.line_bar_style then
            ps.line_bar_style[a], ps.line_bar_style[b] = ps.line_bar_style[b], ps.line_bar_style[a]
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
        target.line_bar_type = target.line_bar_type or {}
        target.line_bar_height = target.line_bar_height or {}
        target.line_bar_style = target.line_bar_style or {}

        -- Append to target
        local ti = #target.lines + 1
        target.lines[ti] = ps.lines[line_idx]
        target.line_style[ti] = ps.line_style and ps.line_style[line_idx] or nil
        target.line_font_size[ti] = ps.line_font_size and ps.line_font_size[line_idx] or nil
        target.line_font_face[ti] = ps.line_font_face and ps.line_font_face[line_idx] or nil
        target.line_v_nudge[ti] = ps.line_v_nudge and ps.line_v_nudge[line_idx] or nil
        target.line_h_nudge[ti] = ps.line_h_nudge and ps.line_h_nudge[line_idx] or nil
        target.line_uppercase[ti] = ps.line_uppercase and ps.line_uppercase[line_idx] or nil
        target.line_bar_type[ti] = ps.line_bar_type and ps.line_bar_type[line_idx] or nil
        target.line_bar_height[ti] = ps.line_bar_height and ps.line_bar_height[line_idx] or nil
        target.line_bar_style[ti] = ps.line_bar_style and ps.line_bar_style[line_idx] or nil

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

function Bookends:showFontPicker(current_face, on_select, default_face)
    local Blitbuffer = require("ffi/blitbuffer")
    local Button = require("ui/widget/button")
    local ButtonTable = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")
    local TopContainer = require("ui/widget/container/topcontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local FontList = require("fontlist")
    local ffiUtil = require("ffi/util")

    -- Build sorted font list from FontList.fontinfo (same source as FontChooser)
    local fonts = {}
    local font_display_names = {} -- file → display name lookup
    for font_file, font_info in pairs(FontList.fontinfo) do
        local info = font_info and font_info[1]
        if info then
            local name = FontList:getLocalizedFontName(font_file, 0) or info.name
            local display = name
            if info.bold then display = display .. " " .. _("bold") end
            if info.italic then display = display .. " " .. _("italic") end
            table.insert(fonts, { file = font_file, name = name, display = display })
            font_display_names[font_file] = display
        end
    end
    table.sort(fonts, function(a, b)
        if a.name ~= b.name then return ffiUtil.strcoll(a.name, b.name) end
        return ffiUtil.strcoll(a.display, b.display)
    end)

    local original_face = current_face
    local selected = current_face
    local per_page = 10
    local page = 1

    -- Find initial page for current font
    for i, f in ipairs(fonts) do
        if f.file == current_face then
            page = math.ceil(i / per_page)
            break
        end
    end
    local total_pages = math.max(1, math.ceil(#fonts / per_page))

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local width = math.floor(math.min(screen_w, screen_h) * 0.9)
    local font_size = 22
    local title_font_size = 22
    local row_height = Screen:scaleBySize(42)
    local left_pad = Size.padding.large

    local picker -- forward declaration

    local function buildPage()
        -- Custom title row: "Select font — FontName" with font name in its typeface
        local selected_name = selected and font_display_names[selected] or _("Default")
        local selected_face = selected and Font:getFace(selected, title_font_size)
                              or Font:getFace("cfont", title_font_size)
        local title_face = Font:getFace("infofont", title_font_size)
        local title_prefix = _("Select font") .. ": "
        local title_text = TextWidget:new{
            text = title_prefix,
            face = title_face,
            fgcolor = Blitbuffer.COLOR_BLACK,
            bold = true,
        }
        local title_text_width = title_text:getWidth()
        local font_name_widget = TextWidget:new{
            text = selected_name,
            face = selected_face,
            max_width = width - title_text_width - 2 * left_pad,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local title_row_height = Screen:scaleBySize(48)
        -- Use forced_height/baseline so both fonts share the same baseline
        title_text.forced_height = title_row_height
        title_text.forced_baseline = math.floor(title_row_height * 0.7)
        font_name_widget.forced_height = title_row_height
        font_name_widget.forced_baseline = math.floor(title_row_height * 0.7)
        local title_row = LeftContainer:new{
            dimen = Geom:new{ w = width, h = title_row_height },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = left_pad },
                title_text,
                font_name_widget,
            },
        }
        local title_line = LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = width, h = Size.line.thick },
        }

        local list_group = VerticalGroup:new{ align = "left" }
        local start_idx = (page - 1) * per_page + 1
        local end_idx = math.min(start_idx + per_page - 1, #fonts)

        for i = start_idx, end_idx do
            local f = fonts[i]
            local is_selected = (f.file == selected)
            local is_default = (f.file == default_face)
            local face = Font:getFace(f.file, font_size)

            local suffix = is_default and "  \xE2\x98\x85" or ""
            local label = f.display .. suffix

            -- Checkmark in a fixed-width area, then the font name
            local baseline = math.floor(row_height * 0.65)
            local check_w = TextWidget:new{
                text = is_selected and "\xE2\x9C\x93 " or "",
                face = Font:getFace("cfont", font_size),
                forced_height = row_height,
                forced_baseline = baseline,
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold = true,
            }
            local check_width = Screen:scaleBySize(30)

            local text_w = TextWidget:new{
                text = label,
                face = face,
                forced_height = row_height,
                forced_baseline = baseline,
                max_width = width - 2 * left_pad - check_width,
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold = is_selected,
            }

            local row_group = HorizontalGroup:new{
                HorizontalSpan:new{ width = left_pad },
                CenterContainer:new{
                    dimen = Geom:new{ w = check_width, h = row_height },
                    check_w,
                },
                text_w,
            }

            local item_container = InputContainer:new{
                dimen = Geom:new{ w = width, h = row_height },
                row_group,
            }
            item_container.ges_events = {
                TapSelect = { GestureRange:new{ ges = "tap", range = item_container.dimen } },
            }
            local font_file = f.file
            item_container.onTapSelect = safe("fontPicker:select", function()
                selected = font_file
                on_select(font_file)
                picker:rebuild()
                return true
            end)

            table.insert(list_group, item_container)
        end

        -- Page navigation row using icon buttons (matching KOReader style)
        local page_info_text = Button:new{
            text = T(_("Page %1 of %2"), page, total_pages),
            text_font_size = 16,
            text_font_bold = false,
            callback = function() end,
            bordersize = 0,
            show_parent = picker,
        }
        local page_first = Button:new{
            icon = "chevron.first",
            callback = function()
                page = 1
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page > 1,
            show_parent = picker,
        }
        local page_info_left = Button:new{
            icon = "chevron.left",
            callback = function()
                page = page - 1
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page > 1,
            show_parent = picker,
        }
        local page_info_right = Button:new{
            icon = "chevron.right",
            callback = function()
                page = page + 1
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page < total_pages,
            show_parent = picker,
        }
        local page_last = Button:new{
            icon = "chevron.last",
            callback = function()
                page = total_pages
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page < total_pages,
            show_parent = picker,
        }

        local nav_spacing = HorizontalSpan:new{ width = Screen:scaleBySize(8) }
        local page_nav = HorizontalGroup:new{
            align = "center",
            page_first,
            nav_spacing,
            page_info_left,
            HorizontalSpan:new{ width = Screen:scaleBySize(16) },
            page_info_text,
            HorizontalSpan:new{ width = Screen:scaleBySize(16) },
            page_info_right,
            nav_spacing,
            page_last,
        }

        local hairline = CenterContainer:new{
            dimen = Geom:new{ w = width, h = Size.line.thin },
            LineWidget:new{
                background = Blitbuffer.COLOR_DARK_GRAY,
                dimen = Geom:new{ w = width - 2 * Size.padding.default, h = Size.line.thin },
            },
        }

        -- Bottom action buttons
        local action_buttons = ButtonTable:new{
            width = width - 2 * Size.padding.default,
            buttons = {{
                {
                    text = _("Close"),
                    callback = function()
                        -- Revert to original font
                        if selected ~= original_face then
                            on_select(original_face)
                        end
                        UIManager:close(picker)
                    end,
                },
                {
                    text = _("Reset"),
                    enabled = selected ~= default_face,
                    callback = function()
                        selected = default_face
                        on_select(default_face)
                        UIManager:close(picker)
                    end,
                },
                {
                    text = _("Set font"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(picker)
                    end,
                },
            }},
            zero_sep = true,
            show_parent = picker,
        }

        local list_height = per_page * row_height
        local content = VerticalGroup:new{
            align = "center",
            title_row,
            title_line,
            TopContainer:new{
                dimen = Geom:new{ w = width, h = list_height },
                list_group,
            },
            hairline,
            VerticalSpan:new{ width = Size.span.vertical_default },
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = page_nav:getSize().h },
                page_nav,
            },
            VerticalSpan:new{ width = Size.span.vertical_default },
            CenterContainer:new{
                dimen = Geom:new{ w = width, h = action_buttons:getSize().h },
                action_buttons,
            },
        }

        return FrameContainer:new{
            radius = Size.radius.window,
            bordersize = Size.border.window,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            content,
        }
    end

    picker = InputContainer:new{
        ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ w = screen_w, h = screen_h },
                },
            },
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = Geom:new{ w = screen_w, h = screen_h },
                },
            },
        },
    }

    function picker:rebuild()
        local ok, frame = xpcall(buildPage, debug.traceback)
        if not ok then
            bookends_error("fontPicker:buildPage", frame)
            UIManager:close(self)
            return
        end
        self[1] = CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            frame,
        }
        self.frame = frame
        UIManager:setDirty(self, "ui")
    end

    function picker:onSwipe(_, ges_ev)
        local dir = ges_ev.direction
        if dir == "west" or dir == "north" then
            if page < total_pages then
                page = page + 1
                self:rebuild()
            end
        elseif dir == "east" or dir == "south" then
            if page > 1 then
                page = page - 1
                self:rebuild()
            end
        end
        return true
    end

    function picker:onTapClose(_, ges_ev)
        if self.frame and ges_ev.pos and not ges_ev.pos:intersectWith(self.frame.dimen) then
            -- Revert to original font on tap-outside
            if selected ~= original_face then
                on_select(original_face)
            end
            UIManager:close(self)
            return true
        end
        return false
    end

    function picker:onShow()
        UIManager:setDirty(self, "ui")
        return true
    end

    function picker:onCloseWidget()
        UIManager:setDirty(nil, "ui")
    end

    picker:rebuild()
    UIManager:show(picker)
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
    { _("Page / progress"), {
        { "%c", _("Current page number") },
        { "%t", _("Total pages") },
        { "%p", _("Book percentage read") },
        { "%P", _("Chapter percentage read") },
        { "%g", _("Pages read in chapter") },
        { "%G", _("Total pages in chapter") },
        { "%l", _("Pages left in chapter") },
        { "%L", _("Pages left in book") },
    }},
    { _("Progress bars"), {
        { "%bar", _("Progress bar (configure type in line editor)") },
    }},
    { _("Time / date"), {
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
    { _("Snippets"), {
        { "\xE2\x80\x94 Page %c of %t \xE2\x80\x94", "" },
        { "%T \xE2\x8B\xAE [i]%A[/i]", "" },
        { "%x Bookmark(s)", "" },
        { "%q Highlight(s)", "" },
        { "\xE2\x8C\x9B %R \xC2\xBB %s page session", "" },
    }},
}

function Bookends:showTokenPicker(on_select)
    local Menu = require("ui/widget/menu")
    local Size = require("ui/size")
    local Tokens = require("tokens")

    -- Resolve current values for each token
    local session_elapsed = self:getSessionElapsed()
    local session_pages = math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0))

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
            local token = token_entry[1]
            local desc = token_entry[2]
            -- Expand the token to get its current value
            local current = ""
            if self.ui then
                local expanded = Tokens.expand(token, self.ui, session_elapsed, session_pages,
                    nil, self.settings:readSetting("tick_width_multiplier", 2))
                if expanded and expanded ~= "" and expanded ~= token then
                    current = expanded
                end
            end
            local display = token .. "  " .. desc
            if current ~= "" then
                display = display .. "  \xE2\x86\x92 " .. current  -- → arrow
            end
            table.insert(items, {
                text = display,
                insert_value = token,
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
    -- Override popout corner radius and page text size to match font picker
    if menu[1] then menu[1].radius = Size.radius.window end
    local x = math.floor((Screen:getWidth() - menu.dimen.w) / 2)
    local y = math.floor((Screen:getHeight() - menu.dimen.h) / 2)
    UIManager:show(menu, nil, nil, x, y)
end

-- ─── Helpers ─────────────────────────────────────────────


function Bookends:_offerReleasesPage(message)
    local url = "https://github.com/AndyHazz/bookends.koplugin/releases"
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text = message .. "\n\n" .. _("Open the releases page in a browser?"),
            ok_text = _("Open"),
            ok_callback = function()
                Device:openLink(url)
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 3,
        })
    end
end

function Bookends:checkForUpdates()

    local DataStorage = require("datastorage")
    local meta_path = DataStorage:getDataDir() .. "/plugins/bookends.koplugin/_meta.lua"
    local ok_meta, meta = pcall(dofile, meta_path)
    local installed_version = (ok_meta and meta and meta.version) or "unknown"

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
        local json = require("json")

        -- Try LuaSocket first, fall back to curl for platforms where SSL crashes
        local function httpGetJSON(url)
            local ok_require, http, ltn12, socket, socketutil =
                pcall(function()
                    return require("socket/http"),
                           require("ltn12"),
                           require("socket"),
                           require("socketutil")
                end)
            if ok_require then
                local body = {}
                local ok_req, code = pcall(function()
                    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
                    local c = socket.skip(1, http.request({
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
                    return c
                end)
                if ok_req and code == 200 then
                    local ok, data = pcall(json.decode, table.concat(body))
                    if ok then return data end
                end
                pcall(function() socketutil:reset_timeout() end)
            end
            -- Fallback: curl (available on Android, desktop)
            local handle = io.popen(string.format(
                "curl -s -L -H 'User-Agent: KOReader-Bookends' -H 'Accept: application/vnd.github.v3+json' %q",
                url))
            if handle then
                local body = handle:read("*a")
                handle:close()
                if body and body ~= "" then
                    local ok, data = pcall(json.decode, body)
                    if ok then return data end
                end
            end
            return nil
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
        local releases = httpGetJSON("https://api.github.com/repos/AndyHazz/bookends.koplugin/releases")
        if not releases or #releases == 0 then
            self:_offerReleasesPage(_("Could not check for updates."))
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
        -- Download ZIP to temp location
        local cache_dir = DataStorage:getSettingsDir() .. "/bookends_cache"
        if lfs.attributes(cache_dir, "mode") ~= "directory" then
            lfs.mkdir(cache_dir)
        end
        local zip_path = cache_dir .. "/bookends.koplugin.zip"

        -- Try LuaSocket first, fall back to curl
        local downloaded = false
        local ok_require, http, ltn12, socket, socketutil =
            pcall(function()
                return require("socket/http"),
                       require("ltn12"),
                       require("socket"),
                       require("socketutil")
            end)
        if ok_require then
            local file = io.open(zip_path, "wb")
            if file then
                local ok_dl, code = pcall(function()
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                    local c = socket.skip(1, http.request({
                        url = zip_url,
                        method = "GET",
                        headers = {
                            ["User-Agent"] = "KOReader-Bookends/" .. old_version,
                        },
                        sink = ltn12.sink.file(file),
                        redirect = true,
                    }))
                    socketutil:reset_timeout()
                    return c
                end)
                if not ok_dl then
                    pcall(function() socketutil:reset_timeout() end)
                end
                downloaded = ok_dl and code == 200
            end
        end
        -- Fallback: curl (available on Android, desktop)
        if not downloaded then
            pcall(os.remove, zip_path)
            local ret = os.execute(string.format(
                "curl -s -L -o %q %q", zip_path, zip_url))
            downloaded = ret == 0 or ret == true
        end
        if not downloaded then
            pcall(os.remove, zip_path)
            self:_offerReleasesPage(_("Download failed."))
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


function Bookends:showMarginAdjuster(touchmenu_instance)
    local restoreMenu = self:hideMenu(touchmenu_instance)
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
                    restoreMenu()
                end,
            },
            {
                text = _("Default"),
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
                text = _("Apply"),
                is_enter_default = true,
                callback = function()
                    self.settings:saveSetting("margin_top", self.defaults.margin_top)
                    self.settings:saveSetting("margin_bottom", self.defaults.margin_bottom)
                    self.settings:saveSetting("margin_left", self.defaults.margin_left)
                    self.settings:saveSetting("margin_right", self.defaults.margin_right)
                    UIManager:close(margin_dialog)
                    restoreMenu()
                end,
            },
        },
    }

    local ButtonDialog = require("ui/widget/buttondialog")
    margin_dialog = ButtonDialog:new{
        dismissable = false,
        title = _("Adjust margins"),
        buttons = buttons,
    }
    UIManager:show(margin_dialog)
end

return Bookends
