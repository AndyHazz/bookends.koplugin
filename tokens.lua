local Device = require("device")
local datetime = require("datetime")

local Tokens = {}

function Tokens.expand(format_str, ui, session_elapsed, session_pages_read, preview_mode)
    -- Fast path: no tokens
    if not format_str:find("%%") then
        return format_str
    end

    -- Preview mode: return descriptive labels
    if preview_mode then
        local preview = {
            ["%c"] = "[page]", ["%t"] = "[total]", ["%p"] = "[%]",
            ["%P"] = "[ch%]", ["%g"] = "[ch.read]", ["%G"] = "[ch.total]",
            ["%l"] = "[ch.left]", ["%L"] = "[left]",
            ["%h"] = "[ch.time]", ["%H"] = "[time]",
            ["%k"] = "[12h]", ["%K"] = "[24h]",
            ["%d"] = "[date]", ["%D"] = "[date.long]",
            ["%n"] = "[dd/mm/yy]", ["%w"] = "[weekday]", ["%a"] = "[wkday]",
            ["%R"] = "[session]", ["%s"] = "[pages]",
            ["%T"] = "[title]", ["%A"] = "[author]",
            ["%S"] = "[series]", ["%C"] = "[chapter]",
            ["%N"] = "[file]", ["%i"] = "[lang]",
            ["%o"] = "[format]", ["%q"] = "[highlights]", ["%Q"] = "[notes]", ["%x"] = "[bookmarks]",
            ["%r"] = "[pg/hr]", ["%E"] = "[total]",
            ["%b"] = "[batt]", ["%B"] = "[batt]", ["%W"] = "[wifi]",
            ["%f"] = "[light]", ["%F"] = "[warmth]",
            ["%m"] = "[mem]",
        }
        return format_str:gsub("(%%%a)", preview)
    end

    -- Helper: check if any of the given tokens appear in the format string
    local function needs(...)
        for i = 1, select("#", ...) do
            if format_str:find("%%" .. select(i, ...)) then
                return true
            end
        end
        return false
    end

    local pageno = ui.view.state.page
    local doc = ui.document

    -- Page numbers (respects hidden flows + pagemap)
    local currentpage = ""
    local totalpages = ""
    local percent = ""
    local pages_left_book = ""
    if needs("c", "t", "p", "L") then
        if ui.pagemap and ui.pagemap:wantsPageLabels() then
            currentpage = ui.pagemap:getCurrentPageLabel(true) or ""
            totalpages = ui.pagemap:getLastPageLabel(true) or ""
        elseif pageno and doc:hasHiddenFlows() then
            currentpage = doc:getPageNumberInFlow(pageno)
            local flow = doc:getPageFlow(pageno)
            totalpages = doc:getTotalPagesInFlow(flow)
        else
            currentpage = pageno or 0
            totalpages = doc:getPageCount()
        end

        local raw_total = doc:getPageCount()
        if pageno and raw_total and raw_total > 0 then
            percent = math.floor(pageno / raw_total * 100) .. "%"
        end

        if pageno then
            local left = doc:getTotalPagesLeft(pageno)
            if left then pages_left_book = left end
        end
    end

    -- Chapter progress
    local chapter_pct = ""
    local chapter_pages_done = ""
    local chapter_pages_left = ""
    local chapter_total_pages = ""
    local chapter_title = ""
    if needs("P", "g", "G", "l", "C") and pageno and ui.toc then
        local done = ui.toc:getChapterPagesDone(pageno)
        local total = ui.toc:getChapterPageCount(pageno)
        if done and total and total > 0 then
            chapter_pages_done = done + 1
            chapter_total_pages = total
            chapter_pct = math.floor(chapter_pages_done / total * 100) .. "%"
        end
        local left = ui.toc:getChapterPagesLeft(pageno)
        if left then chapter_pages_left = left end
        local title = ui.toc:getTocTitleByPage(pageno)
        if title and title ~= "" then chapter_title = title end
    end

    -- Session pages read
    local session_pages = math.max(0, session_pages_read or 0)

    -- Time left in chapter / document (via statistics plugin)
    local time_left_chapter = ""
    local time_left_doc = ""
    if needs("h", "H") and pageno and ui.statistics and ui.statistics.getTimeForPages then
        if needs("h") then
            local ch_left = ui.toc and ui.toc:getChapterPagesLeft(pageno, true)
            if not ch_left then
                ch_left = doc:getTotalPagesLeft(pageno)
            end
            if ch_left then
                local result = ui.statistics:getTimeForPages(ch_left)
                if result and result ~= "N/A" then time_left_chapter = result end
            end
        end
        if needs("H") then
            local doc_left = doc:getTotalPagesLeft(pageno)
            if doc_left then
                local result = ui.statistics:getTimeForPages(doc_left)
                if result and result ~= "N/A" then time_left_doc = result end
            end
        end
    end

    -- Clock
    local time_12h = ""
    local time_24h = ""
    if needs("k") then
        time_12h = os.date("%I:%M %p"):gsub("^0", "")
    end
    if needs("K") then
        time_24h = os.date("%H:%M")
    end

    -- Dates
    local date_short = ""
    local date_long = ""
    local date_num = ""
    local date_weekday = ""
    local date_weekday_short = ""
    if needs("d", "D", "n", "w", "a") then
        if needs("d") then date_short = os.date("%d %b") end
        if needs("D") then date_long = os.date("%d %B %Y") end
        if needs("n") then date_num = os.date("%d/%m/%Y") end
        if needs("w") then date_weekday = os.date("%A") end
        if needs("a") then date_weekday_short = os.date("%a") end
    end

    -- Session reading time
    local session_time = ""
    if needs("R") and session_elapsed then
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        session_time = datetime.secondsToClockDuration(user_duration_format, session_elapsed, true)
    end

    -- Document metadata
    local title = ""
    local authors = ""
    local series = ""
    local book_language = ""
    if needs("T", "A", "S", "i") then
        local doc_props = ui.doc_props or {}
        local ok, props = pcall(doc.getProps, doc)
        if not ok then props = {} end
        title = doc_props.display_title or props.title or ""
        authors = doc_props.authors or props.authors or ""
        series = doc_props.series or props.series or ""
        local series_index = doc_props.series_index or props.series_index
        if series ~= "" and series_index then
            series = series .. " #" .. series_index
        end
        if needs("i") then
            book_language = doc_props.language or props.language or ""
        end
    end

    -- File name (without path and extension)
    local file_name = ""
    local doc_format = ""
    if needs("N", "o") then
        local filepath = doc.file or ""
        if needs("N") then
            file_name = filepath:match("([^/]+)$") or ""
            file_name = (file_name:gsub("%.[^.]+$", ""))
        end
        if needs("o") then
            doc_format = (filepath:match("%.([^.]+)$") or ""):upper()
        end
    end

    -- Highlights and notes count
    local highlights_count = ""
    local notes_count = ""
    local bookmarks_count = ""
    if needs("q", "Q", "x") and ui.annotation then
        local h, n = ui.annotation:getNumberOfHighlightsAndNotes()
        if needs("q") then highlights_count = tostring(h or 0) end
        if needs("Q") then notes_count = tostring(n or 0) end
        if needs("x") then
            local bm = 0
            for _, item in ipairs(ui.annotation.annotations or {}) do
                if not item.drawer then bm = bm + 1 end
            end
            bookmarks_count = tostring(bm)
        end
    end

    -- Reading speed and total book time (via statistics plugin)
    local reading_speed = ""
    local total_book_time = ""
    if needs("r", "E") and ui.statistics then
        if needs("r") then
            local avg = ui.statistics.avg_time
            if avg and avg > 0 then
                reading_speed = tostring(math.floor(3600 / avg))
            end
        end
        if needs("E") then
            local total_secs = ui.statistics.book_read_time
            if total_secs and total_secs > 0 then
                local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
                total_book_time = datetime.secondsToClockDuration(user_duration_format, total_secs, true)
            end
        end
    end

    -- Battery
    local batt_lvl = ""
    local batt_symbol = ""
    if needs("b", "B") then
        local powerd = Device:getPowerDevice()
        local capacity = powerd:getCapacity()
        if capacity then
            batt_symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), capacity) or ""
            batt_lvl = capacity .. "%"
        end
    end

    -- Wi-Fi
    local wifi_symbol = ""
    if needs("W") then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isWifiOn() then
            wifi_symbol = "\xEE\xB2\xA8" -- U+ECA8 wifi on
        else
            wifi_symbol = "\xEE\xB2\xA9" -- U+ECA9 wifi off
        end
    end

    -- Frontlight
    local fl_intensity = ""
    local fl_warmth = ""
    if needs("f", "F") then
        local powerd = Device:getPowerDevice()
        if needs("f") then
            local val = powerd:frontlightIntensity()
            fl_intensity = val == 0 and "OFF" or tostring(val)
        end
        if needs("F") and Device:hasNaturalLight() then
            fl_warmth = tostring(powerd:toNativeWarmth(powerd:frontlightWarmth()))
        end
    end

    -- Memory usage
    local mem_usage = ""
    if needs("m") then
        local meminfo = io.open("/proc/meminfo", "r")
        if meminfo then
            local total, available
            for line in meminfo:lines() do
                if line:match("^MemTotal:") then
                    total = tonumber(line:match("(%d+)"))
                elseif line:match("^MemAvailable:") then
                    available = tonumber(line:match("(%d+)"))
                end
                if total and available then break end
            end
            meminfo:close()
            if total and available and total > 0 then
                mem_usage = math.floor((total - available) / total * 100) .. "%"
            end
        end
    end

    local replace = {
        -- Page/Progress
        ["%c"] = tostring(currentpage),
        ["%t"] = tostring(totalpages),
        ["%p"] = tostring(percent),
        ["%P"] = tostring(chapter_pct),
        ["%g"] = tostring(chapter_pages_done),
        ["%G"] = tostring(chapter_total_pages),
        ["%l"] = tostring(chapter_pages_left),
        ["%L"] = tostring(pages_left_book),
        -- Time/Reading
        ["%h"] = tostring(time_left_chapter),
        ["%H"] = tostring(time_left_doc),
        ["%k"] = time_12h,
        ["%K"] = time_24h,
        ["%d"] = date_short,
        ["%D"] = date_long,
        ["%n"] = date_num,
        ["%w"] = date_weekday,
        ["%a"] = date_weekday_short,
        ["%R"] = session_time,
        ["%s"] = tostring(session_pages),
        -- Metadata
        ["%T"] = tostring(title),
        ["%A"] = tostring(authors),
        ["%S"] = tostring(series),
        ["%C"] = tostring(chapter_title),
        ["%N"] = file_name,
        ["%i"] = book_language,
        ["%o"] = doc_format,
        ["%q"] = highlights_count,
        ["%Q"] = notes_count,
        ["%x"] = bookmarks_count,
        -- Statistics
        ["%r"] = reading_speed,
        ["%E"] = total_book_time,
        -- Device
        ["%b"] = tostring(batt_lvl),
        ["%B"] = tostring(batt_symbol),
        ["%W"] = wifi_symbol,
        ["%f"] = fl_intensity,
        ["%F"] = fl_warmth,
        ["%m"] = tostring(mem_usage),
    }
    -- Track whether all tokens in the string resolved to empty or "0"
    local has_token = false
    local all_empty = true
    local result = format_str:gsub("(%%%a)", function(token)
        local val = replace[token]
        if val == nil then return token end -- unknown token, leave as-is
        has_token = true
        if val ~= "" and val ~= "0" then
            all_empty = false
        end
        return val
    end)

    -- Handle (s) pluralisation: "1 highlight(s)" -> "1 highlight", "3 highlight(s)" -> "3 highlights"
    result = result:gsub("(%d+)(%D-)%(s%)", function(num, between)
        return num == "1" and num .. between or num .. between .. "s"
    end)

    local is_empty = has_token and all_empty
    return result, is_empty
end

function Tokens.expandPreview(format_str, ui, session_elapsed, session_pages_read)
    return Tokens.expand(format_str, ui, session_elapsed, session_pages_read, true)
end

return Tokens
