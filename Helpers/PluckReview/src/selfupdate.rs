// The host updates itself (4.0.7): no Docker socket, TrueNAS API key or root updater.
//
// `supervise` is what `--host` runs first on Linux (the container's PID 1, the Proxmox service): it starts the newest
// verified program kept in <data>/.pluck-host/bin/<version>/, else the built-in one, with PLUCK_SUPERVISED=1. When
// that program exits SWITCH it starts the (new) newest again; when a kept one exits within EARLY of starting, or
// fails its check, that version is marked bad and the one before runs.
//
// The supervised host (`run`) follows the release its Macs name (`self-update` target, never "latest", so a host
// never gets ahead of its Macs): it fetches that release's host-release.json and .sig from GitHub, checks the
// Ed25519 signature with the pinned key before reading anything in it, downloads this architecture's two programs,
// checks their SHA-256 against the signed file, checks the new pluck-review runs and says that version, keeps them,
// and exits SWITCH at a quiet moment (no viewers, nothing uploading or copying; or the nightly window).
use std::{
    io::Write,
    os::unix::{fs::OpenOptionsExt, process::ExitStatusExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::{Notify, mpsc, oneshot},
};
use tokio_rustls::rustls::RootCertStore;

use crate::{host, log, update::VERSION};

/// The exit code that means "start the newest program again" (EX_TEMPFAIL).
pub const SWITCH: i32 = 75;
/// A kept program that exits sooner than this after starting is rolled back.
pub const EARLY: Duration = Duration::from_secs(60);
/// The release signing key (the same as DeliverHostUpdate.releaseKey and the Proxmox scripts' PUBKEY_PEM).
const RELEASE_KEY: &str = "fOPL13shEB3uNAhz5Fz6CYPWGucTgWLv3jcC17ZusAI=";
const MAX_JSON: usize = 64 << 10;
const MAX_BIN: usize = 160 << 20;
const FILES: [&str; 2] = ["pluck-review", "pluck-iroh"];

static WAKE: Notify = Notify::const_new();

/// Where releases come from and what vouches for them. Production: GitHub and the pinned key; tests build their own.
pub struct Trust {
    pub key: Vec<u8>,
    pub base: String,
    pub hosts: Vec<String>,
    pub roots: Option<Arc<RootCertStore>>,
}

impl Trust {
    pub fn github() -> Self {
        Self {
            key: STANDARD.decode(RELEASE_KEY).unwrap_or_default(),
            base: "https://github.com/Astrofrogger/pluck/releases/download".into(),
            // github.com redirects release downloads to its asset CDN; nothing else is followed.
            hosts: ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"].map(String::from).to_vec(),
            roots: None,
        }
    }
}

/// Running under `supervise` (only then can the host switch itself).
pub fn active() -> bool {
    std::env::var("PLUCK_SUPERVISED").as_deref() == Ok("1")
}

fn home(data: &Path) -> PathBuf {
    data.join(".pluck-host")
}

fn bins(data: &Path) -> PathBuf {
    home(data).join("bin")
}

pub fn arch() -> &'static str {
    match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        a => a,
    }
}

/// The release assets for this architecture, in FILES' order (review-host-release.yml uploads them).
fn assets() -> [String; 2] {
    FILES.map(|f| format!("{f}-linux-{}", arch()))
}

pub fn valid_version(v: &str) -> bool {
    (1..=40).contains(&v.len()) && v.as_bytes()[0].is_ascii_alphanumeric() && v.bytes().all(|b| b.is_ascii_alphanumeric() || b".-_+".contains(&b))
}

fn plain(v: &str) -> &str {
    v.strip_prefix('v').unwrap_or(v)
}

fn parts(v: &str) -> Vec<u64> {
    plain(v).split(['-', '+']).next().unwrap_or("").split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

/// `a` is a later version than `b` (numeric, "v" ignored).
pub fn newer(a: &str, b: &str) -> bool {
    let (mut x, mut y) = (parts(a), parts(b));
    let n = x.len().max(y.len());
    x.resize(n, 0);
    y.resize(n, 0);
    x > y
}

/// host-release.json, only when its signature (base64 of 64 bytes) checks out with `key`.
pub fn verify(json: &[u8], sig: &[u8], key: &[u8]) -> Option<Value> {
    let sig = STANDARD.decode(std::str::from_utf8(sig).ok()?.trim()).ok()?;
    if sig.len() != 64 {
        return None;
    }
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key).verify(json, &sig).ok()?;
    let v: Value = serde_json::from_slice(json).ok()?;
    valid_version(plain(v["version"].as_str()?)).then_some(v)
}

fn sha256_hex(b: &[u8]) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(b).iter().map(|b| format!("{b:02x}")).collect()
}

fn read_json(p: &Path) -> Value {
    std::fs::read(p).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| json!({}))
}

fn write_json(p: &Path, v: &Value) {
    let tmp = p.with_extension("part");
    let _ = std::fs::create_dir_all(p.parent().unwrap_or(p));
    if let Err(e) = std::fs::write(&tmp, v.to_string()).and_then(|_| std::fs::rename(&tmp, p)) {
        log(format!("self-update: can't write {}: {e}", p.display()));
    }
}

// ---- bad versions ----

fn bad_path(data: &Path) -> PathBuf {
    home(data).join("bad.json")
}

pub fn is_bad(data: &Path, v: &str) -> bool {
    read_json(&bad_path(data)).get(plain(v)).is_some()
}

