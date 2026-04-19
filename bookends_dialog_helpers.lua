--- Reusable ButtonDialog shapes for nudge-style adjusters.
-- Keeps callers free to decide when to persist (live vs on-apply).
local UIManager = require("ui/uimanager")
local _ = require("bookends_i18n").gettext

local DialogHelpers = {}

--- Hide the parent touch menu while a transient dialog is open so the
--- user can see live visual changes, returning a function that re-shows it.
function DialogHelpers.hideParentMenu(touchmenu_instance)
    if not touchmenu_instance then return function() end end
    -- The UIManager stack holds show_parent (a CenterContainer), not the TouchMenu itself.
    local container = touchmenu_instance.show_parent or touchmenu_instance
    UIManager:close(container, "ui")
    return function()
        UIManager:show(container)
        touchmenu_instance:updateItems()
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
    local function revert()
        for field, value in pairs(originals) do
            opts.set_value(field, value)
        end
    end

    local function nudge(field, delta)
        local new_val = math.max(min_val, (opts.get_value(field) or 0) + delta)
        opts.set_value(field, new_val)
        if opts.on_row_change then opts.on_row_change() end
        dialog:reinit()
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
                dialog:reinit()
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
    UIManager:show(dialog)
    return dialog
end

return DialogHelpers
