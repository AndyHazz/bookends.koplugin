--- Preset Manager: central-aligned modal with Local/Gallery tabs.
-- Local tab renders Personal presets + virtual "(No overlay)" row,
-- supports preview/apply, star toggle for cycle membership, and
-- overflow actions (rename/edit description/duplicate/delete).
-- Gallery tab is a stub until Phase 2.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local util = require("util")
local _ = require("i18n").gettext
local T = require("ffi/util").template

local Screen = Device.screen

local PresetManagerModal = {}

--- Open the manager modal. Single entry point from menu / gesture.
function PresetManagerModal.show(bookends)
    local self = {
        bookends = bookends,
        tab = "local",
        page = 1,
        previewing = nil,
        original_settings = nil,
        modal_widget = nil,
    }

    self.original_settings = util.tableDeepCopy({
        enabled       = bookends.enabled,
        positions     = bookends.positions,
        defaults      = bookends.defaults,
        progress_bars = bookends.progress_bars,
        active_filename = bookends:getActivePresetFilename(),
    })

    -- nextTick lets any pending dialog dismissal flush before we re-open the modal,
    -- avoiding visual glitches where the dialog's close races the modal's rebuild.
    self.rebuild = function()
        UIManager:nextTick(function() PresetManagerModal._rebuild(self) end)
    end
    -- Initial synchronous build on show
    self.rebuildSync = function() PresetManagerModal._rebuild(self) end
    self.close = function(restore) PresetManagerModal._close(self, restore) end
    self.setTab = function(tab)
        if self.tab ~= tab then self.tab = tab; self.page = 1; self.rebuild() end
    end
    self.setPage = function(p) self.page = p; self.rebuild() end
    self.previewLocal = function(p) PresetManagerModal._previewLocal(self, p) end
    self.previewBlank = function() PresetManagerModal._previewBlank(self) end
    self.applyCurrent = function() PresetManagerModal._applyCurrent(self) end
    self.toggleStar = function(key) PresetManagerModal._toggleStar(self, key) end

    self.rebuildSync()
end

function PresetManagerModal._close(self, restore)
    if restore and self.previewing then
        local snap = self.original_settings
        self.bookends.enabled       = snap.enabled
        self.bookends.positions     = util.tableDeepCopy(snap.positions)
        self.bookends.defaults      = util.tableDeepCopy(snap.defaults)
        self.bookends.progress_bars = util.tableDeepCopy(snap.progress_bars)
        self.bookends:setActivePresetFilename(snap.active_filename)
    end
    self.bookends._previewing = false
    self.previewing = nil
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end
    self.bookends:markDirty()
end

function PresetManagerModal._previewLocal(self, entry)
    self.bookends._previewing = true
    local ok = pcall(self.bookends.loadPreset, self.bookends, entry.preset)
    if not ok then
        Notification:notify(_("Could not preview preset"))
        self.bookends._previewing = false
        return
    end
    self.previewing = { kind = "local", name = entry.name, filename = entry.filename, data = entry.preset }
    self.bookends:markDirty()
    self.rebuild()
end

function PresetManagerModal._previewBlank(self)
    self.bookends._previewing = true
    for _, pos in pairs(self.bookends.positions) do pos.lines = {} end
    -- Also disable any progress bars so the overlay really is blank.
    if self.bookends.progress_bars then
        for i = 1, #self.bookends.progress_bars do
            if self.bookends.progress_bars[i] then
                self.bookends.progress_bars[i].enabled = false
            end
        end
    end
    self.previewing = { kind = "blank", name = _("(No overlay)") }
    self.bookends:markDirty()
    self.rebuild()
end

function PresetManagerModal._applyCurrent(self)
    if not self.previewing then return end
    if self.previewing.kind == "local" then
        self.bookends:setActivePresetFilename(self.previewing.filename)
    elseif self.previewing.kind == "blank" then
        self.bookends:setActivePresetFilename(nil)
    end
    self.bookends._previewing = false
    self.previewing = nil
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end
    self.bookends:markDirty()
end

function PresetManagerModal._toggleStar(self, entry_key)
    local cycle = self.bookends.settings:readSetting("preset_cycle") or {}
    local found_idx
    for i, f in ipairs(cycle) do if f == entry_key then found_idx = i; break end end
    if found_idx then
        table.remove(cycle, found_idx)
    else
        table.insert(cycle, entry_key)
    end
    self.bookends.settings:saveSetting("preset_cycle", cycle)
    self.rebuild()
