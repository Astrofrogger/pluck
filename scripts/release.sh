#!/bin/zsh
# Publishes a release: ./scripts/release.sh 1.1.0 ["What changed"]
# Builds Pluck.app, packages Pluck.dmg (for people) and Pluck.zip + checksum (for the in-app
# updater), commits the version bump, tags it, pushes, and creates the GitHub release.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
CHANGES="${2:-}"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }

PLIST=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" "$PLIST"

./scripts/build-app.sh

rm -rf dist && mkdir dist
ditto -c -k --keepParent build/Pluck.app dist/Pluck.zip
(cd dist && shasum -a 256 Pluck.zip > Pluck.zip.sha256)

STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R build/Pluck.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp scripts/dmg-readme.txt "$STAGE/Read Me First.txt"
hdiutil create -quiet -volname "Pluck $VERSION" -srcfolder "$STAGE" -ov -format UDZO dist/Pluck.dmg

NOTES=$(mktemp)
{
  [[ -n "$CHANGES" ]] && printf '%s\n\n' "$CHANGES"
  cat scripts/release-notes.md
} > "$NOTES"

git add "$PLIST"
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" dist/Pluck.dmg dist/Pluck.zip dist/Pluck.zip.sha256 \
  --title "Pluck $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
echo "Released $VERSION"
