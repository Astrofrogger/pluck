// Host mode: the read-only media roots (`--media <id>=<path>`, repeatable). A media path is
// "<rootID>/<relative path>"; the id is the owner's stable name for the root, so bundles and links
// survive restarts and re-mounts. Every path is resolved with symlinks followed and must stay
// inside its root.
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use tokio::process::Command;

use crate::{copies, host::safe_rel, keys};

pub struct Roots(pub Vec<(String, PathBuf)>);

pub const VIDEO: &[&str] = &["mov", "mp4", "m4v", "mxf", "mkv", "avi", "mts", "m2ts", "mpg", "mpeg", "webm", "dv", "3gp"];
pub const AUDIO: &[&str] = &["wav", "mp3", "aac", "m4a", "aif", "aiff", "flac", "ogg", "opus", "caf"];
pub const IMAGE: &[&str] = &["jpg", "jpeg", "png", "tif", "tiff", "heic", "webp", "bmp"];
pub const DOCUMENT: &[&str] = &["pdf"];
/// Clients' uploads waiting in the data folder (<data>/uploads/<link>/<id>.<ext>) as a source of their own: ".uploads/<link>/<file>".
/// A data host's Pluck adds them by reference (they stay on the NAS, its copies are made here). Never listed or browsed,
/// and no id can clash (ids have no dots).
pub const QUARANTINE: &str = ".uploads";

pub fn kind_of(p: &str) -> Option<&'static str> {
    let ext = Path::new(p).extension()?.to_str()?.to_ascii_lowercase();
    let e = ext.as_str();
    [("video", VIDEO), ("audio", AUDIO), ("image", IMAGE), ("document", DOCUMENT)].into_iter().find(|(_, l)| l.contains(&e)).map(|(k, _)| k)
}

impl Roots {
    /// From `id=path` specs. Ids: letters, digits, '-' and '_'.
    pub fn parse(specs: &[String]) -> Roots {
        Roots(specs.iter().filter_map(|s| {
            let (id, p) = s.split_once('=')?;
            let ok = !id.is_empty() && id.len() <= 32 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
            match std::fs::canonicalize(p) {
                Ok(c) if ok => Some((id.to_owned(), c)),
                Ok(_) => { crate::log(format!("media root {s}: bad id")); None }
                Err(e) => { crate::log(format!("media root {s}: {e}")); None }
            }
        }).collect())
    }

    /// "<root>/<rel>" → the real path, if it stays inside that root. `dir` allows folders.
    pub fn resolve(&self, media: &str, dir: bool) -> Option<PathBuf> {
        let (id, rel) = media.split_once('/').unwrap_or((media, ""));
        if id == QUARANTINE && (dir || rel.split('/').count() != 2 || rel.split('/').any(|c| c.starts_with('.'))) {
            return None; // one finished file of one link: never the partial folder, never a folder
        }
        let (_, root) = self.0.iter().find(|(i, _)| i == id)?;
        let p = if rel.is_empty() { root.clone() } else { std::fs::canonicalize(root.join(safe_rel(rel)?)).ok()? };
        // (Never an upload still on its way: the uploads root's partial folder.)
        (p.starts_with(root) && !p.starts_with(root.join(crate::upload_root::PARTIAL)) && if dir { p.is_dir() } else { p.is_file() }).then_some(p)
    }

    /// The uploads root as a source root of its own (its id): browse, probe, thumb and publish by reference work on it.
    pub fn add_uploads(&mut self, u: &crate::upload_root::UploadRoot) {
        self.0.push((u.id.clone(), u.dir.clone()));
    }

    /// The data folder's client uploads as the source root QUARANTINE (a main only).
    pub fn add_quarantine(&mut self, data: &Path) {
        let dir = data.join("uploads");
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(d) = std::fs::canonicalize(dir) {
            self.0.push((QUARANTINE.into(), d));
        }
    }

