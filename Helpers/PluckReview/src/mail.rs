// Email from the always-on host (plan 2026-11-20-deliver-notifications-mentions.md): a minimal SMTP client (implicit
// TLS on 465, STARTTLS on 587, AUTH PLAIN/LOGIN, text/plain UTF-8 quoted-printable) through the owner's own mail
// account, and the files behind it in the data folder: mail.json (settings), mail.secret (the password, 0600),
// subscribers.json, mail-queue.jsonl (what's waiting) and mail-sent.jsonl (ids sent, 30 days: a restart never sends
// twice), hooks.json (the optional per-project webhook). Nothing here goes near pluck.tools.
use std::{
    collections::HashMap,
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

use crate::{host::{iso, now_secs, uuid}, keys};

pub const QUIET_SECS: i64 = 600; // instant mails go after 10 minutes without a new event for that person
const SENT_DAYS: i64 = 30;
const TIMEOUT: Duration = Duration::from_secs(30);
pub const LANGS: [&str; 10] = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pt-BR", "zh-Hans"];
pub const MODES: [&str; 3] = ["instant", "daily", "off"];

#[derive(Debug, PartialEq)]
pub struct MailErr {
    pub code: &'static str, // auth | connect | tls | rejected (5xx on RCPT/DATA: this message's own) | sender | busy
    pub detail: String,
}

fn err(code: &'static str, detail: impl ToString) -> MailErr {
    MailErr { code, detail: detail.to_string() }
}

pub struct Msg {
    pub to: String,
    pub subject: String,
    pub body: String,
    pub unsubscribe: bool, // List-Unsubscribe (not on a test mail)
}

/// One of LANGS for a language tag ("pt" → "pt-BR", "zh-Hant" → "zh-Hans", unknown → "en").
pub fn lang(tag: &str) -> &'static str {
    let base = |t: &str| t.split(['-', '_']).next().unwrap_or("").to_ascii_lowercase();
    LANGS.iter().find(|l| l.eq_ignore_ascii_case(tag)).or_else(|| LANGS.iter().find(|l| base(l) == base(tag))).copied().unwrap_or("en")
}

/// "x@y.z" with text on both sides of one @, no spaces, ≤ 120 characters (the `identify` rules).
pub fn valid_email(s: &str) -> bool {
    let s = s.trim();
    s.chars().count() <= 120 && !s.chars().any(|c| c.is_whitespace() || c.is_control() || "<>,;\"".contains(c))
        && s.split_once('@').is_some_and(|(a, b)| !a.is_empty() && !b.is_empty() && !b.contains('@'))
}

/// The address in "Name <a@b>" (or the whole thing).
pub fn addr(from: &str) -> &str {
    match (from.rfind('<'), from.rfind('>')) {
        (Some(a), Some(b)) if a < b => from[a + 1..b].trim(),
        _ => from.trim(),
    }
}

/// A mention id for a commenter (shared with Swift, vector in the tests): never the token itself.
pub fn mention_id(author_token: &str) -> String {
    format!("a:{}", &keys::sha256_b64(format!("pluck-mention:{author_token}").as_bytes())[..16])
}

// ---- SMTP ----

/// TLS roots: the system's, or the tests' own.
fn tls(roots: Option<Arc<tokio_rustls::rustls::RootCertStore>>) -> Result<tokio_rustls::TlsConnector, MailErr> {
    let roots = roots.unwrap_or_else(|| {
        let mut r = tokio_rustls::rustls::RootCertStore::empty();
        r.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
        Arc::new(r)
    });
    let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());
    let cfg = tokio_rustls::rustls::ClientConfig::builder_with_provider(provider).with_safe_default_protocol_versions()
        .map_err(|e| err("tls", e))?.with_root_certificates(roots).with_no_client_auth();
    Ok(tokio_rustls::TlsConnector::from(Arc::new(cfg)))
}

/// One reply (multi-line `250-…`), as (code, last text).
async fn reply<S: AsyncRead + Unpin>(s: &mut BufReader<S>) -> Result<(u16, String), MailErr> {
    let mut all = String::new();
    loop {
        let mut line = String::new();
        let n = tokio::time::timeout(TIMEOUT, s.read_line(&mut line)).await.map_err(|_| err("connect", "timed out"))?.map_err(|e| err("connect", e))?;
        if n == 0 || line.len() < 3 {
            return Err(err("connect", "the server closed the connection"));
        }
        all.push_str(&line);
        if line.as_bytes().get(3) != Some(&b'-') {
            let code = line.get(..3).and_then(|c| c.parse().ok()).ok_or_else(|| err("connect", "not an SMTP server"))?; // (get: a multibyte reply must not panic)
            return Ok((code, all));
        }
    }
}

async fn cmd<S: AsyncRead + AsyncWrite + Unpin>(s: &mut BufReader<S>, line: &str, want: u16, code: &'static str) -> Result<String, MailErr> {
    s.get_mut().write_all(format!("{line}\r\n").as_bytes()).await.map_err(|e| err("connect", e))?;
    s.get_mut().flush().await.map_err(|e| err("connect", e))?;
    let (got, text) = reply(s).await?;
    if got / 100 != want / 100 {
        return Err(err(code, text.trim().to_owned()));
    }
    Ok(text)
}

async fn expect<S: AsyncRead + Unpin>(s: &mut BufReader<S>) -> Result<(), MailErr> {
    match reply(s).await? {
        (220, _) => Ok(()),
        (_, t) => Err(err("connect", t.trim().to_owned())),
    }
}

