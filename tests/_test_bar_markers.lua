-- Tests for bar markers (#77): Bookends:buildBarMarkers maps the per-line
-- marker config (top/bottom: type/size/offset/colour) plus the chosen bar_info's
-- session_frac / book_open_frac into the renderer-facing markers table.
--
-- Run: cd into the plugin dir, then `lua tests/_test_bar_markers.lua`.

local function permissive()
    local t, mt = {}, nil
    mt = { __index = function() return setmetatable({}, mt) end,
           __call  = function() return setmetatable({}, mt) end }
    return setmetatable(t, mt)
end

-- Specific stubs that buildBarMarkers depends on (Colour + Device.screen).
-- parseColorValue passes the stored value straight through so we can assert it.
package.loaded["bookends_colour"] = {
    parseColorValue = function(v) return v end,
    toStorageShape = function(x) return x end,
}
package.loaded["device"] = { screen = { isColorEnabled = function() return false end } }
package.loaded["ui/widget/container/widgetcontainer"] = {
    extend = function(self, t) t = t or {}; return setmetatable(t, { __index = self }) end,
    new    = function(self, t) return setmetatable(t or {}, { __index = self }) end,
}
package.loaded["bookends_i18n"] = { gettext = function(s) return s end }
-- Stand-ins for the Tokens helpers main.lua reaches for. The real
-- capture/resolve pair (xpointer anchoring for #99/#100) has its own suite in
-- _test_marker_anchors.lua; here they only need to behave well enough for the
-- persistence semantics below (write once per day, one entry per book).
package.loaded["bookends_tokens"] = {
    getCurrentPageNumber = function(ui)
        if ui and ui.document and ui.document.getCurrentPage then
            local ok, p = pcall(function() return ui.document:getCurrentPage() end)
            if ok and p then return p end
        end
        return ui and ui.view and ui.view.state and ui.view.state.page
    end,
    captureMarkerAnchor = function(_, pageno)
        if not pageno then return nil end
        return { page = pageno }
    end,
    resolveMarkerAnchor = function(_, anchor)
        if not anchor then return nil end
        if type(anchor) == "number" then return anchor end
        return anchor.page
    end,
}
_G.require = function(name)
    if package.loaded[name] then return package.loaded[name] end
    local stub = permissive(); package.loaded[name] = stub; return stub
end
_G.G_reader_settings = permissive()

local Bookends = dofile("main.lua")
local self = setmetatable({}, { __index = Bookends })

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected=" .. tostring(b) .. " got=" .. tostring(a), 2) end
end

local SRC = { session_frac = 0.25, book_open_frac = 0.10 }

test("top=session resolves to session_frac with explicit size/offset/style/colour", function()
    local m = self:buildBarMarkers(
        { top = { type = "session", size = 150, offset = 3, style = "chevron", color = { grey = 0 } } }, SRC)
    eq(m.top.frac, 0.25, "frac")
    eq(m.top.size, 150, "size")
    eq(m.top.offset, 3, "offset")
    eq(m.top.style, "chevron", "style passed through")
    eq(m.top.color.grey, 0, "colour passed through parseColorValue")
    eq(m.bottom, nil, "no bottom slot")
end)

test("type=book_open resolves to book_open_frac; defaults size=50 offset=0 style=chevron", function()
    local m = self:buildBarMarkers({ top = { type = "book_open" } }, SRC)
    eq(m.top.frac, 0.10, "book_open frac")
    eq(m.top.size, 50, "default size")
    eq(m.top.offset, 0, "default offset")
    eq(m.top.style, "chevron", "default style")
    eq(m.top.color, nil, "no colour -> nil (painter uses default)")
end)

test("both slots populated independently", function()
    local m = self:buildBarMarkers(
        { top = { type = "book_open" }, bottom = { type = "session" } }, SRC)
    eq(m.top.frac, 0.10, "top book_open")
    eq(m.bottom.frac, 0.25, "bottom session")
end)

test("nil fraction omits the slot (e.g. session outside current chapter)", function()
    local m = self:buildBarMarkers({ top = { type = "session" } },
        { session_frac = nil, book_open_frac = 0.5 })
    eq(m, nil, "no resolvable slot -> nil whole table")
end)

test("slot without a type is ignored", function()
    local m = self:buildBarMarkers({ top = { size = 200 } }, SRC)
    eq(m, nil, "type absent -> Off -> omitted")
end)

test("nil src -> nil (no bar_info this paint)", function()
    eq(self:buildBarMarkers({ top = { type = "session" } }, nil), nil, "nil src")
end)

test("nil config -> nil", function()
    eq(self:buildBarMarkers(nil, SRC), nil, "nil cfg")
end)

test("getBookmarkPages: dedupes by page, excludes highlights (item.drawer set)", function()
    self.ui = { annotation = { annotations = {
        { pageno = 12 },                  -- plain bookmark
        { pageno = 12 },                  -- duplicate page -> deduped
        { pageno = 40, drawer = "lighten" }, -- highlight -> excluded
        { pageno = 7 },                   -- plain bookmark
    } } }
    local pages = self:getBookmarkPages()
    table.sort(pages)
    eq(#pages, 2, "two distinct plain-bookmark pages")
    eq(pages[1], 7, "page 7")
    eq(pages[2], 12, "page 12 (deduped)")
end)

test("getBookmarkPages: nil when annotation module or list is absent", function()
    self.ui = { annotation = nil }
    eq(self:getBookmarkPages(), nil, "no annotation module -> nil")
    self.ui = { annotation = { annotations = nil } }
    eq(self:getBookmarkPages(), nil, "no annotations list -> nil")
end)

test("type=bookmarks resolves src.bookmark_fracs as a list, with slot style/size/offset/colour applied", function()
    local src = { session_frac = 0.25, book_open_frac = 0.10, bookmark_fracs = { 0.1, 0.4, 0.9 } }
    local m = self:buildBarMarkers(
        { top = { type = "bookmarks", size = 80, offset = 2, style = "solid", color = { grey = 128 } } }, src)
    eq(#m.top.fracs, 3, "three bookmark fracs")
    eq(m.top.fracs[1], 0.1); eq(m.top.fracs[2], 0.4); eq(m.top.fracs[3], 0.9)
    eq(m.top.frac, nil, "bookmarks type does not set the singular .frac field")
    eq(m.top.size, 80, "size")
    eq(m.top.offset, 2, "offset")
    eq(m.top.style, "solid", "style")
    eq(m.top.color.grey, 128, "colour")
end)

test("type=bookmarks with empty bookmark_fracs omits the slot", function()
    local m = self:buildBarMarkers({ top = { type = "bookmarks" } },
        { session_frac = 0.25, book_open_frac = 0.10, bookmark_fracs = {} })
    eq(m, nil, "empty list -> no resolvable slot -> nil whole table")
end)

test("type=bookmarks with nil bookmark_fracs (src has no bookmarks field) omits the slot", function()
    local m = self:buildBarMarkers({ top = { type = "bookmarks" } }, SRC)
    eq(m, nil, "SRC has no bookmark_fracs -> nil")
end)

test("existing session/book_open behaviour unchanged: still populate .frac, not .fracs", function()
    local m = self:buildBarMarkers({ top = { type = "session" } }, SRC)
    eq(m.top.frac, 0.25, "session still resolves .frac")
    eq(m.top.fracs, nil, "session does not populate .fracs")
end)

test("type=today resolves src.today_frac via the singular-frac path (like session/book_open)", function()
    local src = { session_frac = 0.25, book_open_frac = 0.10, today_frac = 0.60 }
    local m = self:buildBarMarkers({ top = { type = "today", size = 70 } }, src)
    eq(m.top.frac, 0.60, "today resolves to today_frac")
    eq(m.top.fracs, nil, "today does not populate the bookmarks-only .fracs field")
    eq(m.top.size, 70, "size passed through")
end)

test("type=today with nil today_frac (src has no today_frac field) omits the slot", function()
    local m = self:buildBarMarkers({ top = { type = "today" } }, SRC)
    eq(m, nil, "SRC (session/book_open only) has no today_frac -> nil")
end)

test("existing book_open/session/bookmarks resolution unaffected by the three-way branch", function()
    local m1 = self:buildBarMarkers({ top = { type = "book_open" } }, SRC)
    eq(m1.top.frac, 0.10, "book_open still resolves correctly")
    local m2 = self:buildBarMarkers({ top = { type = "session" } }, SRC)
    eq(m2.top.frac, 0.25, "session still resolves correctly")
end)

local function fakeTodayMarkerSettings(initial_books)
    local data = { books = initial_books or {} }
    local calls = { saveSetting = 0, flush = 0 }
    return {
        readSetting = function(_, key) return data[key] end,
        saveSetting = function(_, key, value) data[key] = value; calls.saveSetting = calls.saveSetting + 1 end,
        flush = function(_) calls.flush = calls.flush + 1 end,
        _data = data,
        _calls = calls,
    }
end

test("getTodayMarkerPage: no entry for this book -> anchors to current page, writes once", function()
    self.today_marker_settings = fakeTodayMarkerSettings()
    self.ui = { document = { file = "/book.epub" }, view = { state = { page = 42 } } }
    local page = self:getTodayMarkerPage()
    eq(page, 42, "anchors to current page")
    eq(self.today_marker_settings._data.books["/book.epub"].page, 42, "persisted page")
    eq(self.today_marker_settings._calls.saveSetting, 1, "wrote once")
    eq(self.today_marker_settings._calls.flush, 1, "flushed once")
end)

test("getTodayMarkerPage: stale date -> re-anchors to current page, writes", function()
    self.today_marker_settings = fakeTodayMarkerSettings({
        ["/book.epub"] = { page = 10, date = "2000-01-01" },
    })
    self.ui = { document = { file = "/book.epub" }, view = { state = { page = 99 } } }
    local page = self:getTodayMarkerPage()
    eq(page, 99, "re-anchors to current page")
    eq(self.today_marker_settings._data.books["/book.epub"].page, 99, "persisted new page")
    eq(self.today_marker_settings._calls.saveSetting, 1, "wrote once")
end)

test("getTodayMarkerPage: current-date entry -> returns stored page, does NOT write", function()
    local today = os.date("%Y-%m-%d")
    self.today_marker_settings = fakeTodayMarkerSettings({
        ["/book.epub"] = { page = 55, date = today },
    })
    self.ui = { document = { file = "/book.epub" }, view = { state = { page = 200 } } }
    local page = self:getTodayMarkerPage()
    eq(page, 55, "returns the already-anchored page, ignoring current page")
    eq(self.today_marker_settings._calls.saveSetting, 0, "no write when date matches")
    eq(self.today_marker_settings._calls.flush, 0, "no flush when date matches")
end)

test("getTodayMarkerPage: no document -> nil", function()
    self.today_marker_settings = fakeTodayMarkerSettings()
    self.ui = { document = nil }
    eq(self:getTodayMarkerPage(), nil, "no document -> nil")
end)

test("getTodayMarkerPage: independent entries per book", function()
    local today = os.date("%Y-%m-%d")
    self.today_marker_settings = fakeTodayMarkerSettings({
        ["/book-a.epub"] = { page = 5, date = today },
    })
    self.ui = { document = { file = "/book-b.epub" }, view = { state = { page = 300 } } }
    local page = self:getTodayMarkerPage()
    eq(page, 300, "book B gets its own fresh anchor")
    eq(self.today_marker_settings._data.books["/book-a.epub"].page, 5, "book A's entry untouched")
end)

print(pass .. " pass / " .. fail .. " fail")
os.exit(fail == 0 and 0 or 1)
