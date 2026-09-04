local Device = require("device")
local datetime = require("datetime")
local LocalDate = require("bookends_localdate")
local BAR_PLACEHOLDER = require("bookends_overlay_widget").BAR_PLACEHOLDER
local SPACER_PLACEHOLDER = require("bookends_overlay_widget").SPACER_PLACEHOLDER
local Semantics = require("token_semantics")
local CalibreMeta = require("calibre_metadata")
-- gettext, bound to T rather than the conventional `_`: this file uses `_` as
-- a throwaway elsewhere, and one careless rebinding would silently turn every
-- translated string back into its msgid.
--
-- Resolved LAZILY and defensively, because bookends_i18n pulls in KOReader's
-- logger at load: a top-level require here makes this whole module unloadable
-- under a bare `lua`, which is exactly how six of the pure-Lua suites run. The
-- untranslated fallback only ever shows if i18n is genuinely unavailable.
local _gettext
local function T(str)
    if _gettext == nil then
        local ok, i18n = pcall(require, "bookends_i18n")
        _gettext = (ok and i18n and i18n.gettext) or false
    end
    if not _gettext then return str end
    return _gettext(str)
end

local Tokens = {}

-- Set by main.lua from the bookends settings file. When true, %L and %l
-- include the current page in their count (e.g. 'n→1' instead of 'n−1→0').
-- Default false matches stock KOReader's default behaviour.
Tokens.pages_left_includes_current = false

-- Returns the current page number across page-mode and scroll-mode for both
-- CRE and KOPT. In CRE scroll mode, ReaderView:onPosUpdate only updates
-- state.pos, not state.page (see KOReader readerview.lua:onPosUpdate), so
-- reading ui.view.state.page directly gives a stale value. CRE's document
-- object exposes getCurrentPage() which always reflects the current page in
-- either mode; KOPT only fires PageUpdate (so view.state.page stays current)
-- and doesn't expose getCurrentPage, so the fallback covers it.
local function getCurrentPageNumber(ui)
    if ui and ui.document and ui.document.getCurrentPage then
        local ok, p = pcall(function() return ui.document:getCurrentPage() end)
        if ok and p then return p end
    end
    return ui and ui.view and ui.view.state and ui.view.state.page
end
Tokens.getCurrentPageNumber = getCurrentPageNumber