/// Send every message over one session: `cfg` is mail.json's settings, `roots` None in use (the system's roots).
pub async fn send(cfg: &Value, password: &str, msgs: &[Msg], roots: Option<Arc<tokio_rustls::rustls::RootCertStore>>) -> Result<(), MailErr> {
    let server = cfg["server"].as_str().unwrap_or("").to_owned();
    let port = cfg["port"].as_u64().unwrap_or(587) as u16;
    let tcp = tokio::time::timeout(TIMEOUT, tokio::net::TcpStream::connect((server.as_str(), port))).await
        .map_err(|_| err("connect", "timed out"))?.map_err(|e| err("connect", e))?;
    let name = tokio_rustls::rustls::pki_types::ServerName::try_from(server.clone()).map_err(|e| err("connect", e))?;
    let connector = tls(roots)?;
    if cfg["security"] == "tls" {
        let t = tokio::time::timeout(TIMEOUT, connector.connect(name, tcp)).await.map_err(|_| err("tls", "timed out"))?.map_err(|e| err("tls", e))?;
        let mut s = BufReader::new(t);
        expect(&mut s).await?;
        let caps = cmd(&mut s, "EHLO pluck-review", 250, "connect").await?;
        return session(&mut s, &caps, cfg, password, msgs).await;
    }
    let mut s = BufReader::new(tcp);
    expect(&mut s).await?;
    let caps = cmd(&mut s, "EHLO pluck-review", 250, "connect").await?;
    if !caps.to_ascii_uppercase().contains("STARTTLS") {
        return Err(err("tls", "the server doesn't offer STARTTLS")); // never a password in the clear
    }
    cmd(&mut s, "STARTTLS", 220, "tls").await?;
    let t = tokio::time::timeout(TIMEOUT, connector.connect(name, s.into_inner())).await.map_err(|_| err("tls", "timed out"))?.map_err(|e| err("tls", e))?;
    let mut s = BufReader::new(t);
    let caps = cmd(&mut s, "EHLO pluck-review", 250, "connect").await?;
    session(&mut s, &caps, cfg, password, msgs).await
}

async fn session<S: AsyncRead + AsyncWrite + Unpin>(s: &mut BufReader<S>, caps: &str, cfg: &Value, password: &str, msgs: &[Msg]) -> Result<(), MailErr> {
    let b64 = |b: &[u8]| base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b);
    let user = cfg["user"].as_str().unwrap_or("");
    let auth = caps.lines().find(|l| l.to_ascii_uppercase().contains("AUTH")).unwrap_or("").to_ascii_uppercase();
    if auth.contains("PLAIN") || !auth.contains("LOGIN") {
        cmd(s, &format!("AUTH PLAIN {}", b64(format!("\0{user}\0{password}").as_bytes())), 235, "auth").await?;
    } else {
        cmd(s, "AUTH LOGIN", 334, "auth").await?;
        cmd(s, &b64(user.as_bytes()), 334, "auth").await?;
        cmd(s, &b64(password.as_bytes()), 235, "auth").await?;
    }
    let from = cfg["from"].as_str().unwrap_or("");
    // Only a 5xx on RCPT or DATA is about this message (the host drops it); a refused sender or a 4xx is the server's (it backs off).
    let own = |e: MailErr| if e.code == "rejected" && !e.detail.starts_with('5') { err("busy", e.detail) } else { e };
    for m in msgs {
        cmd(s, &format!("MAIL FROM:<{}>", addr(from)), 250, "sender").await?;
        cmd(s, &format!("RCPT TO:<{}>", addr(&m.to)), 250, "rejected").await.map_err(own)?;
        cmd(s, "DATA", 354, "rejected").await.map_err(own)?;
        let data = message(cfg, m);
        cmd(s, &format!("{data}\r\n."), 250, "rejected").await.map_err(own)?;
    }
    let _ = cmd(s, "QUIT", 221, "connect").await;
    Ok(())
}

/// An RFC 2047 word when it isn't plain ASCII.
fn word(s: &str) -> String {
    if s.bytes().all(|b| (0x20..0x7f).contains(&b)) {
        return s.to_owned();
    }
    format!("=?UTF-8?B?{}?=", base64::Engine::encode(&base64::engine::general_purpose::STANDARD, s.as_bytes()))
}

fn mailbox(s: &str) -> String {
    match s.rfind('<') {
        Some(i) if i > 0 => format!("{} <{}>", word(s[..i].trim().trim_matches('"')), addr(s)),
        _ => format!("<{}>", addr(s)),
    }
}

/// "Fri, 20 Nov 2026 08:00:00 +0000"
pub fn rfc2822(secs: i64) -> String {
    const DAYS: [&str; 7] = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let i = iso(secs);
    let m: usize = i[5..7].parse().unwrap_or(1);
    format!("{}, {} {} {} {} +0000", DAYS[secs.div_euclid(86_400).rem_euclid(7) as usize], &i[8..10], MONTHS[m - 1], &i[..4], &i[11..19])
}

/// Quoted-printable, CRLF lines, soft breaks under 76.
pub fn qp(body: &str) -> String {
    let mut out = String::new();
    for line in body.replace("\r\n", "\n").split('\n') {
        let mut cur = String::new();
        let b = line.as_bytes();
        for (i, &c) in b.iter().enumerate() {
            let last = i + 1 == b.len();
            let enc = if c == b'=' || c > 126 || (c < 32 && c != b'\t') || ((c == b' ' || c == b'\t') && last) {
                format!("={c:02X}")
            } else {
                (c as char).to_string()
            };
            if cur.len() + enc.len() > 75 {
                out.push_str(&cur);
                out.push_str("=\r\n");
                cur.clear();
            }
            cur.push_str(&enc);
        }
        out.push_str(&cur);
        out.push_str("\r\n");
    }
    out.truncate(out.len() - 2);
    out
}

/// Headers and body, dot-stuffed for DATA.
pub fn message(cfg: &Value, m: &Msg) -> String {
    let from = cfg["from"].as_str().unwrap_or("");
    let domain = addr(from).rsplit('@').next().unwrap_or("pluck");
    let mut h = format!("From: {}\r\nTo: <{}>\r\nSubject: {}\r\nDate: {}\r\nMessage-ID: <{}@{domain}>\r\nMIME-Version: 1.0\r\n\
        Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: quoted-printable\r\nAuto-Submitted: auto-generated\r\n",
        mailbox(from), addr(&m.to), word(&m.subject), rfc2822(now_secs()), uuid());
    if let Some(r) = cfg["replyTo"].as_str().filter(|r| valid_email(addr(r))) {
        h.push_str(&format!("Reply-To: {}\r\n", mailbox(r)));
    }
    if m.unsubscribe {
        // One-click https would need the Worker; mailto is enough for the mail client's button.
        h.push_str(&format!("List-Unsubscribe: <mailto:{}?subject=unsubscribe>\r\n", addr(from)));
    }
    let all = format!("{h}\r\n{}", qp(&m.body));
    all.split("\r\n").map(|l| if l.starts_with('.') { format!(".{l}") } else { l.to_owned() }).collect::<Vec<_>>().join("\r\n")
}

// ---- the webhook (T12, small): one JSON POST per event, never retried ----

