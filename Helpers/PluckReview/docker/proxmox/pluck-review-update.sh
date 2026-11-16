#!/usr/bin/env bash
# Pluck Review host updater (inside the Proxmox container). Run as root by
# pluck-review-update.service (timer, path trigger) and by pluck-proxmox.sh (--install).
#
#   pluck-review-update.sh                 update to the requested version, else the latest release
#   pluck-review-update.sh --install <tag> install exactly <tag> (first install or re-run)
#   pluck-review-update.sh --force         proceed even when the host is still busy after the wait
#   pluck-review-update.sh --allow-downgrade  accept a version older than the installed one
#                                          (refused otherwise: no rollback through an old signed tag)
#
# Everything is verified before anything changes: the signature of host-release.json (Ed25519,
# public key embedded below), then the tarball's SHA-256 against its "assets". Any failure stops
# with the current release untouched and is recorded in update/last.json (for the host to report)
# and in the root-owned state folder.
#
# Runs as root, but the data and update folders belong to the service user: everything read from or
# written to them goes through `as_user` (setpriv to pluck-review), so links planted there can't make
# root read or overwrite anything the service user couldn't already. The lock and the failed list
# live in /var/lib/pluck-review-update (root only), and `--ctl` runs as the service user too.
#
# Test-only knobs (never set in production): PLUCK_PREFIX (prefix for every absolute path),
# PLUCK_RELEASE_BASE / PLUCK_RELEASE_LATEST (download URLs, file:// works), PLUCK_TEST_PUBKEY_FILE
# (replaces the embedded key), PLUCK_UPDATE_POLL_SECS (300), PLUCK_UPDATE_MAX_WAIT_SECS (3600),
# PLUCK_UPDATE_HEALTH_SECS (90), PLUCK_TEST_AS_USER (replaces the setpriv prefix; tests run unprivileged).
set -euo pipefail
umask 022

REPO="__PLUCK_REPO__"
BUILT_FOR_TAG="__PLUCK_TAG__"

# The release signing key (Ed25519). Replace REPLACE with the PEM that
# `scripts/sign-host-release.sh --init` prints. While it says REPLACE, nothing is installed.
PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAfOPL13shEB3uNAhz5Fz6CYPWGucTgWLv3jcC17ZusAI=
-----END PUBLIC KEY-----'

P="${PLUCK_PREFIX:-}"
OPT="$P/opt/pluck-review"
DATA="$P/var/lib/pluck-review"
UPD="$DATA/update"
STATE="$P/var/lib/pluck-review-update"
ENVFILE="$P/etc/pluck-review/env"
HEALTH="${PLUCK_HEALTH_FILE:-$P/run/pluck-review/health}"
POLL="${PLUCK_UPDATE_POLL_SECS:-300}"
MAXWAIT="${PLUCK_UPDATE_MAX_WAIT_SECS:-3600}"
HEALTH_SECS="${PLUCK_UPDATE_HEALTH_SECS:-90}"

# The service user's view of its own files (see the header). Word-split on purpose: a command prefix.
AS_USER="${PLUCK_TEST_AS_USER-setpriv --reuid=pluck-review --regid=pluck-review --init-groups --}"
as_user() { $AS_USER "$@"; }
# First line of a service-user file, read as that user: regular files only, at most 64 bytes.
user_line() { as_user sh -c '[ -f "$1" ] && [ ! -L "$1" ] && head -c 64 "$1" | head -n 1' _ "$1" 2>/dev/null | tr -d '[:space:]' || true; }

log() { echo "pluck-review-update: $*"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

TAG="" ; FORCE=0 ; INSTALL="" ; DOWNGRADE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --allow-downgrade) DOWNGRADE=1 ;;
    --install) shift; [ $# -gt 0 ] || { log "--install needs a tag" >&2; exit 64; }; INSTALL="$1" ;;
    *) log "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

valid_tag() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'; }
[ -z "$INSTALL" ] || valid_tag "$INSTALL" || { log "bad tag: $INSTALL" >&2; exit 64; }

for c in curl jq openssl tar sha256sum base64; do
  command -v "$c" >/dev/null || { log "missing command: $c" >&2; exit 69; }
done
mkdir -p "$OPT/releases"
install -d -m 0700 "$STATE"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { log "state folder is not a folder: $STATE" >&2; exit 70; }

if command -v flock >/dev/null; then
  exec 9>"$STATE/lock"
  flock -n 9 || { log "another update is running"; exit 0; }
fi

