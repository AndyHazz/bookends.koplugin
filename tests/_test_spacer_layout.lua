-- %spacer GEOMETRY, verified against the real renderer rather than eyeballed.
--
-- _test_spacer covers the token half (the placeholder and the precedence
-- rules). This suite covers the half I first claimed needed a device: it stubs
-- KOReader's widget stack, calls OverlayWidget.buildTextWidget for real, and
-- inspects the segments it produced. That answers the actual question - does
-- the gap take exactly the leftover width, so the trailing text lands flush
-- with the far edge - more precisely than a screenshot could, and the
-- maintainer's own notes prefer it for exactly that reason.
--
-- Usage: lua tests/_test_spacer_layout.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local CHAR_W, LINE_H = 10, 20   -- every stub glyph is 10px wide, 20px tall

-- ffi is LuaJIT-only; the module needs typeof("ColorRGB32") at load time.
package.loaded["ffi"] = {
    new    = function() return {} end,
    string = function() return "" end,
    typeof = function() return function() return {} end end,
    cast   = function() return {} end,
    sizeof = function() return 4 end,
}
package.loaded["ffi/blitbuffer"] = {
    COLOR_BLACK = 0, COLOR_WHITE = 1, COLOR_GRAY_5 = 0x55,
    gray = function(v) return v end,
}
package.loaded["ffi/utf8proc"] = { uppercase_dumb = function(s) return s:upper() end }
package.loaded["bookends_colour"] = {
    resolveBarColors = function() return {} end,
    resolve = function() return 0 end,
}
package.loaded["device"] = {
    screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(_self, n) return n end,
    },
    isKindle = function() return false end,
}
package.loaded["ui/font"] = {
    getFace = function(_self, _name, size) return { size = size or 16 } end,
    fontmap = { ffont = "face.ttf" },
}
package.loaded["bookends_pacman_sprite"] = { paint = function() end }

-- A TextWidget whose width is proportional to its text, so the arithmetic the
-- renderer does is visible in the result.
local TextWidget = {}
TextWidget.__index = TextWidget
function TextWidget:new(o)
    o = o or {}
    setmetatable(o, self)
    o.text = o.text or ""
    return o
