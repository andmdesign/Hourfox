# Hourfox

A minimal time tracker for macOS that lives in the MacBook notch, or in the menu bar on Macs without one.

Offline, no account, no analytics. **[Website](https://andmdesign.github.io/Hourfox/) · [Download](https://andmdesign.github.io/Hourfox/Hourfox.zip) · [На русском](README.ru.md)**

## Features

- **Timer in the notch.** Hover to expand, type what you're doing, start. Stopwatch or countdown, with pause.
- **Projects** with colours, hourly rates or a fixed price, expenses and the real per-hour result.
- **Tasks** as a list, kanban or boards by priority, project and due date.
- **Journal** as a list or a day calendar: drag to move and resize entries, split and merge them, undo mistakes.
- **Reports** by day, week, month and year, with a year map, working hours and a shareable year-in-review card.
- **Export** to PDF and CSV, with templates, rounding and scheduled reports.
- **Notes**, pinned tasks, smart input (`call @client 30m`), Apple Calendar sync.
- **Yours to shape.** Every optional feature has a switch and is off by default. 8 interface languages.

## Install

1. Download [Hourfox.zip](https://andmdesign.github.io/Hourfox/Hourfox.zip), unzip it and move Hourfox to Applications.
2. The app is not notarized yet, so macOS blocks the first launch. Open it, then allow it in **System Settings → Privacy & Security → Open Anyway**. Or review the source and build it yourself.

Requires macOS 14 or later. Works on Apple Silicon and Intel.

## Build from source

Only the Command Line Tools are needed (`xcode-select --install`), not Xcode.

```bash
./build.sh            # build/Hourfox.app
./build.sh --install  # build, copy to /Applications and launch
./build.sh --universal  # one app for Apple Silicon and Intel
```

## Your data

Everything stays in `~/Library/Application Support/Hourfox/`: `data.json`, a daily copy in `backups/` (last 30 days) and a copy of the previous launch.

Hourfox makes no network requests, with one exception. Google Calendar is compiled in but stays hidden until you supply your own OAuth client: copy `Resources/GoogleOAuth.example.plist` to `Resources/GoogleOAuth.plist` and fill it in. The file is ignored by git. The sign-in uses PKCE and a loopback redirect, and the refresh token is kept in the Keychain. Official builds ship without keys.

The website, not the app, loads the Inter font from Google Fonts and Three.js from jsDelivr.

## Project layout

| Path | What's inside |
|---|---|
| `Sources/Hourfox/` | SwiftUI and AppKit code. `NotchController` and `NotchViews` are the notch, `Store` holds the data, `JournalViews` is the main window |
| `Sources/Hourfox/Debug.swift` | Self-checks and window snapshots, see below |
| `Scripts/` | Icon generator and `l10n.py`, which builds `Localizable.strings` from `translations.json` |
| `docs/` | The website (GitHub Pages) and the download |
| `Vendor/Vortex/` | Vendored particle library |

Interface strings are keyed by their Russian text, and code comments are in Russian too.

## Checks

There is no XCTest target yet. The checks live inside the app. Run from `.build`, they use a separate data folder and their own settings domain (`Hourfox`), so your installed copy is not touched:

```bash
swift build -c release
mkdir -p /tmp/tempo-data /tmp/tempo-shots
HOURFOX_DATA_DIR=/tmp/tempo-data HOURFOX_EXTRASTEST=/tmp/tempo-shots .build/release/Hourfox
defaults delete Hourfox
```

Logic checks are stable. A few notch checks use real windows and timing, and can fail if you move the mouse during the run.

## Licenses

See [LICENSE](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
