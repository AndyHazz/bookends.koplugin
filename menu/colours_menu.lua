--- Colour-related menus: text/symbol colours and bar colours/ticks.
-- Attached onto the Bookends class by main.lua on plugin load.
local _ = require("bookends_i18n").gettext
local Device = require("device")
local Colour = require("bookends_colour")

return function(Bookends)

--- Build the shared colour items used by bar colours (read / unread /
--- metro-track / tick / invert toggle / border / border thickness / tick-invert).
--- When is_per_bar is true, the Border thickness item inherits the global
--- bar_colors.border_thickness as its default instead of the hard-coded 1px.
function Bookends:_buildColorItems(bc, saveColors, is_per_bar)
    local function colorNudge(title, field, default_pct, touchmenu_instance)
        if Device:screen():isColorEnabled() then
            -- Colour device: show HSV picker. Hex-shape takes priority; if
            -- the field still holds a legacy raw byte or {grey=N}, render
            -- the equivalent greyscale hex so the picker opens on the
            -- user's currently-stored value.
            local v = bc[field]
            local current_hex
            if type(v) == "table" and v.hex then
                current_hex = v.hex
            elseif type(v) == "table" and v.grey then
                local g = string.format("%02X", v.grey)
                current_hex = "#" .. g .. g .. g
            elseif type(v) == "number" then
                local g = string.format("%02X", v)
                current_hex = "#" .. g .. g .. g
            end
            local default_hex = Colour.defaultHexFor(field)
            self:showColourPicker(title, current_hex, default_hex,
                function(new_hex)
                    bc[field] = { hex = new_hex }
                    saveColors()
                end,
                function()
                    bc[field] = nil
                    saveColors()
                end,
                touchmenu_instance)
            return
        end
        -- Greyscale device: existing nudge path, unchanged.
        local v = bc[field]
        local byte
        if type(v) == "table" and v.grey then byte = v.grey
        elseif type(v) == "number" then byte = v
        end
        local current = byte and math.floor((0xFF - byte) * 100 / 0xFF + 0.5) or default_pct
        self:showNudgeDialog(title, current, 0, 100, default_pct, "%",
            function(val)
                bc[field] = { grey = 0xFF - math.floor(val * 0xFF / 100 + 0.5) }
                saveColors()
            end,
            nil, nil, nil, touchmenu_instance,
            function()
                bc[field] = nil; saveColors()
            end,
            _("Default") .. " (" .. _("per style") .. ")")
    end

    local function pctLabel(field)
        local v = bc[field]
        if not v then return _("default") end
        if type(v) == "table" and v.hex then return v.hex end
        local byte
        if type(v) == "table" and v.grey then byte = v.grey
        elseif type(v) == "number" then byte = v
        end
        if byte then
            local pct = math.floor((0xFF - byte) * 100 / 0xFF + 0.5)
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
                return _("Metro read color") .. ": " .. pctLabel("metro_fill")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                colorNudge(_("Metro read color (% black)"), "metro_fill", 100, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                bc.metro_fill = nil; saveColors()
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
        if not bc.fill and not bc.bg and not bc.track and not bc.tick and bc.invert_read_ticks == nil and not bc.tick_height_pct and not bc.border and not bc.invert and not bc.border_thickness and not bc.metro_fill then
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
    local function textColorPickerOrNudge(field, title, default_label_suffix, touchmenu_instance)
        local stored = self.settings:readSetting(field)
        if Device:screen():isColorEnabled() then
            local current_hex
            if stored and stored.hex then
                current_hex = stored.hex
            elseif stored and stored.grey then
                local g = string.format("%02X", stored.grey)
                current_hex = "#" .. g .. g .. g
            end
            self:showColourPicker(title, current_hex, Colour.defaultHexFor(field),
                function(new_hex)
                    self.settings:saveSetting(field, { hex = new_hex })
                    self:markDirty()
                end,
                function()
                    self.settings:delSetting(field)
                    self:markDirty()
                end,
                touchmenu_instance)
            return
        end
        -- Greyscale: existing nudge path.
        local byte = (stored and stored.grey) or nil
        local current = byte and math.floor((0xFF - byte) * 100 / 0xFF + 0.5) or 100
        self:showNudgeDialog(title, current, 0, 100, 100, "%",
            function(val)
                self.settings:saveSetting(field, { grey = 0xFF - math.floor(val * 0xFF / 100 + 0.5) })
                self:markDirty()
            end,
            nil, nil, nil, touchmenu_instance,
            function()
                self.settings:delSetting(field)
                self:markDirty()
            end,
            _("Default") .. " (" .. default_label_suffix .. ")")
    end

    local function textPctLabel()
        local text_color = self.settings:readSetting("text_color")
        if text_color then
            local pct = math.floor((0xFF - text_color.grey) * 100 / 0xFF + 0.5)
            if pct == 0 then return _("transparent") end
            return pct .. "%"
        end
        return _("default") .. " (" .. _("book") .. ")"
    end

    local function symbolPctLabel()
        local symbol_color = self.settings:readSetting("symbol_color")
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
                textColorPickerOrNudge("text_color", _("Text color"), _("book"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
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
                textColorPickerOrNudge("symbol_color", _("Symbol color"), _("text"), touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                self.settings:delSetting("symbol_color")
                self:markDirty()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        },
    }
end

end
