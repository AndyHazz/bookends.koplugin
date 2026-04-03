local Device = require("device")
local datetime = require("datetime")

local Tokens = {}

-- Map KOReader UI language to a system locale for localized date strings.
-- Caches per language to avoid repeated locale probing.
local _date_locale_cache = {} -- lang -> locale string or false
local function getDateLocale()
    local ok, GetText = pcall(require, "gettext")
    if not ok or not GetText or not GetText.current_lang or GetText.current_lang == "C" then
        return false
    end
    local lang = GetText.current_lang:match("^([a-z]+)") -- e.g. "es" from "es_ES"
    if not lang or lang == "en" then
        return false
    end
    if _date_locale_cache[lang] ~= nil then return _date_locale_cache[lang] end
    -- Try common locale patterns
    local candidates = {
        lang .. "_" .. lang:upper() .. ".UTF-8",  -- es_ES.UTF-8
        lang .. ".UTF-8",                           -- es.UTF-8
    }
    local saved = os.setlocale(nil, "time") -- save current locale
    for _, loc in ipairs(candidates) do
        if os.setlocale(loc, "time") then
            os.setlocale(saved or "C", "time") -- restore previous locale
            _date_locale_cache[lang] = loc
            return loc
        end
    end
    if saved then os.setlocale(saved, "time") end -- restore after failed probes
    _date_locale_cache[lang] = false
    return false
end

