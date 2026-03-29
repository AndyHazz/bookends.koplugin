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

| Reading page | Menu with previews |
|:---:|:---:|
| ![Reading page](screenshots/reading-page.png) | ![Menu previews](screenshots/menu-previews.png) |

| Line editor | Icon picker | Token picker |
|:---:|:---:|:---:|
| ![Line editor](screenshots/line-editor.png) | ![Icon picker](screenshots/icon-picker.png) | ![Token picker](screenshots/token-picker.png) |

### Quick start

1. Copy `plugins/bookends.koplugin/` to your KOReader plugins directory
2. Open a book
3. Go to the **typeset/document menu** (style icon) and find **Bookends**
4. Enable bookends
5. Tap a position (e.g., Bottom-center)
6. Tap **Add line**
7. Type a format string like `%c / %t` or use the **Tokens** and **Icons** buttons to insert
8. Tap **Save**

### Tokens

Tokens are placeholders that expand to live values. Insert them by typing `%` followed by a letter, or use the **Tokens** button in the line editor.

#### Metadata

| Token | Description | Example |
|-------|-------------|---------|
| `%T` | Document title | *The Great Gatsby* |
| `%A` | Author(s) | *F. Scott Fitzgerald* |
| `%S` | Series with index | *Dune #1* |
| `%C` | Chapter/section title | *Chapter 3: The Valley* |

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
| `%R` | Session reading time | *0h 23m* |
| `%s` | Session pages read | *14* |

#### Device

| Token | Description | Example |
|-------|-------------|---------|
| `%b` | Battery level | *73%* |
| `%B` | Battery icon (dynamic) | Changes with charge level |
| `%W` | Wi-Fi icon (dynamic) | Changes with connection status |
| `%m` | RAM usage | *33%* |

Page tokens respect **stable page numbers** and **hidden flows** (non-linear EPUB content). Time-left tokens use the **statistics plugin** reading speed data. Session pages tracks forward progress only (going back doesn't inflate the count).

### Icons

The **Icons** button in the line editor opens a picker with categorised glyphs from the Nerd Fonts set (bundled with KOReader). Icons are inserted as literal Unicode characters. Categories include:

- **Dynamic** -- Battery and Wi-Fi icons that change with device state (inserts `%B` / `%W` tokens)
- **Status** -- Bookmark, memory chip
- **Time** -- Watch, hourglass
- **Symbols** -- Sun, card suits (spade/club/heart/diamond), stars
- **Arrows** -- Directional arrows, triangles, angle brackets
- **Separators** -- Vertical bar, bullets, dots, ellipsis, dashes, slashes
- **Misc** -- Check/cross marks, infinity, section signs, daggers, copyright

### Per-line styling

Each line has its own style controls in the editor dialog:

- **Style** -- Cycles through: Regular, Bold, Italic, Bold Italic
- **Uppercase** -- Toggle uppercase rendering (displays "AA" when on, "Aa" when off)
- **Size** -- Font size in pixels (defaults to global setting)
- **Font** -- Choose from the full CRE font list (checkmark shows current selection)
- **Nudge** -- Fine-tune vertical and horizontal position of individual lines with arrow buttons

Italic uses NotoSans-Italic / NotoSerif-Italic font variants. Font and size default to the global settings if not overridden per-line.

### Managing lines

- Tap a **line entry** in a position's submenu to edit it
- Tap **Add line** to add a new line to the position
- **Long-press** a line entry for options: **Move up**, **Move down**, **Move to** another position, or **Delete**
- Saving an empty line automatically removes it
- The editor shows a **live preview** of your format string as you type

### Smart ellipsis

When text would overlap between positions on the same row (top or bottom), Bookends automatically truncates with ellipsis. **Center positions always get priority** -- left and right text is truncated first. A configurable minimum gap prevents text from butting up against each other.

### Presets

Save and load complete configurations:

1. Set up all your positions, lines, fonts, and offsets
2. Go to **Bookends > Presets > Create new preset from current settings**
3. Name it (e.g., "Minimal", "Full status", "Reading session")
4. To load: tap the preset name
5. To manage: long-press a preset for Update, Delete, or Rename

Presets store everything: enabled state, all positions with lines/styles/fonts, all default settings.

Several built-in presets are included: **Minimal**, **Full status**, **Book info**, and **Chapter focus**.

### Global settings

At the bottom of the Bookends menu:

| Setting | Default | Description |
|---------|---------|-------------|
| Default font | Status bar font | Base font for all overlays |
| Default font size | Status bar size | Base size for all overlays |
| Default vertical offset | 35px | Distance from screen edge (all positions) |
| Default horizontal offset | 10px | Distance from screen edge (corners only) |
| Overlap gap | 10px | Minimum space between adjacent texts |
| Truncation priority | Center | Which positions get priority when text overlaps (Center or Sides) |

### Example configurations

**Minimal page counter** (bottom-center):
```
Line 1: %c / %t
```

**Book info header** (top-center, two lines):
```
Line 1: %A          (Bold)
Line 2: %T          (Italic, smaller font)
```

**Reading session** (bottom-left):
```
Line 1: %s pages in %R
```

**Status corner** (top-right):
```
Line 1: %B %b  %k
```

**Chapter progress** (bottom-right):
```
Line 1: %C
Line 2: %g / %G (%P)
```

---

## Installation

**Via the KOReader App Store:** Search for "bookends" and install.

**Manual install:** Download or clone this repo into your KOReader plugins directory:

| Device | Path |
|--------|------|
| Kindle | `/mnt/us/koreader/plugins/bookends.koplugin/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/bookends.koplugin/` |
| Android | `<koreader-dir>/plugins/bookends.koplugin/` |

Restart KOReader after installing.

## Compatibility

Tested on KOReader 2025.08+ (Kindle PW5). Should work on any KOReader device.

## License

AGPL-3.0 — see [LICENSE](LICENSE)
