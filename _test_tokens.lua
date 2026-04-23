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

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
