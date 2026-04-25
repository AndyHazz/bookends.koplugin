--- Top-level Bookends menu (entry point from KOReader main menu).
local Font = require("ui/font")
local Tokens = require("bookends_tokens")
local Updater = require("bookends_updater")
local Utils = require("bookends_utils")
local _ = require("bookends_i18n").gettext

return function(Bookends)

function Bookends:addToMainMenu(menu_items)
    menu_items.bookends = {
        text = _("Bookends"),
        sorting_hint = "typeset",
        sub_item_table_func = function()
            return self:buildMainMenu()
        end,
    }
end

--- Save current overlay as a new preset — opens an input dialog.
--- Extracted so the top-level Bookends menu and any future entry point
--- can share the flow.
local function saveAsNewPresetDialog(self)
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")
    local dlg
    dlg = InputDialog:new{
        title = _("Save preset"),
        input = "",
        input_hint = _("Preset name"),
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dlg:getInputText()
                if name and name ~= "" then
                    local preset = self:buildPreset()
                    preset.name = name
                    local filename = self:writePresetFile(name, preset)
                    self:setActivePresetFilename(filename)
                    local cycle = self.settings:readSetting("preset_cycle") or {}
                    table.insert(cycle, filename)
                    self.settings:saveSetting("preset_cycle", cycle)
                    local Notification = require("ui/widget/notification")
                    Notification:notify(_("Saved preset:") .. " " .. name)
                end
                UIManager:close(dlg)
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

--- Rename the currently-active preset. Prompts for a new name and uses
--- renamePresetFile to rewrite the on-disk file; cycle entries and the
--- active-preset setting are patched to point at the new filename. When
--- invoked from a TouchMenu, `touchmenu_instance:updateItems()` is called
--- after a successful rename so the item's text_func re-renders with the
--- new name without having to close and re-open the menu.
local function renameActivePresetDialog(self, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")
    local old_filename = self:getActivePresetFilename()
    if not old_filename then return end
    local old_name = self:getActivePresetName() or ""
    local dlg
    dlg = InputDialog:new{
        title = _("Rename preset"),
        input = old_name,
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dlg) end },
            { text = _("Rename"), is_enter_default = true, callback = function()
                local new_name = dlg:getInputText()
                local renamed = false
                if new_name and new_name ~= "" and new_name ~= old_name then
                    local new_filename = self:renamePresetFile(old_filename, new_name)
                    if new_filename then
                        local cycle = self.settings:readSetting("preset_cycle") or {}
                        for i, f in ipairs(cycle) do
                            if f == old_filename then cycle[i] = new_filename; break end
                        end
                        self.settings:saveSetting("preset_cycle", cycle)
                        self:setActivePresetFilename(new_filename)
                        renamed = true
                    end
                end
                UIManager:close(dlg)
                if renamed and touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Bookends:buildMainMenu()
    local menu = {}

    -- Bookends settings: global preferences (never saved with presets).
    table.insert(menu, {
        text_func = function()
            if Updater.getAvailableUpdate() then
                return _("Bookends settings") .. " (" .. _("plugin update available") .. ")"
            end
            return _("Bookends settings")
        end,
        separator = true,
        sub_item_table_func = function()
            return self:buildBookendsSettingsMenu()
        end,
    })

    -- Preset submenu: styling settings that ARE saved with the current
    -- preset. Title includes the active preset name so the user can see at
    -- a glance which preset these tweaks will affect.
    table.insert(menu, {
        text_func = function()
            local name = self:getActivePresetName()
            if name then
                return _("Preset") .. " (" .. name .. ")"
            end
            return _("Preset")
        end,
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            return self:buildPresetAdjustmentsMenu()
        end,
    })

    -- Per-position submenus with inline previews.
    for _, pos in ipairs(self.POSITIONS) do
        table.insert(menu, {
            text_func = function()
                local lines = self.positions[pos.key].lines
                if #lines == 0 then
                    return pos.label
                end
                local session_elapsed = self:getSessionElapsed()
                local session_pages = self:getSessionPages()
                local previews = {}
                for _, line in ipairs(lines) do
                    table.insert(previews, (Tokens.expandPreview(line, self.ui, session_elapsed, session_pages,
                        self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER))))
                end
                local preview = table.concat(previews, " \xC2\xB7 ")
                preview = preview:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if #preview > 38 then
                    preview = Utils.truncateUtf8(preview, 35)
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

    -- Full width progress bars — last item of the preset-content block.
    -- Separator here visually closes the block before Save as new preset.
    table.insert(menu, {
        text = _("Full width progress bars"),
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            return self:buildProgressBarMenu()
        end,
        separator = true,
    })

    -- Save current as new preset — duplicates the live overlay state into a
    -- separate preset file. Keep the text explicit about the duplication so
    -- users don't confuse it with saving in-progress edits (those autosave).
    table.insert(menu, {
        text = _("Save current as new preset…"),
        enabled_func = function() return self.enabled end,
        keep_menu_open = false,
        callback = function(touchmenu_instance)
            if touchmenu_instance then
                touchmenu_instance:onClose()
            end
            saveAsNewPresetDialog(self)
        end,
    })

    return menu
end

--- Global Bookends settings (never saved with presets).
function Bookends:buildBookendsSettingsMenu()
    return {
        {
            text = _("Enable bookends"),
            checked_func = function() return self.enabled end,
            callback = function()
                self.enabled = not self.enabled
                self.settings:saveSetting("enabled", self.enabled)
                self:markDirty()
            end,
        },
        {
            text_func = function()
                if not self.stock_bar_disabled then
                    return _("Disable stock status bar") .. " (" .. _("recommended") .. ")"
                end
                return _("Disable stock status bar")
            end,
            keep_menu_open = true,
            help_text = _("Hides KOReader's built-in status bar. This simplifies the render pipeline and can reduce e-ink flicker on some devices. All status bar features are available as Bookends tokens."),
            checked_func = function()
                return self.stock_bar_disabled
            end,
            callback = function()
                local footer = self.ui.view.footer
                self.stock_bar_disabled = not self.stock_bar_disabled
                self.settings:saveSetting("stock_bar_disabled", self.stock_bar_disabled)
                if self.stock_bar_disabled then
                    footer:applyFooterMode(footer.mode_list.off)
                else
                    footer:applyFooterMode(footer.mode_list.page_progress)
                end
                self:markDirty()
            end,
            separator = true,
        },
        {
            text_func = function()
                local fam = Utils.getFontFamilyLabel(self.defaults.font_face)
                if fam then
                    return _("Default font") .. " (" .. fam.label .. ")"
                end
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
                local action = self.settings:readSetting("bottom_center_tap_action")
                local label = _("Bottom center tap gesture")
                if action == "toggle" then
                    return label .. " (" .. _("toggle bookends") .. ")"
                elseif action == "cycle" then
                    return label .. " (" .. _("cycle presets") .. ")"
                elseif action == "library" then
                    return label .. " (" .. _("preset library") .. ")"
                end
                return label
            end,
            help_text = _("Configure what happens when you tap the centre of the status bar area, and whether long-pressing a progress bar opens the skim dialog."),
            sub_item_table_func = function()
                local function setTapAction(val)
                    if val == nil then
                        self.settings:delSetting("bottom_center_tap_action")
                    else
                        self.settings:saveSetting("bottom_center_tap_action", val)
                    end
                end
                return {
                    {
                        text = _("Toggle bookends"),
                        checked_func = function()
                            return self.settings:readSetting("bottom_center_tap_action") == "toggle"
                        end,
                        callback = function()
                            if self.settings:readSetting("bottom_center_tap_action") == "toggle" then
                                setTapAction(nil)
                            else
                                setTapAction("toggle")
                            end
                        end,
                        radio = true,
                    },
                    {
                        text = _("Cycle starred presets"),
                        checked_func = function()
                            return self.settings:readSetting("bottom_center_tap_action") == "cycle"
                        end,
                        callback = function()
                            if self.settings:readSetting("bottom_center_tap_action") == "cycle" then
                                setTapAction(nil)
                            else
                                setTapAction("cycle")
                            end
                        end,
                        radio = true,
                    },
                    {
                        text = _("Open preset library"),
                        checked_func = function()
                            return self.settings:readSetting("bottom_center_tap_action") == "library"
                        end,
                        callback = function()
                            if self.settings:readSetting("bottom_center_tap_action") == "library" then
                                setTapAction(nil)
                            else
                                setTapAction("library")
                            end
                        end,
                        radio = true,
                        separator = true,
                    },
                    {
                        text = _("Long-press progress bars to skim document"),
                        checked_func = function()
                            return self.skim_on_hold
                        end,
                        callback = function()
                            self.skim_on_hold = not self.skim_on_hold
                            self.settings:saveSetting("skim_on_hold", self.skim_on_hold)
                        end,
                        help_text = _("Opens the skim dialog when you long-press on a full-width progress bar. Replaces the stock status bar's long-press to skim feature."),
                    },
                }
            end,
            separator = true,
        },
        {
            text = _("Include current page in pages-left tokens"),
            help_text = _("Affects %L (pages left in book) and %l (pages left in chapter). Off (default): 'n−1 → 0'. On: 'n → 1'."),
            checked_func = function()
                return self.settings:isTrue("pages_left_includes_current")
            end,
            callback = function()
                local val = not self.settings:isTrue("pages_left_includes_current")
                self.settings:saveSetting("pages_left_includes_current", val)
                Tokens.pages_left_includes_current = val
                self:markDirty()
            end,
            separator = true,
        },
        {
            text = _("Notify on wake when update available"),
            checked_func = function()
                return self.check_updates
            end,
            callback = function()
                self.check_updates = not self.check_updates
                self.settings:saveSetting("check_updates", self.check_updates)
            end,
        },
        {
            text_func = function()
                local current = Updater.getInstalledVersion()
                local available = Updater.getAvailableUpdate()
                local source = self.last_install_source or "release"
                local source_suffix = ""
                if source ~= "release" then
                    local branch = source:match("^branch:(.+)$") or source
                    source_suffix = " (branch: " .. branch .. ")"
                end
                if available then
                    return _("Update available") .. ": v" .. current .. source_suffix .. " \xE2\x86\x92 v" .. available
                end
                return _("Installed version") .. ": v" .. current .. source_suffix
            end,
            keep_menu_open = true,
            callback = function()
                self:checkForUpdates()
            end,
        },
        {
            text = _("Advanced"),
            sub_item_table = {
                {
                    text_func = function()
                        local b = self.dev_branch or ""
                        if b == "" then
                            return _("Development branch")
                        end
                        return _("Development branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:editDevBranch(touchmenu_instance)
                    end,
                },
                {
                    text_func = function()
                        local b = self.dev_branch or ""
                        if b == "" then
                            return _("Check for updates")
                        end
                        return _("Install branch") .. ": " .. b
                    end,
                    keep_menu_open = true,
                    callback = function()
                        self:checkForUpdates()
                    end,
                },
                {
                    text = _("Reset to latest stable release"),
                    keep_menu_open = true,
                    callback = function()
                        self:resetToStableRelease()
                    end,
                },
                {
                    text_func = function()
                        local current = Updater.getInstalledVersion()
                        local source = self.last_install_source or "release"
                        if source == "release" then
                            return _("Installed: v") .. current .. " (release)"
                        end
                        local branch = source:match("^branch:(.+)$") or source
                        return _("Installed: v") .. current .. " (branch: " .. branch .. ")"
                    end,
                    enabled_func = function() return false end,
                    keep_menu_open = true,
                },
            },
        },
    }
end

--- Preset submenu: styling tweaks that ARE saved into the active preset.
--- Opens the preset library as its first item so users can pick/manage
--- presets from the same menu that tweaks the current one.
function Bookends:buildPresetAdjustmentsMenu()
    local items = {}

    table.insert(items, {
        text = _("Preset library…"),
        keep_menu_open = false,
        callback = function(touchmenu_instance)
            if touchmenu_instance then
                touchmenu_instance:onClose()
            end
            local PresetManagerModal = require("menu/preset_manager_modal")
            PresetManagerModal.show(self)
        end,
        separator = true,
    })

    -- Rename row doubles as the "which preset am I editing?" indicator —
    -- its text shows the active preset name in parens, and tapping opens
    -- an inline rename dialog that updates the row on success (menu stays
    -- open). Uses the same (name) convention as the parent "Preset (…)"
    -- label so the two read as a matched pair.
    table.insert(items, {
        text_func = function()
            local name = self:getActivePresetName() or ""
            return _("Rename") .. " (" .. name .. ")…"
        end,
        enabled_func = function()
            return self.enabled and self:getActivePresetFilename() ~= nil
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            renameActivePresetDialog(self, touchmenu_instance)
        end,
        separator = true,
    })

    table.insert(items, {
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
    })

    table.insert(items, {
        text_func = function()
            local m = self.defaults
            return _("Adjust margins") .. " (" .. m.margin_top .. "/" .. m.margin_bottom .. "/" .. m.margin_left .. "/" .. m.margin_right .. ")"
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showMarginAdjuster(touchmenu_instance)
        end,
    })

    table.insert(items, {
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
    })

    table.insert(items, {
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
        separator = true,
    })

    -- Text colour + Symbol colour flattened one level up for easier access.
    for _, item in ipairs(self:buildTextColourMenu()) do
        table.insert(items, item)
    end

    -- Progress bar colours remain nested — too many sub-items to flatten
    -- without overflowing the 10-row limit.
    table.insert(items, {
        text = _("Progress bar colors and tick marks"),
        sub_item_table_func = function()
            return self:buildBarColorsMenu()
        end,
    })

    return items
end

end
