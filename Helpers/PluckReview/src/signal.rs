// One WebSocket per room to <signal>/<roomId> (pluck.tools' Room Durable Object): registers with
// the room's reg key, passes offers/candidates/peer-left to the RTC loop and sends its answers,
// candidates and kicks. Reconnects with backoff 1 → 60 s; stops on "taken". Rooms go by rank
// (§13.3): a main host ("host", 3) beats a backup host ("backup", 2) beats the editor's Pluck
// ("mac", 1). One refused with {"t":"taken","by":…} waits in "standby" and retries (backup 20 s,
// mac 60 s, ± 20 %), so it takes over once the room's holder has gone quiet for 50 s.
use std::{sync::{Arc, atomic::{AtomicBool, Ordering}}, time::Duration};

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

pub fn prio() -> &'static str {
    if BACKUP.load(Ordering::Relaxed) { "backup" } else if HOST.load(Ordering::Relaxed) { "host" } else { "mac" }
}

pub const PING: Duration = Duration::from_secs(20);

/// How long a standby helper waits before trying again: 20 s (hosts) or 60 s (a Mac), ± 20 %.
/// PLUCK_STANDBY_SECS overrides the base (tests).
fn standby_delay(prio: &str) -> Duration {
    let dflt = if prio == "mac" { 60.0 } else { 20.0 };
    let base: f64 = std::env::var("PLUCK_STANDBY_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(dflt);
    Duration::from_secs_f64(base * (0.8 + 0.4 * rand::random::<f64>()))
}

pub enum Up {
    Offer { room: String, peer: String, sdp: String },
    Candidate { peer: String, cand: Value },
    PeerLeft { room: String, peer: String },
}

pub struct Room {
    pub tx: mpsc::UnboundedSender<Value>,
    /// Own TURN credentials only while the room's link is live (a paused or past-deadline link keeps its room).
    pub turn: Arc<AtomicBool>,
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

pub fn spawn(base: &str, room: String, reg: String, join: String, turn: bool, ev: mpsc::UnboundedSender<Ev>) -> Room {
    let url = format!("{}/{room}", base.trim_end_matches('/'));
    let (tx, rx) = mpsc::unbounded_channel();
    let turn = Arc::new(AtomicBool::new(turn));
    Room { tx, turn: turn.clone(), task: tokio::spawn(run(url, room, reg, join, turn, ev, rx)) }
}

fn state(room: &str, s: &str) {
    report(json!({"room": {"room": room, "state": s}}));
}

enum End {
    Taken,
    Erased,
    Standby(String),
    Lost { registered: bool },
}

async fn run(url: String, room: String, reg: String, join: String, turn: Arc<AtomicBool>, ev: mpsc::UnboundedSender<Ev>, mut down: mpsc::UnboundedReceiver<Value>) {
    let mut backoff = 1;
    loop {
        let started = std::time::Instant::now();
        match tokio_tungstenite::connect_async(url.as_str()).await {
            Ok((ws, _)) => match session(ws, &room, &reg, &join, &turn, &ev, &mut down).await {
                End::Taken => return state(&room, "taken"),
                End::Erased => return state(&room, "erased"), // 4005: the owner erased the room (link deleted): stop, never re-register
                End::Standby(by) => {
                    report(json!({"room": {"room": room, "state": "standby", "by": by}}));
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

async fn session<S>(ws: S, room: &str, reg: &str, join: &str, turn: &AtomicBool, ev: &mpsc::UnboundedSender<Ev>, down: &mut mpsc::UnboundedReceiver<Value>) -> End
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + SinkExt<Message> + Unpin,
{
    let (mut w, mut r) = ws.split();
    while down.try_recv().is_ok() {} // answers queued while offline are stale
    let mut registered = false;
    if w.send(Message::text(register_msg(reg, join).to_string())).await.is_err() {
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
                    "registered" => {
                        registered = true;
                        if let Some(ms) = v["now"].as_i64() {
                            crate::host::set_clock(ms);
                        }
                        state(room, "active");
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
                    "taken" if v["by"] == "host" || v["by"] == "backup" => return End::Standby(v["by"].as_str().unwrap_or("").to_owned()),
                    "error" if v["code"] == "taken" => return End::Taken,
                    "error" => log(format!("signal {room}: {v}")),
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
            }
        }
    }
}

/// `mac-register` (protocol 2: the owner-only reg and the link's join hash) with this helper's rank,
/// the owner's relay token and whether it hands out its own TURN.
pub fn register_msg(reg: &str, join: &str) -> Value {
    let mut m = json!({"t": "mac-register", "v": 2, "reg": reg, "join": join, "prio": prio()});
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
        let m = register_msg("r", "j");
        assert_eq!((m["prio"].as_str(), m["v"].as_u64(), m["join"].as_str()), (Some("mac"), Some(2), Some("j")));
    }
}
