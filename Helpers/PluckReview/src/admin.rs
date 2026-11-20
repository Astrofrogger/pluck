// The host's admin page, for the owner's LAN only (bind it to the NAS's LAN address): browse the
// media roots, publish files to a review project, make a link, read comments, unpublish.
// HTTPS with the host's own self-signed certificate (the browser warns once). The first visit sets
// the password, which needs the host key, so nobody else on the LAN can claim the page first. The
// password is stored as PBKDF2. Sessions: an HttpOnly, Secure, SameSite=Strict cookie, and every
// call also carries the session's CSRF token in X-CSRF and must come from this page's origin.
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::{mpsc, oneshot},
};
use tokio_rustls::TlsAcceptor;

use crate::{host, keys, log, report, roots::Roots};

const PAGE: &str = include_str!("admin/index.html");
const SCRIPT: &str = include_str!("admin/admin.js");
const OPS: &[&str] = &["admin-state", "admin-publish", "admin-unpublish", "admin-renew", "admin-comments", "admin-activity", "roots", "browse", "probe", "thumb",
    "invite", "devices", "device-remove", "mail-state", "mail-set", "mail-test"];

struct State {
    data: PathBuf,
    fingerprint: String, // shown so the owner can compare it with the one Pluck pinned
    key: Arc<std::sync::RwLock<Vec<u8>>>, // the sync endpoint's: after rotate-key the old key can't claim the page (#18)
    roots: Arc<Roots>,
    to_host: mpsc::Sender<host::Sync>,
    devices: Arc<crate::devices::Devices>,
    sessions: Mutex<HashMap<String, (String, Instant)>>, // cookie → (csrf, expiry)
    fails: Mutex<Vec<Instant>>,
}

#[allow(clippy::too_many_arguments)]
pub async fn serve(data: PathBuf, at: String, acceptor: TlsAcceptor, fingerprint: String, key: Arc<std::sync::RwLock<Vec<u8>>>, roots: Arc<Roots>, to_host: mpsc::Sender<host::Sync>,
                   devices: Arc<crate::devices::Devices>) -> Result<()> {
    let listener = TcpListener::bind(&at).await.with_context(|| format!("can't listen on {at}"))?;
    report(json!({"admin": {"listen": listener.local_addr()?.to_string()}}));
    let st = Arc::new(State { data, fingerprint, key, roots, to_host, devices, sessions: Mutex::default(), fails: Mutex::default() });
    loop {
        let (tcp, _) = listener.accept().await?;
        let (acceptor, st) = (acceptor.clone(), st.clone());
        tokio::spawn(async move {
            let r = async {
                let mut tls = tokio::time::timeout(Duration::from_secs(10), acceptor.accept(tcp)).await??;
                let res = match tokio::time::timeout(Duration::from_secs(30), read_request(&mut tls)).await? {
                    Ok(req) => handle(&st, req).await,
                    Err(e) => resp(400, "text/plain", format!("{e}").into_bytes(), None),
                };
                tls.write_all(&res).await?;
                tls.shutdown().await?;
                anyhow::Ok(())
            };
            if let Err(e) = r.await {
                log(format!("admin: {e:#}")); // no address: logs keep no IPs (hardening §3)
            }
        });
    }
}

struct Req {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

async fn read_request<S: AsyncReadExt + Unpin>(s: &mut S) -> Result<Req> {
    let mut buf = vec![];
    let mut chunk = [0u8; 4096];
    let end = loop {
        let n = s.read(&mut chunk).await?;
        anyhow::ensure!(n > 0, "closed");
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        anyhow::ensure!(buf.len() < 16 * 1024, "header too large");
    };
    let head = String::from_utf8(buf[..end].to_vec())?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let (method, path) = (first.next().unwrap_or("").to_owned(), first.next().unwrap_or("").to_owned());
    let headers: HashMap<String, String> = lines.filter_map(|l| l.split_once(':')).map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_owned())).collect();
    let len: usize = headers.get("content-length").and_then(|l| l.parse().ok()).unwrap_or(0);
    anyhow::ensure!(len <= 1 << 20, "body too large");
    let mut body = buf[end + 4..].to_vec();
    while body.len() < len {
        let n = s.read(&mut chunk).await?;
        anyhow::ensure!(n > 0, "closed");
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(len);
    Ok(Req { method, path, headers, body })
}

