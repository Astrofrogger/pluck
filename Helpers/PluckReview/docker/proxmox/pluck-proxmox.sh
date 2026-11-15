#!/usr/bin/env bash
# Pluck Review backup host in a Proxmox LXC container. Run as root in the Proxmox host's shell,
# after checking this file's SHA-256 (Pluck shows the one-line command). Running it again updates
# the same container: the data stays, --size only grows the disk, and an already paired backup
# ignores --pair.
#
#   bash pluck-proxmox.sh [--storage local-lvm] [--size 50] [--quality 1080-low] [--cores 2]
#        [--memory 2048] [--bridge vmbr0] [--name pluck-backup] [--ip 192.168.1.50/24 --gateway 192.168.1.1]
#        [--update-time 04:00] [--secrets-file /root/pluck-secrets] [--turn-urls U1,U2]
#        --pair 'pluck://edit-anywhere/join?i=…'
#
# Secrets never go on the command line (other users see it in the process list): put
# RELAY_TOKEN=… and/or TURN_SECRET=… lines in a file only root can read (chmod 600) and pass
# --secrets-file, or export PLUCK_RELAY_TOKEN / PLUCK_TURN_SECRET before running this.
#
# Test-only knobs: PLUCK_RELEASE_BASE (download URL, file:// works), PLUCK_TEST_PUBKEY_FILE,
# PLUCK_PAIR_WAIT_SECS (120).
set -euo pipefail

REPO="__PLUCK_REPO__"
TAG="__PLUCK_TAG__"

# The release signing key (Ed25519), the same one as in pluck-review-update.sh. Replace REPLACE with
# the PEM that `scripts/sign-host-release.sh --init` prints. While it says REPLACE nothing installs.
PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
REPLACE_WITH_PUBLIC_KEY_FROM_sign-host-release.sh_--init
-----END PUBLIC KEY-----'

die() { echo "pluck-proxmox: $*" >&2; exit 1; }
usage() { sed -n '2,18p' "$0" >&2; exit 64; }
need() { [ $# -ge 2 ] || die "$1 needs a value"; }
matches() { printf '%s' "$2" | grep -Eq "$1"; }

STORAGE=local-lvm SIZE=50 QUALITY=1080-low CORES=2 MEMORY=2048 BRIDGE=vmbr0 NAME=pluck-backup
IPCIDR="" GATEWAY="" UPDATE_TIME=04:00 PAIR="" TURN_URLS="" SECRETS=""
RELAY_TOKEN="${PLUCK_RELAY_TOKEN:-}" TURN_SECRET="${PLUCK_TURN_SECRET:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --storage) need "$@"; STORAGE="$2" ;;
    --size) need "$@"; SIZE="$2" ;;
    --quality) need "$@"; QUALITY="$2" ;;
    --cores) need "$@"; CORES="$2" ;;
    --memory) need "$@"; MEMORY="$2" ;;
    --bridge) need "$@"; BRIDGE="$2" ;;
    --name) need "$@"; NAME="$2" ;;
    --ip) need "$@"; IPCIDR="$2" ;;
    --gateway) need "$@"; GATEWAY="$2" ;;
    --update-time) need "$@"; UPDATE_TIME="$2" ;;
    --pair) need "$@"; PAIR="$2" ;;
    --relay-token|--turn-secret) die "$1 is no longer accepted (it would show in the process list): put RELAY_TOKEN=… / TURN_SECRET=… in a chmod 600 file and pass --secrets-file <file>" ;;
    --secrets-file) need "$@"; SECRETS="$2" ;;
    --turn-urls) need "$@"; TURN_URLS="$2" ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift 2
done

