// Loopback end to end, no internet: a tiny signaling stub (the Room DO's relay rules), the real
// pluck-review binary (local: true, host candidates only, no STUN), and str0m-based "browsers"
// that make the offer, create `ctl`/`media`, do the §3 auth with the fingerprints they actually
// negotiated, fetch segments with acks, and comment.
use std::{
    collections::{HashMap, VecDeque},
    net::SocketAddr,
    path::Path,
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use str0m::{
    Candidate, Event, Input, Output, Rtc,
    change::SdpAnswer,
    channel::ChannelId,
    net::{Protocol, Receive},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, UdpSocket},
    process::{Child, ChildStdin, Command},
    sync::mpsc,
};
use tokio_tungstenite::tungstenite::{Message, handshake::server::{Request, Response}};

const ROOM: &str = "7E1RkYmx_jTN80i5w8xmOg";
// Protocol 2 (afix contract vector): reg and the signing seed come from the owner-only root, not the link.
const REG: &str = "thuSTJX_ex8_hafj-qs5coPH00wqbknCQ-ON70RP0zQ";
const AUTH: &str = "FndhJOuo-7ZZiHHA7b4rC1jnZIGaNtKo1ipv9OAqI5c";
const JOIN: &str = "DDk_aLVe7_lpSrn2FJsnpy4x8AsymOK8AZOx9K_7OAo";
const SEED: &str = "R85Juszx1tmPSUJlpjYA3DtFmqHJDUUU0Z1HyoU0Mb4";
const PUB: &str = "d-VE2PQpTDJ6Rw_vkvYI0nCJ34xkdCgQRSVNa3LdIFw";

fn hello_msg(mac_nonce: &[u8], fp_mac: &str, fp_br: &str) -> Vec<u8> {
    [b"pluck-review/2 server\n".as_slice(), mac_nonce, fp_mac.as_bytes(), b"\n", fp_br.as_bytes()].concat()
}

/// What Swift (or a host) signs in `hello`, with the room's seed.
fn sign_hello(seed: &str, mac_nonce: &[u8], fp_mac: &str, fp_br: &str) -> String {
    let k = ring::signature::Ed25519KeyPair::from_seed_unchecked(&B64.decode(seed).unwrap()).unwrap();
    B64.encode(k.sign(&hello_msg(mac_nonce, fp_mac, fp_br)).as_ref())
}

/// The browser's check before it sends anything: v 2 and a signature by the link's public key.
fn hello_ok(hello: &Value, fp_mac: &str, fp_br: &str) -> bool {
    let (Some(n), Some(sig)) = (hello["nonce"].as_str().and_then(|n| B64.decode(n).ok()), hello["sig"].as_str().and_then(|s| B64.decode(s).ok())) else { return false };
    hello["v"] == 2 && ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, B64.decode(PUB).unwrap()).verify(&hello_msg(&n, fp_mac, fp_br), &sig).is_ok()
}
const T: Duration = Duration::from_secs(60);

fn proof(role: &str, mac_nonce: &[u8], br_nonce: &[u8], fp_mac: &str, fp_br: &str) -> String {
    let mut m = Hmac::<Sha256>::new_from_slice(&B64.decode(AUTH).unwrap()).unwrap();
    m.update(format!("pluck-review/1 {role}\n").as_bytes());
    m.update(mac_nonce);
    m.update(br_nonce);
    m.update(fp_mac.as_bytes());
    m.update(b"\n");
    m.update(fp_br.as_bytes());
    B64.encode(m.finalize().into_bytes())
}

fn fingerprint(sdp: &str) -> String {
    sdp.lines().find_map(|l| l.trim().strip_prefix("a=fingerprint:sha-256 ")).unwrap().trim().to_ascii_uppercase()
}

// ---- signaling stub: mac-register / browser-join, relay with `peer` added and stripped ----

#[derive(Default)]
struct Stub {
    mac: Option<mpsc::UnboundedSender<String>>,
    browsers: HashMap<String, mpsc::UnboundedSender<String>>,
    n: u32,
}

