#!/usr/bin/env bash
# Tests for the host packaging scripts (updater, Proxmox installer, signer, compose templates).
# Runs on macOS or Linux with stub commands; touches nothing outside a temp folder.
#   bash Helpers/PluckReview/tests/scripts/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOCKER="$(cd "$HERE/../../docker" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
PX="$DOCKER/proxmox"

# --- OpenSSL 3+
OSSL=""
for c in openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if command -v "$c" >/dev/null 2>&1 && "$c" version 2>/dev/null | grep -Eq '^OpenSSL [3-9]'; then OSSL="$(command -v "$c")"; break; fi
done
if [ -z "$OSSL" ]; then echo "SKIP: OpenSSL 3 not found"; exit 0; fi
for c in jq perl curl tar python3; do command -v "$c" >/dev/null || { echo "SKIP: $c not found"; exit 0; }; done

S="$(mktemp -d)"
trap 'rm -rf "${S:?}"' EXIT
NPASS=0; NFAIL=0
ok() { NPASS=$((NPASS + 1)); echo "PASS $1"; }
bad() { NFAIL=$((NFAIL + 1)); echo "FAIL $1${2:+: $2}"; }
check() { # check <name> <command...>
  local n="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi
}
lacks() { ! grep -q -- "$1" "$2" 2>/dev/null; }

