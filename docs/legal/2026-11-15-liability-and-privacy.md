# Liability and privacy: Pluck, Pluck Studio, pluck.tools, Pluck Review, Edit Anywhere

Date: 2026-11-15. Status: **draft research, not legal advice.** A Belgian lawyer (contract, consumer, IP and data
protection law) must review this and the two site pages before anything is published. Fill the placeholders
`[PUBLISHER NAME]`, `[ADDRESS]`, `[CONTACT EMAIL]`, `[JUDICIAL DISTRICT]` (and `[ENTERPRISE NUMBER]` only if the
publisher ever registers with the KBO/BCE).

Files written with this doc:
- `pluck-site/src/pages/terms.astro`, `pluck-site/src/pages/privacy.astro` (noindex, not in the sitemap, until reviewed)
- `pluck-site/src/layouts/Base.astro`: Terms and Privacy links in the footer
- `pluck-release/SECURITY.md`, `pluck-release/docs/legal/2026-11-15-incident-plan.md`

Careful: the next `deploy/deploy.sh` publishes the footer links and the pages, placeholders included. Fill them in
(or revert the footer edit) before the next deploy.

---

## 1. "It's free and open source, so I'm not liable", is that right?

Short answer: **partly. "Free" removes a lot, "open source" doesn't apply, and some liability can never be removed.**

**(1) Pluck is not open source in the legal sense.** The LICENSE is "all rights reserved": the code can be seen
but not copied, changed or redistributed. That is *source-available*. Both EU laws define free and open-source
software as software under a licence that lets anyone freely access, use, modify and redistribute it (CRA art.
3(48); PLD recital 14 uses the same concept). So the **FOSS exclusions of the Product Liability Directive (PLD
2024/2853, art. 2(2)) and the Cyber Resilience Act (CRA 2024/2847) do not cover Pluck as such.**

That isn't the end of it. Both laws only reach products made available "in the course of a commercial
activity, whether in return for payment or free of charge" (PLD art. 4(7); CRA art. 3(22)). So the real question
for Pluck is: *is publishing it a commercial activity?* Indicators against: no price, no ads, no personal data
collected (PLD recital 14 and CRA recital 15 name price and use of personal data as the signs of commerce), made
by an individual in spare time. Indicators for: a polished "Studio" product and marketing site, a hosted service,
donations, and the publisher using the same tools in their own paid work. A non-commercial finding is likely
but **less certain than if Pluck were genuinely FOSS**, because the FOSS recitals give an explicit safe harbour and
Pluck has to rely on the general rule.

**(2) Donations.** CRA recital 15: *"Accepting donations without the intention of making a profit should not be
considered to be a commercial activity"*; the same recital treats donations *exceeding* the costs of design,
development and provision as a sign of commercial activity. The recital is about products generally, not only
FOSS. The PLD is silent on donations; its recital 14 links commerce to a price or to personal data used for more
than security/compatibility. Practical reading: small donations, nothing given in return, total below the real
costs (hardware, Cloudflare, Apple developer fees, time is debatable) = not commercial. Keep a simple yearly note
of donations vs costs. See §2 for the wording.

**(3) What "free" does and does not remove.**

