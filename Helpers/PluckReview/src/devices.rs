// Paired devices (spec §13.2): Macs and backup hosts, each with its own key (only its hash is
// kept here) and, over iroh, its node id. Invitations are single-use 12-character codes that run
// out after 15 minutes; 5 wrong codes close them all and lock pairing for 15 minutes.
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::{host::now_iso, keys};

// Pluck's own code alphabet (OfficeLink.alphabet): a code with L, U, 0, 1, I or O wouldn't read as an invitation there.
const CODE_CHARS: &[u8] = b"23456789ABCDEFGHJKMNPQRSTVWXYZ";
pub const INVITE_SECS: u64 = 15 * 60;
const MAX_WRONG: u32 = 5;

struct Invite {
    code: String, // 12 characters, no dashes
    role: String,
    until: Instant,
}

#[derive(Default)]
struct Inner {
    list: Vec<Value>,
    invites: Vec<Invite>,
    wrong: u32,
    locked: Option<Instant>,
    updates: HashMap<String, String>, // backup device → an update request to hand on at its next status
}

pub struct Devices {
    path: PathBuf,
    inner: Mutex<Inner>,
    /// Commands to the office-mode pluck-iroh child ({"allow"}, {"pair"}, {"paired"}).
    pub iroh: Mutex<Option<mpsc::UnboundedSender<Value>>>,
    /// What an invitation link carries besides the code: o (node), r (relay), n, fp, lan.
    pub link: Mutex<Value>,
}

fn unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn norm_code(c: &str) -> String {
    c.chars().filter(|c| c.is_ascii_alphanumeric()).map(|c| c.to_ascii_uppercase()).collect()
}

pub fn valid_node(n: &str) -> bool {
    n.len() == 64 && n.bytes().all(|b| b.is_ascii_hexdigit())
}

/// A sync session's identity after its first line.
#[derive(Clone, Debug, PartialEq)]
pub struct Who {
    pub device: Option<String>, // None: the legacy host key
    pub role: String,           // "mac" | "backup"
}

