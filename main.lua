-- One-time cleanup: pre-v4.0.1 Bookends shipped its internal modules with
-- generic names (config.lua, utils.lua, i18n.lua, etc.) which collided with
-- identically-named modules in other plugins via Lua's package.loaded cache.
-- v4.0.1 renamed them to bookends_*.lua but upgrades via the updates manager
-- extract over the old dir, leaving orphan copies behind. Delete them before
-- any other plugin has a chance to require one of them.
do
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    local plugin_dir = src:match("^@(.+)/[^/]+$")
    if plugin_dir then
        local orphans = {
            "config.lua", "utils.lua", "tokens.lua", "updater.lua", "i18n.lua",
            "overlay_widget.lua", "dialog_helpers.lua", "icon_picker.lua",
            "line_editor.lua",
        }
        for _, f in ipairs(orphans) do
            os.remove(plugin_dir .. "/" .. f)
        end
    end
end

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Config = require("bookends_config")
local ConfirmBox = require("ui/widget/confirmbox")
local DialogHelpers = require("bookends_dialog_helpers")
local Device = require("device")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local OverlayWidget = require("bookends_overlay_widget")
local Tokens = require("bookends_tokens")
local Updater = require("bookends_updater")
local UIManager = require("ui/uimanager")
local Utils = require("bookends_utils")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("bookends_i18n").gettext
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

local Bookends = WidgetContainer:extend{
    name = "bookends",
    is_doc_only = true,
}

-- Toast overlay that paints a page-coloured halo behind ReaderFlipping's
-- top-left indicator (CRe re-render, page-flip, highlight-mode icons) and
-- re-paints the icon on top. Lives on UIManager._window_stack so it paints
-- after every ReaderView pass — the in-ReaderView attempt was clobbered by
-- whichever view module happened to iterate last. invisible=true keeps it
-- out of getTopmostVisibleWidget so it can't block ReaderRolling's reload
-- gate (the bug we fixed by gutting the old dogear overlay).
local FlippingHaloOverlay = WidgetContainer:extend{
    name = "BookendsFlippingHalo",
    toast = true,
    invisible = true,
    covers_fullscreen = false,
}

function FlippingHaloOverlay:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
end

function FlippingHaloOverlay:paintTo(bb, x, y)
    local b = self._bookends
    if not b or not b.enabled then return end
    if not b:_flippingWillPaintIcon() then return end
    -- Suppress if the topmost widget above ReaderUI has a dimen that covers
    -- the icon corner (TouchMenu, TOC, etc). Small dialogs with centred
    -- dimens don't reach the corner, so they pass. ButtonDialog does this
    -- correctly on its own; widgets wrapping a CenterContainer need to
    -- override paintTo to report the inner frame's dimen (see the preset
    -- library modal).
    local icon_size = Screen:scaleBySize(32)
    local top = UIManager:getTopmostVisibleWidget()
    if top and top.name ~= "ReaderUI" and top.dimen then
        local d, px, py = top.dimen, x + icon_size / 2, y + icon_size / 2
        if px >= d.x and px < d.x + d.w and py >= d.y and py < d.y + d.h then
            return
        end
    end

    local view = b.ui.view
    local flipping = view.flipping
    local icon_size = Screen:scaleBySize(32)
    local halo_pad = Screen:scaleBySize(6)
    local halo_radius = math.floor(icon_size / 2) + halo_pad
    local halo_color = view.page_bgcolor or Blitbuffer.COLOR_WHITE
    local border_color = Blitbuffer.gray(0.65) -- medium-light grey
    local border_width = math.max(1, Screen:scaleBySize(1))
    local cx = x + math.floor(icon_size / 2)
    local cy = y + math.floor(icon_size / 2)
    -- Filled halo in page colour, then a thin grey outline to keep it
    -- reading as an intentional shape where it crops nearby content.
    bb:paintCircle(cx, cy, halo_radius, halo_color, halo_radius)
    bb:paintCircle(cx, cy, halo_radius, border_color, border_width)
    flipping:paintTo(bb, x, y)
end

-- Position keys and their properties
Bookends.POSITIONS = {
    { key = "tl", label = _("Top-left"),      row = "top",    h_anchor = "left",   v_anchor = "top" },
    { key = "tc", label = _("Top-center"),     row = "top",    h_anchor = "center", v_anchor = "top" },
    { key = "tr", label = _("Top-right"),      row = "top",    h_anchor = "right",  v_anchor = "top" },
    { key = "bl", label = _("Bottom-left"),    row = "bottom", h_anchor = "left",   v_anchor = "bottom" },
    { key = "bc", label = _("Bottom-center"),  row = "bottom", h_anchor = "center", v_anchor = "bottom" },
    { key = "br", label = _("Bottom-right"),   row = "bottom", h_anchor = "right",  v_anchor = "bottom" },
}

Bookends.MAX_BARS = Config.MAX_BARS
Bookends.DEFAULT_MARGINS = Config.DEFAULT_MARGINS
Bookends.DEFAULT_TICK_WIDTH_MULTIPLIER = Config.DEFAULT_TICK_WIDTH_MULTIPLIER

-- Attach non-core behaviour defined in dedicated files to keep main.lua focused.
require("bookends_line_editor").attach(Bookends)
require("preset_manager").attach(Bookends)
require("menu.colours_menu")(Bookends)
require("menu.main_menu")(Bookends)
require("menu.position_menu")(Bookends)
require("menu.progress_bar_menu")(Bookends)
require("menu.token_picker")(Bookends)
require("bookends_colour_palette").attach(Bookends)
require("bookends_textwidget_patch")  -- TextWidget: paint ColorRGB32 fgcolor as true colour

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

    -- Preset Manager: one-time migration + first-run provisioning
    self:runPresetManagerMigration()

    -- Re-apply the active preset on startup to re-establish the invariant
    -- "live settings == active preset file". An interrupted preview (crash,
    -- back-button dismissal) can leave bookends.lua holding the preview's
    -- state while active_preset_filename still points at the previous
    -- preset. Without this, the next autosave flush would overwrite the
    -- active preset file with the leaked preview data.
    do
        local active = self:getActivePresetFilename()
        if active then
            local lfs = require("libs/libkoreader-lfs")
            local path = self:presetDir() .. "/" .. active
            if lfs.attributes(path, "mode") == "file" then
                pcall(self.applyPresetFile, self, active)
            end
        end
    end

    -- Register gesture/dispatcher actions
    self:onDispatcherRegisterActions()

    -- Register hold-to-skim touch zone
    self:setupTouchZones()

    -- Apply stock bar disable if our setting is active
    if self.stock_bar_disabled then
        local footer = self.ui.view.footer
        if footer then
            footer:applyFooterMode(footer.mode_list.off)
        end
    end

    -- Background update check on book open (opt-in only, throttled to once/hour)
    self:backgroundUpdateCheck()

    -- Register the flipping-halo toast overlay (see FlippingHaloOverlay above).
    if not self._flipping_halo then
        self._flipping_halo = FlippingHaloOverlay:new{ _bookends = self }
        UIManager:show(self._flipping_halo)
    end
end

function Bookends:onCloseDocument()
    if self._flipping_halo then
        UIManager:close(self._flipping_halo)
        self._flipping_halo = nil
    end
end

