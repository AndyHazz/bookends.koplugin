--- Token picker menu: catalogs, item builder, and the picker dialog.
-- v5 vocabulary throughout. Legacy single-letter tokens still resolve at
-- runtime via the alias table in bookends_tokens.lua, but aren't listed here.
local Tokens = require("bookends_tokens")
local UIManager = require("ui/uimanager")
local _ = require("bookends_i18n").gettext

return function(Bookends)

Bookends.TOKEN_CATALOG = {
    { _("Metadata"), {
        { "%title", _("Document title") },
        { "%author", _("Author(s)") },
        { "%series", _("Series with index (combined)") },
        { "%series_name", _("Series name only") },
        { "%series_num", _("Series number only") },
        { "%chap_title", _("Chapter title (deepest)") },
        { "%chap_title_1", _("Chapter title at depth 1") },
        { "%chap_title_2", _("Chapter title at depth 2") },
        { "%chap_title_3", _("Chapter title at depth 3") },
        { "%chap_num", _("Current chapter number") },
        { "%chap_count", _("Total chapter count") },
        { "%filename", _("File name") },
        { "%lang", _("Book language") },
        { "%format", _("Document format (EPUB, PDF, etc.)") },
        { "%highlights", _("Number of highlights") },
        { "%notes", _("Number of notes") },
        { "%bookmarks", _("Number of bookmarks") },
        { "%annotations", _("Total annotations (bookmarks + highlights + notes)") },
    }},
    { _("Page / progress"), {
        { "%page_num", _("Current page number") },
        { "%page_count", _("Total pages") },
        { "%book_pct", _("Book percentage read") },
        { "%chap_pct", _("Chapter percentage read") },
        { "%chap_read", _("Pages read in chapter") },
        { "%chap_pages", _("Total pages in chapter") },
        { "%chap_pages_left", _("Pages left in chapter") },
        { "%pages_left", _("Pages left in book") },
    }},
    { _("Progress bars"), {
        { "%bar", _("Progress bar (configure type in line editor)") },
        { "%bar{100}", _("Fixed-width progress bar (100px)") },
        { "%bar{v10}", _("Progress bar, 10px tall") },
        { "%bar{200v4}", _("Progress bar, 200px wide and 4px tall") },
    }},
    { _("Time / date"), {
        { "%time", _("Current time (24h, same as %time_24h)") },
        { "%time_12h", _("12-hour clock") },
        { "%time_24h", _("24-hour clock") },
        { "%date", _("Date short (28 Mar)") },
        { "%date_long", _("Date long (28 March 2026)") },
        { "%date_numeric", _("Date numeric (28/03/2026)") },
        { "%weekday", _("Weekday (Friday)") },
        { "%weekday_short", _("Weekday short (Fri)") },
        { "%datetime{%d %B}", _("Custom date/time format (strftime spec)") },
        { "%chap_time_left", _("Time left in chapter") },
        { "%book_time_left", _("Time left in book") },
    }},
    { _("Session / reading"), {
        { "%session_time", _("Session reading time") },
        { "%session_pages", _("Session pages read") },
        { "%speed", _("Reading speed (pages/hour)") },
        { "%book_read_time", _("Total reading time for book") },
    }},
    { _("Device"), {
        { "%batt", _("Battery level") },
        { "%batt_icon", _("Battery icon (dynamic)") },
        { "%wifi", _("Wi-Fi icon (dynamic)") },
        { "%invert", _("Page-turn direction \xE2\x87\x84 (shows when inverted)") },
        { "%light", _("Frontlight brightness") },
        { "%warmth", _("Frontlight warmth") },
        { "%mem", _("RAM used %") },
        { "%ram", _("RAM used (MiB)") },
        { "%disk", _("Free disk space") },
    }},
    { _("Snippets"), {
        { "\xE2\x80\x94 Page %page_num of %page_count \xE2\x80\x94", "" },
        { "%title \xE2\x8B\xAE [i]%author[/i]", "" },
        { "%bookmarks Bookmark(s)", "" },
        { "%highlights Highlight(s)", "" },
        { "\xE2\x8C\x9B %session_time \xC2\xBB %session_pages page session", "" },
    }},
}

