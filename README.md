# Bookends

A KOReader plugin for placing configurable text overlays at the corners and edges of the reading screen. Each position supports multiple lines with independent font, size, and style settings. Format strings use tokens that expand to live book metadata, reading progress, time, and device status.

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

### Screenshots

| Title page | Speed Reader | Classic Alternating |
|:---:|:---:|:---:|
| ![Title page](screenshots/title-page.png) | ![Speed Reader](screenshots/speed-reader.png) | ![Classic Alternating](screenshots/classic-alternating.png) |

| Rich Detail | Main menu | Adjust margins |
|:---:|:---:|:---:|
| ![Rich Detail](screenshots/rich-detail.png) | ![Main menu](screenshots/main-menu.png) | ![Adjust margins](screenshots/adjust-margins.png) |

| Line editor | Symbol picker | Token picker |
|:---:|:---:|:---:|
| ![Line editor](screenshots/line-editor.png) | ![Symbol picker](screenshots/icon-picker.png) | ![Token picker](screenshots/token-picker.png) |

| Progress bar styles | Progress bar line editor |
|:---:|:---:|
| ![Progress bar styles](screenshots/progress-bars-styles.png) | ![Progress bar line editor](screenshots/progress-bars-line-editor.png) |

### Quick start

1. Copy `bookends.koplugin/` to your KOReader plugins directory
2. Open a book
3. Go to the **typeset/document menu** (style icon) and find **Bookends**
4. Enable bookends
5. Tap a position (e.g., Bottom-center)
6. Tap **Add line**
7. Type a format string like `Page %c of %t` or use the **Tokens** and **Icons** buttons to insert
8. Tap **Save**

### Built-in presets

Three presets are included to get you started:

- **Speed Reader** — Session timer, reading speed, time remaining, progress percentages
- **Classic Alternating** — Book title on even pages, chapter on odd, page number at bottom
- **Rich Detail** — All six positions with clock, battery, Wi-Fi, brightness, highlights, and more

Save your own presets via **Presets > Custom presets > Create new preset from current settings**.

### Tokens

Tokens are placeholders that expand to live values. Insert them by typing `%` followed by a letter, or use the **Tokens** button in the line editor.

#### Metadata

| Token | Description | Example |
|-------|-------------|---------|
| `%T` | Document title | *The Great Gatsby* |
| `%A` | Author(s) | *F. Scott Fitzgerald* |
| `%S` | Series with index | *Dune #1* |
| `%C` | Chapter/section title | *Chapter 3: The Valley* |
| `%N` | File name (no path/extension) | *The_Great_Gatsby* |
| `%i` | Book language | *en* |
| `%o` | Document format | *EPUB* |
| `%q` | Number of highlights | *3* |
| `%Q` | Number of notes | *1* |
| `%x` | Number of bookmarks | *5* |

#### Page / Progress

| Token | Description | Example |
|-------|-------------|---------|
| `%c` | Current page number | *42* |
| `%t` | Total pages | *218* |
| `%p` | Book percentage read | *19%* |
| `%P` | Chapter percentage read | *65%* |
| `%g` | Pages read in chapter | *7* |
| `%G` | Total pages in chapter | *12* |
| `%l` | Pages left in chapter | *5* |
| `%L` | Pages left in book | *176* |

#### Time / Date

| Token | Description | Example |
|-------|-------------|---------|
| `%k` | 12-hour clock | *2:35 PM* |
| `%K` | 24-hour clock | *14:35* |
| `%d` | Date short | *28 Mar* |
| `%D` | Date long | *28 March 2026* |
| `%n` | Date numeric | *28/03/2026* |
| `%w` | Weekday | *Friday* |
| `%a` | Weekday short | *Fri* |

#### Reading

| Token | Description | Example |
|-------|-------------|---------|
| `%h` | Time left in chapter | *0h 12m* |
| `%H` | Time left in book | *3h 45m* |
| `%E` | Total reading time for book | *2h 30m* |
| `%R` | Session reading time | *0h 23m* |
| `%s` | Session pages read | *14* |
| `%r` | Reading speed (pages/hour) | *42* |

#### Device

| Token | Description | Example |
|-------|-------------|---------|
| `%b` | Battery level | *73%* |
| `%B` | Battery icon (dynamic) | Changes with charge level |
| `%W` | Wi-Fi icon (dynamic) | Hidden when off, changes when connected/disconnected |
| `%f` | Frontlight brightness | *18* or *OFF* |
| `%F` | Frontlight warmth | *12* |
| `%m` | RAM usage | *33%* |

Page tokens respect **stable page numbers** and **hidden flows** (non-linear EPUB content). Time-left and reading speed tokens use the **statistics plugin**. Session timer and pages reset each time you wake the device.

#### Progress bars

| Token | Description |
|-------|-------------|
| `%bar` | Progress bar (type configured in line editor) |

Add a `%bar` token to any line to render an inline progress bar. The bar auto-fills available space and can be mixed with text (e.g. `%p %bar`). Use the bar controls in the line editor to set:

- **Type** — Chapter, Book, Book+ (top-level ticks), Book++ (top 2 level ticks)
- **Style** — Border, Solid, Rounded, Metro

### Full-width progress bars

