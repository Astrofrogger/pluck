#!/bin/zsh
# Publishes a release: ./scripts/release.sh 1.1.0 ["What changed"]
# Builds both editions (basic Pluck and Pluck Studio), packages a .dmg of each (for people) and a
# .zip + checksum of each (for the in-app updater; Pluck.zip is Studio again, for Pluck 1.15 and
# older, which look for that name), commits the version bump, tags it, pushes, and creates the
# GitHub release.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
CHANGES="${2:-}"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }
grep -q "version: \"$VERSION\"" Sources/Pluck/WhatsNew.swift \
  || { echo "Add the notes for $VERSION to Sources/Pluck/WhatsNew.swift first; people see them after updating." >&2; exit 1; }

PLIST=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" "$PLIST"

./scripts/build-app.sh --edition basic
./scripts/build-app.sh --edition studio

rm -rf dist && mkdir dist
ditto -c -k --keepParent build/basic/Pluck.app dist/Pluck-Basic.zip
ditto -c -k --keepParent build/Pluck.app dist/Pluck-Studio.zip
cp dist/Pluck-Studio.zip dist/Pluck.zip
(cd dist && for zip in Pluck-Basic.zip Pluck-Studio.zip Pluck.zip; do shasum -a 256 $zip > $zip.sha256; done)

# A disk image per edition: Pluck.dmg (basic) and Pluck-Studio.dmg.
dmg() {
  local app="$1" name="$2" out="$3"
  local stage=build/dmg
  rm -rf "$stage" && mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  cp scripts/dmg-readme.txt "$stage/Read Me First.txt"
  hdiutil create -quiet -volname "$name $VERSION" -srcfolder "$stage" -ov -format UDZO "$out"
}
dmg build/basic/Pluck.app "Pluck" dist/Pluck.dmg
dmg build/Pluck.app "Pluck Studio" dist/Pluck-Studio.dmg

NOTES=$(mktemp)
{
  [[ -n "$CHANGES" ]] && printf '%s\n\n' "$CHANGES"
  cat scripts/release-notes.md
} > "$NOTES"

git add "$PLIST"
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" dist/Pluck.dmg dist/Pluck-Studio.dmg \
  dist/Pluck-Basic.zip dist/Pluck-Basic.zip.sha256 dist/Pluck-Studio.zip dist/Pluck-Studio.zip.sha256 \
  dist/Pluck.zip dist/Pluck.zip.sha256 \
  --title "Pluck $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
echo "Released $VERSION"
