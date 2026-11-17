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

// ---- §13.25: uploads during an outage ----

fn iroh_bin() -> Option<std::path::PathBuf> {
    let base = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../PluckIroh/target");
    std::env::var("PLUCK_IROH_BIN").ok().map(Into::into).or_else(|| ["release", "debug"].iter().map(|d| base.join(d).join("pluck-iroh")).find(|p| p.is_file()))
}

/// A child speaking JSON lines (the host with flags, or pluck-iroh with its settings line).
struct Proc {
    child: Child,
    _stdin: ChildStdin,
    out: mpsc::UnboundedReceiver<Value>,
}

impl Proc {
    async fn start(bin: &Path, args: &[&str], settings: Option<Value>) -> Proc {
        let mut child = Command::new(bin).args(args).stdin(Stdio::piped()).stdout(Stdio::piped()).kill_on_drop(true)
            .env("PLUCK_IROH_LOCAL", "1").env("PLUCK_STANDBY_SECS", "1").env("PLUCK_REPLICA_ROUND_SECS", "1")
            .env("PLUCK_HEALTH_FILE", std::env::temp_dir().join(format!("pluck-e2e-health-{}", std::process::id()))).spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        if let Some(s) = settings {
            stdin.write_all(format!("{s}\n").as_bytes()).await.unwrap();
        }
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let (tx, out) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Ok(Some(l)) = lines.next_line().await {
                if std::env::var("PLUCK_REVIEW_TEST_LOG").is_ok() { eprintln!("proc: {l}") }
                if let Ok(v) = serde_json::from_str::<Value>(&l) { let _ = tx.send(v); }
            }
        });
        Proc { child, _stdin: stdin, out }
    }

    async fn wait(&mut self, what: impl Fn(&Value) -> bool) -> Value {
        loop {
            let v = tokio::time::timeout(T, self.out.recv()).await.expect("silent").expect("exited");
            if what(&v) { return v }
        }
    }

    fn signal(&self, sig: &str) {
        std::process::Command::new("kill").args([sig, &self.child.id().unwrap().to_string()]).status().unwrap();
    }
}

async fn ctl(data: &Path, op: Value) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_pluck-review")).arg("--ctl").arg(data).arg(op.to_string()).output().await.unwrap();
    serde_json::from_slice(&out.stdout).unwrap_or(Value::Null)
}

/// A sync session as Pluck opens one (TLS; the pin isn't what this test is about).
mod sync_client {
    use super::*;
    use tokio_rustls::rustls;

    #[derive(Debug)]
    struct Any(Arc<rustls::crypto::CryptoProvider>);
    impl rustls::client::danger::ServerCertVerifier for Any {
        fn verify_server_cert(&self, _: &rustls::pki_types::CertificateDer<'_>, _: &[rustls::pki_types::CertificateDer<'_>], _: &rustls::pki_types::ServerName<'_>, _: &[u8], _: rustls::pki_types::UnixTime) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(&self, m: &[u8], c: &rustls::pki_types::CertificateDer<'_>, d: &rustls::DigitallySignedStruct) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(m, c, d, &self.0.signature_verification_algorithms)
        }
        fn verify_tls13_signature(&self, m: &[u8], c: &rustls::pki_types::CertificateDer<'_>, d: &rustls::DigitallySignedStruct) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(m, c, d, &self.0.signature_verification_algorithms)
        }
        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }

    type S = tokio_rustls::client::TlsStream<tokio::net::TcpStream>;
    pub struct C(BufReader<tokio::io::ReadHalf<S>>, tokio::io::WriteHalf<S>);

    impl C {
        pub async fn open(addr: &str) -> C {
            let _ = rustls::crypto::ring::default_provider().install_default();
            let p = Arc::new(rustls::crypto::ring::default_provider());
            let cfg = rustls::ClientConfig::builder_with_provider(p.clone()).with_protocol_versions(&[&rustls::version::TLS13]).unwrap()
                .dangerous().with_custom_certificate_verifier(Arc::new(Any(p))).with_no_client_auth();
            let tcp = tokio::net::TcpStream::connect(addr).await.unwrap();
            let tls = tokio_rustls::TlsConnector::from(Arc::new(cfg)).connect(rustls::pki_types::ServerName::try_from("x").unwrap(), tcp).await.unwrap();
            let (r, w) = tokio::io::split(tls);
            C(BufReader::new(r), w)
        }

        /// One line (and its bytes) out, one line back (None: closed).
        pub async fn ask(&mut self, v: Value, bytes: &[u8]) -> Option<Value> {
            self.1.write_all(format!("{v}\n").as_bytes()).await.ok()?;
            self.1.write_all(bytes).await.ok()?;
            self.1.flush().await.ok()?;
            let mut l = String::new();
            match tokio::time::timeout(Duration::from_secs(30), self.0.read_line(&mut l)).await {
                Ok(Ok(n)) if n > 0 => serde_json::from_str(&l).ok(),
                _ => None,
            }
        }
    }
}

