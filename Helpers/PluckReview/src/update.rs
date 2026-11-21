// Versions and updates (spec §13.15): the protocol level everywhere the version is reported, the
// health file the updater watches, `prepare-update` (no new uploads or copies while an update
// waits), the update request file, and `--ctl`, the updater's way to ask the running host.
use std::{
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    time::Duration,
};

use serde_json::{Value, json};

use crate::{host::now_iso, store::PROTOCOL};

/// The release tag (without a leading "v") when CI sets PLUCK_REVIEW_VERSION, else Cargo.toml's.
pub const VERSION: &str = match option_env!("PLUCK_REVIEW_VERSION") {
    Some(v) if !v.is_empty() => trim_v(v),
    _ => env!("CARGO_PKG_VERSION"),
};

const fn trim_v(v: &str) -> &str {
    match v.as_bytes() {
        [b'v', ..] => v.split_at(1).1,
        _ => v,
    }
}

/// Shared by the host task and the sync sessions (the uploads root counts its own uploads).
#[derive(Default)]
pub struct Busy {
    pub preparing: AtomicBool,
    pub root_uploads: AtomicUsize,
    /// Sync `put`/`get` byte transfers in flight (a Mac's push, a backup's pull): a switch waits for them too.
    pub transfers: AtomicUsize,
}

impl Busy {
    pub fn preparing(&self) -> bool {
        self.preparing.load(Ordering::Relaxed)
    }

    /// Counts one transfer until the guard drops (also on an error or a cut connection).
    pub fn transfer(&self) -> Transfer<'_> {
        self.transfers.fetch_add(1, Ordering::Relaxed);
        Transfer(self)
    }
}

pub struct Transfer<'a>(&'a Busy);

impl Drop for Transfer<'_> {
    fn drop(&mut self) {
        self.0.transfers.fetch_sub(1, Ordering::Relaxed);
    }
}

/// The answer to `prepare-update`: from now on no new uploads or copy jobs start.
pub fn prepare(busy: &Busy, client_uploads: usize, copies: usize) -> Value {
    busy.preparing.store(true, Ordering::Relaxed);
    let uploads = client_uploads + busy.root_uploads.load(Ordering::Relaxed) + busy.transfers.load(Ordering::Relaxed);
    let mut why = vec![];
    if uploads > 0 {
        why.push("upload");
    }
    if copies > 0 {
        why.push("copies");
    }
    if why.is_empty() {
        return json!({"busy": false});
    }
    // shortcut: a rough guess (5 min per copy job, 1 per upload); upgrade with real progress if the updater needs it.
    json!({"busy": true, "why": why, "eta": (copies * 300 + uploads * 60).clamp(60, 3600)})
}

fn update_dir(data: &Path) -> PathBuf {
    data.join("update")
}

/// `status` gains version, protocol, when this version first ran, and the updater's last result.
pub fn status_fields(s: &mut Value, data: &Path) {
    s["version"] = json!(VERSION);
    s["protocol"] = json!(PROTOCOL);
    let read = |f: &str| std::fs::read(update_dir(data).join(f)).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    s["updated"] = read("version.json").map_or(Value::Null, |v| v["at"].clone());
    s["lastUpdate"] = read("last.json").unwrap_or(Value::Null);
    if crate::selfupdate::active() {
        s["selfUpdate"] = crate::selfupdate::status(data);
    }
}

/// At start: note when this version first ran (status `updated`).
pub fn started(data: &Path) {
    let dir = update_dir(data);
    let _ = std::fs::create_dir_all(&dir);
    let f = dir.join("version.json");
    let same = std::fs::read(&f).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).is_some_and(|v| v["version"] == VERSION);
    if !same {
        let _ = std::fs::write(&f, json!({"version": VERSION, "at": now_iso()}).to_string());
    }
}

/// `{"op":"update","version":"<tag>"}`: a supervised host switches itself (selfupdate.rs); an older setup's host
/// (an unprivileged user) writes the request the root updater's path unit watches.
pub fn request(data: &Path, version: &str) -> Value {
    let ok = (1..=40).contains(&version.len()) && version.bytes().all(|b| b.is_ascii_alphanumeric() || b".-_+".contains(&b));
    if !ok {
        return json!({"error": "invalid"});
    }
    if crate::selfupdate::active() {
        let r = crate::selfupdate::op(data, &json!({"target": version, "now": true}));
        return if r.get("error").is_some() { r } else { json!({"ok": true}) };
    }
    let dir = update_dir(data);
    let tmp = dir.join("request.part");
    match std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(&tmp, format!("{version}\n"))).and_then(|_| std::fs::rename(&tmp, dir.join("request"))) {
        Ok(()) => json!({"ok": true}),
        Err(e) => json!({"error": format!("can't write the update request: {e}")}),
    }
}

