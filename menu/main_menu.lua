--- Top-level Bookends menu (entry point from KOReader main menu).
local Font = require("ui/font")
local Tokens = require("tokens")
local Updater = require("updater")
local Utils = require("utils")
local _ = require("i18n").gettext

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
        text_func = function()
            if Updater.getAvailableUpdate() then
                return _("Settings") .. " (" .. _("plugin update available") .. ")"
            end
            return _("Settings")
        end,
        enabled_func = function() return self.enabled end,
        sub_item_table_func = function()
            return {
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
                    text = _("Colors and tick marks"),
                    sub_item_table_func = function()
                        return self:buildColoursMenu()
                    end,
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
                        if available then
                            return _("Update available") .. ": v" .. current .. " \xE2\x86\x92 v" .. available
                        end
                        return _("Installed version") .. ": v" .. current
                    end,
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

end
