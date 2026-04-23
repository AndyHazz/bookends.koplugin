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
local PresetManager = require("preset_manager")
local PresetNaming = require("preset_naming")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local ColorRGB32_t = ffi.typeof("ColorRGB32")

-- Tiny indicator painted on a preset card when the preset uses hex colours.
-- Rather than a 🎨 emoji (U+1F3A8, not in cfont and too easily missing on
-- e-readers), paint four coloured rectangles stacked horizontally with a
-- luminance ramp dark→light. On colour screens they read as a miniature
-- palette; on greyscale the monotonic darkness gradient reads as "this
-- preset has colour" unambiguously (flat-grey stripes would just look like
-- a single rectangle).
local ColourFlag = WidgetContainer:extend{
    side   = nil,  -- single stripe side in px (height = side, total width = side * 4)
    dimen  = nil,
}

function ColourFlag:init()
    local function c(r, g, b)
        if Device.screen:isColorEnabled() then
            return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
        else
            return Blitbuffer.Color8(math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5))
        end
    end
    -- Luminance ramp ~23 → ~57 → ~136 → ~202 (Rec.601): even visual spacing
    -- on greyscale, distinct hues on colour.
    self._stripes = {
        c(0x00, 0x00, 0xCD),   -- medium blue (lum 23 — darkest)
        c(0xC0, 0x00, 0x00),   -- red (lum 57)
        c(0xFF, 0x66, 0x00),   -- orange (lum 136)
        c(0xFF, 0xD7, 0x00),   -- gold (lum 202 — lightest)
    }
end

function ColourFlag:getSize()
    return Geom:new{ w = self.side * 4, h = self.side }
end

function ColourFlag:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.side * 4, h = self.side }
    for i = 1, 4 do
        local sx = x + (i - 1) * self.side
        local c = self._stripes[i]
        if ffi.istype(ColorRGB32_t, c) then
            bb:paintRectRGB32(sx, y, self.side, self.side, c)
        else
            bb:paintRect(sx, y, self.side, self.side, c)
        end
    end
    -- Thin outline so the flag keeps a silhouette against the card background.
    bb:paintBorder(x, y, self.side * 4, self.side, 1, Blitbuffer.COLOR_DARK_GRAY)
end
local util = require("util")
local _ = require("bookends_i18n").gettext
local T = require("ffi/util").template

local Screen = Device.screen

local function buildBlankPreset(name)
    return {
        name = name,
        description = "",
        author = "",
        positions = {
            tl = { lines = {} }, tc = { lines = {} }, tr = { lines = {} },
            bl = { lines = {} }, bc = { lines = {} }, br = { lines = {} },
        },
        progress_bars = {},
    }
end

local PresetManagerModal = {}

--- Local tab page number containing the active preset, or 1 if no active
--- preset. Used both on modal open and on every switch back to the Local
--- tab so the selected row is always in view.
local function activePresetPage(bookends)
    local active_fn = bookends:getActivePresetFilename()
    if not active_fn then return 1 end
    local ROWS_PER_PAGE = 5
    for i, p in ipairs(bookends:readPresetFiles()) do
        if p.filename == active_fn then
            return math.ceil(i / ROWS_PER_PAGE)
        end
    end
    return 1
end

