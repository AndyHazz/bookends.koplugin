-- Tests for the hour/minute time-left conditional fields (#104).
--
-- %chap_time_left_h / _m and %book_time_left_h / _m have existed as tokens
-- since the split-duration work, but the matching conditional fields did not:
-- [if:chap_time_left_h>0] silently evaluated false (unknown key), so the
-- obvious way to write Kindle's "2 hrs 5 mins left in chapter" - show the hour
-- part only when there is one - produced output with the hours missing and no
-- error to say why. The only formulation that worked was the non-obvious
-- [if:chap_time_left>=60].
--
-- Run: cd into the plugin dir, then `lua tests/_test_time_left_conditionals.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = { secondsToClockDuration = function() return "" end }
package.loaded["bookends_overlay_widget"] = { BAR_PLACEHOLDER = "\x00BAR\x00" }
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
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
            .. " got="      .. string.format("%q", tostring(actual)), 2)
    end
end

-- A book of 500 pages, currently on page 100, with the current chapter running
-- to page 200. avg_time is seconds per page, so chapter pages-left x avg_time
-- gives the minutes the conditional fields are derived from.
local function fakeUI(chapter_pages_left, avg_time)
    return {
        document = {
            getCurrentPage    = function() return 100 end,
            hasHiddenFlows    = function() return false end,
            getPageCount      = function() return 500 end,
            getTotalPagesLeft = function() return 400 end,
            file              = "/books/x.epub",
        },
        -- Chapter 2 of 2, running from page 50 to page 200. Only the page
        -- arithmetic matters here; the titles just have to exist so the
        -- chapter-title buckets don't blow up.
        toc = {
            toc = { { page = 1, title = "One", depth = 1 },
                    { page = 50, title = "Two", depth = 1 } },
            getPreviousChapter   = function() return 50 end,
            isChapterStart       = function() return false end,
            getNextChapter       = function() return 200 end,
            getChapterPagesLeft  = function() return chapter_pages_left end,
            getChapterPagesDone  = function() return 150 - chapter_pages_left end,
            getChapterPageCount  = function() return 150 end,
            getTocTitleByPage    = function() return "Two" end,
            getMaxDepth          = function() return 1 end,
        },
        statistics = { avg_time = avg_time },
    }
end

local FMT = "[if:chap_time_left_h>0]%chap_time_left_h hr(s) [/if]%chap_time_left_m min(s) left in chapter"

local function stateFor(chapter_pages_left, avg_time)
    return Tokens.buildConditionState(fakeUI(chapter_pages_left, avg_time), 0, 0, nil, nil, FMT)
end

-- ============================================================================
-- Derived fields exist and agree with the minutes field
-- ============================================================================

test("chap_time_left_h / _m are derived from chap_time_left", function()
    -- 50 pages left x 150 s = 7500 s = 125 min = 2 h 5 m
    local s = stateFor(50, 150)
    eq(s.chap_time_left, 125, "minutes")
    eq(s.chap_time_left_h, 2, "hours")
    eq(s.chap_time_left_m, 5, "minutes part")
end)

test("book_time_left_h / _m are derived from book_time_left", function()
    -- 400 pages left x 150 s = 60000 s = 1000 min = 16 h 40 m
    local s = stateFor(50, 150)
    eq(s.book_time_left, 1000, "minutes")
    eq(s.book_time_left_h, 16, "hours")
    eq(s.book_time_left_m, 40, "minutes part")
end)

test("h / m always reconstruct the minutes field exactly", function()
    for _, pages in ipairs({ 0, 1, 7, 23, 24, 25, 119, 120, 121 }) do
        local s = stateFor(pages, 150)
        eq(s.chap_time_left_h * 60 + s.chap_time_left_m, s.chap_time_left,
           "pages=" .. pages)
    end
end)

test("under an hour gives h = 0, not nil", function()
    -- 10 pages x 150 s = 25 min: the hour field must be a real 0 so that
    -- [if:chap_time_left_h>0] is a definite false rather than a missing key.
    local s = stateFor(10, 150)
    eq(s.chap_time_left, 25, "minutes")
    eq(s.chap_time_left_h, 0, "hours")
    eq(s.chap_time_left_m, 25, "minutes part")
end)

test("no reading-speed data leaves every time-left field unset", function()
    local s = stateFor(50, 0)
    eq(s.chap_time_left, nil, "minutes")
    eq(s.chap_time_left_h, nil, "hours")
    eq(s.chap_time_left_m, nil, "minutes part")
    eq(s.book_time_left_h, nil, "book hours")
end)

-- ============================================================================
-- End to end: Kindle's "xx hr xx min left in chapter" (#104)
-- ============================================================================

-- Mirrors the tail of Tokens.expand: conditionals, then token substitution,
-- then the (s) pluralisation pass.
local function render(chapter_pages_left, avg_time)
    local s = stateFor(chapter_pages_left, avg_time)
    local out = Tokens._processConditionals(FMT, s)
    out = out:gsub("%%chap_time_left_h", tostring(s.chap_time_left_h or ""))
             :gsub("%%chap_time_left_m", tostring(s.chap_time_left_m or ""))
    return (out:gsub("(%d+)(%D-)%(s%)", function(num, between)
        return num == "1" and num .. between or num .. between .. "s"
    end))
end

test("over two hours: plural hours and minutes", function()
    eq(render(50, 150), "2 hrs 5 mins left in chapter")
end)

test("exactly one hour and one minute: both singular", function()
    -- 61 min: 1 h 1 m
    eq(render(61, 60), "1 hr 1 min left in chapter")
end)

test("under an hour: the hour segment disappears with no leftover space", function()
    eq(render(25, 60), "25 mins left in chapter")
end)

test("one minute left: singular, still no leading space", function()
    eq(render(1, 60), "1 min left in chapter")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
