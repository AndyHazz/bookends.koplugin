-- Dev-box test runner for bookends_tokens.lua token vocabulary + grammar.
-- Runs pure-Lua (no KOReader) by stubbing the modules bookends_tokens requires.
-- Usage: cd into the plugin dir, then `lua tests/_test_tokens.lua`.
-- Exits non-zero on failure; no external dependencies.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function() return "" end,
}
package.loaded["bookends_overlay_widget"] = { BAR_PLACEHOLDER = "\x00BAR\x00" }

-- G_reader_settings is a global in KOReader; stub it so module load succeeds.
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
    readSetting = function() return "classic" end,
    isTrue = function() return false end,
})

local Tokens = dofile("bookends_tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "")
            .. " expected=" .. string.format("%q", tostring(expected))
            .. " got="      .. string.format("%q", tostring(actual)), 2)
    end
end

-- ============================================================================
-- Smoke test: harness works and Tokens module loaded.
-- ============================================================================
test("smoke: Tokens module loads", function()
    assert(type(Tokens) == "table", "Tokens is not a table")
    assert(type(Tokens.expand) == "function", "Tokens.expand missing")
end)

-- ============================================================================
-- Legacy token rewrite (TOKEN_ALIAS)
-- ============================================================================
test("rewrite: %A → %author", function()
    eq(Tokens._rewriteLegacyTokens("%A"), "%author")
end)

test("rewrite: %J → %chap_count", function()
    eq(Tokens._rewriteLegacyTokens("%J"), "%chap_count")
end)

test("rewrite: %C1 → %chap_title_1", function()
    eq(Tokens._rewriteLegacyTokens("%C1"), "%chap_title_1")
end)

test("rewrite: %C2 → %chap_title_2", function()
    eq(Tokens._rewriteLegacyTokens("%C2"), "%chap_title_2")
end)

test("rewrite preserves braces: %A{200} → %author{200}", function()
    eq(Tokens._rewriteLegacyTokens("%A{200}"), "%author{200}")
end)

test("rewrite preserves braces: %C1{300} → %chap_title_1{300}", function()
    eq(Tokens._rewriteLegacyTokens("%C1{300}"), "%chap_title_1{300}")
end)

test("rewrite idempotent: %author unchanged", function()
    eq(Tokens._rewriteLegacyTokens("%author"), "%author")
end)

test("rewrite idempotent: %chap_title_1 unchanged", function()
    eq(Tokens._rewriteLegacyTokens("%chap_title_1"), "%chap_title_1")
end)

test("rewrite mixed: '%A — %title' → '%author — %title'", function()
    eq(Tokens._rewriteLegacyTokens("%A — %title"), "%author — %title")
end)

test("rewrite leaves unknown tokens alone: %zzz unchanged", function()
    eq(Tokens._rewriteLegacyTokens("%zzz"), "%zzz")
end)

test("rewrite leaves literal % alone: 100%% unchanged", function()
    -- %% in a format string is literal %; our rewrite should not touch it.
    eq(Tokens._rewriteLegacyTokens("100%% read"), "100%% read")
end)

test("rewrite handles all legacy single-letter aliases", function()
    local cases = {
        {"%c", "%page_num"}, {"%t", "%page_count"}, {"%p", "%book_pct"},
        {"%P", "%chap_pct"}, {"%g", "%chap_read"}, {"%G", "%chap_pages"},
        {"%l", "%chap_pages_left"}, {"%L", "%pages_left"},
        {"%j", "%chap_num"}, {"%J", "%chap_count"},
        {"%T", "%title"}, {"%A", "%author"}, {"%S", "%series"},
        {"%C", "%chap_title"}, {"%N", "%filename"}, {"%i", "%lang"},
        {"%o", "%format"}, {"%q", "%highlights"}, {"%Q", "%notes"},
        {"%x", "%bookmarks"}, {"%X", "%annotations"},
        {"%k", "%time_12h"}, {"%K", "%time_24h"},
        {"%d", "%date"}, {"%D", "%date_long"}, {"%n", "%date_numeric"},
        {"%w", "%weekday"}, {"%a", "%weekday_short"},
        {"%R", "%session_time"}, {"%s", "%session_pages"},
        {"%r", "%speed"}, {"%E", "%book_read_time"},
        {"%h", "%chap_time_left"}, {"%H", "%book_time_left"},
        {"%b", "%batt"}, {"%B", "%batt_icon"},
        {"%W", "%wifi"}, {"%V", "%invert"},
        {"%f", "%light"}, {"%F", "%warmth"},
        {"%m", "%mem"}, {"%M", "%ram"}, {"%v", "%disk"},
    }
    for _i, pair in ipairs(cases) do
        eq(Tokens._rewriteLegacyTokens(pair[1]), pair[2], "case " .. pair[1])
    end
end)

-- ============================================================================
-- STATE_ALIAS: legacy predicate names resolve to new state keys
-- ============================================================================
test("state alias: [if:chapters>10] reads state.chap_count", function()
    local r = Tokens._processConditionals(
        "[if:chapters>10]many[/if]", { chap_count = 15 })
    eq(r, "many")
end)

test("state alias: [if:chapter_title] reads state.chap_title", function()
    local r = Tokens._processConditionals(
        "[if:chapter_title]has[/if]", { chap_title = "Chapter 1" })
    eq(r, "has")
end)

test("state alias: [if:chapter_title_2] reads state.chap_title_2", function()
    local r = Tokens._processConditionals(
        "[if:chapter_title_2]sub[/if]", { chap_title_2 = "Sub" })
    eq(r, "sub")
end)

test("state alias: mixed predicate '[if:chapters>10 and chap_pct>50]' works", function()
    local r = Tokens._processConditionals(
        "[if:chapters>10 and chap_pct>50]both[/if]",
        { chap_count = 15, chap_pct = 75 })
    eq(r, "both")
end)

test("state alias: [if:percent>50] reads state.book_pct (pre-v4.1 gallery compat)", function()
    local r = Tokens._processConditionals(
        "[if:percent>50]past[/if]", { book_pct = 75 })
    eq(r, "past")
end)

test("state alias: [if:pages>20] reads state.session_pages (pre-v4.1 gallery compat)", function()
    local r = Tokens._processConditionals(
        "[if:pages>20]long[/if]", { session_pages = 30 })
    eq(r, "long")
end)

test("state alias: [if:percent<=50] reads state.book_pct with < operator", function()
    local r = Tokens._processConditionals(
        "[if:percent<50]early[/if]", { book_pct = 25 })
    eq(r, "early")
end)

test("state alias: [if:pages<=10] false with < operator", function()
    local r = Tokens._processConditionals(
        "[if:pages<10]short[/if]", { session_pages = 20 })
    eq(r, "")
end)

test("state alias: new key [if:book_pct>50] direct access still works", function()
    local r = Tokens._processConditionals(
        "[if:book_pct>50]past[/if]", { book_pct = 75 })
    eq(r, "past")
end)

test("state alias: new key [if:session_pages>20] direct access still works", function()
    local r = Tokens._processConditionals(
        "[if:session_pages>20]long[/if]", { session_pages = 30 })
    eq(r, "long")
end)

test("state alias: [if:title=chapters] preserves literal value 'chapters'", function()
    -- The key 'title' isn't aliased; value 'chapters' must NOT be rewritten.
    local r = Tokens._processConditionals(
        "[if:title=chapters]match[/if]", { title = "chapters" })
    eq(r, "match")
end)

test("state alias: combined legacy predicates with aliased keys", function()
    local r = Tokens._processConditionals(
        "[if:percent>50 and pages>20]both[/if]",
        { book_pct = 75, session_pages = 30 })
    eq(r, "both")
end)

