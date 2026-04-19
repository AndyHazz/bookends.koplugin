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
local VerticalSpan = require("ui/widget/verticalspan")
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
        gallery_index = nil,
        gallery_loading = false,
        gallery_error = nil,
    }

    -- Snapshot the complete overlay state via the same pipeline used to save a
    -- preset. On Close-revert we re-apply via loadPreset, which writes back to
    -- settings too — purely in-memory reverts leaked preview data into settings
    -- (loadPreset saves each progress_bar_N and pos_X when applying a preview).
    self.original_preset = bookends:buildPreset()
    self.original_active_filename = bookends:getActivePresetFilename()

    -- nextTick lets any pending dialog dismissal flush before we re-open the modal,
    -- avoiding visual glitches where the dialog's close races the modal's rebuild.
    self.rebuild = function()
        UIManager:nextTick(function() PresetManagerModal._rebuild(self) end)
    end
    -- Initial synchronous build on show
    self.rebuildSync = function() PresetManagerModal._rebuild(self) end
    self.close = function(restore) PresetManagerModal._close(self, restore) end
    -- Explicit refresh: only called by the user tapping the Refresh button.
    -- This is the single code path that initiates a network request for the
    -- gallery index. Results live in self.gallery_index for the lifetime of
    -- this modal only — nothing is persisted to disk.
    self.refreshGallery = function()
        if self.gallery_loading then return end
        local Gallery = require("preset_gallery")
        self.gallery_loading = true
        self.gallery_error = nil
        self.rebuild()
        Gallery.fetchIndex("KOReader-Bookends", function(idx, err)
            self.gallery_loading = false
            if idx then
                self.gallery_index = idx
                self.gallery_error = nil
            else
                self.gallery_error = err
            end
            self.rebuild()
        end)
    end
    self.setTab = function(tab)
        if self.tab ~= tab then
            self.tab = tab
            self.page = 1
            self.rebuild()
        end
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
        -- Must clear _previewing before loadPreset so the saveSetting calls
        -- inside it actually persist; but autosaveActivePreset is triggered
        -- via onFlushSettings which is fine either way since loadPreset is
        -- restoring the ORIGINAL active preset's config.
        self.bookends._previewing = false
        self.bookends:loadPreset(self.original_preset)
        self.bookends:setActivePresetFilename(self.original_active_filename)
    end
    self.bookends._previewing = false
    self.previewing = nil
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end
    self.bookends:markDirty()
    -- Persist now — closing the manager is a strong signal the user is done
    -- making edits. Belt-and-braces alongside markDirty's debounce, in case
    -- the app is backgrounded before the 2s debounce fires.
    pcall(function() self.bookends.settings:flush() end)
    pcall(self.bookends.autosaveActivePreset, self.bookends)
end

