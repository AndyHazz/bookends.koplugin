<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="bookends-logo-dark.png">
    <img alt="Bookends" src="bookends-logo.png" width="320">
  </picture>
</p>

# Bookends

Customisable text overlays for KOReader — page numbers, reading stats, progress bars, clocks, and more, placed anywhere on the reading screen.

### Screenshots

| Title page | Main menu | Token picker |
|:---:|:---:|:---:|
| ![Title page](screenshots/title-page.png) | ![Main menu](screenshots/main-menu.png) | ![Token picker](screenshots/token-picker.png) |

| Line editor | Symbol picker | Adjust margins |
|:---:|:---:|:---:|
| ![Line editor](screenshots/line-editor.png) | ![Symbol picker](screenshots/icon-picker.png) | ![Adjust margins](screenshots/adjust-margins.png) |

| Progress bar styles |
|:---:|
| ![Progress bar styles](screenshots/progress-bars-styles.png) |

### Quick start

1. Copy `bookends.koplugin/` to your KOReader plugins directory ([paths](#installation))
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

You don't need to memorise tokens — the editor has a **Tokens** picker with the full list, and a **live preview** that updates as you type. The built-in presets and the token reference below cover much more.

### Preset library

Open **Bookends → Preset → Preset library…** (or bind the *Open preset library* gesture) for a single central modal that handles everything: creating, editing, starring for the cycle gesture, and browsing community presets from an online gallery.

**My presets tab** — your presets. Tap any row to preview it live on your overlay. Tap **Apply** to commit; tap **Close** to revert. Tap the ★ on the left of a row to add/remove it from the cycle gesture. Use **+ Save current as new preset** (top of the Bookends menu) to snapshot your current overlay. Long-press any preset row to rename, edit its description, duplicate, or delete it.

A virtual **(No overlay)** row lets you star "nothing" for the cycle — useful for quickly hiding all overlays with a gesture.

When a preset is "active", your subsequent overlay edits **autosave back to the file** — no separate save step. Tweak in the regular menus, it's saved.

**Gallery tab** — community presets from [**AndyHazz/bookends-presets**](https://github.com/AndyHazz/bookends-presets). Tap a preset to preview it live; tap **Install** to save it locally. Presets already installed on your device show a ✓ indicator. Fresh installs ship with **Basic bookends** as a starter; the classic *Rich Detail*, *Speed Reader*, *Classic Alternating* and *SimpleUI status bar* presets are available from the Gallery.

Want to share a preset? See the [gallery repo's README](https://github.com/AndyHazz/bookends-presets#for-contributors--how-to-submit-a-preset) for the submission flow.

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
| `%chap_num` | Current chapter number | *3* |
| `%chap_count` | Total chapter count | *24* |
| `%filename` | File name (no path/extension) | *The_Great_Gatsby* |
| `%lang` | Book language | *en* |
| `%format` | Document format | *EPUB* |
| `%highlights` | Number of highlights | *3* |
| `%notes` | Number of notes | *1* |
| `%bookmarks` | Number of bookmarks | *5* |
| `%annotations` | Total annotations (highlights + notes + bookmarks) | *9* |

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

> Custom date and time formats use `%datetime{spec}`, which accepts any [strftime spec](https://strftime.net/). Example: `%datetime{%d %B}` → "23 April". For the common cases, use the fixed tokens like `%date` and `%time`.

#### Reading

| Token | Description | Example |
|-------|-------------|---------|
| `%chap_time_left` | Time left in chapter | *0h 12m* |
| `%book_time_left` | Time left in book | *3h 45m* |
| `%book_read_time` | Total reading time for book | *2h 30m* |
| `%session_time` | Session reading time | *0h 23m* |
| `%session_pages` | Session pages read | *14* |
| `%speed` | Reading speed (pages/hour) | *42* |

#### Device

| Token | Description | Example |
|-------|-------------|---------|
| `%batt` | Battery level | *73%* |
| `%batt_icon` | Battery icon (dynamic) | Changes with charge level |
| `%wifi` | Wi-Fi icon (dynamic) | Hidden when off, changes when connected/disconnected |
| `%plugin_content` | Plugin content (dynamic) | Aggregates output from plugins that register with KOReader's footer hook (e.g. `kobo.koplugin` Bluetooth, `readtimer.koplugin` countdown); hidden when none are reporting. Add a brace filter to restrict to one plugin: `%plugin_content{readtimer}` shows only the read-timer countdown, `%plugin_content{kobo}` only kobo.koplugin's contribution. |
| `%light` | Frontlight brightness | *18* or *OFF* |
| `%warmth` | Frontlight warmth | *12* |
| `%mem` | RAM usage percentage | *33%* |
| `%ram` | RAM usage in MiB | *128 MiB* |
| `%disk` | Free disk space | *2.4 GB* |
| `%invert` | Page-turn direction indicator | Changes when inverted |

Page tokens respect **stable page numbers** and **hidden flows** (non-linear EPUB content). Time-left and reading speed tokens use the **statistics plugin**. Session timer and pages reset each time you wake the device.

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
| `book_read_time` | minutes | Total time spent reading this book (matches `%book_read_time`) — needs statistics plugin |
| `page_num` | 1–N | Current page number (matches `%page_num`) |
| `page_count` | count | Total page count (matches `%page_count`) |
| `pages_left` | count | Pages left in book (matches `%pages_left`) |
| `highlights` | count | Number of highlights in this book (matches `%highlights`) |
| `notes` | count | Number of notes in this book (matches `%notes`) |
| `bookmarks` | count | Number of bookmarks in this book (matches `%bookmarks`) |
| `speed` | pages/hr | Reading speed |
| `session` | minutes | Session reading time |
| `session_time` | minutes | Alias for `session`, matching the `%session_time` token name |
| `session_pages` | count | Session pages read |
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

## License

AGPL-3.0 — see [LICENSE](LICENSE)
