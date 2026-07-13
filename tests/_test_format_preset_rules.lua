-- Dev-box tests for the #87 format-preset-rules helpers in preset_manager.lua.
-- Usage: lua tests/_test_format_preset_rules.lua

local PresetManager = dofile("preset_manager.lua")

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

-- Minimal fake settings object: readSetting/saveSetting/delSetting over a
-- plain table, matching the subset of LuaSettings' API these helpers use.
local function fakeBookends(initial)
    local data = initial or {}
    return {
        settings = {
            data = data,
            readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end,
            delSetting = function(_, k) data[k] = nil end,
        },
    }
end

test("pruneManualDefault: clears when it matches the deleted filename", function()
    local b = fakeBookends({ manual_active_preset_filename = "foo.lua" })
    PresetManager.pruneManualDefault(b, "foo.lua")
    eq(b.settings.data.manual_active_preset_filename, nil)
end)

test("pruneManualDefault: leaves it alone when it doesn't match", function()
    local b = fakeBookends({ manual_active_preset_filename = "bar.lua" })
    PresetManager.pruneManualDefault(b, "foo.lua")
    eq(b.settings.data.manual_active_preset_filename, "bar.lua")
end)

test("renameManualDefault: updates when it matches the old filename", function()
    local b = fakeBookends({ manual_active_preset_filename = "foo.lua" })
    PresetManager.renameManualDefault(b, "foo.lua", "foo_2.lua")
    eq(b.settings.data.manual_active_preset_filename, "foo_2.lua")
end)

test("renameManualDefault: leaves it alone when it doesn't match", function()
    local b = fakeBookends({ manual_active_preset_filename = "bar.lua" })
    PresetManager.renameManualDefault(b, "foo.lua", "foo_2.lua")
    eq(b.settings.data.manual_active_preset_filename, "bar.lua")
end)

test("pruneFormatRules: removes only entries pointing at the deleted file", function()
    local b = fakeBookends({ format_preset_rules = { CBZ = "foo.lua", PDF = "bar.lua" } })
    PresetManager.pruneFormatRules(b, "foo.lua")
    eq(b.settings.data.format_preset_rules.CBZ, nil)
    eq(b.settings.data.format_preset_rules.PDF, "bar.lua")
end)

test("pruneFormatRules: leaves HIDDEN entries alone", function()
    local b = fakeBookends({ format_preset_rules = { CBZ = "HIDDEN" } })
    PresetManager.pruneFormatRules(b, "foo.lua")
    eq(b.settings.data.format_preset_rules.CBZ, "HIDDEN")
end)

test("renameFormatRules: updates every entry pointing at the old filename", function()
    local b = fakeBookends({ format_preset_rules = { CBZ = "foo.lua", CBT = "foo.lua", PDF = "bar.lua" } })
    PresetManager.renameFormatRules(b, "foo.lua", "foo_2.lua")
    eq(b.settings.data.format_preset_rules.CBZ, "foo_2.lua")
    eq(b.settings.data.format_preset_rules.CBT, "foo_2.lua")
    eq(b.settings.data.format_preset_rules.PDF, "bar.lua")
end)

test("setManualActivePreset: sets both active and manual-default pointers", function()
    local b = fakeBookends({})
    -- setActivePresetFilename is defined via Bookends: syntax inside attach();
    -- attach mutates a plain table just like a class, so calling it on `b`
    -- (the fake instance) directly works without any inheritance machinery.
    PresetManager.attach(b)
    b:setManualActivePreset("foo.lua")
    eq(b.settings.data.active_preset_filename, "foo.lua")
    eq(b.settings.data.manual_active_preset_filename, "foo.lua")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