function Bookends:onDispatcherRegisterActions()
    local Dispatcher = require("dispatcher")
    -- Titles all begin with "Bookends:" so the four actions read as a single
    -- block in KOReader's Gesture Manager. Registration order controls the
    -- picker's display order (see Dispatcher.dispatcher_menu_order) so they
    -- appear consecutively. Separator on the last item closes the group.
    -- IDs are kept stable — renaming IDs would break existing bindings.
    Dispatcher:registerAction("toggle_bookends", {
        category = "none",
        event = "ToggleBookends",
        title = _("Bookends: toggle visibility"),
        reader = true,
    })
    Dispatcher:registerAction("cycle_bookends_preset", {
        category = "none",
        event = "CycleBookendsPreset",
        title = _("Bookends: cycle preset"),
        reader = true,
    })
    Dispatcher:registerAction("set_bookends", {
        category = "string",
        event = "SetBookends",
        title = _("Bookends: set visibility"),
        reader = true,
        args = {true, false},
        toggle = {_("on"), _("off")},
    })
    Dispatcher:registerAction("bookends_open_manager", {
        category = "none",
        event = "OpenPresetManager",
        title = _("Bookends: open preset library"),
        reader = true,
        separator = true,
    })
end

function Bookends:onOpenPresetManager()
    local PresetManagerModal = require("menu/preset_manager_modal")
    PresetManagerModal.show(self)
    return true
end

--- One-time migration + first-run provisioning for the Preset Manager.
--- Idempotent — gated by preset_manager_migration_done flag.
function Bookends:runPresetManagerMigration()
    if self.settings:isTrue("preset_manager_migration_done") then return end

    local lfs = require("libs/libkoreader-lfs")

    -- 1. Rename last_cycled_preset (human name) → active_preset_filename (file)
    local last_name = self.settings:readSetting("last_cycled_preset")
    if last_name and last_name ~= "" then
        local presets = self:readPresetFiles()
        for _, p in ipairs(presets) do
            if p.name == last_name then
                self.settings:saveSetting("active_preset_filename", p.filename)
                break
            end
        end
        self.settings:delSetting("last_cycled_preset")
    end

    -- 2. Seed preset_cycle with all existing Personal presets
    if not self.settings:readSetting("preset_cycle") then
        local presets = self:readPresetFiles()
        local cycle = {}
        for _, p in ipairs(presets) do
            table.insert(cycle, p.filename)
        end
        self.settings:saveSetting("preset_cycle", cycle)
    end

    -- 3. First-run provisioning. Two distinct cases:
    --    (a) Brand-new user — empty presets dir AND no existing layout →
    --        provision Basic bookends and make it active.
    --    (b) v3.x upgrader — empty presets dir BUT has a customised layout
    --        in settings → snapshot their layout as a preset called
    --        "My setup" and make THAT active. This preserves the v4
    --        "everything is a preset" invariant, so autosave / cycle /
    --        Preset menu all have something real to hook into.
    -- In both cases Basic bookends lands in the library as a reference.
    self:ensurePresetDir()
    local dir = self:presetDir()
    local has_any = false
    for f in lfs.dir(dir) do
        if f:match("%.lua$") then has_any = true; break end
    end
    if not has_any then
        -- Detect an existing v3.x layout: any position with configured lines.
        local has_existing_layout = false
        for _, pos in ipairs(self.POSITIONS) do
            local saved = self.settings:readSetting("pos_" .. pos.key)
            if saved and saved.lines and #saved.lines > 0 then
                has_existing_layout = true
                break
            end
        end

        -- Always copy Basic bookends into the library as a reference.
        local DataStorage = require("datastorage")
        local source = DataStorage:getDataDir() .. "/plugins/bookends.koplugin/basic_bookends.lua"
        local dest = dir .. "/basic_bookends.lua"
        local src_file = io.open(source, "rb")
        if src_file then
            local dst_file = io.open(dest, "wb")
            if dst_file then
                dst_file:write(src_file:read("*a"))
                dst_file:close()
            end
            src_file:close()
        end

        local cycle = self.settings:readSetting("preset_cycle") or {}
        table.insert(cycle, "basic_bookends.lua")

        if has_existing_layout then
            -- Snapshot the user's v3.x layout as a preset and make it active.
            local ok, data = pcall(self.buildPreset, self)
            if ok and data then
                data.name = _("My setup")
                data.description = _("Imported from your earlier Bookends settings")
                local ok_write, user_filename = pcall(self.writePresetFile, self, data.name, data)
                if ok_write and user_filename then
                    self.settings:saveSetting("active_preset_filename", user_filename)
                    table.insert(cycle, user_filename)
                end
            end
        elseif not self.settings:readSetting("active_preset_filename") then
            -- Genuine first-run: Basic bookends becomes active.
            self.settings:saveSetting("active_preset_filename", "basic_bookends.lua")
        end

        self.settings:saveSetting("preset_cycle", cycle)
    end

    self.settings:saveSetting("preset_manager_migration_done", true)

    -- Recovery migration for users who went through v4.0.0–v4.0.2's
    -- provisioning path and ended up in "detached state" — a customised
    -- layout in settings but no active_preset_filename, because the
    -- earlier migration either (a) wiped their layout onto Basic bookends
    -- and they restored from backup without re-applying a preset, or
    -- (b) v4.0.2 skipped setting active but didn't snapshot their layout.
    -- Idempotent via its own flag; only runs once.
    if not self.settings:isTrue("detached_state_recovery_done") then
        if not self:getActivePresetFilename() then
            local has_layout = false
            for _, pos in ipairs(self.POSITIONS) do
                local saved = self.settings:readSetting("pos_" .. pos.key)
                if saved and saved.lines and #saved.lines > 0 then
                    has_layout = true
                    break
                end
            end
            if has_layout then
                local ok, data = pcall(self.buildPreset, self)
                if ok and data then
                    data.name = _("My setup")
                    data.description = _("Imported from your earlier Bookends settings")
                    local ok_write, fn = pcall(self.writePresetFile, self, data.name, data)
                    if ok_write and fn then
                        self.settings:saveSetting("active_preset_filename", fn)
                        local cycle = self.settings:readSetting("preset_cycle") or {}
                        -- Only add if not already there
                        local already_in = false
                        for _, f in ipairs(cycle) do
                            if f == fn then already_in = true; break end
                        end
                        if not already_in then
                            table.insert(cycle, fn)
                            self.settings:saveSetting("preset_cycle", cycle)
                        end
                    end
                end
            end
        end
        self.settings:saveSetting("detached_state_recovery_done", true)
    end

    self.settings:flush()
end

function Bookends:setupTouchZones()
    if not Device:isTouchDevice() then return end
    local DTAP_ZONE_MINIBAR = G_defaults:readSetting("DTAP_ZONE_MINIBAR")
    self.ui:registerTouchZones({
        {
            id = "bookends_footer_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MINIBAR.x, ratio_y = DTAP_ZONE_MINIBAR.y,
                ratio_w = DTAP_ZONE_MINIBAR.w, ratio_h = DTAP_ZONE_MINIBAR.h,
            },
            handler = function(ges)
                local action = self.settings:readSetting("bottom_center_tap_action")
                if action == "toggle" then
                    self:onToggleBookends()
                    return true
                elseif action == "cycle" then
                    self:onCycleBookendsPreset()
                    return true
                elseif action == "library" then
                    self:onOpenPresetManager()
                    return true
                end
                -- Block the stock footer from re-appearing when we've disabled it
                if self.stock_bar_disabled then
                    return true
                end
            end,
            overrides = {
                "readerfooter_tap",
            },
        },
        {
            id = "bookends_hold",
            ges = "hold",
            screen_zone = {
                ratio_x = 0, ratio_y = 0,
                ratio_w = 1, ratio_h = 1,
            },
            handler = function(ges) return self:onHoldBookends(ges) end,
            overrides = {
                "readerhighlight_hold",
            },
        },
    })
