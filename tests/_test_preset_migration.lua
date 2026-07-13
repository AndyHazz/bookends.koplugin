-- Dev-box tests for bookends_migrations.lua.
-- Usage: lua tests/_test_preset_migration.lua

package.loaded["bookends_i18n"] = { gettext = function(s) return s end }
package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    home_dir = "/",
}

local Migrations = dofile("bookends_migrations.lua")

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

-- Settings-shape (progress_bar_<n> as top-level keys)
test("settings shape: copies bar_colors.tick to enabled bar's colors.tick", function()
    local tbl = {
        bar_colors = { tick = { grey = 0x40 } },
        progress_bar_1 = { enabled = true, colors = nil },
    }
    Migrations.barColorsToPerBar(tbl)
    assert(tbl.progress_bar_1.colors, "bar.colors should be created")
    assert(tbl.progress_bar_1.colors.tick, "bar.colors.tick should be set")
    eq(tbl.progress_bar_1.colors.tick.grey, 0x40)
    eq(tbl.bar_colors, nil, "bar_colors should be stripped")
end)

test("settings shape: per-bar value beats global (nil-fields-only)", function()
    local tbl = {
        bar_colors = { tick = { grey = 0x40 } },
        progress_bar_1 = { enabled = true, colors = { tick = { grey = 0x80 } } },
    }
    Migrations.barColorsToPerBar(tbl)
    eq(tbl.progress_bar_1.colors.tick.grey, 0x80, "per-bar 0x80 should beat global 0x40")
end)

test("settings shape: skips disabled bars", function()
    local tbl = {
        bar_colors = { tick = { grey = 0x40 } },
        progress_bar_1 = { enabled = false, colors = nil },
        progress_bar_2 = { enabled = true, colors = nil },
    }
    Migrations.barColorsToPerBar(tbl)
    eq(tbl.progress_bar_1.colors, nil, "disabled bar should NOT get colors table")
    assert(tbl.progress_bar_2.colors and tbl.progress_bar_2.colors.tick,
        "enabled bar should get colors.tick")
end)

test("settings shape: drops read_height_pct and unread_height_pct", function()
    local tbl = {
        bar_colors = { read_height_pct = 80, unread_height_pct = 60, tick = { grey = 0x40 } },
        progress_bar_1 = { enabled = true, colors = nil },
    }
    Migrations.barColorsToPerBar(tbl)
    eq(tbl.progress_bar_1.colors.read_height_pct, nil, "should NOT propagate read_height_pct")
    eq(tbl.progress_bar_1.colors.unread_height_pct, nil, "should NOT propagate unread_height_pct")
    eq(tbl.progress_bar_1.colors.tick.grey, 0x40, "should still propagate tick")
end)

test("settings shape: standalone tick_height_pct moves into bars", function()
    local tbl = {
        tick_height_pct = 150,
        progress_bar_1 = { enabled = true, colors = nil },
    }
    Migrations.barColorsToPerBar(tbl)
    eq(tbl.progress_bar_1.colors.tick_height_pct, 150)
    eq(tbl.tick_height_pct, nil, "standalone should be stripped")
end)

test("settings shape: standalone tick_width_multiplier moves into bars", function()
    local tbl = {
        tick_width_multiplier = 3,
        progress_bar_1 = { enabled = true, colors = nil },
    }
    Migrations.barColorsToPerBar(tbl)
    eq(tbl.progress_bar_1.colors.tick_width_multiplier, 3)
    eq(tbl.tick_width_multiplier, nil)
end)

test("settings shape: idempotent — empty table is unchanged", function()
    local tbl = { active_preset_filename = "foo.lua" }
    Migrations.barColorsToPerBar(tbl)
    eq(tbl.active_preset_filename, "foo.lua")
    eq(tbl.bar_colors, nil)
end)

test("settings shape: preserves metro_fill / track legacy keys", function()
    local tbl = {
        bar_colors = { metro_fill = { grey = 0x40 }, track = { grey = 0x80 } },
        progress_bar_1 = { enabled = true, colors = nil },
    }
    Migrations.barColorsToPerBar(tbl)
    -- Legacy keys propagate as-is; Colour.resolveBarColors's shim aliases
    -- them at paint time, so this preserves the user's intent.
    eq(tbl.progress_bar_1.colors.metro_fill.grey, 0x40)
    eq(tbl.progress_bar_1.colors.track.grey, 0x80)
end)

test("preset-file shape: progress_bars array form is migrated", function()
    local tbl = {
        bar_colors = { tick = { grey = 0x40 } },
        progress_bars = {
            [1] = { enabled = true, colors = nil },
            [2] = { enabled = false, colors = nil },
        },
    }
    Migrations.barColorsToPerBar(tbl)
    assert(tbl.progress_bars[1].colors and tbl.progress_bars[1].colors.tick)
    eq(tbl.progress_bars[2].colors, nil, "disabled bar in array form should be skipped")
    eq(tbl.bar_colors, nil)
end)

test("returns true when changes were made", function()
    local tbl = {
        bar_colors = { tick = { grey = 0x40 } },
        progress_bar_1 = { enabled = true },
    }
    local changed = Migrations.barColorsToPerBar(tbl)
    eq(changed, true)
end)

test("settings shape: inline-only bar_colors returns true and strips key", function()
    -- bar_colors with ONLY inline-thickness keys: nothing meaningful
    -- to propagate to bars (those keys get stripped from src), but
    -- the originals must still be removed and the function should
    -- return true so the caller persists the change.
    local tbl = {
        bar_colors = { read_height_pct = 80, unread_height_pct = 60 },
        progress_bar_1 = { enabled = true, colors = nil },
    }
    local changed = Migrations.barColorsToPerBar(tbl)
    eq(changed, true, "should return true even when src is empty after strip")
    eq(tbl.bar_colors, nil, "bar_colors should be stripped")
    eq(tbl.progress_bar_1.colors, nil, "bar should NOT get a colors table")
end)

test("returns false when nothing to migrate", function()
    local tbl = { progress_bar_1 = { enabled = true, colors = {} } }
    local changed = Migrations.barColorsToPerBar(tbl)
    eq(changed, false)
end)

test("seedManualActivePreset: seeds from active_preset_filename", function()
    local tbl = { active_preset_filename = "kobo_like.lua" }
    local changed = Migrations.seedManualActivePreset(tbl)
    eq(changed, true)
    eq(tbl.manual_active_preset_filename, "kobo_like.lua")
end)

test("seedManualActivePreset: no-op when already set", function()
    local tbl = {
        active_preset_filename = "kobo_like.lua",
        manual_active_preset_filename = "existing.lua",
    }
    local changed = Migrations.seedManualActivePreset(tbl)
    eq(changed, false)
    eq(tbl.manual_active_preset_filename, "existing.lua")
end)

test("seedManualActivePreset: no-op when there's nothing active yet", function()
    local tbl = {}
    local changed = Migrations.seedManualActivePreset(tbl)
    eq(changed, false)
    eq(tbl.manual_active_preset_filename, nil)
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
