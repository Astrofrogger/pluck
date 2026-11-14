// pluck-iroh: Edit Anywhere's link between the home Mac and the office Mac, on iroh (QUIC,
// dialed by public key, hole punching, relay fallback). Outbound only, no accounts.
//
//   office: accepts iroh connections (ALPN "pluck/1") from allowed node ids, and from any node
//           provisionally while a pairing slot is open (Pluck's pairing decides), and hands each
//           stream to 127.0.0.1:<port>, reporting {"stream":{"peer","port"}} (its local port) first.
//   home:   opens 127.0.0.1:<random>; each TCP connection there becomes a stream to the office.
//
// Settings: one JSON line on stdin:
//   {"mode":"office"|"home","keyFile","port","allow":[ids],"office":id,"officeRelay":url,
//    "officeAddrs":["ip:port"],"relay":url,"local":bool,"relayOnly":bool}
// ("relay": own relay instead of iroh's public ones; "local": no relays or lookups, for tests.)
// Later stdin lines (office): {"allow":[ids]}, {"pair":secs} (adds one single-use slot, at most
// 15 minutes), {"pair":0} (closes all), {"paired":id} (Pluck paired it: allowed, one slot used;
// with none left, provisional connections close). Reports: JSON lines on stdout. Quits when
// stdin closes.
use std::{
    collections::HashSet,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use iroh::{
    Endpoint, EndpointAddr, EndpointId, RelayMap, RelayMode, RelayUrl, SecretKey,
    endpoint::{Connection, ConnectionError, presets},
};
use n0_future::StreamExt;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
};

const ALPN: &[u8] = b"pluck/1";
const MAX_PAIR: u64 = 15 * 60;

fn report(v: Value) {
    println!("{v}"); // println! locks stdout, so lines never interleave
}

#[tokio::main]
async fn main() {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let cfg: Value = match lines.next_line().await {
        Ok(Some(l)) => serde_json::from_str(&l).unwrap_or(Value::Null),
        _ => Value::Null,
    };
    if let Err(e) = run(cfg, lines).await {
        report(json!({"error": format!("{e:#}")}));
        std::process::exit(1);
    }
}

fn parse_ids(v: &Value) -> HashSet<EndpointId> {
    v.as_array().into_iter().flatten().filter_map(|s| s.as_str()?.parse().ok()).collect()
}

fn load_key(path: &str) -> Result<SecretKey> {
    if let Ok(b) = std::fs::read(path) {
        if let Ok(b) = <[u8; 32]>::try_from(b) {
            return Ok(SecretKey::from_bytes(&b));
        }
        // Damaged (a cut-short write): it can't be mended, and failing would leave no way on from
        // within Pluck. Kept aside; the new key gives this Mac a new id, so links need re-inviting.
        let _ = std::fs::rename(path, format!("{path}.damaged"));
        report(json!({"error": "This Mac's Edit Anywhere key was damaged, so it has a new one. Paired Macs need a new invitation."}));
    }
    let key = SecretKey::generate();
    use std::{io::Write, os::unix::fs::OpenOptionsExt};
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
        .and_then(|mut f| f.write_all(&key.to_bytes()))
        .context("can't save key")?;
    Ok(key)
}

struct Gate {
    allow: HashSet<EndpointId>,
    /// Connections let in, so a Mac removed from the list is cut off at once.
    conns: Vec<Connection>,
    /// Open pairing slots (one per invitation), each until its expiry. While one is open any Mac
    /// gets in provisionally (dialing alone uses nothing up); Pluck's {"paired"} uses one.
    pairing: Vec<Instant>,
}

impl Gate {
    fn open(&mut self) -> bool {
        let now = Instant::now();
        self.pairing.retain(|t| now < *t);
        !self.pairing.is_empty()
    }

    fn admit(&mut self, peer: EndpointId) -> bool {
        self.allow.contains(&peer) || self.open()
    }

    /// Pluck paired `peer` (with an invitation's code): allowed from now on, one slot used.
    fn paired(&mut self, peer: EndpointId) {
        self.allow.insert(peer);
        if self.open() {
            let soonest = (0..self.pairing.len()).min_by_key(|i| self.pairing[*i]).unwrap_or(0);
            self.pairing.remove(soonest);
        }
        self.cut();
    }

