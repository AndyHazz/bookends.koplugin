-- %genre / %genres in bookends. Bookshelf documents both tokens and bookends
-- did not resolve them, so a template copied from the shelf printed the raw
-- "%genre" in the footer (caught by _test_no_literal_tokens).
--
-- Source is the OPEN DOCUMENT's Keywords field, not calibre: bookends consumes
-- calibre data only through %calibre{...} (see the note above
-- Tokens._calibreFieldsFor), and %title / %author already come from the
-- document. doc_props.keywords is KOReader's own merged value, so a user's
-- edit in Show info wins over what is embedded in the file.
--
-- The SPLITTING rule is bookshelf's, deliberately: comma, semicolon, pipe and
-- newline separate, and a SPACED slash separates a BISAC-style subject
-- ("Fiction / Fantasy") while a bare one does not ("hurt/comfort").
--
-- Usage: lua tests/_test_genre_tokens.lua

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

-- A reader UI whose Keywords field the test controls. Complete enough for the
-- conditional path, which reaches for flow-aware page totals and the TOC.
local function readerWith(keywords, file_keywords)
    return {
        doc_props = { keywords = keywords },
        document = {
            file              = "/library/book.epub",
            getProps          = function() return { keywords = file_keywords } end,
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
end

local function expand(fmt, keywords, file_keywords)
    return Tokens.expand(fmt, readerWith(keywords, file_keywords), 0, 0, false, 2, nil)
end

test("%genres lists every keyword, comma-separated", function()
    eq(expand("%genres", "Fantasy\nFiction"), "Fantasy, Fiction")
end)

test("%genre is the first keyword only", function()
    eq(expand("%genre", "Fantasy\nFiction"), "Fantasy")
end)

test("comma, semicolon and pipe separate as well as newline", function()
    eq(expand("%genres", "Fantasy, Fiction; Horror|Gothic"),
       "Fantasy, Fiction, Horror, Gothic")
end)

test("a spaced slash separates a BISAC subject", function()
    eq(expand("%genres", "Fiction / Fantasy / Epic"), "Fiction, Fantasy, Epic")
end)

test("a bare slash is part of the tag, not a separator", function()
    eq(expand("%genres", "hurt/comfort"), "hurt/comfort")
end)

test("surrounding whitespace is trimmed and empty entries dropped", function()
    eq(expand("%genres", "  Fantasy ,, Fiction  ,  "), "Fantasy, Fiction")
end)

test("a book with no keywords renders empty, not the literal token", function()
    eq(expand("%genres", nil), "")
    eq(expand("%genre", nil), "")
end)

test("an empty Keywords field renders empty", function()
    eq(expand("%genres", ""), "")
end)

test("the document's own keywords are the fallback when doc_props has none", function()
    eq(expand("%genres", nil, "Poetry"), "Poetry")
end)

test("[if:genres] gates on the book having any", function()
    eq(expand("[if:genres]%genre[/if]", "Fantasy"), "Fantasy")
    eq(expand("[if:genres]%genre[/if]", nil), "")
    eq(expand("[if:not genres]none[/if]", nil), "none")
end)

test("[if:genre=value] compares the first genre", function()
    eq(expand('[if:genre="Fantasy"]yes[else]no[/if]', "Fantasy\nFiction"), "yes")
    eq(expand('[if:genre="Fiction"]yes[else]no[/if]', "Fantasy\nFiction"), "no")
end)

test("preview mode shows a placeholder, not the raw token", function()
    local ui = readerWith("Fantasy")
    for _i, tok in ipairs({ "%genre", "%genres" }) do
        local out = Tokens.expandPreview(tok, ui, 120, 5, 2, nil)
        assert(not out:find(tok, 1, true),
               tok .. " survived preview mode as literal text: " .. out)
    end
end)

test("both tokens are in the catalogue", function()
    local cat = dofile("menu/tokens_catalogue.lua")
    local seen = {}
    for _i, entry in ipairs(cat.TOKENS or {}) do
        seen[tostring(entry.token or "")] = true
    end
    assert(seen["%genre"], "%genre is not in the token catalogue")
    assert(seen["%genres"], "%genres is not in the token catalogue")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
