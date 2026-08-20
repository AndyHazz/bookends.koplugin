-- Tests for the folder-position tokens %file_num / %file_count (#89).
--
-- Reading manga as one CBZ per chapter, "File 5/10" answers "how much of this
-- folder have I got through" - which page/chapter tokens can't, since each
-- chapter is a separate document.
--
-- The ordering has to match what the file manager shows, or the number means
-- nothing. Rather than reimplement sorting, this reuses KOReader's own collate
-- descriptors (BookList.collates, surfaced via FileChooser): each one exposes
-- init_sort_func to build the comparator and, where the comparison needs more
-- than name/attr, an item_func to populate the extra fields.
--
-- Run: cd into the plugin dir, then `lua tests/_test_folder_position.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = { secondsToClockDuration = function() return "" end }
package.loaded["bookends_overlay_widget"] = { BAR_PLACEHOLDER = "\x00BAR\x00" }

-- Fake folder: the fixture each test installs before calling in.
local folder = {}      -- name -> { size, modification } (nil attr = a directory)
local unreadable = false

package.loaded["libs/libkoreader-lfs"] = {
    dir = function(path)
        if unreadable then error("permission denied") end
        local names = { ".", ".." }
        for name in pairs(folder) do table.insert(names, name) end
        table.sort(names)
        local i = 0
        return function()
            i = i + 1
            return names[i]
        end
    end,
    attributes = function(fullpath)
        local name = fullpath:match("([^/]+)$")
        local entry = folder[name]
        if not entry then return nil end
        if entry.dir then return { mode = "directory" } end
        return { mode = "file", size = entry.size or 0,
                 modification = entry.modification or 0, access = entry.access or 0 }
    end,
}
package.loaded["document/documentregistry"] = {
    hasProvider = function(_self, path)
        return path:match("%.(cbz)$") ~= nil or path:match("%.(epub)$") ~= nil
    end,
}
-- Only the pieces of the collate machinery the listing touches. Mirrors
-- BookList.collates / FileChooser:getCollate / :getSortingFunction.
local collate_id = "strcoll"
local reverse = false
package.loaded["ui/widget/filechooser"] = {
    show_hidden = false,
    collates = {
        strcoll = {
            init_sort_func = function()
                return function(a, b) return a.text < b.text end
            end,
        },
        size = {
            init_sort_func = function()
                return function(a, b) return a.attr.size < b.attr.size end
            end,
        },
        type = {
            init_sort_func = function()
                return function(a, b)
                    if (a.suffix or b.suffix) and a.suffix ~= b.suffix then
                        return a.suffix < b.suffix
                    end
                    return a.text < b.text
                end
            end,
            item_func = function(item)
                item.suffix = item.text:match("%.([^.]+)$") or ""
            end,
        },
    },
    getCollate = function(self) return self.collates[collate_id], collate_id end,
    getSortingFunction = function(self, collate, reverse_collate)
        local sorting = collate.init_sort_func()
        if reverse_collate then
            local unreversed = sorting
            return function(a, b) return unreversed(b, a) end
        end
        return sorting
    end,
}
_G.G_reader_settings = setmetatable({
    isTrue = function(_, k) return k == "reverse_collate" and reverse or false end,
}, { __index = function() return function() return false end end })

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
            .. " got="      .. string.format("%q", tostring(actual)), 2)
    end
end

local function setFolder(t)
    folder = t
    collate_id, reverse, unreadable = "strcoll", false, false
    Tokens.flushFolderCache()
end

local function uiFor(name)
    return { document = { file = "/manga/Series/" .. name } }
end

local function positionOf(name)
    local num, count = Tokens.folderPosition(uiFor(name))
    return num, count
end

-- ============================================================================
-- Counting and indexing
-- ============================================================================

test("counts document files and finds the current one's position", function()
    setFolder({
        ["ch01.cbz"] = {}, ["ch02.cbz"] = {}, ["ch03.cbz"] = {},
        ["ch04.cbz"] = {}, ["ch05.cbz"] = {},
    })
    local num, count = positionOf("ch03.cbz")
    eq(num, 3, "position")
    eq(count, 5, "count")
end)

test("first and last file", function()
    setFolder({ ["a.cbz"] = {}, ["b.cbz"] = {}, ["c.cbz"] = {} })
    local n1 = positionOf("a.cbz")
    local n3, c = positionOf("c.cbz")
    eq(n1, 1, "first")
    eq(n3, 3, "last")
    eq(c, 3, "count")
end)

test("a lone file in its folder is 1/1", function()
    setFolder({ ["only.cbz"] = {} })
    local num, count = positionOf("only.cbz")
    eq(num, 1, "position")
    eq(count, 1, "count")
end)

-- ============================================================================
-- What counts as a file
-- ============================================================================

test("ignores subfolders, dotfiles, macOS forks and non-document files", function()
    setFolder({
        ["ch01.cbz"] = {}, ["ch02.cbz"] = {},
        ["extras"] = { dir = true },        -- subfolder
        [".hidden.cbz"] = {},               -- dotfile
        ["._ch01.cbz"] = {},                -- macOS resource fork
        ["cover.jpg"] = {},                 -- no document provider
        ["notes.txt"] = {},                 -- no document provider
    })
    local num, count = positionOf("ch02.cbz")
    eq(count, 2, "count")
    eq(num, 2, "position")
end)

test("counts sidecar-free mixed document formats together", function()
    setFolder({ ["a.cbz"] = {}, ["b.epub"] = {}, ["c.cbz"] = {} })
    local _num, count = positionOf("b.epub")
    eq(count, 3, "count")
end)

test("nil when the folder cannot be read", function()
    setFolder({ ["ch01.cbz"] = {} })
    unreadable = true
    Tokens.flushFolderCache()
    local num, count = positionOf("ch01.cbz")
    eq(num, nil, "position")
    eq(count, nil, "count")
end)

test("nil when there is no document", function()
    setFolder({ ["ch01.cbz"] = {} })
    local num, count = Tokens.folderPosition({ document = nil })
    eq(num, nil, "position")
    eq(count, nil, "count")
end)

test("count still resolves when the open file is not in the listing", function()
    -- e.g. the current book has a status filter applied, or was deleted from
    -- under us. The folder total is still meaningful; the position is not.
    setFolder({ ["a.cbz"] = {}, ["b.cbz"] = {} })
    local num, count = positionOf("gone.cbz")
    eq(num, nil, "position")
    eq(count, 2, "count")
end)

-- ============================================================================
-- Ordering follows the user's collate
-- ============================================================================

test("honours reverse_collate", function()
    setFolder({ ["a.cbz"] = {}, ["b.cbz"] = {}, ["c.cbz"] = {} })
    reverse = true
    Tokens.flushFolderCache()
    eq(positionOf("c.cbz"), 1, "reversed puts c first")
    eq(positionOf("a.cbz"), 3, "reversed puts a last")
end)

test("honours a collate that sorts on attributes (size)", function()
    setFolder({
        ["big.cbz"]    = { size = 300 },
        ["small.cbz"]  = { size = 100 },
        ["medium.cbz"] = { size = 200 },
    })
    collate_id = "size"
    Tokens.flushFolderCache()
    eq(positionOf("small.cbz"), 1, "smallest first")
    eq(positionOf("big.cbz"), 3, "biggest last")
end)

test("runs item_func for collates that need extra fields (type)", function()
    -- The `type` collate compares item.suffix, which only exists once its
    -- item_func has run. Without that call the comparator sees nil suffixes
    -- and silently degrades to a name sort.
    setFolder({ ["b.cbz"] = {}, ["a.epub"] = {}, ["c.cbz"] = {} })
    collate_id = "type"
    Tokens.flushFolderCache()
    eq(positionOf("b.cbz"), 1, "cbz sorts before epub")
    eq(positionOf("c.cbz"), 2, "second cbz")
    eq(positionOf("a.epub"), 3, "epub last despite the earlier name")
end)

-- ============================================================================
-- Caching: the scan must not repeat per paint
-- ============================================================================

test("the folder is scanned once and reused", function()
    setFolder({ ["a.cbz"] = {}, ["b.cbz"] = {} })
    local scans = 0
    local real_dir = package.loaded["libs/libkoreader-lfs"].dir
    package.loaded["libs/libkoreader-lfs"].dir = function(p)
        scans = scans + 1
        return real_dir(p)
    end
    positionOf("a.cbz")
    positionOf("a.cbz")
    positionOf("b.cbz")
    package.loaded["libs/libkoreader-lfs"].dir = real_dir
    eq(scans, 1, "directory scans")
end)

test("flushFolderCache forces a rescan, picking up a new file", function()
    setFolder({ ["a.cbz"] = {}, ["b.cbz"] = {} })
    local _n, count = positionOf("a.cbz")
    eq(count, 2, "before")
    folder["c.cbz"] = {}
    local _n2, stale = positionOf("a.cbz")
    eq(stale, 2, "still cached")
    Tokens.flushFolderCache()
    local _n3, fresh = positionOf("a.cbz")
    eq(fresh, 3, "after flush")
end)

test("moving to a different folder rescans without an explicit flush", function()
    setFolder({ ["a.cbz"] = {}, ["b.cbz"] = {} })
    local _n, count = positionOf("a.cbz")
    eq(count, 2, "first folder")
    -- Same fixture, different path: the cache is keyed by folder, so this must
    -- not be served from the previous folder's entry.
    local num2, count2 = Tokens.folderPosition({ document = { file = "/other/x.cbz" } })
    eq(count2, 2, "second folder counted")
    eq(num2, nil, "x.cbz is not in the fixture listing")
end)

-- ============================================================================
-- Token wiring through Tokens.expand
-- ============================================================================

local function expandUI(name)
    return {
        view = { state = { page = 3 } },
        document = {
            file = "/manga/Series/" .. name,
            getPageCount   = function() return 20 end,
            hasHiddenFlows = function() return false end,
            getProps       = function() return {} end,
            getTotalPagesLeft = function() return 17 end,
        },
        doc_props = {},
        statistics = { avg_time = 30, getTimeForPages = function() return "5m" end },
    }
end

test("%file_num / %file_count expand in a format string", function()
    setFolder({ ["ch01.cbz"] = {}, ["ch02.cbz"] = {}, ["ch03.cbz"] = {} })
    eq(Tokens.expand("File %file_num/%file_count", expandUI("ch02.cbz"), 0, 0),
       "File 2/3")
end)

test("the folder is not scanned when neither token is used", function()
    setFolder({ ["ch01.cbz"] = {}, ["ch02.cbz"] = {} })
    local scans = 0
    local real_dir = package.loaded["libs/libkoreader-lfs"].dir
    package.loaded["libs/libkoreader-lfs"].dir = function(p)
        scans = scans + 1
        return real_dir(p)
    end
    Tokens.expand("Page %page_num of %page_count", expandUI("ch01.cbz"), 0, 0)
    package.loaded["libs/libkoreader-lfs"].dir = real_dir
    eq(scans, 0, "directory scans")
end)

test("a line of only folder tokens auto-hides when the folder is unreadable", function()
    setFolder({ ["ch01.cbz"] = {} })
    unreadable = true
    Tokens.flushFolderCache()
    local out, is_empty = Tokens.expand("%file_num/%file_count", expandUI("ch01.cbz"), 0, 0)
    eq(out, "/", "both tokens render empty")
    eq(is_empty, true, "line auto-hides rather than showing a broken count")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