WORK="$(mktemp -d)"
PREPARED=0
ctl() { as_user "$OPT/current/pluck-review" --ctl "$DATA" "$1"; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# finish <result> <error|""> <mark tag as failed: 0|1> [exit code]
finish() {
  local result="$1" err="$2" mark="$3" code="${4:-1}"
  if [ "$PREPARED" = 1 ]; then ctl '{"op":"cancel-update"}' >/dev/null 2>&1 || true; PREPARED=0; fi
  if [ "$mark" = 1 ] && [ -n "$TAG" ]; then echo "$TAG" >> "$STATE/failed"; fi
  jq -n --arg to "$TAG" --arg r "$result" --arg at "$(now)" --arg e "$err" \
    '{to:$to,result:$r,at:$at,error:(if $e=="" then null else $e end)}' > "$STATE/last.json"
  # The host reads update/last.json; written as the service user, so a planted link only hits its own files.
  as_user sh -c 'cat > "$1.new" && mv -f "$1.new" "$1"' _ "$UPD/last.json" < "$STATE/last.json" 2>/dev/null \
    || log "could not write $UPD/last.json"
  log "$result${err:+: $err}"
  exit "$code"
}

# --- 0. the signing key must be real
if [ -n "${PLUCK_TEST_PUBKEY_FILE:-}" ]; then
  PUB="$PLUCK_TEST_PUBKEY_FILE"
else
  case "$PUBKEY_PEM" in
    *REPLACE*) TAG="$INSTALL"; finish "failed" "no signing key in this script yet: run scripts/sign-host-release.sh --init and paste the public key into the script" 0 ;;
  esac
  PUB="$WORK/pub.pem"; printf '%s\n' "$PUBKEY_PEM" > "$PUB"
fi

case "$REPO" in
  *PLUCK_REPO__*) [ -n "${PLUCK_RELEASE_BASE:-}" ] || { TAG="$INSTALL"; finish "failed" "this script is an unprocessed source copy; use the one from the release" 0; } ;;
esac
BASE="${PLUCK_RELEASE_BASE:-https://github.com/$REPO/releases/download}"
LATEST="${PLUCK_RELEASE_LATEST:-https://github.com/$REPO/releases/latest/download}"
fetch() { curl -fsSL --retry 2 --connect-timeout 20 --max-time 900 -o "$2" "$1"; }

current_tag() { [ -L "$OPT/current" ] && basename "$(readlink "$OPT/current")" || true; }
in_failed() { [ -f "$STATE/failed" ] && grep -Fxq "$1" "$STATE/failed"; }
# 0 when version $1 is older than $2 (v prefixes ignored).
older() { [ "${1#v}" != "${2#v}" ] && [ "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | head -n 1)" = "${1#v}" ]; }
role() { sed -n 's/^PLUCK_ROLE=//p' "$ENVFILE" 2>/dev/null | tail -n 1 | tr -d '"'; }

# --- 1. which version
if [ -n "$INSTALL" ]; then
  TAG="$INSTALL"
else
  req=""
  req="$(user_line "$UPD/request")"
  if [ -n "$req" ] && valid_tag "$req" &&
     ! { [ -f "$STATE/last.json" ] && jq -e --arg t "$req" '.to==$t and (.result|startswith("skipped")|not)' "$STATE/last.json" >/dev/null; }; then
    TAG="$req"
  else
    # shortcut: asks for the latest release only; the spec wants the newest release whose protocol
    # is <= the main's. Upgrade when a release can ship a protocol the older mains can't talk to.
    fetch "$LATEST/host-release.json" "$WORK/latest.json" || finish "failed" "could not read the latest release" 0
    TAG="$(jq -r '.version // empty' "$WORK/latest.json")"
    valid_tag "$TAG" || { TAG=""; finish "failed" "the latest release has no usable version" 0; }
  fi
fi
if [ "$TAG" = "$(current_tag)" ]; then log "already on $TAG"; exit 0; fi
if in_failed "$TAG"; then log "$TAG failed before; not retried"; exit 0; fi
CUR="$(current_tag)"
if [ -n "$CUR" ] && [ "$DOWNGRADE" = 0 ] && older "$TAG" "$CUR"; then
  finish "skipped: $TAG is older than the installed $CUR" "" 0 0
fi

# --- 2. download and verify (nothing changes yet)
arch="$(dpkg --print-architecture)"
case "$arch" in amd64|arm64) ;; *) finish "failed" "unsupported architecture $arch" 1 ;; esac
TARBALL="pluck-review-host-linux-$arch.tar.gz"
D="$WORK/dl"; mkdir -p "$D"
for f in host-release.json host-release.json.sig "$TARBALL"; do
  fetch "$BASE/$TAG/$f" "$D/$f" || finish "failed" "download failed: $f" 1
