local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("bookends_i18n").gettext

local IconPicker = {}

-- Icon catalog: { category_label, { {display, description, insert_value}, ... } }
-- insert_value is what gets inserted; display is what's shown in the picker
-- All icons are from KOReader's bundled Nerd Fonts symbols.ttf or basic Unicode
IconPicker.CATALOG = {
    { _("Dynamic"), {
        { "\xEE\x9E\x90", _("Battery (changes with level)"), "%batt_icon" }, -- U+E790
        { "\xEE\xB2\xA8", _("Wi-Fi (changes with status)"), "%wifi" },       -- U+ECA8
    }},
    { _("Device"), {
        { "\xEF\x83\xAB", _("Lightbulb") },             -- U+F0EB fa-lightbulb-o
        { "\xF0\x9F\x92\xA1", _("Lightbulb emoji") },   -- U+1F4A1
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
        { "\xE2\x87\x90", _("Double arrow left") },     -- U+21D0
        { "\xE2\x87\x92", _("Double arrow right") },    -- U+21D2
        { "\xE2\x87\x91", _("Double arrow up") },       -- U+21D1
        { "\xE2\x87\x93", _("Double arrow down") },     -- U+21D3
        { "\xE2\x87\x84", _("Arrows left-right") },     -- U+21C4
        { "\xE2\x87\x89", _("Double arrows right") },   -- U+21C9
        { "\xE2\xA5\x96", _("Left harpoon with right arrow") }, -- U+2956
        { "\xE2\xA4\xBB", _("Curved back arrow") },     -- U+293B
        { "\xE2\x86\xA2", _("Arrow left with tail") },  -- U+21A2
        { "\xE2\x86\xA3", _("Arrow right with tail") }, -- U+21A3
        { "\xE2\xA4\x9F", _("Arrow left to bar") },     -- U+291F
        { "\xE2\xA4\xA0", _("Arrow right to bar") },    -- U+2920
        { "\xE2\x86\xA9", _("Arrow left hooked") },     -- U+21A9
        { "\xE2\x86\xAA", _("Arrow right hooked") },    -- U+21AA
        { "\xE2\xA4\xB4", _("Arrow right then up") },   -- U+2934
        { "\xE2\xA4\xB5", _("Arrow right then down") }, -- U+2935
        { "\xE2\x86\xB0", _("Arrow up then left") },    -- U+21B0
        { "\xE2\x86\xB1", _("Arrow up then right") },   -- U+21B1
        { "\xE2\x86\xB2", _("Arrow down then left") },  -- U+21B2
        { "\xE2\x86\xB3", _("Arrow down then right") }, -- U+21B3
        { "\xE2\x86\xBA", _("Circle arrow left") },     -- U+21BA
        { "\xE2\x86\xBB", _("Circle arrow right") },    -- U+21BB
        { "\xE2\x9E\x94", _("Heavy arrow right") },     -- U+2794
        { "\xE2\x9E\x9C", _("Heavy round arrow right") }, -- U+279C
        { "\xE2\x9E\x9D", _("Triangle-head right") },   -- U+279D
        { "\xE2\x9E\x9E", _("Heavy triangle right") },  -- U+279E
        { "\xE2\x9E\xA4", _("Arrowhead right") },       -- U+27A4
        { "\xE2\x9F\xB5", _("Long arrow left") },       -- U+27F5
        { "\xE2\x9F\xB6", _("Long arrow right") },      -- U+27F6
        { "\xE2\x96\xB6", _("Triangle right") },        -- U+25B6
        { "\xE2\x97\x80", _("Triangle left") },         -- U+25C0
        { "\xE2\x96\xB2", _("Triangle up") },           -- U+25B2
        { "\xE2\x96\xBC", _("Triangle down") },         -- U+25BC
        { "\xE2\x80\xB9", _("Single angle left") },     -- U+2039
        { "\xE2\x80\xBA", _("Single angle right") },    -- U+203A
        { "\xC2\xAB",     _("Double angle left") },     -- U+00AB
        { "\xC2\xBB",     _("Double angle right") },    -- U+00BB
        { "\xE2\x98\x9B", _("Pointing right (black)") }, -- U+261B
        { "\xE2\x98\x9E", _("Pointing right") },        -- U+261E
        { "\xE2\x98\x9C", _("Pointing left") },         -- U+261C
        { "\xE2\x98\x9D", _("Pointing up") },           -- U+261D
        { "\xE2\x98\x9F", _("Pointing down") },         -- U+261F
    }},
    { _("Progress blocks"), {
        { "\xE2\x96\xB0", _("Slant block") },           -- U+25B0 BLACK PARALLELOGRAM
        { "\xE2\x96\xB1", _("Slant block (empty)") },   -- U+25B1 WHITE PARALLELOGRAM
        { "\xE2\x96\xAE", _("Vertical block") },        -- U+25AE BLACK VERTICAL RECTANGLE
        { "\xE2\x96\xAF", _("Vertical block (empty)") },-- U+25AF WHITE VERTICAL RECTANGLE
        { "\xE2\x96\xA0", _("Square (filled)") },       -- U+25A0 BLACK SQUARE
        { "\xE2\x96\xA1", _("Square (empty)") },        -- U+25A1 WHITE SQUARE
        { "\xE2\x96\x88", _("Block (full)") },          -- U+2588 FULL BLOCK
        { "\xE2\x96\x93", _("Block (dark)") },          -- U+2593 DARK SHADE
        { "\xE2\x96\x92", _("Block (medium)") },        -- U+2592 MEDIUM SHADE
        { "\xE2\x96\x91", _("Block (light)") },         -- U+2591 LIGHT SHADE
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
        { "\xE2\x81\x84\xE2\x81\x84", _("Double fraction slash") }, -- U+2044 ×2 (matches stock chapter progress)
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

--- Show a centered Menu popup for picker UIs (tokens, icons, etc.)
-- opts:
--   multiline      — if true, items may wrap to multiple lines (enables \n
--                    in text to produce a two-line row, e.g. for the
--                    conditional picker where desc + expression need both).
--   items_per_page — override the default. Lower when multiline so taller
--                    rows still fit comfortably.
--   width_pct      — portion of screen width to use (0.0–1.0, default 0.9).
--                    0.9 chosen so the conditional picker's long [if:…]
--                    expressions fit without truncation, and kept uniform
--                    across the token and icon pickers so switching between
--                    them doesn't visually jump.
function IconPicker.showPickerMenu(title, items, on_choice, opts)
    opts = opts or {}
    local Device = require("device")
    local Screen = Device.screen
    local Size = require("ui/size")

    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        width = math.floor(Screen:getWidth() * (opts.width_pct or 0.9)),
        height = math.floor(Screen:getHeight() * 0.8),
        items_per_page = opts.items_per_page or 14,
        multilines_show_more_text = opts.multiline or false,
        onMenuChoice = function(_, item)
            if item.callback then
                item.callback(menu)
            elseif item.insert_value then
                UIManager:close(menu)
                on_choice(item)
            end
        end,
    }
    if menu[1] then menu[1].radius = Size.radius.window end
    -- Shrink the stock pagination (default icons = 40, font size stock)
    -- to match the preset library's 28px / 14pt compact style. We reach
    -- into the Menu widget's named chevron + page-info-text Buttons, poke
    -- new sizes, and trigger a full relayout via updateItems so the Menu's
    -- cached bottom_height recomputes against the smaller content — without
    -- this step the pagination row still reserves its stock-sized footprint
    -- and the chevrons float inside the over-tall area.
    local chev_size = Screen:scaleBySize(32)
    local function patchIconBtn(btn)
        if not btn then return end
        btn.icon_width = chev_size
        btn.icon_height = chev_size
        if btn.label_widget then btn.label_widget:free() end
        btn:init()
    end
    patchIconBtn(menu.page_info_left_chev)
    patchIconBtn(menu.page_info_right_chev)
    patchIconBtn(menu.page_info_first_chev)
    patchIconBtn(menu.page_info_last_chev)
    if menu.page_info_text then
        menu.page_info_text.text_font_size = 15
        -- Match the preset library pagination, which inherits Button's default
        -- text_font_bold = true. The stock Menu explicitly opts out of bold.
        menu.page_info_text.text_font_bold = true
        if menu.page_info_text.label_widget then
            menu.page_info_text.label_widget:free()
        end
        menu.page_info_text:init()
    end
    pcall(function() menu:updateItems() end)

    -- The footer is a BottomContainer that pins page_info's bottom edge to
    -- the dialog's inner bottom. With our shrunken pagination content, that
    -- left the pagination row flush with the dialog edge and a big gap
    -- above it. Shrinking the footer's dimen.h by a fixed amount pulls the
    -- pinning point up, visually centring the pagination in the reserved
    -- bottom region. We locate the footer by identity match on menu.page_info
    -- rather than by index so we're not depending on OverlapGroup child order.
    do
        local frame = menu[1]
        local overlap = frame and frame[1]
        if overlap then
            for i = 1, #overlap do
                local c = overlap[i]
                if c and c[1] == menu.page_info and c.dimen then
                    c.dimen.h = c.dimen.h - Screen:scaleBySize(5)
                    break
                end
            end
        end
    end
    local x = math.floor((Screen:getWidth() - menu.dimen.w) / 2)
    local y = math.floor((Screen:getHeight() - menu.dimen.h) / 2)
    UIManager:show(menu, nil, nil, x, y)
end

--- Show the icon picker. When user selects an icon, on_select(value) is called.
function IconPicker:show(on_select)
    IconPicker.showPickerMenu(_("Insert symbol"), self:buildItemTable(), function(item)
        on_select(item.insert_value)
    end)
end

return IconPicker
