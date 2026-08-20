--- Tokens library: replaces menu/token_picker.lua. Renders the token +
--- conditional catalogues as a chip-filtered list. Conditionals are split
--- across two chips: "If/else" (reference patterns with `...` placeholders)
--- and "Examples" (full templates with content). Icon-only tokens
--- (%batt_icon, %wifi, %light_icon, %warmth_icon, %nightmode, %invert) live
--- in the icons library Dynamic chip, not here. Search submits across
--- descriptions, token literals, and (for conditionals) expressions.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LibraryModal = require("menu.library_modal")
local Size = require("ui/size")
local Tokens = require("bookends_tokens")
local UIManager = require("ui/uimanager")
local Utils = require("bookends_utils")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local _ = require("bookends_i18n").gettext

local Screen = Device.screen

local TokensLibrary = {}

-- Catalogue tables (chip list, regular tokens, conditional templates)
-- live in menu/tokens_catalogue.lua so the curator web app at
-- tools/curate_catalogues.py has a single file to round-trip.
local Catalogue = require("menu.tokens_catalogue")
local CHIPS = Catalogue.CHIPS
TokensLibrary.TOKENS = Catalogue.TOKENS
TokensLibrary.CONDITIONALS = Catalogue.CONDITIONALS

--- Favourites are stored in the `token_favourites` plugin setting as an
--- ordered array of token value strings (item.token or item.expression),
--- most-recent first. These helpers are pure (operate on plain tables, no
--- settings/widget access) so they're unit-testable; persistence + rebuild
--- live in TokensLibrary:show. Exposed on the module table for tests.

--- True if `key` is in the favourites array.
function TokensLibrary._isFavourite(favs, key)
    if not favs or not key then return false end
    for _i = 1, #favs do
        if favs[_i] == key then return true end
    end
    return false
end

