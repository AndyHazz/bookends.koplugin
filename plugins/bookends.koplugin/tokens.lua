local Device = require("device")
local datetime = require("datetime")

local Tokens = {}

function Tokens.expand(format_str, ui, session_start_time)
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
    local chapter_title = ""
    if pageno and ui.toc then
        local done = ui.toc:getChapterPagesDone(pageno)
        local total = ui.toc:getChapterPageCount(pageno)
        if done and total and total > 0 then
            chapter_pages_done = done + 1 -- +1 to include current page
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

    -- Pages left in book
    local pages_left_book = ""
    if pageno then
        local left = doc:getTotalPagesLeft(pageno)
        if left then
            pages_left_book = left
        end
    end

    -- Time left in chapter / document
    local time_left_chapter = ""
    local time_left_doc = ""
    local footer = ui.view.footer
    local avg_time = footer and footer.getAvgTimePerPage and footer:getAvgTimePerPage()
    if avg_time and avg_time == avg_time and pageno then
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        local ch_left = ui.toc:getChapterPagesLeft(pageno)
            or doc:getTotalPagesLeft(pageno)
        if ch_left then
            time_left_chapter = datetime.secondsToClockDuration(
                user_duration_format, ch_left * avg_time, true)
        end
        local doc_left = doc:getTotalPagesLeft(pageno)
        if doc_left then
            time_left_doc = datetime.secondsToClockDuration(
                user_duration_format, doc_left * avg_time, true)
        end
    end

    -- Clock
    local time_12h = os.date("%I:%M %p")
    local time_24h = os.date("%H:%M")

    -- Session reading time
    local session_time = ""
    if session_start_time then
        local elapsed = os.time() - session_start_time
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        session_time = datetime.secondsToClockDuration(user_duration_format, elapsed, true)
    end

    -- Document metadata
    local props = doc:getProps()
    local title = props.display_title or ""
    local authors = props.authors or ""
    local series = props.series or ""
    if series ~= "" and props.series_index then
        series = series .. " #" .. props.series_index
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

    local replace = {
        -- Page/Progress
        ["%c"] = tostring(currentpage),
        ["%t"] = tostring(totalpages),
        ["%p"] = tostring(percent),
        ["%P"] = tostring(chapter_pct),
        ["%g"] = tostring(chapter_pages_done),
        ["%l"] = tostring(chapter_pages_left),
        ["%L"] = tostring(pages_left_book),
        -- Time/Reading
        ["%h"] = tostring(time_left_chapter),
        ["%H"] = tostring(time_left_doc),
        ["%k"] = time_12h,
        ["%K"] = time_24h,
        ["%R"] = session_time,
        -- Metadata
        ["%T"] = tostring(title),
        ["%A"] = tostring(authors),
        ["%S"] = tostring(series),
        ["%C"] = tostring(chapter_title),
        -- Device
        ["%b"] = tostring(batt_lvl),
        ["%B"] = tostring(batt_symbol),
        -- Formatting
        ["%r"] = " | ",
    }
    return format_str:gsub("(%%%a)", replace)
end

return Tokens