fn mark_bad(data: &Path, v: &str, why: &str) {
    log(format!("self-update: {v} marked bad: {why}"));
    let mut b = read_json(&bad_path(data));
    b[plain(v)] = json!({"why": why, "at": host::now_iso()});
    write_json(&bad_path(data), &b);
}

fn clear_bad(data: &Path, v: &str) {
    let mut b = read_json(&bad_path(data));
    if b.as_object_mut().and_then(|o| o.remove(plain(v))).is_some() {
        write_json(&bad_path(data), &b);
    }
}

// ---- a kept version ----

/// The program at `bin` runs here and says `pluck-review <v> …` within 10 s.
fn runs(bin: &Path, v: &str) -> bool {
    let Ok(mut c) = std::process::Command::new(bin).arg("--version").stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null()).spawn() else { return false };
    let until = Instant::now() + Duration::from_secs(10);
    loop {
        match c.try_wait() {
            Ok(Some(st)) if st.success() => break,
            Ok(None) if Instant::now() < until => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = c.kill();
                let _ = c.wait();
                return false;
            }
        }
    }
    let mut out = String::new();
    let _ = std::io::Read::read_to_string(&mut c.stdout.take().unwrap(), &mut out);
    out.split_whitespace().nth(1).is_some_and(|got| plain(got) == plain(v))
}

/// A kept version's folder still matches its signed release (signature, both SHA-256s) and its program runs.
fn check_dir(dir: &Path, v: &str, key: &[u8]) -> Result<()> {
    let json = std::fs::read(dir.join("host-release.json")).context("no host-release.json")?;
    let sig = std::fs::read(dir.join("host-release.json.sig")).context("no signature")?;
    let rel = verify(&json, &sig, key).context("the signature doesn't check out")?;
    ensure!(plain(rel["version"].as_str().unwrap_or("")) == plain(v), "the signed release is for another version");
    for (file, asset) in FILES.iter().zip(assets()) {
        let want = rel["assets"][&asset].as_str().with_context(|| format!("{asset} isn't in the release"))?;
        ensure!(host::sha256_file(&dir.join(file)).ok().as_deref() == Some(want), "{file} doesn't match the signed release");
    }
    ensure!(runs(&dir.join("pluck-review"), v), "it doesn't run here");
    Ok(())
}

fn kept(data: &Path) -> Vec<String> {
    let mut vs: Vec<String> = std::fs::read_dir(bins(data)).into_iter().flatten().flatten()
        .filter_map(|e| e.file_name().into_string().ok()).filter(|n| valid_version(n)).collect();
    vs.sort_by(|a, b| if newer(a, b) { std::cmp::Ordering::Less } else if newer(b, a) { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Equal });
    vs
}

/// The newest kept version later than the built-in one that still checks out (a failing one is marked bad).
pub fn choose(data: &Path, builtin: &str, key: &[u8]) -> Option<(PathBuf, String)> {
    for v in kept(data).into_iter().filter(|v| newer(v, builtin) && !is_bad(data, v)) {
        let dir = bins(data).join(&v);
        match check_dir(&dir, &v, key) {
            Ok(()) => return Some((dir.join("pluck-review"), v)),
            Err(e) => mark_bad(data, &v, &format!("{e:#}")),
        }
    }
    None
}

