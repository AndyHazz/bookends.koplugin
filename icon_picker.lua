local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("i18n").gettext

local IconPicker = {}

-- Icon catalog: { category_label, { {display, description, insert_value}, ... } }
-- insert_value is what gets inserted; display is what's shown in the picker
-- All icons are from KOReader's bundled Nerd Fonts symbols.ttf or basic Unicode
IconPicker.CATALOG = {
    { _("Dynamic"), {
        { "\xEE\x9E\x90", _("Battery (changes with level)"), "%B" },     -- U+E790
        { "\xEE\xB2\xA8", _("Wi-Fi (changes with status)"), "%W" },      -- U+ECA8
    }},
    { _("Device"), {
        { "\xEF\x83\xAB", _("Lightbulb") },             -- U+F0EB fa-lightbulb-o
        { "\xE2\x98\x80", _("Sun (filled)") },             -- U+2600 BLACK SUN WITH RAYS
        { "\xEF\x86\x85", _("Sun (outline)") },          -- U+F185 fa-sun-o
        { "\xEF\x86\x86", _("Moon") },                  -- U+F186 fa-moon-o
        { "\xEE\x88\x97", _("Paper aeroplane") },        -- U+E217
        { "\xEF\x81\x82", _("Adjust / contrast") },     -- U+F042 fa-adjust
        { "\xEF\x83\xA7", _("Lightning bolt") },        -- U+F0E7 fa-bolt
        { "\xEF\x80\x91", _("Power") },                 -- U+F011 fa-power-off
        { "\xEF\x84\x8B", _("Mobile") },                -- U+F10B fa-mobile
        { "\xEF\x87\xAB", _("Wi-Fi") },                 -- U+F1EB fa-wifi
        { "\xEF\x83\x82", _("Cloud") },                 -- U+F0C2 fa-cloud
        { "\xEE\xA9\x9A", _("Memory chip") },           -- U+EA5A
        { "\xEF\x82\xA0", _("HDD / disk") },             -- U+F0A0 fa-hdd-o
    }},
    { _("Reading"), {
        { "\xEF\x80\xAD", _("Book") },                  -- U+F02D fa-book
        { "\xEF\x80\xAE", _("Bookmark (filled)") },     -- U+F02E fa-bookmark
        { "\xEF\x82\x97", _("Bookmark (outline)") },    -- U+F097 fa-bookmark-o
        { "\xEF\x81\xAE", _("Eye") },                   -- U+F06E fa-eye
        { "\xEF\x81\xB0", _("Eye (hidden)") },          -- U+F070 fa-eye-slash
        { "\xEF\x80\xA4", _("Flag") },                  -- U+F024 fa-flag
        { "\xEF\x82\x80", _("Bar chart") },             -- U+F080 fa-bar-chart
        { "\xEF\x83\xA4", _("Tachometer") },            -- U+F0E4 fa-tachometer
        { "\xEF\x87\x9E", _("Sliders") },               -- U+F1DE fa-sliders
    }},
    { _("Time"), {
        { "\xEF\x80\x97", _("Clock") },                 -- U+F017 fa-clock-o
        { "\xE2\x8F\xB2", _("Stopwatch") },             -- U+23F2
        { "\xE2\x8C\x9A", _("Watch") },                 -- U+231A
        { "\xE2\x8F\xB3", _("Hourglass") },             -- U+23F3
        { "\xE2\x8C\x9B", _("Hourglass (filled)") },    -- U+231B
        { "\xEF\x81\xB3", _("Calendar") },              -- U+F073 fa-calendar
        { "\xEF\x89\xB4", _("Calendar (checked)") },    -- U+F274 fa-calendar-check-o
    }},
    { _("Status"), {
        { "\xEF\x80\x8C", _("Check") },                 -- U+F00C fa-check
        { "\xEF\x80\x8D", _("Cross") },                 -- U+F00D fa-times
        { "\xEF\x81\x9A", _("Info") },                  -- U+F05A fa-info-circle
        { "\xEF\x81\xB1", _("Warning") },               -- U+F071 fa-warning
        { "\xEF\x80\x93", _("Cog") },                   -- U+F013 fa-cog
    }},
    { _("Symbols"), {
        { "\xE2\x98\xBC", _("Sun (outline)") },         -- U+263C
        { "\xE2\x99\xA8", _("Hot springs / warmth") },  -- U+2668
        { "\xE2\x99\xA0", _("Spade") },                 -- U+2660
        { "\xE2\x99\xA3", _("Club") },                  -- U+2663
        { "\xE2\x99\xA5", _("Heart") },                 -- U+2665
        { "\xE2\x99\xA6", _("Diamond suit") },          -- U+2666
        { "\xE2\x98\x85", _("Star (filled)") },         -- U+2605
        { "\xE2\x98\x86", _("Star (outline)") },        -- U+2606
        { "\xE2\x9C\x93", _("Check mark") },            -- U+2713
        { "\xE2\x9C\x97", _("Cross mark") },            -- U+2717
        { "\xE2\x88\x9E", _("Infinity") },              -- U+221E
        { "\xC2\xA7",     _("Section sign") },          -- U+00A7
        { "\xC2\xB6",     _("Pilcrow / paragraph") },   -- U+00B6
        { "\xE2\x80\xA0", _("Dagger") },                -- U+2020
        { "\xE2\x80\xA1", _("Double dagger") },         -- U+2021
        { "\xC2\xA9",     _("Copyright") },             -- U+00A9
        { "\xE2\x84\x96", _("Numero") },                -- U+2116
        { "\xE2\x9A\xA1", _("High voltage") },          -- U+26A1
    }},
    { _("Arrows"), {
        { "\xE2\x86\x90", _("Arrow left") },            -- U+2190
        { "\xE2\x86\x92", _("Arrow right") },           -- U+2192
        { "\xE2\x86\x91", _("Arrow up") },              -- U+2191
        { "\xE2\x86\x93", _("Arrow down") },            -- U+2193
        { "\xE2\x87\x84", _("Arrows left-right") },     -- U+21C4
        { "\xE2\x87\x89", _("Double arrows right") },   -- U+21C9
        { "\xE2\x86\xA2", _("Arrow left with tail") },  -- U+21A2
        { "\xE2\x86\xA3", _("Arrow right with tail") }, -- U+21A3
        { "\xE2\xA4\x9F", _("Arrow left to bar") },     -- U+291F
        { "\xE2\xA4\xA0", _("Arrow right to bar") },    -- U+2920
        { "\xE2\x96\xB6", _("Triangle right") },        -- U+25B6
        { "\xE2\x97\x80", _("Triangle left") },         -- U+25C0
        { "\xE2\x96\xB2", _("Triangle up") },           -- U+25B2
        { "\xE2\x96\xBC", _("Triangle down") },         -- U+25BC
        { "\xE2\x80\xB9", _("Single angle left") },     -- U+2039
        { "\xE2\x80\xBA", _("Single angle right") },    -- U+203A
        { "\xC2\xAB",     _("Double angle left") },     -- U+00AB
        { "\xC2\xBB",     _("Double angle right") },    -- U+00BB
    }},
    { _("Separators"), {
        { "|",             _("Vertical bar") },          -- U+007C
        { "\xE2\x80\xA2", _("Bullet") },                -- U+2022
        { "\xC2\xB7",     _("Middle dot") },             -- U+00B7
        { "\xE2\x8B\xAE", _("Vertical ellipsis") },     -- U+22EE
        { "\xE2\x97\x86", _("Diamond") },               -- U+25C6
        { "\xE2\x80\x94", _("Em dash") },               -- U+2014
        { "\xE2\x80\x93", _("En dash") },               -- U+2013
        { "\xE2\x80\xA6", _("Horizontal ellipsis") },   -- U+2026
        { "/",             _("Slash") },                 -- U+002F
        { "\xE2\x88\x95", _("Division slash") },        -- U+2215
        { "\xE2\x81\x84", _("Fraction slash") },        -- U+2044
        { "//",            _("Double slash") },
        { "~",             _("Tilde") },                 -- U+007E
        { "\xE2\x80\xA3", _("Triangular bullet") },     -- U+2023
    }},
}

--- Build the flat item list for the Menu widget, with category headers.
function IconPicker:buildItemTable()
    local items = {}
    for _, category in ipairs(self.CATALOG) do
        local label = category[1]
        local icons = category[2]
        table.insert(items, {
            text = "\xE2\x94\x80\xE2\x94\x80 " .. label .. " \xE2\x94\x80\xE2\x94\x80",
            dim = true,
            callback = function() end,
        })
        for _, icon_entry in ipairs(icons) do
            local display = icon_entry[1]
            local desc = icon_entry[2]
            local insert_value = icon_entry[3] or display -- default: insert the glyph itself
            table.insert(items, {
                text = display .. "   " .. desc,
                insert_value = insert_value,
            })
        end
    end
    return items
end

--- Show the icon picker. When user selects an icon, on_select(value) is called.
function IconPicker:show(on_select)
    local item_table = self:buildItemTable()
    local Device = require("device")
    local Screen = Device.screen

    local menu
    menu = Menu:new{
        title = _("Insert icon"),
        item_table = item_table,
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

return IconPicker
