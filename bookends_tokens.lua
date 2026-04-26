local Device = require("device")
local datetime = require("datetime")
local BAR_PLACEHOLDER = require("bookends_overlay_widget").BAR_PLACEHOLDER

local Tokens = {}

-- Set by main.lua from the bookends settings file. When true, %L and %l
-- include the current page in their count (e.g. 'n→1' instead of 'n−1→0').
-- Default false matches stock KOReader's default behaviour.
Tokens.pages_left_includes_current = false

-- Legacy token → new-name alias map. See
-- docs/superpowers/specs/2026-04-23-v5-token-system-design.md for full rationale.
-- Single-letter keys only; %C1/%C2/%C3 handled via pattern in rewriteLegacyTokens.
local TOKEN_ALIAS = {
    A = "author", T = "title", S = "series", C = "chap_title",
    J = "chap_count", j = "chap_num",
    p = "book_pct", P = "chap_pct",
    c = "page_num", t = "page_count", L = "pages_left", l = "chap_pages_left",
    g = "chap_read", G = "chap_pages",
    k = "time_12h", K = "time_24h",
    d = "date", D = "date_long", n = "date_numeric",
    w = "weekday", a = "weekday_short",
    R = "session_time", s = "session_pages",
    r = "speed", E = "book_read_time",
    h = "chap_time_left", H = "book_time_left",
    b = "batt", B = "batt_icon",
    W = "wifi", V = "invert",
    f = "light", F = "warmth",
    m = "mem", M = "ram", v = "disk",
    N = "filename", i = "lang", o = "format",
    q = "highlights", Q = "notes", x = "bookmarks", X = "annotations",
}

--- Rewrite legacy single-letter tokens (%A, %J, %C1, ...) to their v5 names.
-- Walks the string left-to-right, rewriting bare %ident occurrences via
-- TOKEN_ALIAS while leaving %ident{...} brace content verbatim — brace bodies
-- may contain literal %-escapes (e.g. %datetime{%H:%M}) that must NOT be
-- interpreted as bookends tokens. Idempotent: applying twice gives the same
-- result. %C1/%C2/%C3 is rewritten to %chap_title_<N> via the C(%d) check.
local function rewriteLegacyTokens(format_str)
    local out = {}
    local i, len = 1, #format_str
    while i <= len do
        local pct_s = format_str:find("%", i, true)
        if not pct_s then
            table.insert(out, format_str:sub(i))
            break
        end
        if pct_s > i then
            table.insert(out, format_str:sub(i, pct_s - 1))
        end
        -- Try to match an identifier after the %.
        local ident_s = pct_s + 1
        local ident_e = ident_s
        local c = format_str:sub(ident_s, ident_s)
        if c:match("[%a_]") then
            -- Consume maximal [%a_][%w_]* identifier.
            ident_e = ident_s
            while ident_e <= len and format_str:sub(ident_e, ident_e):match("[%w_]") do
                ident_e = ident_e + 1
            end
            local ident = format_str:sub(ident_s, ident_e - 1)
            -- Determine rewritten identifier, or keep as-is.
            local new_ident
            if #ident == 1 and TOKEN_ALIAS[ident] then
                new_ident = TOKEN_ALIAS[ident]
            else
                local depth = ident:match("^C(%d)$")
                if depth then
                    new_ident = "chap_title_" .. depth
                else
                    new_ident = ident
                end
            end
            -- Look for a following {...} block; if present, preserve its
            -- content verbatim (no scanning for legacy tokens inside braces).
            local brace = ""
            if ident_e <= len and format_str:sub(ident_e, ident_e) == "{" then
                -- Find matching '}' (braces are not nested in our grammar).
                local close = format_str:find("}", ident_e + 1, true)
                if close then
                    brace = format_str:sub(ident_e, close)
                    ident_e = close + 1
                end
            end
            table.insert(out, "%" .. new_ident .. brace)
            i = ident_e
        else
            -- % not followed by an identifier char (e.g. %%, %[space], end of
            -- string). Emit the % literally and advance one char.
            table.insert(out, "%")
            i = pct_s + 1
        end
    end
    return table.concat(out)
end

-- Legacy conditional-state key → v5 state key. Resolved at lookup time inside
-- evaluateCondition (not as a string rewrite on predicates, so literal string
-- values like [if:title=chapters] keep their value unchanged).
-- Only the legacy names that differ from the new vocabulary need entries;
-- keys already on the new vocabulary (batt, title, author, book_pct, speed,
-- session, session_pages, wifi, connected, charging, light, invert, time,
-- day, page, format, series) are unchanged and not aliased.
local STATE_ALIAS = {
    chapters        = "chap_count",    -- v4.1 name
    chapter         = "chap_num",      -- v4.1 name (chapter number)
    chapter_pct     = "chap_pct",      -- v4.1 name
    chapter_title   = "chap_title",    -- v4.1 name
    chapter_title_1 = "chap_title_1",
    chapter_title_2 = "chap_title_2",
    chapter_title_3 = "chap_title_3",
    percent         = "book_pct",      -- pre-v4.1 gallery compat
    pages           = "session_pages", -- pre-v4.1 gallery compat
}

-- Read pages/duration for the current reading session from KOReader's
-- ReaderStatistics plugin. Returns { pages = N, duration = secs } when the
-- plugin is available and the call succeeds; nil otherwise. The caller
-- falls back to bookends' own session counters.
function Tokens._readStatsBookSession(ui)
    if not ui or not ui.statistics or type(ui.statistics.getCurrentBookStats) ~= "function" then
        return nil
    end
    local ok, dur, pages = pcall(function()
        return ui.statistics:getCurrentBookStats()
    end)
    if not ok then return nil end
    return { duration = tonumber(dur) or 0, pages = tonumber(pages) or 0 }
end

-- Read pages/duration for everything read today across all books from
-- ReaderStatistics. Same nil-on-failure contract as _readStatsBookSession.
function Tokens._readStatsToday(ui)
    if not ui or not ui.statistics or type(ui.statistics.getTodayBookStats) ~= "function" then
        return nil
    end
    local ok, dur, pages = pcall(function()
        return ui.statistics:getTodayBookStats()
    end)
    if not ok then return nil end
    return { duration = tonumber(dur) or 0, pages = tonumber(pages) or 0 }