function PresetManagerModal._previewLocal(self, entry)
    -- Commit any pending tweaks on the currently-active preset BEFORE loading
    -- this one. Without this, menu tweaks that haven't triggered a settings
    -- flush yet get wiped when loadPreset mutates the live state.
    pcall(self.bookends.autosaveActivePreset, self.bookends)

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
    -- Same reason as _previewLocal — flush tweaks before overwriting live state.
    pcall(self.bookends.autosaveActivePreset, self.bookends)
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
    elseif self.previewing.kind == "gallery" then
        -- Install: save to bookends_presets/ and make active.
        local entry = self.previewing.entry
        local data = self.previewing.data
        local existing
        for _, p in ipairs(self.bookends:readPresetFiles()) do
            if p.name == entry.name then existing = p; break end
        end
        if existing then
            PresetManagerModal._promptInstallCollision(self, existing, data, entry)
            return  -- flow continues after user choice
        end
        local filename = self.bookends:writePresetFile(entry.name, data)
        self.bookends:setActivePresetFilename(filename)
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
    -- Tab-style segmented toggle: each half fills the full row height so the
    -- bottom edge sits flush with the title-row separator below. Active half
    -- has inverted colors.
    local function segmentHalf(label, is_active, on_tap)
        local pad_h = Screen:scaleBySize(16)
        local bg = is_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        local fg = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local tb = TextWidget:new{
            text = label,
            face = Font:getFace("infofont", 16),
            bold = is_active,
            forced_height = row_height,
            forced_baseline = baseline,
            fgcolor = fg,
        }
        local frame = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_left = pad_h, padding_right = pad_h,
            padding_top = 0, padding_bottom = 0,
            margin = 0,
            background = bg,
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
    local local_seg   = segmentHalf(_("Local"),   self.tab == "local",   function() self.setTab("local") end)
    local gallery_seg = segmentHalf(_("Gallery"), self.tab == "gallery", function() self.setTab("gallery") end)
    local seg_divider = LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = Size.line.thin, h = math.max(local_seg:getSize().h, gallery_seg:getSize().h) },
    }
    local segmented = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{ local_seg, seg_divider, gallery_seg },
    }

    -- Right-align the segmented toggle on the title row.
    local title_w = title:getWidth()
    local seg_w = segmented:getSize().w
    local title_row_spacer_w = math.max(Screen:scaleBySize(20),
                                        width - left_pad - title_w - seg_w - left_pad)
    table.insert(vg, LeftContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        HorizontalGroup:new{
            HorizontalSpan:new{ width = left_pad },
            title,
            HorizontalSpan:new{ width = title_row_spacer_w },
            segmented,
        },
    })
    table.insert(vg, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = width, h = Size.line.thick },
    })

    -- (No dedicated state header row — the ▸ indicator on the selected row + the
    --  inline ⋯ on Personal preset rows carry that information more compactly.)

    -- Body
    if self.tab == "local" then
        PresetManagerModal._renderLocalRows(self, vg, width, row_height, font_size, baseline, left_pad)
    else
        PresetManagerModal._renderGalleryRows(self, vg, width, row_height, font_size, baseline, left_pad)
    end

    -- Footer: three buttons (Close | Edit | Apply) separated by thin vertical lines.
    -- Edit targets whichever Personal preset is "selected": the previewed one
    -- if we're previewing a Local row, otherwise the currently-active preset
    -- (highlighted in the list when no preview is active). Gallery previews
    -- and virtual-blank previews leave edit disabled.
    local edit_target
    if self.previewing then
        if self.previewing.kind == "local" then
            edit_target = self.previewing.filename
        end
    else
        edit_target = self.bookends:getActivePresetFilename()
    end
    local edit_enabled = edit_target ~= nil
    local btn_w = math.floor((width - 2 * Size.line.thick) / 3)

    local function make_footer_btn(label_text, active, on_tap, is_bold)
        local label = TextWidget:new{
            text = label_text,
            face = Font:getFace("infofont", 16),
            forced_height = row_height,
            forced_baseline = baseline,
            bold = is_bold and active,
            fgcolor = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local ic = InputContainer:new{
            dimen = Geom:new{ w = btn_w, h = row_height },
            CenterContainer:new{ dimen = Geom:new{ w = btn_w, h = row_height }, label },
        }
        ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
        ic.onTapSelect = function() if active then on_tap() end; return true end
        return ic
    end

    local btn_close_ic = make_footer_btn(_("Close"), true,
        function() self.close(true) end, true)
    local btn_edit_ic = make_footer_btn(_("Edit…"), edit_enabled, function()
        -- Open the same overflow actions that long-press triggers
        if not edit_target then return end
        local presets = self.bookends:readPresetFiles()
        for _i, p in ipairs(presets) do
            if p.filename == edit_target then
                PresetManagerModal._openOverflow(self, p)
                return
            end
        end
    end, false)
    local apply_text = (self.previewing and self.previewing.kind == "gallery")
        and _("Install") or _("Apply")
    local btn_apply_ic = make_footer_btn(apply_text, self.previewing ~= nil,
        function() self.applyCurrent() end, true)

    table.insert(vg, LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = width, h = Size.line.thick },
    })
    local vdiv = function() return LineWidget:new{
        background = Blitbuffer.COLOR_BLACK,
        dimen = Geom:new{ w = Size.line.thick, h = row_height },
    } end
    table.insert(vg, HorizontalGroup:new{ btn_close_ic, vdiv(), btn_edit_ic, vdiv(), btn_apply_ic })

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
    -- A small top gap so cards don't butt against the title separator.
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })

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

    -- Virtual "(No overlay)" row — only on page 1. A compact single-line
    -- strip (not a card) whose total height matches the Gallery tab's
    -- Refresh button strip so tab-switching doesn't resize the modal.
    -- It's a cycle slot, not a preset: tap-the-label shows a hint, tap-the-
    -- star toggles cycle membership (same as every other starred row).
    if self.page == 1 then
        local blank_selected = (selected_key == "_empty")
        local compact_pad_v = Screen:scaleBySize(6)
        local label_widget = TextWidget:new{
            text = _("Star favorites to cycle through them; star this for a blank"),
            face = Font:getFace("cfont", 14),
            bold = blank_selected,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        -- Height is computed the same way the Gallery Refresh button derives
        -- its own height (text + 2·btn_pad_v + 2·thin border), so the two
        -- tabs produce identical vertical offsets above the first card.
        local compact_h = label_widget:getSize().h + 2 * compact_pad_v + 2 * Size.border.thin
        local star_widget = TextWidget:new{
            text = isStarred(self.bookends, "_empty") and "\xE2\x98\x85" or "\xE2\x98\x86",
            face = Font:getFace("infofont", 18),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local star_w = Screen:scaleBySize(40)
        local star_ic = InputContainer:new{
            dimen = Geom:new{ w = star_w, h = compact_h },
            CenterContainer:new{ dimen = Geom:new{ w = star_w, h = compact_h }, star_widget },
        }
        star_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = star_ic.dimen } } }
        star_ic.onTapSelect = function() self.toggleStar("_empty"); return true end

        local label_inner_w = width - 2 * left_pad - Screen:scaleBySize(6) - star_w
        local label_ic = InputContainer:new{
            dimen = Geom:new{ w = label_inner_w, h = compact_h },
            LeftContainer:new{
                dimen = Geom:new{ w = label_inner_w, h = compact_h },
                label_widget,
            },
        }
        label_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = label_ic.dimen } } }
        label_ic.onTapSelect = function()
            Notification:notify(_("Tap the star to include a blank slot when cycling presets."))
            return true
        end

        table.insert(vg, HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = left_pad },
            label_ic,
            HorizontalSpan:new{ width = Screen:scaleBySize(6) },
            star_ic,
        })
        -- Match the inter-card gap so the first real preset sits at the
        -- same distance below as subsequent rows sit from each other.
        table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })
    end

    -- Real presets, paginated. Page 1 fits the same 5 cards as the Gallery
    -- tab — the compact (No overlay) strip above is small enough that we
    -- don't need to displace a card.
    local presets = self.bookends:readPresetFiles()
    local ROWS_PER_PAGE = 5
    local total_pages = math.max(1, math.ceil(#presets / ROWS_PER_PAGE))
    if self.page > total_pages then self.page = total_pages end
    local start_idx = (self.page - 1) * ROWS_PER_PAGE + 1
    local end_idx = math.min(start_idx + ROWS_PER_PAGE - 1, #presets)
    for i = start_idx, end_idx do
        local p = presets[i]
        PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
            display = p.name,
            description = p.preset.description,
            author = p.preset.author,
            star_key = p.filename,
            on_preview = function() self.previewLocal(p) end,
            on_hold = function() PresetManagerModal._openOverflow(self, p) end,
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
    -- Row layout:  [ card (title + description/author) ]  [ gap ]  [ star ]
    -- Tap card → preview. Tap star → toggle cycle membership (no preview).
    -- Selected row gets a light-gray background fill instead of a thick border.
    -- `opts` fields: display (title), star_key, on_preview, on_hold, is_selected,
    --                 description (optional), author (optional), is_virtual (optional)
    local starred = isStarred(self.bookends, opts.star_key)
    local card_height = Screen:scaleBySize(64)
    local star_width = Screen:scaleBySize(40)
    local star_gap = Screen:scaleBySize(6)
    local inner_pad = Screen:scaleBySize(12)
    local card_outer_w = width - 2 * left_pad - star_gap - star_width
    local content_w = card_outer_w - 2 * inner_pad - 2 * Size.border.thin

    -- Secondary text colour: DARK_GRAY on WHITE is fine; on LIGHT_GRAY
    -- (selected state) we darken to pure black for readable contrast.
    local secondary_fg = opts.is_selected and Blitbuffer.COLOR_BLACK
        or Blitbuffer.COLOR_DARK_GRAY

    -- Title line: "Title" + optional " by Author" in smaller lighter type.
    -- Both widgets get the same forced_height + forced_baseline so the 18pt
    -- title and 12pt "by Author" tail share a visual baseline.
    local title_h = Screen:scaleBySize(26)
    local title_bl = Screen:scaleBySize(20)
    local title_widget = TextWidget:new{
        text = opts.display,
        face = Font:getFace("cfont", 18),
        bold = opts.is_selected or false,
        forced_height = title_h,
        forced_baseline = title_bl,
        max_width = content_w,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local title_line = HorizontalGroup:new{ title_widget }
    if not opts.is_virtual and opts.author and opts.author ~= "" then
        table.insert(title_line, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(title_line, TextWidget:new{
            text = _("by") .. " " .. opts.author,
            face = Font:getFace("cfont", 12),
            forced_height = title_h,
            forced_baseline = title_bl,
            max_width = content_w - title_widget:getWidth(),
            fgcolor = secondary_fg,
        })
    end

    -- Description-only second line (author is in the title line now).
    local description_widget
    if not opts.is_virtual and opts.description and opts.description ~= "" then
        description_widget = TextWidget:new{
            text = opts.description,
            face = Font:getFace("cfont", 12),
            max_width = content_w,
            fgcolor = secondary_fg,
        }
    end

    local content_group = VerticalGroup:new{ align = "left", title_line }
    if description_widget then
        table.insert(content_group, description_widget)
    end

    local content_row = LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = card_height - 2 * Size.border.thin },
        content_group,
    }

    -- Card frame: thin border always; background fills light-gray when selected.
    local card_bg = opts.is_selected
        and (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.gray(0.92))
        or Blitbuffer.COLOR_WHITE
    local card_frame = FrameContainer:new{
        bordersize = Size.border.thin,
        radius = Size.radius.default,
        padding = 0,
        padding_left = inner_pad,
        padding_right = inner_pad,
        padding_top = 0,
        padding_bottom = 0,
        margin = 0,
        background = card_bg,
        content_row,
    }

    -- Tap/hold on the card previews / opens overflow.
    local card = InputContainer:new{
        dimen = Geom:new{ w = card_frame:getSize().w, h = card_frame:getSize().h },
        card_frame,
    }
    card.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = card.dimen } } }
    card.onTapSelect = function() opts.on_preview(); return true end
    if opts.on_hold then
        card.ges_events.HoldSelect = { GestureRange:new{ ges = "hold", range = card.dimen } }
        card.onHoldSelect = function() opts.on_hold(); return true end
    end

    -- Right-hand accent column. Local rows show a tappable ★/☆ that toggles
    -- cycle membership. Gallery rows show a ✓ if the preset is already
    -- installed locally (not tappable). Anything else gets an empty slot so
    -- cards stay left-aligned consistently.
    local accent_ic
    if opts.star_key then
        local star_widget = TextWidget:new{
            text = starred and "\xE2\x98\x85" or "\xE2\x98\x86",
            face = Font:getFace("infofont", 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        accent_ic = InputContainer:new{
            dimen = Geom:new{ w = star_width, h = card_height },
            CenterContainer:new{ dimen = Geom:new{ w = star_width, h = card_height }, star_widget },
        }
        accent_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = accent_ic.dimen } } }
        local key = opts.star_key
        accent_ic.onTapSelect = function() self.toggleStar(key); return true end
    elseif opts.installed then
        local check_widget = TextWidget:new{
            text = "\xE2\x9C\x93",  -- ✓
            face = Font:getFace("infofont", 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        accent_ic = CenterContainer:new{
            dimen = Geom:new{ w = star_width, h = card_height },
            check_widget,
        }
    else
        accent_ic = HorizontalSpan:new{ width = star_width }
    end

    table.insert(vg, HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = left_pad },
        card,
        HorizontalSpan:new{ width = star_gap },
        accent_ic,
    })
    -- Gap between cards
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })
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

