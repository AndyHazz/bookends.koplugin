-- Dev-box test runner for preset_naming.lua. Pure Lua, no KOReader deps.
-- Usage: cd into the plugin dir, then `lua _test_preset_naming.lua`.
-- Exits non-zero on failure.

local PresetNaming = dofile("preset_naming.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "")
            .. " expected=" .. string.format("%q", tostring(expected))
            .. " got="      .. string.format("%q", tostring(actual)), 2)
    end
end

test("empty list returns bare stem", function()
    eq(PresetNaming.nextUntitledName({}, "Untitled"), "Untitled")
end)

test("unrelated presets do not block bare stem", function()
    local presets = { {name = "Minimal"}, {name = "Classic"} }
    eq(PresetNaming.nextUntitledName(presets, "Untitled"), "Untitled")
end)

test("bare stem taken returns numbered suffix", function()
    local presets = { {name = "Untitled"} }
    eq(PresetNaming.nextUntitledName(presets, "Untitled"), "Untitled 2")
end)

test("contiguous suffixes return next integer", function()
    local presets = {
        {name = "Untitled"},
        {name = "Untitled 2"},
        {name = "Untitled 3"},
    }
    eq(PresetNaming.nextUntitledName(presets, "Untitled"), "Untitled 4")
end)

test("gap in suffixes reclaims bare stem", function()
    local presets = { {name = "Untitled 5"} }
    eq(PresetNaming.nextUntitledName(presets, "Untitled"), "Untitled")
end)

test("gap at position 2 reclaims Untitled 2", function()
    local presets = { {name = "Untitled"}, {name = "Untitled 3"} }
    eq(PresetNaming.nextUntitledName(presets, "Untitled"), "Untitled 2")
end)

test("custom stem respected", function()
    local presets = { {name = "New"} }
    eq(PresetNaming.nextUntitledName(presets, "New"), "New 2")
end)

test("presets with similar-but-not-matching names ignored", function()
    local presets = {
        {name = "Untitled Saga"},
        {name = "My Untitled"},
        {name = "UntitledX"},
    }
    eq(PresetNaming.nextUntitledName(presets, "Untitled"), "Untitled")
end)

io.stdout:write(string.format("%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
