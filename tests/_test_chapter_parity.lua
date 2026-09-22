-- #117: odd/even alternation keyed on the CHAPTER page, not the book page.
--
-- The reporter was writing [if:page=odd] to alternate a footer and wanted the
-- in-chapter page to drive it instead. `page` has always been the book page's
-- parity and there was no chapter equivalent, so there was nothing to write.
--
-- `chap_page` is the parity of `chap_read` (the in-chapter page number), which
-- is the value they were already using. Note it is deliberately NOT derived
-- from chap_pages, the chapter's total.
--
-- Usage: lua tests/_test_chapter_parity.lua

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

-- A reader on book page `pageno`, `done` pages into the current chapter.
-- chap_read is done + 1, so done=0 is chapter page 1.
local function readerAt(pageno, done)
    return {
        document = {
            file              = "/library/book.epub",
            getProps          = function() return {} end,
            getCurrentPage    = function() return pageno end,
            hasHiddenFlows    = function() return false end,
            getPageCount      = function() return 500 end,
            getTotalPagesLeft = function() return 500 - pageno end,
        },
        toc = {
            toc = { { page = 1, title = "One", depth = 1 } },
            getPreviousChapter  = function() return 50 end,
            isChapterStart      = function() return false end,
            getNextChapter      = function() return 200 end,
            getChapterPagesLeft = function() return 150 - done end,
            getChapterPagesDone = function() return done end,
            getChapterPageCount = function() return 150 end,
            getTocTitleByPage   = function() return "One" end,
            getMaxDepth         = function() return 1 end,
        },
        statistics = { avg_time = 30 },
        view = { state = { page = pageno } },
    }
end

local function expand(fmt, pageno, done)
    return Tokens.expand(fmt, readerAt(pageno, done), pageno, 5, false, 2, nil)
end

local ALT = "[if:chap_page=odd]L[else]R[/if]"

test("chap_page is odd on the first page of a chapter", function()
    eq(expand(ALT, 100, 0), "L")           -- chap_read 1
    eq(expand("%chap_read", 100, 0), "1")
end)

test("chap_page is even on the second page of a chapter", function()
    eq(expand(ALT, 101, 1), "R")           -- chap_read 2
    eq(expand("%chap_read", 101, 1), "2")
end)

test("it alternates on the chapter page, not the book page", function()
    -- Book page 100 is even, chapter page 1 is odd. Before #117 the only
    -- parity available was the book's, so this pair could not be told apart.
    eq(expand("[if:page=odd]bookL[else]bookR[/if]", 100, 0), "bookR")
    eq(expand(ALT, 100, 0), "L")
end)

test("chap_page=even matches directly, not only via else", function()
    eq(expand("[if:chap_page=even]E[/if]", 101, 1), "E")
    eq(expand("[if:chap_page=even]E[/if]", 100, 0), "")
end)

test("the book's own page parity is unchanged", function()
    eq(expand("[if:page=odd]odd[else]even[/if]", 101, 1), "odd")
    eq(expand("[if:page=odd]odd[else]even[/if]", 100, 0), "even")
end)

test("chap_page falls back to the book page in a chapterless book", function()
    -- Same fallback chap_read already uses: whole book as one chapter.
    local ui = readerAt(101, 1)
    ui.toc.getChapterPagesDone = function() return nil end
    ui.toc.getChapterPageCount = function() return nil end
    eq(Tokens.expand("[if:chap_page=odd]L[else]R[/if]", ui, 101, 5, false, 2, nil), "L")
end)

test("no TOC at all leaves chap_page unset rather than guessing", function()
    local ui = readerAt(100, 0)
    ui.toc = nil
    eq(Tokens.expand("[if:chap_page=odd]L[else]R[/if]", ui, 100, 5, false, 2, nil), "R")
    eq(Tokens.expand("[if:not chap_page]none[/if]", ui, 100, 5, false, 2, nil), "none")
end)

test("chap_page is documented as a condition key", function()
    local f = io.open("README.md", "r")
    local readme = f:read("*a")
    f:close()
    assert(readme:find("`chap_page`", 1, true),
           "chap_page is not in the README's condition-key table")
end)

test("chap_page is offered in the token picker beside the book-page form", function()
    local cat = dofile("menu/tokens_catalogue.lua")
    local seen = {}
    for _i, entry in ipairs(cat.CONDITIONALS or {}) do
        seen[tostring(entry.expression or "")] = true
    end
    assert(seen["[if:page=odd]...[/if]"], "the book-page parity entry has moved")
    assert(seen["[if:chap_page=odd]...[/if]"],
           "chap_page is not offered in the picker's if/else chips")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
