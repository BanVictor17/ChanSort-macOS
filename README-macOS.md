# ChanSort for macOS — native preview

Open **ChanSort.app** in this folder. This build runs on Apple Silicon with a Swift/AppKit interface and the upstream ChanSort loaders on a bundled ARM64 .NET runtime. It requires no CrossOver, Wine, Rosetta, or globally installed .NET.

Use **Open export…**, select a channel list, then move channels with the buttons or double-click a number to swap it with an occupied position. Search filters the view; moves and alphabetical sorting operate on the full selected list. **Save with backup** updates the selected TV export after copying its source files into `backups/`. Each backup contains a `manifest.json` linking the originals to their backup copies.

Keep the app inside a writable folder. Application-owned backups, logs, temporary files and development dependencies stay beside the app. It does not create a ChanSort Application Support directory or save preferences. macOS may maintain its own system metadata. Saving a user-selected export intentionally writes to that export's location.

## Scope

This is a first native port for channel numbering and reordering, not full feature parity with the Windows UI. It preserves existing channel metadata. Renaming, favorite editing, deleting channels, copying reference orders and TV device settings are not exposed yet. Mixed-source favorite lists and lists marked read-only by the upstream loader are not editable. The bundled loaders compile for macOS, but not every TV model has been tested.

Verified load/reorder/save/reload with upstream fixtures:

- Silva-Schneider SDX: 1,108 channels
- LG binary TLL: 3,530 channels
- LG XML/TLL: 150 channels
- Samsung ZIP: 161 channels
- M3U: 6 channels

Schneider brand alone does not identify a format. The included Silva-Schneider fixture uses `.sdx`; `.tll` support was tested using LG fixtures. The user's own TV export still needs verification.

## Source and build

The macOS port is published at https://github.com/BanVictor17/ChanSort-macOS on the default branch `main`, forked from https://github.com/PredatH0r/ChanSort. The upstream history is preserved.

Build with Xcode command-line tools and Python 3:

```sh
./macos/build.sh
python3 macos/tests/smoke.py
```

The build downloads a pinned, SHA-512-verified .NET SDK into `.sdk/`, restores packages into `.nuget/`, builds each original loader for .NET 10, publishes a self-contained engine, compiles the AppKit interface and ad-hoc signs `ChanSort.app`. Logs are in `logs/`.

The adapter projects live in `macos/`; the upstream Windows solution remains separate. The small change to the LG binary loader skips loading the Windows settings interface on macOS. Device-settings dialogs remain unavailable in this preview.

ChanSort is GPLv3. See [the preserved upstream README](docs/readme-upstream.md) for its license notice. macOS adaptation sources are provided under the same license; bundled third-party components retain their respective licenses.
