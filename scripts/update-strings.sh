#!/bin/zsh
# Refreshes Resources/Localizable.xcstrings from the code: the compiler extracts every localizable
# string (SwiftUI text and String(localized:)), and xcstringstool merges them into the catalog,
# keeping existing translations and marking strings that are no longer used as stale.
set -euo pipefail
cd "${0:A:h}/.."
OUT=$(mktemp -d)
swift build --build-system native -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
[[ -f Resources/Localizable.xcstrings ]] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > Resources/Localizable.xcstrings
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$OUT"/*.stringsdata
rm -rf "$OUT"
echo "Updated Resources/Localizable.xcstrings"
