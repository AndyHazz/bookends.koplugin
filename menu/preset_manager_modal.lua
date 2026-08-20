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

-- Dashed-border overlay for the synthetic "+ New blank preset" tile so it
-- reads as a placeholder/affordance rather than another solid card. Drawn
-- on top of the (border-less) card frame inside an OverlapGroup. Paints
-- short rectangles around the perimeter at a fixed dash + gap stride.
local DashedBorder = WidgetContainer:extend{
    w_actual  = 0,
    h_actual  = 0,
    color     = nil,
    dash_len  = nil,
    gap_len   = nil,
}

function DashedBorder:getSize()
    return Geom:new{ w = self.w_actual, h = self.h_actual }
end

function DashedBorder:paintTo(bb, x, y)
    local color = self.color or Blitbuffer.COLOR_DARK_GRAY
    local dash  = self.dash_len or Device.screen:scaleBySize(6)
    local gap   = self.gap_len  or Device.screen:scaleBySize(4)
    local stride = dash + gap
    local w, h = self.w_actual, self.h_actual
    local thickness = Device.screen:scaleBySize(1)
    local cx = x
    while cx < x + w do
        local seg = math.min(dash, x + w - cx)
        bb:paintRect(cx, y, seg, thickness, color)
        bb:paintRect(cx, y + h - thickness, seg, thickness, color)
        cx = cx + stride
    end
    local cy = y
    while cy < y + h do
        local seg = math.min(dash, y + h - cy)
        bb:paintRect(x, cy, thickness, seg, color)
        bb:paintRect(x + w - thickness, cy, thickness, seg, color)
        cy = cy + stride
    end
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
        -- Empty-but-present defaults table is the trigger for loadPreset's
        -- margin-reset path: without a `defaults` key the reset block is
        -- skipped and self.defaults retains whatever the previous preset
        -- left behind (e.g. inherited margin=0 from a customised preset).
        defaults = {},
        positions = {
            tl = { lines = {} }, tc = { lines = {} }, tr = { lines = {} },
            bl = { lines = {} }, bc = { lines = {} }, br = { lines = {} },
        },
        progress_bars = {},
    }
end

local PresetManagerModal = {}