/// POST `body` to an https URL with `X-Pluck-Signature: sha256=<hex HMAC>`. Logged, never retried.
// shortcut: no retry and no redirects; upgrade if owners ask for delivery guarantees.
pub async fn hook(url: String, secret: String, body: String, roots: Option<Arc<tokio_rustls::rustls::RootCertStore>>) -> Result<u16, MailErr> {
    use hmac::Mac;
    let rest = url.strip_prefix("https://").ok_or_else(|| err("invalid", "not https"))?;
    let (hostport, path) = rest.split_once('/').map_or((rest, "/".to_owned()), |(h, p)| (h, format!("/{p}")));
    let host = hostport.rsplit_once(':').map_or(hostport, |(h, _)| h).to_owned();
    let port: u16 = hostport.rsplit_once(':').and_then(|(_, p)| p.parse().ok()).unwrap_or(443);
    let mut mac = hmac::Hmac::<sha2::Sha256>::new_from_slice(secret.as_bytes()).map_err(|e| err("invalid", e))?;
    mac.update(body.as_bytes());
    let sig: String = mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect();
    let tcp = tokio::time::timeout(TIMEOUT, tokio::net::TcpStream::connect((host.as_str(), port))).await
        .map_err(|_| err("connect", "timed out"))?.map_err(|e| err("connect", e))?;
    let name = tokio_rustls::rustls::pki_types::ServerName::try_from(host.clone()).map_err(|e| err("connect", e))?;
    let mut t = tls(roots)?.connect(name, tcp).await.map_err(|e| err("tls", e))?;
    let req = format!("POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nX-Pluck-Signature: sha256={sig}\r\n\
        User-Agent: pluck-review\r\nConnection: close\r\n\r\n{body}", body.len());
    t.write_all(req.as_bytes()).await.map_err(|e| err("connect", e))?;
    t.flush().await.map_err(|e| err("connect", e))?;
    let mut line = String::new();
    tokio::time::timeout(TIMEOUT, BufReader::new(t).read_line(&mut line)).await.map_err(|_| err("connect", "timed out"))?.map_err(|e| err("connect", e))?;
    line.split(' ').nth(1).and_then(|c| c.parse().ok()).ok_or_else(|| err("rejected", line.trim().to_owned()))
}

// ---- the store ----

pub struct Mail {
    dir: PathBuf,
    pub cfg: Value,       // mail.json
    pub subs: Vec<Value>, // subscribers.json
    pub queue: Vec<Value>,
    sent: HashMap<String, i64>, // queue id → when sent
    pub hooks: Value,           // hooks.json: project id → {"url","internal","secret"}
    pub sending: bool,
    pub retry_at: i64,
    pub backoff: i64,
    pub sent_today: (i64, u64), // (day, count)
}

fn read_json(p: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(p).ok()?).ok()
}

fn write_atomic(p: &Path, s: &str, private: bool) -> bool {
    let tmp = PathBuf::from(format!("{}.part", p.display()));
    let ok = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(if private { 0o600 } else { 0o644 }).open(&tmp)
        .and_then(|mut f| f.write_all(s.as_bytes()).and_then(|_| f.sync_data()))
        .and_then(|_| std::fs::rename(&tmp, p));
    if let Err(e) = &ok {
        crate::log(format!("host: can't write {}: {e}", p.display()));
    }
    ok.is_ok()
}

fn lines(p: &Path) -> Vec<Value> {
    std::fs::read_to_string(p).unwrap_or_default().lines().filter_map(|l| serde_json::from_str(l).ok()).collect()
}

impl Mail {
    pub fn load(data: &Path) -> Mail {
        let now = now_secs();
        let sent: HashMap<String, i64> = lines(&data.join("mail-sent.jsonl")).into_iter()
            .filter_map(|v| Some((v["id"].as_str()?.to_owned(), v["at"].as_i64()?))).filter(|(_, at)| now - at < SENT_DAYS * 86_400).collect();
        let mut m = Mail {
            dir: data.to_path_buf(), cfg: read_json(&data.join("mail.json")).unwrap_or_else(|| json!({})),
            subs: read_json(&data.join("subscribers.json")).and_then(|v| v.as_array().cloned()).unwrap_or_default(),
            queue: vec![], sent, hooks: read_json(&data.join("hooks.json")).filter(Value::is_object).unwrap_or_else(|| json!({})),
            sending: false, retry_at: 0, backoff: 0, sent_today: (0, 0),
        };
        m.queue = lines(&data.join("mail-queue.jsonl")).into_iter().filter(|q| q["id"].as_str().is_some_and(|id| !m.sent.contains_key(id))).collect();
        // The ledger without what's older than 30 days.
        let keep: String = m.sent.iter().map(|(id, at)| format!("{}\n", json!({"id": id, "at": at}))).collect();
        write_atomic(&data.join("mail-sent.jsonl"), &keep, false);
        m
    }

    pub fn password(&self) -> Option<String> {
        std::fs::read_to_string(self.dir.join("mail.secret")).ok().filter(|p| !p.is_empty())
    }

    /// Mail is set up: on, a server, a from address and a password.
    pub fn on(&self) -> bool {
        self.cfg["enabled"] == true && self.cfg["server"].as_str().is_some_and(|s| !s.is_empty())
            && self.cfg["from"].as_str().is_some_and(|f| valid_email(addr(f))) && self.password().is_some()
    }

