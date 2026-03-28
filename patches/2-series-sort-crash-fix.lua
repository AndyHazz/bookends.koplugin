-- Fix: metadata sort (series/title/authors/keywords) crashes when item_table
-- contains directory entries that don't have doc_props set by item_func.

local BookList = require("ui/widget/booklist")

local _NIL_PROPS = {
    series = "\u{FFFF}", series_index = nil,
    display_title = "", authors = "\u{FFFF}", keywords = "\u{FFFF}",
}

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
