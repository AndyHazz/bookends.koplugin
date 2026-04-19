--- Per-position (tl/tc/tr/bl/bc/br) configuration menu.
local Tokens = require("bookends_tokens")
local Utils = require("bookends_utils")
local _ = require("bookends_i18n").gettext

return function(Bookends)

function Bookends:buildPositionMenu(pos)
    local is_corner = pos.h_anchor ~= "center"
    local menu = {}
    local lines = self.positions[pos.key].lines

    -- Enable/disable toggle (only shown when position has lines)
    if #lines > 0 then
        table.insert(menu, {
            text = _("Enabled"),
            checked_func = function()
                return not self.positions[pos.key].disabled
            end,
            callback = function()
                self.positions[pos.key].disabled = not self.positions[pos.key].disabled or nil
                self:savePositionSetting(pos.key)
                self:markDirty()
            end,
            separator = true,
        })
    end

    -- Line entries
    for i, line in ipairs(lines) do
        table.insert(menu, {
            text_func = function()
                local ps = self.positions[pos.key]
                local filter = ps.line_page_filter and ps.line_page_filter[i]
                local tag = ""
                if filter == "odd" then tag = " [odd]"
                elseif filter == "even" then tag = " [even]" end
                local preview = (Tokens.expandPreview(ps.lines[i] or "", self.ui, self:getSessionElapsed(), self:getSessionPages(),
                    self.settings:readSetting("tick_width_multiplier", self.DEFAULT_TICK_WIDTH_MULTIPLIER)))
                preview = preview:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if #preview > 42 then
                    preview = Utils.truncateUtf8(preview, 39)
                end
                return _("Line") .. " " .. i .. tag .. ": " .. preview
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:editLineString(pos, i, touchmenu_instance)
            end,
            hold_callback = function(touchmenu_instance)
                self:showLineManageDialog(pos, i, touchmenu_instance)
            end,
        })
    end

    -- Add line
    table.insert(menu, {
        text = "+ " .. _("Add line") .. "  (" .. _("long press lines to manage") .. ")",
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local idx = #self.positions[pos.key].lines + 1
            table.insert(self.positions[pos.key].lines, "")
            self:savePositionSetting(pos.key)
            self:editLineString(pos, idx, touchmenu_instance)
        end,
        separator = true,
    })

    -- Per-position extra margins with nudge buttons
    local is_top = pos.v_anchor == "top"
    local v_label = is_top and _("Extra top margin") or _("Extra bottom margin")
    table.insert(menu, {
        text_func = function()
            local val = self.positions[pos.key].v_offset
            if val then return v_label .. " (" .. val .. ")" end
            return v_label
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local ps = self.positions[pos.key]
            self:showNudgeDialog(v_label, ps.v_offset or 0, 0, 999, 0, "px",
                function(val)
                    ps.v_offset = val > 0 and val or nil
                    self:markDirty()
                end,
                function()
                    self:savePositionSetting(pos.key)
                end, nil, nil, touchmenu_instance)
        end,
    })

    if is_corner then
        local is_left = pos.h_anchor == "left"
        local h_label = is_left and _("Extra left margin") or _("Extra right margin")
        table.insert(menu, {
            text_func = function()
                local val = self.positions[pos.key].h_offset
                if val then return h_label .. " (" .. val .. ")" end
                return h_label
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local ps = self.positions[pos.key]
                self:showNudgeDialog(h_label, ps.h_offset or 0, 0, 999, 0, "px",
                    function(val)
                        ps.h_offset = val > 0 and val or nil
                        self:markDirty()
                    end,
                    function()
                        self:savePositionSetting(pos.key)
                    end, nil, nil, touchmenu_instance)
            end,
        })
    end

    return menu
end

end
