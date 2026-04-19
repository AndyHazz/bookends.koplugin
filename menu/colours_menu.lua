--- Colour-related menus: text/symbol colours and bar colours/ticks.
-- Attached onto the Bookends class by main.lua on plugin load.
local _ = require("bookends_i18n").gettext

return function(Bookends)

--- Build the shared colour items used by bar colours (read / unread /
--- metro-track / tick / invert toggle / border / border thickness / tick-invert).
--- When is_per_bar is true, the Border thickness item inherits the global
--- bar_colors.border_thickness as its default instead of the hard-coded 1px.
function Bookends:_buildColorItems(bc, saveColors, is_per_bar)
    local function colorNudge(title, field, default_pct, touchmenu_instance)
        local current = bc[field] and math.floor((0xFF - bc[field]) * 100 / 0xFF + 0.5) or default_pct
        self:showNudgeDialog(title, current, 0, 100, default_pct, "%",
            function(val)
                bc[field] = 0xFF - math.floor(val * 0xFF / 100 + 0.5)
                saveColors()
            end,
            nil, nil, nil, touchmenu_instance,
            function()
                bc[field] = nil; saveColors()
            end,
            _("Default") .. " (" .. _("per style") .. ")")
    end

    local function pctLabel(field)
        if bc[field] then
            local pct = math.floor((0xFF - bc[field]) * 100 / 0xFF + 0.5)
            if pct == 0 then return _("transparent") end
            return pct .. "%"
        end
        return _("default")
    end

    return {
        {
            text_func = function()
                return _("Read color") .. ": " .. pctLabel("fill")
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
                return _("Unread color") .. ": " .. pctLabel("bg")
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
                return _("Metro track color") .. ": " .. pctLabel("track")
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
                return _("Tick color") .. ": " .. pctLabel("tick")
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
        {
            text_func = function()
                return _("Border color") .. ": " .. pctLabel("border")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                colorNudge(_("Border color (% black)"), "border", 100, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.border = nil; saveColors()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                if bc.border_thickness then
                    return _("Border thickness") .. ": " .. bc.border_thickness .. "px"
                end
                if is_per_bar then
                    local gbc = self.settings:readSetting("bar_colors")
                    local gt = (gbc and gbc.border_thickness) or 1
                    return _("Border thickness") .. ": " .. _("default") .. " (" .. gt .. "px)"
                end
                return _("Border thickness") .. ": 1px"
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local default_val = 1
                if is_per_bar then
                    local gbc = self.settings:readSetting("bar_colors")
                    if gbc and gbc.border_thickness then default_val = gbc.border_thickness end
                end
                local current = bc.border_thickness or default_val
                self:showNudgeDialog(_("Border thickness"), current, 0, 10, default_val, "px",
                    function(val)
                        bc.border_thickness = (val ~= default_val) and val or nil
                        saveColors()
                    end,
                    nil, nil, nil, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.border_thickness = nil; saveColors()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Tick inversion color") .. ": " .. pctLabel("invert")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                colorNudge(_("Tick inversion color (% black)"), "invert", 0, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.invert = nil; saveColors()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
end

function Bookends:buildBarColorsMenu()
    local bc = self.settings:readSetting("bar_colors") or {}

    local function saveColors()
        if not bc.fill and not bc.bg and not bc.track and not bc.tick and bc.invert_read_ticks == nil and not bc.tick_height_pct and not bc.border and not bc.invert and not bc.border_thickness then
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
            local m = self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER)
            return _("Tick width") .. ": " .. m .. "x"
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showNudgeDialog(_("Tick width"), self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER), 1, 5, self.DEFAULT_TICK_WIDTH_MULTIPLIER, "x",
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

function Bookends:buildColoursMenu()
    local items = self:buildTextColourMenu()
    items[#items].separator = true
    table.insert(items, {
        text = _("Progress bar colors and tick marks"),
        sub_item_table_func = function()
            return self:buildBarColorsMenu()
        end,
    })
    return items
end

function Bookends:buildTextColourMenu()
    local text_color = self.settings:readSetting("text_color")
    local symbol_color = self.settings:readSetting("symbol_color")

    local function textPctLabel()
        if text_color then
            local pct = math.floor((0xFF - text_color.grey) * 100 / 0xFF + 0.5)
            if pct == 0 then return _("transparent") end
            return pct .. "%"
        end
        return _("default") .. " (" .. _("book") .. ")"
    end

    local function symbolPctLabel()
        if symbol_color then
            local pct = math.floor((0xFF - symbol_color.grey) * 100 / 0xFF + 0.5)
            if pct == 0 then return _("transparent") end
            return pct .. "%"
        end
        return _("default") .. " (" .. _("text") .. ")"
    end

    return {
        {
            text_func = function()
                return _("Text color") .. ": " .. textPctLabel()
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = text_color and math.floor((0xFF - text_color.grey) * 100 / 0xFF + 0.5) or 100
                self:showNudgeDialog(_("Text color (% black)"), current, 0, 100, 100, "%",
                    function(val)
                        text_color = { grey = 0xFF - math.floor(val * 0xFF / 100 + 0.5) }
                        self.settings:saveSetting("text_color", text_color)
                        self:markDirty()
                    end,
                    nil, nil, nil, touchmenu_instance,
                    function()
                        text_color = nil
                        self.settings:delSetting("text_color")
                        self:markDirty()
                    end,
                    _("Default") .. " (" .. _("book") .. ")")
            end,
            hold_callback = function(touchmenu_instance)
                text_color = nil
                self.settings:delSetting("text_color")
                self:markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
        {
            text_func = function()
                return _("Symbol color") .. ": " .. symbolPctLabel()
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = symbol_color and math.floor((0xFF - symbol_color.grey) * 100 / 0xFF + 0.5) or 100
                self:showNudgeDialog(_("Symbol color (% black)"), current, 0, 100, 100, "%",
                    function(val)
                        symbol_color = { grey = 0xFF - math.floor(val * 0xFF / 100 + 0.5) }
                        self.settings:saveSetting("symbol_color", symbol_color)
                        self:markDirty()
                    end,
                    nil, nil, nil, touchmenu_instance,
                    function()
                        symbol_color = nil
                        self.settings:delSetting("symbol_color")
                        self:markDirty()
                    end,
                    _("Default") .. " (" .. _("text") .. ")")
            end,
            hold_callback = function(touchmenu_instance)
                symbol_color = nil
                self.settings:delSetting("symbol_color")
                self:markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
end

end
