# KOReader Mods

A collection of patches and plugins for [KOReader](https://github.com/koreader/koreader).

## Patches

User patches go in the KOReader `patches/` directory. Copy the `.lua` file and restart KOReader.

| Patch | Description |
|-------|-------------|
| [2-suppress-opening-dialog.lua](patches/2-suppress-opening-dialog.lua) | Hides the "Opening file '...'" dialog that briefly flashes when opening a book. It has a zero timeout and disappears too fast to read — just visual noise. |
| [2-coverbrowser-swipe-updown.lua](patches/2-coverbrowser-swipe-updown.lua) | Adds up/down swipe for page navigation in CoverBrowser History/Collections views. Swipe up = next page, swipe down = previous page. |

## Plugins

Plugins go in the KOReader `plugins/` directory. Copy the entire `.koplugin` folder and restart KOReader.

| Plugin | Description |
|--------|-------------|
| [displaymodehomefolder.koplugin](plugins/displaymodehomefolder.koplugin) | Use a different display mode and sort order in subfolders compared to the home folder. For example: home folder shows a cover grid sorted by date, series subfolders show a detailed list sorted by series reading order. Integrates into CoverBrowser's Display Mode menu. ([FR #15198](https://github.com/koreader/koreader/issues/15198)) |
| [footertext.koplugin](plugins/footertext.koplugin) | Display a configurable text label centered at the bottom of the reading screen, independent of the status bar. Default: "Page 28". Uses the same format tokens as the sleep screen message (`%c`, `%t`, `%T`, etc.). |

## Installation paths

| Device | Patches | Plugins |
|--------|---------|---------|
| Kindle | `/mnt/us/koreader/patches/` | `/mnt/us/koreader/plugins/` |
| Kobo | `/mnt/onboard/.adds/koreader/patches/` | `/mnt/onboard/.adds/koreader/plugins/` |
| Android | Varies — find your KOReader install directory | Same |

Create the `patches/` directory if it doesn't already exist.

## Compatibility

Tested on KOReader 2024.11+ (Kindle PW5). Should work on any KOReader device.

## License

MIT
