// One WebSocket per room to <signal>/<roomId> (pluck.tools' Room Durable Object): registers with
// the room's reg key, passes offers/candidates/peer-left to the RTC loop and sends its answers,
// candidates and kicks. Reconnects with backoff 1 → 60 s; stops on "taken". Rooms go by rank
// (§13.3): a main host ("host", 4) beats a backup host ("backup", 3) beats an always-on Mac hosting
// published bundles ("always-on", 2) beats the editor's Pluck ("mac", 1). One refused with
// {"t":"taken","by":…} waits in "standby" and retries (hosts 20 s, mac 60 s, ± 20 %), so it takes
// over once the room's holder has gone quiet for 50 s. (A Worker before "always-on" ranks it as "mac".)
// Fastest-host routing: a backup also says `standby`, and a Worker that knows it keeps it registered beside a live
// main; the Room then sends it the viewers it uploads clearly faster for. Every host tells the Room its measured
// upload (uplink.rs) and, a backup, whether the room's link is ready here and its copies are the main's own ("info").
// Never serve (`neverServe`, the editor's Mac when the owner has a NAS or an always-on Mac): it still registers, so the room is claimed with the owner's
// reg and it learns who holds it, but a room it would hold itself it closes at once ("nohost") and retries on the
// standby delay; it never answers an offer. Clients are served only by a NAS (or, with none, an always-on Mac).
use std::{collections::HashMap, sync::{Arc, LazyLock, Mutex, atomic::{AtomicBool, Ordering}}, time::Duration};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::{sync::mpsc, task::JoinHandle, time::timeout};
use tokio_tungstenite::tungstenite::{Message, protocol::frame::coding::CloseCode};

use crate::{Ev, log, report};

pub const MAX_FRAME: usize = 16 * 1024;

/// Set once at start-up: host mode (NAS, or a Mac hosting published bundles) registers with prio "host".
pub static HOST: AtomicBool = AtomicBool::new(false);
/// A backup host registers with prio "backup".
pub static BACKUP: AtomicBool = AtomicBool::new(false);
/// A backup whose copies are the main's own bytes (--quality same).
pub static SAME: AtomicBool = AtomicBool::new(false);
/// The main: the owner prefers the fastest host even when its copies are lighter (`prefer-fastest`, on unless turned off).
pub static FASTEST: AtomicBool = AtomicBool::new(false);
/// Never serve a browser (settings `neverServe`): see the header.
pub static NEVER_SERVE: AtomicBool = AtomicBool::new(false);
/// Host mode on an always-on Mac (settings `alwaysOn`): ranks below both NAS roles.
pub static ALWAYS_ON: AtomicBool = AtomicBool::new(false);

pub fn prio() -> &'static str {
    prio_of(BACKUP.load(Ordering::Relaxed), HOST.load(Ordering::Relaxed), ALWAYS_ON.load(Ordering::Relaxed))
}

fn prio_of(backup: bool, host: bool, always_on: bool) -> &'static str {
    match (backup, host, always_on) {
        (true, ..) => "backup",
        (_, true, true) => "always-on",
        (_, true, false) => "host",
        _ => "mac",
    }
}

pub const PING: Duration = Duration::from_secs(20);

