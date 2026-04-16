--- Pure utility helpers shared across the plugin. No KOReader or UI imports.
local Utils = {}

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

return Utils