# --- 1. checks
[ "$(id -u)" = 0 ] || die "run this as root on the Proxmox host"
command -v pct >/dev/null && command -v pveam >/dev/null || die "pct/pveam not found: run this on a Proxmox host"
for c in curl openssl perl sha256sum base64; do command -v "$c" >/dev/null || die "missing command: $c"; done
matches '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$' "$STORAGE" || die "bad --storage"
matches '^[0-9]{1,5}$' "$SIZE" && [ "$SIZE" -ge 1 ] || die "bad --size (whole GB)"
matches '^(same|(540|720|1080)-(low|medium|high))$' "$QUALITY" || die "bad --quality (540-low … 1080-high, or same)"
matches '^[0-9]{1,2}$' "$CORES" && [ "$CORES" -ge 1 ] && [ "$CORES" -le 64 ] || die "bad --cores"
matches '^[0-9]{3,6}$' "$MEMORY" && [ "$MEMORY" -ge 512 ] || die "bad --memory (MB, at least 512)"
matches '^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$' "$BRIDGE" || die "bad --bridge"
matches '^[a-z0-9-]{1,32}$' "$NAME" || die "bad --name (a-z, 0-9, dash, up to 32)"
matches '^([01][0-9]|2[0-3]):[0-5][0-9]$' "$UPDATE_TIME" || die "bad --update-time (HH:MM)"
# Pluck's sheet passes "--ip a.b.c.d/nn,gw=a.b.c.d"; a separate --gateway works too.
case "$IPCIDR" in *,gw=*) [ -n "$GATEWAY" ] || GATEWAY="${IPCIDR#*,gw=}"; IPCIDR="${IPCIDR%%,gw=*}" ;; esac
if [ -n "$IPCIDR" ]; then
  matches '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "$IPCIDR" || die "bad --ip (a.b.c.d/nn)"
  matches '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "$GATEWAY" || die "--ip needs --gateway a.b.c.d"
fi
if [ -n "$PAIR" ]; then
  matches '^pluck://edit-anywhere/join\?i=[A-Za-z0-9_%.~=&:/+-]+$' "$PAIR" || die "bad --pair link (must start with pluck://edit-anywhere/join?i=)"
fi
if [ -n "$SECRETS" ]; then
  [ -f "$SECRETS" ] && [ ! -L "$SECRETS" ] || die "--secrets-file: not a regular file"
  case "$(stat -c %a "$SECRETS")" in 600|400) ;; *) die "--secrets-file must be chmod 600 (only root can read it)" ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      RELAY_TOKEN=*) RELAY_TOKEN="${line#RELAY_TOKEN=}" ;;
      TURN_SECRET=*) TURN_SECRET="${line#TURN_SECRET=}" ;;
      ''|'#'*) ;;
      *) die "--secrets-file: only RELAY_TOKEN= and TURN_SECRET= lines" ;;
    esac
  done < "$SECRETS"
fi
# These go into the env file: plain characters only, no spaces, quotes or newlines.
for v in "$RELAY_TOKEN" "$TURN_SECRET" "$TURN_URLS"; do
  [ -z "$v" ] || matches '^[A-Za-z0-9_.:,/?=&%+~@-]{1,512}$' "$v" || die "bad RELAY_TOKEN/TURN_SECRET/--turn-urls value"
done
case "$REPO$TAG" in
  *PLUCK_REPO__*|*PLUCK_TAG__*) [ -n "${PLUCK_RELEASE_BASE:-}" ] || die "this is an unprocessed source copy; use the file from the release" ;;
esac
if [ -n "${PLUCK_TEST_PUBKEY_FILE:-}" ]; then
  PUB="$PLUCK_TEST_PUBKEY_FILE"
else
  case "$PUBKEY_PEM" in
    *REPLACE*) die "no signing key in this script yet: run scripts/sign-host-release.sh --init and paste the public key into it" ;;
  esac
  PUB="$(mktemp)"; printf '%s\n' "$PUBKEY_PEM" > "$PUB"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE="${PLUCK_RELEASE_BASE:-https://github.com/$REPO/releases/download}/$TAG"