/// Keep the running version, the one before it and the newest one waiting; the rest (and bad ones) go.
pub fn prune(data: &Path, running: &str) {
    let vs = kept(data);
    let waiting = vs.iter().find(|v| newer(v, running) && !is_bad(data, v)).cloned();
    let previous = vs.iter().find(|v| newer(running, v) && !is_bad(data, v)).cloned();
    for v in vs {
        let keep = plain(&v) == plain(running) || Some(&v) == waiting.as_ref() || Some(&v) == previous.as_ref();
        if !keep {
            log(format!("self-update: removing kept version {v}"));
            let _ = std::fs::remove_dir_all(bins(data).join(&v));
        }
    }
    // A download cut off by a restart leaves bin/.<v>.part (stage() runs in this same task, so none is in flight).
    for e in std::fs::read_dir(bins(data)).into_iter().flatten().flatten() {
        if e.file_name().to_str().is_some_and(|n| n.starts_with('.') && n.ends_with(".part")) {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
}

// ---- crashes after the first minute ----

fn crashes_path(data: &Path) -> PathBuf {
    home(data).join("crashes.json")
}

/// Stopped by a person or the service manager (SIGTERM/SIGINT), or killed from outside (SIGKILL: the OOM killer, a
/// container stop that timed out): not a fault of the version.
fn stopped(code: i32) -> bool {
    code == 128 + libc::SIGTERM || code == 128 + libc::SIGINT || code == 128 + libc::SIGKILL
}

/// Notes a crash of kept version `v` at `now`; true at the CRASHES-th within an hour (then it's marked bad).
fn crashed(data: &Path, v: &str, now: i64) -> bool {
    const CRASHES: usize = 3;
    let mut c = read_json(&crashes_path(data));
    let mut times: Vec<i64> = c[plain(v)].as_array().into_iter().flatten().filter_map(Value::as_i64).filter(|t| now - t < 3600).collect();
    times.push(now);
    let out = times.len() >= CRASHES;
    c = json!({plain(v): if out { json!([]) } else { json!(times) }}); // only the running version's count matters
    write_json(&crashes_path(data), &c);
    out
}

// ---- the supervisor ----

fn code_of(st: std::process::ExitStatus) -> i32 {
    st.code().unwrap_or_else(|| 128 + st.signal().unwrap_or(0))
}

async fn forward(child: &mut tokio::process::Child, sig: i32) -> i32 {
    if let Some(pid) = child.id() {
        unsafe { libc::kill(pid as i32, sig) };
    }
    child.wait().await.map_or(1, code_of)
}

/// Runs the host program until it stops for good; returns its exit code. `builtin` is this program (the image's or
/// the Proxmox release's), `args` the host's own arguments.
pub async fn supervise(data: PathBuf, builtin: PathBuf, builtin_v: String, args: Vec<String>, key: Vec<u8>, early: Duration) -> i32 {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut term), Ok(mut int)) = (signal(SignalKind::terminate()), signal(SignalKind::interrupt())) else { return 1 };
    loop {
        let kept = choose(&data, &builtin_v, &key);
        let (bin, v) = kept.clone().unwrap_or_else(|| (builtin.clone(), builtin_v.clone()));
        log(format!("supervisor: starting {v} ({})", if kept.is_some() { "updated" } else { "built in" }));
        let start = Instant::now();
        let mut child = match tokio::process::Command::new(&bin).args(&args).env("PLUCK_SUPERVISED", "1").spawn() {
            Ok(c) => c,
            Err(e) if kept.is_some() => {
                mark_bad(&data, &v, &format!("didn't start: {e}"));
                continue;
            }
            Err(e) => {
                log(format!("supervisor: can't start {}: {e}", bin.display()));
                return 1;
            }
        };
        let st = tokio::select! {
            biased; // a stop for the whole service (systemd signals every process) is a stop, not a crash
            _ = term.recv() => return forward(&mut child, libc::SIGTERM).await,
            _ = int.recv() => return forward(&mut child, libc::SIGINT).await,
            st = child.wait() => st,
        };
        let code = st.map_or(1, code_of);
        if code == SWITCH {
            log(format!("supervisor: {v} asked to switch"));
            tokio::time::sleep(Duration::from_millis(200)).await;
            continue;
        }
        if kept.is_some() && !stopped(code) && start.elapsed() < early {
            mark_bad(&data, &v, &format!("exited ({code}) {} s after starting", start.elapsed().as_secs()));
            log(format!("supervisor: rolled back from {v}"));
            continue;
        }
        // A kept version that keeps crashing later on: after 3 within an hour, back to the one before.
        if kept.is_some() && code != 0 && !stopped(code) && crashed(&data, &v, host::now_secs()) {
            mark_bad(&data, &v, &format!("crashed 3 times within an hour (last: {code})"));
            log(format!("supervisor: rolled back from {v}"));
            continue;
        }
        log(format!("supervisor: {v} exited ({code})"));
        return code;
    }
}

// ---- HTTPS (GitHub only) ----

fn connector(trust: &Trust) -> Result<tokio_rustls::TlsConnector> {
    let roots = trust.roots.clone().unwrap_or_else(|| {
        let mut r = RootCertStore::empty();
        r.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
        Arc::new(r)
    });
    let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());
    let cfg = tokio_rustls::rustls::ClientConfig::builder_with_provider(provider).with_safe_default_protocol_versions()?
        .with_root_certificates(roots).with_no_client_auth();
    Ok(tokio_rustls::TlsConnector::from(Arc::new(cfg)))
}

fn find(b: &[u8], what: &[u8]) -> Option<usize> {
    b.windows(what.len()).position(|w| w == what)
}

fn dechunk(mut b: &[u8], max: usize) -> Result<Vec<u8>> {
    let mut out = vec![];
    loop {
        let i = find(b, b"\r\n").context("bad chunk")?;
        let line = std::str::from_utf8(&b[..i])?;
        let size = usize::from_str_radix(line.split(';').next().unwrap_or("").trim(), 16)?;
        b = &b[i + 2..];
        if size == 0 {
            return Ok(out);
        }
        ensure!(size <= max - out.len(), "too big"); // (out.len() <= max: checked each round; no overflow)
        ensure!(size.checked_add(2).is_some_and(|n| b.len() >= n), "cut short");
        out.extend_from_slice(&b[..size]);
        b = &b[size + 2..];
    }
}

/// GET over HTTPS, following at most 5 redirects, only ever to `trust.hosts`; the body at most `max` bytes.
pub async fn get(url: &str, trust: &Trust, max: usize) -> Result<Vec<u8>> {
    tokio::time::timeout(Duration::from_secs(900), get_inner(url, trust, max)).await.context("timed out")?
}