    /// Closes the connections no longer let in: not allowed, once no invitation is open.
    fn cut(&mut self) {
        let open = self.open();
        let allow = &self.allow;
        self.conns.retain(|c| {
            if c.close_reason().is_some() {
                return false;
            }
            let keep = open || allow.contains(&c.remote_id());
            if !keep {
                c.close(1u32.into(), b"not allowed");
            }
            keep
        });
    }
}

async fn run(cfg: Value, mut lines: tokio::io::Lines<BufReader<tokio::io::Stdin>>) -> Result<()> {
    let mode = cfg["mode"].as_str().unwrap_or("").to_string();
    let port = cfg["port"].as_u64().filter(|p| *p > 0 && *p < 65536).context("bad settings")? as u16;
    let key = load_key(cfg["keyFile"].as_str().context("bad settings")?)?;

    let local = cfg["local"].as_bool() == Some(true);
    let mut b = if local {
        Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Disabled)
    } else {
        Endpoint::builder(presets::N0)
    }
    .secret_key(key);
    // Relays: our own one (if set) instead of iroh's public ones, plus the office's from the
    // link, so a home Mac also reaches an office that uses its own relay.
    let own: Option<RelayUrl> = match cfg["relay"].as_str().filter(|u| !u.is_empty()) {
        Some(u) => Some(u.parse().context("bad relay address")?),
        None => None,
    };
    let office_relay: Option<RelayUrl> = cfg["officeRelay"].as_str().and_then(|u| u.parse().ok());
    if !local && (own.is_some() || office_relay.is_some()) {
        let map = match own {
            Some(u) => RelayMap::from_iter([u]),
            None => iroh::defaults::prod::default_relay_map(),
        };
        if let Some(u) = &office_relay {
            map.extend(&RelayMap::from_iter([u.clone()]));
        }
        b = b.relay_mode(RelayMode::Custom(map));
    }
    if cfg["relayOnly"].as_bool() == Some(true) {
        b = b.clear_ip_transports(); // testing: forces traffic through the relay
    }
    if mode == "office" {
        b = b.alpns(vec![ALPN.to_vec()]);
    }
    let ep = b.bind().await.context("can't start")?;
    if !local && tokio::time::timeout(Duration::from_secs(20), ep.online()).await.is_err() {
        report(json!({"error": "No relay answered. Check the internet connection."}));
    }
    let relay = ep.addr().relay_urls().next().map(|u| u.to_string());
    let addrs: Vec<String> = ep.bound_sockets().iter().map(|a| a.to_string()).collect();
    report(json!({"state": "running", "id": ep.id().to_string(), "relay": relay, "addrs": addrs}));

    match mode.as_str() {
        "office" => {
            let gate = Arc::new(Mutex::new(Gate { allow: parse_ids(&cfg["allow"]), conns: Vec::new(), pairing: Vec::new() }));
            let g = gate.clone();
            // Invitations that ran out: Macs that came in on one but never paired go.
            let expiry = gate.clone();
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    expiry.lock().unwrap().cut();
                }
            });
            tokio::spawn(async move {
                // Commands; quit with Pluck.
                while let Ok(Some(l)) = lines.next_line().await {
                    let Ok(v) = serde_json::from_str::<Value>(&l) else { continue };
                    let mut g = g.lock().unwrap();
                    if v.get("allow").is_some() {
                        g.allow = parse_ids(&v["allow"]);
                        g.cut();
                    }
                    if let Some(id) = v["paired"].as_str().and_then(|s| s.parse().ok()) {
                        g.paired(id);
                    }
                    if let Some(s) = v["pair"].as_u64() {
                        if s > 0 {
                            g.pairing.push(Instant::now() + Duration::from_secs(s.min(MAX_PAIR)));
                        } else {
                            g.pairing.clear();
                        }
                        report(json!({"state": if s > 0 { "pairing" } else { "pairingClosed" }}));
                    }
                }
                std::process::exit(0);
            });
            office(ep, gate, port).await
        }
        "home" => {
            tokio::spawn(async move {
                while let Ok(Some(_)) = lines.next_line().await {}
                std::process::exit(0);
            });
            let id: EndpointId = cfg["office"].as_str().context("no office")?.parse().context("bad office id")?;
            let mut addr = EndpointAddr::new(id);
            if let Some(u) = office_relay.filter(|_| !local) {
                addr = addr.with_relay_url(u); // from the link: no lookup needed
            }
            for a in cfg["officeAddrs"].as_array().into_iter().flatten() {
                if let Some(a) = a.as_str().and_then(|a| a.parse().ok()) {
                    addr = addr.with_ip_addr(a);
                }
            }
            home(ep, addr, local).await
        }
        _ => Err(anyhow!("unknown mode")),
    }
}

