# ChanSort for macOS

A native Apple Silicon channel-list editor, built from [ChanSort](https://github.com/PredatH0r/ChanSort) with a new Swift/AppKit interface and the original TV-format loaders running on a bundled ARM64 .NET runtime.

**The default branch is `master` and contains the macOS port.** This repository is maintained as a macOS fork. For the original Windows application, see [upstream ChanSort](https://github.com/PredatH0r/ChanSort).

## Download

[Download the macOS preview](https://github.com/BanVictor17/ChanSort-macOS/releases/tag/v0.1.0-macos-preview.1) and extract the ARM64 ZIP into a writable folder. Open `ChanSort.app` inside that folder.

- Apple Silicon Mac required; the build targets macOS 13 or later.
- CrossOver, Wine, Rosetta and a separate .NET installation are not required.
- Keep the app in its extracted folder. Backups, logs and temporary files are stored beside it rather than in a ChanSort Application Support directory.
- The preview is ad-hoc signed and is not notarized by Apple. macOS may require approval in Privacy & Security when opening a downloaded copy.

macOS may maintain its own system metadata. Saving an export intentionally updates the selected export at its existing location.

## What works

- Open a TV channel export and choose a channel list.
- Search channels by name.
- Move channels up, down, to the top or to the bottom.
- Edit a channel number; occupied numbers are swapped.
- Sort alphabetically or renumber from 1.
- Save with a backup of the source files and a manifest describing their original locations.

## Preview limitations

This first native version focuses on channel numbering and reordering. Renaming, favorites editing, channel deletion, reference-order copying and TV device settings are not exposed. Lists marked read-only by the loader and mixed-source favorite lists cannot be edited.

The loaders compile for macOS, but every TV model and export variant has not been verified. Load → reorder → save → reload passed with these upstream fixtures:

| Format | Channels |
| --- | ---: |
| Silva-Schneider SDX | 1,108 |
| LG binary TLL | 3,530 |
| LG XML/TLL | 150 |
| Samsung ZIP | 161 |
| M3U | 6 |

Backup contents and rejection of duplicate channel numbers were also checked. Native UI reordering and saving were exercised with the Schneider fixture. Schneider SDX verification does not establish compatibility with an untested Schneider TLL export.

## Build from source

Clone the default `master` branch, then build with Xcode command-line tools and Python 3:

```sh
git clone https://github.com/BanVictor17/ChanSort-macOS.git
cd ChanSort-macOS
./macos/build.sh
python3 macos/tests/smoke.py
```

The build installs its pinned, checksum-verified SDK and package dependencies inside the repository, publishes the bundled ARM64 engine, compiles the AppKit interface and ad-hoc signs `ChanSort.app`.

See [macOS implementation and build details](README-macOS.md). The native interface and adapter projects are in [`macos/`](macos/); the inherited ChanSort source and format loaders are in [`source/`](source/).

## Credits and license

Based on [ChanSort by Horst Beham and contributors](https://github.com/PredatH0r/ChanSort). The original project documentation and GPLv3 notice are preserved in [the upstream README](docs/readme-upstream.md).

ChanSort and this macOS adaptation are provided under GPLv3. Bundled third-party components retain their respective licenses. This is an independent macOS fork, not an official upstream macOS release.