end

function Bookends:onHoldBookends(ges)
    if not self.enabled or not self.skim_on_hold then return end
    local rects = self._hold_rects
    if not rects or #rects == 0 then return end
    local pos = ges.pos
    local PAD = Screen:scaleBySize(15)
    for _, r in ipairs(rects) do
        if pos.x >= r.x - PAD and pos.x < r.x + r.w + PAD
           and pos.y >= r.y - PAD and pos.y < r.y + r.h + PAD then
            local Event = require("ui/event")
            self.ui:handleEvent(Event:new("ShowSkimtoDialog"))
            return true
        end
    end
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
    -- Flush first so unsaved overlay edits autosave to the departing preset.
    if self.settings then self.settings:flush() end
    local ok_save, save_err = pcall(self.autosaveActivePreset, self)
    if not ok_save then require("logger").warn("bookends: pre-cycle autosave failed:", save_err) end

    -- Strip any legacy "_empty" sentinel from the cycle. It used to mean
    -- "cycle to a blank overlay" but we've removed that concept — users who
    -- want a blank state can create an empty preset instead.
    local cycle_raw = self.settings:readSetting("preset_cycle") or {}
    local cycle = {}
    for _, entry in ipairs(cycle_raw) do
        if entry ~= "_empty" then cycle[#cycle + 1] = entry end
    end
    if #cycle ~= #cycle_raw then
        self.settings:saveSetting("preset_cycle", cycle)
    end
    if #cycle == 0 then return true end

    local active = self:getActivePresetFilename()
    local idx = 1
    for i, entry in ipairs(cycle) do
        if entry == active then
            idx = (i % #cycle) + 1
            break
        end
    end

    local next_entry = cycle[idx]
    local Notification = require("ui/widget/notification")

    local ok, err = self:applyPresetFile(next_entry)
    if not ok then
        Notification:notify(T(_("Preset error: %1"), tostring(err)))
        return true
    end
    self:markDirty()
    local presets = self:readPresetFiles()
    local name = next_entry
    for _, p in ipairs(presets) do
        if p.filename == next_entry then name = p.name; break end
    end
    Notification:notify(T(_("Preset: %1"), name))
    return true
end

function Bookends:openSettings()
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local settings_path = DataStorage:getSettingsDir() .. "/bookends.lua"
    self.settings = LuaSettings:open(settings_path)

    -- One-time migration from G_reader_settings
    if not self.settings:has("migrated") then
        for _, key in ipairs(Config.LEGACY_GLOBAL_KEYS) do
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
        margin_top    = self.settings:readSetting("margin_top", self.DEFAULT_MARGINS.margin_top),
        margin_bottom = self.settings:readSetting("margin_bottom", self.DEFAULT_MARGINS.margin_bottom),
        margin_left   = self.settings:readSetting("margin_left", self.DEFAULT_MARGINS.margin_left),
        margin_right  = self.settings:readSetting("margin_right", self.DEFAULT_MARGINS.margin_right),
        font_scale = self.settings:readSetting("font_scale", 100),
        overlap_gap = self.settings:readSetting("overlap_gap", 50),
        truncation_priority = self.settings:readSetting("truncation_priority", "center"),
    }

    self.skim_on_hold = self.settings:readSetting("skim_on_hold", true)
    self.check_updates = self.settings:readSetting("check_updates", false)
    self.dev_branch = self.settings:readSetting("dev_branch", "")
    self.last_install_source = self.settings:readSetting("last_install_source", "release")
    self.stock_bar_disabled = self.settings:readSetting("stock_bar_disabled", false)
    -- Mirror to the Tokens module so %L / %l can read without a settings
    -- handle. main.lua owns the settings; Tokens just consults the flag.
    Tokens.pages_left_includes_current = self.settings:isTrue("pages_left_includes_current")

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
            -- First run: use default configuration (deep-copy the shared constant)
            self.positions[pos.key] = util.tableDeepCopy(Config.DEFAULT_POSITIONS[pos.key]) or { lines = {} }
        end
    end

    -- Full-width progress bars
    self.progress_bars = {}
    for i = 1, Config.MAX_BARS do
        local default = util.tableDeepCopy(Config.BAR_DEFAULTS)
        if i == 1 then default.chapter_ticks = "all" end
        if i == 2 then default.type = "chapter" end
        self.progress_bars[i] = self.settings:readSetting("progress_bar_" .. i, default)
        -- Migrate old boolean show_chapter_ticks → chapter_ticks string
        local bar = self.progress_bars[i]
        if bar.show_chapter_ticks ~= nil then
            bar.chapter_ticks = bar.show_chapter_ticks and "level1" or "off"
            bar.show_chapter_ticks = nil
            self.settings:saveSetting("progress_bar_" .. i, bar)
        end
    end

    self:migrateSchemaIfNeeded()
end

--- One-shot migration of persisted preset/position data to the current
--- Config.SCHEMA_VERSION. Runs at load time; cheap no-op once schema_version
--- is up to date. Walks live self.positions + every saved preset file on
--- disk, canonicalising any legacy tokens to their v5 equivalents.
--- The render-level alias table still handles legacy tokens forever for
--- gallery presets, so this migration is a local-data cleanup — not load-
--- bearing for compatibility.
function Bookends:migrateSchemaIfNeeded()
    -- Positions: canonicaliseLegacy is idempotent and cheap, so we run it
    -- every startup rather than gating on schema_version. Gating only fixed
    -- the "upgrade from v4" case; a legacy token introduced later (manual
    -- edit, gallery install before its own file-level migration completes)
    -- would otherwise persist forever. The per-line `changed` guard keeps
    -- startup cost near zero when there's nothing to rewrite.
    for _, pos in ipairs(self.POSITIONS) do
        local pos_settings = self.positions[pos.key]
        if pos_settings and pos_settings.lines then
            local changed = false
            for i, line in ipairs(pos_settings.lines) do
                local new_line = Tokens.canonicaliseLegacy(line or "")
                if new_line ~= line then
                    pos_settings.lines[i] = new_line
                    changed = true
                end
            end
            if changed then
                self.settings:saveSetting("pos_" .. pos.key, pos_settings)
            end
        end
    end
    self.settings:saveSetting("schema_version", Config.SCHEMA_VERSION)

    -- Preset files on disk: each file carries its own schema_version so
    -- newly-dropped legacy files (e.g. from a backup, a shared snippet, or
    -- a gallery install) get migrated on the next startup even after the
    -- settings-level flag has already been bumped. readPresetFiles() returns
    -- entries of shape { name, filename, preset } — `preset` is the parsed
    -- table already; no need to reload via loadPresetFile.
    local preset_infos = self:readPresetFiles() or {}
    for _, info in ipairs(preset_infos) do
        local data = info.preset
        if data then
            local file_version = tonumber(data.schema_version) or 1
            if file_version < Config.SCHEMA_VERSION then
                if type(data.positions) == "table" then
                    for _pos_key, pos_data in pairs(data.positions) do
                        if type(pos_data) == "table" and type(pos_data.lines) == "table" then
                            for i, line in ipairs(pos_data.lines) do
                                pos_data.lines[i] = Tokens.canonicaliseLegacy(line or "")
                            end
                        end
                    end
                end
                data.schema_version = Config.SCHEMA_VERSION
                self:updatePresetFile(info.filename, data.name or info.filename, data)
            end
        end
    end
end

function Bookends:buildPreset()
    local preset = {
        -- `enabled` is deliberately NOT in presets — it's a global on/off
        -- switch, not a visual style. Older preset files may still contain
        -- it; loadPreset ignores the field.
        defaults = util.tableDeepCopy(self.defaults),
        positions = {},
    }
    -- Exclude default font so presets adapt to the user's installed font
    preset.defaults.font_face = nil
    for _, pos in ipairs(self.POSITIONS) do
        preset.positions[pos.key] = util.tableDeepCopy(self.positions[pos.key])
    end
    preset.progress_bars = util.tableDeepCopy(self.progress_bars)
    for _, key in ipairs(Config.PRESET_OPTIONAL_KEYS) do
        preset[key] = self.settings:readSetting(key)
    end
    preset.schema_version = Config.SCHEMA_VERSION
    return preset
end

function Bookends:loadPreset(preset)
    -- Ignore preset.enabled — it's a global on/off, not a style (kept in
    -- older files but no longer applied on load).
    if preset.defaults then
        local pd = preset.defaults
        -- Ignore old v_offset/h_offset keys from pre-v2 presets
        pd.v_offset = nil
        pd.h_offset = nil
        -- Never override the user's default font from a preset
        pd.font_face = nil
        -- Reset margins before applying preset values
        for k, v in pairs(Config.DEFAULT_MARGINS) do
            self.defaults[k] = v
        end
        for k, v in pairs(pd) do
            self.defaults[k] = v
        end
        for _, key in ipairs(Config.DEFAULTS_KEYS) do
            self.settings:saveSetting(key, self.defaults[key])
        end
    end
    if preset.positions then
        for _, pos in ipairs(self.POSITIONS) do
            if preset.positions[pos.key] then
                local copy = util.tableDeepCopy(preset.positions[pos.key])
                -- Canonicalise any legacy tokens on the way in, so gallery
                -- presets or side-loaded files don't leak %T/%A/etc. into
                -- live position state ahead of the next startup migration.
                if type(copy.lines) == "table" then
                    for i, line in ipairs(copy.lines) do
                        copy.lines[i] = Tokens.canonicaliseLegacy(line or "")
                    end
                end
                self.positions[pos.key] = copy
                self:savePositionSetting(pos.key)
            end
        end
    end
    self.progress_bars = preset.progress_bars and util.tableDeepCopy(preset.progress_bars) or {}
    -- Always ensure exactly MAX_BARS bar slots exist, then persist each
    for i = 1, Config.MAX_BARS do
        if not self.progress_bars[i] then
            self.progress_bars[i] = util.tableDeepCopy(Config.BAR_DEFAULTS)
        end
        self.settings:saveSetting("progress_bar_" .. i, self.progress_bars[i])
    end
    for _, key in ipairs(Config.PRESET_OPTIONAL_KEYS) do
        if preset[key] then
            self.settings:saveSetting(key, preset[key])
        else
            self.settings:delSetting(key)
        end
    end
    self._tick_cache = nil
    self:markDirty()
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