done
base64 -d < "$D/host-release.json.sig" > "$D/sig.bin" 2>/dev/null || finish "failed" "signature is not base64" 1
[ "$(wc -c < "$D/sig.bin" | tr -d ' ')" = 64 ] || finish "failed" "signature has the wrong length" 1
openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$D/host-release.json" -sigfile "$D/sig.bin" >/dev/null 2>&1 \
  || finish "failed" "signature check failed" 1
jq -e --arg t "${TAG#v}" '(.version|ltrimstr("v"))==$t' "$D/host-release.json" >/dev/null \
  || finish "failed" "host-release.json is for another version" 1
want="$(jq -r --arg f "$TARBALL" '.assets[$f] // empty' "$D/host-release.json")"
have="$(sha256sum "$D/$TARBALL" | cut -d' ' -f1)"
[ -n "$want" ] && [ "$want" = "$have" ] || finish "failed" "tarball hash does not match the signed release" 1

# A release the host can't talk to (only when we picked it ourselves, not an explicit request).
if [ -z "$INSTALL" ] && [ -z "${req:-}" ]; then
  proto="$(jq -r '.protocol // 0' "$D/host-release.json")"
  limit="$(user_line "$DATA/main-protocol")"
  if [ -n "$limit" ]; then
    if [ "$proto" -gt "$limit" ] 2>/dev/null; then finish "skipped: protocol $proto is newer than the main's $limit" "" 0 0; fi
  elif [ "$(role)" = backup ]; then
    finish "skipped: main protocol not known yet" "" 0 0
  fi
fi

# --- 3. unpack
REL="$OPT/releases/$TAG"
rm -rf "$REL.partial"; mkdir "$REL.partial"
tar -xzf "$D/$TARBALL" -C "$REL.partial" --no-same-owner || finish "failed" "could not unpack the tarball" 1
[ -x "$REL.partial/pluck-review" ] && "$REL.partial/pluck-review" --version >/dev/null 2>&1 \
  || { rm -rf "$REL.partial"; finish "failed" "the new pluck-review does not run here" 1; }
rm -rf "$REL"; mv "$REL.partial" "$REL"

# A first install has nothing to protect or roll back to: switch only. pluck-proxmox.sh starts the
# service once its unit and config exist.
if [ ! -L "$OPT/current" ]; then
  ( cd "$OPT" && ln -sfn "releases/$TAG" current.new && mv -T current.new current )
  finish "ok" "" 0 0
fi
PREV="$(readlink "$OPT/current")"

# --- 4. never mid-work: ask the running host, wait, give up after MAXWAIT unless forced
waited=0
while :; do
  out="$(ctl '{"op":"prepare-update"}' 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" != 0 ]; then log "prepare-update not answered (exit $rc); going on"; break; fi
  PREPARED=1
  jq -e '.busy==true' <<<"$out" >/dev/null 2>&1 || break
  if [ "$waited" -ge "$MAXWAIT" ]; then
    if [ "$FORCE" = 1 ]; then log "still busy, forced"; break; fi
    finish "skipped: busy" "" 0 0
  fi
  sleep "$POLL"; waited=$((waited + POLL))
done

# --- 5. switch, restart, health check
( cd "$OPT" && ln -sfn "releases/$TAG" current.new && mv -T current.new current )
systemctl restart pluck-review || true
ok=0; v="${TAG#v}"; i=0
while [ "$i" -lt "$HEALTH_SECS" ]; do
  if [ -f "$HEALTH" ] && jq -e --arg v "$v" '.ok==true and (.version|ltrimstr("v"))==$v' "$HEALTH" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1; i=$((i + 1))
done

# --- 6. roll back when it didn't come up
if [ "$ok" != 1 ]; then
  ( cd "$OPT" && ln -sfn "$PREV" current.new && mv -T current.new current )
  systemctl restart pluck-review || true
  rm -rf "$REL"
  PREPARED=0   # the restart cleared the prepare state
  finish "rolledBack" "$TAG did not report healthy within ${HEALTH_SECS}s" 1
fi
PREPARED=0

# --- 7. keep the new and the previous release only
for d in "$OPT"/releases/*; do
  [ -d "$d" ] || continue
  case "releases/$(basename "$d")" in "releases/$TAG"|"$PREV") ;; *) rm -rf "$d" ;; esac
done
finish "ok" "" 0 0