# --- shims for Debian tools on macOS (the scripts target Debian)
SHIM="$S/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$OSSL" > "$SHIM/openssl"
cat > "$SHIM/mv" <<'X'
#!/bin/sh
if [ "$1" = -T ]; then shift; rm -f "$2"; fi
exec /bin/mv "$@"
X
cat > "$SHIM/sha256sum" <<'X'
#!/bin/sh
if command -v shasum >/dev/null; then exec shasum -a 256 "$@"; fi
exec /usr/bin/sha256sum "$@"
X
printf '#!/bin/sh\n[ "$1" = --print-architecture ] && echo amd64\n' > "$SHIM/dpkg"
printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || /usr/bin/id "$@"\n' > "$SHIM/id"
cat > "$SHIM/systemctl" <<'X'
#!/bin/sh
echo "$*" >> "$SYSTEMCTL_LOG"
[ "$1" = restart ] && "$PLUCK_PREFIX/opt/pluck-review/current/pluck-review" fake-start
exit 0
X
chmod +x "$SHIM"/*
export PATH="$SHIM:$PATH"

# --- keys and the scripts under test with __PLUCK_*__ substituted like the workflow does
"$OSSL" genpkey -algorithm ed25519 -out "$S/good.pem" 2>/dev/null
"$OSSL" pkey -in "$S/good.pem" -pubout -out "$S/good.pub" 2>/dev/null
"$OSSL" genpkey -algorithm ed25519 -out "$S/other.pem" 2>/dev/null
SRC="$S/src"; mkdir -p "$SRC"
for f in pluck-review-update.sh pluck-proxmox.sh; do
  sed -e 's|__PLUCK_REPO__|example/pluck|g' -e 's|__PLUCK_TAG__|v9.9.9|g' "$PX/$f" > "$SRC/$f"
done
UPDATER="$SRC/pluck-review-update.sh"
cp "$PX"/pluck-review.service "$PX"/pluck-review-update.service "$PX"/pluck-review-update.timer "$PX"/pluck-review-update.path "$SRC/"

# --- release builder: mk_release <tag> [good|bad]; env SIGKEY, NOSIG=1, BADHASH=1, EXTRA=1
REL="$S/rel"; mkdir -p "$REL"
mk_release() {
  local tag="$1" mode="${2:-good}" d="$REL/$1" v="${1#v}" stage
  stage="$(mktemp -d "$S/stage.XXXXXX")"; rm -rf "${d:?}"; mkdir -p "$d" "$stage/LICENSES"
  cat > "$stage/pluck-review" <<X
#!/bin/sh
case "\$1" in
  --version) echo "pluck-review $v protocol 3";;
  fake-start) hv="$v"; [ "$mode" = bad ] && hv=0.0.0
    mkdir -p "\$(dirname "\$PLUCK_HEALTH_FILE")"
    printf '{"version":"%s","protocol":3,"ok":true,"at":"x"}\n' "\$hv" > "\$PLUCK_HEALTH_FILE";;
  --ctl) echo "\$3" >> "\$CTL_LOG"
    case "\$3" in
      *prepare-update*) if [ -f "\$CTL_BUSY" ]; then echo '{"busy":true,"why":["upload"],"eta":600}'; else echo '{"busy":false}'; fi;;
      *) echo '{"ok":true}';;
    esac;;
esac
X
  echo "iroh" > "$stage/pluck-iroh"; echo "x" > "$stage/LICENSES/THIRD-PARTY.txt"; chmod +x "$stage/pluck-review" "$stage/pluck-iroh"
  tar -czf "$d/pluck-review-host-linux-amd64.tar.gz" -C "$stage" pluck-review pluck-iroh LICENSES
  cp "$d/pluck-review-host-linux-amd64.tar.gz" "$d/pluck-review-host-linux-arm64.tar.gz"
  if [ "${EXTRA:-0}" = 1 ]; then cp "$SRC"/pluck-review-update.sh "$SRC"/pluck-review*.service "$SRC"/pluck-review-update.timer "$SRC"/pluck-review-update.path "$d/"; fi
  local assets='{}' f h
  for f in "$d"/*; do
    h="$(sha256sum "$f" | cut -d' ' -f1)"
    [ "${BADHASH:-0}" = 1 ] && [ "$(basename "$f")" = pluck-review-host-linux-amd64.tar.gz ] && h="$(printf '0%.0s' $(seq 64))"
    assets="$(jq -c --arg k "$(basename "$f")" --arg v "$h" '.[$k]=$v' <<<"$assets")"
  done
  jq -n --arg v "$tag" --argjson a "$assets" '{version:$v,protocol:3,image:"ghcr.io/example/pluck-review-host@sha256:0",assets:$a}' > "$d/host-release.json"
  if [ "${NOSIG:-0}" != 1 ]; then
    "$OSSL" pkeyutl -sign -rawin -inkey "${SIGKEY:-$S/good.pem}" -in "$d/host-release.json" -out "$stage/sig.bin"
    base64 < "$stage/sig.bin" | tr -d '\n' > "$d/host-release.json.sig"
  fi
  mkdir -p "$REL/latest"; cp "$d/host-release.json" "$REL/latest/host-release.json"
  rm -rf "${stage:?}"
}

# --- one fresh fake machine per case
n=0
new_env() {
  n=$((n + 1))
  PFX="$S/case$n"; mkdir -p "$PFX"
  export PLUCK_PREFIX="$PFX" PLUCK_HEALTH_FILE="$PFX/run/health" PLUCK_RELEASE_BASE="file://$REL" PLUCK_RELEASE_LATEST="file://$REL/latest"
  export PLUCK_TEST_PUBKEY_FILE="$S/good.pub" PLUCK_UPDATE_POLL_SECS=1 PLUCK_UPDATE_MAX_WAIT_SECS=2 PLUCK_UPDATE_HEALTH_SECS=2
  export SYSTEMCTL_LOG="$PFX/systemctl.log" CTL_LOG="$PFX/ctl.log" CTL_BUSY="$PFX/busy"
  export PLUCK_TEST_AS_USER="" # no setpriv here: tests run unprivileged
  U="$PFX/var/lib/pluck-review/update"; O="$PFX/opt/pluck-review"; ST="$PFX/var/lib/pluck-review-update" # root-only state
  mkdir -p "$U" # made by pluck-proxmox.sh, owned by the service user
}
cur() { basename "$(readlink "$O/current" 2>/dev/null)" 2>/dev/null; }
result() { jq -r .result "$U/last.json" 2>/dev/null; }
upd() { bash "$UPDATER" "$@" >"$PFX/out.log" 2>&1; }

echo "== syntax"
for f in "$PX"/*.sh "$ROOT/scripts/sign-host-release.sh" "$HERE/run.sh"; do check "bash -n $(basename "$f")" bash -n "$f"; done

echo "== updater: signatures"
mk_release v1.0.0; mk_release v1.1.0
new_env
upd --install v1.0.0; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v1.0.0 ] && [ "$(result)" = ok ] && ok "good signature installs (first install)" || bad "good signature installs" "rc=$rc cur=$(cur)"
[ -x "$O/current/pluck-review" ] && ok "installed binary is executable" || bad "installed binary is executable"

SIGKEY="$S/other.pem" mk_release v2.0.0
upd --install v2.0.0; rc=$?
[ $rc != 0 ] && [ "$(cur)" = v1.0.0 ] && [ "$(result)" = failed ] && grep -qx v2.0.0 "$ST/failed" && [ ! -d "$O/releases/v2.0.0" ] \
  && ok "bad signature: failed, nothing changed" || bad "bad signature" "rc=$rc cur=$(cur)"

NOSIG=1 mk_release v2.1.0
upd --install v2.1.0; rc=$?
[ $rc != 0 ] && [ "$(cur)" = v1.0.0 ] && [ "$(result)" = failed ] && [ ! -d "$O/releases/v2.1.0" ] \
  && ok "missing .sig: failed" || bad "missing .sig" "rc=$rc"

BADHASH=1 mk_release v2.2.0
upd --install v2.2.0; rc=$?
[ $rc != 0 ] && [ "$(cur)" = v1.0.0 ] && grep -q 'hash' "$PFX/out.log" && grep -qx v2.2.0 "$ST/failed" \
  && ok "wrong tarball hash: failed" || bad "wrong tarball hash" "rc=$rc"

new_env; unset PLUCK_TEST_PUBKEY_FILE
upd --install v1.0.0; rc=$?
[ $rc != 0 ] && [ -z "$(cur)" ] && grep -q 'sign-host-release.sh --init' "$PFX/out.log" && [ ! -d "$O/releases/v1.0.0" ] \
  && ok "placeholder key refuses to install" || bad "placeholder key" "rc=$rc"
export PLUCK_TEST_PUBKEY_FILE="$S/good.pub"

echo "== updater: rollback"
mk_release v3.0.0 bad; mk_release v3.1.0; mk_release v3.2.0
new_env
upd --install v1.0.0
echo v3.0.0 > "$U/request"
upd; rc=$?
[ $rc != 0 ] && [ "$(cur)" = v1.0.0 ] && [ "$(result)" = rolledBack ] && grep -qx v3.0.0 "$ST/failed" \
  && [ "$(jq -r .version "$PLUCK_HEALTH_FILE")" = 1.0.0 ] && ok "unhealthy release rolls back" || bad "rollback" "rc=$rc cur=$(cur) res=$(result)"
cp "$REL/v3.0.0/host-release.json" "$REL/latest/host-release.json"   # latest is the failed tag
upd; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v1.0.0 ] && grep -q 'not retried' "$PFX/out.log" && ok "failed tag is not retried" || bad "failed tag retried" "rc=$rc"
echo v3.1.0 > "$U/request"
upd; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v3.1.0 ] && [ "$(result)" = ok ] && ok "newer tag installs after a rollback" || bad "newer tag installs" "rc=$rc cur=$(cur)"
echo v3.2.0 > "$U/request"; upd
[ "$(cur)" = v3.2.0 ] && [ "$(ls "$O/releases" | wc -l | tr -d ' ')" = 2 ] && [ -d "$O/releases/v3.1.0" ] && [ ! -d "$O/releases/v1.0.0" ] \
  && ok "only 2 releases kept" || bad "only 2 releases kept" "$(ls "$O/releases" | tr '\n' ' ')"
cp "$REL/v3.2.0/host-release.json" "$REL/latest/host-release.json"
upd; check "already current is a no-op" grep -q 'already on' "$PFX/out.log"

echo "== updater: no downgrade"
echo v3.1.0 > "$U/request"; upd; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v3.2.0 ] && grep -q 'older than the installed' "$PFX/out.log" && ok "an older requested tag is refused" || bad "older request" "rc=$rc cur=$(cur)"
upd --install v3.1.0; rc=$?
[ "$(cur)" = v3.2.0 ] && ok "--install of an older tag is refused" || bad "older --install" "cur=$(cur)"
upd --install v3.1.0 --allow-downgrade; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v3.1.0 ] && ok "--allow-downgrade installs an older tag" || bad "--allow-downgrade" "rc=$rc cur=$(cur)"
ln -s /etc/passwd "$PFX/link"; rm -f "$U/request"; ln -s "$PFX/link" "$U/request"
cp "$REL/v3.1.0/host-release.json" "$REL/latest/host-release.json"; upd
! grep -q 'root:' "$PFX/out.log" && [ "$(cur)" = v3.1.0 ] && ok "a symlinked request is not followed" || bad "symlinked request"
rm -f "$U/request"

echo "== updater: busy"
new_env
upd --install v1.0.0
touch "$CTL_BUSY"; echo v3.1.0 > "$U/request"
upd; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v1.0.0 ] && [ "$(result)" = "skipped: busy" ] && grep -q cancel-update "$CTL_LOG" && ! grep -q '^restart' "$SYSTEMCTL_LOG" 2>/dev/null \
  && ok "busy: skipped after the wait, cancel-update sent" || bad "busy deferral" "rc=$rc res=$(result)"
upd --force; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v3.1.0 ] && [ "$(result)" = ok ] && ok "--force proceeds when still busy" || bad "--force" "rc=$rc cur=$(cur)"

echo "== updater: latest + protocol"
new_env
upd --install v1.0.0
mk_release v1.1.0   # latest points at it now
echo 2 > "$PFX/var/lib/pluck-review/main-protocol"
upd; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v1.0.0 ] && [ "$(result)" = "skipped: protocol 3 is newer than the main's 2" ] && ok "latest with a newer protocol than the main is skipped" || bad "protocol limit" "res=$(result)"
echo 3 > "$PFX/var/lib/pluck-review/main-protocol"
upd; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v1.1.0 ] && ok "no request: installs the latest release" || bad "latest install" "rc=$rc cur=$(cur)"

echo "== signer (stub gh) interop with the updater"
SGN="$ROOT/scripts/sign-host-release.sh"
new_env
mkdir -p "$S/ghbin"
cat > "$S/ghbin/gh" <<'X'
#!/bin/sh
# gh release download <tag> -p <name> -D <dir> | gh release upload <tag> <file> --clobber
if [ "$2" = download ]; then cp "$GH_REL/$3/$5" "$7/$5"; exit $?; fi
if [ "$2" = upload ]; then cp "$4" "$GH_REL/$3/host-release.json.sig"; echo "uploaded $4" >> "$GH_LOG"; exit 0; fi
exit 1
X
chmod +x "$S/ghbin/gh"
export GH_REL="$REL" GH_LOG="$S/gh.log" PLUCK_HOST_SIGNING_KEY="$S/signing/key.pem"
out="$(bash "$SGN" --init 2>&1)"
[ -f "$PLUCK_HOST_SIGNING_KEY" ] && [ "$(stat -f %Lp "$PLUCK_HOST_SIGNING_KEY" 2>/dev/null || stat -c %a "$PLUCK_HOST_SIGNING_KEY")" = 600 ] \
  && grep -q 'BEGIN PUBLIC KEY' <<<"$out" && ok "--init makes a 0600 key and prints the public key" || bad "--init"
cksum1="$(cksum < "$PLUCK_HOST_SIGNING_KEY")"; bash "$SGN" --init >/dev/null 2>&1
[ "$cksum1" = "$(cksum < "$PLUCK_HOST_SIGNING_KEY")" ] && ok "--init leaves an existing key alone" || bad "--init overwrote the key"
"$OSSL" pkey -in "$PLUCK_HOST_SIGNING_KEY" -pubout -out "$S/signer.pub"
NOSIG=1 mk_release v5.0.0
echo n | PATH="$S/ghbin:$PATH" bash "$SGN" v5.0.0 >"$S/sign.out" 2>&1
[ ! -f "$REL/v5.0.0/host-release.json.sig" ] && ok "signer: answering n uploads nothing" || bad "signer n"
echo y | PATH="$S/ghbin:$PATH" bash "$SGN" v5.0.0 >"$S/sign.out" 2>&1
[ -f "$REL/v5.0.0/host-release.json.sig" ] && [ "$(wc -l < "$REL/v5.0.0/host-release.json.sig" | tr -d ' ')" = 0 ] && ok "signer: y uploads a one-line signature" || bad "signer y" "$(tail -3 "$S/sign.out")"
export PLUCK_TEST_PUBKEY_FILE="$S/signer.pub"
upd --install v5.0.0; rc=$?
[ $rc = 0 ] && [ "$(cur)" = v5.0.0 ] && ok "a signature from sign-host-release.sh passes the updater" || bad "signer/updater interop" "rc=$rc $(tail -2 "$PFX/out.log")"
BADHASH=1 NOSIG=1 mk_release v5.1.0
echo y | PATH="$S/ghbin:$PATH" bash "$SGN" v5.1.0 >"$S/sign.out" 2>&1; rc=$?
[ $rc != 0 ] && [ ! -f "$REL/v5.1.0/host-release.json.sig" ] && ok "signer refuses a hash mismatch" || bad "signer hash mismatch"
export PLUCK_TEST_PUBKEY_FILE="$S/good.pub"

echo "== pluck-proxmox.sh"
PS="$S/pve"; mkdir -p "$PS/bin" "$PS/ct" "$PS/root"
cat > "$PS/bin/pct" <<'X'
#!/bin/sh
# stub: state in $PS (ct/<id>.conf, root/<ct paths>, log)
echo "pct $*" >> "$PS/log"
cmd="$1"; shift
case "$cmd" in
  list) echo "VMID Status Lock Name"; for f in "$PS"/ct/*.conf; do [ -f "$f" ] && echo "$(basename "$f" .conf) running  $(sed -n 's/^hostname: //p' "$f")"; done; exit 0;;
  config) cat "$PS/ct/$1.conf";;
  create) id="$1"; shift 2; host=""; rootfs=""
    while [ $# -gt 0 ]; do case "$1" in --hostname) host="$2";; --rootfs) rootfs="$2";; esac; shift; done
    printf 'hostname: %s\ndescription: pluck-review\nrootfs: %s:vm-%s-disk-0,size=%sG\n' "$host" "${rootfs%%:*}" "$id" "${rootfs##*:}" > "$PS/ct/$id.conf";;
  status) [ -f "$PS/started" ] && echo "status: running" || echo "status: stopped";;
  start) touch "$PS/started";;
  stop) rm -f "$PS/started";;
  set) id="$1"; shift; while [ $# -gt 1 ]; do echo "${1#--}: $2" >> "$PS/ct/$id.conf"; shift 2; done;;
  resize) ;;
  push) mkdir -p "$PS/root$(dirname "$3")"; cp "$2" "$PS/root$3";;
  exec) shift; [ "$1" = -- ] && shift
    c="$1"; shift
    case "$c" in
      test) [ -s "$PS/root$2" ];;
      cat) cat "$PS/root$1";;
      systemctl) if [ "$PS_PAIR" = 1 ] && [ "$1 $2" = "enable --now" ]; then
          mkdir -p "$PS/root/var/lib/pluck-review"
          echo '{"name":"Office NAS","host":"h"}' > "$PS/root/var/lib/pluck-review/main.json"
          echo abcdef0123456789 > "$PS/root/var/lib/pluck-review/iroh-id"
          printf 'pluck-host-iroh:NODEid@relay\npluck-host:KEYkey_-@AB:CD\n' > "$PS/root/var/lib/pluck-review/pairing.txt"; fi;;
      journalctl) echo "journal lines";;
      *) ;;
    esac;;
esac
X
cat > "$PS/bin/pveam" <<'X'
#!/bin/sh
echo "pveam $*" >> "$PS/log"
case "$1" in
  available) printf 'system  debian-11-standard_11.7-1_amd64.tar.zst\nsystem  debian-12-standard_12.2-1_amd64.tar.zst\nsystem  debian-12-standard_12.7-1_amd64.tar.zst\n';;
  list) echo "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst";;
esac
X
printf '#!/bin/sh\nn=100; while [ -f "$PS/ct/$n.conf" ]; do n=$((n + 1)); done; echo $n\n' > "$PS/bin/pvesh"
chmod +x "$PS/bin"/*
export PS PS_PAIR=1
PXS="$SRC/pluck-proxmox.sh"
EXTRA=1 mk_release v9.9.9
LINK='pluck://edit-anywhere/join?i=abc123_-'
px() { PATH="$PS/bin:$PATH" PLUCK_PAIR_WAIT_SECS=3 bash "$PXS" "$@" >"$PS/out" 2>&1; }

for args in "--name Bad_Name" "--name x --size abc" "--pair http://evil.example/x" "--quality 4k-ultra" "--cores 0" "--update-time 25:00" "--storage a;b" "--memory 100" "--ip 10.0.0.2/24" "--bogus 1"; do
  : > "$PS/log"
  # shellcheck disable=SC2086
  px $args; rc=$?
  [ $rc != 0 ] && lacks 'pct create' "$PS/log" && ok "rejects: $args" || bad "rejects: $args" "rc=$rc"
done

: > "$PS/log"
px --storage local-lvm --size 50 --quality 1080-low --cores 2 --memory 2048 --bridge vmbr0 --name pluck-backup --pair "$LINK"; rc=$?
want="pct create 100 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst --hostname pluck-backup --unprivileged 1 --features nesting=0 --cores 2 --memory 2048 --swap 512 --rootfs local-lvm:58 --net0 name=eth0,bridge=vmbr0,ip=dhcp --onboot 1 --description pluck-review"
[ $rc = 0 ] && grep -qxF "$want" "$PS/log" && ok "first run: pct create has the spec's arguments" || bad "first run create" "rc=$rc $(tail -3 "$PS/out")"
grep -q 'Paired with Office NAS. Check code: ABCD-EF01' "$PS/out" && ok "prints the pairing line and check code" || bad "check code" "$(tail -2 "$PS/out")"
env="$PS/root/etc/pluck-review/env"
grep -qx 'PLUCK_ROLE=backup' "$env" && grep -qx "PLUCK_MAIN_LINK=$LINK" "$env" && grep -qx 'PLUCK_BACKUP_MAX=50G' "$env" \
  && grep -qx 'PLUCK_BACKUP_QUALITY=1080-low' "$env" && grep -qx 'PLUCK_UPDATE_TIME=04:00' "$env" && grep -qx 'PLUCK_IROH=1' "$env" \
  && grep -q 'etc/pluck-review/env --perms 0600' "$PS/log" && ok "env file content (first install)" || bad "env file"
grep -qxF 'OnCalendar=*-*-* 04:00:00' "$PS/root/etc/systemd/system/pluck-review-update.timer" && ok "timer has the substituted time" || bad "timer time"
grep -q 'pluck-review-update.sh --install v9.9.9' "$PS/log" && ok "step 5 runs the updater with --install <tag>" || bad "updater run"
grep -qx 'MemoryMax=2G' "$PS/root/etc/systemd/system/pluck-review.service.d/memory.conf" && ok "backup: service memory cap 2G (drop-in)" || bad "backup memory drop-in"
grep -q 'SystemMaxUse=20M' "$PS/log" && ok "the journal is capped (a log flood can't fill the disk)" || bad "journal cap"

: > "$PS/log"
px --storage local-lvm --size 50 --quality 1080-low --cores 2 --memory 2048 --bridge vmbr0 --name pluck-backup --pair "$LINK"; rc=$?
[ $rc = 0 ] && lacks 'pct create' "$PS/log" && lacks 'pct resize' "$PS/log" && ok "second run reuses the container (no create, no resize)" || bad "second run" "rc=$rc"
lacks PLUCK_MAIN_LINK "$env" && ok "already paired: --pair is ignored" || bad "paired ignores --pair"

: > "$PS/log"
px --storage local-lvm --size 80 --name pluck-backup; rc=$?
[ $rc = 0 ] && grep -qxF 'pct resize 100 rootfs +30G' "$PS/log" && grep -qx 'PLUCK_BACKUP_MAX=80G' "$env" && ok "a bigger --size grows the disk" || bad "resize" "rc=$rc"

: > "$PS/log"
px --name pluck-backup --size 20; rc=$?
[ $rc = 0 ] && lacks 'pct resize' "$PS/log" && ok "a smaller --size never shrinks" || bad "no shrink"

# --role host: a main host with read-only media mounts, no pairing link, prints its pairing line
for args in "--role host" "--role host --media relative/path" "--role host --media /nonexistent-pluck-x" "--role host --media $S/media --pair $LINK" "--media $S" "--role mirror --media $S"; do
  mkdir -p "$S/media"; : > "$PS/log"
  # shellcheck disable=SC2086
  px $args; rc=$?
  [ $rc != 0 ] && lacks 'pct create' "$PS/log" && ok "rejects: $args" || bad "rejects: $args" "rc=$rc"
done
# (the stub's container files are shared: start the host's from empty)
rm -rf "${PS:?}/root"; mkdir -p "$PS/root"
: > "$PS/log"
px --role host --media "$S/media" --ip 192.0.2.50/24,gw=192.0.2.1; rc=$?
[ $rc = 0 ] && grep -q -- '--hostname pluck-review ' "$PS/log" && grep -qxF "pct set 101 --mp0 $S/media,mp=/media/nas1,ro=1" "$PS/log" \
  && ok "host: own container (pluck-review) with the media mounted read-only" || bad "host create" "rc=$rc $(tail -3 "$PS/out")"
envh="$PS/root/etc/pluck-review/env"
grep -qx 'PLUCK_ROLE=host' "$envh" && grep -qx 'PLUCK_ARGS=--listen 0.0.0.0:8790 --admin 0.0.0.0:8791 --media nas1=/media/nas1' "$envh" \
  && lacks PLUCK_MAIN_LINK "$envh" && lacks PLUCK_BACKUP "$envh" && ok "host: env has the role, ports and media" || bad "host env" "$(cat "$envh")"
grep -qx 'MemoryMax=3G' "$PS/root/etc/systemd/system/pluck-review.service.d/memory.conf" && grep -q -- '--memory 4096 ' "$PS/log" \
  && ok "host: service memory cap 3G (drop-in), container 4 GB" || bad "host memory" "$(grep 'pct create' "$PS/log")"
grep -qxF '192.0.2.50:8790 pluck-host:KEYkey_-@AB:CD' "$PS/out" && ok "host: prints address and pairing line for Pluck (not the iroh line written first)" || bad "host pairing line" "$(tail -2 "$PS/out")"
: > "$PS/log"
px --role host --media "$S/media" --ip 192.0.2.50/24,gw=192.0.2.1; rc=$?
[ $rc = 0 ] && lacks 'pct create' "$PS/log" && lacks 'pct set' "$PS/log" && lacks 'pct stop' "$PS/log" && ok "host: second run keeps the container and its mounts" || bad "host rerun" "rc=$rc"
: > "$PS/log"
px --role host --media "$S/media" --media "$S" --ip 192.0.2.50/24,gw=192.0.2.1; rc=$?
[ $rc = 0 ] && grep -qxF 'pct stop 101' "$PS/log" && grep -qF -- "--mp1 $S,mp=/media/nas2,ro=1" "$PS/log" && ok "host: a new media folder stops, mounts, starts" || bad "host new media" "rc=$rc"
: > "$PS/log"
px --role backup --name pluck-review --pair "$LINK"; rc=$?
[ $rc != 0 ] && grep -q 'is a Pluck host' "$PS/out" && ok "refuses to turn a host container into a backup" || bad "role switch" "rc=$rc $(tail -1 "$PS/out")"
grep -qxF 'ExecStart=/opt/pluck-review/current/pluck-review --host /var/lib/pluck-review $PLUCK_ARGS' "$PX/pluck-review.service" \
  && ok "service takes the role and host arguments from the env file" || bad "service ExecStart"

# bad signature: nothing is pushed or run
rm -rf "${PS:?}/ct" "${PS:?}/root" "${PS:?}/started"; mkdir -p "$PS/ct" "$PS/root"; : > "$PS/log"
SIGKEY="$S/other.pem" EXTRA=1 mk_release v9.9.9
px --name pluck-backup --pair "$LINK"; rc=$?
[ $rc != 0 ] && lacks 'pluck-review-update.sh' "$PS/log" && grep -q 'signature check failed' "$PS/out" && ok "bad release signature: nothing installed" || bad "px bad signature" "rc=$rc"

# a container with our name but not ours is refused
printf 'hostname: pluck-backup\nrootfs: local-lvm:vm-100-disk-0,size=58G\n' > "$PS/ct/100.conf"; : > "$PS/log"
EXTRA=1 mk_release v9.9.9
px --name pluck-backup --pair "$LINK"; rc=$?
[ $rc != 0 ] && lacks 'pct push' "$PS/log" && ok "refuses a foreign container with the same name" || bad "foreign container"

echo "== units"
check "update service is hardened as in the spec" grep -q 'ReadWritePaths=/opt/pluck-review /var/lib/pluck-review/update' "$PX/pluck-review-update.service"
check "service has RuntimeDirectory for the health file" grep -qx 'RuntimeDirectory=pluck-review' "$PX/pluck-review.service"
check "path unit watches the request file" grep -q 'PathChanged=/var/lib/pluck-review/update/request' "$PX/pluck-review-update.path"
check "timer is persistent with 20m jitter" sh -c "grep -qx 'Persistent=true' '$PX/pluck-review-update.timer' && grep -qx 'RandomizedDelaySec=20m' '$PX/pluck-review-update.timer'"
missing=""
for k in NoNewPrivileges=yes ProtectSystem=strict ProtectHome=yes PrivateTmp=yes PrivateDevices=yes ProtectKernelTunables=yes ProtectKernelModules=yes ProtectControlGroups=yes 'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK' RestrictNamespaces=yes LockPersonality=yes MemoryDenyWriteExecute=yes 'SystemCallFilter=@system-service' 'CapabilityBoundingSet=' ReadWritePaths=/var/lib/pluck-review MemoryMax=2G TasksMax=256 User=pluck-review Restart=on-failure RestartSec=5 EnvironmentFile=/etc/pluck-review/env; do
  grep -qxF "$k" "$PX/pluck-review.service" || missing="$missing $k"
done
[ -z "$missing" ] && ok "pluck-review.service hardening list present" || bad "pluck-review.service lacks" "$missing"

echo "== templates"
python3 -I "$HERE/template_test.py" "$DOCKER" && ok "truenas template renders and parses; compose and coturn conf checked" || bad "templates"

echo
echo "passed $NPASS, failed $NFAIL"
[ "$NFAIL" = 0 ]
