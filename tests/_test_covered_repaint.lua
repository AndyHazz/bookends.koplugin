-- Tests for #114: value-tick repaints must not fire while a widget covers the
-- reader, and must be caught up once it stops covering.
--
-- The bug: marking ReaderUI dirty under an open menu writes the whole page
-- into the framebuffer, racing KOReader's in-flight panel update for the
-- menu's own region. What reached the panel was page content where the menu
-- should be. See the issue for the photos.
--
-- Run: cd into the plugin dir, then `lua tests/_test_covered_repaint.lua`.

local function permissive()
    local t, mt = {}, nil
    mt = { __index = function() return setmetatable({}, mt) end,
           __call  = function() return setmetatable({}, mt) end }
    return setmetatable(t, mt)
end

package.loaded["bookends_colour"] = { parseColorValue = function(v) return v end, toStorageShape = function(x) return x end }
package.loaded["device"] = { screen = { isColorEnabled = function() return false end } }
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(self, t) t = t or {}; return setmetatable(t, { __index = self }) end,
    new    = function(self, t) return setmetatable(t or {}, { __index = self }) end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }

-- The covering widget is the variable under test, so the stub lets each case
-- set it. dirtied/ticks record what actually left the plugin.
local covering = nil
local dirtied, ticks = {}, {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function() end,
    unschedule = function() end,
    nextTick = function(_, fn) table.insert(ticks, fn) end,
    setDirty = function(_, widget, mode, region)
        table.insert(dirtied, { widget = widget, mode = mode, region = region })
    end,
    getTopmostVisibleWidget = function() return covering end,
}

_G.require = function(name)
    if package.loaded[name] then return package.loaded[name] end
    local stub = permissive(); package.loaded[name] = stub; return stub
end
_G.G_reader_settings = permissive()

local Bookends = dofile("main.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected=" .. tostring(b) .. " got=" .. tostring(a), 2) end
end

-- Run everything scheduled, including anything the callbacks schedule in turn.
-- Asserting "no setDirty yet" without this passes on the BROKEN code too,
-- because _scheduleRepaint always defers its dispatcher by a tick - the
-- assertion has to be that nothing reaches setDirty at all, not that it has
-- not got there yet.
local function drainTicks(limit)
    local i, guard = 1, limit or 10
    while ticks[i] and guard > 0 do
        ticks[i]()
        i, guard = i + 1, guard - 1
    end
end

-- A fresh plugin instance with just enough state for the two code paths:
-- paint rects present (so markOverlayDirty takes the regional branch rather
-- than falling back to markDirty), and a settings stub for _scheduleRepaint.
local reader_ui = { name = "ReaderUI" }
local function newInstance()
    local self = setmetatable({}, { __index = Bookends })
    self.ui = reader_ui
    self.enabled = true
    self.settings = { isTrue = function() return true end }
    self._top_paint_rect = { x = 0, y = 0, w = 100, h = 10 }
    self._bottom_paint_rect = { x = 0, y = 90, w = 100, h = 10 }
    self._paintToInner = function() end -- the paint itself is not under test
    dirtied, ticks = {}, {}
    return self
end

test("uncovered: markOverlayDirty marks ReaderUI dirty for both bands", function()
    covering = reader_ui
    local self = newInstance()
    self:markOverlayDirty()
    -- _scheduleRepaint defers the dispatcher to nextTick; run it.
    eq(#ticks, 1, "one nextTick scheduled")
    ticks[1]()
    eq(#dirtied, 2, "top and bottom bands")
    eq(dirtied[1].widget, reader_ui)
    eq(dirtied[1].mode, "ui")
end)

test("covered: markOverlayDirty issues no setDirty at all", function()
    covering = { name = "TouchMenu" }
    local self = newInstance()
    self:markOverlayDirty()
    drainTicks()
    eq(#dirtied, 0, "nothing may be painted under the menu")
    eq(self.dirty, true, "content still flagged stale")
    eq(self._deferred_overlay_repaint, true, "deferral recorded")
end)

test("covered with no paint rects yet: still no setDirty", function()
    -- The markDirty fallback has to be gated too, or a first-ever repaint
    -- under a menu would go through the very path this fixes.
    covering = { name = "TouchMenu" }
    local self = newInstance()
    self._top_paint_rect, self._bottom_paint_rect = nil, nil
    self:markOverlayDirty()
    drainTicks()
    eq(#dirtied, 0, "fallback path must be gated as well")
    eq(self._deferred_overlay_repaint, true)
end)

test("paintTo while still covered keeps the deferral", function()
    -- paintTo runs under an open menu too: ReaderUI paints before the menu
    -- paints on top of it. Clearing here would put the repaint back exactly
    -- where it was skipped from.
    covering = { name = "TouchMenu" }
    local self = newInstance()
    self._deferred_overlay_repaint = true
    self:paintTo({}, 0, 0)
    drainTicks()
    eq(self._deferred_overlay_repaint, true, "deferral must survive a covered paint")
    eq(#dirtied, 0, "no repaint may escape while still covered")
end)

test("paintTo once uncovered clears the deferral and schedules the catch-up", function()
    covering = reader_ui
    local self = newInstance()
    self._deferred_overlay_repaint = true
    self:paintTo({}, 0, 0)
    eq(self._deferred_overlay_repaint, nil, "deferral cleared")
    eq(#ticks, 1, "catch-up scheduled")
    ticks[1]()
    -- That catch-up is markOverlayDirty, which defers its own dispatch again.
    eq(#ticks, 2, "markOverlayDirty scheduled its dispatcher")
    ticks[2]()
    eq(#dirtied, 2, "both bands refreshed once uncovered")
end)

test("paintTo with no deferral pending schedules nothing", function()
    covering = reader_ui
    local self = newInstance()
    self:paintTo({}, 0, 0)
    eq(#ticks, 0, "no catch-up when nothing was deferred")
end)

print(pass .. " pass / " .. fail .. " fail")
os.exit(fail == 0 and 0 or 1)
