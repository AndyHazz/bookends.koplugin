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
    { _("Examples"), {
        { "[if:wifi=on]%wifi[/if]", _("Show wifi icon when connected") },
        { "[if:batt<20]LOW %batt[/if]", _("Warning when battery below 20%") },
        { "[if:charging=yes]\xE2\x9A\xA1[/if] %batt", _("Bolt icon when charging") },
        { "[if:invert=yes]\xE2\x87\x84[/if]", _("Arrows when page-turn direction is flipped") },
        { "[if:speed>0]%speed pg/hr[/if]", _("Speed, hidden until calculated") },
        { "[if:session>0]%session_time[/if]", _("Session time, hidden at start") },
        { "[if:page=odd]%page_num[else]%page_num[/if]", _("Different content on odd/even pages") },
        { "[if:book_pct>90]Almost done![/if]", _("Message near end of book") },
        { "[if:light=off]Light off[else]Light on[/if]", _("Frontlight status") },
        { "[if:format=PDF]%page_num / %page_count[/if]", _("Only show for PDF documents") },
        { "[if:time>22:00]Late night reading![/if]", _("After 10pm") },
        { "[if:day=Sat or day=Sun]Weekend![/if]", _("Weekend days (OR operator)") },
        { "[if:time>=18:00 and time<18:30]6\xE2\x80\x936:30[/if]", _("Half-hour window (AND operator)") },
        { "[if:not series]Standalone[/if]", _("Books not in a series") },
        { "[if:chap_title_2]%chap_title_2[else]%chap_title_1[/if]", _("Sub-chapter title when present") },
        { "[if:chap_count>20]Long read[/if]", _("Books with many chapters") },
    }},
    { _("Reference"), {
        { "[if:wifi=on]...[/if]", _("wifi — on / off") },
        { "[if:connected=yes]...[/if]", _("connected — yes / no") },
        { "[if:batt<50]...[/if]", _("batt — 0 to 100") },
        { "[if:charging=yes]...[/if]", _("charging — yes / no") },
        { "[if:invert=yes]...[/if]", _("invert — yes / no (page-turn direction)") },
        { "[if:book_pct>50]...[/if]", _("book_pct — 0 to 100 (book progress)") },
        { "[if:chap_pct>50]...[/if]", _("chap_pct — 0 to 100 (chapter progress)") },
        { "[if:chap_num=1]...[/if]", _("chap_num — current chapter number") },
        { "[if:chap_count>20]...[/if]", _("chap_count — total chapter count") },
        { "[if:speed>0]...[/if]", _("speed — pages per hour") },
        { "[if:session>30]...[/if]", _("session — minutes reading") },
        { "[if:session_pages>0]...[/if]", _("session_pages — pages read this session") },
        { "[if:page=odd]...[/if]", _("page — odd / even") },
        { "[if:light=on]...[/if]", _("light — on / off") },
        { "[if:format=EPUB]...[/if]", _("format — EPUB / PDF / CBZ etc.") },
        { "[if:time>18:00]...[/if]", _("time — use HH:MM (24h)") },
        { "[if:day=Mon]...[/if]", _("day — Mon Tue Wed Thu Fri Sat Sun") },
        { "[if:title]...[/if]", _("title — book title (empty string is falsy)") },
        { "[if:author]...[/if]", _("author — author name") },
        { "[if:series]...[/if]", _("series — series + index, empty when standalone") },
        { "[if:chap_title]...[/if]", _("chap_title — current chapter title") },
        { "[if:chap_title_2]...[/if]", _("chap_title_1/2/3 — title at depth 1/2/3") },
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
                -- Conditional row: two-line layout — description on the
                -- first line, raw [if:…] expression on the second. The
                -- surrounding picker menu is opened with multiline=true
                -- (see showTokenPicker below) so \n forces the break.
                -- Both items_per_page halved to give taller rows room.
                table.insert(items, {
                    text = desc .. "\n" .. token,
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
                { text = _("Compare:  =  <  >     Boolean:  and  or  not  ( )"), dim = true, callback = dim },
            }
            -- Append catalog items
            for _, item in ipairs(self:buildTokenItems(self.CONDITIONAL_CATALOG, on_select)) do
                table.insert(cond_items, item)
            end
            IconPicker.showPickerMenu(_("Insert conditional"), cond_items, function(item)
                on_select(item.insert_value)
            end, { multiline = true, items_per_page = 7 })
        end,
    })

    IconPicker.showPickerMenu(_("Insert token"), items, function(item)
        on_select(item.insert_value)
    end)
end

end
