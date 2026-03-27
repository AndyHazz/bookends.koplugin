-- Fix: series/title/authors/keywords sort crashes when item_table contains
-- directory entries (e.g. "../") that don't have doc_props set.
--
-- The collation item_func calls ui.bookinfo:getDocProps() for files but
-- directory items skip item_func, leaving doc_props as nil. The sort
-- comparator then crashes with "attempt to index field 'doc_props' (a nil value)".
--
-- This patch wraps the sort functions for metadata-based collations to
-- handle items without doc_props gracefully.

local BookList = require("ui/widget/booklist")
local ffiUtil = require("ffi/util")

local _NIL_PROPS = { series = "\u{FFFF}", series_index = nil, display_title = "", authors = "\u{FFFF}", keywords = "\u{FFFF}" }

for _, id in ipairs({ "series", "title", "authors", "keywords" }) do
    local collate = BookList.collates[id]
    if collate and collate.init_sort_func then
        local orig_init = collate.init_sort_func
        collate.init_sort_func = function(cache)
            local sort_func, new_cache = orig_init(cache)
            return function(a, b)
                if not a.doc_props then a.doc_props = _NIL_PROPS end
                if not b.doc_props then b.doc_props = _NIL_PROPS end
                return sort_func(a, b)
            end, new_cache
        end
    end
end