-- ============================================================================
-- canonicaliseLegacy: tokens + predicate keys rewritten; values preserved
-- ============================================================================
test("canon: token rewrite '%A — %title' → '%author — %title'", function()
    eq(Tokens.canonicaliseLegacy("%A — %title"), "%author — %title")
end)

test("canon: predicate key rewrite '[if:chapters>10]' → '[if:chap_count>10]'", function()
    eq(Tokens.canonicaliseLegacy("[if:chapters>10]ok[/if]"),
       "[if:chap_count>10]ok[/if]")
end)

test("canon: multi-key predicate '[if:chapters>10 and percent>50]'", function()
    eq(Tokens.canonicaliseLegacy("[if:chapters>10 and percent>50]x[/if]"),
       "[if:chap_count>10 and book_pct>50]x[/if]")
end)

test("canon: literal string value 'chapters' preserved in '[if:title=chapters]'", function()
    eq(Tokens.canonicaliseLegacy("[if:title=chapters]t[/if]"),
       "[if:title=chapters]t[/if]")
end)

test("canon: nested [if] blocks both rewritten", function()
    eq(Tokens.canonicaliseLegacy("[if:chapters>10][if:percent>50]x[/if][/if]"),
       "[if:chap_count>10][if:book_pct>50]x[/if][/if]")
end)

test("canon: [if:not chapters] keeps 'not' keyword, rewrites key", function()
    eq(Tokens.canonicaliseLegacy("[if:not chapters]empty[/if]"),
       "[if:not chap_count]empty[/if]")
end)

test("canon: idempotent — running twice gives same result", function()
    local once = Tokens.canonicaliseLegacy("%A [if:chapters>10]%J[/if]")
    local twice = Tokens.canonicaliseLegacy(once)
    eq(twice, once)
end)

test("canon: mixed legacy + new — new names untouched", function()
    eq(Tokens.canonicaliseLegacy("%author — %A"), "%author — %author")
end)

test("canon: empty string returns empty string", function()
    eq(Tokens.canonicaliseLegacy(""), "")
end)

test("canon: string without any tokens or predicates unchanged", function()
    eq(Tokens.canonicaliseLegacy("Just plain text."), "Just plain text.")
end)

-- ============================================================================
-- Brace grammar regression: existing forms must keep working after refactor
-- ============================================================================
-- expandPreview uses symbolic placeholders, so stable across devices.

test("brace: '%bar' in preview renders ▰▰▱▱ (12 bytes)", function()
    local r = Tokens.expandPreview("%bar", { view = {} }, nil, nil, 2, nil)
    eq(#r, 12, "expected 4 box-chars = 12 bytes")
end)

test("brace: '%bar{100}' preview contains '100'", function()
    local r = Tokens.expandPreview("%bar{100}", { view = {} }, nil, nil, 2, nil)
    assert(r:find("100", 1, true), "expected '100' in preview: " .. r)
end)

test("brace: '%T{200}' preview contains '200'", function()
    local r = Tokens.expandPreview("%T{200}", { view = {} }, nil, nil, 2, nil)
    assert(r:find("200", 1, true), "expected '200' in preview: " .. r)
end)

test("brace: '%C1{300}' preview contains '300'", function()
    local r = Tokens.expandPreview("%C1{300}", { view = {} }, nil, nil, 2, nil)
    assert(r:find("300", 1, true), "expected '300' in preview: " .. r)
end)

-- ============================================================================
-- %datetime{...} strftime escape hatch
-- ============================================================================
test("datetime: %datetime{%Y} expands to current year", function()
    local year = os.date("%Y")
    local r = Tokens.expandPreview("%datetime{%Y}", { view = {} }, nil, nil, 2, nil)
    eq(r, year)
end)

test("datetime: %datetime{%H:%M} expands to HH:MM clock", function()
    local r = Tokens.expandPreview("%datetime{%H:%M}", { view = {} }, nil, nil, 2, nil)
    assert(r:match("^%d+:%d%d$"), "expected HH:MM, got: " .. r)
end)

test("datetime: %datetime{%d %B} expands to day + full month", function()
    local expected = os.date("%d %B")
    local r = Tokens.expandPreview("%datetime{%d %B}", { view = {} }, nil, nil, 2, nil)
    eq(r, expected)
end)

test("datetime: bare %datetime falls through as literal", function()
    local r = Tokens.expandPreview("%datetime", { view = {} }, nil, nil, 2, nil)
    eq(r, "%datetime")
end)

test("datetime: mixed with literal text", function()
    local year = os.date("%Y")
    local r = Tokens.expandPreview("Year: %datetime{%Y}",
        { view = {} }, nil, nil, 2, nil)
    eq(r, "Year: " .. year)
end)

-- ============================================================================
-- (More tests added by subsequent tasks.)
-- ============================================================================

-- ============================================================================
-- buildConditionState populates v5 state key names
-- ============================================================================
-- Build a minimal stub ui/doc/toc that exercises the chapter-state path.
local function stubUi(page, total_pages, chapter_data)
    return {
        view = { state = { page = page } },
        document = {
            file = "/book.epub",
            getPageCount = function() return total_pages end,
            hasHiddenFlows = function() return false end,
            getProps = function() return {} end,
        },
        toc = chapter_data and {
            toc = chapter_data.toc,
            getTocTitleByPage = function(_, _) return chapter_data.title or "" end,
            getTocTicks = function() return {} end,
            getMaxDepth = function() return 1 end,
            getPreviousChapter = function(_, _) return chapter_data.start end,
            getNextChapter = function(_, _) return chapter_data.next end,
            isChapterStart = function(_, _) return false end,
            getChapterPagesDone = function(_, _) return 0 end,
            getChapterPageCount = function(_, _) return 1 end,
            getChapterPagesLeft = function(_, _) return 0 end,
        } or nil,
        doc_props = {},
        annotation = nil,
        statistics = nil,
    }
end

test("state: chap_num / chap_count populated (new v5 names)", function()
    local ui = stubUi(5, 100, {
        toc = { { page = 1, depth = 1, title = "C1" }, { page = 10, depth = 1, title = "C2" } },
        start = 1, next = 10,
    })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.chap_num, 1, "chap_num")
    eq(s.chap_count, 2, "chap_count")
    eq(s.chapter_num, nil, "chapter_num should not be set on new-vocab state")
    eq(s.chapters, nil, "chapters should not be set on new-vocab state")
end)

test("state: chap_title / chap_title_1 populated (new v5 names)", function()
    local ui = stubUi(5, 100, {
        toc = { { page = 1, depth = 1, title = "C1" } },
        title = "C1",
        start = 1, next = 10,
    })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.chap_title, "C1")
    eq(s.chap_title_1, "C1")
    eq(s.chapter_title, nil, "chapter_title should not be set on new-vocab state")
end)

test("state: legacy [if:chapters>0] still evaluates via STATE_ALIAS", function()
    local ui = stubUi(5, 100, {
        toc = { { page = 1, depth = 1, title = "C1" }, { page = 10, depth = 1, title = "C2" } },
        start = 1, next = 10,
    })
    local s = Tokens.buildConditionState(ui, 0, 0)
    -- Even though state.chapters is nil, the predicate still works via alias.
    local r = Tokens._processConditionals("[if:chapters>0]ok[/if]", s)
    eq(r, "ok")
end)

-- ============================================================================
-- v5 token names resolve through the full Tokens.expand pipeline
-- ============================================================================
-- A richer stubUi for expansion tests — covers doc props + pageno.
local function stubUiForExpand()
    return {
        view = { state = { page = 5 } },
        document = {
            file = "/Foundation.epub",
            getPageCount = function() return 100 end,
            hasHiddenFlows = function() return false end,
            getProps = function()
                return { title = "Foundation", authors = "Isaac Asimov",
                         series = "Foundation", series_index = 1 }
            end,
        },
        doc_props = { display_title = "Foundation", authors = "Isaac Asimov",
                      series = "Foundation", series_index = 1 },
        toc = nil,
        pagemap = nil,
        annotation = nil,
        statistics = nil,
    }
