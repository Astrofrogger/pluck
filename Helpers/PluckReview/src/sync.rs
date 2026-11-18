// The host's sync endpoint: Pluck (and a backup host) talk to it over TLS 1.3 with the host's own
// self-signed certificate, which the other side pins by SHA-256. The first line says who it is
// (spec §12.6, §13.2):
//   {"key":"<host key>"}                                   legacy: role mac, LAN or iroh
//   {"device":"<id>","key":"<device key>"}                 a paired device (over iroh: its node)
//   {"pair":"<code>","name","node","role"}                 pairing with an invitation's code
//   → {"ok":true,"version","protocol":3,"links":3,"host":{"id","name","role"},"device","key"?}
// (a hello claiming "protocol" < 2 gets {"error":"incompatible","protocol":3}). Then JSON lines,
// one answer per request:
//   list | put + N bytes | delete | get (+ offset/length: a range) + N bytes | roots/browse/probe/thumb
//   invite {role, access} | devices | device-remove | device-role {id, access} | device-node | rotate-key | update  (role mac)
//   mkdir | move {path,to} | upload-begin | upload-part + n bytes | upload-end | upload-cancel  (role mac, uploads root)
//   outage-node | outage-list | outage-done | local-time {offset}                         (role mac, §13.25)
//   pull | append | publish | changes | manifest | status | reload | prepare-update …   → host.rs `sync`
// A backup may only use manifest, changes, pull, append, get (copies, branding), status and the outage push
// (outage-macs, outage-begin, outage-part + n bytes, outage-end). On a backup, one of the main's Macs (role
// "outage", over iroh on the node it registered there) may only upload (upload-begin/-part/-end/-cancel).
// Roles (4.0.5, hello `"roles": 1`): a paired Mac is an admin or an editor (devices.json `access`; one paired before
// has none and is an admin). An editor Mac does the Deliver work; ADMIN_OPS answer it {"error":"admin"}. The legacy host
// key is an admin. Every op handed to host.rs carries `_mac` {id, name, admin}, set here (never the client's).
use std::{
    path::{Path, PathBuf},
    sync::{Arc, RwLock},
    time::Duration,
};

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::TcpListener,
    sync::{mpsc, oneshot},
};
use tokio_rustls::{TlsAcceptor, rustls};

use crate::{devices::Devices, host, keys, log, report, roots::Roots, store::PROTOCOL, update, upload_root::UploadRoot};

const MAX_LINE: usize = 1 << 20;
pub const MAX_PUT: u64 = 256 << 30;
const BACKUP_OPS: &[&str] = &["_accounts", "manifest", "changes", "pull", "append", "get", "status", "outage-macs", "outage-begin", "outage-part", "outage-end"];
const OUTAGE_OPS: &[&str] = &["upload-begin", "upload-part", "upload-end", "upload-cancel"];
const OUTAGE_PUSH: &[&str] = &["outage-macs", "outage-begin", "outage-part", "outage-end"];
/// What only an admin Mac may do: pair and remove devices and change their roles, the server's key, updates and
/// settings, and the team (roles, approvals, removing people, its settings, key, export and restore).
pub const ADMIN_OPS: &[&str] = &["invite", "device-remove", "device-role", "rotate-key", "update", "prepare-update", "cancel-update", "prefer-fastest",
    "team-set", "person-update", "person-reset", "person-remove", "passkey-remove", "invite-cancel", "invite-approve", "request-accept", "request-decline",
    "team-export", "team-restore", "team-reset"];

fn read_or_make(path: &Path, make: impl FnOnce() -> Vec<u8>) -> Result<(Vec<u8>, bool)> {
    if let Ok(b) = std::fs::read(path) {
        return Ok((b, false));
    }
    let b = make();
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
        .with_context(|| format!("can't write {}", path.display()))?;
    std::io::Write::write_all(&mut f, &b)?;
    Ok((b, true))
}

/// A file read without following a symlink, refused unless it's a regular file of at most `max`
/// bytes: the root-run updater's `--ctl` reads files the service user can replace (#21).
pub fn read_plain(path: &Path, max: u64) -> Result<Vec<u8>> {
    use std::os::unix::fs::OpenOptionsExt;
    let f = std::fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path)
        .with_context(|| format!("can't open {} (a link?)", path.display()))?;
    let m = f.metadata()?;
    anyhow::ensure!(m.is_file() && m.len() <= max, "{} isn't a plain file of ≤ {max} bytes", path.display());
    let mut b = vec![];
    std::io::Read::read_to_end(&mut std::io::Read::take(f, max + 1), &mut b)?;
    anyhow::ensure!(b.len() as u64 <= max, "{} grew", path.display());
    Ok(b)
}

/// The host key: $PLUCK_HOST_KEY (base64url of 32 bytes) if set, else <data>/host-key, made on first run
/// (a plain 32-byte file; a link or anything else is refused).
pub fn host_key(data: &Path) -> Result<(Vec<u8>, bool)> {
    if let Some(k) = std::env::var("PLUCK_HOST_KEY").ok().filter(|k| !k.trim().is_empty()) {
        let k = keys::unb64(k.trim()).filter(|k| k.len() == 32).context("PLUCK_HOST_KEY must be base64url of 32 bytes")?;
        return Ok((k, false));
    }
    let path = data.join("host-key");
    if std::fs::symlink_metadata(&path).is_ok() {
        let k = read_plain(&path, 32)?;
        anyhow::ensure!(k.len() == 32, "{} isn't 32 bytes", path.display());
        return Ok((k, false));
    }
    read_or_make(&path, || rand::random::<[u8; 32]>().to_vec())
}

/// A certificate's SHA-256 as uppercase hex with colons.
pub fn cert_fp(der: &[u8]) -> String {
    sha2::Digest::finalize(<sha2::Sha256 as sha2::Digest>::new_with_prefix(der)).iter().map(|b| format!("{b:02X}")).collect::<Vec<_>>().join(":")
}