    /// Folders and media files in a folder ("" lists the roots). Hidden files are skipped.
    pub fn browse(&self, media: &str) -> Result<Value> {
        if media.is_empty() {
            return Ok(json!({"entries": self.0.iter().filter(|(id, _)| id != QUARANTINE).map(|(id, _)| json!({"name": id, "path": id, "dir": true})).collect::<Vec<_>>()}));
        }
        let dir = self.resolve(media.trim_end_matches('/'), true).context("not a folder on this host")?;
        let base = media.trim_end_matches('/');
        let mut out = vec![];
        for e in std::fs::read_dir(&dir)?.flatten().take(5000) {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            let path = format!("{base}/{name}");
            let Ok(m) = std::fs::metadata(e.path()) else { continue }; // follows links; resolve() checks them on use
            let mtime = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| crate::host::iso(d.as_secs() as i64));
            if m.is_dir() {
                if self.resolve(&path, true).is_none() {
                    continue; // a link that leads out of the root
                }
                out.push(json!({"name": name, "path": path, "dir": true, "modified": mtime}));
            } else if let Some(k) = kind_of(&name) {
                out.push(json!({"name": name, "path": path, "dir": false, "kind": k, "size": m.len(), "modified": mtime}));
            }
        }
        out.sort_by(|a, b| (b["dir"].as_bool(), a["name"].as_str()).cmp(&(a["dir"].as_bool(), b["name"].as_str())));
        Ok(json!({"entries": out}))
    }

    /// Duration, size, frame rate and codec of a media file (ffprobe).
    pub async fn probe(&self, media: &str) -> Result<Value> {
        let p = self.resolve(media, false).context("not a file on this host")?;
        let out = Command::new(tool("ffprobe")).args(["-v", "error", "-print_format", "json", "-show_streams", "-show_format"])
            .arg(&p).kill_on_drop(true).output().await.context("can't run ffprobe")?;
        ensure!(out.status.success(), "ffprobe can't read the file");
        let raw: Value = serde_json::from_slice(&out.stdout)?;
        let mut v = copies::probe_from(&raw)?;
        v["codec"] = raw["streams"].as_array().and_then(|s| s.iter().find(|s| s["codec_type"] == "video" || s["codec_type"] == "audio"))
            .map_or(Value::Null, |s| s["codec_name"].clone());
        Ok(v)
    }

    /// A 320 px JPEG thumbnail, base64url.
    pub async fn thumb(&self, media: &str) -> Result<Value> {
        let p = self.resolve(media, false).context("not a file on this host")?;
        let out = Command::new(tool("ffmpeg")).args(["-hide_banner", "-loglevel", "error", "-nostdin", "-ss", "1", "-i"]).arg(&p)
            .args(["-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", "-f", "image2", "-c:v", "mjpeg", "pipe:1"])
            .kill_on_drop(true).output().await.context("can't run ffmpeg")?;
        ensure!(out.status.success() && !out.stdout.is_empty(), "no thumbnail");
        Ok(json!({"jpeg": keys::b64(&out.stdout)}))
    }

    /// The browse ops shared by the sync endpoint and the admin page.
    pub async fn op(&self, op: &Value) -> Option<Value> {
        let path = op["path"].as_str().unwrap_or("");
        let r = match op["op"].as_str()? {
            "roots" => Ok(json!({"roots": self.0.iter().map(|(id, _)| id).filter(|id| *id != QUARANTINE).collect::<Vec<_>>()})),
            "browse" => self.browse(path),
            "probe" => self.probe(path).await,
            "thumb" => self.thumb(path).await,
            _ => return None,
        };
        Some(r.unwrap_or_else(|e| json!({"error": format!("{e:#}")})))
    }
}

pub fn tool(name: &str) -> String {
    std::env::var("PLUCK_FFMPEG_DIR").map_or_else(|_| name.to_owned(), |d| format!("{d}/{name}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Clients' uploads resolve as ".uploads/<link>/<file>" sources (one finished file), never listed, browsed or partial.
    #[test]
    fn the_quarantine_is_a_hidden_source() {
        let d = std::env::temp_dir().join(format!("pluck-roots-q-{}", crate::host::uuid()));
        std::fs::create_dir_all(d.join("uploads/L1")).unwrap();
        std::fs::create_dir_all(d.join("uploads/.partial")).unwrap();
        std::fs::write(d.join("uploads/L1/U1.mov"), b"x").unwrap();
        std::fs::write(d.join("uploads/.partial/p.part"), b"x").unwrap();
        std::fs::write(d.join("host-key"), b"k").unwrap();
        let mut r = Roots(vec![]);
        r.add_quarantine(&d);
        assert!(r.resolve(".uploads/L1/U1.mov", false).is_some());
        for bad in [".uploads/.partial/p.part", ".uploads/L1", ".uploads/../host-key", ".uploads/L1/../../host-key", ".uploads/U1.mov"] {
            assert!(r.resolve(bad, false).is_none() && r.resolve(bad, true).is_none(), "{bad}");
        }
        assert!(r.browse("").unwrap()["entries"].as_array().unwrap().is_empty() && r.browse(".uploads/L1").is_err());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn stays_inside() {
        let base = std::env::temp_dir().join(format!("pluck-roots-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("media/Clients")).unwrap();
        std::fs::create_dir_all(base.join("outside")).unwrap();
        std::fs::write(base.join("media/Clients/hero.mov"), b"x").unwrap();
        std::fs::write(base.join("outside/secret.mov"), b"x").unwrap();
        std::os::unix::fs::symlink(base.join("outside"), base.join("media/escape")).unwrap();
        let r = Roots::parse(&[format!("nas1={}", base.join("media").display())]);
        assert!(r.resolve("nas1/Clients/hero.mov", false).is_some());
        assert!(r.resolve("nas1/escape/secret.mov", false).is_none(), "symlink out of the root");
        assert!(r.resolve("nas1/../outside/secret.mov", false).is_none());
        assert!(r.resolve("nas2/Clients/hero.mov", false).is_none(), "unknown root");
        assert!(r.resolve("nas1/Clients", false).is_none(), "a folder isn't a file");
        let b = r.browse("nas1/Clients").unwrap();
        assert_eq!(b["entries"][0]["path"], "nas1/Clients/hero.mov");
        assert_eq!(b["entries"][0]["kind"], "video");
        assert!(r.browse("nas1/escape").is_err());
        assert!(!r.browse("nas1").unwrap().to_string().contains("escape"), "escaping links aren't listed");
        assert_eq!(kind_of("A.WAV"), Some("audio"));
        let _ = std::fs::remove_dir_all(base);
    }
}
