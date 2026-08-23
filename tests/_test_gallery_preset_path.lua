-- Tests for Gallery.presetPath: resolving a gallery entry to its repo path.
--
-- index.json carries a preset_url per entry that is always "presets/<slug>.lua",
-- so it's pure redundancy — roughly 7 KB of the index at 170 presets. It can't
-- just be dropped upstream, because released plugin versions read the field
-- straight out of the index and would break on a nil concat. Deriving it here
-- lets a future index omit it safely, while a field that IS present still wins.
--
-- Run: cd into the plugin dir, then `lua tests/_test_gallery_preset_path.lua`.

local Gallery = dofile("preset_gallery.lua")

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
            .. " got="      .. string.format("%q", tostring(actual)), 2)
    end
end

test("uses preset_url when the index provides one", function()
    eq(Gallery.presetPath("placid", "presets/placid.lua"), "presets/placid.lua")
end)

test("a non-standard preset_url still wins", function()
    -- A hand-edited index pointing somewhere else must keep working.
    eq(Gallery.presetPath("placid", "curated/placid-v2.lua"), "curated/placid-v2.lua")
end)

test("derives the path when preset_url is absent", function()
    eq(Gallery.presetPath("placid", nil), "presets/placid.lua")
end)

test("derives the path when preset_url is an empty string", function()
    eq(Gallery.presetPath("placid", ""), "presets/placid.lua")
end)

test("derives for a slug with digits and hyphens", function()
    eq(Gallery.presetPath("2-column-blackberry", nil), "presets/2-column-blackberry.lua")
end)

test("rejects a slug that would escape the presets folder", function()
    -- The result lands in a URL, so path traversal and separators are refused
    -- rather than sanitised.
    eq(Gallery.presetPath("../../etc/passwd", nil), nil, "traversal")
    eq(Gallery.presetPath("a/b", nil), nil, "slash")
    eq(Gallery.presetPath("a b", nil), nil, "space")
    eq(Gallery.presetPath("Upper", nil), nil, "uppercase")
    eq(Gallery.presetPath("under_score", nil), nil, "underscore")
end)

test("rejects an empty or over-long slug", function()
    eq(Gallery.presetPath("", nil), nil, "empty")
    eq(Gallery.presetPath(string.rep("a", 65), nil), nil, "65 chars")
    eq(Gallery.presetPath(string.rep("a", 64), nil), "presets/" .. string.rep("a", 64) .. ".lua", "64 is fine")
end)

test("rejects a non-string slug", function()
    eq(Gallery.presetPath(nil, nil), nil, "nil")
    eq(Gallery.presetPath(42, nil), nil, "number")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
