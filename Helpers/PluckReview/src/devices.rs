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
    access: String, // a Mac's: "admin" | "editor"
    until: Instant,
}

#[derive(Default)]
struct Inner {
    list: Vec<Value>,
    invites: Vec<Invite>,
    wrong: u32,
    locked: Option<Instant>,
    updates: HashMap<String, String>, // backup device → an update request to hand on at its next status
    outage: Vec<Value>, // a backup: the main's Macs that may upload here while it's down (main-macs.json, §13.25)
}

pub struct Devices {
    path: PathBuf,
    macs_path: PathBuf,
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

/// A paired Mac's access (roles, 4.0.5): "admin" | "editor". Macs paired before roles have none and stay admin.
pub fn access(d: &Value) -> &str {
    d["access"].as_str().unwrap_or("admin")
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
        let macs_path = data.join("main-macs.json");
        let outage = std::fs::read(&macs_path).ok().and_then(|b| serde_json::from_slice::<Vec<Value>>(&b).ok()).unwrap_or_default();
        Devices { path, macs_path, inner: Mutex::new(Inner { list, outage, ..Default::default() }), iroh: Mutex::new(None), link: Mutex::new(json!({})) }
    }

    fn save(&self, i: &Inner) {
        Self::write(&self.path, &i.list);
    }