--- Returns true if any active line's format string references one of the
--- given v5 bareword tokens (e.g. {"light", "warmth"}). Mirrors the
--- non-ident word-boundary rule used by Tokens.expand's `needs()` helper.
function Bookends:anyActiveLineUses(token_names)
    if not self.enabled then return false end
    for _, pos in ipairs(self.POSITIONS) do
        if self:isPositionActive(pos.key) then
            for _, line in ipairs(self.positions[pos.key].lines) do
                for _, name in ipairs(token_names) do
                    if line:find("%%" .. name .. "[^%w_]") or line:match("%%" .. name .. "$") then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Shared dirty-flag bookkeeping + nextTick debounce. Callers supply the
-- dispatcher that decides which setDirty calls to actually issue.
function Bookends:_scheduleRepaint(dispatcher)
    self.dirty = true
    self._tick_cache = nil
    if not self._error_disabled then
        self.enabled = self.settings:isTrue("enabled")
    end
    if not self._repaint_scheduled then
        self._repaint_scheduled = true
        UIManager:nextTick(function()
            self._repaint_scheduled = false
            if self.dirty then dispatcher() end
        end)
    end

    -- Debounced autosave. settings:saveSetting only updates RAM; without this
    -- debounce, edits aren't persisted until onFlushSettings fires (book close
    -- / suspend). 2s is tight enough to feel instant and loose enough to
    -- coalesce a burst of menu taps or nudge-dialog adjustments.
    if self._pending_autosave then
        UIManager:unschedule(self._pending_autosave)
    end
    self._pending_autosave = function()
        self._pending_autosave = nil
        if self.settings then pcall(function() self.settings:flush() end) end
        pcall(self.autosaveActivePreset, self)
    end
    UIManager:scheduleIn(2, self._pending_autosave)
end

function Bookends:markDirty(refresh_mode)
    local mode = refresh_mode or "ui"
    self:_scheduleRepaint(function()
        UIManager:setDirty(self.ui, mode)
    end)
end

