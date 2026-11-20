# Pluck Review host

The host keeps review links working when your Mac is off: it makes the review copies from your
files, serves them to clients and keeps their comments. Nothing is stored on pluck.tools, and no
port is opened to the internet.

Three ways to run it:

| where | file | how |
|---|---|---|
| TrueNAS SCALE 25.04+ | `truenas-compose.yml` | Pluck installs it for you (automatic), or by hand |
| Proxmox (backup host at another site) | `proxmox/pluck-proxmox.sh` | one pasted command |
| any other Docker host | `docker-compose.yml` | build locally |

The image (`Dockerfile`) holds `pluck-review` and `pluck-iroh` (the secure tunnel for access from
anywhere) plus Debian's `ffmpeg`. Its build context is `Helpers/`:

    docker build -f PluckReview/docker/Dockerfile -t pluck-review-host Helpers

## TrueNAS, automatic

Pluck > Settings > Review > Set up a NAS host > TrueNAS (automatic). It needs the NAS address and a
TrueNAS API key of a dedicated user (never root's), makes the datasets, and installs the app from
`truenas-compose.yml` with the image pinned by digest from the signed `host-release.json`.
The template uses `{{name}}` placeholders (never the dollar-brace form, which TrueNAS interpolates);
optional parts sit between `# begin:media2` / `# end:media2` and `# begin:uploads` / `# end:uploads`
lines, which Pluck keeps or drops whole.

The first time a release is published, open GitHub > Packages > `pluck-review-host` and make the
package **public**, so the NAS can pull it without a login.

## TrueNAS, by hand

1. **Data dataset.** Create `tank/apps/pluck-review`. Give the `apps` user (568) read/write access,
   and read access to your media dataset(s).
2. **Second NAS (optional).** On the other NAS: Shares > NFS > Add, path = its media dataset,
   **Read only** on, Hosts = this NAS's IP only, Maproot/Mapall = a user that can read the media.
   Start the NFS service.
3. **Install.** Apps > Discover Apps > Install via YAML. Paste a filled-in copy of
   `truenas-compose.yml` (the `image` is a published `ghcr.io/…@sha256:…` reference), or build
   `docker-compose.yml` yourself.
4. **First start.** The logs show `{"host":{"listen":…,"fingerprint":…}}` and a `pairing` line.
5. **Pair Pluck.** Deliver > Set up a NAS host > enter the NAS address and sync port. If Pluck made
   the host key it already knows it; otherwise paste the `pairing` line (`pluck-host:<key>@<fingerprint>`,
   also in `pairing.txt`). Pluck pins the certificate fingerprint on first connect.
6. **Admin page (optional).** `https://<LAN address>:<admin port>` on your network. The first visit asks
   for the host key and a new password (10 characters or more).

### The host key

32 random bytes, base64url without padding (43 characters). Pluck makes it and puts it in the
template as `PLUCK_HOST_KEY`, or leave it empty and the host makes one on first start (`host-key` in
the data dataset). Anyone with it can publish to and read from the host: keep it like a password.

## Settings (environment)

`PLUCK_HOST_KEY`, `PLUCK_HOST_NAME`, `PLUCK_IROH` (1 = reachable from anywhere), `PLUCK_UPLOADS`
(`id=/uploads/id`, a read-write folder for uploaded renders; the media roots stay read-only),
`PLUCK_ROLE` (`main`, or `backup`), `PLUCK_MAIN_LINK` (backup: the invite, used once),
`PLUCK_BACKUP_MAX` (e.g. `50G`), `PLUCK_BACKUP_QUALITY` (`540-low` … `1080-high`, or `same`),
`PLUCK_RELAY_TOKEN`, `PLUCK_TURN_SECRET`, `PLUCK_TURN_URLS`, `PLUCK_UPDATE_TIME` (HH:MM, read by
the Proxmox installer and Pluck, not by the host itself).

## Backup host

A backup is a replica of your main host at another site. It serves lighter copies while the main
is offline and hands its comments back when it returns. It has no media roots and never serves
originals. Pluck > Settings > Review > your NAS > Backup host asks for storage, quality and where it
runs, and makes the one-time invite link.

**On TrueNAS:** the same template with `PLUCK_ROLE=backup`, `PLUCK_MAIN_LINK`, `PLUCK_BACKUP_MAX` and
`PLUCK_BACKUP_QUALITY`. **On Proxmox:** Pluck shows one command to paste in the Proxmox host's
shell:

    cd /root && curl -fsSLO https://github.com/<owner>/<repo>/releases/download/<tag>/pluck-proxmox.sh \
      && echo "<sha256>  pluck-proxmox.sh" | sha256sum -c - \
      && bash pluck-proxmox.sh --storage local-lvm --size 50 --quality 1080-low --cores 2 --memory 2048 \
         --bridge vmbr0 --name pluck-backup --pair 'pluck://edit-anywhere/join?i=…'

It makes an unprivileged Debian 12 container (disk = size + 8 GB), installs the verified release,
pairs, and prints `Paired with <main name>. Check code: ABCD-EFGH`; the main's device list shows the
same code. Running it again updates the container (data kept, `--size` only grows the disk, an
already paired backup ignores `--pair`). Optional: `--ip a.b.c.d/nn --gateway …`, `--update-time HH:MM`,
`--turn-urls`, and `--secrets-file <file>` for the relay token and TURN secret: a `chmod 600` file
with `RELAY_TOKEN=…` and/or `TURN_SECRET=…` lines (or export `PLUCK_RELAY_TOKEN` /
`PLUCK_TURN_SECRET` first). They are never command-line flags, which every user of the Proxmox host
could read in the process list. Needs `perl`, `curl` and `openssl` on the Proxmox host
(all standard there). The container gets `jq` too; the updater needs it.

## Updates

Pluck follows its own release: it reads that release's signed `host-release.json` (Ed25519; the
public key is compiled into Pluck, and embedded in the two scripts here) and checks every file's
SHA-256 against it. Unsigned or wrong: nothing runs.