end
function TextWidget:getSize() return { w = #self.text * CHAR_W, h = LINE_H } end
function TextWidget:paintTo() end
function TextWidget:free() end
package.loaded["ui/widget/textwidget"] = TextWidget

local OverlayWidget = dofile("bookends_overlay_widget.lua")
local SPACER = OverlayWidget.SPACER_PLACEHOLDER

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function cfg()
    return { face = { size = 16 }, bold = false, uppercase = false }
end

-- Returns the row widget the renderer built for one line.
local function build(text, available_w)
    local w = OverlayWidget.buildTextWidget({ text }, { cfg() }, "left", nil, available_w)
    return w
end

test("the placeholder is exported so the token layer can find it", function()
    assert(type(SPACER) == "string" and #SPACER == 3,
           "SPACER_PLACEHOLDER should be a 3-byte string")
end)

test("a spacer line splits into before / gap / after", function()
    local row = build("AB" .. SPACER .. "CD", 500)
    assert(row and row.segments, "no row with segments came back")
    assert(#row.segments == 3,
           "expected 3 segments, got " .. tostring(#row.segments))
end)

test("the gap takes exactly the leftover width", function()
    local row = build("AB" .. SPACER .. "CD", 500)
    local before, gap, after = row.segments[1], row.segments[2], row.segments[3]
    assert(before.w == 2 * CHAR_W, "before width " .. before.w)
    assert(after.w == 2 * CHAR_W, "after width " .. after.w)
    assert(gap.w == 500 - 4 * CHAR_W,
           "gap should absorb the remainder, got " .. gap.w)
end)

test("the row fills the available width, so trailing text is flush right", function()
    local row = build("AB" .. SPACER .. "CD", 500)
    assert(row.width == 500,
           "row width should equal the space offered, got " .. tostring(row.width))
end)

test("the gap paints nothing", function()
    local row = build("AB" .. SPACER .. "CD", 500)
    local gap = row.segments[2]
    local painted = false
    local fake_bb = { paintRect = function() painted = true end,
                      setPixel = function() painted = true end }
    gap.widget:paintTo(fake_bb, 0, 0)
    assert(not painted, "the gap must not draw anything")
end)

test("a spacer at the start pushes everything right", function()
    local row = build(SPACER .. "CD", 500)
    -- Only the gap and the trailing text: an empty leading side adds no widget.
    assert(#row.segments == 2, "expected 2 segments, got " .. #row.segments)
    assert(row.segments[1].w == 500 - 2 * CHAR_W,
           "gap should be everything but the text, got " .. row.segments[1].w)
end)

test("the row keeps a text line's height even when it is all gap", function()
    local row = build(SPACER, 500)
    assert(row.height == LINE_H,
           "an all-gap row should still be one line tall, got " .. tostring(row.height))
end)

test("text wider than the line leaves no gap rather than a negative one", function()
    local row = build(string.rep("A", 60) .. SPACER .. "B", 100)
    for _i, seg in ipairs(row.segments) do
        assert(seg.w >= 0, "negative segment width " .. seg.w)
    end
    assert(row.width >= 0)
end)

test("measureTextWidth ignores the spacer on a bar-less line", function()
    -- %spacer is an elastic gap: it has no intrinsic width, and the renderer
    -- distributes the slack itself. The placeholder was only stripped for
    -- lines carrying a %bar, so on any other line it was measured as a notdef
    -- glyph and inflated the overlap width, truncating the opposite position
    -- on that row for no reason.
    local plain  = OverlayWidget.measureTextWidth({ "AB" }, { cfg() })
    local spaced = OverlayWidget.measureTextWidth({ "A" .. SPACER .. "B" }, { cfg() })
    assert(plain == 2 * CHAR_W, "harness changed: plain=" .. tostring(plain))
    assert(spaced == plain,
           "spacer inflated the width: expected " .. tostring(plain)
           .. " got " .. tostring(spaced))
end)

-- The premise the #108 overflow test rests on. That test asks "is this
-- position wider than the room its margins leave?" and truncates if so. For a
-- position carrying an auto-fill bar the WIDGET width is useless as an answer:
-- an auto-fill bar has no natural width, so built unconstrained it takes the
-- whole screen and the test fires every time. It then set a truncation limit,
-- which sent main.lua down the truncation branch and skipped the row-aware bar
-- sizing entirely - so the bar filled the margin box and painted straight over
-- the left and right positions on its row. measureTextWidth is the honest
-- signal because it drops the bar placeholder; these pin that it stays that
-- way, and that a bar line's measurement really is much smaller than a
-- full-width widget.
test("measureTextWidth drops the bar itself, not just the spacer", function()
    local c = cfg(); c.bar = true
    local BAR = OverlayWidget.BAR_PLACEHOLDER
    local with_bar = OverlayWidget.measureTextWidth({ "AB" .. BAR }, { c })
    assert(with_bar == 2 * CHAR_W,
           "the bar placeholder was measured: expected " .. tostring(2 * CHAR_W)
           .. " got " .. tostring(with_bar))
    -- A bar-only line measures as nothing at all, which is the case that made
    -- the old pb.w test wrong by the full width of the screen.
    local bar_only = OverlayWidget.measureTextWidth({ BAR }, { c })
    assert(bar_only == 0, "a bar-only line should measure 0, got " .. tostring(bar_only))
end)

test("measureTextWidth still ignores the spacer on a bar line", function()
    local c = cfg(); c.bar = true
    local plain  = OverlayWidget.measureTextWidth({ "AB" }, { c })
    local spaced = OverlayWidget.measureTextWidth({ "A" .. SPACER .. "B" }, { c })
    assert(spaced == plain, "bar line regressed: " .. tostring(spaced))
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