end

-- Split KOReader's newline-separated authors string into a list. Drops empties
-- because KOReader can yield trailing "\n" or "\n\n" runs from messy metadata.
local function splitAuthors(authors_raw)
    local list = {}
    if not authors_raw or authors_raw == "" then return list end
    for a in (authors_raw .. "\n"):gmatch("([^\n]*)\n") do
        if a ~= "" then table.insert(list, a) end
    end
    return list
end

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
function Tokens.computeTickFractions(doc, toc, tick_width_multiplier, current_pageno)
    if not doc or not toc then return {} end
    local raw_total = doc:getPageCount()
    if not raw_total or raw_total <= 0 then return {} end
    local toc_ticks = toc:getTocTicks() or {}
    local max_depth = toc:getMaxDepth() or 1
    local tick_m = tick_width_multiplier or 2
    local ticks = {}

    -- When KOReader's "Custom flows" feature is in use, the bar fill
    -- percentage is computed flow-relative (getPageNumberInFlow over
    -- getTotalPagesInFlow). Ticks have to follow the same convention,
    -- otherwise they get spaced as fractions of the whole document while
    -- the bar represents only the active flow, and chapter boundaries
    -- stop lining up with the fill.
    local has_flows = current_pageno and doc.hasHiddenFlows and doc:hasHiddenFlows()
    local active_flow, active_flow_total
    if has_flows then
        active_flow = doc:getPageFlow(current_pageno) or 0
        active_flow_total = doc:getTotalPagesInFlow(active_flow) or 0
    end

    for depth, pages in ipairs(toc_ticks) do
        local tick_w = math.max(1, (max_depth - depth + 1) * tick_m - 1)
        for _, page in ipairs(pages) do
            if page > 1 then
                local tick_frac
                if has_flows then
                    if doc:getPageFlow(page) == active_flow and active_flow_total > 0 then
                        local page_in_flow = doc:getPageNumberInFlow(page) or page
                        tick_frac = page_in_flow / active_flow_total
                    end
                else
                    tick_frac = page / raw_total
                end
                if tick_frac and tick_frac > 0 and tick_frac < 1 then
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
-- Supports operators =, !=, <, > for comparisons.
-- When the right-hand value starts with @, it is resolved as a state-table
-- key reference (e.g. chapter_title_1=@title compares two state values).
-- Without an operator, checks if the value is truthy (non-nil, non-empty, non-zero, not "off"/"no").
local function evaluateCondition(cond_str, state)
    -- Try operator: key=value, key!=value, key<value, key>value
    -- Key pattern allows underscores ([%w_]+) to support names like book_pct.
    -- Operator pattern matches =, !=, <, >, <=, >=.
    -- Two-char operators are tried first so the longer match wins.
    local key, op, value = cond_str:match("^([%w_]+)(>=)(.+)$")
    if not key then key, op, value = cond_str:match("^([%w_]+)(<=)(.+)$") end
    if not key then key, op, value = cond_str:match("^([%w_]+)(!=)(.+)$") end
    if not key then key, op, value = cond_str:match("^([%w_]+)([=<>])(.+)$") end
    if key and op and value then
        -- Strip surrounding double quotes from the RHS so users can match
        -- multi-word string values (e.g. [if:author="J.R.R. Tolkien"]).
        if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
            value = value:sub(2, -2)
        end
        -- Try the key as-is first; fall back to aliased key if not found.
        -- This allows both old and new state-key names to work simultaneously.
        local state_val = state[key]
        if state_val == nil then
            -- Fall back to aliased key for legacy state-key names (chapters,
            -- chapter_pct, etc.).
            local aliased_key = STATE_ALIAS[key]
            if aliased_key then
                state_val = state[aliased_key]
            end
        end
        if state_val == nil then
            -- Missing key: != returns true (nil isn't equal to anything),
            -- other operators return false.
            return op == "!="
        end
        -- Resolve @ref on the right-hand side: look up value from state table,
        -- applying the same alias fallback so @chapters works alongside @chap_count.
        if value:sub(1, 1) == "@" then
            local ref_key = value:sub(2)
            local ref_val = state[ref_key]
            if ref_val == nil then
                local aliased_ref = STATE_ALIAS[ref_key]
                if aliased_ref then ref_val = state[aliased_ref] end
            end
            value = ref_val or ""
        end
        -- Try numeric comparison (supports HH:MM → minutes)
        local num_state = tonumber(state_val)
        local num_val = parseNumericValue(tostring(value))
        if op == "=" then
            if num_state and num_val then return num_state == num_val end
            return tostring(state_val) == tostring(value)
        end
        if op == "!=" then
            if num_state and num_val then return num_state ~= num_val end
            return tostring(state_val) ~= tostring(value)
        end
        if not num_state or not num_val then return false end
        if op == "<"  then return num_state <  num_val end
        if op == ">"  then return num_state >  num_val end
        if op == "<=" then return num_state <= num_val end
        if op == ">=" then return num_state >= num_val end
        return false
    end
    -- No operator: truthy check
    local key_only = cond_str:match("^([%w_]+)$")
    if key_only then
        -- Try the key as-is first; fall back to aliased key if not found.
        local v = state[key_only]
        if v == nil then
            local aliased_key = STATE_ALIAS[key_only]
            if aliased_key then
                v = state[aliased_key]
            end
        end
        return v ~= nil and v ~= "" and v ~= false and v ~= 0 and v ~= "off" and v ~= "no"
    end
    return false
end

--- Tokenise a conditional-expression string into keyword / paren / atom tokens.
-- Whitespace separates tokens. "(" and ")" are always single tokens.
-- The words "and", "or", "not" (lowercase, exact match) are keywords.
-- Double-quoted runs ("...") are kept inside the current atom so RHS values
-- can contain spaces (e.g. author="J.R.R. Tolkien").
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
            local in_quote = false
            while j <= len do
                local cj = cond_str:sub(j, j)
                if cj == '"' then
                    in_quote = not in_quote
                elseif not in_quote and (cj == " " or cj == "\t" or cj == "(" or cj == ")") then
                    break
                end
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
        if Device:hasNaturalLight() and powerd.frontlightWarmth then
            state.warmth = powerd:toNativeWarmth(powerd:frontlightWarmth())
        end
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
        -- Page number / count / remaining — exposed as conditional state so
        -- users can write [if:page_num=page_count]last page![/if] or compare
        -- via @-ref (e.g. [if:page_num!=@page_count]). Mirrors the tokens of
        -- the same name that render in overlay output. Uses flow-aware totals
        -- when available so hidden-flow books report the reading sequence.
        local page_count_val
        if doc:hasHiddenFlows() then
            local flow = doc:getPageFlow(pageno)
            local flow_page = doc:getPageNumberInFlow(pageno)
            local flow_total = doc:getTotalPagesInFlow(flow)
            if flow_total and flow_total > 0 then
                state.book_pct = math.floor(flow_page / flow_total * 100 + 0.5)
                state.page_num = flow_page
                state.page_count = flow_total
                page_count_val = flow_total
            end
        else
            local raw_total = doc:getPageCount()
            if raw_total and raw_total > 0 then
                state.book_pct = math.floor(pageno / raw_total * 100 + 0.5)
                state.page_num = pageno
                state.page_count = raw_total
                page_count_val = raw_total
            end
        end
        if state.book_pct ~= nil then
            state.book_pct_left = math.max(0, math.min(100, 100 - state.book_pct))
        end
        if page_count_val and state.page_num then
            local left = page_count_val - state.page_num
            if Tokens.pages_left_includes_current then left = left + 1 end
            state.pages_left = math.max(0, left)
            -- Time-left in book, in minutes (numeric so [if:book_time_left>30] works).
            if ui.statistics and ui.statistics.avg_time and ui.statistics.avg_time > 0 then
                state.book_time_left = math.floor(state.pages_left * ui.statistics.avg_time / 60)
            end
        end

        -- Chapter percent + chapter page counts (read / total / left)
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
                    state.chap_pct = math.floor((pageno - chapter_start) / (total - 1) * 100)
                elseif total > 0 then
                    state.chap_pct = 100
                end
            end
            -- chap_pct fallback to book_pct when no chapter info (mirrors token-side
            -- fallback and stock's getChapterProgress get_percentage path).
            if state.chap_pct == nil and state.book_pct ~= nil then
                state.chap_pct = state.book_pct
            end
            if state.chap_pct ~= nil then
                state.chap_pct_left = math.max(0, math.min(100, 100 - state.chap_pct))
            end
            local pages_left_offset = Tokens.pages_left_includes_current and 1 or 0
            local done = ui.toc:getChapterPagesDone(pageno)
            local total = ui.toc:getChapterPageCount(pageno)
            if done and total and total > 0 then
                state.chap_read = math.max(0, done + 1)
                state.chap_pages = total
            elseif state.page_num and state.page_count then
                -- Fallback: treat whole book as one chapter (matches stock readerfooter)
                state.chap_read  = state.page_num
                state.chap_pages = state.page_count
            end
            local left = ui.toc:getChapterPagesLeft(pageno)
            if left then
                state.chap_pages_left = math.max(0, left + pages_left_offset)
            elseif state.pages_left then
                state.chap_pages_left = state.pages_left
            end
            -- Time-left in chapter, in minutes (for [if:chap_time_left>15]
            -- and bareword "is data available?" tests). Uses statistics
            -- avg_time directly to keep this a pure numeric, vs the token
            -- form which renders a formatted duration string. Falls back to
            -- whole-book time-left when chapter pages-left isn't available.
            if state.chap_pages_left and ui.statistics and ui.statistics.avg_time
                and ui.statistics.avg_time > 0 then
                state.chap_time_left = math.floor(state.chap_pages_left * ui.statistics.avg_time / 60)
            end
        end

        -- Chapter number / total count — match %chap_num / %chap_count tokens.
        -- Always assign (including 0) so [if:chap_count=0] works for chapterless
        -- books and [if:chap_count] reads as the natural "has chapters?" test
        -- (the truthy check excludes 0).
        local titles = Tokens.getChapterTitlesByDepth(ui, pageno)
        state.chap_num   = titles.chapter_num
        state.chap_count = titles.chapter_count

        -- Odd/even page
        state.page = (pageno % 2 == 1) and "odd" or "even"
    end

    -- Document format and filename (extension stripped, matches %filename token)
    local doc = ui.document
    if doc and doc.file then
        state.format = (doc.file:match("%.([^.]+)$") or ""):upper()
        local name = doc.file:match("([^/]+)$") or ""
        state.filename = (name:gsub("%.[^.]+$", ""))
    end

    -- Book metadata (mirrors %T / %A / %S derivation in Tokens.expand)
    if doc then
        local doc_props = ui.doc_props or {}
        local ok, props = pcall(doc.getProps, doc)
        if not ok then props = {} end
        state.title  = doc_props.display_title or props.title   or ""
        local authors_raw = doc_props.authors  or props.authors or ""
        local authors_list = splitAuthors(authors_raw)
        state.author   = authors_list[1] or ""
        state.author_1 = authors_list[1] or ""
        state.author_2 = authors_list[2] or ""
        state.author_3 = authors_list[3] or ""
        state.author_4 = authors_list[4] or ""
        state.author_5 = authors_list[5] or ""
        state.authors  = #authors_list
        local series_name = doc_props.series        or props.series  or ""
        local series_index = doc_props.series_index or props.series_index
        state.series_name = series_name
        state.series_num  = series_index and tostring(series_index) or ""
        local series = series_name
        if series ~= "" and series_index then
            series = series .. " #" .. series_index
        end
        state.series = series
        state.lang = doc_props.language or props.language or ""
    end

    -- Chapter titles (reuses the helper already called for state.chap_num/chap_count)
    if pageno and ui.toc then
        local titles = Tokens.getChapterTitlesByDepth(ui, pageno)
        state.chap_title   = titles.chapter_title or ""
        state.chap_title_1 = titles.chapter_titles_by_depth[1] or ""
        state.chap_title_2 = titles.chapter_titles_by_depth[2] or ""
        state.chap_title_3 = titles.chapter_titles_by_depth[3] or ""
    end

    -- Time (minutes since midnight, compare with HH:MM or raw minutes)
    local now = os.date("*t")
    state.time = now.hour * 60 + now.min

    -- Day of week (locale-independent)
    local weekdays = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
    state.day = weekdays[now.wday]

    -- Session (prefer ReaderStatistics' skip-aware values; fall back to
    -- our wall-clock measurement and max-page counter when stats is disabled).
    do
        local stats_session = Tokens._readStatsBookSession(ui)
        if stats_session then
            state.session = math.floor(stats_session.duration / 60)
            state.session_pages = math.max(0, stats_session.pages)
        else
            state.session = session_elapsed and math.floor(session_elapsed / 60) or 0
            state.session_pages = math.max(0, session_pages_read or 0)
        end
        state.session_time = state.session
    end

    -- Today's reading totals (across all books) from ReaderStatistics.
    -- pages_today is an integer; time_today is integer minutes (raw seconds
    -- get formatted at render time).
    do
        local stats_today = Tokens._readStatsToday(ui)
        if stats_today then
            state.pages_today = math.max(0, stats_today.pages)
            state.time_today = math.floor(stats_today.duration / 60)
        else
            state.pages_today = 0
            state.time_today = 0
        end
    end

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

    -- Total book reading time (minutes), from statistics plugin
    if ui.statistics and ui.statistics.book_read_time and ui.statistics.book_read_time > 0 then
        state.book_read_time = math.floor(ui.statistics.book_read_time / 60)
    end

    -- Annotation counts
    if ui.annotation then
        local h, n = ui.annotation:getNumberOfHighlightsAndNotes()
        state.highlights = h or 0
        state.notes = n or 0
        local bm = 0
        for _, item in ipairs(ui.annotation.annotations or {}) do
            if not item.drawer then bm = bm + 1 end
        end
        state.bookmarks = bm
    end

    if paint_ctx then
        paint_ctx._condition_state = state
    end
    return state
end

--- Rewrite legacy predicate-key names inside [if:...] openers.
-- Walks each opener's predicate via tokeniseExpression, rewrites the KEY
-- portion of each atom (the leading [%w_]+ run before any operator), leaves
-- literal values untouched but rewrites any @ref RHS via the same alias map.
-- Handles =, !=, <, >, <=, >= operators; Boolean operators (and/or/not/parens)
-- pass through unchanged.
local function rewriteConditionalKeys(s)
    return (s:gsub("%[if:([^%]]-)%]", function(pred)
        local toks = tokeniseExpression(pred)
        local out = {}
        for _i, tok in ipairs(toks) do
            if tok.kind == "atom" then
                -- atom = "key", "key=value", "key!=value", "key<value",
                -- "key>value", "key<=value", "key>=value". Try two-char
                -- operators first so the longer match wins.
                local key, op, rest = tok.value:match("^([%w_]+)(>=)(.*)$")
                if not key then key, op, rest = tok.value:match("^([%w_]+)(<=)(.*)$") end
                if not key then key, op, rest = tok.value:match("^([%w_]+)(!=)(.*)$") end
                if not key then key, op, rest = tok.value:match("^([%w_]+)([=<>])(.*)$") end
                if key and op then
                    -- Rewrite @key references on the RHS too.
                    if rest:sub(1, 1) == "@" then
                        local ref_key = rest:sub(2)
                        local new_ref = STATE_ALIAS[ref_key] or ref_key
                        rest = "@" .. new_ref
                    end
                    local new_key = STATE_ALIAS[key] or key
                    table.insert(out, new_key .. op .. rest)
                else
                    -- No operator: bare key
                    local bare = tok.value:match("^([%w_]+)$")
                    if bare then
                        table.insert(out, STATE_ALIAS[bare] or bare)
                    else
                        table.insert(out, tok.value)
                    end
                end
            else
                -- keyword / paren: emit verbatim
                table.insert(out, tok.value)
            end
        end
        return "[if:" .. table.concat(out, " ") .. "]"
    end))
end

--- Canonicalise a stored format string: legacy tokens → v5 names, legacy
-- predicate state keys → v5 keys. Pure and idempotent. Used by the line
-- editor on open, so users see their stored preset in v5 vocabulary.
function Tokens.canonicaliseLegacy(format_str)
    local s = rewriteLegacyTokens(format_str)
    s = rewriteConditionalKeys(s)
    return s
end

--- Walk the footer's additional_footer_content list and join non-empty
-- callback returns with the footer's own separator. If `filter` is set,
-- only callbacks whose source file lives under `<filter>.koplugin/`
-- contribute. Owner is identified via debug.getinfo on the closure's
-- source path — KOReader plugins all live in `<name>.koplugin/`, so the
-- directory basename is a stable public identifier.
local function gatherPluginContent(ui, filter)
    local footer = ui and ui.view and ui.view.footer
    local funcs = footer and footer.additional_footer_content
    if not funcs or #funcs == 0 then return "" end
    local parts = {}
    for _, fn in ipairs(funcs) do
        local include = true
        if filter and filter ~= "" then
            local info = debug.getinfo(fn, "S")
            local source = info and info.source or ""
            local owner = source:match("/([^/]+)%.koplugin/")
            include = (owner == filter)
        end
        if include then
            local val = fn()
            if val and val ~= "" then
                parts[#parts + 1] = val
            end
        end
    end
    if #parts == 0 then return "" end
    return table.concat(parts, footer:genSeparator())
end

function Tokens.expand(format_str, ui, session_elapsed, session_pages_read, preview_mode, tick_width_multiplier, symbol_color, paint_ctx, opts)
    opts = opts or {}
    -- Fast path: no tokens or conditionals
    if not format_str:find("%%") and not format_str:find("%[if:") then
        return format_str
    end

    -- v5 alias pass: rewrite legacy %X tokens to v5 names so all downstream
    -- processing uses a single vocabulary. Gallery presets and user-authored
    -- legacy strings render identically. opts.legacy_literal skips this pass
    -- for the line-editor live preview.
    if not opts.legacy_literal then
        format_str = rewriteLegacyTokens(format_str)
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

    -- Pre-parse %name{content} modifiers.
    -- Single outer pattern captures every %<ident>{<content>} occurrence; each
    -- token decides what its brace content means. Strips the braces from the
    -- format string (storing extracted data in per-token sidecar tables) so
    -- the later bareword expansion step is unchanged.
    --   %bar                auto width, default height
    --   %bar{100}           100px wide, default height
    --   %bar{v10}           auto width, 10px tall
    --   %bar{100v10}        100px wide, 10px tall
    --   %<text-token>{N}    pixel-width cap
    local token_limits = {}  -- { ["%author"] = { [1] = 200 }, ... }
    local bar_limit_w = nil
    local bar_limit_h = nil
    -- Per-occurrence filter list for %plugin_content{<plugin>}. Each braced
    -- occurrence rewrites to a synthetic ident (%__pcfilterN) so multiple
    -- filters in one format string each get their own resolved value, and
    -- the existing bareword auto-hide path applies unchanged.
    local plugin_content_filters = {}

    format_str = format_str:gsub("%%([%a_][%w_]*)(%b{})", function(name, brace)
        local content = brace:sub(2, -2)  -- strip { and }
        if name == "bar" then
            local w = content:match("^(%d+)")
            local h = content:match("v(%d+)")
            if w then
                local px = tonumber(w)
                if px and px > 0 then bar_limit_w = px end
            end
            if h then
                local px = tonumber(h)
                if px and px > 0 then bar_limit_h = px end
            end
            return "%bar"
        end
        if name == "plugin_content" then
            -- Stash filter, rewrite to synthetic ident so the bareword
            -- expander handles it (auto-hide via the standard path).
            plugin_content_filters[#plugin_content_filters + 1] = content
            return "%__pcfilter" .. #plugin_content_filters
        end
        if name == "datetime" then
            -- Strftime escape hatch. Respect device locale (see getDateLocale).
            local loc = getDateLocale()
            local saved_locale
            if loc then
                saved_locale = os.setlocale(nil, "time")
                os.setlocale(loc, "time")
            end
            local formatted = os.date(content) or ""
            if saved_locale then os.setlocale(saved_locale, "time") end
            return formatted
        end
        -- Default: pixel-width cap (digits only).
        local n = content:match("^(%d+)$")
        if n then
            local px = tonumber(n)
            if px and px > 0 then
                local key = "%" .. name
                if not token_limits[key] then token_limits[key] = {} end
                table.insert(token_limits[key], px)
            end
            return "%" .. name
        end
        -- Non-digit content on a token without a registered handler:
        -- leave intact as literal (matches today's behaviour for %A{foo}).
        return nil
    end)

    -- Preview mode: return descriptive labels
    if preview_mode then
        local preview = {
            page_num = "[page]", page_count = "[total]",
            book_pct = "[%]", book_pct_left = "[%left]",
            chap_pct = "[ch%]", chap_pct_left = "[ch%left]",
            chap_read = "[ch.read]", chap_pages = "[ch.total]",
            chap_pages_left = "[ch.left]", pages_left = "[left]",
            chap_num = "[ch.num]", chap_count = "[ch.count]",
            chap_time_left = "[ch.time]", book_time_left = "[time]",
            time_12h = "[12h]", time_24h = "[24h]", time = "[24h]",
            date = "[date]", date_long = "[date.long]",
            date_numeric = "[dd/mm/yy]",
            weekday = "[weekday]", weekday_short = "[wkday]",
            session_time = "[session]", session_pages = "[pages]",
            title = "[title]", author = "[author]",
            series = "[series]", series_name = "[series.name]", series_num = "[series.#]",
            chap_title = "[chapter]",
            filename = "[file]", lang = "[lang]",
            format = "[format]",
            highlights = "[highlights]", notes = "[notes]",
            bookmarks = "[bookmarks]", annotations = "[annotations]",
            speed = "[pg/hr]", book_read_time = "[total]",
            batt = "[batt]", batt_icon = "[batt]", wifi = "[wifi]",
            plugin_content = "[plugins]",
            invert = "[invert]",
            light = "[light]", warmth = "[warmth]",
            mem = "[mem]", ram = "[rss]",
            disk = "[disk]",
            bar = "\xE2\x96\xB0\xE2\x96\xB0\xE2\x96\xB1\xE2\x96\xB1",  -- ▰▰▱▱
        }
        -- Strip %bar{N} and %X{N} for preview, showing limit in label
        -- %bar{N} must be replaced before %bar (longer pattern first)
        local r = orig_format_str:gsub("%%bar{(%d+)}", function(n)
            return preview.bar .. "{<=" .. n .. "}"
        end)
        r = r:gsub("%%bar", preview.bar)
        -- Handle %datetime{...} — in preview mode, actually expand it (not a placeholder)
        r = r:gsub("%%datetime(%b{})", function(brace)
            local content = brace:sub(2, -2)
            local loc = getDateLocale()
            local saved_locale
            if loc then
                saved_locale = os.setlocale(nil, "time")
                os.setlocale(loc, "time")
            end
            local formatted = os.date(content) or ""
            if saved_locale then os.setlocale(saved_locale, "time") end
            return formatted
        end)
        -- %plugin_content{<plugin>} preview label, before generic {N}
        r = r:gsub("%%plugin_content(%b{})", function(brace)
            local filter = brace:sub(2, -2)
            return "[plugins:" .. filter .. "]"
        end)
        -- Depth-specific chapter-title before bareword tokens
        r = r:gsub("%%chap_title_(%d){(%d+)}", function(depth, n)
            return "{ch." .. depth .. "<=" .. n .. "}"
        end)
        r = r:gsub("%%chap_title_(%d)", function(depth)
            return "[ch." .. depth .. "]"
        end)
        -- Legacy %C1/2/3 already rewritten to %chap_title_1/2/3 by the
        -- alias pass at the top of expand().
        r = r:gsub("%%([%a_][%w_]*){(%d+)}", function(token, n)
            local label = preview[token]
            if label then
                -- Turn [chapter] into {chapter<=200}
                return "{" .. label:sub(2, -2) .. "<=" .. n .. "}"
            end
            return "%" .. token .. "{" .. n .. "}"
        end)
        r = r:gsub("%%([%a_][%w_]*)", function(token)
            local label = preview[token]
            if label then return label end
            return "%" .. token
        end)
        return r
    end

    -- Helper: check if any of the given v5 bareword tokens appear in the format string.
    -- Uses a non-ident trailing char (or end-of-string) as the word boundary so
    -- e.g. "page_num" doesn't accidentally match "page_num_foo".
    local function needs(...)
        for i = 1, select("#", ...) do
            local name = select(i, ...)
            if format_str:find("%%" .. name .. "[^%w_]")
                    or format_str:match("%%" .. name .. "$") then
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
    local percent_left = ""
    local pages_left_book = ""
    local pages_left_offset = Tokens.pages_left_includes_current and 1 or 0
    -- Numeric page indices for arithmetic (separate from display labels)
    local page_idx = nil   -- numeric current page position
    local page_count = nil -- numeric total pages
    if needs("page_num", "page_count", "book_pct", "book_pct_left", "pages_left") then
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

        -- Book percent: flow-aware when hidden flows active, raw pages otherwise.
        -- percent_left is derived from the same integer to keep "X% read" + "Y% left"
        -- summing to exactly 100 at the displayed precision.
        local percent_int
        if pageno and doc:hasHiddenFlows() then
            local flow = doc:getPageFlow(pageno)
            local flow_page = doc:getPageNumberInFlow(pageno)
            local flow_total = doc:getTotalPagesInFlow(flow)
            if flow_total and flow_total > 0 then
                percent_int = math.floor(flow_page / flow_total * 100 + 0.5)
            end
        else
            local raw_total = doc:getPageCount()
            if pageno and raw_total and raw_total > 0 then
                percent_int = math.floor(pageno / raw_total * 100 + 0.5)
            end
        end
        if percent_int then
            percent = percent_int .. "%"
            percent_left = math.max(0, math.min(100, 100 - percent_int)) .. "%"
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
    local chapter_pct_left = ""
    local chapter_pages_done = ""
    local chapter_pages_left = ""
    local chapter_total_pages = ""
    local chapter_title = ""
    local chapter_num = ""      -- 1-indexed position of current chapter in TOC
    local chapter_count = ""    -- total number of entries in TOC
    local chapter_titles_by_depth = {}  -- { [1] = "Part II", [2] = "Chapter 1", ... }
    if needs("chap_pct", "chap_pct_left", "chap_read", "chap_pages", "chap_pages_left", "chap_title", "chap_num", "chap_count") and pageno and ui.toc then
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
                local pct_int
                if raw_total > 1 then
                    pct_int = math.floor(raw_done / (raw_total - 1) * 100)
                else
                    pct_int = 100
                end
                chapter_pct = pct_int .. "%"
                chapter_pct_left = math.max(0, math.min(100, 100 - pct_int)) .. "%"
            end
        end
        -- Stable page counts for %chap_read / %chap_pages / %chap_pages_left.
        -- Match stock readerfooter's "treat whole book as one chapter" fallback
        -- when the TOC API returns nil (chapterless books, last chapter of any
        -- book): %chap_read falls back to current page, %chap_pages to total
        -- pages, %chap_pages_left to whole-book pages-left. See
        -- ReaderFooter:getChapterProgress and the pages_left footer item.
        local done = ui.toc:getChapterPagesDone(pageno)
        local total = ui.toc:getChapterPageCount(pageno)
        if done and total and total > 0 then
            chapter_pages_done = math.max(0, done + 1)
            chapter_total_pages = total
        elseif page_idx and page_count and page_count > 0 then
            chapter_pages_done = page_idx
            chapter_total_pages = page_count
        end
        local left = ui.toc:getChapterPagesLeft(pageno)
        if left then
            chapter_pages_left = math.max(0, left + pages_left_offset)
        elseif pages_left_book ~= "" then
            chapter_pages_left = pages_left_book
        end
        -- chap_pct fallback: when the chapter API didn't yield a value,
        -- use book percent (matches stock's getChapterProgress get_percentage path).
        if chapter_pct == "" and percent ~= "" then
            chapter_pct = percent
            chapter_pct_left = percent_left
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

        -- Chapter tick positions as {fraction, width, depth} — page-based to match KOReader footer.
        -- Pass bar_pageno so flow-aware tick fractions line up with the flow-relative book_pct above.
        local ticks = Tokens.computeTickFractions(bar_doc, ui.toc, tick_width_multiplier, bar_pageno)

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

    -- Session pages read (skip-aware via ReaderStatistics with fallback to
    -- bookends' own max-page counter when stats is disabled or absent).
    local session_pages
    do
        local stats_session = Tokens._readStatsBookSession(ui)
        if stats_session then
            session_pages = math.max(0, stats_session.pages)
        else
            session_pages = math.max(0, session_pages_read or 0)
        end
    end

    -- Time left in chapter / document (via statistics plugin).
    -- chap_time_left falls back to whole-book pages-left when no chapter info,
    -- matching stock readerfooter's chapter_time_to_read fallback.
    local time_left_chapter = ""
    local time_left_doc = ""
    if needs("chap_time_left", "book_time_left") and pageno and ui.statistics and ui.statistics.getTimeForPages then
        if needs("chap_time_left") then
            local ch_left = ui.toc and ui.toc:getChapterPagesLeft(pageno, true)
            if not ch_left then
                ch_left = doc:getTotalPagesLeft(pageno)
            end
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
        if needs("book_time_left") then
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
    if needs("time_12h") then
        time_12h = os.date("%I:%M %p"):gsub("^0", "")
    end
    if needs("time_24h", "time") then
        time_24h = os.date("%H:%M")
    end

    -- Dates
    local date_short = ""
    local date_long = ""
    local date_num = ""
    local date_weekday = ""
    local date_weekday_short = ""
    if needs("date", "date_long", "date_numeric", "weekday", "weekday_short") then
        -- Use device language for day/month names if available
        local loc = getDateLocale()
        local saved_locale
        if loc then
            saved_locale = os.setlocale(nil, "time")
            os.setlocale(loc, "time")
        end
        if needs("date") then date_short = os.date("%d %b") end
        if needs("date_long") then date_long = os.date("%d %B %Y") end
        if needs("date_numeric") then date_num = os.date("%d/%m/%Y") end
        if needs("weekday") then date_weekday = os.date("%A") end
        if needs("weekday_short") then date_weekday_short = os.date("%a") end
        if saved_locale then
            os.setlocale(saved_locale, "time")
        end
    end

    -- Session reading time (skip-aware via ReaderStatistics with fallback
    -- to wall-clock when stats is disabled). Output respects the user's
    -- duration_format preference (Settings → Device → Time and date).
    local session_time = ""
    if needs("session_time") then
        local stats_session = Tokens._readStatsBookSession(ui)
        local secs
        if stats_session then
            secs = stats_session.duration
        elseif session_elapsed then
            secs = session_elapsed
        end
        if secs and secs > 0 then
            local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
            session_time = datetime.secondsToClockDuration(user_duration_format, secs, true)
        end
    end

    -- Today's totals (across all books) from ReaderStatistics. Single
    -- call covers both pages_today and time_today; gate is needs(...)
    -- on either token.
    local pages_today_str = ""
    local time_today_str = ""
    if needs("pages_today", "time_today") then
        local stats_today = Tokens._readStatsToday(ui)
        if stats_today then
            if needs("pages_today") and stats_today.pages > 0 then
                pages_today_str = tostring(math.floor(stats_today.pages))
            end
            if needs("time_today") and stats_today.duration > 0 then
                local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
                time_today_str = datetime.secondsToClockDuration(user_duration_format, stats_today.duration, true)
            end
        end
    end

    -- Document metadata
    local title = ""
    local authors = ""
    local first_author = ""
    local authors_list = {}
    local series = ""
    local series_name = ""
    local series_num = ""
    local book_language = ""
    if needs("title", "author", "authors",
             "author_1", "author_2", "author_3", "author_4", "author_5",
             "series", "series_name", "series_num", "lang") then
        local doc_props = ui.doc_props or {}
        local ok, props = pcall(doc.getProps, doc)
        if not ok then props = {} end
        title = doc_props.display_title or props.title or ""
        local authors_raw = doc_props.authors or props.authors or ""
        authors_list = splitAuthors(authors_raw)
        first_author = authors_list[1] or ""
        authors = table.concat(authors_list, ", ")
        series_name = doc_props.series or props.series or ""
        local series_index = doc_props.series_index or props.series_index
        series_num = series_index and tostring(series_index) or ""
        series = series_name
        if series ~= "" and series_index then
            series = series .. " #" .. series_index
        end
        if needs("lang") then
            book_language = doc_props.language or props.language or ""
        end
    end

    -- File name (without path and extension)
    local file_name = ""
    local doc_format = ""
    if needs("filename", "format") then
        local filepath = doc.file or ""
        if needs("filename") then
            file_name = filepath:match("([^/]+)$") or ""
            file_name = (file_name:gsub("%.[^.]+$", ""))
        end
        if needs("format") then
            doc_format = (filepath:match("%.([^.]+)$") or ""):upper()
        end
    end

    -- Highlights and notes count
    local highlights_count = ""
    local notes_count = ""
    local bookmarks_count = ""
    if needs("highlights", "notes", "bookmarks") and ui.annotation then
        local h, n = ui.annotation:getNumberOfHighlightsAndNotes()
        if needs("highlights") then highlights_count = tostring(h or 0) end
        if needs("notes") then notes_count = tostring(n or 0) end
        if needs("bookmarks") then
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
    if needs("speed", "book_read_time") then
        if needs("speed") then
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
        if needs("book_read_time") and ui.statistics then
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
    if needs("batt", "batt_icon") then
        local powerd = Device:getPowerDevice()
        local capacity = powerd:getCapacity()
        if capacity then
            batt_symbol = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), capacity) or ""
            batt_lvl = capacity .. "%"
        end
    end

    -- Wi-Fi: always renders. The bundled symbol font ships only two wifi
    -- glyphs (U+ECA8 wifi, U+ECA9 wifi-off), so "off" and "enabled-but-no-link"
    -- share the wifi-off glyph — both communicate "no working connection".
    -- Use [if:wifi=on]%wifi[/if] to hide on disabled, or [if:connected=yes] for
    -- connected-only.
    local wifi_symbol = ""
    if needs("wifi") then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then
            wifi_symbol = "\xEE\xB2\xA8" -- U+ECA8 wifi connected
        else
            wifi_symbol = "\xEE\xB2\xA9" -- U+ECA9 wifi-off (off or no link)
        end
    end

    -- Aggregate output from plugins that register with KOReader's footer
    -- extension API (ReaderFooter:addAdditionalFooterContent at
    -- readerfooter.lua:2076). Examples: kobo.koplugin (Bluetooth icon),
    -- readtimer.koplugin (countdown). Bare %plugin_content joins all
    -- registered callbacks; %plugin_content{<plugin>} restricts to one
    -- plugin's contribution (filter pre-stashed by the brace handler).
    local plugin_content = ""
    if needs("plugin_content") then
        plugin_content = gatherPluginContent(ui, nil)
    end

    -- Frontlight
    local fl_intensity = ""
    local fl_warmth = ""
    if needs("light", "warmth") then
        local powerd = Device:getPowerDevice()
        if needs("light") then
            local val = powerd:frontlightIntensity()
            fl_intensity = val == 0 and "OFF" or tostring(val)
        end
        if needs("warmth") and Device:hasNaturalLight() then
            fl_warmth = tostring(powerd:toNativeWarmth(powerd:frontlightWarmth()))
        end
    end

    -- Memory usage (system-wide percentage)
    local mem_usage = ""
    if needs("mem") then
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
    if needs("ram") then
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
    if needs("disk") then
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
    if needs("invert") then
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
    if needs("annotations") then
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
        page_num   = tostring(currentpage),
        page_count = tostring(totalpages),
        book_pct   = tostring(percent),
        book_pct_left = tostring(percent_left),
        chap_pct   = tostring(chapter_pct),
        chap_pct_left = tostring(chapter_pct_left),
        chap_read  = tostring(chapter_pages_done),
        chap_pages = tostring(chapter_total_pages),
        chap_pages_left = tostring(chapter_pages_left),
        pages_left = tostring(pages_left_book),
        chap_num   = tostring(chapter_num),
        chap_count = tostring(chapter_count),
        -- Time/Reading
        chap_time_left = tostring(time_left_chapter),
        book_time_left = tostring(time_left_doc),
        time_12h = time_12h,
        time_24h = time_24h,
        time     = time_24h,              -- plain %time = %time_24h
        date          = date_short,
        date_long     = date_long,
        date_numeric  = date_num,
        weekday       = date_weekday,
        weekday_short = date_weekday_short,
        session_time  = session_time,
        session_pages = tostring(session_pages),
        pages_today   = pages_today_str,
        time_today    = time_today_str,
        -- Metadata
        title       = tostring(title),
        author      = first_author,
        authors     = authors,
        author_1    = authors_list[1] or "",
        author_2    = authors_list[2] or "",
        author_3    = authors_list[3] or "",
        author_4    = authors_list[4] or "",
        author_5    = authors_list[5] or "",
        series      = tostring(series),
        series_name = tostring(series_name or ""),   -- populated in Task 10
        series_num  = tostring(series_num or ""),    -- populated in Task 10
        chap_title  = tostring(chapter_title),
        filename    = file_name,
        lang        = book_language,
        format      = doc_format,
        highlights  = highlights_count,
        notes       = notes_count,
        bookmarks   = bookmarks_count,
        annotations = total_annotations,
        -- Statistics
        speed          = reading_speed,
        book_read_time = total_book_time,
        -- Device
        batt      = tostring(batt_lvl),
        batt_icon = tostring(batt_symbol),
        wifi      = wifi_symbol,
        plugin_content = plugin_content,
        light     = fl_intensity,
        warmth    = fl_warmth,
        mem       = tostring(mem_usage),
        ram       = ram_mb,
        disk      = disk_avail,
        invert    = page_turn_symbol,
    }
    -- Populate synthetic %__pcfilterN idents stashed by the brace handler.
    -- Each one resolves to gatherPluginContent for that filter; empty
    -- results auto-hide via the standard bareword path.
    for i = 1, #plugin_content_filters do
        replace["__pcfilter" .. i] = gatherPluginContent(ui, plugin_content_filters[i])
    end
    -- (symbol_color wrapping happens after token expansion — see below)
    -- Track whether all tokens in the string resolved to empty or "0"
    local has_token = false
    local all_empty = true
    -- Tokens that always count as content (page/chapter/time info is meaningful at zero)
    local always_content = {
        page_num = true, page_count = true, book_pct = true, book_pct_left = true, pages_left = true,
        chap_pct = true, chap_pct_left = true, chap_read = true, chap_pages = true, chap_pages_left = true,
        chap_num = true, chap_count = true,
        chap_time_left = true, book_time_left = true, time_12h = true, time_24h = true,
        time = true,
        session_time = true, session_pages = true, speed = true,
    }
    -- Per-token occurrence counters for matching limits
    local token_occurrence = {}
    -- Expand depth-specific chapter tokens (%chap_title_1..3) before bareword
    -- tokens. Legacy %C1/%C2/%C3 are rewritten to %chap_title_1/2/3 by the
    -- alias pass at the top of expand().
    local result = result_str:gsub("%%chap_title_(%d)", function(depth_str)
        local d = tonumber(depth_str)
        has_token = true
        local val = chapter_titles_by_depth[d] or ""
        if val ~= "" then all_empty = false end
        local key = "%chap_title_" .. depth_str
        if token_limits[key] then
            token_occurrence[key] = (token_occurrence[key] or 0) + 1
            local px = token_limits[key][token_occurrence[key]]
            if px then
                return "\x01" .. tostring(px) .. "\x02" .. val .. "\x03"
            end
        end
        return val
    end)
    result = result:gsub("%%([%a_][%w_]*)", function(ident)
        local val = replace[ident]
        if val == nil then return "%" .. ident end  -- unknown, leave as-is
        has_token = true
        if (val ~= "" and val ~= "0") or always_content[ident] then
            all_empty = false
        end
        -- Wrap with markers if this occurrence has a pixel limit.
        -- Apply markers per-line so they don't span newlines (the
        -- renderer splits on \n before processing markers).
        local key = "%" .. ident
        if token_limits[key] then
            token_occurrence[key] = (token_occurrence[key] or 0) + 1
            local px = token_limits[key][token_occurrence[key]]
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
    -- Icon colour for PUA glyphs is applied at parse time by the overlay
    -- widget (see OverlayWidget.parseStyledSegments' emitPua path) — this
    -- function no longer injects [c=…]PUA[/c] wraps, so mid-edit unclosed
    -- user tags can't cause ghost auto-wrap tags to appear in the fallback
    -- plain-text rendering. `symbol_color` is still accepted in the
    -- signature for caller compatibility, but it's now ignored here.
    local _ignored_symbol_color = symbol_color

    -- A line with a bar token is never considered empty
    local is_empty = has_token and all_empty and not bar_info

    return result, is_empty, bar_info
end

function Tokens.expandPreview(format_str, ui, session_elapsed, session_pages_read, tick_width_multiplier, symbol_color, opts)
    return Tokens.expand(format_str, ui, session_elapsed, session_pages_read, true, tick_width_multiplier, symbol_color, nil, opts)
end

-- Test-only internal exports. Underscore prefix marks these as private —
-- they are exposed solely so _test_conditionals.lua can exercise the parser
-- without needing a running KOReader. Not stable API; may change without notice.
Tokens._processConditionals = processConditionals
Tokens._evaluateCondition   = evaluateCondition
Tokens._evaluateExpression  = evaluateExpression
Tokens._rewriteLegacyTokens = rewriteLegacyTokens

return Tokens
