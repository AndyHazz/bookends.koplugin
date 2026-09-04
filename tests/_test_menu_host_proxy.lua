-- Bookends' dialogs hide the parent menu while they're open and re-show it on
-- close (DialogHelpers.hideParentMenu). That re-show puts the object back on
-- UIManager._window_stack, so it must be a real widget.
--
-- A third-party menu host can pass something that ISN'T. ZenOS renders other
-- plugins' menus in its own list widget and hands callbacks a plain-table
-- proxy (zen-os common/ui/zen_arrange_list.lua, and the TOUCHMENU_STUB in
-- modules/menu/app_launcher/plugin_scan.lua + native_menu.lua) implementing
-- only updateItems/closeMenu/onClose/handleEvent. That `handleEvent` is enough
-- for UIManager:show() to accept it, so the failure lands later, in the next
-- repaint, as `attempt to call method 'paintTo' (a nil value)` — see #112.
--
-- Usage: lua tests/_test_menu_host_proxy.lua

-- ─── Stubs ───────────────────────────────────────────────
local shown_widgets = {}
local UIManagerStub = { _window_stack = {} }

-- Mirrors uimanager.lua:156 UIManager:show — nil is rejected, everything else
-- is indexed for a log line, sent a Show event, and pushed on the stack.
function UIManagerStub:show(widget)
    if not widget then return end
    local _label = widget.id or widget.name or tostring(widget)
    widget:handleEvent("Show")
    shown_widgets[#shown_widgets + 1] = widget
    table.insert(self._window_stack, { widget = widget, x = 0, y = 0 })
end

-- Mirrors uimanager.lua:215 UIManager:close — events fire whether or not the
-- widget is actually on the stack.
function UIManagerStub:close(widget)
    if not widget then return end
    widget:handleEvent("FlushSettings")
    widget:handleEvent("CloseWidget")
    for i = #self._window_stack, 1, -1 do
        if self._window_stack[i].widget == widget then
            table.remove(self._window_stack, i)
        end
    end
end

-- Mirrors the paint loop at uimanager.lua:1262, the line #112 crashes on.
function UIManagerStub:_repaint()
    for _idx, window in ipairs(self._window_stack) do
        window.widget:paintTo("bb", window.x, window.y)
    end
end

package.loaded["ui/uimanager"] = UIManagerStub
package.loaded["device"] = {
    hasKeys = function() return false end,
    input = { group = { Back = { "Back" } } },
}
package.loaded["util"] = { tableDeepCopy = function(t) return t end }
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }

local DialogHelpers = require("bookends_dialog_helpers")

-- ─── Harness ─────────────────────────────────────────────
local pass, fail = 0, 0
local function ok(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. (msg or "")) end
end
local function eq(a, b, msg)
    if a == b then pass = pass + 1
    else fail = fail + 1; print(("FAIL %s: expected %s got %s"):format(msg or "", tostring(b), tostring(a))) end
end
local function test(name, fn)
    print("--- " .. name)
    UIManagerStub._window_stack = {}
    shown_widgets = {}
    fn()
end

-- A stock TouchMenu: a real widget, held on the stack via its show_parent
-- CenterContainer.
local function makeTouchMenu()
    local container = {
        name = "MenuContainer",
        paintTo = function() end,
        handleEvent = function() return false end,
    }
    local tm = {
        show_parent = container,
        updated = 0,
        handleEvent = function() return false end,
        paintTo = function() end,
    }
    tm.updateItems = function(self) self.updated = self.updated + 1 end
    return tm, container
end

-- ZenOS's menu_proxy / TOUCHMENU_STUB shape: four methods, no paintTo, no
-- show_parent. Copied from zen-os so the test fails for the real reason.
local function makeHostProxy()
    local proxy = {
        item_table = {},
        updated = 0,
        closeMenu = function() return true end,
        onClose = function() return true end,
        handleEvent = function() return false end,
    }
    proxy.updateItems = function(self) self.updated = self.updated + 1 end
    return proxy
end

-- ─── Tests ───────────────────────────────────────────────
test("stock TouchMenu is still hidden and restored", function()
    local tm, container = makeTouchMenu()
    UIManagerStub:show(container)
    eq(#UIManagerStub._window_stack, 1, "container starts on the stack")

    local restore = DialogHelpers.hideParentMenu(tm)
    eq(#UIManagerStub._window_stack, 0, "hidden while the dialog is open")

    restore()
    eq(#UIManagerStub._window_stack, 1, "restored on close")
    eq(UIManagerStub._window_stack[1].widget, container, "same container back")
    eq(tm.updated, 1, "menu items refreshed")
    ok(pcall(function() UIManagerStub:_repaint() end), "repaint succeeds")
end)

test("a non-widget menu host is never pushed onto the window stack", function()
    local proxy = makeHostProxy()

    local restore = DialogHelpers.hideParentMenu(proxy)
    restore()

    for _idx, window in ipairs(UIManagerStub._window_stack) do
        ok(type(window.widget.paintTo) == "function",
            "every stack entry is paintable")
    end
    eq(#UIManagerStub._window_stack, 0, "proxy not on the stack")
    ok(pcall(function() UIManagerStub:_repaint() end),
        "repaint does not raise 'attempt to call method paintTo'")
    eq(proxy.updated, 1, "hosted menu still refreshed after the dialog closes")
end)

test("a menu host without updateItems does not crash the restore", function()
    local bare = { handleEvent = function() return false end }
    local restore = DialogHelpers.hideParentMenu(bare)
    ok(pcall(restore), "restore survives a host with no updateItems")
end)

test("nil touchmenu_instance still yields a no-op restore", function()
    local restore = DialogHelpers.hideParentMenu(nil)
    ok(pcall(restore), "no-op restore")
    eq(#UIManagerStub._window_stack, 0, "nothing shown")
end)

print()
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