/// The main stops (frozen, as a NAS that's away); its backup holds the room. A client uploads a file and a comment
/// attachment there, an editor's Pluck uploads a render (over iroh, its own node, its main's device key) with the
/// folder it picked. The main comes back: the backup pushes all three, and is restarted half way through. Each
/// lands once: the client's file in "Delivered while offline/<date>/", the editor's in its folder, the attachment
/// in the quarantine under its id (the comment pushed from the backup finds it), and the backup keeps nothing.
#[tokio::test(flavor = "multi_thread")]
async fn uploads_during_an_outage_move_to_the_main() {
    let Some(iroh) = iroh_bin() else { return eprintln!("pluck-iroh not built: skipped") };
    str0m::crypto::from_feature_flags().install_process_default();
    let signal = signaling().await;
    let sig = format!("ws://{signal}/signal");
    let (main_dir, backup_dir, root) = (tmp("om"), tmp("ob"), tmp("oroot"));
    let bin = Path::new(env!("CARGO_BIN_EXE_pluck-review"));
    let ib = iroh.to_str().unwrap();
    let manifest = json!({"format": 1,
        "links": [{"id": "L1", "roomID": ROOM, "reg": REG, "auth": AUTH, "sign": SEED, "join": JOIN, "title": "Cuts", "mode": "review", "expires": null,
                   "revoked": null, "project": "P1", "root": {"kind": "project", "id": "P1", "name": "Spring"},
                   "uploads": {"folder": null, "maxBytes": 200 << 20, "types": ["image", "video"]}}],
        "projects": [{"id": "P1", "name": "Spring", "folders": [], "assets": [{"id": "A1", "name": "Hero", "kind": "video", "folder": null,
            "versions": [{"id": "V1", "number": 1, "frames": 250, "fpsNum": 25, "fpsDen": 1, "renditions": []}]}]}]});
    let uploads = format!("renders={}", root.display());
    let mut main = Proc::start(bin, &["--host", main_dir.to_str().unwrap(), "--signal", &sig, "--local", "--iroh", "--iroh-bin", ib,
        "--uploads", &uploads, "--name", "Office NAS"], None).await;
    let main_iroh = main.wait(|v| v["host"]["iroh"]["id"].is_string()).await["host"]["iroh"].clone();
    assert_eq!(ctl(&main_dir, json!({"op": "publish", "merge": true, "manifest": manifest})).await["ok"], true);
    main.wait(|v| v["room"]["state"] == "active").await;

    // The editor's Mac pairs with the main over iroh, then registers the node it will reach the backups with.
    let inv = ctl(&main_dir, json!({"op": "invite", "role": "mac"})).await;
    let link: Value = serde_json::from_slice(&B64.decode(inv["link"].as_str().unwrap().split("i=").nth(1).unwrap()).unwrap()).unwrap();
    let mut home = Proc::start(&iroh, &[], Some(json!({"mode": "home", "keyFile": main_dir.join("mac-key"), "port": 1, "office": main_iroh["id"],
        "officeAddrs": link["a"], "local": true}))).await;
    let mac_node = home.wait(|v| v["state"] == "running").await["id"].as_str().unwrap().to_owned();
    let to_main = home.wait(|v| v["listen"].is_string()).await["listen"].as_str().unwrap().to_owned();
    let mut c = sync_client::C::open(&to_main).await;
    let h = c.ask(json!({"pair": inv["code"], "name": "Edit Suite", "node": mac_node, "role": "mac", "protocol": 3}), b"").await.unwrap();
    assert_eq!((h["outage"].clone(), h["links"].clone()), (json!(1), json!(3)), "the main says it takes outage uploads: {h}");
    let (dev, dkey) = (h["device"].as_str().unwrap().to_owned(), h["key"].as_str().unwrap().to_owned());

    // The backup pairs, syncs, and takes the room (the stub gives it to the last to register).
    let binv = ctl(&main_dir, json!({"op": "invite", "role": "backup"})).await;
    let mut backup = Proc::start(bin, &["--host", backup_dir.to_str().unwrap(), "--signal", &sig, "--local", "--backup", "--iroh", "--iroh-bin", ib,
        "--main-link", binv["link"].as_str().unwrap(), "--quality", "same", "--name", "Backup"], None).await;
    backup.wait(|v| v["room"]["state"] == "active").await;
    // The main hands the backup's Macs-only side to its Macs; the Mac's outage node reaches the backup.
    let office = loop {
        let st = c.ask(json!({"op": "status"}), b"").await.unwrap();
        if let Some(o) = st["backups"][0]["replica"]["office"].as_object() { break Value::Object(o.clone()) }
        tokio::time::sleep(Duration::from_millis(300)).await;
    };
    assert!(office["fp"].is_string() && office["node"].as_str() != main_iroh["id"].as_str(), "{office}");
    // (Its node: the key's public half. Pluck works it out; here a pluck-iroh that runs once says it.)
    let tunnel = || json!({"mode": "home", "keyFile": main_dir.join("mac-outage-key"), "port": 1, "office": office["node"], "officeAddrs": office["addrs"], "local": true});
    let outage_node = Proc::start(&iroh, &[], Some(json!({"mode": "home", "keyFile": main_dir.join("mac-outage-key"), "port": 1, "office": main_iroh["id"], "local": true})))
        .await.wait(|v| v["state"] == "running").await["id"].as_str().unwrap().to_owned();
    assert_eq!(c.ask(json!({"op": "outage-node", "node": outage_node}), b"").await.unwrap()["ok"], true);
    let until = Instant::now() + T;
    while !std::fs::read_to_string(backup_dir.join("main-macs.json")).unwrap_or_default().contains(&dev) {
        assert!(Instant::now() < until, "the backup never heard of the Mac");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    drop(c);

    // The main goes away.
    main.signal("-STOP");

    // A client uploads to the backup: no error.
    let mut br = Browser::connect(signal).await;
    br.auth("Anna").await;
    br.next(|m| m["t"] == "ready").await;
    let film = random_file(&tmp("ofilm").join("a.mov"), 40 << 20);
    let up = br.call(json!({"t": "upload-begin", "name": "Interview A.mov", "size": film.len(), "for": "asset"})).await;
    assert!(up["upload"].is_u64(), "the backup takes uploads in an outage: {up}");
    br.upload(up["upload"].as_u64().unwrap() as u32, &film, up["credit"].as_u64().unwrap()).await;
    let done = br.call(json!({"t": "upload-end", "upload": up["upload"], "sha256": B64.encode(Sha256::digest(&film))})).await;
    assert_eq!(done["uploaded"]["name"], "Interview A.mov", "{done}");
    let png = b"\x89PNG\r\n\x1a\nref".to_vec();
    let up = br.call(json!({"t": "upload-begin", "name": "ref.png", "size": png.len(), "for": "attachment"})).await;
    br.upload(up["upload"].as_u64().unwrap() as u32, &png, up["credit"].as_u64().unwrap()).await;
    let att = br.call(json!({"t": "upload-end", "upload": up["upload"], "sha256": B64.encode(Sha256::digest(&png))})).await["attachment"].clone();
    let cm = br.call(json!({"t": "comment-add", "asset": "A1", "version": "V1", "frame": null, "text": "Like this", "attachments": [att["id"]]})).await;
    assert_eq!(cm["comment"]["attachments"][0]["id"], att["id"], "{cm}");

    // The editor's Pluck uploads to the backup: its main's device key, on its outage node; uploads only.
    let mut to_backup_iroh = Proc::start(&iroh, &[], Some(tunnel())).await;
    let to_backup = to_backup_iroh.wait(|v| v["listen"].is_string()).await["listen"].as_str().unwrap().to_owned();
    let mut e = sync_client::C::open(&to_backup).await;
    assert_eq!(e.ask(json!({"device": dev, "key": dkey, "protocol": 3}), b"").await.unwrap()["ok"], true);
    for op in ["browse", "mkdir", "move", "devices", "pull", "manifest"] {
        assert_eq!(e.ask(json!({"op": op, "path": "outage/x"}), b"").await.unwrap()["error"], "scope", "{op}");
    }
    let spot = b"spot 30s".repeat(1000);
    let hex: String = Sha256::digest(&spot).iter().map(|b| format!("{b:02x}")).collect();
    let b = e.ask(json!({"op": "upload-begin", "path": "outage/Spot 30s.mov", "size": spot.len(), "sha256": hex, "folder": "renders/Client/2026"}), b"").await.unwrap();
    let id = b["upload"].as_str().unwrap().to_owned();
    assert_eq!(e.ask(json!({"op": "upload-part", "upload": id, "offset": 0, "size": spot.len()}), &spot).await.unwrap()["have"], spot.len());
    let end = e.ask(json!({"op": "upload-end", "upload": id}), b"").await.unwrap();
    assert!(end["outage"].is_string(), "{end}");
    let waiting: Vec<Value> = serde_json::from_slice(&std::fs::read(backup_dir.join("outage.json")).unwrap()).unwrap();
    assert_eq!(waiting.len(), 3, "{waiting:?}");

    // The main is back: the backup pushes; it's restarted while the 40 MB file is on its way.
    main.signal("-CONT");
    let part = root.join(".pluck-partial");
    let until = Instant::now() + T;
    let mut cut = false;
    while Instant::now() < until {
        let midway = std::fs::read_dir(&part).into_iter().flatten().flatten()
            .any(|f| f.file_name().to_string_lossy().starts_with("outage-") && f.metadata().is_ok_and(|m| m.len() > 0 && m.len() < film.len() as u64));
        if midway {
            drop(backup);
            cut = true;
            break;
        }
        if waiting_on(&backup_dir) == 0 { break }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    eprintln!("outage push cut half way: {cut}");
    let _backup = Proc::start(bin, &["--host", backup_dir.to_str().unwrap(), "--signal", &sig, "--local", "--backup", "--iroh", "--iroh-bin", ib,
        "--quality", "same", "--name", "Backup"], None).await;
    let until = Instant::now() + T * 2;
    while waiting_on(&backup_dir) > 0 {
        assert!(Instant::now() < until, "never pushed: {}", std::fs::read_to_string(backup_dir.join("outage.json")).unwrap_or_default());
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    tokio::time::sleep(Duration::from_secs(3)).await; // another round or two: nothing more arrives
    let today = |d: &Path| std::fs::read_dir(d).unwrap().flatten().map(|f| f.path()).collect::<Vec<_>>();
    let days = today(&root.join("Delivered while offline"));
    assert_eq!(days.len(), 1);
    let files = today(&days[0]);
    assert_eq!(files.len(), 1, "once: {files:?}");
    assert!(files[0].ends_with("Interview A.mov") && std::fs::read(&files[0]).unwrap() == film);
    assert_eq!(std::fs::read(root.join("Client/2026/Spot 30s.mov")).unwrap(), spot, "the editor's file in the folder it picked");
    assert_eq!(std::fs::read(main_dir.join(format!("uploads/L1/{}.png", att["id"].as_str().unwrap()))).unwrap(), png);
    let pulled = ctl(&main_dir, json!({"op": "pull", "since": 0})).await;
    let entries = pulled["entries"].as_array().unwrap();
    let ups: Vec<&Value> = entries.iter().filter_map(|e| e.get("upload")).collect();
    assert_eq!(ups.len(), 2, "the client's file and the attachment, logged once each: {ups:?}");
    let asset = ups.iter().find(|u| u["for"] == "asset").unwrap();
    assert_eq!((asset["root"].clone(), asset["outage"].clone()), (json!(true), json!(true)));
    assert!(asset["path"].as_str().unwrap().starts_with("renders/Delivered while offline/") && asset["path"].as_str().unwrap().ends_with("/Interview A.mov"));
    assert!(ups.iter().any(|u| u["for"] == "attachment" && u["id"] == att["id"] && u["path"] == format!("uploads/L1/{}.png", att["id"].as_str().unwrap())));
    assert_eq!(entries.iter().filter(|e| e["comment"]["id"] == cm["comment"]["id"]).count(), 1, "the backup's comment, once");
    let list = ctl(&main_dir, json!({"op": "outage-list"})).await;
    assert_eq!(list["items"].as_array().unwrap().len(), 2, "the Inbox lists the client's file and the editor's: {list}");
    let ed = list["items"].as_array().unwrap().iter().find(|x| x["kind"] == "editor").unwrap();
    assert_eq!((ed["path"].clone(), ed["moved"].clone(), ed["id"].clone()), (json!("renders/Client/2026/Spot 30s.mov"), json!(true), end["outage"].clone()));
    // The backup keeps nothing of it.
    assert!(std::fs::read_dir(backup_dir.join("outage-editor")).unwrap().flatten().all(|f| f.file_name() == ".pluck-partial"));
    assert!(std::fs::read_dir(backup_dir.join("uploads/L1")).map_or(true, |d| d.count() == 0));
    drop((home, to_backup_iroh, main));
    let _ = (std::fs::remove_dir_all(main_dir), std::fs::remove_dir_all(backup_dir), std::fs::remove_dir_all(root));
}

fn waiting_on(backup: &Path) -> usize {
    std::fs::read(backup.join("outage.json")).ok().and_then(|b| serde_json::from_slice::<Vec<Value>>(&b).ok()).map_or(usize::MAX, |v| v.len())
}

// ---- accounts with passkeys: the built site in headless Chrome, a virtual authenticator over CDP (plan 2026-11-17 §9) ----

const SITE_PORT: u16 = 8851; // the page and its signaling; a passkey's origin is http://localhost:8851
const CDP_PORT: u16 = 8852;
const LINK_KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"; // §3 vector: ROOM, AUTH and PUB come from it
const ANDROID: &str = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";
/// Test-only, injected by CDP (not in the site): the page's data channels, so a test can drop the connection.
const HOOK: &str = "window.__chs=[];window.__haves=[];const o=RTCPeerConnection.prototype.createDataChannel;RTCPeerConnection.prototype.createDataChannel=function(...a){const c=o.apply(this,a);window.__chs.push(c);c.addEventListener('message',(e)=>{if(typeof e.data==='string'&&e.data.includes('\"have\"'))try{window.__haves.push(JSON.parse(e.data).have)}catch{}});return c};";

/// The built site's files and the signaling stand-in (one stub per room, as the Room DO) on one localhost port.
async fn site_and_signaling(site: std::path::PathBuf) {
    let l = TcpListener::bind(("127.0.0.1", SITE_PORT)).await.unwrap();
    let rooms: Arc<Mutex<HashMap<String, Stub>>> = Arc::default();
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = l.accept().await else { continue };
            let (rooms, site) = (rooms.clone(), site.clone());
            tokio::spawn(async move {
                let mut head = [0u8; 4096];
                let k = tcp.peek(&mut head).await.unwrap_or(0);
                if String::from_utf8_lossy(&head[..k]).to_ascii_lowercase().contains("upgrade: websocket") { room_socket(tcp, rooms).await } else { serve_file(tcp, &site).await }
            });
        }
    });
}