/// The host's TLS (self-signed, made on first run, kept in the data folder) and its SHA-256.
pub fn tls(data: &Path) -> Result<(TlsAcceptor, String)> {
    let (cert_path, key_path) = (data.join("tls-cert.der"), data.join("tls-key.der"));
    if !(cert_path.exists() && key_path.exists()) {
        let c = rcgen::generate_simple_self_signed(vec!["pluck-review-host".into()])?;
        let _ = (std::fs::remove_file(&cert_path), std::fs::remove_file(&key_path));
        read_or_make(&key_path, || c.signing_key.serialize_der())?;
        read_or_make(&cert_path, || c.cert.der().to_vec())?;
    }
    let (cert_der, key_der) = (std::fs::read(&cert_path)?, std::fs::read(&key_path)?);
    let fp = cert_fp(&cert_der);
    let config = rustls::ServerConfig::builder_with_protocol_versions(&[&rustls::version::TLS13])
        .with_no_client_auth()
        .with_single_cert(vec![cert_der.into()], rustls::pki_types::PrivateKeyDer::try_from(key_der).map_err(anyhow::Error::msg)?)?;
    Ok((TlsAcceptor::from(Arc::new(config)), fp))
}

/// Everything a session needs.
pub struct Ctx {
    pub data: PathBuf,
    pub key: Arc<RwLock<Vec<u8>>>, // shared with the admin page, so rotate-key reaches its first-visit check (#18)
    pub roots: Arc<Roots>,
    pub to_host: mpsc::Sender<host::Sync>,
    pub devices: Arc<Devices>,
    pub uploads: Option<Arc<UploadRoot>>,
    pub outage: Option<Arc<crate::outage::Outage>>,
    pub ident: host::Ident,
    pub fp: String,
    pub acceptor: TlsAcceptor,
}

impl Ctx {
    fn bundle(&self) -> PathBuf {
        self.data.join("bundle")
    }

    pub fn pairing_line(&self) -> String {
        format!("pluck-host:{}@{}", keys::b64(&self.key.read().unwrap()), self.fp)
    }
}

/// Serves the sync endpoint on `listen`. The pairing line (key + certificate fingerprint) is
/// printed when the key is new, and is also in <data>/pairing.txt for the owner to read later.
pub async fn serve(ctx: Arc<Ctx>, listen: String, new_key: bool) -> Result<()> {
    let listener = TcpListener::bind(&listen).await.with_context(|| format!("can't listen on {listen}"))?;
    let pairing = ctx.pairing_line();
    let _ = read_or_make(&ctx.data.join("pairing.txt"), || format!("{pairing}\n").into_bytes());
    let mut info = json!({"listen": listener.local_addr()?.to_string(), "fingerprint": ctx.fp});
    if new_key {
        info["pairing"] = json!(pairing);
    }
    report(json!({ "host": info }));
    accept_loop(ctx, listener, None).await
}

/// Accepts TLS sessions. `iroh`: the loopback listener pluck-iroh forwards streams to; each
/// connection must match a stream report (its local port) from the last 2 s, else it's closed.
pub async fn accept_loop(ctx: Arc<Ctx>, listener: TcpListener, iroh: Option<crate::iroh::Streams>) -> Result<()> {
    loop {
        let (tcp, from) = listener.accept().await?;
        let (ctx, iroh) = (ctx.clone(), iroh.clone());
        tokio::spawn(async move {
            let r = async {
                let node = match &iroh {
                    Some(s) => {
                        anyhow::ensure!(from.ip().is_loopback(), "an iroh-port connection not from loopback");
                        Some(s.claim(from.port()).await.context("no iroh stream for this connection")?)
                    }
                    None => None,
                };
                let tls = tokio::time::timeout(Duration::from_secs(10), ctx.acceptor.accept(tcp)).await??;
                session(tls, &ctx, node).await
            };
            if let Err(e) = r.await {
                log(format!("sync: {e:#}")); // no address: logs keep no IPs (hardening §3)
            }
        });
    }
}

async fn line<R: AsyncBufReadExt + Unpin>(r: &mut R) -> Result<Option<Value>> {
    let mut buf = vec![];
    let n = match (&mut *r).take(MAX_LINE as u64).read_until(b'\n', &mut buf).await {
        // A client that just drops the connection between requests (no TLS close_notify) has simply left.
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof && buf.is_empty() => 0,
        r => r?,
    };
    if n == 0 {
        return Ok(None);
    }
    anyhow::ensure!(buf.ends_with(b"\n"), "line too long");
    Ok(Some(serde_json::from_slice(&buf)?))
}

/// The first line: who's there. Err after the 1 s delay for anything wrong.
async fn hello(h: &Value, ctx: &Ctx, node: Option<&str>) -> Result<(crate::devices::Who, Value)> {
    let ok = |device: Option<String>, role: &str, key: Option<String>| {
        // links: the highest link level it serves (§13.24). Hosts before it (4.0.3) don't say, and serve level 2 only.
        // outage: it takes its backups' uploads from an outage (§13.25); 4.0.3 doesn't say. accounts: People and passkeys (4.0.4). approvals: editor invites wait for an admin (invite-approve).
        // roles: Macs are admins or editors (device-role); `access` is this Mac's.
        let mut r = json!({"ok": true, "version": update::VERSION, "protocol": PROTOCOL, "links": 3, "outage": 1, "accounts": 1, "approvals": 1, "roles": 1,
            "host": {"id": ctx.ident.id, "name": ctx.ident.name, "role": if ctx.ident.backup { "backup" } else { "main" }}});
        if let Some(d) = &device {
            r["device"] = json!(d);
        }
        if role == "mac" {
            r["access"] = json!(if device.as_deref().is_none_or(|d| ctx.devices.is_admin(d)) { "admin" } else { "editor" });
        }
        if let Some(k) = key {
            r["key"] = json!(k);
        }
        (crate::devices::Who { device, role: role.into() }, r)
    };
    if let Some(code) = h["pair"].as_str() {
        let role = h["role"].as_str().unwrap_or("mac");
        let given = h["node"].as_str().filter(|n| !n.is_empty());
        if let Some((id, key)) = ctx.devices.pair(code, h["name"].as_str().unwrap_or(""), given, role, node) {
            return Ok(ok(Some(id), role, Some(key)));
        }
    } else if let (Some(id), Some(k)) = (h["device"].as_str(), h["key"].as_str()) {
        if let Some(role) = ctx.devices.check(id, k, node) {
            return Ok(ok(Some(id.to_owned()), &role, None));
        }
    } else {
        let given = h["key"].as_str().and_then(keys::unb64).unwrap_or_default();
        if keys::subtle_eq(&given, &ctx.key.read().unwrap()) {
            return Ok(ok(None, "mac", None));
        }
    }
    tokio::time::sleep(Duration::from_secs(1)).await; // slows guessing (a 256-bit key anyway)
    anyhow::bail!("wrong host key, device or code");
}

