-- The "Bookshelf status line" mirror (#348): bookends renders the same status
-- line bookshelf shows across the top of its expanded shelf, so switching
-- between the shelf and the reader does not change what that strip says.
--
-- Interop is through a settings KEY, not through bookshelf's code: reading
-- G_reader_settings needs no pcall(require) of a sibling plugin, so it cannot
-- break when bookshelf refactors. What this suite pins is the resolution -
-- especially the case that matters most, where bookshelf has never written the
-- key because the user never edited a region, and the mirror must still show
-- what bookshelf actually renders rather than nothing.
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

local function fakeSettings(value)
    return { readSetting = function(_self, key)
        if key == StatusLine.SETTINGS_KEY then return value end
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

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