async fn signaling() -> SocketAddr {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let st = Arc::new(Mutex::new(Stub::default()));
    tokio::spawn(async move {
        loop {
            let (tcp, _) = l.accept().await.unwrap();
            let st = st.clone();
            tokio::spawn(async move {
                let mut path = String::new();
                let cb = |req: &Request, res: Response| { path = req.uri().path().to_owned(); Ok(res) };
                let ws = tokio_tungstenite::accept_hdr_async(tcp, cb).await.unwrap();
                assert!(path.starts_with("/signal/") && path.len() == 30, "{path}");
                let (mut w, mut r) = ws.split();
                let (tx, mut rx) = mpsc::unbounded_channel::<String>();
                tokio::spawn(async move { while let Some(m) = rx.recv().await { if w.send(Message::text(m)).await.is_err() { break } } });
                let mut me: Option<String> = None; // None = not joined, "mac" or the peer id
                while let Some(Ok(Message::Text(t))) = r.next().await {
                    let mut v: Value = serde_json::from_str(&t).unwrap();
                    let mut s = st.lock().unwrap();
                    match (v["t"].as_str().unwrap(), me.as_deref()) {
                        ("mac-register", _) => {
                            assert!(v["v"] == 2 && v["join"].as_str().is_some_and(|j| j.len() == 43) && v["reg"].as_str().is_some_and(|r| r.len() == 43), "{v}");
                            s.mac = Some(tx.clone());
                            me = Some("mac".into());
                            let _ = tx.send(json!({"t": "registered", "peers": []}).to_string());
                        }
                        ("browser-join", _) => {
                            s.n += 1;
                            let id = format!("p_test{}", s.n);
                            s.browsers.insert(id.clone(), tx.clone());
                            let _ = tx.send(json!({"t": "joined", "peer": id, "mac": s.mac.is_some(), "ice": []}).to_string());
                            me = Some(id);
                        }
                        ("ping", _) => { let _ = tx.send(r#"{"t":"pong"}"#.into()); }
                        (_, Some("mac")) => {
                            let peer = v["peer"].as_str().unwrap_or("").to_owned();
                            v.as_object_mut().unwrap().remove("peer");
                            if v["t"] == "kick" { s.browsers.remove(&peer); }
                            else if let Some(b) = s.browsers.get(&peer) { let _ = b.send(v.to_string()); }
                        }
                        (_, Some(peer)) => {
                            v["peer"] = json!(peer);
                            if let Some(m) = &s.mac { let _ = m.send(v.to_string()); }
                        }
                        _ => {}
                    }
                }
            });
        }
    });
    addr
}

// ---- a str0m "browser" ----

struct Browser {
    rtc: Rtc,
    sock: UdpSocket,
    local: SocketAddr,
    ctl: Option<ChannelId>,
    media: Option<ChannelId>,
    fp_mine: String,
    fp_mac: String,
    inbox: VecDeque<Value>,
    bufs: HashMap<u32, (Vec<u8>, u64, u32)>, // fetch → (bytes, acked, next seq)
    part: String,                            // a ctl message arriving in parts
    parts_seen: usize,
    up_acked: HashMap<u32, u64>,             // upload → bytes the helper has acked
    next_id: u64,
    deadline: Instant,
}

impl Browser {
    async fn connect(signal: SocketAddr) -> Browser {
        let sock = {
            let s = socket2::Socket::new(socket2::Domain::IPV4, socket2::Type::DGRAM, None).unwrap();
            s.set_recv_buffer_size(4 << 20).unwrap();
            s.set_send_buffer_size(4 << 20).unwrap();
            s.set_nonblocking(true).unwrap();
            s.bind(&"127.0.0.1:0".parse::<SocketAddr>().unwrap().into()).unwrap();
            UdpSocket::from_std(s.into()).unwrap()
        };
        let local = sock.local_addr().unwrap();
        let mut rtc = Rtc::builder().set_sctp_max_buffered_amount(1 << 20).build(Instant::now());
        rtc.add_local_candidate(Candidate::host(local, "udp").unwrap());
        let mut api = rtc.sdp_api();
        api.add_channel("ctl".into());
        api.add_channel("media".into());
        let (offer, pending) = api.apply().unwrap();
        let offer = offer.to_sdp_string();
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{signal}/signal/{ROOM}")).await.unwrap();
        ws.send(Message::text(json!({"t": "browser-join", "v": 2, "join": "rRaYJs5-07URNfm3gxhQ2HtP8i4RLTQ_J4wsbiDMdL4"}).to_string())).await.unwrap();
        let joined = next_json(&mut ws).await;
        assert_eq!(joined["mac"], true);
        ws.send(Message::text(json!({"t": "offer", "sdp": offer}).to_string())).await.unwrap();
        let answer = loop {
            let v = next_json(&mut ws).await;
            if v["t"] == "answer" { break v }
        };
        assert!(answer.get("peer").is_none(), "the DO strips peer");
        let sdp = answer["sdp"].as_str().unwrap();
        rtc.sdp_api().accept_answer(pending, SdpAnswer::from_sdp_string(sdp).unwrap()).unwrap();
        let mut b = Browser { rtc, sock, local, ctl: None, media: None, fp_mine: fingerprint(&offer), fp_mac: fingerprint(sdp),
            inbox: VecDeque::new(), bufs: HashMap::new(), part: String::new(), parts_seen: 0, up_acked: HashMap::new(), next_id: 1, deadline: Instant::now() };
        b.drain().await;
        let end = Instant::now() + T;
        while b.ctl.is_none() || b.media.is_none() {
            assert!(Instant::now() < end, "channels never opened");
            b.step().await;
        }
        // The page closes its signaling socket once connected.
        let _ = ws.close(None).await;
        b
    }

    async fn drain(&mut self) {
        loop {
            match self.rtc.poll_output().unwrap() {
                Output::Timeout(t) => return self.deadline = t,
                Output::Transmit(t) => { let _ = self.sock.send_to(&t.contents, t.destination).await; }
                Output::Event(e) => match e {
                    Event::ChannelOpen(id, label) if label == "ctl" => self.ctl = Some(id),
                    Event::ChannelOpen(id, label) if label == "media" => self.media = Some(id),
                    Event::ChannelData(d) if Some(d.id) == self.ctl => {
                        assert!(d.data.len() <= 256 * 1024, "a ctl message over Chrome's 256 KiB: {}", d.data.len());
                        let v: Value = serde_json::from_slice(&d.data).unwrap();
                        if v["t"] == "part" {
                            // {"t":"part","re"?,"n","of","data"}: join the data, in order, then parse.
                            assert_eq!(v["n"].as_u64().unwrap() as usize, self.parts_seen, "parts in order");
                            self.part.push_str(v["data"].as_str().unwrap());
                            self.parts_seen += 1;
                            if self.parts_seen as u64 == v["of"].as_u64().unwrap() {
                                let whole: Value = serde_json::from_str(&std::mem::take(&mut self.part)).unwrap();
                                assert_eq!(whole.get("re"), v.get("re"));
                                self.parts_seen = 0;
                                self.inbox.push_back(json!({"parts": v["of"], "msg": whole}));
                            }
                        } else {
                            self.inbox.push_back(v);
                        }
                    }
                    Event::ChannelData(d) if Some(d.id) == self.media && !d.binary => {
                        let v: Value = serde_json::from_slice(&d.data).unwrap();
                        assert_eq!(v["t"], "upload-ack", "{v}");
                        self.up_acked.insert(v["upload"].as_u64().unwrap() as u32, v["bytes"].as_u64().unwrap());
                    }
                    Event::ChannelData(d) if Some(d.id) == self.media => {
                        assert!(d.binary && d.data.len() <= 65_536 && d.data.len() > 8);
                        let fetch = u32::from_be_bytes(d.data[0..4].try_into().unwrap());
                        let seq = u32::from_be_bytes(d.data[4..8].try_into().unwrap());
                        let (buf, acked, next) = self.bufs.entry(fetch).or_default();
                        assert_eq!(seq, *next, "frames in order, seq from 0");
                        *next += 1;
                        buf.extend_from_slice(&d.data[8..]);
                        if buf.len() as u64 - *acked >= 2 << 20 {
                            *acked = buf.len() as u64;
                            let ack = json!({"t": "ack", "fetch": fetch, "bytes": *acked}).to_string();
                            let mid = self.media.unwrap();
                            assert!(self.rtc.channel(mid).unwrap().write(false, ack.as_bytes()).unwrap());
                        }
                    }
                    _ => {}
                },
            }
        }
    }

    async fn step(&mut self) {
        let mut buf = vec![0u8; 2048];
        let wait = self.deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
        let input = match tokio::time::timeout(wait, self.sock.recv_from(&mut buf)).await {
            Ok(Ok((n, src))) => Some((n, src)),
            _ => None,
        };
        let now = Instant::now();
        match input {
            Some((n, src)) => {
                let r = Receive { proto: Protocol::Udp, source: src, destination: self.local, contents: buf[..n].try_into().unwrap() };
                self.rtc.handle_input(Input::Receive(now, r)).unwrap();
            }
            None => self.rtc.handle_input(Input::Timeout(now)).unwrap(),
        }
        self.drain().await;
    }

    async fn send(&mut self, v: Value) {
        let id = self.ctl.unwrap();
        assert!(self.rtc.channel(id).unwrap().write(false, v.to_string().as_bytes()).unwrap());
        self.drain().await;
    }

    async fn next(&mut self, what: impl Fn(&Value) -> bool) -> Value {
        let end = Instant::now() + T;
        loop {
            if let Some(i) = self.inbox.iter().position(|m| what(m) || m.get("parts").is_some() && what(&m["msg"])) {
                let m = self.inbox.remove(i).unwrap();
                return if m.get("parts").is_some() { let mut w = m["msg"].clone(); w["_parts"] = m["parts"].clone(); w } else { m };
            }
            assert!(Instant::now() < end, "timed out waiting on ctl");
            self.step().await;
        }
    }

    /// A request with an id; waits for its reply.
    async fn call(&mut self, mut v: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        v["id"] = json!(id);
        self.send(v).await;
        self.next(|m| m["re"] == id).await
    }

    async fn bytes(&mut self, fetch: u32, size: u64) -> Vec<u8> {
        let end = Instant::now() + T;
        while self.bufs.get(&fetch).map_or(0, |b| b.0.len() as u64) < size {
            assert!(Instant::now() < end, "fetch {fetch} stalled");
            self.step().await;
        }
        let (b, _, _) = self.bufs.remove(&fetch).unwrap();
        assert_eq!(b.len() as u64, size);
        b
    }

    /// Upload frames on `media` (u32 upload id, u32 seq, ≤ 65,528 bytes), never more than `credit` unacked.
    async fn upload(&mut self, id: u32, data: &[u8], credit: u64) {
        let (mut sent, mut seq) = (0usize, 0u32);
        let end = Instant::now() + T;
        while sent < data.len() {
            assert!(Instant::now() < end, "upload {id} stalled at {sent}");
            let n = (data.len() - sent).min(65_528);
            let acked = self.up_acked.get(&id).copied().unwrap_or(0);
            let mid = self.media.unwrap();
            if (sent + n) as u64 - acked > credit || self.rtc.channel(mid).unwrap().buffered_amount() > 512 << 10 {
                self.step().await;
                continue;
            }
            let mut f = Vec::with_capacity(8 + n);
            f.extend(id.to_be_bytes());
            f.extend(seq.to_be_bytes());
            f.extend(&data[sent..sent + n]);
            if self.rtc.channel(mid).unwrap().write(true, &f).unwrap() {
                (sent, seq) = (sent + n, seq + 1);
                self.drain().await;
            } else {
                self.step().await;
            }
        }
        while self.up_acked.get(&id).copied().unwrap_or(0) < data.len() as u64 {
            assert!(Instant::now() < end, "upload {id}: no final ack");
            self.step().await;
        }
    }

    /// hello (signed by the room's key, checked before anything is sent) → auth (proof over both
    /// fingerprints) → welcome (check the Mac's proof).
    async fn auth(&mut self, name: &str) -> Value {
        let hello = self.next(|m| m["t"] == "hello").await;
        assert!(hello_ok(&hello, &self.fp_mac, &self.fp_mine), "hello signed by the room key: {hello}");
        let mac_nonce = B64.decode(hello["nonce"].as_str().unwrap()).unwrap();
        let mine: [u8; 32] = rand::random();
        let p = proof("browser", &mac_nonce, &mine, &self.fp_mac, &self.fp_mine);
        let w = self.call(json!({"t": "auth", "v": 2, "nonce": B64.encode(mine), "proof": p,
            "token": B64.encode(rand::random::<[u8; 32]>()), "name": name})).await;
        assert_eq!(w["t"], "welcome", "{w}");
        assert_eq!(w["proof"].as_str().unwrap(), proof("mac", &mac_nonce, &mine, &self.fp_mac, &self.fp_mine), "Mac proof");
        w
    }
}

async fn next_json<S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin>(ws: &mut S) -> Value {
    loop {
        if let Some(Ok(Message::Text(t))) = tokio::time::timeout(T, ws.next()).await.unwrap() {
            return serde_json::from_str(&t).unwrap();
        }
    }
}

// ---- the helper process ----

struct Helper {
    _child: Child,
    stdin: ChildStdin,
    out: mpsc::UnboundedReceiver<Value>,
}

impl Helper {
    async fn start(settings: Value) -> Helper {
        let mut child = Command::new(env!("CARGO_BIN_EXE_pluck-review")).stdin(Stdio::piped()).stdout(Stdio::piped())
            .env("PLUCK_STANDBY_SECS", "1").kill_on_drop(true).spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(format!("{settings}\n").as_bytes()).await.unwrap();
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let (tx, out) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Ok(Some(l)) = lines.next_line().await {
                if std::env::var("PLUCK_REVIEW_TEST_LOG").is_ok() { eprintln!("helper: {l}") }
                let _ = tx.send(serde_json::from_str::<Value>(&l).unwrap());
            }
        });
        Helper { _child: child, stdin, out }
    }

    async fn line(&mut self, v: Value) {
        self.stdin.write_all(format!("{v}\n").as_bytes()).await.unwrap();
    }

    async fn wait(&mut self, what: impl Fn(&Value) -> bool) -> Value {
        loop {
            let v = tokio::time::timeout(T, self.out.recv()).await.expect("helper silent").expect("helper exited");
            if what(&v) { return v }
        }
    }
}

