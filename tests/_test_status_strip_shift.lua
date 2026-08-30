-- Bookshelf's in-reader status strip pushes bookends' top content down (#348).
-- This suite pins the ONE property that actually broke: a top-anchored BAR and
-- a top-anchored TEXT ROW must move by the SAME amount.
--
-- The regression that prompted it: the strip height was consumed as an
-- absolute y by the bars (clamped: max(margin_v, strip)) and as a delta by the
-- text rows (strip - margin_top, added). So a bar already below the strip did
-- not move at all while every text row moved by the full delta, and a
-- margin_v=0 bar landed exactly on the top row and painted through it.
--
-- Testing the shift value on its own would not have caught that - both call
-- sites read a plausible number, they just read DIFFERENT plausible numbers.
-- So this measures the two rects the way the paint path does.
--
-- Run: cd into the plugin dir, then `lua tests/_test_status_strip_shift.lua`.

local function permissive()
    local t, mt = {}, nil
    mt = { __index = function() return setmetatable({}, mt) end,
           __call  = function() return setmetatable({}, mt) end }
    return setmetatable(t, mt)
end
package.loaded["bookends_colour"] = { parseColorValue = function(v) return v end,
                                      toStorageShape = function(x) return x end }
package.loaded["device"] = { screen = { isColorEnabled = function() return false end } }
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(s, t) t = t or {}; return setmetatable(t, { __index = s }) end,
    new    = function(s, t) return setmetatable(t or {}, { __index = s }) end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }
package.loaded["bookends_tokens"] = permissive()
_G.require = function(name)
    if package.loaded[name] then return package.loaded[name] end
    local stub = permissive(); package.loaded[name] = stub; return stub
end
_G.G_reader_settings = permissive()

local Bookends = dofile("main.lua")
local computeBarRect = Bookends._computeBarRect

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then
        error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2)
    end
end

local SCREEN_W, SCREEN_H = 1236, 1648
local MARGIN_TOP = 18
local STRIP = 65

-- Both sides call real code: the text row through Bookends:_topRowOffset (the
-- expression the paint path uses), the bar through computeBarRect. Modelling
-- either side here would defeat the point - re-implementing the text path is
-- exactly how the two drifted apart.
local bookends = setmetatable({}, { __index = Bookends })
local function textRowY(v_offset, strip)
    bookends._bs_strip_h = strip or 0
    return bookends:_topRowOffset(v_offset, MARGIN_TOP)
end

local function topBarY(margin_v, strip)
    local _, bar_y = computeBarRect({ v_anchor = "top", margin_v = margin_v, height = 20 },
                                    0, 0, SCREEN_W, SCREEN_H, strip or 0)
    return bar_y
end

test("no strip: bars and rows sit at their own margins", function()
    eq(topBarY(0, 0), 0, "bar margin_v=0")
    eq(topBarY(30, 0), 30, "bar margin_v=30")
    eq(textRowY(0, 0), MARGIN_TOP, "row v_offset=0")
end)

-- THE invariant. Every combination has to move by the same delta, or the gap
-- between a bar and the row beneath it changes when the strip appears.
test("bars and text rows move by the same delta", function()
    for _, margin_v in ipairs({ 0, 12, 30, 100, 200 }) do
        for _, v_offset in ipairs({ 0, 30, 120 }) do
            local bar_delta = topBarY(margin_v, STRIP) - topBarY(margin_v, 0)
            local row_delta = textRowY(v_offset, STRIP) - textRowY(v_offset, 0)
            eq(bar_delta, STRIP, "bar delta (margin_v=" .. margin_v .. ")")
            eq(row_delta, bar_delta,
               "row v_offset=" .. v_offset .. " vs bar margin_v=" .. margin_v)
        end
    end
end)

test("the gap between a bar and the row below it is preserved", function()
    local gap_before = textRowY(0, 0) - topBarY(0, 0)
    local gap_after  = textRowY(0, STRIP) - topBarY(0, STRIP)
    eq(gap_after, gap_before, "bar-to-row gap")
    -- And specifically: they must not land on the same pixel, which is the
    -- collapse that was visible on screen.
    if gap_after == 0 then error("bar and row are on top of each other", 2) end
end)

test("nothing top-anchored is left overlapping the strip", function()
    for _, margin_v in ipairs({ 0, 12, 30 }) do
        local yv = topBarY(margin_v, STRIP)
        if yv < STRIP then
            error("bar margin_v=" .. margin_v .. " starts at " .. yv
                  .. ", inside the strip (0.." .. STRIP .. ")", 2)
        end
    end
    if textRowY(0, STRIP) < STRIP then error("top row overlaps the strip", 2) end
end)

test("bottom-anchored bars are untouched by the strip", function()
    local function bottomBarY(strip)
        local _, bar_y = computeBarRect({ v_anchor = "bottom", margin_v = 10, height = 20 },
                                        0, 0, SCREEN_W, SCREEN_H, strip)
        return bar_y
    end
    eq(bottomBarY(STRIP), bottomBarY(0), "bottom bar y")
end)

-- A vertical bar spans the whole screen height, so it has to start below the
-- strip AND give the height back rather than running off the bottom edge.
test("vertical bars start below the strip and lose the height", function()
    local function vrect(strip)
        local _, bar_y, _, bar_h = computeBarRect(
            { v_anchor = "left", margin_left = 0, margin_right = 0, height = 20 },
            0, 0, SCREEN_W, SCREEN_H, strip)
        return bar_y, bar_h
    end
    local y0, h0 = vrect(0)
    local y1, h1 = vrect(STRIP)
    eq(y1 - y0, STRIP, "vertical bar top")
    eq(h0 - h1, STRIP, "vertical bar height")
    eq(y1 + h1, y0 + h0, "vertical bar bottom edge unchanged")
end)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
