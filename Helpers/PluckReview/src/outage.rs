// Uploads during an outage (spec §13.25). While the main is down its backup holds the room and takes
// uploads itself: clients' from the review page (host.rs, into its own quarantine uploads/<link>/)
// and editors' from Pluck (sync.rs, the backup's own uploads root "outage", <data>/outage-editor/),
// with the main's limits and checks. Each one is an item in <data>/outage.json. When the main is
// back, every round pushes them to it (outage-begin / outage-part + bytes / outage-end, role backup),
// resumable from the main's `have`; the backup deletes its copy only once the main answers with the
// same size and SHA-256. The main puts each file in "<uploads root>/Delivered while offline/<date>/"
// (or the folder the editor picked), comment attachments and, without an uploads root, everything
// else in its quarantine as if uploaded there, and logs the upload entry (same id) so attachments and
// Pluck's import find it. Its delivered.json lists them for Pluck's Inbox (outage-list, outage-done).
// Both sides say `"outage": 1` (the main in its hello, the backup by reporting `office` in its
// status); a 4.0.3 main or backup never sees any of it.
use std::{
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}},
};

use anyhow::Result;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWriteExt},
    sync::{mpsc, oneshot},
};

use crate::{host::{self, now_iso}, keys, log, sync::Client, upload_root::{self, UploadRoot}};

pub const FOLDER: &str = "Delivered while offline";
/// A backup's own uploads root for editors' files (id "outage"), in its data folder.
pub const EDITOR_DIR: &str = "outage-editor";
const PART: u64 = 16 << 20;
const RESERVE: u64 = 10 << 30;
const MAX_ATTACHMENT: u64 = 50 << 20;
const KINDS: [&str; 3] = ["asset", "attachment", "editor"];

/// outage.json on a backup (what arrived here, waiting for the main), delivered.json on a main (what its backups pushed).
pub struct Outage {
    pub data: PathBuf,
    path: PathBuf,
    items: Mutex<Vec<Value>>,
    /// A backup: its main takes pushed uploads (it said `"outage": 1`). Kept in main-outage, so it holds while the main is down.
    main_ok: AtomicBool,
    /// A backup: its main's Macs (outage-macs), for its office-mode pluck-iroh and the sync hello.
    pub devices: Option<Arc<crate::devices::Devices>>,
}

/// A SHA-256 as lowercase hex, from hex (Pluck's) or base64url (a browser's).
pub fn hex_sha(s: &str) -> Option<String> {
    if s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Some(s.to_ascii_lowercase());
    }
    keys::unb64(s).filter(|b| b.len() == 32).map(|b| b.iter().map(|x| format!("{x:02x}")).collect())
}