fn resp(code: u16, kind: &str, body: Vec<u8>, cookie: Option<String>) -> Vec<u8> {
    let reason = match code { 200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 429 => "Too Many Requests", _ => "Error" };
    let mut h = format!("HTTP/1.1 {code} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\
        Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n\
        Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n",
        body.len());
    if let Some(c) = cookie {
        h.push_str(&format!("Set-Cookie: {c}\r\n"));
    }
    h.push_str("\r\n");
    let mut out = h.into_bytes();
    out.extend(body);
    out
}

fn json_resp(v: Value, cookie: Option<String>) -> Vec<u8> {
    resp(200, "application/json", v.to_string().into_bytes(), cookie)
}

fn cookie_of(r: &Req) -> Option<String> {
    r.headers.get("cookie")?.split(';').find_map(|c| c.trim().strip_prefix("pr_admin=").map(str::to_owned))
}

impl State {
    fn new_session(&self) -> (String, String) {
        let (sid, csrf) = (keys::b64(&rand::random::<[u8; 32]>()), keys::b64(&rand::random::<[u8; 32]>()));
        let mut s = self.sessions.lock().unwrap();
        s.retain(|_, (_, exp)| *exp > Instant::now());
        s.insert(sid.clone(), (csrf.clone(), Instant::now() + Duration::from_secs(12 * 3600)));
        (format!("pr_admin={sid}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=43200"), csrf)
    }

    fn csrf(&self, r: &Req) -> Option<String> {
        let sid = cookie_of(r)?;
        let s = self.sessions.lock().unwrap();
        s.get(&sid).filter(|(_, exp)| *exp > Instant::now()).map(|(c, _)| c.clone())
    }

    fn throttled(&self) -> bool {
        let mut f = self.fails.lock().unwrap();
        f.retain(|t| t.elapsed() < Duration::from_secs(60));
        f.len() >= 5
    }

    fn password_file(&self) -> PathBuf {
        self.data.join("admin-password")
    }
}

