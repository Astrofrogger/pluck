#!/usr/bin/env bash
# Sign a Pluck Review host release (the owner's local step after the review-host-release workflow).
#
#   scripts/sign-host-release.sh --init     make the Ed25519 key if missing, print the PUBLIC key
#   scripts/sign-host-release.sh <tag>      download host-release.json and its assets, check every
#                                           SHA-256, sign host-release.json, upload host-release.json.sig
#
# The private key lives at ~/Documents/_CLAUDE/Pluck Signing/host-update-ed25519.pem (override with
# PLUCK_HOST_SIGNING_KEY). Needs OpenSSL 3 or newer, jq and the gh CLI.
set -euo pipefail

KEY="${PLUCK_HOST_SIGNING_KEY:-$HOME/Documents/_CLAUDE/Pluck Signing/host-update-ed25519.pem}"

die() { echo "sign-host-release: $*" >&2; exit 1; }

# macOS ships LibreSSL, which can't do Ed25519 with -rawin: use Homebrew's OpenSSL 3 there.
OPENSSL=""
for c in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if command -v "$c" >/dev/null 2>&1 && "$c" version 2>/dev/null | grep -Eq '^OpenSSL [3-9]'; then OPENSSL="$c"; break; fi
done
[ -n "$OPENSSL" ] || die "OpenSSL 3 or newer not found (brew install openssl@3)"

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

case "${1:-}" in
  --init)
    if [ -e "$KEY" ]; then
      echo "Key already exists: $KEY (not touched)."
    else
      mkdir -p "$(dirname "$KEY")"
      ( umask 077; "$OPENSSL" genpkey -algorithm ed25519 -out "$KEY" )
      chmod 600 "$KEY"
      echo "Made $KEY. Back it up with the other signing keys."
    fi
    echo
    echo "Public key: paste it into PUBKEY_PEM in pluck-review-update.sh and pluck-proxmox.sh"
    echo "(and into Sources/Pluck/…/DeliverHostUpdate.swift):"
    echo
    "$OPENSSL" pkey -in "$KEY" -pubout
    exit 0 ;;
  ""|-*) die "usage: sign-host-release.sh <tag> | --init" ;;
esac

TAG="$1"
printf '%s' "$TAG" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$' || die "bad tag: $TAG"
[ -f "$KEY" ] || die "no signing key at $KEY (run: scripts/sign-host-release.sh --init)"
command -v jq >/dev/null && command -v gh >/dev/null || die "jq and gh are required"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
gh release download "$TAG" -p host-release.json -D "$W" >/dev/null || die "could not download host-release.json for $TAG (did the workflow finish?)"
echo "--- host-release.json"
jq . "$W/host-release.json"

jq -e --arg t "${TAG#v}" '(.version|ltrimstr("v"))==$t' "$W/host-release.json" >/dev/null || die "host-release.json is for another version"
fail=0
while IFS=$'\t' read -r name want; do
  gh release download "$TAG" -p "$name" -D "$W" >/dev/null || die "could not download $name"
  have="$(sha256_of "$W/$name")"
  if [ "$have" = "$want" ]; then echo "ok    $name"; else echo "WRONG $name (release has $have, json says $want)"; fail=1; fi
done < <(jq -r '.assets | to_entries[] | [.key, .value] | @tsv' "$W/host-release.json")
[ "$fail" = 0 ] || die "hash mismatch: not signing"

"$OPENSSL" pkeyutl -sign -rawin -inkey "$KEY" -in "$W/host-release.json" -out "$W/sig.bin"
[ "$(wc -c < "$W/sig.bin" | tr -d ' ')" = 64 ] || die "unexpected signature length"
base64 < "$W/sig.bin" | tr -d '\n' > "$W/host-release.json.sig"
"$OPENSSL" pkey -in "$KEY" -pubout -out "$W/pub.pem"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$W/pub.pem" -rawin -in "$W/host-release.json" -sigfile "$W/sig.bin" >/dev/null \
  || die "the new signature does not verify"
echo "Signature verified with the public key of $KEY."

printf 'Upload host-release.json.sig to release %s? [y/N] ' "$TAG"
read -r answer
[ "$answer" = y ] || [ "$answer" = Y ] || { echo "Not uploaded."; exit 0; }
gh release upload "$TAG" "$W/host-release.json.sig" --clobber
echo "Uploaded. Hosts will install $TAG now."