jget() { perl -MJSON::PP -0777 -e 'my $j=decode_json(<STDIN>); $j=$j->{$_} for @ARGV; print defined $j ? $j : ""' "$@"; }
ct() { pct exec "$CTID" -- "$@"; }

# --- 2. Debian 12 template
pveam update >/dev/null || echo "pluck-proxmox: pveam update failed; using the list we have" >&2
TPL="$(pveam available --section system | awk '{print $2}' | grep '^debian-12-standard' | sort -V | tail -n 1)"
[ -n "$TPL" ] || die "no debian-12-standard template found"
pveam list local | grep -q "$TPL" || pveam download local "$TPL"

# --- 3. container: reuse ours, else create
CTID=""
for id in $(pct list | awk 'NR>1 {print $1}'); do
  cfg="$(pct config "$id")"
  if printf '%s\n' "$cfg" | grep -Eq "^hostname: $NAME\$"; then
    printf '%s\n' "$cfg" | grep -Eq '^description:.*pluck-review' \
      || die "container $id is called $NAME but is not a Pluck container; pick another --name"
    CTID="$id"; break
  fi
done
if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid)"
  if [ -n "$IPCIDR" ]; then NET="name=eth0,bridge=$BRIDGE,ip=$IPCIDR,gw=$GATEWAY"; else NET="name=eth0,bridge=$BRIDGE,ip=dhcp"; fi
  pct create "$CTID" "local:vztmpl/$TPL" --hostname "$NAME" --unprivileged 1 --features nesting=0 \
    --cores "$CORES" --memory "$MEMORY" --swap 512 --rootfs "$STORAGE:$((SIZE + 8))" \
    --net0 "$NET" --onboot 1 --description pluck-review
else
  # --size only grows the disk.
  have="$(pct config "$CTID" | sed -n 's/^rootfs:.*size=\([0-9]*\)G.*/\1/p')"
  if [ -n "$have" ] && [ "$((SIZE + 8))" -gt "$have" ]; then
    pct resize "$CTID" rootfs "+$((SIZE + 8 - have))G"
  fi
fi
pct status "$CTID" | grep -q running || pct start "$CTID"
i=0; until ct getent hosts deb.debian.org >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 60 ] || die "the container has no network (check the bridge and DHCP)"; sleep 1
done

# --- 4. inside: packages, user, folders
ct sh -c 'set -e; export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ffmpeg ca-certificates curl openssl jq
  id pluck-review >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin pluck-review
  install -d -m 0700 -o pluck-review -g pluck-review /var/lib/pluck-review
  install -d -m 0755 -o pluck-review -g pluck-review /var/lib/pluck-review/update
  install -d -m 0755 /opt/pluck-review /opt/pluck-review/releases
  install -d -m 0750 -o root -g pluck-review /etc/pluck-review'

# --- 5. binaries through the verified updater
for f in host-release.json host-release.json.sig pluck-review-update.sh pluck-review.service \
         pluck-review-update.service pluck-review-update.timer pluck-review-update.path; do
  curl -fsSL --retry 2 --max-time 300 -o "$WORK/$f" "$BASE/$f" || die "download failed: $f"
done
base64 -d < "$WORK/host-release.json.sig" > "$WORK/sig.bin" 2>/dev/null || die "signature is not base64"
[ "$(wc -c < "$WORK/sig.bin" | tr -d ' ')" = 64 ] || die "signature has the wrong length"
openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$WORK/host-release.json" -sigfile "$WORK/sig.bin" >/dev/null 2>&1 \
  || die "signature check failed; nothing was installed"
for f in pluck-review-update.sh pluck-review.service pluck-review-update.service \
         pluck-review-update.timer pluck-review-update.path; do
  want="$(jget assets "$f" < "$WORK/host-release.json")"
  have="$(sha256sum "$WORK/$f" | cut -d' ' -f1)"
  [ -n "$want" ] && [ "$want" = "$have" ] || die "$f does not match the signed release; nothing was installed"