-- Targeted refresh of just the overlay regions populated by the last paint.
-- Used by value-tick repaints (heartbeat timer, gated system events) where
-- the overlay's geometry hasn't changed — only the rendered content has.
-- Two benefits:
--   1. The setDirty calls carry a region, so user patches that hook _refresh
--      and look for "ui" + nil-region (e.g. 2-dim-during-refresh.lua) won't
--      treat our refresh as a flashing one and won't dim the frontlight.
--   2. Smaller dirty area = smaller nightmode flash and less battery.
-- Falls back to the full markDirty path until the first paint has populated
-- the region cache (chicken-and-egg: we don't know the dimen pre-paint).
function Bookends:markOverlayDirty()
    if not self._top_paint_rect and not self._bottom_paint_rect then
        return self:markDirty()
    end
    self:_scheduleRepaint(function()
        if self._top_paint_rect then
            UIManager:setDirty(self.ui, "ui", self._top_paint_rect)
        end
        if self._bottom_paint_rect then
            UIManager:setDirty(self.ui, "ui", self._bottom_paint_rect)
        end
    end)
end

--- Compute chapter tick fractions for book progress bars (cached per dirty cycle).
function Bookends:_computeTickCache()
    local tick_m = self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER)
    return Tokens.computeTickFractions(self.ui.document, self.ui.toc, tick_m)
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
    -- Resolve @family:<key> sentinels before any variant lookup.
    face_name = Utils.resolveFontFace(face_name, self.defaults.font_face)
    local resolved_face = face_name
    local synthetic_bold = false

    if style ~= "regular" then
        -- Try to find the exact real font file for this style
        local variant = OverlayWidget.findFontVariant(face_name, style)
        if variant then
            resolved_face = variant
        elseif style == "bold" then
            synthetic_bold = true
        elseif style == "bolditalic" then
            -- Fallback: italic file + synthetic bold
            local italic = OverlayWidget.findFontVariant(face_name, "italic")
            if italic then
                resolved_face = italic
                synthetic_bold = true
            else
                synthetic_bold = true
            end
        end
        -- italic with no file found: use base face (no synthetic italic available)
    end

    -- Apply font scale
    local scale = self.defaults.font_scale or 100
    local scaled_size = math.max(1, math.floor(font_size * scale / 100 + 0.5))

    -- Font:getFace can return nil for unknown files. Fall back to cfont so a
    -- stale setting (font removed, family map points at uninstalled font) can't
    -- crash the overlay.
    local face = Font:getFace(resolved_face, scaled_size) or Font:getFace("cfont", scaled_size)

    return {
        face = face,
        bold = synthetic_bold,
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

--- KOReader broadcasts ColorRenderingUpdate when the user toggles colour
--- rendering in Settings → Screen (screen_color_menu_table.lua, single
--- broadcast site).  Flush the hex cache so the next paint reconstructs
--- Blitbuffer values in the new mode, then mark the overlay dirty so it
--- repaints.  The defensive auto-flush in parseColorValue is a belt-and-
--- braces fallback in case the event fires before our handler is registered
--- or a future KOReader refactor moves the broadcast site.
function Bookends:onColorRenderingUpdate()
    require("bookends_colour").flushCache()
    self:markDirty()
end

-- Repaint after system events that change token values (battery, frontlight, etc.).
-- These events don't trigger a ReaderView repaint on their own, so we need
-- markDirty() to request one.  Use a nextTick to avoid interrupting the
-- event's own processing.
function Bookends:delayedRepaint()
    UIManager:nextTick(function()
        self:markDirty()
    end)
end

-- Token-gated, optionally debounced repaint. Skips entirely when no active
-- line uses any of the given tokens — both an efficiency win and, for
-- frontlight events, the cure for a feedback loop with user patches like
-- 2-dim-during-refresh.lua: that patch calls setIntensity() inside its
-- _refresh hook, which broadcasts FrontlightStateChanged, which used to
-- schedule another "ui" refresh here, which the patch would then dim again.
-- The debounce coalesces the patch's dim/restore pair so any repaint we
-- do schedule lands outside the patch's 0.17 s `restoring` window.
function Bookends:gatedRepaint(token_names, debounce)
    if not self:anyActiveLineUses(token_names) then return end
    if debounce and debounce > 0 then
        if self._gated_repaint_pending then
            UIManager:unschedule(self._gated_repaint_pending)
        end
        self._gated_repaint_pending = function()
            self._gated_repaint_pending = nil
            self:markOverlayDirty()
        end
        UIManager:scheduleIn(debounce, self._gated_repaint_pending)
    else
        UIManager:nextTick(function() self:markOverlayDirty() end)
    end
end

local FRONTLIGHT_TOKENS     = { "light", "warmth" }
local BATTERY_TOKENS        = { "batt", "batt_icon" }
local WIFI_TOKENS           = { "wifi" }
local PLUGIN_CONTENT_TOKENS = { "plugin_content" }

function Bookends:onFrontlightStateChanged()    self:gatedRepaint(FRONTLIGHT_TOKENS, 1.0) end
function Bookends:onCharging()                  self:gatedRepaint(BATTERY_TOKENS) end
function Bookends:onNotCharging()               self:gatedRepaint(BATTERY_TOKENS) end
function Bookends:onNetworkConnected()          self:gatedRepaint(WIFI_TOKENS) end
function Bookends:onNetworkDisconnected()       self:gatedRepaint(WIFI_TOKENS) end
-- Plugins (kobo.koplugin BT, readtimer countdown, ...) broadcast
-- RefreshAdditionalContent on state change. Stock footer repaints on this
-- (readerfooter.lua:2716); we do too so %plugin_content updates without
-- waiting for the next page turn.
function Bookends:onRefreshAdditionalContent() self:gatedRepaint(PLUGIN_CONTENT_TOKENS) end
Bookends.onToggleReadingOrder = Bookends.delayedRepaint
function Bookends:onAnnotationsModified()
    self:markDirty()
end
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
function Bookends:getSessionPages()
    return math.max(0, (self.session_max_page or 0) - (self.session_start_page or 0))
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
    self:backgroundUpdateCheck()
end

-- Mirror ReaderFlipping:paintTo's visibility conditions so we know whether
-- an icon would be drawn at this frame. Used to gate the halo repaint below.
function Bookends:_flippingWillPaintIcon()
    local ui = self.ui
    local view = ui and ui.view
    if not view or not view.flipping then return false end
    if ui.paging and view.flipping_visible then return true end
    if ui.highlight then
        if ui.highlight.select_mode then return true end
        if ui.highlight.long_hold_reached then return true end
    end
    if ui.rolling and ui.rolling.rendering_state then
        local f = view.flipping
        if f.getRollingRenderingStateIconWidget then
            return f:getRollingRenderingStateIconWidget() ~= nil
        end
    end
    return false
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

--- Convert a settings-stored color value (number, {grey=N}, {hex="#RRGGBB"},
--- false, or nil) to a Blitbuffer colour object (or false for transparent).
--- Delegates per-value parsing + memoisation to bookends_colour so hex → RGB
--- and greyscale-fallback are consistent with text_color / symbol_color.
local function resolveBarColors(bc)
    local Colour = require("bookends_colour")
    local is_color_enabled = Screen:isColorEnabled()
    local function cv(v) return Colour.parseColorValue(v, is_color_enabled) end
    return {
        fill = cv(bc.fill),
        bg = cv(bc.bg),
        track = cv(bc.track),
        tick = cv(bc.tick),
        border = cv(bc.border),
        invert = cv(bc.invert),
        metro_fill = cv(bc.metro_fill),
        invert_read_ticks = bc.invert_read_ticks,
        tick_height_pct = bc.tick_height_pct,
        border_thickness = bc.border_thickness,
    }
end

--- Compute the progress percentage and tick marks for a single bar.
--- Returns (pct, ticks).
function Bookends:_computeBarProgress(bar_cfg, pageno_local)
    local doc = self.ui.document
    local is_cre = self.ui.rolling ~= nil
    local pct = 0
    local ticks = {}

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
        if tick_level and tick_level ~= "off" then
            if not self._tick_cache then
                self._tick_cache = self:_computeTickCache()
            end
            if tick_level == "all" then
                ticks = self._tick_cache or {}
            else
                local max_tick_depth = tick_level == "level2" and 2 or 1
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

    return pct, ticks
end

--- Compute the pixel rectangle (x,y,w,h) of a bar given its anchor/margins.
local function computeBarRect(bar_cfg, x, y, screen_w, screen_h)
    local anchor = bar_cfg.v_anchor or "bottom"
    local vertical = anchor == "left" or anchor == "right"
    local is_radial = (bar_cfg.style or "solid") == "radial" or bar_cfg.style == "radial_hollow"
    local bar_thickness = bar_cfg.height or (is_radial and 60 or 20)
    if vertical then
        -- margin_left/right reinterpreted as top/bottom insets
        local bar_h = screen_h - (bar_cfg.margin_left or 0) - (bar_cfg.margin_right or 0)
        local bar_y = y + (bar_cfg.margin_left or 0)
        local bar_x
        if anchor == "left" then
            bar_x = x + (bar_cfg.margin_v or 0)
        else
            bar_x = x + screen_w - bar_thickness - (bar_cfg.margin_v or 0)
        end
        -- Radial: shrink to a square centered along the long axis
        if is_radial then
            local side = math.min(bar_thickness, bar_h)
            bar_y = bar_y + math.floor((bar_h - side) / 2)
            bar_h = side
        end
        return bar_x, bar_y, bar_thickness, bar_h, vertical
    else
        local bar_w = screen_w - (bar_cfg.margin_left or 0) - (bar_cfg.margin_right or 0)
        local bar_x = x + (bar_cfg.margin_left or 0)
        local bar_y
        if anchor == "top" then
            bar_y = y + (bar_cfg.margin_v or 0)
        else
            bar_y = y + screen_h - bar_thickness - (bar_cfg.margin_v or 0)
        end
        -- Radial: shrink to a square centered along the long axis
        if is_radial then
            local side = math.min(bar_w, bar_thickness)
            bar_x = bar_x + math.floor((bar_w - side) / 2)
            bar_w = side
        end
        return bar_x, bar_y, bar_w, bar_thickness, vertical
    end
end

--- Render all enabled full-width progress bars (bars drawn behind text).
--- Populates self._hold_rects so long-press gestures can find the bars.
--- Returns (bar_colors, text_color, symbol_color) — colour values the
--- text-rendering phase also needs.
function Bookends:_renderProgressBars(bb, x, y, screen_w, screen_h)
    if self.dirty then
        self._tick_cache = nil
    end

    -- Progress bar colors from settings
    local global_tick_height_pct = self.settings:readSetting("tick_height_pct")
    local bc = self.settings:readSetting("bar_colors") or {}
    bc.tick_height_pct = global_tick_height_pct or bc.tick_height_pct
    local bar_colors
    if bc.fill or bc.bg or bc.track or bc.tick or bc.invert_read_ticks ~= nil or bc.tick_height_pct or bc.border or bc.invert or bc.border_thickness or bc.metro_fill then
        bar_colors = resolveBarColors(bc)
    end

    local text_color = self.settings:readSetting("text_color")
    local symbol_color = self.settings:readSetting("symbol_color")

    for _bar_idx, bar_cfg in ipairs(self.progress_bars or {}) do
        if bar_cfg.enabled then
            local bar_x, bar_y, bar_w, bar_h, vertical = computeBarRect(bar_cfg, x, y, screen_w, screen_h)
            if bar_w > 0 and bar_h > 0 then
                local pageno_local = self.ui.view.state.page or 0
                local pct, ticks = self:_computeBarProgress(bar_cfg, pageno_local)

                local direction = bar_cfg.direction or (vertical and "ttb" or "ltr")
                local paint_vertical = direction == "ttb" or direction == "btt"
                local paint_reverse = direction == "rtl" or direction == "btt"
                local colors = bar_cfg.colors and resolveBarColors(bar_cfg.colors) or bar_colors
                -- Ensure global tick_height_pct is always available
                if colors and not colors.tick_height_pct and global_tick_height_pct then
                    colors.tick_height_pct = global_tick_height_pct
                elseif not colors and global_tick_height_pct then
                    colors = { tick_height_pct = global_tick_height_pct }
                end
                OverlayWidget.paintProgressBar(bb, bar_x, bar_y, bar_w, bar_h, pct, ticks,
                    bar_cfg.style or "solid", paint_vertical and "vertical" or nil, paint_reverse, colors)
                table.insert(self._hold_rects, { x = bar_x, y = bar_y, w = bar_w, h = bar_h })
            end
        end
    end

    return bar_colors, text_color, symbol_color
end

function Bookends:_paintToInner(bb, x, y)
    self._hold_rects = {}

    local screen_size = Screen:getSize()
    local screen_w = screen_size.w
    local screen_h = screen_size.h

    -- Phase 0: Render full-width progress bars (drawn behind text)
    local bar_colors, text_color, symbol_color = self:_renderProgressBars(bb, x, y, screen_w, screen_h)

    -- Phase 1: Expand tokens for all active positions
    -- Filter lines by page parity, join with \n, then expand tokens
    local pageno = self.ui.view.state.page or 0
    local is_odd_page = (pageno % 2) == 1
    local expanded = {}
    local active_line_indices = {} -- key -> { original indices of visible lines }
    local bar_data = {} -- key -> sparse table { [expanded_line_index] = bar_info }
    -- Shared across every Tokens.expand() call for this paint: lets expensive
    -- setup (buildConditionState) happen once even when many lines need it.
    local paint_ctx = {}
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
                local session_pages = self:getSessionPages()
                local expanded_lines = {}
                local final_indices = {}
                local position_bars = {}
                for j, line in ipairs(visible_lines) do
                    -- Only the line currently open in the editor uses legacy_literal,
                    -- so typing %c mid-word doesn't flicker. All other lines render
                    -- normally, including legacy tokens in the same preset.
                    local is_edit_line = self._live_edit_position == pos.key
                        and self._live_edit_line_idx == visible_indices[j]
                    local result, is_empty, line_bar = Tokens.expand(line, self.ui, session_elapsed, session_pages,
                        nil, self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER),
                        symbol_color, paint_ctx,
                        { legacy_literal = is_edit_line })
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
            cfg.text_color = text_color
            cfg.symbol_color = symbol_color
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
                if all_bars.height then
                    cfg.bar.height = all_bars.height
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

    -- Cache top/bottom-row paint regions for markOverlayDirty. Vertical bars
    -- (full-height) are folded into both rows so any value-tick refresh still
    -- covers them. Each Geom is a union of rects whose centre falls in that
    -- half of the screen.
    local function unionRect(target, r)
        if not target then return Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h } end
        local x1 = math.min(target.x, r.x)
        local y1 = math.min(target.y, r.y)
        local x2 = math.max(target.x + target.w, r.x + r.w)
        local y2 = math.max(target.y + target.h, r.y + r.h)
        target.x, target.y, target.w, target.h = x1, y1, x2 - x1, y2 - y1
        return target
    end
    local top_rect, bot_rect
    for key, entry in pairs(self.widget_cache) do
        local size = entry.widget.getSize and entry.widget:getSize() or { w = 0, h = 0 }
        local rect = { x = x + entry.x, y = y + entry.y, w = size.w, h = size.h }
        if key:sub(1, 1) == "t" then top_rect = unionRect(top_rect, rect)
        else                          bot_rect = unionRect(bot_rect, rect) end
    end
    for _, r in ipairs(self._hold_rects) do
        if r.h > screen_h * 0.5 then
            top_rect = unionRect(top_rect, r)
            bot_rect = unionRect(bot_rect, r)
        elseif (r.y + r.h * 0.5) < screen_h * 0.5 then
            top_rect = unionRect(top_rect, r)
        else
            bot_rect = unionRect(bot_rect, r)
        end
    end
    self._top_paint_rect = top_rect
    self._bottom_paint_rect = bot_rect

    -- Dogear and flipping-icon halo both paint from toast overlays
    -- registered on UIManager, above the ReaderView paint pipeline.
    -- An in-paintTo repaint here would be lost if this function errored
    -- partway through, which has happened (see font.lua paintTo traces),
    -- and could also be clobbered by later view modules.

    self.dirty = false
    self:startRefreshTimer()
