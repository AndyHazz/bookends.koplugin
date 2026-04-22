local Device = require("device")
local datetime = require("datetime")
local BAR_PLACEHOLDER = require("bookends_overlay_widget").BAR_PLACEHOLDER

local Tokens = {}

-- Set by main.lua from the bookends settings file. When true, %L and %l
-- include the current page in their count (e.g. 'n→1' instead of 'n−1→0').
-- Default false matches stock KOReader's default behaviour.
Tokens.pages_left_includes_current = false

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

--- Compute chapter tick fractions as {fraction, width, depth} triples.
function Tokens.computeTickFractions(doc, toc, tick_width_multiplier)
    if not doc or not toc then return {} end
    local raw_total = doc:getPageCount()
    if not raw_total or raw_total <= 0 then return {} end
    local toc_ticks = toc:getTocTicks() or {}
    local max_depth = toc:getMaxDepth() or 1
    local tick_m = tick_width_multiplier or 2
    local ticks = {}
    for depth, pages in ipairs(toc_ticks) do
        local tick_w = math.max(1, (max_depth - depth + 1) * tick_m - 1)
        for _, page in ipairs(pages) do
            if page > 1 then
                local tick_frac = page / raw_total
                if tick_frac > 0 and tick_frac < 1 then
                    table.insert(ticks, { tick_frac, tick_w, depth })
                end
            end
        end
    end
    return ticks
end

--- Walk the TOC once and return a table of chapter-title data derived from it.
-- @param ui     KOReader ReaderUI instance (must have .toc)
-- @param pageno current page number (1-indexed)
-- @return table with keys:
--   chapter_title       — deepest (most-specific) chapter title covering the page
--   chapter_titles_by_depth — { [1]="Part II", [2]="Ch 3", ... }
--   chapter_num         — 1-indexed flat position of the current entry
--   chapter_count       — total TOC entries across all depths
-- Returns an empty-ish table if ui.toc or page data is unavailable.
function Tokens.getChapterTitlesByDepth(ui, pageno)
    local out = {
        chapter_title = "",
        chapter_titles_by_depth = {},
        chapter_num = 0,
        chapter_count = 0,
    }
    if not ui or not ui.toc or not pageno then return out end

    local title = ui.toc:getTocTitleByPage(pageno)
    if title and title ~= "" then out.chapter_title = title end

    local full_toc = ui.toc.toc
    if not full_toc then return out end

    out.chapter_count = #full_toc
    local idx = 0
    for i, entry in ipairs(full_toc) do
        if entry.page and entry.page <= pageno then
            idx = i
        else
            break
        end
    end
    if idx > 0 then out.chapter_num = idx end

    for _, entry in ipairs(full_toc) do
        if entry.page and entry.page <= pageno and entry.depth then
            out.chapter_titles_by_depth[entry.depth] = entry.title or ""
        end
    end
    return out
end

--- Parse a comparison value, handling HH:MM time format as minutes since midnight.
local function parseNumericValue(val)
    local h, m = val:match("^(%d+):(%d+)$")
    if h and m then
        return tonumber(h) * 60 + tonumber(m)
    end
    return tonumber(val)
end

--- Evaluate a single condition string against a state table.
-- Supports operators =, <, > for comparisons.
-- Without an operator, checks if the value is truthy (non-nil, non-empty, non-zero, not "off"/"no").
local function evaluateCondition(cond_str, state)
    -- Try operator: key=value, key<value, key>value
    -- Key pattern allows underscores ([%w_]+) to support names like book_pct.
    local key, op, value = cond_str:match("^([%w_]+)([=<>])(.+)$")
    if key and op and value then
        local state_val = state[key]
        if state_val == nil then return false end
        -- Try numeric comparison (supports HH:MM → minutes)
        local num_state = tonumber(state_val)
        local num_val = parseNumericValue(value)
        if op == "=" then
            if num_state and num_val then return num_state == num_val end
            return tostring(state_val) == value
        end
        if not num_state or not num_val then return false end
        if op == "<" then return num_state < num_val end
        if op == ">" then return num_state > num_val end
        return false
    end
    -- No operator: truthy check
    local key_only = cond_str:match("^([%w_]+)$")
    if key_only then
        local v = state[key_only]
        return v ~= nil and v ~= "" and v ~= false and v ~= 0 and v ~= "off" and v ~= "no"
    end
    return false
