-- A nil frontlight warmth must not take the overlay down.
--
-- Reported crash, at the moment the reader opened:
--   powerd.lua:232: attempt to perform arithmetic on local 'ko_warmth'
--     powerd.lua:232 toNativeWarmth
--     bookends_tokens.lua buildConditionState
--     main.lua paintTo
--
-- Cause is in KOReader, and it is not transient. KindlePowerD:frontlightWarmthHW
-- reads the level over lipc and has NO else branch, so with no lipc handle it
-- returns nil and powerd.fl_warmth stays nil for the whole session. No lipc is
-- exactly what a framework-stopped Kindle looks like (the --framework_stop cold
-- launch). frontlightWarmth() then returns nil on a device whose
-- hasNaturalLight() is true, and every warmth reader gets nil.
--
-- Note the asymmetry that hid this: frontlightIntensityHW DOES have an else
-- branch (sysfs), so intensity is never nil and KOReader's own boot path,
-- which only compares intensity, is unaffected.
--
-- The vendored Semantics.* functions already nil-guard, so %warmth_pct and
-- %warmth_icon degrade correctly. These tests cover the sites that do
-- arithmetic on the value BEFORE it reaches Semantics.
--
-- Usage: lua tests/_test_warmth_nil.lua

-- The power device under test, swapped per case.
local powerd

-- Faithful to KOReader: BasePowerD:toNativeWarmth is a bare division, which is
-- where the reported error is raised. A stub that nil-guarded here would test
-- nothing.
local function makePowerD(warmth)
    return {
        warmth_scale = 100 / 24,   -- a PW5's 0-24 native scale
        fl_max = 24,
        getCapacity = function() return 50 end,
        isCharging = function() return false end,
        isCharged = function() return false end,
        frontlightIntensity = function() return 8 end,
        frontlightWarmth = function() return warmth end,
        toNativeWarmth = function(self, ko_warmth)
            return math.floor(ko_warmth / self.warmth_scale + 0.5)
        end,
    }
end

package.loaded["device"] = {
    getPowerDevice = function() return powerd end,
    isKindle = function() return true end,
    hasNaturalLight = function() return true end,
    hasFrontlight = function() return true end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function() return "" end,
}
package.loaded["bookends_overlay_widget"] = { BAR_PLACEHOLDER = "\x00BAR\x00" }
package.loaded["bookends_i18n"] = { gettext = function(str) return str end }
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
    readSetting = function() return "classic" end,
    isTrue = function() return false end,
})

local Tokens = dofile("bookends_tokens.lua")

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

local ui = {
    document = {
        file              = "/library/book.epub",
        getProps          = function() return {} end,
        getCurrentPage    = function() return 100 end,
        hasHiddenFlows    = function() return false end,
        getPageCount      = function() return 500 end,
        getTotalPagesLeft = function() return 400 end,
    },
    toc = {
        toc = { { page = 1, title = "One", depth = 1 } },
        getPreviousChapter  = function() return 50 end,
        isChapterStart      = function() return false end,
        getNextChapter      = function() return 200 end,
        getChapterPagesLeft = function() return 100 end,
        getChapterPagesDone = function() return 50 end,
        getChapterPageCount = function() return 150 end,
        getTocTitleByPage   = function() return "One" end,
        getMaxDepth         = function() return 1 end,
    },
    statistics = { avg_time = 30 },
    view = { state = { page = 100 } },
}

local function expand(fmt)
    return Tokens.expand(fmt, ui, 100, 5, false, 2, nil)
end

-- ── nil warmth: degrade, never raise ───────────────────────────────────────

test("%warmth renders empty when the device cannot report warmth", function()
    powerd = makePowerD(nil)
    eq(expand("%warmth"), "")
end)

test("%warmth_pct and %warmth_icon stay empty too", function()
    powerd = makePowerD(nil)
    eq(expand("%warmth_pct"), "")
    eq(expand("%warmth_icon"), "")
end)

test("a warmth CONDITIONAL does not raise when warmth is nil", function()
    powerd = makePowerD(nil)
    -- The reported crash: buildConditionState reads warmth for any template
    -- carrying a device conditional, so the whole paint died, not just a token.
    eq(expand("[if:warmth>10]warm[else]cool[/if]"), "cool")
    eq(expand("[if:warmth]set[else]unset[/if]"), "unset")
end)

test("an unrelated conditional still paints when warmth is nil", function()
    powerd = makePowerD(nil)
    -- The point of the bug: a template that never mentions warmth was taken
    -- down with it, because the condition state is built as a whole.
    eq(expand("[if:batt<90]%page_num[/if]"), "100")
end)

test("no power device at all is still safe", function()
    powerd = nil
    eq(expand("%warmth"), "")
    eq(expand("[if:warmth>10]warm[else]cool[/if]"), "cool")
end)

-- ── a working device must be unaffected ────────────────────────────────────

test("%warmth still reports the device-native value", function()
    powerd = makePowerD(50)      -- KOReader scale 0-100
    eq(expand("%warmth"), "12")  -- native 0-24 on a PW5
end)

test("%warmth_pct still reports the 0-100 value", function()
    powerd = makePowerD(50)
    eq(expand("%warmth_pct"), "50%")
end)

test("warmth conditionals still compare the native value", function()
    powerd = makePowerD(50)
    eq(expand("[if:warmth>10]warm[else]cool[/if]"), "warm")
    eq(expand("[if:warmth_pct>40]bright[else]dim[/if]"), "bright")
end)

test("zero warmth is a value, not an absence", function()
    powerd = makePowerD(0)
    eq(expand("%warmth"), "0")
    eq(expand("%warmth_pct"), "0%")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