end

function Bookends:onCloseWidget()
    self:stopRefreshTimer()
    if self.widget_cache then
        OverlayWidget.freeWidgets(self.widget_cache)
        self.widget_cache = nil
    end
    self._top_paint_rect = nil
    self._bottom_paint_rect = nil
    if self.settings then
        self.settings:flush()
    end
end

function Bookends:onFlushSettings()
    if self.settings then
        self.settings:flush()
        -- Autosave the active preset (no-op if _previewing or no active preset).
        local ok, err = pcall(self.autosaveActivePreset, self)
        if not ok then require("logger").warn("bookends: autosave failed:", err) end
    end
end

-- Tokens whose displayed value changes purely with wall-clock time (no event
-- fires — they need the 60s heartbeat to stay current). Battery percent is
-- here because charging/uncharging events handle the icon state change but
-- the numeric % only drifts as time passes.
local TIMER_TOKENS = {
    "time", "time_12h", "time_24h",
    "date", "date_long", "date_numeric", "weekday", "weekday_short",
    "session_time", "book_time_left", "chap_time_left",
    "speed", "book_read_time",
    "batt", "batt_icon",
}

function Bookends:startRefreshTimer()
    if self.refresh_timer_active then return end
    self.refresh_timer_active = true
    self.refresh_timer_func = function()
        if not self.refresh_timer_active then return end
        if self:anyActiveLineUses(TIMER_TOKENS) then
            self:markOverlayDirty()
        end
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