/// Reports the connection's chosen path (and again whenever it changes). `refused` (home) is set
/// when the office turns this Mac away.
fn watch(conn: Connection, refused: Option<Arc<AtomicBool>>) {
    tokio::spawn(async move {
        let peer = conn.remote_id().to_string();
        let mut last = String::new();
        let mut paths = conn.paths_stream();
        while let Some(list) = paths.next().await {
            let (mut direct, mut relay) = (false, false);
            let mut rtt = None;
            for p in &list {
                if p.is_selected() {
                    rtt = Some(p.rtt().as_secs_f64() * 1000.0);
                    if p.is_relay() { relay = true } else { direct = true }
                }
            }
            let kind = match (direct, relay) {
                (true, false) => "direct",
                (false, true) => "relay",
                (true, true) => "mixed",
                _ => "none",
            };
            if kind != last {
                last = kind.to_string();
                report(json!({"conn": {"peer": peer, "type": kind, "rtt": rtt}}));
            }
        }
        // The office's "not allowed" (code 1): an invitation already used or expired, or a Mac
        // that was removed there.
        if let Some(ConnectionError::ApplicationClosed(c)) = conn.close_reason() {
            if c.error_code == 1u32.into() {
                if let Some(r) = &refused {
                    r.store(true, Ordering::Relaxed);
                }
                report(json!({"refused": peer}));
            }
        }
        let why = conn.close_reason().map(|e| e.to_string());
        report(json!({"closed": peer, "reason": why}));
    });
}

async fn office(ep: Endpoint, gate: Arc<Mutex<Gate>>, port: u16) -> Result<()> {
    report(json!({"state": "listening"}));
    while let Some(incoming) = ep.accept().await {
        let gate = gate.clone();
        tokio::spawn(async move {
            let Ok(conn) = async { incoming.accept()?.await }.await else { return };
            let peer = conn.remote_id();
            let ok = {
                let mut g = gate.lock().unwrap();
                let ok = g.admit(peer);
                if ok {
                    g.conns.retain(|c| c.close_reason().is_none());
                    g.conns.push(conn.clone());
                }
                ok
            };
            if !ok {
                report(json!({"refused": peer.to_string()}));
                conn.close(1u32.into(), b"not allowed");
                return;
            }
            watch(conn.clone(), None);
            let peer = peer.to_string();
            while let Ok((send, mut recv)) = conn.accept_bi().await {
                let peer = peer.clone();
                tokio::spawn(async move {
                    let mut hello = [0u8; 1]; // home's first byte: makes the stream visible
                    if recv.read_exact(&mut hello).await.is_err() { return }
                    let Ok(tcp) = TcpStream::connect(("127.0.0.1", port)).await else { return };
                    // Which Mac this local connection carries (Pluck keys pairing by it), before any of its bytes.
                    let Ok(local) = tcp.local_addr() else { return };
                    report(json!({"stream": {"peer": peer, "port": local.port()}}));
                    pipe(tcp, send, recv).await;
                });
            }
        });
    }
    Ok(())
}

#[derive(Default)]
struct HomeLink {
    conn: Option<Connection>,
    /// When the last dial failed: for a few seconds others fail at once instead of dialing again.
    failed: Option<Instant>,
    /// The office turned this Mac away: no more dialing (Pluck starts a new helper to join again).
    refused: Arc<AtomicBool>,
    /// The office found by its id alone, the link's relay being out of date: dialed that way from now on.
    found: Option<EndpointAddr>,
}

