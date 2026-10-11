#!/bin/zsh
# Publishes a release: ./scripts/release.sh 1.1.0 ["What changed"]
# Builds both editions (basic Pluck and Pluck Studio), packages a .dmg of each (for people) and a
# .zip + checksum of each (for the in-app updater; Pluck.zip is Studio again, for Pluck 1.15 and
# older, which look for that name), commits the version bump, tags it, pushes, and creates the
# GitHub release.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: release.sh <version> [notes] [--both]}"
CHANGES="${2:-}"
# --both: a new basic build even when its program didn't change (a translation fix, say).
FORCE_BASIC="${3:-}"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }
grep -q "version: \"$VERSION\"" Sources/Pluck/WhatsNew.swift Sources/Pluck/Studio/WhatsNewStudio.swift \
  || { echo "Add the notes for $VERSION to Sources/Pluck/WhatsNew.swift (or Studio/WhatsNewStudio.swift for Studio-only) first; people see them after updating." >&2; exit 1; }

PLIST=Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" "$PLIST"

# Basic Pluck only gets a new version when it really changed: its program is compared with the
# one in the previous release (builds are reproducible: the same code gives the same bytes). If
# they're the same, the release carries the previous basic build unchanged, so people on basic
# Pluck aren't asked to update for a Studio-only release; editions.json says which version of
# each the release holds. (--both forces a new basic build, for a translation fix, say.)
BASIC_VERSION="$VERSION"
rm -rf dist && mkdir dist
./scripts/build-app.sh --edition basic
PREVIOUS=$(gh release view --json tagName -q .tagName 2>/dev/null || true)
if [[ -n "$PREVIOUS" && "$FORCE_BASIC" != "--both" ]]; then
  OLD=build/previous-basic
  rm -rf "$OLD" && mkdir -p "$OLD"
  if gh release download "$PREVIOUS" -D "$OLD" -p Pluck-Basic.zip -p Pluck-Basic.zip.sha256 -p Pluck.dmg 2>/dev/null; then
    ditto -x -k "$OLD/Pluck-Basic.zip" "$OLD/app"
    if cmp -s "$OLD/app/Pluck.app/Contents/MacOS/Pluck" build/basic/Pluck.app/Contents/MacOS/Pluck; then
      BASIC_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OLD/app/Pluck.app/Contents/Info.plist")
      echo "Basic Pluck is unchanged: carrying over $BASIC_VERSION."
      cp "$OLD/Pluck-Basic.zip" "$OLD/Pluck-Basic.zip.sha256" "$OLD/Pluck.dmg" dist/
    fi
  fi
  rm -rf "$OLD"
fi
if [[ "$BASIC_VERSION" == "$VERSION" ]]; then
  ditto -c -k --keepParent build/basic/Pluck.app dist/Pluck-Basic.zip
  (cd dist && shasum -a 256 Pluck-Basic.zip > Pluck-Basic.zip.sha256)
fi
./scripts/build-app.sh --edition studio
ditto -c -k --keepParent build/Pluck.app dist/Pluck-Studio.zip
cp dist/Pluck-Studio.zip dist/Pluck.zip
(cd dist && for zip in Pluck-Studio.zip Pluck.zip; do shasum -a 256 $zip > $zip.sha256; done)
printf '{"studio": "%s", "basic": "%s"}\n' "$VERSION" "$BASIC_VERSION" > dist/editions.json

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
if [[ "$BASIC_VERSION" == "$VERSION" ]]; then dmg build/basic/Pluck.app "Pluck" dist/Pluck.dmg; fi
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
  dist/Pluck.zip dist/Pluck.zip.sha256 dist/editions.json \
  --title "Pluck $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
echo "Released $VERSION"
