#!/bin/zsh
# Builds Pluck.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

# Universal binary so it runs on both Apple Silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)"

APP=build/Pluck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pluck" "$APP/Contents/MacOS/Pluck"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Pluck.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Pluck.app"
fi
