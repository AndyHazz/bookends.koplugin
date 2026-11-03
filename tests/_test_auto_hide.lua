-- Tests for the optional inactivity auto-hide: timer arming/disarming, the
-- transient hidden state, reveal-by-toggle, and "tap but not page turn".
-- Run: cd into the plugin dir, then `lua tests/_test_auto_hide.lua`.

local function permissive()
    local t, mt = {}, nil
    mt = { __index = function() return setmetatable({}, mt) end,
           __call  = function() return setmetatable({}, mt) end }
    return setmetatable(t, mt)
end

package.loaded["bookends_colour"] = { parseColorValue = function(v) return v end, toStorageShape = function(x) return x end }
package.loaded["device"] = {
    screen = { isColorEnabled = function() return false end },
    hasKeys = function() return false end,
}
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(self, t) t = t or {}; return setmetatable(t, { __index = self }) end,
    new    = function(self, t) return setmetatable(t or {}, { __index = self }) end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }

local scheduled, ticks, unscheduled = {}, {}, {}
local top_widget = nil
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, delay, fn) table.insert(scheduled, { delay = delay, fn = fn }) end,
    unschedule = function(_, fn) table.insert(unscheduled, fn) end,
    nextTick = function(_, fn) table.insert(ticks, fn) end,
    setDirty = function() end,
    getTopmostVisibleWidget = function() return top_widget end,
    show = function() end,
    close = function() end,
}

_G.require = function(name)
    if package.loaded[name] then return package.loaded[name] end
    local stub = permissive(); package.loaded[name] = stub; return stub
end
_G.G_reader_settings = permissive()

local Bookends = dofile("main.lua")

local pass, fail = 0, 0
local function test(name, fn)
    scheduled, ticks, unscheduled = {}, {}, {}
    top_widget = nil
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected=" .. tostring(b) .. " got=" .. tostring(a), 2) end
end

--- Fake plugin instance: real methods via __index, with markDirty counted so
-- timer tests do not depend on the repaint pipeline.
local reader_ui = { name = "ReaderUI" }
local function newSelf(overrides)
    local s = setmetatable({
        ui = reader_ui,
        enabled = true,
        auto_hide_seconds = 30,
        settings = {
            saveSetting = function() end,
            isTrue = function() return true end,
        },
        dirty = false,
        _md = 0,
        markDirty = function(self) self._md = self._md + 1 end,
        _paintToInner = function() error("paintTo should not paint while hidden") end,
    }, { __index = Bookends })
    for k, v in pairs(overrides or {}) do s[k] = v end
    return s
end

