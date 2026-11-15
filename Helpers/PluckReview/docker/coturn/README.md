# Your own TURN relay (coturn)

A relay is only needed when a viewer's network blocks direct connections. This service runs coturn
on the same machine as the host, in its own container. It relays **only to the host's address**:
every IPv4 and IPv6 address is denied (public ones too), then `allowed-peer-ip` opens the host's
LAN address and nothing else. coturn can't limit the port; the firewall rule under "Port scope"
does that.

Pluck never changes your router. You do the steps below once.

## How the settings reach coturn

`turnserver.conf` cannot read environment variables. The realm and addresses are
**command-line flags** in `docker-compose.yml` (`command:`), filled from the env file. coturn
merges both; the flags win. The config file is mounted read-only.

The shared secret is never a flag (anyone on the NAS could read it in the process list or with
`docker inspect`). It's a one-line file: the container appends `static-auth-secret=<it>` to a
private copy of the config in its own tmpfs at start.

    printf '%s\n' '<long random string>' > /mnt/tank/apps/pluck-review/turn-secret
    chown 65534:65534 /mnt/tank/apps/pluck-review/turn-secret && chmod 400 /mnt/tank/apps/pluck-review/turn-secret

| env value | used for |
|---|---|
| `TURN_SECRET_FILE` | path of that file (mounted read-only at `/run/turn-secret`) |
| `TURN_SECRET` | the same string, for the host (`PLUCK_TURN_SECRET`), which mints the viewers' credentials |
| `TURN_REALM` | `--realm`, e.g. `turn.example.com` |
| `LAN_ADDR` | `--listening-ip`, `--relay-ip`, `--allowed-peer-ip` |
| `TURN_EXTERNAL_IP` | `--external-ip=<public>/<LAN_ADDR>`: your public address, so clients are told where to send media |
| `TURN_CERT_DIR` | folder with `fullchain.pem` and `privkey.pem` (mounted read-only at `/certs`) |

Start it with `docker compose --profile relay up -d`. It does not start otherwise.

## Router steps (you do these)

1. Optional: put the NAS on its own VLAN, so a problem at the relay can't reach your other devices.
2. Forward **only** these ports to the NAS's LAN address:
   - `3478` UDP and TCP (STUN/TURN)
   - `5349` TCP (TURN over TLS). To present it on `443` (firewalls that only allow HTTPS), map
     `443 -> 5349` on the router (MikroTik: a dst-nat rule). The container never binds a
     privileged port.
   - `49160-49200` UDP (the relay range, 41 ports)
3. Nothing else is opened. The host's sync and admin ports stay on the LAN.

## Port scope (you do this once)

The relay may only send to the host's address, but coturn can't restrict the port, so a viewer with
a credential could reach any UDP service on the NAS (DNS, rpcbind/NFS, SNMP, mDNS…) through it.
The helper's WebRTC port is chosen by the system at each start, always in Linux's ephemeral range
(32768-60999), while those services sit below it. So drop relayed packets (coturn's relay ports
49160-49200) to the NAS's own address below 32768. On the NAS, as root (replace 192.168.1.10):

    nft add table inet pluckrelay
    nft add chain inet pluckrelay out '{ type filter hook output priority 0; }'
    nft add rule inet pluckrelay out ip daddr 192.168.1.10 udp sport 49160-49200 udp dport 0-32767 drop

Check with `ss -lunp` that nothing else on the NAS listens on a UDP port of 32768 or above.
TrueNAS resets nftables on reboot: add the three lines as a post-init script (System > Advanced >
Init/Shutdown Scripts).

## Certificate (DNS challenge)

TLS needs a certificate for the relay's name (e.g. `turn.example.com`). Use a **DNS challenge**
(for instance with `acme.sh` or your DNS provider's ACME integration), so the router does not
need port 80 open. Put `fullchain.pem` and `privkey.pem` in one folder, readable by user 65534,
and set `TURN_CERT_DIR` to it. Renew it from outside the container, then
`docker compose --profile relay restart coturn`.

## Connecting Pluck to it

In Pluck: Settings > Review > "My own relay (TURN)". Enter the URLs and the secret, for example

```
turns:turn.example.com:443?transport=tcp
turn:turn.example.com:3478?transport=udp
```

Pluck gives the secret to your hosts (`PLUCK_TURN_SECRET`, `PLUCK_TURN_URLS`) and they hand each
viewer short-lived credentials (username `<expiry>:<peer>`, HMAC-SHA1 of it). The Worker never
sees the secret. If you use Cloudflare's TURN instead (the owner's relay token), you don't need this
service at all.

## Limits and hardening

Per user 4 allocations, 40 in total, 8 Mbit/s per allocation; no CLI, no TCP relaying, no TLS 1.0/1.1;
one CPU, 256 MB, 128 processes; read-only root, all capabilities dropped, `no-new-privileges`.
Logs go to stdout (`docker compose logs coturn`) without user names.

The image is pinned by digest in `docker-compose.yml`. To update it, pull a newer tag, check its
digest, and replace it.
