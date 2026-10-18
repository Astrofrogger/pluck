#!/bin/zsh
# make-appex.sh <app> [decoder flags and sources…]: builds Pluck's Quick Look extensions (Finder's
# preview and thumbnails for RED and Blackmagic RAW) into <app>/Contents/PlugIns, with pluck-raw's
# decoders built in (Quick Look extensions may not start programs). The decoder flags and sources
# are build-app.sh's (the SDKs' include paths, -DPLUCK_RED…, the RED library, BRAW's dispatch).
set -euo pipefail
APP=$1; shift
DECODER=("$@")
HERE=${0:A:h}
ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
TYPES='<array><string>com.red.r3d</string><string>com.blackmagic-design.braw-movie</string></array>'
make() {   # name, principal class, extension point, source file, frameworks
  local name=$1 class=$2 point=$3 source=$4 frameworks=$5
  local appex="$APP/Contents/PlugIns/$name.appex"
  rm -rf "$appex"
  mkdir -p "$appex/Contents/MacOS"
  local attributes="<key>QLSupportedContentTypes</key>$TYPES"
  [[ $point == com.apple.quicklook.preview ]] && attributes+="<key>QLSupportsSearchableItems</key><false/>"
  [[ $point == com.apple.quicklook.thumbnail ]] && attributes="<key>QLSupportedContentTypes</key>$TYPES<key>QLThumbnailMinimumDimension</key><integer>16</integer>"
  cat > "$appex/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$ID.$name</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>Pluck</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSExtension</key><dict>
  <key>NSExtensionPointIdentifier</key><string>$point</string>
  <key>NSExtensionPrincipalClass</key><string>$name.$class</string>
  <key>NSExtensionAttributes</key><dict>$attributes</dict>
</dict>
</dict></plist>
PLIST
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -parse-as-library -application-extension -module-name $name \
      -target $arch-apple-macos14 -sdk "$(xcrun --show-sdk-path)" -import-objc-header "$HERE/Bridge.h" \
      "$HERE/RawClip.swift" "$HERE/$source" $WORK/decoder-$arch.o $LIBS ${=frameworks} \
      -framework Foundation -framework CoreFoundation -framework Metal -lc++ -ldl \
      -Xlinker -e -Xlinker _NSExtensionMain -o "$appex/Contents/MacOS/$name.$arch"
  done
  lipo -create "$appex/Contents/MacOS/$name.arm64" "$appex/Contents/MacOS/$name.x86_64" -output "$appex/Contents/MacOS/$name"
  rm "$appex/Contents/MacOS/$name.arm64" "$appex/Contents/MacOS/$name.x86_64"
  # The decoders' libraries, its own copy: the extension's sandbox can't read Pluck's.
  mkdir -p "$appex/Contents/Resources/Decoders"
  for folder in RED BRAW; do
    [[ -d "$APP/Contents/Helpers/$folder" ]] && cp -R "$APP/Contents/Helpers/$folder" "$appex/Contents/Resources/Decoders/"
  done
  codesign --force --options runtime --entitlements "$HERE/extension.entitlements" --sign - "$appex"
}
# The decoders, as a library: sources (.mm/.cpp) compiled here, libraries (.a) linked.
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
FLAGS=() SOURCES=() LIBS=()
for item in "${DECODER[@]}"; do
  case $item in
    -*) FLAGS+=($item) ;;
    *.a) LIBS+=($item) ;;
    *) SOURCES+=($item) ;;
  esac
done
for arch in arm64 x86_64; do
  objects=()
  for source in "$HERE/../PluckRaw/main.mm" $SOURCES; do
    object=$WORK/$arch-${source:t:r}.o
    clang++ -c -O2 -std=c++17 -fobjc-arc -arch $arch -mmacosx-version-min=14.0 -w -DPLUCK_RAW_LIBRARY=1 $FLAGS "$source" -o $object
    objects+=($object)
  done
  ld -r -arch $arch $objects -o $WORK/decoder-$arch.o
done
make PluckPreview PreviewViewController com.apple.quicklook.preview Preview.swift "-framework QuickLookUI -framework AppKit"
make PluckThumbnail ThumbnailProvider com.apple.quicklook.thumbnail Thumbnail.swift "-framework QuickLookThumbnailing -framework AppKit"
