-- Preset-name generator for the "+ New preset" tile.
-- Pure Lua, no KOReader dependencies — unit-testable via _test_preset_naming.lua.

local PresetNaming = {}

--- Return the first unused name in the sequence: stem, "stem 2", "stem 3", ...
--- Collisions are checked by exact string match against the `name` field of
--- every entry in `presets` (the shape produced by Bookends:readPresetFiles).
function PresetNaming.nextUntitledName(presets, stem)
    local taken = {}
    for _, p in ipairs(presets) do
        taken[p.name] = true
    end
    if not taken[stem] then return stem end
    local i = 2
    while taken[stem .. " " .. i] do
        i = i + 1
    end
    return stem .. " " .. i
end

return PresetNaming