Up to 8 independent progress bars rendered as dedicated layers behind text. Configure via **Full width progress bars** in the Bookends menu.

- **Anchor** — Top, Bottom, Left (vertical), Right (vertical)
- **Fill direction** — Left to right, Right to left, Top to bottom, Bottom to top
- **Style** — Solid, Bordered, Rounded, Metro
- **Chapter ticks** — Off, Top level, Top 2 levels (book type only)
- **Thickness** and **margins** with real-time nudge adjustment

Progress on EPUB documents updates smoothly per screen turn using pixel-level position tracking. Chapter tick marks vary in thickness by TOC depth.

### Smart features

- **Auto-hide** — Lines where all tokens resolve to empty or zero are automatically hidden
- **Token width limits** — Append `{N}` to any token to cap its width at N pixels: `%C{200} - %g/%G` truncates the chapter title with ellipsis if it exceeds 200 pixels. Works with `%bar{400}` to set a fixed bar width instead of auto-fill.
- **Pluralisation** — Write `%q highlight(s)` and it becomes `1 highlight` or `3 highlights`
- **Odd/even pages** — Set any line to appear on all pages, odd pages only, or even pages only
- **Auto-refresh** — Clock and other dynamic tokens update every 60 seconds

### Icons

The **Icons** button in the line editor opens a picker with categorised glyphs from the Nerd Fonts set (bundled with KOReader). Categories include:

- **Dynamic** — Battery and Wi-Fi icons that change with device state
- **Device** — Lightbulb, sun, moon, power, Wi-Fi, cloud, memory chip
- **Reading** — Book, bookmarks, eye, flag, bar chart, tachometer, sliders
- **Time** — Clock, stopwatch, watch, hourglass, calendar
- **Status** — Check, cross, info, warning, cog
- **Symbols** — Sun, warmth, card suits, stars, check/cross marks
- **Arrows** — Directional arrows, triangles, angle brackets
- **Separators** — Vertical bar, bullets, dots, dashes, slashes

### Per-line styling

Each line has its own style controls in the editor dialog:

- **Style** — Cycles through: Regular, Bold, Italic, Bold Italic
- **Uppercase** — Toggle uppercase rendering
- **Size** — Font size in pixels (defaults to global setting, affected by font scale)
- **Font** — Choose from the full CRE font list
- **Nudge** — Fine-tune vertical and horizontal position of individual lines
- **Page filter** — Show on all pages, odd pages only, or even pages only

Italic uses automatic font variant detection — searches installed fonts for matching italic variants.

### Inline formatting

Use BBCode-style tags to format parts of a line independently:

| Tag | Effect | Example |
|-----|--------|---------|
| `[b]...[/b]` | Bold | `[b]Page[/b] %c of %t` |
| `[i]...[/i]` | Italic | `[i]%C[/i] — %g/%G` |
| `[u]...[/u]` | Uppercase | `[u]chapter[/u] %P` |

Tags can be nested: `[b][i]bold italic[/i][/b]`. Tags must be properly nested — overlapping tags like `[b][i]...[/b][/i]` render as literal text. Unclosed tags also render as literal text.

Tags override the line's per-line style. If a line is set to Bold, `[i]text[/i]` renders that segment as italic (not bold italic). Use `[b][i]...[/i][/b]` for explicit bold italic.

### Margins

Bookends uses a three-layer positioning system:

1. **Global margins** (top/bottom/left/right) — Set in **Settings > Adjust margins** with real-time preview
2. **Per-position extra margins** — Additional offset for individual regions
3. **Per-line nudges** — Pixel-level fine-tuning in the line editor

### Managing lines

- Tap a **line entry** in a position's submenu to edit it
- Tap **Add line** to add a new line to the position
- **Long-press** a line entry for options: **Move up**, **Move down**, **Move to** another position, or **Delete**
- Saving an empty line automatically removes it
- The editor shows a **live preview** of your format string as you type

### Smart ellipsis

When text would overlap between positions on the same row, Bookends automatically truncates with ellipsis. Center positions get priority by default — left and right text is truncated first. Enable **Prioritise left/right and truncate long center text** to reverse this.

### Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Default font | Status bar font | Base font for all overlays |
| Font scale | 100% | Scale all text sizes (25%–300%) |
| Adjust margins | 10/25/18/18 | Independent top/bottom/left/right margins |
| Truncation gap | 50px | Minimum space between adjacent texts |
| Truncation priority | Center | Which positions get priority when text overlaps |
| Disable stock status bar | Off | Hides KOReader's built-in status bar (see below) |
| Check for updates | — | Check GitHub for new versions with one-tap install |

### Disabling the stock status bar

For the best experience, disable KOReader's built-in status bar via **Settings > Disable stock status bar**. This:

- **Reduces e-ink flicker** — Bookends no longer needs to repaint over the stock footer, eliminating extra screen refreshes on page turns
- **Frees screen space** — The stock footer's reserved area is returned to the reading area
- **Avoids duplication** — All stock status bar features (time, battery, progress, pages, etc.) are available as Bookends tokens

### Gesture support

Assign **Toggle bookends** to any gesture via **Settings > Gesture manager > Reader**. Quickly show/hide all overlays with a tap, swipe, or multi-finger gesture.

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