-- Bar-marker anchors (#99/#100) ------------------------------------------------
--
-- A page index only means something for as long as the current pagination
-- holds. In a reflowable (CRE) document the pagination is a product of the
-- render settings, so bumping the font size - or the margins, line spacing,
-- embedded-styles toggle, anything that fires DocumentRerendered - silently
-- repoints a stored page number at different text. Markers anchored that way
-- drift away from where the reader actually was, which is #100, and can end up
-- pointing further into the book than the reader has reached, which is #99.
--
-- KOReader has the same problem with annotations and solves it by treating the
-- xpointer as the anchor and the page as a derived value it recomputes on
-- re-render (readerannotation.lua:updatePageNumbers). Do the same: capture an
-- xpointer next to the page, and resolve back through it every time.
--
-- Paged documents (PDF, CBZ, images) have no xpointer and don't need one -
-- their page indices are intrinsic to the file - so there the anchor is just
-- the page, and any stray xp on such a document is ignored rather than trusted.

--- Capture a re-render-proof anchor for `pageno`.
-- @param ui reader ui (ui.rolling marks a reflowable document)
-- @param pageno number: raw page number to anchor at
-- @return table { page = pageno, xp = xpointer or nil }, or nil without a page
function Tokens.captureMarkerAnchor(ui, pageno)
    if not pageno then return nil end
    local doc = ui and ui.document
    if ui and ui.rolling and doc and doc.getXPointer then
        local ok, xp = pcall(doc.getXPointer, doc)
        if ok and xp and xp ~= "" then
            return { page = pageno, xp = xp }
        end
    end
    return { page = pageno }
end

--- Resolve an anchor back to a raw page number in the CURRENT pagination.
-- Accepts a bare number so pre-#100 call sites and hand-edited settings keep
-- working, and falls back to the stored page whenever the xpointer can't be
-- used (paged document, xpointer no longer in the document, older entry with
-- no xp recorded at all).
-- @param ui reader ui
-- @param anchor table { page, xp } / number / nil
-- @return number or nil
function Tokens.resolveMarkerAnchor(ui, anchor)
    if not anchor then return nil end
    if type(anchor) == "number" then return anchor end
    local doc = ui and ui.document
    if anchor.xp and ui and ui.rolling and doc and doc.getPageFromXPointer then
        local ok, page = pcall(doc.getPageFromXPointer, doc, anchor.xp)
        if ok and type(page) == "number" and page > 0 then return page end
    end
    return anchor.page
end

-- Position within the containing folder (#89) ---------------------------------
--
-- Reading manga as one CBZ per chapter, the page/chapter tokens can only ever
-- describe the chapter you're in - "File 5/10" is the only thing that answers
-- "how far through this folder am I".
--
-- The ordering has to be the file manager's, or the number is meaningless. So
-- rather than reimplement sorting, reuse KOReader's own collate descriptors
-- (BookList.collates, reached through FileChooser): getCollate resolves the
-- user's choice, init_sort_func builds the comparator, and item_func - present
-- only on the collates whose comparison needs more than name/attr, e.g. `type`
-- comparing item.suffix - fills in the extra fields. getSortingFunction is
-- explicitly safe to call on the class rather than a widget instance: it checks
-- `self ~= FileChooser` before touching the instance sort cache.
--
-- Deliberately NOT reused: FileChooser:getListItem, which also resolves
-- opened/bold state and the mandatory column through BookList for every entry.
-- That's hundreds of sidecar lookups in a big manga folder for display data no
-- token needs. Same reason show_file is not used - it applies whatever transient
-- status filter the file manager view happens to have set, which has no business
-- changing a count in the overlay.
--
-- One scan per folder, memoised below; expansion only asks when %file_num or
-- %file_count is actually in the format string, so a preset without them never
-- touches the disk.

local _folder_cache = nil  -- { dir = <path>, files = { <path>, ... } }

--- Drop the memoised folder listing so the next read rescans. Called on
--- document open/close: a folder gains and loses files between books, and
--- nothing else would notice.
--- Calibre custom-column fields for the open document, or nil.
--- A seam rather than a direct call so tests can stub the reader.
--- No settings gate, and no needs() check either: the brace dispatch only
--- calls this when it has actually matched %calibre{...} in the format string,
--- so the token's presence IS the trigger. Cost is proportional to use by
--- construction rather than by a guard someone could forget. Nothing else in bookends
--- consumes calibre data - %title and %author still come from the open
--- document - so the blast radius is one token. See calibre_metadata.lua.
function Tokens._calibreFieldsFor(ui)
    local filepath = ui and ui.document and ui.document.file
    if not filepath then return nil end
    return CalibreMeta.fieldsFor(filepath, true)
end

function Tokens.flushFolderCache()
    _folder_cache = nil
end

local function buildFolderListing(ui, dir)
    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok_fc and ok_lfs and ok_dr) then return nil end

    -- lfs.dir raises on an unreadable directory, exactly as it does for
    -- FileChooser:getPathList - same pcall treatment.
    local ok_iter, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok_iter then return nil end

    local collate = FileChooser:getCollate()
    if not (collate and collate.init_sort_func) then return nil end

    local items = {}
    for f in iter, dir_obj do
        -- Mirror getPathList's exclusions: dotfiles unless the user shows them,
        -- and macOS resource forks always.
        if (FileChooser.show_hidden or f:sub(1, 1) ~= ".") and f:sub(1, 2) ~= "._" then
            local fullpath = dir .. "/" .. f
            local attr = lfs.attributes(fullpath)
            if attr and attr.mode == "file" and DocumentRegistry:hasProvider(fullpath) then
                local item = { text = f, path = fullpath, attr = attr }
                if collate.item_func then collate.item_func(item, ui) end
                items[#items + 1] = item
            end
        end
    end

    local ok_sort = pcall(function()
        table.sort(items, FileChooser:getSortingFunction(
            collate, G_reader_settings:isTrue("reverse_collate")))
    end)
    -- A comparator that errors (bad metadata on one entry, say) would otherwise
    -- take the whole paint down. An unsorted count is still a truthful count.
    local _ok_sort = ok_sort  -- named, so gettext can never be shadowed here

    local files = {}
    for i = 1, #items do files[i] = items[i].path end
    return files
end

--- Position of the open document among the document files in its folder (#89).
-- @param ui reader ui
-- @return number or nil: 1-based position, nil if it isn't in the listing
-- @return number or nil: total document files in the folder
function Tokens.folderPosition(ui)
    local file = ui and ui.document and ui.document.file
    if not file then return nil, nil end
    local dir = file:match("^(.*)/[^/]*$")
    if not dir or dir == "" then return nil, nil end

    if not (_folder_cache and _folder_cache.dir == dir) then
        local files = buildFolderListing(ui, dir)
        if not files then return nil, nil end
        _folder_cache = { dir = dir, files = files }
    end

    local files = _folder_cache.files
    for i = 1, #files do
        if files[i] == file then return i, #files end
    end
    -- Not in the listing (filtered out, or deleted from under us): the folder
    -- total is still meaningful even though the position isn't.
    return nil, #files
end

--- Map a marker page onto a bar's fraction scale (#77), matching how the bar's
--- own fill fraction is computed. Used by full-width bars; inline bars compute
--- the equivalent inline where book_pct/ch_pct are derived.
-- @param doc document
-- @param toc table or nil
-- @param kind "book" or "chapter"
-- @param current_pageno number: the page the bar is currently showing (defines
--   the chapter window for chapter bars)
-- @param marker_page number or nil: the raw page the marker sits at
-- @return number 0..1, or nil when unavailable
function Tokens.markerFracForBar(doc, toc, kind, current_pageno, marker_page)
    if not marker_page or not doc then return nil end
    if kind == "book" then
        local raw_total = doc:getPageCount()
        if not raw_total or raw_total <= 0 then return nil end
        if doc:hasHiddenFlows() then
            local flow = doc:getPageFlow(marker_page)
            local ft = doc:getTotalPagesInFlow(flow)
            local fp = doc:getPageNumberInFlow(marker_page)
            return (ft and ft > 0) and (fp / ft) or nil
        end
        return marker_page / raw_total
    end
    -- chapter scale: marker position within the CURRENTLY shown chapter
    if not toc then return nil end
    local cs = toc:getPreviousChapter(current_pageno)
    if toc:isChapterStart(current_pageno) then cs = current_pageno end
    if not cs then return nil end
    local nc = toc:getNextChapter(current_pageno)
    local ce = nc or (doc:getPageCount() + 1)
    local ctotal = ce - cs
    if ctotal <= 1 then return nil end
    return math.max(0, math.min(1, (marker_page - cs) / (ctotal - 1)))
end

--- Chapter page-range [start, end) containing current_pageno, or nil if
--- there's no chapter info (or the chapter is degenerate, <=1 page). `end`
--- is exclusive — it's the first page of the *next* chapter, or one past
--- the book's last page if there is no next chapter.
--- Shared by markerFracForBar's chapter branch (via duplicated inline math,
--- unchanged) and by the Bookmarks marker's range filter in main.lua, which
--- needs to EXCLUDE out-of-chapter pages rather than clamp them the way a
--- single session/book-open marker legitimately does.
function Tokens.currentChapterRange(toc, doc, current_pageno)
    if not toc then return nil end
    local cs = toc:getPreviousChapter(current_pageno)
    if toc:isChapterStart(current_pageno) then cs = current_pageno end
    if not cs then return nil end
    local nc = toc:getNextChapter(current_pageno)
    local ce = nc or (doc:getPageCount() + 1)
    if ce - cs <= 1 then return nil end
    return cs, ce
end

--- Return the last digit of a numeric value as a string.
-- Used by the %<token>_lastdigit family (#55) to expose the units digit
-- of page/chapter counters for languages whose grammar branches on it
-- (Hungarian vowel harmony for -ból / -ből, etc.).
--
-- Accepts numbers, numeric strings, or labels that end in a digit
-- (e.g. "page 547" -> "7"). Returns "" if the value has no trailing
-- digit (nil, empty string, or non-numeric label like roman numerals).
--
-- A NUMBER is reduced to its integer part first. Leaning on tostring() made
-- the answer depend on the interpreter: LuaJIT (5.1, what KOReader ships)
-- renders 3.0 as "3", while 5.3+ renders "3.0" and this handed back "0" - the
-- digit AFTER the point, which is never the units digit these tokens exist to
-- expose. A fraction was worse on both: 3.7 answered "7".
--
-- "%.0f" rather than "%d": the latter raises on a non-integral float under
-- 5.3+, and this one leaves nan/inf as words with no trailing digit, so they
-- fall through to "" like any other non-numeric label. A STRING is still taken
-- exactly as written, so a pagemap label keeps its own last character.
function Tokens.lastDigit(value)
    if type(value) == "number" then
        value = string.format("%.0f", math.floor(math.abs(value)))
    end
    return tostring(value or ""):match("(%d)$") or ""
end

--- Uppercase file extension of `doc`'s file (e.g. "CBZ" for foo.cbz), or ""
--- if there's no file / no extension. Shared by conditional-token state
--- (state.format) and format-based preset auto-rules (#87).
function Tokens.getFileExtension(doc)
    local file = doc and doc.file
    if not file then return "" end
    return (file:match("%.([^.]+)$") or ""):upper()
end

--- Decide what the format-based preset auto-rule should do (#87). Pure - no
--- I/O; the caller is responsible for pruning rules that point at a
--- since-deleted preset file before calling this.
-- @param ext uppercase file extension (Tokens.getFileExtension), "" if none
-- @param rules table: extension -> "HIDDEN" | preset filename
-- @param current_active string or nil: the currently-active preset filename
-- @param manual_default string or nil: the user's manual default preset filename
-- @return { hidden = bool, apply = string_or_nil }
function Tokens.decideFormatPresetAction(ext, rules, current_active, manual_default)
    local outcome = (ext and ext ~= "") and rules[ext] or nil
    if outcome == "HIDDEN" then
        return { hidden = true, apply = nil }
    end
    local target = outcome or manual_default
    if target and target ~= current_active then
        return { hidden = false, apply = target }
    end
    return { hidden = false, apply = nil }
end

--- Strip the community-convention page-count suffix Calibre users append
-- via custom save templates ("Book Title - P(123)") so the Kindle/Kobo
-- home-screen badge populates without opening every book first.
--
-- Anchored to end-of-title and requires the literal " - P(" + digits + ")"
-- form with whitespace around the dash. This avoids clobbering:
--   * legitimate year-in-parens titles ("Doctor Strange P(2025)") — no dash
--   * mid-string occurrences ("Title - P(123) - Author")
--   * titles starting with P( ("P(123) Title at start")
--   * unrelated bracketed annotations ("Title (Anniversary Edition)")
--
-- The raw filename stays reachable via %filename for anyone who needs the
-- unstripped form. Closes #53.
function Tokens.stripPageCountSuffix(title)
    return (title or ""):gsub("%s+%-%s+P%(%d+%)%s*$", "")
end

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
-- Display words for the four canonical statuses. Deferred calls rather than
-- eager strings so the active locale is read at render time, and a table rather
-- than logic inside token_semantics so that module needs no gettext.
local STATUS_LABELS = {
    unread   = function() return T("Unread")   end,
    reading  = function() return T("Reading")  end,
    on_hold  = function() return T("On hold")  end,
    finished = function() return T("Finished") end,
}

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
--
-- The DB query only sees pages that have been flushed via insertDB, so we
-- add the in-memory mem_read_pages / mem_read_time counters on top —
-- those track skip-aware reads since the last flush. Together they reflect
-- what the user has actually read this session, with no extra disk writes.
function Tokens._readStatsBookSession(ui, cache)
    if cache and cache.session ~= nil then
        if cache.session == false then return nil end
        return cache.session
    end
    if not ui or not ui.statistics or type(ui.statistics.getCurrentBookStats) ~= "function" then
        if cache then cache.session = false end
        return nil
    end
    local ok, dur, pages = pcall(function()
        return ui.statistics:getCurrentBookStats()
    end)
    if not ok then
        if cache then cache.session = false end
        return nil
    end
    local mem_pages = tonumber(ui.statistics.mem_read_pages) or 0
    local mem_time = tonumber(ui.statistics.mem_read_time) or 0
    local result = {
        duration = (tonumber(dur) or 0) + mem_time,
        pages    = (tonumber(pages) or 0) + mem_pages,
    }
    if cache then cache.session = result end
    return result
end

-- Read pages/duration for everything read today across all books from
-- ReaderStatistics. Same nil-on-failure contract as _readStatsBookSession.
--
-- KOReader only flushes its in-memory page-stats to the DB every 50 page
-- turns (MAX_PAGETURNS_BEFORE_FLUSH). To avoid showing stale "today"
-- counts between flushes, we add the current book's in-memory deltas
-- (mem_read_pages / mem_read_time) on top of the DB query result. For
-- single-book reading sessions the math is exact; for multi-book sessions
-- it can slightly over-count if the previous book's deltas haven't flushed
-- — small and bounded, and still better than reporting frozen counts.
function Tokens._readStatsToday(ui, cache)
    if cache and cache.today ~= nil then
        if cache.today == false then return nil end
        return cache.today
    end
    if not ui or not ui.statistics or type(ui.statistics.getTodayBookStats) ~= "function" then
        if cache then cache.today = false end
        return nil
    end
    local ok, dur, pages = pcall(function()
        return ui.statistics:getTodayBookStats()
    end)
    if not ok then
        if cache then cache.today = false end
        return nil
    end
    local mem_pages = tonumber(ui.statistics.mem_read_pages) or 0
    local mem_time = tonumber(ui.statistics.mem_read_time) or 0
    local result = {
        duration = (tonumber(dur) or 0) + mem_time,
        pages    = (tonumber(pages) or 0) + mem_pages,
    }
    if cache then cache.today = result end
    return result
end

-- Count of distinct local calendar dates the current book has been read on.
-- Mirrors the SQL KOReader's stats plugin uses inside getCurrentStat and
-- getBookStat — the divisor behind "Estimated finish date" and "Average time
-- per day". Cached per paint cycle; the value only changes once per day so
-- paint-scoped staleness is fine.
--
-- Used by %days_reading_book, %pages_per_day, and %book_finish_date so all
-- three answer "what's your pace when you actually read this book" instead
-- of "what's your pace averaged over calendar days since first touching the
-- file" (the latter is meaningless for sporadically-read books).
function Tokens._readBookDistinctReadingDays(ui, cache)
    if cache and cache.book_distinct_days ~= nil then
        if cache.book_distinct_days == false then return nil end
        return cache.book_distinct_days
    end
    if not ui or not ui.statistics or not ui.statistics.id_curr_book then
        if cache then cache.book_distinct_days = false end
        return nil
    end
    local id_book = ui.statistics.id_curr_book
    local ok, days = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local DataStorage = require("datastorage")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local sql = string.format([[
            SELECT count(*) FROM (
                SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime') AS d
                FROM   page_stat
                WHERE  id_book = %d
                GROUP  BY d
            );
        ]], id_book)
        local n = conn:rowexec(sql)
        conn:close()
        return tonumber(n) or 0
    end)
    if not ok or not days then
        if cache then cache.book_distinct_days = false end
        return nil
    end
    -- If the user has read at all this session but no row has flushed yet,
    -- today still counts as a reading day from the user's perspective. Fold
    -- in the in-memory delta so a brand-new book on day-one shows 1 not 0.
    if days == 0 and ui.statistics.mem_read_pages and ui.statistics.mem_read_pages > 0 then
        days = 1
    end
    if cache then cache.book_distinct_days = days end
    return days
end

-- Per-book stats over a time range. Returns { duration, pages } or nil. duration
-- is seconds, pages is count of distinct rescaled pages read in the range.
-- Adds the current-book in-memory deltas (mem_read_pages/mem_read_time) since
-- KOReader doesn't flush every page-turn (MAX_PAGETURNS_BEFORE_FLUSH = 50).
-- cache_key gates per-paint-cycle caching alongside the existing stats helpers.
function Tokens._readStatsBookRange(ui, cache, since_ts, cache_key)
    if cache and cache[cache_key] ~= nil then
        if cache[cache_key] == false then return nil end
        return cache[cache_key]
    end
    if not ui or not ui.statistics or not ui.statistics.id_curr_book then
        if cache then cache[cache_key] = false end
        return nil
    end
    local id_book = ui.statistics.id_curr_book
    local ok, result = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local DataStorage = require("datastorage")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        -- page_stat is a view that rescales to current page count, so per-page
        -- deduplication reflects the user's current page numbering. The view's
        -- triple JOIN is heavier than page_stat_data alone but mirrors what
        -- KOReader's own getTodayBookStats does, keeping the page count
        -- semantically consistent with %pages_today.
        local sql = string.format([[
            SELECT count(*), sum(sum_duration)
            FROM (SELECT sum(duration) AS sum_duration
                  FROM page_stat
                  WHERE id_book = %d AND start_time >= %d
                  GROUP BY page);
        ]], id_book, since_ts)
        local stmt = conn:prepare(sql)
        -- resultset("i") returns column-major data: rows[col][row]. Mirrors
        -- KOReader's own usage in getBookStat (res[1][i], res[2][i], ...).
        local rows, nrows = stmt:reset():resultset("i")
        stmt:close()
        conn:close()
        local pages = (nrows and nrows > 0) and tonumber(rows[1][1]) or 0
        local dur   = (nrows and nrows > 0) and tonumber(rows[2][1]) or 0
        return { pages = pages or 0, duration = dur or 0 }
    end)
    if not ok or not result then
        if cache then cache[cache_key] = false end
        return nil
    end
    local mem_pages = tonumber(ui.statistics.mem_read_pages) or 0
    local mem_time  = tonumber(ui.statistics.mem_read_time) or 0
    result.pages = result.pages + mem_pages
    result.duration = result.duration + mem_time
    if cache then cache[cache_key] = result end
    return result
end

-- Reading streak: consecutive calendar days with activity, ending today
-- (counted) or yesterday (counted; today still has time to qualify). If
-- id_book is non-nil, restricts to that book; otherwise across all books.
-- Bounded to 366 days lookback so the query stays fast on large databases
-- (the start_time index keeps the page_stat_data scan tight).
function Tokens._readStreak(ui, cache, id_book, cache_key)
    if cache and cache[cache_key] ~= nil then
        if cache[cache_key] == false then return nil end
        return cache[cache_key]
    end
    if not ui or not ui.statistics then
        if cache then cache[cache_key] = false end
        return nil
    end
    local ok, result = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local DataStorage = require("datastorage")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local lookback = os.time() - 366 * 86400
        local where = id_book
            and string.format("WHERE id_book = %d AND start_time >= %d", id_book, lookback)
            or string.format("WHERE start_time >= %d", lookback)
        -- Query page_stat_data directly (raw rows, no rescaling join) since
        -- we only need distinct calendar dates. Much cheaper than page_stat.
        local sql = string.format([[
            SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS dt
            FROM page_stat_data %s
            ORDER BY dt DESC
            LIMIT 366;
        ]], where)
        local stmt = conn:prepare(sql)
        -- resultset("i") is column-major: rows[col][row]. With one column,
        -- rows[1] is the date array indexed by row number.
        local rows, nrows = stmt:reset():resultset("i")
        stmt:close()
        conn:close()
        if not nrows or nrows == 0 then return 0 end
        local dates = rows[1]
        local now_t = os.date("*t")
        local today_str = string.format("%04d-%02d-%02d", now_t.year, now_t.month, now_t.day)
        local yest_str  = os.date("%Y-%m-%d", os.time() - 86400)
        if dates[1] ~= today_str and dates[1] ~= yest_str then
            return 0
        end
        local streak = 1
        local prev = dates[1]
        for i = 2, nrows do
            local cur = dates[i]
            local y, m, d = prev:match("(%d+)-(%d+)-(%d+)")
            -- Anchor at noon to dodge DST-transition off-by-one when adding 86400s.
            local prev_t = os.time({ year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=12, min=0, sec=0 })
            local prev_minus_one = os.date("%Y-%m-%d", prev_t - 86400)
            if cur == prev_minus_one then
                streak = streak + 1
                prev = cur
            else
                break
            end
        end
        return streak
    end)
    if not ok or not result then
        if cache then cache[cache_key] = false end
        return nil
    end
    if cache then cache[cache_key] = result end
    return result
end

-- Single-row aggregation over the (small) book table. Returns total lifetime
-- read time in seconds and finished-book count. Adds the current book's
-- in-memory mem_read_time delta to total so the value updates between flushes.
-- "Finished" is heuristic: total_read_pages >= pages, as KOReader doesn't
-- store an explicit completed flag in the stats DB.
function Tokens._readStatsBookSummary(ui, cache)
    if cache and cache.book_summary ~= nil then
        if cache.book_summary == false then return nil end
        return cache.book_summary
    end
    local ok, result = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local DataStorage = require("datastorage")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local sql = [[
            SELECT
                COALESCE(SUM(total_read_time), 0),
                COALESCE(SUM(CASE WHEN pages > 0 AND total_read_pages >= pages THEN 1 ELSE 0 END), 0)
            FROM book;
        ]]
        local stmt = conn:prepare(sql)
        -- resultset("i") is column-major: rows[col][row].
        local rows, nrows = stmt:reset():resultset("i")
        stmt:close()
        conn:close()
        if not nrows or nrows == 0 then return { total_time = 0, finished_count = 0 } end
        return {
            total_time = tonumber(rows[1][1]) or 0,
            finished_count = tonumber(rows[2][1]) or 0,
        }
    end)
    if not ok or not result then
        if cache then cache.book_summary = false end
        return nil
    end
    -- Roll the current book's in-memory delta into the lifetime total so the
    -- value increments live alongside %book_read_time rather than only at flush.
    if ui and ui.statistics then
        local mem_time = tonumber(ui.statistics.mem_read_time) or 0
        result.total_time = result.total_time + mem_time
    end
    if cache then cache.book_summary = result end
    return result
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
-- Preserves the regional code first (e.g. pt_BR), then tries generic
-- fallbacks. Only affects directives formatLocalizedDate leaves to native
-- os.date (weekday/month names go through LocalDate instead, see below).
local _date_locale_cache = {} -- language code -> locale string or false
local function getDateLocale()
    local ok, GetText = pcall(require, "gettext")
    if not ok or not GetText or not GetText.current_lang or GetText.current_lang == "C" then
        return false
    end

    local current_lang = GetText.current_lang:gsub("-", "_")
    local lang = current_lang:match("^([a-z]+)")
    if not lang or lang == "en" then
        return false
    end
    if _date_locale_cache[current_lang] ~= nil then
        return _date_locale_cache[current_lang]
    end

    local candidates = {}
    local seen = {}
    local function add(locale)
        if locale and locale ~= "" and not seen[locale] then
            candidates[#candidates + 1] = locale
            seen[locale] = true
        end
    end

    if current_lang:find("_", 1, true) then
        add(current_lang .. ".UTF-8")
        add(current_lang .. ".utf8")
        add(current_lang)
    end
    add(lang .. "_" .. lang:upper() .. ".UTF-8")
    add(lang .. ".UTF-8")
    add(lang)

    local saved = os.setlocale(nil, "time")
    for _, loc in ipairs(candidates) do
        if os.setlocale(loc, "time") then
            os.setlocale(saved or "C", "time")
            _date_locale_cache[current_lang] = loc
            return loc
        end
    end
    if saved then os.setlocale(saved, "time") end
    _date_locale_cache[current_lang] = false
    return false
end

local WEEKDAY_NAMES = {
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
}
local WEEKDAY_NAMES_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function getLocalizedWeekday(short, epoch)
    local now = os.date("*t", epoch or os.time())
    local source = (short and WEEKDAY_NAMES_SHORT or WEEKDAY_NAMES)[now.wday] or ""
    return LocalDate.weekday(source)
end

local MONTH_NAMES = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}
local MONTH_NAMES_SHORT = {
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

local function getLocalizedMonth(short, epoch)
    local now = os.date("*t", epoch or os.time())
    local source = (short and MONTH_NAMES_SHORT or MONTH_NAMES)[now.month] or ""
    return LocalDate.month(source)
end

-- Format a strftime string, resolving %A/%a/%B/%b/%h through LocalDate
-- (KOReader's own translation tables) and leaving every other directive to
-- native os.date under the device locale (see getDateLocale).
local function formatLocalizedDate(fmt, epoch)
    if not fmt or fmt == "" then return "" end

    local timestamp = epoch or os.time()
    local loc = getDateLocale()
    local saved_locale
    if loc then
        saved_locale = os.setlocale(nil, "time")
        os.setlocale(loc, "time")
    end

    local output = {}
    local native = {}

    local function flushNative()
        if #native == 0 then return end
        output[#output + 1] = os.date(table.concat(native), timestamp) or ""
        native = {}
    end

    local i = 1
    while i <= #fmt do
        local char = fmt:sub(i, i)
        if char ~= "%" or i == #fmt then
            native[#native + 1] = char
            i = i + 1
        else
            local j = i + 1
            local next_char = fmt:sub(j, j)
            if next_char == "%" then
                native[#native + 1] = "%%"
                i = i + 2
            else
                while j <= #fmt and fmt:sub(j, j):match("[-_0%^#EO%d]") do
                    j = j + 1
                end
                if j > #fmt then
                    native[#native + 1] = fmt:sub(i)
                    break
                end

                local directive = fmt:sub(i, j)
                local spec = fmt:sub(j, j)
                if directive == "%A" or directive == "%a"
                        or directive == "%B" or directive == "%b"
                        or directive == "%h" then
                    flushNative()
                    if spec == "A" then
                        output[#output + 1] = getLocalizedWeekday(false, timestamp)
                    elseif spec == "a" then
                        output[#output + 1] = getLocalizedWeekday(true, timestamp)
                    elseif spec == "B" then
                        output[#output + 1] = getLocalizedMonth(false, timestamp)
                    else
                        output[#output + 1] = getLocalizedMonth(true, timestamp)
                    end
                else
                    native[#native + 1] = directive
                end
                i = j + 1
            end
        end
    end

    flushNative()
    if saved_locale then os.setlocale(saved_locale, "time") end
    return table.concat(output)
end

-- Format an ETA epoch for the %*_time_left_eta tokens. When brace_fmt is nil,
-- defaults to KOReader's clock format (datetime.secondsToHour honours the
-- twelve_hour_clock setting and any %_I-style strftime variants the platform
-- needs). When brace_fmt is set, it is passed through formatLocalizedDate.
local function formatEtaEpoch(epoch, brace_fmt)
    if not epoch then return "" end
    if brace_fmt and brace_fmt ~= "" then
        return formatLocalizedDate(brace_fmt, epoch)
    end
    local twelve = G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock") or false
    return datetime.secondsToHour(epoch, twelve)
end

-- Format a finish-date epoch for %book_finish_date. Default format is short
-- localised date ("9 Jun" / "9 Juin" / etc); brace_fmt overrides with a full
-- strftime spec.
local function formatFinishDate(epoch, brace_fmt)
    if not epoch then return "" end
    local fmt = (brace_fmt and brace_fmt ~= "") and brace_fmt or "%d %b"
    return formatLocalizedDate(fmt, epoch)
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

--- Parse a leading chapter-number prefix from a title.
-- Recognises "1 Title", "1. Title", "1: Title", "1) Title" — number, optional
-- single separator, mandatory whitespace, mandatory non-empty rest. Rejects
-- bare-numeric titles ("1"), decimal/section numbers ("1.1 Background"), and
-- numbers with no separator ("1Title").
-- @return number, rest_string on match; nil otherwise.
local function parseChapNumPrefix(title)
    if type(title) ~= "string" then return nil end
    local n_str, rest = title:match("^%s*(%d+)[%.%):]?%s+(.+)$")
    if not n_str then return nil end
    if rest:match("^%s*$") then return nil end
    return tonumber(n_str), rest
end

--- Decide per TOC depth whether stripping leading chapter numbers is safe.
-- A depth is safe iff:
--   1. Parsed leading numbers form a strict 1..N sequence (no gaps, no
--      duplicates, no zero-start) with N >= 2. Entries without a parseable
--      prefix at the depth are ignored (so "Foreword"/"Epilogue" don't
--      break a 1..N sequence).
--   2. The post-strip "rest" strings are all distinct. This guards against
--      cases like "1 Chapter, 2 Chapter, 3 Chapter" where the leading number
--      is the only differentiator and removing it would collapse all titles
--      to the same string.
-- @param toc array of TOC entries with .title and .depth fields
-- @return { [depth] = true|false, ... }
local function computeStripPrefixByDepth(toc)
    local result = {}
    if type(toc) ~= "table" then return result end

    local by_depth = {}
    for _, entry in ipairs(toc) do
        local depth = entry.depth or 1
        local num, rest = parseChapNumPrefix(entry.title)
        if num then
            local bucket = by_depth[depth] or { nums = {}, rests = {} }
            table.insert(bucket.nums, num)
            table.insert(bucket.rests, rest)
            by_depth[depth] = bucket
        end
    end

    for depth, bucket in pairs(by_depth) do
        local ok = #bucket.nums >= 2
        if ok then
            for i, n in ipairs(bucket.nums) do
                if n ~= i then ok = false; break end
            end
        end
        if ok then
            local seen = {}
            for _, rest in ipairs(bucket.rests) do
                local key = rest:match("^%s*(.-)%s*$") or rest
                if seen[key] then ok = false; break end
                seen[key] = true
            end
        end
        result[depth] = ok
    end
    return result
end

-- Per-TOC cache of strip-prefix decisions. Weak-keyed by the TOC array
-- reference so cache entries are reclaimed when the document closes and
-- KOReader drops the TOC.
local _strip_cache = setmetatable({}, { __mode = "k" })

--- Walk the TOC once and return a table of chapter-title data derived from it.
-- Chapter titles are returned as-is from the TOC. The helper additionally
-- exposes split parts (chapter_title_num / chapter_title_name) when the
-- heuristic deems the deepest covering depth strip-safe; see
-- parseChapNumPrefix and computeStripPrefixByDepth for the rule.
-- @param ui     KOReader ReaderUI instance (must have .toc)
-- @param pageno current page number (1-indexed)
-- @return table with keys:
--   chapter_title       — deepest (most-specific) chapter title covering the page (raw)
--   chapter_titles_by_depth — { [1]="Part II", [2]="Ch 3", ... } (raw)
--   chapter_num         — 1-indexed flat position of the current entry
--   chapter_count       — total TOC entries across all depths
--   chapter_title_num   — leading number parsed from chapter_title when the
--                         deepest depth has a strip-safe 1..N sequence; "" otherwise
--   chapter_title_name  — chapter_title with the parsed leading number removed
--                         when strip-safe; equal to chapter_title otherwise (always populated)
-- Returns an empty-ish table if ui.toc or page data is unavailable.
function Tokens.getChapterTitlesByDepth(ui, pageno)
    local out = {
        chapter_title = "",
        chapter_titles_by_depth = {},
        chapter_num = 0,
        chapter_count = 0,
        chapter_title_num = "",
        chapter_title_name = "",
    }
    if not ui or not ui.toc or not pageno then return out end

    local full_toc = ui.toc.toc
    if not full_toc then
        local title = ui.toc:getTocTitleByPage(pageno)
        if title and title ~= "" then
            out.chapter_title = title
            out.chapter_title_name = title
        end
        return out
    end

    out.chapter_count = #full_toc
    local idx = 0
    local max_depth_seen = 0
    for i, entry in ipairs(full_toc) do
        if entry.page and entry.page <= pageno then
            idx = i
            if entry.depth then
                local d = entry.depth
                -- A depth-d entry implicitly closes any siblings/descendants
                -- at depth >= d, so clear them before pushing this one.
                for dd = d, max_depth_seen do
                    out.chapter_titles_by_depth[dd] = nil
                end
                out.chapter_titles_by_depth[d] = entry.title or ""
                if d > max_depth_seen then max_depth_seen = d end
            end
        else
            break
        end
    end
    if idx > 0 then out.chapter_num = idx end

    local deepest_depth = 0
    local deepest_title = ""
    for d = max_depth_seen, 1, -1 do
        local t = out.chapter_titles_by_depth[d]
        if t and t ~= "" then
            deepest_depth = d
            deepest_title = t
            break
        end
    end

    if deepest_title and deepest_title ~= "" then
        out.chapter_title = deepest_title
    else
        local title = ui.toc:getTocTitleByPage(pageno)
        if title and title ~= "" then out.chapter_title = title end
    end

    out.chapter_title_name = out.chapter_title

    if out.chapter_title ~= "" and deepest_depth > 0 then
        local strip_by_depth = _strip_cache[full_toc]
        if not strip_by_depth then
            strip_by_depth = computeStripPrefixByDepth(full_toc)
            _strip_cache[full_toc] = strip_by_depth
        end
        if strip_by_depth[deepest_depth] then
            local n, rest = parseChapNumPrefix(out.chapter_title)
            if n and rest then
                out.chapter_title_num  = tostring(n)
                out.chapter_title_name = rest
            end
        end
    end

    return out
end

--- Half-open page range [start, stop) of the level-`depth` chapter covering
-- `pageno`. The level-`depth` region is delimited by any TOC entry with
-- depth <= `depth` (a shallower heading also opens a new level-`depth` region),
-- so depth=1 yields the coarsest boundaries and depth >= the book's max depth
-- collapses to the deepest (flat) chapter. `stop` is exclusive — the first page
-- past the chapter, or pagecount+1 for the final chapter.
-- @return { start = <page>, stop = <page> }, or nil when TOC data is missing or
--         `pageno` precedes the first qualifying entry.
function Tokens.getChapterRangeByDepth(ui, pageno, depth)
    if not ui or not ui.toc or not pageno or not depth then return nil end
    local full_toc = ui.toc.toc
    if not full_toc or #full_toc == 0 then return nil end
    local start_page, stop_page
    for _i, entry in ipairs(full_toc) do
        if entry.page and entry.depth and entry.depth <= depth then
            if entry.page <= pageno then
                start_page = entry.page
            else
                stop_page = entry.page
                break
            end
        end
    end
    if not start_page then return nil end
    if not stop_page then
        local total = ui.document and ui.document.getPageCount
            and ui.document:getPageCount()
        stop_page = (total or pageno) + 1
    end
    return { start = start_page, stop = stop_page }
end

--- Chapter progress at a given TOC depth, derived from getChapterRangeByDepth.
-- Formulas mirror the flat chapter tokens (see expand()): the current page is
-- counted in `read`, so read + pages_left == pages.
-- @return { read, pages, pages_left, pct, pct_left } (numbers), or nil when no
--         range is available.
function Tokens.getChapterProgressByDepth(ui, pageno, depth)
    local range = Tokens.getChapterRangeByDepth(ui, pageno, depth)
    if not range then return nil end
    local pages = range.stop - range.start
    if pages < 1 then return nil end
    local read = pageno - range.start + 1
    local pages_left = math.max(0, range.stop - 1 - pageno)
    local pct
    if pages > 1 then
        pct = math.floor((pageno - range.start) / (pages - 1) * 100)
    else
        pct = 100
    end
    pct = math.max(0, math.min(100, pct))
    return {
        read       = read,
        pages      = pages,
        pages_left = pages_left,
        pct        = pct,
        pct_left   = math.max(0, math.min(100, 100 - pct)),
    }
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
    -- Braced keys FIRST: [if:calibre{mood}="cosy"]. `[%w_]+` alone stops at
    -- `calibre` and then finds `{` where it wants an operator, so without these
    -- the whole condition falls through to the truthy path below, fails there
    -- too, and silently swallows the branch. %b{} is a valid pattern item and
    -- does not match plain keys, so every existing conditional is unaffected.
    -- Conditionals are processed before the brace dispatch in Tokens.expand,
    -- which is why resolving them here is the only option.
    local key, op, value = cond_str:match("^([%w_]+%b{})(>=)(.+)$")
    if not key then key, op, value = cond_str:match("^([%w_]+%b{})(<=)(.+)$") end
    if not key then key, op, value = cond_str:match("^([%w_]+%b{})(!=)(.+)$") end
    if not key then key, op, value = cond_str:match("^([%w_]+%b{})([=<>])(.+)$") end
    if not key then key, op, value = cond_str:match("^([%w_]+)(>=)(.+)$") end
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
    -- Braced form first, same reasoning as the operator patterns above.
    local key_only = cond_str:match("^([%w_]+%b{})$")
                  or cond_str:match("^([%w_]+)$")
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
--- Add the calibre columns named by THIS template to a condition state.
---
--- Scanning the format string keeps an unnamed column free, matching how
--- needs() gates the rest of the expensive state. Keyed exactly as written,
--- braces included, so evaluateCondition can look up "calibre{mood}" verbatim
--- - the value is normalised for the field lookup, the key is not.
---
--- Separate from the state build because it is the one part that is per-CALLER
--- rather than per-paint. The state table is built once and shared across every
--- line in a paint, so leaving this inside the build meant only the first
--- conditional-bearing line ever got its columns resolved: a second line naming
--- a different column evaluated false and took its [else] branch.
local function addCalibreConditionKeys(state, ui, format_str)
    if not (state and format_str and format_str:find("calibre{", 1, true)) then
        return
    end
    local fields = Tokens._calibreFieldsFor(ui)
    for raw in format_str:gmatch("calibre(%b{})") do
        local key_written = "calibre" .. raw
        -- Already resolved by an earlier line in this paint; the lookup is the
        -- same either way, so skip the work rather than redo it.
        if state[key_written] == nil then
            local inner = raw:sub(2, -2)
            local key = tostring(inner):gsub("^%s*#?", ""):gsub("%s*$", ""):lower()
            state[key_written] = (fields and fields[key]) or ""
        end
    end
end

function Tokens.buildConditionState(ui, session_elapsed, session_pages_read, paint_ctx, stats_cache, format_str)
    if paint_ctx and paint_ctx._condition_state then
        local cached = paint_ctx._condition_state
        -- The shared table is built once per paint, but the calibre columns
        -- are gated on the calling template, so each caller contributes its own.
        addCalibreConditionKeys(cached, ui, format_str)
        return cached
    end

    -- Optional format-string gating: when paint_ctx contains the union of all
    -- visible-line format strings (paint_ctx._cond_format_union, set by
    -- main.lua._paintToInner), or when format_str is passed directly, only
    -- SQL-backed condition fields referenced in some [if:...] block are
    -- fetched. Without either, every bucket fetches (preserves test/back-
    -- compat behaviour). Issue #36: a preset with one [if:title] used to
    -- fire ~7 SQLite queries per page turn, dominating the ~200ms expand
    -- cost on a Clara BW. Gating drops that to 0 for stats-free conditionals.
    local cond_region
    local gating_source = (paint_ctx and paint_ctx._cond_format_union) or format_str
    if gating_source then
        local parts = {}
        for cond in gating_source:gmatch("%[if:([^%]]+)%]") do
            table.insert(parts, cond)
        end
        cond_region = "\0" .. table.concat(parts, "\0") .. "\0"
    end
    local function refs(...)
        if not cond_region then return true end
        for i = 1, select("#", ...) do
            local name = select(i, ...)
            if cond_region:find("[^%w_]" .. name .. "[^%w_]", 1, false) then
                return true
            end
        end
        return false
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
        if powerd.fl_max and powerd.fl_max > 0 then
            -- 0-100 percentage of frontlight intensity; the device-native
            -- range varies (Kindle 0-24, Kobo 0-100, generic 0-10), so
            -- normalise via fl_max for cross-device conditionals.
            state.light_pct = math.floor(
                powerd:frontlightIntensity() / powerd.fl_max * 100 + 0.5)
        end
        if Device:hasNaturalLight() and powerd.frontlightWarmth then
            -- state.warmth keeps the device-native value (0-24 on Kindle)
            -- for users with conditionals tied to that scale; warmth_pct
            -- is the normalised 0-100 frontlightWarmth() return value.
            state.warmth = powerd:toNativeWarmth(powerd:frontlightWarmth())
            state.warmth_pct = math.floor(powerd:frontlightWarmth() + 0.5)
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

    -- Night mode (driven by KOReader's persistent "night_mode" setting,
    -- toggled via the Toggle night mode action — same source as
    -- ToggleNightMode handlers in devicelistener.lua).
    state.night = G_reader_settings:isTrue("night_mode") and "on" or "off"

    -- [if:full_width] (#348). Bookshelf sets this on the state for its
    -- FULL-WIDTH status line and leaves it empty in the narrow cover-view
    -- column, so a template can surface extra content only where there is room
    -- (its issue #178). Every bookends line spans the screen, so the honest
    -- answer here is always "yes" - and giving that answer matters: a template
    -- copied across with [if:full_width] in it would otherwise silently drop
    -- the guarded content, which reads as the token being broken. Overridable
    -- via opts so the mirrored region can state it explicitly.
    state.full_width = "yes"

    -- Page-based state
    local pageno = getCurrentPageNumber(ui)
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
                -- Split hours/minutes, matching the %book_time_left_h / _m
                -- tokens (#104). Without these, the natural way to hide an
                -- empty hour segment - [if:book_time_left_h>0] - is an unknown
                -- key and quietly evaluates false, so the hours never render
                -- and nothing says why. Derived from the minutes field rather
                -- than recomputed, so the conditional and [if:book_time_left>=60]
                -- can never disagree.
                state.book_time_left_h = math.floor(state.book_time_left / 60)
                state.book_time_left_m = state.book_time_left % 60
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
                -- Split hours/minutes to match the %chap_time_left_h / _m
                -- tokens — see the book_time_left_h note above (#104).
                state.chap_time_left_h = math.floor(state.chap_time_left / 60)
                state.chap_time_left_m = state.chap_time_left % 60
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
        state.format = Tokens.getFileExtension(doc)
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
        state.chap_title      = titles.chapter_title or ""
        state.chap_title_1    = titles.chapter_titles_by_depth[1] or ""
        state.chap_title_2    = titles.chapter_titles_by_depth[2] or ""
        state.chap_title_3    = titles.chapter_titles_by_depth[3] or ""
        state.chap_title_num  = titles.chapter_title_num or ""
        state.chap_title_name = titles.chapter_title_name or ""
    end

    -- Time (minutes since midnight, compare with HH:MM or raw minutes)
    local now = os.date("*t")
    state.time = now.hour * 60 + now.min

    -- Day of week (locale-independent)
    local weekdays = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
    state.day = weekdays[now.wday]

    -- Session (prefer ReaderStatistics' skip-aware values; fall back to
    -- our wall-clock measurement and max-page counter when stats is disabled).
    if refs("session", "session_pages", "session_time") then
        local stats_session = Tokens._readStatsBookSession(ui, stats_cache)
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
    if refs("pages_today", "time_today") then
        local stats_today = Tokens._readStatsToday(ui, stats_cache)
        if stats_today then
            state.pages_today = math.max(0, stats_today.pages)
            state.time_today = math.floor(stats_today.duration / 60)
        else
            state.pages_today = 0
            state.time_today = 0
        end
    end

    -- Today's reading totals (current book only). Mirrors pages_today/time_today
    -- but with id_book scoping so a user reading a second book today doesn't
    -- inflate the count for the book they're currently reading.
    if refs("pages_today_book", "time_today_book") then
        local now_t = os.date("*t")
        local start_today = os.time() - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec)
        local s = Tokens._readStatsBookRange(ui, stats_cache, start_today, "book_today")
        state.pages_today_book = s and math.max(0, s.pages) or 0
        state.time_today_book = s and math.floor(s.duration / 60) or 0
    end

    -- Current book over the last 7 days (rolling window, not calendar week).
    if refs("pages_week_book", "time_week_book") then
        local since = os.time() - 7 * 86400
        local s = Tokens._readStatsBookRange(ui, stats_cache, since, "book_week")
        state.pages_week_book = s and math.max(0, s.pages) or 0
        state.time_week_book = s and math.floor(s.duration / 60) or 0
    end

    -- Reading streaks (consecutive calendar days). nil id_book = any-book streak.
    if refs("streak") then
        state.streak = Tokens._readStreak(ui, stats_cache, nil, "streak") or 0
    end
    if refs("book_streak") then
        if ui and ui.statistics and ui.statistics.id_curr_book then
            state.book_streak = Tokens._readStreak(ui, stats_cache, ui.statistics.id_curr_book, "book_streak") or 0
        else
            state.book_streak = 0
        end
    end

    -- Lifetime aggregates over the book table (single SQL, two values).
    if refs("total_read_time", "books_finished") then
        local s = Tokens._readStatsBookSummary(ui, stats_cache)
        state.total_read_time = s and math.floor(s.total_time / 60) or 0
        state.books_finished = s and s.finished_count or 0
    end

    -- Lifetime stats for the current book (instance fields on ui.statistics).
    if ui.statistics and tonumber(ui.statistics.book_read_pages) and ui.statistics.book_read_pages > 0 then
        state.book_pages_read = math.floor(ui.statistics.book_read_pages)
    else
        state.book_pages_read = 0
    end
    if ui.statistics and tonumber(ui.statistics.avg_time) and ui.statistics.avg_time > 0 then
        state.avg_page_time = math.floor(ui.statistics.avg_time)
    else
        state.avg_page_time = 0
    end

    -- Skip-aware book completion percentage (complement of position-based book_pct).
    do
        local read = state.book_pages_read or 0
        local total = (ui.document and tonumber(ui.document:getPageCount())) or 0
        if total > 0 and read > 0 then
            state.book_pct_read = math.min(100, math.floor((read / total) * 100))
        else
            state.book_pct_read = 0
        end
    end

    -- Distinct calendar days the user has actually read this book, and the
    -- derived per-day pace. Uses the stats plugin's divisor (count(distinct
    -- date) over page_stat) rather than calendar-days-since-first-open — so
    -- "5 reading days in the last month" reports 5, not 30, and pages-per-day
    -- reflects pace WHEN reading rather than averaged over dead time.
    if refs("days_reading_book", "pages_per_day") then
        local days = Tokens._readBookDistinctReadingDays(ui, stats_cache) or 0
        state.days_reading_book = days
        local read = state.book_pages_read or 0
        local divisor = math.max(days, 1)
        if read > 0 and days > 0 then
            state.pages_per_day = math.floor(read / divisor)
        else
            state.pages_per_day = 0
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
    addCalibreConditionKeys(state, ui, format_str)

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
    -- Optional caller-supplied cache for SQL-backed stats reads. Lets a caller
    -- iterating many tokens (e.g. the token picker building its catalog
    -- preview) share the result of getCurrentBookStats / getTodayBookStats
    -- across calls instead of re-querying SQLite per token. When omitted,
    -- helpers fall through to fresh reads, matching pre-cache behaviour.
    local stats_cache = opts.stats_cache
    -- Fast path: no tokens or conditionals
    if not format_str:find("%%") and not format_str:find("%[if:") then
        return format_str
    end

    -- #92: %<token> / %<token{arg}> delimited form. The greedy identifier
    -- match (%%[%a_][%w_]*) would otherwise absorb any letters/digits written
    -- immediately after a token, so `%book_time_left_hh` reads as one unknown
    -- name. The angle brackets mark where the name ends. We rewrite the
    -- delimited form to the plain %token followed by a \4 boundary sentinel:
    -- \4 is not a word char, so every downstream pass (legacy alias, brace
    -- pre-parse, bareword, depth-suffix, preview mirror) stops the identifier
    -- there exactly as a space would, and no per-token handling is needed. The
    -- sentinel is stripped just before the value is returned. An unclosed
    -- `%<name` (no `>`) or non-identifier start is left untouched (literal).
    -- This MUST run before rewriteLegacyTokens so a delimited token with a
    -- strftime brace (e.g. %<datetime{%H:%M}>) is already in canonical
    -- %datetime{…} form, which the legacy pass recognises and leaves its brace
    -- body verbatim — otherwise the %H/%M inside would be alias-rewritten.
    format_str = format_str:gsub("%%<([%a_][^>]*)>", "%%%1\4")

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
        -- format_str is passed so buildConditionState can gate the columns it
        -- resolves for [if:calibre{...}] to the ones this template names.
        local state = Tokens.buildConditionState(ui, session_elapsed,
            session_pages_read, paint_ctx, stats_cache, format_str)
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
    -- Decimal places for %book_pct{N} and %book_pct_left{N}. Set by the brace
    -- handler below; consumed during percent computation to format with
    -- string.format("%.Nf", raw_pct) instead of math.floor(pct + 0.5).
    local pct_decimals = {}
    -- strftime format brace for time/date projection tokens. Keyed by token
    -- name; consumed when building the substitution table. Used by the two
    -- %*_time_left_eta tokens and %book_finish_date.
    local date_formats = {}
    -- Calibre custom-column map for this expand pass. false means "looked and
    -- there is nothing", which is distinct from nil ("not looked yet") - a
    -- status line naming three columns should probe once, not three times.
    local calibre_fields = nil

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
            -- Strftime escape hatch.
            return formatLocalizedDate(content)
        end
        if name == "calibre" then
            -- Resolved inline like %datetime rather than rewritten to a
            -- bareword: the field name lives in the brace, so there is no
            -- bareword form to rewrite to. Fetched lazily and cached for the
            -- pass. Field names match case-insensitively with or without
            -- calibre's leading '#', so a column "#mood" answers to
            -- %calibre{mood} and %calibre{#Mood} alike.
            if calibre_fields == nil then
                calibre_fields = Tokens._calibreFieldsFor(ui) or false
            end
            if not calibre_fields then return "" end
            local key = tostring(content):gsub("^%s*#?", ""):gsub("%s*$", ""):lower()
            return calibre_fields[key] or ""
        end
        -- %chap_time_left_eta{<strftime>} / %book_time_left_eta{<strftime>} /
        -- %book_finish_date{<strftime>}. Stash format and rewrite to bareword
        -- so the substitution pass renders it with the right epoch.
        if name == "chap_time_left_eta" or name == "book_time_left_eta"
                or name == "book_finish_date" then
            date_formats[name] = content
            return "%" .. name
        end
        -- %book_pct{N} / %book_pct_left{N}: decimal places (0–4).
        if name == "book_pct" or name == "book_pct_left" then
            local d = content:match("^(%d+)$")
            if d then
                local n = tonumber(d)
                if n and n >= 0 and n <= 4 then
                    pct_decimals[name] = n
                end
            end
            return "%" .. name
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
            chap_time_left_eta = "[ch.eta]", book_time_left_eta = "[eta]",
            book_finish_date = "[finish]",
            time_12h = "[12h]", time_24h = "[24h]", time = "[24h]",
            date = "[date]", date_long = "[date.long]",
            date_numeric = "[dd/mm/yy]",
            weekday = "[weekday]", weekday_short = "[wkday]",
            session_time = "[session]", session_pages = "[pages]",
            title = "[title]", author = "[author]",
            series = "[series]", series_name = "[series.name]", series_num = "[series.#]",
            chap_title = "[chapter]",
            chap_title_num = "[ch.#]", chap_title_name = "[chapter]",
            filename = "[file]", lang = "[lang]",
            format = "[format]",
            highlights = "[highlights]", notes = "[notes]",
            bookmarks = "[bookmarks]", annotations = "[annotations]",
            speed = "[pg/hr]", book_read_time = "[total]",
            pages_today_book = "[pages.book]", time_today_book = "[time.book]",
            pages_week_book = "[pages.wk]", time_week_book = "[time.wk]",
            streak = "[streak]", book_streak = "[bk.streak]",
            total_read_time = "[lifetime]", books_finished = "[done]",
            batt = "[batt]", batt_icon = "[batt]", wifi = "[wifi]",
            plugin_content = "[plugins]",
            invert = "[invert]",
            light = "[light]", light_icon = "[light]", light_pct = "[light]",
            warmth = "[warmth]", warmth_pct = "[warmth]", warmth_icon = "[warmth]",
            nightmode = "[night]",
            mem = "[mem]", ram = "[rss]",
            disk = "[disk]",
            bar = "\xE2\x96\xB0\xE2\x96\xB0\xE2\x96\xB1\xE2\x96\xB1",  -- ▰▰▱▱
            -- An elastic gap, not a name. There is nothing to split in a menu
            -- row, so it previews as a space - the same thing bookshelf's
            -- menuPreview does with it.
            spacer = " ",
            -- The rest of the catalogue. These had no entry at all, so they
            -- fell through to the identity fallback and showed the reader the
            -- raw "%token" in the line editor and the position-menu subtitles
            -- - the #348 sweep documented a batch of tokens without extending
            -- this map. Labelled after the token rather than with invented
            -- wording, which is a maintainer's call, not a mechanical one.
            wifi_icon = "[wifi]",
            authors = "[authors]", authors_short = "[authors]",
            author_2 = "[author.2]", author_count = "[author.count]",
            description = "[description]",
            status = "[status]", status_label = "[status]",
            rating = "[rating]", rating_number = "[rating.n]",
            favourite = "[favourite]",
            quote = "[quote]", quote_source = "[quote.source]",
            added = "[added]", opened = "[opened]",
            size = "[size]",
            file_num = "[file.num]", file_count = "[file.count]",
            book_pct_read = "[read%]",
            book_pages_read = "[bk.pages]",
            pages_today = "[pages.today]", time_today = "[time.today]",
            days_reading_book = "[days]", pages_per_day = "[per.day]",
            avg_page_time = "[pg.time]",
            book_time_left_h = "[time.h]", book_time_left_m = "[time.m]",
            chap_time_left_h = "[ch.time.h]", chap_time_left_m = "[ch.time.m]",
            sysused = "[sys]",
        }
        -- Strip %bar{N} and %X{N} for preview, showing limit in label
        -- %bar{N} must be replaced before %bar (longer pattern first)
        local r = orig_format_str:gsub("%%bar{(%d+)}", function(n)
            return preview.bar .. "{<=" .. n .. "}"
        end)
        r = r:gsub("%%bar", preview.bar)
        -- Handle %datetime{...} — in preview mode, actually expand it (not a placeholder)
        -- %calibre{col} resolves for REAL in preview, like %datetime below:
        -- the document is open while the line editor is up, so the actual
        -- column value is available and far more useful than a placeholder.
        -- Without this branch the literal characters "%calibre{col}" reach
        -- the menu label, which is what a reader would read as broken.
        r = r:gsub("%%calibre(%b{})", function(brace)
            local fields = Tokens._calibreFieldsFor(ui)
            if not fields then return "" end
            local key = brace:sub(2, -2):gsub("^%s*#?", ""):gsub("%s*$", ""):lower()
            return fields[key] or ""
        end)
        r = r:gsub("%%datetime(%b{})", function(brace)
            return formatLocalizedDate(brace:sub(2, -2))
        end)
        -- Live-preview braced ETA tokens with dummy offsets so the user can
        -- see their strftime format render in the line editor. Chapter uses
        -- +30 minutes, book uses +2 hours so the two times differ visibly.
        r = r:gsub("%%chap_time_left_eta(%b{})", function(brace)
            return formatEtaEpoch(os.time() + 30 * 60, brace:sub(2, -2))
        end)
        r = r:gsub("%%book_time_left_eta(%b{})", function(brace)
            return formatEtaEpoch(os.time() + 120 * 60, brace:sub(2, -2))
        end)
        -- Live-preview %book_finish_date with a dummy +17-day offset.
        r = r:gsub("%%book_finish_date(%b{})", function(brace)
            return formatFinishDate(os.time() + 17 * 86400, brace:sub(2, -2))
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
        -- Depth-variant chapter progress/time (issue #85): reuse the base
        -- token's placeholder label. eta (with a strftime brace) runs first so
        -- the plain pass doesn't swallow "%chap_time_left_1" out of "…_1_eta{…}".
        r = r:gsub("%%chap_time_left_(%d)_eta(%b{})", function(_depth, brace)
            return formatEtaEpoch(os.time() + 30 * 60, brace:sub(2, -2))
        end)
        for _, base in ipairs({
            "chap_pages_left", "chap_pct_left", "chap_pages", "chap_pct",
            "chap_read", "chap_time_left",
        }) do
            local label = preview[base]
            r = r:gsub("%%" .. base .. "_(%d)(%b{})", function(_depth, brace)
                local n = brace:sub(2, -2):match("^(%d+)$")
                if n then return "{" .. label:sub(2, -2) .. "<=" .. n .. "}" end
                return label
            end)
            r = r:gsub("%%" .. base .. "_(%d)", function(_depth)
                return label
            end)
        end
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
        -- The fallback stays an IDENTITY on purpose. It is reached by things
        -- that are not tokens at all - a legacy "%A" under legacy_literal, a
        -- bare "%datetime" with no brace - which must survive as typed. It is
        -- also reached by the labels inserted above, two of which carry a
        -- literal percent followed by letters ("[ch%left]"), so anything that
        -- rewrites here corrupts them. A documented token that lands here is a
        -- GAP IN THE MAP, and the fix is an entry, not a cleverer fallback;
        -- tests/_test_no_literal_tokens.lua fails when one is missing.
        r = r:gsub("%%([%a_][%w_]*)", function(token)
            local label = preview[token]
            if label then return label end
            return "%" .. token
        end)
        r = r:gsub("\4", "")  -- #92: drop %<token> boundary sentinels
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
    local has_spacer = format_str:find("%%spacer") ~= nil

    local pageno = getCurrentPageNumber(ui)
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
    if needs("page_num", "page_count", "book_pct", "book_pct_left", "pages_left",
             "page_num_lastdigit", "page_count_lastdigit", "pages_left_lastdigit") then
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
        -- When both tokens render as integers (the common case), percent_left is
        -- derived from the rounded percent so the pair always sums to 100. When
        -- decimals are requested via %book_pct{N} / %book_pct_left{N}, both
        -- values are formatted independently from the shared raw float; this
        -- keeps the pair within ±0.1% at the displayed precision.
        local pct_dec = pct_decimals.book_pct or 0
        local left_dec = pct_decimals.book_pct_left or pct_dec
        local pct_raw  -- raw float 0-100
        if pageno and doc:hasHiddenFlows() then
            local flow = doc:getPageFlow(pageno)
            local flow_page = doc:getPageNumberInFlow(pageno)
            local flow_total = doc:getTotalPagesInFlow(flow)
            if flow_total and flow_total > 0 then
                pct_raw = flow_page / flow_total * 100
            end
        else
            local raw_total = doc:getPageCount()
            if pageno and raw_total and raw_total > 0 then
                pct_raw = pageno / raw_total * 100
            end
        end
        if pct_raw then
            pct_raw = math.max(0, math.min(100, pct_raw))
            local left_raw = math.max(0, 100 - pct_raw)
            -- Default (both integer): derive percent_left from percent_int so the
            -- pair always sums to 100, even at half-integer raw percentages where
            -- two independent floor(x + 0.5) calls would round both up (e.g.
            -- pct_raw=50.5 → 51% and 50% summing to 101%).
            if pct_dec == 0 and left_dec == 0 then
                local percent_int = math.floor(pct_raw + 0.5)
                percent = percent_int .. "%"
                percent_left = math.max(0, 100 - percent_int) .. "%"
            else
                if pct_dec > 0 then
                    local s = string.format("%." .. pct_dec .. "f", pct_raw)
                    percent = (s:gsub("(%..-)0+$", "%1"):gsub("%.$", "")) .. "%"
                else
                    percent = math.floor(pct_raw + 0.5) .. "%"
                end
                if left_dec > 0 then
                    local s = string.format("%." .. left_dec .. "f", left_raw)
                    percent_left = (s:gsub("(%..-)0+$", "%1"):gsub("%.$", "")) .. "%"
                else
                    percent_left = math.floor(left_raw + 0.5) .. "%"
                end
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
    local chapter_pct_left = ""
    local chapter_pages_done = ""
    local chapter_pages_left = ""
    local chapter_total_pages = ""
    local chapter_title = ""
    local chapter_num = ""      -- 1-indexed position of current chapter in TOC
    local chapter_count = ""    -- total number of entries in TOC
    local chapter_title_num = ""   -- leading number parsed from title when strip-safe
    local chapter_title_name = ""  -- title with leading number removed when strip-safe; raw title otherwise
    local chapter_titles_by_depth = {}  -- { [1] = "Part II", [2] = "Chapter 1", ... }
    -- Depth-variant chapter tokens (%chap_read_1, %chap_pct_2, …; issue #85).
    -- Detected here so the flat block below still runs — the depth tokens fall
    -- back to the flat values when no TOC range is available (chapterless book).
    local has_depth_chap = format_str:find("%%chap_read_%d")
        or format_str:find("%%chap_pages_%d")
        or format_str:find("%%chap_pages_left_%d")
        or format_str:find("%%chap_pct_%d")
        or format_str:find("%%chap_pct_left_%d")
    if (needs("chap_pct", "chap_pct_left", "chap_read", "chap_pages", "chap_pages_left",
             "chap_read_lastdigit", "chap_pages_lastdigit", "chap_pages_left_lastdigit",
             "chap_title", "chap_title_1", "chap_title_2", "chap_title_3", "chap_num", "chap_count",
             "chap_title_num", "chap_title_name") or has_depth_chap) and pageno and ui.toc then
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
        chapter_title_num  = titles.chapter_title_num or ""
        chapter_title_name = titles.chapter_title_name or ""
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

        -- Marker fractions (#77): map session-start / book-open RAW pages onto
        -- the same book and chapter scales as the pct values above, so a
        -- triangle marker lines up with where the fill would sit at that page.
        -- Computed with the identical (flow-aware) math; nil when unavailable.
        local mp = opts.marker_pages
        if mp then
            local function bookFrac(p)
                if not p or not raw_total or raw_total <= 0 then return nil end
                if bar_doc:hasHiddenFlows() then
                    local flow = bar_doc:getPageFlow(p)
                    local ft = bar_doc:getTotalPagesInFlow(flow)
                    local fp = bar_doc:getPageNumberInFlow(p)
                    return (ft and ft > 0) and (fp / ft) or nil
                end
                return p / raw_total
            end
            bar_info.book.session_frac   = bookFrac(mp.session)
            bar_info.book.book_open_frac = bookFrac(mp.book_open)
            bar_info.book.today_frac     = bookFrac(mp.today)
            if mp.bookmarks then
                local book_fracs = {}
                for _, p in ipairs(mp.bookmarks) do
                    local f = bookFrac(p)
                    if f then book_fracs[#book_fracs + 1] = f end
                end
                bar_info.book.bookmark_fracs = book_fracs
            end
            if ui.toc then
                local cs = ui.toc:getPreviousChapter(bar_pageno)
                if ui.toc:isChapterStart(bar_pageno) then cs = bar_pageno end
                if cs then
                    local nc = ui.toc:getNextChapter(bar_pageno)
                    local ce = nc or (bar_doc:getPageCount() + 1)
                    local ctotal = ce - cs
                    local function chFrac(p)
                        if not p or ctotal <= 1 then return nil end
                        return math.max(0, math.min(1, (p - cs) / (ctotal - 1)))
                    end
                    bar_info.chapter.session_frac   = chFrac(mp.session)
                    bar_info.chapter.book_open_frac = chFrac(mp.book_open)
                    bar_info.chapter.today_frac     = chFrac(mp.today)
                    if mp.bookmarks then
                        local chap_fracs = {}
                        for _, p in ipairs(mp.bookmarks) do
                            if p and p >= cs and p < ce then
                                local f = chFrac(p)
                                if f then chap_fracs[#chap_fracs + 1] = f end
                            end
                        end
                        bar_info.chapter.bookmark_fracs = chap_fracs
                    end
                end
            end
        end

        if bar_limit_w then
            bar_info.width = bar_limit_w
        end
        if bar_limit_h then
            bar_info.height = bar_limit_h
        end
    end

    -- Session pages read (skip-aware via ReaderStatistics with fallback to
    -- bookends' own max-page counter when stats is disabled or absent).
    -- Only fetched when a token actually consumes it: %session_pages directly,
    -- or %speed (derived from session_pages / session_elapsed). Skipping the
    -- SQL read on stats-free presets is the bulk of the per-page cost on
    -- low-power devices like the Clara BW (issue #36).
    local session_pages = 0
    if needs("session_pages", "speed") then
        local stats_session = Tokens._readStatsBookSession(ui, stats_cache)
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
    local chap_time_left_h, chap_time_left_m
    local book_time_left_h, book_time_left_m
    if needs("chap_time_left", "book_time_left", "chap_time_left_h", "chap_time_left_m",
             "book_time_left_h", "book_time_left_m")
            and pageno and ui.statistics and ui.statistics.getTimeForPages then
        if needs("chap_time_left", "chap_time_left_h", "chap_time_left_m") then
            local ch_left = ui.toc and ui.toc:getChapterPagesLeft(pageno, true)
            if not ch_left then
                ch_left = doc:getTotalPagesLeft(pageno)
            end
            if ch_left then
                ch_left = math.max(0, ch_left)
                local result = ui.statistics:getTimeForPages(ch_left)
                if result and result ~= "N/A" then time_left_chapter = result end
                if ui.statistics.avg_time and ui.statistics.avg_time > 0 then
                    local total_min = math.floor(ch_left * ui.statistics.avg_time / 60)
                    chap_time_left_h = math.floor(total_min / 60)
                    chap_time_left_m = total_min % 60
                end
            end
        end
        if needs("book_time_left", "book_time_left_h", "book_time_left_m") then
            local doc_left = doc:getTotalPagesLeft(pageno)
            if doc_left then
                doc_left = math.max(0, doc_left)
                local result = ui.statistics:getTimeForPages(doc_left)
                if result and result ~= "N/A" then time_left_doc = result end
                if ui.statistics.avg_time and ui.statistics.avg_time > 0 then
                    local total_min = math.floor(doc_left * ui.statistics.avg_time / 60)
                    book_time_left_h = math.floor(total_min / 60)
                    book_time_left_m = total_min % 60
                end
            end
        end
    end

    -- ETA epochs for %chap_time_left_eta / %book_time_left_eta. Derived from
    -- pages_left × avg_time (seconds) instead of parsing the formatted
    -- chap/book_time_left strings — mirrors how buildConditionState computes
    -- state.chap_time_left in minutes.
    local eta_chap_epoch
    local eta_book_epoch
    if needs("chap_time_left_eta", "book_time_left_eta")
            and pageno and doc and ui.statistics and ui.statistics.avg_time then
        local avg = ui.statistics.avg_time
        if avg and avg > 0 then
            local now = os.time()
            if needs("chap_time_left_eta") then
                local ch_left = ui.toc and ui.toc:getChapterPagesLeft(pageno, true)
                if not ch_left then ch_left = doc:getTotalPagesLeft(pageno) end
                if ch_left and ch_left > 0 then
                    eta_chap_epoch = now + math.floor(ch_left * avg + 0.5)
                end
            end
            if needs("book_time_left_eta") then
                local doc_left = doc:getTotalPagesLeft(pageno)
                if doc_left and doc_left > 0 then
                    eta_book_epoch = now + math.floor(doc_left * avg + 0.5)
                end
            end
        end
    end

    -- Finish-date projection for %book_finish_date. Calendar projection (not
    -- clock-time) based on the user's average reading time per day on this
    -- book. Formula matches statistics.koplugin/main.lua:1641-1643:
    --   time_to_read = pages_left * avg_time                  (seconds)
    --   seconds_per_day = book_read_time / distinct_reading_days
    --   days_to_finish = ceil(time_to_read / seconds_per_day)
    -- Auto-hides (empty string) when any input is missing — fresh books with
    -- no recorded reading time can't yield a meaningful projection.
    local book_finish_epoch
    if needs("book_finish_date") and pageno and doc and ui.statistics then
        local avg = ui.statistics.avg_time
        local book_read_time = ui.statistics.book_read_time
        local total_days = Tokens._readBookDistinctReadingDays(ui, stats_cache)
        local doc_left = doc:getTotalPagesLeft(pageno)
        if avg and avg > 0
                and book_read_time and book_read_time > 0
                and total_days and total_days > 0
                and doc_left and doc_left > 0 then
            local time_to_read = doc_left * avg
            local seconds_per_day = book_read_time / total_days
            local days_to_finish = math.ceil(time_to_read / seconds_per_day)
            book_finish_epoch = os.time() + days_to_finish * 86400
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
        if needs("date") then date_short = formatLocalizedDate("%d %b") end
        if needs("date_long") then date_long = formatLocalizedDate("%d %B %Y") end
        if needs("date_numeric") then date_num = os.date("%d/%m/%Y") end
        if needs("weekday") then date_weekday = formatLocalizedDate("%A") end
        if needs("weekday_short") then date_weekday_short = formatLocalizedDate("%a") end
    end

    -- Session reading time (skip-aware via ReaderStatistics with fallback
    -- to wall-clock when stats is disabled). Always renders — a zero
    -- duration formats as "0m"/"00:00"/"0'" rather than blanking, so the
    -- containing line stays visible while time accrues. Output respects
    -- duration_format (Settings → Device → Time and date).
    local session_time = ""
    if needs("session_time") then
        local stats_session = Tokens._readStatsBookSession(ui, stats_cache)
        local secs
        if stats_session then
            secs = stats_session.duration or 0
        else
            secs = session_elapsed or 0
        end
        local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
        session_time = datetime.secondsToClockDuration(user_duration_format, secs, true)
    end

    -- Today's totals (across all books) from ReaderStatistics. Single
    -- call covers both pages_today and time_today; gate is needs(...)
    -- on either token. Always renders zeros so the line stays visible
    -- before any reading has been logged today.
    local pages_today_str = ""
    local time_today_str = ""
    if needs("pages_today", "time_today") then
        local stats_today = Tokens._readStatsToday(ui, stats_cache)
        local today_pages = (stats_today and tonumber(stats_today.pages)) or 0
        local today_dur   = (stats_today and tonumber(stats_today.duration)) or 0
        if needs("pages_today") then
            pages_today_str = tostring(math.floor(today_pages))
        end
        if needs("time_today") then
            local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
            time_today_str = datetime.secondsToClockDuration(user_duration_format, today_dur, true)
        end
    end

    -- Today, current book only. Same shape as pages_today/time_today but
    -- id_book-scoped so multi-book readers see only the book they're in.
    local pages_today_book_str = ""
    local time_today_book_str = ""
    if needs("pages_today_book", "time_today_book") then
        local now_t = os.date("*t")
        local start_today = os.time() - (now_t.hour * 3600 + now_t.min * 60 + now_t.sec)
        local s = Tokens._readStatsBookRange(ui, stats_cache, start_today, "book_today")
        local p = (s and tonumber(s.pages)) or 0
        local d = (s and tonumber(s.duration)) or 0
        if needs("pages_today_book") then
            pages_today_book_str = tostring(math.floor(p))
        end
        if needs("time_today_book") then
            local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
            time_today_book_str = datetime.secondsToClockDuration(user_duration_format, d, true)
        end
    end

    -- Last 7 days, current book. Rolling window from now.
    local pages_week_book_str = ""
    local time_week_book_str = ""
    if needs("pages_week_book", "time_week_book") then
        local since = os.time() - 7 * 86400
        local s = Tokens._readStatsBookRange(ui, stats_cache, since, "book_week")
        local p = (s and tonumber(s.pages)) or 0
        local d = (s and tonumber(s.duration)) or 0
        if needs("pages_week_book") then
            pages_week_book_str = tostring(math.floor(p))
        end
        if needs("time_week_book") then
            local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
            time_week_book_str = datetime.secondsToClockDuration(user_duration_format, d, true)
        end
    end

    -- Reading streaks: consecutive calendar days. Zero auto-hides the line
    -- on a fresh install or after a missed day.
    local streak_str = ""
    if needs("streak") then
        local n = Tokens._readStreak(ui, stats_cache, nil, "streak") or 0
        if n > 0 then streak_str = tostring(n) end
    end
    local book_streak_str = ""
    if needs("book_streak") then
        local id_book = ui.statistics and ui.statistics.id_curr_book
        if id_book then
            local n = Tokens._readStreak(ui, stats_cache, id_book, "book_streak") or 0
            if n > 0 then book_streak_str = tostring(n) end
        end
    end

    -- Lifetime aggregates from the book table (one SQL, two values).
    local total_read_time_str = ""
    local books_finished_str = ""
    if needs("total_read_time", "books_finished") then
        local s = Tokens._readStatsBookSummary(ui, stats_cache)
        if s then
            if needs("total_read_time") and s.total_time > 0 then
                local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
                total_read_time_str = datetime.secondsToClockDuration(user_duration_format, s.total_time, true)
            end
            if needs("books_finished") and s.finished_count > 0 then
                books_finished_str = tostring(s.finished_count)
            end
        end
    end

    -- Lifetime stats for the current book (instance fields, no SQL).
    local book_pages_read_str = ""
    local avg_page_time_str = ""
    if needs("book_pages_read") and ui.statistics
       and tonumber(ui.statistics.book_read_pages)
       and ui.statistics.book_read_pages > 0 then
        book_pages_read_str = tostring(math.floor(ui.statistics.book_read_pages))
    end
    if needs("avg_page_time") and ui.statistics
       and tonumber(ui.statistics.avg_time)
       and ui.statistics.avg_time > 0 then
        local avg_secs = ui.statistics.avg_time
        -- Per-page averages run 30–90 s for most readers; the clock format
        -- ("0:00:47") is awkward for sub-minute values. Render those as a
        -- compact "47s" and only fall back to the user's clock format once
        -- the average crosses a minute. Issue #38. Hard-coded "s" suffix is
        -- universal scientific abbreviation; not gettext'd to avoid pulling
        -- the i18n module into bookends_tokens.lua for one symbol.
        if avg_secs < 60 then
            avg_page_time_str = math.floor(avg_secs) .. "s"
        else
            local user_duration_format = G_reader_settings:readSetting("duration_format", "classic")
            avg_page_time_str = datetime.secondsToClockDuration(user_duration_format, avg_secs, false)
        end
    end

    local book_pct_read_str = ""
    if needs("book_pct_read") then
        local read = (ui.statistics and tonumber(ui.statistics.book_read_pages)) or 0
        local total = (doc and tonumber(doc:getPageCount())) or 0
        if total > 0 and read > 0 then
            local pct = math.min(100, math.floor((read / total) * 100))
            book_pct_read_str = tostring(pct)
        end
    end

    local days_reading_str = ""
    local pages_per_day_str = ""
    if needs("days_reading_book", "pages_per_day") then
        local days = Tokens._readBookDistinctReadingDays(ui, stats_cache) or 0
        if needs("days_reading_book") and days > 0 then
            days_reading_str = tostring(days)
        end
        if needs("pages_per_day") and days > 0 then
            local read = (ui.statistics and tonumber(ui.statistics.book_read_pages)) or 0
            if read > 0 then
                pages_per_day_str = tostring(math.floor(read / days))
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
    -- %author_count / %authors_short / %quote_source are listed here because
    -- they are DERIVED from this block's title + authors_list; without them the
    -- gate skips and they resolve empty for a template that names only them.
    if needs("title", "author", "authors",
             "author_1", "author_2", "author_3", "author_4", "author_5",
             "author_count", "authors_short", "quote_source",
             "series", "series_name", "series_num", "lang") then
        local doc_props = ui.doc_props or {}
        local ok, props = pcall(doc.getProps, doc)
        if not ok then props = {} end
        title = Tokens.stripPageCountSuffix(doc_props.display_title or props.title or "")
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

    -- Position of this file among the document files in its folder (#89), for
    -- per-chapter CBZ manga and the like. Gated on the tokens actually being
    -- used: a preset without them never triggers the directory scan. Both stay
    -- "" when the folder can't be read or the file isn't in the listing, so the
    -- line auto-hides rather than showing a broken "0/0".
    local file_num, file_count = "", ""
    if needs("file_num", "file_count") then
        local fnum, fcount = Tokens.folderPosition(ui)
        file_num = fnum and tostring(fnum) or ""
        file_count = fcount and tostring(fcount) or ""
    end

    -- Highlights and notes count
    local highlights_count = ""
    local notes_count = ""
    local bookmarks_count = ""
    if needs("highlights", "notes", "bookmarks") and ui.annotation then
        -- Counted through the vendored rule rather than KOReader's API, so the
        -- library screen (which has only a sidecar to count) cannot disagree
        -- with the reader (#348). The rule is copied FROM KOReader's
        -- getNumberOfHighlightsAndNotes and checked against it line by line,
        -- so the numbers here are unchanged.
        local counts = Semantics.annotationCounts(ui.annotation.annotations)
        if needs("highlights") then
            highlights_count = tostring(counts.highlights)
        end
        if needs("notes") then notes_count = tostring(counts.notes) end
        if needs("bookmarks") then
            bookmarks_count = tostring(counts.bookmarks)
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
        local capacity = powerd and powerd:getCapacity()
        batt_lvl = Semantics.batt(capacity)
        batt_symbol = Semantics.battIcon(
            powerd and function(charged, charging, cap)
                return powerd:getBatterySymbol(charged, charging, cap)
            end,
            powerd and powerd:isCharged(),
            powerd and powerd:isCharging(),
            capacity)
    end

    -- Wi-Fi: always renders. The bundled symbol font ships only two wifi
    -- glyphs (U+ECA8 wifi, U+ECA9 wifi-off), so "off" and "enabled-but-no-link"
    -- share the wifi-off glyph — both communicate "no working connection".
    -- Use [if:wifi=on]%wifi[/if] to hide on disabled, or [if:connected=yes] for
    -- connected-only.
    local wifi_symbol = ""
    if needs("wifi", "wifi_icon") then
        local NetworkMgr = require("ui/network/manager")
        wifi_symbol = Semantics.wifi(NetworkMgr:isWifiOn(),
                                     NetworkMgr:isConnected())
    end

    -- Frontlight on/off icon (dynamic). Lightbulb-on glyph (rays) when
    -- frontlight is on, lightbulb-outline (empty) when off.
    local light_symbol = ""
    if needs("light_icon") then
        local powerd = Device:getPowerDevice()
        light_symbol = Semantics.lightIcon(
            powerd and powerd:frontlightIntensity())
    end

    -- Night mode icon (dynamic). Moon glyph when night mode is active,
    -- sun glyph otherwise. Driven by KOReader's "night_mode" setting.
    local night_symbol = ""
    if needs("nightmode") then
        night_symbol = Semantics.nightmode(
            G_reader_settings:isTrue("night_mode"))
    end

    -- Frontlight intensity as a 0-100 percentage with "%" suffix, matching
    -- %book_pct / %chap_pct. Conditional state (state.light_pct) stays
    -- numeric for [if:light_pct>50] comparisons — that's a separate path
    -- in buildConditionState.
    local fl_intensity_pct = ""
    if needs("light_pct") then
        local pwd = Device:getPowerDevice()
        fl_intensity_pct = Semantics.lightPct(
            pwd and pwd:frontlightIntensity(), pwd and pwd.fl_max)
    end

    -- Frontlight warmth as a 0-100 percentage with "%" suffix.
    -- frontlightWarmth() is already in the KOReader 0-100 scale
    -- (powerd.lua:243), so no division is needed.
    local fl_warmth_pct = ""
    if needs("warmth_pct") then
        local pwd = Device:getPowerDevice()
        fl_warmth_pct = Semantics.warmthPct(
            pwd and pwd.frontlightWarmth and pwd:frontlightWarmth(),
            Device:hasNaturalLight())
    end

    -- Warmth icon (dynamic). Ramp thresholds and glyphs live in
    -- token_semantics so bookshelf cannot ramp differently.
    local warmth_symbol = ""
    if needs("warmth_icon") then
        local pwd = Device:getPowerDevice()
        warmth_symbol = Semantics.warmthIcon(
            pwd and pwd.frontlightWarmth and pwd:frontlightWarmth(),
            Device:hasNaturalLight())
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
            fl_intensity = Semantics.light(
                powerd and powerd:frontlightIntensity())
        end
        if needs("warmth") then
            local native
            if powerd and powerd.toNativeWarmth and powerd.frontlightWarmth then
                native = powerd:toNativeWarmth(powerd:frontlightWarmth())
            end
            fl_warmth = Semantics.warmth(native, Device:hasNaturalLight())
        end
    end

    -- Memory usage (system-wide percentage)
    local mem_usage = ""
    if needs("mem") then
        local meminfo = io.open("/proc/meminfo", "r")
        if meminfo then
            local total, memfree, buffers, cached, available
            for line in meminfo:lines() do
                if line:match("^MemTotal:") then
                    total = tonumber(line:match("(%d+)"))
                elseif line:match("^MemAvailable:") then
                    available = tonumber(line:match("(%d+)"))
                elseif line:match("^MemFree:") then
                    memfree = tonumber(line:match("(%d+)"))
                elseif line:match("^Buffers:") then
                    buffers = tonumber(line:match("(%d+)"))
                elseif line:match("^Cached:") then
                    cached = tonumber(line:match("(%d+)"))
                end
                if total and available then break end
            end
            meminfo:close()
            -- Fallback for kernels without MemAvailable (e.g. Kindle KPW3 2.6.x)
            if total and not available and memfree then
                available = memfree + (buffers or 0) + (cached or 0)
            end
            if total and available and total > 0 then
                mem_usage = Semantics.mem(total, available)
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
            local rss = line and line:match("%S+%s+(%d+)")
            -- statm reports PAGES; Semantics.ram takes kilobytes.
            ram_mb = Semantics.ram(rss and tonumber(rss) * 4)
        end
    end

    -- Disk available
    local disk_avail = ""
    if needs("disk") then
        local util = require("util")
        if util.diskUsage then
            local drive = Device.home_dir or "/"
            local ok, usage = pcall(util.diskUsage, drive)
            if ok and usage then disk_avail = Semantics.disk(usage.available) end
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

    -- ── Per-book metadata ported from bookshelf (#348) ────────────────────
    -- Formatting goes through the vendored token_semantics so the same book
    -- reads the same on the shelf and in the reader. Each source is reached
    -- defensively: on a reader every one of these can be legitimately absent
    -- (no DocSettings yet, no highlights, no read history), and the right
    -- answer then is an empty string so the line auto-hides.
    local status_str, status_label_str = "", ""
    local rating_stars, rating_num = "", ""
    if needs("status", "status_label", "rating", "rating_number") then
        local summary
        local ds = ui.doc_settings
        if ds and ds.readSetting then
            local ok, v = pcall(function() return ds:readSetting("summary") end)
            if ok and type(v) == "table" then summary = v end
        end
        status_str = Semantics.status(summary and summary.status)
        status_label_str = Semantics.statusLabel(status_str, STATUS_LABELS)
        local r = summary and tonumber(summary.rating)
        rating_stars = Semantics.stars(r)
        rating_num = (r and r > 0) and tostring(math.floor(r)) or ""
    end

    local description_str = ""
    if needs("description") then
        local doc_props = ui.doc_props or {}
        local ok, props = pcall(doc.getProps, doc)
        if not ok then props = {} end
        local raw = doc_props.description or props.description or ""
        -- A <dc:description> is HTML. Untreated it renders literally - a
        -- device screenshot showed "<p>The first ever collection of..." on the
        -- status line. Bookshelf has always sanitised this; the port in
        -- 85aa7c8 took the token and left the sanitiser behind, so it now
        -- lives in the vendored module where only one copy can exist.
        description_str = Semantics.cleanDescription(raw)
        -- Then flatten: cleanDescription keeps paragraph breaks, which is
        -- right for bookshelf's hero card and wrong for a status line, where
        -- an embedded \n starts a new visual row and would silently push the
        -- rest of the overlay around. One line, single-spaced.
        description_str = description_str:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    end

    local size_str, added_str, opened_str = "", "", ""
    if needs("size", "added") then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        local file = doc and doc.file
        if ok_lfs and lfs and lfs.attributes and file then
            if needs("size") then
                local ok, v = pcall(lfs.attributes, file, "size")
                if ok then size_str = Semantics.fileSize(tonumber(v)) or "" end
            end
            if needs("added") then
                -- Mirrors bookshelf's date_added, which is the file mtime.
                local ok, v = pcall(lfs.attributes, file, "modification")
                if ok then added_str = Semantics.isoDate(tonumber(v)) or "" end
            end
        end
    end
    if needs("opened") then
        -- Mirrors bookshelf: ReadHistory, not the file mtime. A book absent
        -- from the history has no date rather than a date in 1970.
        local ok_rh, ReadHistory = pcall(require, "readhistory")
        local file = doc and doc.file
        if ok_rh and ReadHistory and file then
            for _idx, item in ipairs(ReadHistory.hist or {}) do
                if item.file == file then
                    opened_str = Semantics.isoDate(tonumber(item.time)) or ""
                    break
                end
            end
        end
    end

    local favourite_str = ""
    if needs("favourite", "favorite") then
        local ok_rc, ReadCollection = pcall(require, "readcollection")
        local file = doc and doc.file
        if ok_rc and ReadCollection and file then
            local fav = ReadCollection.coll and ReadCollection.coll.favorites
            if fav and fav[file] ~= nil then
                favourite_str = "\xE2\x98\x85"  -- U+2605, matching %rating's filled star
            end
        end
    end

    local author_count_str, authors_short_str = "", ""
    if needs("author_count", "authors_short") then
        if #authors_list > 0 then
            author_count_str = tostring(#authors_list)
            authors_short_str = Semantics.authorsShort(
                authors_list, T(" and "), T(", et al."))
        end
    end

    -- %quote / %quote_source: a highlight from THIS book. Deterministic (the
    -- first highlight) rather than rotating: a status bar repaints constantly,
    -- and a quote that changed on every repaint would be unreadable. Bookshelf
    -- rotates its quote per selected book, which has no analogue here.
    local quote_str, quote_source_str = "", ""
    if needs("quote", "quote_source") then
        local ann = ui.annotation
        for _idx, item in ipairs((ann and ann.annotations) or {}) do
            if type(item.text) == "string" and item.text ~= "" then
                quote_str = "\xE2\x80\x9C" .. item.text .. "\xE2\x80\x9D"
                local bits = {}
                if title and title ~= "" then bits[#bits + 1] = tostring(title) end
                if first_author and first_author ~= "" then
                    bits[#bits + 1] = first_author
                end
                quote_source_str = table.concat(bits, ", ")
                break
            end
        end
    end

    local sysused_str = ""
    if needs("sysused") then
        local meminfo = io.open("/proc/meminfo", "r")
        if meminfo then
            local total, available, memfree, buffers, cached
            for line in meminfo:lines() do
                if line:match("^MemTotal:") then total = tonumber(line:match("(%d+)"))
                elseif line:match("^MemAvailable:") then available = tonumber(line:match("(%d+)"))
                elseif line:match("^MemFree:") then memfree = tonumber(line:match("(%d+)"))
                elseif line:match("^Buffers:") then buffers = tonumber(line:match("(%d+)"))
                elseif line:match("^Cached:") then cached = tonumber(line:match("(%d+)")) end
            end
            meminfo:close()
            -- Fallback for kernels without MemAvailable (e.g. Kindle KPW3 2.6.x).
            -- MemFree alone badly overstates usage on a small device: the kernel
            -- caches nearly all otherwise-free RAM for file I/O, but that cache is
            -- reclaimable and available to us. Same shape as the %mem fallback
            -- above, so the two parsers cannot drift apart again.
            if total and not available and memfree then
                available = memfree + (buffers or 0) + (cached or 0)
            end
            if total and available and total > 0 then
                -- /proc/meminfo is in kB; Semantics.sysused takes bytes used.
                sysused_str = Semantics.sysused((total - available) * 1024)
            end
        end
    end

    -- Replace the elastic tokens with placeholders so the renderer knows where
    -- to put the widget. Both %bar and %spacer take "whatever width is left",
    -- so a line can only honour ONE of them:
    --   * %bar wins if present, being the older and more visible feature;
    --   * otherwise the FIRST %spacer becomes the gap;
    --   * every other occurrence is stripped, never left as literal text -
    --     a reader who wrote two of them should see a sensible line, not the
    --     word "spacer" sitting in the middle of it.
    local result_str = format_str
    if has_bar then
        result_str = result_str:gsub("%%bar", BAR_PLACEHOLDER)
        if has_spacer then
            result_str = result_str:gsub("%%spacer", "")
        end
    elseif has_spacer then
        result_str = result_str:gsub("%%spacer", SPACER_PLACEHOLDER, 1)
        result_str = result_str:gsub("%%spacer", "")
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
        -- Last-digit variants of the numeric page/chapter tokens (#55).
        -- Expose the units digit so format strings can branch on it for
        -- languages with vowel harmony or number-shape agreement
        -- (Hungarian -ból/-ből, Finnish partitive, etc.). Empty string
        -- when the underlying value isn't a number (e.g. roman-numeral
        -- pagemap labels).
        page_num_lastdigit         = Tokens.lastDigit(currentpage),
        page_count_lastdigit       = Tokens.lastDigit(totalpages),
        pages_left_lastdigit       = Tokens.lastDigit(pages_left_book),
        chap_read_lastdigit        = Tokens.lastDigit(chapter_pages_done),
        chap_pages_lastdigit       = Tokens.lastDigit(chapter_total_pages),
        chap_pages_left_lastdigit  = Tokens.lastDigit(chapter_pages_left),
        -- Time/Reading
        chap_time_left = tostring(time_left_chapter),
        book_time_left = tostring(time_left_doc),
        chap_time_left_h   = chap_time_left_h and tostring(chap_time_left_h) or "",
        chap_time_left_m = chap_time_left_m and tostring(chap_time_left_m) or "",
        book_time_left_h   = book_time_left_h and tostring(book_time_left_h) or "",
        book_time_left_m = book_time_left_m and tostring(book_time_left_m) or "",
        chap_time_left_eta = formatEtaEpoch(eta_chap_epoch, date_formats.chap_time_left_eta),
        book_time_left_eta = formatEtaEpoch(eta_book_epoch, date_formats.book_time_left_eta),
        book_finish_date   = formatFinishDate(book_finish_epoch, date_formats.book_finish_date),
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
        pages_today      = pages_today_str,
        time_today       = time_today_str,
        pages_today_book = pages_today_book_str,
        time_today_book  = time_today_book_str,
        pages_week_book  = pages_week_book_str,
        time_week_book   = time_week_book_str,
        streak           = streak_str,
        book_streak      = book_streak_str,
        total_read_time  = total_read_time_str,
        books_finished   = books_finished_str,
        book_pages_read   = book_pages_read_str,
        avg_page_time     = avg_page_time_str,
        book_pct_read     = book_pct_read_str,
        days_reading_book = days_reading_str,
        pages_per_day     = pages_per_day_str,
        -- Metadata
        title       = tostring(title),
        author      = first_author,
        authors     = authors,
        author_1    = authors_list[1] or "",
        -- Ported from bookshelf for #348.
        author_count  = author_count_str,
        authors_short = authors_short_str,
        status        = status_str,
        status_label  = status_label_str,
        rating        = rating_stars,
        rating_number = rating_num,
        description   = description_str,
        size          = size_str,
        added         = added_str,
        opened        = opened_str,
        favourite     = favourite_str,
        favorite      = favourite_str,   -- US spelling alias, as in bookshelf
        quote         = quote_str,
        quote_source  = quote_source_str,
        sysused       = sysused_str,
        author_2    = authors_list[2] or "",
        author_3    = authors_list[3] or "",
        author_4    = authors_list[4] or "",
        author_5    = authors_list[5] or "",
        series      = tostring(series),
        series_name = tostring(series_name or ""),   -- populated in Task 10
        series_num  = tostring(series_num or ""),    -- populated in Task 10
        chap_title      = tostring(chapter_title),
        chap_title_num  = tostring(chapter_title_num or ""),
        chap_title_name = tostring(chapter_title_name or ""),
        filename    = file_name,
        file_num    = file_num,
        file_count  = file_count,
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
        -- Same glyph under bookshelf's name for it, so a template copied
        -- across resolves instead of printing the literal token (#348).
        wifi_icon   = wifi_symbol,
        plugin_content = plugin_content,
        light     = fl_intensity,
        light_icon = light_symbol,
        light_pct = fl_intensity_pct,
        warmth    = fl_warmth,
        warmth_pct = fl_warmth_pct,
        warmth_icon = warmth_symbol,
        nightmode = night_symbol,
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
        chap_time_left = true, book_time_left = true,
        chap_time_left_h = true, chap_time_left_m = true,
        book_time_left_h = true, book_time_left_m = true,
        chap_time_left_eta = true, book_time_left_eta = true,
        book_finish_date = true,
        time_12h = true, time_24h = true,
        time = true,
        session_time = true, session_pages = true, speed = true,
        -- _lastdigit tokens (#55): "0" is a real value (last digit of 10,
        -- 20, …); without this gate it would auto-hide and the conditional
        -- grammar branching on the digit would break.
        page_num_lastdigit = true, page_count_lastdigit = true,
        pages_left_lastdigit = true, chap_read_lastdigit = true,
        chap_pages_lastdigit = true, chap_pages_left_lastdigit = true,
    }
    -- Per-token occurrence counters for matching limits
    local token_occurrence = {}
    -- Bareword pass runs BEFORE the depth-specific chap_title_N pass. If we
    -- expanded %chap_title_1 first, its title text would inline directly
    -- next to any preceding bareword token (e.g. %nightmode%chap_title_1
    -- → %nightmodePart I), and the bareword regex would then greedily
    -- match "%nightmodePart" as one unknown identifier and leave it as
    -- literal text. Running bareword first leaves "%chap_title_1" intact
    -- (chap_title_1 isn't in the replace dict, so it returns "%"..ident),
    -- and the subsequent chap_title_N pass picks it up cleanly. Adjacent
    -- baretoken pairs like %light%warmth already worked because the "%"
    -- boundary between them stops the [%w_]* class on first match.
    local result = result_str:gsub("%%([%a_][%w_]*)", function(ident)
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
    -- Depth-specific chapter tokens (%chap_title_1..3). Legacy %C1/%C2/%C3
    -- are rewritten to %chap_title_1/2/3 by the alias pass at the top of
    -- expand().
    result = result:gsub("%%chap_title_(%d)", function(depth_str)
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

    -- Depth-variant chapter progress (%chap_read_1, %chap_pct_2, …; issue #85).
    -- Values come from the plugin's own TOC walk (getChapterProgressByDepth) so
    -- they can be scoped to any TOC depth, unlike the flat tokens which only see
    -- the deepest chapter. Falls back to the flat values when no depth range is
    -- available (chapterless book / page before the first entry), so
    -- %chap_read_<maxdepth> tracks %chap_read.
    local depth_chap_cache = {}
    local function depthChap(depth_str)
        local d = tonumber(depth_str)
        local cached = depth_chap_cache[d]
        if cached ~= nil then return cached or nil end
        local prog = Tokens.getChapterProgressByDepth(ui, pageno, d)
        depth_chap_cache[d] = prog or false
        return prog
    end
    local function emitDepth(base, depth_str, val)
        has_token = true
        if val ~= "" and val ~= "0" then all_empty = false end
        local key = "%" .. base .. "_" .. depth_str
        if token_limits[key] then
            token_occurrence[key] = (token_occurrence[key] or 0) + 1
            local px = token_limits[key][token_occurrence[key]]
            if px then
                return "\x01" .. tostring(px) .. "\x02" .. val .. "\x03"
            end
        end
        return val
    end
    -- "_left" variants run first so their trailing digit isn't misparsed
    -- (the digit anchor already prevents cross-matching, but keep it explicit).
    result = result:gsub("%%chap_pages_left_(%d)", function(depth_str)
        local p = depthChap(depth_str)
        return emitDepth("chap_pages_left", depth_str,
            p and tostring(p.pages_left) or tostring(chapter_pages_left))
    end)
    result = result:gsub("%%chap_pct_left_(%d)", function(depth_str)
        local p = depthChap(depth_str)
        return emitDepth("chap_pct_left", depth_str,
            p and (tostring(p.pct_left) .. "%") or tostring(chapter_pct_left))
    end)
    result = result:gsub("%%chap_pages_(%d)", function(depth_str)
        local p = depthChap(depth_str)
        return emitDepth("chap_pages", depth_str,
            p and tostring(p.pages) or tostring(chapter_total_pages))
    end)
    result = result:gsub("%%chap_pct_(%d)", function(depth_str)
        local p = depthChap(depth_str)
        return emitDepth("chap_pct", depth_str,
            p and (tostring(p.pct) .. "%") or tostring(chapter_pct))
    end)
    result = result:gsub("%%chap_read_(%d)", function(depth_str)
        local p = depthChap(depth_str)
        return emitDepth("chap_read", depth_str,
            p and tostring(p.read) or tostring(chapter_pages_done))
    end)
    -- Depth-variant chapter time-left. Minutes via the statistics plugin;
    -- eta = now + pages_left_N × avg_time. The eta pass runs first so the plain
    -- pass doesn't consume "%chap_time_left_1" out of "%chap_time_left_1_eta{…}".
    -- Both render empty (auto-hide) when statistics are unavailable or no depth
    -- range applies — depth time is inherently a with-TOC feature.
    result = result:gsub("%%chap_time_left_(%d)_eta(%b{})", function(depth_str, brace)
        has_token = true
        local p = depthChap(depth_str)
        local avg = ui.statistics and ui.statistics.avg_time
        if p and avg and avg > 0 then
            local epoch = os.time() + math.floor(p.pages_left * avg + 0.5)
            local val = formatEtaEpoch(epoch, brace:sub(2, -2))
            if val ~= "" then all_empty = false end
            return val
        end
        return ""
    end)
    result = result:gsub("%%chap_time_left_(%d)", function(depth_str)
        local p = depthChap(depth_str)
        local val = ""
        if p and ui.statistics and ui.statistics.getTimeForPages then
            local r = ui.statistics:getTimeForPages(math.max(0, p.pages_left))
            if r and r ~= "N/A" then val = r end
        end
        return emitDepth("chap_time_left", depth_str, val)
    end)

    -- #92: all token expansion is done; drop the %<token> boundary sentinels
    -- before the remaining text transforms (pluralisation, PUA colour) run.
    result = result:gsub("\4", "")

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
-- they are exposed solely so tests/_test_conditionals.lua can exercise the parser
-- without needing a running KOReader. Not stable API; may change without notice.
Tokens._processConditionals = processConditionals
Tokens._evaluateCondition   = evaluateCondition
Tokens._evaluateExpression  = evaluateExpression
Tokens._rewriteLegacyTokens = rewriteLegacyTokens
Tokens._parseChapNumPrefix       = parseChapNumPrefix
Tokens._computeStripPrefixByDepth = computeStripPrefixByDepth

return Tokens
