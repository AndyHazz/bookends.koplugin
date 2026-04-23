# Bookends 4.3.0 — release notes

## New: colour picker on colour e-ink devices

On Kindle Colorsoft, Kobo Libra Colour, Boox Go Color, and any other colour-capable e-ink device, every colour setting in Bookends (text, icons, and progress-bar fill / background / track / ticks / border / inversion / metro-read) now opens a curated palette picker instead of the `% black` nudge.

The picker shows a 5×5 grid of swatches — five families of five shades (neutrals, warm dark, warm light, cool dark, cool light) — plus a hex input field for any `#RRGGBB` or `#RGB` value you want to type directly. Tap any swatch and the bar repaints immediately around the edge of the dialog; tap **Apply** to commit, **Cancel** to revert, or **Default** to clear the field.

On greyscale devices the picker is not shown — the existing `% black` nudge behaves exactly as before.

## New: true-colour text and icon glyphs

Setting a non-grey **Text color** or **Icon color** (previously "Symbol color") on a colour device now paints overlay text and Nerd-Font / FontAwesome icon glyphs in that colour. Previously the setting stored a hex value but rendered as its greyscale luminance because of a limitation in KOReader's `TextWidget`; this release works around that with a small surgical patch so Bookends-specific text paints in true colour.

The Icon color setting has been renamed from "Symbol color" to better reflect what it actually affects — Nerd Font / FontAwesome icon glyphs in the Private Use Area (U+E000–U+F8FF), not general Unicode symbols like the hourglass (U+231B). Long-press the menu item for the full explanation.

## New: inline `[c=#RRGGBB]` and `[c=#RGB]` in format strings

Format-string lines now accept hex colour tags alongside the existing `[c=N]` greyscale-percent tags. So a line like `[c=#FF0000]WARNING[/c] %k` paints the word WARNING in red. Short-form CSS hex (`[c=#F00]`) works too.

An inline `[c=…]` tag on a PUA icon glyph overrides the global Icon color for just that glyph — so you can have most icons in blue but one highlighted in red via `[c=#F00]%B[/c]`.

## New: Preset Gallery colour flag

Presets that use colour values are marked with a small four-stripe colour flag in the top-right corner of their card in the Preset Library. Greyscale-only presets (including ones that use only neutrals from the palette's top row) stay unmarked — the flag is purely informational, a visual cue that a preset is designed with colour hardware in mind.

## Cross-device preset portability

Presets authored on colour hardware render sensibly on greyscale devices too. Every stored hex value falls back to its Rec.601 luminance at paint time on greyscale screens, so a preset designed in hot pink on a Colorsoft still reads as a clear mid-grey on an older Kindle. The gallery-flagged presets will flatten visually on greyscale devices but won't break.

Picking a neutral (`r == g == b`) from the palette stores the value as `{grey = N}` rather than `{hex = "#XXXXXX"}`, so a user on a colour device building a greyscale theme doesn't accidentally flag the preset as colour-authored.

## New: metro progress bar has a visible read portion

(Shipped in 4.2.0, restated here for completeness of colour-aware behaviours.) The Metro read color applies to the trunk's read portion, the chapter ticks already reached, and the start-cap ring. When unset, metro still renders as a uniform-trunk bar — no visual change for existing users.

## Changed: Icon color menu item renamed

"Symbol color" is now "Icon color". Existing translations for the old label are preserved in locale files. Existing presets using `symbol_color = {…}` continue to work unchanged — only the on-screen label has changed.

## No visual change for existing users

Legacy presets with raw-byte or `{grey=N}` colour storage continue to render pixel-identically. Only presets that were explicitly authored with hex values show colour on a colour-capable device.

---

## Known limitations

- **KOReader's `TextWidget` hardcodes the greyscale colour blit path.** Bookends monkey-patches it in plugin init so overlay text can render in true colour. The patch is strictly additive (falls through to the unchanged upstream path when `fgcolor` isn't a `ColorRGB32`); remove the patch once upstream gains native RGB32 dispatch.
- **Book body text is unaffected by the Bookends text colour.** Book rendering goes through CRE's own font path. Only Bookends overlay text (header/footer lines, icon glyphs) is colourable.
- **Kaleido colour-filter attenuation is hardware-specific.** The curated palette is calibrated for CSS-saturated values that look sensible after Kaleido's colour-filter array reduces saturation. If the palette feels under- or over-saturated on your device, use the hex input or edit the palette in `bookends_colour_palette.lua`.