function PresetManagerModal._openOverflow(self, preset_entry)
    -- preset_entry is a row from readPresetFiles: { name, filename, preset }.
    -- Invoked by long-press on a Personal preset row.
    if not preset_entry then return end
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local entry = { name = preset_entry.name, filename = preset_entry.filename, preset = preset_entry.preset }
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
            {{ text = _("Edit author…"), callback = function()
                UIManager:close(dlg)
                PresetManagerModal._editAuthor(self, entry)
            end }},
            {{ text = _("Duplicate"), callback = function()
                UIManager:close(dlg)
                PresetManagerModal._duplicate(self, entry)
            end }},
            {{ text = _("Submit to gallery…"), callback = function()
                UIManager:close(dlg)
                PresetManagerModal._submitToGallery(self, entry)
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

--- Shared helper: edit a single metadata string field (description, author) in place.
-- For "author", an empty current value is prefilled with the last-used author
-- name (from the plugin settings) — people tend to submit presets under a
-- consistent handle.
local function editMetadataField(self, entry, field_key, dialog_title, on_done)
    local current = (entry.preset and entry.preset[field_key]) or ""
    if current == "" and field_key == "author" then
        current = self.bookends.settings:readSetting("preset_submission_author") or ""
    end
    local dlg
    dlg = InputDialog:new{
        title = dialog_title,
        input = current,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local new_val = dlg:getInputText() or ""
                local path = self.bookends:presetDir() .. "/" .. entry.filename
                local data = self.bookends.loadPresetFile(path)
                if data then
                    data[field_key] = new_val ~= "" and new_val or nil
                    self.bookends:updatePresetFile(entry.filename, data.name or entry.name, data)
                    -- Refresh in-memory entry.preset so subsequent checks see the new value
                    entry.preset = data
                end
                -- Remember author across submissions
                if field_key == "author" and new_val ~= "" then
                    self.bookends.settings:saveSetting("preset_submission_author", new_val)
                end
                UIManager:close(dlg)
                if on_done then on_done(new_val) else self.rebuild() end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

--- Collect every line_font_face + defaults.font_face that isn't a "@family:..."
-- sentinel (i.e. device-specific TTF paths and specific font names). Returns a
-- list of { location, font_label } and a flag for whether anything was found.
local function findNonPortableFonts(preset_data, position_labels)
    local findings = {}
    local function short(face)
        if type(face) ~= "string" or face == "" then return nil end
        if face:match("^@family:") then return nil end
        -- Extract a readable name from a path/filename
        return face:match("([^/]+)%.[tT][tT][fF]$")
            or face:match("([^/]+)%.[oO][tT][fF]$")
            or face
    end
    if preset_data.defaults and preset_data.defaults.font_face then
        local s = short(preset_data.defaults.font_face)
        if s then table.insert(findings, { location = _("Default font"), font = s }) end
    end
    if preset_data.positions then
        -- Note: `_` is gettext here; must not shadow it in the loop.
        for _idx, pos in ipairs(position_labels) do
            local p = preset_data.positions[pos.key]
            if p and p.line_font_face then
                for i, face in pairs(p.line_font_face) do
                    local s = short(face)
                    if s then
                        table.insert(findings, {
                            location = T(_("%1, line %2"), pos.label, tostring(i)),
                            font = s,
                        })
                    end
                end
            end
        end
    end
    return findings
end

--- Return a deep-copied preset with every non-portable font override stripped.
-- Keeps @family:... entries. Used for building the submission payload — the
-- user's on-disk copy is never modified.
local function stripNonPortableFonts(preset_data)
    local clean = util.tableDeepCopy(preset_data)
    if clean.defaults and clean.defaults.font_face
       and not tostring(clean.defaults.font_face):match("^@family:") then
        clean.defaults.font_face = nil
    end
    if clean.positions then
        for _k, pos_data in pairs(clean.positions) do
            if pos_data.line_font_face then
                local kept = {}
                for i, face in pairs(pos_data.line_font_face) do
                    if type(face) == "string" and face:match("^@family:") then
                        kept[i] = face
                    end
                end
                pos_data.line_font_face = kept
            end
        end
    end
    return clean
end

function PresetManagerModal._editDescription(self, entry)
    editMetadataField(self, entry, "description", _("Edit description"))
end

function PresetManagerModal._editAuthor(self, entry)
    editMetadataField(self, entry, "author", _("Edit author"))
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

--- Slugify a preset name into a gallery-compatible slug.
local function slugify(s)
    return (s:lower():gsub("[^%w]", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", ""))
end

--- Re-serialize a preset as a self-contained .lua file (what the Worker expects).
local function serializePresetForSubmission(preset_entry)
    local PresetManager = require("preset_manager")
    local header = "-- Bookends preset: " .. (preset_entry.preset.name or preset_entry.name) .. "\n"
    return header .. "return " .. PresetManager.serializeTable(preset_entry.preset) .. "\n"
end

-- Wrap the submit flow in xpcall so any unhandled error surfaces as a
-- notification rather than crashing the overlay. The submit path runs rarely
-- and shuttles between several dialogs; easy place for regressions.
local function submitToGalleryImpl(self, entry)
    -- Force any pending autosave to disk so recent edits (font change, line
    -- tweak, etc.) are present in the preset file before we serialize it.
    -- autosaveActivePreset writes the *active* preset, so this helps when the
    -- user is editing the same preset they're about to submit.
    pcall(self.bookends.autosaveActivePreset, self.bookends)
    local refreshed = self.bookends.loadPresetFile(
        self.bookends:presetDir() .. "/" .. entry.filename)
    if refreshed then entry.preset = refreshed end

    -- If any required metadata is missing, prompt inline, save it, and continue.
    local data = entry.preset
    local function needsField(f) return not data[f] or data[f] == "" end

    if needsField("author") then
        editMetadataField(self, entry, "author", _("Who should we credit as the author?"),
            function() PresetManagerModal._submitToGallery(self, entry) end)
        return
    end
    if needsField("description") then
        editMetadataField(self, entry, "description", _("One-line description of this preset"),
            function() PresetManagerModal._submitToGallery(self, entry) end)
        return
    end

    -- Remember the author for future submissions.
    if data.author and data.author ~= "" then
        self.bookends.settings:saveSetting("preset_submission_author", data.author)
    end

    -- Font portability check. Always strip specific-font overrides from the
    -- submitted copy; if any were found, warn the user first so they can
    -- cancel and switch to Font-family fonts instead.
    local non_portable = findNonPortableFonts(data, self.bookends.POSITIONS)
    local function showConfirmAndSubmit()
        local clean_data = stripNonPortableFonts(data)
        local slug = slugify(clean_data.name or entry.name)
        local preset_lua = serializePresetForSubmission({
            name = entry.name, filename = entry.filename, preset = clean_data,
        })
        local confirm
        confirm = ConfirmBox:new{
            text = T(_("Submit '%1' by %2 to the gallery? A pull request will be opened for review."),
                     clean_data.name, clean_data.author),
            ok_text = _("Submit"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                Notification:notify(_("Submitting to gallery…"))
                local Gallery = require("preset_gallery")
                local submission = {
                    slug        = slug,
                    name        = clean_data.name,
                    author      = clean_data.author,
                    description = clean_data.description,
                    preset_lua  = preset_lua,
                }
                Gallery.submitPreset(submission, "KOReader-Bookends", function(result, err)
                    if result then
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = T(_("Thanks! Your submission is PR #%1.\n\nThe maintainer will review it before it appears in the Gallery."),
                                     tostring(result.pr_number or "?")),
                        })
                    else
                        Notification:notify(T(_("Submission failed: %1"), tostring(err or "unknown")))
                    end
                end)
            end,
        }
        UIManager:show(confirm)
    end

    if #non_portable > 0 then
        local lines = {
            _("This preset uses specific fonts that won't exist on other devices. These overrides will be stripped from your submission so other users see their own default font."),
            "",
            _("Custom fonts in this preset:"),
        }
        for _, f in ipairs(non_portable) do
            table.insert(lines, "  • " .. f.location .. ": " .. f.font)
        end
        table.insert(lines, "")
        table.insert(lines, _("Tip: for portable presets, pick a Font-family font (Serif, Sans-serif, etc.) instead of a specific one — those adapt to each user's font settings."))
        UIManager:show(ConfirmBox:new{
            text = table.concat(lines, "\n"),
            ok_text = _("Submit anyway"),
            cancel_text = _("Cancel"),
            ok_callback = function() showConfirmAndSubmit() end,
        })
    else
        showConfirmAndSubmit()
    end
end

function PresetManagerModal._submitToGallery(self, entry)
    local ok, err = xpcall(function() submitToGalleryImpl(self, entry) end, debug.traceback)
    if not ok then
        require("logger").warn("bookends: Submit to gallery crashed:", err)
        Notification:notify(_("Submission failed — details in the KOReader log."))
    end
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

function PresetManagerModal._renderGalleryRows(self, vg, width, row_height, font_size, baseline, left_pad)
    local Gallery = require("preset_gallery")
    local online = Gallery.isOnline()

    -- Top gap so the control strip doesn't butt against the title separator
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    -- Control strip: a small card-styled Refresh button on the left, then
    -- status text (last-updated / loading / offline). Refresh is the ONLY
    -- code path that triggers a remote request — we never fetch on tab open.
    local status_text
    if self.gallery_loading then
        status_text = _("Refreshing…")
    elseif not online then
        status_text = _("Offline — connect to refresh")
    elseif self.gallery_error then
        status_text = _("Refresh failed — tap Refresh to retry")
    elseif self.gallery_index and self.gallery_index.presets then
        status_text = ""
    else
        status_text = _("Tap Refresh to load the gallery")
    end

    -- Card-style Refresh pill. Matches the preset cards (thin border, default
    -- rounded corners, white background, darker text when disabled) but scaled
    -- down to sit inline above the list.
    local btn_enabled = online and not self.gallery_loading
    local btn_pad_h = Screen:scaleBySize(12)
    local btn_pad_v = Screen:scaleBySize(6)
    local btn_label = TextWidget:new{
        text = _("Refresh"),
        face = Font:getFace("cfont", 14),
        bold = true,
        fgcolor = btn_enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    local btn_frame = FrameContainer:new{
        bordersize = Size.border.thin,
        radius = Size.radius.default,
        padding = 0,
        padding_left = btn_pad_h,
        padding_right = btn_pad_h,
        padding_top = btn_pad_v,
        padding_bottom = btn_pad_v,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        btn_label,
    }
    local btn_size = btn_frame:getSize()
    local btn_widget
    if btn_enabled then
        local ic = InputContainer:new{
            dimen = Geom:new{ w = btn_size.w, h = btn_size.h },
            btn_frame,
        }
        ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = ic.dimen } } }
        ic.onTapSelect = function() self.refreshGallery(); return true end
        btn_widget = ic
    else
        btn_widget = btn_frame
    end

    local strip_gap = Screen:scaleBySize(12)
    local strip_outer_w = width - 2 * left_pad
    local status_w = strip_outer_w - btn_size.w - strip_gap
    local status_widget = TextWidget:new{
        text = status_text,
        face = Font:getFace("cfont", 13),
        max_width = status_w,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    table.insert(vg, HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = left_pad },
        btn_widget,
        HorizontalSpan:new{ width = strip_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = status_w, h = btn_size.h },
            status_widget,
        },
    })
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    -- Empty state: pad the body so the modal's height stays consistent with
    -- a populated list. The status strip above already explains what to do.
    if not self.gallery_index or not self.gallery_index.presets then
        table.insert(vg, VerticalSpan:new{ width = row_height * 5 })
        return
    end

    -- Build local-preset-name set to mark already-installed entries with ✓
    local local_names = {}
    for _i, p in ipairs(self.bookends:readPresetFiles()) do local_names[p.name] = true end

    -- Sort recent-first by `added` (ISO date, lexicographic compare works).
    -- Name is the tiebreaker for same-day additions. Copy the list before
    -- sorting so the cached index object keeps its original order for future
    -- sort options (added/name/installed/etc.) that we might add later.
    local ROWS_PER_PAGE = 5
    local entries = {}
    for _i, e in ipairs(self.gallery_index.presets) do entries[#entries + 1] = e end
    table.sort(entries, function(a, b)
        local da, db = a.added or "", b.added or ""
        if da ~= db then return da > db end
        return (a.name or "") < (b.name or "")
    end)
    local total_pages = math.max(1, math.ceil(#entries / ROWS_PER_PAGE))
    if self.page > total_pages then self.page = total_pages end
    local start_idx = (self.page - 1) * ROWS_PER_PAGE + 1
    local end_idx = math.min(start_idx + ROWS_PER_PAGE - 1, #entries)

    for i = start_idx, end_idx do
        local entry = entries[i]
        local is_selected = self.previewing and self.previewing.kind == "gallery"
            and self.previewing.entry and self.previewing.entry.slug == entry.slug
        local captured = entry
        PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
            display = entry.name,
            description = entry.description,
            author = entry.author,
            on_preview = function() PresetManagerModal._previewGallery(self, captured) end,
            is_selected = is_selected,
            installed = local_names[entry.name] == true,
        })
    end

    -- Pagination nav (matches Local tab's visual)
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

function PresetManagerModal._previewGallery(self, entry)
    local Gallery = require("preset_gallery")
    Gallery.downloadPreset(entry.slug, entry.preset_url,
        "KOReader-Bookends",
        function(data, err)
            if not data then
                if err == "offline" then
                    Notification:notify(_("Offline — connect to preview this preset."))
                else
                    Notification:notify(T(_("Couldn't download '%1'."), entry.name))
                end
                return
            end
            local clean = self.bookends.validatePreset(data)
            if not clean then
                Notification:notify(_("This preset appears invalid; skipping."))
                require("logger").warn("bookends gallery: invalid preset", entry.slug)
                return
            end
            -- Flush pending tweaks on the currently-active preset first.
            pcall(self.bookends.autosaveActivePreset, self.bookends)
            self.bookends._previewing = true
            local ok = pcall(self.bookends.loadPreset, self.bookends, clean)
            if not ok then
                self.bookends._previewing = false
                Notification:notify(_("Could not preview preset"))
                return
            end
            self.previewing = { kind = "gallery", name = entry.name, entry = entry, data = clean }
            self.bookends:markDirty()
            self.rebuild()
        end)
end

function PresetManagerModal._promptInstallCollision(self, existing, data, entry)
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dlg
    dlg = ButtonDialogTitle:new{
        title = T(_("A preset called '%1' already exists."), entry.name),
        title_align = "center",
        buttons = {
            {{ text = _("Overwrite"), callback = function()
                UIManager:close(dlg)
                self.bookends:deletePresetFile(existing.filename)
                local filename = self.bookends:writePresetFile(entry.name, data)
                self.bookends:setActivePresetFilename(filename)
                self.bookends._previewing = false
                self.previewing = nil
                if self.modal_widget then
                    UIManager:close(self.modal_widget)
                    self.modal_widget = nil
                end
                self.bookends:markDirty()
            end }},
            {{ text = _("Rename…"), callback = function()
                UIManager:close(dlg)
                local input
                input = InputDialog:new{
                    title = _("Install as"),
                    input = entry.name .. " (2)",
                    buttons = {{
                        { text = _("Cancel"), id = "close",
                          callback = function() UIManager:close(input); self.rebuild() end },
                        { text = _("Install"), is_enter_default = true, callback = function()
                            local new_name = input:getInputText()
                            if new_name and new_name ~= "" then
                                data.name = new_name
                                local filename = self.bookends:writePresetFile(new_name, data)
                                self.bookends:setActivePresetFilename(filename)
                            end
                            self.bookends._previewing = false
                            self.previewing = nil
                            UIManager:close(input)
                            if self.modal_widget then
                                UIManager:close(self.modal_widget)
                                self.modal_widget = nil
                            end
                            self.bookends:markDirty()
                        end },
                    }},
                }
                UIManager:show(input)
                input:onShowKeyboard()
            end }},
            {{ text = _("Cancel"), callback = function()
                UIManager:close(dlg)
                self.rebuild()
            end }},
        },
    }
    UIManager:show(dlg)
end

return PresetManagerModal