function Tokens.expand(format_str, ui, session_elapsed, session_pages_read, preview_mode)
    -- Fast path: no tokens
    if not format_str:find("%%") then
        return format_str
    end

    local orig_format_str = format_str

    -- Pre-parse %X{N} pixel-width modifiers.
    -- Builds a table of per-occurrence limits keyed by a running counter per token,
    -- and strips {N} from the format string so existing expansion works unchanged.
    local token_limits = {}  -- { ["%C"] = { [1] = 200 }, ["%T"] = { [1] = 300 } }
    local bar_limit_w = nil  -- pixel width for %bar{N}, stored separately
    local has_limits = format_str:find("{%d+}")
    if has_limits then
        -- Extract %bar{N} first (before single-char tokens, to avoid %b matching)
        format_str = format_str:gsub("%%bar{(%d+)}", function(n)
            local px = tonumber(n)
            if px and px > 0 then
                bar_limit_w = px
            end
            return "%bar"
        end)
        -- Extract %X{N} for single-char tokens
        format_str = format_str:gsub("(%%%a){(%d+)}", function(token, n)
            local px = tonumber(n)
            if px and px > 0 then
                if not token_limits[token] then
                    token_limits[token] = {}
                end
                table.insert(token_limits[token], px)
            end
            return token
        end)
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
            ["%m"] = "[mem]", ["%M"] = "[rss]",
            ["%v"] = "[disk]",
            ["%bar"] = "\xE2\x96\xB0\xE2\x96\xB0\xE2\x96\xB1\xE2\x96\xB1",  -- ▰▰▱▱
        }
        -- Strip %bar{N} and %X{N} for preview, showing limit in label
        -- %bar{N} must be replaced before %bar (longer pattern first)
        local r = orig_format_str:gsub("%%bar{(%d+)}", function(n)
            return preview["%bar"] .. "{<=" .. n .. "}"
        end)
        r = r:gsub("%%bar", preview["%bar"])
        r = r:gsub("(%%%a){(%d+)}", function(token, n)
            local label = preview[token]
            if label then
                -- Turn [chapter] into {chapter<=200}
                return "{" .. label:sub(2, -2) .. "<=" .. n .. "}"
            end
            return token .. "{" .. n .. "}"
        end)
        r = r:gsub("(%%%a)", preview)
        return r
    end

    -- Helper: check if any of the given single-char tokens appear in the format string.
    -- Uses word boundary to avoid %bar matching %b.
    local function needs(...)
        for i = 1, select("#", ...) do
            if format_str:find("%%" .. select(i, ...) .. "[^%a]") or format_str:match("%%" .. select(i, ...) .. "$") then
                return true
            end
        end
        return false
    end

    local has_bar = format_str:find("%%bar") ~= nil

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
            if (ui.pagemap and ui.pagemap:wantsPageLabels()) or doc:hasHiddenFlows() then
                -- Use stable page numbers: totalpages and currentpage are already stable
                local cur = tonumber(currentpage) or 0
                local tot = tonumber(totalpages) or 0
                if tot > 0 and cur > 0 then
                    pages_left_book = tot - cur
                end
            else
                local left = doc:getTotalPagesLeft(pageno)
                if left then pages_left_book = left end
            end
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

    -- Bar token data (parallel channel — not embedded in text)
    -- Bar token data: compute both book and chapter, caller picks via per-line setting
    local bar_info = nil
    if has_bar then
        local bar_pageno = pageno or 0
        local bar_doc = doc
        local is_cre = ui.rolling ~= nil
        bar_info = {}

        -- Book progress (page-based, matches KOReader footer)
        local book_pct
        local raw_total = bar_doc:getPageCount()
        if raw_total and raw_total > 0 then
            if bar_doc:hasHiddenFlows() then
                local flow = bar_doc:getPageFlow(bar_pageno)
                local flow_total = bar_doc:getTotalPagesInFlow(flow)
                local flow_page = bar_doc:getPageNumberInFlow(bar_pageno)
                book_pct = flow_total > 0 and (flow_page / flow_total) or 0
            else
                book_pct = bar_pageno / raw_total
            end
        end

        -- Chapter tick positions as {fraction, width, depth} — page-based to match KOReader footer
        local ticks = {}
        local raw_total = bar_doc:getPageCount()
        if raw_total and raw_total > 0 and ui.toc then
            local toc_ticks = ui.toc:getTocTicks() or {}
            local max_depth = ui.toc:getMaxDepth() or 1
            for depth, pages in ipairs(toc_ticks) do
                local tick_w = math.max(1, (max_depth - depth + 1) * 2 - 1)
                for _, page in ipairs(pages) do
                    if page > 1 then
                        local tick_frac = page / raw_total
                        if tick_frac > 0 and tick_frac < 1 then
                            table.insert(ticks, { tick_frac, tick_w, depth })
                        end
                    end
                end
            end
        end

        bar_info.book = { kind = "book", pct = book_pct or 0, ticks = ticks }

        -- Chapter progress
        local ch_pct = 0
        if is_cre and bar_doc.getCurrentPos and ui.toc then
            local cur_pos = bar_doc:getCurrentPos()
            -- Find current chapter start: getPreviousChapter returns < pageno,
            -- so on a chapter start page we need to use pageno itself
            local chapter_start = ui.toc:getPreviousChapter(bar_pageno)
            if ui.toc:isChapterStart(bar_pageno) then
                chapter_start = bar_pageno
            end
            local next_chapter = ui.toc:getNextChapter(bar_pageno)
            if chapter_start then
                local start_xp = bar_doc:getPageXPointer(chapter_start)
                local start_pos = start_xp and bar_doc:getPosFromXPointer(start_xp) or 0
                local end_pos
                if next_chapter then
                    local next_xp = bar_doc:getPageXPointer(next_chapter)
                    end_pos = next_xp and bar_doc:getPosFromXPointer(next_xp) or (bar_doc.info and bar_doc.info.doc_height or 0)
                else
                    end_pos = bar_doc.info and bar_doc.info.doc_height or 0
                end
                local range = end_pos - start_pos
                if range > 0 then
                    ch_pct = math.max(0, math.min(1, (cur_pos - start_pos) / range))
                end
            end
        elseif ui.toc then
            local done = ui.toc:getChapterPagesDone(bar_pageno)
            local total = ui.toc:getChapterPageCount(bar_pageno)
            if done and total and total > 0 then
                ch_pct = math.max(0, math.min(1, (done + 1) / total))
            end
        end
        bar_info.chapter = { kind = "chapter", pct = ch_pct, ticks = {} }
        if bar_limit_w then
            bar_info.width = bar_limit_w
        end
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
        -- Use device language for day/month names if available
        local loc = getDateLocale()
        local saved_locale
        if loc then
            saved_locale = os.setlocale(nil, "time")
            os.setlocale(loc, "time")
        end
        if needs("d") then date_short = os.date("%d %b") end
        if needs("D") then date_long = os.date("%d %B %Y") end
        if needs("n") then date_num = os.date("%d/%m/%Y") end
        if needs("w") then date_weekday = os.date("%A") end
        if needs("a") then date_weekday_short = os.date("%a") end
        if saved_locale then
            os.setlocale(saved_locale, "time")
        end
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
            if NetworkMgr:isConnected() then
                wifi_symbol = "\xEE\xB2\xA8" -- U+ECA8 wifi connected
            else
                wifi_symbol = "\xEE\xB2\xA9" -- U+ECA9 wifi enabled, not connected
            end
        -- else: wifi disabled, leave as "" (hidden)
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

    -- Memory usage (system-wide percentage)
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

    -- RAM usage (KOReader process RSS in MB)
    local ram_mb = ""
    if needs("M") then
        local statm = io.open("/proc/self/statm", "r")
        if statm then
            local line = statm:read("*l")
            statm:close()
            if line then
                local rss = line:match("%S+%s+(%d+)")
                if rss then
                    ram_mb = math.floor(tonumber(rss) * 4 / 1024) .. "M"
                end
            end
        end
    end

    -- Disk available
    local disk_avail = ""
    if needs("v") then
        local util = require("util")
        if util.diskUsage then
            local drive = Device.home_dir or "/"
            local ok, usage = pcall(util.diskUsage, drive)
            if ok and usage and type(usage.available) == "number" and usage.available > 0 then
                disk_avail = string.format("%.1fG", usage.available / 1024 / 1024 / 1024)
            end
        end
    end

    -- Replace bar tokens with a placeholder so buildBarLine knows where to insert the bar.
    -- Uses U+FFFC OBJECT REPLACEMENT CHARACTER (UTF-8: \xEF\xBF\xBC).
    local BAR_PLACEHOLDER = "\xEF\xBF\xBC"
    local result_str = format_str
    if has_bar then
        result_str = result_str:gsub("%%bar", BAR_PLACEHOLDER)
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
        ["%M"] = ram_mb,
        ["%v"] = disk_avail,
    }
    -- Track whether all tokens in the string resolved to empty or "0"
    local has_token = false
    local all_empty = true
    -- Per-token occurrence counters for matching limits
    local token_occurrence = {}
    local result = result_str:gsub("(%%%a)", function(token)
        local val = replace[token]
        if val == nil then return token end -- unknown token, leave as-is
        has_token = true
        if val ~= "" and val ~= "0" then
            all_empty = false
        end
        -- Wrap with markers if this occurrence has a pixel limit
        if token_limits[token] then
            token_occurrence[token] = (token_occurrence[token] or 0) + 1
            local px = token_limits[token][token_occurrence[token]]
            if px then
                -- \x01 N \x02 value \x03
                return "\x01" .. tostring(px) .. "\x02" .. val .. "\x03"
            end
        end
        return val
    end)

    -- Handle (s) pluralisation: "1 highlight(s)" -> "1 highlight", "3 highlight(s)" -> "3 highlights"
    result = result:gsub("(%d+)(%D-)%(s%)", function(num, between)
        return num == "1" and num .. between or num .. between .. "s"
    end)

    -- A line with a bar token is never considered empty
    local is_empty = has_token and all_empty and not bar_info
    return result, is_empty, bar_info
end

function Tokens.expandPreview(format_str, ui, session_elapsed, session_pages_read)
    return Tokens.expand(format_str, ui, session_elapsed, session_pages_read, true)
end

return Tokens
