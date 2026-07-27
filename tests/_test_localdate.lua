-- bookends_localdate reads weekday/month translations straight out of
-- KOReader's own `datetime` module rather than declaring new Bookends
-- strings, so it can never drift from what KOReader's own UI shows for the
-- same word. Stub `datetime` with a couple of translated entries (as
-- KOReader's real module would provide after gettext resolves them) plus
-- gaps, to check both the translated and untranslated-fallback paths.
--
-- Usage: lua tests/_test_localdate.lua

package.loaded["datetime"] = {
    shortDayOfWeekTranslation = {
        Mon = "lun", Tue = "mar", Wed = "mié", Thu = "jue",
        Fri = "vie", Sat = "sáb", Sun = "dom",
    },
    shortDayOfWeekToLongTranslation = {
        Mon = "lunes", Sun = "domingo",
        -- Tue/Wed/Thu/Fri/Sat deliberately omitted to exercise the
        -- untranslated-fallback path for full weekday names.
    },
    longMonthTranslation = {
        January = "enero", June = "junio",
    },
    shortMonthTranslation = {
        Jan = "ene",
    },
}

local LocalDate = dofile("bookends_localdate.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "")
            .. " expected=" .. string.format("%q", tostring(expected))
            .. " got=" .. string.format("%q", tostring(actual)), 2)
    end
end

test("weekday: short name translated", function()
    eq(LocalDate.weekday("Mon"), "lun")
    eq(LocalDate.weekday("Sun"), "dom")
end)

test("weekday: full name translated when short->long entry exists", function()
    eq(LocalDate.weekday("Monday"), "lunes")
    eq(LocalDate.weekday("Sunday"), "domingo")
end)

test("weekday: full name falls back to English when untranslated", function()
    eq(LocalDate.weekday("Tuesday"), "Tuesday")
end)

test("month: long and short names translated", function()
    eq(LocalDate.month("January"), "enero")
    eq(LocalDate.month("June"), "junio")
    eq(LocalDate.month("Jan"), "ene")
end)

test("month: falls back to English when untranslated", function()
    eq(LocalDate.month("February"), "February")
    eq(LocalDate.month("Feb"), "Feb")
end)

test("unrecognised name passes through unchanged", function()
    eq(LocalDate.weekday("Someday"), "Someday")
    eq(LocalDate.month("Smarch"), "Smarch")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
