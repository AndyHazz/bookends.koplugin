--- Token picker menu: catalogs, item builder, and the picker dialog.
local Tokens = require("bookends_tokens")
local UIManager = require("ui/uimanager")
local _ = require("bookends_i18n").gettext

return function(Bookends)

Bookends.TOKEN_CATALOG = {
    { _("Metadata"), {
        { "%T", _("Document title") },
        { "%A", _("Author(s)") },
        { "%S", _("Series with index") },
        { "%C", _("Chapter title (deepest)") },
        { "%C1", _("Chapter title at depth 1") },
        { "%C2", _("Chapter title at depth 2") },
        { "%C3", _("Chapter title at depth 3") },
        { "%N", _("File name") },
        { "%i", _("Book language") },
        { "%o", _("Document format (EPUB, PDF, etc.)") },
        { "%q", _("Number of highlights") },
        { "%Q", _("Number of notes") },
        { "%x", _("Number of bookmarks") },
        { "%X", _("Total annotations (bookmarks + highlights + notes)") },
    }},
    { _("Page / progress"), {
        { "%c", _("Current page number") },
        { "%t", _("Total pages") },
        { "%p", _("Book percentage read") },
        { "%P", _("Chapter percentage read") },
        { "%g", _("Pages read in chapter") },
        { "%G", _("Total pages in chapter") },
        { "%l", _("Pages left in chapter") },
        { "%L", _("Pages left in book") },
    }},
    { _("Progress bars"), {
        { "%bar", _("Progress bar (configure type in line editor)") },
        { "%bar{100}", _("Fixed-width progress bar (100px)") },
        { "%bar{v10}", _("Progress bar, 10px tall") },
        { "%bar{200v4}", _("Progress bar, 200px wide and 4px tall") },
    }},
    { _("Time / date"), {
        { "%k", _("12-hour clock") },
        { "%K", _("24-hour clock") },
        { "%d", _("Date short (28 Mar)") },
        { "%D", _("Date long (28 March 2026)") },
        { "%n", _("Date numeric (28/03/2026)") },
        { "%w", _("Weekday (Friday)") },
        { "%a", _("Weekday short (Fri)") },
    }},
    { _("Reading"), {
        { "%h", _("Time left in chapter") },
        { "%H", _("Time left in book") },
        { "%E", _("Total reading time for book") },
        { "%R", _("Session reading time") },
        { "%s", _("Session pages read") },
        { "%r", _("Reading speed (pages/hour)") },
    }},
    { _("Device"), {
        { "%b", _("Battery level") },
        { "%B", _("Battery icon (dynamic)") },
        { "%W", _("Wi-Fi icon (dynamic)") },
        { "%V", _("Page-turn direction \xE2\x87\x84 (shows when inverted)") },
        { "%f", _("Frontlight brightness") },
        { "%F", _("Frontlight warmth") },
        { "%m", _("RAM used %") },
        { "%M", _("RAM used (MiB)") },
    }},
    { _("Snippets"), {
        { "\xE2\x80\x94 Page %c of %t \xE2\x80\x94", "" },
        { "%T \xE2\x8B\xAE [i]%A[/i]", "" },
        { "%x Bookmark(s)", "" },
        { "%q Highlight(s)", "" },
        { "\xE2\x8C\x9B %R \xC2\xBB %s page session", "" },
    }},
}

Bookends.CONDITIONAL_CATALOG = {
    { _("Examples"), {
        { "[if:wifi=on]%W[/if]", _("Show wifi icon when connected") },
        { "[if:batt<20]LOW %b[/if]", _("Warning when battery below 20%") },
        { "[if:charging=yes]\xE2\x9A\xA1[/if] %b", _("Bolt icon when charging") },
        { "[if:invert=yes]\xE2\x87\x84[/if]", _("Arrows when page-turn direction is flipped") },
        { "[if:speed>0]%r pg/hr[/if]", _("Speed, hidden until calculated") },
        { "[if:session>0]%R[/if]", _("Session time, hidden at start") },
        { "[if:page=odd]%c[else]%c[/if]", _("Different content on odd/even pages") },
        { "[if:percent>90]Almost done![/if]", _("Message near end of book") },
        { "[if:light=off]Light off[else]Light on[/if]", _("Frontlight status") },
        { "[if:format=PDF]%c / %t[/if]", _("Only show for PDF documents") },
        { "[if:time>22:00]Late night reading![/if]", _("After 10pm") },
        { "[if:day=Sat]Weekend![else]%a[/if]", _("Different text on Saturdays") },
    }},
    { _("Reference"), {
        { "[if:wifi=on]...[/if]", _("wifi — on / off") },
        { "[if:connected=yes]...[/if]", _("connected — yes / no") },
        { "[if:batt<50]...[/if]", _("batt — 0 to 100") },
        { "[if:charging=yes]...[/if]", _("charging — yes / no") },
        { "[if:invert=yes]...[/if]", _("invert — yes / no (page-turn direction)") },
        { "[if:percent>50]...[/if]", _("percent — 0 to 100 (book)") },
        { "[if:chapter>50]...[/if]", _("chapter — 0 to 100 (chapter)") },
        { "[if:speed>0]...[/if]", _("speed — pages per hour") },
        { "[if:session>30]...[/if]", _("session — minutes reading") },
        { "[if:pages>0]...[/if]", _("pages — session pages read") },
        { "[if:page=odd]...[/if]", _("page — odd / even") },
        { "[if:light=on]...[/if]", _("light — on / off") },
        { "[if:format=EPUB]...[/if]", _("format — EPUB / PDF / CBZ etc.") },
        { "[if:time>18:00]...[/if]", _("time — use HH:MM (24h)") },
        { "[if:day=Mon]...[/if]", _("day — Mon Tue Wed Thu Fri Sat Sun") },
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
            local display = token .. "  " .. desc
            if current ~= "" then
                display = display .. "  \xE2\x86\x92 " .. current  -- → arrow
            end
            table.insert(items, {
                text = display,
                insert_value = token,
            })
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
                { text = _("Operators:  =  <  >"), dim = true, callback = dim },
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
