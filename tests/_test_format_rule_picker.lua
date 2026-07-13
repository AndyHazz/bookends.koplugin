-- Dev-box tests for the pure format-rule-picker helper in
-- preset_manager_modal.lua. Usage: lua tests/_test_format_rule_picker.lua
--
-- The module is a plain namespace table (`return PresetManagerModal`), but it
-- performs ~30 heavy KOReader UI requires at load. We stub each with a
-- "universal table" that indexes/calls to more universal tables, so the
-- module's load-time work (WidgetContainer:extend{}, ffi.typeof(), the
-- ColourFlag method definitions, etc.) survives without a KOReader runtime.
-- Then we call the pure helper on the returned table directly.

local function universal()
    local t = {}
    return setmetatable(t, {
        __index = function() return universal() end,
        __call  = function() return universal() end,
    })
end

for _, name in ipairs({
    "ffi/blitbuffer", "ui/widget/button", "ui/widget/container/centercontainer",
    "ui/widget/confirmbox", "device", "ui/font",
    "ui/widget/container/framecontainer", "ui/geometry", "ui/gesturerange",
    "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
    "ui/widget/container/inputcontainer", "ui/widget/inputdialog",
    "ui/widget/container/leftcontainer", "ui/widget/linewidget",
    "ui/widget/notification", "preset_manager", "preset_naming", "ui/size",
    "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/uimanager",
    "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/widget/overlapgroup",
    "ui/widget/container/widgetcontainer", "ffi", "menu.library_modal",
    "preset_gallery", "ui/widget/buttondialogtitle", "ui/widget/iconwidget",
    "ffi/util", "util",
}) do
    package.loaded[name] = universal()
end
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }

local PMM = dofile("menu/preset_manager_modal.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, b, m)
    if a ~= b then error((m or "") .. " expected=" .. tostring(b) .. " got=" .. tostring(a), 2) end
end

test("prepends a hidden-option row", function()
    local out = PMM.formatRulePickerItems({})
    eq(#out, 1)
    eq(out[1].is_hidden_option, true)
end)

test("hidden row is first, presets follow in order", function()
    local entries = {
        { name = "Alpha", filename = "alpha.lua" },
        { name = "Beta",  filename = "beta.lua" },
    }
    local out = PMM.formatRulePickerItems(entries)
    eq(#out, 3)
    eq(out[1].is_hidden_option, true)
    eq(out[2].filename, "alpha.lua")
    eq(out[3].filename, "beta.lua")
end)

test("does not mutate the input array", function()
    local entries = { { filename = "alpha.lua" } }
    PMM.formatRulePickerItems(entries)
    eq(#entries, 1, "input should be untouched")
    eq(entries[1].filename, "alpha.lua")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
