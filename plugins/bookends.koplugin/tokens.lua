local Device = require("device")
local datetime = require("datetime")

local Tokens = {}

function Tokens.expand(format_str, ui, session_start_time, session_pages_read, preview_mode)
    -- Fast path: no tokens
    if not format_str:find("%%") then
        return format_str
    end

    local pageno = ui.view.state.page
    local doc = ui.document

    -- Page numbers (respects hidden flows + pagemap)
    local currentpage
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        currentpage = ui.pagemap:getCurrentPageLabel(true) or ""
    elseif pageno and doc:hasHiddenFlows() then
        currentpage = doc:getPageNumberInFlow(pageno)
    else
        currentpage = pageno or 0
    end

    local totalpages
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        totalpages = ui.pagemap:getLastPageLabel(true) or ""
    elseif pageno and doc:hasHiddenFlows() then
        local flow = doc:getPageFlow(pageno)
        totalpages = doc:getTotalPagesInFlow(flow)
    else
        totalpages = doc:getPageCount()
    end

    -- Book percentage
    local percent = ""
    if type(currentpage) == "number" and type(totalpages) == "number" and totalpages > 0 then
        percent = math.floor(currentpage / totalpages * 100)
    end

    -- Chapter progress
    local chapter_pct = ""
    local chapter_pages_done = ""
    local chapter_pages_left = ""
    local chapter_total_pages = ""
    local chapter_title = ""
    if pageno and ui.toc then
        local done = ui.toc:getChapterPagesDone(pageno)
        local total = ui.toc:getChapterPageCount(pageno)
        if done and total and total > 0 then
            chapter_pages_done = done + 1 -- +1 to include current page
            chapter_total_pages = total
            chapter_pct = math.floor(chapter_pages_done / total * 100)
        end
        local left = ui.toc:getChapterPagesLeft(pageno)
        if left then
            chapter_pages_left = left
        end
        local title = ui.toc:getTocTitleByPage(pageno)
        if title and title ~= "" then
            chapter_title = title
        end
    end

    -- Session pages read (high-water mark minus start)
    local session_pages = math.max(0, session_pages_read or 0)

    -- Pages left in book
    local pages_left_book = ""
    if pageno then
        local left = doc:getTotalPagesLeft(pageno)
        if left then
            pages_left_book = left
        end
    end

    -- Time left in chapter / document (via statistics plugin)
    local time_left_chapter = ""
    local time_left_doc = ""
    if pageno and ui.statistics and ui.statistics.getTimeForPages then
        local ch_left = ui.toc and ui.toc:getChapterPagesLeft(pageno, true)
        if not ch_left then
            ch_left = doc:getTotalPagesLeft(pageno)
        end
        if ch_left then
            local result = ui.statistics:getTimeForPages(ch_left)
            if result and result ~= "N/A" then
                time_left_chapter = result
            end
        end
        local doc_left = doc:getTotalPagesLeft(pageno)
        if doc_left then
            local result = ui.statistics:getTimeForPages(doc_left)
            if result and result ~= "N/A" then
                time_left_doc = result
            end
        end
    end

    -- Clock
    local time_12h = os.date("%I:%M %p"):gsub("^0", "") -- strip leading zero
    local time_24h = os.date("%H:%M")

    -- Session reading time
    local session_time = ""
    if session_start_time then
        local elapsed = os.time() - session_start_time
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        session_time = datetime.secondsToClockDuration(user_duration_format, elapsed, true)
    end

    -- Document metadata — use ui.doc_props (enriched) with doc:getProps() as fallback
    local doc_props = ui.doc_props or {}
    local props = doc:getProps()
    local title = doc_props.display_title or props.title or ""
    local authors = doc_props.authors or props.authors or ""
    local series = doc_props.series or props.series or ""
    local series_index = doc_props.series_index or props.series_index
    if series ~= "" and series_index then
        series = series .. " #" .. series_index
    end

    -- Battery
    local powerd = Device:getPowerDevice()
    local batt_lvl = powerd:getCapacity()
    local batt_symbol = ""
    if batt_lvl then
        batt_symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), batt_lvl) or ""
    else
        batt_lvl = ""
    end

    -- Wi-Fi (dynamic icon)
    local NetworkMgr = require("ui/network/manager")
    local wifi_symbol
    if NetworkMgr:isWifiOn() then
        wifi_symbol = "\xEE\xB2\xA8" -- U+ECA8 wifi on
    else
        wifi_symbol = "\xEE\xB2\xA9" -- U+ECA9 wifi off
    end

    -- Memory usage (KOReader process RSS in MiB, same as status bar)
    local mem_usage = ""
    local statm = io.open("/proc/self/statm", "r")
    if statm then
        local _, rss = statm:read("*number", "*number")
        statm:close()
        if rss then
            mem_usage = math.floor(rss * 4096 / 1024 / 1024)
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
        ["%R"] = session_time,
        ["%s"] = tostring(session_pages),
        -- Metadata
        ["%T"] = tostring(title),
        ["%A"] = tostring(authors),
        ["%S"] = tostring(series),
        ["%C"] = tostring(chapter_title),
        -- Device
        ["%b"] = tostring(batt_lvl),
        ["%B"] = tostring(batt_symbol),
        ["%W"] = wifi_symbol,
        ["%m"] = tostring(mem_usage),
    }
    if preview_mode then
        -- In preview mode, replace empty values with descriptive labels
        local labels = {
            ["%c"] = "page", ["%t"] = "total", ["%p"] = "%",
            ["%P"] = "ch%", ["%g"] = "chread", ["%G"] = "chtotal",
            ["%l"] = "chleft", ["%L"] = "left",
            ["%h"] = "chtime", ["%H"] = "time",
            ["%k"] = "12h", ["%K"] = "24h",
            ["%R"] = "session", ["%s"] = "pages",
            ["%T"] = "title", ["%A"] = "author",
            ["%S"] = "series", ["%C"] = "chapter",
            ["%b"] = "batt", ["%B"] = "batt", ["%W"] = "wifi",
            ["%m"] = "mem",
        }
        for token, value in pairs(replace) do
            if value == "" and labels[token] then
                replace[token] = "[" .. labels[token] .. "]"
            end
        end
    end
    return format_str:gsub("(%%%a)", replace)
end

function Tokens.expandPreview(format_str, ui, session_start_time, session_pages_read)
    return Tokens.expand(format_str, ui, session_start_time, session_pages_read, true)
end

return Tokens