/// How long a standby helper waits before trying again: 20 s (hosts) or 60 s (a Mac), ± 20 %.
/// PLUCK_STANDBY_SECS overrides the base (tests).
fn standby_delay(prio: &str) -> Duration {
    #[cfg(test)]
    if let Some(s) = TEST_STANDBY.get() {
        return Duration::from_secs_f64(s);
    }
    let dflt = if prio == "mac" { 60.0 } else { 20.0 };
    let base: f64 = std::env::var("PLUCK_STANDBY_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(dflt);
    Duration::from_secs_f64(base * (0.8 + 0.4 * rand::random::<f64>()))
}

#[cfg(test)]
thread_local! {
    /// Tests on a current-thread runtime: the standby delay, without touching the environment other tests read.
    static TEST_STANDBY: std::cell::Cell<Option<f64>> = const { std::cell::Cell::new(None) };
}

pub enum Up {
    Offer { room: String, peer: String, sdp: String },
    Candidate { peer: String, cand: Value },
    PeerLeft { room: String, peer: String },
}

pub struct Room {
    pub tx: mpsc::UnboundedSender<Value>,
    /// The link's expiry, sent at registration: the Room keeps a tombstone until then (§13.24). A change re-registers.
    pub expires: Option<String>,
    /// Own TURN credentials only while the room's link is live (a paused or past-deadline link keeps its room).
    pub turn: Arc<AtomicBool>,
    /// A backup: the link's current versions are all here and it needs nothing only the main has (host::backup_ready).
    pub ready: Arc<AtomicBool>,
    task: JoinHandle<()>,
}

impl Drop for Room {
    fn drop(&mut self) {
        self.task.abort(); // closes the socket
    }
}

pub fn valid_room(r: &str) -> bool {
    r.len() == 22 && r.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn valid_peer(p: &str) -> bool {
    (3..=32).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

#[allow(clippy::too_many_arguments)]
pub fn spawn(base: &str, room: String, reg: String, join: String, expires: Option<String>, turn: bool, ev: mpsc::UnboundedSender<Ev>) -> Room {
    let url = format!("{}/{room}", base.trim_end_matches('/'));
    let (tx, rx) = mpsc::unbounded_channel();
    let turn = Arc::new(AtomicBool::new(turn));
    let ready = Arc::new(AtomicBool::new(false));
    Room { tx, expires: expires.clone(), turn: turn.clone(), ready: ready.clone(), task: tokio::spawn(run(url, room, reg, join, expires, turn, ready, ev, rx)) }
}

/// Each room's last state, and whether the Room ever said `registered` (or stood us by for another of the owner's
/// servers) since this process started: a level-3 link is shown only once that's true (§13.24 H1), and "taken" is
/// the owner's problem to see (the admin page asks via `room_state`).
static STATES: LazyLock<Mutex<HashMap<String, (String, bool)>>> = LazyLock::new(Default::default);

pub fn room_state(room: &str) -> Option<(String, bool)> {
    STATES.lock().unwrap().get(room).cloned()
}

fn note(room: &str, s: &str) {
    let mut m = STATES.lock().unwrap();
    let e = m.entry(room.to_owned()).or_insert_with(|| (String::new(), false));
    e.0 = s.to_owned();
    // "nohost": the Room took our register (the owner's reg) before we let go, so the room is the owner's all the same.
    e.1 |= s == "active" || s == "standby" || s == "nohost";
}

pub(crate) fn state(room: &str, s: &str) {
    note(room, s);
    report(json!({"room": {"room": room, "state": s}}));
}

/// `standby` behind another of the owner's servers (its reg matched, so the room is the owner's).
fn standby(room: &str, by: &str) {
    note(room, "standby");
    report(json!({"room": {"room": room, "state": "standby", "by": by}}));
}

enum End {
    Taken,
    Erased,
    Standby(String),
    /// Never serve: the Room would have made us the holder (none of the owner's hosts holds it), so we closed.
    NoHost,
    Lost { registered: bool },
}

#[allow(clippy::too_many_arguments)]
async fn run(url: String, room: String, reg: String, join: String, expires: Option<String>, turn: Arc<AtomicBool>, ready: Arc<AtomicBool>, ev: mpsc::UnboundedSender<Ev>, mut down: mpsc::UnboundedReceiver<Value>) {
    let mut backoff = 1;
    loop {
        let started = std::time::Instant::now();
        match tokio_tungstenite::connect_async(url.as_str()).await {
            Ok((ws, _)) => match session(ws, &room, &reg, &join, expires.as_deref(), &turn, &ready, NEVER_SERVE.load(Ordering::Relaxed), &ev, &mut down).await {
                // Someone else registered this room first (or holds it since it lapsed): the owner sees it as a problem
                // with "Make a New Link" (Pluck's link panel, the host's admin page), never a link that looks fine.
                End::Taken => return state(&room, "taken"),
                End::Erased => return state(&room, "erased"), // 4005: the owner erased the room (link deleted): stop, never re-register
                End::Standby(by) => {
                    standby(&room, &by);
                    tokio::time::sleep(standby_delay(prio())).await;
                    continue;
                }
                // No NAS holds the room: this Mac never serves it, so it waits and asks again like a standby.
                End::NoHost => {
                    state(&room, "nohost");
                    tokio::time::sleep(standby_delay(prio())).await;
                    continue;
                }
                // Only a session that held for a while starts the backoff again (one replaced at once doesn't).
                End::Lost { registered } if registered && started.elapsed() > Duration::from_secs(60) => backoff = 1,
                End::Lost { .. } => {}
            },
            Err(e) => log(format!("signal {room}: {e}")),
        }
        state(&room, "offline");
        tokio::time::sleep(Duration::from_secs(backoff)).await;
        backoff = (backoff * 2).min(60);
    }
}

#[allow(clippy::too_many_arguments)]
async fn session<S>(ws: S, room: &str, reg: &str, join: &str, expires: Option<&str>, turn: &AtomicBool, ready: &AtomicBool, never: bool, ev: &mpsc::UnboundedSender<Ev>, down: &mut mpsc::UnboundedReceiver<Value>) -> End
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + SinkExt<Message> + Unpin,
{
    let (mut w, mut r) = ws.split();
    while down.try_recv().is_ok() {} // answers queued while offline are stale
    let mut registered = false;
    // What the Room last heard of our speed and readiness; None until it says it takes `info`.
    let mut told: Option<Value> = None;
    let first = register_msg(reg, join, expires, ready.load(Ordering::Relaxed));
    if w.send(Message::text(first.to_string())).await.is_err() {
        return End::Lost { registered };
    }
    let mut ping = tokio::time::interval(PING);
    loop {
        tokio::select! {
            m = timeout(Duration::from_secs(75), r.next()) => {
                let m = match m {
                    Ok(Some(Ok(m))) => m,
                    Ok(Some(Err(e))) => { log(format!("signal {room}: {e}")); return End::Lost { registered } }
                    Ok(None) => return End::Lost { registered },
                    Err(_) => { log(format!("signal {room}: silent for 75 s")); return End::Lost { registered } }
                };
                let text = match m {
                    Message::Text(t) if t.len() <= MAX_FRAME => t,
                    Message::Close(Some(c)) if c.code == CloseCode::Library(4005) => return End::Erased,
                    Message::Close(c) => {
                        // 4000 "replaced": a higher rank (or another Mac) took the room; 4004 "stale": we went quiet.
                        if let Some(c) = c.filter(|c| matches!(c.code, CloseCode::Library(4000) | CloseCode::Library(4003) | CloseCode::Library(4004))) {
                            log(format!("signal {room}: {} {}", u16::from(c.code), c.reason));
                        }
                        return End::Lost { registered };
                    }
                    _ => continue,
                };
                let Ok(v) = serde_json::from_str::<Value>(&text) else { continue };
                let s = |k: &str| v[k].as_str().map(str::to_owned);
                match v["t"].as_str().unwrap_or("") {
                    "registered" if never => {
                        // Holding the room (or standing by beside a main, where the Room may still route viewers to
                        // us) would mean serving clients from this Mac: let go at once.
                        let _ = w.close().await;
                        return if v["standby"] == true { End::Standby("host".into()) } else { End::NoHost };
                    }
                    "registered" => {
                        registered = true;
                        if let Some(ms) = v["now"].as_i64() {
                            crate::host::set_clock(ms);
                        }
                        if v["info"] == true {
                            told = Some(info(ready.load(Ordering::Relaxed)));
                            if told.as_ref() != Some(&info_of(&first)) && w.send(Message::text(info_msg(told.as_ref().unwrap()))).await.is_err() {
                                return End::Lost { registered };
                            }
                        }
                        // Beside a live main: it serves the viewers it's faster for; "standby" as before for the Mac's view.
                        if v["standby"] == true {
                            standby(room, "host");
                        } else {
                            state(room, "active");
                        }
                        if let Some(r) = v["relay"].as_str() {
                            report(json!({"relay": {"room": room, "state": r}}));
                        }
                    }
                    "relay-state" => report(json!({"relay": {"room": room, "state": v["state"]}})),
                    "join" => if let (Some(peer), Some(t)) = (s("peer").filter(|p| valid_peer(p)), crate::relay::config().turn.as_ref()) {
                        // Our own TURN for this browser, within the DO's 2 s.
                        let now = crate::host::now_secs().max(0) as u64;
                        let servers = if turn.load(Ordering::Relaxed) { crate::relay::ice(t, &peer, now) } else { json!([]) };
                        let ice = json!({"t": "ice", "peer": peer, "ice": servers});
                        if w.send(Message::text(ice.to_string())).await.is_err() {
                            return End::Lost { registered };
                        }
                    },
                    "taken" if v["by"] == "host" || v["by"] == "backup" || v["by"] == "always-on" => return End::Standby(v["by"].as_str().unwrap_or("").to_owned()),
                    "error" if v["code"] == "taken" => return End::Taken,
                    "error" => log(format!("signal {room}: {v}")),
                    "offer" if never => log(format!("signal {room}: offer dropped (never serve)")),
                    "offer" => if let (Some(peer), Some(sdp)) = (s("peer").filter(|p| valid_peer(p)), s("sdp")) {
                        let _ = ev.send(Ev::Signal(Up::Offer { room: room.to_owned(), peer, sdp }));
                    },
                    "candidate" => if let Some(peer) = s("peer").filter(|p| valid_peer(p)) {
                        let _ = ev.send(Ev::Signal(Up::Candidate { peer, cand: v["cand"].clone() }));
                    },
                    "peer-left" => if let Some(peer) = s("peer") {
                        let _ = ev.send(Ev::Signal(Up::PeerLeft { room: room.to_owned(), peer }));
                    },
                    _ => {}
                }
            }
            Some(out) = down.recv() => {
                let t = out.to_string();
                if t.len() > MAX_FRAME {
                    log(format!("signal {room}: dropped a {} byte message", t.len()));
                } else if w.send(Message::text(t)).await.is_err() {
                    return End::Lost { registered };
                }
            }
            _ = ping.tick() => {
                if w.send(Message::text(r#"{"t":"ping"}"#)).await.is_err() {
                    return End::Lost { registered };
                }
                // A new measurement, a copy that finished, or the owner's setting: the Room hears it within a ping.
                if let Some(t) = told.as_mut() {
                    let now = info(ready.load(Ordering::Relaxed));
                    if now != *t {
                        if w.send(Message::text(info_msg(&now))).await.is_err() {
                            return End::Lost { registered };
                        }
                        *t = now;
                    }
                }
            }
        }
    }
}

/// What the Room routes by: only numbers and flags (no address, nothing that names the host).
/// up: Mbit/s, null = unknown; ready/same: a backup's; fastest: the main's owner setting.
pub fn info(ready: bool) -> Value {
    let backup = BACKUP.load(Ordering::Relaxed);
    json!({"up": crate::uplink::mbps(), "ready": backup && ready, "same": backup && SAME.load(Ordering::Relaxed),
        "fastest": !backup && FASTEST.load(Ordering::Relaxed)})
}

fn info_of(m: &Value) -> Value {
    json!({"up": m["up"], "ready": m["ready"], "same": m["same"], "fastest": m["fastest"]})
}

fn info_msg(i: &Value) -> String {
    let mut m = i.clone();
    m["t"] = json!("info");
    m.to_string()
}

/// `mac-register` (protocol 2: the owner-only reg and the link's join hash) with this helper's rank,
/// the owner's relay token, whether it hands out its own TURN, and `info`. A backup offers to stand by.
/// `expires`: the link's expiry, how long the Room keeps its tombstone (§13.24; none = a year).
pub fn register_msg(reg: &str, join: &str, expires: Option<&str>, ready: bool) -> Value {
    let mut m = json!({"t": "mac-register", "v": 2, "reg": reg, "join": join, "prio": prio()});
    if let Some(e) = expires {
        m["expires"] = json!(e);
    }
    for (k, v) in info(ready).as_object().unwrap() {
        m[k] = v.clone();
    }
    if BACKUP.load(Ordering::Relaxed) {
        m["standby"] = json!(true);
    }
    let c = crate::relay::config();
    if let Some(t) = &c.token {
        m["relay"] = json!(t);
    }
    if c.turn.is_some() {
        m["ownIce"] = json!(true);
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn room_states_remember_a_registration() {
        assert_eq!(room_state("S1"), None);
        state("S1", "offline");
        assert_eq!(room_state("S1"), Some(("offline".into(), false)), "not shown yet");
        state("S1", "active");
        state("S1", "offline");
        assert_eq!(room_state("S1"), Some(("offline".into(), true)), "once registered, the link can be shown");
        standby("S2", "host");
        assert_eq!(room_state("S2"), Some(("standby".into(), true)), "another of the owner's servers holds it");
        state("S3", "taken");
        assert_eq!(room_state("S3"), Some(("taken".into(), false)));
    }

    #[test]
    fn ids() {
        assert!(valid_room("7E1RkYmx_jTN80i5w8xmOg"));
        assert!(!valid_room("7E1RkYmx_jTN80i5w8xmO"));
        assert!(!valid_room("7E1RkYmx/jTN80i5w8xmOg"));
        assert!(valid_peer("p_Yq3"));
        assert!(!valid_peer("p_../x"));
    }

    #[test]
    fn standby_delays_and_ranks() {
        for _ in 0..50 {
            let d = standby_delay("mac").as_secs_f64();
            assert!((48.0..=72.0).contains(&d), "mac {d}");
            let d = standby_delay("backup").as_secs_f64();
            assert!((16.0..=24.0).contains(&d), "backup {d}");
        }
        assert_eq!(PING, Duration::from_secs(20));
        let m = register_msg("r", "j", None, true);
        assert_eq!((m["prio"].as_str(), m["v"].as_u64(), m["join"].as_str(), m.get("expires")), (Some("mac"), Some(2), Some("j"), None));
        assert_eq!(register_msg("r", "j", Some("2027-01-01T00:00:00Z"), false)["expires"], "2027-01-01T00:00:00Z");
        assert_eq!((m["ready"].as_bool(), m["standby"].as_bool()), (Some(false), None), "only a backup is ready or stands by");
        assert_eq!((m["up"].clone(), m["same"].clone()), (info(true)["up"].clone(), json!(false)));
    }

    // Never serve (a Mac whose owner has a NAS), against a local stand-in for the Room.
    type Server = tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>;

    async fn pair() -> (tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, Server) {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/room", l.local_addr().unwrap());
        let (c, s) = tokio::join!(tokio_tungstenite::connect_async(url), async { tokio_tungstenite::accept_async(l.accept().await.unwrap().0).await.unwrap() });
        (c.unwrap().0, s)
    }

    async fn talk(s: &mut Server, replies: &[Value]) {
        let m = s.next().await.unwrap().unwrap();
        assert_eq!(serde_json::from_str::<Value>(m.to_text().unwrap()).unwrap()["t"], "mac-register");
        for r in replies {
            s.send(Message::text(r.to_string())).await.unwrap();
        }
    }

    async fn session_with(never: bool, replies: Vec<Value>) -> (End, Vec<Ev>, bool) {
        let (c, mut s) = pair().await;
        let (ev, mut evs) = mpsc::unbounded_channel();
        let (_tx, mut down) = mpsc::unbounded_channel();
        let (t, r) = (AtomicBool::new(false), AtomicBool::new(false));
        let server = async move {
            talk(&mut s, &replies).await;
            // What the client did next: closed (true), or kept the room until we hung up (false).
            match timeout(Duration::from_millis(500), s.next()).await {
                Ok(Some(Ok(Message::Close(_))) | None) => true,
                _ => { let _ = s.close(None).await; false }
            }
        };
        let (end, closed) = tokio::join!(session(c, "R", "r", "j", None, &t, &r, never, &ev, &mut down), server);
        let mut got = vec![];
        while let Ok(e) = evs.try_recv() { got.push(e); }
        (end, got, closed)
    }

    fn offer() -> Value { json!({"t": "offer", "peer": "p_abc", "sdp": "v=0"}) }

    #[tokio::test]
    async fn never_serve_drops_offers_and_lets_go() {
        let (end, evs, closed) = session_with(true, vec![offer(), json!({"t": "registered", "info": true})]).await;
        assert!(matches!(end, End::NoHost) && evs.is_empty() && closed, "no offer reaches the RTC loop, and the room is let go");
        // Beside a live main the Room may route viewers to a standby: a never-serve helper doesn't stay.
        let (end, _, closed) = session_with(true, vec![json!({"t": "registered", "standby": true})]).await;
        assert!(matches!(end, End::Standby(ref by) if by == "host") && closed);
    }

    #[tokio::test]
    async fn never_serve_stands_by_as_before() {
        for never in [true, false] {
            for by in ["host", "backup", "always-on"] {
                let (end, _, _) = session_with(never, vec![json!({"t": "taken", "by": by})]).await;
                assert!(matches!(end, End::Standby(ref b) if b == by), "never {never}, by {by}");
            }
        }
        assert_eq!([prio_of(false, false, false), prio_of(false, true, false), prio_of(false, true, true), prio_of(true, true, false)],
            ["mac", "host", "always-on", "backup"], "an always-on Mac in host mode ranks below both NAS roles");
    }

    #[tokio::test]
    async fn without_never_serve_the_mac_serves() {
        let (end, evs, closed) = session_with(false, vec![json!({"t": "registered"}), offer()]).await;
        assert!(matches!(end, End::Lost { registered: true }) && !closed);
        assert!(matches!(evs.as_slice(), [Ev::Signal(Up::Offer { peer, .. })] if peer == "p_abc"));
    }

    #[tokio::test]
    async fn never_serve_retries_and_the_room_counts_as_held() {
        TEST_STANDBY.set(Some(0.05));
        NEVER_SERVE.store(true, Ordering::Relaxed);
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("ws://{}", l.local_addr().unwrap());
        let room = "NeverServeRoom00000000".to_string();
        let (ev, _evs) = mpsc::unbounded_channel();
        let r = spawn(&base, room.clone(), "r".into(), "j".into(), None, true, ev);
        for _ in 0..3 {
            let mut s = tokio_tungstenite::accept_async(timeout(Duration::from_secs(5), l.accept()).await.unwrap().unwrap().0).await.unwrap();
            talk(&mut s, &[json!({"t": "registered"})]).await;
            assert!(matches!(timeout(Duration::from_secs(5), s.next()).await.unwrap(), Some(Ok(Message::Close(_))) | None));
        }
        assert_eq!(room_state(&room), Some(("nohost".into(), true)), "registered → nohost, again and again; H1 holds");
        drop(r);
        NEVER_SERVE.store(false, Ordering::Relaxed);
    }

}
