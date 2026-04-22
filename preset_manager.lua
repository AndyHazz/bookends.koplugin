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
--- Walks the table recursively; returns true on the first `hex` key hit.
--- Permissive: any non-empty `hex` string field flags the preset as
--- colour-authored (gallery UI treats false positives as benign — an
--- unused `hex` key is still authoring intent).
local function hasColour(t)
    if type(t) ~= "table" then return false end
    if type(t.hex) == "string" and t.hex ~= "" then return true end
    for _k, v in pairs(t) do
        if type(v) == "table" and hasColour(v) then return true end
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

--- Attach Bookends:methodName variants that use the helpers above.
function PresetManager.attach(Bookends)
    -- Keep class-method references for backwards compatibility with any external code
    Bookends.serializeTable = serializeTable
    Bookends.loadPresetFile = loadPresetFile
    Bookends.validatePreset = validatePreset

    function Bookends:presetDir()
        if not self._preset_dir then
            local DataStorage = require("datastorage")
            self._preset_dir = DataStorage:getSettingsDir() .. "/bookends_presets"
        end
        return self._preset_dir
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

    function Bookends:readPresetFiles()
        local lfs = require("libs/libkoreader-lfs")
        local logger = require("logger")
        local dir = self:presetDir()
        local presets = {}

        if lfs.attributes(dir, "mode") ~= "directory" then
            return presets
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
                        })
                    end
                end
            end
        end

        table.sort(presets, function(a, b) return a.name < b.name end)
        return presets
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
        return filename
    end

    function Bookends:deletePresetFile(filename)
        local path = self:presetDir() .. "/" .. filename
        os.remove(path)
    end

    function Bookends:renamePresetFile(old_filename, new_name)
        local dir = self:presetDir()
        local old_path = dir .. "/" .. old_filename

        local data = loadPresetFile(old_path)
        if not data then return nil end

        local new_filename = self:writePresetFile(new_name, data)

        if new_filename ~= old_filename then
            os.remove(old_path)
        end

        return new_filename
    end

    -- Overwrites `filename` with preset_data (or the current overlay config when
    -- preset_data is nil). Unlike writePresetFile, this does NOT auto-rename on
    -- collision — it's the "update an existing preset" path.
    function Bookends:updatePresetFile(filename, name, preset_data)
        local path = self:presetDir() .. "/" .. filename
        preset_data = preset_data or self:buildPreset()
        preset_data.name = name
        writePresetContents(path, name, preset_data)
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
    end
end

return PresetManager
