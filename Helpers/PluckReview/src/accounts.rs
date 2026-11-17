// Pluck Review accounts with passkeys (plan 2026-11-17-accounts-passkeys.md). The main host is the WebAuthn relying
// party for its own team: people, their passkeys' public keys, invites and client requests live in <data>/accounts.json
// (0600, written through tmp + rename), and a backup keeps a pulled copy for sign-in only. Nothing of it reaches
// pluck.tools. No open sign-up: a person exists only from an owner's (or, when allowed, an editor's) invite naming them
// and a role, and a passkey counts only when its credential id is on one of this host's person records.
use std::{collections::HashMap, path::{Path, PathBuf}};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::{host::{clean, iso, uuid}, keys};

pub const INVITE_SECS: i64 = 7 * 86_400; // a person invite, and an accepted request (owner decision 1)
pub const DEVICE_SECS: i64 = 15 * 60; // a code for adding another device
pub const NONCE_SECS: i64 = 120;
pub const RESUME_SECS: i64 = 12 * 3600;
const FREEZE_SECS: i64 = 15 * 60;
const WRONG_PER_HOUR: usize = 20; // wrong codes on this host, then every invite freezes
const FAILS_PER_HOUR: usize = 30; // failed sign-ins on this host, then sign-in is locked
const REQUESTS_PER_LINK: usize = 3;
const REQUESTS_PER_HOST: usize = 50;
const REQUEST_SECS: i64 = 30 * 86_400;
const WEB_INVITES_PER_DAY: usize = 20;
const CODE_LEN: usize = 16; // base62, about 2^95
const SPKI_P256: [u8; 26] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
    0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00];
pub const ROLES: [&str; 3] = ["client", "editor", "owner"];

/// How an `account-begin create` says who it is.
pub enum Create<'a> {
    Invite(&'a str),
    Device(&'a str),
    Request(&'a str),
}

pub struct Accounts {
    path: PathBuf,
    pub v: Value, // accounts.json, Null when this host has no team
    pub origin: String,
    pub rp_id: String,
    wrong: Vec<i64>, // wrong codes this hour, host-wide
    frozen: i64,     // every invite frozen until (§1.10)
    fails: Vec<i64>, // failed sign-ins this hour, host-wide
    locked: i64,
    resume: HashMap<String, ([u8; 32], i64)>, // person → resume key, expiry (memory only, §2.3)
}

fn arr<'a>(v: &'a Value, k: &str) -> impl Iterator<Item = &'a Value> {
    v[k].as_array().into_iter().flatten()
}

fn arr_mut<'a>(v: &'a mut Value, k: &str) -> &'a mut Vec<Value> {
    if !v[k].is_array() {
        v[k] = json!([]);
    }
    v[k].as_array_mut().unwrap()
}

fn hash(code: &str) -> String {
    keys::sha256_b64(code.as_bytes())
}

/// A fresh 16-character base62 code (bytes < 248 mod 62: no bias, as keys::new_code).
pub fn new_code() -> String {
    const B62: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    let mut out = String::with_capacity(CODE_LEN);
    while out.len() < CODE_LEN {
        let b: u8 = rand::random();
        if b < 248 {
            out.push(B62[usize::from(b % 62)] as char);
        }
    }
    out
}

pub fn is_code(s: &str) -> bool {
    s.len() == CODE_LEN && s.bytes().all(|b| b.is_ascii_alphanumeric())
}

// ---- WebAuthn checks (pure) ----

/// SHA-256("pluck-account/1 " ‖ purpose ‖ "\n" ‖ nonce ‖ macNonce ‖ fpMac ‖ "\n" ‖ fpBrowser): binds an assertion to this
/// session (both DTLS fingerprints and the hello nonce) and to one purpose (§1.2).
pub fn challenge(purpose: &str, nonce: &[u8], mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> [u8; 32] {
    let mut h = Sha256::new();
    for p in [format!("pluck-account/1 {purpose}\n").as_bytes(), nonce, mac_nonce, fp_mac.as_bytes(), b"\n", fp_browser.as_bytes()] {
        h.update(p);
    }
    h.finalize().into()
}

/// clientDataJSON: the right type, exactly our challenge and origin (no subdomain), not cross-origin.
pub fn client_data(raw: &[u8], purpose: &str, challenge: &[u8], origin: &str) -> bool {
    let Ok(c) = serde_json::from_slice::<Value>(raw) else { return false };
    let ty = if purpose == "create" { "webauthn.create" } else { "webauthn.get" };
    c["type"] == ty && c["origin"] == origin && c["crossOrigin"].as_bool() != Some(true)
        && c["challenge"].as_str().and_then(keys::unb64).is_some_and(|ch| keys::subtle_eq(&ch, challenge))
}

/// authenticatorData at fixed offsets: rpIdHash, flags UP and UV (AT too on create, with the credential id = rawId).
/// The sign count when it's good.
pub fn auth_data(b: &[u8], rp_id: &str, create: Option<&[u8]>) -> Option<u32> {
    if b.len() < 37 || b[..32] != Sha256::digest(rp_id.as_bytes())[..] || b[32] & 0x05 != 0x05 {
        return None;
    }
    if let Some(raw_id) = create {
        let n = usize::from(u16::from_be_bytes([*b.get(53)?, *b.get(54)?]));
        if b[32] & 0x40 == 0 || b.get(55..55 + n)? != raw_id {
            return None;
        }
    }
    Some(u32::from_be_bytes([b[33], b[34], b[35], b[36]]))
}

/// The 65-byte P-256 point of an SPKI DER (the only key type offered: ES256).
pub fn spki_p256(der: &[u8]) -> Option<&[u8]> {
    (der.len() == 91 && der[..26] == SPKI_P256 && der[26] == 0x04).then(|| &der[26..])
}

pub fn verify(spki: &[u8], auth: &[u8], client: &[u8], sig: &[u8]) -> bool {
    let Some(point) = spki_p256(spki) else { return false };
    let msg = [auth, &Sha256::digest(client)[..]].concat();
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_ASN1, point).verify(&msg, sig).is_ok()
}

/// b64url(SHA-256("pluck-account/1 token " ‖ team ‖ "/" ‖ person)): a signed-in peer's authorToken (§1.7).
pub fn account_token(team: &str, person: &str) -> String {
    keys::sha256_b64(format!("pluck-account/1 token {team}/{person}").as_bytes())
}

fn resume_mac(key: &[u8], mac_nonce: &[u8], fp_mac: &str, fp_browser: &str) -> hmac::Hmac<Sha256> {
    use hmac::Mac;
    let mut m = hmac::Hmac::<Sha256>::new_from_slice(key).expect("any key length");
    for p in [b"pluck-account/1 resume\n".as_slice(), mac_nonce, fp_mac.as_bytes(), b"\n", fp_browser.as_bytes()] {
        m.update(p);
    }
    m
}

