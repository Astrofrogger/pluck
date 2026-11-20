#!/usr/bin/env bash
# Pluck's own Edit Anywhere relay in a Proxmox LXC container (unprivileged, Docker inside), with the same hardening as
# the TrueNAS app: user 568, read-only, no capabilities, no-new-privileges, memory/CPU caps, only 443/tcp and 7842/udp.
# Run as root in the Proxmox host's shell, after checking this file's SHA-256 (Pluck shows the one-line command).
# Running it again (Pluck shows a new command when Macs are added or removed) updates the same container: the
# certificates stay, the relay container is made again with the new allowlist.
#
#   bash pluck-relay-proxmox.sh --hostname relay.example.com --contact owner@example.com --image ghcr.io/…@sha256:…
#        --allow <node id>,<node id> [--tls acme|files] [--secrets-file /root/pluck-relay-secrets]
#        [--storage local-lvm] [--cores 1] [--memory 512] [--bridge vmbr0] [--name pluck-relay]
#        [--ip 192.168.1.60/24,gw=192.168.1.1]
#
# --tls acme (default): iroh-relay gets its certificate from Let's Encrypt itself over port 443 (no port 80).
# --tls files: a lego sidecar gets it by DNS challenge (Cloudflare). The token never goes on the command line: put a
# DNS_TOKEN=… line in a file only root can read (chmod 600) and pass --secrets-file, or export PLUCK_DNS_TOKEN.
#
# Test-only knob: PLUCK_LEGO_IMAGE (the sidecar image).
set -euo pipefail

LEGO_IMAGE="${PLUCK_LEGO_IMAGE:-docker.io/goacme/lego:v4.25.2}"

die() { echo "pluck-relay-proxmox: $*" >&2; exit 1; }
usage() { sed -n '2,17p' "$0" >&2; exit 64; }
need() { [ $# -ge 2 ] || die "$1 needs a value"; }
matches() { printf '%s' "$2" | grep -Eq "$1"; }

HOSTNAME_="" CONTACT="" IMAGE="" ALLOW="" TLS=acme SECRETS="" STORAGE=local-lvm CORES=1 MEMORY=512 BRIDGE=vmbr0
NAME=pluck-relay IPCIDR="" GATEWAY="" DNS_TOKEN="${PLUCK_DNS_TOKEN:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) need "$@"; HOSTNAME_="$2" ;;
    --contact) need "$@"; CONTACT="$2" ;;
    --image) need "$@"; IMAGE="$2" ;;
    --allow) need "$@"; ALLOW="$2" ;;
    --tls) need "$@"; TLS="$2" ;;
    --secrets-file) need "$@"; SECRETS="$2" ;;
    --storage) need "$@"; STORAGE="$2" ;;
    --cores) need "$@"; CORES="$2" ;;
    --memory) need "$@"; MEMORY="$2" ;;
    --bridge) need "$@"; BRIDGE="$2" ;;
    --name) need "$@"; NAME="$2" ;;
    --ip) need "$@"; IPCIDR="$2" ;;
    --dns-token) die "--dns-token is not accepted (it would show in the process list): put DNS_TOKEN=… in a chmod 600 file and pass --secrets-file <file>" ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift 2
done

