// Host mode: an always-on host (a NAS container, or another Mac) serves a published bundle with no
// Swift in the loop. It plays Swift's part of the spec (§3 auth, §6 handlers) against the bundle's
// manifest.json, and appends what clients write to comments.jsonl, which the editor's Pluck pulls.
// It talks to the RTC loop only through the same commands Swift would send ({"send"}, {"serve"},
// {"close"}, {"rooms"}), and hears the same reports ({"peer"}, {"msg"}).
//
// Layout of the data folder (see the spec, "Published bundles and always-on hosts"):
//   bundle/manifest.json  bundle/copies/<versionID>/…  bundle/originals/…   (pushed by Pluck)
//   comments.jsonl  host-key  tls-cert.der  tls-key.der                       (the host's own)
//   uploads/<linkID>/<id>.<ext>  uploads/.partial/                              (from clients: quarantine,
//                                 never served except as a comment attachment, never opened or run)
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
    io::Write,
    path::{Component, Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};

use crate::{Ev, copies, keys, log, report, roots::{Roots, kind_of}};

#[path = "host_accounts.rs"]
mod accounts_ops;
#[path = "host_mail.rs"]
mod mail_ops;

pub const PALETTE: [&str; 8] = ["#E0605E", "#E0A15E", "#F2D14B", "#7CC294", "#6FA8DC", "#A98BD8", "#EDEBE6", "#111111"];
pub const EMOJI: [&str; 12] = ["👍", "👎", "❤️", "😂", "😮", "🎉", "🔥", "👀", "✅", "❌", "🙏", "💯"];
const STATUSES: [&str; 4] = ["needsReview", "inProgress", "needsChanges", "approved"];
/// Link fields passed to browsers in `ready.link` as they are (the browser treats them as data).
/// (4.1: "order", "statusDefs", "fieldDefs": the link's own order, custom statuses' and fields' names; optional.)
const LINK_FIELDS: [&str; 16] = ["description", "layout", "requireName", "askEmail", "allowProxy", "audience", "recipient",
    "watermark", "fields", "featuredField", "uploads", "header", "order", "statusDefs", "fieldDefs", "delivered"];
const ACTIVITY_CAP: usize = 20_000; // per link, oldest dropped
const ACTIVITY_DAYS: i64 = 90; // when the manifest has no "activityDays" (Pluck's setting, R8; 0 = forever)
const UPLOADS_PER_HOUR: usize = 60; // per link
const UPLOADS_IN_FLIGHT: usize = 4; // per link
const MAX_UPLOAD: u64 = 20 << 30; // default per file
const MAX_ATTACHMENT: u64 = 50 << 20;
const MAX_HEADER: u64 = 400 * 1024;
const LINK_UPLOAD_RESERVE: u64 = 10 << 30; // free space a link upload must leave
const SUPERSEDED_MAX: usize = 64 << 20; // bytes of replaced comment snapshots before the log is compacted (#12)
const PULL_BYTES: usize = 16 << 20; // a pull page stays well under Pluck's 64 MiB line cap

/// A sync request (from stdin or the sync endpoint) and where its answer goes.
pub struct Sync {
    pub op: Value,
    pub reply: oneshot::Sender<Value>,
}

#[derive(Default)]
struct HPeer {
    room: String,
    nonce: [u8; 32],
    fp_mac: String,
    fp_browser: String,
    authed: bool,
    ready: bool,
    token: Option<String>, // sha256 of the browser's token
    name: String,
    wrong: u32,
    viewing: Option<String>,
    writes: VecDeque<Instant>,
    email: String,
    stills: VecDeque<Instant>,
    beacons: VecDeque<Instant>,
    fetches: HashMap<u64, Fetched>, // binary fetches in flight that need something when served
    pw: Value, // the link's passwordHash when this peer became ready: a change ends the session
    acct: accounts_ops::Acct, // signed in with a passkey (accounts plan)
}

/// What to do when a fetch has been served: log a download, delete a temporary still.
#[derive(Default)]
struct Fetched {
    download: Option<(Value, Value, String)>, // asset, version, what
    temp: Option<PathBuf>,
    version: Option<String>, // a backup: fetches in flight keep a version from eviction
}

/// An upload from a browser, between `upload-begin` and `upload-end`.
struct HUp {
    link: String,
    name: String,
    ext: String,
    kind: String, // MIME type, from the extension
    size: u64,
    attachment: bool,
    part: PathBuf,
    sha: Option<String>,          // the helper's hash, once every byte is on disk
    end: Option<(Value, String)>, // upload-end waiting for that: (request id, the browser's hash)
    into: Value,                  // the link's uploads.into ({"root","folder"}) for an asset upload, else null
}

pub struct Host {
    dir: PathBuf,
    log_path: PathBuf,
    manifest: Value,
    comments: Vec<Value>,
    status: HashMap<String, String>,
    entries: Vec<Value>,
    seq: u64,
    peers: HashMap<String, HPeer>,
    fails: HashMap<String, Vec<Instant>>,
    out: mpsc::UnboundedSender<Ev>,
    raw: Value,                    // manifest.json as published
    roots: Arc<Roots>,             // the read-only media roots, for publish by reference
    jobs: HashMap<String, Value>,  // versionID (or "<versionID>/wm-<linkID>") → {"state","progress","error"?}
    job_tx: Option<mpsc::UnboundedSender<copies::Job>>,
    data: PathBuf,
    fields: HashMap<String, serde_json::Map<String, Value>>, // asset → fields set from links
    activity: HashMap<String, usize>,                        // link → activity entries in the log
    attachments: HashMap<String, Value>,                     // attachment id → its upload entry
    uploads: HashMap<(String, u64), HUp>,                    // (peer, upload id)
    up_hour: HashMap<String, VecDeque<Instant>>,             // link → upload starts
    approvals: Vec<Value>,                                   // every approval in the log
    comment_tombs: HashMap<String, u64>,                     // deleted comment → its tombstone's rev
    act_ids: (std::collections::HashSet<String>, VecDeque<String>), // the last 50,000 activity/field ids
    deadlines: HashMap<String, Option<String>>,              // link → effective deadline, for change events
    proof_hashes: HashMap<String, Value>,                    // approval → {"sha256","hashOf"} found later, or {"making":true}
    pub ident: Ident,
    pub busy: Arc<crate::update::Busy>,
    pub replica: Option<Arc<crate::replica::Shared>>,
    pub outage: Option<Arc<crate::outage::Outage>>, // a backup: uploads taken during an outage, for the main (§13.25)
    pub back: Option<mpsc::UnboundedSender<(String, Value)>>, // results of background work, into run()
    added: Vec<(String, String)>, // (asset, version) added by a publish, told to viewers once its copy is ready
    superseded: usize, // bytes of comment snapshots appended since the last compaction that replace an earlier one
    pub accounts: crate::accounts::Accounts, // the team, its people and passkeys (accounts.json)
    acct_begins: VecDeque<Instant>,           // account-begin on this host, a minute
    pub upload_root: Option<Arc<crate::upload_root::UploadRoot>>, // a main's uploads root: team uploads go there (§4.4)
    root_ups: HashMap<(String, u64), accounts_ops::RootUp>,       // (peer, upload id) → a team upload into it
    placing: HashMap<String, (String, Value, Value, HUp)>,      // upload id → (peer, request id, entry, upload) while it's copied into its folder
    pub devices: Option<Arc<crate::devices::Devices>>, // the paired Macs: admins count for the last-admin guard (roles)
    pub mail: crate::mail::Mail, // email settings, subscribers and the queue (host_mail.rs)
    pub drops: HashMap<String, PathBuf>, // media root id → where clients' uploads may be written into it (--drop)
}

/// Who this host is: shown to Pluck, written into tombstones and proofs.
#[derive(Clone)]
pub struct Ident {
    pub id: String,
    pub name: String,
    pub backup: bool,
}

impl Ident {
    pub fn by(&self) -> String {
        format!("host:{}", self.id)
    }
}

const ACT_IDS: usize = 50_000;

pub fn now_iso() -> String {
    iso(now_secs())
}

/// The Worker's clock minus ours, in seconds, from the last `registered` (0 until then, or with an older Worker).
static CLOCK_OFFSET: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);

fn local_secs() -> i64 {
    // PLUCK_CLOCK_SKEW_SECS (tests only): this host's own clock off by that much, as a NAS without NTP.
    let skew = std::env::var("PLUCK_CLOCK_SKEW_SECS").ok().and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64) + skew
}

/// Now, in seconds since 1970, on the Worker's clock when we know it: expiry, deadlines and every timestamp the
/// host writes then agree with the browsers and the other hosts even if this machine's clock is off.
pub fn now_secs() -> i64 {
    local_secs() + CLOCK_OFFSET.load(std::sync::atomic::Ordering::Relaxed)
}

/// `registered` carried the Worker's time (ms). A second or less is network delay, not a wrong clock.
pub fn set_clock(worker_ms: i64) {
    if let Some(off) = new_offset(worker_ms, local_secs(), CLOCK_OFFSET.load(std::sync::atomic::Ordering::Relaxed)) {
        CLOCK_OFFSET.store(off, std::sync::atomic::Ordering::Relaxed);
        if off.abs() > 5 {
            log(format!("host: this machine's clock is {off} s off the Worker's; using the Worker's time"));
        }
    }
}

fn new_offset(worker_ms: i64, local: i64, old: i64) -> Option<i64> {
    let off = worker_ms.div_euclid(1000) - local;
    ((off - old).abs() > 1).then_some(off)
}

/// UTC "YYYY-MM-DDTHH:MM:SSZ", as Swift's .iso8601 writes it (civil-from-days).
pub fn iso(secs: i64) -> String {
    let (days, s) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", s / 3600, s / 60 % 60, s % 60)
}

fn v_id(v: Option<&Value>) -> Option<&Value> {
    v.map(|v| &v["id"])
}

/// SHA-256 of a file, lowercase hex, in 16 MiB reads.
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    use sha2::Digest;
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut h = sha2::Sha256::new();
    let mut buf = vec![0u8; 16 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// An ISO 8601 time (as Swift or JS write it, with fractions or an offset) as "YYYY-MM-DDTHH:MM:SSZ".
pub fn norm_iso(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let num = |r: std::ops::Range<usize>| -> Option<i64> { s.get(r)?.parse().ok() };
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let (y, mo, d, h, mi, se) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?);
    let mut rest = &s[19..];
    if let Some(r) = rest.strip_prefix('.') {
        rest = r.trim_start_matches(|c: char| c.is_ascii_digit());
    }
    let off = match rest {
        "Z" | "" => 0,
        r if r.len() == 6 && (r.starts_with('+') || r.starts_with('-')) => {
            let m = r.get(1..3)?.parse::<i64>().ok()? * 60 + r.get(4..6)?.parse::<i64>().ok()?; // get: no panic on non-ASCII
            if r.starts_with('-') { -m } else { m }
        }
        _ => return None,
    };
    // days from civil (the inverse of iso())
    let (y2, m2) = if mo <= 2 { (y - 1, mo + 9) } else { (y, mo - 3) };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * m2 + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(iso(days * 86_400 + h * 3600 + mi * 60 + se - off * 60))
}

/// An uppercase v4 UUID, as Swift's UUID().uuidString.
pub fn uuid() -> String {
    let mut b: [u8; 16] = rand::random();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02X}")).collect();
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

/// A bundle-relative path from the manifest or a push: plain components only.
pub fn safe_rel(p: &str) -> Option<&Path> {
    let path = Path::new(p);
    (!p.is_empty() && p.len() < 512 && path.components().all(|c| matches!(c, Component::Normal(_)))).then_some(path)
}

fn id_ok(s: &str) -> bool {
    (1..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

pub fn clean(s: &str, max: usize) -> String {
    s.chars().filter(|c| !c.is_control()).collect::<String>().trim().chars().take(max).collect()
}

const MAX_LOGO: u64 = 200 * 1024;

fn hex_colour(v: &Value) -> Option<&str> {
    v.as_str().filter(|c| c.len() == 7 && c.starts_with('#') && c[1..].bytes().all(|b| b.is_ascii_hexdigit()))
}

/// The manifest's `branding` as browsers get it: logos read from the bundle and inlined as base64 PNG
/// (≤ 200 KB each), colours as #RRGGBB. Anything invalid is left out; None when nothing usable is left.
fn branding(b: &Value, dir: &Path) -> Option<Value> {
    let logo = |k: &str| -> Option<String> {
        let path = dir.join(safe_rel(b[k].as_str()?)?);
        if std::fs::metadata(&path).ok()?.len() > MAX_LOGO {
            return None;
        }
        let bytes = std::fs::read(path).ok()?;
        bytes.starts_with(b"\x89PNG\r\n\x1a\n").then(|| base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes))
    };
    let mut o = serde_json::Map::new();
    if let Some(n) = b["name"].as_str() {
        o.insert("name".into(), json!(clean(n, 60)));
    }
    for k in ["logo", "logoLight"] {
        if let Some(l) = logo(k) {
            o.insert(k.into(), json!(l));
        }
    }
    for k in ["accent", "bg", "text"] {
        if let Some(c) = hex_colour(&b[k]) {
            o.insert(k.into(), json!(c));
        }
    }
    (o.len() > usize::from(o.contains_key("name"))).then(|| Value::Object(o))
}

/// A servable link record: level 3 (§13.24: `"level":3`, authKey and join hash) or level 2 (the room's signing seed
/// and the join hash). Level 1 links are not served.
fn servable(l: &Value) -> bool {
    let join = l["join"].as_str().is_some_and(|j| j.len() == 43);
    join && if level3(l) { l["auth"].as_str().and_then(keys::unb64).is_some_and(|a| a.len() == 32) }
        else { l["sign"].as_str().and_then(keys::unb64).is_some_and(|s| s.len() == 32) }
}

fn level3(l: &Value) -> bool {
    l["level"] == 3
}

fn is(v: &Value, k: &str) -> bool {
    v[k].as_bool().unwrap_or(false)
}

fn team(l: &Value) -> bool {
    l["audience"] == "team"
}

/// A JPEG from the bundle (≤ 400 KB, checked by magic bytes) as a data URL.
fn jpeg_data_url(dir: &Path, rel: &Value) -> Option<String> {
    let path = dir.join(safe_rel(rel.as_str()?)?);
    if std::fs::metadata(&path).ok()?.len() > MAX_HEADER {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    bytes.starts_with(&[0xFF, 0xD8, 0xFF]).then(|| format!("data:image/jpeg;base64,{}", base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes)))
}

/// Keep at most `max` times within `per`; false (and nothing recorded) when that's used up.
fn rate(q: &mut VecDeque<Instant>, per: Duration, max: usize) -> bool {
    let since = Instant::now().checked_sub(per);
    q.retain(|t| since.is_none_or(|s| *t > s));
    if q.len() >= max {
        return false;
    }
    q.push_back(Instant::now());
    true
}

/// Upload types: the category of a file name's extension, its MIME type for attachments.
pub fn upload_kind(ext: &str) -> Option<(&'static str, &'static str)> {
    use crate::roots::DOCUMENT;
    const OTHER: &[&str] = &["zip", "txt", "srt", "vtt", "csv", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "psd", "ai", "eps"];
    let cat = [("video", crate::roots::VIDEO), ("audio", crate::roots::AUDIO), ("image", crate::roots::IMAGE), ("document", DOCUMENT), ("other", OTHER)]
        .into_iter().find(|(_, l)| l.contains(&ext)).map(|(k, _)| k)?;
    let mime = match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "pdf" => "application/pdf",
        "txt" | "srt" => "text/plain",
        "vtt" => "text/vtt",
        _ => "application/octet-stream",
    };
    Some((cat, mime))
}

/// A log whose last line was cut short (power loss, disk full) ends at its last whole line again, so the next
/// append starts on a line of its own.
fn repair_tail(path: &Path) {
    let Ok(bytes) = std::fs::read(path) else { return };
    if bytes.last().is_some_and(|b| *b != b'\n') {
        let keep = bytes.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
        if let Ok(f) = std::fs::OpenOptions::new().write(true).open(path) {
            let _ = f.set_len(keep as u64);
            log(format!("host: comments.jsonl ended in a partial line ({} bytes); cut", bytes.len() - keep));
        }
    }
}

/// A file name a browser sent, for display only (stored files are named by id): no folders, no
/// control characters, no leading dots, ≤ 120 characters.
fn display_name(n: &str) -> String {
    let base = n.rsplit(['/', '\\']).next().unwrap_or("");
    clean(base, 120).trim_start_matches('.').to_owned()
}

impl Host {
    pub fn new(data: &Path, roots: Arc<Roots>, out: mpsc::UnboundedSender<Ev>, job_tx: Option<mpsc::UnboundedSender<copies::Job>>) -> Host {
        let mut h = Host {
            dir: data.join("bundle"), log_path: data.join("comments.jsonl"), manifest: json!({}),
            comments: vec![], status: HashMap::new(), entries: vec![], seq: 0,
            peers: HashMap::new(), fails: HashMap::new(), out,
            raw: json!({}), roots, jobs: HashMap::new(), job_tx, data: data.to_path_buf(),
            fields: HashMap::new(), activity: HashMap::new(), attachments: HashMap::new(), uploads: HashMap::new(), up_hour: HashMap::new(),
            approvals: vec![], comment_tombs: HashMap::new(), act_ids: Default::default(), deadlines: HashMap::new(), proof_hashes: HashMap::new(),
            ident: Ident { id: "host".into(), name: "Pluck host".into(), backup: false }, busy: Default::default(), replica: None, outage: None, back: None, added: vec![], superseded: 0,
            accounts: crate::accounts::Accounts::load(data), acct_begins: VecDeque::new(), upload_root: None, root_ups: HashMap::new(), placing: HashMap::new(), devices: None,
            mail: crate::mail::Mail::load(data),
            drops: HashMap::new(),
        };
        let _ = std::fs::create_dir_all(&h.dir);
        h.sweep_tmp(Duration::ZERO); // nothing is in flight yet: stills, proofs and link-upload partials of the last run go
        for e in std::fs::read_dir(data.join("uploads/.partial")).into_iter().flatten().flatten() {
            let _ = std::fs::remove_file(e.path());
        }
        repair_tail(&h.log_path);
        for line in std::fs::read_to_string(&h.log_path).unwrap_or_default().lines() {
            if let Ok(e) = serde_json::from_str::<Value>(line) {
                h.seq = h.seq.max(e["seq"].as_u64().unwrap_or(0));
                h.apply(&e);
                h.entries.push(e);
            }
        }
        h.compact();
        h.reload();
        h
    }

