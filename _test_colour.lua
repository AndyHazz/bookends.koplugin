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
test("hex '#FFF' is short-form → expanded to white (not nil)", function()
    local c = Colour.parseColorValue({ hex = "#FFF" }, true)
    eq(c.kind, "rgb32"); eq(c.r, 255); eq(c.g, 255); eq(c.b, 255)
end)
test("hex missing # → accepted (# optional)", function()
    local c = Colour.parseColorValue({ hex = "FFFFFF" }, true)
    eq(c.kind, "rgb32"); eq(c.r, 255); eq(c.g, 255); eq(c.b, 255)
end)
test("hex with 4 chars → nil (neither short nor long form)", function()
    eq(Colour.parseColorValue({ hex = "#FFFF" }, true), nil)
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

-- --- normaliseHex: accept short and long forms --------------------------
test("normaliseHex('#FF0000') → '#FF0000'", function()
    eq(Colour.normaliseHex("#FF0000"), "#FF0000")
end)
test("normaliseHex('#F00') → '#FF0000'", function()
    eq(Colour.normaliseHex("#F00"), "#FF0000")
end)
test("normaliseHex('#abc') → '#AABBCC' (case normalised, expanded)", function()
    eq(Colour.normaliseHex("#abc"), "#AABBCC")
end)
test("normaliseHex('F00') → '#FF0000' (leading # optional)", function()
    eq(Colour.normaliseHex("F00"), "#FF0000")
end)
test("normaliseHex('  #F00 ') → '#FF0000' (whitespace tolerated)", function()
    eq(Colour.normaliseHex("  #F00 "), "#FF0000")
end)
test("normaliseHex('#FFFF') → nil (4 chars is neither form)", function()
    eq(Colour.normaliseHex("#FFFF"), nil)
end)
test("normaliseHex('#ZZZ') → nil (non-hex)", function()
    eq(Colour.normaliseHex("#ZZZ"), nil)
end)
test("normaliseHex(nil) → nil (non-string)", function()
    eq(Colour.normaliseHex(nil), nil)
end)

-- --- parseColorValue: accept short hex form --------------------------
test("parseColorValue({hex='#F00'}) on colour → ColorRGB32(255,0,0,255)", function()
    Colour.flushCache()
    local c = Colour.parseColorValue({ hex = "#F00" }, true)
    eq(c.kind, "rgb32"); eq(c.r, 255); eq(c.g, 0); eq(c.b, 0); eq(c.a, 0xFF)
end)
test("parseColorValue({hex='#F00'}) and {hex='#FF0000'} share cache entry", function()
    Colour.flushCache()
    local a = Colour.parseColorValue({ hex = "#F00" }, true)
    local b = Colour.parseColorValue({ hex = "#FF0000" }, true)
    if a ~= b then error("expected same memoised ref (both normalise to #FF0000)") end
end)

-- --- toStorageShape: collapse greys to {grey=N}, keep real colours as {hex} ----
test("toStorageShape('#000000') → {grey=0} (black is neutral)", function()
    local s = Colour.toStorageShape("#000000")
    eq(type(s), "table"); eq(s.grey, 0); eq(s.hex, nil)
end)
test("toStorageShape('#808080') → {grey=128}", function()
    local s = Colour.toStorageShape("#808080")
    eq(s.grey, 0x80); eq(s.hex, nil)
end)
test("toStorageShape('#FFF') → {grey=255} (short-form white is neutral)", function()
    local s = Colour.toStorageShape("#FFF")
    eq(s.grey, 0xFF); eq(s.hex, nil)
end)
test("toStorageShape('#F00') → {hex='#FF0000'} (red is not neutral)", function()
    local s = Colour.toStorageShape("#F00")
    eq(s.grey, nil); eq(s.hex, "#FF0000")
end)
test("toStorageShape('#C00000') → {hex='#C00000'}", function()
    local s = Colour.toStorageShape("#C00000")
    eq(s.hex, "#C00000")
end)
test("toStorageShape('xyzzy') → nil (non-hex chars)", function()
    eq(Colour.toStorageShape("xyzzy"), nil)
end)

io.write(string.format("%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
