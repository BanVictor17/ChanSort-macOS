#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/macos/bootstrap.py"
export DOTNET_ROOT="$ROOT/.sdk"
export DOTNET_CLI_HOME="$ROOT/.dotnet-home"
export NUGET_PACKAGES="$ROOT/.nuget"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_NOLOGO=1
export TMPDIR="$ROOT/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-cache"
mkdir -p "$ROOT/logs" "$TMPDIR" "$ROOT/.build" "$CLANG_MODULE_CACHE_PATH"
APP="$ROOT/ChanSort.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Engine"
"$DOTNET_ROOT/dotnet" publish "$ROOT/macos/Backend/Backend.csproj" -c Release -r osx-arm64 --self-contained true -o "$APP/Contents/Resources/Engine" > "$ROOT/logs/build-engine.log" 2>&1
xcrun swiftc -O -target arm64-apple-macos13.0 -module-cache-path "$ROOT/.build/swift-cache" -framework AppKit "$ROOT/macos/App.swift" -o "$APP/Contents/MacOS/ChanSort"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
