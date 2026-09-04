--- Reusable ButtonDialog shapes for nudge-style adjusters.
-- Keeps callers free to decide when to persist (live vs on-apply).
local Device = require("device")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("bookends_i18n").gettext

local DialogHelpers = {}

--- Hide the parent touch menu while a transient dialog is open so the
--- user can see live visual changes, returning a function that re-shows it.
---
--- `touchmenu_instance` is only a real TouchMenu when KOReader drew the menu.
--- A third-party menu host can render our items in its own widget and pass a
--- plain-table proxy instead - ZenOS does exactly that, handing callbacks a
--- table with just updateItems/closeMenu/onClose/handleEvent. Re-showing that
--- proxy puts a non-widget on UIManager._window_stack, which `show` accepts
--- (it only needs handleEvent) and the next repaint dies on, taking KOReader
--- with it: "attempt to call method 'paintTo' (a nil value)" (#112). So only
--- hide what we can prove is paintable; against any other host the dialog just
--- opens over the menu instead of in place of it.
function DialogHelpers.hideParentMenu(touchmenu_instance)
    if not touchmenu_instance then return function() end end
    local function refresh()
        if type(touchmenu_instance.updateItems) == "function" then
            touchmenu_instance:updateItems()
        end
    end
    -- The UIManager stack holds show_parent (a CenterContainer), not the TouchMenu itself.
    local container = touchmenu_instance.show_parent or touchmenu_instance
    if type(container.paintTo) ~= "function" then return refresh end
    UIManager:close(container, "ui")
    return function()
        UIManager:show(container)
        refresh()
    end
end

--- Build one nudge row: [ -big | -small | label:value | +small | +big ].
local function makeNudgeRow(label, field, get_value, nudge_fn, steps)
    local small, big = steps[1], steps[2]
    return {
        { text = "-" .. big, callback = function() nudge_fn(field, -big) end },
        { text = "-" .. small, callback = function() nudge_fn(field, -small) end },
        { text_func = function() return label .. ": " .. tostring(get_value(field)) end, enabled = false },
        { text = "+" .. small, callback = function() nudge_fn(field, small) end },
        { text = "+" .. big, callback = function() nudge_fn(field, big) end },
    }
end

--- Show a dialog with one nudge row per field plus Cancel/Default/Apply.
-- opts (required unless noted):
--   title            (string)
--   rows             list of { label = _("Top"), field = "margin_top" }
--   get_value        function(field) -> number
--   set_value        function(field, value)
--   on_row_change    function?                called after set_value, before reinit
--   on_cancel        function?                called after revert, before dialog close
--   on_default       function?                Default button handler (called with reinit helper)
--   on_apply         function?                Apply button handler
--   on_close         function?                called after any button/tap closes the dialog
--   default_text     string?                  text for the Default button (defaults to _("Default"))
--   steps            {small, big}?            default {1, 10}
--   min_val          number?                  clamp floor (default 0)
--   parent_menu      touchmenu_instance?      will be hidden while dialog is open
-- Returns the ButtonDialog widget (caller may capture it if needed).
function DialogHelpers.showNudgeGrid(opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local steps = opts.steps or { 1, 10 }
    local min_val = opts.min_val or 0
    local restoreMenu = DialogHelpers.hideParentMenu(opts.parent_menu)

    -- Snapshot originals so Cancel / tap-outside can revert.
    local originals = {}
    for _, row in ipairs(opts.rows) do
        originals[row.field] = opts.get_value(row.field)
    end

    local dialog
    -- ButtonDialog:reinit() rebuilds the buttons but keeps a stale self.layout
    -- (buttondialog.lua:267 `self.layout = self.layout or ...`), which strands
    -- the d-pad cursor on the now-freed widgets — arrows stop working after a
    -- nudge. Discard the layout so init() adopts the fresh one, then re-anchor
    -- focus on the next tick (the pressed Button repaints after its callback).
    -- No-op on touch devices (refocusWidget uses FOCUS_ONLY_ON_NT).
    local function rebuild()
        dialog.layout = nil
        dialog:reinit()
        dialog:refocusWidget(true)
    end
    local function revert()
        for field, value in pairs(originals) do
            opts.set_value(field, value)
        end
    end

    local function nudge(field, delta)
        local new_val = math.max(min_val, (opts.get_value(field) or 0) + delta)
        opts.set_value(field, new_val)
        if opts.on_row_change then opts.on_row_change() end
        rebuild()
    end

    local button_rows = {}
    for _, row in ipairs(opts.rows) do
        table.insert(button_rows, makeNudgeRow(row.label, row.field, opts.get_value, nudge, steps))
    end

    local function closeAndRestore()
        UIManager:close(dialog)
        restoreMenu()
        if opts.on_close then opts.on_close() end
    end

    table.insert(button_rows, {
        {
            text = _("Cancel"),
            callback = function()
                revert()
                if opts.on_cancel then opts.on_cancel() end
                closeAndRestore()
            end,
        },
        {
            text = opts.default_text or _("Default"),
            callback = function()
                if opts.on_default then opts.on_default() end
                rebuild()
            end,
        },
        {
            text = _("Apply"),
            is_enter_default = true,
            callback = function()
                if opts.on_apply then opts.on_apply() end
                closeAndRestore()
            end,
        },
    })

    dialog = ButtonDialog:new{
        dismissable = false,
        title = opts.title,
        tap_close_callback = function()
            revert()
            if opts.on_cancel then opts.on_cancel() end
            restoreMenu()
            if opts.on_close then opts.on_close() end
        end,
        buttons = button_rows,
    }
    -- dismissable=false makes ButtonDialog skip its own Back/tap-close wiring
    -- (buttondialog.lua:98), so a keyed/d-pad user would be trapped with no
    -- exit. Re-add ONLY the Back key binding (not tap-close — taps outside must
    -- still be ignored, which is the whole point of dismissable=false). Back
    -- routes to ButtonDialog:onClose, which runs our tap_close_callback
    -- (revert + restore) then closes — i.e. Back == Cancel. Mirrors the
    -- back_group construction ButtonDialog uses for its own Close binding.
    if Device:hasKeys() then
        local back_group = util.tableDeepCopy(Device.input.group.Back)
        table.insert(back_group, Device:hasFewKeys() and "Left" or "Menu")
        dialog.key_events.Close = { { back_group } }
    end
    UIManager:show(dialog)
    return dialog
end

return DialogHelpers