end

-- Builds a UI stub with a configurable mock ui.statistics. Pass a `stats`
-- table whose fields override the defaults below. Setting any field to
-- `false` removes it (useful for testing nil-guard fallbacks).
local function stubUiWithStats(stats)
    stats = stats or {}
    local function pick(k, default)
        if stats[k] == false then return nil end
        if stats[k] == nil then return default end
        return stats[k]
    end
    local id_curr_book = pick("id_curr_book", 1)
    local cur_pages    = pick("current_pages", 0)
    local cur_duration = pick("current_duration", 0)
    local today_pages    = pick("today_pages", 0)
    local today_duration = pick("today_duration", 0)
    -- Pre-populate the first-open cache for this book if a value is provided.
    if stats.first_open_ts and id_curr_book then
        Tokens._first_open_cache = Tokens._first_open_cache or {}
        Tokens._first_open_cache[id_curr_book] = stats.first_open_ts
    end
    return {
        view = { state = { page = 5 } },
        document = {
            file = "/book.epub",
            getPageCount = function() return pick("page_count", 100) end,
            hasHiddenFlows = function() return false end,
            getProps = function() return {} end,
        },
        doc_props = {},
        toc = nil,
        annotation = nil,
        statistics = {
            id_curr_book    = id_curr_book,
            book_read_pages = pick("book_read_pages", 0),
            book_read_time  = pick("book_read_time", 0),
            avg_time        = pick("avg_time", 0),
            mem_read_pages  = pick("mem_read_pages", 0),
            mem_read_time   = pick("mem_read_time", 0),
            getCurrentBookStats = function(_)
                return cur_duration, cur_pages
            end,
            getTodayBookStats = function(_)
                return today_duration, today_pages
            end,
        },
    }
end

test("stats stub: smoke — getCurrentBookStats returns injected values", function()
    local ui = stubUiWithStats({ current_pages = 7, current_duration = 600 })
    local d, p = ui.statistics:getCurrentBookStats()
    eq(p, 7, "pages")
    eq(d, 600, "duration")
end)

test("stats stub: smoke — getTodayBookStats returns injected values", function()
    local ui = stubUiWithStats({ today_pages = 30, today_duration = 1800 })
    local d, p = ui.statistics:getTodayBookStats()
    eq(p, 30, "today pages")
    eq(d, 1800, "today duration")
end)

test("stats helper: readStatsBookSession returns table when stats present", function()
    local ui = stubUiWithStats({ current_pages = 5, current_duration = 300 })
    local result = Tokens._readStatsBookSession(ui)
    assert(result, "expected non-nil result")
    eq(result.pages, 5, "pages")
    eq(result.duration, 300, "duration")
end)

test("stats helper: readStatsBookSession returns nil when stats absent", function()
    eq(Tokens._readStatsBookSession({ statistics = nil }), nil)
end)

test("stats helper: readStatsBookSession returns nil when method missing", function()
    eq(Tokens._readStatsBookSession({ statistics = { } }), nil)
end)

test("stats helper: readStatsToday returns table when stats present", function()
    local ui = stubUiWithStats({ today_pages = 12, today_duration = 720 })
    local result = Tokens._readStatsToday(ui)
    assert(result, "expected non-nil result")
    eq(result.pages, 12, "today pages")
    eq(result.duration, 720, "today duration")
end)

test("stats helper: readStatsToday returns nil when stats absent", function()
    eq(Tokens._readStatsToday({}), nil)
end)

test("stats helper: readStatsBookSession swallows method errors", function()
    local ui = { statistics = { getCurrentBookStats = function() error("db locked") end } }
    eq(Tokens._readStatsBookSession(ui), nil)
end)

test("stats helper: readStatsBookSession adds mem_read deltas to DB result", function()
    -- DB has 5 pages flushed at 300s; in-memory has 2 more pages and 90s
    -- since the last flush. Total reflects everything read this session.
    local ui = stubUiWithStats({
        current_pages = 5, current_duration = 300,
        mem_read_pages = 2, mem_read_time = 90,
    })
    local result = Tokens._readStatsBookSession(ui)
    eq(result.pages, 7, "5 flushed + 2 in-memory")
    eq(result.duration, 390, "300 flushed + 90 in-memory")
end)

test("stats helper: readStatsToday adds mem_read deltas to DB result", function()
    local ui = stubUiWithStats({
        today_pages = 20, today_duration = 1800,
        mem_read_pages = 3, mem_read_time = 120,
    })
    local result = Tokens._readStatsToday(ui)
    eq(result.pages, 23, "20 flushed + 3 in-memory")
    eq(result.duration, 1920, "1800 flushed + 120 in-memory")
end)

test("session_pages: stats-backed value preferred over arg", function()
    -- Arg says 24 (jumped from page 1 to 25), stats says 5 (actually dwelled).
    local ui = stubUiWithStats({ current_pages = 5 })
    local s = Tokens.buildConditionState(ui, 0, 24)
    eq(s.session_pages, 5, "should reflect skip-aware stats value")
end)

test("session_pages: falls back to arg when stats unavailable", function()
    local ui = { statistics = nil, view = { state = { page = 5 } } }
    local s = Tokens.buildConditionState(ui, 0, 24)
    eq(s.session_pages, 24, "fallback to legacy max-page counter")
end)

test("session_pages: render path also uses stats value", function()
    local ui = stubUiWithStats({ current_pages = 5 })
    local r = Tokens.expand("%session_pages", ui, 0, 24, false, 2, nil)
    eq(r, "5")
end)

test("session_time: stats-backed duration preferred over wall-clock arg", function()
    -- session_elapsed (wall clock) = 1800s (30 min).
    -- Stats says actual reading duration = 600s (10 min).
    local ui = stubUiWithStats({ current_duration = 600 })
    local s = Tokens.buildConditionState(ui, 1800, 0)
    eq(s.session_time, 10, "should use stats duration in minutes (600s/60)")
    eq(s.session, 10, "session alias matches")
end)

test("session_time: falls back to wall-clock arg when stats unavailable", function()
    local ui = { statistics = nil, view = { state = { page = 5 } } }
    local s = Tokens.buildConditionState(ui, 1800, 0)
    eq(s.session_time, 30, "fallback: 1800/60 = 30 min")
end)

test("pages_today: renders today's page count from stats", function()
    local ui = stubUiWithStats({ today_pages = 42 })
    local r = Tokens.expand("%pages_today", ui, 0, 0, false, 2, nil)
    eq(r, "42")
end)

