-- [if:plugin_content] and [if:plugin_content{<plugin>}] (#125): show a
-- plugin's footer contribution (e.g. readtimer's countdown) only while it has
-- something to say, and fall back to other content otherwise.
--
-- Usage: lua tests/_test_plugin_content_conditional.lua

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
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

-- gatherPluginContent identifies a callback's owner from its source path, so
-- each fake callback is compiled under a chunk name inside <name>.koplugin/.
local timer_text = ""
local function pluginCallback(plugin, body)
    return load(body, "@/koreader/plugins/" .. plugin .. ".koplugin/main.lua", "t",
        { get_timer = function() return timer_text end })()
end
local readtimer_cb = pluginCallback("readtimer", "return function() return get_timer() end")
local bluetooth_cb = pluginCallback("kobo", "return function() return 'BT' end")

local ui = {
    document = {
        file              = "/library/book.epub",
        getCurrentPage    = function() return 100 end,
        hasHiddenFlows    = function() return false end,
        getPageCount      = function() return 500 end,
        getTotalPagesLeft = function() return 400 end,
    },
    toc = {
        toc = { { page = 1, title = "One", depth = 1 },
                { page = 50, title = "Two", depth = 1 } },
        getPreviousChapter  = function() return 50 end,
        isChapterStart      = function() return false end,
        getNextChapter      = function() return 200 end,
        getChapterPagesLeft = function() return 100 end,
        getChapterPagesDone = function() return 50 end,
        getChapterPageCount = function() return 150 end,
        getTocTitleByPage   = function() return "Two" end,
        getMaxDepth         = function() return 1 end,
    },
    statistics = { avg_time = 30 },
    view = {
        state = { page = 100 },
        footer = {
            additional_footer_content = { readtimer_cb },
            genSeparator = function() return " | " end,
        },
    },
}

local function expand(fmt, ctx)
    return Tokens.expand(fmt, ui, 0, 0, false, 2, nil, ctx)
end

test("[if:plugin_content{readtimer}] is truthy while the timer runs", function()
    timer_text = "12:34"
    eq(expand("[if:plugin_content{readtimer}]%plugin_content{readtimer}[else]clock[/if]"), "12:34")
end)

test("[if:plugin_content{readtimer}] falls to [else] when the timer is idle", function()
    timer_text = ""
    eq(expand("[if:plugin_content{readtimer}]%plugin_content{readtimer}[else]clock[/if]"), "clock")
end)

test("the filter ignores other plugins' content", function()
    ui.view.footer.additional_footer_content = { readtimer_cb, bluetooth_cb }
    timer_text = ""
    eq(expand("[if:plugin_content{readtimer}]timer[else]clock[/if]"), "clock")
    eq(expand("[if:plugin_content{kobo}]bt[else]none[/if]"), "bt")
    ui.view.footer.additional_footer_content = { readtimer_cb }
end)

test("bare [if:plugin_content] reads any plugin's content", function()
    timer_text = "5:00"
    eq(expand("[if:plugin_content]on[else]off[/if]"), "on")
    timer_text = ""
    eq(expand("[if:plugin_content]on[else]off[/if]"), "off")
end)

test("the issue's multi-line template", function()
    timer_text = "9:59"
    local fmt = "[if:plugin_content{readtimer}]\n%plugin_content{readtimer}\n[else]\nclock\n[/if]"
    eq(expand(fmt), "\n9:59\n")
end)

test("no footer at all reads false, not an error", function()
    local footer = ui.view.footer
    ui.view.footer = nil
    eq(expand("[if:plugin_content{readtimer}]timer[else]clock[/if]"), "clock")
    ui.view.footer = footer
end)

test("a shared paint state resolves each line's own filter", function()
    ui.view.footer.additional_footer_content = { readtimer_cb, bluetooth_cb }
    timer_text = ""
    local ctx = {}
    eq(expand("[if:plugin_content{kobo}]bt[/if]", ctx), "bt")
    eq(expand("[if:plugin_content{readtimer}]timer[else]clock[/if]", ctx), "clock")
    ui.view.footer.additional_footer_content = { readtimer_cb }
end)

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
