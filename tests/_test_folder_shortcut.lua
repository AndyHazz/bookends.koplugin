-- Tests for registering the presets folder as a KOReader folder shortcut (#40).
--
-- KOReader's FileManagerShortcuts exposes a static registerShortcut for plugins
-- (filemanagershortcuts.lua:94) and both FileManager and ReaderUI register an
-- instance of the module as ui.folder_shortcuts (readerui.lua:431). That nil
-- check is the whole feature gate: on releases from before the feature landed
-- the field is simply absent. No pcall(require) - which would seed an empty
-- folder_shortcuts table into G_reader_settings as a side effect just by loading
-- the class - and no package.searchpath probing.
--
-- Run: cd into the plugin dir, then `lua tests/_test_folder_shortcut.lua`.

local function permissive()
    local t, mt = {}, nil
    mt = { __index = function() return setmetatable({}, mt) end,
           __call  = function() return setmetatable({}, mt) end }
    return setmetatable(t, mt)
end

package.loaded["bookends_colour"] = {
    parseColorValue = function(v) return v end,
    toStorageShape = function(x) return x end,
}
package.loaded["device"] = { screen = { isColorEnabled = function() return false end } }
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(s, t) t = t or {}; return setmetatable(t, { __index = s }) end,
    new    = function(s, t) return setmetatable(t or {}, { __index = s }) end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }
package.loaded["bookends_tokens"] = { getCurrentPageNumber = function() return 1 end }
-- The presets folder exists in this fixture; the "missing folder" case below
-- swaps this out.
local dir_exists = true
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_, _) return dir_exists and "directory" or nil end,
    mkdir      = function() return true end,
}
_G.require = function(name)
    if package.loaded[name] then return package.loaded[name] end
    local stub = permissive(); package.loaded[name] = stub; return stub
end
_G.G_reader_settings = permissive()

local Bookends = dofile("main.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected=" .. tostring(b) .. " got=" .. tostring(a), 2) end
end

-- A stand-in for the FileManagerShortcuts module instance, recording what a
-- plugin hands it. registerShortcut is a plain function on the class (not a
-- method) and ignores a provider it already knows, mirroring
-- filemanagershortcuts.lua:94 - which is what makes it safe for bookends to
-- register on every document open.
local function fakeShortcuts()
    local rec = { calls = {}, provider_props = {} }
    rec.registerShortcut = function(shortcut)
        if rec.provider_props[shortcut.provider] then return end
        rec.provider_props[shortcut.provider] = shortcut
        table.insert(rec.calls, shortcut)
    end
    return rec
end

local function bookendsWith(folder_shortcuts)
    return setmetatable({
        ui = { folder_shortcuts = folder_shortcuts },
        _preset_dir = "/data/settings/bookends_presets",
        presetDir = function(self) return self._preset_dir end,
    }, { __index = Bookends })
end

test("registers a shortcut pointing at the presets folder", function()
    dir_exists = true
    local sc = fakeShortcuts()
    local be = bookendsWith(sc)
    be:registerFolderShortcut()
    eq(#sc.calls, 1, "one registration")
    local s = sc.calls[1]
    eq(s.provider, "bookends", "provider")
    eq(type(s.name), "string", "has a name")
    eq(s.get(), "/data/settings/bookends_presets", "resolves the presets folder")
end)

test("omits set, so KOReader disables its Set folder button", function()
    -- The presets folder is a fixed location under the settings dir. KOReader
    -- gates that button on `provider_props[provider].set ~= nil`
    -- (filemanagershortcuts.lua:307), so leaving set out is how a read-only
    -- provider is expressed - rather than supplying a no-op set that would
    -- offer relocation and silently do nothing.
    dir_exists = true
    local sc = fakeShortcuts()
    bookendsWith(sc):registerFolderShortcut()
    eq(sc.calls[1].set, nil, "no set")
end)

test("get returns nil when the presets folder does not exist yet", function()
    -- KOReader's add-shortcut dialog does `enabled = folder ~= nil`, so nil is
    -- the graceful answer - better than offering a shortcut to a missing path.
    dir_exists = false
    local sc = fakeShortcuts()
    bookendsWith(sc):registerFolderShortcut()
    eq(sc.calls[1].get(), nil, "no folder")
    dir_exists = true
end)

test("no-op on a KOReader without folder shortcuts", function()
    -- Pre-feature releases have no ui.folder_shortcuts at all.
    local be = bookendsWith(nil)
    be:registerFolderShortcut()  -- must not raise
end)

test("no-op when the module exists but predates registerShortcut", function()
    local be = bookendsWith({})
    be:registerFolderShortcut()  -- must not raise
end)

test("registering twice does not double-register", function()
    dir_exists = true
    local sc = fakeShortcuts()
    local be = bookendsWith(sc)
    be:registerFolderShortcut()
    be:registerFolderShortcut()
    eq(#sc.calls, 1, "one registration")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