function Bookends:hideMenu(touchmenu_instance)
    return DialogHelpers.hideParentMenu(touchmenu_instance)
end

function Bookends:showNudgeDialog(title, value, min_val, max_val, default_val, unit, on_change, on_close, small_step, large_step, touchmenu_instance, on_default, default_label)
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
                { text = default_label or (_("Default") .. " " .. default_val .. unit), callback = function()
                    if on_default then
                        on_default()
                        UIManager:close(dialog)
                        if on_close then on_close() end
                    else
                        value = default_val; on_change(value); dialog:reinit()
                    end
                end },
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

    -- Build font list: one entry per font family, preferring the Regular weight.
    -- Bold/italic/bolditalic variants are dropped when the family has a base
    -- (non-variant) option available — the per-line style button handles them
    -- at render time. If a family has *only* variant files (common for script
    -- fonts that are italic-by-design), keep the best variant so the font
    -- remains directly pickable.
    local fonts = {}
    local font_display_names = {} -- file → display name lookup
    local families_base = {}      -- family → best non-variant
    local families_variant = {}   -- family → best variant (used only as fallback)
    for font_file, font_info in pairs(FontList.fontinfo) do
        local info = font_info and font_info[1]
        if info then
            local lbase = (font_file:match("([^/]+)$") or ""):lower()
            local is_variant = info.bold or info.italic
                or lbase:find("bold") or lbase:find("italic") or lbase:find("oblique")
            -- Group by base family name (e.g. "Amazon Ember"), not per-weight
            -- localized name (e.g. "Amazon Ember Bold") — otherwise each weight
            -- gets its own bucket and variants survive the merge.
            local name = info.name or FontList:getLocalizedFontName(font_file, 0)
            -- Rank: lower = more "regular". Handles within-family weight variants.
            local rank = 0
            if info.bold then rank = rank + 2 end
            if info.italic then rank = rank + 2 end
            if lbase:find("regular") then
                rank = rank - 1
            elseif lbase:find("bold") or lbase:find("italic") or lbase:find("oblique") then
                rank = rank + 2
            elseif lbase:find("light") or lbase:find("thin") or lbase:find("heavy")
                or lbase:find("black") or lbase:find("medium") or lbase:find("semibold")
                or lbase:find("extrabold") or lbase:find("extralight") or lbase:find("ultralight")
                or lbase:find("demibold") or lbase:find("book") then
                rank = rank + 1
            end
            local bucket = is_variant and families_variant or families_base
            local prev = bucket[name]
            if not prev or rank < prev.rank then
                bucket[name] = { file = font_file, name = name, rank = rank }
            end
        end
    end
    -- Merge: base wins where present, variant fills in for variant-only families
    local families = {}
    for name, entry in pairs(families_base) do
        families[name] = entry
    end
    for name, entry in pairs(families_variant) do
        if not families[name] then
            families[name] = entry
        end
    end
    -- Filter out fonts that freetype can't actually load. Users with older
    -- CFF-format OTFs or damaged font files would otherwise see them in the
    -- picker, select one, and end up with a crashing overlay. Validation
    -- calls Font:getFace (which caches); subsequent picker opens are fast.
    -- Skipped fonts are tracked so we can report the count in the footer.
    local skipped_count = 0
    for _, entry in pairs(families) do
        local ok_face = Font:getFace(entry.file, 12)
        if ok_face then
            table.insert(fonts, { file = entry.file, name = entry.name, display = entry.name })
            font_display_names[entry.file] = entry.name
        else
            skipped_count = skipped_count + 1
        end
    end
    table.sort(fonts, function(a, b)
        return ffiUtil.strcoll(a.name, b.name)
    end)
    if skipped_count > 0 then
        require("logger").info(string.format(
            "bookends: font picker skipped %d font(s) that freetype couldn't load",
            skipped_count))
    end

    -- Prepend family entries (page 1 only, before the specific-font list)
    local family_entries = {}
    for _, fkey in ipairs(Utils.FONT_FAMILY_ORDER) do
        local sentinel = "@family:" .. fkey
        local fam_label = Utils.getFontFamilyLabel(sentinel)
        if fam_label then
            table.insert(family_entries, {
                file = sentinel,
                name = Utils.FONT_FAMILIES[fkey],
                display = fam_label.label,
                resolved_file = fam_label.resolved,
                is_family = true,
            })
            font_display_names[sentinel] = fam_label.label
        end
    end

    -- If current/default face is a variant not in the list, resolve to the family representative
    local shown_files = {}
    for _, f in ipairs(fonts) do shown_files[f.file] = true end
    for _, f in ipairs(family_entries) do shown_files[f.file] = true end
    local function resolveToVisible(face)
        if not face or shown_files[face] then return face end
        -- Family sentinels pass through as themselves (they're always "visible" on page 1)
        if type(face) == "string" and face:match("^@family:") then return face end
        local info = FontList.fontinfo[face]
        if info and info[1] then
            local name = FontList:getLocalizedFontName(face, 0) or info[1].name
            if families[name] then return families[name].file end
        end
        return face
    end

    local original_face = current_face
    current_face = resolveToVisible(current_face)
    default_face = resolveToVisible(default_face)
    local selected = current_face
    local per_page = 10
    local page = 1

    -- Page 1 shows fewer specific fonts (family rows + headers take space)
    local page1_fonts = (#family_entries > 0) and math.max(2, per_page - #family_entries - 2) or per_page
    -- Find initial page for current font (family sentinels always live on page 1)
    if type(selected) == "string" and selected:match("^@family:") then
        page = 1
    else
        for i, f in ipairs(fonts) do
            if f.file == selected then
                if i <= page1_fonts then
                    page = 1
                else
                    page = 1 + math.ceil((i - page1_fonts) / per_page)
                end
                break
            end
        end
    end
    local remaining_fonts = math.max(0, #fonts - page1_fonts)
    local total_pages = 1 + math.ceil(remaining_fonts / per_page)

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
        local selected_face
        if selected then
            local sel_resolved = Utils.resolveFontFace(selected, nil)
            -- Font load can fail (unsupported file, freetype errors).
            -- Fall back to cfont if the resolved face returns nil.
            if sel_resolved then
                selected_face = Font:getFace(sel_resolved, title_font_size)
                             or Font:getFace("cfont", title_font_size)
            else
                selected_face = Font:getFace("cfont", title_font_size)
            end
        else
            selected_face = Font:getFace("cfont", title_font_size)
        end
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

        -- Page 1: prepend "Font-family fonts" header + family rows + "Fonts" header
        if page == 1 and #family_entries > 0 then
            local baseline = math.floor(row_height * 0.65)
            -- Family section header (rendered in dark-grey so it reads as a
            -- passive label rather than a tappable row).
            local family_header = TextWidget:new{
                text = "\xE2\x94\x80\xE2\x94\x80 " .. _("Font-family fonts") .. " \xE2\x94\x80\xE2\x94\x80",
                face = Font:getFace("cfont", font_size),
                forced_height = row_height,
                forced_baseline = baseline,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            table.insert(list_group, LeftContainer:new{
                dimen = Geom:new{ w = width, h = row_height },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = left_pad },
                    family_header,
                },
            })

            -- Family rows
            for _, f in ipairs(family_entries) do
                local is_selected = (f.file == selected)
                local row_face = f.resolved_file and Font:getFace(f.resolved_file, font_size)
                                 or Font:getFace("cfont", font_size)
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
                    text = f.display,
                    face = row_face,
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
                local sentinel = f.file
                item_container.onTapSelect = safe("fontPicker:selectFamily", function()
                    selected = sentinel
                    on_select(sentinel)
                    picker:rebuild()
                    return true
                end)
                table.insert(list_group, item_container)
            end

            -- "Fonts" section header (separates family block from specific fonts).
            -- Dark-grey to match the family header and read as a passive label.
            local fonts_header = TextWidget:new{
                text = "\xE2\x94\x80\xE2\x94\x80 " .. _("Fonts") .. " \xE2\x94\x80\xE2\x94\x80",
                face = Font:getFace("cfont", font_size),
                forced_height = row_height,
                forced_baseline = baseline,
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            table.insert(list_group, LeftContainer:new{
                dimen = Geom:new{ w = width, h = row_height },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = left_pad },
                    fonts_header,
                },
            })
        end

        local start_idx
        local rows_on_page = per_page
        if page == 1 then
            start_idx = 1
            if #family_entries > 0 then
                rows_on_page = math.max(2, per_page - #family_entries - 2)
            end
        else
            start_idx = page1_fonts + (page - 2) * per_page + 1
        end
        local end_idx = math.min(start_idx + rows_on_page - 1, #fonts)

        for i = start_idx, end_idx do
            local f = fonts[i]
            local is_selected = (f.file == selected)
            local is_default = (f.file == default_face)
            -- Font load can fail for unsupported files (e.g. some .otf files
            -- with non-Latin1 filenames, parentheses in paths, or glyph tables
            -- freetype can't handle). Fall back to cfont so the picker row
            -- still renders (just in the default font instead of its own).
            local face = Font:getFace(f.file, font_size)
                      or Font:getFace("cfont", font_size)

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

        -- Page navigation: compact chevrons + label, matching the preset
        -- library's reduced pagination (vs. stock 40px icons).
        local chev_size = Screen:scaleBySize(32)
        local page_info_text = Button:new{
            text = T(_("Page %1 of %2"), page, total_pages),
            text_font_size = 15,
            -- Default (Button.text_font_bold = true) to match the preset
            -- library's pagination weight.
            callback = function() end,
            bordersize = 0,
            show_parent = picker,
        }
        local page_first = Button:new{
            icon = "chevron.first", icon_width = chev_size, icon_height = chev_size,
            callback = function()
                page = 1
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page > 1,
            show_parent = picker,
        }
        local page_info_left = Button:new{
            icon = "chevron.left", icon_width = chev_size, icon_height = chev_size,
            callback = function()
                page = page - 1
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page > 1,
            show_parent = picker,
        }
        local page_info_right = Button:new{
            icon = "chevron.right", icon_width = chev_size, icon_height = chev_size,
            callback = function()
                page = page + 1
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page < total_pages,
            show_parent = picker,
        }
        local page_last = Button:new{
            icon = "chevron.last", icon_width = chev_size, icon_height = chev_size,
            callback = function()
                page = total_pages
                picker:rebuild()
            end,
            bordersize = 0,
            enabled = page < total_pages,
            show_parent = picker,
        }

        -- Uniform 32px gap between every element (matches the stock Menu
        -- widget's page_info_spacer so pagination reads identically across
        -- the plugin's custom and stock paginators).
        local nav_span = Screen:scaleBySize(32)
        local page_nav = HorizontalGroup:new{
            align = "center",
            page_first,
            HorizontalSpan:new{ width = nav_span },
            page_info_left,
            HorizontalSpan:new{ width = nav_span },
            page_info_text,
            HorizontalSpan:new{ width = nav_span },
            page_info_right,
            HorizontalSpan:new{ width = nav_span },
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

function Bookends:checkForUpdates()
    local settings = self.settings
    local dev_branch = self.dev_branch or ""
    if dev_branch ~= "" then
        Updater.installBranch(dev_branch, function()
            settings:saveSetting("last_install_source", "branch:" .. dev_branch)
            settings:flush()
        end)
    else
        Updater.check(function()
            settings:saveSetting("last_install_source", "release")
            settings:flush()
        end)
    end
end

function Bookends:editDevBranch(touchmenu_instance)
    local InputDialogMod = require("ui/widget/inputdialog")
    local UIManagerMod = require("ui/uimanager")
    local dlg
    dlg = InputDialogMod:new{
        title = _("Development branch"),
        input = self.dev_branch or "",
        input_hint = _("Branch name (leave empty for stable)"),
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManagerMod:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local raw = dlg:getInputText() or ""
                local trimmed = raw:gsub("^%s+", ""):gsub("%s+$", "")
                self.dev_branch = trimmed
                self.settings:saveSetting("dev_branch", trimmed)
                self.settings:flush()
                UIManagerMod:close(dlg)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManagerMod:show(dlg)
    dlg:onShowKeyboard()
end

function Bookends:resetToStableRelease()
    local ConfirmBoxMod = require("ui/widget/confirmbox")
    local UIManagerMod = require("ui/uimanager")
    UIManagerMod:show(ConfirmBoxMod:new{
        text = _("This will clear the development branch setting and install the latest stable release of Bookends, then restart KOReader. Continue?"),
        ok_text = _("Reset"),
        ok_callback = function()
            self.dev_branch = ""
            self.settings:saveSetting("dev_branch", "")
            self.settings:flush()
            local settings = self.settings
            Updater.installLatestStable(function()
                settings:saveSetting("last_install_source", "release")
                settings:flush()
            end)
        end,
    })
end

function Bookends:backgroundUpdateCheck()
    if not self.check_updates then return end
    Updater.checkBackground(function(ver)
        local Notification = require("ui/widget/notification")
        Notification:notify(_("Bookends update available: v") .. ver,
            Notification.SOURCE_ALWAYS_SHOW)
    end)
end


function Bookends:showMarginAdjuster(touchmenu_instance)
    DialogHelpers.showNudgeGrid{
        title = _("Adjust margins"),
        rows = {
            { label = _("Top"),    field = "margin_top" },
            { label = _("Bottom"), field = "margin_bottom" },
            { label = _("Left"),   field = "margin_left" },
            { label = _("Right"),  field = "margin_right" },
        },
        get_value = function(field) return self.defaults[field] end,
        set_value = function(field, value) self.defaults[field] = value end,
        on_row_change = function() self:markDirty() end,
        on_cancel = function() self:markDirty() end,  -- originals already restored
        on_default = function()
            for k, v in pairs(Config.DEFAULT_MARGINS) do
                self.defaults[k] = v
            end
            self:markDirty()
        end,
        on_apply = function()
            for _, key in ipairs({ "margin_top", "margin_bottom", "margin_left", "margin_right" }) do
                self.settings:saveSetting(key, self.defaults[key])
            end
        end,
        parent_menu = touchmenu_instance,
    }
end

return Bookends