async fn to_host(ctx: &Ctx, op: Value) -> Result<Value> {
    let (tx, rx) = oneshot::channel();
    ctx.to_host.send(host::Sync { op, reply: tx }).await?;
    Ok(rx.await?)
}

pub async fn session<S: AsyncRead + AsyncWrite + Unpin>(s: S, ctx: &Ctx, node: Option<String>) -> Result<()> {
    let (r, mut w) = tokio::io::split(s);
    let mut r = BufReader::new(r);
    let h = tokio::time::timeout(Duration::from_secs(10), line(&mut r)).await??.unwrap_or_default();
    if h["protocol"].as_u64().is_some_and(|p| p < 2) {
        w.write_all(format!("{}\n", json!({"error": "incompatible", "protocol": PROTOCOL})).as_bytes()).await?;
        w.flush().await?;
        return Ok(());
    }
    let (who, reply) = hello(&h, ctx, node.as_deref()).await?;
    w.write_all(format!("{reply}\n").as_bytes()).await?;
    w.flush().await?;
    // A legacy host-key session ends when the key is rotated (#22): it's checked again on every op.
    let legacy = (who.device.is_none()).then(|| h["key"].as_str().and_then(keys::unb64).unwrap_or_default());
    let mut mine: Vec<String> = vec![]; // uploads-root uploads this session began
    let r2 = ops(&mut r, &mut w, ctx, &who, legacy.as_deref(), &mut mine).await;
    if let Some(u) = &ctx.uploads {
        for id in mine {
            u.release(&id);
        }
    }
    r2
}

/// An open session that sends nothing for this long is closed.
const IDLE: Duration = Duration::from_secs(30 * 60);