async fn home(ep: Endpoint, office: EndpointAddr, local: bool) -> Result<()> {
    let ln = TcpListener::bind("127.0.0.1:0").await?;
    let shared: Arc<tokio::sync::Mutex<HomeLink>> = Default::default();
    // Connect once up front so the first report (type, RTT) comes early; later on demand.
    if let Err(e) = connection(&ep, &office, &shared, local).await {
        report(json!({"error": format!("Can't reach the office Mac: {e:#}")}));
    }
    report(json!({"state": "listening", "listen": ln.local_addr()?.to_string()}));
    loop {
        let (tcp, _) = ln.accept().await?;
        let (ep, office, shared) = (ep.clone(), office.clone(), shared.clone());
        tokio::spawn(async move {
            let conn = match connection(&ep, &office, &shared, local).await {
                Ok(c) => c,
                Err(_) if shared.lock().await.refused.load(Ordering::Relaxed) => return,
                Err(e) => return report(json!({"error": format!("Can't reach the office Mac: {e:#}")})),
            };
            let Ok((mut send, recv)) = conn.open_bi().await else { return };
            if send.write_all(&[0]).await.is_err() { return }
            pipe(tcp, send, recv).await;
        });
    }
}

/// The one QUIC connection to the office, made again when it has closed. The lock is held while
/// dialing on purpose: connections arriving meanwhile share that one dial and its outcome.
async fn connection(
    ep: &Endpoint,
    office: &EndpointAddr,
    shared: &tokio::sync::Mutex<HomeLink>,
    local: bool,
) -> Result<Connection> {
    let mut link = shared.lock().await;
    if let Some(c) = link.conn.as_ref().filter(|c| c.close_reason().is_none()) {
        return Ok(c.clone());
    }
    if link.refused.load(Ordering::Relaxed) {
        bail!("the office Mac turned this Mac away");
    }
    if link.failed.is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
        bail!("not reachable just now");
    }
    let dial = |addr: EndpointAddr, secs| async move {
        tokio::time::timeout(Duration::from_secs(secs), ep.connect(addr, ALPN))
            .await
            .map_err(|_| anyhow!("timed out"))?
            .map_err(anyhow::Error::from)
    };
    let mut result = dial(link.found.clone().unwrap_or_else(|| office.clone()), 20).await;
    // The link's relay can be out of date (the office moved to another one), and with a relay
    // given iroh doesn't look the office up: try again by its id alone.
    if result.is_err() && !local && link.found.is_none() && office.relay_urls().next().is_some() {
        let mut bare = EndpointAddr::new(office.id);
        for a in office.ip_addrs() {
            bare = bare.with_ip_addr(*a);
        }
        result = dial(bare.clone(), 15).await;
        if result.is_ok() {
            link.found = Some(bare);
        }
    }
    match result {
        Ok(c) => {
            watch(c.clone(), Some(link.refused.clone()));
            link.conn = Some(c.clone());
            link.failed = None;
            Ok(c)
        }
        Err(e) => {
            link.failed = Some(Instant::now());
            Err(e)
        }
    }
}

/// Copies both ways; each side's end of data is passed on as a half-close.
async fn pipe(tcp: TcpStream, mut send: iroh::endpoint::SendStream, mut recv: iroh::endpoint::RecvStream) {
    let _ = tcp.set_nodelay(true);
    let (mut r, mut w) = tcp.into_split();
    let up = async {
        let _ = tokio::io::copy(&mut r, &mut send).await;
        let _ = send.finish();
    };
    let down = async {
        let _ = tokio::io::copy(&mut recv, &mut w).await;
        let _ = w.shutdown().await;
    };
    tokio::join!(up, down);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_slots_are_used_by_pairing_not_dialing() {
        let (a, b, c) = (SecretKey::generate().public(), SecretKey::generate().public(), SecretKey::generate().public());
        let mut g = Gate { allow: HashSet::new(), conns: vec![], pairing: vec![] };
        assert!(!g.admit(a), "closed gate refuses");
        g.pairing.push(Instant::now() + Duration::from_secs(60));
        assert!(g.admit(b) && g.admit(a), "an open slot lets anyone in provisionally, using nothing");
        g.paired(a);
        assert!(!g.admit(b), "pairing used the slot up");
        assert!(g.admit(a), "the paired one stays allowed");
        g.pairing.push(Instant::now() + Duration::from_secs(60));
        g.pairing.push(Instant::now() + Duration::from_secs(120));
        g.paired(b);
        assert!(g.admit(c) && g.pairing.len() == 1, "one pairing uses one slot of two");
        assert!(g.pairing[0] > Instant::now() + Duration::from_secs(90), "the soonest-ending slot goes first");
        g.pairing = vec![Instant::now() - Duration::from_secs(1)];
        assert!(!g.admit(c), "an expired slot refuses");
    }
}
