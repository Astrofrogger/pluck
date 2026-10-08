#!/bin/zsh
# Builds Pluck.app into ./build. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

# Universal binary so it runs on both Apple Silicon and Intel Macs.
MIN_MACOS=14.0
SDK_VERSION="$(xcrun --show-sdk-version)"
# The universal build otherwise stamps the binary with SDK = MIN_MACOS, and macOS then treats
# Pluck as an old app: no Liquid Glass window buttons or controls. Record the real SDK.
FLAGS=(--arch arm64 --arch x86_64
       -Xlinker -platform_version -Xlinker macos -Xlinker $MIN_MACOS -Xlinker $SDK_VERSION)
swift build -c release $FLAGS
BIN="$(swift build -c release $FLAGS --show-bin-path)"
for arch in arm64 x86_64; do
  STAMP=$(vtool -arch $arch -show-build "$BIN/Pluck" | awk '/ sdk /{print $2}')
  [[ "$STAMP" == "$SDK_VERSION" ]] || { echo "Binary ($arch) is stamped with SDK $STAMP, expected $SDK_VERSION" >&2; exit 1; }
done

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
