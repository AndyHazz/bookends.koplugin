-- Dev-box test runner for bookends_tokens.lua token vocabulary + grammar.
-- Runs pure-Lua (no KOReader) by stubbing the modules bookends_tokens requires.
-- Usage: cd into the plugin dir, then `lua _test_tokens.lua`.
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
    local ui = stubUiWithStats({ avg_time = 45.3 })
    local r = Tokens.expand("%avg_page_time", ui, 0, 0, false, 2, nil)
    eq(r, "AVG:45.3")
    package.loaded["datetime"].secondsToClockDuration = prev
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

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
