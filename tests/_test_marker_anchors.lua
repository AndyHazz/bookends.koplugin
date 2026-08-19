-- Tests for re-render-proof bar-marker anchors (#99/#100).
--
-- Page indices in a reflowable (CRE) document are a function of the current
-- rendering: change the font size and the same page number lands on different
-- text. Storing a marker as a bare page index therefore makes it drift as soon
-- as the book is re-paginated - which is what #100 reports for the "Today"
-- marker and what #99 sees as a marker sitting further into the book than the
-- reader has actually got.
--
-- Fix under test: capture an xpointer alongside the page (KOReader's own
-- annotation pattern, readerannotation.lua:updatePageNumbers) and re-derive the
-- page from it, so the anchor stays pinned to the text across re-renders.
--
-- Run: cd into the plugin dir, then `lua tests/_test_marker_anchors.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
    screen = { isColorEnabled = function() return false end },
}
package.loaded["datetime"] = { secondsToClockDuration = function() return "" end }
package.loaded["bookends_overlay_widget"] = { BAR_PLACEHOLDER = "\x00BAR\x00" }
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

local Tokens = dofile("bookends_tokens.lua")
package.loaded["bookends_tokens"] = Tokens

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
            .. " got="      .. string.format("%q", tostring(actual)), 2)
    end
end

-- ============================================================================
-- Fake documents
-- ============================================================================

-- Reflowable stand-in: the book is `total_atoms` indivisible units of text and
-- `atoms_per_page` of them fit on a page. Shrinking atoms_per_page models a
-- font-size increase (fewer atoms per page, more pages); the xpointer names the
-- atom, so it survives the change exactly like a real crengine xpointer does.
local function fakeRolling(atoms_per_page, total_atoms)
    local doc = { atoms_per_page = atoms_per_page, atom = 1, file = "/books/x.epub" }
    function doc:pageOf(atom) return math.floor((atom - 1) / self.atoms_per_page) + 1 end
    function doc:getCurrentPage() return self:pageOf(self.atom) end
    function doc:getXPointer() return "atom" .. self.atom end
    function doc:getPageFromXPointer(xp)
        local atom = tonumber(tostring(xp):match("^atom(%d+)$"))
        return atom and self:pageOf(atom) or nil
    end
    function doc:getPageCount() return math.ceil(total_atoms / self.atoms_per_page) end
    return doc
end

-- Paged stand-in (PDF/CBZ): page indices are intrinsic to the file, so there is
-- no xpointer to capture and none is wanted.
local function fakePaged(total_pages)
    local doc = { page = 1, file = "/books/x.cbz" }
    function doc:getCurrentPage() return self.page end
    function doc:getPageCount() return total_pages end
    return doc
end

local function rollingUI(doc) return { rolling = {}, document = doc, view = { state = {} } } end
local function pagedUI(doc)   return { paging  = {}, document = doc, view = { state = {} } } end

-- ============================================================================
-- Tokens.captureMarkerAnchor
-- ============================================================================

test("capture on a reflowable doc records both page and xpointer", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 100
    local a = Tokens.captureMarkerAnchor(rollingUI(doc), doc:getCurrentPage())
    eq(a.page, 10, "page")
    eq(a.xp, "atom100", "xp")
end)

test("capture on a paged doc records the page only", function()
    local doc = fakePaged(40)
    doc.page = 7
    local a = Tokens.captureMarkerAnchor(pagedUI(doc), 7)
    eq(a.page, 7, "page")
    eq(a.xp, nil, "xp")
end)

test("capture tolerates a document with no xpointer support", function()
    local doc = fakePaged(40)
    local a = Tokens.captureMarkerAnchor(rollingUI(doc), 3)
    eq(a.page, 3, "page")
    eq(a.xp, nil, "xp")
end)

test("capture with no page returns nil", function()
    eq(Tokens.captureMarkerAnchor(rollingUI(fakeRolling(10, 100)), nil), nil)
end)

-- ============================================================================
-- Tokens.resolveMarkerAnchor
-- ============================================================================

test("resolve returns the captured page when nothing has been re-rendered", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 100
    local ui = rollingUI(doc)
    eq(Tokens.resolveMarkerAnchor(ui, Tokens.captureMarkerAnchor(ui, doc:getCurrentPage())), 10)
end)

test("resolve re-derives the page after a font-size increase (#100)", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 100
    local ui = rollingUI(doc)
    local anchor = Tokens.captureMarkerAnchor(ui, doc:getCurrentPage())
    eq(anchor.page, 10, "captured page")
    -- Bigger font: 5 atoms per page, so the anchored text is now on page 20.
    doc.atoms_per_page = 5
    eq(Tokens.resolveMarkerAnchor(ui, anchor), 20, "after re-render")
end)

test("resolve re-derives the page after a font-size decrease (#100)", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 100
    local ui = rollingUI(doc)
    local anchor = Tokens.captureMarkerAnchor(ui, doc:getCurrentPage())
    doc.atoms_per_page = 20
    eq(Tokens.resolveMarkerAnchor(ui, anchor), 5, "after re-render")
end)

test("resolve falls back to the stored page for a legacy page-only anchor", function()
    local doc = fakeRolling(10, 1000)
    eq(Tokens.resolveMarkerAnchor(rollingUI(doc), { page = 42 }), 42)
end)

test("resolve accepts a bare number (pre-anchor call sites)", function()
    eq(Tokens.resolveMarkerAnchor(rollingUI(fakeRolling(10, 1000)), 42), 42)
end)

test("resolve returns nil for a nil anchor", function()
    eq(Tokens.resolveMarkerAnchor(rollingUI(fakeRolling(10, 1000)), nil), nil)
end)

test("resolve ignores the xpointer on a paged document", function()
    local doc = fakePaged(40)
    -- A stray xp (e.g. the book was converted, or the setting was hand-edited)
    -- must not be trusted on a doc whose pages are intrinsic.
    eq(Tokens.resolveMarkerAnchor(pagedUI(doc), { page = 7, xp = "atom100" }), 7)
end)

test("resolve falls back to the page when the xpointer no longer resolves", function()
    local doc = fakeRolling(10, 1000)
    eq(Tokens.resolveMarkerAnchor(rollingUI(doc), { page = 9, xp = "not-an-xpointer" }), 9)
end)

test("resolve rejects a non-positive page from the xpointer", function()
    local doc = fakeRolling(10, 1000)
    function doc:getPageFromXPointer() return 0 end
    eq(Tokens.resolveMarkerAnchor(rollingUI(doc), { page = 9, xp = "atom1" }), 9)
end)

-- ============================================================================
-- Bookends:getTodayMarkerPage - the persisted anchor (#99/#100)
-- ============================================================================

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
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(s, t) t = t or {}; return setmetatable(t, { __index = s }) end,
    new    = function(s, t) return setmetatable(t or {}, { __index = s }) end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }
local real_require = _G.require
_G.require = function(name)
    if package.loaded[name] then return package.loaded[name] end
    local ok, mod = pcall(real_require, name)
    if ok then return mod end
    local stub = permissive(); package.loaded[name] = stub; return stub
end

local Bookends = dofile("main.lua")

-- Minimal LuaSettings stand-in over a plain table, plus a call counter so we can
-- assert the once-a-day flush isn't happening on every paint.
local function fakeSettings()
    local store, flushes = {}, 0
    return {
        readSetting = function(_, k) return store[k] end,
        saveSetting = function(_, k, v) store[k] = v end,
        flush = function() flushes = flushes + 1 end,
        _store = store,
        _flushes = function() return flushes end,
    }
end

local function bookendsOn(ui)
    local st = fakeSettings()
    return setmetatable({ ui = ui, today_marker_settings = st }, { __index = Bookends }), st
end

test("today anchor persists an xpointer on first call of the day", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 250
    local be, st = bookendsOn(rollingUI(doc))
    eq(be:getTodayMarkerPage(), 25, "returns current page")
    local entry = st._store.books["/books/x.epub"]
    eq(entry.page, 25, "stored page")
    eq(entry.xp, "atom250", "stored xp")
end)

test("today anchor survives a font-size change within the same day (#100)", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 250
    local be = bookendsOn(rollingUI(doc))
    eq(be:getTodayMarkerPage(), 25, "captured")
    -- Reader moves on, then bumps the font size up: same text, new pagination.
    doc.atom = 400
    doc.atoms_per_page = 5
    eq(be:getTodayMarkerPage(), 50, "anchor tracks the text, not the old index")
end)

test("today anchor is not re-flushed on subsequent calls the same day", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 250
    local be, st = bookendsOn(rollingUI(doc))
    be:getTodayMarkerPage()
    be:getTodayMarkerPage()
    be:getTodayMarkerPage()
    eq(st._flushes(), 1, "flushes")
end)

test("today anchor reads a legacy page-only entry unchanged", function()
    local doc = fakeRolling(10, 1000)
    doc.atom = 400
    local be, st = bookendsOn(rollingUI(doc))
    st._store.books = { ["/books/x.epub"] = { page = 12, date = os.date("%Y-%m-%d") } }
    eq(be:getTodayMarkerPage(), 12)
end)

test("today anchor on a paged document still works without xpointers", function()
    local doc = fakePaged(40)
    doc.page = 9
    local be, st = bookendsOn(pagedUI(doc))
    eq(be:getTodayMarkerPage(), 9, "captured")
    eq(st._store.books["/books/x.cbz"].xp, nil, "no xp stored")
    doc.page = 15
    eq(be:getTodayMarkerPage(), 9, "anchor holds")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