async fn ops<R: AsyncBufReadExt + Unpin, W: AsyncWrite + Unpin>(r: &mut R, w: &mut W, ctx: &Ctx, who: &crate::devices::Who, legacy: Option<&[u8]>,
                                                                mine: &mut Vec<String>) -> Result<()> {
    let bundle = ctx.bundle();
    let mac = who.role == "mac";
    while let Some(op) = tokio::time::timeout(IDLE, line(r)).await.context("idle")?? {
        if who.device.as_deref().is_some_and(|d| !ctx.devices.exists(d)) {
            anyhow::bail!("device removed");
        }
        if legacy.is_some_and(|k| !keys::subtle_eq(k, &ctx.key.read().unwrap())) {
            anyhow::bail!("host key rotated");
        }
        let name = op["op"].as_str().unwrap_or("").to_owned();
        let rel = op["path"].as_str().and_then(host::safe_rel);
        // Client uploads live next to the bundle (the quarantine), not in it; the partial folder is never handed out.
        let upload = rel.filter(|p| p.starts_with("uploads") && !p.starts_with("uploads/.partial") && p.components().count() == 3).map(|p| ctx.data.join(p));
        let path = rel.map(|p| bundle.join(p));
        let allowed = match who.role.as_str() {
            "mac" => !OUTAGE_PUSH.contains(&name.as_str()),
            "backup" => BACKUP_OPS.contains(&name.as_str()),
            _ => OUTAGE_OPS.contains(&name.as_str()),
        };
        // An editor Mac: no admin work, apart from removing itself (leaving the server).
        let admin = mac && who.device.as_deref().is_none_or(|d| ctx.devices.is_admin(d));
        let own = name == "device-remove" && who.device.is_some() && op["id"].as_str() == who.device.as_deref();
        if mac && !admin && !own && ADMIN_OPS.contains(&name.as_str()) {
            w.write_all(format!("{}\n", json!({"error": "admin"})).as_bytes()).await?;
            w.flush().await?;
            continue;
        }
        // `_accounts`: a backup's copy of the main's accounts.json (accounts plan §1.4); every other `_` op stays internal.
        if (name.starts_with('_') && !(name == "_accounts" && who.role == "backup")) || !allowed {
            if name == "put" || name == "upload-part" || name == "outage-part" {
                anyhow::bail!("{name} not allowed"); // its bytes can't be skipped safely
            }
            w.write_all(format!("{}\n", json!({"error": "scope"})).as_bytes()).await?;
            w.flush().await?;
            continue;
        }
        let reply = match name.as_str() {
            "list" => json!({"files": list(&bundle)}),
            "put" => {
                let size = op["size"].as_u64().filter(|s| *s <= MAX_PUT);
                let (Some(path), Some(size)) = (path, size) else { anyhow::bail!("bad put") }; // can't skip the bytes safely
                let tmp = path.with_extension("part-upload");
                tokio::fs::create_dir_all(path.parent().unwrap_or(&bundle)).await?;
                let mut f = tokio::fs::File::create(&tmp).await?;
                let n = tokio::io::copy(&mut (&mut *r).take(size), &mut f).await?;
                anyhow::ensure!(n == size, "upload cut short");
                f.sync_all().await?;
                tokio::fs::rename(&tmp, &path).await?;
                json!({"ok": true})
            }
            "get" => {
                // Ranges of copies/branding (and uploads), originals for Macs only (§13.1); a backup gets copies and branding.
                let bundled = rel.filter(|p| p.starts_with("copies") || p.starts_with("branding") || (mac && p.starts_with("originals"))).map(|_| path.clone().unwrap());
                let file = if mac { upload.clone().or(bundled) } else { bundled };
                match file.as_ref().and_then(|p| std::fs::metadata(p).ok().filter(|m| m.is_file()).map(|m| (p, m.len()))) {
                    Some((p, len)) => {
                        let off = op["offset"].as_u64().unwrap_or(0).min(len);
                        let n = op["length"].as_u64().unwrap_or(len - off).min(len - off);
                        w.write_all(format!("{}\n", json!({"ok": true, "size": n})).as_bytes()).await?;
                        let mut f = tokio::fs::File::open(p).await?;
                        tokio::io::AsyncSeekExt::seek(&mut f, std::io::SeekFrom::Start(off)).await?;
                        let sent = tokio::io::copy(&mut f.take(n), w).await?;
                        anyhow::ensure!(sent == n, "file changed while sending");
                        continue;
                    }
                    None => json!({"error": "not found"}),
                }
            }
            "delete" if upload.is_some() => {
                let _ = tokio::fs::remove_file(upload.unwrap()).await;
                json!({"ok": true})
            }
            "delete" => match path {
                Some(p) => {
                    let _ = tokio::fs::remove_file(&p).await;
                    json!({"ok": true})
                }
                None => json!({"error": "bad path"}),
            },
            "roots" => {
                let mut v = ctx.roots.op(&op).await.unwrap_or_default();
                v["writable"] = json!(ctx.uploads.iter().map(|u| u.id.clone()).collect::<Vec<_>>());
                v
            }
            "browse" | "probe" | "thumb" => ctx.roots.op(&op).await.unwrap_or_default(),
            "invite" => ctx.devices.invite(op["role"].as_str().unwrap_or(""), op["access"].as_str()),
            "devices" => ctx.devices.list(),
            // (host.rs: it keeps the last admin, which needs the team too)
            "device-node" => match &who.device {
                Some(d) => ctx.devices.set_node(d, op["node"].as_str().unwrap_or("")),
                None => json!({"error": "invalid"}),
            },
            "rotate-key" => rotate_key(ctx),
            "update" => match op["device"].as_str() {
                Some(d) => ctx.devices.queue_update(d, op["version"].as_str().unwrap_or("")),
                None => update::request(&ctx.data, op["version"].as_str().unwrap_or("")),
            },
            "outage-node" => match &who.device {
                Some(d) => ctx.devices.set_outage_node(d, op["node"].as_str().unwrap_or("")),
                None => json!({"error": "invalid"}),
            },
            "outage-macs" => ctx.devices.outage_macs(),
            "outage-list" | "outage-done" | "local-time" | "outage-begin" | "outage-part" | "outage-end" => {
                let Some(o) = ctx.outage.as_ref().filter(|_| !ctx.ident.backup) else {
                    if name == "outage-part" {
                        anyhow::bail!("not a main"); // can't skip the bytes
                    }
                    w.write_all(format!("{}\n", json!({"error": "scope"})).as_bytes()).await?;
                    w.flush().await?;
                    continue;
                };
                match name.as_str() {
                    "outage-list" => o.list(),
                    "outage-done" => o.done(op["id"].as_str().unwrap_or(""), op["path"].as_str()),
                    "local-time" => o.set_offset(op["offset"].as_i64().unwrap_or(i64::MAX)),
                    _ => o.receive(&name, &op, r, ctx.uploads.as_deref(), &ctx.to_host).await?,
                }
            }
            "mkdir" | "move" | "upload-begin" | "upload-part" | "upload-end" | "upload-cancel" => {
                // A backup takes uploads (not mkdir/move) only while its main can take them on (§13.25).
                let on_backup = name.starts_with("upload-") && ctx.outage.as_ref().is_some_and(|o| o.accepting());
                let Some(u) = ctx.uploads.as_ref().filter(|_| !ctx.ident.backup || on_backup) else {
                    if name == "upload-part" {
                        anyhow::bail!("no uploads root"); // can't skip the bytes without a valid size
                    }
                    w.write_all(format!("{}\n", json!({"error": "scope"})).as_bytes()).await?;
                    w.flush().await?;
                    continue;
                };
                let device = who.device.clone().unwrap_or_else(|| "host-key".into());
                match name.as_str() {
                    "mkdir" => u.mkdir(op["path"].as_str().unwrap_or("")),
                    "move" => u.move_file(op["path"].as_str().unwrap_or(""), op["to"].as_str().unwrap_or("")),
                    "upload-begin" => {
                        let v = u.begin(&op, &device);
                        if let Some(id) = v["upload"].as_str() {
                            mine.push(id.to_owned());
                        }
                        v
                    }
                    "upload-part" => u.part(&op, r).await?,
                    "upload-end" if ctx.ident.backup => {
                        let meta = u.meta(op["upload"].as_str().unwrap_or("")).unwrap_or_default();
                        // Recorded BEFORE end() links the file into place: a restart in between leaves an item whose file
                        // isn't there (push drops it), never a placed file no item pushes to the main (L3).
                        let item = |rel: &str| json!({"id": "", "kind": "editor", "file": format!("{}/{rel}", crate::outage::EDITOR_DIR),
                            "name": rel.rsplit('/').next().unwrap_or(rel), "size": meta["size"], "sha256": meta["sha256"], "by": ctx.devices.name(&device),
                            "device": device, "folder": meta["folder"], "at": host::now_iso()});
                        let planned = ctx.outage.as_ref().zip(meta["path"].as_str()).map(|(o, rel)| {
                            let id = host::uuid();
                            let mut x = item(rel);
                            x["id"] = json!(id);
                            x["placing"] = json!(host::now_secs()); // push leaves it alone while end() is still at it
                            o.add(x);
                            (o, id)
                        });
                        let mut v = u.end(&op).await;
                        if let Some((o, id)) = planned {
                            match v["path"].as_str() {
                                Some(path) => {
                                    // (another name when the planned one was taken: "Spot 2.mov")
                                    let rel = path.strip_prefix(&format!("{}/", u.id)).unwrap_or("").to_owned();
                                    let x = item(&rel);
                                    o.update(&id, |i| {
                                        i["file"] = x["file"].clone();
                                        i["name"] = x["name"].clone();
                                        i["size"] = v["size"].clone();
                                        if let Some(i) = i.as_object_mut() { i.remove("placing"); }
                                    });
                                    v["outage"] = json!(id);
                                }
                                None => o.remove(&id),
                            }
                        }
                        v
                    }
                    "upload-end" => u.end(&op).await,
                    _ => u.cancel(&op),
                }
            }
            "status" => {
                let mut s = to_host(ctx, op.clone()).await?;
                if mac {
                    s["backups"] = ctx.devices.backups();
                } else if let Some(d) = &who.device {
                    if let Some(v) = ctx.devices.backup_status(d, &op["replica"]) {
                        s["update"] = json!(v); // an "Update now" for this backup, handed on
                    }
                }
                s
            }
            _ => {
                let mut op = op;
                let id = who.device.clone();
                op["_mac"] = if mac { json!({"id": id, "name": id.as_deref().map(|d| ctx.devices.name(d)), "admin": admin}) } else { json!({"admin": false}) };
                to_host(ctx, op).await?
            }
        };
        w.write_all(format!("{reply}\n").as_bytes()).await?;
        w.flush().await?; // TLS: without a flush the end of a big answer can sit in the buffer (H3)
    }
    Ok(())
}

