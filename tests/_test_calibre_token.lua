-- %calibre{field} in bookends (#348). The reader itself is covered by
-- bookshelf's _test_calibre_metadata; this suite covers the TOKEN: brace
-- parsing, case and '#' insensitivity, the empty-field degrade, and the
-- needs() gate that means a template without the token never touches disk.
--
-- Usage: lua tests/_test_calibre_token.lua

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

-- Stub the reader seam. Records whether it was consulted at all, which is how
-- the gate is tested: a template with no %calibre must never reach here.
local consulted = false
local FIELDS = { mood = "cosy", wordcount = "104233", pubdate = "1979" }
Tokens._calibreFieldsFor = function()
    consulted = true
    return FIELDS
end

local ui = {
    document = { file = "/library/book.epub" },
    view = { state = { page = 1 } },
}

local function expand(fmt)
    consulted = false
    return Tokens.expand(fmt, ui, 0, 0, false, 2, nil)
end

test("resolves a custom column", function()
    eq(expand("%calibre{mood}"), "cosy")
end)

test("field lookup ignores case and a leading '#'", function()
    eq(expand("%calibre{Mood}"), "cosy")
    eq(expand("%calibre{#mood}"), "cosy")
    eq(expand("%calibre{#MOOD}"), "cosy")
end)

test("an unknown field renders empty, not the literal token", function()
    eq(expand("%calibre{nosuchcolumn}"), "")
end)

test("standard fields work the same way", function()
    eq(expand("%calibre{pubdate}"), "1979")
end)

test("more than one field in a line each resolve", function()
    eq(expand("%calibre{mood} / %calibre{wordcount}"), "cosy / 104233")
end)

test("no %calibre in the template means the reader is never consulted", function()
    expand("%title")
    assert(not consulted,
           "the calibre file was probed for a template that does not name it; "
           .. "needs() is the gate and it leaked")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