impl Devices {
    pub fn load(data: &Path) -> Devices {
        let path = data.join("devices.json");
        let list = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice::<Vec<Value>>(&b).ok()).unwrap_or_default();
        Devices { path, inner: Mutex::new(Inner { list, ..Default::default() }), iroh: Mutex::new(None), link: Mutex::new(json!({})) }
    }

    fn save(&self, i: &Inner) {
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        let tmp = self.path.with_extension("json.part");
        let _ = std::fs::remove_file(&tmp);
        let r = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)
            .and_then(|mut f| f.write_all(Value::from(i.list.clone()).to_string().as_bytes()))
            .and_then(|_| std::fs::rename(&tmp, &self.path));
        if let Err(e) = r {
            crate::log(format!("devices.json: {e}"));
        }
    }

    fn to_iroh(&self, v: Value) {
        if let Some(tx) = self.iroh.lock().unwrap().as_ref() {
            let _ = tx.send(v);
        }
    }

    /// The node ids pluck-iroh lets in.
    pub fn allow(&self) -> Vec<String> {
        self.inner.lock().unwrap().list.iter().filter_map(|d| d["node"].as_str().map(str::to_owned)).collect()
    }

    fn send_allow(&self) {
        self.to_iroh(json!({"allow": self.allow()}));
    }

    pub fn locked(&self) -> bool {
        self.inner.lock().unwrap().locked.is_some_and(|t| Instant::now() < t)
    }

    /// `invite`: a new single-use code for a Mac or a backup host, and the link that carries it.
    pub fn invite(&self, role: &str) -> Value {
        if role != "mac" && role != "backup" {
            return json!({"error": "invalid"});
        }
        if self.locked() {
            return json!({"error": "limit"});
        }
        let code: String = (0..12).map(|_| CODE_CHARS[rand::random_range(0..CODE_CHARS.len())] as char).collect();
        let expires = unix() + INVITE_SECS;
        {
            let mut i = self.inner.lock().unwrap();
            let now = Instant::now();
            i.invites.retain(|x| x.until > now);
            i.invites.push(Invite { code: code.clone(), role: role.into(), until: now + Duration::from_secs(INVITE_SECS) });
        }
        self.to_iroh(json!({"pair": INVITE_SECS}));
        let shown = format!("{}-{}-{}", &code[..4], &code[4..8], &code[8..]);
        let mut l = self.link.lock().unwrap().clone();
        l["v"] = json!(3);
        l["k"] = json!("nas");
        l["c"] = json!(shown);
        l["e"] = json!(expires);
        l["role"] = json!(role);
        let i = keys::b64(l.to_string().as_bytes());
        json!({"link": format!("pluck://edit-anywhere/join?i={i}"), "expires": crate::host::iso(expires as i64), "code": shown})
    }

    /// `{"pair","name","node","role"}`: Some((device id, its key)) for a right, open code.
    /// `stream` is the iroh node the session came in on (None on the LAN).
    pub fn pair(&self, code: &str, name: &str, node: Option<&str>, role: &str, stream: Option<&str>) -> Option<(String, String)> {
        let mut i = self.inner.lock().unwrap();
        let now = Instant::now();
        if i.locked.is_some_and(|t| now < t) {
            return None;
        }
        i.invites.retain(|x| x.until > now);
        let want = norm_code(code);
        let pos = i.invites.iter().position(|x| keys::subtle_eq(x.code.as_bytes(), want.as_bytes()));
        let node_ok = node.is_none_or(valid_node) && (stream.is_none() || stream == node);
        let Some(pos) = pos.filter(|p| i.invites[*p].role == role && node_ok) else {
            i.wrong += 1;
            if i.wrong >= MAX_WRONG {
                i.invites.clear();
                i.wrong = 0;
                i.locked = Some(now + Duration::from_secs(INVITE_SECS));
                drop(i);
                crate::log("pairing locked for 15 min after 5 wrong codes".into());
                self.to_iroh(json!({"pair": 0}));
            }
            return None;
        };
        i.invites.remove(pos);
        i.wrong = 0;
        let key: [u8; 32] = rand::random();
        let id = crate::host::uuid();
        let via = if stream.is_some() { "iroh" } else { "lan" };
        i.list.push(json!({"id": id, "name": crate::host::clean(name, 60), "role": role, "node": node, "keyHash": keys::sha256_b64(&key),
            "added": now_iso(), "lastSeen": now_iso(), "via": via}));
        self.save(&i);
        drop(i);
        self.send_allow();
        if let Some(n) = node {
            self.to_iroh(json!({"paired": n}));
        }
        Some((id, keys::b64(&key)))
    }

    /// `{"device","key"}`: the device's role if the key is its own and, over iroh, the node is its node.
    pub fn check(&self, id: &str, key: &str, stream: Option<&str>) -> Option<String> {
        let mut i = self.inner.lock().unwrap();
        let given = keys::unb64(key).filter(|k| k.len() == 32)?;
        let d = i.list.iter_mut().find(|d| d["id"] == id)?;
        let hash_ok = keys::subtle_eq(keys::sha256_b64(&given).as_bytes(), d["keyHash"].as_str()?.as_bytes());
        let node_ok = stream.is_none_or(|s| d["node"].as_str() == Some(s));
        if !(hash_ok && node_ok) {
            return None;
        }
        d["lastSeen"] = json!(now_iso());
        d["via"] = json!(if stream.is_some() { "iroh" } else { "lan" });
        let role = d["role"].as_str().unwrap_or("mac").to_owned();
        self.save(&i);
        Some(role)
    }

    pub fn exists(&self, id: &str) -> bool {
        self.inner.lock().unwrap().list.iter().any(|d| d["id"] == id)
    }

    pub fn list(&self) -> Value {
        let i = self.inner.lock().unwrap();
        json!({"devices": i.list.iter().map(|d| {
            let mut d = d.clone();
            d.as_object_mut().map(|o| o.remove("keyHash"));
            d
        }).collect::<Vec<_>>(), "pairingLocked": i.locked.is_some_and(|t| Instant::now() < t)})
    }

    pub fn remove(&self, id: &str) -> Value {
        let mut i = self.inner.lock().unwrap();
        let before = i.list.len();
        i.list.retain(|d| d["id"] != id);
        if i.list.len() == before {
            return json!({"error": "notFound"});
        }
        self.save(&i);
        drop(i);
        self.send_allow(); // pluck-iroh cuts its connection at once
        json!({"ok": true})
    }

    /// `device-node`: a Mac paired on the LAN registers its iroh node for later.
    pub fn set_node(&self, id: &str, node: &str) -> Value {
        if !valid_node(node) {
            return json!({"error": "invalid"});
        }
        let mut i = self.inner.lock().unwrap();
        let Some(d) = i.list.iter_mut().find(|d| d["id"] == id) else { return json!({"error": "notFound"}) };
        d["node"] = json!(node);
        self.save(&i);
        drop(i);
        self.send_allow();
        self.to_iroh(json!({"paired": node}));
        json!({"ok": true})
    }

    /// For `status`: the backups, with what each last reported of itself.
    pub fn backups(&self) -> Value {
        json!(self.inner.lock().unwrap().list.iter().filter(|d| d["role"] == "backup")
            .map(|d| json!({"id": d["id"], "name": d["name"], "lastSeen": d["lastSeen"], "replica": d["replica"],
                "serving": d["replica"]["serving"].as_bool().unwrap_or(false)})).collect::<Vec<_>>())
    }

    /// A backup's `status` call carries its replica summary; the answer hands on an update request.
    pub fn backup_status(&self, id: &str, replica: &Value) -> Option<String> {
        let mut i = self.inner.lock().unwrap();
        if let Some(d) = i.list.iter_mut().find(|d| d["id"] == id) {
            if !replica.is_null() {
                d["replica"] = replica.clone();
            }
        }
        self.save(&i);
        i.updates.remove(id)
    }

    /// `{"op":"update","version","device"}` for a backup: kept until its next status call.
    pub fn queue_update(&self, id: &str, version: &str) -> Value {
        let mut i = self.inner.lock().unwrap();
        if !i.list.iter().any(|d| d["id"] == id && d["role"] == "backup") {
            return json!({"error": "notFound"});
        }
        i.updates.insert(id.to_owned(), version.to_owned());
        json!({"ok": true, "queued": true})
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn devs() -> Devices {
        let d = std::env::temp_dir().join(format!("pluck-dev-{}", crate::host::uuid()));
        std::fs::create_dir_all(&d).unwrap();
        Devices::load(&d)
    }

    fn code(inv: &Value) -> String {
        inv["code"].as_str().unwrap().to_owned()
    }

    #[test]
    fn pair_once_then_device_key() {
        let d = devs();
        let (tx, mut rx) = mpsc::unbounded_channel();
        *d.iroh.lock().unwrap() = Some(tx);
        *d.link.lock().unwrap() = json!({"o": "a".repeat(64), "n": "Office NAS", "fp": "AA:BB"});
        let inv = d.invite("mac");
        let link = inv["link"].as_str().unwrap().strip_prefix("pluck://edit-anywhere/join?i=").unwrap();
        let l: Value = serde_json::from_slice(&keys::unb64(link).unwrap()).unwrap();
        assert_eq!((l["v"].clone(), l["k"].clone(), l["role"].clone(), l["c"].clone()), (json!(3), json!("nas"), json!("mac"), inv["code"].clone()));
        assert_eq!(rx.try_recv().unwrap(), json!({"pair": 900}));
        for _ in 0..200 {
            let c = code(&d.invite("mac")).replace('-', "");
            assert!(c.len() == 12 && c.bytes().all(|b| b"23456789ABCDEFGHJKMNPQRSTVWXYZ".contains(&b)), "Pluck reads only its own alphabet: {c}");
        }
        let node = "b".repeat(64);
        assert!(d.pair(&code(&inv), "MacBook Pro", Some(&node), "backup", Some(&node)).is_none(), "the invite's role must match");
        assert!(d.pair(&code(&inv), "MacBook Pro", Some(&node), "mac", Some(&"c".repeat(64))).is_none(), "node must be the stream's");
        let (id, key) = d.pair(&code(&inv).to_lowercase(), "MacBook Pro", Some(&node), "mac", Some(&node)).unwrap();
        assert!(d.pair(&code(&inv), "Other", None, "mac", None).is_none(), "single use");
        let cmds: Vec<Value> = std::iter::from_fn(|| rx.try_recv().ok()).collect();
        assert!(cmds.contains(&json!({"allow": [node.clone()]})) && cmds.contains(&json!({"paired": node.clone()})));
        assert_eq!(d.check(&id, &key, Some(&node)).as_deref(), Some("mac"));
        assert_eq!(d.check(&id, &key, None).as_deref(), Some("mac"), "the same key on the LAN");
        assert!(d.check(&id, &key, Some(&"c".repeat(64))).is_none(), "another node");
        assert!(d.check(&id, &keys::b64(&[0u8; 32]), Some(&node)).is_none(), "another key");
        assert!(d.list()["devices"][0].get("keyHash").is_none());
        assert_eq!(Devices::load(d.path.parent().unwrap()).check(&id, &key, None).as_deref(), Some("mac"), "kept on disk");
        assert_eq!(d.remove(&id)["ok"], true);
        assert!(d.check(&id, &key, None).is_none(), "removed: its key stops working");
        assert_eq!(rx.try_recv().unwrap(), json!({"allow": []}));
    }

    #[test]
    fn five_wrong_codes_lock() {
        let d = devs();
        let inv = d.invite("backup");
        for _ in 0..5 {
            assert!(d.pair("AAAA-AAAA-AAAA", "x", None, "backup", None).is_none());
        }
        assert!(d.locked());
        assert!(d.pair(&code(&inv), "x", None, "backup", None).is_none(), "every open code closed");
        assert!(d.invite("mac").get("error").is_some(), "no new ones while locked");
        assert_eq!(d.list()["pairingLocked"], true);
    }
}
