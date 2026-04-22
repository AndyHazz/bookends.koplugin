-- Dev-box test runner for bookends_colour.lua parseColorValue.
-- Runs pure-Lua (no KOReader) by stubbing ffi/blitbuffer with in-memory
-- constructors so we can assert on r/g/b/alpha without FFI.
-- Usage: cd into the plugin dir, then `lua _test_colour.lua`.
-- Exits non-zero on failure; no external dependencies.

package.loaded["ffi/blitbuffer"] = {
    ColorRGB32 = function(r, g, b, a)
        return { kind = "rgb32", r = r, g = g, b = b, a = a }
    end,
    Color8 = function(v)
        return { kind = "color8", v = v }
    end,
}

local Colour = dofile("bookends_colour.lua")

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
            .. " expected=" .. tostring(expected)
            .. " got=" .. tostring(actual), 2)
    end
end

-- --- nil / false passthrough ------------------------------------------------
test("nil → nil", function()
    eq(Colour.parseColorValue(nil, true), nil)
end)
test("false → false (transparent)", function()
    eq(Colour.parseColorValue(false, true), false)
end)

-- --- hex on colour-enabled screen ------------------------------------------
test("hex black on colour → ColorRGB32(0,0,0,255)", function()
    local c = Colour.parseColorValue({ hex = "#000000" }, true)
    eq(c.kind, "rgb32"); eq(c.r, 0); eq(c.g, 0); eq(c.b, 0); eq(c.a, 0xFF)
end)
test("hex purple on colour → ColorRGB32(127,8,255,255)", function()
    local c = Colour.parseColorValue({ hex = "#7F08FF" }, true)
    eq(c.kind, "rgb32"); eq(c.r, 0x7F); eq(c.g, 0x08); eq(c.b, 0xFF)
end)

-- --- hex on greyscale screen: Rec.601 luminance ----------------------------
test("hex white on greyscale → Color8(255)", function()
    local c = Colour.parseColorValue({ hex = "#FFFFFF" }, false)
    eq(c.kind, "color8"); eq(c.v, 255)
end)
test("hex pure red on greyscale → Color8(76)   [0.299 × 255 = 76.245]", function()
    local c = Colour.parseColorValue({ hex = "#FF0000" }, false)
    eq(c.kind, "color8"); eq(c.v, 76)
end)
test("hex pure green on greyscale → Color8(150) [0.587 × 255 = 149.685]", function()
    local c = Colour.parseColorValue({ hex = "#00FF00" }, false)
    eq(c.kind, "color8"); eq(c.v, 150)
end)

-- --- grey and raw-byte passthrough -----------------------------------------
test("{grey=0x40} → Color8(0x40) on colour and greyscale alike", function()
    local c1 = Colour.parseColorValue({ grey = 0x40 }, true)
    local c2 = Colour.parseColorValue({ grey = 0x40 }, false)
    eq(c1.v, 0x40); eq(c2.v, 0x40)
end)
test("{grey=0xFF} → false (transparent)", function()
    eq(Colour.parseColorValue({ grey = 0xFF }, true), false)
end)
test("raw byte 0x80 → Color8(0x80)", function()
    local c = Colour.parseColorValue(0x80, true)
    eq(c.v, 0x80)
end)
test("raw byte 0xFF → false (transparent)", function()
    eq(Colour.parseColorValue(0xFF, true), false)
end)

-- --- invalid input does not crash ------------------------------------------
test("hex with too few chars → nil (no crash)", function()
    eq(Colour.parseColorValue({ hex = "#FFF" }, true), nil)
end)
test("hex missing # → nil", function()
    eq(Colour.parseColorValue({ hex = "FFFFFF" }, true), nil)
end)
test("hex with non-hex chars → nil", function()
    eq(Colour.parseColorValue({ hex = "#ZZZZZZ" }, true), nil)
end)
test("empty table → nil", function()
    eq(Colour.parseColorValue({}, true), nil)
end)

-- --- cache behaviour: flushCache drops entries -----------------------------
test("flushCache drops memoised hex entries", function()
    local c1 = Colour.parseColorValue({ hex = "#123456" }, true)
    local c2 = Colour.parseColorValue({ hex = "#123456" }, true)
    if c1 ~= c2 then error("expected same memoised ref before flush") end
    Colour.flushCache()
    local c3 = Colour.parseColorValue({ hex = "#123456" }, true)
    if c3 == c1 then error("expected different ref after flush (new construction)") end
end)

-- --- cache key includes is_color_enabled (colour and greyscale differ) -----
test("cache is keyed on is_color_enabled — both kinds retained", function()
    local cc = Colour.parseColorValue({ hex = "#FF0000" }, true)
    local gg = Colour.parseColorValue({ hex = "#FF0000" }, false)
    eq(cc.kind, "rgb32"); eq(gg.kind, "color8")
end)

io.write(string.format("%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