fn random_file(path: &Path, len: usize) -> Vec<u8> {
    let mut s = 0x1234_5678u64;
    let data: Vec<u8> = (0..len).map(|_| { s ^= s << 13; s ^= s >> 7; s ^= s << 17; s as u8 }).collect();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, &data).unwrap();
    data
}

fn tmp(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("pluck-review-e2e-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Swift's side over stdin/stdout, faked: hello/auth/welcome/ready, then a 20 MB serve.
#[tokio::test(flavor = "multi_thread")]
async fn stdin_protocol_end_to_end() {
    str0m::crypto::from_feature_flags().install_process_default();
    let signal = signaling().await;
    let dir = tmp("stdin");
    let file = dir.join("media.m4s");
    let data = random_file(&file, 20 << 20);
    let mut h = Helper::start(json!({"signal": format!("ws://{signal}/signal"), "stun": [], "local": true, "maxPeers": 20,
        "rooms": [{"room": ROOM, "reg": REG, "join": JOIN}]})).await;
    h.wait(|v| v["room"]["state"] == "active").await;

    let mut b = Browser::connect(signal).await;
    let open = h.wait(|v| v["peer"]["state"] == "open").await["peer"].clone();
    let peer = open["peer"].as_str().unwrap().to_owned();
    assert_eq!(open["fpLocal"].as_str().unwrap(), b.fp_mac, "fpLocal = the Mac's fingerprint the browser sees");
    assert_eq!(open["fpRemote"].as_str().unwrap(), b.fp_mine);
    assert_eq!(open["path"], "direct");
    let mac_nonce = [1u8; 32];
    // A link holder (it knows authKey, not the room seed) can't make a hello the browser accepts.
    let forged = json!({"t": "hello", "v": 2, "nonce": B64.encode(mac_nonce), "sig": sign_hello(&B64.encode([7u8; 32]), &mac_nonce, &b.fp_mac, &b.fp_mine)});
    assert!(!hello_ok(&forged, &b.fp_mac, &b.fp_mine), "a forged hello is refused");
    let sig = sign_hello(SEED, &mac_nonce, &b.fp_mac, &b.fp_mine);
    h.line(json!({"send": {"peer": peer, "msg": {"t": "hello", "v": 2, "nonce": B64.encode(mac_nonce), "sig": sig}}})).await;

    // Swift's task: answer auth with the proof, and the fetch with a serve.
    let browser = async {
        b.auth("Anna").await;
        let r = b.call(json!({"t": "fetch", "what": "segment"})).await;
        let got = b.bytes(r["fetch"].as_u64().unwrap() as u32, r["size"].as_u64().unwrap()).await;
        assert_eq!(Sha256::digest(&got), Sha256::digest(&data), "20 MB arrived intact");
        b
    };
    let swift = async {
        let auth = h.wait(|v| v["msg"]["msg"]["t"] == "auth").await["msg"]["msg"].clone();
        let br_nonce = B64.decode(auth["nonce"].as_str().unwrap()).unwrap();
        let fp = (open["fpLocal"].as_str().unwrap(), open["fpRemote"].as_str().unwrap());
        assert_eq!(auth["proof"].as_str().unwrap(), proof("browser", &mac_nonce, &br_nonce, fp.0, fp.1), "browser proof");
        h.line(json!({"send": {"peer": peer, "msg": {"re": auth["id"], "t": "welcome", "needPassword": false,
            "proof": proof("mac", &mac_nonce, &br_nonce, fp.0, fp.1)}}})).await;
        let f = h.wait(|v| v["msg"]["msg"]["t"] == "fetch").await["msg"]["msg"].clone();
        let id = f["id"].as_u64().unwrap();
        h.line(json!({"send": {"peer": peer, "msg": {"re": id, "fetch": id, "size": data.len(), "type": "video/mp4"}}})).await;
        h.line(json!({"serve": {"peer": peer, "fetch": id, "path": file.to_string_lossy(), "offset": 0, "length": data.len()}})).await;
        let s = h.wait(|v| v.get("served").is_some()).await;
        assert_eq!(s["served"]["result"], "done");
        assert_eq!(s["served"]["bytes"], data.len());
        // Limits: a 5th serve beyond 4 in flight, an unknown peer, a >256 KiB message.
        h.line(json!({"serve": {"peer": "p_nobody", "fetch": 99, "path": "/etc/hosts", "offset": 0, "length": 1}})).await;
        assert_eq!(h.wait(|v| v.get("served").is_some()).await["served"]["result"], "error");
        h.line(json!({"close": {"peer": peer, "reason": "revoked"}})).await;
        h.wait(|v| v["peer"]["state"] == "closed").await;
    };
    tokio::join!(browser, swift);
    let _ = std::fs::remove_dir_all(dir);
}

/// Host mode: the helper alone serves a bundle to two browsers at once, with password, scope
/// checks, comments pushed live to the other viewer, and the comment pulled back over stdin.
#[tokio::test(flavor = "multi_thread")]
async fn host_mode_end_to_end() {
    str0m::crypto::from_feature_flags().install_process_default();
    let signal = signaling().await;
    let data_dir = tmp("host");
    let b = data_dir.join("bundle");
    let seg = 4 << 20;
    let media = random_file(&b.join("copies/V1/1080/media.m4s"), 5 * seg);
    let init = random_file(&b.join("copies/V1/1080/init.mp4"), 1403);
    let segs: Vec<Value> = (0..5).map(|i| json!({"t": i * 2, "d": 2, "file": "media.m4s", "offset": i * seg, "length": seg})).collect();
    std::fs::write(b.join("copies/V1/1080/index.json"), json!({"codecs": "avc1.64002a", "duration": 10.0, "fpsNum": 25, "fpsDen": 1,
        "width": 1920, "height": 1080, "init": {"file": "init.mp4", "offset": 0, "length": 1403}, "segments": segs}).to_string()).unwrap();
    let salt = [3u8; 16];
    let mut hash = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(b"test", &salt, 1000, &mut hash);
    let version = json!({"id": "V1", "number": 1, "added": "2026-11-14T10:00:00Z", "duration": 10.0, "fpsNum": 25, "fpsDen": 1,
        "width": 1920, "height": 1080, "startTimecode": "01:00:00:00", "dropFrame": false, "frames": 250, "renditions": ["1080"], "size": 0});
    std::fs::write(b.join("manifest.json"), json!({"format": 1,
        "links": [{"id": "L1", "roomID": ROOM, "reg": REG, "auth": AUTH, "sign": SEED, "join": JOIN, "title": "Cuts", "mode": "review", "allowDownload": false,
                   "latestOnly": false, "expires": null, "revoked": null,
                   "passwordHash": format!("pbkdf2-sha256$1000${}${}", B64.encode(salt), B64.encode(hash)),
                   "project": "P1", "root": {"kind": "project", "id": "P1", "name": "Spring"}}],
        "projects": [
            {"id": "P1", "name": "Spring", "folders": [{"id": "F1", "name": "Socials", "parent": null}],
             "assets": [{"id": "A1", "name": "Hero 30s", "folder": null, "kind": "video", "status": "needsReview", "versions": [version]},
                        {"id": "A2", "name": "Cutdown", "folder": "F1", "kind": "video", "status": "none", "versions": []}]},
            {"id": "P2", "name": "Other", "folders": [], "assets": [{"id": "A9", "name": "Secret", "folder": null, "kind": "video", "versions": []}]}]
    }).to_string()).unwrap();

    let mut h = Helper::start(json!({"signal": format!("ws://{signal}/signal"), "stun": [], "local": true,
        "host": {"dir": data_dir.to_string_lossy()}})).await;
    h.wait(|v| v["room"]["state"] == "active").await;

    let mut b1 = Browser::connect(signal).await;
    let mut b2 = Browser::connect(signal).await;
    for (b, name) in [(&mut b1, "Anna"), (&mut b2, "Ben")] {
        assert_eq!(b.auth(name).await["needPassword"], true);
        assert_eq!(b.call(json!({"t": "list", "folder": null})).await["error"]["code"], "auth", "nothing before the password");
        assert_eq!(b.call(json!({"t": "password", "password": "wrong"})).await["error"]["code"], "password");
        let r = b.call(json!({"t": "password", "password": "test"})).await;
        assert_eq!(r["t"], "ready", "{r}");
        assert_eq!(r["link"]["title"], "Cuts");
    }
    let list = b1.call(json!({"t": "list", "folder": null})).await;
    assert_eq!(list["folders"][0]["name"], "Socials");
    assert_eq!(list["assets"][0]["current"]["id"], "V1");
    assert_eq!(b1.call(json!({"t": "list", "folder": "F1"})).await["assets"][0]["id"], "A2");
    assert_eq!(b1.call(json!({"t": "asset", "asset": "A9"})).await["error"]["code"], "scope", "another project's asset");
    let bad = json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "../", "rendition": "1080"});
    assert_eq!(b1.call(bad).await["error"]["code"], "invalid");
    let bad = json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "segment", "rendition": "../../x", "n": 0});
    assert_eq!(b1.call(bad).await["error"]["code"], "invalid");
    assert_eq!(b1.call(json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "original"})).await["error"]["code"], "scope");
    let idx = b1.call(json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "index", "rendition": "1080"})).await;
    assert_eq!(idx["json"]["segments"].as_array().unwrap().len(), 5);

    // Both viewers stream every segment at the same time.
    async fn all(b: &mut Browser, media: &[u8], init: &[u8]) {
        let r = b.call(json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "init", "rendition": "1080"})).await;
        assert_eq!(b.bytes(r["fetch"].as_u64().unwrap() as u32, 1403).await, init);
        let mut got = vec![];
        for n in 0..5 {
            let r = b.call(json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "segment", "rendition": "1080", "n": n})).await;
            assert_eq!(r["type"], "video/mp4");
            got.extend(b.bytes(r["fetch"].as_u64().unwrap() as u32, r["size"].as_u64().unwrap()).await);
        }
        assert_eq!(Sha256::digest(&got), Sha256::digest(media));
    }
    let started = Instant::now();
    tokio::join!(all(&mut b1, &media, &init), all(&mut b2, &media, &init));
    eprintln!("2 viewers × 20 MiB over loopback in {:.2?}", started.elapsed());

    // A comment from one viewer reaches the other live, and the editor can pull it.
    let add = json!({"t": "comment-add", "asset": "A1", "version": "V1", "frame": 120, "endFrame": null, "text": "Logo too early",
        "drawing": {"strokes": [{"tool": "arrow", "colour": "#E0605E", "width": 0.004, "points": [[0.41, 0.30], [0.52, 0.38]]}]}});
    let c = b1.call(add).await;
    assert_eq!(c["comment"]["mine"], true, "{c}");
    assert!(c["comment"].get("authorToken").is_none() && c["comment"].get("link").is_none());
    let ev = b2.next(|m| m["t"] == "comment").await;
    assert_eq!(ev["comment"]["text"], "Logo too early");
    assert_eq!(ev["comment"]["mine"], false);
    let cid = c["comment"]["id"].clone();
    assert_eq!(b2.call(json!({"t": "comment-edit", "comment": cid, "text": "x"})).await["error"]["code"], "scope", "not Ben's comment");
    assert_eq!(b1.call(json!({"t": "comment-add", "asset": "A1", "version": "V1", "frame": 250, "text": "past the end"})).await["error"]["code"], "invalid");
    let ap = b2.call(json!({"t": "approve", "asset": "A1", "version": "V1", "decision": "approve"})).await;
    assert_eq!(ap["status"], "approved");
    assert_eq!(b1.next(|m| m["t"] == "status").await["by"], "Ben");
    h.line(json!({"host": {"op": "pull", "since": 0}})).await;
    let pulled = h.wait(|v| v["host"]["entries"].is_array()).await;
    let all = pulled["host"]["entries"].as_array().unwrap();
    let opened: Vec<&Value> = all.iter().filter(|e| e["activity"]["kind"] == "opened").collect();
    assert_eq!(opened.len(), 2, "both viewers' visits are in the activity log");
    assert!(opened.iter().any(|e| e["activity"]["name"] == "Anna") && opened[0]["activity"]["link"] == "L1");
    let e: Vec<&Value> = all.iter().filter(|e| e.get("activity").is_none()).collect();
    assert_eq!(e[0]["comment"]["text"], "Logo too early");
    assert!(e[0]["comment"]["authorToken"].is_string(), "the editor gets the token hash");
    assert_eq!(e[1]["approval"]["decision"], "approve");
    assert!(std::fs::read_to_string(data_dir.join("comments.jsonl")).unwrap().contains("Logo too early"));

    // Turning the link off ends both sessions.
    let mut m: Value = serde_json::from_slice(&std::fs::read(b.join("manifest.json")).unwrap()).unwrap();
    m["links"][0]["revoked"] = json!("2026-11-15T12:00:00Z");
    std::fs::write(b.join("manifest.json"), m.to_string()).unwrap();
    h.line(json!({"host": {"op": "reload"}})).await;
    assert_eq!(b1.next(|m| m["t"] == "bye").await["code"], "revoked");
    h.wait(|v| v["peer"]["state"] == "closed").await;
    let _ = std::fs::remove_dir_all(data_dir);
}

