--[[--
Localize the weekday/month NAMES produced by os.date.

os.date("%A"/"%B") (and the short "%a"/"%b" forms) return English names
from the C library's LC_TIME locale, independent of KOReader's own UI
language — so date tokens render "Monday" even when the interface is
Spanish, unless the device also has the matching glibc locale data
installed (rare on Kindle).

KOReader's own `datetime` module already carries translation tables
(populated via its gettext at load) mapping the English names to the
active UI language, for every language KOReader ships. This module reads
those tables directly instead of declaring new Bookends-side strings, so
results can never drift from what KOReader's own UI shows for the same
word.

Usage:
    local LocalDate = require("bookends_localdate")
    LocalDate.weekday("Monday") --> localized full weekday name
    LocalDate.weekday("Mon")    --> localized short weekday name
    LocalDate.month("January")  --> localized full month name
    LocalDate.month("Jan")      --> localized short month name

Falls back to returning the English name unchanged if `datetime` (or a
given table within it) is unavailable, e.g. in pure-Lua tests.
]]--

local M = {}

local weekday_map, month_map -- English name -> localized name; built lazily

-- No long-weekday translation table exists upstream; derive it from the
-- short -> long map (keyed on the English long name).
local EN_LONG_DAY = {
    Mon = "Monday", Tue = "Tuesday", Wed = "Wednesday", Thu = "Thursday",
    Fri = "Friday", Sat = "Saturday", Sun = "Sunday",
}

local function buildMaps()
    weekday_map, month_map = {}, {}
    local ok, datetime = pcall(require, "datetime")
    if not (ok and type(datetime) == "table") then return end

    for eng, tr in pairs(datetime.shortDayOfWeekTranslation or {}) do
        weekday_map[eng] = tr
    end
    local short_to_long = datetime.shortDayOfWeekToLongTranslation or {}
    for short, eng_long in pairs(EN_LONG_DAY) do
        local tr = short_to_long[short]
        if tr then weekday_map[eng_long] = tr end
    end

    for eng, tr in pairs(datetime.longMonthTranslation or {}) do
        month_map[eng] = tr
    end
    for eng, tr in pairs(datetime.shortMonthTranslation or {}) do
        month_map[eng] = tr
    end
end

--- Translate an English full/short weekday name to the UI language.
function M.weekday(eng_name)
    if not weekday_map then buildMaps() end
    return weekday_map[eng_name] or eng_name
end

--- Translate an English full/short month name to the UI language.
function M.month(eng_name)
    if not month_map then buildMaps() end
    return month_map[eng_name] or eng_name
end

return M
