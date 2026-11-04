#!/bin/zsh
# Publishes a release: ./scripts/release.sh 1.18.0 ["What changed"] [--both] [--with-update-files]
# A release is just two disk images: Pluck.dmg (standard) and Pluck-Studio.dmg. The in-app updater
# downloads the one for its edition and checks it against the SHA-256 GitHub records for it.
# Commits the version bump, tags it, pushes, and creates the GitHub release.
#   --both               a new basic build even when its program didn't change (a translation fix)
#   --with-update-files  also the zips, checksums and editions.json that Pluck 1.17.2 and older
#                        update from (only for the release that moves them to the new updater)
set -euo pipefail
unset PLUCK_ALLOW_ADHOC  # a release is always checked for the Pluck signature
cd "${0:A:h}/.."

VERSION="${1:?usage: release.sh <version> [notes] [--both] [--with-update-files]}"
CHANGES="${2:-}"
FORCE_BASIC="" ; LEGACY=""
for option in "${@:3}"; do
  case "$option" in
    --both) FORCE_BASIC=1 ;;
    --with-update-files) LEGACY=1 ;;
    *) echo "Unknown option $option" >&2; exit 1 ;;
  esac
done
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.18.0, not $VERSION." >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "Releases are made from main; you're on $(git branch --show-current)." >&2; exit 1; }
LATEST=$(git tag -l 'v[0-9]*' | sort -V | tail -1)
[[ -z "$LATEST" || "$(printf '%s\n%s\n' "${LATEST#v}" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "${LATEST#v}" != "$VERSION" ]] \
  || { echo "$VERSION must be higher than the latest release, $LATEST." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists." >&2; exit 1; }
# (Ad hoc, an update would be a new app to macOS: everyone's permissions would reset.)
security find-certificate -c "Pluck Code Signing" >/dev/null 2>&1 || { echo "The Pluck Code Signing certificate isn't in the keychain." >&2; exit 1; }
grep -qF "version: \"$VERSION\"" Sources/Pluck/WhatsNew.swift Sources/Pluck/Studio/WhatsNewStudio.swift \
  || { echo "Add the notes for $VERSION to Sources/Pluck/WhatsNew.swift (or Studio/WhatsNewStudio.swift for Studio-only) first; people see them after updating." >&2; exit 1; }

# Studio-only code leaking into basic Pluck fails here, before anything is changed.
PLUCK_EDITION=basic SDKROOT="${SDKROOT:-macosx}" swift build --scratch-path .build-basic >/dev/null

PLIST=Resources/Info.plist
# If anything fails before the release commit, the version bump doesn't stay behind.
trap '[[ -n "${COMMITTED:-}" ]] || git checkout -- "$PLIST"' EXIT
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" "$PLIST"

# A disk image per edition.
dmg() {
  local app="$1" name="$2" out="$3"
  local stage=build/dmg
  rm -rf "$stage" && mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  cp scripts/dmg-readme.txt "$stage/Read Me First.txt"
  hdiutil create -quiet -volname "$name $VERSION" -srcfolder "$stage" -ov -format UDZO "$out"
}

# Basic Pluck only gets a new version when it really changed: its program is compared with the
# one in the previous release's Pluck.dmg (builds are reproducible: the same code gives the same
# bytes). If they're the same, the previous Pluck.dmg is carried over unchanged, so people on
# basic Pluck aren't asked to update for a Studio-only release.
BASIC_VERSION="$VERSION"
rm -rf dist && mkdir dist
./scripts/build-app.sh --edition basic
./scripts/check-app.sh build/basic/Pluck.app basic
PREVIOUS=$(gh release view --json tagName -q .tagName 2>/dev/null || true)
if [[ -n "$PREVIOUS" && -z "$FORCE_BASIC" ]]; then
  OLD=build/previous-basic
  rm -rf "$OLD" && mkdir -p "$OLD/mount"
  if gh release download "$PREVIOUS" -D "$OLD" -p Pluck.dmg 2>/dev/null \
     && hdiutil attach "$OLD/Pluck.dmg" -nobrowse -readonly -noautoopen -mountpoint "$OLD/mount" >/dev/null; then
    if cmp -s "$OLD/mount/Pluck.app/Contents/MacOS/Pluck" build/basic/Pluck.app/Contents/MacOS/Pluck; then
      BASIC_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OLD/mount/Pluck.app/Contents/Info.plist")
      echo "Basic Pluck is unchanged: carrying over $BASIC_VERSION."
      cp "$OLD/Pluck.dmg" dist/Pluck.dmg
      if [[ -n "$LEGACY" ]]; then ditto -c -k --keepParent "$OLD/mount/Pluck.app" dist/Pluck-Basic.zip; fi
    fi
    hdiutil detach "$OLD/mount" -force >/dev/null || true
  fi
  rm -rf "$OLD"
fi
if [[ "$BASIC_VERSION" == "$VERSION" ]]; then
  dmg build/basic/Pluck.app "Pluck" dist/Pluck.dmg
  if [[ -n "$LEGACY" ]]; then ditto -c -k --keepParent build/basic/Pluck.app dist/Pluck-Basic.zip; fi
fi
./scripts/build-app.sh --edition studio
./scripts/check-app.sh build/Pluck.app studio
dmg build/Pluck.app "Pluck Studio" dist/Pluck-Studio.dmg

ASSETS=(dist/Pluck.dmg dist/Pluck-Studio.dmg)
if [[ -n "$LEGACY" ]]; then
  # What Pluck 1.17.2 and older update from (Pluck.zip is Studio, for 1.15 and older).
  ditto -c -k --keepParent build/Pluck.app dist/Pluck-Studio.zip
  cp dist/Pluck-Studio.zip dist/Pluck.zip
  (cd dist && for zip in Pluck-Basic.zip Pluck-Studio.zip Pluck.zip; do shasum -a 256 $zip > $zip.sha256; done)
  printf '{"studio": "%s", "basic": "%s"}\n' "$VERSION" "$BASIC_VERSION" > dist/editions.json
  ASSETS+=(dist/Pluck-Basic.zip dist/Pluck-Basic.zip.sha256 dist/Pluck-Studio.zip dist/Pluck-Studio.zip.sha256
           dist/Pluck.zip dist/Pluck.zip.sha256 dist/editions.json)
fi

NOTES=$(mktemp)
{
  [[ -n "$CHANGES" ]] && printf '%s\n\n' "$CHANGES"
  cat scripts/release-notes.md
  # Out of sight on the page: which version of each edition this release holds (for the updater).
  printf '\n<!-- pluck-editions studio=%s basic=%s -->\n' "$VERSION" "$BASIC_VERSION"
} > "$NOTES"

git add "$PLIST"
git commit -q -m "Release $VERSION"
COMMITTED=1
git tag "v$VERSION"
# A draft first: the upload is the step most likely to fail, and nothing is public (or pushed) until
# it succeeded. Then the push, then the draft goes live on the tag that was just pushed.
# (--target: gh refuses a tag that's only local without it; main is on GitHub already, and once
# the tag is pushed GitHub publishes on the tag, not on this.)
gh release create "v$VERSION" "${ASSETS[@]}" --draft --target main --title "Pluck $VERSION" --notes-file "$NOTES" || {
  echo "The draft release couldn't be made; nothing was pushed. To undo the local release commit and tag:" >&2
  echo "  git tag -d v$VERSION && git reset --keep HEAD~1   (and gh release delete v$VERSION if a half-made draft is on GitHub)" >&2
  exit 1
}
git push -q origin HEAD "v$VERSION"
gh release edit "v$VERSION" --draft=false
rm -f "$NOTES"
echo "Released $VERSION"