/// Publish by reference: a clip on a read-only media root is published by path; the host makes
/// the §2 review copies itself with ffmpeg, and the link it makes derives its room from its key.
/// Skipped when ffmpeg isn't installed.
#[tokio::test(flavor = "multi_thread")]
async fn host_makes_review_copies() {
    if std::process::Command::new("ffmpeg").arg("-version").output().is_err() {
        eprintln!("ffmpeg not installed: skipped");
        return;
    }
    let base = tmp("copies");
    let (media, data) = (base.join("media"), base.join("data"));
    std::fs::create_dir_all(media.join("Renders")).unwrap();
    let clip = media.join("Renders/Hero 30s.mov");
    let ok = std::process::Command::new("ffmpeg").args(["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25:duration=5",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=5", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
        .arg(&clip).status().unwrap();
    assert!(ok.success());
    let signal = signaling().await;
    let mut h = Helper::start(json!({"signal": format!("ws://{signal}/signal"), "stun": [], "local": true,
        "host": {"dir": data.to_string_lossy(), "media": [format!("nas1={}", media.display())]}})).await;
    h.line(json!({"host": {"op": "admin-publish", "newProject": "Spring", "files": ["nas1/Renders/Hero 30s.mov", "nas1/../etc/passwd"],
        "link": {"title": "Cuts", "expiresDays": 7}}})).await;
    let r = h.wait(|v| v["host"]["ok"] == true).await["host"].clone();
    assert_eq!(r["added"], 1);
    assert_eq!(r["skipped"][0], "nas1/../etc/passwd");
    let url = r["url"].as_str().unwrap();
    // Protocol 3 (§13.24): https://pluck.tools/r/#<12 base62>; roomId comes from the code, never in the link.
    let code = url.strip_prefix("https://pluck.tools/r/#").expect("level 3 link");
    assert!(code.len() == 12 && code.bytes().all(|b| b.is_ascii_alphanumeric()), "{url}");
    let hk = |salt: &[u8], ikm: &[u8], info: &[u8], n: usize| { let mut o = vec![0u8; n]; hkdf::Hkdf::<Sha256>::new(Some(salt), ikm).expand(info, &mut o).unwrap(); o };
    let mut key = vec![0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(code.as_bytes(), b"pluck-link-v3", 300_000, &mut key); // §13.24 linkKey
    let room = B64.encode(hk(b"pluck-review/1", &key, b"room", 16));
    let manifest = std::fs::read_to_string(data.join("bundle/manifest.json")).unwrap();
    assert!(!manifest.contains(code) && !manifest.contains(&B64.encode(&key)), "the host never stores the code or the link key");
    let ml: Value = serde_json::from_str(&manifest).unwrap();
    assert_eq!(ml["links"][0]["roomID"], room.as_str());
    let reg_from_key = B64.encode(hk(b"pluck-review/1", &key, b"register", 32));
    assert_ne!(ml["links"][0]["reg"].as_str().unwrap(), reg_from_key, "a link holder can't derive the registration secret");
    assert!(ml["links"][0]["level"] == 3 && ml["links"][0]["sign"].is_null() && ml["links"][0]["join"].is_string());
    let done = tokio::time::timeout(Duration::from_secs(240), h.wait(|v| v["copy"]["state"] == "ready" || v["copy"]["state"] == "failed")).await.unwrap();
    assert_eq!(done["copy"]["state"], "ready", "{done}");
    let vid = done["copy"]["version"].as_str().unwrap();
    let dir = data.join("bundle/copies").join(vid);
    let ready: Value = serde_json::from_slice(&std::fs::read(dir.join("ready.json")).unwrap()).unwrap();
    assert_eq!(ready["renditions"], json!(["1080", "540", "360"]));
    assert_eq!(ready["probe"]["frames"], 125);
    for (r, w, codecs) in [("1080", 1280, "avc1.64002a,mp4a.40.2"), ("540", 960, "avc1.640020,mp4a.40.2"), ("360", 640, "avc1.64001f,mp4a.40.2")] {
        let idx: Value = serde_json::from_slice(&std::fs::read(dir.join(r).join("index.json")).unwrap()).unwrap();
        assert_eq!(idx["width"], w, "720p source: 1080 made at 720, 540 at 960×540, 360 at 640×360");
        assert_eq!(idx["codecs"], codecs);
        let segs = idx["segments"].as_array().unwrap();
        assert!(segs.len() >= 2, "2 s segments");
        let m4s = std::fs::read(dir.join(r).join("media.m4s")).unwrap();
        let last = segs.last().unwrap();
        assert_eq!(last["offset"].as_u64().unwrap() + last["length"].as_u64().unwrap(), m4s.len() as u64, "ranges cover media.m4s");
        let init = std::fs::read(dir.join(r).join(idx["init"]["file"].as_str().unwrap())).unwrap();
        assert_eq!(&init[4..8], b"ftyp");
    }
    assert!(dir.join("poster.jpg").exists() && dir.join("strip.jpg").exists());
    h.line(json!({"host": {"op": "admin-state"}})).await;
    let st = h.wait(|v| v["host"]["projects"].is_array()).await;
    assert_eq!(st["host"]["projects"][0]["assets"][0]["versions"][0]["ready"], true);
    assert!(st["host"]["links"][0].get("auth").is_none(), "no secrets in the admin state");
    let _ = std::fs::remove_dir_all(base);
}

/// Host mode, the Frame.io-parity additions over a real data channel: a JSON answer too big for
/// one SCTP message arrives in parts, a proxy download is the init and the media served as one
/// fetch, and an upload goes browser → host in frames with credit, becomes a comment attachment,
/// and comes back as a fetch. The editor pulls the upload and the activity.
#[tokio::test(flavor = "multi_thread")]
async fn host_parity_end_to_end() {
    str0m::crypto::from_feature_flags().install_process_default();
    let signal = signaling().await;
    let data_dir = tmp("parity");
    let b = data_dir.join("bundle");
    let media = random_file(&b.join("copies/V1/1080/media.m4s"), 3 << 20);
    let init = random_file(&b.join("copies/V1/1080/init.mp4"), 1403);
    std::fs::write(b.join("copies/V1/1080/index.json"), json!({"init": {"file": "init.mp4", "offset": 0, "length": 1403},
        "segments": [{"t": 0, "d": 2, "file": "media.m4s", "offset": 0, "length": 1 << 20}, {"t": 2, "d": 4, "file": "media.m4s", "offset": 1 << 20, "length": 2 << 20}]}).to_string()).unwrap();
    let words: Vec<Value> = (0..20_000).map(|i| json!([i as f64 * 0.25, i as f64 * 0.25 + 0.125, format!("word\"{i}")])).collect();
    let transcript = json!({"lang": "en", "words": words});
    std::fs::write(b.join("copies/V1/transcript.json"), transcript.to_string()).unwrap();
    assert!(transcript.to_string().len() > 600 * 1024);
    std::fs::write(b.join("manifest.json"), json!({"format": 1,
        "links": [{"id": "L1", "roomID": ROOM, "reg": REG, "auth": AUTH, "sign": SEED, "join": JOIN, "title": "Cuts", "mode": "review", "expires": null, "revoked": null,
                   "project": "P1", "root": {"kind": "project", "id": "P1", "name": "Spring"}, "allowProxy": true, "requireName": true,
                   "uploads": {"folder": null, "maxBytes": 100 << 20, "types": ["image", "video"]}}],
        "projects": [{"id": "P1", "name": "Spring", "folders": [], "assets": [{"id": "A1", "name": "Hero", "kind": "video", "folder": null,
            "versions": [{"id": "V1", "number": 3, "frames": 150, "fpsNum": 25, "fpsDen": 1, "renditions": ["1080"]}]}]}]}).to_string()).unwrap();
    let mut h = Helper::start(json!({"signal": format!("ws://{signal}/signal"), "stun": [], "local": true,
        "host": {"dir": data_dir.to_string_lossy()}})).await;
    h.wait(|v| v["room"]["state"] == "active").await;
    let mut br = Browser::connect(signal).await;
    assert_eq!(br.auth("").await["needPassword"], false);
    let ready = br.next(|m| m["t"] == "ready").await;
    assert_eq!((&ready["link"]["allowProxy"], &ready["link"]["requireName"]), (&json!(true), &json!(true)), "{ready}");
    assert_eq!(br.call(json!({"t": "list", "folder": null})).await["error"]["code"], "auth", "a name first");
    assert_eq!(br.call(json!({"t": "identify", "name": "Anna", "email": "anna@example.com"})).await["ok"], true);

    // 700 KB of transcript: several parts, each under 256 KiB, joined into the one answer.
    let t = br.call(json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "transcript"})).await;
    assert!(t["_parts"].as_u64().unwrap() >= 3, "came in parts");
    assert_eq!(t["json"], transcript);

    // The proxy: one MP4 from two pieces.
    let r = br.call(json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "proxy"})).await;
    assert_eq!(r["name"], "Hero v3 (review).mp4");
    let got = br.bytes(r["fetch"].as_u64().unwrap() as u32, r["size"].as_u64().unwrap()).await;
    assert_eq!(Sha256::digest(&got), Sha256::digest([init.as_slice(), media.as_slice()].concat()));

    // An attachment upload of 20 MB (several credit windows), then on a comment, then fetched back.
    let file = { let mut s = 7u64; (0..20 << 20).map(|_| { s ^= s << 13; s ^= s >> 7; s ^= s << 17; s as u8 }).collect::<Vec<u8>>() };
    assert_eq!(br.call(json!({"t": "upload-begin", "name": "ref.exe", "size": 10, "for": "attachment"})).await["error"]["code"], "invalid");
    assert_eq!(br.call(json!({"t": "upload-begin", "name": "ref.png", "size": 60 << 20, "for": "attachment"})).await["error"]["code"], "tooLarge");
    let up = br.call(json!({"t": "upload-begin", "name": "ref.png", "size": file.len(), "for": "attachment"})).await;
    let (uid, credit) = (up["upload"].as_u64().unwrap(), up["credit"].as_u64().unwrap());
    assert_eq!(credit, 8 << 20, "{up}");
    br.upload(uid as u32, &file, credit).await;
    let done = br.call(json!({"t": "upload-end", "upload": uid, "sha256": B64.encode(Sha256::digest(&file))})).await;
    let att = done["attachment"].clone();
    assert_eq!((&att["name"], &att["size"]), (&json!("ref.png"), &json!(file.len())), "{done}");
    let c = br.call(json!({"t": "comment-add", "asset": "A1", "version": "V1", "frame": null, "text": "Like this", "attachments": [att["id"]]})).await;
    assert_eq!(c["comment"]["attachments"][0]["id"], att["id"], "{c}");
    let r = br.call(json!({"t": "fetch", "asset": "A1", "version": "V1", "what": "attachment", "attachment": att["id"]})).await;
    assert_eq!((&r["type"], &r["name"]), (&json!("image/png"), &json!("ref.png")), "{r}");
    let back = br.bytes(r["fetch"].as_u64().unwrap() as u32, r["size"].as_u64().unwrap()).await;
    assert!(back == file, "the attachment comes back intact");
    // A second upload, cancelled half way: no file left behind.
    let up = br.call(json!({"t": "upload-begin", "name": "b.mov", "size": 4 << 20, "for": "asset"})).await;
    br.upload(up["upload"].as_u64().unwrap() as u32, &file[..1 << 20], 8 << 20).await;
    br.send(json!({"t": "cancel", "upload": up["upload"]})).await;

    // The editor pulls the upload and the activity (opened, the proxy download, the upload, the comment).
    let pulled = loop {
        h.line(json!({"host": {"op": "pull", "since": 0}})).await;
        let p = h.wait(|v| v["host"]["entries"].is_array()).await;
        if p["host"]["entries"].as_array().unwrap().iter().any(|e| e["activity"]["kind"] == "downloaded") { break p }
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    let e = pulled["host"]["entries"].as_array().unwrap();
    let u = e.iter().find_map(|e| e.get("upload")).unwrap();
    assert_eq!((&u["for"], &u["size"], &u["sha256"]), (&json!("attachment"), &json!(file.len()), &json!(B64.encode(Sha256::digest(&file)))));
    assert_eq!(std::fs::read(data_dir.join(u["path"].as_str().unwrap())).unwrap().len(), file.len());
    let kinds: Vec<&str> = e.iter().filter_map(|e| e["activity"]["kind"].as_str()).collect();
    for k in ["opened", "downloaded", "uploaded", "commented"] {
        assert!(kinds.contains(&k), "{k} in {kinds:?}");
    }
    assert!(e.iter().any(|e| e["activity"]["email"] == "anna@example.com"));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let partial: Vec<_> = std::fs::read_dir(data_dir.join("uploads/.partial")).unwrap().collect();
    assert!(partial.is_empty(), "the cancelled upload's partial file is gone");
    let _ = std::fs::remove_dir_all(data_dir);
}