pub fn health_path() -> PathBuf {
    std::env::var("PLUCK_HEALTH_FILE").map_or_else(|_| PathBuf::from("/run/pluck-review/health"), PathBuf::from)
}

/// The health file, once the host is up, rewritten every 30 s. A missing /run folder (a Mac, a
/// container without it) is only logged once.
pub async fn health(path: PathBuf) {
    let mut warned = false;
    loop {
        let body = json!({"version": VERSION, "protocol": PROTOCOL, "ok": true, "at": now_iso()}).to_string();
        let tmp = path.with_extension("part");
        if let Err(e) = std::fs::write(&tmp, body).and_then(|_| std::fs::rename(&tmp, &path)) {
            if !warned {
                crate::log(format!("health file {}: {e}", path.display()));
                warned = true;
            }
        }
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
}

/// `pluck-review --ctl <data> '<op>'`: one op over the host's loopback control listener, with
/// the host key. Exit 0 = an answer without "error", 1 = an error answer, 2 = no host running.
pub async fn ctl(data: &Path, op: &str) -> i32 {
    let run = async {
        let op: Value = serde_json::from_str(op)?;
        let c: Value = serde_json::from_slice(&crate::sync::read_plain(&data.join("ctl.json"), 4096)?)?;
        let (key, _) = crate::sync::host_key(data)?;
        let addr = c["listen"].as_str().ok_or_else(|| anyhow::anyhow!("no listen in ctl.json"))?;
        let fp = c["fingerprint"].as_str().unwrap_or("");
        let mut s = crate::sync::Client::connect(addr, fp, json!({"key": crate::keys::b64(&key), "protocol": PROTOCOL})).await?;
        anyhow::Ok(s.ask(&op).await?)
    };
    match tokio::time::timeout(Duration::from_secs(30), run).await {
        Ok(Ok(v)) => {
            println!("{v}");
            i32::from(v.get("error").is_some())
        }
        Ok(Err(e)) => {
            eprintln!("pluck-review --ctl: {e:#}");
            2
        }
        Err(_) => {
            eprintln!("pluck-review --ctl: no answer");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prepare_update_busy_logic() {
        let b = Busy::default();
        assert_eq!(prepare(&b, 0, 0), json!({"busy": false}));
        assert!(b.preparing(), "preparing from the first ask");
        let r = prepare(&b, 1, 2);
        assert_eq!((r["busy"].clone(), r["why"].clone(), r["eta"].clone()), (json!(true), json!(["upload", "copies"]), json!(660)));
        b.root_uploads.store(1, Ordering::Relaxed);
        assert_eq!(prepare(&b, 0, 0)["why"], json!(["upload"]), "uploads-root uploads count too");
        b.root_uploads.store(0, Ordering::Relaxed);
        let t = b.transfer();
        assert_eq!(prepare(&b, 0, 0)["why"], json!(["upload"]), "a sync put/get in flight counts");
        drop(t);
        assert_eq!(prepare(&b, 0, 0), json!({"busy": false}));
    }

    #[test]
    fn update_request_file() {
        let d = std::env::temp_dir().join(format!("pluck-upd-{}", std::process::id()));
        assert!(request(&d, "../x").get("error").is_some());
        assert_eq!(request(&d, "v1.2.3")["ok"], true);
        assert_eq!(std::fs::read_to_string(d.join("update/request")).unwrap(), "v1.2.3\n");
        std::fs::write(d.join("update/last.json"), r#"{"to":"v1.2.3","result":"ok"}"#).unwrap();
        started(&d);
        let mut s = json!({});
        status_fields(&mut s, &d);
        assert_eq!((s["protocol"].clone(), s["lastUpdate"]["result"].clone()), (json!(3), json!("ok")));
        assert!(s["updated"].is_string());
        let _ = std::fs::remove_dir_all(d);
    }
}
