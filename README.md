# GetThatNote

**GetThatNote** is a from-scratch, open clone of [Antinote](https://antinote.io) — the macOS scratchpad for notes you're going to throw away — with every documented feature, in the smallest possible package:

| File | What it is |
|---|---|
| `app.html` | The whole app: editor, keywords (`list` `math` `sum` `avg` `count` `code` `timer` `paste`), math engine with units/currency/variables, markdown, links, extensions (`::`), search, find & replace, The Void, export, settings, themes, sync merge. Zero dependencies. Also runs in a plain browser (degraded: no hotkey/OCR/menu bar). |
| `GetThatNote.swift` | The native macOS shell (AppKit + WKWebView): global hotkey, dock / pseudo-menu-bar / traditional menu-bar dropdown / nothing modes, pin on top, translucency, Apple Vision OCR, AutoPaste clipboard watcher, SQLite notes database + auto-backups, `antinote://` URL schemes, Apple Notes / Obsidian / Bear / txt / md / PDF / print export, notifications, sounds, full-screen timer alerts, iCloud-Drive sync (optionally AES-GCM encrypted). |
| `build.sh` | Builds `GetThatNote.app` (needs Xcode command line tools). |

## Build & install

```bash
./build.sh
cp -R GetThatNote.app /Applications/
open /Applications/GetThatNote.app
```

First launch: macOS asks about notifications (timers). Apple Notes export asks for Automation permission the first time. ⌥A is the global hotkey (customize in Settings > Shortcuts). If you used `dockMode` "Nothing", the only way in is the hotkey.

## Using it (same as Antinote)

- **Swipe** two fingers left/right to move between notes; swipe past the newest to create one; empty notes delete themselves. `⌘[` `⌘]` `⌘1` jump to front, `⌘⇧1` promote, `⌘D` delete (→ The Void), `⌘N` new, arrows enter a note after swiping.
- **Keywords** on the first line: `list` (`/x` at end of a line checks it), `math` (end a line with `=`; `name : value` makes a reactive variable; `10 USD to JPY =`, `175 cm to in =`, `100 + 15% =`, `50% of 200 =`, `√16`, `5!`, `log2(8)`…), `sum`, `avg`, `count`, `code: py`, plus `timer …` and `paste` commands on any line. Type `/` at the start of a line to pick one; `title` with `list: Groceries`.
- **Checkboxes/bullets/numbers anywhere**: start a line with `[] `, `[x] `, `- [ ] `, `- `, `1. `. Return continues, Return on an empty item ends, Tab/⇧Tab indent, numbers self-renumber.
- **Markdown**: `#`/`##`/`###`, `**bold**`, `*italic*`, `~~strike~~`, `__underline__`, `` `code` ``, ``` fences, `//` comments. `⌘B ⌘I ⌘U ⌘⇧X ⌘⇧H ⌘/ ⌥↑ ⌥↓`.
- **Links** shorten to `+host/...ending+`; ⌘-click opens, ⌘⇧-click expands, ⌘↩ opens the link at the cursor, copies are always the full URL.
- **Timer**: `timer` (stopwatch) · `timer 3.5` / `timer 3:30` · `timer 5: Laundry` · `timer 25 5` / `timer pomo` · `timer p` / `r` / `s`. Gutter shows progress; click pauses, double-click stops, `⌘⇧M` full screen.
- **AutoPaste**: type `paste` (or `paste(, )`) and press Return; everything you copy lands in the note. Esc stops.
- **Extensions**: type `::` for 180+ commands (`::today`, `::sort_lines_az`, `::roll(2d6)`, `::json_format`, `::loan(250000, 6, 30)`, `::ai("summarize")`…). Custom ones go in `~/Library/Application Support/GetThatNote/Extensions/` as `name.js` or `name/extension.json + index.js`:
  ```js
  antinote.register({ name: "shout", description: "UPPERCASE the line + suffix", type: "replaceLine",
    params: [{ name: "suffix", default: "!" }], run: (ctx, suffix) => ctx.line.toUpperCase() + suffix });
  // type: insert | replaceLine | replaceAll | openURL — ctx: line, body, header, note, selection, vars, fmt(), math(), fetch(), ai()
  ```
- **Slotted notes** (`⌘T`, planets bar, `⌘⇧T` split screen), **Search** (`⌘F`: drag to reorder, list/cards, multi-select), **Find & Replace** (`⌘⇧F`), **The Void** (File menu), **Export** (`⌘S` quick export), **Lock** (`⌘L`), **Pin** (`⌘P`), **Settings** (`⌘,`).
- **Themes**: 14 built in (Antinote Light/Dark, Mononoke, Gundam, Tokyo Drift, Vendetta, Piccolo, A24, Brave, Agrabah, Totoro, Akira, Matrix, Zelda); build your own in Settings > Appearance > Theme Maker, or drop JSON into `~/Library/Application Support/GetThatNote/Themes/`.
- **URL schemes**: `getthatnote://x-callback-url/createNote?content=…` (also accepts `antinote://` for Raycast/Alfred workflows), `appendToCurrent`, `overwriteCurrent`, `promoteAndOpen?noteId=`, `togglePin`, `hotkey`, `search?searchTerm=…&x-success=…`, `reloadDB`.
- **Terminal**: `defaults delete com.free.getthatnote` resets preferences; `/Applications/GetThatNote.app/Contents/MacOS/GetThatNote` launches with logs.

## Data

Notes: `~/Library/Application Support/GetThatNote/notes.sqlite` (+ timestamped backups in `backups/`). Preferences: `defaults` domain `com.free.getthatnote`. Sync (optional): `~/Library/Mobile Documents/com~apple~CloudDocs/GetThatNote/sync.json` through your own iCloud Drive — no server anywhere. Nothing is collected.

## Not identical by design

- Sync uses an iCloud Drive file with a line-level 3-way merge instead of CloudKit (no developer account needed); set the same passphrase on each Mac to encrypt it.
- Apple Notes export uses AppleScript directly (no Shortcut to install).
- Six of the fourteen themes are original (the eight Antinote-named ones are approximations of the screenshots).
- Currency rates come from the free `fawazahmed0/currency-api` (fiat + crypto), with an offline snapshot fallback.
