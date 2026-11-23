#!/bin/bash
# Builds build/TaskRadarBar.app, installs it to /Applications and restarts it. No Xcode needed, Command Line Tools are enough.
# Optional arg: path to a note, to run the self-check against a temp copy of it.
set -euo pipefail
cd "$(dirname "$0")"

# every L("key") used in the code must exist in the English strings file
grep -ohE 'L\("([^"\\]|\\.)*"' Sources/*.swift | sed -E 's/^L\(//' | sort -u | while IFS= read -r key; do
  grep -qF -- "$key = " Resources/en.lproj/Localizable.strings || { echo "missing in en.lproj: $key"; exit 1; }
done

# self-check from the debug build: release strips precondition messages
swift build
.build/debug/taskradarbar --selftest "$@"
swift build -c release

APP=build/TaskRadarBar.app
mkdir -p "$APP/Contents/MacOS"
cp -f .build/release/taskradarbar "$APP/Contents/MacOS/TaskRadarBar"
cp -f Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# app icon: drawn by the binary itself (Sources/Logo.swift) -> iconset -> icns
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET" "$APP/Contents/Resources"
.build/release/taskradarbar --icon build/icon_1024.png
for sz in 16 32 128 256 512; do
  sips -z $sz $sz build/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) build/icon_1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# hardened runtime: no code injection via DYLD_*, only system-signed libraries can load
codesign --force --options runtime --sign - "$APP"
echo "built $APP"

# install: replace the copy in /Applications and restart it
pkill -x TaskRadarBar || true
sleep 1
ditto "$APP" /Applications/TaskRadarBar.app
touch /Applications/TaskRadarBar.app
open /Applications/TaskRadarBar.app
echo "installed and restarted /Applications/TaskRadarBar.app"