/// `rotate-key`: a new legacy host key; the old one stops working at once.
fn rotate_key(ctx: &Ctx) -> Value {
    if std::env::var("PLUCK_HOST_KEY").is_ok_and(|k| !k.trim().is_empty()) {
        return json!({"error": "the host key is set by PLUCK_HOST_KEY; change it there"});
    }
    let new: [u8; 32] = rand::random();
    let path = ctx.data.join("host-key");
    let tmp = path.with_extension("new");
    use std::os::unix::fs::OpenOptionsExt;
    let _ = std::fs::remove_file(&tmp);
    let r = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)
        .and_then(|mut f| std::io::Write::write_all(&mut f, &new)).and_then(|_| std::fs::rename(&tmp, &path));
    if let Err(e) = r {
        return json!({"error": format!("can't write the host key: {e}")});
    }
    *ctx.key.write().unwrap() = new.to_vec();
    let _ = std::fs::write(ctx.data.join("pairing.txt"), format!("{}\n", ctx.pairing_line()));
    json!({"ok": true, "key": keys::b64(&new)})
}

fn list(dir: &Path) -> Vec<Value> {
    let mut out = vec![];
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let Ok(t) = e.file_type() else { continue };
            if t.is_dir() {
                stack.push(e.path());
            } else if t.is_file() {
                if let (Ok(rel), Ok(m)) = (e.path().strip_prefix(dir).map(Path::to_path_buf), e.metadata()) {
                    out.push(json!({"path": rel.to_string_lossy(), "size": m.len()}));
                }
            }
        }
    }
    out
}

// ---- the client side: a backup talking to its main, and `--ctl` ----

/// Accepts exactly the certificate whose SHA-256 is pinned.
#[derive(Debug)]
struct Pin(String, Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for Pin {
    fn verify_server_cert(&self, cert: &rustls::pki_types::CertificateDer<'_>, _: &[rustls::pki_types::CertificateDer<'_>],
                          _: &rustls::pki_types::ServerName<'_>, _: &[u8], _: rustls::pki_types::UnixTime)
                          -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        if cert_fp(cert).eq_ignore_ascii_case(self.0.trim()) {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("certificate fingerprint doesn't match the pinned one".into()))
        }
    }
    fn verify_tls12_signature(&self, m: &[u8], c: &rustls::pki_types::CertificateDer<'_>, d: &rustls::DigitallySignedStruct)
                              -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(m, c, d, &self.1.signature_verification_algorithms)
    }
    fn verify_tls13_signature(&self, m: &[u8], c: &rustls::pki_types::CertificateDer<'_>, d: &rustls::DigitallySignedStruct)
                              -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(m, c, d, &self.1.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.1.signature_verification_algorithms.supported_schemes()
    }
}

type Tls = tokio_rustls::client::TlsStream<tokio::net::TcpStream>;

pub struct Client {
    r: BufReader<tokio::io::ReadHalf<Tls>>,
    w: tokio::io::WriteHalf<Tls>,
    pub hello: Value,
}