--- Returns a NEW favourites array (never mutates `favs`): prepend `key` when
--- absent (most-recent first), remove it when present.
function TokensLibrary._toggleFavourite(favs, key)
    favs = favs or {}
    local out, found = {}, false
    for _i = 1, #favs do
        if favs[_i] == key then
            found = true
        else
            out[#out + 1] = favs[_i]
        end
    end
    if not found then table.insert(out, 1, key) end
    return out
end

--- Intersect catalogue `items` with `favs`, returned in favs order
--- (most-recent first). Items are keyed by their value string (token or
--- expression). Favourites with no matching catalogue entry (e.g. the curator
--- later removed the token) are silently skipped — self-cleaning, no migration.
function TokensLibrary._filterFavourites(items, favs)
    favs = favs or {}
    local by_value = {}
    for _i = 1, #items do
        local it = items[_i]
        local val = it.token or it.expression
        if val and by_value[val] == nil then by_value[val] = it end
    end
    local out = {}
    for _i = 1, #favs do
        local it = by_value[favs[_i]]
        if it then out[#out + 1] = it end
    end
    return out
end

--- Filter the merged token + conditional list by chip and search query.
--- All chip → both lists merged; If/else chip → conditionals only; other
--- chips → tokens with matching chip tag.
function TokensLibrary._currentItems(active_chip, search_query, favourites)
    local items = {}
    if active_chip == "favourites" then
        -- Full merged catalogue intersected with the favourites set, kept in
        -- favourites order (most-recent first). favourites passed in by show
        -- so this stays pure/testable (no settings access here).
        local merged = {}
        for _i, t in ipairs(TokensLibrary.TOKENS) do merged[#merged + 1] = t end
        for _i, c in ipairs(TokensLibrary.CONDITIONALS) do merged[#merged + 1] = c end
        items = TokensLibrary._filterFavourites(merged, favourites or {})
    elseif active_chip == "all" or not active_chip then
        for _i, t in ipairs(TokensLibrary.TOKENS) do items[#items + 1] = t end
        for _i, c in ipairs(TokensLibrary.CONDITIONALS) do items[#items + 1] = c end
    else
        -- Single uniform filter — works for both regular tokens (chip in
        -- {book, progress, time, session, device}) and conditionals
        -- (chip = "ifelse"). The "templates" chip merges plain-text
        -- snippets (TOKENS with chip = "templates") and conditional
        -- templates (CONDITIONALS with chip = "templates").
        for _i, t in ipairs(TokensLibrary.TOKENS) do
            if t.chip == active_chip then items[#items + 1] = t end
        end
        for _i, c in ipairs(TokensLibrary.CONDITIONALS) do
            if c.chip == active_chip then items[#items + 1] = c end
        end
    end
    if search_query and #search_query >= 2 then
        local filtered = {}
        for _i, item in ipairs(items) do
            local hay = (item.description or "")
                .. " " .. (item.token or "")
                .. " " .. (item.expression or "")
            if LibraryModal._matchesQuery(hay, search_query) then
                filtered[#filtered + 1] = item
                if #filtered >= 200 then break end
            end
        end
        return filtered
    end
    return items
end

--- Per-render document context for live token expansion. pcall'd so any
--- nil-deref or missing API on the Bookends instance just disables
--- expansion rather than crashing the modal open.
local function buildDocContext(bookends)
    if not bookends then return nil end
    local ok, ctx = pcall(function()
        if not bookends.ui then return nil end
        return {
            ui              = bookends.ui,
            session_elapsed = bookends:getSessionElapsed(),
            session_pages   = bookends:getSessionPages(),
            tick_mult       = bookends.DEFAULT_TICK_WIDTH_MULTIPLIER,
            stats_cache     = {},
        }
    end)
    return ok and ctx or nil
end

--- Render a single token / conditional row as a card. Two-line:
---   Line 1 (bold): description
---   Line 2:        for conditionals: expression; for tokens: '%token → live'
---                  (or just the literal if expansion fails or no ctx);
---                  for snippets: full template.
function TokensLibrary._renderRow(item, slot_dimen, doc_ctx, is_fav, on_select, on_toggle_fav)
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local inner_pad = Screen:scaleBySize(12)
    local card_h = slot_dimen.h
    -- Reserve a right-hand star column (matches preset_manager_modal layout:
    -- 40px star + 6px gap). The card occupies the remaining width.
    local star_width = Screen:scaleBySize(40)
    local star_gap = Screen:scaleBySize(6)
    local card_outer_w = slot_dimen.w - star_gap - star_width
    local content_w = card_outer_w - 2 * inner_pad - 2 * Size.border.thin

    local line1 = TextWidget:new{
        text = item.description or "",
        face = Font:getFace("cfont", 16),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = content_w,
    }

    local line2_text
    if item.expression then
        line2_text = item.expression
    elseif item.is_snippet then
        line2_text = item.token
    else
        local expansion = ""
        if doc_ctx and item.token then
            -- Memoise per-token within this modal session: token values are
            -- invariant for the lifetime of the picker, but row_renderer
            -- fires every refresh (chip tap, page chevron, search submit).
            -- doc_ctx.expand_cache holds the formatted suffix string, or
            -- false when the token has no displayable value. nil = uncached.
            local cache = doc_ctx.expand_cache
            if not cache then
                cache = {}
                doc_ctx.expand_cache = cache
            end
            local cached = cache[item.token]
            if cached == nil then
                -- Tokens.expand can throw on edge cases (eg %datetime{format}
                -- with bad format spec, or stats tokens before SQLite is
                -- ready) — pcall so a single bad token doesn't take the
                -- whole list down.
                local ok, val = pcall(Tokens.expand, item.token, doc_ctx.ui,
                    doc_ctx.session_elapsed, doc_ctx.session_pages,
                    nil, doc_ctx.tick_mult, nil, nil,
                    { stats_cache = doc_ctx.stats_cache })
                if ok and val and val ~= "" and val ~= item.token then
                    cached = " \xE2\x86\x92 " .. Utils.truncateUtf8(val, 25)
                else
                    cached = false
                end
                cache[item.token] = cached
            end
            if cached then expansion = cached end
        end
        line2_text = (item.token or "") .. expansion
    end
    local line2 = TextWidget:new{
        text = line2_text,
        face = Font:getFace("cfont", 13),
        -- COLOR_DARK_GRAY (0x88) read as too faded — bumping to GRAY_5
        -- (0x55) for clearer contrast against white while staying
        -- visibly subordinate to the bold-black description above.
        fgcolor = Blitbuffer.COLOR_GRAY_5,
        max_width = content_w,
    }

    local stack = VerticalGroup:new{
        align = "left",
        line1,
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        line2,
    }
    local card_frame = FrameContainer:new{
        bordersize = Size.border.thin,
        radius = Size.radius.default,
        padding = 0,
        padding_left = inner_pad,
        padding_right = inner_pad,
        padding_top = 0,
        padding_bottom = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = card_h - 2 * Size.border.thin },
            stack,
        },
    }
    local card = InputContainer:new{
        dimen = Geom:new{ w = card_outer_w, h = card_h },
        card_frame,
    }
    card.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = card.dimen } },
    }
    card.onTapSelect = function() if on_select then on_select() end; return true end
    LibraryModal._attachFocus(card, card_frame)

    -- Right-hand tappable star, same glyphs/size as the preset chooser
    -- (preset_manager_modal.lua): ★ filled = favourited, ☆ outline = not.
    local star_widget = TextWidget:new{
        text = is_fav and "\xE2\x98\x85" or "\xE2\x98\x86",
        face = Font:getFace("infofont", 22),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    -- Reserved focus-border slot (white = invisible) so the star is a
    -- d-pad-focusable cell with no glyph reflow on focus. The inner
    -- CenterContainer shrinks by the border so the outer size holds.
    -- Mirrors preset_manager_modal.lua's accent-column star.
    local fb = LibraryModal.FOCUS_BORDER
    local star_frame = FrameContainer:new{
        bordersize = fb, color = Blitbuffer.COLOR_WHITE,
        padding = 0, margin = 0, radius = Size.radius.default,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = star_width - 2 * fb, h = card_h - 2 * fb },
            star_widget,
        },
    }
    local star_ic = InputContainer:new{
        dimen = Geom:new{ w = star_width, h = card_h },
        star_frame,
    }
    star_ic.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = star_ic.dimen } },
    }
    star_ic.onTapSelect = function() if on_toggle_fav then on_toggle_fav() end; return true end
    LibraryModal._attachFocus(star_ic, star_frame)

    local row = HorizontalGroup:new{
        align = "center",
        card,
        HorizontalSpan:new{ width = star_gap },
        star_ic,
    }
    -- Both cells d-pad reachable left->right (LibraryModal reads _focus_row).
    row._focus_row = { card, star_ic }
    return row