    fn write(path: &Path, list: &[Value]) {
        use std::{io::Write, os::unix::fs::OpenOptionsExt};
        let tmp = path.with_extension("json.part");
        let _ = std::fs::remove_file(&tmp);
        let r = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)
            .and_then(|mut f| f.write_all(Value::from(list.to_vec()).to_string().as_bytes()))
            .and_then(|_| std::fs::rename(&tmp, path));
        if let Err(e) = r {
            crate::log(format!("{}: {e}", path.display()));
        }
    }

    fn to_iroh(&self, v: Value) {
        if let Some(tx) = self.iroh.lock().unwrap().as_ref() {
            let _ = tx.send(v);
        }
    }

    /// The node ids pluck-iroh lets in.
    pub fn allow(&self) -> Vec<String> {
        let i = self.inner.lock().unwrap();
        i.list.iter().chain(&i.outage).filter_map(|d| d["node"].as_str().map(str::to_owned)).collect()
    }

    fn send_allow(&self) {
        self.to_iroh(json!({"allow": self.allow()}));
    }

    pub fn locked(&self) -> bool {
        self.inner.lock().unwrap().locked.is_some_and(|t| Instant::now() < t)
    }

    /// `invite`: a new single-use code for a Mac or a backup host, and the link that carries it. `access`: what the
    /// Mac may do once paired; None (a Mac or the admin page from before roles) is admin, as every Mac was then.
    pub fn invite(&self, role: &str, access: Option<&str>) -> Value {
        let access = access.unwrap_or("admin");
        if (role != "mac" && role != "backup") || (access != "admin" && access != "editor") {
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
            i.invites.push(Invite { code: code.clone(), role: role.into(), access: access.into(), until: now + Duration::from_secs(INVITE_SECS) });
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
        let access = i.invites.remove(pos).access;
        i.wrong = 0;
        let key: [u8; 32] = rand::random();
        let id = crate::host::uuid();
        let via = if stream.is_some() { "iroh" } else { "lan" };
        i.list.push(json!({"id": id, "name": crate::host::clean(name, 60), "role": role, "node": node, "keyHash": keys::sha256_b64(&key),
            "added": now_iso(), "lastSeen": now_iso(), "via": via}));
        if role == "mac" {
            i.list.last_mut().unwrap()["access"] = json!(access);
        }
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
        let Some(d) = i.list.iter_mut().find(|d| d["id"] == id) else {
            // A backup: one of its main's Macs, on the node it registered there for this (§13.25), may upload while the main is down.
            let d = i.outage.iter().find(|d| d["id"] == id)?;
            let hash_ok = keys::subtle_eq(keys::sha256_b64(&given).as_bytes(), d["keyHash"].as_str()?.as_bytes());
            return (hash_ok && stream.is_some_and(|s| d["node"].as_str() == Some(s))).then(|| "outage".into());
        };
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

    /// A paired Mac that may do admin work (read on every op, so a change reaches open sessions at once).
    pub fn is_admin(&self, id: &str) -> bool {
        self.inner.lock().unwrap().list.iter().any(|d| d["id"] == id && d["role"] == "mac" && access(d) == "admin")
    }

    /// Admin Macs other than `except`; None when no Mac is paired at all (only the legacy host key, itself an admin).
    pub fn admin_macs(&self, except: Option<&str>) -> Option<usize> {
        let i = self.inner.lock().unwrap();
        let macs: Vec<&Value> = i.list.iter().filter(|d| d["role"] == "mac").collect();
        (!macs.is_empty()).then(|| macs.iter().filter(|d| access(d) == "admin" && except.is_none_or(|e| d["id"] != e)).count())
    }

    /// The device record (no key hash).
    pub fn get(&self, id: &str) -> Option<Value> {
        self.inner.lock().unwrap().list.iter().find(|d| d["id"] == id).map(|d| json!({"id": d["id"], "name": d["name"], "role": d["role"], "access": access(d)}))
    }

    /// `device-role`: a paired Mac becomes an admin or an editor (the caller checked who asks and the last admin).
    pub fn set_access(&self, id: &str, to: &str) -> Value {
        if to != "admin" && to != "editor" {
            return json!({"error": "invalid"});
        }
        let mut i = self.inner.lock().unwrap();
        let Some(d) = i.list.iter_mut().find(|d| d["id"] == id && d["role"] == "mac") else { return json!({"error": "notFound"}) };
        d["access"] = json!(to);
        self.save(&i);
        json!({"ok": true})
    }

    pub fn exists(&self, id: &str) -> bool {
        let i = self.inner.lock().unwrap();
        i.list.iter().chain(&i.outage).any(|d| d["id"] == id)
    }

    /// A device's name (also one of the main's Macs, on a backup).
    pub fn name(&self, id: &str) -> String {
        let i = self.inner.lock().unwrap();
        i.list.iter().chain(&i.outage).find(|d| d["id"] == id).and_then(|d| d["name"].as_str()).unwrap_or("").to_owned()
    }

    /// `outage-node`: the node this Mac uses to reach the backups while the main is down (its own iroh key for them).
    pub fn set_outage_node(&self, id: &str, node: &str) -> Value {
        if !valid_node(node) {
            return json!({"error": "invalid"});
        }
        let mut i = self.inner.lock().unwrap();
        let Some(d) = i.list.iter_mut().find(|d| d["id"] == id && d["role"] == "mac") else { return json!({"error": "notFound"}) };
        d["outageNode"] = json!(node);
        self.save(&i);
        json!({"ok": true})
    }

    /// `outage-macs` (the main, for its backups): the Macs with an outage node, their key hashes and that node.
    pub fn outage_macs(&self) -> Value {
        let i = self.inner.lock().unwrap();
        json!({"macs": i.list.iter().filter(|d| d["role"] == "mac" && d["outageNode"].as_str().is_some_and(valid_node))
            .map(|d| json!({"id": d["id"], "name": d["name"], "node": d["outageNode"], "keyHash": d["keyHash"]})).collect::<Vec<_>>()})
    }

    /// A backup: the main's `outage-macs`, kept (main-macs.json) for while the main is down; a Mac gone there is cut here.
    pub fn set_outage(&self, macs: &Value) {
        let list: Vec<Value> = macs.as_array().into_iter().flatten()
            .filter(|d| d["id"].as_str().is_some_and(|x| !x.is_empty() && x.len() <= 64) && d["node"].as_str().is_some_and(valid_node) && d["keyHash"].is_string())
            .map(|d| json!({"id": d["id"], "name": d["name"], "node": d["node"], "keyHash": d["keyHash"]})).take(200).collect();
        let mut i = self.inner.lock().unwrap();
        if i.outage == list {
            return;
        }
        Self::write(&self.macs_path, &list);
        i.outage = list;
        drop(i);
        self.send_allow();
    }

    pub fn list(&self) -> Value {
        let i = self.inner.lock().unwrap();
        json!({"devices": i.list.iter().map(|d| {
            let mut d = d.clone();
            d.as_object_mut().map(|o| o.remove("keyHash"));
            if d["role"] == "mac" {
                d["access"] = json!(access(&d)); // one from before roles: admin
            }
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

    /// Whether a backup is paired (the main's upload is only compared with one there).
    pub fn has_backup(&self) -> bool {
        self.inner.lock().unwrap().list.iter().any(|d| d["role"] == "backup")
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
        let inv = d.invite("mac", None);
        let link = inv["link"].as_str().unwrap().strip_prefix("pluck://edit-anywhere/join?i=").unwrap();
        let l: Value = serde_json::from_slice(&keys::unb64(link).unwrap()).unwrap();
        assert_eq!((l["v"].clone(), l["k"].clone(), l["role"].clone(), l["c"].clone()), (json!(3), json!("nas"), json!("mac"), inv["code"].clone()));
        assert_eq!(rx.try_recv().unwrap(), json!({"pair": 900}));
        for _ in 0..200 {
            let c = code(&d.invite("mac", None)).replace('-', "");
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
        let inv = d.invite("backup", None);
        for _ in 0..5 {
            assert!(d.pair("AAAA-AAAA-AAAA", "x", None, "backup", None).is_none());
        }
        assert!(d.locked());
        assert!(d.pair(&code(&inv), "x", None, "backup", None).is_none(), "every open code closed");
        assert!(d.invite("mac", None).get("error").is_some(), "no new ones while locked");
        assert_eq!(d.list()["pairingLocked"], true);
    }

    /// §13.25: a main hands its Macs' outage nodes to its backups; on the backup such a Mac gets in only on that node,
    /// as role "outage", and goes when the main drops it.
    #[test]
    fn outage_macs_reach_the_backup_on_their_own_node() {
        let d = std::env::temp_dir().join(format!("pluck-dev-o-{}", crate::host::uuid()));
        std::fs::create_dir_all(d.join("main")).unwrap();
        let main = Devices::load(&d.join("main"));
        let inv = main.invite("mac", None);
        let node = "a".repeat(64);
        let (id, key) = main.pair(&code(&inv), "Edit Suite", Some(&node), "mac", Some(&node)).unwrap();
        assert_eq!(main.outage_macs()["macs"].as_array().unwrap().len(), 0, "not before it registered an outage node");
        let outage = "b".repeat(64);
        assert!(main.set_outage_node(&id, "nope")["error"].is_string());
        assert_eq!(main.set_outage_node(&id, &outage)["ok"], true);
        let macs = main.outage_macs()["macs"].clone();
        assert_eq!((macs[0]["node"].clone(), macs[0]["id"].clone()), (json!(outage), json!(id)));
        std::fs::create_dir_all(d.join("backup")).unwrap();
        let backup = Devices::load(&d.join("backup"));
        backup.set_outage(&macs);
        assert!(backup.allow().contains(&outage) && backup.exists(&id));
        assert_eq!(backup.check(&id, &key, Some(&outage)).as_deref(), Some("outage"));
        assert!(backup.check(&id, &key, Some(&node)).is_none(), "only on its outage node");
        assert!(backup.check(&id, &key, None).is_none(), "never off iroh");
        assert!(backup.check(&id, &keys::b64(&[0u8; 32]), Some(&outage)).is_none());
        assert_eq!(Devices::load(&d.join("backup")).check(&id, &key, Some(&outage)).as_deref(), Some("outage"), "kept for the outage");
        backup.set_outage(&json!([]));
        assert!(backup.check(&id, &key, Some(&outage)).is_none() && !backup.exists(&id), "gone with the main's list");
        let _ = std::fs::remove_dir_all(d);
    }

    /// Roles (4.0.5): a Mac paired before roles (no `access`) is an admin; an invite says what the new Mac is.
    #[test]
    fn old_macs_stay_admin_and_invites_carry_the_role() {
        let dir = std::env::temp_dir().join(format!("pluck-dev-r-{}", crate::host::uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("devices.json"), json!([{"id": "old", "name": "Edit Suite iMac", "role": "mac", "keyHash": "x"},
            {"id": "b", "name": "Studio NAS", "role": "backup", "keyHash": "y"}]).to_string()).unwrap();
        let d = Devices::load(&dir);
        assert!(d.is_admin("old") && !d.is_admin("b"), "an old Mac is an admin, a backup never");
        assert_eq!(d.list()["devices"][0]["access"], "admin");
        assert!(d.list()["devices"][1].get("access").is_none());
        assert_eq!(d.admin_macs(None), Some(1));
        assert!(d.invite("mac", Some("boss"))["error"].is_string());
        let inv = d.invite("mac", Some("editor"));
        let (id, _) = d.pair(&code(&inv), "Studio MacBook", None, "mac", None).unwrap();
        assert!(!d.is_admin(&id));
        assert_eq!(d.get(&id).unwrap()["access"], "editor");
        assert_eq!(d.admin_macs(Some("old")), Some(0), "without the old one, no admin Mac");
        assert_eq!(d.set_access(&id, "admin")["ok"], true);
        assert!(Devices::load(&dir).is_admin(&id), "kept on disk");
        assert_eq!(d.set_access("b", "admin")["error"], "notFound", "only Macs have roles");
        assert_eq!(devs().admin_macs(None), None, "no Mac paired: only the host key");
        let _ = std::fs::remove_dir_all(dir);
    }
}
