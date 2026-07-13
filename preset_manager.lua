--- Preset file I/O, serialization, validation, and migration.
-- Kept as methods on Bookends so existing call sites (`self:readPresetFiles()`)
-- keep working. Stateless helpers (serialize, load, validate) are module-local.

local PresetManager = {}

--- Serialize a plain Lua table to a string that evaluates back to an equivalent table.
-- Sparse integer arrays are emitted with explicit `[N] =` keys so gaps round-trip correctly.
local function serializeTable(tbl, indent)
    indent = indent or ""
    local next_indent = indent .. "    "
    local parts = {}
    table.insert(parts, "{\n")

    local int_keys = {}
    local str_keys = {}
    for k in pairs(tbl) do
        if type(k) == "number" and k == math.floor(k) and k >= 1 then
            table.insert(int_keys, k)
        else
            table.insert(str_keys, tostring(k))
        end
    end
    table.sort(int_keys)
    table.sort(str_keys)

    local function serializeValue(v)
        if type(v) == "table" then
            return serializeTable(v, next_indent)
        elseif type(v) == "string" then
            return string.format("%q", v)
        elseif type(v) == "boolean" then
            return tostring(v)
        elseif type(v) == "number" then
            return tostring(v)
        else
            return string.format("%q", tostring(v))
        end
    end

    -- Detect sparse integer arrays (gaps in keys) — must use explicit [N] = syntax
    local is_contiguous = #int_keys > 0 and int_keys[#int_keys] == #int_keys
    for _, k in ipairs(int_keys) do
        if is_contiguous then
            table.insert(parts, next_indent .. serializeValue(tbl[k]) .. ",\n")
        else
            table.insert(parts, next_indent .. "[" .. k .. "] = " .. serializeValue(tbl[k]) .. ",\n")
        end
    end
    for _, k in ipairs(str_keys) do
        local key_str
        if k:match("^[%a_][%w_]*$") then
            key_str = k
        else
            key_str = string.format("[%q]", k)
        end
        table.insert(parts, next_indent .. key_str .. " = " .. serializeValue(tbl[k]) .. ",\n")
    end

    table.insert(parts, indent .. "}")
    return table.concat(parts)
end
PresetManager.serializeTable = serializeTable

