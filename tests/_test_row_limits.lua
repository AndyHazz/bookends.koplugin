-- Pure-Lua test for OverlayWidget.calculateRowLimits, focused on the
-- lone-side margin-collapse fix (issue #43): a long left-only or right-only
-- line must be capped to the content width (screen minus BOTH horizontal
-- offsets), not just the near-side offset — otherwise it runs to the screen
-- edge and collapses the opposite margin.
-- Run: cd into the plugin dir, then `lua tests/_test_row_limits.lua`.
package.loaded["ffi"] = {
    typeof = function() return function() return {} end end,
    istype = function() return false end,
}
package.loaded["ffi/blitbuffer"] = {
    ColorRGB32 = function() return {} end,
    Color8 = function() return {} end,
}
package.loaded["ffi/utf8proc"] = {}
package.loaded["device"] = { screen = { scaleBySize = function(_, n) return n end, isColorEnabled = function() return false end, getSize = function() return {w=600,h=800} end } }
package.loaded["ui/font"] = { fontmap = {} }
package.loaded["ui/widget/textwidget"] = {}
package.loaded["bookends_colour"] = { parseColorValue = function() return nil end }

local OverlayWidget = dofile("bookends_overlay_widget.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected=" .. tostring(b) .. " got=" .. tostring(a), 2) end
end

local SCREEN_W = 1236
local GAP = 50

-- calculateRowLimits(left_w, center_w, right_w, screen_w, gap, h_offset, priority, left_offset, right_offset)

test("lone left, symmetric margins: cap reserves BOTH margins", function()
    -- margins 40/40; a 1300px-wide left line must cap at 1236-40-40 = 1156,
    -- not 1236-40 = 1196 (which would collapse the right margin).
    local limits = OverlayWidget.calculateRowLimits(
        1300, nil, nil, SCREEN_W, GAP, 40, "center", 40, 40)
    eq(limits.left, 1156, "lone-left symmetric cap")
    eq(limits.right, nil, "right untouched")
end)

test("lone right, symmetric margins: cap reserves BOTH margins", function()
    local limits = OverlayWidget.calculateRowLimits(
        nil, nil, 1300, SCREEN_W, GAP, 40, "center", 40, 40)
    eq(limits.right, 1156, "lone-right symmetric cap")
    eq(limits.left, nil, "left untouched")
end)

test("lone left, asymmetric margins: caps at screen - left_off - right_off", function()
    -- margin_left=10, margin_right=50 -> content width 1236-10-50 = 1176.
    -- h_offset passed as max(10,50)=50 (mirrors main.lua's max_h_offset).
    local limits = OverlayWidget.calculateRowLimits(
        1300, nil, nil, SCREEN_W, GAP, 50, "center", 10, 50)
    eq(limits.left, 1176, "lone-left asymmetric cap")
end)

test("lone right, asymmetric margins: caps at screen - left_off - right_off", function()
    local limits = OverlayWidget.calculateRowLimits(
        nil, nil, 1300, SCREEN_W, GAP, 50, "center", 10, 50)
    eq(limits.right, 1176, "lone-right asymmetric cap")
end)

test("lone left that already fits: no cap (no needless truncation)", function()
    local limits = OverlayWidget.calculateRowLimits(
        800, nil, nil, SCREEN_W, GAP, 40, "center", 40, 40)
    eq(limits.left, nil, "short line not truncated")
end)

test("backward compat: offsets omitted falls back to 2*h_offset", function()
    -- No left_offset/right_offset args -> reserve the (max) margin both sides.
    local limits = OverlayWidget.calculateRowLimits(
        1300, nil, nil, SCREEN_W, GAP, 40, "center")
    eq(limits.left, 1156, "fallback to 2*h_offset")
end)

-- ── OverlayWidget.marginRoom (issue #108) ───────────────────────────────────
-- The widest a line can be before it overflows BOOKENDS' own margins, for a
-- line with no overlapping neighbour to cap it. The #108 fix computed this
-- inline as screen_w - 2*(near_margin + h_offset) for every position, which is
-- only right for a centred line on symmetric margins: getMargin returns
-- margin_right for tc/tr/bc/br, so the near margin was doubled and the far one
-- ignored, and a left-anchored line lost twice its own h_offset.

test("centred, symmetric margins: both margins reserved", function()
    eq(OverlayWidget.marginRoom("center", 1236, 18, 18, 0), 1200)
end)

test("centred: the TIGHTER margin governs both sides", function()
    -- centring is symmetric about the middle, so the wider margin binds first
    eq(OverlayWidget.marginRoom("center", 1236, 18, 40, 0), 1236 - 80)
    eq(OverlayWidget.marginRoom("center", 1236, 40, 18, 0), 1236 - 80)
end)

test("centred: h_offset slides the line toward one margin", function()
    -- +10 shifts right, so the right margin binds: (w+screen)/2 + 10 <= screen - 18
    eq(OverlayWidget.marginRoom("center", 1236, 18, 18, 10), 1236 - 56)
end)

test("right-anchored: near margin plus offset, far margin once", function()
    eq(OverlayWidget.marginRoom("right", 1236, 18, 18, 0), 1200)
    eq(OverlayWidget.marginRoom("right", 1236, 18, 18, 50), 1150)
end)

test("left-anchored: its own offset counted once, not twice", function()
    -- the old inline maths gave 1236 - 2*(18+50) = 1100 here
    eq(OverlayWidget.marginRoom("left", 1236, 18, 18, 50), 1150)
    eq(OverlayWidget.marginRoom("left", 1236, 18, 18, 0), 1200)
end)

test("asymmetric margins are respected per side", function()
    eq(OverlayWidget.marginRoom("left",  1236, 10, 60, 0), 1236 - 70)
    eq(OverlayWidget.marginRoom("right", 1236, 10, 60, 0), 1236 - 70)
end)

test("never returns a negative room", function()
    eq(OverlayWidget.marginRoom("center", 100, 400, 400, 0), 0)
    eq(OverlayWidget.marginRoom("left", 100, 400, 400, 0), 0)
end)

print(pass .. " pass / " .. fail .. " fail")
os.exit(fail == 0 and 0 or 1)