done
pct push "$CTID" "$WORK/pluck-review-update.sh" /usr/local/sbin/pluck-review-update.sh --perms 0755
ct /usr/local/sbin/pluck-review-update.sh --install "$TAG"

# --- 6. config
PAIRED=0; ct test -s /var/lib/pluck-review/main.json && PAIRED=1
if [ "$PAIRED" = 0 ] && [ -z "$PAIR" ]; then die "this backup is not paired yet: add --pair '<invite link from Pluck>'"; fi
OLDENV="$(ct cat /etc/pluck-review/env 2>/dev/null || true)"
{
  echo "PLUCK_ROLE=backup"
  echo "PLUCK_IROH=1"
  [ "$PAIRED" = 1 ] || echo "PLUCK_MAIN_LINK=$PAIR"
  echo "PLUCK_BACKUP_MAX=${SIZE}G"
  echo "PLUCK_BACKUP_QUALITY=$QUALITY"
  echo "PLUCK_UPDATE_TIME=$UPDATE_TIME"
  # Keep what an earlier run (or Pluck) set, unless this run gives a new value.
  for k in RELAY_TOKEN TURN_SECRET TURN_URLS; do
    eval "new=\$$k"
    if [ -n "$new" ]; then echo "PLUCK_$k=$new"; else printf '%s\n' "$OLDENV" | grep "^PLUCK_$k=" || true; fi
  done
} > "$WORK/env"
pct push "$CTID" "$WORK/env" /etc/pluck-review/env --perms 0600
ct sh -c 'chown root:pluck-review /etc/pluck-review/env && chmod 0640 /etc/pluck-review/env'

# --- 7. systemd
sed "s/__PLUCK_UPDATE_TIME__/$UPDATE_TIME/" "$WORK/pluck-review-update.timer" > "$WORK/timer.out"
pct push "$CTID" "$WORK/pluck-review.service" /etc/systemd/system/pluck-review.service
pct push "$CTID" "$WORK/pluck-review-update.service" /etc/systemd/system/pluck-review-update.service
pct push "$CTID" "$WORK/timer.out" /etc/systemd/system/pluck-review-update.timer
pct push "$CTID" "$WORK/pluck-review-update.path" /etc/systemd/system/pluck-review-update.path
# The host logs to the journal: cap it (10 MB files, 20 MB in all) so a log flood can't fill the disk.
ct sh -c 'mkdir -p /etc/systemd/journald.conf.d && printf "[Journal]\nSystemMaxFileSize=10M\nSystemMaxUse=20M\n" > /etc/systemd/journald.conf.d/pluck-review.conf && systemctl restart systemd-journald'
ct systemctl daemon-reload
ct systemctl enable --now pluck-review.service pluck-review-update.timer pluck-review-update.path
NEWENV="$(cat "$WORK/env")"
[ -z "$OLDENV" ] || [ "$OLDENV" = "$NEWENV" ] || ct systemctl restart pluck-review.service

# --- 8. wait for pairing
WAIT="${PLUCK_PAIR_WAIT_SECS:-120}"; i=0
until ct test -s /var/lib/pluck-review/main.json && ct test -s /var/lib/pluck-review/iroh-id; do
  i=$((i + 1))
  if [ "$i" -gt "$WAIT" ]; then
    echo "pluck-proxmox: not paired after ${WAIT}s. Last log lines:" >&2
    ct journalctl -u pluck-review -n 20 --no-pager >&2 || true
    exit 1
  fi
  sleep 1
done
# The name comes from the container: no control characters on this root terminal.
MAIN="$(ct cat /var/lib/pluck-review/main.json | jget name | tr -d '[:cntrl:]' | cut -c1-80)"
RAW="$(ct cat /var/lib/pluck-review/iroh-id | head -n 1 | cut -c1-8 | tr 'a-z' 'A-Z')"
echo "Paired with $MAIN. Check code: ${RAW:0:4}-${RAW:4:4}"
