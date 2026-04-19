--- Full-width progress bar menus: list of bars, per-bar configuration,
-- and the bar-margin adjuster dialog.
local DialogHelpers = require("bookends_dialog_helpers")
local UIManager = require("ui/uimanager")
local Utils = require("bookends_utils")
local _ = require("bookends_i18n").gettext
local T = require("ffi/util").template

return function(Bookends)

function Bookends:buildProgressBarMenu()
    local items = {}

    local function swapBars(a, b, touchmenu_instance)
        self.progress_bars[a], self.progress_bars[b] = self.progress_bars[b], self.progress_bars[a]
        self.settings:saveSetting("progress_bar_" .. a, self.progress_bars[a])
        self.settings:saveSetting("progress_bar_" .. b, self.progress_bars[b])
        self:markDirty()
        if touchmenu_instance then
            touchmenu_instance.item_table = self:buildProgressBarMenu()
            touchmenu_instance:updateItems()
        end
    end

    local num_bars = #self.progress_bars
    for idx in ipairs(self.progress_bars) do
        table.insert(items, {
            text_func = function()
                local bar_cfg = self.progress_bars[idx]
                local label = _("Bar") .. " " .. idx
                if bar_cfg.enabled then
                    local type_label = bar_cfg.type == "chapter" and _("chapter") or _("book")
                    local anchor_labels = { top = _("top"), bottom = _("bottom"), left = _("left"), right = _("right") }
                    local orient = anchor_labels[bar_cfg.v_anchor or "bottom"]
                    return label .. " (" .. type_label .. ", " .. orient .. ")"
                end
                return label
            end,
            checked_func = function() return self.progress_bars[idx].enabled end,
            hold_callback = function(touchmenu_instance)
                local buttons = {}
                if idx > 1 then
                    table.insert(buttons, {{
                        text = _("Move up"),
                        callback = function()
                            UIManager:close(self._bar_manage_dialog)
                            swapBars(idx, idx - 1, touchmenu_instance)
                        end,
                    }})
                end
                if idx < num_bars then
                    table.insert(buttons, {{
                        text = _("Move down"),
                        callback = function()
                            UIManager:close(self._bar_manage_dialog)
                            swapBars(idx, idx + 1, touchmenu_instance)
                        end,
                    }})
                end
                if #buttons == 0 then return end
                table.insert(buttons, {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self._bar_manage_dialog)
                    end,
                }})
                local ButtonDialog = require("ui/widget/buttondialog")
                self._bar_manage_dialog = ButtonDialog:new{
                    title = T(_("Bar %1"), idx),
                    buttons = buttons,
                }
                UIManager:show(self._bar_manage_dialog)
            end,
            sub_item_table_func = function()
                return self:buildSingleBarMenu(idx, self.progress_bars[idx])
            end,
        })
    end
    table.insert(items, {
        text = _("Long press to change render order"),
        enabled_func = function() return false end,
    })
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
                bar_cfg.chapter_ticks = Utils.cycleNext(
                    { "off", "level1", "level2", "all" },
                    bar_cfg.chapter_ticks or "off")
                saveBar()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                local style_labels = { solid = _("Solid"), bordered = _("Bordered"), rounded = _("Rounded"), metro = _("Metro"), wavy = _("Wave") }
                return _("Style") .. ": " .. (style_labels[bar_cfg.style] or _("Solid"))
            end,
            enabled_func = isEnabled,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                bar_cfg.style = Utils.cycleNext(
                    { "solid", "bordered", "rounded", "metro", "wavy" },
                    bar_cfg.style or "solid")
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
                local new_anchor = Utils.cycleNext(
                    { "top", "bottom", "left", "right" },
                    bar_cfg.v_anchor or "bottom")
                bar_cfg.v_anchor = new_anchor
                local new_vert = new_anchor == "left" or new_anchor == "right"
                local cur_dir = bar_cfg.direction or "ltr"
                local cur_is_vert = cur_dir == "ttb" or cur_dir == "btt"
                if new_vert and not cur_is_vert then
                    bar_cfg.direction = "btt"
                elseif not new_vert and cur_is_vert then
                    bar_cfg.direction = nil
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
                local style = bar_cfg.style or "solid"
                local axis_locked = style == "metro" or style == "wavy"
                local cycle
                if axis_locked and is_side then
                    cycle = { "ttb", "btt" }
                elseif axis_locked then
                    cycle = { "ltr", "rtl" }
                else
                    cycle = { "ltr", "rtl", "ttb", "btt" }
                end
                local default_dir = is_side and "ttb" or "ltr"
                local cur = bar_cfg.direction or default_dir
                local next_dir = Utils.cycleNext(cycle, cur)
                bar_cfg.direction = next_dir ~= default_dir and next_dir or nil
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
                    return _("Custom colors and tick marks") .. " (\u{2713})"
                end
                return _("Custom colors and tick marks")
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
                end, true)
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
                        return _("Tick width") .. ": " .. _("default") .. " (" .. self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER) .. "x)"
                    end,
                    enabled_func = function() return bar_cfg.colors ~= nil end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local current = bc.tick_width_multiplier or self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER)
                        self:showNudgeDialog(_("Tick width"), current, 1, 5, self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER), "x",
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
    local vert = bar_cfg.v_anchor == "left" or bar_cfg.v_anchor == "right"
    local setting_key = "progress_bar_" .. bar_idx
    local function persist()
        self.settings:saveSetting(setting_key, bar_cfg)
        self:markDirty()
    end
    DialogHelpers.showNudgeGrid{
        title = _("Adjust margins"),
        rows = {
            { label = vert and _("Edge") or _("Vertical"), field = "margin_v" },
            { label = vert and _("Top") or _("Left"),      field = "margin_left" },
            { label = vert and _("Bottom") or _("Right"),  field = "margin_right" },
        },
        get_value = function(field) return bar_cfg[field] or 0 end,
        set_value = function(field, value) bar_cfg[field] = value end,
        on_row_change = persist,
        on_cancel = persist,                 -- originals already restored; re-persist reverted state
        on_default = function()
            bar_cfg.margin_v = 0
            bar_cfg.margin_left = 0
            bar_cfg.margin_right = 0
            persist()
        end,
        default_text = _("Default") .. " 0",
        parent_menu = touchmenu_instance,
        -- No on_apply: values are already persisted live.
    }
end

end
