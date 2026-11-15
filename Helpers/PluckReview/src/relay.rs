// Relays (spec §13.10). (a) The owner's Cloudflare TURN: the helper registers with the owner's
// relay token and, since it does all I/O for its peers, reports how many bytes each peer moved
// through a relay (`relay-usage`), with a 20 GB cap per peer. (b) "My own relay": TURN REST
// credentials for a coturn with a shared secret, handed to each browser on `join` (`ice`).
use std::sync::OnceLock;

use serde_json::{Value, json};

pub const CAP: u64 = 20_000_000_000; // 20 GB relayed per peer (per credential)
pub const REPORT_SECS: u64 = 300;

pub struct Turn {
    pub secret: Vec<u8>,
    pub urls: Vec<String>,
    pub ttl: u64,
}

#[derive(Default)]
pub struct Config {
    pub token: Option<String>,
    pub turn: Option<Turn>,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

pub fn set(c: Config) {
    let _ = CONFIG.set(c);
}

pub fn config() -> &'static Config {
    CONFIG.get_or_init(Config::default)
}

/// From Pluck's settings line (`relayToken`, `turn`) or, for a host, the environment
/// (PLUCK_RELAY_TOKEN, PLUCK_TURN_SECRET, PLUCK_TURN_URLS or --turn-url, PLUCK_TURN_TTL).
pub fn from(cfg: &Value, flag_urls: &[String]) -> Config {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let token = cfg["relayToken"].as_str().map(str::to_owned).or_else(|| env("PLUCK_RELAY_TOKEN"));
    let urls: Vec<String> = match cfg["turn"]["urls"].as_array() {
        Some(u) => u.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect(),
        None if !flag_urls.is_empty() => flag_urls.to_vec(),
        None => env("PLUCK_TURN_URLS").map(|u| u.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect()).unwrap_or_default(),
    };
    let secret = cfg["turn"]["secret"].as_str().map(str::to_owned).or_else(|| env("PLUCK_TURN_SECRET"));
    let ttl = cfg["turn"]["ttl"].as_u64().or_else(|| env("PLUCK_TURN_TTL")?.parse().ok()).unwrap_or(3600).clamp(60, 86_400);
    let urls: Vec<String> = urls.into_iter().filter(|u| url_ok(u)).take(4).collect();
    let turn = match (secret, urls.is_empty()) {
        (Some(s), false) => Some(Turn { secret: s.into_bytes(), urls, ttl }),
        _ => None,
    };
    Config { token, turn }
}

/// What the Worker accepts (§13.10b): stun:/turn:/turns: and no spaces, ≤ 250 characters after the scheme.
fn url_ok(u: &str) -> bool {
    let rest = u.strip_prefix("stun:").or_else(|| u.strip_prefix("turns:")).or_else(|| u.strip_prefix("turn:"));
    rest.is_some_and(|r| (1..=250).contains(&r.len()) && !r.chars().any(char::is_whitespace))
}