    /// Temp stills and proofs older than `age` that no fetch in flight holds (a late ffmpeg task for a
    /// peer that left, a reused fetch id): removed at start and every 30 s with 10 minutes (#13).
    fn sweep_tmp(&self, age: Duration) {
        let held: std::collections::HashSet<&PathBuf> = self.peers.values().flat_map(|p| p.fetches.values()).filter_map(|f| f.temp.as_ref()).collect();
        for e in std::fs::read_dir(self.data.join("tmp")).into_iter().flatten().flatten() {
            let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_none_or(|d| d >= age);
            if old && !held.contains(&e.path()) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }

    fn cmd(&self, v: Value) {
        let _ = self.out.send(Ev::Cmd(v));
    }

    fn send(&self, peer: &str, msg: Value) {
        self.cmd(json!({"send": {"peer": peer, "msg": msg}}));
    }

    fn err(&self, peer: &str, id: &Value, code: &str) {
        self.send(peer, json!({"re": id, "error": {"code": code}}));
    }

    /// Close after the last message has had time to go out.
    fn close_later(&self, peer: &str) {
        let (out, peer) = (self.out.clone(), peer.to_owned());
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let _ = out.send(Ev::Cmd(json!({"close": {"peer": peer, "reason": "host"}})));
        });
    }

    /// Re-read the manifest; register the live links' rooms; end sessions whose link is gone.
    pub fn reload(&mut self) {
        match std::fs::read(self.dir.join("manifest.json")).map(|b| serde_json::from_slice::<Value>(&b)) {
            Ok(Ok(m)) if m["format"] == 1 => self.raw = m,
            Ok(_) => log("host: manifest.json isn't a format 1 bundle".into()),
            Err(_) => log("host: no manifest.json yet".into()),
        }
        self.effective();
        for l in self.links().filter(|l| !servable(l)) {
            log(format!("host: link {} is from an older Pluck (no signing key): not served; publish it again", l["id"]));
        }
        self.queue_copies();
        self.load_serving();
        self.check_links();
    }

    /// "<rootID>/<path>" of an original on this host, if it resolves inside that root.
    fn resolve_media(&self, media: &str) -> Option<PathBuf> {
        self.roots.resolve(media, false)
    }

    fn versions_mut(m: &mut Value) -> impl Iterator<Item = (&mut Value, String)> {
        m["projects"].as_array_mut().into_iter().flatten()
            .flat_map(|p| p["assets"].as_array_mut().into_iter().flatten())
            .flat_map(|a| {
                let kind = a["kind"].as_str().unwrap_or("").to_owned();
                a["versions"].as_array_mut().into_iter().flatten().map(move |v| (v, kind.clone()))
            })
    }

    /// The manifest browsers see: versions published by reference get their probe and renditions
    /// from the copies this host made (ready.json), or `ready: false` until then.
    fn effective(&mut self) {
        let mut m = self.raw.clone();
        let dir = self.dir.clone();
        for (v, _) in Self::versions_mut(&mut m) {
            let Some(vid) = v["id"].as_str().filter(|s| id_ok(s)).map(str::to_owned) else { continue };
            if v.get("source").is_none() && !self.ident.backup {
                v["ready"] = json!(true);
                continue;
            }
            let r: Option<Value> = std::fs::read(dir.join("copies").join(&vid).join("ready.json")).ok().and_then(|b| serde_json::from_slice(&b).ok());
            match r {
                Some(r) => {
                    for (k, x) in r["probe"].as_object().into_iter().flatten() {
                        v[k] = x.clone();
                    }
                    v["renditions"] = r["renditions"].clone();
                    if r["sha256"].is_string() {
                        v["sha256"] = r["sha256"].clone();
                    }
                    v["ready"] = json!(true);
                }
                None => {
                    v["renditions"] = json!([]);
                    v["ready"] = json!(false);
                }
            }
        }
        // A link's header image (its own, else the branding's) goes to browsers as a data URL.
        let brand_header = m["branding"]["header"].clone();
        for l in m["links"].as_array_mut().into_iter().flatten() {
            let rel = if l["header"].is_string() { l["header"].clone() } else { brand_header.clone() };
            match jpeg_data_url(&dir, &rel) {
                Some(u) => l["header"] = json!(u),
                None => { l.as_object_mut().map(|o| o.remove("header")); }
            }
        }
        match branding(&m["branding"], &dir) {
            Some(b) => m["branding"] = b,
            None => { m.as_object_mut().map(|o| o.remove("branding")); }
        }
        self.manifest = m;
    }

    /// Queue review copies for referenced versions that have none (also after a restart).
    fn queue_copies(&mut self) {
        let Some(tx) = self.job_tx.clone() else { return };
        if self.busy.preparing() {
            return; // an update waits: no new copy jobs (§13.15)
        }
        let want: Vec<(String, String, String, bool)> = self.manifest["projects"].as_array().into_iter().flatten()
            .flat_map(|p| Self::arr(p, "assets").map(move |a| (p["uhd"] == true, a)))
            .flat_map(|(uhd, a)| Self::arr(a, "versions").map(move |v| (uhd, a, v)))
            .filter(|(_, _, v)| v["ready"] == false)
            .filter_map(|(uhd, a, v)| Some((v["id"].as_str()?.to_owned(), a["kind"].as_str()?.to_owned(), v["source"].as_str()?.to_owned(), uhd)))
            .collect();
        for (vid, kind, source, uhd) in want {
            if self.jobs.contains_key(&vid) {
                continue; // queued, making, or failed (a new publish retries)
            }
            let Some(src) = self.resolve_media(&source) else {
                self.jobs.insert(vid, json!({"state": "failed", "progress": 0.0, "error": "original not found on this host"}));
                continue;
            };
            // A subtitle file next to the original ("Hero.vtt" / "Hero.srt") becomes the captions.
            let stem = source.rsplit_once('.').map_or(source.as_str(), |(s, _)| s);
            let captions = ["vtt", "srt"].iter().find_map(|e| self.resolve_media(&format!("{stem}.{e}")));
            self.jobs.insert(vid.clone(), json!({"state": "queued", "progress": 0.0}));
            let _ = tx.send(copies::Job { out: self.dir.join("copies").join(&vid), version: vid, kind, src, captions, watermark: None, uhd });
        }
        // Links that burn their watermark in get their own copies of the versions they show, once
        // the plain copy is ready. Only for versions this host makes (Pluck pushes the others).
        let today = now_iso()[..10].to_owned();
        let mut wm = vec![];
        for l in self.links().filter(|l| Self::burned(l) && self.live(l).is_ok()) {
            let Some(lid) = l["id"].as_str().filter(|s| id_ok(s)) else { continue };
            let Some(p) = self.project(l) else { continue };
            for a in Self::arr(p, "assets").filter(|a| a["id"].as_str().is_some_and(|id| self.asset_in_scope(l, id).is_some())) {
                for v in Self::versions(l, a).into_iter().filter(|v| v["ready"] == true) {
                    let (Some(vid), Some(src), Some(kind)) = (v["id"].as_str().filter(|s| id_ok(s)), v["source"].as_str(), a["kind"].as_str()) else { continue };
                    let key = format!("{vid}/wm-{lid}");
                    let out = self.dir.join("copies").join(vid).join(format!("wm-{lid}"));
                    if kind == "document" || self.jobs.contains_key(&key) || out.join("ready.json").is_file() {
                        continue;
                    }
                    let text = copies::burned_text(l["watermark"]["text"].as_str().unwrap_or("{name} · {date}"), l["title"].as_str().unwrap_or(""),
                        l["recipient"].as_str(), &today);
                    wm.push((key, kind.to_owned(), src.to_owned(), out, text, l["watermark"].clone()));
                }
            }
        }
        for (key, kind, src, out, text, settings) in wm {
            let Some(src) = self.resolve_media(&src) else { continue };
            self.jobs.insert(key.clone(), json!({"state": "queued", "progress": 0.0}));
            let _ = tx.send(copies::Job { out, version: key, kind, src, captions: None, watermark: Some((text, settings)), uhd: false });
        }
    }

    /// Publish (by reference). `manifest.projects` and `.links` are upserted by id, and
    /// `remove.projects`/`.links` taken out, so the editor's Pluck and the admin page don't
    /// overwrite each other. Versions whose `source` is on this host get copies made here; the
    /// others come back as `missing` (Pluck pushes their copies, and they go without `source`).
    fn publish(&mut self, m: &Value, remove: &Value) -> Value {
        if m["format"] != 1 {
            return json!({"error": "not a format 1 manifest"});
        }
        let mut m = m.clone();
        let mut missing = vec![];
        for (v, _) in Self::versions_mut(&mut m) {
            let Some(src) = v["source"].as_str() else { continue };
            if self.resolve_media(src).is_none() {
                missing.push(v["id"].clone());
                v.as_object_mut().map(|o| o.remove("source"));
            }
        }
        let mut raw = if self.raw["format"] == 1 { self.raw.clone() } else { json!({"format": 1, "projects": [], "links": []}) };
        for k in ["projects", "links"] {
            if !raw[k].is_array() {
                raw[k] = json!([]);
            }
        }
        // Files added on the admin page to a project Pluck publishes stay: Pluck's project replaces
        // only Pluck's assets (it never knew of the admin's, so it can't send them back).
        for p in m["projects"].as_array_mut().into_iter().flatten() {
            let Some(old) = Self::arr(&raw, "projects").find(|x| x["id"] == p["id"]) else { continue };
            let theirs: Vec<Value> = Self::arr(old, "assets")
                .filter(|a| a["by"] == "admin" && !Self::arr(p, "assets").any(|n| n["id"] == a["id"])).cloned().collect();
            if let Some(list) = p["assets"].as_array_mut() {
                list.extend(theirs);
            }
        }
        if let Some(d) = m.get("activityDays").filter(|d| d.is_i64()) { raw["activityDays"] = d.clone(); } // Pluck's retention (R8)
        if let Some(d) = m.get("archiveForgetDays").filter(|d| d.is_i64()) { raw["archiveForgetDays"] = d.clone(); } // wf-deliver
        // Branding is the whole object or nothing: a publish that carries it replaces it, null removes it.
        match m.get("branding") {
            Some(Value::Null) => { raw.as_object_mut().map(|o| o.remove("branding")); }
            Some(b) => raw["branding"] = b.clone(),
            None => {}
        }
        for k in ["projects", "links"] {
            let gone: Vec<&Value> = Self::arr(remove, k).collect();
            let new: Vec<Value> = Self::arr(&m, k).cloned().collect();
            let list = raw[k].as_array().cloned().unwrap_or_default().into_iter()
                .filter(|x| !gone.contains(&&x["id"]) && !new.iter().any(|n| n["id"] == x["id"]))
                .chain(new.iter().cloned()).collect::<Vec<_>>();
            raw[k] = json!(list);
        }
        self.jobs.retain(|_, j| j["state"] != "failed");
        let by = self.ident.by();
        match self.save(&raw, &by) {
            Ok(()) => json!({"ok": true, "missing": missing, "storeSeq": self.raw["storeSeq"]}),
            Err(e) => json!({"error": e}),
        }
    }

    /// `publish` with `merge:true` (§13.1), or a backup applying the main's changes (`own` false:
    /// no copies are made from originals here, and sources are kept as the main's).
    fn merge_publish(&mut self, m: &Value, tombstones: &Value, own: bool) -> Value {
        let mut m = m.clone();
        let mut missing = vec![];
        if own && !self.ident.backup {
            for (v, _) in Self::versions_mut(&mut m) {
                let Some(src) = v["source"].as_str() else { continue };
                if self.resolve_media(src).is_none() {
                    missing.push(v["id"].clone());
                    v.as_object_mut().map(|o| o.remove("source"));
                }
            }
        }
        let base = if self.raw["format"] == 1 { self.raw.clone() } else { json!({"format": 1, "projects": [], "links": []}) };
        let (mut raw, stale) = crate::store::merge_publish(&base, &m, tombstones, own);
        if !stale.is_empty() {
            log(format!("publish: {} lost to newer copies here: {}", stale.len(), json!(stale)));
        }
        if let Some(b) = m.get("branding") {
            if b.is_null() { raw.as_object_mut().map(|o| o.remove("branding")); } else { raw["branding"] = b.clone(); }
        }
        if let Some(d) = m.get("activityDays").filter(|d| d.is_i64()) { raw["activityDays"] = d.clone(); }
        if let Some(d) = m.get("archiveForgetDays").filter(|d| d.is_i64()) { raw["archiveForgetDays"] = d.clone(); }
        self.jobs.retain(|_, j| j["state"] != "failed");
        let by = self.ident.by();
        match self.save(&raw, &by) {
            Ok(()) => json!({"ok": true, "missing": missing, "stale": stale, "storeSeq": self.raw["storeSeq"]}),
            Err(e) => json!({"error": e}),
        }
    }

    /// Write the manifest: changed objects get the next storeSeq (and rev+1 by `by` when the
    /// writer didn't raise it), removed ones a tombstone (§13.1).
    fn save(&mut self, raw: &Value, by: &str) -> Result<(), String> {
        let mut raw = raw.clone();
        let now = now_secs();
        let old = if self.raw["format"] == 1 { self.raw.clone() } else { json!({}) };
        crate::store::stamp(&old, &mut raw, by, &iso(now), &iso(now - crate::store::TOMBSTONE_DAYS * 86_400));
        let tmp = self.dir.join("manifest.json.part");
        std::fs::write(&tmp, raw.to_string()).and_then(|_| std::fs::rename(&tmp, self.dir.join("manifest.json")))
            .map_err(|e| format!("can't write the manifest: {e}"))?;
        // New versions of assets that were already there: "version-added" once their copy is ready (§13.4).
        let versions = |m: &Value| -> Vec<(String, String)> {
            Self::arr(m, "projects").flat_map(|p| Self::arr(p, "assets")).flat_map(|a| Self::arr(a, "versions")
                .filter_map(move |v| Some((a["id"].as_str()?.to_owned(), v["id"].as_str()?.to_owned())))).collect()
        };
        let before = versions(&old);
        for (a, v) in versions(&raw) {
            if before.iter().any(|(x, _)| *x == a) && !before.iter().any(|(_, y)| *y == v) {
                self.added.push((a, v));
            }
        }
        self.reload();
        self.tell_added();
        Ok(())
    }

    /// `version-added` to every ready viewer whose link holds the asset, once the version is
    /// ready here. Not for latestOnly links: they switch on their next `asset` fetch.
    fn tell_added(&mut self) {
        let ready = |h: &Host, v: &str| h.manifest["projects"].as_array().into_iter().flatten().flat_map(|p| Self::arr(p, "assets"))
            .flat_map(|a| Self::arr(a, "versions")).any(|x| x["id"] == v && x["ready"] == true);
        let (now, later): (Vec<_>, Vec<_>) = std::mem::take(&mut self.added).into_iter().partition(|(_, v)| ready(self, v));
        self.added = later;
        for (aid, vid) in &now {
            self.mail_version(aid, vid);
        }
        for (aid, vid) in now {
            for (id, p) in &self.peers {
                let Some(l) = self.peer_link(p).filter(|l| p.ready && !is(l, "latestOnly")) else { continue };
                let Some((_, a)) = self.asset_in_scope(&l, &aid) else { continue };
                let Some(v) = Self::arr(a, "versions").find(|v| v["id"] == vid.as_str()) else { continue };
                self.send(id, json!({"t": "asset-changed", "asset": aid}));
                self.send(id, json!({"t": "version-added", "asset": aid, "version": vid, "number": v["number"], "name": a["name"]}));
            }
        }
    }

    /// What a backup should hold (§13.3): the current version of every asset in a live link,
    /// newest `added` first, with the main's details and the burned-watermark links that show it.
    fn replica_plan(&self) -> Vec<Value> {
        let mut out: Vec<Value> = vec![];
        for l in self.links().filter(|l| self.live(l).is_ok()) {
            let Some(p) = self.project(l) else { continue };
            for a in Self::arr(p, "assets").filter(|a| a["id"].as_str().is_some_and(|id| self.asset_in_scope(l, id).is_some())) {
                // Every version in scope (a viewer may recall an older one); only the current one fills (`current`).
                let last = v_id(Self::arr(a, "versions").last()).cloned();
                for id in Self::arr(a, "versions").filter_map(|v| v_id(Some(v))) {
                    let Some(v) = self.raw_version(Some(id)) else { continue };
                    let lid = Self::burned(l).then(|| l["id"].clone());
                    match out.iter_mut().find(|x| x["id"] == v["id"]) {
                        Some(x) => if let Some(lid) = lid { x["wm"].as_array_mut().unwrap().push(lid) },
                        None => {
                            let mut e = json!({"id": v["id"], "kind": a["kind"], "added": v["added"], "version": v, "wm": [], "current": Some(id) == last.as_ref()});
                            if let Some(lid) = lid { e["wm"] = json!([lid]) }
                            out.push(e);
                        }
                    }
                }
            }
        }
        out.sort_by(|a, b| b["added"].as_str().cmp(&a["added"].as_str()));
        out
    }

    /// A version as the main published it (the raw manifest: renditions, probe, sha256).
    fn raw_version(&self, id: Option<&Value>) -> Option<Value> {
        let id = id?;
        self.raw["projects"].as_array()?.iter().flat_map(|p| Self::arr(p, "assets")).flat_map(|a| Self::arr(a, "versions")).find(|v| v["id"] == *id).cloned()
    }

    fn prepare_update(&mut self) -> Value {
        let copies = self.jobs.values().filter(|j| j["state"] == "queued" || j["state"] == "making").count()
            + self.replica.as_ref().map_or(0, |r| r.making());
        crate::update::prepare(&self.busy, self.uploads.len(), copies)
    }

    // ---- the LAN admin page (admin.rs checks the session; these are its operations) ----

    /// What the admin page shows: projects with copy states and comment counts, links without secrets.
    fn admin_state(&self) -> Value {
        let mut m = self.manifest.clone();
        for p in m["projects"].as_array_mut().into_iter().flatten() {
            for a in p["assets"].as_array_mut().into_iter().flatten() {
                a["status"] = self.status_of(a);
                a["comments"] = json!(self.comments.iter().filter(|c| c["asset"] == a["id"]).count());
                for v in a["versions"].as_array_mut().into_iter().flatten() {
                    v["copy"] = v["id"].as_str().and_then(|id| self.jobs.get(id)).cloned().unwrap_or(json!({"state": if v["ready"] == true { "ready" } else { "queued" }}));
                }
            }
        }
        let links: Vec<Value> = self.links().map(|l| json!({"id": l["id"], "title": l["title"], "project": l["project"], "root": l["root"],
            "mode": l["mode"], "expires": l["expires"], "revoked": l["revoked"], "password": l["passwordHash"].is_string(),
            "allowDownload": l["allowDownload"], "viewers": self.peers.values().filter(|p| p.ready && p.room == l["roomID"]).count(),
            "activity": l["id"].as_str().and_then(|id| self.activity.get(id)).copied().unwrap_or(0),
            "paused": is(l, "paused"), "audience": l["audience"], "recipient": l["recipient"],
            // §13.24: `ready` once one of the owner's servers holds the room (the page shows a new link only then);
            // `taken` when someone else does (the page offers "Make a New Link").
            "ready": l["roomID"].as_str().and_then(crate::signal::room_state).is_some_and(|s| s.1),
            "taken": l["roomID"].as_str().and_then(crate::signal::room_state).is_some_and(|s| s.0 == "taken")})).collect();
        json!({"projects": m["projects"], "links": links, "roots": self.roots.0.iter().map(|(id, _)| id).collect::<Vec<_>>()})
    }

    /// Add files (media paths) to a project (by id, or a new one by name) and optionally make a
    /// link to it. The link address is shown once: the host keeps only the room's reg/auth keys.
    fn admin_publish(&mut self, op: &Value) -> Value {
        let mut raw = if self.raw["format"] == 1 { self.raw.clone() } else { json!({"format": 1, "projects": [], "links": []}) };
        let pid = match (op["project"].as_str(), op["newProject"].as_str().map(|n| clean(n, 80)).filter(|n| !n.is_empty())) {
            (_, Some(name)) => {
                let id = uuid();
                raw["projects"].as_array_mut().unwrap().push(json!({"id": id, "name": name, "folders": [], "assets": []}));
                id
            }
            (Some(id), None) if Self::arr(&raw, "projects").any(|p| p["id"] == id) => id.to_owned(),
            _ => return json!({"error": "choose a project"}),
        };
        let mut added = 0;
        let mut skipped = vec![];
        {
            let p = raw["projects"].as_array_mut().unwrap().iter_mut().find(|p| p["id"] == pid.as_str()).unwrap();
            if !p["assets"].is_array() {
                p["assets"] = json!([]); // stored as a plain publish sent it
            }
            for f in op["files"].as_array().into_iter().flatten().filter_map(Value::as_str).take(500) {
                let (Some(real), Some(kind)) = (self.roots.resolve(f, false), kind_of(f)) else { skipped.push(f.to_owned()); continue };
                if Self::arr(p, "assets").any(|a| Self::arr(a, "versions").any(|v| v["source"] == f)) {
                    continue;
                }
                let name = Path::new(f).file_stem().map_or(f.into(), |s| s.to_string_lossy().to_string());
                let size = std::fs::metadata(&real).map_or(0, |m| m.len());
                let v = json!({"id": uuid(), "number": 1, "added": now_iso(), "source": f, "size": size,
                    "originalName": Path::new(f).file_name().map(|n| n.to_string_lossy().to_string())});
                p["assets"].as_array_mut().unwrap().push(json!({"id": uuid(), "name": clean(&name, 80), "folder": null, "kind": kind,
                    "status": "needsReview", "versions": [v], "created": now_iso(), "by": "admin"}));
                added += 1;
            }
        }
        let (mut url, mut link_id) = (Value::Null, Value::Null);
        if let Some(l) = op.get("link").filter(|l| l.is_object()) {
            let nl = keys::new_link();
            let pname = Self::arr(&raw, "projects").find(|p| p["id"] == pid.as_str()).map(|p| p["name"].clone()).unwrap_or_default();
            let days = l["expiresDays"].as_i64().filter(|d| *d > 0);
            let expires = days.map(|d| iso(now_secs() + d * 86_400));
            let pw = l["password"].as_str().filter(|p| !p.is_empty()).map(keys::hash_password);
            let title = clean(l["title"].as_str().unwrap_or(""), 80);
            let mut new = json!({"id": uuid(), "roomID": nl.room, "reg": nl.reg, "auth": nl.auth, "level": 3, "join": nl.join,
                "title": if title.is_empty() { pname.clone() } else { json!(title) },
                "mode": if l["mode"] == "presentation" { "presentation" } else { "review" },
                "allowDownload": is(l, "allowDownload"), "latestOnly": is(l, "latestOnly"), "expires": expires, "revoked": null,
                "passwordHash": pw, "project": pid, "root": {"kind": "project", "id": pid, "name": pname}, "created": now_iso(),
                "requireName": is(l, "requireName"), "allowProxy": is(l, "allowProxy")});
            if let Some(w) = l["watermark"].as_str().map(|w| clean(w, 120)).filter(|w| !w.is_empty()) {
                new["watermark"] = json!({"text": w, "position": "center", "opacity": 0.25, "size": 0.03, "burned": false});
            }
            link_id = new["id"].clone();
            raw["links"].as_array_mut().unwrap().push(new);
            url = json!(format!("https://pluck.tools/r/#{}", nl.fragment)); // level 3: the room id isn't in the link
        }
        self.jobs.retain(|_, j| j["state"] != "failed"); // as `publish`: a new publish tries failed copies again
        match self.save(&raw, "admin") {
            // The page keeps `url` hidden until admin-state says this link is `ready` (§13.24 H1).
            Ok(()) => json!({"ok": true, "project": pid, "added": added, "skipped": skipped, "url": url, "link": link_id}),
            Err(e) => json!({"error": e}),
        }
    }

    /// Turn a link off, or take an asset out of a project (its review copies go; originals never).
    fn admin_unpublish(&mut self, op: &Value) -> Value {
        let mut raw = self.raw.clone();
        if let Some(l) = op["link"].as_str() {
            let Some(link) = raw["links"].as_array_mut().into_iter().flatten().find(|x| x["id"] == l) else { return json!({"error": "no such link"}) };
            link["revoked"] = json!(now_iso());
        } else if let Some(a) = op["asset"].as_str() {
            let mut gone = vec![];
            for p in raw["projects"].as_array_mut().into_iter().flatten() {
                if let Some(list) = p["assets"].as_array_mut() {
                    for x in list.iter().filter(|x| x["id"] == a) {
                        gone.extend(Self::arr(x, "versions").filter_map(|v| v["id"].as_str().filter(|s| id_ok(s)).map(str::to_owned)));
                    }
                    list.retain(|x| x["id"] != a);
                }
            }
            for v in gone {
                let _ = std::fs::remove_dir_all(self.dir.join("copies").join(v));
            }
        } else {
            return json!({"error": "nothing to unpublish"});
        }
        match self.save(&raw, "admin") {
            Ok(()) => json!({"ok": true}),
            Err(e) => json!({"error": e}),
        }
    }

    /// "Make a New Link" for a link whose room someone else holds (§13.24 H1): a new code, R and room for the same link
    /// record. The new address is shown once, as from admin-publish; the old one stops working.
    fn admin_renew(&mut self, op: &Value) -> Value {
        let mut raw = self.raw.clone();
        let Some(link) = raw["links"].as_array_mut().into_iter().flatten().find(|x| x["id"] == op["link"] && x["revoked"].is_null()) else {
            return json!({"error": "no such link"});
        };
        let nl = keys::new_link();
        for (k, v) in [("roomID", nl.room), ("reg", nl.reg), ("auth", nl.auth), ("join", nl.join)] {
            link[k] = json!(v);
        }
        link["level"] = json!(3);
        link.as_object_mut().unwrap().remove("sign");
        let id = link["id"].clone();
        match self.save(&raw, "admin") {
            Ok(()) => json!({"ok": true, "link": id, "url": format!("https://pluck.tools/r/#{}", nl.fragment)}),
            Err(e) => json!({"error": e}),
        }
    }

    fn admin_comments(&self, op: &Value) -> Value {
        let list: Vec<Value> = self.comments.iter().filter(|c| c["asset"] == op["asset"]).map(|c| Self::wire_comment(c, [None, None], true)).collect();
        json!({"comments": list})
    }

    /// A copy job moved on: report it, and when it's ready tell clients to re-fetch the asset.
    pub fn copy_progress(&mut self, version: String, state: Value) {
        if let Some(k) = version.strip_prefix("acct:") {
            return self.acct_back(k, state); // a team upload's hash or a footage thumbnail, done in the background
        }
        if let Some(fid) = version.strip_prefix("place:") {
            let Some((peer, id, entry, u)) = self.placing.remove(fid) else { return };
            return self.record_upload(&peer, &id, Self::with_placed(entry, state.as_str().map(str::to_owned)), u);
        }
        if let Some(k) = version.strip_prefix("mail:") {
            return self.mail_back(k, state);
        }
        if let Some(ap) = version.strip_prefix("proof:") {
            self.proof_hashes.insert(ap.to_owned(), state);
            return;
        }
        report(json!({"copy": {"version": version, "state": state["state"], "progress": state["progress"], "error": state["error"]}}));
        let ready = state["state"] == "ready";
        if ready {
            self.jobs.remove(&version);
            self.effective();
            self.tell_added();
            self.queue_copies(); // burned-watermark copies follow the plain one
            let vid = version.split('/').next().unwrap_or("");
            let asset = self.manifest["projects"].as_array().into_iter().flatten().flat_map(|p| Self::arr(p, "assets"))
                .find(|a| Self::arr(a, "versions").any(|v| v["id"] == vid)).map(|a| a["id"].clone());
            let Some(a) = asset.as_ref().and_then(Value::as_str) else { return };
            for (id, p) in &self.peers {
                if p.ready && self.peer_link(p).is_some_and(|l| self.asset_in_scope(&l, a).is_some()) {
                    self.send(id, json!({"t": "asset-changed", "asset": a}));
                }
            }
        } else {
            self.jobs.insert(version, state);
        }
    }

    /// Also run every 30 s, so links expire on time.
    pub fn check_links(&mut self) {
        self.forget_archived();
        let mut rooms: Vec<Value> = self.links().filter(|l| servable(l) && matches!(self.live(l), Ok(()) | Err("paused") | Err("deadline") | Err("archived")))
            .map(|l| json!({"room": l["roomID"], "reg": l["reg"], "join": l["join"], "expires": l["expires"], "turn": self.live(l).is_ok(), "ready": self.backup_ready(l)})).collect();
        rooms.extend(self.team_room_reg());
        let ended: Vec<(String, &str)> = self.peers.iter()
            .filter_map(|(id, p)| match self.link(&p.room) {
                Some(l) => self.live(l).err().or_else(|| Self::repassworded(p, l)).or_else(|| self.acct_gone(p)),
                None if self.is_team(&p.room) => self.acct_gone(p),
                None => Some("revoked"),
            }.map(|c| (id.clone(), c)))
            .collect();
        // A deadline the owner changed while peers are connected (§13.9).
        let now: HashMap<String, Option<String>> = self.links().filter_map(|l| Some((l["id"].as_str()?.to_owned(), self.deadline(l)))).collect();
        for (id, p) in &self.peers {
            let Some(l) = self.link(&p.room) else { continue };
            let (Some(lid), true) = (l["id"].as_str(), p.ready) else { continue };
            if self.deadlines.get(lid).is_some_and(|old| *old != now[lid]) {
                self.send(id, json!({"t": "deadline", "deadline": now[lid]}));
            }
        }
        self.deadlines = now;
        let rooms = json!({"rooms": rooms});
        if ended.is_empty() {
            return self.cmd(rooms);
        }
        for (id, code) in ended {
            let bye = self.peers.get(&id).and_then(|p| self.link(&p.room)).map_or_else(|| json!({"t": "bye", "code": code}), |l| self.bye(l, code));
            self.send(&id, bye);
            self.close_later(&id);
            self.drop_peer(&id);
        }
        // Dropping a room closes its peers at once, so let the byes go out first.
        let out = self.out.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(1500)).await;
            let _ = out.send(Ev::Cmd(rooms));
        });
    }

    /// Fastest-host routing: may this backup take the link's viewers while the main is online? Only when the
    /// current version of every asset in scope is copied here, and the link needs nothing only the main has:
    /// uploads (off on a backup, §13.3) and original downloads stay with the main.
    fn backup_ready(&self, l: &Value) -> bool {
        if !self.ident.backup || l["uploads"].is_object() || is(l, "allowDownload") {
            return false;
        }
        let Some(p) = self.project(l) else { return false };
        let mut scope = Self::arr(p, "assets").filter(|a| a["id"].as_str().is_some_and(|id| self.asset_in_scope(l, id).is_some())).peekable();
        // (Nothing in scope, a removed asset say: nothing copied to serve, so the main keeps it.)
        scope.peek().is_some() && scope.all(|a| Self::arr(a, "versions").last().is_some_and(|v| v["ready"] == true))
    }

    /// The owner's "Prefer fastest even if lighter" (a main's own setting, kept in serving.json; on by default).
    fn load_serving(&self) {
        let on = std::fs::read(self.data.join("serving.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .is_none_or(|v| v["preferFastest"] != false); // the fastest NAS serves unless the owner turned it off
        crate::signal::FASTEST.store(on, std::sync::atomic::Ordering::Relaxed);
    }

    /// A peer gone (closed, or ended by check_links): its fetches end (temp files go, a backup's
    /// versions become evictable again) and its partial uploads go.
    fn drop_peer(&mut self, id: &str) -> Option<HPeer> {
        let p = self.peers.remove(id)?;
        for f in p.fetches.values() {
            if let (Some(r), Some(v)) = (&self.replica, &f.version) {
                r.fetch_end(v);
            }
            if let Some(t) = &f.temp { let _ = std::fs::remove_file(t); }
        }
        // A finished writer no longer deletes its partial file, so the host does (#14).
        self.uploads.retain(|(peer, _), u| peer != id || { let _ = std::fs::remove_file(&u.part); false });
        // A team upload keeps its partial for the resume (§4.4); only this session's hold on it ends.
        let ru = self.upload_root.clone();
        self.root_ups.retain(|(peer, _), u| peer != id || { if let Some(r) = &ru { r.release(&u.id) } false });
        Some(p)
    }

    /// A link's expiry or deadline falls in the next 31 s (ISO strings compare in time order).
    fn ends_soon(&self) -> bool {
        let secs = now_secs();
        let (now, soon) = (iso(secs - 1), iso(secs + 31));
        self.links().any(|l| [l["expires"].as_str().map(str::to_owned), self.deadline(l)].into_iter().flatten()
            .any(|e| e.as_str() >= now.as_str() && e.as_str() <= soon.as_str()))
    }

    /// A ready session admitted under another password (or none) than the link has now ends.
    fn repassworded(p: &HPeer, l: &Value) -> Option<&'static str> {
        (p.ready && l["passwordHash"] != p.pw).then_some("password")
    }

    fn links(&self) -> impl Iterator<Item = &Value> {
        self.manifest["links"].as_array().into_iter().flatten()
    }

    /// Only level-2 links (with a signing seed and join hash) are served.
    fn link(&self, room: &str) -> Option<&Value> {
        self.links().find(|l| l["roomID"] == room && servable(l))
    }

    fn live(&self, l: &Value) -> Result<(), &'static str> {
        if !l["revoked"].is_null() {
            return Err("revoked");
        }
        if is(l, "paused") {
            return Err("paused");
        }
        // Archived (wf-deliver): the room stays, the page says so until the owner reopens it.
        if l["archived"].is_string() {
            return Err("archived");
        }
        let now = now_iso();
        match l["expires"].as_str() {
            Some(e) if e <= now.as_str() => Err("expired"),
            _ => match self.deadline(l) {
                Some(d) if d.as_str() <= now.as_str() => Err("deadline"),
                _ => Ok(()),
            },
        }
    }

    /// `bye`, with the deadline's time when that's why.
    fn bye(&self, l: &Value, code: &str) -> Value {
        let mut b = json!({"t": "bye", "code": code});
        if code == "deadline" {
            b["at"] = json!(self.deadline(l));
        }
        if code == "archived" {
            b = json!({"t": "bye", "code": "paused", "archived": true}); // wf-deliver: an older page says "paused"
        }
        b
    }

    /// The effective feedback deadline (§13.9): the link's own, else its project's. Normalised to
    /// "YYYY-MM-DDTHH:MM:SSZ" so it compares as a string with now_iso().
    fn deadline(&self, l: &Value) -> Option<String> {
        if l["delivered"].is_string() {
            return None; // delivered: feedback is over, the downloads stay
        }
        let d = l["deadline"].as_str().or_else(|| self.project(l)?["deadline"].as_str())?;
        let d = norm_iso(d).unwrap_or_else(|| d.to_owned());
        // Pluck's "reopened, no deadline" is a far-future date (it must outrank a past project deadline).
        if d.get(..4).and_then(|y| y.parse::<u32>().ok()).is_some_and(|y| y >= 4000) { return None; }
        Some(d)
    }

    fn project(&self, l: &Value) -> Option<&Value> {
        self.manifest["projects"].as_array()?.iter().find(|p| p["id"] == l["project"])
    }

    fn arr<'a>(v: &'a Value, k: &str) -> impl Iterator<Item = &'a Value> {
        v[k].as_array().into_iter().flatten()
    }

    /// Is folder `f` (None = project root) inside `root` (a folder id), walking up the parents?
    fn under<'a>(project: &'a Value, mut f: Option<&'a str>, root: &str) -> bool {
        for _ in 0..32 {
            match f {
                Some(id) if id == root => return true,
                Some(id) => f = Self::arr(project, "folders").find(|x| x["id"] == id).and_then(|x| x["parent"].as_str()),
                None => return false,
            }
        }
        false
    }

    /// A level-3 deep link's `/a/<8>` (§13.24): the one asset in the link's scope whose id starts with it.
    fn short_asset(&self, l: &Value, short: &str) -> Option<String> {
        if !short.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let mut hits = Self::arr(self.project(l)?, "assets").filter_map(|a| a["id"].as_str())
            .filter(|id| id.get(..8).is_some_and(|p| p.eq_ignore_ascii_case(short)) && self.asset_in_scope(l, id).is_some());
        let one = hits.next()?;
        hits.next().is_none().then(|| one.to_owned())
    }

    fn asset_in_scope<'a>(&'a self, l: &Value, asset: &str) -> Option<(&'a Value, &'a Value)> {
        let p = self.project(l)?;
        let a = Self::arr(p, "assets").find(|a| a["id"] == asset)?;
        let ok = match l["root"]["kind"].as_str()? {
            "project" => true,
            "folder" => Self::under(p, a["folder"].as_str(), l["root"]["id"].as_str()?),
            "asset" => l["root"]["id"] == asset,
            "assets" => Self::arr(&l["root"], "assets").any(|x| x == asset), // a hand-picked set (§6.1)
            _ => false,
        };
        ok.then_some((p, a))
    }

    /// Whether the link may hear about a comment on (asset, version): in scope, and not on a version
    /// latestOnly hides (#3). A null version (an asset-level entry) goes by the asset.
    fn sees(&self, l: &Value, asset: &str, version: &Value) -> bool {
        self.asset_in_scope(l, asset).is_some_and(|(_, a)| version.is_null() || Self::versions(l, a).iter().any(|v| v["id"] == *version))
    }

    fn versions<'a>(l: &Value, a: &'a Value) -> Vec<&'a Value> {
        let v: Vec<&Value> = Self::arr(a, "versions").collect();
        if is(l, "latestOnly") { v.last().copied().into_iter().collect() } else { v }
    }

    fn status_of(&self, a: &Value) -> Value {
        a["id"].as_str().and_then(|id| self.status.get(id)).map_or_else(|| a["status"].clone(), |s| json!(s))
    }

    /// `toks`: the browser's per-link token and, signed in, the account's: either one makes it `mine` (§1.7).
    /// `team`: a team link (or the Mac) sees internal replies; anyone else gets the thread without them.
    fn wire_comment(c: &Value, toks: [Option<&str>; 2], team: bool) -> Value {
        let is_mine = |w: Option<&str>| w.is_some() && toks.contains(&w);
        let mine = |x: &Value| json!(is_mine(x["authorToken"].as_str()));
        let mut w = c.clone();
        if let Some(o) = w.as_object_mut() {
            o.insert("mine".into(), mine(c));
            o.remove("authorToken");
            o.remove("link");
            o.remove("deletedReplies"); // sync only
            // Stored {"👍":["<authorToken|owner>",…]} → [{"emoji","count","mine"}], in the fixed order.
            if let Some(r) = o.get("reactions").and_then(Value::as_object) {
                let list: Vec<Value> = EMOJI.iter().filter_map(|e| {
                    let who = r.get(*e)?.as_array().filter(|w| !w.is_empty())?;
                    Some(json!({"emoji": e, "count": who.len(), "mine": who.iter().any(|w| is_mine(w.as_str()))}))
                }).collect();
                o.insert("reactions".into(), json!(list));
            }
            if let Some(rs) = o.get_mut("replies").and_then(Value::as_array_mut) {
                if !team {
                    rs.retain(|r| !is(r, "internal"));
                }
                for r in rs.iter_mut() {
                    let m = mine(r);
                    if let Some(ro) = r.as_object_mut() {
                        ro.insert("mine".into(), m);
                        ro.remove("authorToken");
                    }
                }
            }
        }
        w
    }

    // ---- the comment log ----

    fn apply(&mut self, e: &Value) {
        if let Some(c) = e.get("comment") {
            match self.comments.iter_mut().find(|x| x["id"] == c["id"]) {
                Some(x) => *x = c.clone(),
                None => self.comments.push(c.clone()),
            }
        } else if let Some(d) = e.get("deleted") {
            let rev = d["rev"].as_u64().unwrap_or(u64::MAX); // an old tombstone without rev beats everything
            self.comments.retain(|x| x["id"] != d["id"] || x["rev"].as_u64().unwrap_or(0) > rev);
            if let Some(id) = d["id"].as_str() {
                self.comment_tombs.insert(id.to_owned(), rev);
            }
        } else if let Some(a) = e.get("approval") {
            if !self.approvals.iter().any(|x| x["id"] == a["id"]) {
                self.approvals.push(a.clone());
            }
            if let Some(asset) = a["asset"].as_str() {
                let s = if a["decision"] == "approve" { "approved" } else { "needsChanges" };
                self.status.insert(asset.to_owned(), s.into());
            }
        } else if let Some(f) = e.get("field") {
            self.seen(f["id"].as_str());
            if let (Some(asset), Some(k)) = (f["asset"].as_str(), f["field"].as_str()) {
                match (k, f["value"].as_str()) {
                    ("status", Some(st)) => { self.status.insert(asset.to_owned(), st.to_owned()); }
                    _ => { self.fields.entry(asset.to_owned()).or_default().insert(k.to_owned(), f["value"].clone()); }
                }
            }
        } else if let Some(a) = e.get("activity") {
            self.seen(a["id"].as_str());
            *self.activity.entry(a["link"].as_str().unwrap_or("").to_owned()).or_default() += 1;
        } else if let Some(u) = e.get("upload") {
            if let (Some(id), true) = (u["id"].as_str(), u["for"] == "attachment") {
                self.attachments.insert(id.to_owned(), u.clone());
            }
        }
    }

    /// Remember an activity or field id (the last 50,000), so a repeated push isn't logged twice.
    fn seen(&mut self, id: Option<&str>) {
        let Some(id) = id else { return };
        if self.act_ids.0.insert(id.to_owned()) {
            self.act_ids.1.push_back(id.to_owned());
            if self.act_ids.1.len() > ACT_IDS {
                if let Some(old) = self.act_ids.1.pop_front() {
                    self.act_ids.0.remove(&old);
                }
            }
        }
    }

    /// An entry pushed by the editor's Pluck or another host, merged (§13.0): comments with MC,
    /// tombstones by rev, approvals/activity/fields by id. None when it changes nothing.
    fn merged_entry(&self, kind: &str, x: &Value) -> Option<Value> {
        let id = x["id"].as_str()?;
        match kind {
            "comment" => {
                let rev = x["rev"].as_u64().unwrap_or(0);
                if self.comment_tombs.get(id).is_some_and(|t| *t >= rev) {
                    return None;
                }
                match self.comments.iter().find(|c| c["id"] == id) {
                    // An old Pluck sends no rev: its copy replaces ours, as before.
                    Some(c) if x.get("rev").is_none() => (c != x).then(|| x.clone()),
                    Some(c) => {
                        let m = crate::store::merge_comment(c, x);
                        (m != *c).then_some(m)
                    }
                    None => Some(x.clone()),
                }
            }
            "deleted" => {
                let rev = x["rev"].as_u64().unwrap_or(u64::MAX);
                let newer = self.comments.iter().any(|c| c["id"] == id && c["rev"].as_u64().unwrap_or(0) > rev);
                let known = self.comment_tombs.get(id).is_some_and(|t| *t >= rev);
                (!newer && !known).then(|| x.clone())
            }
            "approval" => (!self.approvals.iter().any(|a| a["id"] == id)).then(|| x.clone()),
            _ => (!self.act_ids.0.contains(id)).then(|| x.clone()),
        }
    }

    /// Activity retention: the manifest's `activityDays` (else 90; 0 = forever), and the newest 20,000 entries per link.
    /// Rewrites comments.jsonl (temp file + rename) only when something goes; seqs stay as they were.
    fn compact(&mut self) {
        let days = self.raw["activityDays"].as_i64().filter(|d| [0, 30, 90, 180].contains(d)).unwrap_or(ACTIVITY_DAYS);
        let cutoff = if days == 0 { String::new() } else {
            iso(now_secs() - days * 86_400)
        };
        let mut keep: HashMap<String, usize> = HashMap::new();
        let mut newest: std::collections::HashSet<String> = Default::default();
        let forget = self.forgotten();
        let before = self.entries.len();
        let mut kept: Vec<Value> = self.entries.iter().rev().filter(|e| {
            if let Some(c) = e.get("comment") {
                // Only a comment's newest snapshot is kept: each reply, reaction or complete re-logged it whole (#12).
                return newest.insert(c["id"].as_str().unwrap_or("").to_owned());
            }
            let Some(a) = e.get("activity") else { return true };
            if a["link"].as_str().is_some_and(|l| forget.contains(l)) {
                return false;
            }
            let n = keep.entry(a["link"].as_str().unwrap_or("").to_owned()).or_default();
            *n += 1;
            *n <= ACTIVITY_CAP && a["at"].as_str().is_some_and(|t| t >= cutoff.as_str())
        }).cloned().collect();
        let mut stripped = false;
        for a in kept.iter_mut().filter_map(|e| e.get_mut("approval")) {
            if a["link"].as_str().is_some_and(|l| forget.contains(l)) && a.as_object_mut().and_then(|o| o.remove("email")).is_some() {
                stripped = true;
            }
        }
        if kept.len() == before && !stripped {
            return;
        }
        kept.reverse();
        let text: String = kept.iter().map(|e| format!("{e}\n")).collect();
        let tmp = self.log_path.with_extension("jsonl.part");
        if let Err(e) = std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, &self.log_path)) {
            return log(format!("host: can't compact comments.jsonl: {e}"));
        }
        self.entries = kept;
        self.superseded = 0;
        self.activity.clear();
        for e in &self.entries {
            if let Some(a) = e.get("activity") {
                *self.activity.entry(a["link"].as_str().unwrap_or("").to_owned()).or_default() += 1;
            }
        }
    }

    /// Links archived longer than the manifest's `archiveForgetDays` (Pluck's setting; 0 or none: kept) (wf-deliver).
    fn forgotten(&self) -> std::collections::HashSet<String> {
        let days = self.raw["archiveForgetDays"].as_i64().unwrap_or(0);
        if days <= 0 {
            return Default::default();
        }
        let cutoff = iso(now_secs() - days * 86_400);
        self.links().filter(|l| l["archived"].as_str().and_then(norm_iso).is_some_and(|a| a < cutoff))
            .filter_map(|l| l["id"].as_str().map(str::to_owned)).collect()
    }

    /// Their client data goes: activity, the emails on approvals (name and date stay) and the clients' mail rows.
    fn forget_archived(&mut self) {
        let forget = self.forgotten();
        if forget.is_empty() {
            return;
        }
        let has = |l: &Value| l.as_str().is_some_and(|l| forget.contains(l));
        let stale = self.entries.iter().any(|e| e.get("activity").is_some_and(|a| has(&a["link"]))
            || e.get("approval").is_some_and(|a| has(&a["link"]) && a.get("email").is_some()));
        for a in self.approvals.iter_mut().filter(|a| has(&a["link"])) {
            a.as_object_mut().map(|o| o.remove("email"));
        }
        let n = self.mail.subs.len();
        self.mail.subs.retain(|r| !(r["kind"] == "client" && has(&r["link"])));
        if self.mail.subs.len() != n {
            self.mail.save_subs();
        }
        if stale {
            self.compact();
        }
    }

    /// Log what a browser did (the owner's activity feed). Never the IP: the host only sees NAT/TURN addresses.
    fn activity(&mut self, peer: &str, kind: &str, asset: Value, version: Value, detail: Value) {
        let Some(p) = self.peers.get(peer) else { return };
        let Some(link) = self.link(&p.room).map(|l| l["id"].clone()).or_else(|| self.is_team(&p.room).then(|| json!("team"))) else { return };
        let mut a = json!({"id": uuid(), "link": link, "at": now_iso(), "peer": peer, "name": p.name, "kind": kind,
            "asset": asset, "version": version, "detail": detail});
        if !p.email.is_empty() {
            a["email"] = json!(p.email);
        }
        self.append(json!({"activity": a}));
        if self.activity.get(link.as_str().unwrap_or("")).is_some_and(|n| *n > ACTIVITY_CAP + ACTIVITY_CAP / 20) {
            self.compact();
        }
    }

    /// Append one entry ({"comment"} | {"deleted"} | {"approval"}) with the next seq.
    fn append(&mut self, mut e: Value) -> bool {
        self.seq += 1;
        e["seq"] = json!(self.seq);
        let line = format!("{e}\n");
        if e.get("comment").is_some_and(|c| self.comments.iter().any(|x| x["id"] == c["id"])) {
            self.superseded += line.len();
        }
        let ok = std::fs::OpenOptions::new().create(true).append(true).open(&self.log_path).and_then(|mut f| {
            let len = f.metadata()?.len();
            // A disk-full write can stop mid-line; cut it off, or the next entry would join it and both be lost.
            f.write_all(line.as_bytes()).and_then(|_| f.sync_data()).inspect_err(|_| { let _ = f.set_len(len); })
        });
        if let Err(err) = ok {
            log(format!("host: can't write comments.jsonl: {err}"));
            self.seq -= 1;
            return false;
        }
        // A backup's own comment, approval or field (not an activity line): to the main now, not at the next round.
        if let (Some(r), true) = (&self.replica, e.get("main").is_none() && e.get("activity").is_none()) {
            r.nudge();
        }
        self.apply(&e);
        self.entries.push(e);
        if self.superseded > SUPERSEDED_MAX {
            self.compact();
        }
        true
    }

    /// The sync API (stdin `{"host":{…}}` and the sync endpoint): pull, append, reload.
    pub fn sync(&mut self, op: &Value) -> Value {
        if let Some(r) = self.account_sync(op).or_else(|| self.mail_sync(op)) {
            return r;
        }
        match op["op"].as_str().unwrap_or("") {
            "pull" => {
                let since = op["since"].as_u64().unwrap_or(0);
                // A page of ≤ 5000 entries (and ~16 MB); seq is the last one returned, `more` when entries are left (#16).
                let mut bytes = 0;
                let mut e: Vec<&Value> = vec![];
                let mut rest = self.entries.iter().filter(|e| e["seq"].as_u64().unwrap_or(0) > since);
                for x in rest.by_ref() {
                    bytes += x.to_string().len();
                    e.push(x);
                    if e.len() >= 5000 || bytes >= PULL_BYTES {
                        break;
                    }
                }
                let more = rest.next().is_some();
                let seq = if more { e.last().and_then(|x| x["seq"].as_u64()).unwrap_or(since) } else { self.seq };
                json!({"entries": e, "seq": seq, "more": more})
            }
            "append" | "_replica-entries" => {
                let (mut n, mut failed) = (0, false);
                const KINDS: [&str; 5] = ["comment", "deleted", "approval", "field", "activity"];
                for e in op["entries"].as_array().into_iter().flatten() {
                    let keys = KINDS.iter().filter(|k| e.get(**k).is_some()).count();
                    let id_ok = KINDS.iter().find_map(|k| e.get(*k)).is_some_and(|x| x["id"].is_string());
                    if keys == 1 && id_ok {
                        let k = KINDS.into_iter().find(|k| e.get(*k).is_some()).unwrap();
                        let Some(x) = self.merged_entry(k, &e[k]) else { continue };
                        let mut entry = json!({ k: x });
                        if op["op"] == "_replica-entries" {
                            entry["main"] = e["seq"].clone(); // from the main: never pushed back
                        }
                        let before = self.comments.iter().find(|c| c["id"] == entry[k]["id"]).cloned();
                        if !self.append(entry.clone()) {
                            failed = true; // disk full or unwritable: the sender keeps them and sends again (merging makes that safe)
                            break;
                        }
                        n += 1;
                        self.fan_synced(k, &entry[k], before.as_ref());
                        if op["op"] == "append" {
                            match k {
                                "comment" => self.mail_comment(before.as_ref(), &entry[k]),
                                "approval" => self.mail_approval(&entry[k]),
                                _ => {}
                            }
                        }
                    }
                }
                if n > 0 {
                    self.broadcast_all_changed();
                }
                if failed {
                    return json!({"error": "write", "appended": n, "seq": self.seq});
                }
                json!({"ok": true, "appended": n, "seq": self.seq})
            }
            "_replica-plan" => json!({"versions": self.replica_plan()}),
            "_outage-entry" => {
                // A backup's upload from an outage, now here (outage.rs): logged once by its id, as if made here.
                let e = &op["entry"];
                if !e["id"].is_string() || self.entries.iter().any(|x| x["upload"]["id"] == e["id"]) {
                    return json!({"ok": true});
                }
                if !self.append(json!({"upload": e})) {
                    return json!({"error": "write"});
                }
                json!({"ok": true})
            }
            "_replica-own" => {
                // A backup's own entries (not from the main) after `since`, to push to the main.
                let since = op["since"].as_u64().unwrap_or(0);
                let e: Vec<&Value> = self.entries.iter().filter(|e| e.get("main").is_none() && e.get("upload").is_none()
                    && e["seq"].as_u64().unwrap_or(0) > since).take(500).collect();
                json!({"entries": e})
            }
            "_replica-apply" => {
                // A page of the main's `changes`, applied to this backup's manifest under M.
                let mut m = crate::store::fragment(op);
                for k in ["branding", "activityDays"] { // not in `changes`: from the main's manifest (replica::branding)
                    if let Some(v) = op.get(k) { m[k] = v.clone(); }
                }
                self.merge_publish(&m, &op["removed"], false)
            }
            "reload" => {
                self.reload();
                self.broadcast_all_changed(); // e.g. a backup's recalled copy is there: open viewers play it
                json!({"ok": true})
            }
            "publish" if op["merge"] == true => {
                let by_admin = op["by"] == "admin";
                let mut r = self.merge_publish(&op["manifest"], &op["tombstones"], true);
                if by_admin { r["by"] = json!("admin") }
                r
            }
            "publish" => self.publish(&op["manifest"], &op["remove"]),
            "changes" => crate::store::changes(&self.raw, op["since"].as_u64().unwrap_or(0), op["limit"].as_u64().unwrap_or(500) as usize),
            "prepare-update" => self.prepare_update(),
            "cancel-update" => {
                self.busy.preparing.store(false, std::sync::atomic::Ordering::Relaxed);
                self.queue_copies();
                json!({"ok": true})
            }
            "manifest" => self.raw.clone(),
            "admin-state" => self.admin_state(),
            "admin-publish" => self.admin_publish(op),
            "admin-unpublish" => self.admin_unpublish(op),
            "admin-renew" => self.admin_renew(op),
            "admin-comments" => self.admin_comments(op),
            "admin-activity" => {
                let list: Vec<&Value> = self.entries.iter().rev().filter_map(|e| e.get("activity")).filter(|a| a["link"] == op["link"]).take(500).collect();
                json!({"activity": list})
            }
            "status" => {
                let mut s = json!({"seq": self.seq, "storeSeq": self.raw["storeSeq"], "viewers": self.peers.values().filter(|p| p.ready).count(),
                    "copies": self.jobs, "role": if self.ident.backup { "backup" } else { "main" }});
                crate::update::status_fields(&mut s, &self.data);
                s["uplinkMbps"] = json!(crate::uplink::mbps());
                s["preferFastest"] = json!(crate::signal::FASTEST.load(std::sync::atomic::Ordering::Relaxed));
                if let Some(r) = &self.replica {
                    s["replica"] = r.summary();
                }
                s
            }
            "prefer-fastest" if !self.ident.backup => {
                let on = op["on"] == true;
                match std::fs::write(self.data.join("serving.json"), json!({"preferFastest": on}).to_string()) {
                    Ok(()) => { self.load_serving(); json!({"ok": true, "preferFastest": on}) }
                    Err(e) => json!({"error": format!("can't write serving.json: {e}")}),
                }
            }
            // 4.1: the team's custom statuses, fields and saved views (Pluck's library.json), kept for the team's Macs as
            // they send it; the newest `at` wins (an ISO date, so strings compare). Never to browsers.
            "library" => json!({"library": std::fs::read(self.data.join("library.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())}),
            "library-set" if !self.ident.backup => {
                let new = &op["library"];
                let size = new.to_string().len();
                if !new.is_object() || size > 256 * 1024 {
                    return json!({"error": {"code": "invalid"}});
                }
                let path = self.data.join("library.json");
                let old = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
                let newer = old.as_ref().is_none_or(|o| new["at"].as_str().unwrap_or("") > o["at"].as_str().unwrap_or(""));
                if newer {
                    if let Err(e) = std::fs::write(&path, new.to_string()) {
                        return json!({"error": format!("can't write library.json: {e}")});
                    }
                }
                json!({"ok": true, "library": if newer { new.clone() } else { old.unwrap_or(Value::Null) }})
            }
            _ => json!({"error": "unknown op"}),
        }
    }

    /// After the editor pushed comments, ready clients re-fetch what they're looking at.
    /// A comment (or its deletion) that came in by sync (the editor's Mac, the main or a backup): live to the browsers
    /// whose link holds its asset, as a browser's own write is; internal ones to team links only.
    fn fan_synced(&self, kind: &str, x: &Value, before: Option<&Value>) {
        if kind != "comment" && kind != "deleted" {
            return;
        }
        let asset = x["asset"].as_str().or_else(|| before.and_then(|c| c["asset"].as_str())).unwrap_or("").to_owned();
        let hidden = is(before.unwrap_or(x), "internal") || is(x, "internal");
        let version = if x["version"].is_null() { before.map_or(Value::Null, |c| c["version"].clone()) } else { x["version"].clone() };
        for (id, p) in &self.peers {
            let Some(pl) = self.peer_link(p) else { continue };
            if !p.ready || !self.sees(&pl, &asset, &version) || (hidden && !team(&pl)) {
                continue;
            }
            let ev = if kind == "deleted" {
                json!({"t": "comment", "op": "delete", "comment": x})
            } else {
                json!({"t": "comment", "op": if before.is_some() { "edit" } else { "add" }, "comment": Self::wire_comment(x, Self::toks(p), team(&pl))})
            };
            self.send(id, ev);
        }
    }

    fn broadcast_all_changed(&self) {
        for (id, p) in &self.peers {
            if let (true, Some(a)) = (p.ready, &p.viewing) {
                self.send(id, json!({"t": "asset-changed", "asset": a}));
            }
        }
    }

    // ---- reports from the RTC loop ----

    pub fn report(&mut self, v: &Value) {
        if let Some(p) = v.get("peer") {
            let id = p["peer"].as_str().unwrap_or("").to_owned();
            match p["state"].as_str() {
                Some("open") => {
                    let nonce: [u8; 32] = rand::random();
                    let (room, fp_mac, fp_browser) = (p["room"].as_str().unwrap_or(""), p["fpLocal"].as_str().unwrap_or(""), p["fpRemote"].as_str().unwrap_or(""));
                    // Protocol 2: the hello is signed with the room's key, which link holders don't have. Protocol 3
                    // (§13.24): a MAC with the code-derived authKey, which pluck.tools doesn't have.
                    let hello = if self.is_team(room) { self.team_hello(&nonce, fp_mac, fp_browser) } else { self.link(room).and_then(|l| if level3(l) {
                        let auth = keys::unb64(l["auth"].as_str()?)?;
                        Some(json!({"t": "hello", "v": 3, "nonce": keys::b64(&nonce), "mac": keys::hello_v3(&auth, &nonce, fp_mac, fp_browser)}))
                    } else {
                        let sig = keys::sign_hello(&keys::unb64(l["sign"].as_str()?)?, &nonce, fp_mac, fp_browser)?;
                        Some(json!({"t": "hello", "v": 2, "nonce": keys::b64(&nonce), "sig": sig}))
                    }) };
                    let Some(hello) = hello else {
                        return self.cmd(json!({"close": {"peer": id, "reason": "unknown"}}));
                    };
                    self.peers.insert(id.clone(), HPeer {
                        room: room.into(), nonce, fp_mac: fp_mac.into(), fp_browser: fp_browser.into(),
                        authed: false, ready: false, token: None, name: String::new(), wrong: 0, viewing: None, writes: VecDeque::new(),
                        email: String::new(), stills: VecDeque::new(), beacons: VecDeque::new(), fetches: HashMap::new(), pw: Value::Null,
                        ..Default::default()
                    });
                    self.send(&id, hello);
                }
                Some("closed") => {
                    if let Some(p) = self.drop_peer(&id) {
                        self.presence(&p.room);
                    }
                }
                _ => {}
            }
        } else if let Some(s) = v.get("served") {
            let (peer, fetch) = (s["peer"].as_str().unwrap_or(""), s["fetch"].as_u64().unwrap_or(u64::MAX));
            let Some(f) = self.peers.get_mut(peer).and_then(|p| p.fetches.remove(&fetch)) else { return };
            if let (Some(r), Some(v)) = (&self.replica, &f.version) {
                r.fetch_end(v);
            }
            if let Some(t) = f.temp {
                let _ = std::fs::remove_file(t);
            }
            if let (Some((asset, version, what)), "done") = (f.download, s["result"].as_str().unwrap_or("")) {
                if what != "proxy" {
                    self.mail_download(peer, &asset, &version);
                }
                self.activity(peer, "downloaded", asset, version, json!({"what": what}));
            }
        } else if let Some(u) = v.get("upload") {
            let key = (u["peer"].as_str().unwrap_or("").to_owned(), u["upload"].as_u64().unwrap_or(u64::MAX));
            if self.root_ups.contains_key(&key) {
                return self.root_written(&key, u);
            }
            let Some(up) = self.uploads.get_mut(&key) else { return };
            if u["state"] == "done" && u["bytes"].as_u64() == Some(up.size) {
                up.sha = u["sha256"].as_str().map(str::to_owned);
                if up.end.is_some() {
                    self.finish_upload(&key);
                }
            } else if let Some(up) = self.uploads.remove(&key) {
                let _ = std::fs::remove_file(&up.part);
                if let Some((id, _)) = up.end {
                    self.err(&key.0, &id, "invalid");
                }
            }
        } else if let Some(m) = v.get("msg") {
            let peer = m["peer"].as_str().unwrap_or("").to_owned();
            if self.peers.contains_key(&peer) {
                self.request(&peer, &m["msg"]);
            }
        }
    }

    fn request(&mut self, peer: &str, m: &Value) {
        let id = m["id"].clone();
        let t = m["t"].as_str().unwrap_or("");
        let room = self.peers[peer].room.clone();
        if self.is_team(&room) {
            return self.team_request(peer, &id, t, m);
        }
        let Some(link) = self.link(&room).cloned() else { return self.err(peer, &id, "revoked") };
        if let Err(code) = self.live(&link).and_then(|()| Self::repassworded(&self.peers[peer], &link).map_or(Ok(()), Err)) {
            let mut e = json!({"re": id, "error": {"code": code}});
            if code == "deadline" {
                e["error"]["at"] = json!(self.deadline(&link));
            }
            if code == "archived" {
                e["error"] = json!({"code": "paused", "archived": true}); // (an older page shows "paused", never retries)
            }
            self.send(peer, e);
            self.send(peer, self.bye(&link, code));
            return self.close_later(peer);
        }
        match t {
            "auth" => return self.auth(peer, &id, m, &link),
            "password" => return self.password(peer, &id, m, &link),
            // The token in a mail is the right: no name, password or sign-in needed, only a verified link session.
            "unsubscribe" if self.peers[peer].authed => {
                let mut r = self.unsubscribe(m["token"].as_str().unwrap_or(""));
                r["re"] = id;
                return self.send(peer, r);
            }
            // The same for the link in a confirmation mail (double opt-in, 4.0.7).
            "confirm" if self.peers[peer].authed => {
                let mut r = self.confirm_sub(m["token"].as_str().unwrap_or(""));
                r["re"] = id;
                return self.send(peer, r);
            }
            _ if !self.peers[peer].ready => return self.err(peer, &id, "auth"),
            _ => {}
        }
        if self.account_op(peer, &id, t, m).is_some() {
            return;
        }
        // Personal and "require a name" links: nothing but naming yourself until there's a name.
        if is(&link, "requireName") && self.peers[peer].name.is_empty() && t != "identify" && t != "name" {
            return self.err(peer, &id, "auth");
        }
        let writes = ["comment-add", "reply-add", "comment-edit", "comment-delete", "comment-complete", "approve", "react", "field-set",
            "upload-begin", "upload-end"];
        if writes.contains(&t) && (link["mode"] == "presentation" || link["delivered"].is_string()) {
            return self.err(peer, &id, "readonly");
        }
        self.dispatch(peer, &id, t, &link, m)
    }

    /// A link's ops (and the team room's, with a link built for the project).
    fn dispatch(&mut self, peer: &str, id: &Value, t: &str, link: &Value, m: &Value) {
        let (id, room) = (id.clone(), self.peers[peer].room.clone());
        let r = match t {
            "list" => self.list(link, m),
            "asset" => self.asset(peer, link, m),
            "fetch" => return self.fetch(peer, &id, link, m),
            "comments" => self.comments(peer, link, m),
            "comment-add" | "reply-add" | "comment-edit" | "comment-delete" | "comment-complete" | "approve" | "react" => self.write(peer, t, link, m),
            "field-set" => self.field_set(peer, link, m),
            "upload-begin" => return self.upload_begin(peer, &id, link, m),
            "upload-end" => return self.upload_end(peer, &id, m),
            "cancel" => {
                let key = (peer.to_owned(), m["upload"].as_u64().unwrap_or(u64::MAX));
                if let Some(u) = self.uploads.remove(&key) {
                    self.cmd(json!({"cancel": {"peer": peer, "upload": key.1}}));
                    let _ = std::fs::remove_file(&u.part);
                }
                if id.is_null() { return }
                Ok(json!({"ok": true}))
            }
            "name" | "identify" => {
                let p = self.peers.get_mut(peer).unwrap();
                // A signed-in peer keeps the account's name; a personal link keeps its recipient's.
                if p.acct.person.is_none() && link["recipient"].as_str().is_none_or(|r| r.trim().is_empty()) {
                    p.name = clean(m["name"].as_str().unwrap_or(""), 40); // a personal link keeps its recipient's name
                }
                if let Some(e) = m["email"].as_str().filter(|_| p.acct.person.is_none()) {
                    p.email = clean(e, 120);
                }
                self.presence(&room);
                Ok(if t == "identify" { json!({"ok": true}) } else { json!({}) })
            }
            "viewing" => {
                let a = m["asset"].as_str().filter(|a| self.asset_in_scope(link, a).is_some()).map(str::to_owned);
                let changed = self.peers[peer].viewing != a;
                self.peers.get_mut(peer).unwrap().viewing = a.clone();
                self.presence(&room);
                if let (true, Some(a)) = (changed, a) {
                    self.activity(peer, "viewed", json!(a), Value::Null, Value::Null);
                }
                Ok(json!({}))
            }
            "played" => self.played(peer, link, m),
            "mentionable" => Ok(json!({"people": self.mentionable(link)})),
            "subscribe" | "subscription" => self.subscribe(peer, link, m, t),
            _ => Err("invalid"),
        };
        match r {
            Ok(mut v) => {
                v["re"] = id;
                self.send(peer, v);
            }
            Err(code) => self.err(peer, &id, code),
        }
    }

    /// The playback beacon: frames watched since the last one, logged as activity (≤ 30 a minute).
    fn played(&mut self, peer: &str, l: &Value, m: &Value) -> Result<Value, &'static str> {
        let (_, a) = self.asset_in_scope(l, m["asset"].as_str().ok_or("invalid")?).ok_or("scope")?;
        let v = *Self::versions(l, a).iter().find(|v| v["id"] == m["version"]).ok_or("scope")?;
        let frames = v["frames"].as_i64().unwrap_or(i64::MAX).max(1);
        let (from, to) = (m["from"].as_i64().ok_or("invalid")?, m["to"].as_i64().ok_or("invalid")?);
        if from < 0 || to < from || to > frames {
            return Err("invalid");
        }
        let (asset, version) = (a["id"].clone(), v["id"].clone());
        if !rate(&mut self.peers.get_mut(peer).unwrap().beacons, Duration::from_secs(60), 30) {
            return Err("limit");
        }
        self.activity(peer, "played", asset, version, json!({"from": from, "to": to}));
        Ok(json!({"ok": true}))
    }

    fn auth(&mut self, peer: &str, id: &Value, m: &Value, link: &Value) {
        let auth_key = link["auth"].as_str().and_then(keys::unb64).unwrap_or_default();
        let p = &self.peers[peer];
        let nonce = m["nonce"].as_str().and_then(keys::unb64).filter(|n| n.len() == 32);
        let ok = !p.authed && m["v"] == if level3(link) { 3 } else { 2 } && auth_key.len() == 32 && nonce.as_ref().is_some_and(|n| {
            keys::check_proof(&auth_key, m["proof"].as_str().unwrap_or(""), &p.nonce, n, &p.fp_mac, &p.fp_browser)
        });
        if !ok {
            self.err(peer, id, "auth");
            return self.close_later(peer);
        }
        let proof = keys::proof(&auth_key, "mac", &p.nonce, nonce.as_ref().unwrap(), &p.fp_mac, &p.fp_browser);
        let need = link["passwordHash"].is_string();
        let p = self.peers.get_mut(peer).unwrap();
        p.authed = true;
        p.token = m["token"].as_str().and_then(keys::unb64).filter(|t| t.len() == 32).map(|t| keys::sha256_b64(&t));
        p.name = match link["recipient"].as_str().map(|r| clean(r, 40)).filter(|r| !r.is_empty()) {
            Some(r) => r, // a personal link: the recipient's name, read-only
            None => clean(m["name"].as_str().unwrap_or(""), 40),
        };
        p.email = clean(m["email"].as_str().unwrap_or(""), 120);
        let team_room = self.is_team(&self.peers[peer].room);
        let mut w = json!({"re": id, "t": "welcome", "proof": proof, "needPassword": need});
        if self.accounts.on() {
            w["team"] = self.accounts.team(); // a 4.0.4 host with accounts: the page offers sign-in (§2.2)
        }
        if team_room {
            w["needAccount"] = json!(true); // the team room: a passkey, never `ready` before it (§2.1)
        }
        self.send(peer, w);
        if !need && !team_room {
            self.ready(peer, &Value::Null, link); // no password: `ready` follows as an event
        }
    }

    fn password(&mut self, peer: &str, id: &Value, m: &Value, link: &Value) {
        let lid = link["id"].as_str().unwrap_or("").to_owned();
        let hour = Instant::now().checked_sub(Duration::from_secs(3600));
        let fails = self.fails.entry(lid.clone()).or_default();
        fails.retain(|t| hour.is_none_or(|h| *t > h));
        if fails.len() >= 20 {
            return self.err(peer, id, "locked");
        }
        let p = &self.peers[peer];
        if !p.authed || p.ready {
            return self.err(peer, id, "auth");
        }
        if keys::check_password(link["passwordHash"].as_str().unwrap_or(""), m["password"].as_str().unwrap_or("")) {
            return self.ready(peer, id, link);
        }
        self.fails.get_mut(&lid).unwrap().push(Instant::now());
        self.err(peer, id, "password");
        let p = self.peers.get_mut(peer).unwrap();
        p.wrong += 1;
        if p.wrong >= 5 {
            self.close_later(peer);
        }
        if self.fails[&lid].len() == 20 {
            log(format!("host: link {lid} locked for an hour after 20 wrong passwords"));
        }
    }

    fn ready(&mut self, peer: &str, id: &Value, link: &Value) {
        let room = self.peers[peer].room.clone();
        let p = self.peers.get_mut(peer).unwrap();
        p.ready = true;
        p.pw = link["passwordHash"].clone();
        let mut wire = json!({"title": link["title"], "mode": link["mode"], "allowDownload": is(link, "allowDownload"),
            "latestOnly": is(link, "latestOnly"), "expires": link["expires"]});
        for k in LINK_FIELDS {
            if let Some(x) = link.get(k) {
                wire[k] = x.clone();
            }
        }
        if let Some(u) = wire["uploads"].as_object_mut() {
            u.remove("into"); // where files land on the NAS is the team's business
        }
        if let Some(d) = self.deadline(link) {
            wire["deadline"] = json!(d);
        }
        let mut root = link["root"].clone();
        if let Some(o) = root.as_object_mut() {
            o.remove("assets"); // the picked ids stay on the host; the browser lists them
        }
        let mut v = json!({"t": "ready", "link": wire, "root": root, "me": {"peer": peer, "name": self.peers[peer].name}, "now": now_iso(),
            "mentions": true});
        if self.mail_link_ok(link) {
            v["mail"] = json!(true); // the page may offer "Email me about replies"
        }
        // A backup serving lighter copies says so (§13.3); in "same" mode, or on the main, nothing.
        if self.replica.as_ref().is_some_and(|r| r.lighter()) {
            v["served"] = json!({"by": "backup", "lighter": true});
        }
        if !id.is_null() {
            v["re"] = id.clone();
        }
        if self.manifest["branding"].is_object() {
            v["branding"] = self.manifest["branding"].clone();
        }
        self.send(peer, v);
        self.presence(&room);
        self.activity(peer, "opened", Value::Null, Value::Null, Value::Null);
    }

    fn presence(&self, room: &str) {
        // (Team-room clients are neither told nor listed: accounts review fix M3.)
        let viewers: Vec<Value> = self.peers.iter().filter(|(_, p)| p.ready && p.room == room && self.presence_ok(p))
            .map(|(id, p)| json!({"peer": id, "name": p.name, "asset": p.viewing})).collect();
        for (id, p) in &self.peers {
            if p.ready && p.room == room && self.presence_ok(p) {
                self.send(id, json!({"t": "presence", "viewers": viewers}));
            }
        }
    }

    /// The asset's fields this link shows (`link.fields`, default status only), the manifest's
    /// merged with those set from links. Status has its own key.
    fn fields_of(&self, l: &Value, a: &Value) -> Option<Value> {
        // A team link shows every field, custom ones too (as the Mac's own server); a client link only its `fields`.
        let set = a["id"].as_str().and_then(|id| self.fields.get(id));
        let shown: Vec<&str> = if team(l) {
            let custom = a["fields"].as_object().into_iter().flat_map(|o| o.keys()).chain(set.into_iter().flat_map(|m| m.keys()));
            let custom: std::collections::BTreeSet<&str> = custom.map(String::as_str).filter(|k| k.starts_with("cf:")).collect();
            ["rating", "keywords", "assignee", "due", "notes"].into_iter().chain(custom).collect()
        } else {
            Self::arr(l, "fields").filter_map(Value::as_str).filter(|f| *f != "status").collect()
        };
        let mut o = serde_json::Map::new();
        for f in shown {
            let set = a["id"].as_str().and_then(|id| self.fields.get(id)).and_then(|m| m.get(f));
            if let Some(x) = set.or(a["fields"].get(f)).filter(|x| !x.is_null()) {
                o.insert(f.into(), x.clone());
            }
        }
        (!o.is_empty()).then_some(Value::Object(o))
    }

    fn visible(l: &Value, c: &Value) -> bool {
        !is(c, "internal") || team(l)
    }

    fn summary(&self, l: &Value, a: &Value) -> Value {
        let vs = Self::versions(l, a);
        let cur = vs.last().map(|v| json!({"id": v["id"], "number": v["number"], "duration": v["duration"],
            "fpsNum": v["fpsNum"], "fpsDen": v["fpsDen"], "ready": v["ready"],
            "comments": self.comments.iter().filter(|c| c["version"] == v["id"] && Self::visible(l, c)).count()}));
        let mut s = json!({"id": a["id"], "name": a["name"], "kind": a["kind"], "status": self.status_of(a), "current": cur, "versions": vs.len()});
        if a["group"].is_string() {
            s["group"] = a["group"].clone(); // a deliverable group (wf-deliver): one card on the page
        }
        if let Some(f) = self.fields_of(l, a) {
            s["fields"] = f;
        }
        s
    }

    fn list(&self, l: &Value, m: &Value) -> Result<Value, &'static str> {
        let p = self.project(l).ok_or("notFound")?;
        let root = &l["root"];
        let pid = || json!({"id": p["id"], "name": p["name"]});
        if root["kind"] == "asset" || root["kind"] == "assets" {
            if !m["folder"].is_null() {
                return Err("scope");
            }
            // As Swift: no breadcrumb (the project isn't part of these links), just the assets, in the link's order.
            let ids: Vec<&Value> = if root["kind"] == "asset" { vec![&root["id"]] } else { Self::arr(root, "assets").collect() };
            let assets: Vec<Value> = ids.into_iter().filter_map(|id| self.asset_in_scope(l, id.as_str()?)).map(|(_, a)| self.summary(l, a)).collect();
            return Ok(json!({"path": [], "folders": [], "assets": assets}));
        }
        let at: Option<String> = match (m["folder"].as_str(), root["kind"].as_str()) {
            (None, Some("folder")) => root["id"].as_str().map(str::to_owned),
            (None, Some("project")) => None,
            (Some(f), Some("folder")) if Self::under(p, Some(f), root["id"].as_str().unwrap_or("")) => Some(f.to_owned()),
            (Some(f), Some("project")) if Self::arr(p, "folders").any(|x| x["id"] == f) => Some(f.to_owned()),
            _ => return Err("scope"),
        };
        // Breadcrumb: the project (project links), then the folders down to `at`.
        let mut chain = vec![];
        let mut f = at.clone();
        while let Some(id) = f.take() {
            let Some(x) = Self::arr(p, "folders").find(|x| x["id"] == id.as_str()) else { break };
            chain.push(json!({"id": x["id"], "name": x["name"]}));
            if root["kind"] == "folder" && root["id"] == id.as_str() || chain.len() > 32 {
                break;
            }
            f = x["parent"].as_str().map(str::to_owned);
        }
        if root["kind"] == "project" {
            chain.push(pid());
        }
        chain.reverse();
        let here = |v: &Value| v.as_str() == at.as_deref();
        let folders: Vec<Value> = Self::arr(p, "folders").filter(|x| here(&x["parent"]))
            .map(|x| json!({"id": x["id"], "name": x["name"], "count": Self::arr(p, "assets").filter(|a| a["folder"] == x["id"]).count()}))
            .collect();
        let assets: Vec<Value> = Self::arr(p, "assets").filter(|a| here(&a["folder"])).map(|a| self.summary(l, a)).collect();
        Ok(json!({"path": chain, "folders": folders, "assets": assets}))
    }

    fn asset(&self, _peer: &str, l: &Value, m: &Value) -> Result<Value, &'static str> {
        let given = m["asset"].as_str().ok_or("invalid")?;
        let full = if given.len() == 8 { self.short_asset(l, given).ok_or("notFound")? } else { given.to_owned() };
        let (_, a) = self.asset_in_scope(l, &full).ok_or("scope")?;
        let dl = is(l, "allowDownload");
        let versions: Vec<Value> = Self::versions(l, a).into_iter().map(|v| {
            let can = dl && !Self::burned(l) && !self.ident.backup && (v["original"].is_string() || v["source"].is_string());
            let mut w = json!({});
            for k in ["id", "number", "added", "duration", "fpsNum", "fpsDen", "width", "height", "startTimecode", "dropFrame", "frames", "renditions"] {
                w[k] = v[k].clone();
            }
            if v["pages"].is_u64() {
                w["pages"] = v["pages"].clone();
            }
            if Self::burned(l) {
                // Its own copies are the H.264 ladder only: no 4K to pick.
                w["renditions"] = json!(Self::arr(v, "renditions").filter(|r| !r.as_str().is_some_and(|r| r.starts_with("2160"))).collect::<Vec<_>>());
            }
            w["ready"] = v["ready"].clone();
            w["canDownload"] = json!(can);
            w["size"] = if can { v["size"].clone() } else { json!(0) };
            w
        }).collect();
        let mut asset = json!({"id": a["id"], "name": a["name"], "kind": a["kind"], "status": self.status_of(a), "versions": versions});
        if let Some(f) = self.fields_of(l, a) {
            asset["fields"] = f;
        }
        let approvals: Vec<Value> = self.approvals_of(l, &a["id"]).into_iter().map(|x| json!({"id": x["id"], "decision": x["decision"],
            "by": x["author"], "at": x["created"], "version": x["version"],
            "number": x.get("versionNumber").cloned().unwrap_or_else(|| Self::arr(a, "versions").find(|v| v["id"] == x["version"]).map_or(Value::Null, |v| v["number"].clone()))})).collect();
        Ok(json!({"asset": asset, "approvals": approvals}))
    }

    /// Review copies with the watermark burned in, made per link: originals are then never offered.
    fn burned(l: &Value) -> bool {
        l["watermark"]["burned"] == true
    }

    fn fetch(&mut self, peer: &str, id: &Value, l: &Value, m: &Value) {
        let Some(fetch) = id.as_u64().filter(|f| *f <= u32::MAX as u64) else { return self.err(peer, id, "invalid") };
        if self.peers[peer].fetches.contains_key(&fetch) {
            return self.err(peer, id, "invalid"); // an id still in flight: its temp file would be lost (#13)
        }
        let what = m["what"].as_str().unwrap_or("").to_owned();
        if what == "proof" {
            return self.fetch_proof(peer, id, l, m);
        }
        match self.resolve(l, m) {
            Ok(Resolved::Inline(j)) => self.send(peer, json!({"re": id, "json": j})),
            Ok(Resolved::File { parts, kind, name, asset, version }) => {
                let length: u64 = parts.iter().map(|p| p.2).sum();
                let mut r = json!({"re": id, "fetch": fetch, "size": length, "type": kind});
                if let Some(n) = name {
                    r["name"] = json!(n);
                }
                if let (Some(r), Some(v)) = (&self.replica, version.as_str()) {
                    r.fetch_start(v);
                    self.peers.get_mut(peer).unwrap().fetches.entry(fetch).or_default().version = Some(v.to_owned());
                }
                if what == "original" || what == "proxy" {
                    let f = self.peers.get_mut(peer).unwrap().fetches.entry(fetch).or_default();
                    f.download = Some((asset, version, what));
                }
                self.send(peer, r);
                let parts: Vec<Value> = parts.into_iter().map(|(path, offset, length)| json!({"path": path, "offset": offset, "length": length})).collect();
                self.cmd(json!({"serve": {"peer": peer, "fetch": fetch, "pieces": parts}}));
            }
            Ok(Resolved::Still { input, t }) => {
                if !rate(&mut self.peers.get_mut(peer).unwrap().stills, Duration::from_secs(60), 60) {
                    return self.err(peer, id, "limit");
                }
                // A frame from the 1080 copy (ffmpeg), served from a temp file deleted once served.
                let tmp = self.data.join("tmp");
                let _ = std::fs::create_dir_all(&tmp);
                let out_path = tmp.join(format!("still-{}.jpg", uuid()));
                self.peers.get_mut(peer).unwrap().fetches.entry(fetch).or_default().temp = Some(out_path.clone());
                let (out, peer, id) = (self.out.clone(), peer.to_owned(), id.clone());
                tokio::spawn(async move {
                    let ok = copies::still(&input, t, &out_path).await;
                    let len = std::fs::metadata(&out_path).map_or(0, |m| m.len());
                    let msg = match ok {
                        Ok(()) if len > 0 => json!({"re": id, "fetch": fetch, "size": len, "type": "image/jpeg"}),
                        _ => json!({"re": id, "error": {"code": "internal"}}),
                    };
                    let good = msg.get("fetch").is_some();
                    let _ = out.send(Ev::Cmd(json!({"send": {"peer": peer, "msg": msg}})));
                    if good {
                        let parts = json!([{"path": out_path.to_string_lossy(), "offset": 0, "length": len}]);
                        let _ = out.send(Ev::Cmd(json!({"serve": {"peer": peer, "fetch": fetch, "pieces": parts}})));
                    } else {
                        let _ = std::fs::remove_file(&out_path);
                    }
                });
            }
            Err("notReady") if self.replica.is_some() => {
                // A backup: recall the copy from the main (head of the queue), or say the main is offline.
                let vid = m["version"].as_str().unwrap_or("");
                match self.replica.as_ref().unwrap().recall(vid) {
                    Some(p) => self.send(peer, json!({"re": id, "error": {"code": "notReady"}, "progress": p})),
                    None => self.err(peer, id, "offline"),
                }
            }
            Err("notReady") => {
                let key = match (Self::burned(l), l["id"].as_str()) {
                    (true, Some(lid)) => format!("{}/wm-{lid}", m["version"].as_str().unwrap_or("")),
                    _ => m["version"].as_str().unwrap_or("").to_owned(),
                };
                let p = self.jobs.get(&key).map_or(json!(0.0), |j| j["progress"].clone());
                self.send(peer, json!({"re": id, "error": {"code": "notReady"}, "progress": p}));
            }
            Err(code) => self.err(peer, id, code),
        }
    }

    /// Map (asset, version, what, rendition, n) to files inside the bundle. Nothing a browser sends
    /// becomes part of a path except values that match the manifest exactly (or a checked number).
    fn resolve(&self, l: &Value, m: &Value) -> Result<Resolved, &'static str> {
        let (_, a) = self.asset_in_scope(l, m["asset"].as_str().ok_or("invalid")?).ok_or("scope")?;
        let v = *Self::versions(l, a).iter().find(|v| v["id"] == m["version"]).ok_or("scope")?;
        let vid = v["id"].as_str().filter(|s| id_ok(s)).ok_or("internal")?;
        let what = m["what"].as_str().ok_or("invalid")?;
        if v["ready"] == false && what != "original" && what != "attachment" {
            return Err("notReady");
        }
        let plain = self.dir.join("copies").join(vid);
        // With a burned-in watermark, the picture comes from this link's own copies.
        let copies = match (Self::burned(l), l["id"].as_str().filter(|s| id_ok(s))) {
            (false, _) => plain.clone(),
            (true, Some(lid)) => {
                let d = plain.join(format!("wm-{lid}"));
                let made_here = v["source"].is_string();
                let ready = if made_here { d.join("ready.json").is_file() } else { d.is_dir() };
                if !ready && ["index", "init", "segment", "poster", "strip", "image", "proxy", "still"].contains(&what) {
                    return Err("notReady");
                }
                d
            }
            (true, None) => return Err("internal"),
        };
        let (asset, version) = (a["id"].clone(), v["id"].clone());
        let file = |p: PathBuf, kind: &str, name: Option<String>| -> Result<Resolved, &'static str> {
            let length = std::fs::metadata(&p).ok().filter(|m| m.is_file()).ok_or("notFound")?.len();
            Ok(Resolved::File { parts: vec![(p.to_string_lossy().into(), 0, length)], kind: kind.into(), name, asset: asset.clone(), version: version.clone() })
        };
        let inline = |p: PathBuf| -> Result<Resolved, &'static str> {
            let b = std::fs::read(p).map_err(|_| "notFound")?;
            Ok(Resolved::Inline(serde_json::from_slice(&b).map_err(|_| "internal")?))
        };
        let index = |r: &str| -> Result<(PathBuf, Value), &'static str> {
            let r = Self::arr(v, "renditions").filter_map(Value::as_str).find(|x| *x == r && id_ok(x)).ok_or("invalid")?;
            let dir = copies.join(r);
            let index: Value = std::fs::read(dir.join("index.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).ok_or("notReady")?;
            Ok((dir, index))
        };
        let piece = |dir: &Path, part: &Value| -> Result<crate::media::Part, &'static str> {
            let f = part["file"].as_str().filter(|f| !f.contains('/') && safe_rel(f).is_some()).ok_or("internal")?;
            let (Some(offset), Some(length)) = (part["offset"].as_u64(), part["length"].as_u64()) else { return Err("internal") };
            Ok((dir.join(f).to_string_lossy().into(), offset, length))
        };
        let av = if a["kind"] == "audio" { "audio/mp4" } else { "video/mp4" };
        match what {
            "poster" | "strip" | "image" => file(copies.join(format!("{what}.jpg")), "image/jpeg", None),
            "original" => {
                if !is(l, "allowDownload") || Self::burned(l) {
                    return Err("scope");
                }
                let name = v["originalName"].as_str().map(|s| clean(s, 200));
                let path = match v["source"].as_str() {
                    Some(src) => self.resolve_media(src).ok_or("notFound")?,
                    None => self.dir.join(v["original"].as_str().and_then(safe_rel).ok_or("notFound")?),
                };
                file(path, "application/octet-stream", name)
            }
            "index" | "init" | "segment" => {
                let (dir, index) = index(m["rendition"].as_str().ok_or("invalid")?)?;
                if what == "index" {
                    return Ok(Resolved::Inline(index));
                }
                let part = if what == "init" {
                    &index["init"]
                } else {
                    let n = m["n"].as_u64().ok_or("invalid")? as usize;
                    index["segments"].get(n).ok_or("notFound")?
                };
                Ok(Resolved::File { parts: vec![piece(&dir, part)?], kind: av.into(), name: None, asset, version })
            }
            "proxy" => {
                // The fMP4 review copy as one MP4 file: init, then every segment's bytes back to back.
                if !is(l, "allowProxy") {
                    return Err("scope");
                }
                let r = m["rendition"].as_str().unwrap_or(if a["kind"] == "audio" { "a" } else { "1080" });
                let (dir, index) = index(r)?;
                let segs = index["segments"].as_array().filter(|s| !s.is_empty()).ok_or("notReady")?;
                let mut parts = vec![piece(&dir, &index["init"])?];
                for s in segs {
                    let p = piece(&dir, s)?;
                    match parts.last_mut() {
                        Some(last) if last.0 == p.0 && last.1 + last.2 == p.1 => last.2 += p.2,
                        _ => parts.push(p),
                    }
                }
                let ext = if a["kind"] == "audio" { "m4a" } else { "mp4" };
                let name = format!("{} v{} (review).{ext}", clean(a["name"].as_str().unwrap_or("Review"), 160), v["number"].as_i64().unwrap_or(1));
                Ok(Resolved::File { parts, kind: av.into(), name: Some(name), asset, version })
            }
            "still" => {
                if a["kind"] == "image" {
                    return file(copies.join("image.jpg"), "image/jpeg", None);
                }
                let frame = m["frame"].as_u64().ok_or("invalid")?;
                if a["kind"] != "video" || frame >= v["frames"].as_u64().unwrap_or(0) {
                    return Err("invalid");
                }
                let (num, den) = (v["fpsNum"].as_f64().unwrap_or(25.0).max(1.0), v["fpsDen"].as_f64().unwrap_or(1.0).max(1.0));
                let (dir, _) = index("1080").or_else(|_| index("540"))?;
                Ok(Resolved::Still { input: dir.join("index.m3u8"), t: frame as f64 * den / num })
            }
            "waveform" => inline(plain.join("waveform.json")),
            "transcript" => inline(plain.join("transcript.json")),
            "captions" => file(plain.join("captions.vtt"), "text/vtt", None),
            "page" => {
                let n = m["n"].as_u64().filter(|n| *n >= 1 && *n <= v["pages"].as_u64().unwrap_or(0)).ok_or("invalid")?;
                file(plain.join("pages").join(format!("{n}.jpg")), "image/jpeg", None)
            }
            "attachment" => {
                // Only an attachment of a comment this link may see, on this version. The id goes in
                // "attachment": §3.4's "id" is already the request id.
                let att = m["attachment"].as_str().ok_or("invalid")?;
                let c = self.comments.iter().find(|c| c["version"] == v["id"] && Self::visible(l, c)
                    && Self::arr(c, "attachments").any(|x| x["id"] == att)).ok_or("notFound")?;
                let meta = Self::arr(c, "attachments").find(|x| x["id"] == att).ok_or("notFound")?;
                let path = match self.attachments.get(att) {
                    Some(u) => self.data.join(u["path"].as_str().and_then(safe_rel).filter(|p| p.starts_with("uploads")).ok_or("notFound")?),
                    None => self.dir.join("attachments").join(Some(att).filter(|a| id_ok(a)).ok_or("notFound")?), // pushed by the editor
                };
                let kind = meta["type"].as_str().filter(|t| ["image/jpeg", "image/png", "image/webp", "application/pdf", "text/plain"].contains(t)).unwrap_or("application/octet-stream");
                file(path, kind, meta["name"].as_str().map(display_name))
            }
            _ => Err("invalid"),
        }
    }

    fn comments(&self, peer: &str, l: &Value, m: &Value) -> Result<Value, &'static str> {
        let (_, a) = self.asset_in_scope(l, m["asset"].as_str().ok_or("invalid")?).ok_or("scope")?;
        Self::versions(l, a).iter().find(|v| v["id"] == m["version"]).ok_or("scope")?;
        let toks = Self::toks(&self.peers[peer]);
        let list: Vec<Value> = self.comments.iter().filter(|c| c["asset"] == a["id"] && c["version"] == m["version"] && Self::visible(l, c))
            .map(|c| Self::wire_comment(c, toks, team(l))).collect();
        Ok(json!({"comments": list}))
    }

    fn drawing_ok(d: &Value) -> bool {
        if d.is_null() {
            return true;
        }
        let Some(strokes) = d["strokes"].as_array() else { return false };
        let points: usize = strokes.iter().map(|s| s["points"].as_array().map_or(0, Vec::len)).sum();
        strokes.len() <= 64 && points <= 2000 && strokes.iter().all(|s| {
            let tool = s["tool"].as_str().unwrap_or("");
            let pts = s["points"].as_array();
            ["pen", "arrow", "line", "rect", "ellipse"].contains(&tool)
                && PALETTE.iter().any(|c| s["colour"].as_str().is_some_and(|x| x.eq_ignore_ascii_case(c)))
                && s["width"].as_f64().is_some_and(|w| (0.002..=0.02).contains(&w))
                && pts.is_some_and(|p| !p.is_empty() && (tool == "pen" || p.len() == 2) && p.iter().all(|xy| {
                    xy.as_array().is_some_and(|xy| xy.len() == 2 && xy.iter().all(|c| c.as_f64().is_some_and(|c| (0.0..=1.0).contains(&c))))
                }))
        })
    }

    /// Comment and approval writes: validated, appended to comments.jsonl, then pushed to every ready
    /// client whose link holds the asset.
    fn write(&mut self, peer: &str, t: &str, l: &Value, m: &Value) -> Result<Value, &'static str> {
        // Signed in: what they write carries the account token, and what either token wrote is theirs (§1.7).
        let (tok, browser, name) = { let p = &self.peers[peer]; (p.acct.token.clone().or(p.token.clone()), p.token.clone(), p.name.clone()) };
        let toks = [tok.as_deref(), browser.as_deref()];
        // Comments, replies (drawings too) and approvals carry a name: the page asks for one on `needName`.
        if name.is_empty() && matches!(t, "comment-add" | "reply-add" | "approve") {
            return Err("needName");
        }
        let author = if name.is_empty() { "Guest".to_owned() } else { name };
        let text = clean(m["text"].as_str().unwrap_or(""), 2001);
        let text_ok = (1..=2000).contains(&text.chars().count());
        // The comment a request names, if the link can see it.
        let find = |h: &Host| -> Result<Value, &'static str> {
            let c = h.comments.iter().find(|c| c["id"] == m["comment"]).ok_or("notFound")?;
            if !Self::visible(l, c) {
                return Err("notFound"); // a client link never learns an internal comment exists
            }
            let (_, a) = h.asset_in_scope(l, c["asset"].as_str().unwrap_or("")).ok_or("scope")?;
            Self::versions(l, a).iter().find(|v| v["id"] == c["version"]).ok_or("scope")?;
            Ok(c.clone())
        };
        let own = |x: &Value| x["authorToken"].as_str().is_some_and(|a| toks.contains(&Some(a)));
        let mentions = if matches!(t, "comment-add" | "reply-add") { self.mention_ids(l, m) } else { vec![] };
        // Every write (add, edit, complete, delete, approve, react): 30 a minute per peer.
        if !rate(&mut self.peers.get_mut(peer).unwrap().writes, Duration::from_secs(60), 30) {
            return Err("limit");
        }
        let (asset, entry, op) = match t {
            "comment-add" => {
                // The same browser sending again after its answer was lost (same cid): the stored comment, kept once.
                let cid = m["cid"].as_str().filter(|c| (8..=64).contains(&c.len()) && c.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
                if let Some(c) = cid.and_then(|cid| self.comments.iter().find(|c| c["cid"] == cid && own(c))) {
                    return Ok(json!({"comment": Self::wire_comment(c, toks, team(l))}));
                }
                let (_, a) = self.asset_in_scope(l, m["asset"].as_str().ok_or("invalid")?).ok_or("scope")?;
                let v = *Self::versions(l, a).iter().find(|v| v["id"] == m["version"]).ok_or("scope")?;
                let frames = v["frames"].as_i64().unwrap_or(1).max(1);
                // frame: null is a general comment (no timecode); documents stamp a page instead.
                let (frame, end) = match m["frame"].as_i64() {
                    _ if m["frame"].is_null() => (None, None),
                    Some(f) => (Some(f), m["endFrame"].as_i64()),
                    None => return Err("invalid"),
                };
                let range_ok = match frame {
                    Some(f) => (0..frames).contains(&f) && end.is_none_or(|e| e >= f && e < frames),
                    None => m["endFrame"].is_null(),
                };
                let page = m["page"].as_i64();
                let page_ok = m["page"].is_null() || (frame.is_none() && a["kind"] == "document" && page.is_some_and(|p| p >= 1 && p <= v["pages"].as_i64().unwrap_or(0)));
                let anchor_ok = m["anchor"].is_null() || m["anchor"].as_array().is_some_and(|xy| xy.len() == 2 && xy.iter().all(|c| c.as_f64().is_some_and(|c| (0.0..=1.0).contains(&c))));
                if !text_ok || !range_ok || !page_ok || !anchor_ok || !Self::drawing_ok(&m["drawing"]) {
                    return Err("invalid");
                }
                let internal = is(m, "internal");
                if internal && !team(l) {
                    return Err("scope");
                }
                // Attachments: ≤ 6 files this link uploaded (upload-end ids).
                let ids: Vec<&str> = Self::arr(m, "attachments").filter_map(Value::as_str).collect();
                if ids.len() > 6 || ids.len() != Self::arr(m, "attachments").count() {
                    return Err("invalid");
                }
                let attachments: Vec<Value> = ids.iter().map(|id| {
                    let u = self.attachments.get(*id).filter(|u| u["link"] == l["id"]).ok_or("invalid")?;
                    Ok(json!({"id": u["id"], "name": u["name"], "size": u["size"], "type": u["type"]}))
                }).collect::<Result<_, &'static str>>()?;
                if self.comments.iter().filter(|c| c["version"] == v["id"]).count() >= 2000 {
                    return Err("limit");
                }
                let mut c = json!({"id": uuid(), "asset": a["id"], "version": v["id"], "frame": frame, "endFrame": end,
                    "text": text, "author": author, "authorToken": tok, "link": l["id"],
                    "drawing": if m["drawing"].is_null() { Value::Null } else { m["drawing"].clone() },
                    "replies": [], "completed": false, "created": now_iso()});
                for (k, x) in [("page", json!(page)), ("anchor", m["anchor"].clone()), ("attachments", json!(attachments))] {
                    if !x.is_null() && x != json!([]) {
                        c[k] = x;
                    }
                }
                if internal {
                    c["internal"] = json!(true);
                }
                if !mentions.is_empty() {
                    c["mentions"] = json!(mentions);
                }
                if let Some(cid) = cid {
                    c["cid"] = json!(cid);
                }
                (a["id"].clone(), json!({"comment": c}), "add")
            }
            "reply-add" => {
                let mut c = find(self)?;
                if !text_ok || c["replies"].as_array().map_or(0, Vec::len) >= 100 {
                    return Err(if text_ok { "limit" } else { "invalid" });
                }
                let mut r = json!({"id": uuid(), "text": text, "author": author, "authorToken": tok, "created": now_iso()});
                // An internal reply (team links only) in a visible thread: clients keep the thread, never see the reply.
                if is(m, "internal") {
                    if !team(l) {
                        return Err("scope");
                    }
                    r["internal"] = json!(true);
                }
                if !mentions.is_empty() {
                    r["mentions"] = json!(mentions);
                }
                c["replies"].as_array_mut().ok_or("internal")?.push(r);
                (c["asset"].clone(), json!({"comment": c}), "edit")
            }
            "comment-edit" => {
                let mut c = find(self)?;
                if !text_ok {
                    return Err("invalid");
                }
                match m["reply"].as_str() {
                    Some(rid) => {
                        let r = c["replies"].as_array_mut().and_then(|rs| rs.iter_mut().find(|r| r["id"] == rid)).ok_or("notFound")?;
                        if !own(r) { return Err("scope") }
                        r["text"] = json!(text);
                    }
                    None => {
                        if !own(&c) { return Err("scope") }
                        c["text"] = json!(text);
                        c["edited"] = json!(now_iso());
                    }
                }
                (c["asset"].clone(), json!({"comment": c}), "edit")
            }
            "comment-delete" => {
                let mut c = find(self)?;
                match m["reply"].as_str() {
                    Some(rid) => {
                        let rs = c["replies"].as_array_mut().ok_or("internal")?;
                        let i = rs.iter().position(|r| r["id"] == rid).ok_or("notFound")?;
                        if !own(&rs[i]) { return Err("scope") }
                        let gone = rs.remove(i);
                        if !c["deletedReplies"].is_array() {
                            c["deletedReplies"] = json!([]);
                        }
                        c["deletedReplies"].as_array_mut().unwrap().push(gone["id"].clone()); // so a merge doesn't bring it back
                        (c["asset"].clone(), json!({"comment": c}), "edit")
                    }
                    None => {
                        if !own(&c) { return Err("scope") }
                        (c["asset"].clone(), json!({"deleted": {"id": c["id"], "asset": c["asset"], "version": c["version"]}}), "delete")
                    }
                }
            }
            "comment-complete" => {
                let mut c = find(self)?;
                c["completed"] = json!(m["completed"].as_bool().ok_or("invalid")?);
                (c["asset"].clone(), json!({"comment": c}), "edit")
            }
            "react" => {
                let mut c = find(self)?;
                let e = m["emoji"].as_str().filter(|e| EMOJI.contains(e)).ok_or("invalid")?;
                let who = json!(tok.clone().ok_or("invalid")?);
                if !c["reactions"].is_object() {
                    c["reactions"] = json!({});
                }
                let list = c["reactions"].as_object_mut().unwrap().entry(e).or_insert(json!([]));
                let l2 = list.as_array_mut().ok_or("internal")?;
                l2.retain(|w| *w != who && !w.as_str().is_some_and(|w| toks.contains(&Some(w)))); // either token: one reaction
                if m["on"].as_bool().ok_or("invalid")? {
                    l2.push(who);
                }
                (c["asset"].clone(), json!({"comment": c}), "edit")
            }
            _ => {
                // approve: the status field, so only where reviewers may set status (old links: always).
                if !team(l) && l.get("featuredField").is_some_and(|f| f != "status") {
                    return Err("scope");
                }
                let (_, a) = self.asset_in_scope(l, m["asset"].as_str().ok_or("invalid")?).ok_or("scope")?;
                Self::versions(l, a).iter().find(|v| v["id"] == m["version"]).ok_or("scope")?;
                let d = m["decision"].as_str().filter(|d| *d == "approve" || *d == "changes").ok_or("invalid")?;
                let ap = self.approval_record(peer, l, a, &m["version"], d, &author);
                (a["id"].clone(), json!({"approval": ap}), "status")
            }
        };
        // Whether it's internal, from the comment as it was (a delete only names the id).
        let hidden = match t {
            "comment-add" => is(&entry["comment"], "internal"),
            "approve" => false,
            _ => self.comments.iter().find(|c| c["id"] == m["comment"]).is_some_and(|c| is(c, "internal")),
        };
        // Every write the host makes carries its rev (§13.0): one above the comment it replaces.
        let mut entry = entry;
        for k in ["comment", "deleted"] {
            if let Some(x) = entry.get_mut(k) {
                let prev = self.comments.iter().find(|c| c["id"] == x["id"]).and_then(|c| c["rev"].as_u64()).unwrap_or(0);
                x["rev"] = json!(prev + 1);
                x["at"] = json!(now_iso());
                x["by"] = json!(self.ident.by());
            }
        }
        let before = self.comments.iter().find(|c| c["id"] == entry["comment"]["id"]).cloned();
        if !self.append(entry.clone()) {
            return Err("internal");
        }
        match t {
            "comment-add" | "reply-add" => self.mail_comment(before.as_ref(), &entry["comment"]),
            "approve" => self.mail_approval(&entry["approval"]),
            _ => {}
        }
        match t {
            "comment-add" => self.activity(peer, "commented", asset.clone(), entry["comment"]["version"].clone(), json!({"comment": entry["comment"]["id"]})),
            "reply-add" => self.activity(peer, "commented", asset.clone(), entry["comment"]["version"].clone(), json!({"comment": entry["comment"]["id"], "reply": true})),
            "approve" => self.activity(peer, "approved", asset.clone(), entry["approval"]["version"].clone(), json!({"decision": entry["approval"]["decision"]})),
            _ => {}
        }
        let asset = asset.as_str().unwrap_or("").to_owned();
        let version = ["comment", "deleted", "approval"].iter().find_map(|k| entry.get(*k)).map_or(Value::Null, |x| x["version"].clone());
        // Tell everyone whose link holds the asset (each sees its own "mine"); internal ones go to team links only.
        for (id, p) in &self.peers {
            let Some(pl) = self.peer_link(p) else { continue };
            let seen = if op == "status" { self.asset_in_scope(&pl, &asset).is_some() } else { self.sees(&pl, &asset, &version) };
            if !p.ready || !seen || (hidden && !team(&pl)) {
                continue;
            }
            let ev = match op {
                "status" => json!({"t": "status", "asset": asset, "status": self.status.get(&asset), "by": author, "approval": entry["approval"]["id"]}),
                "delete" => json!({"t": "comment", "op": "delete", "comment": entry["deleted"]}),
                _ => json!({"t": "comment", "op": op, "comment": Self::wire_comment(&entry["comment"], Self::toks(p), team(&pl))}),
            };
            if id != peer {
                self.send(id, ev);
            }
        }
        Ok(match op {
            "status" => {
                let a = self.asset_in_scope(l, &asset).map(|(_, a)| self.summary(l, a));
                json!({"status": self.status.get(&asset), "approval": {"id": entry["approval"]["id"], "decision": entry["approval"]["decision"], "proof": true},
                    "asset": a})
            }
            "delete" => json!({"deleted": entry["deleted"]["id"]}),
            _ => json!({"comment": Self::wire_comment(&entry["comment"], toks, team(l))}),
        })
    }

    /// A reviewer sets the link's featured field (team links: any field). Status approved/needs
    /// changes is also an Approval, so `approve` and the editor's approvals keep working.
    fn field_set(&mut self, peer: &str, l: &Value, m: &Value) -> Result<Value, &'static str> {
        let (_, a) = self.asset_in_scope(l, m["asset"].as_str().ok_or("invalid")?).ok_or("scope")?;
        let a = a.clone();
        let field = m["field"].as_str().ok_or("invalid")?;
        let featured = match l.get("featuredField") { None => Some("status"), Some(f) => f.as_str() };
        if !team(l) && featured != Some(field) {
            return Err("scope");
        }
        let x = &m["value"];
        let date = |d: &str| d.len() == 10 && d.bytes().enumerate().all(|(i, b)| if i == 4 || i == 7 { b == b'-' } else { b.is_ascii_digit() });
        let value = match field {
            "status" => json!(x.as_str().filter(|s| STATUSES.contains(s)).ok_or("invalid")?),
            "rating" => json!(x.as_u64().filter(|r| *r <= 5).ok_or("invalid")?),
            "keywords" => json!(x.as_array().ok_or("invalid")?.iter().filter_map(Value::as_str).map(|k| clean(k, 40)).filter(|k| !k.is_empty()).take(20).collect::<Vec<_>>()),
            "assignee" => json!(clean(x.as_str().ok_or("invalid")?, 80)),
            "due" if x.is_null() => Value::Null,
            "due" => json!(x.as_str().filter(|d| date(d)).ok_or("invalid")?),
            "notes" => json!(clean(x.as_str().ok_or("invalid")?, 2000)),
            // A custom field (4.1) the link names in `fieldDefs` (a client link: also in `fields`); the Mac checks the
            // value by its kind when it syncs.
            f if f.starts_with("cf:") && Self::arr(l, "fieldDefs").any(|d| d["id"] == f) && (team(l) || Self::arr(l, "fields").any(|x| x == f)) => {
                if x.is_null() { Value::Null } else { json!(clean(x.as_str().ok_or("invalid")?, 2000)) }
            }
            _ => return Err("invalid"),
        };
        if !rate(&mut self.peers.get_mut(peer).unwrap().writes, Duration::from_secs(60), 30) {
            return Err("limit");
        }
        let name = self.peers[peer].name.clone();
        let author = if name.is_empty() { "Guest".to_owned() } else { name };
        let version = Self::versions(l, &a).iter().find(|v| v["id"] == m["version"]).or(Self::versions(l, &a).last()).map(|v| v["id"].clone()).unwrap_or_default();
        let approval = field == "status" && (value == "approved" || value == "needsChanges");
        let entry = if approval {
            json!({"approval": self.approval_record(peer, l, &a, &version, if value == "approved" { "approve" } else { "changes" }, &author)})
        } else {
            json!({"field": {"id": uuid(), "asset": a["id"], "field": field, "value": value, "by": author, "link": l["id"], "at": now_iso()}})
        };
        if !self.append(entry.clone()) {
            return Err("internal");
        }
        if approval {
            self.activity(peer, "approved", a["id"].clone(), version, json!({"decision": entry["approval"]["decision"]}));
        }
        let aid = a["id"].as_str().unwrap_or("").to_owned();
        for (id, p) in &self.peers {
            let Some(pl) = self.peer_link(p) else { continue };
            if id == peer || !p.ready || self.asset_in_scope(&pl, &aid).is_none() {
                continue;
            }
            if field == "status" {
                let mut ev = json!({"t": "status", "asset": aid, "status": value, "by": author});
                if approval {
                    ev["approval"] = entry["approval"]["id"].clone();
                }
                self.send(id, ev);
            }
            if field == "status" || team(&pl) || Self::arr(&pl, "fields").any(|f| f == field) {
                self.send(id, json!({"t": "field", "asset": aid, "field": field, "value": value, "by": author}));
            }
        }
        Ok(json!({"asset": self.summary(l, &a)}))
    }

    /// An approval as stored (§13.8): who, which version, the original's file name and hash.
    fn approval_record(&self, peer: &str, l: &Value, a: &Value, version: &Value, decision: &str, author: &str) -> Value {
        let v = Self::arr(a, "versions").find(|v| v["id"] == *version);
        let file = v.and_then(|v| v["originalName"].as_str().or_else(|| v["source"].as_str()?.rsplit('/').next())
            .or_else(|| v["original"].as_str()?.rsplit('/').next())).map(str::to_owned).unwrap_or_else(|| a["name"].as_str().unwrap_or("").to_owned());
        let sha = v.and_then(|v| v["sha256"].as_str()).map(str::to_owned);
        let mut ap = json!({"id": uuid(), "asset": a["id"], "version": version, "decision": decision, "author": author,
            "link": l["id"], "created": now_iso(), "versionNumber": v.map_or(json!(1), |v| v["number"].clone()), "file": file,
            "sha256": sha, "hashOf": if sha.is_some() { json!("original") } else { Value::Null }});
        if let Some(e) = self.peers.get(peer).map(|p| p.email.clone()).filter(|e| !e.is_empty()) {
            ap["email"] = json!(e);
        }
        ap
    }

    /// Approvals this link may see for an asset: its own, or all of them on a team link.
    fn approvals_of(&self, l: &Value, asset: &Value) -> Vec<&Value> {
        self.approvals.iter().filter(|x| x["asset"] == *asset && (team(l) || x["link"] == l["id"])).collect()
    }

    /// The hash a proof needs: stored with the approval, else the version's (manifest or copy
    /// job), else worked out now — the original when this host has it, else the review copy.
    fn proof_hash(&mut self, ap: &Value) -> Result<(String, String), &'static str> {
        if let Some(h) = ap["sha256"].as_str() {
            return Ok((h.to_owned(), ap["hashOf"].as_str().unwrap_or("original").to_owned()));
        }
        let aid = ap["id"].as_str().unwrap_or("").to_owned();
        if let Some(h) = self.proof_hashes.get(&aid).cloned() {
            return match (h["sha256"].as_str(), h["hashOf"].as_str()) {
                (Some(s), Some(o)) => Ok((s.to_owned(), o.to_owned())),
                _ if h["failed"] == true => {
                    self.proof_hashes.remove(&aid); // reported once; the next fetch tries again
                    Err("internal")
                }
                _ => Err("notReady"),
            };
        }
        let v = self.manifest["projects"].as_array().into_iter().flatten().flat_map(|p| Self::arr(p, "assets"))
            .flat_map(|a| Self::arr(a, "versions")).find(|v| v["id"] == ap["version"]).cloned().ok_or("notFound")?;
        if let Some(h) = v["sha256"].as_str() {
            return Ok((h.to_owned(), "original".into()));
        }
        let original = match (v["source"].as_str(), v["original"].as_str().and_then(safe_rel)) {
            (Some(src), _) if !self.ident.backup => self.resolve_media(src),
            (None, Some(rel)) => Some(self.dir.join(rel)).filter(|p| p.is_file()),
            _ => None,
        };
        let vid = v["id"].as_str().filter(|s| id_ok(s)).ok_or("internal")?;
        let (path, of) = match original {
            Some(p) => (p, "original"),
            None => {
                // (The 1080 copy, as before 4K: "2160"/"2160h" are left out.)
                let top = Self::arr(&v, "renditions").filter_map(Value::as_str).filter(|r| id_ok(r) && r.parse::<u64>().is_ok_and(|n| n <= 1080))
                    .max_by_key(|r| r.parse::<u64>().unwrap_or(0)).ok_or("notReady")?;
                (self.dir.join("copies").join(vid).join(top).join("media.m4s"), "copy")
            }
        };
        self.proof_hashes.insert(aid.clone(), json!({"making": true}));
        let back = self.back.clone();
        tokio::task::spawn_blocking(move || {
            let r = sha256_file(&path).map_or(json!({"failed": true}), |h| json!({"sha256": h, "hashOf": of}));
            if let Some(b) = back {
                let _ = b.send((format!("proof:{aid}"), r));
            }
        });
        Err("notReady")
    }

    /// `fetch` of `what:"proof"`: the approval's PDF, made now and served from a temp file.
    fn fetch_proof(&mut self, peer: &str, id: &Value, l: &Value, m: &Value) {
        let Some(fetch) = id.as_u64().filter(|f| *f <= u32::MAX as u64) else { return self.err(peer, id, "invalid") };
        let Some(ap) = self.approvals.iter().find(|x| x["id"] == m["approval"]).cloned() else { return self.err(peer, id, "notFound") };
        if !(team(l) || ap["link"] == l["id"]) || self.asset_in_scope(l, ap["asset"].as_str().unwrap_or("")).is_none() {
            return self.err(peer, id, "scope");
        }
        let (sha, of) = match self.proof_hash(&ap) {
            Ok(h) => h,
            Err("notReady") => return self.send(peer, json!({"re": id, "error": {"code": "notReady"}, "progress": 0.0})),
            Err(c) => return self.err(peer, id, c),
        };
        let (p, a) = self.asset_in_scope(l, ap["asset"].as_str().unwrap_or("")).unwrap();
        let link_of = self.links().find(|x| x["id"] == ap["link"]).unwrap_or(l);
        let pr = crate::proof::Proof {
            project: p["name"].as_str().unwrap_or("").into(), asset: a["name"].as_str().unwrap_or("").into(),
            version: ap["versionNumber"].as_i64().unwrap_or(1), file: ap["file"].as_str().unwrap_or("").into(), sha256: sha, hash_of: of,
            decision: ap["decision"].as_str().unwrap_or("").into(), name: ap["author"].as_str().unwrap_or("").into(),
            email: ap["email"].as_str().map(str::to_owned), time: ap["created"].as_str().unwrap_or("").into(),
            link_title: link_of["title"].as_str().unwrap_or("").into(), link: ap["link"].as_str().unwrap_or("").into(),
            approval: ap["id"].as_str().unwrap_or("").into(), served_by: self.ident.name.clone(), generated: now_iso(),
        };
        let tmp = self.data.join("tmp");
        let path = tmp.join(format!("proof-{}.pdf", uuid()));
        let bytes = pr.pdf();
        if std::fs::create_dir_all(&tmp).and_then(|_| std::fs::write(&path, &bytes)).is_err() {
            return self.err(peer, id, "internal");
        }
        self.peers.get_mut(peer).unwrap().fetches.entry(fetch).or_default().temp = Some(path.clone());
        let name = format!("{} – {} v{}.pdf", if pr.decision == "approve" { "Approval" } else { "Changes requested" }, clean(&pr.asset, 120), pr.version);
        self.send(peer, json!({"re": id, "fetch": fetch, "size": bytes.len(), "type": "application/pdf", "name": name}));
        self.cmd(json!({"serve": {"peer": peer, "fetch": fetch, "pieces": [{"path": path.to_string_lossy(), "offset": 0, "length": bytes.len()}]}}));
    }

    // ---- uploads from browsers (host mode): into <data>/uploads/<linkID>/, a quarantine ----

    /// `upload-begin`: checked against the link's upload settings and limits, then the helper is
    /// told to accept the bytes (before the reply, so it knows the id when the first frame comes).
    fn upload_begin(&mut self, peer: &str, id: &Value, l: &Value, m: &Value) {
        let into_ok = self.into_dir(&l["uploads"]["into"], false).is_some();
        let r = (|| -> Result<(u64, HUp), &'static str> {
            // A backup takes them only while its main can take them on afterwards (§13.25; a 4.0.3 main can't: off, §13.3).
            let backup_ok = self.outage.as_ref().is_some_and(|o| o.accepting());
            let up = l["uploads"].as_object().filter(|_| !self.ident.backup || backup_ok).ok_or("scope")?;
            let lid = l["id"].as_str().filter(|s| id_ok(s)).ok_or("internal")?.to_owned();
            let uid = id.as_u64().filter(|u| *u <= u32::MAX as u64).ok_or("invalid")?;
            let attachment = match m["for"].as_str() { Some("asset") => false, Some("attachment") => true, _ => return Err("invalid") };
            let name = display_name(m["name"].as_str().unwrap_or(""));
            let ext = Path::new(&name).extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase)
                .filter(|e| (1..=8).contains(&e.len()) && e.bytes().all(|b| b.is_ascii_alphanumeric())).ok_or("invalid")?;
            let (cat, mime) = upload_kind(&ext).ok_or("invalid")?;
            let types: Vec<&str> = up.get("types").and_then(Value::as_array).map_or(vec!["video", "audio", "image", "document", "other"], |t| t.iter().filter_map(Value::as_str).collect());
            if name.is_empty() || !types.contains(&cat) {
                return Err("invalid");
            }
            // Asset uploads into a folder of a media root (a backup has none: its main's Pluck places them).
            let into = match up.get("into") {
                Some(i) if !i.is_null() && !attachment && !self.ident.backup => if into_ok { i.clone() } else { return Err("scope") },
                _ => Value::Null,
            };
            let size = m["size"].as_u64().ok_or("invalid")?;
            let cap = if attachment { MAX_ATTACHMENT } else { up.get("maxBytes").and_then(Value::as_u64).unwrap_or(MAX_UPLOAD).min(crate::sync::MAX_PUT) };
            if size > cap {
                return Err("tooLarge");
            }
            if self.uploads.contains_key(&(peer.to_owned(), uid)) {
                return Err("invalid");
            }
            if self.busy.preparing() {
                return Err("limit"); // an update waits (§13.15)
            }
            if self.uploads.values().filter(|u| u.link == lid).count() >= UPLOADS_IN_FLIGHT {
                return Err("limit");
            }
            if !rate(self.up_hour.entry(lid.clone()).or_default(), Duration::from_secs(3600), UPLOADS_PER_HOUR) {
                return Err("limit");
            }
            let dir = self.data.join("uploads").join(".partial");
            std::fs::create_dir_all(&dir).map_err(|_| "internal")?;
            // 10 GB stay free for comments.jsonl and the manifest; can't tell = refuse.
            if crate::upload_root::free_space(&dir).unwrap_or(0) < size.saturating_add(LINK_UPLOAD_RESERVE) {
                return Err("limit");
            }
            Ok((uid, HUp { link: lid, name, ext, kind: mime.into(), size, attachment, part: dir.join(format!("{}.part", uuid())), sha: None, end: None, into }))
        })();
        match r {
            Ok((uid, u)) => {
                self.cmd(json!({"accept": {"peer": peer, "upload": uid, "path": u.part.to_string_lossy(), "size": u.size}}));
                self.send(peer, json!({"re": id, "upload": uid, "credit": crate::media::UP_CREDIT}));
                self.uploads.insert((peer.to_owned(), uid), u);
            }
            Err(code) => self.err(peer, id, code),
        }
    }

    /// `upload-end`: answered once the helper has every byte on disk and the hashes match.
    fn upload_end(&mut self, peer: &str, id: &Value, m: &Value) {
        let key = (peer.to_owned(), m["upload"].as_u64().unwrap_or(u64::MAX));
        let (Some(u), Some(sha)) = (self.uploads.get_mut(&key), m["sha256"].as_str()) else { return self.err(peer, id, "invalid") };
        if u.end.is_some() {
            return self.err(peer, id, "invalid");
        }
        u.end = Some((id.clone(), sha.to_owned()));
        if u.sha.is_some() {
            self.finish_upload(&key);
        }
    }

    fn finish_upload(&mut self, key: &(String, u64)) {
        let Some(u) = self.uploads.remove(key) else { return };
        let Some((id, theirs)) = u.end.clone() else { return };
        let peer = key.0.as_str();
        if u.sha.as_deref() != Some(theirs.as_str()) {
            let _ = std::fs::remove_file(&u.part);
            return self.err(peer, &id, "invalid");
        }
        let fid = uuid();
        let rel = format!("uploads/{}/{fid}.{}", u.link, u.ext);
        let dest = self.data.join(&rel);
        let moved = dest.parent().map_or(Ok(()), std::fs::create_dir_all).and_then(|_| std::fs::rename(&u.part, &dest));
        if moved.is_err() {
            let _ = std::fs::remove_file(&u.part);
            return self.err(peer, &id, "internal");
        }
        let by = self.peers.get(peer).map(|p| p.name.clone()).unwrap_or_default();
        let mut entry = json!({"id": fid, "link": u.link, "name": u.name, "path": rel, "size": u.size, "sha256": theirs, "type": u.kind,
            "for": if u.attachment { "attachment" } else { "asset" }, "by": by, "at": now_iso()});
        if !u.into.is_null() {
            entry["into"] = u.into.clone();
            if let Some((dir, name)) = self.place_target(&u, &fid) {
                let (root, folder) = (u.into["root"].as_str().unwrap_or("").to_owned(), u.into["folder"].as_str().unwrap_or("").to_owned());
                let place = move || crate::upload_root::place(&dest, &dir, &name)
                    .map_err(|e| log(format!("host: upload {fid} stays in the quarantine: {e}"))).ok()
                    .map(|p| if folder.is_empty() { format!("{root}/{p}") } else { format!("{root}/{folder}/{p}") });
                let Some(back) = self.back.clone() else { return self.record_upload(peer, &id, Self::with_placed(entry, place()), u) };
                // Another dataset means a whole copy (up to 256 GB): off the host task, which keeps answering meanwhile;
                // the entry is logged and the browser answered when it's done (a switch waits for it).
                let busy = self.busy.clone();
                busy.transfers.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let fid = entry["id"].as_str().unwrap_or("").to_owned();
                self.placing.insert(fid.clone(), (peer.to_owned(), id, entry, u));
                tokio::task::spawn_blocking(move || {
                    let _ = back.send((format!("place:{fid}"), place().map_or(Value::Null, Value::String)));
                    busy.transfers.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
                });
                return;
            }
        }
        self.record_upload(peer, &id, entry, u);
    }

    /// Where an upload went: `placed` "<root>/<folder>/<name>" (moved out of the quarantine). `root` + `path` say it the way a
    /// 4.0.6 Mac reads (it adds such an entry by reference instead of fetching a quarantine file that's gone).
    fn with_placed(mut entry: Value, placed: Option<String>) -> Value {
        if let Some(p) = placed {
            entry["placed"] = json!(p);
            entry["root"] = json!(true);
            entry["path"] = json!(p);
        }
        entry
    }

    /// A finished upload's entry logged, the browser answered.
    fn record_upload(&mut self, peer: &str, id: &Value, entry: Value, u: HUp) {
        let (fid, rel, by) = (entry["id"].clone(), entry["path"].clone(), entry["by"].clone());
        if !self.append(json!({"upload": entry.clone()})) {
            if entry["placed"].is_string() {
                log(format!("host: upload {fid} is in its folder but not logged")); // a retry would only make "Name 2"
            } else {
                return self.err(peer, id, "internal");
            }
        }
        if let Some(o) = self.outage.as_ref().filter(|_| self.ident.backup) {
            // Waits here for the main (outage.rs pushes it when it's back), under the same id.
            o.add(json!({"id": fid, "kind": if u.attachment { "attachment" } else { "asset" }, "file": rel, "name": u.name, "size": u.size,
                "sha256": entry["sha256"], "type": u.kind, "link": u.link, "by": by, "at": entry["at"]}));
        }
        self.activity(peer, "uploaded", Value::Null, Value::Null, json!({"name": u.name, "size": u.size}));
        let item = json!({"id": fid, "name": u.name, "size": u.size, "type": u.kind});
        // Asset uploads wait in the quarantine until the editor's Pluck takes them in (pull → upload entries).
        let mut r = if u.attachment { json!({"re": id, "attachment": item}) } else { json!({"re": id, "uploaded": item}) };
        // (not while the main still answers, e.g. this backup serving because its upload is faster: it goes up within a round)
        if self.ident.backup && !u.attachment && !self.replica.as_ref().is_some_and(|r| r.main_reachable()) {
            r["later"] = json!(true); // a backup in an outage: the page says the editor gets it once the office is back (§13.25)
        }
        self.send(peer, r);
    }

    /// A link's `uploads.into` as a real folder inside that media root (never the quarantine or the uploads root);
    /// `write`: inside the place --drop lets it be written instead (None when the root isn't droppable).
    fn into_dir(&self, into: &Value, write: bool) -> Option<PathBuf> {
        let root = into["root"].as_str()?;
        let folder = match &into["folder"] { Value::Null => "", Value::String(f) => f.as_str(), _ => return None };
        if root == crate::roots::QUARANTINE || self.upload_root.as_ref().is_some_and(|u| u.id == root) {
            return None;
        }
        let base = if write { self.drops.get(root)? } else { &self.roots.0.iter().find(|(i, _)| i == root)?.1 };
        crate::upload_root::subdir(base, folder)
    }

    /// Where a finished asset upload goes from the quarantine: its droppable `into` folder, checked again now, and the name.
    /// None leaves it in the quarantine (not droppable, gone…): never lost.
    fn place_target(&self, u: &HUp, fid: &str) -> Option<(PathBuf, String)> {
        if u.attachment || self.ident.backup || !u.into["root"].is_string() {
            return None;
        }
        let dir = self.into_dir(&u.into, true)?;
        Some((dir, if crate::upload_root::name_ok(&u.name) { u.name.clone() } else { format!("{fid}.{}", u.ext) }))
    }
}