end

local function isStarred(bookends, key)
    local cycle = bookends.settings:readSetting("preset_cycle") or {}
    for _, f in ipairs(cycle) do if f == key then return true end end
    return false
end

function PresetManagerModal._rebuild(self)
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end

    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.8)
    local row_height = Screen:scaleBySize(42)
    local font_size = 18
    local baseline = math.floor(row_height * 0.65)
    local left_pad = Size.padding.large

    local vg = VerticalGroup:new{ align = "left" }

    -- Title + tab switcher
    local title_face = Font:getFace("infofont", 20)
    local title = TextWidget:new{
        text = _("Bookends preset manager"),
        face = title_face,
        bold = true,
        forced_height = row_height,
        forced_baseline = baseline,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    -- Build a tab button: framed, active tab gets bold text + radius accent
    local function tabButton(label, is_active, on_tap)
        local inner_pad = Screen:scaleBySize(12)
        local tb = TextWidget:new{
            text = label,
            face = Font:getFace("infofont", 16),
            forced_height = math.floor(row_height * 0.75),
            forced_baseline = math.floor(row_height * 0.55),
            bold = is_active,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local frame = FrameContainer:new{
            bordersize = is_active and Size.border.thick or Size.border.thin,
            radius = Size.radius.default,
            padding = 0,
            padding_left = inner_pad,
            padding_right = inner_pad,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            tb,
        }
        local ic = InputContainer:new{
            dimen = Geom:new{ w = frame:getSize().w, h = frame:getSize().h },
            frame,
        }
        ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
        ic.onTapSelect = function() on_tap(); return true end
        return ic
    end
    local local_btn   = tabButton(_("Local"),   self.tab == "local",   function() self.setTab("local") end)
    local gallery_btn = tabButton(_("Gallery"), self.tab == "gallery", function() self.setTab("gallery") end)

    -- Compute spacer width so the tab buttons sit flush with the right edge.
    local tabs_block_w = local_btn:getSize().w + Screen:scaleBySize(8) + gallery_btn:getSize().w
    local title_w = title:getWidth()
    local title_row_spacer_w = math.max(Screen:scaleBySize(20),
                                        width - left_pad - title_w - tabs_block_w - left_pad)
    table.insert(vg, LeftContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = left_pad },
            title,
            HorizontalSpan:new{ width = title_row_spacer_w },
            local_btn,
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            gallery_btn,
        },
    })
    table.insert(vg, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = width, h = Size.line.thick },
    })

    -- State header
    local active_fn = self.bookends:getActivePresetFilename()
    local active_name = _("(No overlay)")
    if active_fn then
        local presets = self.bookends:readPresetFiles()
        for _, p in ipairs(presets) do
            if p.filename == active_fn then active_name = p.name; break end
        end
    end
    local state_line = T(_("Currently editing: %1"), active_name)
    if self.previewing then
        state_line = state_line .. "  //  " .. T(_("Previewing: %1"), self.previewing.name)
    end
    local state_group = HorizontalGroup:new{
        HorizontalSpan:new{ width = left_pad },
        TextWidget:new{
            text = state_line,
            face = Font:getFace("cfont", 14),
            forced_height = row_height,
            forced_baseline = baseline,
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
    if self.previewing and self.previewing.kind == "local" then
        local overflow = TextWidget:new{
            text = "\xE2\x8B\xAF",
            face = Font:getFace("infofont", 18),
            forced_height = math.floor(row_height * 0.75),
            forced_baseline = math.floor(row_height * 0.55),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local overflow_frame = FrameContainer:new{
            bordersize = Size.border.thin,
            radius = Size.radius.default,
            padding = 0,
            padding_left = Screen:scaleBySize(14),
            padding_right = Screen:scaleBySize(14),
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            overflow,
        }
        local overflow_ic = InputContainer:new{
            dimen = Geom:new{ w = overflow_frame:getSize().w, h = overflow_frame:getSize().h },
            overflow_frame,
        }
        overflow_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = overflow_ic.dimen } } }
        overflow_ic.onTapSelect = function()
            PresetManagerModal._openOverflow(self)
            return true
        end
        -- Right-align overflow: push with a spacer filling remaining width.
        local state_text_widget = state_group[2]
        local text_w = state_text_widget:getWidth()
        local spacer_w = math.max(Screen:scaleBySize(12),
                                   width - left_pad - text_w - overflow_ic:getSize().w - left_pad)
        table.insert(state_group, HorizontalSpan:new{ width = spacer_w })
        table.insert(state_group, overflow_ic)
    end
    table.insert(vg, LeftContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        state_group,
    })

    -- Body
    if self.tab == "local" then
        PresetManagerModal._renderLocalRows(self, vg, width, row_height, font_size, baseline, left_pad)
    else
        table.insert(vg, LeftContainer:new{
            dimen = Geom:new{ w = width, h = row_height * 3 },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = left_pad },
                TextWidget:new{
                    text = _("Gallery — coming soon"),
                    face = Font:getFace("infofont", 16),
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            },
        })
    end

    -- Footer buttons
    local btn_close = TextWidget:new{
        text = _("Close"),
        face = Font:getFace("infofont", 16),
        forced_height = row_height,
        forced_baseline = baseline,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local btn_close_ic = InputContainer:new{
        dimen = Geom:new{ w = math.floor((width - Size.line.thick) / 2), h = row_height },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor((width - Size.line.thick) / 2), h = row_height },
            btn_close,
        },
    }
    btn_close_ic.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = btn_close_ic.dimen } },
    }
    btn_close_ic.onTapSelect = function() self.close(true); return true end

    local apply_text = _("Apply")
    if self.previewing and self.previewing.kind == "gallery" then
        apply_text = _("Install")
    end
    local btn_apply = TextWidget:new{
        text = apply_text,
        face = Font:getFace("infofont", 16),
        forced_height = row_height,
        forced_baseline = baseline,
        bold = true,
        fgcolor = self.previewing and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    local btn_apply_ic = InputContainer:new{
        dimen = Geom:new{ w = math.floor((width - Size.line.thick) / 2), h = row_height },
        CenterContainer:new{
            dimen = Geom:new{ w = math.floor((width - Size.line.thick) / 2), h = row_height },
            btn_apply,
        },
    }
    btn_apply_ic.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = btn_apply_ic.dimen } },
    }
    btn_apply_ic.onTapSelect = function()
        if self.previewing then self.applyCurrent() end
        return true
    end

    table.insert(vg, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = width, h = Size.line.thick },
    })
    local btn_divider = LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = Size.line.thick, h = row_height },
    }
    table.insert(vg, HorizontalGroup:new{ btn_close_ic, btn_divider, btn_apply_ic })

    -- Outer frame + center
    local frame = FrameContainer:new{
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        vg,
    }
    local wc = CenterContainer:new{
        dimen = Screen:getSize(),
        frame,
    }
    self.modal_widget = wc
    UIManager:show(wc)
    -- Force a full-screen flash so e-ink repaints cleanly when a dialog above
    -- us closes and we rebuild (otherwise the dialog's last frame can ghost).
    UIManager:setDirty("all", "flashui")
end

function PresetManagerModal._renderLocalRows(self, vg, width, row_height, font_size, baseline, left_pad)
    -- "+ Save current as new preset"
    local plus = TextWidget:new{
        text = "+ " .. _("Save current as new preset"),
        face = Font:getFace("infofont", 16),
        forced_height = row_height,
        forced_baseline = baseline,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local plus_ic = InputContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        HorizontalGroup:new{ HorizontalSpan:new{ width = left_pad }, plus },
    }
    plus_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = plus_ic.dimen } } }
    plus_ic.onTapSelect = function() PresetManagerModal._saveCurrentAsPreset(self); return true end
    table.insert(vg, plus_ic)

    -- Work out which row should look "selected" — the one currently previewed,
    -- or the currently-active preset when nothing is being previewed.
    local active_fn = self.bookends:getActivePresetFilename()
    local selected_key
    if self.previewing then
        if self.previewing.kind == "blank" then selected_key = "_empty"
        elseif self.previewing.kind == "local" then selected_key = self.previewing.filename
        end
    else
        selected_key = active_fn  -- nil means the virtual blank is active
        if selected_key == nil then selected_key = "_empty" end
    end

    -- Virtual "(No overlay)" row
    PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
        display = _("(No overlay)"),
        star_key = "_empty",
        on_preview = function() self.previewBlank() end,
        is_selected = (selected_key == "_empty"),
    })

    -- Real presets, paginated
    local presets = self.bookends:readPresetFiles()
    local ROWS_PER_PAGE = 8
    local total_pages = math.max(1, math.ceil(#presets / ROWS_PER_PAGE))
    if self.page > total_pages then self.page = total_pages end
    local start_idx = (self.page - 1) * ROWS_PER_PAGE + 1
    local end_idx = math.min(start_idx + ROWS_PER_PAGE - 1, #presets)
    for i = start_idx, end_idx do
        local p = presets[i]
        local by = p.preset.author and (" — " .. p.preset.author) or ""
        PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
            display = p.name .. by,
            star_key = p.filename,
            on_preview = function() self.previewLocal(p) end,
            is_selected = (selected_key == p.filename),
        })
    end

    -- Pad out short pages so the modal height stays stable across pages
    local rendered = end_idx - start_idx + 1
    for _ = rendered + 1, ROWS_PER_PAGE do
        table.insert(vg, HorizontalGroup:new{
            HorizontalSpan:new{ width = left_pad },
            TextWidget:new{
                text = "",
                face = Font:getFace("cfont", font_size),
                forced_height = row_height,
                forced_baseline = baseline,
            },
        })
    end

    -- Pagination nav (matching font picker style)
    if total_pages > 1 then
        local page_cur = self.page
        local page_nav = HorizontalGroup:new{
            align = "center",
            Button:new{ icon = "chevron.first",
                callback = function() self.setPage(1) end,
                bordersize = 0, enabled = page_cur > 1, show_parent = self.modal_widget },
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            Button:new{ icon = "chevron.left",
                callback = function() self.setPage(page_cur - 1) end,
                bordersize = 0, enabled = page_cur > 1, show_parent = self.modal_widget },
            HorizontalSpan:new{ width = Screen:scaleBySize(16) },
            Button:new{ text = T(_("Page %1 of %2"), page_cur, total_pages),
                text_font_size = 16, callback = function() end,
                bordersize = 0, show_parent = self.modal_widget },
            HorizontalSpan:new{ width = Screen:scaleBySize(16) },
            Button:new{ icon = "chevron.right",
                callback = function() self.setPage(page_cur + 1) end,
                bordersize = 0, enabled = page_cur < total_pages, show_parent = self.modal_widget },
            HorizontalSpan:new{ width = Screen:scaleBySize(8) },
            Button:new{ icon = "chevron.last",
                callback = function() self.setPage(total_pages) end,
                bordersize = 0, enabled = page_cur < total_pages, show_parent = self.modal_widget },
        }
        table.insert(vg, CenterContainer:new{
            dimen = Geom:new{ w = width, h = row_height },
            page_nav,
        })
    end
end

function PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, opts)
    local starred = isStarred(self.bookends, opts.star_key)
    local star_widget = TextWidget:new{
        text = starred and "\xE2\x98\x85" or "\xE2\x98\x86",
        face = Font:getFace("infofont", 18),
        forced_height = row_height,
        forced_baseline = baseline,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local star_width = Screen:scaleBySize(40)
    local star_ic = InputContainer:new{
        dimen = Geom:new{ w = star_width, h = row_height },
        CenterContainer:new{ dimen = Geom:new{ w = star_width, h = row_height }, star_widget },
    }
    star_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = star_ic.dimen } } }
    local key = opts.star_key
    star_ic.onTapSelect = function() self.toggleStar(key); return true end

    local name_widget = TextWidget:new{
        text = (opts.is_selected and "\xE2\x96\xB8 " or "   ") .. opts.display,
        face = Font:getFace("cfont", font_size),
        forced_height = row_height,
        forced_baseline = baseline,
        max_width = width - 2 * left_pad - star_width,
        fgcolor = Blitbuffer.COLOR_BLACK,
        bold = opts.is_selected,
    }
    local name_ic = InputContainer:new{
        dimen = Geom:new{ w = width - 2 * left_pad - star_width, h = row_height },
        name_widget,
    }
    name_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = name_ic.dimen } } }
    name_ic.onTapSelect = function() opts.on_preview(); return true end

    table.insert(vg, HorizontalGroup:new{
        HorizontalSpan:new{ width = left_pad },
        star_ic,
        name_ic,
    })