| Removed or reduced by "free" | Not removed |
| --- | --- |
| Consumer *conformity* claims for digital content (Directive 2019/770, Belgian Civil Code art. 1701/1 ff.) apply only when a price or personal data is given in return: Pluck gets neither. | Fault-based liability in tort (Belgian Civil Code Book 6, art. 6.5 ff., in force 1 Jan 2025) to anyone harmed, including people who never accepted any terms (an editor's clients, people whose IP address is processed). |
| Most of the contractual expectation: a free tool "as is" sets a low standard of what users can expect. | Liability for one's own intentional fault, and any clause covering harm to life or physical integrity (Book 5 art. 5.89 §1). |
| The PLD/CRA, *if* the activity is non-commercial (see above). | Gross negligence, towards consumers, if the publisher counts as an "enterprise" under Book VI (art. VI.83 blacklist, see §6). Courts will look hard at gross negligence anyway. |
| | GDPR: applies to the Worker, relay and logs whether or not anything is paid. The household exemption doesn't cover running a service for others. |
| | Copyright/anti-circumvention rules on the download tool (see §5.7), which no terms clause can fix. |

**(4) Licence options for liability vs "nobody copies or sells my code"** (no change made; owner's choice):

| Option | Liability effect | Copying/selling |
| --- | --- | --- |
| Keep all rights reserved (now) | No FOSS safe harbour; rely on "non-commercial" and on the Terms. | Strongest control. |
| Source-available licence (PolyForm Noncommercial/Strict, Business Source License, a custom "view only" licence with a standard warranty disclaimer) | Same as now legally (not FOSS), but a clear, well-known disclaimer text and a clean permission story. | Strong: commercial use/resale forbidden. |
| GPL-3.0 / AGPL-3.0 | FOSS: gains the explicit PLD/CRA exclusion while non-commercial. GPL's own disclaimer is subject to the same Belgian limits. | Anyone may copy, change and **sell** it, but must publish their changes under the GPL. AGPL extends that to hosted use (relevant for Review). |
| MIT / Apache-2.0 | FOSS, same gain as GPL. | Anyone may copy, sell, close it. Weakest control. |

The liability gain from going FOSS is real but modest: it only matters if a court would otherwise call the
activity commercial, and the PLD/CRA mostly concern safety-type damage (see §5.1). The owner's wish to prevent
copying points to the first two rows. Note the Spektrafilm engine is already a separate opt-in GPL download.

---

## 2. Decided: individual publisher, donations kept

**What publishing as an individual means.** There is no company between the publisher and any claim: if a claim
succeeds, it is paid from **personal assets** (savings, house, income), and for a married/legally cohabiting
publisher possibly from common assets. The Terms reduce the chance and size of claims; they can't build a wall.
What helps most, in order:
1. Collect and keep almost no data (done largely; §4 lists the rest), so there's little to breach.
2. Show due care: audits, tests, SECURITY.md, incident plan, prompt fixes (the hardening plan). This is the
   practical defence against "gross negligence".
3. The Terms' "as is / free / backups / no uptime" framing, honest carve-outs.
4. Insurance: ask the existing family liability policy (familiale verzekering / BA vie privée) in writing whether
   a free, non-commercial software hobby and a free online service are covered; many policies exclude
   "professional activities" and some exclude IT damage. A separate professional liability policy normally
   requires an enterprise number. Ask a broker once.
5. If the publisher's own video business uses Pluck Review for paying clients (the owner-relay rooms), keep that
   business use clearly separate from "publishing Pluck" so it doesn't paint the publication as commercial.

**Donation wording** (used in the Terms; use the same idea on the Buy Me a Coffee page and next to every button):
> "A donation is a voluntary gift. It doesn't buy anything: no licence, features, support, updates, priority
> or access to the services. Pluck stays the same whether you donate or not."

Also: no Buy Me a Coffee "memberships", "extras" or perks; no "supporters get…" anywhere; no fixed prices.
That keeps donations a gift (no contract for a service, no consumer-law "price") and fits CRA recital 15. Ask an
accountant once how Belgian tax treats regular small donations to a private person.

---

## 3. Data-flow inventory (from the source, 2026-11-15)

Legend: **Owner** = something the publisher runs or chose. **3rd** = a third party contacted directly by the
user's device. **Local** = stays on the user's device.

### 3.1 Worker and Durable Objects (pluck-site/deploy/worker, Cloudflare)

| Data | Where | Kept | Notes |
| --- | --- | --- | --- |
| HTTP request (IP, UA, URL path, headers) for every HTML page, `/r/*`, `/signal/*` | Cloudflare edge only | Cloudflare's own | **Workers Logs off** (`observability: { enabled: false }` in `deploy/cloudflare.config.ts`, R1); the Worker has no `console.*` calls. Still check the dashboard for a Logpush job (none expected). The URL fragment (link key) is never sent by browsers. |
| Room storage: `regHash` (SHA-256 of the owner-only registration secret), `joinHash` (SHA-256 of the link's join value), `lastMac` (ISO time), `until` (ms: the link's expiry, else a year), `joins` ({start, n}: checked joins this minute, no IP) | Room DO SQLite (`room.ts`) | 30 days after a server was last online everything but a tombstone `{regHash, until}` is deleted; the tombstone goes at `until` (at most 5 years). Erase (R11) leaves the same tombstone. | Pseudonymous, no personal data on its own. The tombstone stops a link holder from taking over a lapsed room (§13.24). |
| Guess brake `JOINS` (10/min) and backstops `SOCKETS` (120/min browser sockets), `REGS` (600/min server sockets) | Cloudflare Workers rate limiting | About a minute per counter | Keyed by `HMAC(LIMIT_KEY, ipKey(ip))` (16 bytes; IPv6 by /64, `::ffff:` IPv4 as IPv4), never the IP. JOINS counts unverified browser joins and servers' refused/first registrations and erases; verified joins never. |
| Per-socket tag: role, random peer id `p_xxxxxxxx`, open time, `sha256(salt + IP)` (16 bytes), room id, flags | WebSocket attachment (`serializeAttachment`) | While the socket is open (browsers max 10 min) | R5: the raw IP is never stored; the 16-byte salt lives only in the object's memory (new after hibernation). Used for join rate limiting. |
| `joinsByIp` map: salted IP hash -> join times | DO memory | 60 s window; cleared on hibernation | Rate limit (10 joins/min/IP). |
| Room erase | Room DO | - | R11: `{"t":"erase","v":2,"reg","expires"?}` from whoever holds the room's reg deletes `joinHash`, `lastMac`, the counters and folds the room's ledger rows, keeping only the tombstone `{regHash, until}`; every socket closes with 4005. Pluck sends it from "Delete Link and Its Data…". |
| SDP offers/answers and ICE candidates | Passed through, not stored | Transient | **Contain both sides' IP addresses** (host, srflx, relay candidates) and DTLS fingerprints. Content is not visible: media and ctl channels are DTLS end-to-end. |
| Relay ledger `creds`: room id, peer id, TURN username, minted/exp times, bytes, final, month; `meta` month totals (`month:<YYYY-MM>`: bytes, pending count) and `analytics` | RelayBudget DO SQLite (`ledger.ts`) | A row lives only until its credential is final, or expired + 1 h (≤ ~5 h); then it folds into the month total and is deleted (R6). Month totals: current + previous month. | Only rooms whose Mac presents `OWNER_RELAY_TOKEN` (the owner's own rooms). |
| TURN traffic | Cloudflare Realtime TURN | Cloudflare's own | Encrypted DTLS/SRTP-style payload; Cloudflare sees IPs and volumes. |
| STUN | `stun.cloudflare.com:3478` only (`room.ts` `STUN_ONLY`; Mac side: `DeliverLink.swift:75`, `ReviewPublish.swift:871`, `Helpers/PluckReview/src/main.rs:105`) | Cloudflare's own | R2: Google STUN removed; Cloudflare is already the processor. |

### 3.2 Review page in the client's browser (pluck-site/src/review)

| Key | Content | Storage | Sent to |
| --- | --- | --- | --- |
| `pluck-review-token` | random 32 bytes, one per browser, **never sent**: `auth` carries `HMAC-SHA256(token, roomId)`, different per room (R3) | localStorage (session fallback) | Editor's Mac in `auth` (stored there as sha256 `authorToken`) |
| `pluck-review-token-rooms` | room ids (no keys) opened before R3, which keep the old global token so their comments stay editable | localStorage | Nowhere; cleared by "Forget"/"Forget all" |
| `pluck-review-name` | what the client typed | localStorage | Editor's Mac (auth, comments, approvals, activity log, watermarks) |
| `pluck-review-email` | what the client typed | sessionStorage (this tab), localStorage only with "Remember my email on this device" ticked (R7) | as the name |
| `pluck-review-links` | up to 30 opened links with key, title, time; **none older than 90 days; never a password or personal link**; "Forget all" (R4) | localStorage | Nowhere (local list) |
| `pluck-review-branding:<room>` | editor's branding | sessionStorage | - |
| language + view prefs (grid, viewer, comments, overlays, compare) | settings | localStorage | - |

No cookies, no analytics, no third-party scripts or fonts (CSP `default-src 'self'`). The key stays in the
fragment; `Referrer-Policy: no-referrer`. ePrivacy art. 5(3): all of this is "strictly necessary" for a feature
the user asked for (consent not required), but it must be disclosed (done in privacy.astro).

### 3.3 The editor's Mac / NAS (controller: the editor)

Client name, email, comments, drawings, approvals with proof (`DeliverProof.swift`), uploads, an activity log
(`Review/activity/<linkID>.jsonl`: name, email, time; **Settings › Review › Keep activity: 30/90/180 days or
forever, default 90**, 20,000 entries per link, `DeliverActivity.swift`; NAS hosts get the same days in the manifest
`activityDays`, `host.rs` `compact`, R8). "Delete Link and Its Data…" deletes a link's log (R11), watermarks with name/email. Never on the owner's server. Spec test asserts the host log
has no `ip` (`host.rs:2088`).

### 3.4 Edit Anywhere (Remote/**, Helpers/PluckIroh, Helpers/PluckTunnel)

- iroh `presets::N0` (`PluckIroh/src/main.rs:137`): **n0's public relays and discovery** (number 0, a US company) see
  node ids and IP addresses; streams are QUIC/TLS end-to-end. Users can set their own relay (`"relay"`).
- Tailscale (`pluck-tunnel`, tsnet; `PrivateNetwork.swift` calls `api.tailscale.com`): the user's own account.
- Pairing slots: one-time, max 15 min, on the office Mac. Nothing passes through the owner.
- NAS review hosts reach the editor via LAN or an iroh tunnel (`ReviewHostTunnel.swift`).

### 3.5 Other outbound requests from the apps (all 3rd, nothing to the owner)

| Host | Why | What it sees |
| --- | --- | --- |
| api.github.com, github.com | App update check (`AppUpdater.swift:161`), yt-dlp (`Updater.swift:174`), Deno (`HelperToolsUpdater.swift:145`), NAS host updates (`DeliverHostUpdate.swift:64`), uv, KAIR weights | IP, default UA; **no identifiers added** |
| ffmpeg.martin-riedl.de | FFmpeg download (`HelperToolsUpdater.swift:121`) | IP |
| huggingface.co | Vision LLMs (`Edit/VisionModel.swift`), SAM, LaMa, depth, stems models | IP, which file; on request only |
| raw.githubusercontent.com | lensfun data, film packs | IP |
| lrclib.net | Lyrics: artist/title (`Lyrics.swift`) | song metadata, UA "Pluck (repo URL)" |
| itunes.apple.com, open.spotify.com, i.ytimg.com | Metadata/thumbnails for pasted links | the link/track id |
| The site of a pasted link | yt-dlp download; **browser cookies only if the user picks a browser** (default `none`, `DownloadManager.swift:62`), read locally, passed only to that site | the user's session on that site |
| www.youtube.com, music.youtube.com | Search in the app (yt-dlp `ytsearch` / YouTube Music search, `Search.swift`), oEmbed for artist names | **the search text**, IP |
| music.apple.com | Apple Music links (`AppleMusic.swift`, page read for metadata) | the link |
| pluck.tools | Review signaling (`wss://pluck.tools/signal/<room>`, helper), room erase (`DeliverLink.erase`) | IP, room id, reg key proof; see 3.1 |
| stun.cloudflare.com | STUN (helper and browsers) | IP |
| speed.cloudflare.com | Review host upload test (`Helpers/PluckReview/src/uplink.rs`): 3 × 4 MB random bytes at start and every ~6 h; `PLUCK_UPLINK_TEST=off` disables | IP, random bytes; no UA, no cookies |
| ghcr.io | NAS host container images (pulled by the NAS; pinned digests from the release, `DeliverHostUpdate.swift:146`) | the NAS's IP |
| login.tailscale.com | opened in the browser only (`OfficeRenderView.swift`) | - |
| buymeacoffee.com | a link only | - |

No crash reporting, telemetry or analytics anywhere (grep for sentry/telemetry/analytics/firebase/posthog: none).
Local AI: Apple on-device speech/translation/Apple Intelligence and local models; no cloud AI provider found.

---

## 4. Risky flows and the exact minimisation change (input for hardening plan §1)

Applied 2026-11-15 (R1-R8, R11; R9 disclosure only; R10 already mitigated): see each row's file; the inventory in §3 shows the result.

| # | Flow | Risk | Change (file: what) |
| --- | --- | --- | --- |
| R1 | Workers Logs on for every request incl. `/signal/*` | IP addresses of clients/editors kept 3-7 days by the owner's processor; contradicts spec "request lines only" if headers are logged | `pluck-site/deploy/cloudflare.config.ts`: in `observability`, turn invocation logs off (`logs: { invocationLogs: false }`, the `cf/config` form of Wrangler's `[observability.logs] invocation_logs = false`), keep `console` logs only for errors without IPs; or set a low `headSamplingRate`. Then check Workers & Pages > pluck-tools > Logs shows no IPs. Also confirm no Logpush job exists. |
| R2 | Google STUN | Third party (Google) gets every client's and editor's IP; not needed (Cloudflare STUN works and Cloudflare is already the processor) | Remove `stun:stun.l.google.com:19302` from `pluck-site/deploy/worker/room.ts` (`STUN_ONLY`), `Sources/Pluck/Deliver/DeliverLink.swift:75`, `Sources/Pluck/Deliver/ReviewPublish.swift:871`, `Helpers/PluckReview/src/main.rs:81`. Update tests that assert the list. |
| R3 | One global browser token for all rooms | `sha256(token)` is identical at every editor: two editors (or one editor with several rooms) can link the same client across projects. Not needed: edit-own-comment only needs per-room identity | `pluck-site/src/review/main.ts` `browserToken()`: send a per-room value, e.g. `b64url(HMAC-SHA256(token, roomId))` (or store `pluck-review-token:<room>`). Existing `authorToken`s change: accept old+new during one release, or note that old comments can't be edited from the browser. |
| R4 | `pluck-review-links` stores full link keys | Anyone with access to that browser profile can reopen every link (and on a shared computer, see a client's unreleased work) | `pluck-site/src/review/main.ts` (`rememberLink`/`openedLinks`): drop entries older than 90 days (or the link's expiry), add "Forget all", and skip remembering when the link is a personal/password link or when the user unticks "Remember on this device". |
| R5 | Client IP in socket attachment + `joinsByIp` | Raw IPs in owner storage while connected (small) | `pluck-site/deploy/worker/room.ts`: store `ip` as a hash with a per-object random salt held in memory (`sha256(salt + ip)` truncated to 16 bytes); rate limiting keeps working, the raw IP is never persisted with hibernation. |
| R6 | Relay ledger keeps room id + peer id + TURN username ~62 days | Longer than needed; the per-credential row is only needed until `final` or TTL | `pluck-site/deploy/worker/ledger.ts`: after `final` or `exp`, fold the row into a per-month total (`meta` key `month:<YYYY-MM>` bytes/pending) and delete it; keep only month totals for 2 months. Update `ledger` tests. |
| R7 | Email persisted in localStorage by default | Unneeded persistence on shared devices | `pluck-site/src/review/ui/name.ts`: keep email in sessionStorage unless a "Remember" box is ticked (name may stay in localStorage). |
| R8 | Activity log on the editor's Mac: 180 days with name/email | Editor's controller duty; long default | `Sources/Pluck/Deliver/DeliverActivity.swift`: make retention a setting (default 90 days?) and show it in the share sheet with one line "You keep this; tell your clients" (owner decision). |
| R9 | iroh default = n0 public relays/discovery | Third party (US) sees node ids/IPs; disclosed now | Optional: a setting/explanation in Edit Anywhere; or host an iroh relay on Cloudflare-adjacent infra. Disclosure is enough for now. |
| R10 | Cloudflare has no spending cap on TURN | Financial, not data: leaked token -> bill | Already mitigated (budget ledger, 4-h TTL). Keep the billing alert at 950 GB (documented in `cloudflare.config.ts`). |
| R11 | No admin tool to wipe one room's state | Incident response | Hardening: a secret-protected admin route or a script to `deleteAll` a Room by id. |

Good already: link key only in the fragment; strict CSP; `no-referrer`; TURN only for the owner's rooms; room TTL;
proof-based auth over DTLS fingerprints (no server can impersonate the Mac); no telemetry.

---

## 5. What applies (research, with sources)

### 5.1 Product Liability Directive (EU) 2024/2853
- Software is a product. Transposition by **9 December 2026** (art. 22); applies to products placed on the market
  after that date. Belgian transposition law: check its status (not found yet).
- FOSS outside commercial activity excluded (art. 2(2), recital 14); not Pluck's licence (§1).
- Commercial activity includes free supply (art. 4(7)).
- Damage covered: death/injury, damage to property, and **destruction/corruption of data not used for
  professional purposes** (art. 6(1)); property used exclusively for professional purposes is excluded. So an
  editor's professional project loss is outside the PLD; a hobbyist's personal photo library isn't.
- **Liability can't be excluded or limited by contract** (art. 15). The Terms therefore carve it out.
- Defences include the defect not existing when placed on the market and the development-risk defence (art. 11);
  for software, failing to provide security updates can itself be a defect while the manufacturer controls updates.

### 5.2 Cyber Resilience Act (EU) 2024/2847
- Applies from **11 December 2027**; vulnerability and incident **reporting from 11 September 2026** (art. 14:
  24 h early warning, 72 h notification, final report, via ENISA's single reporting platform).
- Only for products made available in a commercial activity (art. 3(22)); recital 15 on donations (§1); recital
  18: unmonetised FOSS isn't commercial. Pluck is not FOSS, so it relies on recital 15's general test.
- If it applied: CE marking, risk assessment, SBOM, vulnerability handling, support period. Heavy. Another reason
  to keep the activity plainly non-commercial. Reporting already applies (since 11 September 2026) if the CRA
  covers Pluck at all, so ask the lawyer for a written view now.

### 5.3 Belgian contract law: Civil Code Book 5 (in force 1 Jan 2023)
- Art. 5.89 §1: exemption clauses are allowed **except** for (a) one's own intentional fault (and, new, that of
  helpers), (b) a fault that harms life or physical integrity, and (c) a clause that empties the contract of its
  substance. Invalid clauses are deemed unwritten. Gross negligence is *not* on this general list: in non-consumer
  relations it can in principle be excluded.
- Standard terms bind only if the other party could know them and accepted them (Book 5 rules on general terms):
  a footer link alone is weak. Hence the in-app notice (§8) and the owner decision on acceptance.
- Book 6 (extra-contractual liability, in force 1 Jan 2025): fault liability remains; between contracting parties
  a clause can also cover tort claims within the same limits; **it never binds third parties** (an editor's clients).

### 5.4 Consumer law: Directive 93/13/EEC and Book VI WER
- Unfair terms rules apply to contracts between an **enterprise** and a consumer (WER art. I.1 and I.8, 22°;
  Directive "seller or supplier" acting for business purposes). Whether an individual publishing free software
  with donations is an "enterprise" (a natural person pursuing an economic goal in a durable way) is debatable;
  write the Terms as if it were.
- Art. VI.83 blacklist (null, no assessment): among others, excluding/limiting liability for the enterprise's
  **intent or gross fault** (and that of its agents), or, except force majeure, for failing an essential
  obligation; and for death or personal injury. (Verify the exact numbering, 13° and following, with the lawyer.)
- Directive 93/13 Annex point (b): inappropriately limiting legal rights; the €10 cap (or 12 months of payments) must be "appropriate". For
  a free product that seems defensible; lawyer to confirm.
- Rome I art. 6(2): choice of Belgian law cannot deprive a consumer of their home law's mandatory protection;
  Brussels Ibis art. 18: consumers can sue at home. The Terms say so.

### 5.5 GDPR roles
- **Owner = controller** for: website/Worker request data, signaling metadata (IP addresses in transit, peer ids),
  room state, relay ledger, Workers Logs, donor and email data. Purpose and means are the owner's.
- **Editor = controller** for all client data on their Mac/NAS (§3.3). The owner never receives it, so the owner is
  **not the editor's processor** and **no DPA between owner and editors is needed**. The privacy page says so.
  (If the owner ever stored comments, names or media server-side, this would flip to processor and need an
  art. 28 DPA.)
- Owner's processors: **Cloudflare** (hosting, Workers, DOs, TURN, logs).
- Not processors (independent third parties, chosen by the owner but receiving data directly from the user's
  device): Google STUN (remove, R2), n0 iroh relays, GitHub, Hugging Face, LRCLIB, Apple, Spotify. Disclose them.
- Legal bases: art. 6(1)(b) (providing the service asked for) and 6(1)(f) (security, abuse prevention, budget).
- International transfers: Cloudflare is EU-US Data Privacy Framework certified and its DPA includes SCCs.

### 5.6 Cloudflare DPA
Cloudflare's Self-Serve Subscription Agreement, section 6.1 (Data Processing), incorporates the Cloudflare Data
Processing Addendum "by reference into this Agreement". The DPA itself says it forms part of the Main Agreement,
including the Self-Serve Subscription Agreement. **Nothing to sign.** Owner to-do: (1) keep a PDF copy of the
current DPA version with this doc; (2) note the sub-processor list URL (cloudflare.com/gdpr/subprocessors) and
optionally subscribe to its change notices; (3) make sure the account email is monitored (Cloudflare notifies
breaches there).

### 5.7 Copyright and the download tool
- Users: Belgian private-copy exception (Code of Economic Law art. XI.190, 9°) only for copies from a **lawful
  source** (CJEU C-435/12 ACI Adam), and circumventing an effective technical protection measure is prohibited
  (art. XI.291, Directive 2001/29 art. 6). The Terms put this on the user.
- **Publisher risk that no clause fixes:** Directive 2001/29 art. 6(2) also forbids *distributing* tools mainly
  designed to circumvent effective TPMs. The Hamburg courts held YouTube's "rolling cipher" to be an effective TPM
  and held a hosting provider liable for aiding the distribution of youtube-dl (LG Hamburg, March 2023;
  OLG Hamburg 21 Nov 2024, 5 U 54/23). A Belgian court isn't bound, but rightsholders (IFPI/BVMI and their Belgian
  equivalents) have used this route. Pluck downloads and runs yt-dlp. Lower the risk: don't market "download from
  YouTube/Spotify", market "save your own and licensed media"; don't bundle yt-dlp in the DMG (fetch from its
  official release, as now); keep a working takedown/contact address; consider a Belgian IP lawyer's view.
- Spotify links: Pluck looks up metadata and finds the audio elsewhere: same user-responsibility clause.

### 5.8 ePrivacy (art. 5(3)) and the website
No cookies or trackers on pluck.tools. Review page storage is strictly necessary for requested features: no
consent banner, disclosure done (§3.2). Keep it that way: any analytics would need consent.

### 5.9 Digital Services Act
The DSA covers "information society services", normally provided for remuneration. A free hobby service with no
ads is arguably not one. If it is, signaling is a **mere conduit** (art. 4: transmits, doesn't host or store
content), with the liability exemption; all intermediaries must name a single point of contact (art. 11-12) and
describe content restrictions in their terms (art. 14). The Terms' fair-use section and contact email cover that
cheaply. Not a hosting service: no user content is stored.

---

## 6. What each clause protects against, and what can't be excluded

| Clause (terms.astro) | Protects against | Limits |
| --- | --- | --- |
| Free, as it is; keep backups | Claims that Pluck should have worked, kept compatibility, kept updating; data-loss claims (contributory fault of a user without backups) | Not intent; not gross negligence toward consumers if "enterprise"; not PLD damage (if PLD applies) |
| No uptime promise | Missed deliveries / deadlines through Review | Same |
| Review links are keys | Leaks by link sharing | A bug that leaks without sharing stays the owner's |
| User responsible for content, downloads, clients' data | Copyright claims via users; GDPR claims by clients (editor = controller) | Doesn't stop direct claims by rightsholders against the publisher (§5.7) |
| Fair use + blocking | Abuse; DSA art. 14 information | Act proportionately, warn if possible |
| Liability exclusion, €10 cap (or 12 months of payments) | Everything else, to the extent allowed | Intent, physical harm, gross negligence (consumers), PLD, GDPR art. 82, non-waivable consumer rights: all carved out explicitly. An overbroad clause risks being struck as a whole (no reduction under VI.84), which is why the carve-outs are honest. |
| Donation is a gift | Arguments that donors bought a service; PLD/CRA "commercial activity" | Keep it true in practice |
| Belgian law and courts, consumer home rights kept | Forum shopping; validity under Rome I / Brussels Ibis | |

**Gross negligence and GDPR (owner's two remaining risks).** Neither can be contracted away towards consumers or
data subjects. The defence is evidence of due care: the hardening plan (audit, tests, leak tests), SECURITY.md,
the incident plan, the record of processing below, minimal retention (§4), and fixing reported issues quickly.
GDPR art. 82 liability is excused if the controller proves it is "not in any way responsible" for the event;
the documentation is what proves it.

---

## 7. Record of processing (GDPR art. 30)

Art. 30(5) exempts organisations under 250 people **unless** the processing is not occasional, is likely to result
in a risk, or includes special categories. The signaling service runs continuously, so the exemption likely
**does not** apply. Keep this record (it costs nothing):

| Activity | Purpose | Legal basis | Data subjects | Data | Recipients / processors | Transfers | Retention | Security |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Website delivery | Serve pluck.tools, security | 6(1)(f) | Visitors | IP, UA, URL, time | Cloudflare | US (DPF, SCCs) | Logs ≤ 7 days | TLS, CSP |
| Review signaling | Connect browsers to the editor's Mac | 6(1)(b)/(f) | Editors, their clients | IP (in candidates and in memory), random peer id, room id, timing | Cloudflare | US (DPF, SCCs) | In memory while connected; room state 30 days after last Mac | TLS/WSS, rate limits, no content |
| Relay budget | Keep TURN within budget (owner rooms) | 6(1)(f) | The owner's clients | room id, peer id, TURN username, bytes | Cloudflare | US | ~62 days (target: month totals only, R6) | Token-gated |
| Request logs | Debugging, abuse | 6(1)(f) | All of the above | Request metadata incl. IP | Cloudflare | US | 3/7 days (target: off, R1) | Account 2FA |
| Donations | Thank donors, tax | 6(1)(f), 6(1)(c) | Donors | name, message, email if shared | Buy Me a Coffee (own controller) | per BMC | as tax law requires | BMC account 2FA |
| Email contact | Answer questions, security reports | 6(1)(f) | Senders | email, message | email provider | per provider | ≤ 2 years after last contact | |

Controller: [PUBLISHER NAME], [ADDRESS], [CONTACT EMAIL]. No DPO (not required: no large-scale monitoring).

---

## 8. Short in-product texts

**First launch (one line + link, both apps):**
> Pluck is free and comes as it is. Keep backups, and only download what you have the right to. [Terms & privacy]

(Link: `https://pluck.tools/terms/`. Show once in the welcome screen; also as a footnote in What's New when the
terms change.)

**Review page footer (always, not only when branded):**
> Shared with Pluck · Your comments go to the person who shared this link, not to Pluck. [Privacy] [Terms]

(Today `sharedWith()` in `src/review/main.ts` shows only "foot.shared" when branding is set; add the two links to
`strings.ts` in all languages. For the name/email prompt, one line under the fields:
"Only the person who shared this link sees your name and email.")

**Settings > About (and Support):**
> Terms of use · Privacy · Security (report a vulnerability) · Licence · Third-party licences

(Security links to the repository's SECURITY.md.)

**Share sheet, for editors (once):**
> Your clients' names, comments and approvals are stored on this Mac. You're responsible for them. [Learn more]
(-> `https://pluck.tools/privacy/#editors`)

---

## 9. Owner decisions still open

1. **In-app acceptance?** A footer link is weak (§5.3). Options: (a) first-launch notice with link, "by
   continuing" (recommended: low friction, clearly better); (b) a click-to-accept checkbox (strongest, adds
   friction). The review page can't bind clients either way; they are third parties.
2. **Cap**: owner chose €10, or what was paid in the last 12 months if more (decided 2026-11-15). Lawyer to confirm it is "appropriate"; a near-zero cap on a free product is likelier to hold than on a paid one. First-launch notice: owner chose yes (decided 2026-11-15).
3. **Licence** (§1 table): keep all-rights-reserved or move to a named source-available licence with a standard
   warranty disclaimer.
4. **Download marketing** (§5.7): how prominently to advertise YouTube/Spotify downloading.
5. **Activity log retention default** (R8) and whether editors see a one-line notice in the share sheet.
6. **Insurance**: ask the family liability insurer in writing (§2).
7. Which minimisation changes (R1-R7, R11) go in the hardening round; all are recommended.
8. Lawyer review: Terms, Privacy, this doc, the CRA/PLD "commercial activity" question and the download-tool risk.

## 10. Sources

- PLD 2024/2853 text: https://eur-lex.europa.eu/eli/dir/2024/2853/oj (consolidated reading via https://lexaris.eu/book/version/documentflat/head/6811882) ; arts. 2(2), 4(7), 6(1), 11, 15, 22, recital 14
- CRA 2024/2847: https://eur-lex.europa.eu/eli/reg/2024/2847/oj ; recital 15: https://www.springlex.eu/en/packages/cra/cra-regulation/recital-15/ ; art. 14 timing: https://best.openssf.org/CRA-Brief-Guide-for-OSS-Developers
- GitHub on PLD/CRA for developers: https://github.blog/open-source/maintainers/what-the-eus-new-software-legislation-means-for-developers/
- Belgian Civil Code art. 5.89 (exemption clauses): https://legalnews.be/verbintenissen-goederen/beperking-van-aansprakelijkheid-in-het-nieuwe-verbintenissenrecht-forum-advocaten/ ; https://legalnews.be/handel-consument/nut-en-grenzen-van-een-exoneratiebeding-de-langhe-advocaten/ ; official text: ejustice.just.fgov.be (Book 5, law of 28 April 2022)
- Unfair terms, Book VI WER: https://legalnews.be/handel-consument/onrechtmatige-bedingen-in-consumentenovereenkomsten-gevaco-advocaten/ ; Directive 93/13: https://eur-lex.europa.eu/eli/dir/1993/13/oj
- Cloudflare Self-Serve Subscription Agreement §6.1: https://www.cloudflare.com/terms/ ; DPA: https://www.cloudflare.com/cloudflare-customer-dpa/
- Workers Logs retention and settings: https://developers.cloudflare.com/workers/observability/logs/workers-logs/
- youtube-dl / Uberspace: https://heise.de/-10179284 ; https://www.ferner-alsdorf.de/entscheidung-des-olg-hamburg-zu-youtube-dl/ ; https://torrentfreak.com/youtube-dl-hosting-ban-paves-the-way-to-privatized-censorship-230411/
- CJEU C-435/12 ACI Adam: https://curia.europa.eu/juris/liste.jsf?num=C-435/12
- GDPR: https://eur-lex.europa.eu/eli/reg/2016/679/oj (arts. 4(12), 6, 28, 30(5), 33, 34, 82)
- DSA 2022/2065: https://eur-lex.europa.eu/eli/reg/2022/2065/oj (arts. 4, 11, 12, 14)
- Belgian DPA: https://www.dataprotectionauthority.be

Not verified from primary text in this pass (lawyer to check): exact numbering of WER art. VI.83 items; Belgian PLD
transposition status; whether Workers invocation logs store `CF-Connecting-IP`.