test("startAutoHideTimer arms the configured delay", function()
    local s = newSelf()
    s:startAutoHideTimer()
    eq(#scheduled, 1, "one timer")
    eq(scheduled[1].delay, 30, "configured seconds")
end)

test("startAutoHideTimer is a no-op when disabled or hidden", function()
    for _, overrides in ipairs({
        { auto_hide_seconds = 0 },
        { enabled = false },
        { _format_hidden = true },
        { _auto_hidden = true },
    }) do
        local s = newSelf(overrides)
        s:startAutoHideTimer()
        eq(#scheduled, 0, "no timer")
    end
end)

test("timeout hides the overlay and requests a repaint", function()
    local s = newSelf()
    top_widget = reader_ui
    s:startAutoHideTimer()
    scheduled[1].fn()
    eq(s._auto_hidden, true, "hidden")
    eq(s._auto_hide_timer, nil, "timer cleared")
    eq(s._md, 1, "repaint requested")
end)

test("startAutoHideTimer waits while a menu covers the reader", function()
    local s = newSelf()
    top_widget = { name = "TouchMenu" }
    s:startAutoHideTimer()
    eq(#scheduled, 1, "one recheck scheduled")
    eq(scheduled[1].delay, 1, "recheck after one second")
end)

test("closing the menu arms the timer without another page turn", function()
    local s = newSelf()
    top_widget = { name = "TouchMenu" }
    s:startAutoHideTimer()
    -- Still covered: the recheck keeps waiting.
    scheduled[1].fn()
    eq(#scheduled, 2, "another recheck while the menu stays open")
    eq(scheduled[2].delay, 1, "still one-second rechecks")
    -- Menu closed; the next recheck arms the real countdown.
    top_widget = reader_ui
    scheduled[2].fn()
    eq(#scheduled, 3, "real countdown armed")
    eq(scheduled[3].delay, 30, "configured timeout")
    scheduled[3].fn()
    eq(s._auto_hidden, true, "overlay hidden after the timeout")
end)

test("timeout under an open menu leaves the overlay alone", function()
    local s = newSelf()
    -- Arm while uncovered, then a menu opens before the timeout expires.
    s:startAutoHideTimer()
    top_widget = { name = "TouchMenu" }
    scheduled[1].fn()
    eq(s._auto_hidden, nil, "overlay must not hide under the menu")
    eq(s._md, 0, "must not paint under the menu")
    eq(s.dirty, false, "no pending repaint")
end)

test("input re-arms the timer while visible but does nothing when hidden", function()
    local s = newSelf()
    s:onInputEvent()
    eq(#scheduled, 1, "visible input arms the timer")

    scheduled, ticks, unscheduled = {}, {}, {}
    s._auto_hidden = true
    s:onInputEvent()
    eq(#scheduled, 0, "hidden input does not arm a timer")
end)

test("toggle gesture reveals an auto-hidden overlay instead of disabling it", function()
    local s = newSelf({ _auto_hidden = true })
    s:onToggleBookends()
    eq(s._auto_hidden, false, "revealed")
    eq(s.enabled, true, "still enabled")
    eq(s._md, 1, "repaint requested")
    eq(#scheduled, 1, "hide timer restarted")
end)

test("toggle gesture still disables a visible overlay", function()
    local s = newSelf()
    s:onToggleBookends()
    eq(s.enabled, false, "disabled")
    eq(s._md, 1, "repaint requested")
    eq(#scheduled, 0, "no hide timer while disabled")
end)

test("set visibility on reveals; off disables", function()
    local s = newSelf({ _auto_hidden = true })
    s:onSetBookends(true)
    eq(s._auto_hidden, false, "on clears hidden state")
    eq(s.enabled, true, "enabled")
    eq(#scheduled, 1, "timer armed")

    scheduled, ticks, unscheduled = {}, {}, {}
    s:onSetBookends(false)
    eq(s.enabled, false, "disabled")
    eq(#scheduled, 0, "timer stopped")
end)

test("tap reveals after a tick when the page did not change", function()
    local s = newSelf({ _auto_hidden = true })
    s:_observeAutoHideTap()
    eq(s._auto_hidden, true, "not revealed synchronously")
    eq(#ticks, 1, "one deferred reveal")
    ticks[1]()
    eq(s._auto_hidden, false, "revealed")
    eq(s._md, 1, "repaint requested")
    eq(#scheduled, 1, "timer restarted")
end)

test("tap that changes position does not reveal", function()
    local s = newSelf({ _auto_hidden = true })
    s:_observeAutoHideTap()
    s:onPosUpdate() -- scroll/page change caused by the same tap
    ticks[1]()
    eq(s._auto_hidden, true, "page-turn taps leave the overlay hidden")
    eq(s._md, 0, "no reveal repaint")
    eq(s._auto_hide_reveal_pending, false, "pending guard cleared")
end)

test("tap that opened a menu defers the reveal repaint", function()
    local s = newSelf({ _auto_hidden = true })
    s:_observeAutoHideTap()
    top_widget = { name = "TouchMenu" }
    ticks[1]()
    eq(s._auto_hidden, false, "revealed in memory")
    eq(s._md, 0, "no repaint under the menu")
    eq(s._deferred_overlay_repaint, true, "bands refresh after the menu closes")
    eq(#scheduled, 1, "timer waits for the reading screen to be visible")
    eq(scheduled[1].delay, 1, "one-second visibility recheck")
end)

test("paintTo suppresses drawing while auto-hidden and clears dirty", function()
    local s = newSelf({ _auto_hidden = true, dirty = true })
    Bookends.paintTo(s, {}, 0, 0)
    eq(s.dirty, false, "dirty cleared")
end)

test("markOverlayDirty does nothing while auto-hidden", function()
    local s = newSelf({
        _auto_hidden = true,
        markDirty = function() error("markOverlayDirty must not repaint while hidden") end,
    })
    s:markOverlayDirty()
end)

test("auto-hide nudge offers 1s, 10s and 60s steps", function()
    local captured
    package.loaded["ui/widget/buttondialog"] = {
        new = function(_, opts)
            captured = opts
            return {
                buttons = opts.buttons,
                movable = { dimen = {} },
                reinit = function() end,
                refocusWidget = function() end,
            }
        end,
    }
    local s = newSelf({ hideMenu = function() return function() end end })
    s:showNudgeDialog("Auto-hide", 0, 0, 3600, 0, " s",
        function() end, nil, 1, 60, nil, nil, nil,
        { text = "Off", value = 0 }, 10)
    local texts = {}
    for _, button in ipairs(captured.buttons[1]) do
        texts[#texts + 1] = button.text_func and button.text_func() or button.text
    end
    eq(table.concat(texts, ","), "-60,-10,-1,0 s,+1,+10,+60", "nudge row")
end)

print(pass .. " pass / " .. fail .. " fail")
os.exit(fail == 0 and 0 or 1)
