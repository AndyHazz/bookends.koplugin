--- Utility helpers shared across the plugin. KOReader modules loaded lazily where needed.
local _ = require("bookends_i18n").gettext
local Utils = {}

--- Supported font-family keys with human-readable labels.
-- "ui" resolves to KOReader's UI font; others resolve via cre_font_family_fonts.
Utils.FONT_FAMILIES = {
    ui             = _("UI font"),
    serif          = _("Serif"),
    ["sans-serif"] = _("Sans-serif"),
    monospace      = _("Monospace"),
    cursive        = _("Cursive"),
    fantasy        = _("Fantasy"),
}
Utils.FONT_FAMILY_ORDER = { "ui", "serif", "sans-serif", "monospace", "cursive", "fantasy" }

--- Remove an index from a sparse table, shifting higher indices down.
-- Unlike table.remove, this works correctly when the table has gaps.
function Utils.sparseRemove(tbl, idx)
    if not tbl then return end
    local max_idx = 0
    for k in pairs(tbl) do
        if type(k) == "number" and k > max_idx then max_idx = k end
    end
    for i = idx, max_idx do
        tbl[i] = tbl[i + 1]
    end
end

--- Truncate a string to max_bytes, avoiding splitting multi-byte UTF-8 characters.
function Utils.truncateUtf8(str, max_bytes)
    if #str <= max_bytes then return str end
    local pos = 0
    local i = 1
    while i <= max_bytes do
        local b = str:byte(i)
        local char_len
        if b < 0x80 then char_len = 1
        elseif b < 0xE0 then char_len = 2
        elseif b < 0xF0 then char_len = 3
        else char_len = 4 end
        if i + char_len - 1 > max_bytes then break end
        pos = i + char_len - 1
        i = i + char_len
    end
    return str:sub(1, pos) .. "..."
end

--- Cycle to the next value in a list, wrapping around to the first.
function Utils.cycleNext(tbl, current)
    for i, v in ipairs(tbl) do
        if v == current then return tbl[(i % #tbl) + 1] end
    end
    return tbl[1]
end

--- Resolve a font display name (e.g. "Noto Sans") to its file path.
-- KOReader's cre_font_family_fonts stores display names, but Font:getFace
-- needs a file. Returns the input as-is if it already looks like a path.
-- Uses CRE's own face-to-file logic when available (picks the regular
-- variant, matching the stock KOReader font menu). Falls back to
-- rank-based FontList iteration — same heuristic the bookends picker uses.
-- Returns nil if no matching font is installed.
local function resolveFontNameToFile(name_or_file)
    if type(name_or_file) ~= "string" or name_or_file == "" then return nil end
    if name_or_file:find("/") or name_or_file:match("%.[tT][tT][fFcC]$")
       or name_or_file:match("%.[oO][tT][fFcC]$") then
        return name_or_file  -- already a file path
    end
    -- Preferred: ask CRE (matches stock KOReader's font resolution)
    local ok_cre, cre = pcall(function()
        return require("document/credocument"):engineInit()
    end)
    if ok_cre and cre and cre.getFontFaceFilenameAndFaceIndex then
        local ok_call, file = pcall(cre.getFontFaceFilenameAndFaceIndex, name_or_file)
        if ok_call and type(file) == "string" and file ~= "" then
            return file
        end
    end
    -- Fallback: rank-based FontList iteration (most-regular variant wins)
    local FontList = require("fontlist")
    local best_file, best_rank = nil, math.huge
    for file, info in pairs(FontList.fontinfo or {}) do
        if info and info[1] and info[1].name == name_or_file then
            local fi = info[1]
            local rank = 0
            if fi.bold then rank = rank + 2 end
            if fi.italic then rank = rank + 2 end
            local lbase = (file:match("([^/]+)$") or ""):lower()
            if lbase:find("regular") then
                rank = rank - 1
            elseif lbase:find("bold") or lbase:find("italic") or lbase:find("oblique") then
                rank = rank + 2
            elseif lbase:find("light") or lbase:find("thin") or lbase:find("heavy")
                or lbase:find("black") or lbase:find("medium") or lbase:find("semibold")
                or lbase:find("extrabold") or lbase:find("extralight") or lbase:find("ultralight")
                or lbase:find("demibold") or lbase:find("book") then
                rank = rank + 1
            end
            if rank < best_rank then
                best_file, best_rank = file, rank
            end
        end
    end
    return best_file
end

--- Resolve a font-face string to a concrete file path.
-- Returns `face` unchanged if it isn't a family sentinel.
-- Family sentinels resolve via KOReader's font-family map; unmapped slots fall
-- back to the UI font (matching KOReader's own family fallback semantics).
-- The mapped value may be a display name (as stored by KOReader's font-family
-- fonts menu) or a file path; both are handled.
-- @param face string: a TTF path, or "@family:<key>"
-- @param fallback any: returned only in pathological cases (no UI font registered)
function Utils.resolveFontFace(face, fallback)
    if type(face) ~= "string" then return fallback end
    local family = face:match("^@family:(.+)$")
    if not family then return face end
    local Font = require("ui/font")
    local ui_face = resolveFontNameToFile(Font.fontmap and Font.fontmap.cfont)
                 or (Font.fontmap and Font.fontmap.cfont)
    if family == "ui" then
        return ui_face or fallback
    end
    local map = G_reader_settings:readSetting("cre_font_family_fonts") or {}
    local mapped = map[family]
    if mapped and mapped ~= "" then
        local resolved = resolveFontNameToFile(mapped)
        if resolved then return resolved end
        -- mapping exists but font not installed → fall through to UI font
    end
    return ui_face or fallback
end

--- Build a display label for a font-face value.
-- Returns nil for non-family faces (caller uses its existing display logic).
-- For family faces, returns a table with fields:
--   label       string  e.g. "Serif (Noto Serif)" or "Cursive (UI font)"
--   is_family   bool    always true
--   is_mapped   bool    false when the family has no mapping in KOReader
--   resolved    string  the resolved TTF path (may be UI font for unmapped)
function Utils.getFontFamilyLabel(face)
    if type(face) ~= "string" then return nil end
    local family = face:match("^@family:(.+)$")
    if not family then return nil end
    local human = Utils.FONT_FAMILIES[family] or family
    local resolved = Utils.resolveFontFace(face, nil)
    local FontList = require("fontlist")
    local display
    if resolved then
        -- Prefer the family name (e.g. "Noto Sans") over the localized full name
        -- (e.g. "Noto Sans Medium"), which would include the weight.
        local info = FontList.fontinfo and FontList.fontinfo[resolved]
        display = (info and info[1] and info[1].name)
               or FontList:getLocalizedFontName(resolved, 0)
               or resolved:match("([^/]+)%.[tT][tT][fF]$")
               or resolved
    end
    local is_mapped
    if family == "ui" then
        is_mapped = true
    else
        local map = G_reader_settings:readSetting("cre_font_family_fonts") or {}
        local stored = map[family]
        -- Only "mapped" if the stored name resolves to an installed font.
        is_mapped = stored ~= nil and stored ~= ""
                    and resolveFontNameToFile(stored) ~= nil
    end
    local inner
    if is_mapped then
        inner = display or "?"
    else
        inner = _("UI font")
    end
    return {
        label     = human .. " (" .. inner .. ")",
        is_family = true,
        is_mapped = is_mapped,
        resolved  = resolved,
    }
end

return Utils
