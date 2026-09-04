<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/bookends-logo-dark.png">
    <img alt="Bookends" src="assets/bookends-logo.png" width="320">
  </picture>
</p>

# Bookends

Customisable text overlays for KOReader — page numbers, reading stats, progress bars, clocks, and more, placed anywhere on the reading screen.

### Screenshots

| Main menu | Line editor | Preset gallery |
|:---:|:---:|:---:|
| ![Main menu](screenshots/main-menu.png) | ![Line editor](screenshots/line-editor.png) | ![Preset gallery](screenshots/preset-gallery.png) |

### Quick start

1. Download the [latest release zip](https://github.com/AndyHazz/bookends.koplugin/releases/latest) and extract `bookends.koplugin/` to your KOReader plugins directory ([paths](#installation))
2. Open a book → **typeset/document menu** (style icon) → **Bookends** → **Bookends settings** → tick **Enable bookends**
3. Tap a position (e.g., Bottom-center) → **Add line**
4. Type a format string or use the **Tokens** and **Symbols** buttons to insert placeholders
5. Tap **Save** — your overlay appears immediately

### Recipes

A few examples to show how format strings work. Type these in the line editor, or use the **Tokens** and **Symbols** buttons to build them visually.

| You type | You get |
|----------|---------|
| `Page %page_num of %page_count` | Page 42 of 218 |
| `%book_pct %bar` | 19% ━━━━━━━░░░░░░░░░░░ |
| `%time_12h  %batt_icon` | 2:35 PM 🔋 |
| `[if:chap_time_left_h>0]%chap_time_left_h hr(s) [/if]%chap_time_left_m min(s) left in chapter` | 2 hrs 5 mins left in chapter — and *42 mins left in chapter* once under an hour |

You don't need to memorise tokens — the editor has a **Tokens** picker with the full list, and a **live preview** that updates as you type. The built-in presets and the token reference below cover much more.

### Preset library

Open **Bookends → Preset → Preset library…** (or bind the *Open preset library* gesture) for a single central modal that handles everything: creating, editing, starring for the cycle gesture, and browsing community presets from an online gallery.

**My presets tab** — your presets. Tap any row to preview it live on your overlay. Tap **Apply** to commit; tap **Close** to revert. Tap the ★ on the left of a row to add/remove it from the cycle gesture. Use **+ Save current as new preset** (top of the Bookends menu) to snapshot your current overlay. Long-press any preset row to rename, edit its description, duplicate, or delete it.

A virtual **(No overlay)** row lets you star "nothing" for the cycle — useful for quickly hiding all overlays with a gesture.

When a preset is "active", your subsequent overlay edits **autosave back to the file** — no separate save step. Tweak in the regular menus, it's saved.

**Gallery tab** — community presets from [**AndyHazz/bookends-presets**](https://github.com/AndyHazz/bookends-presets). Tap a preset to preview it live; tap **Install** to save it locally. Presets already installed on your device show a ✓ indicator. Fresh installs ship with **Basic bookends** as a starter; the classic *Rich Detail*, *Speed Reader*, *Classic Alternating* and *SimpleUI status bar* presets are available from the Gallery.

Want to share a preset? See the [gallery repo's README](https://github.com/AndyHazz/bookends-presets#for-contributors--how-to-submit-a-preset) for the submission flow.

**Presets folder shortcut** — the presets folder registers itself with KOReader's *Folder shortcuts*, so you can jump straight to it from the file manager (long-press the folder icon in the title bar → **Folder shortcuts** → **Add** → *Bookends presets folder*). Handy for copying preset files on or off the device by hand. Needs a KOReader release with folder shortcuts; on older builds the entry simply doesn't appear.

### Auto preset by file type

Bookends can switch preset, or hide itself entirely, depending on the file you open. Under **Bookends settings > Auto preset by file type**, choose **Add rule…**, type a file extension, then pick either a preset or **Hidden (no overlay)**.

| Rule | Effect |
|------|--------|
| `CBZ > Hidden` | No overlay at all while reading CBZ files |
| `PDF > Compact` | Switches to your "Compact" preset for PDFs |
| `EPUB > Rich detail` | Switches to "Rich detail" for EPUBs |

Comics and manga are the case this was built for: hiding the overlay for CBZ and CBR keeps the artwork clear, and opening an EPUB again restores your usual preset with nothing to toggle by hand.

Rules match on the extension, so one rule covers every file of that type. Long-press a rule to change or remove it.

> **Your normal preset is remembered separately.** Bookends tracks the preset you chose yourself, distinct from whatever a rule switched you to, so removing a rule (or opening a file type with no rule) puts you back where you were rather than leaving you on the last rule's preset.

### Screen positions

```
 TL              TC              TR
 ┌──────────────────────────────────┐
 │                                  │
 │          (reading area)          │
 │                                  │
 └──────────────────────────────────┘
 BL              BC              BR
```

Six positions: **Top-left**, **Top-center**, **Top-right**, **Bottom-left**, **Bottom-center**, **Bottom-right**. Each position can have multiple lines of text.

---

## Reference

Everything below is the full feature reference. Expand any section you need.

<details>
<summary><strong>Tokens</strong> — all available placeholders</summary>

Tokens are placeholders that expand to live values. Type `%` followed by a name, or use the **Tokens** button in the line editor.

> All tokens below use the v5 descriptive vocabulary. Older one-letter tokens like `%A` or `%J` still work — your existing presets don't need changing — but when you open an existing preset in the editor, they'll be rewritten to the new names so you can see what they mean at a glance.

#### Metadata

| Token | Description | Example |
|-------|-------------|---------|
| `%title` | Document title | *The Great Gatsby* |
| `%author` | First author | *F. Scott Fitzgerald* |
| `%authors` | All authors, comma-joined | *Neil Gaiman, Terry Pratchett* |
| `%author_2` | Second author (empty if none) | *Terry Pratchett* |
| `%series` | Series with index | *Dune #1* |
| `%series_name` | Series name only | *Dune* |
| `%series_num` | Series number only | *1* |
| `%chap_title` | Chapter/section title (deepest level) | *Chapter 3: The Valley* |
| `%chap_title_1`…`%chap_title_9` | Chapter title at TOC depth N (menu shows 1–3; deeper levels work when typed manually) | `%chap_title_1` → *Part II*, `%chap_title_2` → *Chapter 3* |
| `%chap_title_num` | Just the number parsed out of the chapter title, when one is detected | *3* |
| `%chap_title_name` | The chapter title with its leading number stripped | *The Valley* |
| `%chap_num` | Current chapter number | *3* |
| `%chap_count` | Total chapter count | *24* |
| `%filename` | File name (no path/extension) | *The_Great_Gatsby* |
| `%file_num` | This file's position among the documents in its folder | *5* |
| `%file_count` | Documents in this file's folder | *10* |
| `%author_count` | Number of authors | *3* |
| `%authors_short` | Short author list, collapsing to "et al." at three or more | *Frank Herbert, Brian Herbert, et al.* |
| `%status` | Reading status value: `unread`, `reading`, `on_hold`, `finished` (never translated, so conditionals stay reliable) | *finished* |
| `%status_label` | The same status as a word, translated | *Finished* |
| `%rating` | Your rating as stars | *★★★★☆* |
| `%rating_number` | Your rating as a number | *4* |
| `%description` | Book description / blurb | *A desert planet…* |
| `%size` | File size | *2 KB* |
| `%added` | Date added, from the file's own date | *2024-03-09* |
| `%opened` | Date the book was last opened | *2024-07-03* |
| `%favourite` | A star when the book is in Favourites, empty otherwise | *★* |
| `%quote` | A highlight from this book, in quotation marks | *"The spice must flow."* |
| `%quote_source` | Title and author, to caption `%quote` | *Dune, Frank Herbert* |
| `%lang` | Book language | *en* |
| `%format` | Document format | *EPUB* |
| `%highlights` | Number of highlights | *3* |
| `%notes` | Number of notes | *1* |
| `%bookmarks` | Number of bookmarks | *5* |
| `%annotations` | Total annotations (highlights + notes + bookmarks) | *9* |
| `%calibre{name}` | Any Calibre column, by its lookup name (the `#` is optional) | *cosy* |

> **Calibre columns.** If your library is managed by Calibre, `%calibre{name}` shows any column from it, using the column's lookup name: a custom column `#mood` renders with `%calibre{mood}`. Text, list, number, date, yes/no and multi-value columns all work; long-text ("Comments") columns are skipped, being the wrong shape for a status line. Three standard fields come through the same way: `%calibre{pubdate}` (the year), `%calibre{publisher}` and `%calibre{rating}`. Conditionals work too, e.g. `[if:calibre{mood}="cosy"]Cosy read[/if]`.

> This reads the `metadata.calibre` file Calibre writes into your KOReader home folder, and reads nothing at all unless one of your lines actually uses the token. One caveat worth knowing: KOReader's own wireless Calibre sync rewrites that file and permanently drops custom columns from it. A small `calibre.bookshelf.json` saved alongside preserves them and is shared with [Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) if you run both plugins.

> **Author and last-digit families, typed manually.** `%author_1` through `%author_5` pick a specific author by position, the same way `%author_2` does. And `%page_num_lastdigit`, `%page_count_lastdigit`, `%pages_left_lastdigit`, `%chap_read_lastdigit`, `%chap_pages_lastdigit` and `%chap_pages_left_lastdigit` expose just the final digit of their counter, for languages whose grammar branches on it (Hungarian vowel harmony, for instance: `[if:page_num_lastdigit=3]`). Neither family appears in the token picker.

> **`%file_num` / `%file_count`** count the document files in the folder the open book sits in, ordered the same way the file manager shows them (your **sort by** and **reverse sorting** settings both apply). Mainly useful for comics and manga kept as one file per chapter, where the page and chapter tokens can only describe the chapter you're in: `File %file_num/%file_count` → *File 5/10*. The folder is read once per book opened, and only if one of these two tokens is in your preset.

#### Page / Progress

| Token | Description | Example |
|-------|-------------|---------|
| `%page_num` | Current page number | *42* |
| `%page_count` | Total pages | *218* |
| `%book_pct` | Book percentage read | *19%* |
| `%book_pct_left` | Book percentage remaining | *81%* |
| `%chap_pct` | Chapter percentage read | *65%* |
| `%chap_pct_left` | Chapter percentage remaining | *35%* |
| `%chap_read` | Pages read in chapter | *7* |
| `%chap_pages` | Total pages in chapter | *12* |
| `%chap_pages_left` | Pages left in chapter | *5* |
| `%pages_left` | Pages left in book | *176* |

> **Chapter progress at a TOC depth.** Like `%chap_title_N`, the chapter progress tokens take a depth suffix `N` (1-9): `%chap_pct_N`, `%chap_pct_left_N`, `%chap_read_N`, `%chap_pages_N`, `%chap_pages_left_N`. Without a suffix they track the deepest chapter covering the page; with `%chap_read_1` etc. they measure against the top-level chapter instead. Useful for books with a very fine TOC (a heading every few paragraphs), where pairing `%chap_title_1` with a plain `%chap_read` would show the top-level title next to a tiny sub-chapter's length. `N` deeper than the book's TOC collapses to the deepest level. Typed manually — not in the token picker.

#### Time / Date

| Token | Description | Example |
|-------|-------------|---------|
| `%time` | 24-hour clock (alias for `%time_24h`) | *14:35* |
| `%time_12h` | 12-hour clock | *2:35 PM* |
| `%time_24h` | 24-hour clock | *14:35* |
| `%date` | Date short | *28 Mar* |
| `%date_long` | Date long | *28 March 2026* |
| `%date_numeric` | Date numeric | *28/03/2026* |
| `%weekday` | Weekday | *Friday* |
| `%weekday_short` | Weekday short | *Fri* |
| `%datetime{spec}` | Custom date/time via strftime spec | `%datetime{%d %B}` → *23 April* |

> Custom date and time formats use `%datetime{spec}`, which accepts any [strftime spec](https://strftime.net/). Example: `%datetime{%d %B}` → "23 April". For the common cases, use the fixed tokens like `%date` and `%time`. The same brace syntax also works on `%chap_time_left_eta`, `%book_time_left_eta`, `%book_finish_date`, and the depth variant `%chap_time_left_N_eta`.

#### Reading

| Token | Description | Example |
|-------|-------------|---------|
| `%chap_time_left` | Time left in chapter | *0h 12m* |
| `%book_time_left` | Time left in book | *3h 45m* |
| `%chap_time_left_eta` | Clock time you'd reach end of chapter | *14:47* |
| `%book_time_left_eta` | Clock time you'd reach end of book | *18:20* |
| `%book_finish_date` | Projected calendar date you'll finish the book | *9 Jun* |
| `%book_read_time` | Total reading time for book | *2h 30m* |
| `%session_time` | Session reading time (skip-aware) | *0h 23m* |
| `%session_pages` | Session pages read (skip-aware) | *14* |
| `%pages_today` | Pages read today across all books | *32* |
| `%time_today` | Reading time today across all books | *1h 15m* |
| `%speed` | Reading speed (pages/hour) | *42* |
| `%avg_page_time` | Average time per page | *1m 12s* |
| `%book_pages_read` | Pages read of this book (lifetime) | *87* |
| `%book_pct_read` | Book read percentage (skip-aware) | *44* |
| `%days_reading_book` | Distinct days you've read this book | *5* |
| `%pages_per_day` | Pages per reading day for this book | *14* |
| `%total_read_time` | Lifetime reading time across all books | *42h 10m* |
| `%time_today_book` | Reading time today, this book only | *0h 40m* |
| `%pages_today_book` | Pages read today, this book only | *18* |
| `%time_week_book` | Reading time this week, this book only | *3h 05m* |
| `%pages_week_book` | Pages read this week, this book only | *96* |
| `%streak` | Consecutive days you've read anything | *7* |
| `%book_streak` | Consecutive days you've read this book | *3* |
| `%books_finished` | Books you've finished (lifetime) | *24* |

> **Time left at a TOC depth.** `%chap_time_left_N` and `%chap_time_left_N_eta{spec}` scope the remaining-time estimate to the level-`N` chapter, the same way the progress tokens above do. Both need the statistics plugin and render empty without it.

> **Duration formatting follows KOReader, not Bookends.** Every duration above is rendered by KOReader's own formatter, so the style comes from **Settings → Device → Time and date → Duration format**. The default is *classic*, which gives `7:36`; choose *letters* for `7h 36m`, or *modern* for a `7h36'` style. The examples in this table are shown in the *letters* style. Bookends deliberately does not override the choice, so durations match the rest of your reader.

#### Device

| Token | Description | Example |
|-------|-------------|---------|
| `%batt` | Battery level | *73%* |
| `%batt_icon` | Battery icon (dynamic) | Changes with charge level |
| `%wifi` | Wi-Fi icon (dynamic) | Hidden when off, changes when connected/disconnected |
| `%wifi_icon` | The same Wi-Fi glyph under Bookshelf's name for it | *(wifi glyph)* |
| `%plugin_content` | Plugin content (dynamic) | Aggregates output from plugins that register with KOReader's footer hook (e.g. `kobo.koplugin` Bluetooth, `readtimer.koplugin` countdown); hidden when none are reporting. Add a brace filter to restrict to one plugin: `%plugin_content{readtimer}` shows only the read-timer countdown, `%plugin_content{kobo}` only kobo.koplugin's contribution. |
| `%light` | Frontlight brightness | *18* or *OFF* |
| `%light_pct` | Frontlight brightness as a percentage | *56%* |
| `%light_icon` | Frontlight icon (dynamic) | Lit bulb when on, outline when off |
| `%warmth` | Frontlight warmth | *12* |
| `%warmth_pct` | Frontlight warmth as a percentage | *50%* |
| `%warmth_icon` | Warmth icon (dynamic) | Shown on devices with a warm frontlight |
| `%nightmode` | Night-mode icon (dynamic) | Moon when inverted, sun when not |
| `%mem` | RAM usage percentage | *33%* |
| `%sysused` | System memory used, in MiB | *84M* |
| `%ram` | RAM usage in MiB | *128M* |
| `%disk` | Free disk space | *2.4 GB* |
| `%invert` | Page-turn direction indicator | Changes when inverted |

Page tokens respect **stable page numbers** and **hidden flows** (non-linear EPUB content). All reading-time and pages-read tokens (session, today, lifetime) come from the **statistics plugin** and are skip-aware — pages flicked through faster than the dwell threshold (default 5s) don't count. Session counters reset each time you open the book or wake from suspend.

#### Inline progress bar

| Token | Description |
|-------|-------------|
| `%bar` | Progress bar (type configured in line editor) |

Add a `%bar` token to any line to render an inline progress bar. The bar auto-fills available space and can be mixed with text (e.g. `%book_pct %bar`). Use the bar controls in the line editor to set:

- **Type** — Chapter, Book, Book+ (top-level ticks), Book++ (top 2 level ticks)
- **Style** — Border, Solid, Round, Metro, Wave, Radial, Hollow

</details>

<details>
<summary><strong>Conditional tokens</strong> — show/hide content based on state</summary>

Show or hide content based on device state, reading progress, time, and more using `[if:condition]...[/if]` blocks with optional `[else]`:

```
[if:wifi=on]📶[/if]
[if:batt<20]LOW %batt[/if]
[if:charging=yes]⚡[/if] %batt
[if:page=odd]%title[else]%chap_title[/if]
[if:book_pct>90]Almost done![/if]
[if:time>22:00]Late night reading![/if]
[if:day=Sat]Weekend![else]%weekday_short[/if]
[if:chap_title_2]%chap_title_2[else]%chap_title_1[/if]
[if:not series]Standalone[/if]
[if:day=Sat or day=Sun]Weekend[/if]
[if:format=PDF]%page_num / %page_count[/if]
[if:chap_title_1!=@title]%chap_title_1 · [/if]
[if:batt!=100]charging…[/if]
```

Comparison operators: `=` (equals), `!=` (not equals), `<` (less than), `>` (greater than), `<=` (less than or equal), `>=` (greater than or equal). Boolean operators: `and`, `or`, `not`, with parens `()` for grouping. Conditionals can be nested to any depth — `[if:A][if:B]…[/if][/if]` — and compose with `[else]`.

| Condition | Values | Description |
|-----------|--------|-------------|
| `wifi` | on / off | Wi-Fi radio state |
| `connected` | yes / no | Network connection state |
| `batt` | 0–100 | Battery percentage |
| `charging` | yes / no | Charging or charged |
| `book_pct` | 0–100 | Book progress percentage (matches `%book_pct`) |
| `book_pct_left` | 0–100 | Book percentage remaining (matches `%book_pct_left`) |
| `chap_pct` | 0–100 | Chapter progress percentage (matches `%chap_pct`) |
| `chap_pct_left` | 0–100 | Chapter percentage remaining (matches `%chap_pct_left`) |
| `chap_num` | 1–N | Current chapter number (matches `%chap_num`) |
| `chap_count` | count | Total chapter count, 0 for chapterless books (matches `%chap_count`) |
| `chap_read` | count | Pages read in current chapter (matches `%chap_read`) |
| `chap_pages` | count | Total pages in current chapter (matches `%chap_pages`) |
| `chap_pages_left` | count | Pages left in current chapter (matches `%chap_pages_left`) |
| `chap_time_left` | minutes | Estimated time left in chapter (matches `%chap_time_left`) — needs statistics plugin |
| `book_time_left` | minutes | Estimated time left in book (matches `%book_time_left`) — needs statistics plugin |
| `chap_time_left_h` | hours | Whole hours left in chapter (matches `%chap_time_left_h`) — needs statistics plugin |
| `chap_time_left_m` | 0–59 | Minutes part of the time left in chapter (matches `%chap_time_left_m`) |
| `book_time_left_h` | hours | Whole hours left in book (matches `%book_time_left_h`) — needs statistics plugin |
| `book_time_left_m` | 0–59 | Minutes part of the time left in book (matches `%book_time_left_m`) |
| `book_read_time` | minutes | Total time spent reading this book (matches `%book_read_time`) — needs statistics plugin |
| `page_num` | 1–N | Current page number (matches `%page_num`) |
| `page_count` | count | Total page count (matches `%page_count`) |
| `pages_left` | count | Pages left in book (matches `%pages_left`) |
| `highlights` | count | Number of highlights in this book (matches `%highlights`) |
| `notes` | count | Number of notes in this book (matches `%notes`) |
| `bookmarks` | count | Number of bookmarks in this book (matches `%bookmarks`) |
| `speed` | pages/hr | Reading speed |
| `session` | minutes | Session reading time (skip-aware) |
| `session_time` | minutes | Alias for `session`, matching the `%session_time` token name |
| `session_pages` | count | Session pages read (skip-aware) |
| `pages_today` | count | Pages read today across all books (skip-aware) |
| `time_today` | minutes | Reading time today across all books |
| `avg_page_time` | seconds | Average time per page |
| `book_pages_read` | count | Lifetime skip-aware pages read of this book |
| `book_pct_read` | 0–100 | Book read percentage, skip-aware (complements position-based `book_pct`) |
| `days_reading_book` | count | Distinct days you've read this book |
| `pages_per_day` | count | Pages per reading day for this book |
| `page` | odd / even | Current page parity |
| `light` | on / off | Frontlight state |
| `warmth` | 0–100 | Frontlight warmth (only on devices with natural light) |
| `format` | EPUB / PDF / CBZ… | Document format |
| `time` | HH:MM (24h) | Time of day |
| `day` | Mon–Sun | Day of week |
| `invert` | yes / no | Page-turn direction flipped |
| `title` | string | Book title (matches `%title`) — test with `[if:not title]` or `[if:title="A Book"]` |
| `author` | string | Author (matches `%author`) |
| `series` | string | Series, e.g. `"Foo #2"` (matches `%series`) — empty when not in a series |
| `series_name` | string | Series name without index (matches `%series_name`) |
| `series_num` | string | Series index, e.g. `"2"` (matches `%series_num`) |
| `lang` | string | Document language code, e.g. `"en"` (matches `%lang`) |
| `filename` | string | File name without extension (matches `%filename`) |
| `chap_title` | string | Current chapter title (matches `%chap_title`) |
| `chap_title_1` | string | Chapter title at depth 1 (matches `%chap_title_1`) |
| `chap_title_2` | string | Chapter title at depth 2 (matches `%chap_title_2`) |
| `chap_title_3` | string | Chapter title at depth 3 (matches `%chap_title_3`) |

String predicates evaluate as falsy when the string is empty, so `[if:not series]` means "book isn't in a series" and `[if:chap_title_2]` means "we're in a sub-chapter at depth 2". For exact-match comparisons, wrap multi-word values in double quotes — e.g. `[if:author="J.R.R. Tolkien"]` or `[if:title!="Untitled"]`.

> **Keep the separating space inside the block.** A hidden `[if:…][/if]` is replaced by nothing at all, so any space you leave *outside* it survives into the output and shows up as a stray indent — visible as uneven margins on a centred or right-aligned position. Write `[if:chap_time_left_h>0]%chap_time_left_h hr(s) [/if]%chap_time_left_m min(s)` (space before `[/if]`), not `[if:…]%chap_time_left_h hr(s)[/if] %chap_time_left_m min(s)`.

> Legacy predicate names (`chapters`, `chapter_pct`, `chapter_title`, `percent`, `pages`) still evaluate — they're aliased to their v5 equivalents automatically.

The right-hand side of a comparison can reference another state value with `@`. For example, `[if:chap_title_1!=@title]` is true when the depth-1 chapter title differs from the book title — useful for hiding duplicate headings when a book's only top-level TOC entry is the title itself. Any `@key` that doesn't exist in the state table resolves to an empty string.

Conditions evaluate live — the charging icon appears the moment you plug in, the wifi icon vanishes when you disconnect. The token picker has a dedicated **If/Else conditional tokens** submenu with syntax help, examples, and a complete reference.

</details>

<details>
<summary><strong>Full-width progress bars</strong> — dedicated bar layers behind text</summary>

Up to 8 independent progress bars rendered as dedicated layers behind text. Configure via **Full width progress bars** in the Bookends menu.

- **Anchor** — Top, Bottom, Left (vertical), Right (vertical)
- **Fill direction** — Left to right, Right to left, Top to bottom, Bottom to top
- **Style** — Solid, Bordered, Rounded, Metro, Wave, Radial, Radial hollow
- **Chapter ticks** — Off, Top level, Top 2 levels (book type only)
- **Thickness** and **margins** with real-time nudge adjustment

Progress on EPUB documents updates smoothly per screen turn using pixel-level position tracking. Chapter tick marks vary in thickness by TOC depth.

</details>

<details>
<summary><strong>Symbols</strong> — Nerd Fonts glyph picker</summary>

The **Symbols** button in the line editor opens a picker with categorised glyphs from the Nerd Fonts set (bundled with KOReader). Categories include:

- **Dynamic** — Battery and Wi-Fi icons that change with device state
- **Device** — Lightbulb, sun, moon, power, Wi-Fi, cloud, memory chip
- **Reading** — Book, bookmarks, eye, flag, bar chart, tachometer, sliders
- **Time** — Clock, stopwatch, watch, hourglass, calendar
- **Status** — Check, cross, info, warning, cog
- **Symbols** — Sun, warmth, card suits, stars, daggers, pilcrow, copyright, numero, check/cross marks
- **Arrows** — Directional arrows, triangles, angle brackets
- **Progress blocks** — Block-fill glyphs for hand-built progress strings
- **Separators** — Vertical bar, bullets, dots, dashes, slashes

</details>

<details>
<summary><strong>Styling</strong> — per-line fonts, inline bold/italic/uppercase</summary>

#### Per-line styling

Each line has its own style controls in the editor dialog:

- **Style** — Cycles through: Regular, Bold, Italic, Bold Italic
- **Uppercase** — Toggle uppercase rendering
- **Size** — Font size in pixels (defaults to global setting, affected by font scale)
- **Font** — Choose from the full CRE font list
- **Nudge** — Fine-tune vertical and horizontal position of individual lines
- **Page filter** — Show on all pages, odd pages only, or even pages only

Italic uses automatic font variant detection — searches installed fonts for matching italic variants.

#### Inline formatting

Use BBCode-style tags to format parts of a line independently:

| Tag | Effect | Example |
|-----|--------|---------|
| `[b]...[/b]` | Bold | `[b]Page[/b] %page_num of %page_count` |
| `[i]...[/i]` | Italic | `[i]%chap_title[/i] — %chap_read/%chap_pages` |
| `[u]...[/u]` | Uppercase | `[u]chapter[/u] %chap_pct` |

Tags can be nested: `[b][i]bold italic[/i][/b]`. Tags must be properly nested — overlapping tags like `[b][i]...[/b][/i]` render as literal text. Unclosed tags also render as literal text.

Tags override the line's per-line style. If a line is set to Bold, `[i]text[/i]` renders that segment as italic (not bold italic). Use `[b][i]...[/i][/b]` for explicit bold italic.

</details>

<details>
<summary><strong>Smart features</strong> — auto-hide, token width limits, pluralisation</summary>

- **Auto-hide** — Lines where all tokens resolve to empty or zero are automatically hidden
- **Token width limits** — Append `{N}` to any token to cap its width at N pixels: `%chap_title{200} - %chap_read/%chap_pages` truncates the chapter title with ellipsis if it exceeds 200 pixels. Works with `%bar{400}` to set a fixed bar width instead of auto-fill.
- **Elastic gap.** `%spacer` absorbs the leftover width of a line, pushing everything after it to the far edge: `%author%spacer%book_pct` puts the author hard left and the percentage hard right on one line. A line can only stretch in one place, so if it also has a `%bar` the bar takes the space and the spacer is dropped; a second `%spacer` is dropped too.
- **Delimited tokens** — A token name runs until the next non-letter, so text placed straight after it is read as part of the name. Wrap the name in angle brackets to butt text directly against it: `%<book_time_left_h>h%<book_time_left_m>m` → `4h40m`. Width limits still work inside: `%<author{200}>`.
- **Pluralisation** — Write `%highlights highlight(s)` and it becomes `1 highlight` or `3 highlights`
- **Odd/even pages** — Set any line to appear on all pages, odd pages only, or even pages only
- **Auto-refresh** — Clock and other dynamic tokens update every 60 seconds

#### Smart ellipsis

When text would overlap between positions on the same row, Bookends automatically truncates with ellipsis. Center positions get priority by default — left and right text is truncated first. Enable **Prioritise left/right and truncate long center text** to reverse this.

</details>

<details>
<summary><strong>Layout & margins</strong> — positioning, managing lines</summary>

#### Margins

Bookends uses a three-layer positioning system:

1. **Global margins** (top/bottom/left/right) — Set in **Settings > Adjust margins** with real-time preview
2. **Per-position extra margins** — Additional offset for individual regions
3. **Per-line nudges** — Pixel-level fine-tuning in the line editor

#### Managing lines

- Tap a **line entry** in a position's submenu to edit it
- Tap **Add line** to add a new line to the position
- **Long-press** a line entry for options: **Move up**, **Move down**, **Move to** another position, or **Delete**
- Saving an empty line automatically removes it
- The editor shows a **live preview** of your format string as you type

</details>

<details>
<summary><strong>Settings</strong> — fonts, stock status bar, gestures, updates</summary>

The Bookends menu separates **global** settings (apply everywhere, never saved with presets) from **per-preset** styling (saved into the active preset and switched when you swap presets).

#### Global — *Bookends → Bookends settings*

| Setting | Default | Description |
|---------|---------|-------------|
| Enable bookends | Off | Master on/off |
| Disable stock status bar | Off | Hides KOReader's built-in status bar (recommended — see below) |
| Default font | Status bar font | Base font for all overlays; pick a font family slot for portable presets |
| Bottom-center tap gesture | Toggle bookends | Action when you tap the centre of the status bar area |
| Include current page in pages-left tokens | Off | Affects `%pages_left` and `%chap_pages_left` |
| Notify on wake when update available | Off | Show a notification when a new release is published on GitHub |
| Check for updates | — | Manual one-tap install from GitHub |

#### Per-preset — *Bookends → Preset (active preset name)*

| Setting | Default | Description |
|---------|---------|-------------|
| Font scale | 100% | Scale all text sizes (25%–300%) |
| Adjust margins | 10/25/18/18 | Independent top/bottom/left/right margins |
| Truncation gap between regions | 50px | Minimum space between adjacent texts |
| Prioritise left/right and truncate long center text | Off | Reverses the default centre-first truncation |
| Text colour | Black | Default text colour (per-preset) |
| Symbol colour | Black | Default colour for icon glyphs |

#### Bookshelf's status line

If you also run [Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin), it can put its own status line across the top of the reader. **Bookshelf draws it and Bookshelf owns the switch** (*menu > Settings > Also show status line in reader*), so it works whether or not Bookends is installed.

All Bookends does is get out of the way: your top-row regions, and any top-anchored progress bar, all shift down by the height of the strip, so they keep the spacing you set between them. Nothing to configure here.

#### Disabling the stock status bar

For the best experience, disable KOReader's built-in status bar via **Bookends → Bookends settings → Disable stock status bar**. This:

- **Reduces e-ink flicker** — Bookends no longer needs to repaint over the stock footer, eliminating extra screen refreshes on page turns
- **Frees screen space** — The stock footer's reserved area is returned to the reading area
- **Avoids duplication** — All stock status bar features (time, battery, progress, pages, etc.) are available as Bookends tokens

#### Gesture support

Assign **Bookends: toggle visibility**, **Bookends: cycle preset**, **Bookends: set visibility**, or **Bookends: open preset library** to any gesture via KOReader's **Gesture manager > Reader** to show/hide overlays or swap presets with a tap, swipe, or multi-finger gesture.

</details>

<details>
<summary><strong>Using KOReader's font families</strong> — pick Serif, Sans-serif, etc. instead of specific fonts</summary>

Bookends' font picker includes KOReader's font-family slots: **UI font**, **Serif**, **Sans-serif**, **Monospace**, **Cursive**, and **Fantasy**. Pick a family instead of a specific font, and overlays will use whichever font you have mapped to that slot in **KOReader Settings › Font › Font-family fonts**. This keeps overlay appearance consistent with your document font and makes presets portable across devices — someone sharing a preset that picks "Serif" will have it rendered in *your* serif, not theirs.

If a family slot isn't mapped in KOReader, the overlay falls back to your KOReader UI font. That's the same behaviour KOReader itself uses. If you see overlay text rendering in the UI font when you expected something else, check your KOReader **Font-family fonts** menu and set a mapping for that family.

</details>

<details>
<summary><strong>Coverage of KOReader's stock status bar</strong> — every stock item mapped to a bookends token</summary>

Bookends covers the same information as KOReader's built-in status bar, often with finer granularity. This table maps each stock footer item to the bookends token(s) that produce the same information.

| Stock footer item | Bookends token(s) |
|-------------------|-------------------|
| Page number (current / total) | `%page_num` / `%page_count` |
| Pages left in book | `%pages_left` |
| Pages left in chapter | `%chap_pages_left` |
| Chapter progress (page in chapter) | `%chap_read` / `%chap_pages` |
| Book percentage | `%book_pct` |
| Chapter percentage | `%chap_pct` |
| Time to finish book | `%book_time_left` |
| Time to finish chapter | `%chap_time_left` |
| Clock (12h / 24h) | `%time_12h` / `%time_24h` |
| Battery level | `%batt` (%) / `%batt_icon` (dynamic icon) |
| Charging indicator | `[if:charging=yes]⚡[/if]` |
| Wi-Fi status | `%wifi` (dynamic) |
| Plugin status (Bluetooth, timer, …) | `%plugin_content` (dynamic) |
| Frontlight brightness | `%light` |
| Frontlight warmth | `%warmth` |
| Memory usage | `%mem` (%) / `%ram` (MiB) |
| Book title / author | `%title` / `%author` |
| Current chapter title | `%chap_title` (also `%chap_title_1`…`%chap_title_9` by depth) |
| Bookmark count | `%bookmarks` |
| Highlight count | `%highlights` |
| Note count | `%notes` |
| **Total annotations** | `%annotations` |
| **Page-turning inverted** | `%invert` (also `[if:invert=yes]`) |

Bookends' six-zone positioning model replaces stock's `dynamic_filler` layout. Stock's `additional_content` plugin hook is exposed as the `%plugin_content` token (see Device tokens above), so plugins like `kobo.koplugin` and `readtimer.koplugin` keep working when the stock bar is disabled.

</details>

---

## Installation

**Manual install:** Download the latest release ZIP from [GitHub Releases](https://github.com/AndyHazz/bookends.koplugin/releases) and extract to your KOReader plugins directory:

| Device | Path |
|--------|------|
| Kindle | `/mnt/us/koreader/plugins/bookends.koplugin/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/bookends.koplugin/` |
| Android | `<koreader-dir>/plugins/bookends.koplugin/` |

Or use the built-in **Check for updates** feature in Settings to update from within KOReader.

Restart KOReader after installing.

## See also

**[Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin)** — a customisable home screen for KOReader, letting you browse and pick books from your library with configurable book preview info.

## License

AGPL-3.0 — see [LICENSE](LICENSE)
