--- Schema migrations for bookends presets and settings.
-- Pure-Lua, no KOReader dependencies — keeps migrations unit-testable
-- from the dev-box harness.
--
-- Each migration is a function that mutates a settings-shaped table
-- in place and returns true if it changed anything, false otherwise.
-- Callers wrap with their own persistence (settings:flush, preset save).

local Migrations = {}

--- Promote global bar_colors / tick_height_pct / tick_width_multiplier
-- into each enabled progress bar's per-bar colors table.
--
-- Handles both storage shapes:
--   - Settings file: progress_bar_<n> as separate top-level keys
--   - Preset file:   progress_bars as an array (tbl.progress_bars[1..N])
--
-- Per-bar values win: only nil fields on the bar are filled from the
-- global source. read_height_pct and unread_height_pct are dropped
-- entirely (they were inline-only effects with no per-bar meaning).
--
-- Legacy metro_fill / track keys propagate as-is — the read-shim in
-- Colour.resolveBarColors aliases them at paint time, so the user's
-- intent is preserved without additional renaming here.
--
-- @param tbl table  settings-shaped table to mutate in place
-- @return boolean   true if any field was migrated, false if no-op
function Migrations.barColorsToPerBar(tbl)
    local bc = tbl.bar_colors
    local th = tbl.tick_height_pct
    local tw = tbl.tick_width_multiplier
    local has_anything = (bc ~= nil and next(bc) ~= nil) or th ~= nil or tw ~= nil
    if not has_anything then return false end

    -- Build the source table: bar_colors fields plus the two standalones.
    -- Strip inline-only thickness keys; they no longer have a home.
    local src = {}
    if bc then
        for k, v in pairs(bc) do src[k] = v end
    end
    if th ~= nil then src.tick_height_pct = th end
    if tw ~= nil then src.tick_width_multiplier = tw end
    src.read_height_pct = nil
    src.unread_height_pct = nil

    if next(src) == nil then
        -- Nothing meaningful to propagate (e.g. bar_colors had only
        -- read_height_pct). Still strip the originals.
        tbl.bar_colors = nil
        tbl.tick_height_pct = nil
        tbl.tick_width_multiplier = nil
        return true
    end

    local function migrate_bar(bar_cfg)
        if type(bar_cfg) ~= "table" then return end
        if not bar_cfg.enabled then return end
        bar_cfg.colors = bar_cfg.colors or {}
        for k, v in pairs(src) do
            if bar_cfg.colors[k] == nil then
                bar_cfg.colors[k] = v
            end
        end
    end

    -- Preset-file shape: progress_bars array
    if type(tbl.progress_bars) == "table" then
        for _, bar_cfg in ipairs(tbl.progress_bars) do
            migrate_bar(bar_cfg)
        end
    end

    -- Settings-file shape: progress_bar_<n> as separate keys
    for k, v in pairs(tbl) do
        if type(k) == "string" and k:match("^progress_bar_%d+$") then
            migrate_bar(v)
        end
    end

    tbl.bar_colors = nil
    tbl.tick_height_pct = nil
    tbl.tick_width_multiplier = nil
    return true
end

--- Seed manual_active_preset_filename from active_preset_filename (#87).
--- Introduces the "manual default" pointer, distinct from
--- active_preset_filename (which format-based auto-rules are free to
--- override per document). Existing users' current active preset becomes
--- their manual default; brand-new users with no active preset yet get
--- nothing seeded (same as always).
-- @param tbl settings table (mutated in place)
-- @return true if manual_active_preset_filename was set, false if there was
--   nothing to seed or it was already set
function Migrations.seedManualActivePreset(tbl)
    if tbl.manual_active_preset_filename then return false end
    if not tbl.active_preset_filename then return false end
    tbl.manual_active_preset_filename = tbl.active_preset_filename
    return true
end

return Migrations
