-- #121: %session_pages_advanced - pages ADVANCED this session, in stable page
-- numbers when the book has them.
--
-- The reporter reads with stable page numbers and wants a count that starts at
-- 0 and goes up only when a new stable page is reached:
--   start on stable page 10 -> 0, move around within 10 -> 0,
--   reach 11 -> 1, reach 12 -> 2.
-- That is v3.5.0's %s. Its counter still exists: main.lua's getSessionPages()
-- is furthest-page-reached minus the session's first page, on the pagemap
-- index when there is one, and it arrives in Tokens.expand as
-- session_pages_read. Since v4 %session_pages prefers the statistics plugin's
-- skip-aware count of RENDERED pages and only falls back to that counter when
-- statistics is off, so stable-page readers lost it. This token is that
-- counter, always, and %session_pages is left exactly as it was.
--
-- Usage: lua tests/_test_session_pages_advanced.lua

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
package.loaded["bookends_i18n"] = { gettext = function(str) return str end }
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
    readSetting = function() return "classic" end,
    isTrue = function() return false end,
})

local Tokens = dofile("bookends_tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "")
            .. " expected=" .. string.format("%q", tostring(expected))
            .. " got=" .. string.format("%q", tostring(actual)), 2)
    end
end

-- The statistics seam. Records whether it was consulted, and what it reports
-- is deliberately DIFFERENT from the advanced counter, so a test can tell which
-- source a value came from.
local stats_reads = 0
local stats_session = { pages = 40, duration = 1800 }
Tokens._readStatsBookSession = function()
    stats_reads = stats_reads + 1
    return stats_session
end

local ui = {
    document = {
        file              = "/library/book.epub",
        getProps          = function() return {} end,
        getCurrentPage    = function() return 100 end,
        hasHiddenFlows    = function() return false end,
        getPageCount      = function() return 500 end,
        getTotalPagesLeft = function() return 400 end,
    },
    toc = {
        toc = { { page = 1, title = "One", depth = 1 } },
        getPreviousChapter  = function() return 50 end,
        isChapterStart      = function() return false end,
        getNextChapter      = function() return 200 end,
        getChapterPagesLeft = function() return 100 end,
        getChapterPagesDone = function() return 50 end,
        getChapterPageCount = function() return 150 end,
        getTocTitleByPage   = function() return "One" end,
        getMaxDepth         = function() return 1 end,
    },
    statistics = { avg_time = 30 },
    view = { state = { page = 100 } },
}

-- `advanced` is what main.lua's getSessionPages() hands in.
local function expand(fmt, advanced)
    stats_reads = 0
    return Tokens.expand(fmt, ui, 600, advanced, false, 2, nil)
end

test("shows the pages advanced this session", function()
    eq(expand("%session_pages_advanced", 2), "2")
end)

test("starts at 0, not blank, before any page is advanced", function()
    -- The reporter's own example opens with "count = 0".
    eq(expand("%session_pages_advanced", 0), "0")
end)

test("a line showing 0 is not auto-hidden", function()
    -- A token reading "0" counts as empty and hides its line unless it is in
    -- always_content, which is where %session_pages already sits so a session
    -- line stays up at the start. Same here: 0 is the opening value, not a gap.
    stats_reads = 0
    local _text, is_empty = Tokens.expand("%session_pages_advanced", ui, 600, 0, false, 2, nil)
    eq(is_empty, false, "a line holding only the 0 was treated as empty")
    -- The precedent it follows:
    local _t2, sp_empty = Tokens.expand("%session_pages", ui, 600, 0, false, 2, nil)
    eq(sp_empty, false, "precedent changed: %session_pages at 0 now hides")
end)

test("reads 0 before the counter has been set at all", function()
    eq(expand("%session_pages_advanced", nil), "0")
end)

test("ignores the statistics plugin's count", function()
    -- The defining difference from %session_pages, which is statistics-first.
    eq(expand("%session_pages", 2), "40")
    eq(expand("%session_pages_advanced", 2), "2")
end)

test("%session_pages is unchanged by the new token", function()
    eq(expand("%session_pages / %session_pages_advanced", 2), "40 / 2")
end)

test("does not touch the statistics database", function()
    -- %session_pages' stats read is the per-page cost that #36 gated on the
    -- Clara BW; a template using only this token must not pay it.
    expand("%session_pages_advanced", 2)
    eq(stats_reads, 0, "statistics were read for a template that does not need them")
end)

test("is a condition key", function()
    eq(expand("[if:session_pages_advanced>=2]on[else]off[/if]", 2), "on")
    eq(expand("[if:session_pages_advanced>=2]on[else]off[/if]", 1), "off")
end)

test("the condition key does not read statistics either", function()
    expand("[if:session_pages_advanced>0]x[/if]", 3)
    eq(stats_reads, 0, "the condition state read statistics for this key")
end)

test("preview mode shows a placeholder, not the raw token", function()
    local out = Tokens.expandPreview("%session_pages_advanced", ui, 600, 2, 2, nil)
    assert(not out:find("%session_pages_advanced", 1, true),
           "survived preview mode as literal text: " .. out)
end)

test("is in the token catalogue", function()
    local cat = dofile("menu/tokens_catalogue.lua")
    local found = false
    for _i, entry in ipairs(cat.TOKENS or {}) do
        if entry.token == "%session_pages_advanced" then found = true end
    end
    assert(found, "%session_pages_advanced is not in the token catalogue")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