end

function PresetManagerModal._saveCurrentAsPreset(self)
    local dlg
    dlg = InputDialog:new{
        title = _("Save preset"),
        input = "",
        input_hint = _("Preset name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dlg)
                self.rebuild()
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dlg:getInputText()
                if name and name ~= "" then
                    local preset = self.bookends:buildPreset()
                    preset.name = name
                    local filename = self.bookends:writePresetFile(name, preset)
                    self.bookends:setActivePresetFilename(filename)
                    local cycle = self.bookends.settings:readSetting("preset_cycle") or {}
                    table.insert(cycle, filename)
                    self.bookends.settings:saveSetting("preset_cycle", cycle)
                end
                UIManager:close(dlg)
                self.rebuild()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function PresetManagerModal._openOverflow(self)
    if not self.previewing or self.previewing.kind ~= "local" then return end
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local entry_name = self.previewing.name
    local entry_filename = self.previewing.filename
    -- Snapshot the entry for the closures to use — self.previewing may change.
    local entry = { name = entry_name, filename = entry_filename, preset = self.previewing.data }
    local dlg
    dlg = ButtonDialogTitle:new{
        title = entry.name,
        title_align = "center",
        buttons = {
            {{ text = _("Rename…"), callback = function()
                UIManager:close(dlg)
                PresetManagerModal._rename(self, entry)
            end }},
            {{ text = _("Edit description…"), callback = function()
                UIManager:close(dlg)
                PresetManagerModal._editDescription(self, entry)
            end }},
            {{ text = _("Duplicate"), callback = function()
                UIManager:close(dlg)
                PresetManagerModal._duplicate(self, entry)
            end }},
            {{ text = _("Delete"), callback = function()
                UIManager:close(dlg)
                PresetManagerModal._delete(self, entry)
            end }},
        },
    }
    UIManager:show(dlg)
end

function PresetManagerModal._rename(self, entry)
    local dlg
    dlg = InputDialog:new{
        title = _("Rename preset"),
        input = entry.name,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Rename"), is_enter_default = true, callback = function()
                local new_name = dlg:getInputText()
                if new_name and new_name ~= "" and new_name ~= entry.name then
                    local new_filename = self.bookends:renamePresetFile(entry.filename, new_name)
                    if new_filename then
                        local cycle = self.bookends.settings:readSetting("preset_cycle") or {}
                        for i, f in ipairs(cycle) do
                            if f == entry.filename then cycle[i] = new_filename; break end
                        end
                        self.bookends.settings:saveSetting("preset_cycle", cycle)
                        if self.bookends:getActivePresetFilename() == entry.filename then
                            self.bookends:setActivePresetFilename(new_filename)
                        end
                        self.previewing = nil
                        self.bookends._previewing = false
                    end
                end
                UIManager:close(dlg)
                self.rebuild()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function PresetManagerModal._editDescription(self, entry)
    local current = (entry.preset and entry.preset.description) or ""
    local dlg
    dlg = InputDialog:new{
        title = _("Edit description"),
        input = current,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local new_desc = dlg:getInputText() or ""
                local path = self.bookends:presetDir() .. "/" .. entry.filename
                local data = self.bookends.loadPresetFile(path)
                if data then
                    data.description = new_desc ~= "" and new_desc or nil
                    self.bookends:writePresetFile(data.name or entry.name, data)
                end
                UIManager:close(dlg)
                self.rebuild()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function PresetManagerModal._duplicate(self, entry)
    local suggested = entry.name .. " (" .. _("copy") .. ")"
    local dlg
    dlg = InputDialog:new{
        title = _("Duplicate preset"),
        input = suggested,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local new_name = dlg:getInputText()
                if new_name and new_name ~= "" then
                    local path = self.bookends:presetDir() .. "/" .. entry.filename
                    local data = self.bookends.loadPresetFile(path)
                    if data then
                        data.name = new_name
                        self.bookends:writePresetFile(new_name, data)
                    end
                end
                UIManager:close(dlg)
                self.rebuild()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function PresetManagerModal._delete(self, entry)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete preset '%1'?"), entry.name),
        ok_text = _("Delete"),
        ok_callback = function()
            self.bookends:deletePresetFile(entry.filename)
            local cycle = self.bookends.settings:readSetting("preset_cycle") or {}
            for i = #cycle, 1, -1 do
                if cycle[i] == entry.filename then table.remove(cycle, i) end
            end
            self.bookends.settings:saveSetting("preset_cycle", cycle)
            if self.bookends:getActivePresetFilename() == entry.filename then
                local remaining = self.bookends:readPresetFiles()
                if remaining[1] then
                    self.bookends:applyPresetFile(remaining[1].filename)
                else
                    self.bookends:setActivePresetFilename(nil)
                end
            end
            self.previewing = nil
            self.bookends._previewing = false
            self.bookends:markDirty()
            self.rebuild()
        end,
    })
end

return PresetManagerModal
