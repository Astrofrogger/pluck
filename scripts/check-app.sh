#!/bin/zsh
# check-app.sh <app> studio|basic: fails unless the built app is complete and its signature holds.
# A Studio build quietly drops a helper when its SDK or Go is missing; a release must not ship that.
set -euo pipefail
APP="${1:?usage: check-app.sh <app> studio|basic}"
EDITION="${2:?usage: check-app.sh <app> studio|basic}"
C="$APP/Contents"
need=("$C/Resources/ThirdPartyLicenses.md" "$C/Resources/ThirdPartyLicenses/Tailscale/LICENSE")
if [[ "$EDITION" == studio ]]; then
  need+=("$C/Helpers/pluck-raw" "$C/Helpers/pluck-tunnel" "$C/Helpers/pluck-vision"
         "$C/Resources/FilmTables/index.json" "$C/PlugIns/PluckPreview.appex")
fi
for f in $need; do [[ -e "$f" ]] || { echo "$APP is incomplete: missing ${f#$APP/}" >&2; exit 1; }; done
codesign --verify --deep --strict "$APP" || { echo "$APP: the signature doesn't verify." >&2; exit 1; }
# Releases are signed with the Pluck certificate (updates check it); PLUCK_ALLOW_ADHOC=1 for local ad-hoc builds.
if [[ -z "${PLUCK_ALLOW_ADHOC:-}" ]]; then
  [[ "$(codesign -dv --verbose=2 "$APP" 2>&1)" == *$'\nAuthority=Pluck Code Signing\n'* ]] \
    || { echo "$APP isn't signed by Pluck Code Signing (PLUCK_ALLOW_ADHOC=1 for a local build)." >&2; exit 1; }
fi
echo "$APP ($EDITION) is complete."