# --- 1. checks (every value ends up in a file or a command: plain characters only)
[ "$(id -u)" = 0 ] || die "run this as root on the Proxmox host"
command -v pct >/dev/null && command -v pveam >/dev/null || die "pct/pveam not found: run this on a Proxmox host"
HOSTNAME_="$(printf '%s' "$HOSTNAME_" | tr 'A-Z' 'a-z')"
matches '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' "$HOSTNAME_" && [ ${#HOSTNAME_} -le 253 ] \
  || die "bad --hostname (the relay's domain, e.g. relay.example.com)"
matches '^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,253}$' "$CONTACT" || die "bad --contact (an e-mail address for Let's Encrypt)"
matches '^[a-z0-9./_-]{1,200}@sha256:[0-9a-f]{64}$' "$IMAGE" || die "bad --image (the relay image with its sha256 digest, never latest)"
ALLOW="$(printf '%s' "$ALLOW" | tr 'A-F' 'a-f')"
matches '^[0-9a-f]{64}(,[0-9a-f]{64})*$' "$ALLOW" || die "bad --allow (node ids, comma separated; an open relay is never started)"
case "$TLS" in acme|files) ;; *) die "bad --tls (acme or files)" ;; esac
matches '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$' "$STORAGE" || die "bad --storage"
matches '^[0-9]{1,2}$' "$CORES" && [ "$CORES" -ge 1 ] && [ "$CORES" -le 16 ] || die "bad --cores"
matches '^[0-9]{3,5}$' "$MEMORY" && [ "$MEMORY" -ge 256 ] || die "bad --memory (MB, at least 256)"
matches '^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$' "$BRIDGE" || die "bad --bridge"
matches '^[a-z0-9-]{1,32}$' "$NAME" || die "bad --name (a-z, 0-9, dash, up to 32)"
case "$IPCIDR" in *,gw=*) GATEWAY="${IPCIDR#*,gw=}"; IPCIDR="${IPCIDR%%,gw=*}" ;; esac
if [ -n "$IPCIDR" ]; then
  matches '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "$IPCIDR" || die "bad --ip (a.b.c.d/nn,gw=a.b.c.d)"
  matches '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "$GATEWAY" || die "--ip needs its gateway: a.b.c.d/nn,gw=a.b.c.d"
fi
if [ -n "$SECRETS" ]; then
  [ -f "$SECRETS" ] && [ ! -L "$SECRETS" ] || die "--secrets-file: not a regular file"
  case "$(stat -c %a "$SECRETS")" in 600|400) ;; *) die "--secrets-file must be chmod 600 (only root can read it)" ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      DNS_TOKEN=*) DNS_TOKEN="${line#DNS_TOKEN=}" ;;
      ''|'#'*) ;;
      *) die "--secrets-file: only DNS_TOKEN= lines" ;;
    esac
  done < "$SECRETS"
