-- Dev-box test runner for bookends_updater.lua.
-- Runs pure-Lua (no KOReader) by stubbing every module the updater requires.
-- Usage: cd into the plugin dir, then `lua _test_updater.lua`.

package.loaded["ui/widget/confirmbox"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["device"] = {
    canOpenLink = function() return false end,
    openLink = function() end,
    unpackArchive = function() return true end,
}
package.loaded["ui/widget/infomessage"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function() end,
    restartKOReader = function() end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }

local Updater = dofile("bookends_updater.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(actual, expected)
    if actual ~= expected then
        error(("expected=%q got=%q"):format(tostring(expected), tostring(actual)), 2)
    end
end

-- Smoke: module loads
test("module loads", function()
    assert(Updater, "Updater module did not load")
    assert(type(Updater.getInstalledVersion) == "function")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