async fn serve_file(mut s: tokio::net::TcpStream, site: &Path) {
    use tokio::io::AsyncReadExt;
    let mut buf = vec![0u8; 16384];
    let mut n = 0;
    while !String::from_utf8_lossy(&buf[..n]).contains("\r\n\r\n") && n < buf.len() {
        match s.read(&mut buf[n..]).await { Ok(0) | Err(_) => return, Ok(k) => n += k }
    }
    let line = String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_owned();
    let path = line.split(' ').nth(1).unwrap_or("/").split('?').next().unwrap_or("/").to_owned();
    let mut file = site.join(path.trim_start_matches('/'));
    if path.starts_with("/r/") || path == "/r" { file = site.join("r/index.html") } else if file.is_dir() { file = file.join("index.html") }
    let (status, body) = match std::fs::read(&file) { Ok(b) if !path.contains("..") => ("200 OK", b), _ => ("404 Not Found", vec![]) };
    let ty = match file.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "js" | "mjs" => "text/javascript", "css" => "text/css", "svg" => "image/svg+xml", "png" => "image/png", "json" | "webmanifest" => "application/json", _ => "text/html",
    };
    let _ = s.write_all(format!("HTTP/1.1 {status}\r\nContent-Type: {ty}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len()).as_bytes()).await;
    let _ = s.write_all(&body).await;
}

async fn room_socket(tcp: tokio::net::TcpStream, rooms: Arc<Mutex<HashMap<String, Stub>>>) {
    let mut path = String::new();
    let cb = |req: &Request, res: Response| { path = req.uri().path().to_owned(); Ok(res) };
    let Ok(ws) = tokio_tungstenite::accept_hdr_async(tcp, cb).await else { return };
    let room = path.trim_start_matches("/signal/").to_owned();
    let (mut w, mut r) = ws.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move { while let Some(m) = rx.recv().await { if w.send(Message::text(m)).await.is_err() { break } } });
    let mut me: Option<String> = None;
    while let Some(Ok(m)) = r.next().await {
        let Message::Text(t) = m else { continue };
        let Ok(mut v) = serde_json::from_str::<Value>(&t) else { continue };
        let mut all = rooms.lock().unwrap();
        let total = all.values().map(|s| s.n).sum::<u32>();
        let s = all.entry(room.clone()).or_default();
        match (v["t"].as_str().unwrap_or(""), me.as_deref()) {
            ("mac-register", _) => {
                s.mac = Some(tx.clone());
                me = Some("mac".into());
                let _ = tx.send(json!({"t": "registered", "peers": []}).to_string());
                for b in s.browsers.values() { let _ = b.send(json!({"t": "mac-here", "ice": []}).to_string()); }
            }
            ("browser-join", _) => {
                s.n += 1;
                let id = format!("p_web{}", total + 1);
                s.browsers.insert(id.clone(), tx.clone());
                let _ = tx.send(json!({"t": "joined", "peer": id, "mac": s.mac.is_some(), "ice": []}).to_string());
                me = Some(id);
            }
            ("ping", _) => { let _ = tx.send(r#"{"t":"pong"}"#.into()); }
            (_, Some("mac")) => {
                let peer = v["peer"].as_str().unwrap_or("").to_owned();
                v.as_object_mut().unwrap().remove("peer");
                if v["t"] == "kick" { s.browsers.remove(&peer); } else if let Some(b) = s.browsers.get(&peer) { let _ = b.send(v.to_string()); }
            }
            (_, Some(peer)) => {
                v["peer"] = json!(peer);
                if let Some(m) = &s.mac { let _ = m.send(v.to_string()); }
            }
            _ => {}
        }
    }
    if me.as_deref() == Some("mac") {
        if let Some(s) = rooms.lock().unwrap().get_mut(&room) { s.mac = None }
    }
}

/// Chrome DevTools over its browser socket, one flat session per page.
struct Cdp {
    w: futures_util::stream::SplitSink<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, Message>,
    r: futures_util::stream::SplitStream<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>>,
    id: u64,
    events: VecDeque<Value>,
    authn: HashMap<String, String>, // page session → its virtual authenticator
}

impl Cdp {
    async fn open() -> Cdp {
        use tokio::io::AsyncReadExt;
        let deadline = Instant::now() + T;
        let url = loop {
            if let Ok(mut s) = tokio::net::TcpStream::connect(("127.0.0.1", CDP_PORT)).await {
                let _ = s.write_all(b"GET /json/version HTTP/1.1\r\nHost: 127.0.0.1:8852\r\nConnection: close\r\n\r\n").await;
                let mut out = vec![];
                let _ = tokio::time::timeout(Duration::from_secs(5), s.read_to_end(&mut out)).await;
                let t = String::from_utf8_lossy(&out);
                if let Some(v) = t.split("\r\n\r\n").nth(1).and_then(|b| serde_json::from_str::<Value>(b).ok()) {
                    break v["webSocketDebuggerUrl"].as_str().unwrap().to_owned();
                }
            }
            assert!(Instant::now() < deadline, "Chrome didn't open its DevTools port");
            tokio::time::sleep(Duration::from_millis(200)).await;
        };
        let (ws, _) = tokio_tungstenite::connect_async(url).await.unwrap();
        let (w, r) = ws.split();
        Cdp { w, r, id: 0, events: VecDeque::new(), authn: HashMap::new() }
    }

    async fn call(&mut self, session: Option<&str>, method: &str, params: Value) -> Value {
        self.id += 1;
        let id = self.id;
        let mut m = json!({"id": id, "method": method, "params": params});
        if let Some(s) = session { m["sessionId"] = json!(s) }
        self.w.send(Message::text(m.to_string())).await.unwrap();
        loop {
            let v = next_json(&mut self.r).await;
            if v["id"] == id {
                assert!(v.get("error").is_none(), "{method}: {v}");
                return v["result"].clone();
            }
            if v.get("method").is_some() {
                self.events.push_back(v);
                if self.events.len() > 2000 { self.events.pop_front(); }
            }
        }
    }

    async fn event(&mut self, method: &str) -> Value {
        if let Some(i) = self.events.iter().position(|e| e["method"] == method) { return self.events.remove(i).unwrap() }
        loop {
            let v = next_json(&mut self.r).await;
            if v["method"] == method { return v }
        }
    }

    /// A page in `context` (None: the default profile), with its own virtual authenticator (§9: ctap2, internal, resident
    /// keys, user verification as given, presence answered by itself).
    async fn page(&mut self, context: Option<&str>, uv: bool, android: bool) -> String {
        let mut p = json!({"url": "about:blank"});
        if let Some(c) = context { p["browserContextId"] = json!(c) }
        let target = self.call(None, "Target.createTarget", p).await["targetId"].clone();
        let s = self.call(None, "Target.attachToTarget", json!({"targetId": target, "flatten": true})).await["sessionId"].as_str().unwrap().to_owned();
        let s = s.as_str();
        self.call(Some(s), "Page.enable", json!({})).await;
        self.call(Some(s), "Page.addScriptToEvaluateOnNewDocument", json!({"source": HOOK})).await;
        self.call(Some(s), "WebAuthn.enable", json!({"enableUI": false})).await;
        let a = self.call(Some(s), "WebAuthn.addVirtualAuthenticator", json!({"options": {"protocol": "ctap2", "transport": "internal", "hasResidentKey": true,
            "hasUserVerification": true, "isUserVerified": uv, "automaticPresenceSimulation": true}})).await;
        self.authn.insert(s.to_owned(), a["authenticatorId"].as_str().unwrap().to_owned());
        if android {
            self.call(Some(s), "Emulation.setUserAgentOverride", json!({"userAgent": ANDROID, "platform": "Linux armv8l"})).await;
            self.call(Some(s), "Emulation.setDeviceMetricsOverride", json!({"width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true})).await;
        }
        s.to_owned()
    }

    async fn context(&mut self) -> String {
        self.call(None, "Target.createBrowserContext", json!({})).await["browserContextId"].as_str().unwrap().to_owned()
    }

    async fn go(&mut self, s: &str, url: &str) {
        self.call(Some(s), "Page.navigate", json!({"url": url})).await;
    }

    async fn eval(&mut self, s: &str, js: &str) -> Value {
        let r = self.call(Some(s), "Runtime.evaluate", json!({"expression": js, "returnByValue": true, "awaitPromise": true, "userGesture": true})).await;
        r["result"]["value"].clone()
    }

    /// Wait until `js` is truthy (30 s), else fail with what the page shows.
    async fn until(&mut self, s: &str, js: &str, what: &str) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let v = self.eval(s, &format!("(()=>{{try{{return !!({js})}}catch(e){{return false}}}})()")).await;
            if v == true { return }
            if Instant::now() > deadline {
                let body = self.eval(s, "document.body.innerText").await;
                panic!("{what}: timed out; the page shows: {body}");
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    }

    async fn sees(&mut self, s: &str, text: &str) {
        self.until(s, &format!("document.body.innerText.includes({})", json!(text)), text).await
    }

    /// Click the last visible, enabled button whose text is `label` (dialogs come last in the body).
    async fn click(&mut self, s: &str, label: &str) {
        let js = format!("(()=>{{const b=[...document.querySelectorAll('button')].filter(b=>!b.disabled&&b.getClientRects().length&&b.textContent.trim()==={}).pop();if(!b)return false;b.click();return true}})()", json!(label));
        self.until(s, &js, &format!("button {label}")).await;
    }

    async fn credentials(&mut self, s: &str) -> usize {
        let id = self.authn[s].clone();
        let a = self.call(Some(s), "WebAuthn.getCredentials", json!({"authenticatorId": id})).await;
        a["credentials"].as_array().map_or(0, |c| c.len())
    }
}

/// Asks the helper's host (Pluck's stdin sync path) and returns its answer.
async fn host_op(h: &mut Helper, op: Value) -> Value {
    h.line(json!({"host": op})).await;
    h.wait(|v| v.get("host").is_some()).await["host"].clone()
}

/// W-1…W-4 and the hand-off cases of plan 2026-11-17 §9 step 5, against the built site (PLUCK_REVIEW_SITE: the
/// astro build's out dir) in a windowless Chrome (PLUCK_REVIEW_BROWSER):
/// `cargo test --release --test e2e -- --ignored real_browser_passkeys --nocapture`.
#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn real_browser_passkeys() {
    let (Ok(browser), Ok(site)) = (std::env::var("PLUCK_REVIEW_BROWSER"), std::env::var("PLUCK_REVIEW_SITE")) else {
        return eprintln!("PLUCK_REVIEW_BROWSER or PLUCK_REVIEW_SITE not set: skipped");
    };
    assert!(Path::new(&site).join("r/index.html").exists(), "PLUCK_REVIEW_SITE must be an astro build output");
    str0m::crypto::from_feature_flags().install_process_default();
    site_and_signaling(site.into()).await;
    let base = tmp("passkeys");
    let (data, renders, media) = (base.join("data"), base.join("renders"), base.join("media"));
    std::fs::create_dir_all(&renders).unwrap();
    random_file(&media.join("Day 1/A001.mp4"), 300_000);
    let b = data.join("bundle");
    std::fs::create_dir_all(&b).unwrap();
    std::fs::write(b.join("manifest.json"), json!({"format": 1,
        "links": [{"id": "L1", "roomID": ROOM, "reg": REG, "auth": AUTH, "sign": SEED, "join": JOIN, "title": "Cuts", "mode": "review", "expires": null, "revoked": null,
                   "project": "P1", "root": {"kind": "project", "id": "P1", "name": "Spring"}}],
        "projects": [{"id": "P1", "name": "Spring", "folders": [], "assets": [{"id": "A1", "name": "Hero", "kind": "image", "folder": null,
            "versions": [{"id": "V1", "number": 1, "frames": 1, "renditions": []}]}]}]}).to_string()).unwrap();
    let origin = format!("http://localhost:{SITE_PORT}");
    let mut h = Helper::start(json!({"signal": format!("ws://127.0.0.1:{SITE_PORT}/signal"), "stun": [], "local": true,
        "host": {"dir": data.to_string_lossy(), "webauthnOrigin": origin, "uploads": format!("renders={}", renders.display()),
                 "media": [format!("media={}", media.display())]}})).await;
    h.wait(|v| v["room"]["state"] == "active").await;
    assert_eq!(host_op(&mut h, json!({"op": "team-set", "name": "Northwind Films"})).await["ok"], true);
    h.wait(|v| v["room"]["state"] == "active" && v["room"]["room"] != ROOM).await; // the team room is held
    let invite = |name: &str, role: &str| json!({"op": "person-invite", "name": name, "role": role, "footage": true});
    let inv = host_op(&mut h, invite("Editor One", "editor")).await;
    let link = inv["link"].as_str().unwrap().to_owned();
    assert!(link.starts_with(&format!("{origin}/r/#")) && link.contains("/i/"), "{link}");
    let team = link.split("/i/").next().unwrap().to_owned();

    let profile = tmp("passkeys-chrome");
    let mut chrome = Command::new(&browser).args(["--headless=new", "--no-first-run", "--disable-gpu", "--disable-extensions", "--mute-audio",
        "--disable-features=WebRtcHideLocalIpsWithMdns", &format!("--remote-debugging-port={CDP_PORT}")])
        .arg(format!("--user-data-dir={}", profile.display())).arg("about:blank").stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true).spawn().unwrap();
    let mut c = Cdp::open().await;
    let ok = |s: &str| eprintln!("passkeys: {s} ok");

    // W-1: invite → create passkey → projects; the code leaves the address; reload → sign in with the same passkey (the hint).
    let a = c.page(None, true, false).await;
    c.go(&a, &link).await;
    c.sees(&a, "Create your passkey").await;
    assert_eq!(c.eval(&a, "location.hash.includes('/i/')").await, false, "the invite code left the address before anything was used (L7)");
    c.click(&a, "Create passkey").await;
    c.sees(&a, "Spring").await;
    assert_eq!(c.eval(&a, "location.hash.includes('/i/')").await, false, "the invite code is stripped");
    assert_eq!(c.eval(&a, "JSON.parse(localStorage.getItem('pluck-teams')).length").await, 1);
    assert_eq!(c.eval(&a, "JSON.parse(localStorage.getItem('pluck-teams'))[0].link").await, json!(team), "the plain team link is kept");
    let host_team = host_op(&mut h, json!({"op": "people"})).await["team"]["id"].clone();
    assert_ne!(c.eval(&a, "JSON.parse(localStorage.getItem('pluck-teams'))[0].id").await, host_team, "keyed by the verified team room, not the host's id");
    // A project is the review-link grid with `project` on each op; footage browses read-only; another device gets a /d/ link.
    c.eval(&a, "document.querySelector('.rv-folder').click()").await;
    c.sees(&a, "Hero").await;
    assert_eq!(c.eval(&a, "location.hash.includes('/p/P1')").await, true);
    c.eval(&a, "history.back()").await;
    c.click(&a, "Footage").await;
    c.eval(&a, "(async()=>{for(const n of ['media','Day 1']){for(let i=0;i<50&&![...document.querySelectorAll('.rv-folder')].some(b=>b.textContent===n);i++)await new Promise(r=>setTimeout(r,100));[...document.querySelectorAll('.rv-folder')].find(b=>b.textContent===n).click()}})()").await;
    c.sees(&a, "A001.mp4").await;
    c.click(&a, "Open on another device").await;
    c.until(&a, "document.querySelector('dialog[open] .rv-qr') && document.querySelector('dialog[open] input').value.includes('/d/')", "a device link and its QR").await;
    c.click(&a, "Close").await;
    c.go(&a, "about:blank").await;
    c.go(&a, &team).await;
    c.sees(&a, "Sign in to Northwind Films").await;
    c.click(&a, "Sign in with a passkey").await;
    c.sees(&a, "Spring").await;
    assert_eq!(c.credentials(&a).await, 1, "signed in with the passkey made at the invite");
    ok("W-1");

    // W-2: a passkey the page made itself is refused, and nothing of the team shows.
    let ctx = c.context().await;
    let w2 = c.page(Some(&ctx), true, false).await;
    c.go(&w2, &team).await;
    c.sees(&w2, "Sign in to Northwind Films").await;
    let made = c.eval(&w2, "navigator.credentials.create({publicKey:{rp:{id:location.hostname,name:'x'},user:{id:new Uint8Array(16).fill(9),name:'Someone · Elsewhere',displayName:'Someone'},challenge:new Uint8Array(32),pubKeyCredParams:[{type:'public-key',alg:-7}],authenticatorSelection:{residentKey:'required',userVerification:'required'}}}).then(()=>true,(e)=>String(e))").await;
    assert_eq!(made, true, "{made}");
    c.click(&w2, "Sign in with a passkey").await;
    c.sees(&w2, "That passkey isn't for Northwind Films").await;
    assert_eq!(c.eval(&w2, "document.body.innerText.includes('Spring')").await, false, "no data");
    ok("W-2");

    // W-3: the used invite again in a new profile → "already used"; an invite past its expiry → "expired".
    let ctx = c.context().await;
    let w3 = c.page(Some(&ctx), true, false).await;
    c.go(&w3, &link).await;
    c.sees(&w3, "Invite already used").await;
    let old = host_op(&mut h, invite("Late One", "client")).await;
    let mut file = host_op(&mut h, json!({"op": "_accounts"})).await;
    for i in file["invites"].as_array_mut().unwrap() {
        if i["person"] == old["person"] { i["expires"] = json!("2000-01-01T00:00:00Z") } // test only: its expiry passed
    }
    assert_eq!(host_op(&mut h, json!({"op": "_accounts-apply", "accounts": file})).await["ok"], true);
    let ctx = c.context().await;
    let w3b = c.page(Some(&ctx), true, false).await;
    c.go(&w3b, old["link"].as_str().unwrap()).await;
    c.sees(&w3b, "Invite expired").await;
    ok("W-3");

    // User verification is required: an authenticator that can't verify makes no passkey.
    let uv = host_op(&mut h, invite("No Verify", "editor")).await;
    let ctx = c.context().await;
    let nu = c.page(Some(&ctx), false, false).await;
    c.go(&nu, uv["link"].as_str().unwrap()).await;
    c.sees(&nu, "Create your passkey").await;
    c.click(&nu, "Create passkey").await;
    c.sees(&nu, "No passkey was used").await;
    assert_eq!(c.credentials(&nu).await, 0);
    assert_eq!(c.eval(&nu, "document.body.innerText.includes('Spring')").await, false);
    ok("UV required");

    // Mobile (Android UA): upload into the uploads root, the connection dropped at about half, the page resumes with its
    // in-memory key (no prompt) and finishes; the file on disk is the file.
    let up = host_op(&mut h, invite("Phone One", "editor")).await;
    let ctx = c.context().await;
    let m = c.page(Some(&ctx), true, true).await;
    c.go(&m, up["link"].as_str().unwrap()).await;
    c.click(&m, "Create passkey").await;
    c.sees(&m, "Spring").await;
    let clip = base.join("phone/Clip.mp4");
    let body = random_file(&clip, 64 << 20);
    c.call(Some(&m), "Page.setInterceptFileChooserDialog", json!({"enabled": true})).await;
    c.eval(&m, "window.__drop=setInterval(()=>{const p=document.querySelector('.rv-upload progress');if(p&&p.value>=.4){clearInterval(window.__drop);window.__dropped=true;window.__chs.filter(c=>c.label==='ctl'&&c.readyState==='open').forEach(c=>c.close())}},2)").await;
    c.click(&m, "Upload").await;
    c.click(&m, "Choose files").await;
    let fc = c.event("Page.fileChooserOpened").await;
    c.call(Some(&m), "DOM.setFileInputFiles", json!({"files": [clip.to_string_lossy()], "backendNodeId": fc["params"]["backendNodeId"]})).await;
    c.until(&m, "window.__dropped", "the connection dropped mid-upload").await;
    c.sees(&m, "Uploaded").await;
    assert_eq!(c.eval(&m, "document.body.innerText.includes('Create your passkey')||document.body.innerText.includes('Sign in to')").await, false, "no prompt on resume");
    let haves = c.eval(&m, "window.__haves").await;
    assert!(haves[0] == 0 && haves[1].as_u64().is_some_and(|n| n > 0 && n < body.len() as u64), "begun at 0, resumed from what the host had: {haves}");
    assert!(std::fs::read(renders.join("Clip.mp4")).unwrap() == body, "the file on disk is the file");
    let ups = host_op(&mut h, json!({"op": "pull", "since": 0})).await;
    assert!(ups["entries"].as_array().unwrap().iter().any(|e| e["upload"]["for"] == "root" && e["upload"]["by"] == "Phone One"));
    ok("mobile upload resume");
    // A device code needs a passkey on this session, not just the resume key (M1): the page asks for it, then shows the link.
    c.click(&m, "Open on another device").await;
    c.sees(&m, "Confirm it's you with your passkey first.").await;
    c.click(&m, "Sign in with a passkey").await;
    c.until(&m, "document.querySelector('dialog[open] .rv-qr') && document.querySelector('dialog[open] input').value.includes('/d/')", "a device link after the passkey").await;
    c.click(&m, "Close").await;
    ok("device code needs a fresh passkey");
    // A lower role ends the session (M3): the page connects again and offers sign-in; signed in, a client is "set".
    let phone = host_op(&mut h, json!({"op": "people"})).await["people"].as_array().unwrap().iter().find(|p| p["name"] == "Phone One").unwrap()["id"].clone();
    assert_eq!(host_op(&mut h, json!({"op": "person-update", "id": phone, "role": "client"})).await["ok"], true);
    c.sees(&m, "Sign in to Northwind Films").await;
    c.click(&m, "Sign in with a passkey").await;
    c.sees(&m, "You're set").await;
    ok("role down: sign in again");

    // W-4: on a review link, "Make an account…" → waiting (no "Create passkey"); accepted in Pluck → the event → create
    // → signed in, and a new comment carries the account name.
    let ctx = c.context().await;
    let r = c.page(Some(&ctx), true, false).await;
    c.go(&r, &format!("{origin}/r/{ROOM}#{LINK_KEY}.{PUB}")).await;
    c.click(&r, "Sign in").await;
    c.click(&r, "Make an account…").await;
    c.eval(&r, "(()=>{const i=document.querySelector('dialog[open] input[type=text]');i.value='Dana';return true})()").await;
    c.click(&r, "Ask for an account").await;
    c.sees(&r, "Waiting for approval").await;
    c.click(&r, "Close").await;
    c.until(&r, "JSON.parse(localStorage.getItem('pluck-requests')).length === 1", "the request secret is kept").await;
    assert_eq!(c.eval(&r, "[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='Create passkey')").await, false, "no passkey while pending");
    let people = host_op(&mut h, json!({"op": "people"})).await;
    let req = people["requests"].as_array().unwrap().iter().find(|q| q["name"] == "Dana").unwrap()["id"].clone();
    assert_eq!(host_op(&mut h, json!({"op": "request-accept", "id": req})).await["ok"], true);
    c.sees(&r, "Your account was approved").await;
    c.click(&r, "Create passkey").await;
    c.click(&r, "Create passkey").await;
    c.sees(&r, "Signed in as Dana").await;
    assert_eq!(c.eval(&r, "JSON.parse(localStorage.getItem('pluck-requests')||'[]').length").await, 0, "the request is used");
    c.eval(&r, &format!("location.hash='#{LINK_KEY}.{PUB}/a/A1'")).await;
    c.until(&r, "document.querySelector('.rv-compose-text')", "the composer").await;
    c.eval(&r, "(()=>{const t=document.querySelector('.rv-compose-text');t.value='Signed in comment';t.dispatchEvent(new Event('input'));t.form.requestSubmit();return true})()").await;
    c.sees(&r, "Signed in comment").await;
    let pulled = host_op(&mut h, json!({"op": "pull", "since": 0})).await;
    assert!(pulled["entries"].as_array().unwrap().iter().any(|e| e["comment"]["text"] == "Signed in comment" && e["comment"]["author"] == "Dana"), "the account name on the comment");
    ok("W-4");

    // Editors invite, an admin approves: with "Editors can invite people" on, the editor's page gets Invite (client or
    // editor only); the link is pending; the invitee waits ("Waiting for an admin"); the editor sees no waiting list; an
    // owner approves on the web team page; the invitee's page goes on by itself to the passkey and joins.
    assert_eq!(host_op(&mut h, json!({"op": "team-set", "editorsInvite": true})).await["ok"], true);
    let mut editor_invite = async |c: &mut Cdp, who: &str| -> String {
        c.click(&a, "Invite").await;
        c.eval(&a, &format!("(()=>{{const i=document.querySelector('dialog[open] input[type=text]');i.value={};return true}})()", json!(who))).await;
        assert_eq!(c.eval(&a, "[...document.querySelectorAll('dialog[open] select option')].map(o=>o.value).join()").await, "client,editor", "never an owner");
        c.click(&a, "Make invite link").await;
        c.sees(&a, "An admin approves them before they can join").await;
        let l = c.eval(&a, "document.querySelector('dialog[open] input[readonly]').value").await.as_str().unwrap().to_owned();
        c.click(&a, "Close").await;
        l
    };
    let pat = editor_invite(&mut c, "Pat").await;
    let ctx = c.context().await;
    let p = c.page(Some(&ctx), true, false).await;
    c.go(&p, &pat).await;
    c.sees(&p, "Waiting for an admin").await;
    assert_eq!(c.eval(&p, "[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='Create passkey')").await, false, "no passkey while pending");
    assert_eq!(c.eval(&a, "document.body.innerText.includes('Waiting for approval')").await, false, "editors don't approve, not even their own");
    let boss = host_op(&mut h, invite("Boss One", "owner")).await;
    let ctx = c.context().await;
    let o = c.page(Some(&ctx), true, false).await;
    c.go(&o, boss["link"].as_str().unwrap()).await;
    c.click(&o, "Create passkey").await;
    c.sees(&o, "Waiting for approval: 1").await;
    c.click(&o, "Review").await;
    c.sees(&o, "invited by Editor One").await;
    c.sees(&o, "opened the link").await;
    c.click(&o, "Approve").await;
    c.sees(&p, "Create your passkey").await;
    c.click(&p, "Create passkey").await;
    c.sees(&p, "You're set").await; // a client: their review links
    let people = host_op(&mut h, json!({"op": "people"})).await;
    let pp = people["people"].as_array().unwrap().iter().find(|x| x["name"] == "Pat").unwrap().clone();
    assert_eq!((pp["role"].as_str(), pp["passkeys"].as_array().map(|k| k.len())), (Some("client"), Some(1)), "a member once approved");
    ok("editor invite approved by an owner");
    // Revoked while pending: the owner's Revoke, then the link is refused.
    let quinn = editor_invite(&mut c, "Quinn").await;
    c.sees(&o, "Waiting for approval: 1").await;
    c.click(&o, "Review").await;
    c.click(&o, "Revoke").await;
    let ctx = c.context().await;
    let q = c.page(Some(&ctx), true, false).await;
    c.go(&q, &quinn).await;
    c.sees(&q, "This invite isn't valid").await;
    assert!(host_op(&mut h, json!({"op": "people"})).await["people"].as_array().unwrap().iter().all(|x| x["name"] != "Quinn"), "the person it named goes too");
    ok("revoked editor invite");

    // Removed during a session: the removed screen at once.
    let people = host_op(&mut h, json!({"op": "people"})).await;
    let ed = people["people"].as_array().unwrap().iter().find(|p| p["name"] == "Editor One").unwrap()["id"].clone();
    assert_eq!(host_op(&mut h, json!({"op": "person-remove", "id": ed})).await["ok"], true);
    c.sees(&a, "Sign in to Northwind Films").await; // M3: first the sign-in again; the refused passkey then says why
    c.click(&a, "Sign in with a passkey").await;
    c.sees(&a, "Your access was removed").await;
    assert_eq!(c.eval(&a, "document.body.innerText.includes('Spring')").await, false);
    ok("removed");

    // Team key pinning: a page that saw this team's key refuses another one for the same team id (no passkey prompt),
    // warns, and "Forget this team" (confirmed) clears the pin. A team reset's signed move is taken with a short note.
    let tid = host_op(&mut h, json!({"op": "people"})).await["team"]["id"].clone();
    let ctx = c.context().await;
    let k = c.page(Some(&ctx), true, false).await;
    c.go(&k, &format!("{origin}/r/{ROOM}#{LINK_KEY}.{PUB}")).await;
    c.until(&k, &format!("JSON.parse(localStorage.getItem('pluck-team-pins')||'{{}}')[{tid}]"), "the team key is pinned").await;
    let real = c.eval(&k, &format!("JSON.parse(localStorage.getItem('pluck-team-pins'))[{tid}]")).await;
    c.eval(&k, &format!("localStorage.setItem('pluck-team-pins', JSON.stringify({{[{tid}]: 'A'.repeat(43)}}))")).await;
    c.go(&k, "about:blank").await;
    c.go(&k, &team).await;
    c.sees(&k, "This team's key changed").await;
    assert_eq!(c.eval(&k, "[...document.querySelectorAll('button')].some(b=>b.textContent.trim()==='Sign in with a passkey')").await, false, "no passkey prompt for it");
    c.click(&k, "Forget this team").await;
    c.click(&k, "Forget").await;
    c.sees(&k, "Sign in to Northwind Films").await;
    assert_eq!(c.eval(&k, &format!("JSON.parse(localStorage.getItem('pluck-team-pins'))[{tid}]")).await, real, "pinned again after the confirmed forget");
    ok("team key mismatch");
    let old = host_op(&mut h, json!({"op": "people"})).await["team"]["link"].clone();
    assert_eq!(host_op(&mut h, json!({"op": "team-reset"})).await["ok"], true);
    assert_ne!(host_op(&mut h, json!({"op": "people"})).await["team"]["link"], old);
    c.go(&k, "about:blank").await;
    c.go(&k, &format!("{origin}/r/{ROOM}#{LINK_KEY}.{PUB}")).await;
    c.sees(&k, "started over with a new key").await;
    assert_ne!(c.eval(&k, &format!("JSON.parse(localStorage.getItem('pluck-team-pins'))[{tid}]")).await, real, "the pin follows the signed move");
    ok("team moved");

    let _ = chrome.kill().await;
    let _ = std::fs::remove_dir_all(base);
    let _ = std::fs::remove_dir_all(profile);
}
