# Changelog

All notable changes to GetThatNote. Format follows [Keep a Changelog](https://keepachangelog.com); versions follow semver.

## [2.3.0] — 2026-09-01
### Added
- **Open on your current Space & screen** (Settings › General › Window, on by default): summoning GetThatNote brings the note window to whatever Space and display you're working on — and it stays with you when you switch Spaces while it's open — instead of macOS yanking you back to the Space where the window last lived. Turn it off to get the old single-Space behavior.

## [2.2.0] — 2026-08-22
### Fixed
- Editor: typing on an empty line or at the start of a line could let WebKit restructure the note's DOM, desyncing it from the model — backspace then looked dead until you swiped to another note and back. Typing at line boundaries now goes through the model directly.
- Editor: caret tracking could go stale after such a desync (deletes silently did nothing).
- Window: the app no longer fills/zooms the window on its own when the top strip is double-clicked (macOS's "double-click title bar to Fill" action). The window now only changes size when you resize it; position and size are remembered.
### Added
- Proper build lifecycle: `VERSION` file, git repository, `./build.sh [install|release|clean]`, version + git hash stamped into the app (About screen and Info.plist), and this changelog.
- GitHub Actions workflow: pushing a `vX.Y.Z` tag builds the app on a free macOS runner and publishes the zip to GitHub Releases with the matching changelog section as notes.

## [2.1.0] — 2026-08-22
### Changed
- Renamed **Antinote → GetThatNote** (bundle id `com.free.getthatnote`); new app icon. Notes and settings migrate from the old folder automatically.
- Universal binary (Apple Silicon + Intel), minimum macOS 13 — shareable with other Macs.
### Added
- `getthatnote://` URL scheme (`antinote://` links still work).
- Escape key forwarded to the app natively.
- `GetThatNote.zip` build artifact for sharing.

## [2.0.0] — 2026-08-22
### Added
- Initial release: full clone of Antinote 2.0's documented features — keywords (list, math, sum, avg, count, code, timer, paste), inline math with unit/currency/crypto conversion and reactive variables, checkboxes/bullets/numbered lists, simple Markdown, link shrinking, screenshot-to-text (Vision OCR), AutoPaste, slotted notes + split screen, search with reorder/multi-select, find & replace, The Void, export (txt/md/PDF/print/Apple Notes/Obsidian/Bear/custom URL/zip), `::` extensions (~180 built-in commands + custom JS + AI providers), 14 themes + Theme Maker, paper types, translucency, global hotkey ⌥A, dock/menu-bar/dropdown window modes, pin-on-top, SQLite storage with auto-backups, iCloud-Drive sync with line-level merge and optional encryption, `antinote://` URL schemes, notification/sound/full-screen timer alerts.
