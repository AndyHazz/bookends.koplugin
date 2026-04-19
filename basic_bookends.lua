-- Bookends preset: Basic bookends
return {
    name = "Basic bookends",
    description = "Minimal starter — clock, page number, and a slim progress bar",
    author = "bookends",
    enabled = true,
    positions = {
        tl = { lines = {} },
        tc = { lines = { "%k" }, line_font_size = { [1] = 14 } },
        tr = { lines = {} },
        bl = { lines = {} },
        bc = { lines = { "Page %c of %t" }, line_font_size = { [1] = 14 } },
        br = { lines = {} },
    },
    progress_bars = {
        {
            enabled = true,
            type = "book",
            style = "solid",
            height = 5,
            v_anchor = "bottom",
            margin_v = 0,
            margin_left = 0,
            margin_right = 0,
            chapter_ticks = "off",
        },
    },
}
