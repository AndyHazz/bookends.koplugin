-- The per-book metadata tokens ported from bookshelf for #348 parity:
-- %status, %status_label, %rating, %rating_number, %description, %added,
-- %opened, %size, %favourite, %author_count, %authors_short, %quote,
-- %quote_source, %sysused.
--
-- Formatting lives in the vendored token_semantics (and is pinned by the
-- conformance fixture); what this suite covers is bookends' plumbing - that
-- each token reaches the right KOReader source and degrades to empty when that
-- source is absent, which on a reader is the common case.
--
-- Usage: lua tests/_test_metadata_tokens.lua

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = { secondsToClockDuration = function() return "" end }
package.loaded["bookends_overlay_widget"] = {
    BAR_PLACEHOLDER = "\xEF\xBF\xBC", SPACER_PLACEHOLDER = "\xEF\xBF\xB9",
}
package.loaded["bookends_i18n"] = { gettext = function(str) return str end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_path, what)
        if what == "modification" then return 1710000000 end
        if what == "size" then return 2048 end
        return { modification = 1710000000, size = 2048, mode = "file" }
    end,
}
package.loaded["readhistory"] = {
    hist = { { file = "/library/dune.epub", time = 1720000000 } },
}
package.loaded["readcollection"] = {
    coll = { favorites = { ["/library/dune.epub"] = true } },
}
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
local function eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. " expected=" .. string.format("%q", tostring(e))
              .. " got=" .. string.format("%q", tostring(a)), 2)
    end
end

local function mkUI(overrides)
    overrides = overrides or {}
    local ui = {
        document = {
            file = "/library/dune.epub",
            getCurrentPage = function() return 100 end,
            hasHiddenFlows = function() return false end,
            getPageCount = function() return 500 end,
            getTotalPagesLeft = function() return 400 end,
            getProps = function()
                return {
                    title = "Dune",
                    authors = "Frank Herbert\nBrian Herbert\nKevin Anderson",
                    description = "A desert planet and a great deal of spice.",
                }
            end,
        },
        doc_settings = {
            readSetting = function(_self, key)
                if key == "summary" then
                    return { status = "complete", rating = 4 }
                end
                return nil
            end,
        },
        annotation = {
            annotations = {
                { text = "The spice must flow.", drawer = "lighten" },
                { text = "Fear is the mind-killer.", drawer = "lighten" },
            },
            getNumberOfHighlightsAndNotes = function() return 2, 0 end,
            getNumberOfAnnotations = function() return 2 end,
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
            getTocTicks = function() return { [1] = { 1, 200 } } end,
        },
        view = { state = { page = 100 } },
        statistics = { avg_time = 30 },
    }
    for k, v in pairs(overrides) do ui[k] = v end
    return ui
end

local function ex(fmt, ui) return Tokens.expand(fmt, ui or mkUI(), 0, 0, false, 2, nil) end

test("%status normalises KOReader's vocabulary", function()
    eq(ex("%status"), "finished")
end)

test("%status_label reads as words", function()
    eq(ex("%status_label"), "Finished")
end)

test("%status is 'unread' when there is no DocSettings summary", function()
    local ui = mkUI{ doc_settings = { readSetting = function() return nil end } }
    eq(ex("%status", ui), "unread")
end)

test("%rating is a star row, %rating_number the bare number", function()
    eq(ex("%rating"), "\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x85\xE2\x98\x86")
    eq(ex("%rating_number"), "4")
end)

test("an unrated book gives empty for both rating tokens", function()
    local ui = mkUI{ doc_settings = {
        readSetting = function() return { status = "reading" } end } }
    eq(ex("%rating", ui), "")
    eq(ex("%rating_number", ui), "")
end)

test("%description comes from the document properties", function()
    eq(ex("%description"), "A desert planet and a great deal of spice.")
end)

test("%size formats the file size", function()
    eq(ex("%size"), "2 KB")
end)

test("%added uses the file modification time", function()
    eq(ex("%added"), os.date("%Y-%m-%d", 1710000000))
end)

test("%opened uses the read history", function()
    eq(ex("%opened"), os.date("%Y-%m-%d", 1720000000))
end)

test("%author_count and %authors_short collapse a long author list", function()
    eq(ex("%author_count"), "3")
    eq(ex("%authors_short"), "Frank Herbert, Brian Herbert, et al.")
end)

test("%favourite shows a glyph only for a favourited book", function()
    local got = ex("%favourite")
    assert(got ~= "", "expected a glyph for a favourited book")
    local ui = mkUI{}
    ui.document.file = "/library/other.epub"
    eq(ex("%favourite", ui), "", "a non-favourite must render empty")
end)

test("%quote and %quote_source read the highlights", function()
    local q = ex("%quote")
    assert(q:find("spice must flow", 1, true), "no highlight text in: " .. q)
    assert(q:find("\xE2\x80\x9C", 1, true), "quote should be curly-quoted")
    local src = ex("%quote_source")
    assert(src:find("Dune", 1, true), "no title in source: " .. src)
end)

test("%quote is empty when the book has no highlights", function()
    local ui = mkUI{ annotation = { annotations = {},
        getNumberOfHighlightsAndNotes = function() return 0, 0 end,
        getNumberOfAnnotations = function() return 0 end } }
    eq(ex("%quote", ui), "")
    eq(ex("%quote_source", ui), "")
end)

test("%sysused reports memory in MiB", function()
    local got = ex("%sysused")
    assert(got:find("MiB", 1, true) or got == "",
           "expected a MiB value or empty, got: " .. got)
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