    /// `mail-set`: the settings checked, and the password (Some("") removes it).
    pub fn set(&mut self, s: &Value, password: Option<&str>) -> Value {
        let str_ok = |k: &str, max: usize| s[k].as_str().is_some_and(|v| v.chars().count() <= max && !v.chars().any(char::is_control));
        let server_ok = s["server"].as_str().is_some_and(|v| !v.is_empty() && v.len() <= 253 && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-'));
        let ok = server_ok && matches!(s["port"].as_u64(), Some(465 | 587)) && (s["security"] == "tls" || s["security"] == "starttls")
            && str_ok("user", 254) && str_ok("from", 200) && valid_email(addr(s["from"].as_str().unwrap_or("")))
            && (s["replyTo"].is_null() || s["replyTo"].as_str().is_some_and(|r| r.is_empty() || valid_email(addr(r))))
            && s["digestHour"].as_u64().is_none_or(|h| h < 24) && s["tzOffset"].as_i64().is_none_or(|o| (-840..=840).contains(&o))
            && s["enabled"].is_boolean();
        if !ok {
            return json!({"error": {"code": "invalid"}});
        }
        let mut c = json!({});
        for k in ["enabled", "server", "port", "security", "user", "from", "replyTo", "digestHour", "tzOffset", "lang"] {
            c[k] = s[k].clone();
        }
        c["lang"] = json!(lang(s["lang"].as_str().unwrap_or("en")));
        if c["replyTo"] == "" {
            c["replyTo"] = Value::Null;
        }
        c["lastError"] = self.cfg["lastError"].clone();
        if let Some(p) = password {
            let path = self.dir.join("mail.secret");
            let ok = if p.is_empty() { std::fs::remove_file(&path).is_ok() || !path.exists() } else { write_atomic(&path, p, true) };
            if !ok {
                return json!({"error": {"code": "write"}});
            }
        }
        self.cfg = c;
        if !self.save_cfg() {
            return json!({"error": {"code": "write"}});
        }
        json!({"ok": true})
    }

    pub fn save_cfg(&self) -> bool {
        write_atomic(&self.dir.join("mail.json"), &self.cfg.to_string(), false)
    }

    pub fn save_subs(&self) -> bool {
        write_atomic(&self.dir.join("subscribers.json"), &Value::Array(self.subs.clone()).to_string(), true)
    }

    pub fn save_hooks(&self) -> bool {
        write_atomic(&self.dir.join("hooks.json"), &self.hooks.to_string(), true)
    }

    fn save_queue(&self) -> bool {
        let s: String = self.queue.iter().map(|q| format!("{q}\n")).collect();
        write_atomic(&self.dir.join("mail-queue.jsonl"), &s, true)
    }

    /// A new row, with its unsubscribe token.
    pub fn new_row(kind: &str) -> Value {
        json!({"id": uuid(), "kind": kind, "mode": "instant", "mute": [], "token": keys::b64(&rand::random::<[u8; 32]>()), "since": iso(now_secs())})
    }

    /// Queue items (an id already queued or sent is skipped: a deadline reminder or a repeated push stays one mail).
    pub fn push(&mut self, items: Vec<Value>) {
        let mut changed = false;
        for q in items {
            let id = q["id"].as_str().unwrap_or("");
            if id.is_empty() || self.sent.contains_key(id) || self.queue.iter().any(|x| x["id"] == id) {
                continue;
            }
            self.queue.push(q);
            changed = true;
        }
        if changed {
            self.save_queue();
        }
    }

    /// When a daily mail for an event at `at` goes: the next `digestHour` in the host's offset.
    pub fn daily_due(&self, at: i64) -> i64 {
        let off = self.cfg["tzOffset"].as_i64().unwrap_or(0) * 60;
        let local = at + off;
        let mut t = local.div_euclid(86_400) * 86_400 + self.cfg["digestHour"].as_i64().unwrap_or(8) * 3600;
        if t <= local {
            t += 86_400;
        }
        t - off
    }

    /// The batches due now, per subscriber: (row, items). Items of rows gone, off or muted are dropped here.
    pub fn due(&mut self, now: i64) -> Vec<(Value, Vec<Value>)> {
        let mut by: HashMap<String, Vec<Value>> = HashMap::new();
        for q in &self.queue {
            by.entry(q["to"].as_str().unwrap_or("").to_owned()).or_default().push(q.clone());
        }
        let mut out = vec![];
        let mut drop = vec![];
        for (to, items) in by {
            let Some(row) = self.subs.iter().find(|s| s["id"] == to.as_str()) else { drop.extend(items); continue };
            let muted = |q: &Value| row["mute"].as_array().is_some_and(|m| m.contains(&q["link"]));
            let (gone, items): (Vec<Value>, Vec<Value>) = items.into_iter().partition(|q| row["mode"] == "off" || muted(q));
            drop.extend(gone);
            if items.is_empty() {
                continue;
            }
            let at = |f: fn(std::slice::Iter<'_, Value>) -> Option<i64>| f(items.iter()).unwrap_or(now);
            let ready = items.iter().any(|q| q["event"] == "confirm") || match row["mode"].as_str() {
                Some("daily") => self.daily_due(at(|i| i.filter_map(|q| q["at"].as_i64()).min())) <= now,
                _ => at(|i| i.filter_map(|q| q["at"].as_i64()).max()) + QUIET_SECS <= now,
            };
            if ready {
                out.push((row.clone(), items));
            }
        }
        if !drop.is_empty() {
            let ids: Vec<&Value> = drop.iter().map(|q| &q["id"]).collect();
            self.queue.retain(|q| !ids.contains(&&q["id"]));
            self.save_queue();
        }
        out
    }

    /// Sent (or not worth sending): into the ledger, out of the queue.
    pub fn done(&mut self, ids: &[String]) {
        let now = now_secs();
        let add: String = ids.iter().map(|id| format!("{}\n", json!({"id": id, "at": now}))).collect();
        let ok = std::fs::OpenOptions::new().create(true).append(true).open(self.dir.join("mail-sent.jsonl"))
            .and_then(|mut f| f.write_all(add.as_bytes()).and_then(|_| f.sync_data()));
        if let Err(e) = ok {
            crate::log(format!("host: can't write mail-sent.jsonl: {e}"));
        }
        for id in ids {
            self.sent.insert(id.clone(), now);
        }
        self.queue.retain(|q| !q["id"].as_str().is_some_and(|id| ids.iter().any(|x| x == id)));
        self.save_queue();
    }

    pub fn count_sent(&mut self, n: u64) {
        let day = now_secs().div_euclid(86_400);
        if self.sent_today.0 != day {
            self.sent_today = (day, 0);
        }
        self.sent_today.1 += n;
    }

    /// `mail-state`: never the password or the tokens.
    pub fn state(&self) -> Value {
        let mut s = self.cfg.clone();
        let last = s.as_object_mut().and_then(|o| o.remove("lastError")).unwrap_or(Value::Null);
        let subs: Vec<Value> = self.subs.iter().map(|r| {
            let mut r = r.clone();
            if let Some(o) = r.as_object_mut() {
                o.remove("token");
                o.remove("author");
                o.remove("confirm");
            }
            r
        }).collect();
        let hooks: serde_json::Map<String, Value> = self.hooks.as_object().into_iter().flatten()
            .map(|(k, v)| (k.clone(), json!({"url": v["url"], "internal": v["internal"] == true}))).collect();
        let today = if self.sent_today.0 == now_secs().div_euclid(86_400) { self.sent_today.1 } else { 0 };
        json!({"mail": 1, "settings": s, "hasPassword": self.password().is_some(), "on": self.on(), "lastError": last,
            "queued": self.queue.len(), "sentToday": today, "subscribers": subs, "hooks": hooks})
    }
}

// ---- mail text ----

/// The mail strings in one language (copied from the review page's wording; no names).
fn t(lang: &str, k: &str) -> &'static str {
    let i = LANGS.iter().position(|l| *l == lang).unwrap_or(0);
    let row: [&'static str; 10] = match k {
        "comment" => ["{name} commented on {asset}", "{name} hat {asset} kommentiert", "{name} comentó en {asset}", "{name} a commenté {asset}",
            "{name} ha commentato {asset}", "{name}さんが{asset}にコメントしました", "{name}님이 {asset}에 댓글을 남겼습니다", "{name} reageerde op {asset}",
            "{name} comentou em {asset}", "{name} 评论了 {asset}"],
        "reply" => ["{name} replied on {asset}", "{name} hat bei {asset} geantwortet", "{name} respondió en {asset}", "{name} a répondu sur {asset}",
            "{name} ha risposto su {asset}", "{name}さんが{asset}で返信しました", "{name}님이 {asset}에 답글을 남겼습니다", "{name} antwoordde op {asset}",
            "{name} respondeu em {asset}", "{name} 回复了 {asset}"],
        "mention" => ["{name} mentioned you on {asset}", "{name} hat dich bei {asset} erwähnt", "{name} te mencionó en {asset}", "{name} vous a mentionné sur {asset}",
            "{name} ti ha menzionato su {asset}", "{name}さんが{asset}であなたをメンションしました", "{name}님이 {asset}에서 회원님을 언급했습니다", "{name} noemde je bij {asset}",
            "{name} mencionou você em {asset}", "{name} 在 {asset} 中提到了你"],
        "approval" => ["{name} approved {asset}", "{name} hat {asset} freigegeben", "{name} aprobó {asset}", "{name} a approuvé {asset}",
            "{name} ha approvato {asset}", "{name}さんが{asset}を承認しました", "{name}님이 {asset}을(를) 승인했습니다", "{name} keurde {asset} goed",
            "{name} aprovou {asset}", "{name} 批准了 {asset}"],
        "changes" => ["{name} asked for changes on {asset}", "{name} wünscht Änderungen an {asset}", "{name} pidió cambios en {asset}", "{name} demande des modifications sur {asset}",
            "{name} ha chiesto modifiche a {asset}", "{name}さんが{asset}の修正を依頼しました", "{name}님이 {asset}의 수정을 요청했습니다", "{name} vraagt wijzigingen voor {asset}",
            "{name} pediu alterações em {asset}", "{name} 要求修改 {asset}"],
        "version" => ["New version of {asset}: v{n}", "Neue Version von {asset}: v{n}", "Nueva versión de {asset}: v{n}", "Nouvelle version de {asset} : v{n}",
            "Nuova versione di {asset}: v{n}", "{asset}の新しいバージョン: v{n}", "{asset}의 새 버전: v{n}", "Nieuwe versie van {asset}: v{n}",
            "Nova versão de {asset}: v{n}", "{asset} 的新版本:v{n}"],
        "deadline" => ["Feedback on {asset} closes in 24 hours", "Feedback zu {asset} endet in 24 Stunden", "Los comentarios sobre {asset} cierran en 24 horas",
            "Les retours sur {asset} se terminent dans 24 heures", "Il feedback su {asset} si chiude tra 24 ore", "{asset}へのフィードバックは24時間後に締め切られます",
            "{asset}에 대한 피드백이 24시간 후 마감됩니다", "Feedback op {asset} sluit over 24 uur", "O feedback sobre {asset} encerra em 24 horas", "{asset} 的反馈将在 24 小时后截止"],
        "due" => ["{asset} is due today", "{asset} ist heute fällig", "{asset} vence hoy", "{asset} est à rendre aujourd'hui",
            "{asset} scade oggi", "{asset}の期限は今日です", "{asset}의 마감일은 오늘입니다", "{asset} moet vandaag af",
            "{asset} vence hoje", "{asset} 今天到期"],
        "overdue" => ["{asset} is overdue", "{asset} ist überfällig", "{asset} está atrasado", "{asset} est en retard",
            "{asset} è in ritardo", "{asset}は期限を過ぎています", "{asset}의 마감일이 지났습니다", "{asset} is te laat",
            "{asset} está atrasado", "{asset} 已逾期"],
        "many" => ["{n} updates on {asset}", "{n} Neuigkeiten zu {asset}", "{n} novedades en {asset}", "{n} nouveautés sur {asset}", "{n} novità su {asset}",
            "{asset}の更新 {n}件", "{asset}의 새 소식 {n}개", "{n} updates over {asset}", "{n} novidades em {asset}", "{asset} 有 {n} 条更新"],
        "open" => ["Open the review:", "Review öffnen:", "Abrir la revisión:", "Ouvrir la revue :", "Apri la revisione:", "レビューを開く:", "리뷰 열기:",
            "Open de review:", "Abrir a revisão:", "打开审阅:"],
        "browser" => ["If the link doesn't open, copy it into your browser's address bar.", "Falls der Link nicht öffnet, kopiere ihn in die Adresszeile deines Browsers.",
            "Si el enlace no se abre, cópialo en la barra de direcciones del navegador.", "Si le lien ne s'ouvre pas, copiez-le dans la barre d'adresse de votre navigateur.",
            "Se il link non si apre, copialo nella barra degli indirizzi del browser.", "リンクが開かない場合は、ブラウザのアドレスバーにコピーしてください。",
            "링크가 열리지 않으면 브라우저 주소창에 복사하세요.", "Opent de link niet? Kopieer hem in de adresbalk van je browser.",
            "Se o link não abrir, copie-o na barra de endereços do navegador.", "如果链接无法打开,请将其复制到浏览器地址栏。"],
        "stop" => ["Stop these emails:", "Diese E-Mails abbestellen:", "Dejar de recibir estos correos:", "Ne plus recevoir ces e-mails :", "Non ricevere più queste email:",
            "このメールの配信を停止:", "이 이메일 그만 받기:", "Deze e-mails stoppen:", "Parar de receber estes e-mails:", "停止接收这些邮件:"],
        "test" => ["Pluck: test email", "Pluck: Test-E-Mail", "Pluck: correo de prueba", "Pluck : e-mail de test", "Pluck: email di prova", "Pluck: テストメール",
            "Pluck: 테스트 이메일", "Pluck: testmail", "Pluck: e-mail de teste", "Pluck:测试邮件"],
        "testBody" => ["Email from your review server works.", "E-Mails von deinem Review-Server funktionieren.", "El correo de tu servidor de revisión funciona.",
            "L'e-mail de votre serveur de revue fonctionne.", "L'email dal tuo server di revisione funziona.", "レビューサーバーからのメールは正常に届いています。",
            "리뷰 서버의 이메일이 정상적으로 작동합니다.", "E-mail vanaf je reviewserver werkt.", "O e-mail do seu servidor de revisão funciona.", "审阅服务器的邮件功能正常。"],
        "confirm" => ["Confirm your email updates", "Bestätige deine E-Mail-Benachrichtigungen", "Confirma tus avisos por correo",
            "Confirmez vos notifications par e-mail", "Conferma gli aggiornamenti via email", "メール通知の確認",
            "이메일 알림을 확인하세요", "Bevestig je e-mailupdates", "Confirme suas atualizações por e-mail", "确认邮件通知"],
        "confirmBody" => ["Open this link to get emails about this review:", "Öffne diesen Link, um E-Mails zu diesem Review zu bekommen:",
            "Abre este enlace para recibir correos sobre esta revisión:", "Ouvrez ce lien pour recevoir des e-mails sur cette revue :",
            "Apri questo link per ricevere email su questa revisione:", "このレビューに関するメールを受け取るには、次のリンクを開いてください:",
            "이 리뷰에 대한 이메일을 받으려면 다음 링크를 여세요:", "Open deze link om e-mails over deze review te krijgen:",
            "Abra este link para receber e-mails sobre esta revisão:", "打开此链接以接收关于此审阅的邮件:"],
        "confirmIgnore" => ["Didn't ask for this? Ignore this email: nothing will be sent.", "Nicht angefordert? Ignoriere diese E-Mail: Es wird nichts gesendet.",
            "¿No lo pediste? Ignora este correo: no se enviará nada.", "Vous ne l'avez pas demandé ? Ignorez cet e-mail : rien ne sera envoyé.",
            "Non l'hai chiesto? Ignora questa email: non verrà inviato nulla.", "心当たりがない場合は、このメールを無視してください。何も送信されません。",
            "요청하지 않으셨나요? 이 이메일을 무시하세요. 아무것도 발송되지 않습니다.", "Niet aangevraagd? Negeer deze e-mail: er wordt niets verstuurd.",
            "Não pediu isso? Ignore este e-mail: nada será enviado.", "不是你申请的?忽略此邮件即可,不会发送任何内容。"],
        _ => [""; 10],
    };
    row[i]
}

pub fn text(lang: &str, k: &str, vars: &[(&str, &str)]) -> String {
    let mut s = t(lang, k).to_owned();
    for (k, v) in vars {
        s = s.replace(&format!("{{{k}}}"), v);
    }
    s
}

/// One line of a mail: what happened, and the comment's text (clipped) on the next.
pub struct Line {
    pub event: String,
    pub name: String,
    pub asset: String,
    pub n: String,
    pub text: Option<String>,
}

/// Subject and body for one person's batch. `url`: where to open it; `stop`: the unsubscribe link.
pub fn compose(lang: &str, title: &str, lines: &[Line], url: Option<&str>, stop: Option<&str>) -> (String, String) {
    let head = |l: &Line| text(lang, &l.event, &[("name", &l.name), ("asset", &l.asset), ("n", &l.n)]);
    let subject = if lines.len() == 1 { head(&lines[0]) } else { text(lang, "many", &[("n", &lines.len().to_string()), ("asset", title)]) };
    let mut body = String::new();
    for l in lines {
        body.push_str(&head(l));
        body.push('\n');
        if let Some(x) = &l.text {
            let clipped: String = x.chars().take(500).collect();
            body.push_str(&format!("  “{}”{}\n", clipped, if x.chars().count() > 500 { "…" } else { "" }));
        }
        body.push('\n');
    }
    if let Some(u) = url {
        body.push_str(&format!("{}\n{u}\n{}\n", text(lang, "open", &[]), text(lang, "browser", &[])));
    }
    if let Some(s) = stop {
        body.push_str(&format!("\n{} {s}\n", text(lang, "stop", &[])));
    }
    (subject, body)
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn a_multibyte_reply_is_an_error_not_a_panic() {
        let mut r = BufReader::new("12é hi\r\n".as_bytes());
        assert_eq!(reply(&mut r).await.unwrap_err().code, "connect");
        assert_eq!(reply(&mut BufReader::new("250 ok\r\n".as_bytes())).await.unwrap().0, 250);
    }

    #[test]
    fn mention_id_vector_and_addresses() {
        assert_eq!(mention_id("q1w2e3r4t5y6u7i8o9p0a1s2d3f4g5h6j7k8l9z0x1c"), "a:9sXYOUiNEwau8WPK");
        assert!(valid_email("a@b.c") && valid_email(" client@example.com "));
        for bad in ["", "a", "@b", "a@", "a b@c", "a@b@c", "<a@b>"] {
            assert!(!valid_email(bad), "{bad}");
        }
        assert_eq!(addr("Studio <studio@example.com>"), "studio@example.com");
        assert_eq!((lang("pt"), lang("zh"), lang("nl-BE"), lang("xx"), lang("pt-BR")), ("pt-BR", "zh-Hans", "nl", "en", "pt-BR"));
        assert_eq!(rfc2822(0), "Thu, 01 Jan 1970 00:00:00 +0000");
        assert_eq!(rfc2822(1_795_132_800), "Fri, 20 Nov 2026 00:00:00 +0000");
    }

    #[test]
    fn quoted_printable_and_dot_stuffing() {
        assert_eq!(qp("café = ok "), "caf=C3=A9 =3D ok=20");
        let long = "x".repeat(200);
        assert!(qp(&long).split("\r\n").all(|l| l.len() <= 76));
        let m = message(&json!({"from": "Studio <studio@example.com>"}), &Msg { to: "c@example.com".into(), subject: "Ünïcode".into(),
            body: "first\n.dot line\nlast".into(), unsubscribe: true });
        assert!(m.contains("\r\n..dot line\r\n"), "{m}");
        assert!(m.contains("Subject: =?UTF-8?B?"));
        assert!(m.contains("List-Unsubscribe: <mailto:studio@example.com?subject=unsubscribe>"));
    }

    #[test]
    fn digest_hour_in_the_hosts_offset() {
        let dir = std::env::temp_dir().join(format!("pluck-mail-{}", uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut m = Mail::load(&dir);
        m.cfg = json!({"digestHour": 8, "tzOffset": 60});
        let at = 1_795_132_800 + 9 * 3600; // 09:00 UTC = 10:00 local: tomorrow 08:00 local = 07:00 UTC
        assert_eq!(m.daily_due(at), 1_795_132_800 + 86_400 + 7 * 3600);
        assert_eq!(m.daily_due(1_795_132_800 + 3600), 1_795_132_800 + 7 * 3600, "01:00 UTC: today 07:00 UTC");
    }

    #[test]
    fn queue_batches_and_survives_a_restart_without_doubles() {
        let dir = std::env::temp_dir().join(format!("pluck-mail-{}", uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut m = Mail::load(&dir);
        let (mut a, mut b, mut off) = (Mail::new_row("team"), Mail::new_row("client"), Mail::new_row("client"));
        b["mode"] = json!("daily");
        off["mode"] = json!("off");
        a["mute"] = json!(["Lmuted"]);
        m.subs = vec![a.clone(), b.clone(), off.clone()];
        m.cfg = json!({"digestHour": 8, "tzOffset": 0});
        let t0 = 1_795_132_800 + 9 * 3600;
        let q = |id: &str, to: &Value, at: i64, link: &str| json!({"id": id, "to": to["id"], "event": "comment", "link": link, "at": at});
        m.push(vec![q("1", &a, t0, "L"), q("2", &a, t0 + 300, "L"), q("3", &b, t0, "L"), q("4", &off, t0, "L"), q("5", &a, t0, "Lmuted"), q("1", &a, t0, "L")]);
        assert_eq!(m.queue.len(), 5, "a repeated id is queued once");
        assert!(m.due(t0 + 700).is_empty(), "still within 10 quiet minutes of the second");
        assert_eq!(m.queue.len(), 3, "off and muted dropped");
        let d = m.due(t0 + 900);
        assert_eq!((d.len(), d[0].1.len()), (1, 2), "both of a's in one mail; b's daily waits");
        m.done(&["1".into(), "2".into()]);
        let mut m2 = Mail::load(&dir);
        m2.subs = m.subs.clone();
        m2.cfg = m.cfg.clone();
        assert_eq!(m2.queue.len(), 1, "after a restart only b's is left");
        m2.push(vec![q("1", &a, t0, "L")]);
        assert_eq!(m2.queue.len(), 1, "a sent id never comes back");
        assert_eq!(m2.due(t0 + 86_400 - 3600).len(), 1, "b's digest at 08:00 the next day");
    }

    #[test]
    fn settings_secret_and_state() {
        let dir = std::env::temp_dir().join(format!("pluck-mail-{}", uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut m = Mail::load(&dir);
        let s = json!({"enabled": true, "server": "smtp.example.com", "port": 587, "security": "starttls", "user": "u", "from": "Studio <studio@example.com>",
            "replyTo": null, "digestHour": 8, "tzOffset": 60, "lang": "en"});
        assert_eq!(m.set(&json!({"port": 25}), Some("x"))["error"]["code"], "invalid");
        assert_eq!(m.set(&s, Some("app-password"))["ok"], true);
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(dir.join("mail.secret")).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(m.on());
        m.subs.push(Mail::new_row("client"));
        let st = m.state().to_string();
        assert!(!st.contains("app-password") && !st.contains("token"), "{st}");
        assert_eq!(m.set(&s, Some(""))["ok"], true);
        assert!(!m.on() && m.state()["hasPassword"] == false);
    }

    /// A fake SMTP server on localhost: STARTTLS (or implicit TLS) with a test certificate, AUTH PLAIN, and what DATA got.
    pub async fn fake_smtp(implicit: bool, accept: &'static str) -> (u16, Arc<tokio_rustls::rustls::RootCertStore>, tokio::sync::oneshot::Receiver<Vec<String>>) {
        let ck = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let mut roots = tokio_rustls::rustls::RootCertStore::empty();
        roots.add(ck.cert.der().clone()).unwrap();
        let key = tokio_rustls::rustls::pki_types::PrivateKeyDer::Pkcs8(ck.signing_key.serialize_der().into());
        let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());
        let scfg = tokio_rustls::rustls::ServerConfig::builder_with_provider(provider).with_safe_default_protocol_versions().unwrap()
            .with_no_client_auth().with_single_cert(vec![ck.cert.der().clone()], key).unwrap();
        let acc = tokio_rustls::TlsAcceptor::from(Arc::new(scfg));
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (tcp, _) = l.accept().await.unwrap();
            let mut got = vec![];
            async fn talk<S: AsyncRead + AsyncWrite + Unpin>(s: &mut BufReader<S>, got: &mut Vec<String>, accept: &str, greet: bool) -> bool {
                if greet { s.get_mut().write_all(b"220 fake ESMTP\r\n").await.unwrap(); }
                let mut data = false;
                loop {
                    let mut line = String::new();
                    if s.read_line(&mut line).await.unwrap_or(0) == 0 { return false; }
                    got.push(line.trim_end().to_owned());
                    let l = line.trim_end();
                    let r: &str = if data {
                        if l == "." { data = false; "250 queued\r\n" } else { continue }
                    } else if l.starts_with("EHLO") {
                        "250-fake\r\n250-STARTTLS\r\n250 AUTH PLAIN LOGIN\r\n"
                    } else if l == "STARTTLS" {
                        s.get_mut().write_all(b"220 go ahead\r\n").await.unwrap();
                        return true;
                    } else if l.starts_with("AUTH PLAIN") {
                        if l == accept { "235 ok\r\n" } else { "535 5.7.8 bad credentials\r\n" }
                    } else if l.starts_with("RCPT TO:<bounce@") {
                        "550 5.1.1 no such user\r\n"
                    } else if l.starts_with("RCPT TO:<busy@") {
                        "451 4.3.0 try again later\r\n"
                    } else if l == "DATA" {
                        data = true; "354 go\r\n"
                    } else if l == "QUIT" {
                        s.get_mut().write_all(b"221 bye\r\n").await.unwrap(); return false;
                    } else {
                        "250 ok\r\n"
                    };
                    s.get_mut().write_all(r.as_bytes()).await.unwrap();
                }
            }
            if implicit {
                let mut s = BufReader::new(acc.accept(tcp).await.unwrap());
                talk(&mut s, &mut got, accept, true).await;
            } else {
                let mut s = BufReader::new(tcp);
                if talk(&mut s, &mut got, accept, true).await {
                    let mut s = BufReader::new(acc.accept(s.into_inner()).await.unwrap());
                    talk(&mut s, &mut got, accept, false).await;
                }
            }
            let _ = tx.send(got);
        });
        (port, Arc::new(roots), rx)
    }

    fn cfg(port: u16, security: &str) -> Value {
        json!({"server": "localhost", "port": port, "security": security, "user": "studio@example.com", "from": "Studio <studio@example.com>"})
    }

    const PLAIN: &str = "AUTH PLAIN AHN0dWRpb0BleGFtcGxlLmNvbQBzZWNyZXQ="; // \0studio@example.com\0secret

    #[tokio::test]
    async fn smtp_starttls_auth_and_a_dot_stuffed_body() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let (port, roots, rx) = fake_smtp(false, PLAIN).await;
        let msg = Msg { to: "client@example.com".into(), subject: "Hi".into(), body: "one\n.two".into(), unsubscribe: true };
        send(&cfg(port, "starttls"), "secret", &[msg], Some(roots)).await.unwrap();
        let got = rx.await.unwrap();
        let i = got.iter().position(|l| l == "STARTTLS").unwrap();
        assert!(got[i + 1].starts_with("EHLO"), "EHLO again inside TLS: {got:?}");
        assert!(got.iter().position(|l| l.starts_with("AUTH")).unwrap() > i, "never AUTH before TLS");
        assert!(got.contains(&"RCPT TO:<client@example.com>".to_owned()));
        assert!(got.contains(&"..two".to_owned()), "{got:?}");
    }

    #[tokio::test]
    async fn smtp_implicit_tls_and_a_535_is_auth() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let (port, roots, _rx) = fake_smtp(true, PLAIN).await;
        let msg = || Msg { to: "c@example.com".into(), subject: "s".into(), body: "b".into(), unsubscribe: false };
        send(&cfg(port, "tls"), "secret", &[msg()], Some(roots)).await.unwrap();
        let (port, roots, _rx) = fake_smtp(true, PLAIN).await;
        assert_eq!(send(&cfg(port, "tls"), "wrong", &[msg()], Some(roots)).await.unwrap_err().code, "auth");
        let (port, _, _rx) = fake_smtp(true, PLAIN).await;
        assert_eq!(send(&cfg(port, "tls"), "secret", &[msg()], None).await.unwrap_err().code, "tls", "an untrusted certificate");
        let to = |a: &str| Msg { to: a.into(), subject: "s".into(), body: "b".into(), unsubscribe: false };
        let (port, roots, _rx) = fake_smtp(true, PLAIN).await;
        assert_eq!(send(&cfg(port, "tls"), "secret", &[to("bounce@example.com")], Some(roots)).await.unwrap_err().code, "rejected", "a 550 on RCPT");
        let (port, roots, _rx) = fake_smtp(true, PLAIN).await;
        assert_eq!(send(&cfg(port, "tls"), "secret", &[to("busy@example.com")], Some(roots)).await.unwrap_err().code, "busy", "a 451 is the server's");
        let free = TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap().port();
        assert_eq!(send(&cfg(free, "tls"), "secret", &[msg()], None).await.unwrap_err().code, "connect");
    }

    #[tokio::test]
    async fn webhook_posts_signed_json() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let ck = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let mut roots = tokio_rustls::rustls::RootCertStore::empty();
        roots.add(ck.cert.der().clone()).unwrap();
        let key = tokio_rustls::rustls::pki_types::PrivateKeyDer::Pkcs8(ck.signing_key.serialize_der().into());
        let provider = Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());
        let scfg = tokio_rustls::rustls::ServerConfig::builder_with_provider(provider).with_safe_default_protocol_versions().unwrap()
            .with_no_client_auth().with_single_cert(vec![ck.cert.der().clone()], key).unwrap();
        let acc = tokio_rustls::TlsAcceptor::from(Arc::new(scfg));
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let srv = tokio::spawn(async move {
            let (tcp, _) = l.accept().await.unwrap();
            let mut s = BufReader::new(acc.accept(tcp).await.unwrap());
            let mut head = String::new();
            loop {
                let mut line = String::new();
                s.read_line(&mut line).await.unwrap();
                if line == "\r\n" { break }
                head.push_str(&line);
            }
            s.get_mut().write_all(b"HTTP/1.1 204 No Content\r\n\r\n").await.unwrap();
            head
        });
        let code = hook(format!("https://localhost:{port}/hook"), "k".into(), "{\"text\":\"hi\"}".into(), Some(Arc::new(roots))).await.unwrap();
        assert_eq!(code, 204);
        let head = srv.await.unwrap();
        assert!(head.starts_with("POST /hook HTTP/1.1") && head.contains("Content-Type: application/json"), "{head}");
        // HMAC-SHA256("k", body), hex.
        use hmac::Mac;
        let mut m = hmac::Hmac::<sha2::Sha256>::new_from_slice(b"k").unwrap();
        m.update(b"{\"text\":\"hi\"}");
        let hex: String = m.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect();
        assert!(head.contains(&format!("X-Pluck-Signature: sha256={hex}")));
        assert_eq!(hook("http://x/".into(), "k".into(), "{}".into(), None).await.unwrap_err().code, "invalid");
    }

    #[test]
    fn mail_text() {
        let lines = [Line { event: "reply".into(), name: "Sam".into(), asset: "Cut".into(), n: String::new(), text: Some("Looks good".into()) }];
        let (s, b) = compose("nl", "Film", &lines, Some("https://pluck.tools/r/#k"), Some("https://pluck.tools/r/#k/u/t"));
        assert_eq!(s, "Sam antwoordde op Cut");
        assert!(b.contains("“Looks good”") && b.contains("https://pluck.tools/r/#k/u/t"));
        let two = [lines[0].clone_line(), lines[0].clone_line()];
        assert_eq!(compose("xx", "Film", &two, None, None).0, "2 updates on Film", "an unknown language is English");
        for k in ["comment", "reply", "mention", "approval", "changes", "version", "deadline", "due", "overdue", "many", "open", "browser", "stop", "test", "testBody"] {
            assert!(LANGS.iter().all(|l| !t(l, k).is_empty()), "{k}");
        }
    }

    impl Line {
        fn clone_line(&self) -> Line {
            Line { event: self.event.clone(), name: self.name.clone(), asset: self.asset.clone(), n: self.n.clone(), text: self.text.clone() }
        }
    }
}
