-- Dev-box test runner for bookends_updater.lua.
-- Runs pure-Lua (no KOReader) by stubbing every module the updater requires.
-- Usage: cd into the plugin dir, then `lua tests/_test_updater.lua`.

package.loaded["ui/widget/confirmbox"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["device"] = {
    canOpenLink = function() return false end,
    openLink = function() end,
    unpackArchive = function() return true end,
}
package.loaded["ui/widget/infomessage"] = setmetatable({}, { __index = function() return function() end end })
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    scheduleIn = function() end,
    restartKOReader = function() end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }
-- Reached only by the install paths, and only down to the scheduleIn boundary:
-- with the gate now passing on a connected device, the body runs as far as these
-- two requires before parking the real work in the (no-op) scheduler.
package.loaded["datastorage"] = {
    getDataDir     = function() return "/nonexistent/koreader" end,
    getSettingsDir = function() return "/nonexistent/koreader/settings" end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
    mkdir      = function() return true end,
}

-- NetworkMgr stub, faithful to KOReader's real semantics (manager.lua:698/713)
-- so the routing tests below exercise the branch the device would actually take:
--
--   isConnected() -- interface associated and holding an IP
--   isOnline()    -- canResolveHostnames(), i.e. a DNS lookup of
--                    dns.msftncsi.com; false whenever that host can't be
--                    resolved even on a perfectly working connection
--
--   runWhenOnline    -- online: run. not connected: prompt, then run.
--                       connected-but-not-"online": prompt and DROP the callback.
--   runWhenConnected -- connected: run. otherwise: prompt, then run.
--
-- Callbacks are allowed to run: UIManager.scheduleIn is a no-op stub, so the
-- bodies stop before any fetch or download (no http stubs needed).
local net = { run_when_online = 0, run_when_connected = 0, prompts = 0,
              wifi_on = false, connected = false, online = false }
function net.reset(wifi_on, connected, online)
    net.run_when_online, net.run_when_connected, net.prompts = 0, 0, 0
    net.wifi_on, net.connected, net.online = wifi_on, connected, online
end
package.loaded["ui/network/manager"] = {
    isWifiOn    = function() return net.wifi_on end,
    isOnline    = function() return net.online end,
    isConnected = function() return net.connected end,
    runWhenOnline = function(_self, cb)
        net.run_when_online = net.run_when_online + 1
        if net.online then return cb() end
        net.prompts = net.prompts + 1
        if not net.connected then return cb() end
        -- connected but unresolvable: KOReader prompts and forfeits the callback
    end,
    runWhenConnected = function(_self, cb)
        net.run_when_connected = net.run_when_connected + 1
        if net.connected then return cb() end
        net.prompts = net.prompts + 1
        return cb()
    end,
}

local Updater = dofile("bookends_updater.lua")
-- Stub version detection (needs datastorage); irrelevant to network routing.
Updater.getInstalledVersion = function() return "5.0.0" end

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(actual, expected)
    if actual ~= expected then
        error(("expected=%q got=%q"):format(tostring(expected), tostring(actual)), 2)
    end
end

-- Smoke: module loads
test("module loads", function()
    assert(Updater, "Updater module did not load")
    assert(type(Updater.getInstalledVersion) == "function")
end)

test("composeBranchUrl: simple branch", function()
    eq(Updater.composeBranchUrl("master"),
       "https://github.com/AndyHazz/bookends.koplugin/archive/refs/heads/master.zip")
end)

test("composeBranchUrl: branch with slash kept literal", function()
    eq(Updater.composeBranchUrl("feature/v5.2-test"),
       "https://github.com/AndyHazz/bookends.koplugin/archive/refs/heads/feature/v5.2-test.zip")
end)

test("composeBranchUrl: special chars are URL-encoded", function()
    -- Spaces, semicolons, etc. encoded; alnum/-/_/./~// preserved
    eq(Updater.composeBranchUrl("a b;c"),
       "https://github.com/AndyHazz/bookends.koplugin/archive/refs/heads/a%20b%3Bc.zip")
end)

