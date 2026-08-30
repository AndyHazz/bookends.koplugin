-- Every documented token must RESOLVE - never survive as its own literal text.
--
-- This is the class of bug that reached a render during the #348 sweep:
-- bookshelf's default status template uses %wifi_icon, bookends only had
-- %wifi, and the status bar showed the characters "%wifi_icon" to the user.
-- A set-difference audit of token NAMES cannot see that, because both plugins
-- "have a wifi token" - they just disagree on its name.
--
-- Empty output is fine and often correct (a book with one author has no
-- %author_2). The literal token surviving is never correct: to a reader it
-- looks like the plugin is broken.
--
-- The token list is read from the README and the picker catalogue, so a token
-- that is documented or offered but never wired fails here rather than in
-- someone's status bar.
--
-- Usage: lua tests/_test_no_literal_tokens.lua

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function(_fmt, s)
        if not s or s <= 0 then return "" end
        return string.format("%dh %02dm", math.floor(s / 3600),
                             math.floor((s % 3600) / 60))
    end,
    -- The ETA tokens format a wall-clock time from an epoch.
    secondsToHour = function(_epoch) return "14:30" end,
    secondsToDate = function(_epoch) return "2026-08-29" end,
}
package.loaded["bookends_overlay_widget"] = {
    BAR_PLACEHOLDER = "\xEF\xBF\xBC", SPACER_PLACEHOLDER = "\xEF\xBF\xB9",
}
package.loaded["bookends_i18n"] = { gettext = function(str) return str end }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_p, what)
        if what == "modification" then return 1710000000 end
        if what == "size" then return 2048 end
        return { modification = 1710000000, size = 2048, mode = "file" }
    end,
}
package.loaded["util"] = {
    diskUsage = function() return { available = 13207024435, total = 32e9 } end,
}
package.loaded["ui/network/manager"] = {
    isWifiOn = function() return true end,
    isConnected = function() return true end,
}
package.loaded["readhistory"] = { hist = { { file = "/lib/b.epub", time = 1720000000 } } }
package.loaded["readcollection"] = { coll = { favorites = { ["/lib/b.epub"] = true } } }
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

-- A book and reader state rich enough that most tokens have something to say.
local ui = {
    document = {
        file = "/lib/b.epub",
        getCurrentPage    = function() return 100 end,
        hasHiddenFlows    = function() return false end,
        getPageCount      = function() return 500 end,
        getTotalPagesLeft = function() return 400 end,
        getProps = function()
            return { title = "Dune", authors = "Frank Herbert\nBrian Herbert",
                     series = "Dune", series_index = 1, language = "en",
                     description = "Spice." }
        end,
    },
    doc_settings = { readSetting = function(_s, k)
        if k == "summary" then return { status = "complete", rating = 4 } end
        return nil
    end },
    annotation = {
        annotations = { { text = "The spice must flow.", drawer = "lighten" },
                        { text = "note", drawer = "lighten", note = "n" },
                        { page = 3 } },
        getNumberOfHighlightsAndNotes = function() return 1, 1 end,
        getNumberOfAnnotations = function() return 3 end,
    },
    toc = {
        toc = { { page = 1, title = "One", depth = 1 },
                { page = 50, title = "2. Two", depth = 1 } },
        getPreviousChapter  = function() return 50 end,
        isChapterStart      = function() return false end,
        getNextChapter      = function() return 200 end,
        getChapterPagesLeft = function() return 100 end,
        getChapterPagesDone = function() return 50 end,
        getChapterPageCount = function() return 150 end,
        getTocTitleByPage   = function() return "2. Two" end,
        getMaxDepth         = function() return 1 end,
        getTocTicks         = function() return { [1] = { 1, 50, 200 } } end,
    },
    view = { state = { page = 100 } },
    statistics = { avg_time = 30, id_curr_book = 1,
                   mem_read_pages = 0, mem_read_time = 0 },
}

-- Collect the token names this plugin PROMISES: the README reference tables
-- and the picker catalogue.
local function documentedTokens()
    local names, seen = {}, {}
    local function add(n)
        if n and n ~= "" and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    local f = assert(io.open("README.md", "r"))
    for line in f:lines() do
        local n = line:match("^| `%%([a-z_0-9]+)`")
        if n then add(n) end
    end
    f:close()
    local cat = dofile("menu/tokens_catalogue.lua")
    for _i, entry in ipairs(cat.TOKENS or {}) do
        local n = tostring(entry.token or ""):match("^%%([a-z_0-9]+)$")
        if n then add(n) end
    end
    table.sort(names)
    return names
end

local names = documentedTokens()