impl Accounts {
    pub fn load(data: &Path) -> Accounts {
        let path = data.join("accounts.json");
        let v = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).filter(|v| v["format"] == 1).unwrap_or(Value::Null);
        Accounts { path, v, origin: "https://pluck.tools".into(), rp_id: "pluck.tools".into(), wrong: vec![], frozen: 0, fails: vec![], locked: 0,
            resume: HashMap::new() }
    }

    /// The test override (§1.1): honoured only with a loopback signaling URL, as TURN_API_BASE is.
    pub fn set_origin(&mut self, origin: &str, signal: &str) -> bool {
        let local = |u: &str| ["ws://127.0.0.1", "ws://localhost", "wss://127.0.0.1", "wss://localhost"].iter().any(|p| u.starts_with(p));
        let host = origin.strip_prefix("http://localhost").filter(|r| r.is_empty() || r.starts_with(':'));
        if !local(signal) || host.is_none() {
            return false;
        }
        (self.origin, self.rp_id) = (origin.to_owned(), "localhost".into());
        true
    }

    pub fn on(&self) -> bool {
        self.v["team"]["room"]["roomID"].is_string()
    }

    /// Atomically, 0600: a crash between the two steps keeps the old file.
    pub fn save(&self) -> bool {
        use std::os::unix::fs::OpenOptionsExt;
        let tmp = self.path.with_extension("json.tmp");
        let _ = std::fs::remove_file(&tmp);
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)
            .and_then(|mut f| { std::io::Write::write_all(&mut f, self.v.to_string().as_bytes())?; f.sync_all() })
            .and_then(|_| std::fs::rename(&tmp, &self.path)).is_ok()
    }

    /// A backup's copy from the main (`_accounts`), written as the main does.
    pub fn replace(&mut self, v: Value) -> bool {
        if v["format"] != 1 {
            return false;
        }
        self.v = v;
        // Resume keys of people the main removed or reset go too.
        let live: Vec<String> = self.people().filter(|p| arr(p, "passkeys").next().is_some()).filter_map(|p| p["id"].as_str().map(str::to_owned)).collect();
        self.resume.retain(|k, _| live.contains(k));
        self.save()
    }

    pub fn room(&self) -> Option<&Value> {
        self.on().then(|| &self.v["team"]["room"])
    }

    pub fn team(&self) -> Value {
        json!({"id": self.v["team"]["id"], "name": self.v["team"]["name"]})
    }

    pub fn editors_invite(&self) -> bool {
        self.v["settings"]["editorsInvite"] == true
    }

    fn people(&self) -> impl Iterator<Item = &Value> {
        arr(&self.v, "people")
    }

    pub fn person(&self, id: &str) -> Option<&Value> {
        self.people().find(|p| p["id"] == id)
    }

    fn person_mut(&mut self, id: &str) -> Option<&mut Value> {
        arr_mut(&mut self.v, "people").iter_mut().find(|p| p["id"] == id)
    }

    /// A signed-in person who may still use it (exists, has a passkey): their role.
    pub fn role(&self, id: &str) -> Option<&str> {
        self.person(id).filter(|p| arr(p, "passkeys").next().is_some()).and_then(|p| p["role"].as_str())
    }

    /// "Anna · Northwind Films": what the passkey manager shows (owner decision 8).
    pub fn display(&self, p: &Value) -> String {
        format!("{} · {}", p["name"].as_str().unwrap_or(""), self.v["team"]["name"].as_str().unwrap_or(""))
    }

    fn link_with(&self, tail: &str) -> Option<String> {
        let r = self.room()?;
        Some(format!("{}/r/#{}.{}{tail}", self.origin, r["key"].as_str()?, r["pub"].as_str()?))
    }

    pub fn team_link(&self) -> Option<String> {
        self.link_with("")
    }

    /// `team-set`: the first call makes the team and its level-2 room (§1.6).
    pub fn team_set(&mut self, name: Option<&str>, editors_invite: Option<bool>) -> Value {
        if !self.on() {
            let (key, r): ([u8; 32], [u8; 32]) = (rand::random(), rand::random());
            let seed = keys::owner(&r, "sign");
            let Some(public) = keys::public(&seed) else { return json!({"error": "internal"}) };
            self.v = json!({"format": 1, "team": {"id": keys::b64(&rand::random::<[u8; 16]>()), "name": "",
                "room": {"roomID": keys::b64(&keys::derive(&key, "room", 16)), "reg": keys::b64(&keys::owner(&r, "register")),
                    "sign": keys::b64(&seed), "auth": keys::b64(&keys::derive(&key, "auth", 32)), "join": keys::join_hash(&key), "level": 2,
                    "key": keys::b64(&key), "pub": keys::b64(&public)}},
                "settings": {"editorsInvite": false}, "people": [], "invites": [], "requests": []});
        }
        if let Some(n) = name.map(|n| clean(n, 60)).filter(|n| !n.is_empty()) {
            self.v["team"]["name"] = json!(n);
        }
        if let Some(e) = editors_invite {
            self.v["settings"]["editorsInvite"] = json!(e);
        }
        if !self.save() {
            return json!({"error": "write"});
        }
        json!({"ok": true, "link": self.team_link()})
    }

    fn add_invite(&mut self, person: &str, kind: &str, hash: String, by: &str, expires: i64, now: i64) {
        let list = arr_mut(&mut self.v, "invites");
        let old = iso(now - 30 * 86_400);
        list.retain(|i| i["expires"].as_str().is_some_and(|e| e > old.as_str())); // a month after it ran out, it goes
        list.push(json!({"id": uuid(), "hash": hash, "person": person, "kind": kind, "by": by, "made": iso(now), "expires": iso(expires), "used": null}));
    }

    /// `person-invite` (Pluck, `by` "mac") or `invite` from the web (`by` a person id, checked by the caller's role):
    /// the person record with no passkeys, and a one-time 7-day code naming them (§1.5).
    pub fn invite(&mut self, name: &str, role: &str, footage: bool, email: Option<&str>, by: &str, now: i64) -> Value {
        let name = clean(name, 40);
        if !self.on() || name.is_empty() || !ROLES.contains(&role) {
            return json!({"error": "invalid"});
        }
        if by != "mac" {
            let day = iso(now - 86_400);
            if arr(&self.v, "invites").filter(|i| i["by"] == by && i["made"].as_str().is_some_and(|m| m > day.as_str())).count() >= WEB_INVITES_PER_DAY {
                return json!({"error": "limit"});
            }
        }
        let id = uuid();
        arr_mut(&mut self.v, "people").push(json!({"id": id, "userId": keys::b64(&rand::random::<[u8; 16]>()), "name": name,
            "email": email.map(|e| clean(e, 120)).filter(|e| !e.is_empty()), "role": role, "footage": footage, "added": iso(now), "by": by,
            "lastSeen": null, "passkeys": []}));
        let code = new_code();
        self.add_invite(&id, "invite", hash(&code), by, now + INVITE_SECS, now);
        if !self.save() {
            return json!({"error": "write"});
        }
        json!({"person": id, "link": self.link_with(&format!("/i/{code}")), "expires": iso(now + INVITE_SECS)})
    }

    /// `device-code`: 15 minutes, once, for the same person.
    pub fn device_code(&mut self, person: &str, now: i64) -> Value {
        if self.person(person).is_none() {
            return json!({"error": "revoked"});
        }
        let code = new_code();
        self.add_invite(person, "device", hash(&code), person, now + DEVICE_SECS, now);
        if !self.save() {
            return json!({"error": "write"});
        }
        json!({"link": self.link_with(&format!("/d/{code}")), "expires": iso(now + DEVICE_SECS)})
    }

    fn wrong_code(&mut self, now: i64) -> &'static str {
        self.wrong.retain(|t| *t > now - 3600);
        self.wrong.push(now);
        if self.wrong.len() >= WRONG_PER_HOUR {
            self.frozen = now + FREEZE_SECS;
            self.wrong.clear();
            crate::log(format!("host: {WRONG_PER_HOUR} wrong account codes in an hour; every invite is frozen for 15 minutes"));
        }
        "auth"
    }

    pub fn frozen(&self, now: i64) -> bool {
        now < self.frozen
    }

    /// `account-begin create`: the open invite this code (or accepted request) names, and its person. Wrong codes are
    /// counted (§1.10); nothing is used up until `finish_create`.
    pub fn begin_create(&mut self, how: Create, now: i64) -> Result<(String, String), &'static str> {
        if !self.on() {
            return Err("auth");
        }
        if self.frozen(now) {
            return Err("locked");
        }
        let (kind, h) = match how {
            Create::Invite(c) if is_code(c) => ("invite", hash(c)),
            Create::Device(c) if is_code(c) => ("device", hash(c)),
            Create::Request(s) if keys::unb64(s).is_some_and(|b| b.len() == 32) => {
                let h = hash(s);
                let state = arr(&self.v, "requests").find(|r| keys::subtle_eq(r["hash"].as_str().unwrap_or("").as_bytes(), h.as_bytes())).map(|r| r["state"].clone());
                match state {
                    Some(s) if s == "pending" => return Err("pending"),
                    Some(s) if s == "declined" => return Err("revoked"),
                    Some(_) => ("request", h),
                    None => return Err(self.wrong_code(now)),
                }
            }
            _ => return Err(self.wrong_code(now)),
        };
        let found = arr(&self.v, "invites").find(|i| i["kind"] == kind && keys::subtle_eq(i["hash"].as_str().unwrap_or("").as_bytes(), h.as_bytes())).cloned();
        let Some(i) = found else {
            return Err(if kind == "request" { "used" } else { self.wrong_code(now) }); // an accepted request whose invite went: used
        };
        if !i["used"].is_null() {
            return Err("used");
        }
        if i["expires"].as_str().is_none_or(|e| e <= iso(now).as_str()) {
            return Err("expired");
        }
        let person = i["person"].as_str().unwrap_or("").to_owned();
        if self.person(&person).is_none() {
            return Err("revoked");
        }
        Ok((i["id"].as_str().unwrap_or("").to_owned(), person))
    }

    /// What `account-begin create` answers besides the nonce: the user and the passkeys to exclude.
    pub fn create_user(&self, person: &str) -> Value {
        let p = self.person(person).cloned().unwrap_or_default();
        json!({"user": {"id": p["userId"], "name": self.display(&p)}, "exclude": arr(&p, "passkeys").map(|k| k["id"].clone()).collect::<Vec<_>>()})
    }

    fn failed(&mut self, now: i64) {
        self.fails.retain(|t| *t > now - 3600);
        self.fails.push(now);
        if self.fails.len() >= FAILS_PER_HOUR {
            self.locked = now + FREEZE_SECS;
            self.fails.clear();
            crate::log(format!("host: {FAILS_PER_HOUR} failed account sign-ins in an hour; sign-in is locked for 15 minutes"));
        }
    }

    pub fn locked(&self, now: i64) -> bool {
        now < self.locked
    }

    /// `account-create`: the invite still open, the attestation's client data and authenticator data good, the SPKI a
    /// P-256 key whose coordinates are the attested key's. The passkey goes on the invite's person; the invite is used.
    pub fn finish_create(&mut self, invite: &str, cred: &Value, challenge: &[u8], label: &str, now: i64) -> Result<String, &'static str> {
        let r = (|| -> Option<(String, Value)> {
            let raw_id = keys::unb64(cred["id"].as_str()?).filter(|i| (16..=1023).contains(&i.len()))?;
            let (spki, auth, client) = (keys::unb64(cred["spki"].as_str()?)?, keys::unb64(cred["authData"].as_str()?)?, keys::unb64(cred["clientData"].as_str()?)?);
            let point = spki_p256(&spki)?;
            let count = auth_data(&auth, &self.rp_id, Some(&raw_id))?;
            // The attested COSE key (no CBOR parser): both 32-byte coordinates must be in it.
            let key = auth.get(55 + raw_id.len()..)?;
            let has = |c: &[u8]| key.windows(32).any(|w| w == c);
            if !client_data(&client, "create", challenge, &self.origin) || !has(&point[1..33]) || !has(&point[33..]) {
                return None;
            }
            Some((keys::b64(&raw_id), json!({"id": keys::b64(&raw_id), "spki": keys::b64(&spki), "label": clean(label, 60), "added": iso(now),
                "lastUsed": iso(now), "count": count})))
        })();
        let Some((cid, pk)) = r else {
            self.failed(now);
            return Err("auth");
        };
        if self.people().any(|p| arr(p, "passkeys").any(|k| k["id"] == cid.as_str())) {
            self.failed(now);
            return Err("auth"); // a credential already on a record
        }
        let i = arr_mut(&mut self.v, "invites").iter_mut().find(|i| i["id"] == invite).ok_or("auth")?;
        if !i["used"].is_null() {
            return Err("used");
        }
        if i["expires"].as_str().is_none_or(|e| e <= iso(now).as_str()) {
            return Err("expired");
        }
        i["used"] = json!(iso(now));
        i["usedBy"] = pk["label"].clone();
        let person = i["person"].as_str().unwrap_or("").to_owned();
        let p = self.person_mut(&person).ok_or("revoked")?;
        arr_mut(p, "passkeys").push(pk);
        p["lastSeen"] = json!(iso(now));
        if !self.save() {
            return Err("internal");
        }
        Ok(person)
    }

    /// `account-get`: only a credential id on one of this host's person records counts (a self-made passkey, another
    /// company's, a removed one: `auth`). `main`: a sign count going backwards is refused and the use is written down.
    pub fn finish_get(&mut self, cred: &Value, challenge: &[u8], main: bool, now: i64) -> Result<String, &'static str> {
        if self.locked(now) {
            return Err("locked");
        }
        let id = cred["id"].as_str().unwrap_or("");
        let found = self.people().find_map(|p| arr(p, "passkeys").find(|k| k["id"] == id).map(|k| (p.clone(), k.clone())));
        let ok = found.as_ref().and_then(|(p, k)| {
            if !cred["userHandle"].is_null() && cred["userHandle"] != p["userId"] {
                return None; // the handle must be this person's (§ hard rule)
            }
            let (auth, client, sig) = (keys::unb64(cred["authData"].as_str()?)?, keys::unb64(cred["clientData"].as_str()?)?, keys::unb64(cred["sig"].as_str()?)?);
            let count = auth_data(&auth, &self.rp_id, None)?;
            let stored = k["count"].as_u64().unwrap_or(0) as u32;
            let backwards = main && stored > 0 && count <= stored; // a cloned key; synced passkeys report 0
            (client_data(&client, "get", challenge, &self.origin) && verify(&keys::unb64(k["spki"].as_str()?)?, &auth, &client, &sig) && !backwards).then_some(count)
        });
        let (Some(count), Some((p, k))) = (ok, found) else {
            self.failed(now);
            return Err("auth");
        };
        let person = p["id"].as_str().unwrap_or("").to_owned();
        if main {
            let pm = self.person_mut(&person).unwrap();
            pm["lastSeen"] = json!(iso(now));
            if let Some(km) = arr_mut(pm, "passkeys").iter_mut().find(|x| x["id"] == k["id"]) {
                (km["lastUsed"], km["count"]) = (json!(iso(now)), json!(count));
            }
            let _ = self.save();
        }
        Ok(person)
    }

    /// A new resume key for this person (12 h, memory only).
    pub fn new_resume(&mut self, person: &str, now: i64) -> String {
        let k: [u8; 32] = rand::random();
        self.resume.insert(person.to_owned(), (k, now + RESUME_SECS));
        keys::b64(&k)
    }

    /// `account-resume`: the person whose live resume key made this session's proof.
    pub fn check_resume(&self, proof: &str, mac_nonce: &[u8], fp_mac: &str, fp_browser: &str, now: i64) -> Option<String> {
        use hmac::Mac;
        let given = keys::unb64(proof)?;
        self.resume.iter().filter(|(p, (_, exp))| *exp > now && self.role(p).is_some())
            .find(|(_, (k, _))| resume_mac(k, mac_nonce, fp_mac, fp_browser).verify_slice(&given).is_ok()).map(|(p, _)| p.clone())
    }

    // ---- client requests from a review link (§1.5) ----

    pub fn request(&mut self, name: &str, email: &str, link: &str, now: i64) -> Result<String, &'static str> {
        let name = clean(name, 40);
        if !self.on() || name.is_empty() {
            return Err("invalid");
        }
        let old = iso(now - REQUEST_SECS);
        let reqs = arr_mut(&mut self.v, "requests");
        reqs.retain(|r| r["state"] != "pending" || r["at"].as_str().is_some_and(|a| a > old.as_str())); // the oldest pending go after 30 days
        let pending = || reqs.iter().filter(|r| r["state"] == "pending");
        if pending().filter(|r| r["link"] == link).count() >= REQUESTS_PER_LINK || pending().count() >= REQUESTS_PER_HOST {
            return Err("limit");
        }
        let secret = keys::b64(&rand::random::<[u8; 32]>());
        reqs.push(json!({"id": uuid(), "hash": hash(&secret), "name": name, "email": Some(clean(email, 120)).filter(|e| !e.is_empty()),
            "link": link, "at": iso(now), "state": "pending"}));
        if !self.save() {
            return Err("internal");
        }
        Ok(secret)
    }

    pub fn request_state(&self, secret: &str) -> Option<&str> {
        let h = hash(secret);
        arr(&self.v, "requests").find(|r| keys::subtle_eq(r["hash"].as_str().unwrap_or("").as_bytes(), h.as_bytes())).and_then(|r| r["state"].as_str())
    }

    /// The request's hash (who to tell), for request-accept/-decline.
    pub fn request_hash(&self, id: &str) -> Option<String> {
        arr(&self.v, "requests").find(|r| r["id"] == id).and_then(|r| r["hash"].as_str()).map(str::to_owned)
    }

    /// Accept: a client person and an invite under the request's own hash (the browser holds the secret).
    pub fn request_accept(&mut self, id: &str, now: i64) -> Value {
        let Some(r) = arr(&self.v, "requests").find(|r| r["id"] == id && r["state"] == "pending").cloned() else { return json!({"error": "notFound"}) };
        let pid = uuid();
        arr_mut(&mut self.v, "people").push(json!({"id": pid, "userId": keys::b64(&rand::random::<[u8; 16]>()), "name": r["name"], "email": r["email"],
            "role": "client", "footage": false, "added": iso(now), "by": "mac", "lastSeen": null, "passkeys": []}));
        self.add_invite(&pid, "request", r["hash"].as_str().unwrap_or("").to_owned(), "mac", now + INVITE_SECS, now);
        self.set_request(id, "accepted")
    }

    pub fn request_decline(&mut self, id: &str) -> Value {
        if !arr(&self.v, "requests").any(|r| r["id"] == id && r["state"] == "pending") {
            return json!({"error": "notFound"});
        }
        self.set_request(id, "declined")
    }

    fn set_request(&mut self, id: &str, state: &str) -> Value {
        if let Some(r) = arr_mut(&mut self.v, "requests").iter_mut().find(|r| r["id"] == id) {
            r["state"] = json!(state);
        }
        if self.save() { json!({"ok": true}) } else { json!({"error": "write"}) }
    }

    // ---- what the owner sees and removes (§3) ----

    /// `people`: every person and passkey (no public keys), every open invite, every pending request.
    pub fn view(&self, now: i64) -> Value {
        let people: Vec<Value> = self.people().map(|p| {
            let mut p = p.clone();
            for k in p["passkeys"].as_array_mut().into_iter().flatten() {
                k.as_object_mut().map(|o| o.remove("spki"));
            }
            p
        }).collect();
        let now = iso(now);
        let invites: Vec<Value> = arr(&self.v, "invites").filter(|i| i["used"].is_null() && i["expires"].as_str().is_some_and(|e| e > now.as_str()))
            .map(|i| json!({"id": i["id"], "person": i["person"], "kind": i["kind"], "by": i["by"], "expires": i["expires"]})).collect();
        let used: Vec<Value> = arr(&self.v, "invites").filter(|i| !i["used"].is_null())
            .map(|i| json!({"id": i["id"], "person": i["person"], "kind": i["kind"], "used": i["used"], "usedBy": i["usedBy"]})).collect();
        let requests: Vec<Value> = arr(&self.v, "requests").filter(|r| r["state"] == "pending")
            .map(|r| json!({"id": r["id"], "name": r["name"], "email": r["email"], "link": r["link"], "at": r["at"]})).collect();
        json!({"team": {"id": self.v["team"]["id"], "name": self.v["team"]["name"], "link": self.team_link()}, "settings": self.v["settings"],
            "people": people, "invites": invites, "used": used, "requests": requests})
    }

    pub fn person_update(&mut self, id: &str, op: &Value) -> Value {
        let Some(p) = self.person_mut(id) else { return json!({"error": "notFound"}) };
        if let Some(n) = op["name"].as_str().map(|n| clean(n, 40)).filter(|n| !n.is_empty()) {
            p["name"] = json!(n);
        }
        match op["role"].as_str() {
            Some(r) if ROLES.contains(&r) => p["role"] = json!(r),
            Some(_) => return json!({"error": "invalid"}),
            None => {}
        }
        if let Some(f) = op["footage"].as_bool() {
            p["footage"] = json!(f);
        }
        if let Some(f) = op["footageDownload"].as_bool() {
            p["footageDownload"] = json!(f); // whole footage files, a right of its own (owner decision 3)
        }
        if self.save() { json!({"ok": true}) } else { json!({"error": "write"}) }
    }

    /// Reset sign-in: every passkey and open invite of the person goes, and a new invite for the same record.
    pub fn person_reset(&mut self, id: &str, now: i64) -> Value {
        let Some(p) = self.person_mut(id) else { return json!({"error": "notFound"}) };
        p["passkeys"] = json!([]);
        self.resume.remove(id);
        arr_mut(&mut self.v, "invites").retain(|i| i["person"] != id || !i["used"].is_null());
        let code = new_code();
        self.add_invite(id, "invite", hash(&code), "mac", now + INVITE_SECS, now);
        if !self.save() {
            return json!({"error": "write"});
        }
        json!({"link": self.link_with(&format!("/i/{code}")), "expires": iso(now + INVITE_SECS)})
    }

    pub fn person_remove(&mut self, id: &str) -> Value {
        if self.person(id).is_none() {
            return json!({"error": "notFound"});
        }
        arr_mut(&mut self.v, "people").retain(|p| p["id"] != id);
        arr_mut(&mut self.v, "invites").retain(|i| i["person"] != id);
        self.resume.remove(id);
        if self.save() { json!({"ok": true}) } else { json!({"error": "write"}) }
    }

    pub fn passkey_remove(&mut self, person: &str, id: &str) -> Value {
        let Some(p) = self.person_mut(person) else { return json!({"error": "notFound"}) };
        let keys = arr_mut(p, "passkeys");
        let n = keys.len();
        keys.retain(|k| k["id"] != id);
        if keys.len() == n {
            return json!({"error": "notFound"});
        }
        if keys.is_empty() {
            self.resume.remove(person);
        }
        if self.save() { json!({"ok": true}) } else { json!({"error": "write"}) }
    }

    pub fn invite_cancel(&mut self, id: &str) -> Value {
        let list = arr_mut(&mut self.v, "invites");
        let n = list.len();
        list.retain(|i| i["id"] != id);
        if list.len() == n {
            return json!({"error": "notFound"});
        }
        if self.save() { json!({"ok": true}) } else { json!({"error": "write"}) }
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use hmac::Mac;
    use ring::signature::{ECDSA_P256_SHA256_ASN1_SIGNING, EcdsaKeyPair, KeyPair};

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../../../docs/superpowers/plans/accounts-vectors.json")).unwrap()
    }

    fn un(v: &Value) -> Vec<u8> {
        keys::unb64(v.as_str().unwrap()).unwrap()
    }

    pub fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("pluck-acct-{}", uuid()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// A passkey in a test: a P-256 key made with ring, signing as an authenticator would.
    pub struct Key {
        pair: EcdsaKeyPair,
        pub id: Vec<u8>,
        rng: ring::rand::SystemRandom,
    }

    impl Key {
        pub fn new() -> Key {
            let rng = ring::rand::SystemRandom::new();
            let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng).unwrap();
            Key { pair: EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng).unwrap(), id: rand::random::<[u8; 16]>().to_vec(), rng }
        }

        pub fn spki(&self) -> Vec<u8> {
            [&SPKI_P256[..], self.pair.public_key().as_ref()].concat()
        }

        fn client(ty: &str, challenge: &[u8], origin: &str) -> Vec<u8> {
            json!({"type": ty, "challenge": keys::b64(challenge), "origin": origin, "crossOrigin": false}).to_string().into_bytes()
        }

        /// `account-create`'s cred, with authData flags and the client data's fields as given.
        pub fn create_with(&self, challenge: &[u8], rp: &str, origin: &str, flags: u8) -> Value {
            let p = self.pair.public_key().as_ref();
            let cose = [&[0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20][..], &p[1..33], &[0x22, 0x58, 0x20], &p[33..]].concat();
            let auth = [&Sha256::digest(rp.as_bytes())[..], &[flags], &[0; 4], &[0; 16], &[0, self.id.len() as u8], &self.id, &cose].concat();
            json!({"id": keys::b64(&self.id), "spki": keys::b64(&self.spki()), "authData": keys::b64(&auth),
                "clientData": keys::b64(&Self::client("webauthn.create", challenge, origin))})
        }

        pub fn create(&self, challenge: &[u8]) -> Value {
            self.create_with(challenge, "pluck.tools", "https://pluck.tools", 0x45)
        }

        pub fn get_with(&self, challenge: &[u8], user: &Value, count: u32, origin: &str, flags: u8) -> Value {
            let auth = [&Sha256::digest(b"pluck.tools")[..], &[flags], &count.to_be_bytes()].concat();
            let client = Self::client("webauthn.get", challenge, origin);
            let sig = self.pair.sign(&self.rng, &[&auth[..], &Sha256::digest(&client)[..]].concat()).unwrap();
            json!({"id": keys::b64(&self.id), "authData": keys::b64(&auth), "clientData": keys::b64(&client), "sig": keys::b64(sig.as_ref()), "userHandle": user})
        }

        pub fn get(&self, challenge: &[u8], user: &Value) -> Value {
            self.get_with(challenge, user, 0, "https://pluck.tools", 0x05)
        }
    }

    pub fn team() -> (Accounts, PathBuf) {
        let d = tmp();
        let mut a = Accounts::load(&d);
        assert!(!a.on());
        assert_eq!(a.team_set(Some("Northwind Films"), None)["ok"], true);
        (a, d)
    }

    fn code_of(link: &Value) -> String {
        link.as_str().unwrap().rsplit('/').next().unwrap().to_owned()
    }

    /// Invite → begin → finish with a fresh key: the person id and that key.
    fn enrol(a: &mut Accounts, role: &str, now: i64) -> (String, Key) {
        let inv = a.invite("Anna", role, false, None, "mac", now);
        let (invite, person) = a.begin_create(Create::Invite(&code_of(&inv["link"])), now).unwrap();
        assert_eq!(person, inv["person"]);
        let k = Key::new();
        let ch = [9u8; 32];
        assert_eq!(a.finish_create(&invite, &k.create(&ch), &ch, "Chrome on Mac", now).unwrap(), person);
        (person, k)
    }

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn vectors_match() {
        let v = vectors();
        let s = |k: &str| v[k].as_str().unwrap().to_owned();
        let (mn, n) = (un(&v["macNonce"]), un(&v["nonce"]));
        assert_eq!(keys::b64(&challenge("get", &n, &mn, &s("fpMac"), &s("fpBrowser"))), s("challengeGet"));
        assert_eq!(keys::b64(&challenge("create", &n, &mn, &s("fpMac"), &s("fpBrowser"))), s("challengeCreate"));
        assert_ne!(s("challengeGet"), s("challengeCreate"), "the purpose is in it");
        assert_eq!(account_token(&s("teamId"), &s("personId")), s("accountToken"));
        assert_eq!(keys::b64(&resume_mac(&un(&v["resume"]), &mn, &s("fpMac"), &s("fpBrowser")).finalize().into_bytes()), s("resumeProof"));
        // The browser-made attestation and assertion verify here.
        let ch_get = un(&v["challengeGet"]);
        assert!(client_data(&un(&v["get"]["clientData"]), "get", &ch_get, "https://pluck.tools"));
        assert_eq!(auth_data(&un(&v["get"]["authData"]), "pluck.tools", None), Some(7));
        assert!(verify(&un(&v["spki"]), &un(&v["get"]["authData"]), &un(&v["get"]["clientData"]), &un(&v["get"]["sig"])));
        let ch_create = un(&v["challengeCreate"]);
        assert!(client_data(&un(&v["create"]["clientData"]), "create", &ch_create, "https://pluck.tools"));
        assert_eq!(auth_data(&un(&v["create"]["authData"]), "pluck.tools", Some(&un(&v["credId"]))), Some(0));
        assert!(!client_data(&un(&v["create"]["clientData"]), "get", &ch_create, "https://pluck.tools"), "a create isn't a get");
    }

    #[test]
    fn verify_create_ok_and_refusals() {
        let (mut a, _d) = team();
        let ch = [7u8; 32];
        let mut bad = vec![];
        let k = Key::new();
        bad.push(("evil.pluck.tools", k.create_with(&ch, "pluck.tools", "https://evil.pluck.tools", 0x45)));
        bad.push(("http", k.create_with(&ch, "pluck.tools", "http://pluck.tools", 0x45)));
        bad.push(("rpIdHash", k.create_with(&ch, "evil.tools", "https://pluck.tools", 0x45)));
        bad.push(("no UV", k.create_with(&ch, "pluck.tools", "https://pluck.tools", 0x41)));
        bad.push(("no UP", k.create_with(&ch, "pluck.tools", "https://pluck.tools", 0x44)));
        bad.push(("no AT", k.create_with(&ch, "pluck.tools", "https://pluck.tools", 0x05)));
        bad.push(("challenge", k.create(&[8u8; 32])));
        let mut c = k.create(&ch);
        c["id"] = json!(keys::b64(&[1u8; 16]));
        bad.push(("credential id ≠ rawId", c));
        let mut c = k.create(&ch);
        let mut spki = k.spki();
        spki[3] ^= 1;
        c["spki"] = json!(keys::b64(&spki));
        bad.push(("SPKI prefix", c));
        let mut c = k.create(&ch);
        c["spki"] = json!(keys::b64(&Key::new().spki()));
        bad.push(("SPKI not the attested key", c));
        let mut c = k.create(&ch);
        let mut cd: Value = serde_json::from_slice(&un(&c["clientData"])).unwrap();
        cd["crossOrigin"] = json!(true);
        c["clientData"] = json!(keys::b64(cd.to_string().as_bytes()));
        bad.push(("crossOrigin", c));
        let mut c = k.create(&ch);
        let mut cd: Value = serde_json::from_slice(&un(&c["clientData"])).unwrap();
        cd["type"] = json!("webauthn.get");
        c["clientData"] = json!(keys::b64(cd.to_string().as_bytes()));
        bad.push(("type", c));
        let inv = a.invite("Ben", "editor", false, None, "mac", NOW);
        let (invite, person) = a.begin_create(Create::Invite(&code_of(&inv["link"])), NOW).unwrap();
        for (why, cred) in bad {
            assert_eq!(a.finish_create(&invite, &cred, &ch, "x", NOW), Err("auth"), "{why}");
        }
        assert_eq!(a.finish_create(&invite, &k.create(&ch), &ch, "Safari on iPhone", NOW).unwrap(), person);
        assert_eq!(a.role(&person), Some("editor"));
    }

    #[test]
    fn verify_get_ok_and_refusals() {
        let (mut a, _d) = team();
        let (person, k) = enrol(&mut a, "editor", NOW);
        let user = a.person(&person).unwrap()["userId"].clone();
        let ch = [5u8; 32];
        assert_eq!(a.finish_get(&k.get(&ch, &user), &ch, true, NOW).unwrap(), person);
        assert_eq!(a.finish_get(&k.get(&ch, &Value::Null), &ch, true, NOW).unwrap(), person, "no userHandle: the credential id decides");
        let mut flipped = k.get(&ch, &user);
        let mut sig = un(&flipped["sig"]);
        let last = sig.len() - 1;
        sig[last] ^= 1;
        flipped["sig"] = json!(keys::b64(&sig));
        for (why, cred) in [("evil origin", k.get_with(&ch, &user, 0, "https://evil.pluck.tools", 0x05)), ("http", k.get_with(&ch, &user, 0, "http://pluck.tools", 0x05)),
                            ("no UV", k.get_with(&ch, &user, 0, "https://pluck.tools", 0x01)), ("challenge", k.get(&[6u8; 32], &user)),
                            ("other user handle", k.get(&ch, &json!(keys::b64(&[0u8; 16])))), ("flipped signature bit", flipped)] {
            assert_eq!(a.finish_get(&cred, &ch, true, NOW), Err("auth"), "{why}");
        }
        // signCount backwards on the main: a cloned key.
        assert!(a.finish_get(&k.get_with(&ch, &user, 5, "https://pluck.tools", 0x05), &ch, true, NOW).is_ok());
        assert_eq!(a.finish_get(&k.get_with(&ch, &user, 5, "https://pluck.tools", 0x05), &ch, true, NOW), Err("auth"));
        assert_eq!(a.finish_get(&k.get_with(&ch, &user, 3, "https://pluck.tools", 0x05), &ch, false, NOW).unwrap(), person, "a backup doesn't track counts");
        assert!(a.finish_get(&k.get_with(&ch, &user, 6, "https://pluck.tools", 0x05), &ch, true, NOW).is_ok());
    }

    /// R-1: a validly signed assertion from a credential on no person record (self-made, or another host's) → auth.
    #[test]
    fn r1_an_uninvited_passkey_is_refused() {
        let (mut a, _d) = team();
        let (_, _) = enrol(&mut a, "editor", NOW);
        let (mut b, _d2) = team();
        let (pb, kb) = enrol(&mut b, "owner", NOW);
        let ch = [1u8; 32];
        let self_made = Key::new();
        assert_eq!(a.finish_get(&self_made.get(&ch, &json!(keys::b64(&[3u8; 16]))), &ch, true, NOW), Err("auth"), "a page's own passkey");
        let ub = b.person(&pb).unwrap()["userId"].clone();
        assert!(b.finish_get(&kb.get(&ch, &ub), &ch, true, NOW).is_ok(), "fine at its own host");
        assert_eq!(a.finish_get(&kb.get(&ch, &ub), &ch, true, NOW), Err("auth"), "host B's passkey at host A");
    }

    /// R-2 / R-3: expired and used invites; a device code after 15 minutes.
    #[test]
    fn r2_r3_expired_and_used_invites_are_refused() {
        let (mut a, _d) = team();
        let inv = a.invite("Cleo", "client", false, None, "mac", NOW);
        let code = code_of(&inv["link"]);
        assert_eq!(a.begin_create(Create::Invite(&code), NOW + INVITE_SECS + 1).unwrap_err(), "expired");
        let (invite, person) = a.begin_create(Create::Invite(&code), NOW + 10).unwrap();
        let k = Key::new();
        assert!(a.finish_create(&invite, &k.create(&[1u8; 32]), &[1u8; 32], "x", NOW + 10).is_ok());
        assert_eq!(a.begin_create(Create::Invite(&code), NOW + 20).unwrap_err(), "used");
        assert_eq!(a.finish_create(&invite, &Key::new().create(&[1u8; 32]), &[1u8; 32], "x", NOW + 20).unwrap_err(), "used", "the same invite twice");
        let d = a.device_code(&person, NOW);
        let dcode = code_of(&d["link"]);
        assert_eq!(a.begin_create(Create::Device(&dcode), NOW + DEVICE_SECS + 1).unwrap_err(), "expired");
        assert_eq!(a.begin_create(Create::Invite(&dcode), NOW).unwrap_err(), "auth", "a device code isn't an invite");
        let (di, dp) = a.begin_create(Create::Device(&dcode), NOW + 60).unwrap();
        assert_eq!(dp, person);
        assert_eq!(a.create_user(&person)["exclude"][0], json!(keys::b64(&k.id)), "the existing passkey is excluded");
        assert!(a.finish_create(&di, &Key::new().create(&[1u8; 32]), &[1u8; 32], "Phone", NOW + 60).is_ok());
        assert_eq!(a.person(&person).unwrap()["passkeys"].as_array().unwrap().len(), 2, "a second passkey on the same person");
    }

    /// R-4: a request stays pending until the owner accepts it; declined → revoked; accepted → ok once.
    #[test]
    fn r4_a_pending_request_without_approval_is_refused() {
        let (mut a, _d) = team();
        let s1 = a.request("Dana", "dana@example.com", "L1", NOW).unwrap();
        let s2 = a.request("Eve", "", "L1", NOW).unwrap();
        assert_eq!(a.begin_create(Create::Request(&s1), NOW).unwrap_err(), "pending");
        assert_eq!(a.request_state(&s1), Some("pending"));
        let ids: Vec<String> = a.view(NOW)["requests"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap().to_owned()).collect();
        assert_eq!(a.request_decline(&ids[1])["ok"], true);
        assert_eq!(a.begin_create(Create::Request(&s2), NOW).unwrap_err(), "revoked");
        assert_eq!(a.request_accept(&ids[0], NOW)["ok"], true);
        let (inv, person) = a.begin_create(Create::Request(&s1), NOW + 5).unwrap();
        assert_eq!(a.person(&person).unwrap()["role"], "client");
        assert!(a.finish_create(&inv, &Key::new().create(&[2u8; 32]), &[2u8; 32], "x", NOW + 5).is_ok());
        assert_eq!(a.begin_create(Create::Request(&s1), NOW + 6).unwrap_err(), "used");
        // Limits: 3 pending per link, then limit.
        for i in 0..3 {
            assert!(a.request(&format!("P{i}"), "", "L2", NOW).is_ok());
        }
        assert_eq!(a.request("P4", "", "L2", NOW).unwrap_err(), "limit");
        assert_eq!(a.request("", "", "L3", NOW).unwrap_err(), "invalid");
    }

    /// R-5: no open sign-up. No code, a random code, another host's code → auth; 20 wrong in an hour freeze every invite.
    #[test]
    fn r5_no_open_sign_up() {
        let (mut a, _d) = team();
        let (mut b, _d2) = team();
        let theirs = code_of(&b.invite("X", "owner", false, None, "mac", NOW)["link"]);
        let ours = code_of(&a.invite("Finn", "editor", false, None, "mac", NOW)["link"]);
        assert_eq!(a.begin_create(Create::Invite(""), NOW).unwrap_err(), "auth");
        assert_eq!(a.begin_create(Create::Invite(&new_code()), NOW).unwrap_err(), "auth");
        assert_eq!(a.begin_create(Create::Invite(&theirs), NOW).unwrap_err(), "auth", "another host's code");
        assert_eq!(a.begin_create(Create::Request(&keys::b64(&[1u8; 32])), NOW).unwrap_err(), "auth");
        assert!(a.begin_create(Create::Invite(&ours), NOW).is_ok());
        for _ in 0..16 {
            let _ = a.begin_create(Create::Invite(&new_code()), NOW + 1);
        }
        assert_eq!(a.begin_create(Create::Invite(&ours), NOW + 2).unwrap_err(), "locked", "frozen, even the right one");
        assert_eq!(a.begin_create(Create::Invite(&ours), NOW + 2 + FREEZE_SECS).is_ok(), true, "thawed after 15 minutes");
        // A team-less host has nothing to sign up to.
        let mut none = Accounts::load(&tmp());
        assert_eq!(none.begin_create(Create::Invite(&ours), NOW).unwrap_err(), "auth");
        assert_eq!(none.invite("X", "client", false, None, "mac", NOW)["error"], "invalid");
    }

    /// R-6: the owner removes a passkey, a person (and their open invites), an invite.
    #[test]
    fn r6_the_owner_removes_everything() {
        let (mut a, _d) = team();
        let (person, k) = enrol(&mut a, "editor", NOW);
        let user = a.person(&person).unwrap()["userId"].clone();
        let ch = [4u8; 32];
        assert_eq!(a.passkey_remove(&person, &keys::b64(&k.id))["ok"], true);
        assert_eq!(a.finish_get(&k.get(&ch, &user), &ch, true, NOW), Err("auth"), "a removed passkey");
        assert_eq!(a.role(&person), None, "no passkey: no session");
        let (p2, k2) = enrol(&mut a, "client", NOW);
        let u2 = a.person(&p2).unwrap()["userId"].clone();
        let open = code_of(&a.device_code(&p2, NOW)["link"]);
        assert_eq!(a.view(NOW)["invites"].as_array().unwrap().iter().filter(|i| i["person"] == p2.as_str()).count(), 1);
        assert_eq!(a.person_remove(&p2)["ok"], true);
        assert_eq!(a.finish_get(&k2.get(&ch, &u2), &ch, true, NOW), Err("auth"));
        assert_eq!(a.begin_create(Create::Device(&open), NOW).unwrap_err(), "auth", "their open invites are gone");
        let inv = a.invite("Gus", "client", false, None, "mac", NOW);
        let iid = a.view(NOW)["invites"].as_array().unwrap().iter().find(|i| i["person"] == inv["person"]).unwrap()["id"].as_str().unwrap().to_owned();
        assert_eq!(a.invite_cancel(&iid)["ok"], true);
        assert_eq!(a.begin_create(Create::Invite(&code_of(&inv["link"])), NOW).unwrap_err(), "auth");
        // Reset: passkeys gone, a new invite for the same record.
        let (p3, k3) = enrol(&mut a, "editor", NOW);
        let r = a.person_reset(&p3, NOW);
        assert_eq!(a.finish_get(&k3.get(&ch, &a.person(&p3).unwrap()["userId"].clone()), &ch, true, NOW), Err("auth"));
        assert_eq!(a.begin_create(Create::Invite(&code_of(&r["link"])), NOW).unwrap().1, p3, "the same record");
    }

    #[test]
    fn the_file_is_atomic_and_0600_and_the_view_has_no_keys() {
        use std::os::unix::fs::PermissionsExt;
        let (mut a, d) = team();
        let (person, _) = enrol(&mut a, "owner", NOW);
        let path = d.join("accounts.json");
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        std::fs::write(d.join("accounts.json.tmp"), b"{half").unwrap(); // a crash after the tmp write, before the rename
        let b = Accounts::load(&d);
        assert!(b.person(&person).is_some(), "the old file is kept");
        let mut c = Accounts::load(&d);
        assert!(c.invite("Hal", "client", false, None, "mac", NOW)["link"].is_string(), "a leftover tmp doesn't block the next save");
        let v = a.view(NOW);
        assert!(v.to_string().find("spki").is_none(), "no public keys in the view");
        assert_eq!(v["people"][0]["passkeys"][0]["label"], "Chrome on Mac");
        assert!(a.team_link().unwrap().starts_with("https://pluck.tools/r/#"));
        let room = a.room().unwrap().clone();
        assert_eq!(room["pub"], json!(keys::b64(&keys::public(&un(&room["sign"])).unwrap())));
        assert_eq!(room["roomID"], json!(keys::b64(&keys::derive(&un(&room["key"]), "room", 16))));
    }

    #[test]
    fn resume_keys_and_origin_override() {
        let (mut a, _d) = team();
        let (person, _) = enrol(&mut a, "editor", NOW);
        let r = keys::unb64(&a.new_resume(&person, NOW)).unwrap();
        let proof = keys::b64(&resume_mac(&r, &[1u8; 32], "AA", "BB").finalize().into_bytes());
        assert_eq!(a.check_resume(&proof, &[1u8; 32], "AA", "BB", NOW + 10).as_deref(), Some(person.as_str()));
        assert_eq!(a.check_resume(&proof, &[2u8; 32], "AA", "BB", NOW + 10), None, "another session");
        assert_eq!(a.check_resume(&proof, &[1u8; 32], "AA", "BB", NOW + RESUME_SECS + 1), None, "12 h at most");
        a.person_reset(&person, NOW);
        assert_eq!(a.check_resume(&proof, &[1u8; 32], "AA", "BB", NOW + 10), None, "gone on reset");
        assert!(!a.set_origin("http://localhost:8851", "wss://pluck.tools/signal"), "only with a local signaling URL");
        assert!(!a.set_origin("https://evil.example", "ws://127.0.0.1:8851/signal"));
        assert!(a.set_origin("http://localhost:8851", "ws://127.0.0.1:8851/signal"));
        assert_eq!((a.origin.as_str(), a.rp_id.as_str()), ("http://localhost:8851", "localhost"));
    }

    #[test]
    fn thirty_failed_sign_ins_lock_sign_in_for_15_minutes() {
        let (mut a, _d) = team();
        let (person, k) = enrol(&mut a, "editor", NOW);
        let ch = [3u8; 32];
        for _ in 0..FAILS_PER_HOUR {
            assert_eq!(a.finish_get(&Key::new().get(&ch, &Value::Null), &ch, true, NOW), Err("auth"));
        }
        assert_eq!(a.finish_get(&k.get(&ch, &Value::Null), &ch, true, NOW + 1), Err("locked"), "even the right passkey");
        assert_eq!(a.finish_get(&k.get(&ch, &Value::Null), &ch, true, NOW + FREEZE_SECS).unwrap(), person);
    }

    #[test]
    fn web_invites_are_capped_per_day() {
        let (mut a, _d) = team();
        for i in 0..WEB_INVITES_PER_DAY {
            assert!(a.invite(&format!("C{i}"), "client", false, None, "P1", NOW)["link"].is_string());
        }
        assert_eq!(a.invite("C", "client", false, None, "P1", NOW)["error"], "limit");
        assert!(a.invite("C", "client", false, None, "P1", NOW + 86_401)["link"].is_string());
    }
}
