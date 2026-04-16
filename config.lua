--- Central constants: defaults, schema, and preset key groupings.
-- Pure data, no logic. Any module that needs a setting default reads it here.
local Config = {}

Config.MAX_BARS = 8

Config.DEFAULT_MARGINS = {
    margin_top = 10, margin_bottom = 25,
    margin_left = 18, margin_right = 18,
}

Config.DEFAULT_TICK_WIDTH_MULTIPLIER = 2

--- Default per-progress-bar configuration.
Config.BAR_DEFAULTS = {
    enabled = false, type = "book", style = "solid", height = 20,
    v_anchor = "bottom", margin_v = 0, margin_left = 0, margin_right = 0,
    chapter_ticks = "off",
}

--- First-run default positions. Loaded only when no saved config exists.
Config.DEFAULT_POSITIONS = {
    tl = { lines = { "%A \xE2\x8B\xAE %T" }, line_font_size = { [1] = 12 } },
    tc = { lines = { "%k \xC2\xB7 %a %d" }, line_font_size = { [1] = 14 }, line_style = { [1] = "bold" } },
    tr = { lines = { "%C" }, line_style = { [1] = "bold" } },
    bl = { lines = { "\xE2\x8F\xB3 %R session" } },
    bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 16 } },
    br = { lines = { "%B %W" }, line_font_size = { [1] = 10 } },
}

--- Per-line attribute field names. Used anywhere per-line metadata is
--- rebased/shifted (line delete, line swap) to avoid hard-coding the list.
Config.LINE_FIELDS = {
    "line_style", "line_font_size", "line_font_face",
    "line_v_nudge", "line_h_nudge", "line_uppercase",
    "line_page_filter", "line_bar_type", "line_bar_height", "line_bar_style",
}

--- Settings keys that belong to the "defaults" group (font/margin/layout
--- shared across every position). Drives bulk save/load in preset logic.
Config.DEFAULTS_KEYS = {
    "font_face", "font_size", "font_bold", "font_scale",
    "margin_top", "margin_bottom", "margin_left", "margin_right",
    "overlap_gap", "truncation_priority",
}

--- Optional settings that a preset may carry. Each key is saved if the
--- preset provides a value, or cleared from settings otherwise. Omit
--- `font_face` — the user's default font is never overridden by a preset.
Config.PRESET_OPTIONAL_KEYS = {
    "bar_colors", "tick_width_multiplier", "tick_height_pct",
    "text_color", "symbol_color",
}

--- Legacy G_reader_settings keys migrated into the plugin's own settings
--- file on first run. Only read once; safe to extend without breaking users.
Config.LEGACY_GLOBAL_KEYS = {
    "enabled", "font_face", "font_size", "font_bold", "font_scale",
    "margin_top", "margin_bottom", "margin_left", "margin_right",
    "overlap_gap", "truncation_priority", "presets", "last_cycled_preset",
}

return Config