test("the token inventory is non-trivial", function()
    assert(#names > 60, "only found " .. #names .. " tokens; the parse is wrong")
end)

local leaked = {}
for _i, name in ipairs(names) do
    local out = Tokens.expand("%" .. name, ui, 120, 5, false, 2, nil)
    -- The one legitimate way a "%name" string may appear is when the token
    -- resolves to text that itself contains a percent sign, so compare against
    -- the exact literal only.
    if type(out) == "string" and out:find("%" .. name, 1, true) then
        leaked[#leaked + 1] = "%" .. name
    end
end

test("no documented token survives as literal text", function()
    assert(#leaked == 0,
        #leaked .. " token(s) rendered as their own name: "
        .. table.concat(leaked, " "))
end)

-- ── The cross-plugin check ─────────────────────────────────────────────────
--
-- This is the one that would have caught %wifi_icon before it reached a
-- render. #348 is about templates being COPIED between the two plugins, so
-- the real question is not "does bookends resolve its own tokens" but "does
-- bookends resolve a line written for bookshelf". A set-difference of token
-- names cannot answer that: both plugins have a Wi-Fi token, they just
-- disagreed on its name.
--
-- Absences that are DELIBERATE are listed here with their reason, so this
-- test documents the scope decisions rather than just tolerating gaps. Any
-- token not on this list must resolve.
local DELIBERATELY_ABSENT = {
    books_read    = "library-wide aggregate; bookends is per-book by design",
    books_started = "library-wide aggregate; bookends is per-book by design",
    hardcover_rating = "needs bookshelf's Hardcover client, auth and cache DB",
    hardcover_stars  = "needs bookshelf's Hardcover client, auth and cache DB",
    sysused       = "present, but reads /proc; empty under the test stubs",
    full_width    = "a CONDITION key, not a printable token",
    connected     = "a CONDITION key, not a printable token",
    charging      = "a CONDITION key, not a printable token",
}

local SIBLING_README = "../bookshelf.koplugin/README.md"

local function siblingTokens()
    local f = io.open(SIBLING_README, "r")
    if not f then return nil end
    local names, seen = {}, {}
    for line in f:lines() do
        -- Cheatsheet rows may list several tokens in one cell.
        for n in line:gmatch("`%%([a-z_0-9]+)`") do
            if not seen[n] then seen[n] = true; names[#names + 1] = n end
        end
    end
    f:close()
    table.sort(names)
    return names
end

local sib = siblingTokens()

test("bookshelf's documented tokens resolve here too", function()
    if not sib then
        print("  SKIP: no sibling checkout at " .. SIBLING_README)
        return
    end
    assert(#sib > 40, "only found " .. #sib .. " sibling tokens; parse is wrong")
    local gaps = {}
    for _i, name in ipairs(sib) do
        if not DELIBERATELY_ABSENT[name] then
            local out = Tokens.expand("%" .. name, ui, 120, 5, false, 2, nil)
            if type(out) == "string" and out:find("%" .. name, 1, true) then
                gaps[#gaps + 1] = "%" .. name
            end
        end
    end
    assert(#gaps == 0,
        #gaps .. " token(s) documented by bookshelf render as literal text "
        .. "here, so a copied template would show them raw: "
        .. table.concat(gaps, " "))
end)

-- ── The same rule, in PREVIEW mode ─────────────────────────────────────────
--
-- The line editor and the position-menu subtitles render through
-- expandPreview, which swaps each token for a short bracketed placeholder so a
-- reader sees the SHAPE of the line without a document open. Tokens missing
-- from that map fell through to `return "%" .. token` - the raw literal, in
-- exactly the surface this suite exists to keep clean. The suite only ever
-- exercised the real expansion, so it could not see it.
test("no documented token survives as literal text in PREVIEW mode", function()
    local gaps = {}
    for _i, name in ipairs(names) do
        local out = Tokens.expandPreview("%" .. name, ui, 120, 5, 2, nil)
        if type(out) == "string" and out:find("%" .. name, 1, true) then
            gaps[#gaps + 1] = "%" .. name
        end
    end
    assert(#gaps == 0,
        #gaps .. " token(s) show as raw text in the line editor and menu "
        .. "subtitles: " .. table.concat(gaps, " "))
end)

test("the width-modifier form previews without leaking either", function()
    local gaps = {}
    for _i, name in ipairs(names) do
        local out = Tokens.expandPreview("%" .. name .. "{200}", ui, 120, 5, 2, nil)
        if type(out) == "string" and out:find("%" .. name, 1, true) then
            gaps[#gaps + 1] = "%" .. name .. "{200}"
        end
    end
    assert(#gaps == 0,
        #gaps .. " token(s) leak their raw name when width-capped: "
        .. table.concat(gaps, " "))
end)

print(pass .. " passed, " .. fail .. " failed  (" .. #names .. " own tokens, "
      .. (sib and #sib or 0) .. " sibling tokens checked)")
os.exit(fail == 0 and 0 or 1)