test("pages_today: 0 when stats unavailable", function()
    local ui = { statistics = nil, view = { state = { page = 5 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.pages_today, 0)
end)

test("time_today: renders formatted clock duration", function()
    local prev = package.loaded["datetime"].secondsToClockDuration
    package.loaded["datetime"].secondsToClockDuration = function(_fmt, secs, _hp)
        return "DUR:" .. tostring(secs)
    end
    local ui = stubUiWithStats({ today_duration = 1800 })
    local r = Tokens.expand("%time_today", ui, 0, 0, false, 2, nil)
    eq(r, "DUR:1800")
    package.loaded["datetime"].secondsToClockDuration = prev
end)

test("time_today: state value is integer minutes", function()
    local ui = stubUiWithStats({ today_duration = 1800 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.time_today, 30)
end)

test("pages_today: state value is integer", function()
    local ui = stubUiWithStats({ today_pages = 17 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.pages_today, 17)
end)

test("[if:pages_today>10] evaluates against state", function()
    local ui = stubUiWithStats({ today_pages = 17 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    local r = Tokens._processConditionals("[if:pages_today>10]ok[/if]", s)
    eq(r, "ok")
end)

-- Regression: 5.6.0 shipped with `> 0` guards that blanked these tokens
-- when no time/pages had accrued, breaking the bl preset's "⏳ %session_time
-- session" line on freshly-opened books. Tokens must always render — a
-- zero duration formats per duration_format, never blank.
test("session_time: renders zero duration on freshly-opened book (stats=0)", function()
    local prev = package.loaded["datetime"].secondsToClockDuration
    package.loaded["datetime"].secondsToClockDuration = function(_fmt, secs, _hp)
        return "DUR:" .. tostring(secs)
    end
    local ui = stubUiWithStats({ current_duration = 0 })
    local r = Tokens.expand("%session_time", ui, 0, 0, false, 2, nil)
    eq(r, "DUR:0")
    package.loaded["datetime"].secondsToClockDuration = prev
end)

test("session_time: renders zero duration when stats disabled and no wall-clock", function()
    local prev = package.loaded["datetime"].secondsToClockDuration
    package.loaded["datetime"].secondsToClockDuration = function(_fmt, secs, _hp)
        return "DUR:" .. tostring(secs)
    end
    local ui = { statistics = nil, view = { state = { page = 5 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local r = Tokens.expand("%session_time", ui, nil, nil, false, 2, nil)
    eq(r, "DUR:0")
    package.loaded["datetime"].secondsToClockDuration = prev
end)

test("pages_today: renders 0 when nothing read today", function()
    local ui = stubUiWithStats({ today_pages = 0 })
    local r = Tokens.expand("%pages_today", ui, 0, 0, false, 2, nil)
    eq(r, "0")
end)

test("pages_today: renders 0 when stats unavailable", function()
    local ui = { statistics = nil, view = { state = { page = 5 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local r = Tokens.expand("%pages_today", ui, 0, 0, false, 2, nil)
    eq(r, "0")
end)

test("time_today: renders zero duration when nothing read today", function()
    local prev = package.loaded["datetime"].secondsToClockDuration
    package.loaded["datetime"].secondsToClockDuration = function(_fmt, secs, _hp)
        return "DUR:" .. tostring(secs)
    end
    local ui = stubUiWithStats({ today_duration = 0 })
    local r = Tokens.expand("%time_today", ui, 0, 0, false, 2, nil)
    eq(r, "DUR:0")
    package.loaded["datetime"].secondsToClockDuration = prev
end)

test("book_pages_read: renders cached instance field", function()
    local ui = stubUiWithStats({ book_read_pages = 87 })
    local r = Tokens.expand("%book_pages_read", ui, 0, 0, false, 2, nil)
    eq(r, "87")
end)

test("book_pages_read: state value populated", function()
    local ui = stubUiWithStats({ book_read_pages = 87 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.book_pages_read, 87)
end)

test("book_pages_read: 0 when stats absent", function()
    local ui = { statistics = nil, view = { state = { page = 5 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.book_pages_read, 0)
end)

test("avg_page_time: renders formatted duration", function()
    local prev = package.loaded["datetime"].secondsToClockDuration
    package.loaded["datetime"].secondsToClockDuration = function(_f, s, _h) return "AVG:" .. tostring(s) end
    -- Use a value ≥ 60 so the code path calls secondsToClockDuration
    -- (sub-minute averages take a fast path: math.floor(n) .. "s").
    local ui = stubUiWithStats({ avg_time = 90.3 })
    local r = Tokens.expand("%avg_page_time", ui, 0, 0, false, 2, nil)
    eq(r, "AVG:90.3")
    package.loaded["datetime"].secondsToClockDuration = prev
end)

test("avg_page_time: sub-minute rounds to integer with s suffix", function()
    local ui = stubUiWithStats({ avg_time = 45.7 })
    local r = Tokens.expand("%avg_page_time", ui, 0, 0, false, 2, nil)
    eq(r, "45s")
end)

test("avg_page_time: state value is integer seconds", function()
    local ui = stubUiWithStats({ avg_time = 45.7 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.avg_page_time, 45)
end)

test("book_pct_read: renders integer 0-100", function()
    local ui = stubUiWithStats({ book_read_pages = 50, page_count = 200 })
    local r = Tokens.expand("%book_pct_read", ui, 0, 0, false, 2, nil)
    eq(r, "25")
end)

test("book_pct_read: state value populated", function()
    local ui = stubUiWithStats({ book_read_pages = 50, page_count = 200 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.book_pct_read, 25)
end)

test("book_pct_read: 0 when page_count is 0", function()
    local ui = stubUiWithStats({ book_read_pages = 50, page_count = 0 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.book_pct_read, 0)
end)

test("book_pct_read: 0 when stats absent", function()
    local ui = { statistics = nil, view = { state = { page = 5 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.book_pct_read, 0)
end)

test("book_pct_read: clamps to 100 when read pages exceed total", function()
    local ui = stubUiWithStats({ book_read_pages = 250, page_count = 200 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.book_pct_read, 100)
end)

-- ============================================================================
-- book_pct decimal places: %book_pct{N} and %book_pct_left{N}
-- ============================================================================

test("book_pct: default (no brace) renders integer with % suffix", function()
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct: {0} rounds to integer (same as default)", function()
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct{0}", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct: {1} shows 1 decimal place (trailing zeros stripped)", function()
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct{1}", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct: {2} shows 2 decimal places (trailing zeros stripped)", function()
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct{2}", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct: {4} shows 4 decimal places (trailing zeros stripped)", function()
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct{4}", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct: {1} renders non-round value correctly", function()
    -- 33 of 200 → 33/200*100 = 16.5
    local ui = stubUi(33, 200)
    local r = Tokens.expand("%book_pct{1}", ui, 0, 0, false, 2, nil)
    eq(r, "16.5%")
end)

test("book_pct_left: {2} derived from the same raw fraction as book_pct", function()
    -- 33 of 200 → 16.5% read → 83.5% left
    local ui = stubUi(33, 200)
    local r = Tokens.expand("%book_pct_left{2}", ui, 0, 0, false, 2, nil)
    eq(r, "83.5%")
end)

test("book_pct: invalid brace value falls back to 0 decimals", function()
    -- {x} (non-numeric) and {5}+ (out of range) should be ignored → integer default.
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct{x}", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct: {3} shows 3 decimal places (trailing zeros stripped)", function()
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct{3}", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct: {5} out of range, falls back to 0 decimals", function()
    local ui = stubUi(5, 100)
    local r = Tokens.expand("%book_pct{5}", ui, 0, 0, false, 2, nil)
    eq(r, "5%")
end)

test("book_pct + book_pct_left: default integer pair sums to 100 at half-integer raw", function()
    -- 101 of 200 → pct_raw = 50.5; independent rounding would give 51% + 50% = 101%.
    local ui = stubUi(101, 200)
    local r = Tokens.expand("%book_pct %book_pct_left", ui, 0, 0, false, 2, nil)
    eq(r, "51% 49%")
end)

test("page_num: CRE scroll mode uses document:getCurrentPage(), not stale view.state.page", function()
    -- Issue #46: in CRE scroll mode, ReaderView:onPosUpdate only updates
    -- state.pos, not state.page. The widget needs to prefer the document's
    -- getCurrentPage(), which reflects the live page in both modes.
    local ui = stubUi(5, 100)  -- view.state.page = 5 (stale, as in scroll mode)
    ui.document.getCurrentPage = function() return 42 end  -- actual current page
    local r = Tokens.expand("%page_num/%page_count %book_pct", ui, 0, 0, false, 2, nil)
    eq(r, "42/100 42%")
end)

test("days_reading_book: 14 days from cached first-open ts", function()
    local fourteen_days_ago = os.time() - (14 * 86400)
    local ui = stubUiWithStats({ first_open_ts = fourteen_days_ago, id_curr_book = 100 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.days_reading_book, 14)
end)

test("days_reading_book: 0 when stats absent", function()
    local ui = { statistics = nil, view = { state = { page = 5 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.days_reading_book, 0)
end)

test("pages_per_day: book_pages_read / days_reading_book", function()
    local fourteen_days_ago = os.time() - (14 * 86400)
    local ui = stubUiWithStats({ book_read_pages = 70, first_open_ts = fourteen_days_ago, id_curr_book = 101 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.pages_per_day, 5)
end)

test("pages_per_day: zero-day handling — fresh book returns book_pages_read", function()
    local ui = stubUiWithStats({ book_read_pages = 5, first_open_ts = os.time(), id_curr_book = 102 })
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.pages_per_day, 5)
end)

test("pages_per_day: 0 when stats absent", function()
    local ui = { statistics = nil, view = { state = { page = 5 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.pages_per_day, 0)
end)

test("days_reading_book: render path", function()
    local seven_days_ago = os.time() - (7 * 86400)
    local ui = stubUiWithStats({ first_open_ts = seven_days_ago, id_curr_book = 103 })
    local r = Tokens.expand("%days_reading_book", ui, 0, 0, false, 2, nil)
    eq(r, "7")
end)

test("v5 tokens: %author expands to author name", function()
    local r = Tokens.expand("%author", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Isaac Asimov")
end)

test("v5 tokens: %title expands to title", function()
    local r = Tokens.expand("%title", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Foundation")
end)

test("v5 tokens: %page_num expands to current page", function()
    local r = Tokens.expand("%page_num", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "5")
end)

test("legacy alias via expand: %A expands to author name", function()
    local r = Tokens.expand("%A", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Isaac Asimov")
end)

test("legacy alias via expand: %T expands to title", function()
    local r = Tokens.expand("%T", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Foundation")
end)

test("legacy alias via expand: %c expands to current page", function()
    local r = Tokens.expand("%c", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "5")
end)

test("mixed legacy + new: '%A — %title' → 'Isaac Asimov — Foundation'", function()
    local r = Tokens.expand("%A — %title", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Isaac Asimov — Foundation")
end)

-- ============================================================================
-- series split: %series, %series_name, %series_num
-- ============================================================================
test("series: %series unchanged (combined 'Foundation #1')", function()
    local r = Tokens.expand("%series", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Foundation #1")
end)

test("series: %series_name alone gives 'Foundation'", function()
    local r = Tokens.expand("%series_name", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Foundation")
end)

test("series: %series_num alone gives '1'", function()
    local r = Tokens.expand("%series_num", stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "1")
end)

test("series: custom layout '%series_name, book %series_num'", function()
    local r = Tokens.expand("%series_name, book %series_num",
        stubUiForExpand(), nil, nil, false, 2, nil)
    eq(r, "Foundation, book 1")
end)

-- ============================================================================
-- legacy_literal flag: skip alias rewrite for live-preview behaviour
-- ============================================================================
test("legacy_literal: %A stays literal in preview", function()
    local r = Tokens.expandPreview("%A", stubUiForExpand(), nil, nil, 2, nil,
        { legacy_literal = true })
    eq(r, "%A")
end)

test("legacy_literal: %author still resolves in preview", function()
    local r = Tokens.expandPreview("%author", stubUiForExpand(), nil, nil, 2, nil,
        { legacy_literal = true })
    eq(r, "[author]")  -- preview-mode label
end)

test("legacy_literal: default (no opts) keeps rewriting", function()
    local r = Tokens.expandPreview("%A", stubUiForExpand(), nil, nil, 2, nil)
    eq(r, "[author]")
end)

test("legacy_literal: [if:chapters>10] keeps legacy key literal in preview", function()
    -- In preview mode, conditionals are bypassed (fast-path).
    -- With legacy_literal, the legacy predicate body passes through untouched.
    local r = Tokens.expandPreview("[if:chapters>10]X[/if]",
        stubUiForExpand(), nil, nil, 2, nil, { legacy_literal = true })
    assert(r:find("%[if:chapters>10%]"), "expected legacy predicate preserved: " .. r)
end)

-- ============================================================================
-- computeTickFractions: flow-aware chapter ticks
-- ============================================================================

-- Stub a TOC and Document. toc_pages is { [depth] = {page1, page2, ...} }.
-- For flow tests, page_to_flow maps a page number to its flow id, and
-- flow_pages maps flow id to ordered list of page numbers in that flow.
local function stubDocToc(opts)
    local total = opts.total
    local toc_pages = opts.toc_pages
    local has_flows = opts.has_flows or false
    local page_to_flow = opts.page_to_flow or {}
    local flow_pages = opts.flow_pages or {}
    local doc = {
        getPageCount = function() return total end,
        hasHiddenFlows = function() return has_flows end,
        getPageFlow = function(_self, page) return page_to_flow[page] or 0 end,
        getTotalPagesInFlow = function(_self, flow)
            return flow_pages[flow] and #flow_pages[flow] or 0
        end,
        getPageNumberInFlow = function(_self, page)
            local flow = page_to_flow[page] or 0
            local list = flow_pages[flow] or {}
            for i, p in ipairs(list) do
                if p == page then return i end
            end
            return 0
        end,
    }
    -- Make hasHiddenFlows callable via colon syntax (the function above is
    -- already plain — no self).
    local toc = {
        getTocTicks = function() return toc_pages end,
        getMaxDepth = function() return #toc_pages end,
    }
    return doc, toc
end

test("ticks: no-flow doc returns whole-doc fractions", function()
    local doc, toc = stubDocToc{
        total = 100,
        toc_pages = { [1] = { 25, 50, 75 } },
    }
    local ticks = Tokens.computeTickFractions(doc, toc, 2)
    eq(#ticks, 3, "tick count")
    eq(ticks[1][1], 0.25, "tick 1 fraction")
    eq(ticks[2][1], 0.5, "tick 2 fraction")
    eq(ticks[3][1], 0.75, "tick 3 fraction")
end)

test("ticks: skips first-page tick (page 1)", function()
    local doc, toc = stubDocToc{
        total = 100,
        toc_pages = { [1] = { 1, 50 } },
    }
    local ticks = Tokens.computeTickFractions(doc, toc, 2)
    eq(#ticks, 1, "page-1 tick is dropped")
    eq(ticks[1][1], 0.5)
end)

test("ticks: hidden flows + current page in flow 0 keeps only flow-0 ticks", function()
    -- Trilogy: pages 1-50 = flow 0 (book 1), pages 51-100 = flow 1 (book 2),
    -- pages 101-150 = flow 2 (book 3). Whole-doc total = 150.
    local p_to_f, f_pages = {}, { [0] = {}, [1] = {}, [2] = {} }
    for p = 1, 50 do p_to_f[p] = 0; table.insert(f_pages[0], p) end
    for p = 51, 100 do p_to_f[p] = 1; table.insert(f_pages[1], p) end
    for p = 101, 150 do p_to_f[p] = 2; table.insert(f_pages[2], p) end

    local doc, toc = stubDocToc{
        total = 150,
        toc_pages = { [1] = { 10, 25, 60, 80, 110, 130 } },
        has_flows = true,
        page_to_flow = p_to_f,
        flow_pages = f_pages,
    }
    -- Reading on page 30 (flow 0, book 1). Expect only ticks at pages 10
    -- and 25, expressed as fractions of flow-0's 50-page total.
    local ticks = Tokens.computeTickFractions(doc, toc, 2, 30)
    eq(#ticks, 2, "tick count limited to active flow")
    eq(ticks[1][1], 10 / 50, "tick at page 10 → 0.2 of flow")
    eq(ticks[2][1], 25 / 50, "tick at page 25 → 0.5 of flow")
end)

test("ticks: hidden flows + current page in flow 1 uses flow-1 fractions", function()
    local p_to_f, f_pages = {}, { [0] = {}, [1] = {} }
    for p = 1, 50 do p_to_f[p] = 0; table.insert(f_pages[0], p) end
    for p = 51, 100 do p_to_f[p] = 1; table.insert(f_pages[1], p) end

    local doc, toc = stubDocToc{
        total = 100,
        toc_pages = { [1] = { 25, 60, 80 } },
        has_flows = true,
        page_to_flow = p_to_f,
        flow_pages = f_pages,
    }
    -- Reading on page 70 (flow 1). Page 60 is index 10 in flow 1 (51 → 1,
    -- 52 → 2, ... 60 → 10). Page 80 is index 30. Flow 1 has 50 pages.
    local ticks = Tokens.computeTickFractions(doc, toc, 2, 70)
    eq(#ticks, 2, "page-25 tick (flow 0) is dropped")
    eq(ticks[1][1], 10 / 50, "page 60 → flow-1 page 10 / 50")
    eq(ticks[2][1], 30 / 50, "page 80 → flow-1 page 30 / 50")
end)

-- ============================================================================
-- book_pct_left / chap_pct_left: complement-of-progress conditional state
-- ============================================================================

test("state: [if:book_pct_left<10] true at 95% read", function()
    local r = Tokens._processConditionals(
        "[if:book_pct_left<10]nearly done[/if]", { book_pct_left = 5 })
    eq(r, "nearly done")
end)

test("state: [if:chap_pct_left>50] true mid-chapter", function()
    local r = Tokens._processConditionals(
        "[if:chap_pct_left>50]plenty[/if]", { chap_pct_left = 60 })
    eq(r, "plenty")
end)

test("state: book_pct + book_pct_left = 100 at any point", function()
    -- Same clamp the production code does. Guards against drift if the
    -- rounding of one branch is changed without the other.
    for _, pct in ipairs({0, 1, 17, 42, 50, 83, 99, 100}) do
        local left = math.max(0, math.min(100, 100 - pct))
        eq(pct + left, 100, "pct=" .. pct)
    end
end)

test("ticks: hidden flows but no current_pageno falls back to whole-doc", function()
    local doc, toc = stubDocToc{
        total = 100,
        toc_pages = { [1] = { 50 } },
        has_flows = true,
        page_to_flow = setmetatable({}, { __index = function() return 0 end }),
        flow_pages = { [0] = {} },
    }
    -- No current_pageno passed → backwards-compatible path.
    local ticks = Tokens.computeTickFractions(doc, toc, 2)
    eq(#ticks, 1)
    eq(ticks[1][1], 0.5, "whole-doc fraction when caller didn't opt in")
end)

-- ============================================================================
-- Per-book today/week, streaks, lifetime aggregates (cache-seam tests)
-- ============================================================================
-- These stats hit SQLite via SQ3 which isn't available in this pure-Lua runner.
-- The helpers consult stats_cache first, so pre-populating it lets us exercise
-- the resolver + state plumbing without hitting the DB.
test("pages_today_book: cached entry renders count", function()
    local ui = stubUiWithStats({})
    local r = Tokens.expand("%pages_today_book", ui, 0, 0, false, 2, nil, nil,
        { stats_cache = { book_today = { pages = 12, duration = 1800 } } })
    eq(r, "12")
end)

test("time_today_book: duration formatted via secondsToClockDuration", function()
    local prev = package.loaded["datetime"].secondsToClockDuration
    package.loaded["datetime"].secondsToClockDuration = function(_fmt, secs, _hp)
        return "DUR:" .. tostring(secs)
    end
    local ui = stubUiWithStats({})
    local r = Tokens.expand("%time_today_book", ui, 0, 0, false, 2, nil, nil,
        { stats_cache = { book_today = { pages = 5, duration = 1800 } } })
    eq(r, "DUR:1800")
    package.loaded["datetime"].secondsToClockDuration = prev
end)

test("state: time_today_book and pages_today_book populated from cache", function()
    local ui = stubUiWithStats({})
    local s = Tokens.buildConditionState(ui, 0, 0, nil,
        { book_today = { pages = 8, duration = 600 } })
    eq(s.pages_today_book, 8)
    eq(s.time_today_book, 10, "10 minutes from 600 seconds")
end)

test("state: time_today_book = 0 when cache empty and no stats", function()
    local ui = { statistics = nil, view = { state = { page = 1 } },
                 document = { file = "/b.epub", getPageCount = function() return 100 end,
                              hasHiddenFlows = function() return false end,
                              getProps = function() return {} end } }
    local s = Tokens.buildConditionState(ui, 0, 0)
    eq(s.pages_today_book, 0)
    eq(s.time_today_book, 0)
end)

test("week_book: state populates from book_week cache", function()
    local ui = stubUiWithStats({})
    local s = Tokens.buildConditionState(ui, 0, 0, nil,
        { book_week = { pages = 50, duration = 7200 } })
    eq(s.pages_week_book, 50)
    eq(s.time_week_book, 120, "120 minutes from 7200 seconds")
end)

test("streak: state.streak from cache", function()
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil, { streak = 7 })
    eq(s.streak, 7)
end)

test("book_streak: state.book_streak populated when id_curr_book set", function()
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil, { book_streak = 3 })
    eq(s.book_streak, 3)
end)

test("book_streak: state.book_streak = 0 without id_curr_book", function()
    local ui = stubUiWithStats({ id_curr_book = false })
    local s = Tokens.buildConditionState(ui, 0, 0, nil, { book_streak = 99 })
    -- id_curr_book missing → resolver bails, cache lookup never runs.
    eq(s.book_streak, 0)
end)

test("streak: %streak resolver renders cached integer", function()
    local r = Tokens.expand("%streak", stubUiWithStats({}), 0, 0, false, 2, nil, nil,
        { stats_cache = { streak = 14 } })
    eq(r, "14")
end)

test("streak: %streak auto-hides at zero (renders empty)", function()
    local r = Tokens.expand("%streak", stubUiWithStats({}), 0, 0, false, 2, nil, nil,
        { stats_cache = { streak = 0 } })
    eq(r, "")
end)

test("books_finished: state populated from book_summary cache", function()
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil,
        { book_summary = { total_time = 360000, finished_count = 23 } })
    eq(s.books_finished, 23)
    eq(s.total_read_time, 6000, "6000 minutes from 360000 seconds")
end)

test("books_finished: %books_finished renders the count", function()
    local r = Tokens.expand("%books_finished", stubUiWithStats({}), 0, 0, false, 2, nil, nil,
        { stats_cache = { book_summary = { total_time = 0, finished_count = 7 } } })
    eq(r, "7")
end)

test("[if:streak>=7] evaluates against state", function()
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil, { streak = 10 })
    eq(Tokens._processConditionals("[if:streak>=7]week+[/if]", s), "week+")
end)

test("[if:books_finished>=5] evaluates against state", function()
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil,
        { book_summary = { total_time = 0, finished_count = 12 } })
    eq(Tokens._processConditionals("[if:books_finished>=5]many[/if]", s), "many")
end)

-- ============================================================================
-- buildConditionState: lazy SQL-fetch gating (issue #36)
-- ============================================================================

test("gating: format_str arg restricts SQL fetch to referenced fields", function()
    local cache = {
        session = { pages = 5, duration = 300 },
        today = { pages = 9, duration = 600 },
        book_today = { pages = 4, duration = 200 },
        book_week = { pages = 30, duration = 3600 },
        streak = 7,
        book_streak = 3,
        book_summary = { total_time = 360000, finished_count = 23 },
    }
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil, cache,
        "[if:streak >= 5]hot[/if]")
    eq(s.streak, 7, "streak referenced -> populated")
    eq(s.session_pages, nil, "session_pages not referenced -> nil")
    eq(s.pages_today, nil, "pages_today not referenced -> nil")
    eq(s.book_streak, nil, "book_streak not referenced -> nil")
    eq(s.total_read_time, nil, "total_read_time not referenced -> nil")
    eq(s.pages_today_book, nil, "pages_today_book not referenced -> nil")
end)

test("gating: paint_ctx._cond_format_union takes precedence over format_str arg", function()
    local cache = { streak = 7, book_summary = { total_time = 60, finished_count = 1 } }
    local paint_ctx = { _cond_format_union = "[if:total_read_time > 0]ok[/if]" }
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, paint_ctx, cache,
        "[if:streak >= 5]hot[/if]")
    eq(s.total_read_time, 1, "union-referenced field populated")
    eq(s.streak, nil, "format_str-only field skipped when union present")
end)

test("gating: word-boundary regex distinguishes streak from book_streak", function()
    local cache = { streak = 99, book_streak = 4 }
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil, cache,
        "[if:book_streak >= 3]chain[/if]")
    eq(s.book_streak, 4, "book_streak fetched as referenced")
    eq(s.streak, nil, "streak not over-matched by book_streak ref")
end)

test("gating: pages_today_book ref does not pull pages_today bucket", function()
    local cache = {
        today = { pages = 50, duration = 1000 },
        book_today = { pages = 5, duration = 200 },
    }
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil, cache,
        "[if:pages_today_book > 0]read[/if]")
    eq(s.pages_today_book, 5, "today_book bucket fetched")
    eq(s.pages_today, nil, "today bucket not fetched (different field)")
end)

test("gating: union covering multiple lines fetches each referenced bucket", function()
    local cache = {
        streak = 14,
        book_summary = { total_time = 1200, finished_count = 8 },
        session = { pages = 3, duration = 180 },
    }
    local paint_ctx = {
        _cond_format_union = "[if:streak >= 7]hot[/if]\0[if:books_finished > 5]reader[/if]",
    }
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, paint_ctx, cache)
    eq(s.streak, 14, "first line's field fetched")
    eq(s.books_finished, 8, "second line's field fetched")
    eq(s.session_pages, nil, "unreferenced bucket not fetched even when cache has data")
end)

test("gating: no format_str and no union -> all SQL buckets fetched (back-compat)", function()
    local cache = { streak = 1, book_summary = { total_time = 0, finished_count = 0 } }
    local s = Tokens.buildConditionState(stubUiWithStats({}), 0, 0, nil, cache)
    eq(s.streak, 1, "streak populated without gating")
    eq(s.books_finished, 0, "book_summary populated without gating")
end)

-- ============================================================================
-- Chapter-number prefix stripping
-- ============================================================================

test("parseChapNumPrefix: '1 Title' -> 1, 'Title'", function()
    local n, rest = Tokens._parseChapNumPrefix("1 Title")
    eq(n, 1); eq(rest, "Title")
end)

test("parseChapNumPrefix: '1. Title' -> 1, 'Title'", function()
    local n, rest = Tokens._parseChapNumPrefix("1. Title")
    eq(n, 1); eq(rest, "Title")
end)

test("parseChapNumPrefix: '12: Long Title' -> 12, 'Long Title'", function()
    local n, rest = Tokens._parseChapNumPrefix("12: Long Title")
    eq(n, 12); eq(rest, "Long Title")
end)

test("parseChapNumPrefix: '3) Subsection' -> 3, 'Subsection'", function()
    local n, rest = Tokens._parseChapNumPrefix("3) Subsection")
    eq(n, 3); eq(rest, "Subsection")
end)

test("parseChapNumPrefix: bare '1' -> nil (no separator/rest)", function()
    eq(Tokens._parseChapNumPrefix("1"), nil)
end)

test("parseChapNumPrefix: '1.1 Background' -> nil (decimal section number)", function()
    eq(Tokens._parseChapNumPrefix("1.1 Background"), nil)
end)

test("parseChapNumPrefix: '1Title' -> nil (no whitespace separator)", function()
    eq(Tokens._parseChapNumPrefix("1Title"), nil)
end)

test("parseChapNumPrefix: 'Foreword' -> nil (no leading number)", function()
    eq(Tokens._parseChapNumPrefix("Foreword"), nil)
end)

test("parseChapNumPrefix: leading whitespace tolerated", function()
    local n, rest = Tokens._parseChapNumPrefix("  4 Title")
    eq(n, 4); eq(rest, "Title")
end)

test("computeStripPrefixByDepth: clean 1..N at depth 1 -> safe", function()
    local toc = {
        { title = "1 Continental Setting", depth = 1, page = 1 },
        { title = "2 The Wars",            depth = 1, page = 50 },
        { title = "3 The Aftermath",       depth = 1, page = 100 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], true)
end)

test("computeStripPrefixByDepth: year-titled history -> NOT safe", function()
    local toc = {
        { title = "1939 Invasion of Poland", depth = 1, page = 1 },
        { title = "1940 Battle of Britain",  depth = 1, page = 50 },
        { title = "1941 Pearl Harbor",       depth = 1, page = 100 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false,
       "year-anchored sequence does not start at 1")
end)

test("computeStripPrefixByDepth: listicle '10 Rules' singleton -> NOT safe", function()
    local toc = {
        { title = "10 Rules for Sleep", depth = 1, page = 1 },
        { title = "Bedtime",            depth = 1, page = 30 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false,
       "single parseable entry is not a sequence")
end)

test("computeStripPrefixByDepth: gap in sequence -> NOT safe", function()
    local toc = {
        { title = "1 Ch1", depth = 1, page = 1 },
        { title = "2 Ch2", depth = 1, page = 30 },
        { title = "4 Ch4", depth = 1, page = 60 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false,
       "gap at 3 breaks strict 1..N")
end)

test("computeStripPrefixByDepth: duplicate breaks sequence -> NOT safe", function()
    local toc = {
        { title = "1 Ch1",      depth = 1, page = 1 },
        { title = "2 Ch2",      depth = 1, page = 30 },
        { title = "2 Ch2 dupe", depth = 1, page = 60 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false)
end)

test("computeStripPrefixByDepth: Foreword + numbered + Epilogue -> safe", function()
    local toc = {
        { title = "Foreword", depth = 1, page = 1 },
        { title = "1 Ch1",    depth = 1, page = 10 },
        { title = "2 Ch2",    depth = 1, page = 40 },
        { title = "3 Ch3",    depth = 1, page = 70 },
        { title = "Epilogue", depth = 1, page = 100 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], true,
       "non-numbered entries are ignored, 1..3 is still strict")
end)

test("computeStripPrefixByDepth: starts at 0 -> NOT safe", function()
    local toc = {
        { title = "0 Prologue", depth = 1, page = 1 },
        { title = "1 Ch1",      depth = 1, page = 10 },
        { title = "2 Ch2",      depth = 1, page = 40 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false, "must start at 1")
end)

test("computeStripPrefixByDepth: independent decisions per depth", function()
    local toc = {
        { title = "1 Part One",  depth = 1, page = 1 },
        { title = "1939 Year",   depth = 2, page = 5 },
        { title = "1940 Year",   depth = 2, page = 20 },
        { title = "2 Part Two",  depth = 1, page = 50 },
        { title = "1941 Year",   depth = 2, page = 55 },
    }
    local r = Tokens._computeStripPrefixByDepth(toc)
    eq(r[1], true,  "depth-1 is 1..2")
    eq(r[2], false, "depth-2 is year-anchored")
end)

test("computeStripPrefixByDepth: section-numbered '1.1' at depth 2 -> NOT safe", function()
    local toc = {
        { title = "1 Introduction", depth = 1, page = 1 },
        { title = "1.1 Background", depth = 2, page = 3 },
        { title = "1.2 Methods",    depth = 2, page = 8 },
        { title = "2 Results",      depth = 1, page = 20 },
        { title = "2.1 Findings",   depth = 2, page = 23 },
    }
    local r = Tokens._computeStripPrefixByDepth(toc)
    eq(r[1], true,  "depth-1 is 1..2")
    eq(r[2] or false, false, "depth-2 doesn't parse — pattern rejects '1.1 Background'")
end)

test("computeStripPrefixByDepth: empty/missing TOC -> empty result", function()
    eq(next(Tokens._computeStripPrefixByDepth(nil)), nil)
    eq(next(Tokens._computeStripPrefixByDepth({})), nil)
end)

test("computeStripPrefixByDepth: '1. Title' / '2. Title' (period sep) -> safe", function()
    local toc = {
        { title = "1. Continental", depth = 1, page = 1 },
        { title = "2. Wars",        depth = 1, page = 30 },
        { title = "3. Aftermath",   depth = 1, page = 60 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], true)
end)

test("computeStripPrefixByDepth: '1 Chapter, 2 Chapter' uniform-rest -> NOT safe", function()
    local toc = {
        { title = "1 Chapter", depth = 1, page = 1 },
        { title = "2 Chapter", depth = 1, page = 30 },
        { title = "3 Chapter", depth = 1, page = 60 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false,
       "stripping would leave duplicate 'Chapter' entries")
end)

test("computeStripPrefixByDepth: '1 Vignette, 2 Vignette' uniform-rest -> NOT safe", function()
    local toc = {
        { title = "1 Vignette", depth = 1, page = 1 },
        { title = "2 Vignette", depth = 1, page = 30 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false)
end)

test("computeStripPrefixByDepth: partial collision in stripped rest -> NOT safe", function()
    local toc = {
        { title = "1 Introduction", depth = 1, page = 1 },
        { title = "2 The Wars",     depth = 1, page = 30 },
        { title = "3 The Wars",     depth = 1, page = 60 },
        { title = "4 Aftermath",    depth = 1, page = 90 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false,
       "any duplicate in the post-strip set blocks stripping the whole depth")
end)

test("computeStripPrefixByDepth: trailing whitespace in rest is normalised", function()
    local toc = {
        { title = "1 Chapter ",  depth = 1, page = 1 },
        { title = "2 Chapter",   depth = 1, page = 30 },
    }
    eq(Tokens._computeStripPrefixByDepth(toc)[1], false,
       "trailing space shouldn't make 'Chapter ' and 'Chapter' look distinct")
end)

test("getChapterTitlesByDepth: returns raw titles (no auto-strip on chap_title)", function()
    local toc = {
        { title = "1 Continental Setting", depth = 1, page = 1 },
        { title = "2 The Wars",            depth = 1, page = 50 },
        { title = "3 The Aftermath",       depth = 1, page = 100 },
    }
    local stub_ui = {
        toc = {
            toc = toc,
            getTocTitleByPage = function(_, _) return "" end,
        },
    }
    local out = Tokens.getChapterTitlesByDepth(stub_ui, 60)
    eq(out.chapter_title, "2 The Wars",
       "chapter_title is raw; the strip happens in chapter_title_name only")
    eq(out.chapter_titles_by_depth[1], "2 The Wars")
end)

test("getChapterTitlesByDepth: leaves year-titles untouched", function()
    local toc = {
        { title = "1939 Invasion of Poland", depth = 1, page = 1 },
        { title = "1940 Battle of Britain",  depth = 1, page = 50 },
        { title = "1941 Pearl Harbor",       depth = 1, page = 100 },
    }
    local stub_ui = {
        toc = {
            toc = toc,
            getTocTitleByPage = function(_, _) return "" end,
        },
    }
    local out = Tokens.getChapterTitlesByDepth(stub_ui, 60)
    eq(out.chapter_title, "1940 Battle of Britain")
    eq(out.chapter_titles_by_depth[1], "1940 Battle of Britain")
end)

test("getChapterTitlesByDepth: chapter_title_num/_name populate when strip-safe", function()
    local toc = {
        { title = "1 Continental Setting", depth = 1, page = 1 },
        { title = "2 The Wars",            depth = 1, page = 50 },
        { title = "3 The Aftermath",       depth = 1, page = 100 },
    }
    local stub_ui = {
        toc = {
            toc = toc,
            getTocTitleByPage = function(_, _) return "" end,
        },
    }
    local out = Tokens.getChapterTitlesByDepth(stub_ui, 60)
    eq(out.chapter_title_num, "2", "leading number parsed from current chapter title")
    eq(out.chapter_title_name, "The Wars", "stripped name")
end)

test("getChapterTitlesByDepth: chapter_title_num empty / _name = raw when not strip-safe", function()
    local toc = {
        { title = "1939 Invasion of Poland", depth = 1, page = 1 },
        { title = "1940 Battle of Britain",  depth = 1, page = 50 },
        { title = "1941 Pearl Harbor",       depth = 1, page = 100 },
    }
    local stub_ui = {
        toc = {
            toc = toc,
            getTocTitleByPage = function(_, _) return "" end,
        },
    }
    local out = Tokens.getChapterTitlesByDepth(stub_ui, 60)
    eq(out.chapter_title_num, "", "no parsed number when heuristic rejects")
    eq(out.chapter_title_name, "1940 Battle of Britain",
       "name falls back to raw title so layouts using only _name still work")
end)

test("getChapterTitlesByDepth: deeper middle section doesn't pin deepest forever", function()
    -- Issue #50: a few chapters in the middle are nested one level deeper than
    -- those before/after. Once the reader passes the last deep entry, the
    -- deepest-title resolver must drop back to the shallower current ancestor
    -- rather than keep showing the last deep title for the rest of the book.
    local toc = {
        { title = "Teil I",                   depth = 1, page = 1   },
        { title = "Teil II",                  depth = 1, page = 50  },
        { title = "- 103 - Nachspiel",        depth = 2, page = 80  },
        { title = "Teil III",                 depth = 1, page = 120 },
        { title = "Die Verlorenen",           depth = 2, page = 125 },
    }
    local stub_ui = {
        toc = {
            toc = toc,
            getTocTitleByPage = function(_, _) return "" end,
        },
    }

    -- Mid-Nachspiel: deepest is the depth-2 entry.
    local mid = Tokens.getChapterTitlesByDepth(stub_ui, 100)
    eq(mid.chapter_title, "- 103 - Nachspiel", "deepest while inside Nachspiel")
    eq(mid.chapter_titles_by_depth[2], "- 103 - Nachspiel")

    -- After Teil III opens but before Die Verlorenen: depth-2 must clear.
    local after_part = Tokens.getChapterTitlesByDepth(stub_ui, 122)
    eq(after_part.chapter_title, "Teil III",
       "deepest should drop back to Teil III, not stay pinned on Nachspiel")
    eq(after_part.chapter_titles_by_depth[1], "Teil III")
    eq(after_part.chapter_titles_by_depth[2], nil,
       "stale depth-2 title from previous section must be cleared")

    -- Once Die Verlorenen opens at depth 2: depth-2 is the current sub-chapter.
    local in_verlorenen = Tokens.getChapterTitlesByDepth(stub_ui, 200)
    eq(in_verlorenen.chapter_title, "Die Verlorenen")
    eq(in_verlorenen.chapter_titles_by_depth[1], "Teil III")
    eq(in_verlorenen.chapter_titles_by_depth[2], "Die Verlorenen")
end)

test("getChapterTitlesByDepth: chapter_title_num/_name empty when no chapter title", function()
    local stub_ui = {
        toc = {
            toc = {},
            getTocTitleByPage = function(_, _) return "" end,
        },
    }
    local out = Tokens.getChapterTitlesByDepth(stub_ui, 60)
    eq(out.chapter_title, "")
    eq(out.chapter_title_num, "")
    eq(out.chapter_title_name, "")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
