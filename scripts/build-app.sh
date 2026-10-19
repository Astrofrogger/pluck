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
  # Camera raw clips open in Raw Player (and Finder's preview plays them): the types, declared for
  # Macs where no other app does, and Pluck as an app that opens them.
  /usr/libexec/PlistBuddy -c "Merge Resources/RawTypes.plist" "$APP/Contents/Info.plist"
  # "Play in Pluck" on clips and folders in Finder.
  /usr/libexec/PlistBuddy -c "Add :NSServices:1 dict" \
    -c "Add :NSServices:1:NSMenuItem dict" -c "Add :NSServices:1:NSMenuItem:default string Play in Pluck" \
    -c "Add :NSServices:1:NSMessage string playInPluck" -c "Add :NSServices:1:NSPortName string Pluck" \
    -c "Add :NSServices:1:NSRequiredContext dict" \
    -c "Add :NSServices:1:NSSendFileTypes array" -c "Add :NSServices:1:NSSendFileTypes:0 string public.movie" \
    -c "Add :NSServices:1:NSSendFileTypes:1 string public.folder" -c "Add :NSServices:1:NSSendFileTypes:2 string com.red.r3d" \
    -c "Add :NSServices:1:NSSendFileTypes:3 string com.blackmagic-design.braw-movie" "$APP/Contents/Info.plist"
  # RED clip folders as one item in Finder (a Settings choice): the type, in an app of its own
  # that Pluck registers with macOS only when asked. Kept in Resources so it isn't found by itself.
  TYPES_APP="$APP/Contents/Resources/RedClipTypes.app"
  mkdir -p "$TYPES_APP/Contents/MacOS"
  cp Helpers/RedClipTypes/Info.plist "$TYPES_APP/Contents/Info.plist"
  clang -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 Helpers/RedClipTypes/main.c -o "$TYPES_APP/Contents/MacOS/RedClipTypes"
  codesign --force --options runtime --sign - "$TYPES_APP"
fi

if [[ "$EDITION" == studio ]]; then
# The bridge to spektrafilm (film simulation), which Pluck downloads separately when asked.
mkdir -p "$APP/Contents/Resources/FilmEngine"
cp Resources/FilmEngine/pluck_film.py Resources/FilmEngine/NOTICE.txt Resources/FilmEngine/COPYING "$APP/Contents/Resources/FilmEngine/"
# The vision helper (Qwen on the GPU with MLX): Apple silicon only, so it's built on its own and
# Intel Macs simply don't have it. Its Metal kernels sit next to it in the Cmlx bundle.
(cd Helpers/PluckVision && swift build -c release --arch arm64 >/dev/null)
VBIN="$(cd Helpers/PluckVision && swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$APP/Contents/Helpers"
# The film engine: darktable's native spektrafilm port with Pluck's driver (GPL-3, its own program).
if [[ "$EDITION" != "basic" ]]; then
  SPK=Helpers/PluckSpektra
  clang -O3 -std=gnu11 -ffp-contract=off -fblocks -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -I$SPK/shim -I$SPK/darktable -I$SPK/shim/common -w \
    $SPK/main.c $SPK/darktable/spektra_sim.c $SPK/darktable/spektra_core.c $SPK/shim/shim.c \
    -o "$APP/Contents/Helpers/pluck-spektra"
  codesign --force --options runtime --sign - "$APP/Contents/Helpers/pluck-spektra"
fi
cp "$VBIN/pluck-vision" "$APP/Contents/Helpers/pluck-vision"
cp -R "$VBIN/mlx-swift_Cmlx.bundle" "$APP/Contents/Helpers/"
codesign --force --sign - "$APP/Contents/Helpers/mlx-swift_Cmlx.bundle"
codesign --force --options runtime --sign - "$APP/Contents/Helpers/pluck-vision"
# The raw decoder (RED and Blackmagic RAW) with the camera makers' own libraries, from their SDKs
# (which aren't in this repository: their licences don't allow sharing them). Without an SDK,
# Pluck is built without that format. PLUCK_RAW_SDKS points at the folder with red/ and braw/.
SDKS="${PLUCK_RAW_SDKS:-${0:A:h}/../../sdks}"
RED_SDK=("$SDKS"/red/R3DSDK*(N/))
BRAW_SDK="$SDKS/braw/SDK/Mac"
RAW_FLAGS=() RAW_SOURCES=()
if (( ${#RED_SDK} )); then
  RAW_FLAGS+=(-DPLUCK_RED=1 -I"$RED_SDK[1]/Include")
  RAW_SOURCES+=("$RED_SDK[1]/Lib/mac64/libR3DSDK-libcpp.a")
  mkdir -p "$APP/Contents/Helpers/RED"
  cp "$RED_SDK[1]"/Redistributable/mac/REDR3D.dylib "$RED_SDK[1]"/Redistributable/mac/REDMetal.dylib "$APP/Contents/Helpers/RED/"
fi
if [[ -d "$BRAW_SDK" ]]; then
  RAW_FLAGS+=(-DPLUCK_BRAW=1 -I"$BRAW_SDK/Include")
  RAW_SOURCES+=("$BRAW_SDK/Include/BlackmagicRawAPIDispatch.cpp")
  mkdir -p "$APP/Contents/Helpers/BRAW"
  cp -R "$BRAW_SDK/Libraries/BlackmagicRawAPI.framework" "$APP/Contents/Helpers/BRAW/"
fi
if (( ${#RAW_FLAGS} )); then
  clang++ -O2 -std=c++17 -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -w $RAW_FLAGS \
    Helpers/PluckRaw/main.mm $RAW_SOURCES -framework Foundation -framework CoreFoundation -framework Metal -ldl \
    -o "$APP/Contents/Helpers/pluck-raw"
  codesign --force --options runtime --entitlements Helpers/PluckRaw/entitlements.plist --sign - "$APP/Contents/Helpers/pluck-raw"
  # Finder's preview (the space bar) and thumbnails for the same clips, with the decoders built in.
  Helpers/PluckQuickLook/make-appex.sh "$APP" $RAW_FLAGS $RAW_SOURCES
else
  echo "No camera raw SDKs in $SDKS: building without the raw decoder" >&2
fi
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