impl Client {
    /// Connects to `addr`, pins `fp`, sends the hello line; Err unless the answer is ok.
    pub async fn connect(addr: &str, fp: &str, hello: Value) -> Result<Client> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let cfg = rustls::ClientConfig::builder_with_provider(provider.clone()).with_protocol_versions(&[&rustls::version::TLS13])?
            .dangerous().with_custom_certificate_verifier(Arc::new(Pin(fp.to_owned(), provider))).with_no_client_auth();
        let tcp = tokio::time::timeout(Duration::from_secs(15), tokio::net::TcpStream::connect(addr)).await.context("connect timed out")??;
        let tls = tokio_rustls::TlsConnector::from(Arc::new(cfg))
            .connect(rustls::pki_types::ServerName::try_from("pluck-review-host")?, tcp).await?;
        let (r, w) = tokio::io::split(tls);
        let mut c = Client { r: BufReader::new(r), w, hello: Value::Null };
        c.w.write_all(format!("{hello}\n").as_bytes()).await?;
        c.w.flush().await?;
        let h = tokio::time::timeout(Duration::from_secs(20), line(&mut c.r)).await??.context("closed: wrong key or code")?;
        anyhow::ensure!(h["ok"] == true, "refused: {h}");
        c.hello = h;
        Ok(c)
    }

    /// An op followed by its raw bytes (outage-part).
    pub async fn send(&mut self, op: &Value, bytes: &[u8]) -> Result<Value> {
        self.w.write_all(format!("{op}\n").as_bytes()).await?;
        self.w.write_all(bytes).await?;
        self.w.flush().await?;
        tokio::time::timeout(Duration::from_secs(120), line(&mut self.r)).await??.context("closed")
    }

    pub async fn ask(&mut self, op: &Value) -> Result<Value> {
        self.w.write_all(format!("{op}\n").as_bytes()).await?;
        self.w.flush().await?; // a big op (append, publish) would otherwise stall half-sent
        tokio::time::timeout(Duration::from_secs(120), line(&mut self.r)).await??.context("closed")
    }

    /// A ranged `get` (whole file when `range` is None); Ok(None) when the host hasn't got it.
    pub async fn get(&mut self, path: &str, range: Option<(u64, u64)>, out: &mut (impl AsyncWrite + Unpin)) -> Result<Option<u64>> {
        let mut op = json!({"op": "get", "path": path});
        if let Some((o, n)) = range {
            (op["offset"], op["length"]) = (json!(o), json!(n));
        }
        let h = self.ask(&op).await?;
        let Some(n) = h["size"].as_u64().filter(|_| h["ok"] == true) else { return Ok(None) };
        let got = tokio::io::copy(&mut (&mut self.r).take(n), out).await?;
        anyhow::ensure!(got == n, "cut short");
        Ok(Some(n))
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub fn ctx(data: &Path, uploads: Option<Arc<UploadRoot>>) -> (Arc<Ctx>, mpsc::Receiver<host::Sync>) {
        let (tx, rx) = mpsc::channel(4);
        let _ = rustls::crypto::ring::default_provider().install_default();
        let (acceptor, fp) = tls(data).unwrap();
        (Arc::new(Ctx { data: data.into(), key: Arc::new(RwLock::new(vec![7u8; 32])), roots: Arc::new(Roots(vec![])), to_host: tx,
            devices: Arc::new(Devices::load(data)), uploads, outage: Some(crate::outage::Outage::load(data, false, None)),
            ident: host::Ident { id: "H".into(), name: "Office NAS".into(), backup: false },
            fp, acceptor }), rx)
    }

    async fn ask<R: AsyncBufReadExt + Unpin, W: AsyncWriteExt + Unpin>(r: &mut R, w: &mut W, v: Value) -> Value {
        w.write_all(format!("{v}\n").as_bytes()).await.unwrap();
        line(r).await.unwrap().unwrap()
    }

    #[tokio::test]
    async fn uploads_can_be_fetched_and_deleted_but_nothing_else() {
        let data = std::env::temp_dir().join(format!("pluck-sync-{}", host::uuid()));
        std::fs::create_dir_all(data.join("uploads/L1")).unwrap();
        std::fs::create_dir_all(data.join("uploads/.partial")).unwrap();
        std::fs::create_dir_all(data.join("bundle/copies/V/1080")).unwrap();
        std::fs::create_dir_all(data.join("bundle/originals")).unwrap();
        std::fs::write(data.join("bundle/copies/V/1080/media.m4s"), b"0123456789").unwrap();
        std::fs::write(data.join("bundle/originals/V.mov"), b"orig").unwrap();
        std::fs::write(data.join("uploads/L1/a.png"), b"hello").unwrap();
        std::fs::write(data.join("uploads/.partial/x.part"), b"half").unwrap();
        let (c, _rx) = ctx(&data, None);
        let (client, server) = tokio::io::duplex(1 << 16);
        let c2 = c.clone();
        let task = tokio::spawn(async move { session(server, &c2, None).await });
        let (r, mut w) = tokio::io::split(client);
        let mut r = BufReader::new(r);
        let hello = ask(&mut r, &mut w, json!({"key": keys::b64(&[7u8; 32]), "protocol": 3})).await;
        assert_eq!((hello["ok"].clone(), hello["protocol"].clone(), hello["host"]["name"].clone()), (json!(true), json!(3), json!("Office NAS")));
        assert_eq!(hello["links"], 3, "says it serves level-3 links (Pluck makes level 2 for hosts that don't)");
        assert_eq!(ask(&mut r, &mut w, json!({"op": "get", "path": "uploads/L1/a.png"})).await["size"], 5);
        let mut body = [0u8; 5];
        r.read_exact(&mut body).await.unwrap();
        assert_eq!(&body, b"hello");
        assert_eq!(ask(&mut r, &mut w, json!({"op": "get", "path": "copies/V/1080/media.m4s", "offset": 3, "length": 4})).await["size"], 4);
        let mut body = [0u8; 4];
        r.read_exact(&mut body).await.unwrap();
        assert_eq!(&body, b"3456", "a range");
        for bad in ["uploads/.partial/x.part", "host-key", "uploads/../host-key", "manifest.json", "uploads/L1"] {
            assert!(ask(&mut r, &mut w, json!({"op": "get", "path": bad})).await["error"].is_string(), "{bad}");
        }
        assert!(ask(&mut r, &mut w, json!({"op": "_replica-own"})).await["error"].is_string(), "internal ops stay internal");
        assert_eq!(ask(&mut r, &mut w, json!({"op": "_accounts"})).await["error"], "scope", "only a backup gets the accounts file");
        assert_eq!(hello["accounts"], 1, "says it has People (4.0.4)");
        assert_eq!(hello["approvals"], 1, "and approves editors' invites; `accounts` stays 1 so Pluck 4.0.4 test builds keep People");
        assert_eq!(ask(&mut r, &mut w, json!({"op": "delete", "path": "uploads/L1/a.png"})).await["ok"], true);
        assert!(!data.join("uploads/L1/a.png").exists());
        drop(task);
        // An old client claiming protocol 1.
        let (client, server) = tokio::io::duplex(1 << 16);
        let c2 = c.clone();
        tokio::spawn(async move { let _ = session(server, &c2, None).await; });
        let (r, mut w) = tokio::io::split(client);
        let mut r = BufReader::new(r);
        assert_eq!(ask(&mut r, &mut w, json!({"key": keys::b64(&[7u8; 32]), "protocol": 1})).await, json!({"error": "incompatible", "protocol": 3}));
        let _ = std::fs::remove_dir_all(data);
    }

    /// #22: rotate-key ends a session that is open with the old legacy key.
    /// #21: the host key and ctl.json are refused as links or odd files.
    #[test]
    fn host_key_refuses_links_and_odd_files() {
        let d = std::env::temp_dir().join(format!("pluck-hk-{}", host::uuid()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("secret"), [1u8; 32]).unwrap();
        std::os::unix::fs::symlink(d.join("secret"), d.join("host-key")).unwrap();
        assert!(host_key(&d).is_err(), "a link to another file");
        std::fs::remove_file(d.join("host-key")).unwrap();
        std::fs::write(d.join("host-key"), [1u8; 33]).unwrap();
        assert!(host_key(&d).is_err(), "wrong size");
        std::fs::write(d.join("host-key"), [1u8; 32]).unwrap();
        assert_eq!(host_key(&d).unwrap().0, vec![1u8; 32]);
        std::fs::create_dir(d.join("dir")).unwrap();
        assert!(read_plain(&d.join("dir"), 4096).is_err(), "not a regular file");
        let _ = std::fs::remove_dir_all(d);
    }

    #[tokio::test]
    async fn rotate_key_ends_legacy_sessions() {
        let data = std::env::temp_dir().join(format!("pluck-sync-r-{}", host::uuid()));
        std::fs::create_dir_all(data.join("bundle")).unwrap();
        let (c, _rx) = ctx(&data, None);
        let (client, server) = tokio::io::duplex(1 << 16);
        let c2 = c.clone();
        let task = tokio::spawn(async move { session(server, &c2, None).await });
        let (r, mut w) = tokio::io::split(client);
        let mut r = BufReader::new(r);
        assert_eq!(ask(&mut r, &mut w, json!({"key": keys::b64(&[7u8; 32]), "protocol": 3})).await["ok"], true);
        assert!(ask(&mut r, &mut w, json!({"op": "list"})).await["files"].is_array());
        assert_eq!(rotate_key(&c)["ok"], true);
        w.write_all(b"{\"op\":\"list\"}\n").await.unwrap();
        assert!(line(&mut r).await.unwrap_or(None).is_none(), "the old key's session is cut");
        assert!(task.await.unwrap().is_err());
        let _ = std::fs::remove_dir_all(data);
    }

    #[tokio::test]
    async fn answers_are_flushed_through_a_buffering_stream() {
        // TLS holds written bytes until a flush, as this BufWriter does: an answer must arrive without the next request.
        let data = std::env::temp_dir().join(format!("pluck-sync-f-{}", host::uuid()));
        std::fs::create_dir_all(data.join("bundle/copies/V")).unwrap();
        let (c, _rx) = ctx(&data, None);
        let (client, server) = tokio::io::duplex(1 << 16);
        let (sr, sw) = tokio::io::split(server);
        let c2 = c.clone();
        let _task = tokio::spawn(async move { session(tokio::io::join(sr, tokio::io::BufWriter::with_capacity(1 << 20, sw)), &c2, None).await });
        let (r, mut w) = tokio::io::split(client);
        let mut r = BufReader::new(r);
        let hello = tokio::time::timeout(Duration::from_secs(5), ask(&mut r, &mut w, json!({"key": keys::b64(&[7u8; 32]), "protocol": 3}))).await;
        assert_eq!(hello.expect("hello answered without a flush")["ok"], true);
        let list = tokio::time::timeout(Duration::from_secs(5), ask(&mut r, &mut w, json!({"op": "list"}))).await;
        assert!(list.expect("list answered without a flush")["files"].is_array());
        let _ = std::fs::remove_dir_all(data);
    }

    #[tokio::test]
    async fn a_backup_gets_copies_only_and_removed_devices_are_cut() {
        let data = std::env::temp_dir().join(format!("pluck-sync-b-{}", host::uuid()));
        std::fs::create_dir_all(data.join("bundle/copies/V")).unwrap();
        std::fs::create_dir_all(data.join("bundle/originals")).unwrap();
        std::fs::write(data.join("bundle/copies/V/poster.jpg"), b"jpg").unwrap();
        std::fs::write(data.join("bundle/originals/V.mov"), b"orig").unwrap();
        let (c, _rx) = ctx(&data, None);
        let inv = c.devices.invite("backup", None);
        let (client, server) = tokio::io::duplex(1 << 16);
        let c2 = c.clone();
        let task = tokio::spawn(async move { session(server, &c2, None).await });
        let (r, mut w) = tokio::io::split(client);
        let mut r = BufReader::new(r);
        let h = ask(&mut r, &mut w, json!({"pair": inv["code"], "name": "Backup", "node": null, "role": "backup"})).await;
        let (id, key) = (h["device"].as_str().unwrap().to_owned(), h["key"].as_str().unwrap().to_owned());
        assert_eq!(ask(&mut r, &mut w, json!({"op": "get", "path": "copies/V/poster.jpg"})).await["size"], 3);
        let mut b = [0u8; 3];
        r.read_exact(&mut b).await.unwrap();
        assert!(ask(&mut r, &mut w, json!({"op": "get", "path": "originals/V.mov"})).await["error"].is_string(), "never originals");
        for op in ["list", "invite", "devices", "browse", "publish", "mkdir", "move", "rotate-key"] {
            assert_eq!(ask(&mut r, &mut w, json!({"op": op})).await["error"], "scope", "{op}");
        }
        drop(task);
        // Its device key works on a new session until it's removed; then the session ends.
        let (client, server) = tokio::io::duplex(1 << 16);
        let c2 = c.clone();
        let task = tokio::spawn(async move { session(server, &c2, None).await });
        let (r, mut w) = tokio::io::split(client);
        let mut r = BufReader::new(r);
        assert_eq!(ask(&mut r, &mut w, json!({"device": id, "key": key})).await["ok"], true);
        assert_eq!(c.devices.remove(&id)["ok"], true);
        w.write_all(b"{\"op\":\"manifest\"}\n").await.unwrap();
        assert!(line(&mut r).await.unwrap_or(None).is_none(), "cut");
        assert!(task.await.unwrap().is_err());
        let _ = std::fs::remove_dir_all(data);
    }

    /// §13.25: a backup takes uploads (not mkdir/move) only once its main takes them on; the push ops are a backup's,
    /// never a Mac's; a main says it takes them in its hello.
    #[tokio::test]
    async fn outage_ops_by_role() {
        let data = std::env::temp_dir().join(format!("pluck-sync-o-{}", host::uuid()));
        std::fs::create_dir_all(data.join("bundle")).unwrap();
        std::fs::create_dir_all(data.join(crate::outage::EDITOR_DIR)).unwrap();
        let root = UploadRoot::parse(&format!("outage={}", data.join(crate::outage::EDITOR_DIR).display()), &[], Arc::default()).map(Arc::new);
        let (main, _rx) = ctx(&data, None);
        let o = crate::outage::Outage::load(&data, true, None);
        let backup = Arc::new(Ctx { data: data.clone(), key: main.key.clone(), roots: main.roots.clone(), to_host: main.to_host.clone(), devices: main.devices.clone(),
            uploads: root, outage: Some(o.clone()), ident: host::Ident { id: "B".into(), name: "Backup".into(), backup: true }, fp: main.fp.clone(),
            acceptor: main.acceptor.clone() });
        let open = |c: Arc<Ctx>| async move {
            let (client, server) = tokio::io::duplex(1 << 16);
            tokio::spawn(async move { let _ = session(server, &c, None).await; });
            let (r, mut w) = tokio::io::split(client);
            let mut r = BufReader::new(r);
            let h = ask(&mut r, &mut w, json!({"key": keys::b64(&[7u8; 32]), "protocol": 3})).await;
            (r, w, h)
        };
        let (mut r, mut w, h) = open(main.clone()).await;
        assert_eq!(h["outage"], 1);
        assert_eq!(ask(&mut r, &mut w, json!({"op": "outage-begin", "item": {}})).await["error"], "scope", "a Mac doesn't push");
        assert!(ask(&mut r, &mut w, json!({"op": "outage-list"})).await["items"].is_array());
        let (mut r, mut w, _) = open(backup.clone()).await;
        let sha = "c".repeat(64);
        let begin = json!({"op": "upload-begin", "path": "outage/a.mov", "size": 1, "sha256": sha, "folder": "renders/Client"});
        assert_eq!(ask(&mut r, &mut w, begin.clone()).await["error"], "scope", "not before its main takes them on");
        o.set_main(true);
        assert!(ask(&mut r, &mut w, begin).await["upload"].is_string());
        for op in ["mkdir", "move", "outage-list"] {
            assert_eq!(ask(&mut r, &mut w, json!({"op": op, "path": "outage/x", "to": "outage"})).await["error"], "scope", "{op}");
        }
        let _ = std::fs::remove_dir_all(data);
    }

    /// Roles (4.0.5): an editor Mac does the Deliver work, gets {"error":"admin"} for every admin op (but may leave),
    /// and the host learns who asked from `_mac`, never from the client. Made admin, the same session may at once.
    #[tokio::test]
    async fn an_editor_mac_does_no_admin_work() {
        let data = std::env::temp_dir().join(format!("pluck-sync-r-{}", host::uuid()));
        std::fs::create_dir_all(data.join("bundle")).unwrap();
        let (c, mut rx) = ctx(&data, None);
        tokio::spawn(async move {
            while let Some(s) = rx.recv().await {
                let _ = s.reply.send(json!({"ok": true, "got": s.op}));
            }
        });
        let inv = c.devices.invite("mac", Some("editor"));
        let (client, server) = tokio::io::duplex(1 << 16);
        let c2 = c.clone();
        tokio::spawn(async move { let _ = session(server, &c2, None).await; });
        let (r, mut w) = tokio::io::split(client);
        let mut r = BufReader::new(r);
        let h = ask(&mut r, &mut w, json!({"pair": inv["code"], "name": "Studio MacBook", "node": null, "role": "mac", "protocol": 3})).await;
        assert_eq!((h["roles"].clone(), h["access"].clone()), (json!(1), json!("editor")));
        let id = h["device"].as_str().unwrap().to_owned();
        for op in ADMIN_OPS {
            assert_eq!(ask(&mut r, &mut w, json!({"op": op, "id": "other", "role": "mac"})).await["error"], "admin", "{op}");
        }
        assert!(ask(&mut r, &mut w, json!({"op": "list"})).await["files"].is_array());
        assert!(ask(&mut r, &mut w, json!({"op": "devices"})).await["devices"].is_array());
        let got = ask(&mut r, &mut w, json!({"op": "publish", "_mac": {"admin": true}})).await["got"].clone();
        assert_eq!((got["_mac"]["admin"].clone(), got["_mac"]["id"].clone(), got["_mac"]["name"].clone()), (json!(false), json!(id), json!("Studio MacBook")), "set here");
        assert_eq!(ask(&mut r, &mut w, json!({"op": "person-invite", "name": "New client", "role": "client"})).await["got"]["op"], "person-invite", "to the host");
        assert_eq!(ask(&mut r, &mut w, json!({"op": "device-remove", "id": id})).await["got"]["op"], "device-remove", "it may leave");
        assert_eq!(c.devices.set_access(&id, "admin")["ok"], true);
        assert!(ask(&mut r, &mut w, json!({"op": "invite", "role": "mac", "access": "editor"})).await["link"].is_string(), "admin at once");
        assert_eq!(ask(&mut r, &mut w, json!({"op": "people"})).await["got"]["_mac"]["admin"], true);
        let _ = std::fs::remove_dir_all(data);
    }
}