end

--- Show the tokens library modal. on_select(value) is called with the
--- chosen token / expression when the user taps a row.
function TokensLibrary:show(bookends, on_select)
    self.bookends = bookends
    local state = { active_chip = "all", search_query = nil }
    -- Memoise the filtered list per (chip, query) key. Each LibraryModal
    -- refresh fires item_count + item_at-per-row + a second item_count from
    -- pagination, so without this the merged TOKENS+CONDITIONALS list got
    -- rebuilt 6-8x per refresh. Key invalidates automatically when chip or
    -- query change; nothing else mutates the underlying catalogues.
    local items_key, items_cache = nil, nil
    local function items()
        -- Favourites view: never cache -- a star toggle mutates the list
        -- without changing the (chip, query) key, and the list is small.
        if state.active_chip == "favourites" then
            local favs = bookends.settings:readSetting("token_favourites") or {}
            items_key = nil  -- force a fresh build on the next non-favourites view
            return TokensLibrary._currentItems("favourites", state.search_query, favs)
        end
        local key = (state.active_chip or "") .. "\0" .. (state.search_query or "")
        if items_key ~= key then
            items_cache = TokensLibrary._currentItems(state.active_chip, state.search_query)
            items_key = key
        end
        return items_cache
    end
    -- Doc context built once at modal-open. Live-token expansions in row 2
    -- reference this; if buildDocContext returned nil (e.g. ui not ready),
    -- _renderRow falls back to showing the raw token literal.
    local doc_ctx = buildDocContext(bookends)
    local self_ref = self

    local config = {
        title = _("Tokens library"),
        help_title = _("Tokens & conditionals"),
        help_text = _([[TOKENS

Tokens are placeholders that get replaced with live data each time the preset renders. Each entry in the Book / Progress / Time / Session / Device chips is a token, written as %name. They expand inline:
  %title — %page_num/%page_count
  → 1984 — 12/268

A token name runs until the next non-letter, so you need a space (or punctuation) before any following text. To butt text right up against a token, wrap the name in angle brackets:
  %<book_time_left_h>h%<book_time_left_m>m
  → 4h40m
Width limits still work inside them: %<author{200}>.

INLINE STYLING

Wrap a span of text to restyle just that part:
  [b]…[/b] bold   [i]…[/i] italic   [u]…[/u] UPPERCASE
  [c=50]…[/c] grey 0–100   [c=#RRGGBB]…[/c] colour
  [font=Name]…[/font] switch font for the span

The font Name is the display name shown in KOReader's font menu, e.g. [font=Noto Sans]%title[/font]. Spaces are fine. If that font isn't installed on the device, the span falls back to the line's font, so presets stay readable when shared.

CONDITIONALS

Wrap content in [if:condition]…[/if] to show it only when the condition is true. Add an [else]…[/if] branch for an alternative.

OPERATORS
  =    equals               !=  not equals
  <    less than            >   greater than
  <=   at most              >=  at least
  and / or / not  · ( ) for grouping

  Example:  [if:batt<20 and not charging]LOW[/if]

Truthy check: a bare [if:key] tests whether the key is set, non-zero, and not "off"/"no". Useful for [if:title]…[/if], [if:author]…[/if], [if:series]…[/if].

Token-reference comparison: =@token compares against another token's current value, e.g. [if:chap_title_1!=@title]…[/if] hides the chapter title when it equals the book title.

For the full list of conditional state keys (wifi, batt, light_pct, night, time, format, …) browse the If/else chip — every reference entry there shows the exact key and operator syntax for one condition.

EXAMPLES

  [if:authors>1]%author, et al.[else]%author[/if]
  [if:batt<20]LOW %batt[/if]
  [if:time>=18:00 and time<18:30]6–6:30[/if]
  [if:not series]Standalone[/if]
]]),
        chip_strip = function()
            -- Favourites is injected here (not in tokens_catalogue.lua's CHIPS)
            -- because the curator web app overwrites the catalogue file wholesale.
            local out = {
                {
                    key = "favourites",
                    label = _("\xE2\x98\x85 Favourites"),
                    is_active = (state.active_chip == "favourites") and true or false,
                },
            }
            for _i, c in ipairs(CHIPS) do
                out[#out + 1] = {
                    key = c.key, label = c.label,
                    is_active = (c.key == state.active_chip) and true or false,
                }
            end
            return out
        end,
        on_chip_tap = function(chip_key)
            state.active_chip = chip_key
            -- Mirror the icons-modal contract: chip taps clear active search
            -- so the chip-filtered view becomes the consistent visible state.
            if state.search_query then
                state.search_query = nil
                if self_ref.modal then
                    self_ref.modal.search_query = nil
                    if self_ref.modal._search_input then
                        self_ref.modal._search_input:setText("")
                    end
                end
            end
        end,
        search_placeholder = function() return _("Search tokens by name, value, or expression…") end,
        empty_state = function(content_width, area_height)
            if state.active_chip ~= "favourites" then return nil end
            local hint = TextWidget:new{
                -- Plain hyphen, no em dash (project style).
                text = _("No favourites yet. Tap the \xE2\x98\x86 on any token to add it."),
                face = Font:getFace("cfont", 15),
                fgcolor = Blitbuffer.COLOR_GRAY_5,
                max_width = content_width - Screen:scaleBySize(24),
            }
            return CenterContainer:new{
                dimen = Geom:new{ w = content_width, h = area_height },
                hint,
            }
        end,
        on_search_submit = function(query)
            state.search_query = query
            -- Search hits the merged TOKENS + CONDITIONALS pool regardless
            -- of the active chip, so snap the chip strip back to "All" so
            -- it reflects what's actually visible. Mirrors the icons
            -- library's behaviour (menu/icons_library.lua).
            if query then state.active_chip = "all" end
        end,
        rows_per_page = function()
            return Screen:getWidth() > Screen:getHeight() and 4 or 5
        end,
        item_count = function() return #items() end,
        item_at = function(idx) return items()[idx] end,
        row_renderer = function(item, dimen)
            local val = item.token or item.expression
            local favs = bookends.settings:readSetting("token_favourites") or {}
            local is_fav = TokensLibrary._isFavourite(favs, val)
            -- Card tap: insert the token + close. Star tap: toggle favourite,
            -- persist, and refresh the modal so the glyph + (in the Favourites
            -- view) the filtered list both update.
            local function selectRow()
                if self_ref.modal then UIManager:close(self_ref.modal); self_ref.modal = nil end
                if on_select and val then on_select(val) end
            end
            local function toggleFav()
                if not val then return end
                local cur = bookends.settings:readSetting("token_favourites") or {}
                bookends.settings:saveSetting("token_favourites",
                    TokensLibrary._toggleFavourite(cur, val))
                if self_ref.modal then self_ref.modal:refresh() end
            end
            return TokensLibrary._renderRow(item, dimen, doc_ctx, is_fav, selectRow, toggleFav)
        end,
        footer_actions = {
            { key = "close", label = _("Close"), on_tap = function()
                if self_ref.modal then UIManager:close(self_ref.modal); self_ref.modal = nil end
            end },
            { key = "help", label = _("Help"), on_tap = function()
                if self_ref.modal then self_ref.modal:_showHelp() end
            end },
        },
    }
    self.modal = LibraryModal:new{ config = config }
    UIManager:show(self.modal)
end

return TokensLibrary