/// The same against a real, windowless Chromium (Playwright's chrome-headless-shell), when
/// PLUCK_REVIEW_BROWSER points at it: `cargo test --release -- --ignored real_browser`.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn real_browser() {
    let Ok(browser) = std::env::var("PLUCK_REVIEW_BROWSER") else { return eprintln!("PLUCK_REVIEW_BROWSER not set: skipped") };
    str0m::crypto::from_feature_flags().install_process_default();
    let signal = signaling().await;
    let data_dir = tmp("browser");
    let b = data_dir.join("bundle");
    let (seg, n) = (4u64 << 20, 6u64);
    let media = random_file(&b.join("copies/V1/1080/media.m4s"), (n * seg) as usize);
    let segs: Vec<Value> = (0..n).map(|i| json!({"t": i * 2, "d": 2, "file": "media.m4s", "offset": i * seg, "length": seg})).collect();
    std::fs::write(b.join("copies/V1/1080/index.json"), json!({"init": {"file": "media.m4s", "offset": 0, "length": 1}, "segments": segs}).to_string()).unwrap();
    let words: Vec<Value> = (0..20_000).map(|i| json!([i, i, format!("word{i}")])).collect();
    std::fs::write(b.join("copies/V1/transcript.json"), json!({"lang": "en", "words": words}).to_string()).unwrap();
    let salt = [3u8; 16];
    let mut hash = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<Sha256>(b"test", &salt, 1000, &mut hash);
    std::fs::write(b.join("manifest.json"), json!({"format": 1,
        "links": [{"id": "L1", "roomID": ROOM, "reg": REG, "auth": AUTH, "sign": SEED, "join": JOIN, "title": "Cuts", "mode": "review", "expires": null, "revoked": null,
                   "passwordHash": format!("pbkdf2-sha256$1000${}${}", B64.encode(salt), B64.encode(hash)),
                   "project": "P1", "root": {"kind": "project", "id": "P1", "name": "Spring"}, "uploads": {"folder": null, "types": ["image"]}}],
        "projects": [{"id": "P1", "name": "Spring", "folders": [], "assets": [{"id": "A1", "name": "Hero", "kind": "video", "folder": null,
            "versions": [{"id": "V1", "number": 1, "frames": 300, "renditions": ["1080"]}]}]}]}).to_string()).unwrap();
    let mut h = Helper::start(json!({"signal": format!("ws://{signal}/signal"), "stun": [], "local": true,
        "host": {"dir": data_dir.to_string_lossy()}})).await;
    h.wait(|v| v["room"]["state"] == "active").await;

    // A one-page web server on localhost (a secure context, so WebCrypto works).
    let web = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = web.local_addr().unwrap().port();
    let (res_tx, mut res_rx) = mpsc::unbounded_channel::<Value>();
    tokio::spawn(async move {
        loop {
            let (mut s, _) = web.accept().await.unwrap();
            let tx = res_tx.clone();
            tokio::spawn(async move {
                use tokio::io::AsyncReadExt;
                let mut buf = vec![0u8; 65536];
                let mut n = 0;
                loop {
                    let k = s.read(&mut buf[n..]).await.unwrap_or(0);
                    if k == 0 { break }
                    n += k;
                    let t = String::from_utf8_lossy(&buf[..n]);
                    if let Some(i) = t.find("\r\n\r\n") {
                        let len = t.lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0))).unwrap_or(0);
                        if n >= i + 4 + len {
                            let body = if t.starts_with("GET /page") { include_str!("browser/page.html").to_owned() } else {
                                let _ = tx.send(serde_json::from_str(&t[i + 4..i + 4 + len]).unwrap_or(json!({"error": "bad result"})));
                                String::new()
                            };
                            let _ = s.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await;
                            break;
                        }
                    }
                }
            });
        }
    });
    let profile = tmp("chrome-profile");
    let url = format!("http://localhost:{port}/page#{},{ROOM},{AUTH},{n},{PUB}", signal.port());
    let mut chrome = Command::new(browser).args(["--no-first-run", "--disable-gpu", "--disable-extensions", "--mute-audio"])
        .arg(format!("--user-data-dir={}", profile.display())).arg(url).stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true).spawn().unwrap();
    let r = tokio::time::timeout(Duration::from_secs(90), res_rx.recv()).await.expect("no result from the browser").unwrap();
    let _ = chrome.kill().await;
    eprintln!("browser: {r}");
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(r["sha"].as_str().unwrap(), B64.encode(Sha256::digest(&media)), "the browser got every byte");
    assert_eq!(r["words"], 20_000, "a ctl answer over Chrome's 256 KiB arrived in parts");
    assert!(r["parts"].as_u64().unwrap() >= 1);
    assert_eq!(r["attachment"], 3 << 20, "the upload went through");
    let _ = std::fs::remove_dir_all(data_dir);
    let _ = std::fs::remove_dir_all(profile);
}

