-- Bookshelf's status line in the reader (#348). BOOKENDS DOES NOT DRAW IT:
-- bookshelf draws it itself, with the same builder its expanded shelf uses, so
-- the two are identical by construction rather than by two renderers agreeing,
-- and the feature works with bookends absent. All bookends does is get out of
-- the way - move its top row, and any top-anchored bar, below the strip.
--
-- Interop is through settings KEYS, not through bookshelf's code: reading
-- G_reader_settings needs no pcall(require) of a sibling plugin, so it cannot
-- break when bookshelf refactors. What this suite pins is that contract - the
-- resolution of the line's own config (still read here, because the picker
-- subtitle and the parity checker both care), the switch, and the reserved
-- height, including the case that matters most: bookshelf never writes the
-- regions key until a region is edited, so the defaults have to be right.
--
-- Usage: lua tests/_test_bookshelf_status_line.lua

local StatusLine = dofile("status_line.lua")

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

local function fakeSettings(value, reserved, show_in_reader)
    return { readSetting = function(_self, key)
        if key == StatusLine.SETTINGS_KEY then return value end
        if key == StatusLine.RESERVED_KEY then return reserved end
        if key == StatusLine.SHOW_IN_READER_KEY then return show_in_reader end
        return nil
    end }
end

test("the settings key is the one bookshelf writes", function()
    eq(StatusLine.SETTINGS_KEY, "bookshelf_hero_regions")
    eq(StatusLine.REGION_KEY, "status")
end)

test("no stored regions at all still yields bookshelf's default line", function()
    local cfg, customised = StatusLine.fromSettings(fakeSettings(nil))
    eq(customised, false, "nothing was stored")
    assert(cfg.template:find("%%time_12h", 1, false),
           "the default template should carry the clock: " .. cfg.template)
    eq(cfg.font_size, 14)
    eq(cfg.alignment, "right")
    eq(cfg.bold, false)
end)

test("a stored override wins field by field", function()
    local cfg = StatusLine.fromSettings(fakeSettings({
        status = { template = "%title", font_size = 22, bold = true },
    }))
    eq(cfg.template, "%title")
    eq(cfg.font_size, 22)
    eq(cfg.bold, true)
    -- Untouched fields still come from the default.
    eq(cfg.alignment, "right", "alignment was not overridden")
end)

test("a malformed template falls back rather than rendering garbage", function()
    local cfg = StatusLine.fromSettings(fakeSettings({
        status = { template = { "not", "a", "string" }, font_size = 18 },
    }))
    eq(cfg.template, StatusLine.DEFAULTS.template)
    eq(cfg.font_size, 18, "the valid sibling field still applies")
end)

test("non-scalar fields are ignored, not copied through", function()
    local cfg = StatusLine.fromSettings(fakeSettings({
        status = { template = "%title", junk = { 1, 2, 3 } },
    }))
    eq(type(cfg.junk), "nil")
end)

-- The flag means "the user customised the STATUS line", not "bookshelf is
-- installed" - there is no reliable signal for the latter. Editing some other
-- region must not make bookends claim the status line was customised.
test("editing another region does not count as customising the status line", function()
    local cfg, customised = StatusLine.fromSettings(fakeSettings({ title = {} }))
    eq(customised, false)
    eq(cfg.template, StatusLine.DEFAULTS.template)
end)

test("resolve never hands back the shared defaults table", function()
    local cfg = StatusLine.resolve(nil)
    cfg.font_size = 99
    eq(StatusLine.DEFAULTS.font_size, 14, "the defaults were mutated")
end)

test("a broken settings object degrades instead of raising", function()
    local ok, cfg = pcall(StatusLine.fromSettings, {
        readSetting = function() error("settings exploded") end,
    })
    assert(ok, "fromSettings raised: " .. tostring(cfg))
    eq(cfg.template, StatusLine.DEFAULTS.template)
end)

test("a published height is only honoured while the switch is on", function()
    -- Bookshelf writes the height when it PAINTS, and has no chance to clear
    -- it if it is disabled or uninstalled between sessions. Reserving on the
    -- bare number left a permanent gap at the top of the reader for a strip
    -- nobody draws, so the switch is the gate and the height is only the size.
    eq(StatusLine.reservedHeight(fakeSettings(nil, 60, nil)), 0)
    eq(StatusLine.reservedHeight(fakeSettings(nil, 60, false)), 0)
    eq(StatusLine.reservedHeight(fakeSettings(nil, 60, true)), 60)
end)

test("the reader switch is its own key, not a field on the status region", function()
    -- It used to live in the region entry. The line editor's "Default" button
    -- clears the draft and copies every key out of DEFAULTS, so resetting the
    -- status line's WORDING also silently switched the reader strip off. A
    -- region edit must not be able to reach this.
    eq(StatusLine.DEFAULTS.show_in_reader, nil)
    eq(StatusLine.showInReader(fakeSettings(nil, nil, nil)), false)
    eq(StatusLine.showInReader(fakeSettings(nil, nil, true)), true)
    -- A region entry claiming the old field name has no effect any more.
    eq(StatusLine.showInReader(
        fakeSettings({ status = { show_in_reader = true } }, nil, nil)), false)
end)

test("showInReader degrades to false rather than raising", function()
    eq(StatusLine.showInReader(nil), false)
    local ok, v = pcall(StatusLine.showInReader, {
        readSetting = function() error("settings exploded") end,
    })
    assert(ok, "showInReader raised: " .. tostring(v))
    eq(v, false)
end)

test("reservedHeight degrades to 0 rather than raising", function()
    eq(StatusLine.reservedHeight(nil), 0)
    eq(StatusLine.reservedHeight({}), 0)
    local ok, v = pcall(StatusLine.reservedHeight, {
        readSetting = function() error("settings exploded") end,
    })
    assert(ok, "reservedHeight raised: " .. tostring(v))
    eq(v, 0)
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
