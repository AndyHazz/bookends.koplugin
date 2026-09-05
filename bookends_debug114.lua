--[[--
DEBUG BRANCH ONLY - instrumentation for issue #114.

    "Book page draws above some part of KOReader's menu when wifi is displayed
     on bookends and turned on/off from the menu."

Never merge this file (or its call sites) to master.

## What it records

Bookends repaints its overlay on NetworkConnected / NetworkDisconnected when a
line uses %wifi, and it does that by marking ReaderUI dirty. ReaderUI is at the
bottom of UIManager's window stack, so a repaint of it paints the whole page
into the framebuffer; UIManager is then supposed to repaint every widget above
it (the open menu) before any refresh reaches the panel. The reported symptom
is page content ending up on top of the menu, so the question is which half of
that contract breaks - the paint order, or the refresh region.

So this logs, in order, for a short window around each network event:

  * STACK      - the window stack: name, covers_fullscreen, toast, invisible,
                 dirty flag, dimen, and the index UIManager:_repaint() would
                 start painting from
  * setDirty   - every call: target widget, refresh type, region
  * _refresh   - every refresh actually enqueued for the panel: mode + region
  * repaint    - the stack before the pass, and the lowest index that actually
                 painted (a widget's dirty flag is cleared when it paints)
  * PAINT      - each widget that actually painted in the pass, in order. This
                 is the line the whole question turns on: if ReaderUI paints
                 and no menu PAINT follows it, the page went into the frame-
                 buffer with nothing put back on top.
  * PANEL      - the Screen call UIManager actually made, after painting
  * DIRECT     - a Screen:refreshX() that bypassed UIManager entirely
  * note       - Bookends-side decisions (gated repaint fired / skipped, the
                 overlay paint rects handed to setDirty)

setDirty, _refresh and DIRECT lines carry `from=` - a short chain of
source:line for the calling frames. That is what tells a third-party plugin's
repaint apart from Bookends' own: ours reads plugins/bookends.koplugin/...,
KOReader's own reads frontend/..., anything else names itself.

Everything is off unless armed, and arming happens only on a network event (or
explicitly), so a normal reading session logs nothing.

## Reading the log

    grep BE114 /mnt/us/koreader/crash.log

Lines are sequence-numbered so interleaving is unambiguous.

## What we expect to see

If the paint order is intact, a repaint pass triggered by Bookends should show
`lowest painted index = 1` (ReaderUI) and the menu sitting above it in the same
stack - which means the menu WAS repainted over the page, and the corruption
has to come from the refresh side (region, or an in-flight panel update racing
the framebuffer). If instead the menu is missing from the stack, or painting
starts above ReaderUI, the problem is on the paint side.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")

local Debug114 = {
    installed = false,
    armed_until = 0,
    seq = 0,
}

local function nowMs()
    return time.to_ms(time.now())
end

-- Most KOReader widgets carry no `name`, and a bare table address tells the
-- reader of the log nothing. Fall back to the fields that identify the widget
-- classes that matter here, then to the first child (menus are wrapped in a
-- CenterContainer, so the interesting widget is one level down).
local function describe(w, depth)
    if type(w) ~= "table" then return tostring(w) end
    if w.name then return tostring(w.name) end
    if w.id then return tostring(w.id) end
    if w.tab_item_table then return "TouchMenu" end
    if w.item_table then return "Menu?" end
    if w.title_bar or w.title then return "Dialog?" end
    if (depth or 0) < 2 and type(w[1]) == "table" then
        local inner = describe(w[1], (depth or 0) + 1)
        if not inner:match("^table: ") then return "container>" .. inner end
    end
    return tostring(w)
end

local function widgetName(w)
    return describe(w, 0)
end

--- Exposed so call sites outside this file name widgets the same way.
Debug114.widgetName = widgetName

-- Who asked for this. Without it the log names the TARGET of a setDirty and
-- never the caller, so Bookends marking ReaderUI dirty and some other plugin
-- doing the same thing are the same line. A two-or-three frame chain of
-- short_src:line is enough to tell them apart: KOReader's own callers show as
-- frontend/..., a third-party one as plugins/<name>.koplugin/....
-- debug.getinfo is affordable here because it only runs inside an armed window.
local function caller(skip)
    skip = skip or 3
    local out = {}
    for lvl = skip, skip + 8 do
        -- No pcall here: it would add a stack frame and shift every level by
        -- one. debug.getinfo returns nil for an out-of-range level rather than
        -- erroring, which is the only failure we need to handle.
        local info = debug.getinfo(lvl, "Sl")
        if not info then break end
        local src = tostring(info.short_src or "?")
        -- Skip frames belonging to this file, and the [C] boundary of its
        -- pcall around _repaint. They are the instrumentation standing on the
        -- stack, not part of the answer to "who asked for this repaint" - and
        -- leaving them in made every refresh flushed during a repaint pass
        -- read "from=... < bookends_debug114.lua:210", which is exactly the
        -- false positive the from= field exists to rule out.
        if not src:find("bookends_debug114", 1, true) and src ~= "[C]" then
            src = src:gsub("^.*/koreader/", ""):gsub("^%.%./", "")
            out[#out + 1] = src .. ":" .. tostring(info.currentline)
            if #out >= 3 then break end
        end
    end
    if #out == 0 then return "?" end
    return table.concat(out, " < ")
end

local function regionStr(r)
    if r == nil then return "nil" end
    if type(r) ~= "table" then return tostring(r) end
    return string.format("(%s,%s %sx%s)",
        tostring(r.x), tostring(r.y), tostring(r.w), tostring(r.h))
end

function Debug114.log(...)
    Debug114.seq = Debug114.seq + 1
    logger.warn(string.format("BE114 %04d", Debug114.seq), ...)
end

function Debug114.armed()
    return nowMs() < Debug114.armed_until
end

--- Log a Bookends-side decision. Cheap no-op when not armed.
function Debug114.note(...)
    if not Debug114.armed() then return end
    Debug114.log("note:", ...)
end

--- Mirrors the start_idx search in UIManager:_repaint().
local function paintStartIndex(stack)
    for i = #stack, 1, -1 do
        if stack[i].widget.covers_fullscreen then return i end
    end
    return 1
end

function Debug114.dumpStack(tag)
    local stack = UIManager._window_stack
    Debug114.log("STACK", tag, "n=" .. #stack, "paint_from=" .. paintStartIndex(stack))
    for i = 1, #stack do
        local w = stack[i].widget
        Debug114.log(string.format(
            "  [%d] %s cover=%s toast=%s invis=%s dirty=%s dimen=%s",
            i, widgetName(w),
            tostring(w.covers_fullscreen or false),
            tostring(w.toast or false),
            tostring(w.invisible or false),
            tostring(UIManager._dirty[w] and true or false),
            regionStr(w.dimen)))
    end
end

--- Start logging for `secs` seconds (default 15).
function Debug114.arm(reason, secs)
    secs = secs or 15
    Debug114.armed_until = nowMs() + secs * 1000
    Debug114.log("ARMED by", reason, "for", secs .. "s")
    Debug114.dumpStack("at arm")
end

function Debug114.install()
    if Debug114.installed then return end
    Debug114.installed = true
    Debug114.log("instrumentation installed (debug branch for issue #114)")

    local orig_setDirty = UIManager.setDirty
    UIManager.setDirty = function(self, widget, refreshtype, refreshregion, refreshdither)
        if Debug114.armed() then
            Debug114.log("setDirty", widgetName(widget),
                "type=" .. tostring(refreshtype),
                "region=" .. regionStr(refreshregion),
                "from=" .. caller(3))
        end
        return orig_setDirty(self, widget, refreshtype, refreshregion, refreshdither)
    end

    local orig_refresh = UIManager._refresh
    UIManager._refresh = function(self, mode, region, dither)
        if Debug114.armed() then
            Debug114.log("_refresh", tostring(mode), regionStr(region),
                "from=" .. caller(3))
        end
        return orig_refresh(self, mode, region, dither)
    end

    local orig_repaint = UIManager._repaint
    UIManager._repaint = function(self)
        if not Debug114.armed() then
            -- One-shot marker so a log that simply stops is distinguishable
            -- from one where the window was open and nothing happened.
            if Debug114.armed_until > 0 then
                Debug114.armed_until = 0
                Debug114.log("DISARMED")
            end
            return orig_repaint(self)
        end
        local stack = self._window_stack
        -- Snapshot (widget, dirty) pairs by identity: the stack itself can be
        -- reordered or shortened during the pass (widgets close), so indices
        -- alone would not survive it.
        local snapshot = {}
        for i = 1, #stack do
            snapshot[i] = { widget = stack[i].widget, dirty = self._dirty[stack[i].widget] and true or false }
        end
        Debug114.dumpStack("pre-repaint")

        -- Wrap each stack widget's paintTo for the duration of THIS pass.
        -- "lowest painted index" only says where painting started; everything
        -- above it is assumed to follow, because that is what UIManager's
        -- propagation does. But the whole question in #114 is whether the menu
        -- really did repaint over the page, so inferring it from the rule is
        -- assuming the answer. These PAINT lines observe it instead.
        local restore = {}
        for i = 1, #stack do
            local w = stack[i].widget
            local fn = w.paintTo
            if type(fn) == "function" and restore[w] == nil then
                -- rawget distinguishes a widget's own paintTo from one reached
                -- through its class metatable: restoring the latter means
                -- clearing the field, not writing the function back onto the
                -- instance.
                restore[w] = { own = rawget(w, "paintTo") }
                local name = widgetName(w)
                w.paintTo = function(...)
                    Debug114.log("PAINT", name)
                    return fn(...)
                end
            end
        end

        local ok, err = pcall(orig_repaint, self)

        for w, r in pairs(restore) do
            if r.own ~= nil then w.paintTo = r.own else w.paintTo = nil end
        end

        pcall(function()
            local painted_from
            for i = 1, #snapshot do
                if snapshot[i].dirty and not self._dirty[snapshot[i].widget] then
                    painted_from = i
                    break
                end
            end
            Debug114.log("repaint done; lowest painted index =", tostring(painted_from),
                "stack_n=" .. #self._window_stack)
        end)
        if not ok then error(err) end
    end

    -- The actual panel updates. UIManager merges and promotes overlapping
    -- refreshes inside _refresh() and only flushes them at the END of a repaint
    -- pass, so the regions logged above are what was *requested*, not what the
    -- panel got. refresh_methods is a file-local in uimanager.lua, reachable
    -- only as an upvalue of the original _repaint closure; the table can be
    -- mutated in place to wrap the Screen calls that actually drive the panel.
    -- Best effort - if the upvalue moves in a future KOReader we lose this one
    -- line rather than the whole build.
    local ok_panel, methods = pcall(function()
        return require("userpatch").getUpValue(orig_repaint, "refresh_methods")
    end)
    if ok_panel and type(methods) == "table" then
        local wrapped = 0
        for mode, fn in pairs(methods) do
            if type(fn) == "function" then
                methods[mode] = function(screen, x, y, w, h, dither)
                    if Debug114.armed() then
                        Debug114.log("PANEL", mode, string.format("(%s,%s %sx%s)",
                            tostring(x), tostring(y), tostring(w), tostring(h)))
                    end
                    return fn(screen, x, y, w, h, dither)
                end
                wrapped = wrapped + 1
            end
        end
        Debug114.log("panel refresh hooks installed:", wrapped)
    else
        Debug114.log("panel refresh hooks NOT installed (refresh_methods upvalue not found)")
    end

    -- Refreshes that bypass UIManager altogether. The refresh_methods table
    -- above holds the ORIGINAL function references, captured when uimanager.lua
    -- loaded, and the wrappers there call those directly - so UIManager's own
    -- flushes never pass through the instance methods wrapped here. Anything
    -- logged as DIRECT is therefore someone calling Screen:refreshX() by hand,
    -- which is the one case the window-stack view is blind to.
    local ok_screen = pcall(function()
        local Screen = require("device").screen
        for _, m in ipairs({ "refreshUI", "refreshPartial", "refreshFull",
                             "refreshFast", "refreshA2", "refreshFlashUI",
                             "refreshFlashPartial", "refreshNoMergeUI",
                             "refreshNoMergePartial" }) do
            local fn = Screen[m]
            if type(fn) == "function" then
                Screen[m] = function(this, x, y, w, h, dither)
                    if Debug114.armed() then
                        Debug114.log("DIRECT", m, string.format("(%s,%s %sx%s)",
                            tostring(x), tostring(y), tostring(w), tostring(h)),
                            "from=" .. caller(3))
                    end
                    return fn(this, x, y, w, h, dither)
                end
            end
        end
    end)
    Debug114.log("direct Screen refresh hooks installed:", tostring(ok_screen))

    local orig_show = UIManager.show
    UIManager.show = function(self, widget, refreshtype, refreshregion, x, y, refreshdither)
        Debug114.log("show", widgetName(widget),
            "toast=" .. tostring(widget and widget.toast or false),
            "cover=" .. tostring(widget and widget.covers_fullscreen or false))
        return orig_show(self, widget, refreshtype, refreshregion, x, y, refreshdither)
    end

    local orig_close = UIManager.close
    UIManager.close = function(self, widget, refreshtype, refreshregion, refreshdither)
        Debug114.log("close", widgetName(widget))
        return orig_close(self, widget, refreshtype, refreshregion, refreshdither)
    end
end

return Debug114