fn id_ok(s: &str) -> bool {
    (1..=64).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn ext_of(name: &str) -> Option<String> {
    Path::new(name).extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase)
        .filter(|e| (1..=8).contains(&e.len()) && e.bytes().all(|b| b.is_ascii_alphanumeric()))
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::symlink_metadata(a), std::fs::symlink_metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

impl Outage {
    pub fn load(data: &Path, backup: bool, devices: Option<Arc<crate::devices::Devices>>) -> Arc<Outage> {
        let path = data.join(if backup { "outage.json" } else { "delivered.json" });
        let items = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice::<Vec<Value>>(&b).ok()).unwrap_or_default();
        let main_ok = backup && std::fs::read_to_string(data.join("main-outage")).is_ok_and(|s| s.trim() == "1");
        Arc::new(Outage { data: data.into(), path, items: Mutex::new(items), main_ok: AtomicBool::new(main_ok), devices })
    }

    fn save(&self, items: &[Value]) {
        let tmp = self.path.with_extension("json.part");
        let _ = std::fs::remove_file(&tmp);
        let r = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)
            .and_then(|mut f| std::io::Write::write_all(&mut f, Value::from(items.to_vec()).to_string().as_bytes()).and_then(|_| f.sync_all()))
            .and_then(|_| std::fs::rename(&tmp, &self.path));
        if let Err(e) = r {
            log(format!("{}: {e}", self.path.display()));
        }
    }

    /// A backup takes uploads only while its main can take them on (so nothing waits for a main that never will).
    pub fn accepting(&self) -> bool {
        self.main_ok.load(Ordering::Relaxed)
    }

    pub fn set_main(&self, ok: bool) {
        if self.main_ok.swap(ok, Ordering::Relaxed) != ok {
            let p = self.data.join("main-outage");
            let _ = if ok { std::fs::write(p, "1\n") } else { std::fs::remove_file(p) };
        }
    }

    pub fn add(&self, item: Value) {
        let mut i = self.items.lock().unwrap();
        i.retain(|x| x["id"] != item["id"]);
        i.push(item);
        self.save(&i);
    }

    pub fn items(&self) -> Vec<Value> {
        self.items.lock().unwrap().clone()
    }

    fn get(&self, id: &str) -> Option<Value> {
        self.items.lock().unwrap().iter().find(|x| x["id"] == id).cloned()
    }

    fn update(&self, id: &str, f: impl FnOnce(&mut Value)) {
        let mut i = self.items.lock().unwrap();
        if let Some(x) = i.iter_mut().find(|x| x["id"] == id) {
            f(x);
            self.save(&i);
        }
    }

    fn remove(&self, id: &str) {
        let mut i = self.items.lock().unwrap();
        i.retain(|x| x["id"] != id);
        self.save(&i);
    }

    /// `outage-list` (a main, for Pluck's Inbox): what arrived during an outage, newest first.
    pub fn list(&self) -> Value {
        let i = self.items.lock().unwrap();
        let mut out: Vec<Value> = i.iter().filter(|x| x["state"] == "delivered").map(|x| {
            let mut x = x.clone();
            if let Some(o) = x.as_object_mut() {
                for k in ["state", "part", "target"] { o.remove(k); }
            }
            x
        }).collect();
        out.reverse();
        out.truncate(1000);
        json!({"items": out})
    }

    /// `outage-done`: the Inbox entry was dealt with (moved: its new path).
    pub fn done(&self, id: &str, path: Option<&str>) -> Value {
        if self.get(id).is_none_or(|x| x["state"] != "delivered") {
            return json!({"error": "notFound"});
        }
        self.update(id, |x| {
            x["moved"] = json!(true);
            if let Some(p) = path.filter(|p| p.len() < 2048) { x["path"] = json!(p) }
        });
        json!({"ok": true})
    }

    // ---- the main: receiving a backup's pushes ----

    fn part_path(&self, uploads: Option<&UploadRoot>, item: &Value) -> PathBuf {
        let id = item["id"].as_str().unwrap_or("");
        match uploads.filter(|_| item["kind"] != "attachment") {
            Some(u) => u.partial_dir().join(format!("outage-{id}.part")),
            None => self.data.join("outage-partial").join(format!("{id}.part")),
        }
    }

    /// outage-begin / outage-part (+ n bytes, always read) / outage-end from a backup.
    pub async fn receive<R: AsyncRead + Unpin>(&self, op_name: &str, op: &Value, r: &mut R, uploads: Option<&UploadRoot>,
                                               to_host: &mpsc::Sender<host::Sync>) -> Result<Value> {
        Ok(match op_name {
            "outage-begin" => self.begin(&op["item"], uploads, to_host).await,
            "outage-part" => return self.part(op, r).await,
            _ => self.end(op["upload"].as_str().unwrap_or(""), uploads, to_host).await,
        })
    }

    fn done_answer(x: &Value) -> Value {
        json!({"done": {"path": x["path"], "size": x["size"], "sha256": x["hex"]}})
    }

    async fn begin(&self, item: &Value, uploads: Option<&UploadRoot>, to_host: &mpsc::Sender<host::Sync>) -> Value {
        let id = item["id"].as_str().filter(|i| id_ok(i)).unwrap_or("");
        if let Some(x) = self.get(id) {
            match x["state"].as_str() {
                Some("delivered") => return Self::done_answer(&x), // pushed before: nothing twice
                Some("placing") => return self.finish(id, uploads, to_host).await.map(|x| Self::done_answer(&x)).unwrap_or_else(|c| json!({"error": c})),
                _ => {}
            }
        }
        let r = (|| -> Result<Value, &'static str> {
            let kind = item["kind"].as_str().filter(|k| KINDS.contains(k)).ok_or("invalid")?;
            let size = item["size"].as_u64().ok_or("invalid")?;
            let hex = item["sha256"].as_str().and_then(hex_sha).ok_or("invalid")?;
            let name = host::clean(item["name"].as_str().unwrap_or(""), 120);
            if id.is_empty() || name.is_empty() || name.starts_with('.') || ext_of(&name).is_none() && kind != "editor" {
                return Err("invalid");
            }
            if kind != "editor" && !item["link"].as_str().is_some_and(id_ok) {
                return Err("invalid");
            }
            if size > if kind == "attachment" { MAX_ATTACHMENT } else { upload_root::MAX_FILE } {
                return Err("tooLarge");
            }
            let part = self.part_path(uploads, item);
            std::fs::create_dir_all(part.parent().unwrap()).map_err(|_| "internal")?;
            let mut have = std::fs::symlink_metadata(&part).ok().filter(|m| m.is_file()).map_or(0, |m| m.len());
            if have > size {
                let _ = std::fs::remove_file(&part);
                have = 0;
            }
            if upload_root::free_space(part.parent().unwrap()).unwrap_or(0) < (size - have).saturating_add(RESERVE) {
                return Err("space");
            }
            if !part.exists() {
                std::fs::OpenOptions::new().write(true).create_new(true).custom_flags(libc::O_NOFOLLOW).mode(0o640).open(&part).map_err(|_| "internal")?;
            }
            let mut x = json!({"id": id, "kind": kind, "name": name, "size": size, "sha256": item["sha256"], "hex": hex, "type": item["type"],
                "link": item["link"], "by": host::clean(item["by"].as_str().unwrap_or(""), 120), "at": item["at"], "state": "receiving",
                "part": part.to_string_lossy()});
            if let Some(f) = item["folder"].as_str().filter(|f| f.len() <= 1024) {
                x["folder"] = json!(f);
            }
            if self.get(id).is_none() {
                self.add(x);
            }
            Ok(json!({"upload": id, "have": have}))
        })();
        r.unwrap_or_else(|c| json!({"error": c}))
    }

    async fn part<R: AsyncRead + Unpin>(&self, op: &Value, r: &mut R) -> Result<Value> {
        let n = op["size"].as_u64().filter(|n| *n <= upload_root::MAX_PART).ok_or_else(|| anyhow::anyhow!("bad outage-part"))?;
        let item = op["upload"].as_str().and_then(|id| self.get(id)).filter(|x| x["state"] == "receiving");
        let part = item.as_ref().and_then(|x| x["part"].as_str().map(PathBuf::from));
        let have = part.as_ref().and_then(|p| std::fs::symlink_metadata(p).ok()).filter(|m| m.is_file()).map_or(0, |m| m.len());
        let fits = item.as_ref().is_some_and(|x| have + n <= x["size"].as_u64().unwrap_or(0));
        let (Some(part), true, true) = (part, op["offset"].as_u64() == Some(have), fits) else {
            tokio::io::copy(&mut r.take(n), &mut tokio::io::sink()).await?;
            return Ok(if item.is_none() { json!({"error": "notFound"}) } else { json!({"error": "offset", "have": have}) });
        };
        let f = std::fs::OpenOptions::new().append(true).custom_flags(libc::O_NOFOLLOW).open(&part)?;
        let mut f = tokio::fs::File::from_std(f);
        let got = tokio::io::copy(&mut r.take(n), &mut f).await?;
        f.flush().await?;
        anyhow::ensure!(got == n, "outage push cut short");
        Ok(json!({"ok": true, "have": have + n}))
    }

    async fn end(&self, id: &str, uploads: Option<&UploadRoot>, to_host: &mpsc::Sender<host::Sync>) -> Value {
        let Some(x) = self.get(id) else { return json!({"error": "notFound"}) };
        if x["state"] == "receiving" {
            let part = PathBuf::from(x["part"].as_str().unwrap_or(""));
            let have = std::fs::symlink_metadata(&part).map_or(0, |m| m.len());
            if have != x["size"].as_u64().unwrap_or(0) {
                return json!({"error": "offset", "have": have});
            }
            let p2 = part.clone();
            let sha = tokio::task::spawn_blocking(move || {
                let s = host::sha256_file(&p2)?;
                std::fs::File::open(&p2)?.sync_all()?;
                Ok::<_, std::io::Error>(s)
            }).await.ok().and_then(Result::ok);
            if sha.as_deref() != x["hex"].as_str() {
                let _ = std::fs::remove_file(&part); // sent again from the start
                return json!({"error": "checksum"});
            }
            self.update(id, |x| x["state"] = json!("placing"));
        }
        match self.finish(id, uploads, to_host).await {
            Ok(x) => json!({"ok": true, "path": x["path"], "size": x["size"], "sha256": x["hex"]}),
            Err(c) => json!({"error": c}),
        }
    }

    /// A whole, checked file into its place, and its upload entry logged. Safe to run again after a restart at any point:
    /// the place chosen is recorded before link() makes it, and a name already holding this very file is ours.
    async fn finish(&self, id: &str, uploads: Option<&UploadRoot>, to_host: &mpsc::Sender<host::Sync>) -> Result<Value, &'static str> {
        let x = self.get(id).ok_or("notFound")?;
        if x["state"] == "delivered" {
            return Ok(x);
        }
        let part = PathBuf::from(x["part"].as_str().unwrap_or(""));
        let (kind, name, link) = (x["kind"].as_str().unwrap_or(""), x["name"].as_str().unwrap_or(""), x["link"].as_str().unwrap_or("outage"));
        let root = uploads.filter(|_| kind != "attachment");
        let path = match root {
            None => {
                // The quarantine, as if it had been uploaded here (Pluck imports it as today).
                let rel = format!("uploads/{link}/{id}.{}", ext_of(name).unwrap_or_else(|| "bin".into()));
                let dest = self.data.join(&rel);
                if !dest.exists() {
                    dest.parent().map(std::fs::create_dir_all).transpose().map_err(|_| "internal")?;
                    std::fs::rename(&part, &dest).map_err(|_| "internal")?;
                }
                rel
            }
            Some(u) => {
                let date = x["at"].as_str().and_then(host::norm_iso).unwrap_or_else(now_iso)[..10].to_owned();
                let picked = x["folder"].as_str().filter(|_| kind == "editor").and_then(|f| u.folder(f).ok().map(|d| (f.to_owned(), d)));
                let (folder, dir) = match picked {
                    Some(p) => p,
                    None => {
                        let f = format!("{}/{FOLDER}/{date}", u.id);
                        let d = u.folder(&f)?;
                        (f, d)
                    }
                };
                let safe = if upload_root::name_ok(name) { name.to_owned() } else { format!("{id}.{}", ext_of(name).unwrap_or_else(|| "bin".into())) };
                let (stem, ext) = match safe.rsplit_once('.') { Some((s, e)) if !s.is_empty() => (s.to_owned(), format!(".{e}")), _ => (safe.clone(), String::new()) };
                let mut placed = None;
                if !part.exists() {
                    // Linked and unlinked before a restart: the recorded target is it.
                    placed = x["target"].as_str().filter(|t| x["targetDir"].as_str() == Some(&dir.to_string_lossy())).map(str::to_owned)
                        .filter(|t| dir.join(t).is_file());
                    if placed.is_none() {
                        return Err("lost");
                    }
                }
                for n in 1..1000 {
                    if placed.is_some() {
                        break;
                    }
                    let cand = if n == 1 { safe.clone() } else { format!("{stem} {n}{ext}") };
                    let d = dir.to_string_lossy().into_owned();
                    self.update(id, |x| { x["target"] = json!(cand); x["targetDir"] = json!(d); });
                    match std::fs::hard_link(&part, dir.join(&cand)) {
                        Ok(()) => placed = Some(cand),
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && same_file(&part, &dir.join(&cand)) => placed = Some(cand),
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                        Err(_) => return Err("internal"),
                    }
                }
                let placed = placed.ok_or("exists")?;
                let _ = std::fs::remove_file(&part);
                format!("{folder}/{placed}")
            }
        };
        self.update(id, |x| x["path"] = json!(path));
        // Attachments and clients' files are logged like an upload made here (same id: comments' attachments resolve,
        // Pluck imports them); an editor's file is Pluck's own, found through outage-list.
        if kind != "editor" {
            let mut e = json!({"id": id, "link": x["link"], "name": name, "path": path, "size": x["size"], "sha256": x["sha256"], "type": x["type"],
                "for": if kind == "attachment" { "attachment" } else { "asset" }, "by": x["by"], "at": x["at"], "outage": true});
            if root.is_some() {
                e["root"] = json!(true);
            }
            let (tx, rx) = oneshot::channel();
            to_host.send(host::Sync { op: json!({"op": "_outage-entry", "entry": e}), reply: tx }).await.map_err(|_| "internal")?;
            if rx.await.map_err(|_| "internal")?.get("error").is_some() {
                return Err("write");
            }
        }
        let quarantine = root.is_none() && kind != "attachment";
        self.update(id, |x| {
            x["state"] = json!("delivered");
            x["delivered"] = json!(now_iso());
            x["quarantine"] = json!(quarantine);
            x["moved"] = json!(kind == "editor" && x["folder"].is_string() && !path.starts_with(&format!("{}/{FOLDER}/", uploads.map_or("", |u| u.id.as_str()))));
        });
        self.get(id).ok_or("internal")
    }

    // ---- the backup: pushing to the main once it's back ----

    /// Every item to the main, oldest first; each deleted here only once the main has it whole (same size and hash).
    /// Ok(n) when the main refused something (space…): the rest wait for the next round, the round goes on.
    pub async fn push(&self, c: &mut Client) -> Result<usize> {
        let mut n = 0;
        for item in self.items() {
            let id = item["id"].as_str().unwrap_or("").to_owned();
            let file = item["file"].as_str().and_then(host::safe_rel).map(|p| self.data.join(p));
            if item.get("pushed").is_none() {
                let Some(file) = file.as_ref().filter(|f| f.is_file()) else {
                    log(format!("backup: an upload that arrived during the outage is gone here ({id})"));
                    self.remove(&id);
                    continue;
                };
                let size = item["size"].as_u64().unwrap_or(0);
                let mut out = item.clone();
                if let Some(o) = out.as_object_mut() {
                    for k in ["file", "device"] { o.remove(k); }
                }
                let b = c.ask(&json!({"op": "outage-begin", "item": out})).await?;
                let done = match b.get("done") {
                    Some(d) => d.clone(),
                    None => {
                        let Some(mut have) = b["have"].as_u64() else {
                            log(format!("backup: the main didn't take {} yet: {b}", item["name"]));
                            return Ok(n);
                        };
                        let mut f = tokio::fs::File::open(file).await?;
                        let mut buf = vec![];
                        while have < size {
                            let k = PART.min(size - have);
                            f.seek(std::io::SeekFrom::Start(have)).await?;
                            buf.resize(k as usize, 0);
                            f.read_exact(&mut buf).await?;
                            let a = c.send(&json!({"op": "outage-part", "upload": id, "offset": have, "size": k}), &buf).await?;
                            have = a["have"].as_u64().ok_or_else(|| anyhow::anyhow!("outage-part: {a}"))?;
                        }
                        let e = c.ask(&json!({"op": "outage-end", "upload": id})).await?;
                        if e["ok"] != true {
                            log(format!("backup: the main didn't take {}: {e}", item["name"]));
                            return Ok(n);
                        }
                        e
                    }
                };
                let want = item["sha256"].as_str().and_then(hex_sha);
                anyhow::ensure!(done["size"].as_u64() == Some(size) && done["sha256"].as_str().map(str::to_owned) == want,
                    "the main's copy of {id} differs: {done}");
                self.update(&id, |x| x["pushed"] = done["path"].clone());
            }
            if let Some(f) = file {
                let _ = std::fs::remove_file(f);
            }
            self.remove(&id);
            n += 1;
        }
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::Digest;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pluck-outage-{tag}-{}", host::uuid()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn hex(b: &[u8]) -> String {
        sha2::Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
    }

    /// The host task's part: logs `_outage-entry` and counts them.
    fn host_task() -> (mpsc::Sender<host::Sync>, Arc<Mutex<Vec<Value>>>) {
        let (tx, mut rx) = mpsc::channel::<host::Sync>(4);
        let seen = Arc::new(Mutex::new(vec![]));
        let s2 = seen.clone();
        tokio::spawn(async move {
            while let Some(s) = rx.recv().await {
                let mut l = s2.lock().unwrap();
                if !l.iter().any(|e: &Value| e["id"] == s.op["entry"]["id"]) {
                    l.push(s.op["entry"].clone());
                }
                let _ = s.reply.send(json!({"ok": true}));
            }
        });
        (tx, seen)
    }

    async fn send(o: &Outage, id: &str, offset: u64, bytes: &[u8]) -> Value {
        let mut r = bytes;
        o.receive("outage-part", &json!({"upload": id, "offset": offset, "size": bytes.len()}), &mut r, None, &mpsc::channel(1).0).await.unwrap()
    }

    #[test]
    fn shas_in_either_form() {
        let h = hex(b"abc");
        assert_eq!(hex_sha(&h.to_uppercase()), Some(h.clone()));
        assert_eq!(hex_sha(&keys::sha256_b64(b"abc")), Some(h));
        assert_eq!(hex_sha("nope"), None);
    }

    /// A client's file and an editor's: into the delivery folder (or the editor's), resumed after a cut, never twice,
    /// the entry logged once with the backup's id; without an uploads root, the quarantine as today.
    #[tokio::test]
    async fn the_main_places_pushed_files_once() {
        let data = tmp("main");
        let rootdir = tmp("root");
        std::fs::create_dir_all(rootdir.join("Client/2026")).unwrap();
        let root = UploadRoot::parse(&format!("renders={}", rootdir.display()), &[], Arc::default()).unwrap();
        let o = Outage::load(&data, false, None);
        let (to_host, logged) = host_task();
        let body = b"0123456789".repeat(30);
        let item = json!({"id": "U1", "kind": "asset", "name": "Interview A.mov", "size": body.len(), "sha256": keys::sha256_b64(&body),
            "type": "video/quicktime", "link": "L1", "by": "Client", "at": "2026-11-16T10:00:00Z"});
        let b = o.receive("outage-begin", &json!({"item": item}), &mut &b""[..], Some(&root), &to_host).await.unwrap();
        assert_eq!(b, json!({"upload": "U1", "have": 0}));
        let mut r = &body[..100];
        o.receive("outage-part", &json!({"upload": "U1", "offset": 0, "size": 100}), &mut r, Some(&root), &to_host).await.unwrap();
        // The backup restarts mid-push: begin again resumes from what's here.
        let b = o.receive("outage-begin", &json!({"item": item}), &mut &b""[..], Some(&root), &to_host).await.unwrap();
        assert_eq!(b["have"], 100);
        assert_eq!(send(&o, "U1", 50, &body[100..]).await, json!({"error": "offset", "have": 100}), "a wrong offset");
        send(&o, "U1", 100, &body[100..]).await;
        let e = o.receive("outage-end", &json!({"upload": "U1"}), &mut &b""[..], Some(&root), &to_host).await.unwrap();
        assert_eq!(e["path"], format!("renders/{FOLDER}/2026-11-16/Interview A.mov"));
        assert_eq!((e["size"].as_u64(), e["sha256"].as_str()), (Some(300), Some(hex(&body).as_str())));
        assert_eq!(std::fs::read(rootdir.join(FOLDER).join("2026-11-16/Interview A.mov")).unwrap(), body);
        // Pushed again (the backup never heard the answer): the same answer, nothing new.
        let again = o.receive("outage-begin", &json!({"item": item}), &mut &b""[..], Some(&root), &to_host).await.unwrap();
        assert_eq!(again["done"]["path"], e["path"]);
        assert_eq!(std::fs::read_dir(rootdir.join(FOLDER).join("2026-11-16")).unwrap().count(), 1, "nothing twice");
        assert!(!rootdir.join(upload_root::PARTIAL).join("outage-U1.part").exists());
        let l = logged.lock().unwrap().clone();
        assert_eq!((l.len(), l[0]["id"].clone(), l[0]["root"].clone(), l[0]["for"].clone()), (1, json!("U1"), json!(true), json!("asset")));
        // An editor's, with the folder it picked; the same name there gets " 2".
        std::fs::write(rootdir.join("Client/2026/Spot.mov"), b"old").unwrap();
        let spot = b"spot".to_vec();
        let ed = json!({"id": "E1", "kind": "editor", "name": "Spot.mov", "size": 4, "sha256": hex(&spot), "by": "MacBook", "at": now_iso(), "folder": "renders/Client/2026"});
        o.receive("outage-begin", &json!({"item": ed}), &mut &b""[..], Some(&root), &to_host).await.unwrap();
        let mut r = &spot[..];
        o.receive("outage-part", &json!({"upload": "E1", "offset": 0, "size": 4}), &mut r, Some(&root), &to_host).await.unwrap();
        // A restart between link() and the answer: the file is linked, the partial still there.
        let x = o.get("E1").unwrap();
        std::fs::hard_link(x["part"].as_str().unwrap(), rootdir.join("Client/2026/Spot 2.mov")).unwrap();
        o.update("E1", |x| { x["state"] = json!("placing"); x["target"] = json!("Spot 2.mov"); x["targetDir"] = json!(std::fs::canonicalize(rootdir.join("Client/2026")).unwrap().to_string_lossy()); });
        let e = o.receive("outage-begin", &json!({"item": ed}), &mut &b""[..], Some(&root), &to_host).await.unwrap();
        assert_eq!(e["done"]["path"], "renders/Client/2026/Spot 2.mov", "the file already linked is it");
        assert_eq!(std::fs::read_dir(rootdir.join("Client/2026")).unwrap().count(), 2, "Spot.mov and Spot 2.mov, no Spot 3");
        assert_eq!(logged.lock().unwrap().len(), 1, "an editor's file isn't logged");
        let list = o.list();
        assert_eq!(list["items"].as_array().unwrap().len(), 2);
        assert_eq!(list["items"][0]["moved"], true, "already where the editor wanted it");
        assert_eq!(list["items"][1]["moved"], false);
        assert_eq!(o.done("U1", Some("renders/Client/2026/Interview A.mov"))["ok"], true);
        assert_eq!(o.list()["items"][1]["path"], "renders/Client/2026/Interview A.mov");
        // A wrong hash is sent again from the start.
        let bad = json!({"id": "B1", "kind": "asset", "name": "b.mov", "size": 3, "sha256": hex(b"abd"), "link": "L1", "at": now_iso()});
        o.receive("outage-begin", &json!({"item": bad}), &mut &b""[..], Some(&root), &to_host).await.unwrap();
        send(&o, "B1", 0, b"abc").await;
        assert_eq!(o.receive("outage-end", &json!({"upload": "B1"}), &mut &b""[..], Some(&root), &to_host).await.unwrap(), json!({"error": "checksum"}));
        assert_eq!(o.receive("outage-begin", &json!({"item": bad}), &mut &b""[..], Some(&root), &to_host).await.unwrap()["have"], 0);
        // Without an uploads root (and for attachments always): the quarantine.
        let plain = Outage::load(&tmp("main2"), false, None);
        let att = json!({"id": "A1", "kind": "attachment", "name": "ref.png", "size": 3, "sha256": keys::sha256_b64(b"png"), "type": "image/png", "link": "L1", "at": now_iso()});
        plain.receive("outage-begin", &json!({"item": att}), &mut &b""[..], None, &to_host).await.unwrap();
        let mut r = &b"png"[..];
        plain.receive("outage-part", &json!({"upload": "A1", "offset": 0, "size": 3}), &mut r, None, &to_host).await.unwrap();
        let e = plain.receive("outage-end", &json!({"upload": "A1"}), &mut &b""[..], None, &to_host).await.unwrap();
        assert_eq!(e["path"], "uploads/L1/A1.png");
        assert_eq!(std::fs::read(plain.data.join("uploads/L1/A1.png")).unwrap(), b"png");
        assert!(logged.lock().unwrap().iter().any(|x| x["id"] == "A1" && x["for"] == "attachment" && x.get("root").is_none()));
        // Bad items.
        for bad in [json!({"id": "../x", "kind": "asset", "name": "a.mov", "size": 1, "sha256": hex(b"a"), "link": "L1"}),
                    json!({"id": "X2", "kind": "asset", "name": "a.mov", "size": 1, "sha256": "zz", "link": "L1"}),
                    json!({"id": "X3", "kind": "other", "name": "a.mov", "size": 1, "sha256": hex(b"a"), "link": "L1"}),
                    json!({"id": "X4", "kind": "attachment", "name": "a.png", "size": MAX_ATTACHMENT + 1, "sha256": hex(b"a"), "link": "L1"})] {
            assert!(plain.receive("outage-begin", &json!({"item": bad}), &mut &b""[..], None, &to_host).await.unwrap()["error"].is_string(), "{bad}");
        }
        let _ = (std::fs::remove_dir_all(&data), std::fs::remove_dir_all(&rootdir));
    }

    #[test]
    fn a_backup_takes_uploads_only_for_a_main_that_takes_them_on() {
        let data = tmp("b");
        let o = Outage::load(&data, true, None);
        assert!(!o.accepting(), "until the main said so");
        o.set_main(true);
        assert!(Outage::load(&data, true, None).accepting(), "kept for while the main is down");
        o.set_main(false);
        assert!(!Outage::load(&data, true, None).accepting());
    }
}