-- Wi-Fi gating (parity with bookshelf issue #77): user-initiated network paths
-- must bring Wi-Fi up rather than bail when it's off...
test("Updater.check brings Wi-Fi up when it is off", function()
    net.reset(false, false, false)
    Updater.check()
    eq(net.run_when_connected, 1)
    eq(net.prompts, 1)
end)
test("Updater.install brings Wi-Fi up when it is off", function()
    net.reset(false, false, false)
    Updater.install("https://example.invalid/x.zip", "5.0.0", "5.1.0")
    eq(net.run_when_connected, 1)
    eq(net.prompts, 1)
end)
test("Updater.installBranch brings Wi-Fi up when it is off (no isWifiOn bail)", function()
    net.reset(false, false, false)
    Updater.installBranch("master")
    eq(net.run_when_connected, 1)
    eq(net.prompts, 1)
end)
test("Updater.installLatestStable brings Wi-Fi up when it is off", function()
    net.reset(false, false, false)
    Updater.installLatestStable()
    eq(net.run_when_connected, 1)
    eq(net.prompts, 1)
end)

-- ...but must never ask to turn on Wi-Fi that is ALREADY on (#101). A connected
-- device whose DNS can't resolve dns.msftncsi.com - Pi-hole/AdGuard blocking
-- Microsoft telemetry domains, a captive portal, or a resolver that isn't up yet
-- moments after wake - reads as isOnline() == false while being perfectly
-- usable. Gating on isOnline there produces a nonsensical "Do you want to turn
-- on Wi-Fi?" box and, worse, KOReader forfeits the callback, so the action the
-- user asked for never runs even if they tap "Turn on".
test("Updater.check does not prompt when connected but DNS won't resolve (#101)", function()
    net.reset(true, true, false)
    Updater.check()
    eq(net.prompts, 0)
end)
test("Updater.install does not prompt when connected but DNS won't resolve (#101)", function()
    net.reset(true, true, false)
    Updater.install("https://example.invalid/x.zip", "5.0.0", "5.1.0")
    eq(net.prompts, 0)
end)
test("Updater.installBranch does not prompt when connected but DNS won't resolve (#101)", function()
    net.reset(true, true, false)
    Updater.installBranch("master")
    eq(net.prompts, 0)
end)
test("Updater.installLatestStable does not prompt when connected but DNS won't resolve (#101)", function()
    net.reset(true, true, false)
    Updater.installLatestStable()
    eq(net.prompts, 0)
end)

-- No path may reach the deprecated runWhenOnline helper any more.
test("no updater path uses runWhenOnline", function()
    for _, run in ipairs({
        function() Updater.check() end,
        function() Updater.install("https://example.invalid/x.zip", "5.0.0", "5.1.0") end,
        function() Updater.installBranch("master") end,
        function() Updater.installLatestStable() end,
    }) do
        net.reset(true, true, false)
        run()
        eq(net.run_when_online, 0)
    end
end)


-- unpackStripRoot: the release/branch zip wraps everything in a single top
-- level dir, which must be stripped so files land directly in the plugin dir.
--
-- This path had no coverage and shipped broken: it called Device:unpackArchive,
-- a wrapper KOReader dropped mid-2026, so every in-app update crashed the
-- reader with "attempt to call method 'unpackArchive' (a nil value)". Nothing
-- caught it because the only assertions here were about network routing.
local function fakeArchiver(entries, opts)
    opts = opts or {}
    local extracted = {}
    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({ err = nil }, Reader) end
    function Reader:open(path)
        if opts.open_fails then self.err = "bad zip"; return false end
        self.opened = path; return true
    end
    function Reader:iterate()
        local i = 0
        return function() i = i + 1; return entries[i] end
    end
    function Reader:extractToPath(key, dest)
        if opts.fail_on and key == opts.fail_on then self.err = "extract boom"; return false end
        extracted[#extracted + 1] = dest; return true
    end
    function Reader:close() self.closed = true end
    package.loaded["ffi/archiver"] = { Reader = Reader }
    return extracted
end

test("unpackStripRoot strips the wrapping directory", function()
    local got = fakeArchiver({
        { path = "bookends.koplugin/" },
        { path = "bookends.koplugin/main.lua" },
        { path = "bookends.koplugin/menu/main_menu.lua" },
        { path = "bookends.koplugin/locale/es.po" },
    })
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/plugins/bookends.koplugin")
    eq(ok, true)
    eq(err, nil)
    eq(#got, 3)
    eq(got[1], "/plugins/bookends.koplugin/main.lua")
    eq(got[2], "/plugins/bookends.koplugin/menu/main_menu.lua")
    eq(got[3], "/plugins/bookends.koplugin/locale/es.po")
end)

test("unpackStripRoot handles a branch zip's versioned root dir", function()
    -- GitHub branch archives wrap in bookends.koplugin-<branch>/ instead.
    local got = fakeArchiver({
        { path = "bookends.koplugin-master/main.lua" },
        { path = "bookends.koplugin-master/_meta.lua" },
    })
    eq(Updater._unpackStripRoot("/tmp/x.zip", "/dest"), true)
    eq(#got, 2)
    eq(got[1], "/dest/main.lua")
end)

test("unpackStripRoot skips the bare root entry, keeps nested paths", function()
    local got = fakeArchiver({
        { path = "root/" },
        { path = "root/a/b/c.lua" },
    })
    eq(Updater._unpackStripRoot("/tmp/x.zip", "/d"), true)
    eq(#got, 1)
    eq(got[1], "/d/a/b/c.lua")
end)

test("unpackStripRoot reports a clean error when the archive won't open", function()
    fakeArchiver({}, { open_fails = true })
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/d")
    eq(ok, false)
    eq(err, "bad zip")
end)

test("unpackStripRoot reports a clean error when an entry fails to extract", function()
    fakeArchiver({ { path = "r/ok.lua" }, { path = "r/bad.lua" }, { path = "r/never.lua" } },
                 { fail_on = "r/bad.lua" })
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/d")
    eq(ok, false)
    eq(err, "extract boom")
end)

test("unpackStripRoot degrades cleanly with no extractor available", function()
    -- Must return an error rather than raise: the update path is also the
    -- recovery path, so a crash here would leave users stuck on the broken
    -- version with no way to reach the fix.
    package.loaded["ffi/archiver"] = nil
    local real = _G.require
    _G.require = function(n)
        if n == "ffi/archiver" then error("no such module") end
        return real(n)
    end
    local ok, err = Updater._unpackStripRoot("/tmp/x.zip", "/d")
    _G.require = real
    eq(ok, false)
    eq(err, "archive extractor unavailable")
end)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