--- Sort + filter the local preset list by the given mode. "name" is the
--- default alphabetical order already produced by readPresetFiles. "latest"
--- re-sorts by file mtime desc. "starred" filters to presets in the cycle
--- list (still A-Z within that subset).
local function sortedLocalPresets(bookends, mode)
    local presets = bookends:readPresetFiles()
    if mode == "starred" then
        local cycle = bookends.settings:readSetting("preset_cycle") or {}
        local in_cycle = {}
        for _i, fn in ipairs(cycle) do in_cycle[fn] = true end
        local filtered = {}
        for _i, p in ipairs(presets) do
            if in_cycle[p.filename] then filtered[#filtered + 1] = p end
        end
        return filtered
    elseif mode == "latest" then
        local lfs = require("libs/libkoreader-lfs")
        local dir = bookends:presetDir()
        local mtimes = {}
        for _i, p in ipairs(presets) do
            mtimes[p.filename] = lfs.attributes(dir .. "/" .. p.filename, "modification") or 0
        end
        table.sort(presets, function(a, b)
            local ta, tb = mtimes[a.filename], mtimes[b.filename]
            if ta ~= tb then return ta > tb end
            return a.name < b.name
        end)
    end
    return presets
end

--- Build the format-rule picker's item list: a synthetic "Hidden" option
--- followed by the given local preset entries (order preserved). Pure - the
--- input array is not mutated. See the format-rule preset picker spec (#87).
function PresetManagerModal.formatRulePickerItems(entries)
    local out = { { is_hidden_option = true } }
    for _i = 1, #entries do
        out[#out + 1] = entries[_i]
    end
    return out
end

--- Local tab page number containing the active preset in the given sort
--- order, or 1 if no active preset or the active preset is filtered out
--- (e.g. unstarred while Starred filter is on). Used on modal open and
--- whenever the sort mode changes so the selected row stays in view.
local function activePresetPage(bookends, mode)
    local active_fn = bookends:getActivePresetFilename()
    if not active_fn then return 1 end
    local ROWS_PER_PAGE = 5
    for i, p in ipairs(sortedLocalPresets(bookends, mode or "name")) do
        if p.filename == active_fn then
            return math.ceil(i / ROWS_PER_PAGE)
        end
    end
    return 1
end

local GALLERY_STALE_SECONDS = 5 * 60

--- True when the gallery data is absent, errored, or older than the freshness
--- window. Extracted from the show() closure so it can be tested in isolation.
local function galleryIsStale(self)
    if not self.gallery_index then return true end
    if self.gallery_error then return true end
    if not self.gallery_last_refresh_time then return true end
    if self.gallery_sort == "popular" and type(self.gallery_counts) ~= "table" then
        return true
    end
    return (os.time() - self.gallery_last_refresh_time) >= GALLERY_STALE_SECONDS
end

--- Cache-invalidation key: any state change that affects the item list changes this.
local function _cacheKey(self)
    return table.concat({
        self.tab or "",
        self.my_sort or "",
        self.gallery_sort or "",
        self.current_search or "",
        tostring(self.gallery_loading),
        tostring(self.gallery_error),
        self.gallery_index and "idx" or "no",
        self.gallery_counts and "ctn" or "noctn",
    }, "|")
end

--- Sorted item list for whichever tab is active. Returns {} when the gallery
--- is not yet loaded so callers get a consistent empty list without branching.
--- Applies the current_search filter when set. Annotates gallery entries with
--- _installed so renderPresetCard doesn't have to re-read preset files per card.
--- Memoized by _cacheKey so multiple calls per refresh cycle don't repeat the
--- sort + file-read work (item_count and item_at each call this).
local function currentItemList(self)
    local key = _cacheKey(self)
    if self._items_cache_key == key and self._items_cache then
        return self._items_cache
    end
    local LibraryModal = require("menu.library_modal")
    local entries
    if self.tab == "local" then
        entries = sortedLocalPresets(self.bookends, self.my_sort)
    else
        if not self.gallery_index or not self.gallery_index.presets then
            self._items_cache_key = key
            self._items_cache = {}
            return self._items_cache
        end
        if self.gallery_loading or self.gallery_error then
            self._items_cache_key = key
            self._items_cache = {}
            return self._items_cache
        end
        entries = {}
        for _i, e in ipairs(self.gallery_index.presets) do entries[#entries + 1] = e end
        if self.gallery_sort == "popular" and type(self.gallery_counts) == "table" then
            local counts = self.gallery_counts
            table.sort(entries, function(a, b)
                local ca = counts[a.slug or ""] or 0
                local cb = counts[b.slug or ""] or 0
                if ca ~= cb then return ca > cb end
                local da, db = a.added or "", b.added or ""
                if da ~= db then return da > db end
                return (a.name or "") < (b.name or "")
            end)
        else
            table.sort(entries, function(a, b)
                local da, db = a.added or "", b.added or ""
                if da ~= db then return da > db end
                return (a.name or "") < (b.name or "")
            end)
        end
        -- Annotate installed-state once per call so per-card render doesn't
        -- re-read the preset directory on every paint.
        local local_names = {}
        for _i, p in ipairs(self.bookends:readPresetFiles()) do local_names[p.name] = true end
        for _i, e in ipairs(entries) do e._installed = local_names[e.name] == true end
    end
    if self.current_search and #self.current_search >= 2 then
        local filtered = {}
        for _i, item in ipairs(entries) do
            -- Search across name AND author. Local presets nest author
            -- inside item.preset; gallery entries have it flat. Build a
            -- single haystack so multi-term AND match (e.g. "stock kobo"
            -- or "minimal mido") works across both fields.
            local author = (item.preset and item.preset.author) or item.author or ""
            local haystack = (item.name or "") .. " " .. author
            if LibraryModal._matchesQuery(haystack, self.current_search) then
                filtered[#filtered + 1] = item
            end
        end
        entries = filtered
    end
    -- Append a synthetic "+ New blank preset" tile at the end of the local
    -- list as a discoverable affordance for creating a fresh preset. Skip
    -- it when search is active so the tile doesn't clutter filtered results.
    if self.tab == "local" and not self.current_search then
        entries[#entries + 1] = { is_virtual = true, name = _("+ New blank preset") }
    end
    self._items_cache = entries
    self._items_cache_key = key
    return self._items_cache
end

--- Empty-state help panel for the Gallery tab. Rendered when gallery_index is
--- nil or has no presets. Sized to exactly area_height so the modal chrome
--- stays the same height as when cards are present.
local function galleryHelpPanel(self, width, area_height, left_pad)
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
        text = _("Tap Latest or Popular above to load the gallery."),
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
    -- CenterContainer sizes itself to exactly area_height — no trailing span needed.
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = area_height },
        help_group,
    }
end

--- Render a single preset card widget to return to LibraryModal as a row.
--- Delegates to _addRow by wrapping a temporary VerticalGroup and extracting
--- the first (and only) logical card, since _addRow also inserts a gap span.
--- This keeps Phase 1 behavioural parity without duplicating card layout code.
local function renderPresetCard(self, item, slot_dimen)
    local card_height = Screen:scaleBySize(64)
    local row_height = card_height
    local font_size = 18
    local baseline = math.floor(row_height * 0.65)
    local left_pad = Size.padding.large

    -- Tap on a card should dismiss the on-screen keyboard if it's up,
    -- otherwise the user is trapped behind it after previewing a preset
    -- (the modal's pagination/footer sit beneath the keyboard).
    local function withKeyboardDismiss(action)
        return function()
            local lm = self.modal_widget
            if lm and lm._dismissKeyboard then lm:_dismissKeyboard() end
            action()
        end
    end

    local is_local = self.tab == "local"
    local vg_tmp = VerticalGroup:new{ align = "left" }

    if is_local then
        local opts
        if item.is_virtual then
            -- Synthetic "+ New blank preset" tile: bypass _previewLocal
            -- (no preset to load) and route the tap to _createBlankPreset.
            -- _addRow's is_virtual branch handles the centered-italic
            -- placeholder styling.
            opts = {
                display    = item.name,
                is_virtual = true,
                on_preview = withKeyboardDismiss(function() PresetManagerModal._createBlankPreset(self) end),
            }
        else
            local selected_key
            if self.previewing and self.previewing.kind == "local" then
                selected_key = self.previewing.filename
            else
                selected_key = self.bookends:getActivePresetFilename()
            end
            -- item.has_colour is memoised on the cached entry by readPresetFiles;
            -- fall back to a fresh walk for any caller that hand-builds an item.
            local has_colour = item.has_colour
            if has_colour == nil then
                has_colour = PresetManager.hasColour(item.preset) or false
            end
            opts = {
                display      = item.name,
                description  = item.preset and item.preset.description,
                author       = item.preset and item.preset.author,
                star_key     = item.filename,
                has_colour   = has_colour,
                on_preview   = withKeyboardDismiss(function() PresetManagerModal._previewLocal(self, item) end),
                on_hold      = withKeyboardDismiss(function() PresetManagerModal._openOverflow(self, item) end),
                is_selected  = (selected_key == item.filename),
            }
        end
        PresetManagerModal._addRow(self, vg_tmp, slot_dimen.w, row_height, font_size, baseline, left_pad, opts)
    else
        -- Gallery tab highlight is mutually exclusive (matches the local-tab
        -- pattern at line 386-406): when previewing a gallery item, only
        -- that card lights up; with no active preview, the gallery entry
        -- whose name matches the currently-applied local preset highlights
        -- instead. Without this exclusivity the active-name match and the
        -- preview-slug match could fire on different cards in the same
        -- render and the user would see two cards selected with no way to
        -- tell which is which.
        local is_selected
        if self.previewing and self.previewing.kind == "gallery" then
            is_selected = self.previewing.entry ~= nil
                and self.previewing.entry.slug == item.slug
        else
            -- Resolve once per render cycle; reuse across cards via self cache.
            if self._active_preset_name == nil then
                local active_fn = self.bookends:getActivePresetFilename()
                if active_fn then
                    local presets = self.bookends:readPresetFiles()
                    for _i, p in ipairs(presets) do
                        if p.filename == active_fn then
                            -- false sentinel prevents repeated lookups when no match.
                            self._active_preset_name = p.name or false
                            break
                        end
                    end
                end
                if self._active_preset_name == nil then self._active_preset_name = false end
            end
            is_selected = self._active_preset_name ~= false
                and self._active_preset_name == item.name
        end
        local captured = item
        PresetManagerModal._addRow(self, vg_tmp, slot_dimen.w, row_height, font_size, baseline, left_pad, {
            display     = item.name,
            description = item.description,
            author      = item.author,
            has_colour  = item.has_colour or false,
            on_preview  = withKeyboardDismiss(function() PresetManagerModal._previewGallery(self, captured) end),
            is_selected = is_selected,
            installed   = item._installed == true,
        })
    end

    -- _addRow inserts card then a gap VerticalSpan into vg_tmp; return the
    -- card (index 1) wrapped in a VerticalGroup so LibraryModal gets a widget.
    -- The gap is intentionally dropped — LibraryModal manages inter-row spacing.
    local card_widget = vg_tmp[1]
    return card_widget
end

--- Render one card for the format-rule picker. Local presets get a radio that
--- selects them as the rule target; the synthetic Hidden row gets its own radio
--- and virtual-tile styling. Tapping a card body previews (preset or hidden);
--- tapping the radio chooses. See the format-rule preset picker spec (#87).
local function renderFormatRulePickerCard(self, item, slot_dimen)
    local card_height = Screen:scaleBySize(64)
    local row_height = card_height
    local font_size = 18
    local baseline = math.floor(row_height * 0.65)
    local left_pad = Size.padding.large
    local rules = self.bookends.settings:readSetting("format_preset_rules") or {}
    local vg_tmp = VerticalGroup:new{ align = "left" }

    if item.is_hidden_option then
        PresetManagerModal._addRow(self, vg_tmp, slot_dimen.w, row_height, font_size, baseline, left_pad, {
            display       = _("Hidden (no overlay)"),
            is_virtual    = true,
            radio_key     = "HIDDEN",
            radio_selected = (rules[self.ext] == "HIDDEN"),
            on_preview    = function() self.previewHidden() end,
        })
    else
        local has_colour = item.has_colour
        if has_colour == nil then
            has_colour = PresetManager.hasColour(item.preset) or false
        end
        PresetManagerModal._addRow(self, vg_tmp, slot_dimen.w, row_height, font_size, baseline, left_pad, {
            display        = item.name,
            description    = item.preset and item.preset.description,
            author         = item.preset and item.preset.author,
            has_colour     = has_colour,
            radio_key      = item.filename,
            radio_selected = (rules[self.ext] == item.filename),
            on_preview     = function() self.previewLocal(item) end,
        })
    end

    return vg_tmp[1]
end

-- Format-rule picker item list: local presets (optionally search-filtered),
-- with the synthetic Hidden row prepended. Cached per render cycle; the picker
-- busts the cache in its rebuild() closure (self._items_cache = nil).
local function pickerItems(self)
    if self._items_cache then return self._items_cache end
    local entries = sortedLocalPresets(self.bookends, "latest")
    if self.current_search and #self.current_search >= 2 then
        local LibraryModal = require("menu.library_modal")
        local filtered = {}
        for _i = 1, #entries do
            local item = entries[_i]
            local author = (item.preset and item.preset.author) or ""
            local haystack = (item.name or "") .. " " .. author
            if LibraryModal._matchesQuery(haystack, self.current_search) then
                filtered[#filtered + 1] = item
            end
        end
        entries = filtered
    end
    self._items_cache = PresetManagerModal.formatRulePickerItems(entries)
    return self._items_cache
end

--- LibraryModal config for the format-rule picker. Local presets only, Hidden
--- row prepended, radio-select, live preview, Done footer.
local function buildFormatRulePickerConfig(self)
    return {
        title = _("Preset for this file type"),
        search_placeholder = function() return _("Search my presets by name or author…") end,
        on_search_submit = function(query)
            self.current_search = query
            self.page = 1
            self.rebuild()
        end,
        rows_per_page = function()
            return Screen:getWidth() > Screen:getHeight() and 4 or 5
        end,
        item_count = function() return #pickerItems(self) end,
        item_at = function(idx) return pickerItems(self)[idx] end,
        row_renderer = function(item, dimen)
            return renderFormatRulePickerCard(self, item, dimen)
        end,
        footer_actions = {
            {
                key = "done",
                label = _("Done"),
                primary = true,
                on_tap = function() self.close(true) end,
            },
        },
    }
end

--- Build the LibraryModal config table for the preset manager.
--- Called once from show(); self must already have all state fields set.
local function buildPresetLibraryConfig(self)
    return {
        title = _("Preset library"),
        tabs = {
            { key = "local",   label = _("My presets") },
            { key = "gallery", label = _("Gallery") },
        },
        on_tab_change = function(tab_key)
            -- LibraryModal calls refresh() after on_tab_change; setTab also
            -- calls rebuild(). Accept the double-refresh for Phase 1 simplicity.
            self.setTab(tab_key)
        end,
        chip_strip = function(active_tab)
            if active_tab == "local" then
                return {
                    { key = "latest",  label = _("Latest"),  is_active = self.my_sort == "latest" },
                    { key = "starred", label = _("Starred"), is_active = self.my_sort == "starred" },
                }
            else
                -- Cold gallery state (never engaged) shows neither chip active
                -- so the user's first tap carries an unambiguous "load this"
                -- intent. is_active must be an explicit true/false (not nil)
                -- so LibraryModal's chip-strip honors the config flag rather
                -- than falling back to widget-tracked active_chip.
                local engaged = (self.gallery_loading or self.gallery_index ~= nil
                    or self.gallery_error ~= nil) and true or false
                return {
                    { key = "latest",  label = _("Latest"),
                      is_active = engaged and self.gallery_sort == "latest" or false },
                    { key = "popular", label = _("Popular"),
                      is_active = engaged and self.gallery_sort == "popular" or false },
                }
            end
        end,
        -- Inline status text rendered to the right of the chips, in the
        -- slot the legacy chrome used for the approval-queue count.
        -- Currently only used for transient gallery-load feedback so the
        -- message reads as part of bookends' modal rather than a generic
        -- KOReader popup floating over it.
        chip_strip_status = function(active_tab)
            if active_tab == "gallery" and self.gallery_loading then
                return _("Loading gallery…")
            end
            return nil
        end,
        on_chip_tap = function(chip_key)
            if self.tab == "local" then
                self.setMySort(chip_key)
            else
                self.setGallerySort(chip_key)
            end
        end,
        search_placeholder = function(active_tab)
            if active_tab == "local" then
                return _("Search my presets by name or author…")
            else
                return _("Search gallery presets by name or author…")
            end
        end,
        on_search_submit = function(query)
            self.current_search = query
            self.page = 1
            -- Submitting a search on the cold gallery tab kicks off the
            -- gallery fetch. Without this, the search would just hit an
            -- empty list (currentItemList returns {} until gallery_index
            -- is populated). The fetch's completion callback re-renders,
            -- at which point the search filter applies to the loaded data.
            if self.tab == "gallery" and not self.gallery_loading
                    and galleryIsStale(self) then
                self.refreshGallery()
            else
                self.rebuild()
            end
        end,
        rows_per_page = function()
            return Screen:getWidth() > Screen:getHeight() and 4 or 5
        end,
        item_count = function() return #currentItemList(self) end,
        item_at = function(idx) return currentItemList(self)[idx] end,
        row_renderer = function(item, dimen)
            return renderPresetCard(self, item, dimen)
        end,
        empty_state = function(w, h)
            if self.tab == "gallery" and not self.gallery_index then
                -- Pass a reasonable left_pad so the help panel's text margins
                -- look correct; galleryHelpPanel uses it to inset text_width.
                return galleryHelpPanel(self, w, h, Size.padding.large)
            end
            return nil
        end,
        footer_actions = {
            {
                key   = "close",
                label = _("Close"),
                on_tap = function() self.close(true) end,
            },
            {
                key   = "manage",
                label = _("Manage…"),
                on_tap = function()
                    if not self.previewing then return end
                    -- Convert self.previewing to the preset_entry shape _openOverflow expects.
                    if self.previewing.kind == "local" then
                        local presets = self.bookends:readPresetFiles()
                        for _i, p in ipairs(presets) do
                            if p.filename == self.previewing.filename then
                                PresetManagerModal._openOverflow(self, p)
                                return
                            end
                        end
                    end
                end,
                enabled_when = function() return self.previewing ~= nil and self.previewing.kind == "local" end,
            },
            {
                key      = "install",
                label    = _("Install"),
                label_func = function()
                    return (self.previewing and self.previewing.kind == "local")
                        and _("Apply") or _("Install")
                end,
                on_tap   = function() self.applyCurrent() end,
                primary  = true,
                enabled_when = function() return self.previewing ~= nil end,
            },
        },
    }
end

--- Open the manager modal. Single entry point from menu / gesture.
function PresetManagerModal.show(bookends)
    local self = {
        bookends = bookends,
        tab = "local",
        -- My presets sort mode. "latest" is mtime desc; "starred" filters
        -- to presets in the cycle gesture. ("name" is still honoured by the
        -- sort helper as a fallback but no longer has a dedicated pill.)
        my_sort = "latest",
        page = activePresetPage(bookends, "latest"),
        previewing = nil,
        original_settings = nil,
        modal_widget = nil,
        gallery_index = nil,
        gallery_loading = false,
        gallery_error = nil,
        -- Sort mode for the Gallery tab. "latest" is the historical behaviour
        -- (by `added` descending). "popular" orders by install-popularity
        -- counts fetched from the submit worker; falls back to latest when
        -- counts haven't loaded yet.
        gallery_sort = "latest",
        gallery_counts = nil,
        -- Used for tap-to-refresh staleness: a sort-mode tap only triggers a
        -- network fetch when the cached data is older than this threshold,
        -- absent, or flagged as failed. Otherwise it just re-sorts locally.
        gallery_last_refresh_time = nil,
        -- Active search query from the LibraryModal search bar; nil means no
        -- filter applied. Reset to nil on tab change.
        current_search = nil,
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
        -- Bust the per-render active-preset-name cache so gallery highlights
        -- reflect the current active preset after an apply or tab switch.
        self._active_preset_name = nil
        -- Invalidate the item list cache so disk-changing operations
        -- (delete / duplicate / rename / blank-create / install) see the
        -- new state. The cache key only tracks in-memory sort/tab/search
        -- toggles, not filesystem state. Within one refresh cycle the
        -- cache is rebuilt on the first item_count call and reused by the
        -- subsequent item_at calls (same key). The page is owned by
        -- LibraryModal once the modal is shown — chevron taps update
        -- lm.page directly; explicit domain-driven page jumps go through
        -- syncPageToWidget. Don't overwrite lm.page here or chevron
        -- navigation gets reset on every preview/star tap.
        self._items_cache = nil
        self._items_cache_key = nil
        UIManager:nextTick(function()
            if self.modal_widget and self.modal_widget.refresh then
                self.modal_widget:refresh()
            end
        end)
    end
    self.close = function(restore) PresetManagerModal._close(self, restore) end
    -- Explicit refresh: only called by the user tapping the Refresh button.
    -- This is the single code path that initiates a network request for the
    -- gallery index. Results live in self.gallery_index for the lifetime of
    -- this modal only — nothing is persisted to disk.
    self.refreshGallery = function()
        if self.gallery_loading then return end
        -- Bring Wi-Fi up if it's off (prompt per the user's KOReader prefs) and
        -- load once connected; cancel = no-op. Loading state is set inside the
        -- callback so a cancelled prompt leaves the gallery untouched
        -- (parity with bookshelf, issue #77). runWhenConnected, not
        -- runWhenOnline: the latter gates on a DNS lookup of Microsoft's
        -- dns.msftncsi.com and asks to turn on Wi-Fi that is already on when
        -- that host can't be resolved (#101, see Updater.gateOnConnection).
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:runWhenConnected(function()
        local Gallery = require("preset_gallery")
        self.gallery_loading = true
        self.gallery_error = nil
        -- Keep gallery_counts through the refresh so stale-refresh-in-background
        -- doesn't visibly strip the current sort. It gets overwritten when the
        -- new fetch lands.
        self.rebuild()

        -- Defer the synchronous fetch by one paint cycle so the chip strip
        -- has a chance to render the "Loading gallery…" status (driven by
        -- the chip_strip_status callback above) before the main thread
        -- freezes inside httpGet. Without this the chip-tap would freeze
        -- the UI silently for 1–5 s: rebuild()'s nextTick can't fire
        -- because the next call on the stack is the blocking fetch. 0.1 s
        -- is the same delay bookends_updater.lua:304-309 uses for the
        -- equivalent "show feedback then block" pattern.
        UIManager:scheduleIn(0.1, function()
            Gallery.fetchIndex("KOReader-Bookends", function(idx, err)
                if not idx then
                    self.gallery_loading = false
                    self.gallery_error = err
                    self.rebuild()
                    return
                end
                self.gallery_index = idx
                self.gallery_error = nil
                self.gallery_last_refresh_time = os.time()
                -- Secondary fetch: install counts (drives Popular sort). Non-fatal:
                -- failure just hides the popularity ordering until the next refresh.
                Gallery.fetchCounts("KOReader-Bookends", function(counts)
                    if counts then self.gallery_counts = counts end
                    self.gallery_loading = false
                    self.rebuild()
                end)
            end)
        end)
        end)
    end
    self.setGallerySort = function(mode)
        local mode_changed = self.gallery_sort ~= mode
        if mode_changed then
            self.gallery_sort = mode
            self.page = 1
        end
        -- LibraryModal._onChipTap already refreshes after this returns; we only
        -- trigger an explicit rebuild for the async-fetch case (refreshGallery
        -- updates state from a network callback that LibraryModal can't see).
        if not self.gallery_loading and galleryIsStale(self) then
            self.refreshGallery()
        end
    end
    -- Keep LibraryModal's internal page counter in step with the domain page
    -- whenever a sort/tab change recomputes it. The widget's _onTabSelect /
    -- _onChipTap both reset their local page=1 unconditionally, then call our
    -- handler — so we have to push the corrected page value back before they
    -- refresh.
    local function syncPageToWidget(self)
        if self.modal_widget then self.modal_widget.page = self.page end
    end
    self.setTab = function(tab)
        if self.tab ~= tab then
            self.tab = tab
            -- Drop search state across tabs so a query typed on one tab doesn't
            -- silently filter the other tab when the user switches.
            self.current_search = nil
            -- When returning to My presets, jump to the page with the active
            -- preset (same reason as on initial show). Gallery has no active
            -- concept, so it resets to page 1.
            if tab == "local" then
                self.page = activePresetPage(self.bookends, self.my_sort)
            else
                self.page = 1
            end
            syncPageToWidget(self)
        end
    end
    self.setMySort = function(mode)
        if self.my_sort ~= mode then
            self.my_sort = mode
            -- Keep the active preset in view when switching sort modes. Falls
            -- back to page 1 if filtered out (e.g. unstarred in Starred view).
            self.page = activePresetPage(self.bookends, mode)
            syncPageToWidget(self)
        end
    end
    self.setPage = function(p) self.page = p; self.rebuild() end
    -- Dismissal helper: star and other domain-internal taps go through this
    -- so the keyboard doesn't trap the user behind it after they tap.
    local function dismissModalKeyboard()
        if self.modal_widget and self.modal_widget._dismissKeyboard then
            self.modal_widget:_dismissKeyboard()
        end
    end
    self.previewLocal = function(p) dismissModalKeyboard(); PresetManagerModal._previewLocal(self, p) end
    self.applyCurrent = function() dismissModalKeyboard(); PresetManagerModal._applyCurrent(self) end
    self.toggleStar = function(key) dismissModalKeyboard(); PresetManagerModal._toggleStar(self, key) end

    -- Open at the page containing the active preset so it's immediately visible
    -- without the user having to page forward. Must be set before LibraryModal
    -- :init() runs because the config's item_count/item_at are called at refresh
    -- time, but page is also read by LibraryModal directly via self.page on the
    -- widget — so we stash it on the domain self and let the config's item_count
    -- drive pagination through LibraryModal's own self.page field (which starts
    -- at 1). We sync it via on_search_submit / setMySort / setTab.
    -- NOTE: LibraryModal owns its own self.page counter. The domain self.page is
    -- used by config callbacks that directly set self.page then call rebuild().
    -- LibraryModal's pagination state is fully separate. The active-preset jump
    -- is achieved by pre-computing the page and injecting it into LibraryModal
    -- after :new{} but before UIManager:show.
    local LibraryModal = require("menu.library_modal")
    local config = buildPresetLibraryConfig(self)
    local lm = LibraryModal:new{ config = config }
    -- Jump to the page containing the active preset on first open.
    lm.page = activePresetPage(bookends, "latest")
    self.modal_widget = lm
    UIManager:show(lm)
    UIManager:setDirty("all", "flashui")
end

--- Open the format-rule preset picker for file extension `ext` (uppercase).
--- Local presets only; a radio chooses the rule target (written immediately to
--- format_preset_rules[ext]); tapping a card previews live; Done restores the
--- pre-open overlay. on_done() fires once the modal closes. See spec (#87).
function PresetManagerModal.showFormatRulePicker(bookends, ext, on_done)
    local self = {
        bookends = bookends,
        ext = ext,
        on_done = on_done,
        tab = "local",
        page = 1,
        previewing = nil,
        modal_widget = nil,
        current_search = nil,
    }

    -- Snapshot the live overlay so Done can restore it exactly. The rule only
    -- takes effect on the NEXT document open, so previewing here must never
    -- leave a changed overlay behind. _format_hidden is captured too because
    -- the picker may toggle it while previewing the Hidden option.
    self.original_preset = bookends:buildPreset()
    self.original_active_filename = bookends:getActivePresetFilename()
    self.original_format_hidden = bookends._format_hidden

    -- Hide the reader menu (TouchMenu) that opened this picker while it's up.
    -- The picker previews each preset on the page BEHIND it; with the menu
    -- still shown it covers the page, so the user can't see what they're
    -- choosing. UIManager:close only removes the container from the window
    -- stack — the TouchMenu widget and its drilldown position survive — so we
    -- can re-show the very same widget on close and land the user back exactly
    -- where they were (the format-rules submenu). Mirrors the rest of the app,
    -- where applying/choosing a preset happens over the page, not the menu.
    local reader_menu = bookends.ui and bookends.ui.menu
    self._hidden_menu_container = reader_menu and reader_menu.menu_container or nil
    if self._hidden_menu_container then
        UIManager:close(self._hidden_menu_container)
    end

    self.rebuild = function()
        self._items_cache = nil
        UIManager:nextTick(function()
            if self.modal_widget and self.modal_widget.refresh then
                self.modal_widget:refresh()
            end
        end)
    end

    local function dismissModalKeyboard()
        if self.modal_widget and self.modal_widget._dismissKeyboard then
            self.modal_widget:_dismissKeyboard()
        end
    end

    -- Preview a local preset. Clears the hidden gate first so previewing a
    -- visible preset after previewing Hidden actually shows it.
    self.previewLocal = function(entry)
        dismissModalKeyboard()
        self.bookends._format_hidden = false
        PresetManagerModal._previewLocal(self, entry)
    end

    -- Preview the hidden state: overlay vanishes. Mirrors _previewLocal's
    -- _previewing bookkeeping (so the debounced autosave can't leak state) but
    -- toggles the render gate instead of loading a preset.
    self.previewHidden = function()
        dismissModalKeyboard()
        pcall(self.bookends.autosaveActivePreset, self.bookends)
        self.bookends._previewing = true
        self.bookends._format_hidden = true
        self.previewing = { kind = "hidden" }
        self.bookends:markDirty()
        self.rebuild()
    end

    -- Choose `key` (a preset filename or "HIDDEN") as the rule target. Persists
    -- immediately, then previews the choice. The picker stays open.
    self.chooseRuleTarget = function(key)
        local rules = self.bookends.settings:readSetting("format_preset_rules") or {}
        rules[ext] = key
        self.bookends.settings:saveSetting("format_preset_rules", rules)
        if key == "HIDDEN" then
            self.previewHidden()
        else
            local entry
            for _i, p in ipairs(sortedLocalPresets(self.bookends, "latest")) do
                if p.filename == key then entry = p; break end
            end
            if entry then self.previewLocal(entry) end
        end
    end

    -- Close + restore. Reuses _close for preset/active-filename restore, then
    -- puts the hidden gate back to its pre-open value. Fires on_done last.
    self.close = function(restore)
        PresetManagerModal._close(self, restore)
        if restore then
            self.bookends._format_hidden = self.original_format_hidden
            self.bookends:markDirty()
        end
        if self.on_done then self.on_done() end
    end

    local LibraryModal = require("menu.library_modal")
    local lm = LibraryModal:new{ config = buildFormatRulePickerConfig(self) }
    self.modal_widget = lm
    -- Route the hardware Back key through the picker's own close(true) so a
    -- Back dismissal restores the previewed overlay and fires on_done, same as
    -- the Done footer. LibraryModal's stock onClose just closes the widget
    -- (skipping the config footer), which would leave a previewed preset/hidden
    -- state applied until the next document open. Instance-level override only:
    -- this is a fresh LibraryModal per picker, so the everyday manager (which
    -- shares LibraryModal's class onClose) is unaffected. Tap-outside dismissal
    -- still takes the stock path; that state self-corrects on next document open.
    lm.onClose = function()
        self.close(true)
        return true
    end
    -- Re-show the reader menu we hid on open, at the same position. Hook
    -- onCloseWidget (not just self.close) so EVERY dismissal path restores it:
    -- the Done footer and hardware Back both route through self.close →
    -- UIManager:close(lm), and a tap-outside dismissal takes LibraryModal's
    -- stock path — all of them fire onCloseWidget exactly once. Guarded on the
    -- saved reference so it can't double-show.
    local lm_onCloseWidget = lm.onCloseWidget
    lm.onCloseWidget = function(widget, ...)
        if self._hidden_menu_container then
            UIManager:show(self._hidden_menu_container)
            UIManager:setDirty(self._hidden_menu_container, "flashui")
            self._hidden_menu_container = nil
        end
        if lm_onCloseWidget then return lm_onCloseWidget(widget, ...) end
    end
    UIManager:show(lm)
    UIManager:setDirty("all", "flashui")
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
        self.bookends:setManualActivePreset(self.previewing.filename)
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
        self.bookends:setManualActivePreset(filename)
        pcall(require("preset_gallery").recordInstall, entry.slug, "KOReader-Bookends")
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
    -- Row fills the full slot width: [card][gap][star_column]. The card's
    -- left edge sits flush with the slot's left edge so it lines up with
    -- the search box / chip strip / pagination divider above and below.
    local card_outer_w = width - star_gap - star_width
    local content_w = card_outer_w - 2 * inner_pad - 2 * Size.border.thin

    -- Secondary text colour: GRAY_5 (0x55) on WHITE — read as too faded
    -- at the older DARK_GRAY (0x88), matched the tokens picker bump.
    -- On LIGHT_GRAY (selected state) we darken to pure black for
    -- readable contrast.
    local secondary_fg = opts.is_selected and Blitbuffer.COLOR_BLACK
        or Blitbuffer.COLOR_GRAY_5

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

    -- Card frame: solid thin border for real cards; bordersize 0 for virtual
    -- placeholders so the dashed-border overlay below is the only outline.
    local card_bg = opts.is_selected
        and (Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.gray(0.92))
        or Blitbuffer.COLOR_WHITE
    local card_frame = FrameContainer:new{
        bordersize = opts.is_virtual and 0 or Size.border.thin,
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
    if opts.is_virtual then
        -- Synthetic placeholder tile gets a dashed-border overlay instead of
        -- the solid bordered look so it reads as an action affordance, not
        -- another preset card.
        card_stack = OverlapGroup:new{
            dimen = Geom:new{ w = card_w, h = card_h },
            allow_mirroring = false,
            card_frame,
            DashedBorder:new{ w_actual = card_w, h_actual = card_h,
                              color = Blitbuffer.COLOR_DARK_GRAY },
        }
    elseif opts.has_colour then
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
    local LibraryModal = require("menu.library_modal")
    LibraryModal._attachFocus(card, card_frame)

    -- Right-hand accent column. Local rows show a tappable ★/☆ that toggles
    -- cycle membership. Gallery rows show a ✓ if the preset is already
    -- installed locally (not tappable). Anything else gets an empty slot so
    -- cards stay left-aligned consistently.
    local accent_ic
    if opts.radio_key then
        -- Radio control for the format-rule picker: filled when this row is the
        -- chosen rule target, empty otherwise. Tap chooses this target. Mirrors
        -- the star branch's focus-bordered, d-pad-focusable accent cell.
        local radio_widget = TextWidget:new{
            text = opts.radio_selected and "\xE2\x97\x89" or "\xE2\x97\xAF",  -- ◉ / ◯
            face = Font:getFace("infofont", 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        local fb = LibraryModal.FOCUS_BORDER
        local radio_frame = FrameContainer:new{
            bordersize = fb,
            color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_WHITE,
            padding = 0,
            margin = 0,
            radius = Size.radius.default,
            CenterContainer:new{
                dimen = Geom:new{ w = star_width - 2 * fb, h = card_height - 2 * fb },
                radio_widget,
            },
        }
        accent_ic = InputContainer:new{
            dimen = Geom:new{ w = star_width, h = card_height },
            radio_frame,
        }
        accent_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = accent_ic.dimen } } }
        local key = opts.radio_key
        accent_ic.onTapSelect = function() self.chooseRuleTarget(key); return true end
        LibraryModal._attachFocus(accent_ic, radio_frame)
    elseif opts.star_key then
        local star_widget = TextWidget:new{
            text = starred and "\xE2\x98\x85" or "\xE2\x98\x86",
            face = Font:getFace("infofont", 22),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        -- Reserved focus-border slot (white = invisible) so the star is a
        -- d-pad-focusable cell beside the card, with no reflow on focus. The
        -- inner CenterContainer shrinks by the border so the outer size holds.
        local fb = LibraryModal.FOCUS_BORDER
        local star_frame = FrameContainer:new{
            bordersize = fb,
            color = Blitbuffer.COLOR_WHITE,
            background = Blitbuffer.COLOR_WHITE,
            padding = 0,
            margin = 0,
            radius = Size.radius.default,
            CenterContainer:new{
                dimen = Geom:new{ w = star_width - 2 * fb, h = card_height - 2 * fb },
                star_widget,
            },
        }
        accent_ic = InputContainer:new{
            dimen = Geom:new{ w = star_width, h = card_height },
            star_frame,
        }
        accent_ic.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = accent_ic.dimen } } }
        local key = opts.star_key
        accent_ic.onTapSelect = function() self.toggleStar(key); return true end
        LibraryModal._attachFocus(accent_ic, star_frame)
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

    local row_hgroup = HorizontalGroup:new{
        align = "center",
        card,
        HorizontalSpan:new{ width = star_gap },
        accent_ic,
    }
    -- Tell LibraryModal._renderListArea which inner widget(s) are focusable
    -- (the wrapper HorizontalGroup itself is not). Local rows expose two cells
    -- — the card body (preview) and the star toggle (favourite) — so d-pad
    -- Left/Right reaches the star. Gallery/installed/virtual rows have only the
    -- card body. Drop this and the row vanishes from d-pad navigation.
    if opts.star_key or opts.radio_key then
        row_hgroup._focus_row = { card, accent_ic }
    else
        row_hgroup._focus_target = card
    end
    table.insert(vg, row_hgroup)
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
                    self.bookends:setManualActivePreset(filename)
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
    -- applyManualPresetFile loads the blank into memory before setting it
    -- active (so the debounced autosave can't clobber the on-disk file with
    -- the previously-active preset's data) and remembers it as the manual
    -- default (#87), same as any other explicit preset choice.
    self.bookends:applyManualPresetFile(filename)
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

-- Submit-flow rename helper: same effect as the standard rename action (file
-- on disk + cycle list + active-preset bookkeeping) but takes a callback so
-- the gate can re-enter the submit flow once the user picks a real name. The
-- explanatory `message` argument tells the user *why* a rename is being asked
-- for, which differs from a cold rename initiated from the manage menu.
local function promptRenameAndContinue(self, entry, message, on_done)
    local dlg
    dlg = InputDialog:new{
        title       = _("Rename before sharing"),
        description = message,
        input       = entry.name,
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dlg) end },
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
                        entry.filename = new_filename
                        entry.name     = new_name
                        if entry.preset then entry.preset.name = new_name end
                    end
                end
                UIManager:close(dlg)
                if on_done then on_done() end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
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

    -- Default-content gates: catch placeholder name/description that the
    -- plugin auto-generates (migration default "My setup", new-preset default
    -- "Untitled[ N]", migration description). Both English source string and
    -- current-locale translation are checked, so a Spanish KOReader's
    -- "Mi configuración" is also gated. See preset_naming.lua for predicates.
    local PresetNaming = require("preset_naming")
    local default_names = { "My setup", _("My setup") }
    local untitled_prefixes = { "Untitled", _("Untitled") }
    local default_descriptions = {
        "Imported from your earlier Bookends settings",
        _("Imported from your earlier Bookends settings"),
    }
    if PresetNaming.looksLikeDefaultName(data.name, default_names, untitled_prefixes) then
        promptRenameAndContinue(self, entry,
            T(_("'%1' is one of Bookends' default placeholder names. Give your preset something distinctive — that's how it'll appear in the gallery."), data.name),
            function() PresetManagerModal._submitToGallery(self, entry) end)
        return
    end
    if PresetNaming.looksLikeDefaultDescription(data.description, default_descriptions) then
        editMetadataField(self, entry, "description",
            _("Write a short description that tells gallery users what your preset shows"),
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
                -- Bring Wi-Fi up if it's off (prompt per the user's prefs) and
                -- submit once connected; cancel = no-op (bookshelf #77).
                -- runWhenConnected rather than runWhenOnline - see the refresh
                -- path above and Updater.gateOnConnection (#101).
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenConnected(function()
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
                self.bookends:setManualActivePreset(filename)
                pcall(require("preset_gallery").recordInstall, entry.slug, "KOReader-Bookends")
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
                                self.bookends:setManualActivePreset(filename)
                                pcall(require("preset_gallery").recordInstall, entry.slug, "KOReader-Bookends")
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