fi
if [ "$TLS" = files ]; then
  [ -n "$DNS_TOKEN" ] || die "--tls files needs the DNS token: DNS_TOKEN=… in --secrets-file (chmod 600)"
  [ ${#DNS_TOKEN} -le 512 ] && matches '^[A-Za-z0-9_.-]+$' "$DNS_TOKEN" || die "the DNS token has characters a Cloudflare token doesn't"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ct() { pct exec "$CTID" -- "$@"; }

# --- 2. Debian 12 template
pveam update >/dev/null || echo "pluck-relay-proxmox: pveam update failed; using the list we have" >&2
TPL="$(pveam available --section system | awk '{print $2}' | grep '^debian-12-standard' | sort -V | tail -n 1 || true)"
[ -n "$TPL" ] || die "no debian-12-standard template found"
pveam list local | grep -q "$TPL" || pveam download local "$TPL"

# --- 3. container: reuse ours, else create (unprivileged; Docker inside needs nesting and keyctl)
CTID=""
for id in $(pct list | awk 'NR>1 {print $1}'); do
  cfg="$(pct config "$id")"
  if printf '%s\n' "$cfg" | grep -Eq "^hostname: $NAME\$"; then
    printf '%s\n' "$cfg" | grep -Eq '^description:.*pluck-relay' \
      || die "container $id is called $NAME but is not Pluck's relay; pick another --name"
    CTID="$id"; break
  fi
done
if [ -z "$CTID" ]; then
  CTID="$(pvesh get /cluster/nextid)"
  if [ -n "$IPCIDR" ]; then NET="name=eth0,bridge=$BRIDGE,ip=$IPCIDR,gw=$GATEWAY"; else NET="name=eth0,bridge=$BRIDGE,ip=dhcp"; fi
  pct create "$CTID" "local:vztmpl/$TPL" --hostname "$NAME" --unprivileged 1 --features nesting=1,keyctl=1 \
    --cores "$CORES" --memory "$MEMORY" --swap 256 --rootfs "$STORAGE:4" \
    --net0 "$NET" --onboot 1 --description pluck-relay
fi
pct status "$CTID" | grep -q running || pct start "$CTID"
i=0; until ct getent hosts deb.debian.org >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -lt 60 ] || die "the container has no network (check the bridge and DHCP)"; sleep 1
done

# --- 4. inside: Docker from Debian, the settings in root-only files
ct sh -c 'set -e; export DEBIAN_FRONTEND=noninteractive
  command -v docker >/dev/null || { apt-get update; apt-get install -y --no-install-recommends docker.io ca-certificates; }
  systemctl enable --now docker >/dev/null
  install -d -m 0700 /etc/pluck-relay'
{
  echo "PLUCK_RELAY_HOSTNAME=$HOSTNAME_"
  echo "PLUCK_RELAY_CONTACT=$CONTACT"
  echo "PLUCK_RELAY_ALLOW=$ALLOW"
  echo "PLUCK_RELAY_TLS=$TLS"
} > "$WORK/relay.env"
pct push "$CTID" "$WORK/relay.env" /etc/pluck-relay/relay.env --perms 0600
if [ "$TLS" = files ]; then
  { echo "CLOUDFLARE_DNS_API_TOKEN=$DNS_TOKEN"; echo "EMAIL=$CONTACT"; echo "HOST=$HOSTNAME_"; } > "$WORK/dns.env"
  pct push "$CTID" "$WORK/dns.env" /etc/pluck-relay/dns.env --perms 0600
fi

# --- 5. the containers (values were checked above; the relay first, so the certificates' volume is user 568's)
cat > "$WORK/run.sh" <<EOF
set -e
HARDEN="--restart unless-stopped --user 568:568 --read-only --cap-drop ALL --security-opt no-new-privileges:true --tmpfs /tmp:size=8m --log-opt max-size=10m --log-opt max-file=3"
docker pull '$IMAGE'
docker rm -f pluck-relay >/dev/null 2>&1 || true
docker run -d --name pluck-relay \$HARDEN --pids-limit 128 --memory 256m --cpus 1 \\
  -p 443:8443/tcp -p 7842:7842/udp -v pluck-relay-certs:/certs --env-file /etc/pluck-relay/relay.env '$IMAGE'
docker rm -f pluck-relay-certs >/dev/null 2>&1 || true
if [ '$TLS' = files ]; then
  docker run -d --name pluck-relay-certs \$HARDEN --memory 128m --cpus 0.25 -v pluck-relay-certs:/certs \\
    --env-file /etc/pluck-relay/dns.env --entrypoint /bin/sh '$LEGO_IMAGE' -c \\
    'lego --accept-tos --path /certs --email "\$EMAIL" --dns cloudflare --domains "\$HOST" run; while true; do lego --path /certs --email "\$EMAIL" --dns cloudflare --domains "\$HOST" renew --days 30; sleep 86400; done'
else
  rm -f /etc/pluck-relay/dns.env
fi
EOF
pct push "$CTID" "$WORK/run.sh" /etc/pluck-relay/run.sh --perms 0700
ct sh /etc/pluck-relay/run.sh

# --- 6. what to do on the router
sleep 3
ct docker ps --filter name=pluck-relay --format '{{.Names}}: {{.Status}}' || true
IP="$( { [ -n "$IPCIDR" ] && echo "${IPCIDR%/*}"; } || ct hostname -I | awk '{print $1}')"
echo "Pluck's relay runs in container $CTID."
echo "On the router, forward 443 (TCP) and 7842 (UDP) to $IP, and point $HOSTNAME_ at the office's public IP."
echo "Then use Test relay in Pluck."