/// A Mac refused because a host holds the room waits in "standby", then registers once the host is gone.
#[tokio::test]
async fn mac_stands_by_while_host_holds_the_room() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let (regs_tx, mut regs) = mpsc::unbounded_channel::<Value>();
    tokio::spawn(async move {
        let mut n = 0;
        loop {
            let (tcp, _) = l.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            let Some(Ok(Message::Text(t))) = ws.next().await else { continue };
            let v: Value = serde_json::from_str(&t).unwrap();
            regs_tx.send(v).unwrap();
            n += 1;
            let reply = if n == 1 { json!({"t": "taken", "by": "host"}) } else { json!({"t": "registered", "peers": []}) };
            ws.send(Message::text(reply.to_string())).await.unwrap();
            if n > 1 { tokio::spawn(async move { while ws.next().await.is_some() {} }); }
        }
    });
    let mut h = Helper::start(json!({"signal": format!("ws://{addr}/signal"), "stun": [], "local": true, "maxPeers": 20,
        "rooms": [{"room": ROOM, "reg": REG, "join": JOIN}]})).await;
    h.wait(|v| v["room"]["state"] == "standby").await;
    h.wait(|v| v["room"]["state"] == "active").await;
    let (first, second) = (regs.recv().await.unwrap(), regs.recv().await.unwrap());
    assert_eq!(first["prio"], "mac");
    assert_eq!(second["prio"], "mac");
}