--- Open the manager modal. Single entry point from menu / gesture.
function PresetManagerModal.show(bookends)
    local self = {
        bookends = bookends,
        tab = "local",
        page = activePresetPage(bookends),
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
        self.approval_queue_count = nil
        self.rebuild()
        Gallery.fetchIndex("KOReader-Bookends", function(idx, err)
            if not idx then
                self.gallery_loading = false
                self.gallery_error = err
                self.rebuild()
                return
            end
            self.gallery_index = idx
            self.gallery_error = nil
            -- Secondary fetch: open PRs on the presets repo. Non-fatal —
            -- failure just means we don't display the count.
            Gallery.fetchApprovalQueueCount("KOReader-Bookends", function(count)
                self.gallery_loading = false
                if count then self.approval_queue_count = count end
                self.rebuild()
            end)
        end)
    end
    self.setTab = function(tab)
        if self.tab ~= tab then
            self.tab = tab
            -- When returning to My presets, jump to the page with the active
            -- preset (same reason as on initial show). Gallery has no active
            -- concept, so it resets to page 1.
            if tab == "local" then
                self.page = activePresetPage(self.bookends)
            else
                self.page = 1
            end
            self.rebuild()
        end
    end
    self.setPage = function(p) self.page = p; self.rebuild() end
    self.previewLocal = function(p) PresetManagerModal._previewLocal(self, p) end
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

function PresetManagerModal._applyCurrent(self)
    if not self.previewing then
        -- Nothing previewed — Apply is a no-op, just close the modal.
        self.close()
        return
    end
    if self.previewing.kind == "local" then
        self.bookends:setActivePresetFilename(self.previewing.filename)
    elseif self.previewing.kind == "gallery" then
        -- Install: save to bookends_presets/ and make active.
        local entry = self.previewing.entry
        local data = self.previewing.data
        -- Normalize to alphanumeric-lowercase before comparing. Catches
        -- preset files whose `name` field is missing (fallback derives
        -- from filename, which can differ in punctuation from the gallery
        -- entry's name — e.g. 'kobo-like' vs 'Kobo Like').
        local function normalize(s)
            return s and tostring(s):lower():gsub("[^%w]", "") or ""
        end
        local entry_norm = normalize(entry.name)
        local existing
        for _, p in ipairs(self.bookends:readPresetFiles()) do
            if normalize(p.name) == entry_norm
               or normalize(p.filename:gsub("%.lua$", "")) == entry_norm then
                existing = p
                break
            end
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
        text = _("Preset library"),
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
    local local_seg   = segmentHalf(_("My presets"), self.tab == "local",   function() self.setTab("local") end)
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
    local btn_w = math.floor((width - 2 * Size.line.thin) / 3)

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
    local btn_edit_ic = make_footer_btn(_("Manage…"), edit_enabled, function()
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
    -- Apply is always tappable. If there's nothing previewed it just closes
    -- the modal (same end state as reopening it). This is less surprising
    -- than toggling the button's enablement after a tap on the already-
    -- active preset.
    local btn_apply_ic = make_footer_btn(apply_text, true,
        function() self.applyCurrent() end, true)

    -- Thin dark-grey separator above the footer, matching the font picker's
    -- treatment. Lighter than the title bar's thick black line so the title
    -- remains the strongest visual divide.
    table.insert(vg, LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{ w = width, h = Size.line.thin },
    })
    -- Vertical button dividers: lighter and inset top/bottom so they don't
    -- run the full button height (also matching the font picker's ButtonTable).
    local vdiv_inset = Screen:scaleBySize(10)
    local vdiv = function() return CenterContainer:new{
        dimen = Geom:new{ w = Size.line.thin, h = row_height },
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{ w = Size.line.thin, h = row_height - 2 * vdiv_inset },
        },
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
    -- Outer shell publishes the visible frame's rect to external observers
    -- (Bookends' FlippingHaloOverlay suppression, the dogear userpatch) via
    -- its own dimen, while wc keeps dimen = Screen:getSize() — that field
    -- is what CenterContainer:paintTo uses to compute its centring offset,
    -- so overwriting it pins the modal to (0, 0) on the second repaint.
    -- Matches ButtonDialog, which hangs `self.dimen = movable.dimen` on its
    -- outer FocusManager, not on the inner CenterContainer.
    local shell = WidgetContainer:new{ dimen = Screen:getSize(), wc }
    function shell:paintTo(bb, x, y)
        wc:paintTo(bb, x, y)
        self.dimen = frame.dimen
    end
    self.modal_widget = shell
    UIManager:show(shell)
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
    if self.previewing and self.previewing.kind == "local" then
        selected_key = self.previewing.filename
    else
        selected_key = active_fn
    end

    -- Non-interactive hint row on every page. Height mirrors the Gallery
    -- Refresh button strip so tab-switching keeps the modal height stable.
    local hint_pad_v = Screen:scaleBySize(6)
    local hint_widget = TextWidget:new{
        text = _("Star = include in preset cycle gesture"),
        face = Font:getFace("cfont", 13),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local hint_h = hint_widget:getSize().h + 2 * hint_pad_v + 2 * Size.border.thin
    table.insert(vg, HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = left_pad },
        LeftContainer:new{
            dimen = Geom:new{ w = width - 2 * left_pad, h = hint_h },
            hint_widget,
        },
    })
    -- Match the inter-card gap so the first real preset sits at the same
    -- distance below as subsequent rows sit from each other.
    table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(8) })

    -- Real presets, paginated. Page 1 fits the same 5 cards as the Gallery
    -- tab — the compact (No overlay) strip above is small enough that we
    -- don't need to displace a card.
    local presets = self.bookends:readPresetFiles()
    local ROWS_PER_PAGE = 5
    local TILE_SLOT = 1  -- the synthetic "+ New preset" tile after the last card
    local total_items = #presets + TILE_SLOT
    local total_pages = math.max(1, math.ceil(total_items / ROWS_PER_PAGE))
    if self.page > total_pages then self.page = total_pages end
    local start_idx = (self.page - 1) * ROWS_PER_PAGE + 1
    local end_idx = math.min(start_idx + ROWS_PER_PAGE - 1, total_items)
    for i = start_idx, end_idx do
        if i <= #presets then
            local p = presets[i]
            local has_colour = PresetManager.hasColour(p.preset) or false
            PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
                display = p.name,
                description = p.preset.description,
                author = p.preset.author,
                star_key = p.filename,
                has_colour = has_colour,
                on_preview = function() self.previewLocal(p) end,
                on_hold = function() PresetManagerModal._openOverflow(self, p) end,
                is_selected = (selected_key == p.filename),
            })
        else
            -- Synthetic tile: final slot on the last page.
            PresetManagerModal._addRow(self, vg, width, row_height, font_size, baseline, left_pad, {
                display = _("+ New blank preset"),
                is_virtual = true,
                on_preview = function() PresetManagerModal._createBlankPreset(self) end,
            })
        end
    end

    -- Pad out short pages so the modal height stays stable regardless of
    -- how many items fit the page. Each pad slot equals one card plus the
    -- 8px gap _addRow adds after every rendered card.
    local rendered = end_idx - start_idx + 1
    local card_slot_h = Screen:scaleBySize(64) + Screen:scaleBySize(8)
    for _ = rendered + 1, ROWS_PER_PAGE do
        table.insert(vg, VerticalSpan:new{ width = card_slot_h })
    end

    -- Always reserve the pagination area's full height (span + hairline +
    -- span + nav) even when we don't render it, so Local ↔ Gallery and
    -- empty ↔ loaded transitions don't resize the modal.
    PresetManagerModal._renderPagination(self, vg, width, row_height, total_pages)