async fn get_inner(url: &str, trust: &Trust, max: usize) -> Result<Vec<u8>> {
    let idle = Duration::from_secs(60);
    let mut url = url.to_owned();
    for _ in 0..6 {
        let rest = url.strip_prefix("https://").context("not https")?;
        let (authority, path) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
        let path = if path.is_empty() { "/" } else { path };
        let (host, port) = match authority.rsplit_once(':') {
            Some((h, p)) => (h, p.parse::<u16>()?),
            None => (authority, 443),
        };
        ensure!(trust.hosts.iter().any(|h| h == host), "{host} isn't GitHub");
        ensure!(path.bytes().all(|b| b.is_ascii_graphic()), "bad address");
        let tcp = tokio::time::timeout(Duration::from_secs(20), tokio::net::TcpStream::connect((host, port))).await.context("connect timed out")??;
        let name = tokio_rustls::rustls::pki_types::ServerName::try_from(host.to_owned())?;
        let mut s = tokio::time::timeout(Duration::from_secs(20), connector(trust)?.connect(name, tcp)).await.context("TLS timed out")??;
        s.write_all(format!("GET {path} HTTP/1.1\r\nHost: {authority}\r\nUser-Agent: pluck-review/{VERSION}\r\nAccept: */*\r\nConnection: close\r\n\r\n").as_bytes()).await?;
        let mut buf = Vec::new();
        let mut chunk = vec![0u8; 64 << 10];
        let mut read = async |s: &mut tokio_rustls::client::TlsStream<tokio::net::TcpStream>, buf: &mut Vec<u8>| -> Result<usize> {
            match tokio::time::timeout(idle, s.read(&mut chunk)).await.context("read timed out")? {
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    Ok(n)
                }
                // (a server that closes without TLS close_notify: the end of the body)
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => Ok(0),
                Err(e) => Err(e.into()),
            }
        };
        let head_end = loop {
            if let Some(i) = find(&buf, b"\r\n\r\n") {
                break i + 4;
            }
            ensure!(buf.len() < 16 << 10, "headers too long");
            ensure!(read(&mut s, &mut buf).await? > 0, "closed early");
        };
        let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
        let mut lines = head.split("\r\n");
        let code: u16 = lines.next().and_then(|l| l.split(' ').nth(1)).and_then(|c| c.parse().ok()).context("not HTTP")?;
        let header = |k: &str| head.split("\r\n").skip(1).find_map(|l| l.split_once(':').filter(|(n, _)| n.trim().eq_ignore_ascii_case(k)).map(|(_, v)| v.trim().to_owned()));
        if matches!(code, 301 | 302 | 303 | 307 | 308) {
            url = header("location").context("redirect without a location")?;
            continue;
        }
        ensure!(code == 200, "HTTP {code}");
        if let Some(len) = header("content-length").and_then(|l| l.parse::<usize>().ok()) {
            ensure!(len <= max, "too big ({len} bytes)");
            while buf.len() - head_end < len {
                ensure!(read(&mut s, &mut buf).await? > 0, "cut short");
            }
            return Ok(buf[head_end..head_end + len].to_vec());
        }
        while read(&mut s, &mut buf).await? > 0 {
            ensure!(buf.len() - head_end <= max * 2 + 4096, "too big");
        }
        let body = &buf[head_end..];
        if header("transfer-encoding").is_some_and(|t| t.eq_ignore_ascii_case("chunked")) {
            return dechunk(body, max);
        }
        ensure!(body.len() <= max, "too big");
        return Ok(body.to_vec());
    }
    bail!("too many redirects")
}

// ---- fetching and keeping a release ----

fn write_exec(p: &Path, b: &[u8]) -> std::io::Result<()> {
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o755).open(p)?;
    f.write_all(b)?;
    f.sync_all()
}

/// Download, verify and keep release `v` in bin/<v> (written in bin/.<v>.part, renamed when all checks pass).
pub async fn stage(data: &Path, trust: &Trust, v: &str) -> Result<()> {
    ensure!(valid_version(v), "bad version");
    let part = bins(data).join(format!(".{}.part", plain(v)));
    let r = stage_in(data, trust, v, &part).await;
    if r.is_err() {
        let _ = std::fs::remove_dir_all(&part); // a failed try leaves nothing behind
    }
    r
}

async fn stage_in(data: &Path, trust: &Trust, v: &str, part: &Path) -> Result<()> {
    let url = |f: &str| format!("{}/v{}/{f}", trust.base, plain(v));
    let json = get(&url("host-release.json"), trust, MAX_JSON).await.context("host-release.json")?;
    let sig = get(&url("host-release.json.sig"), trust, 1024).await.context("host-release.json.sig")?;
    let rel = verify(&json, &sig, &trust.key).context("the release signature doesn't check out")?;
    ensure!(plain(rel["version"].as_str().unwrap_or("")) == plain(v), "the signed release is for another version");
    let _ = std::fs::remove_dir_all(part);
    std::fs::create_dir_all(part)?;
    for (file, asset) in FILES.iter().zip(assets()) {
        let want = rel["assets"][&asset].as_str().with_context(|| format!("{asset} isn't in the release"))?.to_owned();
        let body = get(&url(&asset), trust, MAX_BIN).await.with_context(|| asset.clone())?;
        ensure!(sha256_hex(&body) == want, "{asset} doesn't match the signed release");
        write_exec(&part.join(file), &body)?;
    }
    std::fs::write(part.join("host-release.json"), &json)?;
    std::fs::write(part.join("host-release.json.sig"), &sig)?;
    let (bin, ver) = (part.join("pluck-review"), v.to_owned());
    if !tokio::task::spawn_blocking(move || runs(&bin, &ver)).await? {
        bail!("the new program doesn't run here (is the data folder mounted noexec?)");
    }
    let dir = bins(data).join(plain(v));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::rename(part, &dir)?;
    log(format!("self-update: {v} downloaded and verified"));
    Ok(())
}

// ---- settings and state (what Pluck sees) ----

fn settings_path(data: &Path) -> PathBuf {
    home(data).join("settings.json")
}

fn state_path(data: &Path) -> PathBuf {
    home(data).join("state.json")
}

fn auto(s: &Value) -> bool {
    s["auto"].as_bool().unwrap_or(true)
}