enum Resolved {
    Inline(Value),
    File { parts: Vec<crate::media::Part>, kind: String, name: Option<String>, asset: Value, version: Value },
    Still { input: PathBuf, t: f64 },
}

/// The host task: reports from the RTC loop, sync requests, and a 30 s expiry check.
pub async fn run(mut host: Host, mut tap: mpsc::UnboundedReceiver<Value>, mut sync: mpsc::Receiver<Sync>,
                 mut progress: mpsc::UnboundedReceiver<(String, Value)>) {
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    let mut second = tokio::time::interval(Duration::from_secs(1));
    let mut daily = tokio::time::interval(Duration::from_secs(6 * 3600));
    loop {
        tokio::select! {
            Some((v, s)) = progress.recv() => host.copy_progress(v, s),
            Some(v) = tap.recv() => host.report(&v),
            Some(s) = sync.recv() => {
                if s.op["op"] == "mail-test" {
                    // Network work (up to ~30 s): in the background, so the host keeps answering.
                    match host.mail_test_job(&s.op) {
                        Ok((cfg, pw, msg)) => { tokio::spawn(async move {
                            let r = crate::mail::send(&cfg, &pw, &[msg], None).await;
                            let _ = s.reply.send(r.map_or_else(|e| json!({"error": {"code": e.code, "detail": e.detail}}), |()| json!({"ok": true})));
                        }); }
                        Err(v) => { let _ = s.reply.send(v); }
                    }
                } else {
                    let r = host.sync(&s.op);
                    let _ = s.reply.send(r);
                }
            }
            _ = tick.tick() => { host.check_links(); host.sweep_tmp(Duration::from_secs(600)); host.mail_tick(); }
            // An expiry or deadline due before the next 30 s check: cut its viewers off on the second (H3).
            _ = second.tick(), if host.ends_soon() => host.check_links(),
            _ = daily.tick() => host.compact(), // activity older than the retention setting goes
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_and_ids() {
        assert_eq!(iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso(1_796_083_200), "2026-12-01T00:00:00Z");
        assert_eq!(iso(951_782_400), "2000-02-29T00:00:00Z");
        let u = uuid();
        assert_eq!(u.len(), 36);
        assert_eq!(&u[14..15], "4");
        assert!(safe_rel("copies/V1/1080/media.m4s").is_some());
        for bad in ["../x", "/etc/passwd", "a/../../b", "", "./a"] {
            assert!(safe_rel(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn branding_inlines_logo_and_drops_bad_values() {
        let dir = std::env::temp_dir().join(format!("pluck-brand-{}", uuid()));
        std::fs::create_dir_all(dir.join("branding")).unwrap();
        std::fs::write(dir.join("branding/logo.png"), b"\x89PNG\r\n\x1a\nxx").unwrap();
        std::fs::write(dir.join("branding/big.png"), vec![0x89; 300 * 1024]).unwrap();
        let b = branding(&json!({"name": "Acme", "logo": "branding/logo.png", "logoLight": "branding/big.png",
            "accent": "#336699", "bg": "red", "text": "#FFFFFF"}), &dir).unwrap();
        assert!(b["logo"].as_str().unwrap().starts_with("iVBORw0KGg"));
        assert!(b.get("logoLight").is_none() && b.get("bg").is_none());
        assert_eq!(b["accent"], "#336699");
        assert!(branding(&json!({"logo": "../x.png"}), &dir).is_none());
        assert!(branding(&Value::Null, &dir).is_none());
    }

    const SEED: &str = "R85Juszx1tmPSUJlpjYA3DtFmqHJDUUU0Z1HyoU0Mb4"; // the contract vector's room seed

    fn test_host() -> (Host, mpsc::UnboundedReceiver<Ev>) {
        let dir = std::env::temp_dir().join(format!("pluck-host-{}", uuid()));
        let (tx, rx) = mpsc::unbounded_channel();
        (Host::new(&dir, Arc::new(Roots(vec![])), tx, None), rx)
    }

    fn sample(links: Value) -> Value {
        json!({"format": 1, "projects": [{"id": "P", "name": "Film", "folders": [],
            "assets": [{"id": "A", "name": "Cut", "folder": null, "kind": "video", "status": "needsReview",
                        "versions": [{"id": "V", "number": 1, "frames": 100}]},
                       {"id": "B", "name": "Other", "folder": null, "kind": "video", "status": "needsReview",
                        "versions": [{"id": "W", "number": 1, "frames": 100}]}]}],
            "links": links})
    }

    fn link(id: &str, room: &str, root: Value) -> Value {
        json!({"id": id, "roomID": room, "reg": "r", "auth": "a", "title": "T", "mode": "review", "revoked": null,
               "expires": null, "project": "P", "root": root, "sign": SEED, "join": "DDk_aLVe7_lpSrn2FJsnpy4x8AsymOK8AZOx9K_7OAo"})
    }

    fn sent(rx: &mut mpsc::UnboundedReceiver<Ev>) -> Vec<Value> {
        std::iter::from_fn(|| rx.try_recv().ok()).filter_map(|e| if let Ev::Cmd(v) = e { v.get("send").cloned() } else { None }).collect()
    }

    fn ready_peer(h: &mut Host, peer: &str, room: &str) {
        h.report(&json!({"peer": {"peer": peer, "state": "open", "room": room}}));
        h.peers.get_mut(peer).unwrap().ready = true;
    }

    #[test]
    fn admin_links_wait_for_a_registration_and_a_taken_room_gets_a_new_link() {
        let (mut h, _rx) = test_host();
        assert_eq!(h.publish(&sample(json!([])), &json!({}))["ok"], true);
        let r = h.sync(&json!({"op": "admin-publish", "project": "P", "files": [], "link": {"title": "T"}}));
        let id = r["link"].clone();
        let find = |h: &Host| h.admin_state()["links"].as_array().unwrap().iter().find(|l| l["id"] == id).cloned().unwrap();
        let room = |h: &Host| h.raw["links"].as_array().unwrap().iter().find(|l| l["id"] == id).unwrap()["roomID"].as_str().unwrap().to_owned();
        assert_eq!((find(&h)["ready"].clone(), find(&h)["taken"].clone()), (json!(false), json!(false)), "not shown before a server holds the room");
        crate::signal::state(&room(&h), "active");
        assert_eq!(find(&h)["ready"], true);
        // Someone else holds the room: a problem, and "Make a New Link" gives the same record a new code, R and room.
        let before = room(&h);
        crate::signal::state(&before, "taken");
        assert_eq!(find(&h)["taken"], true);
        let n = h.sync(&json!({"op": "admin-renew", "link": id}));
        let url = n["url"].as_str().unwrap();
        assert!(url.starts_with("https://pluck.tools/r/#") && url.len() == 35, "{n}");
        let l = h.raw["links"].as_array().unwrap().iter().find(|l| l["id"] == id).unwrap().clone();
        assert!(l["roomID"] != before.as_str() && l["level"] == 3 && l["sign"].is_null() && l["reg"].is_string());
        assert_eq!(l["roomID"], keys::b64(&keys::derive(&keys::link_key(&url[23..]), "room", 16)));
        assert_eq!((find(&h)["ready"].clone(), find(&h)["taken"].clone()), (json!(false), json!(false)), "the new room waits again");
        assert!(h.sync(&json!({"op": "admin-renew", "link": "nope"}))["error"].is_string());
    }

    #[test]
    fn an_admin_publish_tries_failed_copies_again() {
        let (mut h, _rx) = test_host();
        assert_eq!(h.publish(&sample(json!([])), &json!({}))["ok"], true);
        h.jobs.insert("V".into(), json!({"state": "failed", "progress": 0.0, "error": "the host's disk is full"}));
        h.jobs.insert("W".into(), json!({"state": "making", "progress": 0.5}));
        assert_eq!(h.sync(&json!({"op": "admin-publish", "project": "P", "files": []}))["ok"], true);
        assert!(!h.jobs.contains_key("V"), "the failed copy is queued again (s4a: disk full, then space back)");
        assert!(h.jobs.contains_key("W"), "a running one is left alone");
    }

    #[tokio::test]
    async fn removed_links_go_and_their_peers_are_told() {
        let (mut h, mut rx) = test_host();
        let r = h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"})), link("L2", "R2", json!({"kind": "project", "id": "P"}))])), &json!({}));
        assert_eq!(r["ok"], true);
        ready_peer(&mut h, "p1", "R1");
        ready_peer(&mut h, "p2", "R2");
        sent(&mut rx);
        h.publish(&sample(json!([])), &json!({"links": ["L1"]}));
        assert!(h.link("R1").is_none() && h.link("R2").is_some());
        assert!(!h.peers.contains_key("p1") && h.peers.contains_key("p2"));
        assert!(sent(&mut rx).iter().any(|s| s["peer"] == "p1" && s["msg"]["t"] == "bye"));
    }

    /// Protocol 2: the hello is signed with the room's seed; a level-1 link (no seed) is neither
    /// registered nor served; auth v1 is refused; own TURN only for live links (#20).
    #[tokio::test]
    async fn level2_hello_and_old_links() {
        let (mut h, mut rx) = test_host();
        let mut old = link("L0", "R0", json!({"kind": "project", "id": "P"}));
        old.as_object_mut().unwrap().remove("sign");
        let mut paused = link("L2", "R2", json!({"kind": "project", "id": "P"}));
        paused["paused"] = json!(true);
        h.publish(&sample(json!([old, link("L1", "R1", json!({"kind": "project", "id": "P"})), paused])), &json!({}));
        let rooms = cmds(&mut rx).into_iter().rev().find(|c| c.get("rooms").is_some()).unwrap();
        let ids: Vec<&Value> = rooms["rooms"].as_array().unwrap().iter().map(|r| &r["room"]).collect();
        assert_eq!(ids, [&json!("R1"), &json!("R2")], "the level-1 link isn't registered");
        assert_eq!((rooms["rooms"][0]["turn"].clone(), rooms["rooms"][1]["turn"].clone(), rooms["rooms"][0]["join"].clone()),
            (json!(true), json!(false), json!("DDk_aLVe7_lpSrn2FJsnpy4x8AsymOK8AZOx9K_7OAo")), "own TURN only while live");
        h.report(&json!({"peer": {"peer": "p0", "state": "open", "room": "R0", "fpLocal": "AA", "fpRemote": "BB"}}));
        assert!(!h.peers.contains_key("p0") && cmds(&mut rx).iter().any(|c| c["close"]["peer"] == "p0"), "an old link's peer is closed");
        h.report(&json!({"peer": {"peer": "p1", "state": "open", "room": "R1", "fpLocal": "AA", "fpRemote": "BB"}}));
        let hello = sent(&mut rx).into_iter().find(|s| s["peer"] == "p1").unwrap()["msg"].clone();
        let nonce = keys::unb64(hello["nonce"].as_str().unwrap()).unwrap();
        let public = keys::public(&keys::unb64(SEED).unwrap()).unwrap();
        assert!(hello["v"] == 2 && keys::verify_hello(&public, hello["sig"].as_str().unwrap(), &nonce, "AA", "BB"), "{hello}");
        h.request("p1", &json!({"id": 1, "t": "auth", "v": 1, "nonce": keys::b64(&[2u8; 32]), "proof": "x"}));
        assert_eq!(answer(&mut rx, "p1", 1)["error"]["code"], "auth", "auth v1 is refused");
    }

    /// Protocol 3 (§13.24): a level-3 record (no seed) is served with a MAC hello from authKey; auth must be v3; a
    /// wrong code's proof fails; `/a/<8>` resolves to the one in-scope asset with that prefix.
    #[tokio::test]
    async fn level3_hello_auth_and_short_assets() {
        let v: Value = serde_json::from_str(include_str!("../../../docs/superpowers/plans/link-v3-vectors.json")).unwrap();
        let auth = keys::unb64(v["authKey"].as_str().unwrap()).unwrap();
        let (mut h, mut rx) = test_host();
        let mut l3 = link("L3", "R3", json!({"kind": "project", "id": "P"}));
        l3.as_object_mut().unwrap().remove("sign");
        l3["level"] = json!(3);
        l3["auth"] = v["authKey"].clone();
        l3["join"] = v["joinHash"].clone();
        let mut m = sample(json!([l3]));
        for (id, name) in [("1a2b3c4d-0000-4000-8000-000000000001", "Short"), ("9f9f9f9f-0000-4000-8000-000000000001", "Twin1"),
                           ("9F9F9F9F-0000-4000-8000-000000000002", "Twin2")] {
            m["projects"][0]["assets"].as_array_mut().unwrap().push(json!({"id": id, "name": name, "folder": null, "kind": "video",
                "status": "needsReview", "versions": [{"id": format!("V{name}"), "number": 1, "frames": 10}]}));
        }
        h.publish(&m, &json!({}));
        let rooms = cmds(&mut rx).into_iter().rev().find(|c| c.get("rooms").is_some()).unwrap();
        assert_eq!(rooms["rooms"][0]["room"], "R3", "a level-3 link is registered");
        let open = |h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, peer: &str| {
            h.report(&json!({"peer": {"peer": peer, "state": "open", "room": "R3", "fpLocal": "AA", "fpRemote": "BB"}}));
            sent(rx).into_iter().find(|s| s["peer"] == peer).unwrap()["msg"].clone()
        };
        let hello = open(&mut h, &mut rx, "p1");
        let nonce = keys::unb64(hello["nonce"].as_str().unwrap()).unwrap();
        assert!(hello["v"] == 3 && hello.get("sig").is_none(), "{hello}");
        assert!(keys::check_hello_v3(&auth, hello["mac"].as_str().unwrap(), &nonce, "AA", "BB"));
        let bn = [2u8; 32];
        let good = keys::proof(&auth, "browser", &nonce, &bn, "AA", "BB");
        h.request("p1", &json!({"id": 1, "t": "auth", "v": 2, "nonce": keys::b64(&bn), "proof": good, "token": keys::b64(&[3u8; 32])}));
        assert_eq!(answer(&mut rx, "p1", 1)["error"]["code"], "auth", "a level-2 auth on a level-3 link is refused");
        let hello = open(&mut h, &mut rx, "p2");
        let nonce = keys::unb64(hello["nonce"].as_str().unwrap()).unwrap();
        let wrong = keys::derive(&keys::link_key("Mt0Rkt98Xy3R"), "auth", 32);
        h.request("p2", &json!({"id": 1, "t": "auth", "v": 3, "nonce": keys::b64(&bn), "proof": keys::proof(&wrong, "browser", &nonce, &bn, "AA", "BB"),
            "token": keys::b64(&[3u8; 32])}));
        assert_eq!(answer(&mut rx, "p2", 1)["error"]["code"], "auth", "a wrong code's proof is refused");
        let hello = open(&mut h, &mut rx, "p3");
        let nonce = keys::unb64(hello["nonce"].as_str().unwrap()).unwrap();
        h.request("p3", &json!({"id": 1, "t": "auth", "v": 3, "nonce": keys::b64(&bn), "proof": keys::proof(&auth, "browser", &nonce, &bn, "AA", "BB"),
            "token": keys::b64(&[3u8; 32])}));
        let welcome = answer(&mut rx, "p3", 1);
        assert_eq!(welcome["proof"], json!(keys::proof(&auth, "mac", &nonce, &bn, "AA", "BB")), "{welcome}");
        h.request("p3", &json!({"id": 2, "t": "asset", "asset": "1A2B3C4D"}));
        assert_eq!(answer(&mut rx, "p3", 2)["asset"]["id"], "1a2b3c4d-0000-4000-8000-000000000001");
        h.request("p3", &json!({"id": 3, "t": "asset", "asset": "9f9f9f9f"}));
        assert_eq!(answer(&mut rx, "p3", 3)["error"]["code"], "notFound", "two assets share the prefix");
        h.request("p3", &json!({"id": 4, "t": "asset", "asset": "zzzzzzzz"}));
        assert_eq!(answer(&mut rx, "p3", 4)["error"]["code"], "notFound");
    }

    /// #18 owner decision: a ready session ends when the link's password is set or changed.
    #[tokio::test]
    async fn a_new_password_ends_open_sessions() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        ready_peer(&mut h, "p1", "R1");
        h.request("p1", &json!({"id": 1, "t": "list"}));
        assert!(answer(&mut rx, "p1", 1)["error"].is_null());
        let mut m = sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))]));
        m["links"][0]["passwordHash"] = json!(keys::hash_password("new"));
        h.publish(&m, &json!({}));
        assert!(sent(&mut rx).iter().any(|s| s["peer"] == "p1" && s["msg"]["t"] == "bye" && s["msg"]["code"] == "password"));
        assert!(!h.peers.contains_key("p1"));
    }

    /// #3: comment events about a version a latestOnly link hides don't reach its viewers.
    #[test]
    fn latest_only_links_hear_nothing_of_older_versions() {
        let (mut h, mut rx) = test_host();
        let mut m = sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"})), link("L2", "R2", json!({"kind": "project", "id": "P"}))]));
        m["links"][0]["latestOnly"] = json!(true);
        m["projects"][0]["assets"][0]["versions"].as_array_mut().unwrap().push(json!({"id": "V2", "number": 2, "frames": 100}));
        h.publish(&m, &json!({}));
        ready_peer(&mut h, "p1", "R1");
        named_peer(&mut h, "p2", "R2", "t2", "Ben");
        sent(&mut rx);
        h.request("p2", &json!({"id": 1, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "old cut"}));
        assert!(!sent(&mut rx).iter().any(|s| s["peer"] == "p1"), "a write on V (hidden) says nothing to the latestOnly link");
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "M", "asset": "A", "version": "V", "text": "mac", "rev": 1, "replies": []}}]}));
        assert!(!sent(&mut rx).iter().any(|s| s["peer"] == "p1" && s["msg"]["t"] == "comment"), "nor a synced one");
        h.request("p2", &json!({"id": 2, "t": "comment-add", "asset": "A", "version": "V2", "frame": 1, "text": "new cut"}));
        assert!(sent(&mut rx).iter().any(|s| s["peer"] == "p1" && s["msg"]["t"] == "comment"), "the current version is told");
    }

    /// #12: replies, reactions and completes re-log the whole comment; only the newest snapshot is kept.
    #[test]
    fn superseded_comment_snapshots_are_compacted() {
        let (mut h, _rx) = test_host();
        for rev in 1..=50 {
            h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "C", "asset": "A", "version": "V", "text": "x".repeat(2000), "rev": rev, "replies": []}}]}));
        }
        assert_eq!(h.entries.len(), 50);
        h.compact();
        assert_eq!(h.entries.len(), 1, "one snapshot per comment");
        assert_eq!(h.entries[0]["comment"]["rev"], 50);
        assert_eq!(std::fs::read_to_string(&h.log_path).unwrap().lines().count(), 1);
        assert_eq!(h.comments.len(), 1);
    }

    /// #16: pull pages carry the seq of their last entry and `more`.
    #[test]
    fn pull_pages_never_skip() {
        let (mut h, _rx) = test_host();
        let entries: Vec<Value> = (0..5002).map(|i| json!({"activity": {"id": format!("a{i}"), "link": "L", "at": now_iso(), "kind": "viewed"}})).collect();
        h.sync(&json!({"op": "append", "entries": entries}));
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "C", "asset": "A", "version": "V", "text": "t", "rev": 1, "replies": []}}]}));
        let p1 = h.sync(&json!({"op": "pull", "since": 0}));
        assert_eq!((p1["entries"].as_array().unwrap().len(), p1["more"].clone(), p1["seq"].clone()), (5000, json!(true), json!(5000)));
        let p2 = h.sync(&json!({"op": "pull", "since": p1["seq"]}));
        assert_eq!((p2["entries"].as_array().unwrap().len(), p2["more"].clone(), p2["seq"].clone()), (3, json!(false), json!(5003)));
        assert_eq!(p2["entries"][2]["comment"]["id"], "C", "the comment after the first page arrives");
    }

    /// #13/#14: a fetch id in use is refused; stray temp files and link-upload partials are swept.
    #[test]
    fn temp_files_and_partials_are_cleaned() {
        let (mut h, mut rx) = test_host();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        l["uploads"] = json!({"folder": null, "maxBytes": 1000, "types": ["image"]});
        h.publish(&sample(json!([l])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        sent(&mut rx);
        h.peers.get_mut("p1").unwrap().fetches.insert(5, Fetched::default());
        h.request("p1", &json!({"id": 5, "t": "fetch", "what": "proof", "approval": "X"}));
        assert_eq!(answer(&mut rx, "p1", 5)["error"]["code"], "invalid", "a fetch id still in flight");
        let tmp = h.data.join("tmp");
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join("still-late.jpg"), b"x").unwrap();
        h.sweep_tmp(Duration::from_secs(600));
        assert!(tmp.join("still-late.jpg").exists(), "young files stay a while");
        h.sweep_tmp(Duration::ZERO);
        assert!(!tmp.join("still-late.jpg").exists(), "no fetch holds it: gone");
        // A finished upload the browser never ends: the partial goes when the peer closes.
        h.request("p1", &json!({"id": 6, "t": "upload-begin", "name": "a.png", "size": 3, "for": "attachment"}));
        let part = PathBuf::from(cmds(&mut rx).into_iter().find_map(|c| c["accept"]["path"].as_str().map(str::to_owned)).unwrap());
        std::fs::write(&part, b"abc").unwrap();
        h.report(&json!({"upload": {"peer": "p1", "upload": 6, "state": "done", "bytes": 3, "sha256": keys::sha256_b64(b"abc")}}));
        h.report(&json!({"peer": {"peer": "p1", "state": "closed"}}));
        assert!(!part.exists(), "closed after done: the partial is deleted");
        // And any left from an earlier run go at start-up.
        std::fs::write(h.data.join("uploads/.partial/old.part"), b"x").unwrap();
        let (tx, _rx2) = mpsc::unbounded_channel();
        let _h2 = Host::new(&h.data, Arc::new(Roots(vec![])), tx, None);
        assert!(!h.data.join("uploads/.partial/old.part").exists());
    }

    #[test]
    fn odd_inputs_fail_closed() {
        assert_eq!(norm_iso("2026-01-01T00:00:00+0é:0"), None, "no panic on non-ASCII offsets");
        let (mut h, _rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "mystery", "id": "P"}))])), &json!({}));
        let l = h.link("R1").unwrap().clone();
        assert_eq!(h.list(&l, &json!({})).err(), Some("scope"), "an unknown root kind isn't the whole project");
    }

    #[test]
    fn republish_keeps_admin_assets() {
        let (mut h, _rx) = test_host();
        h.publish(&sample(json!([])), &json!({}));
        let mut raw = h.raw.clone();
        raw["projects"][0]["assets"].as_array_mut().unwrap().push(json!({"id": "X", "name": "Added", "kind": "video", "by": "admin", "versions": []}));
        h.save(&raw, "admin").unwrap();
        let mut m = sample(json!([]));
        m["projects"][0]["assets"].as_array_mut().unwrap().remove(1);
        h.publish(&m, &json!({}));
        let ids: Vec<&Value> = Host::arr(&h.raw["projects"][0], "assets").map(|a| &a["id"]).collect();
        assert_eq!(ids, [&json!("A"), &json!("X")]);
    }

    #[test]
    fn every_write_is_rate_limited() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "C", "asset": "A", "version": "V", "text": "hi", "replies": [], "completed": false}}]}));
        ready_peer(&mut h, "p1", "R1");
        sent(&mut rx);
        for n in 0..31 {
            h.request("p1", &json!({"id": n, "t": "comment-complete", "comment": "C", "completed": n % 2 == 0}));
        }
        let answers = sent(&mut rx);
        let limited: Vec<&Value> = answers.iter().filter(|s| s["msg"]["error"]["code"] == "limit").collect();
        assert_eq!(limited.len(), 1);
        assert_eq!(limited[0]["msg"]["re"], 30);
    }

    #[test]
    fn synced_comments_reach_open_browsers_live() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "asset", "id": "A"})), link("L2", "R2", json!({"kind": "asset", "id": "B"}))])), &json!({}));
        ready_peer(&mut h, "p1", "R1");
        ready_peer(&mut h, "p2", "R2");
        sent(&mut rx);
        let c = json!({"id": "M1", "asset": "A", "version": "V", "text": "from the Mac", "rev": 1, "replies": []});
        h.sync(&json!({"op": "append", "entries": [{"comment": c}]}));
        let ev: Vec<Value> = sent(&mut rx).into_iter().filter(|s| s["msg"]["t"] == "comment").collect();
        assert_eq!(ev.len(), 1, "only the peer whose link holds A");
        assert_eq!((ev[0]["peer"].clone(), ev[0]["msg"]["op"].clone(), ev[0]["msg"]["comment"]["text"].clone()), (json!("p1"), json!("add"), json!("from the Mac")));
        let mut edited = c.clone();
        edited["text"] = json!("edited on the Mac");
        edited["rev"] = json!(2);
        h.sync(&json!({"op": "append", "entries": [{"comment": edited}]}));
        assert!(sent(&mut rx).iter().any(|s| s["msg"]["op"] == "edit" && s["msg"]["comment"]["text"] == "edited on the Mac"));
        h.sync(&json!({"op": "append", "entries": [{"comment": c}]}));
        assert!(!sent(&mut rx).iter().any(|s| s["msg"]["t"] == "comment"), "a repeat changes nothing and says nothing");
    }

    #[test]
    fn copies_ready_only_tell_peers_that_see_the_asset() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "asset", "id": "A"})), link("L2", "R2", json!({"kind": "asset", "id": "B"}))])), &json!({}));
        ready_peer(&mut h, "p1", "R1");
        ready_peer(&mut h, "p2", "R2");
        sent(&mut rx);
        h.copy_progress("V".into(), json!({"state": "ready", "progress": 1.0}));
        let to: Vec<Value> = sent(&mut rx).into_iter().filter(|s| s["msg"]["t"] == "asset-changed").map(|s| s["peer"].clone()).collect();
        assert_eq!(to, [json!("p1")]);
    }

    #[test]
    fn drawings() {
        let ok = json!({"strokes": [{"tool": "arrow", "colour": "#E0605E", "width": 0.004, "points": [[0.41, 0.30], [0.52, 0.38]]}]});
        assert!(Host::drawing_ok(&ok));
        assert!(Host::drawing_ok(&Value::Null));
        let mut bad = ok.clone();
        bad["strokes"][0]["colour"] = json!("#000000");
        assert!(!Host::drawing_ok(&bad));
        let mut bad = ok.clone();
        bad["strokes"][0]["points"][0][0] = json!(1.5);
        assert!(!Host::drawing_ok(&bad));
    }

    fn named_peer(h: &mut Host, peer: &str, room: &str, token: &str, name: &str) {
        ready_peer(h, peer, room);
        let p = h.peers.get_mut(peer).unwrap();
        p.token = Some(token.into());
        p.name = name.into();
    }

    fn answer(rx: &mut mpsc::UnboundedReceiver<Ev>, peer: &str, re: u64) -> Value {
        sent(rx).into_iter().find(|s| s["peer"] == peer && s["msg"]["re"] == re).map(|s| s["msg"].clone()).unwrap_or(Value::Null)
    }

    fn cmds(rx: &mut mpsc::UnboundedReceiver<Ev>) -> Vec<Value> {
        std::iter::from_fn(|| rx.try_recv().ok()).filter_map(|e| if let Ev::Cmd(v) = e { Some(v) } else { None }).collect()
    }

    #[test]
    fn branding_from_a_publish_is_kept_and_can_be_removed() {
        let (mut h, _rx) = test_host();
        std::fs::create_dir_all(h.dir.join("branding")).unwrap();
        std::fs::write(h.dir.join("branding/logo.png"), b"\x89PNG\r\n\x1a\nxx").unwrap();
        std::fs::write(h.dir.join("branding/header.jpg"), [0xFF, 0xD8, 0xFF, 0xE0, 1, 2]).unwrap();
        let mut m = sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))]));
        m["branding"] = json!({"name": "Studio", "logo": "branding/logo.png", "accent": "#336699", "header": "branding/header.jpg"});
        assert_eq!(h.publish(&m, &json!({}))["ok"], true);
        assert_eq!(h.manifest["branding"]["accent"], "#336699", "NAS hosts apply the branding they're sent");
        assert!(h.link("R1").unwrap()["header"].as_str().unwrap().starts_with("data:image/jpeg;base64,/9j/"));
        h.publish(&sample(json!([])), &json!({}));
        assert_eq!(h.manifest["branding"]["accent"], "#336699", "a publish without branding leaves it");
        let mut m = sample(json!([]));
        m["branding"] = Value::Null;
        h.publish(&m, &json!({}));
        assert!(h.manifest.get("branding").is_none());
    }

    #[tokio::test]
    async fn a_peer_ended_by_check_links_ends_its_fetches() {
        let (mut h, _rx) = test_host();
        let r = crate::replica::Shared::load(&h.data, 1 << 30, "1080-low");
        h.replica = Some(r.clone());
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        ready_peer(&mut h, "p1", "R1");
        let temp = h.data.join("tmp/f.part");
        std::fs::create_dir_all(temp.parent().unwrap()).unwrap();
        std::fs::write(&temp, b"x").unwrap();
        r.fetch_start("V");
        h.peers.get_mut("p1").unwrap().fetches.insert(5, Fetched { temp: Some(temp.clone()), version: Some("V".into()), ..Default::default() });
        let mut m = sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))]));
        m["links"][0]["paused"] = json!(true);
        h.publish(&m, &json!({}));
        assert!(!h.peers.contains_key("p1"));
        assert_eq!(r.inflight("V"), 0, "the version can be evicted again");
        assert!(!temp.exists());
    }

    #[tokio::test]
    async fn paused_links_answer_paused_and_keep_their_room() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        ready_peer(&mut h, "p1", "R1");
        cmds(&mut rx);
        let mut m = sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))]));
        m["links"][0]["paused"] = json!(true);
        h.publish(&m, &json!({}));
        let c = cmds(&mut rx);
        assert!(c.iter().any(|c| c["send"]["peer"] == "p1" && c["send"]["msg"]["t"] == "bye" && c["send"]["msg"]["code"] == "paused"));
        h.report(&json!({"peer": {"peer": "p2", "state": "open", "room": "R1"}}));
        h.request("p2", &json!({"id": 1, "t": "auth"}));
        assert_eq!(answer(&mut rx, "p2", 1)["error"]["code"], "paused", "before the proof check");
        h.peers.remove("p2");
        h.check_links();
        let rooms = cmds(&mut rx).into_iter().find(|c| c.get("rooms").is_some()).unwrap();
        assert_eq!(rooms["rooms"][0]["room"], "R1", "still registered, so new visitors hear why");
    }

    #[test]
    fn names_emails_and_personal_links() {
        let (mut h, mut rx) = test_host();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        l["requireName"] = json!(true);
        let mut personal = link("L2", "R2", json!({"kind": "project", "id": "P"}));
        personal["recipient"] = json!("Anna");
        h.publish(&sample(json!([l, personal])), &json!({}));
        ready_peer(&mut h, "p1", "R1");
        h.request("p1", &json!({"id": 1, "t": "list", "folder": null}));
        assert_eq!(answer(&mut rx, "p1", 1)["error"]["code"], "auth", "a name first");
        h.request("p1", &json!({"id": 2, "t": "identify", "name": "Ben", "email": "ben@example.com"}));
        assert_eq!(answer(&mut rx, "p1", 2)["ok"], true);
        assert_eq!((h.peers["p1"].name.as_str(), h.peers["p1"].email.as_str()), ("Ben", "ben@example.com"));
        h.request("p1", &json!({"id": 3, "t": "list", "folder": null}));
        assert!(answer(&mut rx, "p1", 3)["assets"].is_array());
        named_peer(&mut h, "p2", "R2", "t2", "Anna");
        h.request("p2", &json!({"id": 4, "t": "name", "name": "Someone else"}));
        assert_eq!(h.peers["p2"].name, "Anna", "a personal link keeps its recipient");
    }

    #[test]
    fn internal_comments_reach_team_links_only() {
        let (mut h, mut rx) = test_host();
        let mut t = link("LT", "RT", json!({"kind": "project", "id": "P"}));
        t["audience"] = json!("team");
        h.publish(&sample(json!([link("LC", "RC", json!({"kind": "project", "id": "P"})), t])), &json!({}));
        named_peer(&mut h, "client", "RC", "tc", "Client");
        named_peer(&mut h, "team", "RT", "tt", "Editor");
        sent(&mut rx);
        h.request("client", &json!({"id": 1, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "x", "internal": true}));
        assert_eq!(answer(&mut rx, "client", 1)["error"]["code"], "scope");
        h.request("team", &json!({"id": 2, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "Fix the grade first", "internal": true}));
        let msgs = sent(&mut rx);
        let cid = msgs.iter().find(|s| s["msg"]["re"] == 2).unwrap()["msg"]["comment"]["id"].clone();
        assert!(!msgs.iter().any(|s| s["peer"] == "client"), "no event to the client");
        h.request("client", &json!({"id": 3, "t": "comments", "asset": "A", "version": "V"}));
        assert_eq!(answer(&mut rx, "client", 3)["comments"], json!([]));
        h.request("client", &json!({"id": 4, "t": "reply-add", "comment": cid, "text": "?"}));
        assert_eq!(answer(&mut rx, "client", 4)["error"]["code"], "notFound");
        h.request("client", &json!({"id": 5, "t": "list", "folder": null}));
        assert_eq!(answer(&mut rx, "client", 5)["assets"][0]["current"]["comments"], 0);
        h.request("team", &json!({"id": 6, "t": "comments", "asset": "A", "version": "V"}));
        assert_eq!(answer(&mut rx, "team", 6)["comments"][0]["internal"], true);
        // The editor still gets it.
        assert!(h.sync(&json!({"op": "pull", "since": 0}))["entries"].as_array().unwrap().iter().any(|e| e["comment"]["internal"] == true));
    }

    /// Clients see every comment and reply on what they can open (the team's, other clients', their own) except
    /// internal ones: an internal comment never, an internal reply taken out of a thread they still see.
    #[test]
    fn clients_see_all_comments_but_internal_ones() {
        let (mut h, mut rx) = test_host();
        let mut t = link("LT", "RT", json!({"kind": "project", "id": "P"}));
        t["audience"] = json!("team");
        h.publish(&sample(json!([link("LC", "RC", json!({"kind": "project", "id": "P"})), t])), &json!({}));
        named_peer(&mut h, "c1", "RC", "t1", "Client one");
        named_peer(&mut h, "c2", "RC", "t2", "Client two");
        named_peer(&mut h, "team", "RT", "tt", "Editor");
        sent(&mut rx);
        let add = |h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, peer: &str, id: u64, text: &str, internal: bool| {
            h.request(peer, &json!({"id": id, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": text, "internal": internal}));
            answer(rx, peer, id)["comment"]["id"].clone()
        };
        let team_c = add(&mut h, &mut rx, "team", 1, "Grade pass done", false);
        add(&mut h, &mut rx, "c2", 2, "Love the opening", false);
        add(&mut h, &mut rx, "team", 3, "Budget note", true);
        h.request("team", &json!({"id": 4, "t": "reply-add", "comment": team_c, "text": "Between us: v2 is rough", "internal": true}));
        let msgs = sent(&mut rx);
        assert!(msgs.iter().filter(|s| s["peer"] == "c1" && s["msg"]["t"] == "comment").all(|s| s["msg"]["comment"]["replies"] == json!([])),
            "the live event leaves the internal reply out");
        h.request("team", &json!({"id": 5, "t": "reply-add", "comment": team_c, "text": "Thanks, looks good"}));
        h.request("c1", &json!({"id": 6, "t": "reply-add", "comment": team_c, "text": "x", "internal": true}));
        assert_eq!(answer(&mut rx, "c1", 6)["error"]["code"], "scope", "a client can't write an internal reply");
        h.request("c1", &json!({"id": 7, "t": "comments", "asset": "A", "version": "V"}));
        let list = answer(&mut rx, "c1", 7)["comments"].clone();
        let texts: Vec<&str> = list.as_array().unwrap().iter().map(|c| c["text"].as_str().unwrap()).collect();
        assert_eq!(texts, ["Grade pass done", "Love the opening"], "the team's and another client's, not the internal one");
        let replies: Vec<&str> = list[0]["replies"].as_array().unwrap().iter().map(|r| r["text"].as_str().unwrap()).collect();
        assert_eq!(replies, ["Thanks, looks good"], "the thread stays, its internal reply goes");
        h.request("team", &json!({"id": 8, "t": "comments", "asset": "A", "version": "V"}));
        let team_list = answer(&mut rx, "team", 8)["comments"].clone();
        assert_eq!((team_list.as_array().unwrap().len(), team_list[0]["replies"].as_array().unwrap().len()), (3, 2), "the team sees everything");
    }

    #[test]
    fn assets_root_holds_only_the_picked_assets() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("LA", "RA", json!({"kind": "assets", "id": "LA", "name": "T", "assets": ["B"]}))])), &json!({}));
        ready_peer(&mut h, "p", "RA");
        sent(&mut rx);
        h.request("p", &json!({"id": 1, "t": "list", "folder": null}));
        let r = answer(&mut rx, "p", 1);
        assert_eq!((r["path"].clone(), r["assets"].as_array().unwrap().len(), r["assets"][0]["id"].clone()), (json!([]), 1, json!("B")));
        h.request("p", &json!({"id": 2, "t": "asset", "asset": "A"}));
        assert_eq!(answer(&mut rx, "p", 2)["error"]["code"], "scope");
        h.request("p", &json!({"id": 3, "t": "list", "folder": "F"}));
        assert_eq!(answer(&mut rx, "p", 3)["error"]["code"], "scope");
        h.request("p", &json!({"id": 4, "t": "comments", "asset": "B", "version": "W"}));
        assert!(answer(&mut rx, "p", 4)["comments"].is_array());
    }

    #[test]
    fn the_workers_clock_wins_over_a_wrong_local_one() {
        let local = 1_800_000_000;
        assert_eq!(new_offset((local + 600) * 1000, local, 0), Some(600), "this machine is 10 min slow");
        assert_eq!(new_offset((local + 600) * 1000 + 900, local, 600), None, "network delay changes nothing");
        assert_eq!(new_offset((local - 600) * 1000, local, 600), Some(-600));
        assert_eq!(new_offset(local * 1000, local, 0), None);
    }

    #[test]
    fn an_expiry_due_soon_is_checked_every_second() {
        let (mut h, _rx) = test_host();
        let secs = now_secs();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        h.publish(&sample(json!([l.clone()])), &json!({}));
        assert!(!h.ends_soon());
        l["expires"] = json!(iso(secs + 20));
        h.publish(&sample(json!([l.clone()])), &json!({}));
        assert!(h.ends_soon());
        l["expires"] = json!(iso(secs + 3600));
        h.publish(&sample(json!([l])), &json!({}));
        assert!(!h.ends_soon());
    }

    #[test]
    fn an_append_that_cant_be_written_answers_an_error() {
        let (mut h, _rx) = test_host();
        let _ = std::fs::remove_file(&h.log_path);
        std::fs::create_dir_all(&h.log_path).unwrap(); // comments.jsonl can't be opened for writing
        let r = h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "C", "asset": "A", "version": "V", "text": "x", "replies": []}}]}));
        assert_eq!(r["error"], "write", "{r}");
        assert!(h.comments.is_empty());
    }

    #[test]
    fn a_resent_comment_is_kept_once() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        named_peer(&mut h, "p2", "R1", "t2", "Ben");
        let add = |id: u64, cid: &str| json!({"id": id, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "once", "cid": cid});
        h.request("p1", &add(1, "cid-0123456789"));
        let first = answer(&mut rx, "p1", 1)["comment"].clone();
        h.request("p1", &add(2, "cid-0123456789")); // the answer to 1 was lost; the browser sends it again
        assert_eq!(answer(&mut rx, "p1", 2)["comment"]["id"], first["id"]);
        h.request("p2", &add(3, "cid-0123456789")); // another browser's cid never matches
        assert_ne!(answer(&mut rx, "p2", 3)["comment"]["id"], first["id"]);
        h.request("p1", &add(4, "cid-another-one"));
        assert_ne!(answer(&mut rx, "p1", 4)["comment"]["id"], first["id"]);
        assert_eq!(h.comments.iter().filter(|c| c["text"] == "once").count(), 3);
    }

    #[test]
    fn a_comment_needs_a_name() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "");
        let add = json!({"id": 1, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "who am I"});
        h.request("p1", &add);
        assert_eq!(answer(&mut rx, "p1", 1)["error"]["code"], "needName");
        h.request("p1", &json!({"id": 2, "t": "approve", "asset": "A", "version": "V", "decision": "approve"}));
        assert_eq!(answer(&mut rx, "p1", 2)["error"]["code"], "needName");
        h.request("p1", &json!({"id": 3, "t": "identify", "name": "  Anna  "}));
        h.request("p1", &json!({"id": 4, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "who am I"}));
        assert_eq!(answer(&mut rx, "p1", 4)["comment"]["author"], "Anna");
        let c = h.comments[0]["id"].clone();
        h.request("p1", &json!({"id": 5, "t": "reply-add", "comment": c, "text": "me"}));
        assert!(answer(&mut rx, "p1", 5)["comment"].is_object());
        h.peers.get_mut("p1").unwrap().name.clear();
        h.request("p1", &json!({"id": 6, "t": "reply-add", "comment": c, "text": "me"}));
        assert_eq!(answer(&mut rx, "p1", 6)["error"]["code"], "needName");
    }

    #[test]
    fn a_torn_last_line_is_cut_and_later_entries_survive() {
        let dir = std::env::temp_dir().join(format!("pluck-host-{}", uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let good = json!({"seq": 1, "comment": {"id": "C1", "asset": "A", "version": "V", "text": "kept", "replies": []}});
        std::fs::write(dir.join("comments.jsonl"), format!("{good}\n{{\"seq\":2,\"comment\":{{\"id\":\"C2\",\"te")).unwrap();
        let (tx, _rx) = mpsc::unbounded_channel();
        let mut h = Host::new(&dir, Arc::new(Roots(vec![])), tx, None);
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "C3", "asset": "A", "version": "V", "text": "after", "replies": []}}]}));
        let (tx, _rx) = mpsc::unbounded_channel();
        let h2 = Host::new(&dir, Arc::new(Roots(vec![])), tx, None);
        let ids: Vec<_> = h2.comments.iter().map(|c| c["id"].as_str().unwrap().to_owned()).collect();
        assert_eq!(ids, ["C1", "C3"]);
        assert!(std::fs::read_to_string(dir.join("comments.jsonl")).unwrap().lines().all(|l| serde_json::from_str::<Value>(l).is_ok()));
    }

    #[test]
    fn reactions_general_comments_pins_and_lines() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        named_peer(&mut h, "p2", "R1", "t2", "Ben");
        h.request("p1", &json!({"id": 1, "t": "comment-add", "asset": "A", "version": "V", "frame": null, "text": "Overall: lovely", "anchor": [0.4, 0.3],
            "drawing": {"strokes": [{"tool": "line", "colour": "#F2D14B", "width": 0.004, "points": [[0.1, 0.1], [0.4, 0.4]]}]}}));
        let c = answer(&mut rx, "p1", 1)["comment"].clone();
        assert!(c["frame"].is_null() && c["anchor"] == json!([0.4, 0.3]), "{c}");
        h.request("p1", &json!({"id": 2, "t": "comment-add", "asset": "A", "version": "V", "frame": null, "endFrame": 5, "text": "x"}));
        assert_eq!(answer(&mut rx, "p1", 2)["error"]["code"], "invalid", "no range without a start");
        h.request("p1", &json!({"id": 3, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "x", "anchor": [2, 0]}));
        assert_eq!(answer(&mut rx, "p1", 3)["error"]["code"], "invalid");
        h.request("p1", &json!({"id": 4, "t": "comment-add", "asset": "A", "version": "V", "frame": null, "page": 1, "text": "x"}));
        assert_eq!(answer(&mut rx, "p1", 4)["error"]["code"], "invalid", "pages only on documents");
        for (id, who, on) in [(5, "p1", true), (6, "p2", true), (7, "p2", false)] {
            h.request(who, &json!({"id": id, "t": "react", "comment": c["id"], "emoji": "👍", "on": on}));
        }
        let mine = answer(&mut rx, "p2", 7);
        h.request("p1", &json!({"id": 8, "t": "comments", "asset": "A", "version": "V"}));
        assert_eq!(answer(&mut rx, "p1", 8)["comments"][0]["reactions"], json!([{"emoji": "👍", "count": 1, "mine": true}]));
        assert_eq!(mine["comment"]["reactions"], json!([{"emoji": "👍", "count": 1, "mine": false}]));
        h.request("p1", &json!({"id": 9, "t": "react", "comment": c["id"], "emoji": "🍕", "on": true}));
        assert_eq!(answer(&mut rx, "p1", 9)["error"]["code"], "invalid", "a fixed set of 12");
        let stored = h.comments.iter().find(|x| x["id"] == c["id"]).unwrap();
        assert_eq!(stored["reactions"]["👍"], json!(["t1"]), "stored by author token");
    }

    #[test]
    fn custom_statuses_fields_and_order_pass_through() {
        let (mut h, mut rx) = test_host();
        let mut t = link("LT", "RT", json!({"kind": "project", "id": "P"}));
        t["audience"] = json!("team");
        t["fields"] = json!(["status", "cf:shot"]);
        t["order"] = json!(["B", "A"]);
        t["statusDefs"] = json!([{"id": "c:lock", "name": "Picture lock", "colour": "violet"}]);
        t["fieldDefs"] = json!([{"id": "cf:shot", "name": "Shot", "kind": "text"}]);
        let old = link("LO", "RO", json!({"kind": "project", "id": "P"}));
        let mut m = sample(json!([t, old]));
        m["projects"][0]["assets"][0]["status"] = json!("c:lock");
        m["projects"][0]["assets"][0]["fields"] = json!({"cf:shot": "Wide", "notes": "n"});
        h.publish(&m, &json!({}));
        let l = h.links().find(|l| l["id"] == "LT").unwrap().clone();
        named_peer(&mut h, "pt", "RT", "tt", "Editor");
        h.ready("pt", &Value::Null, &l);
        let ready = sent(&mut rx).into_iter().find(|s| s["msg"]["t"] == "ready").unwrap()["msg"]["link"].clone();
        assert_eq!((ready["order"].clone(), ready["statusDefs"][0]["id"].clone(), ready["fieldDefs"][0]["id"].clone()),
                   (json!(["B", "A"]), json!("c:lock"), json!("cf:shot")));
        h.request("pt", &json!({"id": 1, "t": "list", "folder": null}));
        let a = answer(&mut rx, "pt", 1)["assets"][0].clone();
        assert_eq!((a["status"].clone(), a["fields"]["cf:shot"].clone()), (json!("c:lock"), json!("Wide")), "an unknown status id passes through");
        assert_eq!(a["fields"]["notes"], "n", "a team link shows every field, as the Mac's own server");
        h.request("pt", &json!({"id": 2, "t": "field-set", "asset": "A", "field": "cf:shot", "value": "Close"}));
        assert_eq!(answer(&mut rx, "pt", 2)["asset"]["fields"]["cf:shot"], "Close");
        h.request("pt", &json!({"id": 3, "t": "field-set", "asset": "A", "field": "cf:other", "value": "x"}));
        h.request("pt", &json!({"id": 4, "t": "field-set", "asset": "A", "field": "status", "value": "c:lock"}));
        let msgs = sent(&mut rx);
        let code = |re: u64| msgs.iter().find(|s| s["msg"]["re"] == re).unwrap()["msg"]["error"]["code"].clone();
        assert_eq!((code(3), code(4)), (json!("invalid"), json!("invalid")), "unlisted fields and custom statuses aren't set from links");
        let o = h.links().find(|l| l["id"] == "LO").unwrap().clone();
        named_peer(&mut h, "po", "RO", "to", "Anna");
        h.ready("po", &Value::Null, &o);
        let r = sent(&mut rx).into_iter().find(|s| s["msg"]["t"] == "ready").unwrap()["msg"]["link"].clone();
        assert!(r.get("order").is_none() && r.get("statusDefs").is_none(), "an old link has none of them");
    }

    #[test]
    fn featured_field_and_team_fields() {
        let (mut h, mut rx) = test_host();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        l["featuredField"] = json!("rating");
        l["fields"] = json!(["status", "rating"]);
        let mut t = link("LT", "RT", json!({"kind": "project", "id": "P"}));
        t["audience"] = json!("team");
        t["fields"] = json!(["notes"]);
        h.publish(&sample(json!([l, t])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        named_peer(&mut h, "pt", "RT", "tt", "Editor");
        sent(&mut rx);
        h.request("p1", &json!({"id": 1, "t": "field-set", "asset": "A", "field": "rating", "value": 4}));
        assert_eq!(answer(&mut rx, "p1", 1)["asset"]["fields"]["rating"], 4);
        for (id, f, v) in [(2, "rating", json!(9)), (3, "notes", json!("x"))] {
            h.request("p1", &json!({"id": id, "t": "field-set", "asset": "A", "field": f, "value": v}));
        }
        let a = sent(&mut rx);
        let code = |re: u64| a.iter().find(|s| s["msg"]["re"] == re).unwrap()["msg"]["error"]["code"].clone();
        assert_eq!((code(2), code(3)), (json!("invalid"), json!("scope")));
        h.request("p1", &json!({"id": 4, "t": "approve", "asset": "A", "version": "V", "decision": "approve"}));
        assert_eq!(answer(&mut rx, "p1", 4)["error"]["code"], "scope", "status isn't this link's field");
        h.request("pt", &json!({"id": 5, "t": "field-set", "asset": "A", "field": "status", "value": "approved"}));
        let msgs = sent(&mut rx);
        assert_eq!(msgs.iter().find(|s| s["msg"]["re"] == 5).unwrap()["msg"]["asset"]["status"], "approved");
        assert!(msgs.iter().any(|s| s["peer"] == "p1" && s["msg"]["t"] == "status"), "the client sees the status change");
        h.request("pt", &json!({"id": 6, "t": "field-set", "asset": "A", "field": "notes", "value": "Music not final"}));
        assert!(!sent(&mut rx).iter().any(|s| s["peer"] == "p1" && s["msg"]["field"] == "notes"), "notes aren't on the client link");
        let e = h.sync(&json!({"op": "pull", "since": 0}));
        let e = e["entries"].as_array().unwrap();
        assert!(e.iter().any(|e| e["approval"]["decision"] == "approve" && e["approval"]["author"] == "Editor"), "status approved is an Approval");
        assert!(e.iter().any(|e| e["field"]["field"] == "rating" && e["field"]["value"] == 4));
        assert!(e.iter().any(|e| e["activity"]["kind"] == "approved"));
    }

    #[test]
    fn activity_and_its_retention() {
        let (mut h, mut rx) = test_host();
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        h.peers.get_mut("p1").unwrap().email = "anna@example.com".into();
        h.request("p1", &json!({"id": 1, "t": "viewing", "asset": "A"}));
        h.request("p1", &json!({"id": 2, "t": "played", "asset": "A", "version": "V", "from": 0, "to": 80}));
        assert_eq!(answer(&mut rx, "p1", 2)["ok"], true);
        h.request("p1", &json!({"id": 3, "t": "played", "asset": "A", "version": "V", "from": 50, "to": 101}));
        assert_eq!(answer(&mut rx, "p1", 3)["error"]["code"], "invalid", "past the end");
        let acts: Vec<Value> = h.entries.iter().filter_map(|e| e.get("activity").cloned()).collect();
        assert_eq!(acts.iter().map(|a| a["kind"].as_str().unwrap()).collect::<Vec<_>>(), ["viewed", "played"]);
        assert_eq!((&acts[1]["email"], &acts[1]["detail"]["to"], &acts[1]["link"]), (&json!("anna@example.com"), &json!(80), &json!("L1")));
        assert!(acts[0].get("ip").is_none());
        assert_eq!(h.sync(&json!({"op": "admin-activity", "link": "L1"}))["activity"].as_array().unwrap().len(), 2);
        // Retention: old entries and those beyond the cap go; seqs and other entries stay.
        let old = json!({"seq": 0, "activity": {"link": "L1", "at": "2020-01-01T00:00:00Z", "kind": "opened"}});
        h.entries.insert(0, old);
        for n in 0..ACTIVITY_CAP + 5 {
            h.entries.push(json!({"seq": 1000 + n, "activity": {"link": "L2", "at": now_iso(), "kind": "played"}}));
        }
        h.compact();
        let count = |l: &str| h.entries.iter().filter(|e| e["activity"]["link"] == l).count();
        assert_eq!((count("L1"), count("L2")), (2, ACTIVITY_CAP));
        assert_eq!(h.entries.iter().filter(|e| e["activity"]["link"] == "L2").next().unwrap()["seq"], 1005, "the oldest dropped");
        let on_disk = std::fs::read_to_string(&h.log_path).unwrap().lines().count();
        assert_eq!(on_disk, h.entries.len());
        // R8: the manifest's activityDays (Pluck's setting): 30 drops a 60-day-old entry, 0 keeps everything.
        let at = |days: i64| iso(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64 - days * 86_400);
        let mut m = sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))]));
        m["activityDays"] = json!(0);
        h.publish(&m, &json!({}));
        h.entries.push(json!({"seq": 90_000, "activity": {"link": "L3", "at": "2020-01-01T00:00:00Z", "kind": "opened"}}));
        h.compact();
        let l3 = |h: &Host| h.entries.iter().filter(|e| e["activity"]["link"] == "L3").count();
        assert_eq!(l3(&h), 1, "forever keeps it");
        m["activityDays"] = json!(30);
        h.publish(&m, &json!({}));
        assert_eq!(h.raw["activityDays"], 30);
        h.entries.push(json!({"seq": 90_001, "activity": {"link": "L3", "at": at(60), "kind": "opened"}}));
        h.entries.push(json!({"seq": 90_002, "activity": {"link": "L3", "at": at(10), "kind": "opened"}}));
        h.compact();
        assert_eq!(l3(&h), 1, "only the 10-day-old one stays");
    }

    #[test]
    fn proxy_watermark_and_new_fetch_kinds() {
        let (mut h, mut rx) = test_host();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        (l["allowProxy"], l["allowDownload"]) = (json!(true), json!(true));
        let mut b = link("LB", "RB", json!({"kind": "project", "id": "P"}));
        (b["allowDownload"], b["watermark"]) = (json!(true), json!({"text": "{name}", "burned": true}));
        let mut m = sample(json!([l, b]));
        let v = &mut m["projects"][0]["assets"][0]["versions"][0];
        (v["renditions"], v["original"], v["fpsNum"], v["fpsDen"]) = (json!(["1080", "2160"]), json!("originals/V.mov"), json!(25), json!(1));
        m["projects"][0]["assets"].as_array_mut().unwrap().push(json!({"id": "D", "name": "Deck", "kind": "document", "folder": null,
            "versions": [{"id": "DV", "number": 1, "pages": 2, "frames": 0}]}));
        h.publish(&m, &json!({}));
        let c = h.dir.join("copies/V/1080");
        std::fs::create_dir_all(&c).unwrap();
        std::fs::write(c.join("media.m4s"), vec![1u8; 3000]).unwrap();
        std::fs::write(c.join("init.mp4"), vec![2u8; 100]).unwrap();
        std::fs::write(c.join("index.json"), json!({"init": {"file": "init.mp4", "offset": 0, "length": 100},
            "segments": [{"file": "media.m4s", "offset": 0, "length": 1000}, {"file": "media.m4s", "offset": 1000, "length": 2000}]}).to_string()).unwrap();
        std::fs::write(h.dir.join("copies/V/captions.vtt"), "WEBVTT\n").unwrap();
        std::fs::write(h.dir.join("copies/V/waveform.json"), r#"{"buckets":2,"peaks":[1,2],"channels":1}"#).unwrap();
        std::fs::create_dir_all(h.dir.join("copies/DV/pages")).unwrap();
        std::fs::write(h.dir.join("copies/DV/pages/2.jpg"), [0xFF, 0xD8, 0xFF]).unwrap();
        let link1 = h.link("R1").unwrap().clone();
        let fetch = |h: &Host, l: &Value, what: &str, extra: Value| {
            let mut m = json!({"asset": "A", "version": "V", "what": what});
            for (k, v) in extra.as_object().unwrap() { m[k] = v.clone() }
            h.resolve(l, &m)
        };
        let Ok(Resolved::File { parts, name, kind, .. }) = fetch(&h, &link1, "proxy", json!({})) else { panic!() };
        assert_eq!(parts.iter().map(|p| (p.1, p.2)).collect::<Vec<_>>(), [(0, 100), (0, 3000)], "init, then the segments as one range");
        assert_eq!((name.as_deref(), kind.as_str()), (Some("Cut v1 (review).mp4"), "video/mp4"));
        assert!(matches!(fetch(&h, &link1, "captions", json!({})), Ok(Resolved::File { ref kind, .. }) if kind == "text/vtt"));
        assert!(matches!(fetch(&h, &link1, "waveform", json!({})), Ok(Resolved::Inline(ref j)) if j["peaks"] == json!([1, 2])));
        assert!(matches!(fetch(&h, &link1, "transcript", json!({})), Err("notFound")));
        assert!(matches!(fetch(&h, &link1, "still", json!({"frame": 100})), Err("invalid")), "past the end");
        assert!(matches!(fetch(&h, &link1, "still", json!({"frame": 50})), Ok(Resolved::Still { t, .. }) if t == 2.0));
        let doc = json!({"asset": "D", "version": "DV", "what": "page"});
        assert!(h.resolve(&link1, &{ let mut d = doc.clone(); d["n"] = json!(2); d }).is_ok());
        assert!(matches!(h.resolve(&link1, &{ let mut d = doc.clone(); d["n"] = json!(3); d }), Err("invalid")));
        // Burned watermark: originals never, and the picture waits for this link's own copy.
        let lb = h.link("RB").unwrap().clone();
        assert!(matches!(fetch(&h, &lb, "original", json!({})), Err("scope")));
        assert!(matches!(fetch(&h, &lb, "segment", json!({"rendition": "1080", "n": 0})), Err("notReady")));
        assert!(matches!(fetch(&h, &lb, "proxy", json!({})), Err("notReady")));
        ready_peer(&mut h, "pb", "RB");
        sent(&mut rx);
        h.request("pb", &json!({"id": 1, "t": "asset", "asset": "A"}));
        let burned = answer(&mut rx, "pb", 1)["asset"]["versions"][0].clone();
        assert_eq!((burned["canDownload"].clone(), burned["renditions"].clone()), (json!(false), json!(["1080"])), "its own copies have no 4K");
        std::fs::create_dir_all(h.dir.join("copies/V/wm-LB/1080")).unwrap(); // pushed by Pluck
        assert!(matches!(fetch(&h, &lb, "segment", json!({"rendition": "1080", "n": 0})), Err("notReady")), "no index.json yet");
        std::fs::copy(c.join("index.json"), h.dir.join("copies/V/wm-LB/1080/index.json")).unwrap();
        let Ok(Resolved::File { parts, .. }) = fetch(&h, &lb, "segment", json!({"rendition": "1080", "n": 1})) else { panic!() };
        assert!(parts[0].0.contains("wm-LB"));
        // A finished proxy download is logged.
        ready_peer(&mut h, "p1", "R1");
        h.request("p1", &json!({"id": 7, "t": "fetch", "asset": "A", "version": "V", "what": "proxy"}));
        assert_eq!(answer(&mut rx, "p1", 7)["size"], 3100);
        h.report(&json!({"served": {"peer": "p1", "fetch": 7, "bytes": 3100, "result": "done"}}));
        assert!(h.entries.iter().any(|e| e["activity"]["kind"] == "downloaded" && e["activity"]["detail"]["what"] == "proxy"));
    }

    #[test]
    fn uploads_and_attachments() {
        let (mut h, mut rx) = test_host();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        l["uploads"] = json!({"folder": null, "maxBytes": 1000, "types": ["image", "video"]});
        h.publish(&sample(json!([l, link("L2", "R2", json!({"kind": "project", "id": "P"}))])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        named_peer(&mut h, "p2", "R2", "t2", "Ben");
        sent(&mut rx);
        let begin = |h: &mut Host, peer: &str, id: u64, name: &str, size: u64, f: &str| h.request(peer, &json!({"id": id, "t": "upload-begin", "name": name, "size": size, "for": f}));
        begin(&mut h, "p2", 1, "a.png", 10, "attachment");
        begin(&mut h, "p1", 2, "a.exe", 10, "asset");
        begin(&mut h, "p1", 3, "notes.pdf", 10, "asset");
        begin(&mut h, "p1", 4, "big.mov", 1001, "asset");
        begin(&mut h, "p1", 5, "huge.png", 60 << 20, "attachment");
        let a = sent(&mut rx);
        let code = |re: u64| a.iter().find(|s| s["msg"]["re"] == re).unwrap()["msg"]["error"]["code"].clone();
        assert_eq!([code(1), code(2), code(3), code(4), code(5)], [json!("scope"), json!("invalid"), json!("invalid"), json!("tooLarge"), json!("tooLarge")]);
        begin(&mut h, "p1", 6, "../../etc/ref.png", 5, "attachment");
        let c = cmds(&mut rx);
        let accept = c.iter().position(|c| c.get("accept").is_some()).unwrap();
        let reply = c.iter().position(|c| c["send"]["msg"]["re"] == 6).unwrap();
        assert!(accept < reply, "the helper hears accept before the browser hears the reply");
        assert_eq!(c[reply]["send"]["msg"]["credit"], 8 << 20);
        let part = PathBuf::from(c[accept]["accept"]["path"].as_str().unwrap());
        assert!(part.starts_with(h.data.join("uploads/.partial")));
        std::fs::write(&part, b"hello").unwrap(); // what the helper would have written
        let sha = keys::sha256_b64(b"hello");
        h.request("p1", &json!({"id": 7, "t": "upload-end", "upload": 6, "sha256": sha}));
        assert_eq!(answer(&mut rx, "p1", 7), Value::Null, "waits for the helper");
        h.report(&json!({"upload": {"peer": "p1", "upload": 6, "state": "done", "bytes": 5, "sha256": sha}}));
        let att = answer(&mut rx, "p1", 7)["attachment"].clone();
        assert_eq!((&att["name"], &att["type"], &att["size"]), (&json!("ref.png"), &json!("image/png"), &json!(5)), "no folders in the name");
        let entry = h.entries.iter().rev().find_map(|e| e.get("upload")).unwrap().clone();
        let stored = h.data.join(entry["path"].as_str().unwrap());
        assert!(stored.starts_with(h.data.join("uploads/L1")) && stored.extension().unwrap() == "png" && std::fs::read(&stored).unwrap() == b"hello");
        assert!(!part.exists());
        // The attachment on a comment, then fetched by a viewer of the same link only.
        h.request("p2", &json!({"id": 8, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "x", "attachments": [att["id"]]}));
        assert_eq!(answer(&mut rx, "p2", 8)["error"]["code"], "invalid", "another link's upload");
        h.request("p1", &json!({"id": 9, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "see this", "attachments": [att["id"]]}));
        assert_eq!(answer(&mut rx, "p1", 9)["comment"]["attachments"][0]["id"], att["id"]);
        let l1 = h.link("R1").unwrap().clone();
        let Ok(Resolved::File { parts, name, .. }) = h.resolve(&l1, &json!({"asset": "A", "version": "V", "what": "attachment", "attachment": att["id"]})) else { panic!() };
        assert_eq!((parts[0].0.as_str(), name.as_deref()), (stored.to_string_lossy().as_ref(), Some("ref.png")));
        // A wrong hash fails and leaves nothing; in-flight limit per link.
        begin(&mut h, "p1", 10, "b.png", 3, "attachment");
        let part = PathBuf::from(cmds(&mut rx).into_iter().find_map(|c| c["accept"]["path"].as_str().map(str::to_owned)).unwrap());
        std::fs::write(&part, b"abc").unwrap();
        h.report(&json!({"upload": {"peer": "p1", "upload": 10, "state": "done", "bytes": 3, "sha256": keys::sha256_b64(b"abc")}}));
        h.request("p1", &json!({"id": 11, "t": "upload-end", "upload": 10, "sha256": "wrong"}));
        assert_eq!(answer(&mut rx, "p1", 11)["error"]["code"], "invalid");
        assert!(!part.exists());
        for id in 20..24 { begin(&mut h, "p1", id, "c.png", 1, "attachment") }
        begin(&mut h, "p1", 24, "c.png", 1, "attachment");
        assert_eq!(answer(&mut rx, "p1", 24)["error"]["code"], "limit");
        h.request("p1", &json!({"t": "cancel", "upload": 20}));
        assert!(cmds(&mut rx).iter().any(|c| c["cancel"]["upload"] == 20));
        h.report(&json!({"peer": {"peer": "p1", "state": "closed"}}));
        assert!(h.uploads.is_empty(), "a peer's uploads end with it");
    }

    #[tokio::test]
    async fn deadlines_close_links_but_keep_their_rooms() {
        let (mut h, mut rx) = test_host();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        l["deadline"] = json!("2030-01-01T10:00:00.000+02:00");
        let mut m = sample(json!([l, link("L2", "R2", json!({"kind": "project", "id": "P"}))]));
        m["projects"][0]["deadline"] = json!("2020-01-01T00:00:00Z"); // the project's: past
        h.publish(&m, &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        h.request("p1", &json!({"id": 1, "t": "list", "folder": null}));
        assert!(answer(&mut rx, "p1", 1)["assets"].is_array(), "the link's own deadline wins over the project's");
        assert_eq!(h.deadline(h.link("R1").unwrap()).as_deref(), Some("2030-01-01T08:00:00Z"));
        let mut far = link("L3", "R3", json!({"kind": "project", "id": "P"}));
        far["deadline"] = json!("4001-01-01T00:00:00Z"); // reopened without a deadline
        assert_eq!(h.deadline(&far), None, "a far-future deadline is no deadline");
        h.report(&json!({"peer": {"peer": "p2", "state": "open", "room": "R2"}}));
        h.request("p2", &json!({"id": 2, "t": "auth"}));
        let e = answer(&mut rx, "p2", 2);
        assert_eq!((e["error"]["code"].clone(), e["error"]["at"].clone()), (json!("deadline"), json!("2020-01-01T00:00:00Z")), "before the proof check");
        h.peers.remove("p2");
        // The owner moves L1's deadline into the past: its peer hears the change and a bye; both rooms stay.
        let mut m2 = m.clone();
        m2["links"][0]["deadline"] = json!("2021-01-01T00:00:00Z");
        cmds(&mut rx);
        h.publish(&m2, &json!({}));
        let c = cmds(&mut rx);
        assert!(c.iter().any(|c| c["send"]["peer"] == "p1" && c["send"]["msg"] == json!({"t": "deadline", "deadline": "2021-01-01T00:00:00Z"})));
        assert!(c.iter().any(|c| c["send"]["peer"] == "p1" && c["send"]["msg"] == json!({"t": "bye", "code": "deadline", "at": "2021-01-01T00:00:00Z"})));
        h.check_links();
        let rooms = cmds(&mut rx).into_iter().find(|c| c.get("rooms").is_some()).unwrap();
        assert_eq!(rooms["rooms"].as_array().unwrap().len(), 2, "a reopened link works again with no new key");
        assert_eq!(norm_iso("2026-11-16T10:00:00.5-01:30").as_deref(), Some("2026-11-16T11:30:00Z"));
    }

    #[test]
    fn appends_merge_and_repeat_harmlessly() {
        let (mut h, _rx) = test_host();
        let c = |rev: u64, replies: Value| json!({"comment": {"id": "C", "asset": "A", "version": "V", "text": "x", "rev": rev, "at": "2026-11-16T10:00:00Z", "by": "M", "replies": replies}});
        let n = |h: &mut Host, e: Value| h.sync(&json!({"op": "append", "entries": [e]}))["appended"].as_u64().unwrap();
        assert_eq!(n(&mut h, c(2, json!([{"id": "r1"}, {"id": "r4"}]))), 1);
        assert_eq!(n(&mut h, c(2, json!([{"id": "r1"}, {"id": "r4"}]))), 0, "the same (id, rev) again: nothing");
        assert_eq!(n(&mut h, c(1, json!([{"id": "r1"}, {"id": "r3"}]))), 1, "an older copy still adds its reply (MC)");
        let ids: Vec<&str> = h.comments[0]["replies"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap()).collect();
        assert_eq!((ids, h.comments[0]["rev"].clone()), (vec!["r1", "r3", "r4"], json!(2)));
        let pulled = h.sync(&json!({"op": "pull", "since": 0}));
        assert_eq!(pulled["entries"].as_array().unwrap().last().unwrap()["comment"]["replies"].as_array().unwrap().len(), 3, "pull carries the merged result");
        let ap = json!({"approval": {"id": "AP", "asset": "A", "version": "V", "decision": "approve"}});
        let act = json!({"activity": {"id": "X1", "link": "L1", "at": now_iso(), "kind": "opened"}});
        assert_eq!((n(&mut h, ap.clone()), n(&mut h, ap), n(&mut h, act.clone()), n(&mut h, act)), (1, 0, 1, 0), "by id");
        assert_eq!(n(&mut h, json!({"deleted": {"id": "C", "rev": 1}})), 0, "an older tombstone loses to rev 2");
        assert_eq!(n(&mut h, json!({"deleted": {"id": "C", "rev": 2}})), 1);
        assert!(h.comments.is_empty());
        assert_eq!(n(&mut h, c(2, json!([]))), 0, "a tombstone beats every comment with rev ≤ its own");
        assert_eq!(n(&mut h, c(3, json!([]))), 1);
    }

    /// Fastest-host routing: a backup tells the Room a link is ready once the current version of every asset in
    /// scope is copied, and never for a link with uploads or downloads (those stay with the main); a main never is.
    #[tokio::test]
    async fn a_backup_is_ready_for_a_link_once_its_current_versions_are_here() {
        let (mut h, mut rx) = test_host();
        h.ident.backup = true;
        let mut up = link("L2", "R2", json!({"kind": "asset", "id": "A"}));
        up["uploads"] = json!({});
        let mut dl = link("L3", "R3", json!({"kind": "asset", "id": "A"}));
        dl["allowDownload"] = json!(true);
        let all = link("L4", "R4", json!({"kind": "project", "id": "P"}));
        let gone = link("L5", "R5", json!({"kind": "asset", "id": "GONE"}));
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "asset", "id": "A"})), up, dl, all, gone])), &json!({}));
        let ready = |rx: &mut mpsc::UnboundedReceiver<Ev>| -> Vec<bool> {
            let r = cmds(rx).into_iter().rev().find(|c| c.get("rooms").is_some()).unwrap();
            ["R1", "R2", "R3", "R4", "R5"].iter().map(|id| r["rooms"].as_array().unwrap().iter().find(|x| x["room"] == *id).unwrap()["ready"] == true).collect()
        };
        assert_eq!(ready(&mut rx), [false; 5], "nothing copied yet: the main serves");
        std::fs::create_dir_all(h.dir.join("copies/V")).unwrap();
        std::fs::write(h.dir.join("copies/V/ready.json"), json!({"renditions": [], "probe": {}}).to_string()).unwrap();
        h.reload();
        assert_eq!(ready(&mut rx), [true, false, false, false, false], "V is here: only the plain link to A (B's W isn't; nothing is in R5's scope)");
        h.ident.backup = false;
        h.reload();
        assert_eq!(ready(&mut rx), [false; 5], "a main is never a standby");
    }

    /// A comment, approval or field made on a backup (its viewers while the main is online, or in an outage)
    /// starts a sync round at once; entries from the main and activity lines don't.
    #[tokio::test]
    async fn a_backup_sends_its_own_comments_to_the_main_at_once() {
        let (mut h, _rx) = test_host();
        h.ident.backup = true;
        let r = crate::replica::Shared::load(&h.data, 1 << 30, "same");
        h.replica = Some(r.clone());
        let c = |id: &str| json!({"comment": {"id": id, "asset": "A", "version": "V", "text": "x", "rev": 1, "replies": []}});
        let mut from_main = c("M1");
        from_main["seq"] = json!(3);
        h.sync(&json!({"op": "_replica-entries", "entries": [from_main]}));
        h.sync(&json!({"op": "append", "entries": [{"activity": {"id": "X1", "link": "L1", "at": now_iso(), "kind": "opened"}}]}));
        assert!(!r.nudged().await, "the main's entries and activity wait for the round");
        h.sync(&json!({"op": "append", "entries": [c("B1")]}));
        assert!(r.nudged().await, "own comment: a round now");
        assert_eq!(h.sync(&json!({"op": "_replica-own", "since": 0}))["entries"].as_array().unwrap().len(), 2, "B1 and the activity go up");
    }

    #[test]
    fn library_newest_wins() {
        let (mut h, _rx) = test_host();
        assert_eq!(h.sync(&json!({"op": "library"})), json!({"library": null}));
        let a = json!({"v": 1, "at": "2026-11-20T10:00:00Z", "statuses": [{"id": "c:abc", "name": "Graded", "colour": "accent", "builtin": false}]});
        assert_eq!(h.sync(&json!({"op": "library-set", "library": a}))["library"], a);
        let older = json!({"v": 1, "at": "2026-11-19T10:00:00Z"});
        assert_eq!(h.sync(&json!({"op": "library-set", "library": older}))["library"], a, "an older one is answered with what's kept");
        assert_eq!(h.sync(&json!({"op": "library"}))["library"], a);
        assert_eq!(h.sync(&json!({"op": "library-set", "library": "x"}))["error"]["code"], "invalid");
        h.ident.backup = true;
        assert_eq!(h.sync(&json!({"op": "library-set", "library": a}))["error"], "unknown op", "only the main keeps it");
    }

    #[test]
    fn prefer_fastest_is_the_mains_setting() {
        let (mut h, _rx) = test_host();
        assert_eq!(h.sync(&json!({"op": "prefer-fastest", "on": true})), json!({"ok": true, "preferFastest": true}));
        let f: Value = serde_json::from_slice(&std::fs::read(h.data.join("serving.json")).unwrap()).unwrap();
        assert_eq!(f, json!({"preferFastest": true}));
        assert!(h.sync(&json!({"op": "status"})).get("uplinkMbps").is_some());
        h.sync(&json!({"op": "prefer-fastest", "on": false}));
        h.ident.backup = true;
        assert_eq!(h.sync(&json!({"op": "prefer-fastest", "on": true}))["error"], "unknown op", "not on a backup");
    }

    #[test]
    fn a_backup_pushes_only_its_own_entries_once() {
        let (mut h, _rx) = test_host();
        h.ident.backup = true;
        let from_main = json!({"seq": 7, "comment": {"id": "M1", "asset": "A", "version": "V", "text": "main", "rev": 1, "replies": []}});
        h.sync(&json!({"op": "_replica-entries", "entries": [from_main.clone()]}));
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "B1", "asset": "A", "version": "V", "text": "here", "rev": 1, "replies": []}}]}));
        let own = h.sync(&json!({"op": "_replica-own", "since": 0}));
        let ids: Vec<&Value> = own["entries"].as_array().unwrap().iter().map(|e| &e["comment"]["id"]).collect();
        assert_eq!(ids, [&json!("B1")], "the main's entries never go back");
        let last = own["entries"][0]["seq"].as_u64().unwrap();
        assert!(h.sync(&json!({"op": "_replica-own", "since": last}))["entries"].as_array().unwrap().is_empty());
        // The main hands B1 back in its pull: no duplicate here.
        let back = json!({"seq": 8, "comment": {"id": "B1", "asset": "A", "version": "V", "text": "here", "rev": 1, "replies": []}});
        assert_eq!(h.sync(&json!({"op": "_replica-entries", "entries": [back, from_main]}))["appended"], 0);
        assert_eq!(h.comments.len(), 2);
    }

    #[tokio::test]
    async fn approvals_carry_proof_data_and_the_proof_is_served() {
        let (mut h, mut rx) = test_host();
        let mut m = sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"}))]));
        m["projects"][0]["assets"][0]["versions"][0]["sha256"] = json!("ab".repeat(32));
        m["projects"][0]["assets"][0]["versions"][0]["originalName"] = json!("Cut v1.mov");
        h.publish(&m, &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        h.peers.get_mut("p1").unwrap().email = "anna@example.com".into();
        h.request("p1", &json!({"id": 1, "t": "approve", "asset": "A", "version": "V", "decision": "approve"}));
        let r = answer(&mut rx, "p1", 1);
        assert_eq!((r["status"].clone(), r["approval"]["proof"].clone(), r["asset"]["id"].clone()), (json!("approved"), json!(true), json!("A")));
        let ap = h.approvals[0].clone();
        assert_eq!((ap["email"].clone(), ap["file"].clone(), ap["versionNumber"].clone(), ap["hashOf"].clone()),
            (json!("anna@example.com"), json!("Cut v1.mov"), json!(1), json!("original")));
        h.request("p1", &json!({"id": 2, "t": "asset", "asset": "A"}));
        assert_eq!(answer(&mut rx, "p1", 2)["approvals"][0]["id"], ap["id"]);
        h.request("p1", &json!({"id": 3, "t": "fetch", "what": "proof", "approval": ap["id"]}));
        let c = cmds(&mut rx);
        let reply = c.iter().find(|c| c["send"]["msg"]["re"] == 3).unwrap()["send"]["msg"].clone();
        assert_eq!((reply["type"].clone(), reply["name"].clone()), (json!("application/pdf"), json!("Approval – Cut v1.pdf")));
        let path = c.iter().find_map(|c| c["serve"]["pieces"][0]["path"].as_str().map(PathBuf::from)).unwrap();
        assert!(std::fs::read(&path).unwrap().starts_with(b"%PDF-1.4"));
        h.report(&json!({"served": {"peer": "p1", "fetch": 3, "bytes": 1, "result": "done"}}));
        assert!(!path.exists(), "the temp PDF goes once served");
        // Another link doesn't get this link's proof.
        let mut m2 = m.clone();
        m2["links"].as_array_mut().unwrap().push(link("L2", "R2", json!({"kind": "project", "id": "P"})));
        h.publish(&m2, &json!({}));
        named_peer(&mut h, "p2", "R2", "t2", "Ben");
        h.request("p2", &json!({"id": 4, "t": "fetch", "what": "proof", "approval": ap["id"]}));
        assert_eq!(answer(&mut rx, "p2", 4)["error"]["code"], "scope");
    }

    #[test]
    fn preparing_an_update_stops_new_uploads_and_copies() {
        let (mut h, mut rx) = test_host();
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        l["uploads"] = json!({"folder": null});
        h.publish(&sample(json!([l])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        assert_eq!(h.sync(&json!({"op": "prepare-update"})), json!({"busy": false}));
        h.request("p1", &json!({"id": 1, "t": "upload-begin", "name": "a.png", "size": 1, "for": "attachment"}));
        assert_eq!(answer(&mut rx, "p1", 1)["error"]["code"], "limit");
        assert_eq!(h.sync(&json!({"op": "cancel-update"}))["ok"], true);
        h.request("p1", &json!({"id": 2, "t": "upload-begin", "name": "a.png", "size": 1, "for": "attachment"}));
        assert!(answer(&mut rx, "p1", 2)["upload"].is_u64());
        let busy = h.sync(&json!({"op": "prepare-update"}));
        assert_eq!((busy["busy"].clone(), busy["why"].clone()), (json!(true), json!(["upload"])));
        let st = h.sync(&json!({"op": "status"}));
        assert_eq!((st["protocol"].clone(), st["role"].clone()), (json!(3), json!("main")));
    }

    #[test]
    fn a_failed_proof_hash_is_tried_again() {
        let (mut h, _rx) = test_host();
        h.proof_hashes.insert("AP".into(), json!({"failed": true}));
        assert_eq!(h.proof_hash(&json!({"id": "AP", "version": "V"})), Err("internal"));
        assert!(!h.proof_hashes.contains_key("AP"), "not cached: the next fetch hashes again");
    }

    #[test]
    fn a_backup_refuses_uploads() {
        let (mut h, mut rx) = test_host();
        h.ident.backup = true;
        let mut l = link("L1", "R1", json!({"kind": "project", "id": "P"}));
        l["uploads"] = json!({"folder": null});
        h.publish(&sample(json!([l])), &json!({}));
        named_peer(&mut h, "p1", "R1", "t1", "Anna");
        h.request("p1", &json!({"id": 1, "t": "upload-begin", "name": "a.png", "size": 1, "for": "attachment"}));
        assert_eq!(answer(&mut rx, "p1", 1)["error"]["code"], "scope");
        // §13.25: once its main takes them on (and only then), the same limits as the main, kept for the main.
        let o = crate::outage::Outage::load(&h.data, true, None);
        h.outage = Some(o.clone());
        h.request("p1", &json!({"id": 2, "t": "upload-begin", "name": "a.png", "size": 1, "for": "attachment"}));
        assert_eq!(answer(&mut rx, "p1", 2)["error"]["code"], "scope", "a main that can't take them on");
        o.set_main(true);
        h.request("p1", &json!({"id": 3, "t": "upload-begin", "name": "a.exe", "size": 1, "for": "asset"}));
        assert_eq!(answer(&mut rx, "p1", 3)["error"]["code"], "invalid", "the same checks");
        h.request("p1", &json!({"id": 4, "t": "upload-begin", "name": "a.png", "size": 60 << 20, "for": "attachment"}));
        assert_eq!(answer(&mut rx, "p1", 4)["error"]["code"], "tooLarge");
        h.request("p1", &json!({"id": 5, "t": "upload-begin", "name": "Shot.png", "size": 3, "for": "asset"}));
        assert!(answer(&mut rx, "p1", 5)["upload"].is_u64());
        let part = h.uploads[&("p1".to_owned(), 5)].part.clone();
        std::fs::write(&part, b"abc").unwrap();
        let sha = keys::sha256_b64(b"abc");
        h.report(&json!({"upload": {"peer": "p1", "upload": 5, "state": "done", "bytes": 3, "sha256": sha}}));
        h.request("p1", &json!({"id": 6, "t": "upload-end", "upload": 5, "sha256": sha}));
        let done = answer(&mut rx, "p1", 6);
        assert_eq!((done["uploaded"]["name"].clone(), done["later"].clone()), (json!("Shot.png"), json!(true)), "the page says it's kept for later");
        let items = o.items();
        assert_eq!((items.len(), items[0]["kind"].clone(), items[0]["link"].clone(), items[0]["sha256"].clone()), (1, json!("asset"), json!("L1"), json!(sha)));
        assert_eq!(std::fs::read(h.data.join(items[0]["file"].as_str().unwrap())).unwrap(), b"abc", "in its own quarantine");
        assert!(items[0]["file"].as_str().unwrap().starts_with("uploads/L1/"));
        assert!(h.sync(&json!({"op": "_replica-own", "since": 0}))["entries"].as_array().unwrap().iter().all(|e| e.get("upload").is_none()),
            "the file goes by the outage push, not as an entry");
    }

    /// The main logs a pushed upload once by its id, however often it's handed over.
    #[test]
    fn an_outage_entry_is_logged_once() {
        let (mut h, _rx) = test_host();
        let e = json!({"id": "U1", "link": "L1", "name": "a.png", "path": "uploads/L1/U1.png", "for": "attachment"});
        assert_eq!(h.sync(&json!({"op": "_outage-entry", "entry": e})), json!({"ok": true}));
        assert_eq!(h.sync(&json!({"op": "_outage-entry", "entry": e})), json!({"ok": true}));
        assert_eq!(h.entries.iter().filter(|x| x["upload"]["id"] == "U1").count(), 1);
        assert!(h.attachments.contains_key("U1"), "a comment's attachment finds it");
    }

    #[test]
    fn replica_apply_takes_branding_and_activity_days() {
        let (mut h, _rx) = test_host();
        let r = h.sync(&json!({"op": "_replica-apply", "branding": {"name": "Studio", "accent": "#336699"}, "activityDays": 30}));
        assert!(r.get("error").is_none(), "{r}");
        assert_eq!((h.raw["branding"]["accent"].clone(), h.raw["activityDays"].clone()), (json!("#336699"), json!(30)));
        h.sync(&json!({"op": "_replica-apply"}));
        assert_eq!(h.raw["branding"]["accent"], "#336699", "a page without branding leaves it");
        h.sync(&json!({"op": "_replica-apply", "branding": null}));
        assert!(h.raw.get("branding").is_none(), "the main has none: gone here too");
    }

    #[test]
    fn merge_publish_through_the_host() {
        let (mut h, _rx) = test_host();
        let mut m = sample(json!([]));
        m["projects"][0]["rev"] = json!(1);
        m["projects"][0]["assets"][0]["rev"] = json!(5);
        let r = h.sync(&json!({"op": "publish", "merge": true, "manifest": m, "tombstones": []}));
        assert_eq!((r["ok"].clone(), r["stale"].clone()), (json!(true), json!([])));
        let mut old = sample(json!([]));
        old["projects"][0]["assets"][0]["rev"] = json!(4);
        old["projects"][0]["assets"][0]["name"] = json!("Stale name");
        let r = h.sync(&json!({"op": "publish", "merge": true, "manifest": old}));
        assert!(r["stale"].as_array().unwrap().contains(&json!("A")));
        assert_eq!(h.raw["projects"][0]["assets"][0]["name"], "Cut");
        let c = h.sync(&json!({"op": "changes", "since": 0}));
        assert_eq!(c["assets"].as_array().unwrap().len(), 2);
        let seq = c["storeSeq"].as_u64().unwrap();
        h.sync(&json!({"op": "publish", "merge": true, "manifest": {"format": 1}, "tombstones": [{"kind": "asset", "id": "B", "project": "P", "rev": 9, "at": now_iso(), "by": "M"}]}));
        let c = h.sync(&json!({"op": "changes", "since": seq}));
        assert_eq!((c["removed"][0]["id"].clone(), c["assets"].as_array().unwrap().len()), (json!("B"), 0));
    }

    #[test]
    fn a_published_version_is_announced_once_its_copy_is_ready() {
        let (mut h, mut rx) = test_host();
        let mut lo = link("L2", "R2", json!({"kind": "project", "id": "P"}));
        lo["latestOnly"] = json!(true);
        h.publish(&sample(json!([link("L1", "R1", json!({"kind": "project", "id": "P"})), lo])), &json!({}));
        ready_peer(&mut h, "p1", "R1");
        ready_peer(&mut h, "p2", "R2");
        cmds(&mut rx);
        let mut m = h.raw.clone();
        m["projects"][0]["assets"][0]["versions"].as_array_mut().unwrap().push(json!({"id": "V2", "number": 2, "frames": 100}));
        m["projects"][0]["assets"][0]["rev"] = json!(m["projects"][0]["assets"][0]["rev"].as_u64().unwrap() + 1);
        h.sync(&json!({"op": "publish", "merge": true, "manifest": m}));
        let ev: Vec<Value> = sent(&mut rx).into_iter().filter(|s| s["msg"]["t"] == "version-added").collect();
        assert_eq!(ev.len(), 1, "not to the latestOnly link");
        assert_eq!((ev[0]["peer"].clone(), ev[0]["msg"]["number"].clone(), ev[0]["msg"]["name"].clone()), (json!("p1"), json!(2), json!("Cut")));
    }

    fn answer_id(h: &Host, text: &str) -> Value {
        h.comments.iter().find(|c| c["text"] == text).unwrap()["id"].clone()
    }

    /// Email (4.1.0): mentions, subscribe, who hears what, and nothing internal (nor mailCode) ever reaching a client.
    #[test]
    fn mail_mentions_subscribe_and_audience() {
        let (mut h, mut rx) = test_host();
        let mut c = link("LC", "RC", json!({"kind": "project", "id": "P"}));
        c["notify"] = json!({"email": true, "recipientEmail": null, "mailCode": "KEYCODE.PUB"});
        let mut t = link("LT", "RT", json!({"kind": "project", "id": "P"}));
        t["audience"] = json!("team");
        let plain = link("LP", "RP", json!({"kind": "project", "id": "P"}));
        h.publish(&sample(json!([c, t, plain])), &json!({}));
        assert_eq!(h.mail.set(&json!({"enabled": true, "server": "smtp.example.com", "port": 587, "security": "starttls", "user": "u",
            "from": "Studio <studio@example.com>", "replyTo": null, "digestHour": 8, "tzOffset": 60, "lang": "en"}), Some("pw"))["ok"], true);
        // The owner without accounts: a team row by hand.
        assert_eq!(h.sync(&json!({"op": "subscriber-set", "kind": "team", "email": "owner@example.com", "mode": "instant"}))["ok"], true);
        // A Mac's per-link mute merges into the row's list (the web page's mutes stay); an old Mac's whole list still replaces it.
        let owner = h.mail.subs.iter().find(|r| r["email"] == "owner@example.com").unwrap()["id"].clone();
        let set = |h: &mut Host, extra: Value| {
            let mut op = json!({"op": "subscriber-set", "id": owner, "kind": "team", "mode": "instant"});
            op.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            assert_eq!(h.sync(&op)["ok"], true);
            h.mail.subs.iter().find(|r| r["id"] == owner).unwrap()["mute"].clone()
        };
        assert_eq!(set(&mut h, json!({"mute": ["LW"]})), json!(["LW"]));
        assert_eq!(set(&mut h, json!({"mute": ["LM"], "muteLink": "LM", "muted": true})), json!(["LW", "LM"]), "web mute kept");
        assert_eq!(set(&mut h, json!({"mute": [], "muteLink": "LM", "muted": false})), json!(["LW"]));
        assert_eq!(set(&mut h, json!({"mute": [], "muteLink": "LX", "muted": false})), json!(["LW"]), "unmuting a link not muted");
        assert_eq!(set(&mut h, json!({"mute": []})), json!([]));
        named_peer(&mut h, "c1", "RC", "t1", "Client one");
        named_peer(&mut h, "c2", "RC", "t2", "Client two");
        named_peer(&mut h, "p1", "RP", "t3", "Plain");
        named_peer(&mut h, "team", "RT", "tt", "Editor");
        sent(&mut rx);
        // ready says mail only where a client may subscribe, and never carries notify or mailCode.
        let lc = h.link("RC").cloned().unwrap();
        h.ready("c1", &json!(9), &lc);
        let lp = h.link("RP").cloned().unwrap();
        h.ready("p1", &json!(10), &lp);
        let msgs = sent(&mut rx);
        assert!(!msgs.iter().any(|m| m.to_string().contains("KEYCODE") || m.to_string().contains("notify")), "mailCode stays on the host");
        let ready = |peer: &str| msgs.iter().find(|m| m["peer"] == peer && m["msg"]["t"] == "ready").unwrap()["msg"].clone();
        assert_eq!((ready("c1")["mail"].clone(), ready("c1")["mentions"].clone(), ready("p1")["mail"].clone()), (json!(true), json!(true), Value::Null));
        h.request("p1", &json!({"id": 1, "t": "subscribe", "email": "p@example.com", "mode": "instant"}));
        assert_eq!(answer(&mut rx, "p1", 1)["error"]["code"], "off", "no Email updates on that link");
        for (i, (peer, e)) in [("c1", "one@example.com"), ("c2", "two@example.com")].into_iter().enumerate() {
            h.request(peer, &json!({"id": 2 + i, "t": "subscribe", "email": e, "mode": "instant", "lang": "nl"}));
            let a = answer(&mut rx, peer, 2 + i as u64);
            assert_eq!((a["ok"].clone(), a["pending"].clone()), (json!(true), json!(true)), "a typed address waits for its confirmation");
        }
        // Double opt-in: the confirmation mail (at once, even for a daily row), then nothing else until its link is opened.
        let c1 = h.mail.subs.iter().find(|r| r["email"] == "one@example.com").unwrap().clone();
        let due = h.mail.due(now_secs());
        let (_, confirm) = due.iter().find(|(r, _)| r["id"] == c1["id"]).expect("the confirmation is due now");
        let m = h.compose(&c1, confirm).unwrap();
        let ctok = c1["confirm"].as_str().unwrap().to_owned();
        assert!(m.body.contains(&format!("https://pluck.tools/r/#KEYCODE.PUB/c/{ctok}")) && m.subject.contains("Bevestig"), "{}", m.body);
        assert!(!h.sync(&json!({"op": "mail-state"})).to_string().contains(&ctok), "the confirm token stays on the host");
        h.mail.queue.retain(|q| q["event"] != "confirm");
        h.peers.get_mut("c1").unwrap().authed = true;
        h.request("c1", &json!({"id": 40, "t": "confirm", "token": ctok}));
        assert_eq!(answer(&mut rx, "c1", 40)["confirmed"], true);
        let c2tok = h.mail.subs.iter().find(|r| r["email"] == "two@example.com").unwrap()["confirm"].clone();
        assert_eq!(h.sync(&json!({"op": "subscribe-confirm", "token": c2tok}))["confirmed"], true, "through a Mac's forward");
        assert!(h.mail.subs.iter().all(|r| r["pending"].is_null() && r["confirm"].is_null()));
        // A personal link's own address needs no confirmation; a Mac-forwarded browser subscribe does.
        let personal = h.links().find(|l| l["id"] == "LC").cloned().map(|mut l| { l["notify"]["recipientEmail"] = json!("Me@Example.com"); l }).unwrap();
        let idx = h.mail.subs.len();
        h.mail.subs.push(crate::mail::Mail::new_row("client"));
        h.mail.subs[idx]["email"] = json!("me@example.com");
        h.ask_confirm(idx, &personal);
        assert!(h.mail.subs[idx]["pending"].is_null(), "the recipient's own address");
        h.mail.subs.pop();
        let fwd = h.sync(&json!({"op": "subscriber-set", "kind": "client", "email": "three@example.com", "link": "LC", "author": "tok3", "mode": "daily"}));
        assert_eq!((fwd["ok"].clone(), fwd["pending"].clone()), (json!(true), json!(true)));
        h.mail.subs.retain(|r| r["email"] != "three@example.com");
        h.mail.queue.retain(|q| q["event"] != "confirm");
        h.request("c1", &json!({"id": 5, "t": "subscribe", "email": "not an email", "mode": "instant"}));
        assert_eq!(answer(&mut rx, "c1", 5)["error"]["code"], "invalid");
        // The editor writes only an internal comment: never mentionable on the client link.
        h.request("team", &json!({"id": 6, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "Secret budget", "internal": true,
            "mentions": [crate::mail::mention_id("t1")]}));
        sent(&mut rx);
        h.request("c2", &json!({"id": 70, "t": "comment-add", "asset": "A", "version": "V", "frame": 2, "text": "Nice"}));
        h.request("c1", &json!({"id": 7, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "Love it"}));
        let cid = answer(&mut rx, "c1", 7)["comment"]["id"].clone();
        h.request("c2", &json!({"id": 8, "t": "mentionable"}));
        let names: Vec<String> = answer(&mut rx, "c2", 8)["people"].as_array().unwrap().iter().map(|p| p["name"].as_str().unwrap().to_owned()).collect();
        assert_eq!(names, ["Client two", "Client one"], "no internal-only author on a client link");
        h.request("team", &json!({"id": 9, "t": "mentionable"}));
        assert_eq!(answer(&mut rx, "team", 9)["people"].as_array().unwrap().len(), 3, "the team link sees the editor too");
        // A foreign id is dropped; a known one is kept on the reply.
        h.request("team", &json!({"id": 10, "t": "reply-add", "comment": cid, "text": "Thanks!", "mentions": ["bogus", crate::mail::mention_id("t2")]}));
        let r = answer(&mut rx, "team", 10);
        assert_eq!(r["comment"]["replies"][0]["mentions"], json!([crate::mail::mention_id("t2")]));
        let rows = h.mail.subs.clone();
        let row = |email: &str| rows.iter().find(|r| r["email"] == email).unwrap()["id"].clone();
        let queued = |h: &Host, to: &Value| h.mail.queue.iter().filter(|q| q["to"] == *to).map(|q| q["event"].as_str().unwrap().to_owned()).collect::<Vec<_>>();
        assert_eq!(queued(&h, &row("one@example.com")), ["reply"], "c1: the reply in their thread, never the internal comment (nor its mention)");
        assert_eq!(queued(&h, &row("two@example.com")), ["mention"], "c2: mentioned");
        assert_eq!(queued(&h, &row("owner@example.com")), ["comment", "comment", "comment", "reply"], "the team hears everything");
        h.request("team", &json!({"id": 12, "t": "comment-add", "asset": "A", "version": "V", "frame": 3, "text": "Internal ping", "internal": true,
            "mentions": [crate::mail::mention_id("t1")]}));
        assert_eq!(answer(&mut rx, "team", 12)["comment"]["mentions"], json!([crate::mail::mention_id("t1")]), "kept on the team's comment");
        assert_eq!(queued(&h, &row("one@example.com")), ["reply"], "an internal mention never queues for a client");
        let ping = answer_id(&h, "Internal ping");
        h.mail.queue.retain(|q| q["comment"] != ping);
        // The client's mail, composed now: Dutch, the link, the stop link, nothing internal.
        let c1row = rows.iter().find(|r| r["email"] == "one@example.com").unwrap().clone();
        let items: Vec<Value> = h.mail.queue.iter().filter(|q| q["to"] == c1row["id"]).cloned().collect();
        let m = h.compose(&c1row, &items).unwrap();
        assert!(m.subject.contains("antwoordde") && m.body.contains("https://pluck.tools/r/#KEYCODE.PUB/u/") && !m.body.contains("Secret"), "{}", m.body);
        let own: Vec<Value> = h.mail.queue.iter().filter(|q| q["to"] == row("owner@example.com")).cloned().collect();
        let team_row = rows.iter().find(|r| r["email"] == "owner@example.com").unwrap().clone();
        assert!(h.compose(&team_row, &own).unwrap().body.contains("Secret budget"), "the team's mail has it");
        // Unsubscribe by the mail's token, before a name or ready: that link's row goes off.
        h.peers.get_mut("c2").unwrap().ready = false;
        h.peers.get_mut("c2").unwrap().authed = true;
        let tok = rows.iter().find(|r| r["email"] == "two@example.com").unwrap()["token"].clone();
        h.request("c2", &json!({"id": 11, "t": "unsubscribe", "token": tok}));
        assert_eq!(answer(&mut rx, "c2", 11), json!({"ok": true, "scope": "link", "re": 11}));
        assert_eq!(h.mail.subs.iter().find(|r| r["email"] == "two@example.com").unwrap()["mode"], "off");
        let st = h.sync(&json!({"op": "mail-state"})).to_string();
        assert!(!st.contains("\"token\"") && !st.contains("pw\"") && st.contains("\"queued\""), "{st}");
        // A comment pushed by sync that's old history mails nobody; a new one does.
        let n = h.mail.queue.len();
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "OLD", "asset": "A", "version": "V", "frame": 1, "text": "old", "author": "X",
            "replies": [], "created": "2020-01-01T00:00:00Z", "rev": 1}}]}));
        assert_eq!(h.mail.queue.len(), n);
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "NEW", "asset": "A", "version": "V", "frame": 1, "text": "new", "author": "X",
            "replies": [], "created": now_iso(), "rev": 1}}]}));
        assert_eq!(h.mail.queue.len(), n + 1, "the owner's row");
        // A backup never queues.
        h.ident.backup = true;
        h.sync(&json!({"op": "append", "entries": [{"comment": {"id": "NEW2", "asset": "A", "version": "V", "frame": 1, "text": "new", "author": "X",
            "replies": [], "created": now_iso(), "rev": 1}}]}));
        assert_eq!(h.mail.queue.len(), n + 1);
    }

    /// A team person's page sends one link's mute (`muteLink`/`muted`) when the host says `delta`: merged, the Mac's mutes stay.
    #[test]
    fn mail_team_subscribe_merges_one_link() {
        let (mut h, mut rx) = test_host();
        let mut c = link("LC", "RC", json!({"kind": "project", "id": "P"}));
        c["notify"] = json!({"email": true, "recipientEmail": null, "mailCode": "KEYCODE.PUB"});
        h.publish(&sample(json!([c])), &json!({}));
        h.mail.set(&json!({"enabled": true, "server": "smtp.example.com", "port": 587, "security": "starttls", "user": "u",
            "from": "studio@example.com", "replyTo": null, "digestHour": 8, "tzOffset": 60, "lang": "en"}), Some("pw"));
        h.accounts.v = json!({"team": {"id": "T", "room": {"roomID": "TR"}}, "people": [{"id": "ed", "name": "Editor", "email": "ed@example.com", "role": "editor", "passkeys": [{"id": "k"}]}]});
        named_peer(&mut h, "e1", "RC", "te", "Editor");
        h.peers.get_mut("e1").unwrap().acct.person = Some("ed".into());
        sent(&mut rx);
        let mute = |h: &Host| h.mail.subs.iter().find(|r| r["person"] == "ed").unwrap()["mute"].clone();
        h.request("e1", &json!({"id": 1, "t": "subscribe", "mode": "instant", "mute": ["LW"]}));
        assert_eq!((answer(&mut rx, "e1", 1)["ok"].clone(), mute(&h)), (json!(true), json!(["LW"])), "an older page's whole list");
        h.request("e1", &json!({"id": 2, "t": "subscribe", "mode": "instant", "muteLink": "LM", "muted": true}));
        assert_eq!((answer(&mut rx, "e1", 2)["ok"].clone(), mute(&h)), (json!(true), json!(["LW", "LM"])));
        h.request("e1", &json!({"id": 3, "t": "subscribe", "mode": "daily", "muteLink": "LW", "muted": false}));
        assert_eq!((answer(&mut rx, "e1", 3)["ok"].clone(), mute(&h)), (json!(true), json!(["LM"])));
        h.request("e1", &json!({"id": 4, "t": "subscription"}));
        let r = answer(&mut rx, "e1", 4);
        assert_eq!((r["delta"].clone(), r["mode"].clone(), r["mute"].clone()), (json!(true), json!("daily"), json!(["LM"])), "{r}");
    }

    /// A Mac's mute toggle keeps the row's mode (an unsubscribe stays); an editor Mac can't edit a team row by its id;
    /// a browser changing its address over and over gets one confirmation per 10 minutes, 3 a day.
    #[test]
    fn mail_rows_mute_scope_and_confirm_limits() {
        let (mut h, mut rx) = test_host();
        let mut c = link("LC", "RC", json!({"kind": "project", "id": "P"}));
        c["notify"] = json!({"email": true, "recipientEmail": null, "mailCode": "KEYCODE.PUB"});
        h.publish(&sample(json!([c])), &json!({}));
        h.mail.set(&json!({"enabled": true, "server": "smtp.example.com", "port": 587, "security": "starttls", "user": "u",
            "from": "studio@example.com", "replyTo": null, "digestHour": 8, "tzOffset": 60, "lang": "en"}), Some("pw"));
        assert_eq!(h.sync(&json!({"op": "subscriber-set", "kind": "team", "email": "owner@example.com", "mode": "off"}))["ok"], true);
        let owner = h.mail.subs[0]["id"].clone();
        let r = h.sync(&json!({"op": "subscriber-set", "id": owner, "kind": "team", "email": "owner@example.com", "muteLink": "LM", "muted": true}));
        assert_eq!((r["ok"].clone(), h.mail.subs[0]["mode"].clone(), h.mail.subs[0]["mute"].clone()), (json!(true), json!("off"), json!(["LM"])), "mode kept");
        assert_eq!(h.sync(&json!({"op": "subscriber-set", "id": owner, "kind": "team"}))["error"]["code"], "invalid", "no mode, no muteLink");
        let ed = h.sync(&json!({"op": "subscriber-set", "id": owner, "kind": "client", "mode": "instant", "email": "x@example.com", "_mac": {"admin": false}}));
        assert_eq!((ed["error"].clone(), h.mail.subs[0]["email"].clone()), (json!("admin"), json!("owner@example.com")), "an editor Mac, a team row's id");
        named_peer(&mut h, "c1", "RC", "t1", "Client one");
        sent(&mut rx);
        let sub = |h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, id: u64, e: &str| {
            h.request("c1", &json!({"id": id, "t": "subscribe", "email": e, "mode": "instant"}));
            answer(rx, "c1", id)
        };
        assert_eq!(sub(&mut h, &mut rx, 1, "one@example.com")["ok"], true);
        assert_eq!(sub(&mut h, &mut rx, 2, "two@example.com")["error"]["code"], "later", "a new address too soon");
        assert_eq!(sub(&mut h, &mut rx, 3, "one@example.com")["ok"], true, "the same address: no new mail, fine");
        let row = h.mail.subs.iter().position(|r| r["author"] == "t1").unwrap();
        let now = now_secs();
        h.mail.subs[row]["confirmAt"] = json!([now - 700]);
        assert_eq!(sub(&mut h, &mut rx, 4, "two@example.com")["ok"], true, "10 minutes later");
        h.mail.subs[row]["confirmAt"] = json!([now - 3000, now - 2000, now - 1000]);
        assert_eq!(sub(&mut h, &mut rx, 5, "three@example.com")["error"]["code"], "later", "3 a day");
        h.mail.subs[row]["confirmAt"] = json!([now - 90_000, now - 2000, now - 1000]);
        assert_eq!(sub(&mut h, &mut rx, 6, "three@example.com")["ok"], true, "a day later");
        // A Mac forwarding its browser's change: the same limit.
        let fwd = |h: &mut Host, e: &str| h.sync(&json!({"op": "subscriber-set", "kind": "client", "email": e, "link": "LC", "author": "tok9", "mode": "daily"}));
        assert_eq!(fwd(&mut h, "a@example.com")["ok"], true);
        assert_eq!(fwd(&mut h, "b@example.com")["error"]["code"], "later");
        assert_eq!(h.sync(&json!({"op": "hook-set", "project": "P", "url": "https://hooks.example.com/x"}))["ok"], true);
        let st = h.sync(&json!({"op": "mail-state", "_mac": {"admin": false}})).to_string();
        assert!(!st.contains("owner@example.com") && !st.contains("three@example.com") && !st.contains("hooks.example.com") && st.contains("\"enabled\":true"), "an editor's mail-state: {st}");
        assert!(h.sync(&json!({"op": "mail-state"})).to_string().contains("hooks.example.com"), "an admin's has it all");
    }

    /// A refused address (5xx on RCPT/DATA) drops that batch only; connect/tls/auth back everything off.
    #[test]
    fn mail_rejected_drops_its_batch_only() {
        let (mut h, _rx) = test_host();
        h.mail.push(vec![json!({"id": "q1", "to": "r1", "at": 0}), json!({"id": "q2", "to": "r2", "at": 0})]);
        h.mail_back("sent", json!({"ids": ["q1"], "error": {"code": "rejected", "detail": "550 no such user"}}));
        assert_eq!((h.mail.queue.len(), h.mail.backoff, h.mail.cfg["lastError"]["code"].clone()), (1, 0, json!("rejected")));
        h.mail.push(vec![json!({"id": "q1", "to": "r1", "at": 0})]);
        assert_eq!(h.mail.queue.len(), 1, "in the ledger: never queued again");
        h.mail_back("sent", json!({"ids": ["q2"], "error": {"code": "connect", "detail": "timed out"}}));
        assert!(h.mail.queue.len() == 1 && h.mail.backoff >= 60 && h.mail.retry_at > now_secs(), "kept for the retry");
    }

    /// Assignment reminders by mail (4.0.7): to the teammate's row only, once per asset and day, never a client.
    #[test]
    fn mail_remind_queues_once_for_the_teammate() {
        let (mut h, _rx) = test_host();
        h.publish(&sample(json!([])), &json!({}));
        let remind = |h: &mut Host, person: &str, overdue: bool| h.sync(&json!({"op": "mail-remind", "asset": "A", "person": person, "overdue": overdue}));
        assert_eq!(remind(&mut h, "ed", false)["error"]["code"], "off", "mail not set up");
        h.mail.set(&json!({"enabled": true, "server": "smtp.example.com", "port": 587, "security": "starttls", "user": "u",
            "from": "studio@example.com", "replyTo": null, "digestHour": 8, "tzOffset": 60, "lang": "en"}), Some("pw"));
        h.accounts.v = json!({"team": {"id": "T", "room": {"roomID": "TR"}}, "people": [
            {"id": "ed", "name": "Editor", "email": "ed@example.com", "role": "editor"},
            {"id": "cl", "name": "Client", "email": "client@example.com", "role": "client"}]});
        assert_eq!(remind(&mut h, "ed", false)["queued"], true);
        assert_eq!(remind(&mut h, "ed", true)["queued"], true);
        assert_eq!(h.mail.queue.len(), 1, "both reminders the same day, or from two Macs: one mail");
        assert_eq!((remind(&mut h, "cl", false)["queued"].clone(), remind(&mut h, "nobody", false)["queued"].clone()), (json!(false), json!(false)));
        let ev = h.sync(&json!({"op": "mail-remind", "asset": "nope", "person": "ed"}));
        assert_eq!((ev["queued"].clone(), h.mail.queue.len()), (json!(false), 1), "a client or an unknown person or asset: nothing");
        let row = h.mail.subs.iter().find(|r| r["person"] == "ed").unwrap().clone();
        assert_eq!(h.mail.queue[0]["to"], row["id"]);
        let m = h.compose(&row, &h.mail.queue.clone()).unwrap();
        assert_eq!((m.to.as_str(), m.subject.as_str()), ("ed@example.com", "Cut is due today"));
    }

    /// A host with the media root "m1" (holding "Clients" and a link "Out" to a folder outside it).
    fn drop_host(droppable: bool) -> (Host, mpsc::UnboundedReceiver<Ev>, PathBuf) {
        let dir = std::fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("pluck-drop-{}", uuid()));
        let media = dir.join("media");
        std::fs::create_dir_all(media.join("Clients")).unwrap();
        std::fs::create_dir_all(dir.join("outside")).unwrap();
        std::os::unix::fs::symlink(dir.join("outside"), media.join("Out")).unwrap();
        let (tx, rx) = mpsc::unbounded_channel();
        let mut h = Host::new(&dir.join("data"), Arc::new(Roots(vec![("m1".into(), media.clone())])), tx, None);
        if droppable {
            h.drops.insert("m1".into(), media.clone());
        }
        (h, rx, media)
    }

    /// Publishes an "Ask for Files" link (no assets, uploads only) with `into`, and a ready peer "p1" on it.
    fn ask_link(h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, into: Value) {
        let mut l = link("L1", "R1", json!({"kind": "assets", "assets": []}));
        l["uploads"] = json!({"folder": null, "maxBytes": 1000, "into": into});
        let mut m = sample(json!([l]));
        m["projects"][0]["assets"] = json!([]);
        assert_eq!(h.publish(&m, &json!({}))["ok"], true);
        named_peer(h, "p1", "R1", "t1", "Anna");
        sent(rx);
    }

    /// A whole upload of `bytes` as `name`: the entry it logged (or the error code as {"error": code}).
    fn upload(h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, re: u64, name: &str, bytes: &[u8]) -> Value {
        h.request("p1", &json!({"id": re, "t": "upload-begin", "name": name, "size": bytes.len(), "for": "asset"}));
        let c = cmds(rx);
        let Some(part) = c.iter().find_map(|c| c["accept"]["path"].as_str().map(PathBuf::from)) else {
            return json!({"error": c.iter().find(|c| c["send"]["msg"]["re"] == re).unwrap()["send"]["msg"]["error"]["code"]});
        };
        std::fs::write(&part, bytes).unwrap();
        let sha = keys::sha256_b64(bytes);
        h.report(&json!({"upload": {"peer": "p1", "upload": re, "state": "done", "bytes": bytes.len(), "sha256": sha}}));
        h.request("p1", &json!({"id": re + 1000, "t": "upload-end", "upload": re, "sha256": sha}));
        assert_eq!(answer(rx, "p1", re + 1000)["uploaded"]["name"], name, "the browser hears it as today");
        h.entries.iter().rev().find_map(|e| e.get("upload")).unwrap().clone()
    }

    #[test]
    fn uploads_into_a_folder_outside_the_root_are_refused() {
        for into in [json!({"root": "m1", "folder": "../outside"}), json!({"root": "m1", "folder": "Out"}), json!({"root": "nope", "folder": ""}),
                     json!({"root": ".uploads", "folder": ""}), json!({"root": "m1", "folder": "Missing"}), json!({"root": "m1", "folder": "Clients/"}),
                     json!({"root": "m1", "folder": 5}), json!({"folder": "Clients"})] {
            let (mut h, mut rx, _) = drop_host(true);
            ask_link(&mut h, &mut rx, into.clone());
            assert_eq!(upload(&mut h, &mut rx, 1, "a.mov", b"x")["error"], "scope", "{into}");
        }
    }

    #[test]
    fn a_read_only_root_leaves_the_upload_in_the_quarantine() {
        let (mut h, mut rx, media) = drop_host(false);
        let into = json!({"root": "m1", "folder": "Clients"});
        ask_link(&mut h, &mut rx, into.clone());
        let e = upload(&mut h, &mut rx, 1, "Hero.mov", b"hello");
        assert_eq!((&e["into"], &e["placed"]), (&into, &Value::Null));
        assert_eq!(std::fs::read(h.data.join(e["path"].as_str().unwrap())).unwrap(), b"hello");
        assert!(!media.join("Clients/Hero.mov").exists());
    }

    #[test]
    fn a_droppable_root_takes_the_upload_and_never_overwrites() {
        let (mut h, mut rx, media) = drop_host(true);
        std::fs::write(media.join("Clients/Hero.mov"), b"theirs").unwrap();
        let into = json!({"root": "m1", "folder": "Clients"});
        ask_link(&mut h, &mut rx, into.clone());
        let e = upload(&mut h, &mut rx, 1, "Hero.mov", b"hello");
        assert_eq!((&e["into"], &e["placed"]), (&into, &json!("m1/Clients/Hero 2.mov")));
        assert_eq!(std::fs::read(media.join("Clients/Hero.mov")).unwrap(), b"theirs", "the existing file is untouched");
        assert_eq!(std::fs::read(media.join("Clients/Hero 2.mov")).unwrap(), b"hello");
        assert!(!h.data.join(format!("uploads/L1/{}.mov", e["id"].as_str().unwrap())).exists(), "moved out of the quarantine");
        assert_eq!((&e["root"], &e["path"]), (&json!(true), &json!("m1/Clients/Hero 2.mov")), "a 4.0.6 Mac adds it by reference");
        assert!(h.roots.resolve("m1/Clients/Hero 2.mov", false).is_some(), "Pluck can add it by reference");
        // The root itself (no folder), and the link the browser sees doesn't show where files go.
        let (mut h, mut rx, media) = drop_host(true);
        ask_link(&mut h, &mut rx, json!({"root": "m1", "folder": ""}));
        assert_eq!(upload(&mut h, &mut rx, 1, "b.mov", b"x")["placed"], "m1/b.mov");
        assert!(media.join("b.mov").is_file());
        let l = h.link("R1").unwrap().clone();
        h.ready("p1", &json!(9), &l);
        let ready = answer(&mut rx, "p1", 9);
        assert!(ready["link"]["uploads"].is_object() && ready["link"]["uploads"]["into"].is_null(), "{ready}");
    }

    #[tokio::test]
    async fn placing_an_upload_runs_off_the_host_task() {
        let (mut h, mut rx, media) = drop_host(true);
        let (tx, mut back) = mpsc::unbounded_channel();
        h.back = Some(tx);
        ask_link(&mut h, &mut rx, json!({"root": "m1", "folder": "Clients"}));
        h.request("p1", &json!({"id": 1, "t": "upload-begin", "name": "Big.mov", "size": 3, "for": "asset"}));
        let part = cmds(&mut rx).iter().find_map(|c| c["accept"]["path"].as_str().map(PathBuf::from)).unwrap();
        std::fs::write(&part, b"abc").unwrap();
        let sha = keys::sha256_b64(b"abc");
        h.report(&json!({"upload": {"peer": "p1", "upload": 1, "state": "done", "bytes": 3, "sha256": sha}}));
        h.request("p1", &json!({"id": 2, "t": "upload-end", "upload": 1, "sha256": sha}));
        assert!(!sent(&mut rx).iter().any(|m| m["msg"]["re"] == 2), "no answer until it's in its folder");
        assert!(h.entries.iter().all(|e| e.get("upload").is_none()), "not logged half-way (a Mac would move it too)");
        let pull = h.sync(&json!({"op": "pull", "since": 0}));
        assert!(pull["seq"].is_u64(), "the host keeps answering meanwhile");
        let (k, v) = back.recv().await.unwrap();
        h.copy_progress(k, v);
        assert_eq!(answer(&mut rx, "p1", 2)["uploaded"]["name"], "Big.mov");
        let e = h.entries.iter().rev().find_map(|e| e.get("upload")).unwrap();
        assert_eq!((&e["placed"], &e["path"]), (&json!("m1/Clients/Big.mov"), &json!("m1/Clients/Big.mov")));
        assert_eq!(std::fs::read(media.join("Clients/Big.mov")).unwrap(), b"abc");
        assert_eq!(h.busy.transfers.load(std::sync::atomic::Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn ask_for_files_links_keep_their_caps_and_checks() {
        let (mut h, mut rx, _) = drop_host(true);
        ask_link(&mut h, &mut rx, json!({"root": "m1", "folder": "Clients"}));
        // No assets: listing works, an oversize file doesn't.
        h.request("p1", &json!({"id": 1, "t": "list"}));
        assert_eq!(answer(&mut rx, "p1", 1)["assets"], json!([]));
        assert_eq!(upload(&mut h, &mut rx, 2, "big.mov", &[0; 1001])["error"], "tooLarge");
        // Expired: refused before upload-begin is looked at.
        let mut l = link("L1", "R1", json!({"kind": "assets", "assets": []}));
        l["uploads"] = json!({"into": {"root": "m1", "folder": "Clients"}});
        l["expires"] = json!("2000-01-01T00:00:00Z");
        let mut m = sample(json!([l.clone()]));
        m["projects"][0]["assets"] = json!([]);
        h.publish(&m, &json!({}));
        ready_peer(&mut h, "p2", "R1");
        h.request("p2", &json!({"id": 3, "t": "upload-begin", "name": "a.mov", "size": 1, "for": "asset"}));
        assert_eq!(answer(&mut rx, "p2", 3)["error"]["code"], "expired");
        // A password link: a wrong password leaves the peer unable to upload.
        l["expires"] = Value::Null;
        l["passwordHash"] = json!(keys::hash_password("right"));
        m["links"] = json!([l]);
        h.publish(&m, &json!({}));
        h.report(&json!({"peer": {"peer": "p3", "state": "open", "room": "R1"}}));
        h.peers.get_mut("p3").unwrap().authed = true;
        h.request("p3", &json!({"id": 4, "t": "password", "password": "wrong"}));
        assert_eq!(answer(&mut rx, "p3", 4)["error"]["code"], "password");
        h.request("p3", &json!({"id": 5, "t": "upload-begin", "name": "a.mov", "size": 1, "for": "asset"}));
        assert_eq!(answer(&mut rx, "p3", 5)["error"]["code"], "auth");
        assert!(cmds(&mut rx).iter().all(|c| c.get("accept").is_none()));
    }

    /// wf-deliver: a delivered link is read only and past its deadline still opens; an archived one says so and keeps
    /// its room; a client's download reaches the team; one expiry reminder a week before.
    #[tokio::test]
    async fn delivered_and_archived_links() {
        let (mut h, mut rx) = test_host();
        let mut d = link("LD", "RD", json!({"kind": "project", "id": "P"}));
        (d["delivered"], d["deadline"], d["allowDownload"]) = (json!("2026-11-01T10:00:00Z"), json!("2020-01-01T00:00:00Z"), json!(true));
        d["expires"] = json!(iso(now_secs() + 3 * 86_400));
        d["notify"] = json!({"email": true, "recipientEmail": null, "mailCode": "KEYCODE.PUB"});
        let mut a = link("LA", "RA", json!({"kind": "project", "id": "P"}));
        a["archived"] = json!("2026-11-02T10:00:00Z");
        let mut m = sample(json!([d, a]));
        m["archiveForgetDays"] = json!(1);
        h.publish(&m, &json!({}));
        let ld = h.link("RD").cloned().unwrap();
        assert_eq!((h.deadline(&ld), h.live(&ld)), (None, Ok(())), "delivered: no deadline");
        assert_eq!(h.live(h.link("RA").unwrap()), Err("archived"));
        named_peer(&mut h, "c1", "RD", "t1", "Client one");
        sent(&mut rx);
        h.ready("c1", &json!(1), &ld);
        assert_eq!(answer(&mut rx, "c1", 1)["link"]["delivered"], "2026-11-01T10:00:00Z");
        h.request("c1", &json!({"id": 2, "t": "comment-add", "asset": "A", "version": "V", "frame": 1, "text": "Late"}));
        assert_eq!(answer(&mut rx, "c1", 2)["error"]["code"], "readonly");
        h.request("c1", &json!({"id": 3, "t": "list", "folder": null}));
        assert!(answer(&mut rx, "c1", 3)["assets"].is_array(), "reading still works");
        named_peer(&mut h, "c2", "RA", "t2", "Client two");
        h.request("c2", &json!({"id": 4, "t": "list", "folder": null}));
        let all = sent(&mut rx);
        assert!(all.iter().any(|m| m["peer"] == "c2" && m["msg"]["error"] == json!({"code": "paused", "archived": true})), "an older page: paused");
        assert!(all.iter().any(|m| m["peer"] == "c2" && m["msg"] == json!({"t": "bye", "code": "paused", "archived": true})));
        h.peers.remove("c2");
        h.check_links();
        let rooms = cmds(&mut rx).into_iter().find(|c| c.get("rooms").is_some()).unwrap();
        assert!(rooms["rooms"].as_array().unwrap().iter().any(|r| r["room"] == "RA"), "an archived link keeps its room");
        // Archived longer than archiveForgetDays: its activity and the clients' emails go, the approval's name and date stay.
        h.append(json!({"activity": {"id": "x1", "link": "LA", "at": now_iso(), "kind": "opened", "email": "c@example.com"}}));
        let ap = json!({"id": "AP", "asset": "A", "version": "V", "decision": "approve", "author": "Client two", "link": "LA",
            "created": "2026-11-01T09:00:00Z", "email": "c@example.com"});
        h.append(json!({"approval": ap}));
        h.approvals.push(ap);
        let mut gone = crate::mail::Mail::new_row("client");
        (gone["email"], gone["link"]) = (json!("c@example.com"), json!("LA"));
        h.mail.subs.push(gone);
        h.check_links();
        assert!(!h.entries.iter().any(|e| e["activity"]["link"] == "LA"), "its activity");
        assert!(h.entries.iter().chain(h.approvals.iter()).filter(|e| e.get("approval").unwrap_or(e)["id"] == "AP")
            .all(|a| a.get("approval").unwrap_or(a).get("email").is_none() && a.get("approval").unwrap_or(a)["author"] == "Client two"), "name kept, email gone");
        assert!(!h.mail.subs.iter().any(|r| r["link"] == "LA"));
        // Mail: the team hears the download; the client row gets one expiry reminder.
        assert_eq!(h.mail.set(&json!({"enabled": true, "server": "smtp.example.com", "port": 587, "security": "starttls", "user": "u",
            "from": "Studio <studio@example.com>", "replyTo": null, "digestHour": 8, "tzOffset": 60, "lang": "en"}), Some("pw"))["ok"], true);
        assert_eq!(h.sync(&json!({"op": "subscriber-set", "kind": "team", "email": "owner@example.com", "mode": "instant"}))["ok"], true);
        let mut row = crate::mail::Mail::new_row("client");
        (row["email"], row["link"]) = (json!("client@example.com"), json!("LD"));
        h.mail.subs.push(row);
        h.mail_download("c1", &json!("A"), &json!("V"));
        let q = h.mail.queue.iter().find(|q| q["event"] == "downloaded").cloned().expect("the team's mail");
        let owner = h.mail.subs.iter().find(|r| r["email"] == "owner@example.com").cloned().unwrap();
        assert_eq!(h.compose(&owner, &[q]).unwrap().subject, "Client one downloaded Cut");
        h.mail_tick();
        h.mail_tick();
        assert_eq!(h.mail.queue.iter().filter(|q| q["event"] == "expiry").count(), 1, "once");
    }
}
