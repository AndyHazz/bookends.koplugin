-- %spacer: an elastic gap that pushes the text after it to the far edge of the
-- line. Ported from bookshelf for #348 parity, and a prerequisite for the
-- bookshelf-status-line region.
--
-- The RENDERER half (the gap widget and the segment split) needs KOReader's
-- widget stack and is verified on device; what is unit-testable here is the
-- token half: %spacer must reach the renderer as a placeholder, exactly the
-- way %bar does, and must never survive into output as literal text.
--
-- Usage: lua tests/_test_spacer.lua

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = { secondsToClockDuration = function() return "" end }
package.loaded["bookends_overlay_widget"] = {
    BAR_PLACEHOLDER    = "\xEF\xBF\xBC",
    SPACER_PLACEHOLDER = "\xEF\xBF\xB9",
}
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
    readSetting = function() return "classic" end,
    isTrue = function() return false end,
})

local SPACER = "\xEF\xBF\xB9"
local Tokens = dofile("bookends_tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local ui = {
    document = {
        file = "/b.epub",
        getCurrentPage = function() return 100 end,
        hasHiddenFlows = function() return false end,
        getPageCount = function() return 500 end,
        getTotalPagesLeft = function() return 400 end,
        getProps = function() return { title = "Dune", authors = "Frank Herbert" } end,
    },
    toc = {
        toc = { { page = 1, title = "One", depth = 1 } },
        getPreviousChapter = function() return 1 end,
        isChapterStart = function() return false end,
        getNextChapter = function() return 200 end,
        getChapterPagesLeft = function() return 100 end,
        getChapterPagesDone = function() return 50 end,
        getChapterPageCount = function() return 150 end,
        getTocTitleByPage = function() return "One" end,
        getMaxDepth = function() return 1 end,
        -- %bar asks the TOC for chapter tick positions.
        -- depth-keyed lists of chapter start pages, not a flat list.
        getTocTicks = function() return { [1] = { 1, 200, 350 } } end,
    },
    view = { state = { page = 100 } },
    statistics = { avg_time = 30 },
}

local function ex(fmt) return Tokens.expand(fmt, ui, 0, 0, false, 2, nil) end

test("%spacer becomes the placeholder the renderer looks for", function()
    local out = ex("%page_num%spacer%page_count")
    assert(out:find(SPACER, 1, true), "no spacer placeholder in: " .. out)
    assert(out == "100" .. SPACER .. "500", "got: " .. out)
end)

test("the literal word never survives into output", function()
    local out = ex("a%spacerb")
    assert(not out:find("spacer", 1, true),
           "the literal token leaked: " .. out)
end)

test("a line without %spacer is untouched", function()
    local out = ex("%page_num of %page_count")
    assert(not out:find(SPACER, 1, true), "placeholder appeared unbidden")
    assert(out == "100 of 500", "got: " .. out)
end)

test("%<spacer> wrapping resolves to the placeholder too", function()
    local out = ex("%<spacer>")
    assert(out == SPACER, "got: " .. string.format("%q", out))
end)

test("more than one %spacer: only the first becomes elastic", function()
    -- Two elastic gaps on one line cannot both take the remaining width. The
    -- first wins and the rest are dropped, matching bookshelf's rule.
    local out = ex("a%spacerb%spacerc")
    local _, n = out:gsub(SPACER, "")
    assert(n == 1, "expected exactly one placeholder, got " .. n .. " in " .. out)
    assert(not out:find("spacer", 1, true), "a literal survived: " .. out)
end)

test("%bar wins when a line carries both elastic tokens", function()
    local out = ex("a%barb%spacerc")
    assert(out:find("\xEF\xBF\xBC", 1, true), "the bar placeholder was lost")
    local _, n = out:gsub(SPACER, "")
    assert(n == 0, "the spacer should be dropped when a bar is present")
    assert(not out:find("spacer", 1, true), "a literal survived: " .. out)
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