/// `{"op":"self-update","target"?,"auto"?,"now"?}` from a Mac (admin) or the main (for its backups): the newest
/// version a Mac runs, "Updates by itself" on or off, and "Update Now". A target never goes down.
pub fn op(data: &Path, op: &Value) -> Value {
    if !active() {
        return json!({"error": "unknown op"});
    }
    let mut s = read_json(&settings_path(data));
    if let Some(t) = op["target"].as_str() {
        if !valid_version(plain(t)) {
            return json!({"error": "invalid"});
        }
        if s["target"].as_str().is_none_or(|old| newer(t, old)) {
            s["target"] = json!(plain(t));
        }
        s["checked"] = json!(host::now_iso());
    }
    if let Some(a) = op["auto"].as_bool() {
        s["auto"] = json!(a);
    }
    if op["now"] == true {
        s["now"] = json!(true);
        if let Some(t) = s["target"].as_str() {
            clear_bad(data, t); // a person asking for it again: one more try
        }
    }
    write_json(&settings_path(data), &s);
    WAKE.notify_one();
    status(data)
}

/// The `selfUpdate` object in `status`: state upToDate | available (Updates off) | downloading | waiting | failed |
/// rolledBack (the target was undone; `error` says why).
pub fn status(data: &Path) -> Value {
    let s = read_json(&settings_path(data));
    let st = read_json(&state_path(data));
    json!({"auto": auto(&s), "version": VERSION, "target": s["target"], "checked": s["checked"],
           "state": st["state"].as_str().unwrap_or("upToDate"), "error": st["error"], "now": s["now"] == true})
}

fn set_state(data: &Path, state: &str, error: Option<String>) {
    let old = read_json(&state_path(data));
    let new = json!({"state": state, "error": error});
    if old != new {
        write_json(&state_path(data), &new);
    }
}

// ---- when to switch ----

/// HH:MM (PLUCK_UPDATE_TIME, 04:00 by default) to an hour later, UTC.
/// shortcut: UTC, not the NAS's time zone (the container has none); upgrade if owners want an exact local hour.
pub fn in_window(now_secs: i64, at: &str) -> bool {
    let p: Vec<i64> = at.split(':').filter_map(|x| x.parse().ok()).collect();
    let start = match p[..] {
        [h, m] if (0..24).contains(&h) && (0..60).contains(&m) => h * 60 + m,
        _ => 4 * 60,
    };
    (now_secs.rem_euclid(86_400) / 60 - start).rem_euclid(1440) < 60
}

/// Try now: asked to (Update Now), the nightly window, or nobody watching. Uploads and copies are checked after this.
pub fn should_try(now: bool, viewers: u64, window: bool) -> bool {
    now || window || viewers == 0
}

async fn ask(to_host: &mpsc::Sender<host::Sync>, op: Value) -> Option<Value> {
    let (tx, rx) = oneshot::channel();
    to_host.send(host::Sync { op, reply: tx }).await.ok()?;
    rx.await.ok()
}

async fn quiet(to_host: &mpsc::Sender<host::Sync>, now: bool) -> bool {
    let viewers = ask(to_host, json!({"op": "status"})).await.and_then(|s| s["viewers"].as_u64()).unwrap_or(0);
    let at = std::env::var("PLUCK_UPDATE_TIME").unwrap_or_default();
    if !should_try(now, viewers, in_window(host::now_secs(), &at)) {
        return false;
    }
    // prepare-update: from here no new uploads or copies start; still busy → back to normal and try again later.
    if ask(to_host, json!({"op": "prepare-update"})).await.is_some_and(|r| r["busy"] == false) {
        return true;
    }
    ask(to_host, json!({"op": "cancel-update"})).await;
    false
}

/// One look: what to do now. Returns true when the host should exit SWITCH.
pub async fn tick(data: &Path, trust: &Trust, to_host: &mpsc::Sender<host::Sync>, retry: &mut Option<Instant>) -> bool {
    let mut s = read_json(&settings_path(data));
    let Some(t) = s["target"].as_str().map(str::to_owned).filter(|t| newer(t, VERSION)) else {
        set_state(data, "upToDate", None);
        return false;
    };
    if is_bad(data, &t) {
        // Tried and undone (it failed its check or kept crashing): said so, until Update Now tries it once more.
        let why = read_json(&bad_path(data))[plain(&t)]["why"].as_str().map(str::to_owned);
        set_state(data, "rolledBack", why);
        return false;
    }
    let now = s["now"] == true;
    if !auto(&s) && !now {
        set_state(data, "available", None);
        return false;
    }
    if !bins(data).join(&t).join("pluck-review").is_file() {
        if retry.is_some_and(|r| Instant::now() < r) && !now {
            return false;
        }
        set_state(data, "downloading", None);
        if let Err(e) = stage(data, trust, &t).await {
            log(format!("self-update: {t}: {e:#}"));
            set_state(data, "failed", Some(format!("{e:#}")));
            *retry = Some(Instant::now() + Duration::from_secs(3600));
            if now {
                s["now"] = json!(false);
                write_json(&settings_path(data), &s);
            }
            return false;
        }
    }
    set_state(data, "waiting", None);
    if !quiet(to_host, now).await {
        return false;
    }
    s["now"] = json!(false);
    write_json(&settings_path(data), &s);
    log(format!("self-update: switching to {t}"));
    true
}

