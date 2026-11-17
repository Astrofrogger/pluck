// The one write-enabled root (spec §13.2, `--uploads <id>=<path>`): Macs put renders there over
// the sync channel, resumable, then add them as versions by reference. Media roots stay
// read-only. Every path component passes the file name rule, the parent's realpath stays inside
// the root, partial files open O_NOFOLLOW|O_CREAT|O_EXCL, and the final file is made with link()
// so nothing is ever overwritten ("Name 2.mov" when the name is taken).
use std::{
    collections::HashMap,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, atomic::Ordering},
    time::{Duration, SystemTime},
};

use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};

use crate::{host::now_iso, update::Busy};

pub const PARTIAL: &str = ".pluck-partial";
pub const MAX_FILE: u64 = 200 << 30;
pub const MAX_PART: u64 = 64 << 20;
const MAX_DEPTH: usize = 8;
const PER_DEVICE: usize = 2;
const IN_ALL: usize = 4;
const KEEP_PARTIAL: Duration = Duration::from_secs(7 * 86_400);

pub struct UploadRoot {
    pub id: String,
    pub dir: PathBuf,
    pub reserve: u64, // free space left over after an upload: 10 GB
    active: Mutex<HashMap<String, String>>, // upload id → device
    busy: Arc<Busy>,
}

/// The §6.1 file name rule, as a check: one plain component, no `/ \ :`, no leading dot, no
/// control characters, ≤ 120 characters.
pub fn name_ok(c: &str) -> bool {
    !c.is_empty() && c.chars().count() <= 120 && !c.starts_with('.') && !c.chars().any(|ch| ch.is_control() || "/\\:".contains(ch)) && c.trim() == c
}

pub fn free_space(dir: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: c is a valid NUL-terminated path and s a properly sized out-parameter.
    (unsafe { libc::statvfs(c.as_ptr(), &mut s) } == 0).then(|| (s.f_bavail as u64).saturating_mul(s.f_frsize as u64))
}

impl UploadRoot {
    /// `id=path`; the id must differ from every media root's.
    pub fn parse(spec: &str, media: &[String], busy: Arc<Busy>) -> Option<UploadRoot> {
        let (id, p) = spec.split_once('=')?;
        let ok = !id.is_empty() && id.len() <= 32 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
        if !ok || media.iter().any(|m| m == id) {
            crate::log(format!("uploads root {spec}: bad or duplicate id"));
            return None;
        }
        let dir = std::fs::canonicalize(p).map_err(|e| crate::log(format!("uploads root {spec}: {e}"))).ok()?;
        let r = UploadRoot { id: id.into(), dir, reserve: 10 << 30, active: Mutex::default(), busy };
        r.sweep();
        Some(r)
    }

    fn partial(&self) -> PathBuf {
        self.dir.join(PARTIAL)
    }