async fn handle(st: &State, r: Req) -> Vec<u8> {
    match (r.method.as_str(), r.path.as_str()) {
        ("GET", "/") => return resp(200, "text/html; charset=utf-8", PAGE.into(), None),
        ("GET", "/admin.js") => return resp(200, "text/javascript; charset=utf-8", SCRIPT.into(), None),
        ("POST", _) => {}
        _ => return resp(404, "text/plain", b"not found".to_vec(), None),
    }
    // Same origin only (the page's own fetches), and JSON only, so no other site can post here.
    let host = r.headers.get("host").cloned().unwrap_or_default();
    let same_origin = r.headers.get("origin").is_none_or(|o| *o == format!("https://{host}"));
    let json_body = r.headers.get("content-type").is_some_and(|c| c.starts_with("application/json"));
    if !same_origin || !json_body {
        return resp(403, "text/plain", b"forbidden".to_vec(), None);
    }
    let body: Value = serde_json::from_slice(&r.body).unwrap_or_default();
    let have_password = st.password_file().exists();
    match r.path.as_str() {
        "/api/session" => {
            let csrf = st.csrf(&r);
            json_resp(json!({"setup": !have_password, "loggedIn": csrf.is_some(), "csrf": csrf, "fingerprint": st.fingerprint}), None)
        }
        "/api/setup" | "/api/login" => {
            if st.throttled() {
                return resp(429, "application/json", br#"{"error":"Too many tries. Wait a minute."}"#.to_vec(), None);
            }
            let pw = body["password"].as_str().unwrap_or("");
            let ok = if r.path == "/api/setup" {
                let key_ok = body["hostKey"].as_str().and_then(keys::unb64).is_some_and(|k| keys::subtle_eq(&k, &st.key.read().unwrap()));
                if have_password || !key_ok || pw.chars().count() < 10 {
                    false
                } else {
                    use std::os::unix::fs::OpenOptionsExt;
                    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(st.password_file())
                        .and_then(|mut f| std::io::Write::write_all(&mut f, keys::hash_password(pw).as_bytes())).is_ok()
                }
            } else {
                let stored = std::fs::read_to_string(st.password_file()).unwrap_or_default();
                keys::check_password(stored.trim(), pw)
            };
            if !ok {
                st.fails.lock().unwrap().push(Instant::now());
                let msg = if r.path == "/api/setup" { "Check the host key; the password needs 10 characters or more." } else { "Wrong password." };
                return json_resp(json!({"error": msg}), None);
            }
            let (cookie, csrf) = st.new_session();
            json_resp(json!({"ok": true, "csrf": csrf}), Some(cookie))
        }
        "/api/logout" | "/api/op" => {
            let Some(csrf) = st.csrf(&r) else { return resp(403, "application/json", br#"{"error":"Sign in again."}"#.to_vec(), None) };
            if !r.headers.get("x-csrf").is_some_and(|c| keys::subtle_eq(c.as_bytes(), csrf.as_bytes())) {
                return resp(403, "text/plain", b"forbidden".to_vec(), None);
            }
            if r.path == "/api/logout" {
                if let Some(sid) = cookie_of(&r) {
                    st.sessions.lock().unwrap().remove(&sid);
                }
                return json_resp(json!({"ok": true}), Some("pr_admin=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0".into()));
            }
            let op = body["op"].as_str().unwrap_or("");
            if !OPS.contains(&op) {
                return json_resp(json!({"error": "unknown op"}), None);
            }
            if let Some(v) = st.roots.op(&body).await {
                return json_resp(v, None);
            }
            // "Pair a Mac" / "Pair a backup host": the same invitation as the sync op, shown once.
            match op {
                "invite" => return json_resp(st.devices.invite(body["role"].as_str().unwrap_or(""), None), None),
                "devices" => return json_resp(st.devices.list(), None),
                _ => {}
            }
            let root = op == "device-remove";
            let mut body = body;
            // The page was claimed with the host key: it is the root of trust (it may remove the last admin Mac).
            body["_root"] = json!(root);
            body["_mac"] = json!({"name": "NAS admin page", "admin": true});
            let (tx, rx) = oneshot::channel();
            if st.to_host.send(host::Sync { op: body, reply: tx }).await.is_err() {
                return json_resp(json!({"error": "host stopped"}), None);
            }
            json_resp(rx.await.unwrap_or_default(), None)
        }
        _ => resp(404, "text/plain", b"not found".to_vec(), None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #18: after rotate-key (the shared key changes) the pre-rotation key can't claim an unclaimed page.
    #[tokio::test]
    async fn setup_uses_the_current_host_key() {
        let data = std::env::temp_dir().join(format!("pluck-admin-{}", host::uuid()));
        std::fs::create_dir_all(&data).unwrap();
        let key = Arc::new(std::sync::RwLock::new(vec![7u8; 32]));
        let (to_host, _rx) = mpsc::channel(1);
        let st = State { data: data.clone(), fingerprint: "AA".into(), key: key.clone(), roots: Arc::new(Roots(vec![])), to_host,
            devices: Arc::new(crate::devices::Devices::load(&data)), sessions: Mutex::default(), fails: Mutex::default() };
        let req = |k: &[u8]| Req { method: "POST".into(), path: "/api/setup".into(),
            headers: [("content-type".to_owned(), "application/json".to_owned())].into(),
            body: json!({"hostKey": keys::b64(k), "password": "long enough password"}).to_string().into_bytes() };
        *key.write().unwrap() = vec![8u8; 32]; // what rotate_key does to the sync endpoint's key
        let old = String::from_utf8(handle(&st, req(&[7u8; 32])).await).unwrap();
        assert!(old.contains("\"error\"") && !st.password_file().exists(), "{old}");
        let new = String::from_utf8(handle(&st, req(&[8u8; 32])).await).unwrap();
        assert!(new.contains("\"ok\":true") && st.password_file().exists(), "{new}");
        let _ = std::fs::remove_dir_all(data);
    }
}