/// The supervised host's updater: a look every minute, or at once after a `self-update` op.
pub async fn run(data: PathBuf, trust: Trust, to_host: mpsc::Sender<host::Sync>) {
    let (started, mut pruned, mut retry) = (Instant::now(), false, None);
    loop {
        if !pruned && started.elapsed() > EARLY {
            prune(&data, VERSION);
            pruned = true;
        }
        if tick(&data, &trust, &to_host, &mut retry).await {
            std::process::exit(SWITCH);
        }
        tokio::select! {
            _ = WAKE.notified() => {}
            _ = tokio::time::sleep(Duration::from_secs(60)) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    // A test signing key, only here.
    fn signer() -> ring::signature::Ed25519KeyPair {
        ring::signature::Ed25519KeyPair::from_seed_unchecked(&[7u8; 32]).unwrap()
    }

    fn public() -> Vec<u8> {
        use ring::signature::KeyPair;
        signer().public_key().as_ref().to_vec()
    }

    fn sign(json: &[u8]) -> Vec<u8> {
        STANDARD.encode(signer().sign(json).as_ref()).into_bytes()
    }

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pluck-selfupd-{name}-{}", host::uuid()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// A fake pluck-review: says `v` for --version, else runs `body`.
    fn fake(v: &str, body: &str) -> Vec<u8> {
        format!("#!/bin/sh\nif [ \"$1\" = --version ]; then echo \"pluck-review {v} protocol 3\"; exit 0; fi\n{body}\n").into_bytes()
    }

    fn release(v: &str, review: &[u8], iroh: &[u8]) -> Vec<u8> {
        let a = assets();
        json!({"version": format!("v{v}"), "protocol": 3, "image": "x", "assets": {&a[0]: sha256_hex(review), &a[1]: sha256_hex(iroh)}}).to_string().into_bytes()
    }

    /// bin/<v> as stage() leaves it.
    fn keep(data: &Path, v: &str, body: &str) {
        let dir = bins(data).join(v);
        std::fs::create_dir_all(&dir).unwrap();
        let (r, i) = (fake(v, body), b"iroh".to_vec());
        write_exec(&dir.join("pluck-review"), &r).unwrap();
        write_exec(&dir.join("pluck-iroh"), &i).unwrap();
        let j = release(v, &r, &i);
        std::fs::write(dir.join("host-release.json.sig"), sign(&j)).unwrap();
        std::fs::write(dir.join("host-release.json"), j).unwrap();
    }

    #[test]
    fn versions_and_signatures() {
        assert!(newer("4.0.10", "4.0.9") && newer("v4.1", "4.0.99") && !newer("4.0.7", "v4.0.7") && !newer("4.0.6", "4.0.7"));
        assert!(!valid_version("../x") && !valid_version("") && valid_version("4.0.7"));
        let j = release("4.0.7", b"a", b"b");
        assert!(verify(&j, &sign(&j), &public()).is_some());
        let mut tampered = j.clone();
        tampered.push(b' ');
        assert!(verify(&tampered, &sign(&j), &public()).is_none(), "bad signature");
        assert!(verify(&j, &sign(&j), &STANDARD.decode(RELEASE_KEY).unwrap()).is_none(), "another key");
        assert!(verify(&j, b"", &public()).is_none());
    }

    #[test]
    fn window_and_gate() {
        let day = 20_000 * 86_400;
        assert!(in_window(day + 4 * 3600 + 30 * 60, "04:00") && !in_window(day + 5 * 3600 + 1, "04:00"));
        assert!(in_window(day + 23 * 3600 + 50 * 60, "23:30") && in_window(day + 10 * 60, "23:30"), "across midnight");
        assert!(in_window(day + 4 * 3600, ""), "default 04:00");
        assert!(should_try(false, 0, false) && should_try(true, 3, false) && should_try(false, 3, true) && !should_try(false, 2, false));
    }

    #[test]
    fn choose_keeps_only_valid_and_newer() {
        let d = tmp("choose");
        let key = public();
        assert!(choose(&d, "4.0.7", &key).is_none());
        keep(&d, "4.0.6", "exit 0"); // older than built in: never picked (no downgrade)
        keep(&d, "4.0.8", "exit 0");
        keep(&d, "4.0.9", "exit 0");
        assert_eq!(choose(&d, "4.0.7", &key).unwrap().1, "4.0.9");
        // a changed program (wrong hash) is marked bad, the next one runs
        std::fs::write(bins(&d).join("4.0.9/pluck-review"), fake("4.0.9", "echo evil")).unwrap();
        assert_eq!(choose(&d, "4.0.7", &key).unwrap().1, "4.0.8");
        assert!(is_bad(&d, "4.0.9"));
        // a release signed by another key
        assert!(choose(&d, "4.0.7", &STANDARD.decode(RELEASE_KEY).unwrap()).is_none());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn prune_keeps_two() {
        let d = tmp("prune");
        for v in ["4.0.5", "4.0.6", "4.0.7", "4.0.8", "4.0.9"] {
            keep(&d, v, "exit 0");
        }
        mark_bad(&d, "4.0.9", "test");
        std::fs::create_dir_all(bins(&d).join(".4.1.0.part")).unwrap();
        prune(&d, "4.0.7");
        assert_eq!(kept(&d), vec!["4.0.8", "4.0.7", "4.0.6"], "running, the one before, the one waiting");
        assert!(!bins(&d).join(".4.1.0.part").exists(), "a stale download goes too");
        let _ = std::fs::remove_dir_all(d);
    }

    #[tokio::test]
    async fn supervisor_switches_and_rolls_back() {
        let d = tmp("sup");
        let key = public();
        let builtin = d.join("builtin");
        let marks = d.join("marks");
        std::fs::create_dir_all(&marks).unwrap();
        let m = marks.display();
        // built in 4.0.7: the first time it "stages" 4.0.8 and asks to switch; afterwards it exits 3.
        write_exec(&builtin, &fake("4.0.7", &format!("echo b >> {m}/runs\n[ -f {m}/switched ] && exit 3\ntouch {m}/switched\nexit 75"))).unwrap();
        keep(&d, "4.0.8", &format!("echo n >> {m}/runs\nexit 9")); // the new one crashes at once
        let code = supervise(d.clone(), builtin.clone(), "4.0.7".into(), vec!["--host".into()], key.clone(), Duration::from_secs(5)).await;
        // 4.0.8 ran first (newest), crashed early → bad; built in ran (exit 75: switch), then again (exit 3).
        assert_eq!(std::fs::read_to_string(marks.join("runs")).unwrap(), "n\nb\nb\n");
        assert_eq!(code, 3);
        assert!(is_bad(&d, "4.0.8") && choose(&d, "4.0.7", &key).is_none());
        // a good new one that runs past `early` and then exits: its code, not a rollback
        keep(&d, "4.0.9", "sleep 1; exit 4");
        assert_eq!(supervise(d.clone(), builtin, "4.0.7".into(), vec![], key.clone(), Duration::from_millis(300)).await, 4);
        assert!(!is_bad(&d, "4.0.9"));
        // stopped by SIGTERM (systemd stopping the service) within `early`: not marked bad
        keep(&d, "4.0.10", "kill -TERM $$");
        assert_eq!(supervise(d.clone(), d.join("builtin"), "4.0.7".into(), vec![], key.clone(), Duration::from_secs(5)).await, 143);
        assert!(!is_bad(&d, "4.0.10"));
        // crashing later on: the 3rd crash within an hour rolls back
        let _ = std::fs::remove_dir_all(bins(&d).join("4.0.10"));
        keep(&d, "4.0.11", "sleep 0.4; kill -ABRT $$");
        let sup = || supervise(d.clone(), d.join("builtin"), "4.0.7".into(), vec![], key.clone(), Duration::from_millis(300));
        assert_eq!((sup().await, sup().await), (134, 134), "a panic=abort crash: its code, first and second time");
        assert!(!is_bad(&d, "4.0.11"));
        assert_eq!(sup().await, 4, "third time: marked bad, the one before (4.0.9) runs");
        assert!(is_bad(&d, "4.0.11"));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn crash_count_is_per_hour() {
        let d = tmp("crash");
        assert!(!crashed(&d, "4.0.8", 1000) && !crashed(&d, "4.0.8", 2000));
        assert!(!crashed(&d, "4.0.8", 5000), "the first one is over an hour ago");
        assert!(crashed(&d, "4.0.8", 5100));
        assert!(!stopped(134) && stopped(143) && stopped(130) && stopped(137), "SIGKILL (OOM) isn't the version's crash");
        let _ = std::fs::remove_dir_all(d);
    }

    /// A host task that answers status (viewers) and prepare-update (busy).
    fn host_task(viewers: u64, busy: bool) -> mpsc::Sender<host::Sync> {
        let (tx, mut rx) = mpsc::channel::<host::Sync>(4);
        tokio::spawn(async move {
            while let Some(m) = rx.recv().await {
                let _ = m.reply.send(match m.op["op"].as_str() {
                    Some("status") => json!({"viewers": viewers}),
                    Some("prepare-update") => json!({"busy": busy}),
                    _ => json!({"ok": true}),
                });
            }
        });
        tx
    }

    #[tokio::test]
    async fn tick_follows_the_target_at_a_quiet_moment() {
        let d = tmp("tick");
        let trust = Trust { key: public(), base: "https://localhost:1/none".into(), hosts: vec![], roots: None };
        let mut retry = None;
        let set = |v: Value| write_json(&settings_path(&d), &v);
        keep(&d, "99.0.0", "exit 0");
        set(json!({"target": "0.0.1"}));
        assert!(!tick(&d, &trust, &host_task(0, false), &mut retry).await, "never down");
        assert_eq!(status(&d)["state"], "upToDate");
        set(json!({"target": "99.0.0", "auto": false}));
        assert!(!tick(&d, &trust, &host_task(0, false), &mut retry).await, "Updates off");
        assert_eq!(status(&d)["state"], "available");
        set(json!({"target": "99.0.0"}));
        assert!(!tick(&d, &trust, &host_task(0, true), &mut retry).await, "an upload or copy running");
        assert_eq!(status(&d)["state"], "waiting");
        assert!(tick(&d, &trust, &host_task(0, false), &mut retry).await, "nobody watching, nothing busy");
        set(json!({"target": "99.0.0", "now": true}));
        assert!(tick(&d, &trust, &host_task(5, false), &mut retry).await, "Update Now with viewers");
        assert_eq!(read_json(&settings_path(&d))["now"], false);
        mark_bad(&d, "99.0.0", "test");
        assert!(!tick(&d, &trust, &host_task(0, false), &mut retry).await, "a bad version is never retried by itself");
        assert_eq!((status(&d)["state"].clone(), status(&d)["error"].clone()), (json!("rolledBack"), json!("test")), "said, not \"up to date\"");
        // not kept yet and GitHub unreachable: failed, tried again in an hour
        set(json!({"target": "98.0.0"}));
        assert!(!tick(&d, &trust, &host_task(0, false), &mut retry).await);
        assert_eq!(status(&d)["state"], "failed");
        assert!(retry.is_some());
        let _ = std::fs::remove_dir_all(d);
    }

    // ---- a fake GitHub over TLS ----

    struct Fake {
        trust: Trust,
        _task: tokio::task::JoinHandle<()>,
    }

    async fn github(routes: HashMap<String, (u16, Vec<(String, String)>, Vec<u8>)>) -> Fake {
        let c = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let cert = tokio_rustls::rustls::pki_types::CertificateDer::from(c.cert.der().to_vec());
        let key = tokio_rustls::rustls::pki_types::PrivateKeyDer::try_from(c.signing_key.serialize_der()).unwrap();
        let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());
        let cfg = tokio_rustls::rustls::ServerConfig::builder_with_provider(provider).with_safe_default_protocol_versions().unwrap()
            .with_no_client_auth().with_single_cert(vec![cert.clone()], key).unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(cfg));
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let routes = Arc::new(routes);
        let task = tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = l.accept().await else { return };
                let (acceptor, routes) = (acceptor.clone(), routes.clone());
                tokio::spawn(async move {
                    let Ok(mut s) = acceptor.accept(tcp).await else { return };
                    let mut buf = vec![0u8; 4096];
                    let n = s.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]).to_string();
                    let path = req.split(' ').nth(1).unwrap_or("").to_owned();
                    let (code, headers, body) = routes.get(&path).cloned().unwrap_or((404, vec![], vec![]));
                    let mut head = format!("HTTP/1.1 {code} X\r\n");
                    for (k, v) in &headers {
                        head += &format!("{k}: {}\r\n", v.replace("SELF", &format!("https://localhost:{port}")));
                    }
                    if !headers.iter().any(|(k, _)| k == "Transfer-Encoding") {
                        head += &format!("Content-Length: {}\r\n", body.len());
                    }
                    let _ = s.write_all(format!("{head}\r\n").as_bytes()).await;
                    let _ = s.write_all(&body).await;
                    let _ = s.shutdown().await;
                });
            }
        });
        let mut roots = RootCertStore::empty();
        roots.add(cert).unwrap();
        Fake { trust: Trust { key: public(), base: format!("https://localhost:{port}/dl"), hosts: vec!["localhost".into()], roots: Some(Arc::new(roots)) }, _task: task }
    }

    fn ok(b: &[u8]) -> (u16, Vec<(String, String)>, Vec<u8>) {
        (200, vec![], b.to_vec())
    }

    #[tokio::test]
    async fn stage_verifies_everything() {
        let a = assets();
        let (review, iroh) = (fake("4.0.8", "exit 0"), b"iroh".to_vec());
        let j = release("4.0.8", &review, &iroh);
        let chunked = { let mut c = format!("{:x}\r\n", iroh.len()).into_bytes(); c.extend(&iroh); c.extend(b"\r\n0\r\n\r\n"); c };
        let r: HashMap<_, _> = [
            ("/dl/v4.0.8/host-release.json".into(), ok(&j)),
            ("/dl/v4.0.8/host-release.json.sig".into(), ok(&sign(&j))),
            // the binary through a redirect, like GitHub's asset CDN
            (format!("/dl/v4.0.8/{}", a[0]), (302, vec![("Location".into(), "SELF/cdn/review".into())], vec![])),
            ("/cdn/review".into(), ok(&review)),
            (format!("/dl/v4.0.8/{}", a[1]), (200, vec![("Transfer-Encoding".into(), "chunked".into())], chunked)),
            // 4.0.9: signed by someone else
            ("/dl/v4.0.9/host-release.json".into(), ok(&release("4.0.9", &review, &iroh))),
            ("/dl/v4.0.9/host-release.json.sig".into(), ok(&sign(b"other"))),
            // 4.1.0: the program doesn't match its hash
            ("/dl/v4.1.0/host-release.json".into(), ok(&release("4.1.0", b"other", &iroh))),
            ("/dl/v4.1.0/host-release.json.sig".into(), ok(&sign(&release("4.1.0", b"other", &iroh)))),
            (format!("/dl/v4.1.0/{}", a[0]), ok(&review)),
            // 4.2.0: a redirect off GitHub
            ("/dl/v4.2.0/host-release.json".into(), (302, vec![("Location".into(), "https://example.com/x".into())], vec![])),
        ].into_iter().collect();
        let trust = github(r).await.trust;
        let d = tmp("stage");
        stage(&d, &trust, "4.0.8").await.unwrap();
        assert!(check_dir(&bins(&d).join("4.0.8"), "4.0.8", &public()).is_ok());
        let e = format!("{:#}", stage(&d, &trust, "4.0.9").await.unwrap_err());
        assert!(e.contains("signature"), "{e}");
        let e = format!("{:#}", stage(&d, &trust, "4.1.0").await.unwrap_err());
        assert!(e.contains("doesn't match"), "{e}");
        let e = format!("{:#}", stage(&d, &trust, "4.2.0").await.unwrap_err());
        assert!(e.contains("isn't GitHub"), "{e}");
        assert!(get(&trust.base.replace("https", "http"), &trust, 10).await.is_err(), "https only");
        assert!(format!("{:#}", get(&format!("{}/v4.0.8/{}", trust.base, a[0]), &trust, 10).await.unwrap_err()).contains("too big"));
        assert_eq!(kept(&d), vec!["4.0.8"], "nothing half-written kept");
        assert!(!bins(&d).join(".4.1.0.part").exists(), "a failed stage removes its .part");
        assert!(dechunk(b"ffffffffffffffff\r\nab", 10).is_err() && dechunk(b"fffffffffffffffe\r\nab", usize::MAX).is_err(), "huge sizes: an error, not a panic");
        let _ = std::fs::remove_dir_all(d);
    }
}
