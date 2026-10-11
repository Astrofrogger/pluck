#!/bin/zsh
# Builds Pluck.app: Pluck Studio into ./build (the default), basic Pluck with --edition basic into
# ./build/basic. Pass --install to copy it to /Applications.
set -euo pipefail
cd "${0:A:h}/.."

EDITION=studio
INSTALL=""
while (( $# )); do
  case "$1" in
    --edition) EDITION="$2"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    *) echo "usage: build-app.sh [--edition studio|basic] [--install]" >&2; exit 1 ;;
  esac
done
[[ "$EDITION" == studio || "$EDITION" == basic ]] || { echo "Unknown edition $EDITION" >&2; exit 1; }
export PLUCK_EDITION=$EDITION
# Each edition builds in its own folder (they're different builds of the same code).
SCRATCH=.build
[[ "$EDITION" == basic ]] && SCRATCH=.build-basic

# Universal binary so it runs on both Apple Silicon and Intel Macs.
MIN_MACOS=14.0
SDK_VERSION="$(xcrun --show-sdk-version)"
# The universal build otherwise stamps the binary with SDK = MIN_MACOS, and macOS then treats
# Pluck as an old app: no Liquid Glass window buttons or controls. Record the real SDK.
FLAGS=(--arch arm64 --arch x86_64
       -Xlinker -platform_version -Xlinker macos -Xlinker $MIN_MACOS -Xlinker $SDK_VERSION)
swift build -c release --scratch-path $SCRATCH $FLAGS
BIN="$(swift build -c release --scratch-path $SCRATCH $FLAGS --show-bin-path)"
for arch in arm64 x86_64; do
  STAMP=$(vtool -arch $arch -show-build "$BIN/Pluck" | awk '/ sdk /{print $2}')
  [[ "$STAMP" == "$SDK_VERSION" ]] || { echo "Binary ($arch) is stamped with SDK $STAMP, expected $SDK_VERSION" >&2; exit 1; }
done

APP=build/Pluck.app
[[ "$EDITION" == basic ]] && APP=build/basic/Pluck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pluck" "$APP/Contents/MacOS/Pluck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$EDITION" == studio ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Pluck Studio" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Pluck Studio" "$APP/Contents/Info.plist"
fi

if [[ "$EDITION" == studio ]]; then
# The vision helper (Qwen on the GPU with MLX): Apple silicon only, so it's built on its own and
# Intel Macs simply don't have it. Its Metal kernels sit next to it in the Cmlx bundle.
(cd Helpers/PluckVision && swift build -c release --arch arm64 >/dev/null)
VBIN="$(cd Helpers/PluckVision && swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$APP/Contents/Helpers"
cp "$VBIN/pluck-vision" "$APP/Contents/Helpers/pluck-vision"
cp -R "$VBIN/mlx-swift_Cmlx.bundle" "$APP/Contents/Helpers/"
codesign --force --sign - "$APP/Contents/Helpers/mlx-swift_Cmlx.bundle"
codesign --force --options runtime --sign - "$APP/Contents/Helpers/pluck-vision"
# The private network for Edit Anywhere (Tailscale's engine, in Go): both architectures, so it
# runs on every Mac Pluck runs on. Without Go installed, Pluck is built without it.
GO="$(command -v go || echo /opt/homebrew/bin/go)"
if [[ -x "$GO" ]]; then
  TUN=build/tunnel
  mkdir -p $TUN
  (cd Helpers/PluckTunnel && for arch in arm64 amd64; do
     CGO_ENABLED=0 GOOS=darwin GOARCH=$arch "$GO" build -trimpath -ldflags "-s -w" -o ../../$TUN/pluck-tunnel-$arch . || exit 1
   done)
  lipo -create $TUN/pluck-tunnel-arm64 $TUN/pluck-tunnel-amd64 -output "$APP/Contents/Helpers/pluck-tunnel"
  codesign --force --options runtime --sign - "$APP/Contents/Helpers/pluck-tunnel"
else
  echo "Go isn't installed: building without Edit Anywhere's private network" >&2
fi
fi
# Translations: compile the String Catalog into <language>.lproj/Localizable.strings.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" >/dev/null
mkdir -p "$APP/Contents/Resources/en.lproj"   # English is the source language; marks it as available

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Hardened runtime: blocks code injection (DYLD_* variables, unsigned libraries) into Pluck.
codesign --force --options runtime --sign - "$APP"
echo "Built $APP"

if [[ -n "$INSTALL" ]]; then
  rm -rf /Applications/Pluck.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Pluck.app"
fi