end

--- Tokenise a conditional-expression string into keyword / paren / atom tokens.
-- Whitespace separates tokens. "(" and ")" are always single tokens.
-- The words "and", "or", "not" (lowercase, exact match) are keywords.
-- Everything else is an atom, passed verbatim to evaluateCondition.
local function tokeniseExpression(cond_str)
    local tokens = {}
    local i, len = 1, #cond_str
    while i <= len do
        local c = cond_str:sub(i, i)
        if c == " " or c == "\t" then
            i = i + 1
        elseif c == "(" or c == ")" then
            tokens[#tokens + 1] = { kind = "op", value = c }
            i = i + 1
        else
            local j = i
            while j <= len do
                local cj = cond_str:sub(j, j)
                if cj == " " or cj == "\t" or cj == "(" or cj == ")" then break end
                j = j + 1
            end
            local word = cond_str:sub(i, j - 1)
            if word == "and" or word == "or" or word == "not" then
                tokens[#tokens + 1] = { kind = "op", value = word }
            else
                tokens[#tokens + 1] = { kind = "atom", value = word }
            end
            i = j
        end
    end
    return tokens
end

--- Evaluate a conditional expression with operators (and/or/not/parens).
-- Recursive-descent parser. Precedence: not > and > or (standard).
-- A bare atom is delegated to evaluateCondition, preserving all legacy
-- atom semantics (numeric comparison, HH:MM, truthiness).
local function evaluateExpression(cond_str, state)
    local tokens = tokeniseExpression(cond_str)
    local pos = 1
    local function peek() return tokens[pos] end
    local function advance()
        local t = tokens[pos]; pos = pos + 1; return t
    end

    local parseOr  -- forward declaration for mutual recursion

    local function parsePrimary()
        local t = peek()
        if not t then return false end
        if t.kind == "op" and t.value == "(" then
            advance()
            local v = parseOr()
            local cl = peek()
            if cl and cl.kind == "op" and cl.value == ")" then advance() end
            return v
        end
        if t.kind == "atom" then
            advance()
            return evaluateCondition(t.value, state)
        end
        -- Stray "and"/"or"/")"/etc. — skip and continue as false
        advance()
        return false
    end

    local function parseNot()
        local t = peek()
        if t and t.kind == "op" and t.value == "not" then
            advance()
            return not parseNot()
        end
        return parsePrimary()
    end

    local function parseAnd()
        local left = parseNot()
        while true do
            local t = peek()
            if not (t and t.kind == "op" and t.value == "and") then break end
            advance()
            local right = parseNot()
            left = left and right
        end
        return left
    end

    parseOr = function()
        local left = parseAnd()
        while true do
            local t = peek()
            if not (t and t.kind == "op" and t.value == "or") then break end
            advance()
            local right = parseAnd()
            left = left or right
        end
        return left
    end

    return parseOr()
end

--- Process [if:condition]...[/if] blocks, supporting nesting and boolean
-- operators in predicates. Peels the innermost block each iteration:
--   1. Find the first [/if]
--   2. Find the last [if:...] that appears before it
--   3. That pair is the innermost block (no nested [if:] can sit between them)
--   4. Evaluate its predicate, substitute the chosen branch, repeat
-- Unbalanced tags are left in place (no [/if] → break; orphan closer → break).
local function processConditionals(format_str, state)
    local result = format_str
    while true do
        local close_s, close_e = result:find("%[/if%]", 1, false)
        if not close_s then break end

        -- Scan forward for all [if:...] openers that start before close_s,
        -- keeping the last one — that's the innermost opener for this closer.
        local open_s, open_e, cond
        local search_from = 1
        while true do
            local s, e, c = result:find("%[if:([^%]]-)%]", search_from, false)
            if not s or s >= close_s then break end
            open_s, open_e, cond = s, e, c
            search_from = s + 1
        end
        if not open_s then break end  -- orphan [/if], leave string as-is

        local body = result:sub(open_e + 1, close_s - 1)
        local if_part, else_part = body:match("^(.-)%[else%](.*)$")
        if not if_part then
            if_part = body
            else_part = ""
        end
        local chosen = evaluateExpression(cond, state) and if_part or else_part
        result = result:sub(1, open_s - 1) .. chosen .. result:sub(close_e + 1)
    end
    return result
end

--- Build a state table of raw values for conditional evaluation.
--- If paint_ctx is provided and already has a cached state, returns it
--- (shared across all expand() calls within one paint cycle).
function Tokens.buildConditionState(ui, session_elapsed, session_pages_read, paint_ctx)
    if paint_ctx and paint_ctx._condition_state then
        return paint_ctx._condition_state
    end
    local state = {}

    -- WiFi
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then
        state.wifi = NetworkMgr:isWifiOn() and "on" or "off"
        state.connected = (NetworkMgr:isWifiOn() and NetworkMgr:isConnected()) and "yes" or "no"
    end

    -- Battery & charging
    local powerd = Device:getPowerDevice()
    if powerd then
        state.batt = powerd:getCapacity() or 0
        state.charging = (powerd:isCharging() or powerd:isCharged()) and "yes" or "no"
        state.light = powerd:frontlightIntensity() > 0 and "on" or "off"
    end

    -- Page-turn direction (any of: global key inversion flags, per-book reading order)
    local G = G_reader_settings
    local page_turn_inverted =
           G:isTrue("input_invert_page_turn_keys")
        or G:isTrue("input_invert_left_page_turn_keys")
        or G:isTrue("input_invert_right_page_turn_keys")
        or (ui.view and ui.view.inverse_reading_order)
    state.invert = page_turn_inverted and "yes" or "no"

    -- Page-based state
    local pageno = ui.view and ui.view.state and ui.view.state.page
    local doc = ui.document
    if pageno and doc then
        -- Book percent
        if doc:hasHiddenFlows() then
            local flow = doc:getPageFlow(pageno)
            local flow_page = doc:getPageNumberInFlow(pageno)
            local flow_total = doc:getTotalPagesInFlow(flow)
            if flow_total and flow_total > 0 then
                state.book_pct = math.floor(flow_page / flow_total * 100 + 0.5)
            end
        else
            local raw_total = doc:getPageCount()
            if raw_total and raw_total > 0 then
                state.book_pct = math.floor(pageno / raw_total * 100 + 0.5)
            end
        end

        -- Chapter percent
        if ui.toc then
            local chapter_start = ui.toc:getPreviousChapter(pageno)
            if ui.toc:isChapterStart(pageno) then
                chapter_start = pageno
            end
            if chapter_start then
                local next_chapter = ui.toc:getNextChapter(pageno)
                local chapter_end = next_chapter or (doc:getPageCount() + 1)
                local total = chapter_end - chapter_start
                if total > 1 then
                    state.chapter_pct = math.floor((pageno - chapter_start) / (total - 1) * 100)
                elseif total > 0 then
                    state.chapter_pct = 100
                end
            end
        end

        -- Chapter number / total count — same source as %j / %J tokens.
        local titles = Tokens.getChapterTitlesByDepth(ui, pageno)
        if titles.chapter_num  > 0 then state.chapter  = titles.chapter_num  end
        if titles.chapter_count > 0 then state.chapters = titles.chapter_count end

        -- Odd/even page
        state.page = (pageno % 2 == 1) and "odd" or "even"
    end

    -- Document format
    local doc = ui.document
    if doc and doc.file then
        state.format = (doc.file:match("%.([^.]+)$") or ""):upper()
    end

    -- Book metadata (mirrors %T / %A / %S derivation in Tokens.expand)
    if doc then
        local doc_props = ui.doc_props or {}
        local ok, props = pcall(doc.getProps, doc)
        if not ok then props = {} end
        state.title  = doc_props.display_title or props.title   or ""
        state.author = doc_props.authors       or props.authors or ""
        local series = doc_props.series        or props.series  or ""
        local series_index = doc_props.series_index or props.series_index
        if series ~= "" and series_index then
            series = series .. " #" .. series_index
        end
        state.series = series
    end

    -- Chapter titles (reuses the helper already called for state.chapter/chapters)
    if pageno and ui.toc then
        local titles = Tokens.getChapterTitlesByDepth(ui, pageno)
        state.chapter_title   = titles.chapter_title or ""
        state.chapter_title_1 = titles.chapter_titles_by_depth[1] or ""
        state.chapter_title_2 = titles.chapter_titles_by_depth[2] or ""
        state.chapter_title_3 = titles.chapter_titles_by_depth[3] or ""
    end

    -- Time (minutes since midnight, compare with HH:MM or raw minutes)
    local now = os.date("*t")
    state.time = now.hour * 60 + now.min

    -- Day of week (locale-independent)
    local weekdays = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
    state.day = weekdays[now.wday]

    -- Session
    state.session = session_elapsed and math.floor(session_elapsed / 60) or 0
    state.session_pages = math.max(0, session_pages_read or 0)

    -- Reading speed (pages/hr)
    if session_elapsed and session_elapsed > 60 and (session_pages_read or 0) > 0 then
        state.speed = math.floor(session_pages_read / session_elapsed * 3600)
    elseif ui.statistics and ui.statistics.avg_time then
        local avg = ui.statistics.avg_time
        if avg and avg > 0 then
            state.speed = math.floor(3600 / avg)
        end
    end
    state.speed = state.speed or 0

    if paint_ctx then
        paint_ctx._condition_state = state
    end
    return state
end

function Tokens.expand(format_str, ui, session_elapsed, session_pages_read, preview_mode, tick_width_multiplier, symbol_color, paint_ctx)
    -- Fast path: no tokens or conditionals
    if not format_str:find("%%") and not format_str:find("%[if:") then
        return format_str
    end

    -- Process conditionals before token expansion (skip in preview mode).
    -- buildConditionState will reuse paint_ctx._condition_state if present,
    -- so multiple lines with [if:...] in the same paint share one build.
    if not preview_mode and format_str:find("%[if:") then
        local state = Tokens.buildConditionState(ui, session_elapsed, session_pages_read, paint_ctx)
        format_str = processConditionals(format_str, state)
        -- After stripping false branches, check if anything remains to expand
        if not format_str:find("%%") then
            local is_empty = format_str:match("^%s*$") ~= nil
            return format_str, is_empty
        end
    end

    -- Fast path: no tokens
    if not format_str:find("%%") then
        return format_str
    end

    local orig_format_str = format_str

    -- Pre-parse %X{N} pixel-width modifiers.
    -- Builds a table of per-occurrence limits keyed by a running counter per token,
    -- and strips {N} from the format string so existing expansion works unchanged.
    local token_limits = {}  -- { ["%C"] = { [1] = 200 }, ["%T"] = { [1] = 300 } }
    local bar_limit_w = nil  -- pixel width from %bar{N} or %bar{Nv…}
    local bar_limit_h = nil  -- pixel height from %bar{v…}
    -- Bar syntax (always evaluated so it handles non-numeric contents like {v10}):
    --   %bar               auto width, default height
    --   %bar{100}          100px wide, default height
    --   %bar{v10}          auto width, 10px tall
    --   %bar{100v10}       100px wide, 10px tall
    format_str = format_str:gsub("%%bar{([^}]+)}", function(spec)
        local w = spec:match("^(%d+)")
        local h = spec:match("v(%d+)")
        if w then
            local px = tonumber(w)
            if px and px > 0 then bar_limit_w = px end
        end
        if h then
            local px = tonumber(h)
            if px and px > 0 then bar_limit_h = px end
        end
        return "%bar"
    end)
    -- Other tokens still use {N} numeric-only for pixel-width limits.
    if format_str:find("{%d+}") then
        -- Extract %C<depth>{N} (depth-specific chapter title with width limit)
        format_str = format_str:gsub("%%C(%d){(%d+)}", function(depth, n)
            local px = tonumber(n)
            if px and px > 0 then
                local key = "%C" .. depth
                if not token_limits[key] then
                    token_limits[key] = {}
                end
                table.insert(token_limits[key], px)
            end
            return "%C" .. depth
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
            ["%j"] = "[ch.num]", ["%J"] = "[ch.count]",
            ["%h"] = "[ch.time]", ["%H"] = "[time]",
            ["%k"] = "[12h]", ["%K"] = "[24h]",
            ["%d"] = "[date]", ["%D"] = "[date.long]",
            ["%n"] = "[dd/mm/yy]", ["%w"] = "[weekday]", ["%a"] = "[wkday]",
            ["%R"] = "[session]", ["%s"] = "[pages]",
            ["%T"] = "[title]", ["%A"] = "[author]",
            ["%S"] = "[series]", ["%C"] = "[chapter]",
            ["%N"] = "[file]", ["%i"] = "[lang]",
            ["%o"] = "[format]", ["%q"] = "[highlights]", ["%Q"] = "[notes]", ["%x"] = "[bookmarks]",
            ["%X"] = "[annotations]",
            ["%r"] = "[pg/hr]", ["%E"] = "[total]",
            ["%b"] = "[batt]", ["%B"] = "[batt]", ["%W"] = "[wifi]",
            ["%V"] = "[invert]",
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
        -- Handle %C<depth>{N} and %C<depth> before generic patterns
        r = r:gsub("%%C(%d){(%d+)}", function(depth, n)
            return "{ch." .. depth .. "<=" .. n .. "}"
        end)
        r = r:gsub("%%C(%d)", function(depth)
            return "[ch." .. depth .. "]"
        end)
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
    local pages_left_offset = Tokens.pages_left_includes_current and 1 or 0
    -- Numeric page indices for arithmetic (separate from display labels)
    local page_idx = nil   -- numeric current page position
    local page_count = nil -- numeric total pages
    if needs("c", "t", "p", "L") then
        if ui.pagemap and ui.pagemap:wantsPageLabels() then
            local label, idx, count = ui.pagemap:getCurrentPageLabel(true)
            currentpage = label or ""
            page_idx = idx
            page_count = count
            -- Total: show count of mapped pages (not the last label, which may be "279" while count is 247)
            totalpages = count and tostring(count) or ""
        elseif pageno and doc:hasHiddenFlows() then
            currentpage = doc:getPageNumberInFlow(pageno)
            local flow = doc:getPageFlow(pageno)
            totalpages = doc:getTotalPagesInFlow(flow)
            page_idx = tonumber(currentpage)
            page_count = tonumber(totalpages)
        else
            currentpage = pageno or 0
            totalpages = doc:getPageCount()
            page_idx = pageno
            page_count = tonumber(totalpages)
        end

        -- Book percent: flow-aware when hidden flows active, raw pages otherwise
        if pageno and doc:hasHiddenFlows() then
            local flow = doc:getPageFlow(pageno)
            local flow_page = doc:getPageNumberInFlow(pageno)
            local flow_total = doc:getTotalPagesInFlow(flow)
            if flow_total and flow_total > 0 then
                percent = math.floor(flow_page / flow_total * 100 + 0.5) .. "%"
            end
        else
            local raw_total = doc:getPageCount()
            if pageno and raw_total and raw_total > 0 then
                percent = math.floor(pageno / raw_total * 100 + 0.5) .. "%"
            end
        end
        -- Pages left in book: stable page count. Offset controlled by the
        -- Bookends `pages_left_includes_current` setting so users don't need
        -- to rummage through the stock status bar's configuration (which we
        -- recommend disabling).
        if page_idx and page_count and page_count > 0 then
            pages_left_book = math.max(0, page_count - page_idx + pages_left_offset)
        end
    end

    -- Chapter progress: raw pages for %P (per-flip accuracy),
    -- stable pages for %g, %G, %l (display values matching page numbers)
    local chapter_pct = ""
    local chapter_pages_done = ""
    local chapter_pages_left = ""
    local chapter_total_pages = ""
    local chapter_title = ""
    local chapter_num = ""      -- 1-indexed position of current chapter in TOC
    local chapter_count = ""    -- total number of entries in TOC
    local chapter_titles_by_depth = {}  -- { [1] = "Part II", [2] = "Chapter 1", ... }
    if needs("P", "g", "G", "l", "C", "j", "J") and pageno and ui.toc then
        -- Raw page calculation for %P (percentage)
        local chapter_start = ui.toc:getPreviousChapter(pageno)
        if ui.toc:isChapterStart(pageno) then
            chapter_start = pageno
        end
        if chapter_start then
            local next_chapter = ui.toc:getNextChapter(pageno)
            local chapter_end = next_chapter or (doc:getPageCount() + 1)
            local raw_total = chapter_end - chapter_start
            if raw_total > 0 then
                local raw_done = pageno - chapter_start
                if raw_total > 1 then
                    chapter_pct = math.floor(raw_done / (raw_total - 1) * 100) .. "%"
                else
                    chapter_pct = "100%"
                end
            end
        end
        -- Stable page counts for %g (done), %G (total), %l (left)
        local done = ui.toc:getChapterPagesDone(pageno)
        local total = ui.toc:getChapterPageCount(pageno)
        if done and total and total > 0 then
            chapter_pages_done = math.max(0, done + 1)
            chapter_total_pages = total
        end
        local left = ui.toc:getChapterPagesLeft(pageno)
        if left then
            chapter_pages_left = math.max(0, left + pages_left_offset)
        end
        local titles = Tokens.getChapterTitlesByDepth(ui, pageno)
        if titles.chapter_title ~= "" then chapter_title = titles.chapter_title end
        chapter_titles_by_depth = titles.chapter_titles_by_depth
        if titles.chapter_num > 0  then chapter_num   = titles.chapter_num   end
        if titles.chapter_count > 0 then chapter_count = titles.chapter_count end
    end

    -- Bar token data (parallel channel — not embedded in text)
    -- Bar token data: compute both book and chapter, caller picks via per-line setting
    local bar_info = nil
    if has_bar then
        local bar_pageno = pageno or 0
        local bar_doc = doc
        bar_info = {}

        -- Book progress: raw pages (visual position through screen flips)
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
        local ticks = Tokens.computeTickFractions(bar_doc, ui.toc, tick_width_multiplier)

        bar_info.book = { kind = "book", pct = book_pct or 0, ticks = ticks }

        -- Chapter progress: raw page numbers to avoid stable-page rounding
        local ch_pct = 0
        if ui.toc then
            local chapter_start = ui.toc:getPreviousChapter(bar_pageno)
            if ui.toc:isChapterStart(bar_pageno) then
                chapter_start = bar_pageno
            end
            if chapter_start then
                local next_chapter = ui.toc:getNextChapter(bar_pageno)
                local chapter_end = next_chapter or (bar_doc:getPageCount() + 1)
                local total = chapter_end - chapter_start
                if total > 1 then
                    local done = bar_pageno - chapter_start
                    ch_pct = math.max(0, math.min(1, done / (total - 1)))
                elseif total > 0 then
                    ch_pct = 1 -- single-page chapter
                end
            end
        end
        bar_info.chapter = { kind = "chapter", pct = ch_pct, ticks = {} }
        if bar_limit_w then
            bar_info.width = bar_limit_w
        end
        if bar_limit_h then
            bar_info.height = bar_limit_h
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
            if ch_left then
                ch_left = math.max(0, ch_left)
                if ch_left > 0 then
                    local result = ui.statistics:getTimeForPages(ch_left)
                    if result and result ~= "N/A" then time_left_chapter = result end
                else
                    time_left_chapter = "0m"
                end
            end
        end
        if needs("H") then
            -- Use raw page count: getTimeForPages is calibrated against avg_time per raw page
            local doc_left = doc:getTotalPagesLeft(pageno)
            if doc_left and doc_left > 0 then
                local result = ui.statistics:getTimeForPages(doc_left)
                if result and result ~= "N/A" then time_left_doc = result end
            elseif doc_left then
                time_left_doc = "0m"
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
    if needs("r", "E") then
        if needs("r") then
            -- Prefer session-based speed after initial stabilisation period
            if session_elapsed and session_elapsed > 60 and session_pages > 0 then
                reading_speed = tostring(math.floor(session_pages / session_elapsed * 3600))
            elseif ui.statistics then
                local avg = ui.statistics.avg_time
                if avg and avg > 0 then
                    reading_speed = tostring(math.floor(3600 / avg))
                end
            end
        end
        if needs("E") and ui.statistics then
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

    -- Page-turn direction indicator
    -- Shows ⇄ when any page-turn direction is inverted; empty otherwise.
    -- Matches stock readerfooter page_turning_inverted logic (OR of four flags).
    local page_turn_symbol = ""
    if needs("V") then
        local G = G_reader_settings
        local inverted =
               G:isTrue("input_invert_page_turn_keys")
            or G:isTrue("input_invert_left_page_turn_keys")
            or G:isTrue("input_invert_right_page_turn_keys")
            or (ui.view and ui.view.inverse_reading_order)
        if inverted then
            page_turn_symbol = "\xE2\x87\x84" -- U+21C4
        end
    end

    -- Total annotations (bookmarks + highlights + notes, matching stock bookmark_count)
    local total_annotations = ""
    if needs("X") then
        if ui.annotation and ui.annotation.getNumberOfAnnotations then
            total_annotations = tostring(ui.annotation:getNumberOfAnnotations() or 0)
        end
    end

    -- Replace bar tokens with a placeholder so buildBarLine knows where to insert the bar.
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
        ["%j"] = tostring(chapter_num),
        ["%J"] = tostring(chapter_count),
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
        ["%X"] = total_annotations,
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
        ["%V"] = page_turn_symbol,
    }
    -- (symbol_color wrapping happens after token expansion — see below)
    -- Track whether all tokens in the string resolved to empty or "0"
    local has_token = false
    local all_empty = true
    -- Tokens that always count as content (page/chapter/time info is meaningful at zero)
    local always_content = {
        ["%c"] = true, ["%t"] = true, ["%p"] = true, ["%L"] = true,
        ["%P"] = true, ["%g"] = true, ["%G"] = true, ["%l"] = true,
        ["%j"] = true, ["%J"] = true,
        ["%h"] = true, ["%H"] = true, ["%k"] = true, ["%K"] = true,
        ["%R"] = true, ["%s"] = true, ["%r"] = true,
    }
    -- Per-token occurrence counters for matching limits
    local token_occurrence = {}
    -- Expand depth-specific chapter tokens (%C1, %C2, …) before single-char tokens,
    -- so that %C2 isn't partially consumed as %C + literal "2".
    local result = result_str:gsub("%%C(%d)", function(depth_str)
        local d = tonumber(depth_str)
        has_token = true
        local val = chapter_titles_by_depth[d] or ""
        if val ~= "" then all_empty = false end
        local key = "%C" .. depth_str
        if token_limits[key] then
            token_occurrence[key] = (token_occurrence[key] or 0) + 1
            local px = token_limits[key][token_occurrence[key]]
            if px then
                return "\x01" .. tostring(px) .. "\x02" .. val .. "\x03"
            end
        end
        return val
    end)
    result = result:gsub("(%%%a)", function(token)
        local val = replace[token]
        if val == nil then return token end -- unknown token, leave as-is
        has_token = true
        if (val ~= "" and val ~= "0") or always_content[token] then
            all_empty = false
        end
        -- Wrap with markers if this occurrence has a pixel limit.
        -- Apply markers per-line so they don't span newlines (the
        -- renderer splits on \n before processing markers).
        if token_limits[token] then
            token_occurrence[token] = (token_occurrence[token] or 0) + 1
            local px = token_limits[token][token_occurrence[token]]
            if px then
                if val:find("\n") then
                    local wrapped = {}
                    for line in val:gmatch("([^\n]+)") do
                        table.insert(wrapped, "\x01" .. tostring(px) .. "\x02" .. line .. "\x03")
                    end
                    return table.concat(wrapped, "\n")
                end
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

    -- Wrap Private Use Area characters (U+E000-U+F8FF) with symbol colour.
    -- These are icon font glyphs (Nerd Fonts, FontAwesome) — never regular text.
    -- Detection is by UTF-8 byte pattern: 0xEE xx xx = U+E000-U+EFFF,
    -- 0xEF [0x80-0xA3] xx = U+F000-U+F8FF.
    if symbol_color and symbol_color.grey then
        local pct = math.floor((0xFF - symbol_color.grey) * 100 / 0xFF + 0.5)
        local wrap = "[c=" .. pct .. "]%1[/c]"
        result = result:gsub("(\xEE[\x80-\xBF][\x80-\xBF])", wrap)
        result = result:gsub("(\xEF[\x80-\xA3][\x80-\xBF])", wrap)
    end

    -- A line with a bar token is never considered empty
    local is_empty = has_token and all_empty and not bar_info
    return result, is_empty, bar_info
end

function Tokens.expandPreview(format_str, ui, session_elapsed, session_pages_read, tick_width_multiplier, symbol_color)
    return Tokens.expand(format_str, ui, session_elapsed, session_pages_read, true, tick_width_multiplier, symbol_color)
end

-- Test-only internal exports. Underscore prefix marks these as private —
-- they are exposed solely so _test_conditionals.lua can exercise the parser
-- without needing a running KOReader. Not stable API; may change without notice.
Tokens._processConditionals = processConditionals
Tokens._evaluateCondition   = evaluateCondition
Tokens._evaluateExpression  = evaluateExpression

return Tokens