end

--- Render the pagination strip OR reserve its equivalent height. Shared
--- between Local and Gallery tabs so single-page and multi-page states
--- produce identical modal heights.
function PresetManagerModal._renderPagination(self, vg, width, row_height, total_pages)
    local pagination_area_h = 2 * Size.span.vertical_default + Size.line.thin + row_height
    if total_pages <= 1 then
        table.insert(vg, VerticalSpan:new{ width = pagination_area_h })
        return
    end
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
    table.insert(vg, VerticalSpan:new{ width = Size.span.vertical_default })
    table.insert(vg, CenterContainer:new{
        dimen = Geom:new{ w = width, h = Size.line.thin },
        LineWidget:new{
            background = Blitbuffer.COLOR_DARK_GRAY,
            dimen = Geom:new{ w = width - 2 * Size.padding.default, h = Size.line.thin },
        },
    })
    table.insert(vg, VerticalSpan:new{ width = Size.span.vertical_default })
    table.insert(vg, CenterContainer:new{
        dimen = Geom:new{ w = width, h = row_height },
        page_nav,
    })
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
        bold = opts.is_selected or opts.is_virtual or false,
        forced_height = title_h,
        forced_baseline = title_bl,
        max_width = content_w,
        fgcolor = opts.is_virtual and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
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

    -- ColourFlag is positioned in the top-right corner of the card itself
    -- (see the OverlapGroup below the FrameContainer construction), not
    -- inline in the title_line, so it reads as a card-level indicator and
    -- sits flush inside the rounded border rather than bumping against
    -- the author/title text.

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

    local content_group = VerticalGroup:new{
        align = opts.is_virtual and "center" or "left",
        title_line,
    }
    if description_widget then
        table.insert(content_group, description_widget)
    end

    local content_row
    if opts.is_virtual then
        content_row = CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = card_height - 2 * Size.border.thin },
            content_group,
        }
    else
        content_row = LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = card_height - 2 * Size.border.thin },
            content_group,
        }
    end

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

    -- Overlay the ColourFlag in the top-right corner of the card, flush
    -- inside the rounded border. OverlapGroup supports an overlap_offset
    -- field on each child that positions it at {x, y} within the group —
    -- we compute offsets that put the flag `inset` pixels in from the
    -- top and right edges so the rounded corner isn't visually clipped.
    local card_w, card_h = card_frame:getSize().w, card_frame:getSize().h
    local card_stack
    if opts.has_colour then
        local flag_inset = Screen:scaleBySize(6)
        local flag_side = Screen:scaleBySize(8)
        local flag_w = flag_side * 4
        local flag = ColourFlag:new{ side = flag_side }
        flag.overlap_offset = { card_w - flag_w - flag_inset, flag_inset }
        card_stack = OverlapGroup:new{
            dimen = Geom:new{ w = card_w, h = card_h },
            allow_mirroring = false,
            card_frame,
            flag,
        }
    else
        card_stack = card_frame
    end

    -- Tap/hold on the card previews / opens overflow.
    local card = InputContainer:new{
        dimen = Geom:new{ w = card_w, h = card_h },
        card_stack,
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

--- Open the reader menu and drop the user straight into the Bookends
--- submenu, so the full tab bar is visible but they land on
--- "Preset (Untitled)" with empty position items ready to populate.
--- Done by opening the reader menu (which builds its own TouchMenu),
--- finding the "bookends" item inside its tab_item_table, and firing
--- onMenuSelect on it — same as a user tap.
local function openBookendsMenu(bookends)
    local reader_menu = bookends.ui and bookends.ui.menu
    if not reader_menu then return end
    reader_menu:onShowMenu()
    local container = reader_menu.menu_container
    local main_menu = container and container[1]
    if not main_menu or not main_menu.tab_item_table then return end
    for tab_idx, tab in ipairs(main_menu.tab_item_table) do
        for _, item in ipairs(tab) do
            if item.id == "bookends" then
                -- Mirror the user-tap flow: bar.switchToTab invokes the icon
                -- widget's callback, which updates the bar's selected-icon
                -- visual AND calls menu:switchMenuTab. Calling switchMenuTab
                -- directly only updates menu state, leaving the bar showing
                -- whichever tab the user last had open.
                if main_menu.cur_tab ~= tab_idx then
                    main_menu.bar:switchToTab(tab_idx)
                end
                main_menu:onMenuSelect(item)
                return
            end
        end
    end
end

function PresetManagerModal._createBlankPreset(self)
    local presets = self.bookends:readPresetFiles()
    local name = PresetNaming.nextUntitledName(presets, _("Untitled"))
    local preset = buildBlankPreset(name)
    local filename = self.bookends:writePresetFile(name, preset)
    -- applyPresetFile loads the blank into memory before setting it active,
    -- so the debounced autosave can't clobber the on-disk file with the
    -- previously-active preset's data.
    self.bookends:applyPresetFile(filename)
    -- Close the modal and drop the user straight into the Bookends menu, so
    -- they see "Preset (Untitled)" + the empty position items ready to edit.
    -- nextTick lets the modal's close flush before the TouchMenu shows.
    if self.modal_widget then
        UIManager:close(self.modal_widget)
        self.modal_widget = nil
    end
    local bookends = self.bookends
    UIManager:nextTick(function() openBookendsMenu(bookends) end)
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
                -- Client-side collision check: if we've refreshed the gallery,
                -- catch duplicates before the server round-trip so the user
                -- gets a clear, specific message.
                if self.gallery_index and self.gallery_index.presets then
                    for _i, p in ipairs(self.gallery_index.presets) do
                        if p.slug == slug then
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = T(_("A preset called '%1' is already in the gallery. Rename your preset (Manage… → Rename…) before submitting, so it doesn't collide with the existing entry."),
                                         clean_data.name),
                            })
                            return
                        end
                    end
                end
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
                        -- Surface errors as an InfoMessage (stays until dismissed)
                        -- rather than a Notification (fades away). Map the two
                        -- known collision errors to clearer, actionable copy.
                        local msg
                        if err == "slug already exists in the gallery" then
                            msg = T(_("A preset called '%1' is already in the gallery. Rename your preset (Manage… → Rename…) before submitting."),
                                    clean_data.name)
                        elseif err == "a submission for this slug is already open" then
                            msg = T(_("A submission for '%1' is already awaiting review. Wait for that one to be reviewed, or rename your preset to submit under a different name."),
                                    clean_data.name)
                        else
                            msg = T(_("Submission failed: %1"), tostring(err or "unknown"))
                        end
                        UIManager:show(require("ui/widget/infomessage"):new{ text = msg })
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
            elseif self.previewing then
                -- We deleted a preset we were previewing, but it wasn't the
                -- active preset. Positions in RAM still hold the preview's
                -- content; without re-applying the active preset, the next
                -- autosave would dump that preview state into the active
                -- preset's file (previously observed: 'Wow' content ending
                -- up in Basic bookends after the previewed Wow was deleted).
                local active = self.bookends:getActivePresetFilename()
                if active then
                    pcall(self.bookends.applyPresetFile, self.bookends, active)
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
    elseif self.approval_queue_count and self.approval_queue_count > 0 then
        -- Approval queue = open PRs on the presets repo. Shown only when
        -- a refresh has successfully populated both the index and the count.
        if self.approval_queue_count == 1 then
            status_text = _("1 preset in the approval queue")
        else
            status_text = T(_("%1 presets in the approval queue"), self.approval_queue_count)
        end
    else
        -- When loaded with no pending PRs, and when idle-empty (the help
        -- panel already explains what to do), leave the status blank.
        status_text = ""
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

    -- Empty state: render an explanatory help panel in the space a populated
    -- list would occupy. Total height matches the populated layout (5 card
    -- slots + pagination area) so the modal doesn't resize on Refresh.
    if not self.gallery_index or not self.gallery_index.presets then
        local card_slot_h = Screen:scaleBySize(64) + Screen:scaleBySize(8)
        local pagination_area_h = 2 * Size.span.vertical_default + Size.line.thin + row_height
        local help_h = card_slot_h * 5
        -- Wider side margins than the card layout so the help panel reads as
        -- content, not a list. Body text stays pure black on e-ink — dark-grey
        -- is reserved for labels/chrome, not for reading content.
        local text_width = width - 8 * left_pad
        local title_widget = TextWidget:new{
            text = _("Discover more presets"),
            face = Font:getFace("cfont", 20),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local intro = TextBoxWidget:new{
            text = _("Browse presets others have shared, preview them on your own status bar, and install the ones you like. Once installed, you can edit each preset freely on the My presets tab."),
            face = Font:getFace("cfont", 16),
            width = text_width,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local share = TextBoxWidget:new{
            text = _("Made something worth sharing? Submit it with the Manage button while viewing one of your own presets."),
            face = Font:getFace("cfont", 16),
            width = text_width,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local cta = TextWidget:new{
            text = _("Tap Refresh above to load the gallery."),
            face = Font:getFace("cfont", 16),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local help_group = VerticalGroup:new{
            align = "center",
            title_widget,
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
            intro,
            VerticalSpan:new{ width = Screen:scaleBySize(14) },
            share,
            VerticalSpan:new{ width = Screen:scaleBySize(22) },
            cta,
        }
        table.insert(vg, CenterContainer:new{
            dimen = Geom:new{ w = width, h = help_h },
            help_group,
        })
        table.insert(vg, VerticalSpan:new{ width = pagination_area_h })
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
            has_colour = entry.has_colour or false,
            on_preview = function() PresetManagerModal._previewGallery(self, captured) end,
            is_selected = is_selected,
            installed = local_names[entry.name] == true,
        })
    end

    -- Pad out short pages so the Gallery tab's body height matches the Local
    -- tab's (which also pads). Each slot equals one card plus the 8px gap.
    local rendered = end_idx - start_idx + 1
    local card_slot_h = Screen:scaleBySize(64) + Screen:scaleBySize(8)
    for _ = rendered + 1, ROWS_PER_PAGE do
        table.insert(vg, VerticalSpan:new{ width = card_slot_h })
    end

    PresetManagerModal._renderPagination(self, vg, width, row_height, total_pages)
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
        title = T(_("'%1' already exists in your library.\n\nReplacing it will overwrite your local copy with the current gallery version. Any local edits will be lost.\n\nInstall under a new name to keep both."), entry.name),
        title_align = "left",
        buttons = {
            {{ text = _("Cancel"), callback = function()
                UIManager:close(dlg)
            end }},
            {{ text = _("Replace"), callback = function()
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
            {{ text = _("Install as new name…"), callback = function()
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