/// HMAC-SHA1 (RFC 2104) over the sha1 crate.
pub fn hmac_sha1(key: &[u8], msg: &[u8]) -> [u8; 20] {
    use sha1::Digest;
    let mut k = [0u8; 64];
    if key.len() > 64 {
        k[..20].copy_from_slice(&sha1::Sha1::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let pad = |b: u8| k.map(|x| x ^ b);
    let inner = sha1::Sha1::new().chain_update(pad(0x36)).chain_update(msg).finalize();
    let outer = sha1::Sha1::new().chain_update(pad(0x5c)).chain_update(inner).finalize();
    outer.into()
}

/// The TURN REST credential: username "<unix expiry>:<peer>", credential = base64(HMAC-SHA1(secret, username)).
pub fn ice(t: &Turn, peer: &str, now: u64) -> Value {
    use base64::Engine;
    let username = format!("{}:{peer}", now + t.ttl);
    let credential = base64::engine::general_purpose::STANDARD.encode(hmac_sha1(&t.secret, username.as_bytes()));
    json!([{"urls": t.urls, "username": username, "credential": credential}])
}

/// Peers already given a final report, so a late peer-left for them doesn't send another.
#[derive(Default)]
pub struct Finals(std::collections::HashSet<String>);

impl Finals {
    pub fn note(&mut self, peer: &str) {
        if self.0.len() >= 4096 {
            self.0.clear(); // shortcut: bounded memory; a duplicate final 0 after this is harmless (the DO ignores it)
        }
        self.0.insert(peer.to_owned());
    }

    /// `final` with 0 bytes for a peer the helper never had (or already finalised: None).
    pub fn final_zero(&mut self, peer: &str) -> Option<Value> {
        if self.0.contains(peer) {
            return None;
        }
        self.note(peer);
        Some(usage(peer, 0, true))
    }
}

pub fn usage(peer: &str, bytes: u64, last: bool) -> Value {
    json!({"t": "relay-usage", "peer": peer, "bytes": bytes, "final": last})
}

/// One peer's relayed bytes, counted by the helper itself (browsers aren't trusted to say).
#[derive(Default)]
pub struct Count {
    pub bytes: u64,
    reported: Option<std::time::Instant>,
    done: bool,
    pub direct: Option<bool>, // the path when its channels opened
    pub kill_at: Option<std::time::Instant>,
}

impl Count {
    /// A packet to or from this peer: counted only when its far end is one of its relay candidates.
    pub fn add(&mut self, via_relay: bool, n: usize) {
        if via_relay {
            self.bytes += n as u64;
        }
    }

    /// (a relay-usage report that's due, whether to say bye with relayLimit now).
    pub fn due(&mut self, peer: &str, now: std::time::Instant) -> (Option<Value>, bool) {
        if self.done {
            return (None, false);
        }
        let mut bye = false;
        if self.bytes > CAP && self.kill_at.is_none() {
            self.kill_at = Some(now + std::time::Duration::from_secs(1));
            bye = true;
        }
        if self.direct == Some(true) && self.bytes == 0 {
            self.done = true; // connected directly: its reserve goes back
            return (Some(usage(peer, 0, true)), bye);
        }
        if self.bytes > 0 && self.reported.is_none_or(|t| now.duration_since(t).as_secs() >= REPORT_SECS) {
            self.reported = Some(now);
            return (Some(usage(peer, self.bytes, false)), bye);
        }
        (None, bye)
    }

    /// The final report when the peer goes, if it isn't final yet: its bytes, or 0 (never relayed or
    /// never connected), so the DO releases its reserve and revokes the credential (#23).
    pub fn last(&mut self, peer: &str) -> Option<Value> {
        (!self.done).then(|| {
            self.done = true;
            usage(peer, self.bytes, true)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_sha1_vectors() {
        let hex = |b: &[u8]| b.iter().map(|x| format!("{x:02x}")).collect::<String>();
        // RFC 2202 test cases 2 and 6 (a key longer than the block).
        assert_eq!(hex(&hmac_sha1(b"Jefe", b"what do ya want for nothing?")), "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79");
        assert_eq!(hex(&hmac_sha1(&[0xaa; 80], b"Test Using Larger Than Block-Size Key - Hash Key First")), "aa4ae5e15272d00e95705637ce8a3b55ed402112");
    }

    #[test]
    fn relay_bytes_only_on_relay_paths_and_the_cap() {
        let t0 = std::time::Instant::now();
        let mut c = Count::default();
        c.add(false, 1000);
        assert_eq!(c.due("p", t0), (None, false), "direct packets don't count");
        c.add(true, 500);
        assert_eq!(c.due("p", t0).0, Some(usage("p", 500, false)));
        c.add(true, 500);
        assert_eq!(c.due("p", t0 + std::time::Duration::from_secs(60)).0, None, "every 5 min");
        assert_eq!(c.due("p", t0 + std::time::Duration::from_secs(300)).0, Some(usage("p", 1000, false)));
        c.add(true, CAP as usize);
        let (r, bye) = c.due("p", t0 + std::time::Duration::from_secs(310));
        assert!(bye && r.is_none() && c.kill_at.is_some(), "past 20 GB: relayLimit, closed a second later");
        assert_eq!(c.last("p"), Some(usage("p", 1000 + CAP, true)));
        assert_eq!(c.last("p"), None, "final once");
        let mut d = Count { direct: Some(true), ..Default::default() };
        assert_eq!(d.due("q", t0).0, Some(usage("q", 0, true)), "connected directly: final with 0");
        assert_eq!(d.last("q"), None);
        let mut never = Count::default();
        assert_eq!(never.last("n"), Some(usage("n", 0, true)), "never relayed: final with 0 releases the reserve");
        assert_eq!(never.last("n"), None);
    }

    /// #23: a peer-left for a browser that never offered gives exactly one final report.
    #[test]
    fn never_offered_peers_get_one_final() {
        let mut f = Finals::default();
        assert_eq!(f.final_zero("p_never"), Some(usage("p_never", 0, true)));
        assert_eq!(f.final_zero("p_never"), None, "a second peer-left: nothing");
        f.note("p_gone"); // finalised when its rtc peer went
        assert_eq!(f.final_zero("p_gone"), None);
    }

    #[test]
    fn coturn_credentials() {
        let t = Turn { secret: b"Jefe".to_vec(), urls: vec!["turns:turn.example.com:443?transport=tcp".into()], ttl: 3600 };
        let v = ice(&t, "p_Yq3", 1_800_000_000);
        assert_eq!(v[0]["username"], "1800003600:p_Yq3");
        use base64::Engine;
        let want = base64::engine::general_purpose::STANDARD.encode(hmac_sha1(b"Jefe", b"1800003600:p_Yq3"));
        assert_eq!(v[0]["credential"], want.as_str());
        let c = from(&json!({"turn": {"secret": "s", "urls": ["turn:a:3478", "http://x", "turn: bad"]}}), &[]);
        assert_eq!(c.turn.unwrap().urls, ["turn:a:3478"], "only stun/turn/turns URLs without spaces");
        assert!(from(&json!({"turn": {"urls": ["turn:a"]}}), &[]).turn.is_none(), "no secret, no TURN");
    }
}