    /// "<id>/a/b/c" → the checked components after the root id.
    fn parts<'a>(&self, path: &'a str) -> Result<Vec<&'a str>, &'static str> {
        let rest = path.strip_prefix(&self.id).and_then(|r| r.strip_prefix('/')).ok_or("scope")?;
        let parts: Vec<&str> = rest.split('/').collect();
        if parts.len() > MAX_DEPTH || !parts.iter().all(|c| name_ok(c)) {
            return Err("invalid");
        }
        Ok(parts)
    }

    /// A folder inside the root, by its real path (no symlink leads out, never the partial folder).
    fn inside(&self, dir: &Path) -> Result<PathBuf, &'static str> {
        let real = std::fs::canonicalize(dir).map_err(|_| "notFound")?;
        if !real.starts_with(&self.dir) || real.starts_with(self.partial()) || !real.is_dir() {
            return Err("scope");
        }
        Ok(real)
    }

    pub fn mkdir(&self, path: &str) -> Value {
        self.folder(path).map(|_| json!({"ok": true})).unwrap_or_else(|c| json!({"error": c}))
    }

    /// A folder of the root ("<id>" or "<id>/a/b"), made when missing, by its real path (checked as mkdir checks).
    pub fn folder(&self, path: &str) -> Result<PathBuf, &'static str> {
        if path == self.id {
            return self.inside(&self.dir);
        }
        let mut at = self.dir.clone();
        for c in self.parts(path)? {
            at = self.inside(&at)?.join(c);
            match std::fs::create_dir(&at) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err("internal"),
            }
        }
        self.inside(&at)
    }

    /// Where pushed files wait inside the root (same filesystem as their final place: link() works).
    pub fn partial_dir(&self) -> PathBuf {
        self.partial()
    }

    /// `move`: a file in the root into another folder of it, its name kept (" 2" when taken: never overwritten).
    /// Both sides pass the same checks as an upload; the partial folder is neither a source nor a destination.
    pub fn move_file(&self, from: &str, to: &str) -> Value {
        let r = (|| {
            let src = self.parts(from)?;
            let dst = if to == self.id { vec![] } else { self.parts(to)? };
            let parent = src[..src.len() - 1].iter().fold(self.dir.clone(), |p, c| p.join(c));
            let file = self.inside(&parent)?.join(src[src.len() - 1]);
            let meta = std::fs::symlink_metadata(&file).map_err(|_| "notFound")?;
            if !meta.is_file() {
                return Err("invalid"); // (no folders, no links)
            }
            let real = self.inside(&dst.iter().fold(self.dir.clone(), |p, c| p.join(c)))?;
            let name = src[src.len() - 1];
            let (stem, ext) = match name.rsplit_once('.') { Some((s, e)) if !s.is_empty() => (s, format!(".{e}")), _ => (name, String::new()) };
            for n in 1..1000 {
                let candidate = if n == 1 { name.to_owned() } else { format!("{stem} {n}{ext}") };
                let target = real.join(&candidate);
                if target == file {
                    return Ok(json!({"ok": true, "path": from})); // already there
                }
                match std::fs::hard_link(&file, &target) {
                    Ok(()) => {
                        let _ = std::fs::remove_file(&file);
                        let shown = if dst.is_empty() { format!("{}/{candidate}", self.id) } else { format!("{}/{}/{candidate}", self.id, dst.join("/")) };
                        return Ok(json!({"ok": true, "path": shown}));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(_) => return Err("internal"),
                }
            }
            Err("exists")
        })();
        r.unwrap_or_else(|c| json!({"error": c}))
    }

    fn files(&self, id: &str) -> (PathBuf, PathBuf) {
        (self.partial().join(format!("{id}.part")), self.partial().join(format!("{id}.json")))
    }

    pub fn begin(&self, op: &Value, device: &str) -> Value {
        let r = (|| {
            if self.busy.preparing() {
                return Err("limit");
            }
            let path = op["path"].as_str().ok_or("invalid")?;
            let parts = self.parts(path)?;
            let size = op["size"].as_u64().ok_or("invalid")?;
            let sha = op["sha256"].as_str().filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())).ok_or("invalid")?.to_ascii_lowercase();
            if size > MAX_FILE {
                return Err("tooLarge");
            }
            let parent = parts[..parts.len() - 1].iter().fold(self.dir.clone(), |p, c| p.join(c));
            self.inside(&parent)?;
            // Same bytes to another path or from another device are another upload; the same ones resume.
            let to: String = <sha2::Sha256 as sha2::Digest>::digest(format!("{device}\0{path}")).iter().take(8).map(|b| format!("{b:02x}")).collect();
            let id = format!("{sha}-{size}-{to}");
            {
                let mut a = self.active.lock().unwrap();
                if !a.contains_key(&id) {
                    if a.values().filter(|d| *d == device).count() >= PER_DEVICE || a.len() >= IN_ALL {
                        return Err("limit");
                    }
                }
                a.insert(id.clone(), device.to_owned());
                self.busy.root_uploads.store(a.len(), Ordering::Relaxed);
            }
            // A full disk can't even make the partial folder: say "space", not "internal".
            let full = |s: &Self| free_space(&s.dir).is_some_and(|f| f < size.saturating_add(s.reserve));
            if std::fs::create_dir_all(self.partial()).is_err() {
                self.release(&id);
                return Err(if full(self) { "space" } else { "internal" });
            }
            let (part, meta) = self.files(&id);
            let mut have = std::fs::symlink_metadata(&part).ok().filter(|m| m.is_file()).map_or(0, |m| m.len());
            if have > size {
                let _ = std::fs::remove_file(&part);
                have = 0;
            }
            // Space first: on a full disk even the empty partial file can't be made.
            let free = free_space(&self.partial()).unwrap_or(0); // can't tell: refuse (fails closed)
            if free < (size - have).saturating_add(self.reserve) {
                self.release(&id);
                return Err("space");
            }
            if have == 0 && !part.exists() {
                std::fs::OpenOptions::new().write(true).create_new(true).custom_flags(libc::O_NOFOLLOW).mode(0o640).open(&part)
                    .map_err(|_| { self.release(&id); "internal" })?;
            }
            let mut m = json!({"path": path, "size": size, "sha256": sha, "device": device, "started": now_iso()});
            // A backup (§13.25): the folder the editor picked on the main, applied there when the file moves.
            if let Some(f) = op["folder"].as_str().filter(|f| f.len() <= 1024 && !f.contains('\0')) {
                m["folder"] = json!(f);
            }
            // A browser's upload (accounts plan §4.4): `sha256` is only its resume key; the hash comes with `end`.
            if op["hashAtEnd"] == true {
                m["hashAtEnd"] = json!(true);
            }
            let _ = std::fs::write(&meta, m.to_string());
            Ok(json!({"upload": id, "path": path, "have": have}))
        })();
        r.unwrap_or_else(|c| json!({"error": c}))
    }

    pub fn meta(&self, id: &str) -> Option<Value> {
        let ok = id.len() > 65 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-');
        let (_, meta) = self.files(id);
        ok.then(|| std::fs::read(meta).ok().and_then(|b| serde_json::from_slice(&b).ok())).flatten()
    }

    /// `upload-part` + n raw bytes (always read, so the session stays in step).
    pub async fn part<R: AsyncRead + Unpin>(&self, op: &Value, r: &mut R) -> anyhow::Result<Value> {
        let n = op["size"].as_u64().filter(|n| *n <= MAX_PART).ok_or_else(|| anyhow::anyhow!("bad upload-part"))?;
        let id = op["upload"].as_str().unwrap_or("");
        let known = self.active.lock().unwrap().contains_key(id);
        let meta = self.meta(id).filter(|_| known);
        let (part, _) = self.files(id);
        let have = std::fs::symlink_metadata(&part).ok().filter(|m| m.is_file()).map_or(0, |m| m.len());
        let fits = meta.as_ref().is_some_and(|m| have + n <= m["size"].as_u64().unwrap_or(0));
        if meta.is_none() || op["offset"].as_u64() != Some(have) || !fits {
            tokio::io::copy(&mut r.take(n), &mut tokio::io::sink()).await?;
            return Ok(if meta.is_none() { json!({"error": "notFound"}) } else { json!({"error": "offset", "have": have}) });
        }
        let f = std::fs::OpenOptions::new().append(true).custom_flags(libc::O_NOFOLLOW).open(&part)?;
        let mut f = tokio::fs::File::from_std(f);
        let got = tokio::io::copy(&mut r.take(n), &mut f).await?;
        f.flush().await?;
        anyhow::ensure!(got == n, "upload cut short");
        Ok(json!({"ok": true, "have": have + n}))
    }

    pub async fn end(&self, op: &Value) -> Value {
        let id = op["upload"].as_str().unwrap_or("").to_owned();
        let Some(meta) = self.meta(&id).filter(|_| self.active.lock().unwrap().contains_key(&id)) else { return json!({"error": "notFound"}) };
        let (part, mfile) = self.files(&id);
        let size = meta["size"].as_u64().unwrap_or(0);
        let have = std::fs::symlink_metadata(&part).map_or(0, |m| m.len());
        if have != size {
            return json!({"error": "offset", "have": have});
        }
        let p2 = part.clone();
        let sha = tokio::task::spawn_blocking(move || crate::host::sha256_file(&p2)).await.ok().and_then(Result::ok);
        let want = if meta["hashAtEnd"] == true { op["sha256"].as_str().map(str::to_ascii_lowercase) } else { meta["sha256"].as_str().map(str::to_owned) };
        if sha.is_none() || sha != want {
            let _ = (std::fs::remove_file(&part), std::fs::remove_file(&mfile));
            self.release(&id);
            return json!({"error": "checksum"});
        }
        let r = (|| {
            let path = meta["path"].as_str().ok_or("internal")?;
            let parts = self.parts(path)?;
            let parent = parts[..parts.len() - 1].iter().fold(self.dir.clone(), |p, c| p.join(c));
            let real = self.inside(&parent)?;
            let name = parts[parts.len() - 1];
            let (stem, ext) = match name.rsplit_once('.') { Some((s, e)) if !s.is_empty() => (s, format!(".{e}")), _ => (name, String::new()) };
            for n in 1..1000 {
                let candidate = if n == 1 { name.to_owned() } else { format!("{stem} {n}{ext}") };
                match std::fs::hard_link(&part, real.join(&candidate)) {
                    Ok(()) => {
                        let _ = (std::fs::remove_file(&part), std::fs::remove_file(&mfile));
                        let rel: Vec<&str> = parts[..parts.len() - 1].to_vec();
                        let shown = if rel.is_empty() { format!("{}/{candidate}", self.id) } else { format!("{}/{}/{candidate}", self.id, rel.join("/")) };
                        return Ok(json!({"ok": true, "path": shown, "size": size}));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(_) => return Err("internal"),
                }
            }
            Err("exists")
        })();
        self.release(&id);
        r.unwrap_or_else(|c| json!({"error": c}))
    }

    pub fn cancel(&self, op: &Value) -> Value {
        let id = op["upload"].as_str().unwrap_or("");
        if self.meta(id).is_none() {
            return json!({"error": "notFound"});
        }
        let (part, meta) = self.files(id);
        let _ = (std::fs::remove_file(part), std::fs::remove_file(meta));
        self.release(id);
        json!({"ok": true})
    }

    /// The session that began it ended (the partial stays for a resume).
    pub fn release(&self, id: &str) {
        let mut a = self.active.lock().unwrap();
        a.remove(id);
        self.busy.root_uploads.store(a.len(), Ordering::Relaxed);
    }

    /// Partials untouched for 7 days go.
    pub fn sweep(&self) {
        let cutoff = SystemTime::now() - KEEP_PARTIAL;
        for e in std::fs::read_dir(self.partial()).into_iter().flatten().flatten() {
            if e.metadata().ok().and_then(|m| m.modified().ok()).is_some_and(|t| t < cutoff) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::Digest;

    fn root() -> UploadRoot {
        let d = std::env::temp_dir().join(format!("pluck-up-{}", crate::host::uuid()));
        std::fs::create_dir_all(d.join("Clients")).unwrap();
        UploadRoot::parse(&format!("renders={}", d.display()), &["nas1".into()], Arc::default()).unwrap()
    }

    fn hex(b: &[u8]) -> String {
        sha2::Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
    }

    async fn put(r: &UploadRoot, id: &str, offset: u64, bytes: &[u8]) -> Value {
        let mut src = bytes;
        r.part(&json!({"upload": id, "offset": offset, "size": bytes.len()}), &mut src).await.unwrap()
    }

    #[tokio::test]
    async fn resume_checksum_names_and_space() {
        let r = root();
        assert!(UploadRoot::parse(&format!("nas1={}", r.dir.display()), &["nas1".into()], Arc::default()).is_none(), "ids differ from media roots");
        let data = b"0123456789".repeat(100);
        let b = r.begin(&json!({"path": "renders/Clients/Hero 30s v4.mov", "size": data.len(), "sha256": hex(&data)}), "D1");
        let id = b["upload"].as_str().unwrap().to_owned();
        assert_eq!(b["have"], 0);
        assert_eq!(put(&r, &id, 0, &data[..400]).await["have"], 400);
        assert_eq!(put(&r, &id, 100, &data[400..500]).await, json!({"error": "offset", "have": 400}), "a wrong offset is refused");
        r.release(&id); // the connection dropped
        let b = r.begin(&json!({"path": "renders/Clients/Hero 30s v4.mov", "size": data.len(), "sha256": hex(&data)}), "D1");
        assert_eq!((b["upload"].as_str(), b["have"].as_u64()), (Some(id.as_str()), Some(400)), "resumes from have");
        put(&r, &id, 400, &data[400..]).await;
        assert_eq!(r.end(&json!({"upload": id})).await, json!({"ok": true, "path": "renders/Clients/Hero 30s v4.mov", "size": 1000}));
        assert_eq!(std::fs::read(r.dir.join("Clients/Hero 30s v4.mov")).unwrap(), data);
        // The same name again: " 2", never overwritten.
        let b = r.begin(&json!({"path": "renders/Clients/Hero 30s v4.mov", "size": data.len(), "sha256": hex(&data)}), "D1");
        put(&r, b["upload"].as_str().unwrap(), 0, &data).await;
        assert_eq!(r.end(&json!({"upload": b["upload"]})).await["path"], "renders/Clients/Hero 30s v4 2.mov");
        // A wrong hash.
        let b = r.begin(&json!({"path": "renders/x.mov", "size": 3, "sha256": hex(b"abd")}), "D1");
        put(&r, b["upload"].as_str().unwrap(), 0, b"abc").await;
        assert_eq!(r.end(&json!({"upload": b["upload"]})).await, json!({"error": "checksum"}));
        assert!(!r.dir.join("x.mov").exists());
        // Space: 10 GB must stay free after the upload.
        let mut big = root();
        big.reserve = u64::MAX / 2;
        assert_eq!(big.begin(&json!({"path": "renders/y.mov", "size": 5, "sha256": hex(b"abcde")}), "D1"), json!({"error": "space"}));
        assert!(big.dir.join(PARTIAL).read_dir().map_or(true, |mut d| d.next().is_none()), "a refused upload makes no partial file (a full disk can't)");
        assert!(r.dir.join(PARTIAL).read_dir().unwrap().next().is_none(), "no partials left");
    }

    /// An upload is a source for publish by reference (the Mac's "Share for Review" into Client/2026): the finished
    /// file resolves under the uploads root's own id; a partial, an escape and the media roots' ids don't.
    #[tokio::test]
    async fn uploaded_files_are_reference_sources() {
        let r = root();
        let data = b"spot".repeat(50);
        assert_eq!(r.mkdir("renders/Client/2026"), json!({"ok": true}));
        let b = r.begin(&json!({"path": "renders/Client/2026/Spot 30s.mov", "size": data.len(), "sha256": hex(&data)}), "D1");
        let id = b["upload"].as_str().unwrap().to_owned();
        put(&r, &id, 0, &data[..10]).await;
        let mut roots = crate::roots::Roots::parse(&[]);
        roots.add_uploads(&r);
        assert!(roots.resolve(&format!("renders/{PARTIAL}/{id}.part"), false).is_none(), "an upload on its way isn't a source");
        put(&r, &id, 10, &data[10..]).await;
        assert_eq!(r.end(&json!({"upload": id})).await["path"], "renders/Client/2026/Spot 30s.mov");
        assert_eq!(roots.resolve("renders/Client/2026/Spot 30s.mov", false), Some(r.dir.join("Client/2026/Spot 30s.mov")));
        assert!(roots.resolve("renders/Client/2026", true).is_some());
        assert!(roots.resolve("renders/../x.mov", false).is_none() && roots.resolve("nas1/Client/2026/Spot 30s.mov", false).is_none());
        let listed = roots.browse("renders/Client/2026").unwrap();
        assert_eq!(listed["entries"][0]["path"], "renders/Client/2026/Spot 30s.mov");
        assert!(!roots.browse("renders").unwrap().to_string().contains(PARTIAL), "the partial folder isn't listed");
    }

    #[test]
    fn traversal_and_limits() {
        let r = root();
        let outside = r.dir.parent().unwrap().join(format!("outside-{}", crate::host::uuid()));
        std::fs::create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, r.dir.join("link")).unwrap();
        let sha = "a".repeat(64);
        for bad in ["renders/../x.mov", "/etc/x.mov", "renders//x.mov", "renders/.hidden.mov", "renders/link/x.mov", "nas1/x.mov",
                    "renders/.pluck-partial/x.mov", "renders/a:b.mov", "renders/1/2/3/4/5/6/7/8/x.mov"] {
            assert!(r.begin(&json!({"path": bad, "size": 1, "sha256": sha}), "D").get("error").is_some(), "{bad}");
        }
        assert!(r.mkdir("renders/link/Sub").get("error").is_some(), "no folders through a symlink");
        assert_eq!(r.mkdir("renders/Clients/Spring/Cuts"), json!({"ok": true}));
        assert!(r.dir.join("Clients/Spring/Cuts").is_dir());
        assert!(!outside.join("Sub").exists());
        let begin = |n: u64, d: &str| r.begin(&json!({"path": "renders/a.mov", "size": n, "sha256": sha}), d);
        assert!(begin(1, "D").get("upload").is_some() && begin(2, "D").get("upload").is_some());
        assert_eq!(begin(3, "D"), json!({"error": "limit"}), "2 per device");
        assert!(begin(4, "E").get("upload").is_some() && begin(5, "F").get("upload").is_some());
        assert_eq!(begin(6, "G"), json!({"error": "limit"}), "4 in all");
        assert_eq!(begin(MAX_FILE + 1, "H"), json!({"error": "tooLarge"}));
    }

    #[test]
    fn move_stays_inside_the_root_and_never_overwrites() {
        let r = root();
        let outside = r.dir.parent().unwrap().join(format!("outside-{}", crate::host::uuid()));
        std::fs::create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, r.dir.join("link")).unwrap();
        std::fs::create_dir_all(r.dir.join("Delivered while offline/2026-11-16")).unwrap();
        std::fs::create_dir_all(r.dir.join("Client/2026")).unwrap();
        std::fs::write(r.dir.join("Delivered while offline/2026-11-16/Spot.mov"), b"a").unwrap();
        std::fs::write(r.dir.join("Client/2026/Spot.mov"), b"b").unwrap();
        assert_eq!(r.move_file("renders/Delivered while offline/2026-11-16/Spot.mov", "renders/Client/2026"),
                   json!({"ok": true, "path": "renders/Client/2026/Spot 2.mov"}), "a name taken gets \" 2\"");
        assert_eq!(std::fs::read(r.dir.join("Client/2026/Spot.mov")).unwrap(), b"b");
        assert_eq!(std::fs::read(r.dir.join("Client/2026/Spot 2.mov")).unwrap(), b"a");
        assert!(!r.dir.join("Delivered while offline/2026-11-16/Spot.mov").exists());
        assert_eq!(r.move_file("renders/Client/2026/Spot.mov", "renders"), json!({"ok": true, "path": "renders/Spot.mov"}));
        for (from, to) in [("renders/Spot.mov", "renders/link"), ("renders/Spot.mov", "renders/../x"), ("renders/Spot.mov", "nas1/x"),
                           ("renders/Spot.mov", "renders/.pluck-partial"), ("renders/../x.mov", "renders/Client"), ("renders/Client", "renders/Client/2026"),
                           ("renders/link/x.mov", "renders"), ("renders/nothing.mov", "renders/Client")] {
            assert!(r.move_file(from, to).get("error").is_some(), "{from} → {to}");
        }
        assert!(r.dir.join("Spot.mov").exists() && std::fs::read_dir(&outside).unwrap().next().is_none());
    }

    #[test]
    fn same_bytes_to_another_path_or_device_is_another_upload() {
        let r = root();
        let sha = "b".repeat(64);
        let id = |p: &str, d: &str| r.begin(&json!({"path": p, "size": 7, "sha256": sha}), d)["upload"].as_str().unwrap().to_owned();
        let a = id("renders/a.mov", "D");
        assert_eq!(id("renders/a.mov", "D"), a, "the same upload resumes");
        assert_ne!(id("renders/Clients/a.mov", "D"), a);
        assert_ne!(id("renders/a.mov", "E"), a);
    }
}