--- Detect whether a preset payload uses any colour (hex) values.
--- Walks the table recursively; returns true on the first:
---   (a) `{hex = "#..."}` field — colour stored as a setting;
---   (b) inline `[c=#RGB]` or `[c=#RRGGBB]` tag inside a string value —
---       colour authored inside a line's text (e.g. format strings in
---       `positions.<pos>.lines`).
--- Greyscale-only authoring (`{grey = N}` fields, `[c=N]` percent tags)
--- does NOT flag the preset, so a preset that uses only neutrals stays
--- portable to greyscale devices without a "uses colour" annotation.
local function hasColour(t)
    local tt = type(t)
    if tt == "string" then
        -- Inline [c=#RGB] or [c=#RRGGBB] — but only flag if the hex is a
        -- real colour. Greyscale hex like [c=#222] (== [c=#222222]) is
        -- visually pure grey; treating it as colour would misfire on
        -- presets that happen to use hex syntax for a neutral.
        local Colour = require("bookends_colour")
        for hex in t:gmatch("%[c=(#%x%x%x)%]") do
            if Colour.isColourHex(hex) then return true end
        end
        for hex in t:gmatch("%[c=(#%x%x%x%x%x%x)%]") do
            if Colour.isColourHex(hex) then return true end
        end
        return false
    end
    if tt ~= "table" then return false end
    -- {hex=…} storage: only flag when the hex is a real colour. A preset
    -- authored pre-toStorageShape could have {hex="#404040"}; same visual
    -- result as {grey=64}, shouldn't light up the flag.
    if type(t.hex) == "string" and t.hex ~= "" then
        local Colour = require("bookends_colour")
        if Colour.isColourHex(t.hex) then return true end
        -- grey hex stored in a {hex=…} field: keep walking siblings but
        -- don't flag on this one.
    end
    for _k, v in pairs(t) do
        if hasColour(v) then return true end
    end
    return false
end
PresetManager.hasColour = hasColour

--- Load a preset .lua file in a sandboxed environment.
--- The file can only return a plain data table — no access to os, io, require, etc.
local function loadPresetFile(path)
    local fn, err = loadfile(path)
    if not fn then return nil, "parse error: " .. tostring(err) end
    setfenv(fn, {})
    local ok, result = pcall(fn)
    if not ok then return nil, "runtime error: " .. tostring(result) end
    if type(result) ~= "table" then return nil, "expected table, got " .. type(result) end
    return result
end
PresetManager.loadPresetFile = loadPresetFile

--- Validate that a preset table has the expected structure.
--- Returns the (possibly cleaned) table, or nil + error string.
local function validatePreset(data)
    -- Allow only known top-level keys (unknown ones accepted silently for forward compat)
    local EXPECTED_TYPES = {
        name = "string",
        description = "string",
        author = "string",
        enabled = "boolean",
        defaults = "table",
        positions = "table",
        progress_bars = "table",
        bar_colors = "table",
        tick_width_multiplier = "number",
        tick_height_pct = "number",
    }

    for key, val in pairs(data) do
        local expected = EXPECTED_TYPES[key]
        if expected and type(val) ~= expected then
            return nil, "field '" .. key .. "' should be " .. expected .. ", got " .. type(val)
        end
    end

    if data.positions then
        local VALID_POS = { tl=true, tc=true, tr=true, bl=true, bc=true, br=true }
        for key, val in pairs(data.positions) do
            if not VALID_POS[key] then
                return nil, "unknown position key: " .. tostring(key)
            end
            if type(val) ~= "table" then
                return nil, "position '" .. key .. "' should be table, got " .. type(val)
            end
            if val.lines and type(val.lines) ~= "table" then
                return nil, "position '" .. key .. "'.lines should be table"
            end
        end
    end

    return data
end
PresetManager.validatePreset = validatePreset

--- Low-level write: serialize and save to a path.
local function writePresetContents(path, name, preset_data)
    local fout = io.open(path, "w")
    if fout then
        fout:write("-- Bookends preset: " .. name .. "\n")
        fout:write("return " .. serializeTable(preset_data) .. "\n")
        fout:close()
        return true
    end
    return false
end

-- Remove `filename` from manual_active_preset_filename if it's the
-- current value. Mirrors pruneFromCycle (below, inside attach()) for the
-- #87 manual-default pointer: this preset is gone, so it can no longer be
-- anyone's default. Kept module-level (rather than alongside its sibling
-- inside attach()) so it's testable via dofile() without needing a
-- Bookends instance to attach() onto first.
--
-- Deliberately clears to nil rather than falling back to another remaining
-- preset, unlike the active_preset_filename delete-fallback in
-- preset_manager_modal.lua's _delete handler. That asymmetry is intentional:
-- active_preset_filename must always point at something applied, but "no
-- manual default set yet" is a normal, valid state for
-- manual_active_preset_filename -- the auto-rule path (decideFormatPresetAction)
-- already treats a nil manual default as "nothing to restore to" and copes fine.
local function pruneManualDefault(self_bookends, filename)
    if not filename then return end
    if self_bookends.settings:readSetting("manual_active_preset_filename") == filename then
        self_bookends.settings:delSetting("manual_active_preset_filename")
    end
end
PresetManager.pruneManualDefault = pruneManualDefault

-- Update manual_active_preset_filename in place on rename. Mirrors
-- renameInCycle for the #87 manual-default pointer.
local function renameManualDefault(self_bookends, old_filename, new_filename)
    if not old_filename or not new_filename or old_filename == new_filename then return end
    if self_bookends.settings:readSetting("manual_active_preset_filename") == old_filename then
        self_bookends.settings:saveSetting("manual_active_preset_filename", new_filename)
    end
end
PresetManager.renameManualDefault = renameManualDefault

-- Remove any format_preset_rules entry pointing at `filename` (#87).
-- HIDDEN entries are untouched since they don't reference a file.
local function pruneFormatRules(self_bookends, filename)
    if not filename then return end
    local rules = self_bookends.settings:readSetting("format_preset_rules") or {}
    local changed = false
    for ext, target in pairs(rules) do
        if target == filename then
            rules[ext] = nil
            changed = true
        end
    end
    if changed then
        self_bookends.settings:saveSetting("format_preset_rules", rules)
    end
end
PresetManager.pruneFormatRules = pruneFormatRules

-- Update every format_preset_rules entry pointing at old_filename (#87).
local function renameFormatRules(self_bookends, old_filename, new_filename)
    if not old_filename or not new_filename or old_filename == new_filename then return end
    local rules = self_bookends.settings:readSetting("format_preset_rules") or {}
    local changed = false
    for ext, target in pairs(rules) do
        if target == old_filename then
            rules[ext] = new_filename
            changed = true
        end
    end
    if changed then
        self_bookends.settings:saveSetting("format_preset_rules", rules)
    end
end
PresetManager.renameFormatRules = renameFormatRules

--- Attach Bookends:methodName variants that use the helpers above.
function PresetManager.attach(Bookends)
    -- Keep class-method references for backwards compatibility with any external code
    Bookends.serializeTable = serializeTable
    Bookends.loadPresetFile = loadPresetFile
    Bookends.validatePreset = validatePreset

    function Bookends:presetDir()
        if not self._preset_dir then
            local DataStorage = require("datastorage")
            -- Resolve to absolute via getFullDataDir(), which expands "."
            -- to lfs.currentdir(). Kobo's launcher runs without KO_HOME, so
            -- DataStorage falls back to "." — caching the relative path
            -- means a later cwd shift would break every preset file lookup.
            local data_dir = DataStorage:getFullDataDir() or DataStorage:getDataDir()
            self._preset_dir = data_dir .. "/settings/bookends_presets"
        end
        return self._preset_dir
    end

    -- Remove `filename` from the preset_cycle setting if present.
    -- Used by deletePresetFile and renamePresetFile so any cycle entries
    -- referring to a now-gone file are pruned at the source — preventing
    -- the "first cycle works, every subsequent fails" symptom that caused
    -- issue #31, where a stale `preset_cycle` entry pointed at a deleted
    -- preset file.
    local function pruneFromCycle(self_bookends, filename)
        if not filename then return end
        local cycle = self_bookends.settings:readSetting("preset_cycle") or {}
        local changed = false
        for i = #cycle, 1, -1 do
            if cycle[i] == filename then
                table.remove(cycle, i)
                changed = true
            end
        end
        if changed then
            self_bookends.settings:saveSetting("preset_cycle", cycle)
        end
    end

    -- Replace `old_filename` with `new_filename` in preset_cycle (in place,
    -- preserving cycle position). No-op if old_filename isn't present.
    local function renameInCycle(self_bookends, old_filename, new_filename)
        if not old_filename or not new_filename or old_filename == new_filename then return end
        local cycle = self_bookends.settings:readSetting("preset_cycle") or {}
        local changed = false
        for i, entry in ipairs(cycle) do
            if entry == old_filename then
                cycle[i] = new_filename
                changed = true
            end
        end
        if changed then
            self_bookends.settings:saveSetting("preset_cycle", cycle)
        end
    end

    function Bookends:sanitizePresetFilename(name)
        local sanitized = name:lower()
            :gsub("[^%w_]", "_")
            :gsub("_+", "_")
            :gsub("^_", "")
            :gsub("_$", "")
        if sanitized == "" then sanitized = "preset" end
        return sanitized .. ".lua"
    end

    function Bookends:ensurePresetDir()
        local lfs = require("libs/libkoreader-lfs")
        local dir = self:presetDir()
        if lfs.attributes(dir, "mode") ~= "directory" then
            lfs.mkdir(dir)
        end
        return dir
    end

    --- Invalidate the in-memory preset-files cache. Called by every
    --- mutator path on this object so the next readPresetFiles() picks up
    --- the new state. Cache survives only the plugin process lifetime;
    --- a KOReader restart always rebuilds.
    function Bookends:invalidatePresetCache()
        self._preset_files_cache = nil
    end

    -- Shallow-copy the cached entries so callers can table.insert / table.sort
    -- freely (e.g. the modal appending a synthetic "+ New blank preset" tile,
    -- or sortedLocalPresets reordering by mtime) without polluting the cache
    -- for the next reader. Entry tables are still shared, but entry-level
    -- mutations only happen inside mutator flows that invalidate the cache
    -- anyway (rename / write / delete / update). Cost: a few dozen ref-copies,
    -- vs. the loadfile + sandbox + parse + validate per file the cache avoids.
    local function copyEntries(src)
        local out = {}
        for i = 1, #src do out[i] = src[i] end
        return out
    end

    function Bookends:readPresetFiles()
        if self._preset_files_cache then
            return copyEntries(self._preset_files_cache)
        end
        local lfs = require("libs/libkoreader-lfs")
        local logger = require("logger")
        local dir = self:presetDir()
        local presets = {}

        if lfs.attributes(dir, "mode") ~= "directory" then
            self._preset_files_cache = presets
            return copyEntries(presets)
        end

        for f in lfs.dir(dir) do
            if f:match("%.lua$") then
                local path = dir .. "/" .. f
                local data, err = loadPresetFile(path)
                if not data then
                    logger.warn("bookends: skipping preset", f, "—", err)
                else
                    data, err = validatePreset(data)
                    if not data then
                        logger.warn("bookends: invalid preset", f, "—", err)
                    else
                        local name = data.name or f:gsub("%.lua$", ""):gsub("_", " ")
                        table.insert(presets, {
                            name = name,
                            filename = f,
                            preset = data,
                            -- Memoise hasColour at parse time so card
                            -- renderers don't re-walk the preset table on
                            -- every visible slot, every refresh. Falls in
                            -- step with the readPresetFiles cache: stays
                            -- valid until invalidatePresetCache() runs.
                            has_colour = hasColour(data),
                        })
                    end
                end
            end
        end

        table.sort(presets, function(a, b) return a.name < b.name end)
        self._preset_files_cache = presets
        return copyEntries(presets)
    end

    function Bookends:writePresetFile(name, preset_data)
        local dir = self:ensurePresetDir()
        local lfs = require("libs/libkoreader-lfs")

        preset_data.name = name

        local base = self:sanitizePresetFilename(name)
        local filename = base
        local counter = 2
        while lfs.attributes(dir .. "/" .. filename, "mode") == "file" do
            filename = base:gsub("%.lua$", "_" .. counter .. ".lua")
            counter = counter + 1
        end

        writePresetContents(dir .. "/" .. filename, name, preset_data)
        self:invalidatePresetCache()
        return filename
    end

    function Bookends:deletePresetFile(filename)
        local path = self:presetDir() .. "/" .. filename
        os.remove(path)
        pruneFromCycle(self, filename)
        pruneManualDefault(self, filename)
        pruneFormatRules(self, filename)
        self:invalidatePresetCache()
    end

    function Bookends:renamePresetFile(old_filename, new_name)
        local dir = self:presetDir()
        local old_path = dir .. "/" .. old_filename

        local data = loadPresetFile(old_path)
        if not data then return nil end

        local new_filename = self:writePresetFile(new_name, data)

        if new_filename ~= old_filename then
            os.remove(old_path)
            renameInCycle(self, old_filename, new_filename)
            renameManualDefault(self, old_filename, new_filename)
            renameFormatRules(self, old_filename, new_filename)
        end

        -- writePresetFile already invalidated; renaming the file on disk
        -- invalidates the prior entry's filename too, so re-invalidate.
        self:invalidatePresetCache()
        return new_filename
    end

    -- Overwrites `filename` with preset_data (or the current overlay config when
    -- preset_data is nil). Unlike writePresetFile, this does NOT auto-rename on
    -- collision — it's the "update an existing preset" path.
    function Bookends:updatePresetFile(filename, name, preset_data)
        local path = self:presetDir() .. "/" .. filename
        preset_data = preset_data or self:buildPreset()
        preset_data.name = name
        local ok = writePresetContents(path, name, preset_data)
        self:invalidatePresetCache()
        return ok
    end

    function Bookends:migratePresetsToFiles()
        local embedded = self.settings:readSetting("presets")
        if not embedded or not next(embedded) then return end

        self:ensurePresetDir()

        for name, preset_data in pairs(embedded) do
            self:writePresetFile(name, preset_data)
        end

        self.settings:delSetting("presets")
        self.settings:delSetting("last_cycled_preset")
        self.settings:flush()
    end

    --- Read the filename of the currently-open Personal preset, or nil.
    function Bookends:getActivePresetFilename()
        return self.settings:readSetting("active_preset_filename")
    end

    --- Human-readable name of the active preset (the `name` field from its
    --- file), or nil when no preset is active or the file can't be read.
    function Bookends:getActivePresetName()
        local filename = self:getActivePresetFilename()
        if not filename then return nil end
        for _, p in ipairs(self:readPresetFiles()) do
            if p.filename == filename then return p.name end
        end
        return nil
    end

    --- Set (or clear with nil) the active preset file.
    function Bookends:setActivePresetFilename(filename)
        if filename then
            self.settings:saveSetting("active_preset_filename", filename)
        else
            self.settings:delSetting("active_preset_filename")
        end
    end

    --- The user has explicitly chosen `filename` as their default preset,
    --- distinct from a transient format-rule auto-override (#87). Use when
    --- the preset's data is already loaded elsewhere in the current flow
    --- (e.g. a preview) and only the active pointer needs updating.
    function Bookends:setManualActivePreset(filename)
        self:setActivePresetFilename(filename)
        if filename then
            self.settings:saveSetting("manual_active_preset_filename", filename)
        else
            self.settings:delSetting("manual_active_preset_filename")
        end
    end

    --- Given a preset filename, load it + set it active. Returns true on success.
    function Bookends:applyPresetFile(filename)
        local path = self:presetDir() .. "/" .. filename
        local data, err = loadPresetFile(path)
        if not data then return false, err end
        data = validatePreset(data)
        if not data then return false, "validation failed" end
        local ok, lerr = pcall(self.loadPreset, self, data)
        if not ok then return false, lerr end
        self:setActivePresetFilename(filename)
        return true
    end

    --- Like applyPresetFile, but also remembers `filename` as the user's
    --- manual default (#87). Use for explicit choices that need the
    --- preset's data loaded (not already loaded elsewhere), e.g. the
    --- cycle gesture, creating a new blank preset.
    function Bookends:applyManualPresetFile(filename)
        local ok, err = self:applyPresetFile(filename)
        if ok then
            self.settings:saveSetting("manual_active_preset_filename", filename)
        end
        return ok, err
    end

    --- Serialize current overlay state to the active preset file.
    --- No-op if there's no active preset or if previewing.
    function Bookends:autosaveActivePreset()
        if self._previewing then return end
        local filename = self:getActivePresetFilename()
        if not filename then return end
        self:ensurePresetDir()
        local path = self:presetDir() .. "/" .. filename
        local preset_data = self:buildPreset()
        -- Preserve metadata from the on-disk file if present.
        local existing = loadPresetFile(path)
        if existing then
            preset_data.name = existing.name or preset_data.name
            preset_data.description = existing.description
            preset_data.author = existing.author
        end
        writePresetContents(path, preset_data.name or filename, preset_data)
        self:invalidatePresetCache()
    end
end

return PresetManager