Bookends.CONDITIONAL_CATALOG = {
    { _("Reference"), {
        { "[if:wifi=on]...[/if]", _("If Wi-Fi is on") },
        { "[if:connected=yes]...[/if]", _("If connected") },
        { "[if:batt<50]...[/if]", _("Battery 0\xE2\x80\x93100") },
        { "[if:charging=yes]...[/if]", _("If charging") },
        { "[if:invert=yes]...[/if]", _("If page-turn flipped") },
        { "[if:book_pct>50]...[/if]", _("Book progress 0\xE2\x80\x93100") },
        { "[if:chap_pct>50]...[/if]", _("Chapter progress 0\xE2\x80\x93100") },
        { "[if:chap_num=1]...[/if]", _("Current chapter number") },
        { "[if:chap_count>20]...[/if]", _("Total chapters") },
        { "[if:speed>0]...[/if]", _("Pages per hour") },
        { "[if:session>30]...[/if]", _("Minutes this session") },
        { "[if:session_pages>0]...[/if]", _("Pages this session") },
        { "[if:page=odd]...[/if]", _("odd / even") },
        { "[if:light=on]...[/if]", _("If frontlight on") },
        { "[if:format=EPUB]...[/if]", _("EPUB / PDF / CBZ / \xE2\x80\xA6") },
        { "[if:time>18:00]...[/if]", _("Current HH:MM (24h)") },
        { "[if:day=Mon]...[/if]", _("Mon\xE2\x80\x93Sun") },
        { "[if:title]...[/if]", _("If book has title") },
        { "[if:author]...[/if]", _("If book has author") },
        { "[if:series]...[/if]", _("If book in series") },
        { "[if:chap_title]...[/if]", _("If chapter has title") },
        { "[if:chap_title_2]...[/if]", _("Chapter title at depth 1/2/3") },
    }},
    { _("Examples"), {
        { "[if:wifi=on]%wifi[/if]", _("Wi-Fi icon when connected") },
        { "[if:batt<20]LOW %batt[/if]", _("Low-battery warning") },
        { "[if:charging=yes]\xE2\x9A\xA1[/if] %batt", _("Bolt when charging") },
        { "[if:invert=yes]\xE2\x87\x84[/if]", _("Arrow when page-turn flipped") },
        { "[if:speed>0]%speed pg/hr[/if]", _("Speed once calculated") },
        { "[if:session>0]%session_time[/if]", _("Session time after start") },
        { "[if:page=odd]%page_num[else]%page_num[/if]", _("Odd/even variations") },
        { "[if:book_pct>90]Almost done![/if]", _("Near end of book") },
        { "[if:light=off]Light off[else]Light on[/if]", _("Frontlight on/off label") },
        { "[if:format=PDF]%page_num / %page_count[/if]", _("Only for PDFs") },
        { "[if:time>22:00]Late night reading![/if]", _("Late-night reading") },
        { "[if:day=Sat or day=Sun]Weekend![/if]", _("Weekends") },
        { "[if:time>=18:00 and time<18:30]6\xE2\x80\x936:30[/if]", _("Time window") },
        { "[if:not series]Standalone[/if]", _("Non-series books") },
        { "[if:chap_title_2]%chap_title_2[else]%chap_title_1[/if]", _("Fall back to shallower chapter") },
        { "[if:chap_count>20]Long read[/if]", _("Long books (20+ chapters)") },
        { "%title[if:chap_title_1!=@title] \xE2\x80\xA2 %chap_title_1[/if]", _("Chapter title only when different from book title") },
    }},
}

function Bookends:buildTokenItems(catalog, on_select)
    local session_elapsed = self:getSessionElapsed()
    local session_pages = self:getSessionPages()
    local items = {}
    for _, category in ipairs(catalog) do
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
            local current = ""
            if self.ui then
                local expanded = Tokens.expand(token, self.ui, session_elapsed, session_pages,
                    nil, self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER))
                if expanded and expanded ~= "" and expanded ~= token then
                    current = expanded
                end
            end
            if desc == "" then
                -- Snippet row (category "Snippets"): the "token" field is an
                -- entire format-string template. Keep the legacy single-line
                -- display — the template itself is the primary label.
                local display = token
                if current ~= "" and current ~= token then
                    display = display .. "  \xE2\x86\x92 " .. current
                end
                table.insert(items, {
                    text = display,
                    insert_value = token,
                })
            elseif token:sub(1, 4) == "[if:" then
                -- Conditional row: expression is what an advanced user needs
                -- to see at a glance — put it in the primary text field so
                -- long expressions get Menu's own ellipsis treatment instead
                -- of overflowing mandatory_w. Description sits dim on the
                -- right as secondary orientation.
                table.insert(items, {
                    text = token,
                    mandatory = desc,
                    mandatory_dim = true,
                    insert_value = token,
                })
            else
                -- Regular token row: description is the primary scannable
                -- label, live value sits dim on the right. Token syntax is
                -- deliberately not shown — users tap to insert.
                table.insert(items, {
                    text = desc,
                    mandatory = current ~= "" and ("\xE2\x86\x92 " .. current) or nil,
                    mandatory_dim = true,
                    insert_value = token,
                })
            end
        end
    end
    return items
end

function Bookends:showTokenPicker(on_select)
    local IconPicker = require("bookends_icon_picker")
    local items = self:buildTokenItems(self.TOKEN_CATALOG, on_select)

    -- Insert "Conditionals →" at the top, opening a sub-picker
    table.insert(items, 1, {
        text = _("If/Else conditional tokens") .. " \xE2\x96\xB8",
        callback = function(parent_menu)
            UIManager:close(parent_menu)
            -- Help text at the top
            local dim = function() end
            local cond_items = {
                { text = _("[if:key=value]show when true[/if]"), dim = true, callback = dim },
                { text = _("[if:key=value]if true[else]if false[/if]"), dim = true, callback = dim },
                { text = _("Compare:  =  !=  <  >     Boolean:  and  or  not  ( )"), dim = true, callback = dim },
                { text = _("@key = another field's value (chap_title_1!=@title)"), dim = true, callback = dim },
            }
            -- Append catalog items
            for _, item in ipairs(self:buildTokenItems(self.CONDITIONAL_CATALOG, on_select)) do
                table.insert(cond_items, item)
            end
            IconPicker.showPickerMenu(_("Insert conditional"), cond_items, function(item)
                on_select(item.insert_value)
            end)
        end,
    })

    IconPicker.showPickerMenu(_("Insert token"), items, function(item)
        on_select(item.insert_value)
    end)
end

end