**From 4.0.7 the host updates itself** (`src/selfupdate.rs`), on TrueNAS, Proxmox and any Docker host
alike, with no Docker socket, API key or root: `--host` on Linux first runs a small supervisor that
starts the newest verified program in `<data>/.pluck-host/bin/<version>/` (the data volume; the
image root stays read-only), else the built-in one. Pluck tells the host its own version
(`self-update`, admins only; a host never gets ahead of its Macs, never goes down). The host fetches
that release's `host-release.json` + `.sig` from GitHub (HTTPS; only github.com and its asset CDN),
checks the signature before anything else, downloads `pluck-review-linux-<arch>` and
`pluck-iroh-linux-<arch>`, checks their SHA-256 and that the new program runs and says that version,
then exits 75 when nobody is watching and nothing uploads or copies (or in the hour after
`PLUCK_UPDATE_TIME`, UTC). A new program that exits within a minute is marked bad
(`.pluck-host/bad.json`) and the previous one runs. Two versions are kept. "Updates by itself" off
(`auto: false`) waits for Update Now. `PLUCK_SELF_UPDATE=0` runs the host without the supervisor.
The routes below are for hosts before 4.0.7 (their one last update):

- **TrueNAS:** Pluck updates the app through the API (with the stored API key) at the quiet time
  (default 04:00), after asking the host to finish uploads and copies (`prepare-update`). On failure
  it puts the previous compose back.
- **Proxmox:** `pluck-review-update.timer` (daily at the quiet time, +/- 20 min) and
  `pluck-review-update.path` (Pluck's "Update now" writes the request) run `pluck-review-update.sh`:
  verify, unpack to `/opt/pluck-review/releases/<version>/`, wait while the host is busy (up to 1 h),
  switch `current`, restart, require a healthy `/run/pluck-review/health` within 90 s, else roll back
  and never retry that version. The last two releases are kept; the result is in
  `/var/lib/pluck-review/update/last.json`. A version older than the installed one is refused
  (`pluck-review-update.sh --allow-downgrade --install <tag>` as root in the container does it on
  purpose). The updater runs as root but reads and writes the service user's folders only as that
  user, keeps its lock and failed list in `/var/lib/pluck-review-update` (root only), and runs
  `pluck-review --ctl` as the service user.
- **Other Docker hosts:** no automatic update; Pluck shows the new digest to paste.

### Releasing (owner)

1. Publish a GitHub release. `.github/workflows/review-host-release.yml` builds both architectures,
   pushes the image and uploads the tarballs, `pluck-proxmox.sh`, `pluck-review-update.sh`, the
   four systemd files and `host-release.json`. It does not sign.
2. Run `scripts/sign-host-release.sh <tag>`: it checks every hash, signs, and uploads
   `host-release.json.sig`. Until then no host installs the release.
   Self-updating hosts download `pluck-review-linux-<arch>` / `pluck-iroh-linux-<arch>` from it:
   both must be in the signed `assets`.
4. Once, with 4.0.7 (the first release with the supervisor): the image must be published with it, and
   every TrueNAS host made before needs one last update by hand (Pluck shows it: Apps ›
   pluck-review › Edit, the new image, Save; or one API key). Proxmox hosts take it through
   "Update Now" (the old root updater); re-running `pluck-proxmox.sh` turns that updater's timer off.
3. Once: `scripts/sign-host-release.sh --init`, then paste the public key into `PUBKEY_PEM` in
   `proxmox/pluck-proxmox.sh`, `proxmox/pluck-review-update.sh` and Pluck. While it says `REPLACE`
   the scripts refuse to install anything.

## Relay (optional)

`coturn/` holds your own TURN relay for viewers behind strict networks: start it with
`docker compose --profile relay up -d` after reading `coturn/README.md` (router steps, certificate).

## Files in the data folder

`bundle/` (manifest and review copies), `comments.jsonl` (comments and approvals, append-only),
`host-key`, `pairing.txt`, `tls-cert.der`, `tls-key.der`, `admin-password` (a PBKDF2 hash), and on a
backup `main.json`, `iroh-id`. Deleting `bundle/copies` frees space; copies are made again on the
next publish.

## Tests

`bash Helpers/PluckReview/tests/scripts/run.sh` (or `cargo test --test scripts`) exercises the
updater, the Proxmox installer, the signer and the templates with stub commands. Nothing real is touched.

## Licences

The image contains Debian's `ffmpeg` (GPL v2 or later as Debian builds it), used as a separate
program; Debian publishes its source. The release tarballs carry `LICENSES/` with the licence
files of the Rust crates inside `pluck-review` and `pluck-iroh`.
