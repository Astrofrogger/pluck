// The host's side of accounts (plan 2026-11-17-accounts-passkeys.md §2–§4): the team room, passkey sign-in on it and on
// review links, client requests, the owner's sync ops. A child module of host.rs, so it works on Host's own fields.
use std::{collections::VecDeque, time::{Duration, Instant}};

use serde_json::{Value, json};

use super::{Host, HPeer, clean, now_secs, rate};
use crate::{accounts::{self, Create}, keys, log};

const BEGINS_PER_PEER: usize = 10; // a minute
const BEGINS_PER_HOST: usize = 120; // a minute
const FAILS_PER_PEER: u32 = 5; // failed sign-ins and wrong codes, then the peer is closed
const TEAM_FIELDS: [&str; 6] = ["status", "rating", "keywords", "assignee", "due", "notes"];
/// Ops a signed-in editor or owner may run in the team room on a project, through the review-link handlers.
const PROJECT_OPS: [&str; 13] = ["list", "asset", "comments", "fetch", "comment-add", "reply-add", "comment-edit", "comment-delete",
    "comment-complete", "react", "field-set", "viewing", "played"];

/// A team upload into the uploads root (§4.4), between `root-upload-begin` and its end.
pub struct RootUp {
    pub id: String, // the uploads root's upload id: the same file from the same person resumes
    left: u64,      // bytes the helper writes this time (size − have)
    done: bool,     // every byte is on disk
    end: Option<(Value, String)>, // root-upload-end waiting: (request id, the browser's SHA-256, hex)
    name: String,
    by: String,
}

/// A SHA-256 as lowercase hex, from hex or base64url.
fn hex_sha(s: &str) -> Option<String> {
    if s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Some(s.to_ascii_lowercase());
    }
    keys::unb64(s).filter(|b| b.len() == 32).map(|b| b.iter().map(|x| format!("{x:02x}")).collect())
}

const PREVIEW_BYTES: u64 = 8 << 20; // without the download right: at most this of one file per session (fix M4)
const PREVIEW_SLACK: u64 = 1 << 20;  // ranges asked again after a stall
const FRESH_SECS: i64 = 120; // a device code needs a passkey used this recently on this peer (fix M1)
const MKDIRS_PER_MINUTE: usize = 30;

/// Role order: a session whose role goes down is closed (fix M3), so it signs in again with what it may do now.
fn rank(r: Option<&str>) -> u8 {
    match r { Some("owner") => 3, Some("editor") => 2, Some("client") => 1, _ => 0 }
}

/// What a signed-in peer is, on top of a link peer.
#[derive(Default)]
pub struct Acct {
    pub person: Option<String>,
    pub token: Option<String>, // accountToken: the authorToken of what they write (§1.7)
    pending: Option<([u8; 32], i64, &'static str, Option<String>)>, // nonce, made, purpose, invite (create)
    fails: u32,
    begins: VecDeque<Instant>,
    pub project: Option<String>, // team room: the project last asked about, for live events
    pub request: Option<String>, // the account request this peer made (its event)
    pub cred: Option<String>,    // the passkey it signed in with: removing it ends this session (fix H1)
    role: Option<String>,        // the role it signed in with
    fresh: Option<i64>,          // when a passkey (not a resume key) was last used on this peer
    served: std::collections::HashMap<String, u64>, // footage path → bytes served this session (fix M4)
    mkdirs: VecDeque<Instant>,
}

impl Host {
    pub(super) fn is_team(&self, room: &str) -> bool {
        self.accounts.room().is_some_and(|r| r["roomID"] == room)
    }

    /// The team room's hello: signed with its seed, as a level-2 link's (§1.6).
    pub(super) fn team_hello(&self, nonce: &[u8; 32], fp_mac: &str, fp_browser: &str) -> Option<Value> {
        let sig = keys::sign_hello(&keys::unb64(self.accounts.room()?["sign"].as_str()?)?, nonce, fp_mac, fp_browser)?;
        Some(json!({"t": "hello", "v": 2, "nonce": keys::b64(nonce), "sig": sig}))
    }

    /// The room record check_links registers (no expiry: a year at the Worker, §13.24).
    pub(super) fn team_room_reg(&self) -> Option<Value> {
        let r = self.accounts.room()?;
        Some(json!({"room": r["roomID"], "reg": r["reg"], "join": r["join"], "expires": null, "turn": true, "ready": false}))
    }

    /// A link built on the fly for a team op on `project` (§2.1): the review-link handlers do the rest.
    pub(super) fn team_link(&self, project: &str) -> Option<Value> {
        let p = self.manifest["projects"].as_array()?.iter().find(|p| p["id"] == project)?;
        let room = self.accounts.room()?["roomID"].clone();
        Some(json!({"id": "team", "roomID": room, "title": p["name"], "project": project, "root": {"kind": "project", "id": project},
            "audience": "team", "mode": "review", "allowDownload": true, "allowProxy": true, "fields": TEAM_FIELDS, "revoked": null, "expires": null}))
    }

    /// The link a peer's events go by: its own, or for a team peer the project it's looking at.
    pub(super) fn peer_link(&self, p: &HPeer) -> Option<Value> {
        match self.link(&p.room) {
            Some(l) => Some(l.clone()),
            // Only editors and owners hear a team project's live events (fix M3).
            None if p.ready && self.is_team(&p.room) && rank(p.acct.person.as_deref().and_then(|x| self.accounts.role(x))) >= 2 =>
                self.team_link(p.acct.project.as_deref()?),
            None => None,
        }
    }

    /// A signed-in session ends when its person was removed, the passkey it used was removed, or its role went down.
    pub(super) fn acct_gone(&self, p: &HPeer) -> Option<&'static str> {
        let gone = match (&p.acct.person, &p.acct.cred) {
            (Some(id), Some(c)) => !self.accounts.has_cred(id, c) || rank(self.accounts.role(id)) < rank(p.acct.role.as_deref()),
            (Some(_), None) => true,
            (None, _) => p.ready && self.is_team(&p.room),
        };
        gone.then_some("revoked")
    }

    /// Presence goes to (and lists) team-room peers only when they're editors or owners (fix M3).
    pub(super) fn presence_ok(&self, p: &HPeer) -> bool {
        !self.is_team(&p.room) || rank(p.acct.person.as_deref().and_then(|x| self.accounts.role(x))) >= 2
    }

    /// The tokens whose comments are this peer's: the browser's per-link one and the account's.
    pub(super) fn toks(p: &HPeer) -> [Option<&str>; 2] {
        [p.token.as_deref(), p.acct.token.as_deref()]
    }

    fn me(&self, peer: &str) -> Value {
        let p = &self.peers[peer];
        let person = p.acct.person.as_deref().and_then(|id| self.accounts.person(id)).cloned().unwrap_or_default();
        json!({"peer": peer, "account": person["id"], "name": p.name, "role": person["role"], "footage": person["footage"] == true,
            "footageDownload": person["footageDownload"] == true})
    }

    fn can_invite(&self, peer: &str) -> bool {
        match self.peers[peer].acct.person.as_deref().and_then(|id| self.accounts.role(id)) {
            Some("owner") => true,
            Some("editor") => self.accounts.editors_invite(),
            _ => false,
        }
    }

    /// Signed in (create, get or resume): the account's name and token on this peer, a fresh resume key, and on the
    /// team room `ready`; on a review link `me` (the link's rights don't change).
    /// `resumed`: the old resume key's expiry (a resume never extends it); None for a passkey just used.
    fn signed_in(&mut self, peer: &str, id: &Value, person: &str, cred: &str, resumed: Option<i64>) {
        let now = now_secs();
        let Some(rec) = self.accounts.person(person).cloned() else { return self.err(peer, id, "revoked") };
        let team = self.accounts.v["team"]["id"].as_str().unwrap_or("").to_owned();
        let resume = self.accounts.new_resume(person, cred, resumed, now);
        let room = self.peers[peer].room.clone();
        let team_room = self.is_team(&room);
        let role = self.accounts.role(person).map(str::to_owned);
        let p = self.peers.get_mut(peer).unwrap();
        p.acct.cred = Some(cred.to_owned());
        p.acct.role = role;
        p.acct.fresh = resumed.is_none().then_some(now);
        p.acct.person = Some(person.to_owned());
        p.acct.token = Some(accounts::account_token(&team, person));
        p.acct.fails = 0;
        p.name = clean(rec["name"].as_str().unwrap_or(""), 40);
        p.email = rec["email"].as_str().map(|e| clean(e, 120)).unwrap_or_default();
        if team_room {
            p.ready = true;
            let me = self.me(peer);
            self.send(peer, json!({"re": id, "t": "ready", "team": true, "me": me, "resume": resume, "uploads": self.upload_root.is_some(),
                "uploadsRoot": self.upload_root.as_ref().map(|u| u.id.clone()),
                "invite": self.can_invite(peer), "now": super::now_iso()}));
            self.activity(peer, "signedIn", Value::Null, Value::Null, Value::Null);
        } else {
            self.send(peer, json!({"re": id, "ok": true}));
            self.send(peer, json!({"t": "me", "me": self.me(peer), "resume": resume}));
            self.activity(peer, "signedIn", Value::Null, Value::Null, Value::Null);
        }
        self.presence(&room);
    }

    /// A failed sign-in or a wrong code: five on one peer close it.
    fn acct_fail(&mut self, peer: &str, id: &Value, code: &str) {
        self.err(peer, id, code);
        let p = self.peers.get_mut(peer).unwrap();
        p.acct.fails += 1;
        if p.acct.fails >= FAILS_PER_PEER {
            self.close_later(peer);
        }
    }

    /// `account-begin`, `account-get`, `account-create`, `account-resume`, on the team room or a review link. None: not
    /// an account op.
    pub(super) fn account_op(&mut self, peer: &str, id: &Value, t: &str, m: &Value) -> Option<()> {
        if !t.starts_with("account-") || !self.accounts.on() {
            return None;
        }
        let now = now_secs();
        let backup = self.ident.backup;
        let p = &self.peers[peer];
        // Signed in: only a fresh passkey `get` again (for device-code, fix M1) and a client's request ops.
        let again = t == "account-get" || (t == "account-begin" && m["purpose"] == "get");
        if !p.authed || (p.acct.person.is_some() && !again && t != "account-request" && t != "account-status") {
            return Some(self.err(peer, id, "auth"));
        }
        let team_room = self.is_team(&p.room);
        // On a review link: only once the link has let it in, and only signing in or a client's request (§2.2).
        if !team_room && !p.ready {
            return Some(self.err(peer, id, "auth"));
        }
        match t {
            "account-begin" => {
                let ok = rate(&mut self.peers.get_mut(peer).unwrap().acct.begins, Duration::from_secs(60), BEGINS_PER_PEER)
                    && rate(&mut self.acct_begins, Duration::from_secs(60), BEGINS_PER_HOST);
                if !ok {
                    return Some(self.err(peer, id, "limit"));
                }
                let nonce: [u8; 32] = rand::random();
                let mut r = json!({"re": id, "nonce": keys::b64(&nonce), "rp": self.accounts.rp_id});
                let invite = match m["purpose"].as_str() {
                    Some("get") => None,
                    Some("create") if backup => return Some(self.err(peer, id, "main")),
                    Some("create") => {
                        // Only an invite, a device code or an accepted request makes a passkey (no open sign-up). On a review
                        // link only a request: invites open the team room.
                        let how = match (m["invite"].as_str(), m["device"].as_str(), m["request"].as_str()) {
                            (Some(c), None, None) if team_room => Create::Invite(c),
                            (None, Some(c), None) if team_room => Create::Device(c),
                            (None, None, Some(s)) => Create::Request(s),
                            _ => return Some(self.acct_fail(peer, id, "auth")),
                        };
                        match self.accounts.begin_create(how, now) {
                            Ok((invite, person)) => {
                                let u = self.accounts.create_user(&person);
                                (r["user"], r["exclude"]) = (u["user"].clone(), u["exclude"].clone());
                                Some(invite)
                            }
                            Err(c @ ("auth" | "locked")) => return Some(self.acct_fail(peer, id, c)),
                            Err(c) => return Some(self.err(peer, id, c)),
                        }
                    }
                    _ => return Some(self.err(peer, id, "invalid")),
                };
                let purpose = if invite.is_some() { "create" } else { "get" };
                self.peers.get_mut(peer).unwrap().acct.pending = Some((nonce, now, purpose, invite));
                self.send(peer, r);
            }
            "account-get" | "account-create" => {
                let p = self.peers.get_mut(peer).unwrap();
                let pending = p.acct.pending.take();
                let (mac_nonce, fp_mac, fp_browser) = (p.nonce, p.fp_mac.clone(), p.fp_browser.clone());
                let want = if t == "account-get" { "get" } else { "create" };
                // The nonce: this peer's last one, once, within 120 s, for this purpose (§1.2).
                let Some((nonce, at, purpose, invite)) = pending.filter(|(n, at, pu, _)| *pu == want && now - at <= accounts::NONCE_SECS
                    && m["nonce"].as_str().and_then(keys::unb64).is_some_and(|g| keys::subtle_eq(&g, n))) else {
                    return Some(self.acct_fail(peer, id, "auth"));
                };
                let _ = at;
                let challenge = accounts::challenge(purpose, &nonce, &mac_nonce, &fp_mac, &fp_browser);
                let r = match invite {
                    Some(inv) => self.accounts.finish_create(&inv, &m["cred"], &challenge, m["label"].as_str().unwrap_or(""), now),
                    None => self.accounts.finish_get(&m["cred"], &challenge, !backup, now),
                };
                match r {
                    Ok((person, cred)) => self.signed_in(peer, id, &person, &cred, None),
                    Err(c) => self.acct_fail(peer, id, c),
                }
            }
            "account-resume" => {
                let p = &self.peers[peer];
                match self.accounts.check_resume(m["proof"].as_str().unwrap_or(""), &p.nonce, &p.fp_mac, &p.fp_browser, now) {
                    Some((person, cred, exp)) => self.signed_in(peer, id, &person, &cred, Some(exp)),
                    None => self.acct_fail(peer, id, "auth"),
                }
            }
            "account-request" if !team_room => {
                // A client asks for an account from a review link: pending until the owner accepts it in Pluck (§1.5).
                if backup {
                    return Some(self.err(peer, id, "main"));
                }
                if self.peers[peer].acct.request.is_some() {
                    return Some(self.err(peer, id, "limit")); // one per peer
                }
                let link = self.link(&self.peers[peer].room).map_or(Value::Null, |l| l["id"].clone());
                match self.accounts.request(m["name"].as_str().unwrap_or(""), m["email"].as_str().unwrap_or(""), link.as_str().unwrap_or(""), now) {
                    Ok(secret) => {
                        self.peers.get_mut(peer).unwrap().acct.request = Some(keys::sha256_b64(secret.as_bytes()));
                        log("host: a new account request".into());
                        self.send(peer, json!({"re": id, "request": secret}));
                    }
                    Err(c) => self.err(peer, id, c),
                }
            }
            "account-status" if !team_room => match self.accounts.request_state(m["request"].as_str().unwrap_or("")) {
                Some(s) => self.send(peer, json!({"re": id, "state": s})),
                None => self.acct_fail(peer, id, "auth"),
            },
            _ => self.err(peer, id, "invalid"),
        }
        Some(())
    }

    /// Everything on the team room once a peer has passed the hello and `auth` (§2.1). The person's role is read on every
    /// request, so a removal, a role change or footage switched off counts at once.
    pub(super) fn team_request(&mut self, peer: &str, id: &Value, t: &str, m: &Value) {
        let room = self.peers[peer].room.clone();
        let team_auth = json!({"auth": self.accounts.room().map(|r| r["auth"].clone())});
        if t == "auth" {
            return self.auth(peer, id, m, &team_auth);
        }
        if self.account_op(peer, id, t, m).is_some() {
            return;
        }
        if !self.peers[peer].ready {
            return self.err(peer, id, "auth");
        }
        let Some(role) = self.peers[peer].acct.person.as_deref().and_then(|p| self.accounts.role(p)).map(str::to_owned) else {
            self.err(peer, id, "revoked");
            self.send(peer, json!({"t": "bye", "code": "revoked"}));
            return self.close_later(peer);
        };
        let now = now_secs();
        let r = match t {
            "me" => Ok(json!({"me": self.me(peer), "invite": self.can_invite(peer)})),
            "device-code" if self.ident.backup => Err("main"),
            // Only right after a passkey was used on this peer, never on a resume key alone (fix M1).
            "device-code" if self.peers[peer].acct.fresh.is_none_or(|t| now - t > FRESH_SECS) => Err("fresh"),
            "device-code" => {
                let person = self.peers[peer].acct.person.clone().unwrap_or_default();
                Ok(self.accounts.device_code(&person, now))
            }
            _ if role == "client" => Err("scope"), // clients use their links (owner decision 9)
            "projects" => {
                let list: Vec<Value> = self.manifest["projects"].as_array().into_iter().flatten()
                    .map(|p| json!({"id": p["id"], "name": p["name"], "assets": Self::arr(p, "assets").count(), "updated": p["updated"]})).collect();
                Ok(json!({"projects": list}))
            }
            "uploads" => {
                let from = m["offset"].as_u64().unwrap_or(0) as usize;
                let all: Vec<Value> = self.entries.iter().rev().filter_map(|e| e.get("upload"))
                    .map(|u| json!({"id": u["id"], "link": u["link"], "name": u["name"], "size": u["size"], "type": u["type"], "for": u["for"], "by": u["by"], "at": u["at"]}))
                    .skip(from).take(201).collect();
                Ok(json!({"more": all.len() > 200, "uploads": all.into_iter().take(200).collect::<Vec<_>>()}))
            }
            "invite" if self.ident.backup => Err("main"),
            "invite" => {
                // Owners, and editors while "Editors can invite people" is on; never an owner invite from the web.
                let want = m["role"].as_str().unwrap_or("");
                if !self.can_invite(peer) || !(want == "client" || want == "editor") {
                    Err("scope")
                } else {
                    let by = self.peers[peer].acct.person.clone().unwrap_or_default();
                    let r = self.accounts.invite(m["name"].as_str().unwrap_or(""), want, m["footage"] == true && role == "owner", m["email"].as_str(), &by, now);
                    match r["error"].as_str() {
                        Some("limit") => Err("limit"),
                        Some(_) => Err("invalid"),
                        None => Ok(json!({"link": r["link"], "expires": r["expires"]})),
                    }
                }
            }
            "approve" => Err("scope"), // a client's sign-off, never an editor's (owner decision 4)
            "field-set" if m["field"] == "status" && (m["value"] == "approved" || m["value"] == "needsChanges") => Err("scope"),
            "root-list" | "mkdir" | "root-upload-begin" | "root-upload-end" | "root-upload-cancel" => return self.root_op(peer, id, t, m),
            "footage-roots" | "footage-browse" | "footage-thumb" => return self.footage(peer, id, t, m),
            "fetch" if m["what"] == "footage" => return self.footage(peer, id, t, m),
            _ if PROJECT_OPS.contains(&t) => {
                let Some(l) = m["project"].as_str().and_then(|p| self.team_link(p)) else { return self.err(peer, id, "notFound") };
                self.peers.get_mut(peer).unwrap().acct.project = l["project"].as_str().map(str::to_owned);
                return self.dispatch(peer, id, t, &l, m);
            }
            _ => Err("invalid"),
        };
        let _ = room;
        match r {
            Ok(mut v) => {
                if let Some(e) = v["error"].as_str().map(str::to_owned) {
                    return self.err(peer, id, &e);
                }
                v["re"] = id.clone();
                self.send(peer, v);
            }
            Err(c) => self.err(peer, id, c),
        }
    }

    /// The uploads root from a phone (§4.4): list, make folders, and resumable uploads that never overwrite. None on a
    /// backup or without `--uploads` (`scope`).
    fn root_op(&mut self, peer: &str, id: &Value, t: &str, m: &Value) {
        let Some(u) = self.upload_root.clone() else { return self.err(peer, id, "scope") };
        let inside = |p: &str| p == u.id || p.strip_prefix(&u.id).is_some_and(|r| r.starts_with('/'));
        let person = self.peers[peer].acct.person.clone().unwrap_or_default();
        let key = (peer.to_owned(), m["upload"].as_u64().unwrap_or(u64::MAX));
        let r = match t {
            "root-list" => {
                let p = m["path"].as_str().unwrap_or(&u.id);
                if !inside(p) { Err("invalid") } else { self.roots.browse(p).map_err(|_| "invalid") }
            }
            "mkdir" if !rate(&mut self.peers.get_mut(peer).unwrap().acct.mkdirs, Duration::from_secs(60), MKDIRS_PER_MINUTE) => Err("limit"),
            "mkdir" => {
                let p = m["path"].as_str().unwrap_or("");
                let r = if inside(p) { u.mkdir(p) } else { json!({"error": "invalid"}) };
                match r["error"].as_str() { Some(e) => Err(if e == "internal" { "internal" } else { "invalid" }), None => Ok(r) }
            }
            "root-upload-begin" => {
                let Some(uid) = id.as_u64().filter(|u| *u <= u32::MAX as u64) else { return self.err(peer, id, "invalid") };
                let folder = m["path"].as_str().unwrap_or(&u.id).trim_end_matches('/');
                let name = m["name"].as_str().unwrap_or("");
                let Some(size) = m["size"].as_u64().filter(|_| inside(folder) && crate::upload_root::name_ok(name)) else { return self.err(peer, id, "invalid") };
                if self.root_ups.contains_key(&(peer.to_owned(), uid)) {
                    return self.err(peer, id, "invalid");
                }
                // The same file (person, place, size, mtime) gets the same id: a new session resumes it. Its hash comes at the end.
                let full = format!("{folder}/{name}");
                let key = keys::sha256_b64(format!("{person}\0{full}\0{size}\0{}", m["mtime"]).as_bytes());
                let key: String = keys::unb64(&key).unwrap_or_default().iter().map(|b| format!("{b:02x}")).collect();
                let r = u.begin(&json!({"path": full, "size": size, "sha256": key, "hashAtEnd": true, "exclusive": true}), &format!("acct:{person}"));
                if let Some(e) = r["error"].as_str() {
                    return self.err(peer, id, if e == "scope" { "invalid" } else { e }); // (out of the root through a link)
                }
                let (rid, have) = (r["upload"].as_str().unwrap_or("").to_owned(), r["have"].as_u64().unwrap_or(0));
                let left = size - have.min(size);
                if left > 0 {
                    let part = u.partial_dir().join(format!("{rid}.part"));
                    self.cmd(json!({"accept": {"peer": peer, "upload": uid, "path": part.to_string_lossy(), "size": left, "offset": have}}));
                }
                let by = self.peers[peer].name.clone();
                self.root_ups.insert((peer.to_owned(), uid), RootUp { id: rid, left, done: left == 0, end: None, name: name.to_owned(), by });
                Ok(json!({"upload": uid, "have": have, "credit": crate::media::UP_CREDIT}))
            }
            "root-upload-end" => {
                let sha = m["sha256"].as_str().and_then(hex_sha);
                let Some((ru, sha)) = self.root_ups.get_mut(&key).filter(|r| r.end.is_none()).zip(sha) else { return self.err(peer, id, "invalid") };
                ru.end = Some((id.clone(), sha));
                if ru.done {
                    self.root_finish(&key);
                }
                return;
            }
            _ => {
                // root-upload-cancel: the partial goes too.
                let Some(ru) = self.root_ups.remove(&key) else { return self.err(peer, id, "notFound") };
                self.cmd(json!({"cancel": {"peer": peer, "upload": key.1}}));
                Ok(u.cancel(&json!({"upload": ru.id})))
            }
        };
        match r {
            Ok(mut v) => {
                v["re"] = id.clone();
                self.send(peer, v);
            }
            Err(c) => self.err(peer, id, c),
        }
    }

    /// The helper's report for a team upload: every byte there (then the end, if asked), or it failed (the partial
    /// stays for a resume).
    pub(super) fn root_written(&mut self, key: &(String, u64), u: &Value) {
        let Some(ru) = self.root_ups.get_mut(key) else { return };
        if u["state"] == "done" && u["bytes"].as_u64() == Some(ru.left) {
            ru.done = true;
            if ru.end.is_some() {
                self.root_finish(key);
            }
        } else if let Some(ru) = self.root_ups.remove(key) {
            if let Some(r) = &self.upload_root {
                r.release(&ru.id);
            }
            if let Some((id, _)) = ru.end {
                self.err(&key.0, &id, "invalid");
            }
        }
    }

    /// The whole file hashed and placed by UploadRoot::end (link + unlink, " 2" names), off the host task.
    fn root_finish(&mut self, key: &(String, u64)) {
        let Some(ru) = self.root_ups.remove(key) else { return };
        let (Some(u), Some((re, sha))) = (self.upload_root.clone(), ru.end.clone()) else { return };
        let (back, peer) = (self.back.clone(), key.0.clone());
        tokio::spawn(async move {
            let r = u.end(&json!({"upload": ru.id, "sha256": sha})).await;
            if let Some(b) = back {
                let _ = b.send(("acct:up".into(), json!({"peer": peer, "re": re, "name": ru.name, "by": ru.by, "sha256": sha, "r": r})));
            }
        });
    }

    /// Background results (`acct:` in run's progress channel).
    pub(super) fn acct_back(&mut self, kind: &str, s: Value) {
        let (peer, re) = (s["peer"].as_str().unwrap_or("").to_owned(), s["re"].clone());
        if let Some(e) = s["r"]["error"].as_str() {
            return self.err(&peer, &re, if e.contains(' ') { "notFound" } else { e });
        }
        if kind == "thumb" {
            return self.send(&peer, json!({"re": re, "jpeg": s["r"]["jpeg"]}));
        }
        let path = s["r"]["path"].as_str().unwrap_or("").to_owned();
        let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
        let entry = json!({"id": super::uuid(), "link": "team", "name": s["name"], "path": path, "size": s["r"]["size"], "sha256": s["sha256"],
            "type": super::upload_kind(&ext).map_or("application/octet-stream", |(_, m)| m), "for": "root", "by": s["by"], "at": super::now_iso()});
        if !self.append(json!({"upload": entry})) {
            return self.err(&peer, &re, "internal");
        }
        if self.peers.contains_key(&peer) {
            self.activity(&peer, "uploaded", Value::Null, Value::Null, json!({"name": s["name"], "size": s["r"]["size"], "path": path}));
        }
        self.send(&peer, json!({"re": re, "uploaded": {"name": s["name"], "path": path, "size": s["r"]["size"]}}));
    }

    /// Footage (`footage: true` only, owner decision 3): the host's roots read-only, thumbnails, and fetches that are
    /// ranges for a streaming preview; a whole file only with the separate download right. Each fetch is in the activity.
    fn footage(&mut self, peer: &str, id: &Value, t: &str, m: &Value) {
        let person = self.peers[peer].acct.person.as_deref().and_then(|p| self.accounts.person(p)).cloned().unwrap_or_default();
        if person["footage"] != true {
            return self.err(peer, id, "scope");
        }
        // Never the clients' quarantine or anything hidden.
        let path = m["path"].as_str().unwrap_or("").to_owned();
        if path.starts_with('.') || path.split('/').any(|c| c.starts_with('.')) {
            return self.err(peer, id, "invalid");
        }
        match t {
            "footage-roots" => {
                let ids: Vec<&String> = self.roots.0.iter().map(|(i, _)| i).filter(|i| !i.starts_with('.')).collect();
                self.send(peer, json!({"re": id, "roots": ids}));
            }
            "footage-browse" => match self.roots.browse(&path).ok().filter(|_| !path.is_empty()) {
                Some(mut v) => {
                    v["re"] = id.clone();
                    self.send(peer, v);
                }
                None => self.err(peer, id, "invalid"),
            },
            "footage-thumb" => {
                if self.roots.resolve(&path, false).is_none() {
                    return self.err(peer, id, "invalid");
                }
                let (roots, back, peer, re) = (self.roots.clone(), self.back.clone(), peer.to_owned(), id.clone());
                tokio::spawn(async move {
                    let r = roots.thumb(&path).await.unwrap_or_else(|e| json!({"error": format!("{e:#}")}));
                    if let Some(b) = back {
                        let _ = b.send(("acct:thumb".into(), json!({"peer": peer, "re": re, "r": r})));
                    }
                });
            }
            _ => {
                let Some(fetch) = id.as_u64().filter(|f| *f <= u32::MAX as u64) else { return self.err(peer, id, "invalid") };
                if self.peers[peer].fetches.contains_key(&fetch) {
                    return self.err(peer, id, "invalid"); // an id still in flight (as fetch() does, fix L6)
                }
                let Some(file) = self.roots.resolve(&path, false) else { return self.err(peer, id, "invalid") };
                let len = std::fs::metadata(&file).map_or(0, |x| x.len());
                let off = m["offset"].as_u64().unwrap_or(0).min(len);
                let want = m["length"].as_u64().unwrap_or(len - off).min(len - off);
                // A preview: at most PREVIEW_BYTES of a file per session in all, so ranges in a row are no download (fix M4).
                // (keyed by the file itself: another spelling of the same path doesn't get a fresh budget)
                let key = file.to_string_lossy().into_owned();
                let served = self.peers[peer].acct.served.get(&key).copied().unwrap_or(0);
                if person["footageDownload"] != true && served + want > PREVIEW_BYTES + PREVIEW_SLACK {
                    return self.err(peer, id, "scope"); // downloading needs its own right
                }
                let p = self.peers.get_mut(peer).unwrap();
                *p.acct.served.entry(key).or_default() += want;
                p.fetches.insert(fetch, Default::default());
                let kind = match crate::roots::kind_of(&path) { Some("video") => "video/mp4", Some("audio") => "audio/mp4", Some("image") => "image/jpeg", _ => "application/octet-stream" };
                let name = path.rsplit('/').next().unwrap_or("").to_owned();
                self.send(peer, json!({"re": id, "fetch": fetch, "size": want, "type": kind, "name": name}));
                self.cmd(json!({"serve": {"peer": peer, "fetch": fetch, "pieces": [{"path": file.to_string_lossy(), "offset": off, "length": want}]}}));
                self.activity(peer, "footage", Value::Null, Value::Null, json!({"path": path, "offset": off, "length": want}));
            }
        }
    }

    /// After a People change: sessions of removed people end (bye revoked); the others re-read `me`.
    fn people_changed(&mut self) {
        self.check_links(); // ends removed people, removed passkeys and lowered roles (acct_gone)
        let signed: Vec<String> = self.peers.iter().filter(|(_, p)| p.acct.person.is_some()).map(|(id, _)| id.clone()).collect();
        for id in signed {
            self.send(&id, json!({"t": "account-changed"}));
        }
    }

    /// The owner's ops (Pluck → main, role mac; §3). None: not an account op. A backup answers `main` to every change.
    pub(super) fn account_sync(&mut self, op: &Value) -> Option<Value> {
        let name = op["op"].as_str().unwrap_or("");
        let now = now_secs();
        const WRITES: [&str; 9] = ["team-set", "person-invite", "person-update", "person-reset", "person-remove", "passkey-remove", "invite-cancel",
            "request-accept", "request-decline"];
        if WRITES.contains(&name) && self.ident.backup {
            return Some(json!({"error": {"code": "main"}}));
        }
        let s = |x: &str| op[x].as_str().unwrap_or("").to_owned();
        let r = match name {
            "people" => {
                let mut v = if self.accounts.on() { self.accounts.view(now) } else { json!({"team": null, "people": [], "invites": [], "requests": []}) };
                v["locked"] = json!(self.accounts.locked(now)); // passkeys locked after failed sign-ins
                v
            }
            "team-set" => self.accounts.team_set(op["name"].as_str(), op["editorsInvite"].as_bool()),
            "person-invite" => {
                if !self.accounts.on() {
                    return Some(json!({"error": "invalid"}));
                }
                self.accounts.invite(&s("name"), &s("role"), op["footage"] == true, op["email"].as_str(), "mac", now)
            }
            "person-update" => self.accounts.person_update(&s("id"), op),
            "person-reset" => self.accounts.person_reset(&s("id"), now),
            "person-remove" => self.accounts.person_remove(&s("id")),
            "passkey-remove" => self.accounts.passkey_remove(&s("person"), &s("id")),
            "invite-cancel" => self.accounts.invite_cancel(&s("id")),
            "request-accept" | "request-decline" => {
                let hash = self.accounts.request_hash(&s("id"));
                let r = if name == "request-accept" { self.accounts.request_accept(&s("id"), now) } else { self.accounts.request_decline(&s("id"), now) };
                // The browser that asked, if it's still here, checks again at once.
                for (pid, p) in &self.peers {
                    if hash.is_some() && p.acct.request == hash {
                        self.send(pid, json!({"t": "account-request-changed"}));
                    }
                }
                r
            }
            "_accounts" if self.ident.backup => json!({"error": "scope"}),
            "_accounts" => if self.accounts.on() { self.accounts.v.clone() } else { json!({"format": 0}) },
            "_accounts-apply" => {
                // A backup's pull (replica.rs): the main's file as it is; nothing there yet leaves ours alone.
                if op["accounts"]["format"] != 1 {
                    return Some(json!({"ok": true}));
                }
                // The same as ours (every pull while nothing changed): no rewrite, and team pages don't redraw.
                if op["accounts"] == self.accounts.v {
                    return Some(json!({"ok": true}));
                }
                if !self.accounts.replace(op["accounts"].clone()) {
                    return Some(json!({"error": "write"}));
                }
                self.people_changed();
                return Some(json!({"ok": true}));
            }
            _ => return None,
        };
        if name != "people" && r.get("error").is_none() {
            self.people_changed();
        }
        Some(r)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use serde_json::{Value, json};
    use tokio::sync::mpsc;

    use super::super::{Host, now_secs, uuid};
    use crate::{Ev, accounts::{self, tests::Key}, keys, roots::Roots};

    const SEED: &str = "R85Juszx1tmPSUJlpjYA3DtFmqHJDUUU0Z1HyoU0Mb4";

    fn host() -> (Host, mpsc::UnboundedReceiver<Ev>) {
        let dir = std::env::temp_dir().join(format!("pluck-host-acct-{}", uuid()));
        let (tx, rx) = mpsc::unbounded_channel();
        let mut h = Host::new(&dir, Arc::new(Roots(vec![])), tx, None);
        let link = json!({"id": "L1", "roomID": "R1", "reg": "r", "auth": keys::b64(&[8u8; 32]), "title": "T", "mode": "review", "revoked": null,
            "expires": null, "project": "P", "root": {"kind": "project", "id": "P"}, "sign": SEED, "join": "DDk_aLVe7_lpSrn2FJsnpy4x8AsymOK8AZOx9K_7OAo"});
        h.publish(&json!({"format": 1, "projects": [{"id": "P", "name": "Film", "folders": [],
            "assets": [{"id": "A", "name": "Cut", "folder": null, "kind": "video", "status": "needsReview", "versions": [{"id": "V", "number": 1, "frames": 100}]}]},
            {"id": "Q", "name": "Other", "folders": [], "assets": []}], "links": [link]}), &json!({}));
        (h, rx)
    }

    fn msgs(rx: &mut mpsc::UnboundedReceiver<Ev>) -> Vec<Value> {
        std::iter::from_fn(|| rx.try_recv().ok()).filter_map(|e| if let Ev::Cmd(v) = e { Some(v) } else { None }).collect()
    }

    fn to(all: &[Value], peer: &str) -> Vec<Value> {
        all.iter().filter(|c| c["send"]["peer"] == peer).map(|c| c["send"]["msg"].clone()).collect()
    }

    /// A browser on one DTLS session: its view of the hello nonce and both fingerprints.
    struct Br {
        peer: String,
        mac_nonce: Vec<u8>,
        fp: (String, String),
    }

    impl Br {
        fn ask(&self, h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, id: u64, mut m: Value) -> Value {
            m["id"] = json!(id);
            h.request(&self.peer, &m);
            let all = msgs(rx);
            to(&all, &self.peer).into_iter().find(|x| x["re"] == id).unwrap_or(Value::Null)
        }

        fn challenge(&self, purpose: &str, nonce: &Value) -> [u8; 32] {
            accounts::challenge(purpose, &keys::unb64(nonce.as_str().unwrap()).unwrap(), &self.mac_nonce, &self.fp.0, &self.fp.1)
        }
    }

    /// Open a peer on `room` and pass `auth` with `auth_key` (the team room's, or a link's).
    fn open(h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, peer: &str, room: &str, auth_key: &[u8], fp: (&str, &str)) -> (Br, Value, Value) {
        h.report(&json!({"peer": {"peer": peer, "state": "open", "room": room, "fpLocal": fp.0, "fpRemote": fp.1}}));
        let hello = to(&msgs(rx), peer).into_iter().find(|m| m["t"] == "hello").unwrap();
        let br = Br { peer: peer.into(), mac_nonce: keys::unb64(hello["nonce"].as_str().unwrap()).unwrap(), fp: (fp.0.into(), fp.1.into()) };
        let bn = [2u8; 32];
        h.request(peer, &json!({"id": 1, "t": "auth", "v": 2, "nonce": keys::b64(&bn), "proof": keys::proof(auth_key, "browser", &br.mac_nonce, &bn, fp.0, fp.1),
            "token": keys::b64(&rand::random::<[u8; 32]>()), "name": "Typed name"}));
        let all = msgs(rx);
        let welcome = to(&all, peer).into_iter().find(|m| m["re"] == 1).unwrap_or(Value::Null);
        (br, hello, welcome)
    }

    fn open_team(h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, peer: &str, fp: (&str, &str)) -> (Br, Value, Value) {
        let (r, a) = (room(h), team_auth(h));
        open(h, rx, peer, &r, &a, fp)
    }

    fn team_auth(h: &Host) -> Vec<u8> {
        keys::unb64(h.accounts.room().unwrap()["auth"].as_str().unwrap()).unwrap()
    }

    fn room(h: &Host) -> String {
        h.accounts.room().unwrap()["roomID"].as_str().unwrap().to_owned()
    }

    fn invite(h: &mut Host, role: &str) -> String {
        let r = h.sync(&json!({"op": "person-invite", "name": format!("{role} one"), "role": role, "footage": false}));
        r["link"].as_str().unwrap().rsplit('/').next().unwrap().to_owned()
    }

    /// Invite → open the team room → create a passkey: the signed-in browser and its key.
    fn enrol(h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, peer: &str, role: &str) -> (Br, Key, Value) {
        let code = invite(h, role);
        let (r, a) = (room(h), team_auth(h));
        let (br, _, w) = open(h, rx, peer, &r, &a, ("AA", "BB"));
        assert_eq!(w["needAccount"], true);
        let b = br.ask(h, rx, 2, json!({"t": "account-begin", "purpose": "create", "invite": code}));
        let k = Key::new();
        let ready = br.ask(h, rx, 3, json!({"t": "account-create", "nonce": b["nonce"], "cred": k.create(&br.challenge("create", &b["nonce"])), "label": "Chrome on Mac"}));
        assert_eq!(ready["t"], "ready", "{ready}");
        (br, k, ready)
    }

    fn sign_in(h: &mut Host, rx: &mut mpsc::UnboundedReceiver<Ev>, peer: &str, k: &Key, fp: (&str, &str)) -> (Br, Value) {
        let (r, a) = (room(h), team_auth(h));
        let (br, _, _) = open(h, rx, peer, &r, &a, fp);
        let b = br.ask(h, rx, 2, json!({"t": "account-begin", "purpose": "get"}));
        let r = br.ask(h, rx, 3, json!({"t": "account-get", "nonce": b["nonce"], "cred": k.get(&br.challenge("get", &b["nonce"]), &Value::Null)}));
        (br, r)
    }

    #[tokio::test]
    async fn the_team_room_signs_its_hello_and_wants_a_passkey() {
        let (mut h, mut rx) = host();
        assert_eq!(h.sync(&json!({"op": "team-set", "name": "Northwind Films"}))["ok"], true);
        let rooms = msgs(&mut rx).into_iter().rev().find(|c| c.get("rooms").is_some()).unwrap();
        let team = h.accounts.room().unwrap().clone();
        assert!(rooms["rooms"].as_array().unwrap().iter().any(|r| r["room"] == team["roomID"] && r["expires"].is_null() && r["reg"] == team["reg"]), "{rooms}");
        let (br, hello, welcome) = open_team(&mut h, &mut rx, "t1", ("AA", "BB"));
        assert!(keys::verify_hello(&keys::unb64(team["pub"].as_str().unwrap()).unwrap(), hello["sig"].as_str().unwrap(), &br.mac_nonce, "AA", "BB"));
        assert_eq!((welcome["needAccount"].clone(), welcome["team"]["name"].clone()), (json!(true), json!("Northwind Films")));
        assert!(to(&msgs(&mut rx), "t1").iter().all(|m| m["t"] != "ready"), "no ready before a passkey");
        for (i, t) in ["projects", "list", "uploads", "invite", "device-code", "me"].iter().enumerate() {
            assert_eq!(br.ask(&mut h, &mut rx, 10 + i as u64, json!({"t": t, "project": "P"}))["error"]["code"], "auth", "{t}");
        }
        // A get with a passkey on no record (a self-made one) is refused, and shows nothing.
        let b = br.ask(&mut h, &mut rx, 20, json!({"t": "account-begin", "purpose": "get"}));
        let k = Key::new();
        assert_eq!(br.ask(&mut h, &mut rx, 21, json!({"t": "account-get", "nonce": b["nonce"], "cred": k.get(&br.challenge("get", &b["nonce"]), &Value::Null)}))["error"]["code"], "auth");
        // A create without an invite: auth (no open sign-up).
        assert_eq!(br.ask(&mut h, &mut rx, 22, json!({"t": "account-begin", "purpose": "create"}))["error"]["code"], "auth");
    }

    #[tokio::test]
    async fn invite_create_then_sign_in_and_challenges_bound_to_the_session() {
        let (mut h, mut rx) = host();
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let (br, k, ready) = enrol(&mut h, &mut rx, "t1", "editor");
        assert_eq!((ready["me"]["role"].clone(), ready["me"]["name"].clone(), ready["team"].clone()), (json!("editor"), json!("editor one"), json!(true)));
        assert!(ready["resume"].is_string());
        let p = br.ask(&mut h, &mut rx, 4, json!({"t": "projects"}));
        assert_eq!(p["projects"].as_array().unwrap().len(), 2);
        let l = br.ask(&mut h, &mut rx, 5, json!({"t": "list", "project": "P"}));
        assert_eq!(l["assets"][0]["id"], "A");
        // Sign in again on a new session: fine.
        let (_, r) = sign_in(&mut h, &mut rx, "t2", &k, ("CC", "DD"));
        assert_eq!(r["t"], "ready");
        // A nonce from session 3 answered on session 4 (other fingerprints and hello nonce): auth.
        let (a3, _, _) = open_team(&mut h, &mut rx, "t3", ("AA", "BB"));
        let (a4, _, _) = open_team(&mut h, &mut rx, "t4", ("EE", "FF"));
        let b3 = a3.ask(&mut h, &mut rx, 2, json!({"t": "account-begin", "purpose": "get"}));
        let b4 = a4.ask(&mut h, &mut rx, 2, json!({"t": "account-begin", "purpose": "get"}));
        let cross = k.get(&a3.challenge("get", &b3["nonce"]), &Value::Null);
        assert_eq!(a4.ask(&mut h, &mut rx, 3, json!({"t": "account-get", "nonce": b4["nonce"], "cred": cross}))["error"]["code"], "auth", "another session's challenge");
        // Replayed nonce: used once.
        let b = a3.ask(&mut h, &mut rx, 4, json!({"t": "account-begin", "purpose": "get"}));
        let _ = b3;
        let good = k.get(&a3.challenge("get", &b["nonce"]), &Value::Null);
        h.peers.get_mut("t3").unwrap().acct.pending.as_mut().unwrap().1 -= 121;
        assert_eq!(a3.ask(&mut h, &mut rx, 5, json!({"t": "account-get", "nonce": b["nonce"], "cred": good}))["error"]["code"], "auth", "older than 120 s");
        let b = a3.ask(&mut h, &mut rx, 6, json!({"t": "account-begin", "purpose": "get"}));
        let good = k.get(&a3.challenge("get", &b["nonce"]), &Value::Null);
        assert_eq!(a3.ask(&mut h, &mut rx, 7, json!({"t": "account-get", "nonce": b["nonce"], "cred": good.clone()}))["t"], "ready");
        let (a5, _, _) = open_team(&mut h, &mut rx, "t5", ("AA", "BB"));
        assert_eq!(a5.ask(&mut h, &mut rx, 3, json!({"t": "account-get", "nonce": b["nonce"], "cred": good}))["error"]["code"], "auth", "a replayed nonce");
        // A create challenge can't be a get.
        let b = a5.ask(&mut h, &mut rx, 4, json!({"t": "account-begin", "purpose": "get"}));
        let wrong = k.get(&a5.challenge("create", &b["nonce"]), &Value::Null);
        assert_eq!(a5.ask(&mut h, &mut rx, 5, json!({"t": "account-get", "nonce": b["nonce"], "cred": wrong}))["error"]["code"], "auth");
    }

    #[tokio::test]
    async fn roles_are_checked_on_every_request() {
        let (mut h, mut rx) = host();
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let (client, _, ready) = enrol(&mut h, &mut rx, "c1", "client");
        assert_eq!(ready["me"]["role"], "client");
        assert_eq!(client.ask(&mut h, &mut rx, 4, json!({"t": "projects"}))["error"]["code"], "scope", "clients get the 'You're set' screen only");
        assert_eq!(client.ask(&mut h, &mut rx, 5, json!({"t": "list", "project": "P"}))["error"]["code"], "scope");
        assert!(client.ask(&mut h, &mut rx, 6, json!({"t": "device-code"}))["link"].as_str().unwrap().contains("/d/"));
        let (ed, _, ready) = enrol(&mut h, &mut rx, "e1", "editor");
        assert_eq!(ready["invite"], false);
        for (i, m) in [json!({"t": "approve", "project": "P", "asset": "A", "version": "V", "decision": "approve"}),
                       json!({"t": "field-set", "project": "P", "asset": "A", "field": "status", "value": "approved"}),
                       json!({"t": "invite", "name": "X", "role": "client"})].into_iter().enumerate() {
            assert_eq!(ed.ask(&mut h, &mut rx, 10 + i as u64, m.clone())["error"]["code"], "scope", "{m}");
        }
        assert!(ed.ask(&mut h, &mut rx, 20, json!({"t": "field-set", "project": "P", "asset": "A", "field": "status", "value": "inProgress"}))["asset"].is_object(),
            "an editor sets status, not approvals");
        h.sync(&json!({"op": "team-set", "editorsInvite": true}));
        assert_eq!(ed.ask(&mut h, &mut rx, 21, json!({"t": "invite", "name": "Owner?", "role": "owner"}))["error"]["code"], "scope", "never an owner invite");
        let inv = ed.ask(&mut h, &mut rx, 22, json!({"t": "invite", "name": "New client", "role": "client"}));
        assert!(inv["link"].as_str().unwrap().contains("/i/"), "{inv}");
        assert_eq!(h.accounts.view(0)["invites"].as_array().unwrap().iter().filter(|i| i["by"] == ready["me"]["account"]).count(), 1);
        // A role going up: account-changed, the session stays. Going down: the session ends (fix M3), and signed in
        // again it goes by the new role.
        let eid = ready["me"]["account"].as_str().unwrap().to_owned();
        msgs(&mut rx);
        assert_eq!(h.sync(&json!({"op": "person-update", "id": eid, "role": "owner"}))["ok"], true);
        assert!(to(&msgs(&mut rx), "e1").iter().any(|m| m["t"] == "account-changed"));
        assert_eq!(ed.ask(&mut h, &mut rx, 23, json!({"t": "me"}))["me"]["role"], "owner");
        assert_eq!(h.sync(&json!({"op": "person-update", "id": eid, "role": "client"}))["ok"], true);
        assert!(to(&msgs(&mut rx), "e1").iter().any(|m| m["t"] == "bye" && m["code"] == "revoked"));
        assert!(!h.peers.contains_key("e1"), "a lowered role closes the session");
    }

    /// Fix H1/M1/M3: removing one passkey ends that device's session only; a device code needs a passkey just used;
    /// team-room clients hear no presence and no live project events.
    #[tokio::test]
    async fn one_removed_passkey_ends_its_own_session_and_device_codes_need_a_fresh_passkey() {
        let (mut h, mut rx) = host();
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let (b1, k1, ready) = enrol(&mut h, &mut rx, "t1", "editor");
        let pid = ready["me"]["account"].as_str().unwrap().to_owned();
        let d = b1.ask(&mut h, &mut rx, 4, json!({"t": "device-code"}));
        let code = d["link"].as_str().unwrap().rsplit('/').next().unwrap().to_owned();
        let (b2, _, _) = open_team(&mut h, &mut rx, "t2", ("CC", "DD"));
        let b = b2.ask(&mut h, &mut rx, 2, json!({"t": "account-begin", "purpose": "create", "device": code}));
        let k2 = Key::new();
        assert_eq!(b2.ask(&mut h, &mut rx, 3, json!({"t": "account-create", "nonce": b["nonce"], "cred": k2.create(&b2.challenge("create", &b["nonce"])), "label": "Phone"}))["t"], "ready");
        // Resume on a third session from t1's key: a resume never makes device codes.
        let resume = keys::unb64(ready["resume"].as_str().unwrap()).unwrap();
        let (b3, _, _) = open_team(&mut h, &mut rx, "t3", ("EE", "FF"));
        use hmac::Mac;
        let mut m = hmac::Hmac::<sha2::Sha256>::new_from_slice(&resume).unwrap();
        for p in [b"pluck-account/1 resume\n".as_slice(), &b3.mac_nonce, b"EE", b"\n", b"FF"] {
            m.update(p);
        }
        assert_eq!(b3.ask(&mut h, &mut rx, 2, json!({"t": "account-resume", "proof": keys::b64(&m.finalize().into_bytes())}))["t"], "ready");
        assert_eq!(b3.ask(&mut h, &mut rx, 3, json!({"t": "device-code"}))["error"]["code"], "fresh");
        h.peers.get_mut("t1").unwrap().acct.fresh = Some(now_secs() - 121);
        assert_eq!(b1.ask(&mut h, &mut rx, 5, json!({"t": "device-code"}))["error"]["code"], "fresh", "two minutes at most");
        let b = b1.ask(&mut h, &mut rx, 6, json!({"t": "account-begin", "purpose": "get"}));
        assert_eq!(b1.ask(&mut h, &mut rx, 7, json!({"t": "account-get", "nonce": b["nonce"], "cred": k1.get(&b1.challenge("get", &b["nonce"]), &Value::Null)}))["t"], "ready");
        assert!(b1.ask(&mut h, &mut rx, 8, json!({"t": "device-code"}))["link"].is_string(), "the passkey again: fresh");
        assert_eq!(b1.ask(&mut h, &mut rx, 9, json!({"t": "account-begin", "purpose": "create", "invite": accounts::new_code()}))["error"]["code"], "auth",
            "signed in: no create");
        // Remove the first passkey: t1 and t3 (its resume) end, t2 (the phone's passkey) stays.
        msgs(&mut rx);
        assert_eq!(h.sync(&json!({"op": "passkey-remove", "person": pid, "id": keys::b64(&k1.id)}))["ok"], true);
        let all = msgs(&mut rx);
        for p in ["t1", "t3"] {
            assert!(to(&all, p).iter().any(|m| m["t"] == "bye" && m["code"] == "revoked"), "{p}");
            assert!(!h.peers.contains_key(p));
        }
        assert!(h.peers.contains_key("t2"));
        assert_eq!(b2.ask(&mut h, &mut rx, 4, json!({"t": "projects"}))["projects"].as_array().unwrap().len(), 2);
        // A client in the team room: no presence, no live comments.
        let (_, _, cr) = enrol(&mut h, &mut rx, "c1", "client");
        assert_eq!(cr["me"]["role"], "client");
        b2.ask(&mut h, &mut rx, 5, json!({"t": "viewing", "project": "P", "asset": "A"}));
        h.peers.get_mut("c1").unwrap().acct.project = Some("P".into());
        h.request("t2", &json!({"id": 6, "t": "comment-add", "project": "P", "asset": "A", "version": "V", "frame": 2, "text": "Internal"}));
        let all = msgs(&mut rx);
        assert!(to(&all, "c1").iter().all(|m| m["t"] != "presence" && m["t"] != "comment"), "{:?}", to(&all, "c1"));
        assert!(to(&all, "t2").iter().filter(|m| m["t"] == "presence").all(|m| m["viewers"].as_array().unwrap().iter().all(|v| v["peer"] != "c1")));
    }

    #[tokio::test]
    async fn removing_a_person_ends_their_sessions_and_comments_follow_the_account() {
        let (mut h, mut rx) = host();
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let (b1, k, ready) = enrol(&mut h, &mut rx, "t1", "editor");
        let c = b1.ask(&mut h, &mut rx, 4, json!({"t": "comment-add", "project": "P", "asset": "A", "version": "V", "frame": 1, "text": "Trim this"}));
        assert_eq!((c["comment"]["mine"].clone(), c["comment"]["author"].clone()), (json!(true), json!("editor one")));
        let (b2, _) = sign_in(&mut h, &mut rx, "t2", &k, ("CC", "DD"));
        let list = b2.ask(&mut h, &mut rx, 4, json!({"t": "comments", "project": "P", "asset": "A", "version": "V"}));
        assert_eq!(list["comments"][0]["mine"], true, "mine on another device: the account token");
        assert_eq!(b2.ask(&mut h, &mut rx, 5, json!({"t": "comment-edit", "project": "P", "comment": c["comment"]["id"], "text": "Trim more"}))["comment"]["text"], "Trim more");
        // A team comment reaches the other team peer live.
        b1.ask(&mut h, &mut rx, 5, json!({"t": "viewing", "project": "P", "asset": "A"}));
        h.request("t2", &json!({"id": 6, "t": "comment-add", "project": "P", "asset": "A", "version": "V", "frame": 2, "text": "Live"}));
        assert!(to(&msgs(&mut rx), "t1").iter().any(|m| m["t"] == "comment" && m["comment"]["text"] == "Live" && m["comment"]["mine"] == true));
        // Remove the person: both sessions get bye revoked.
        let id = ready["me"]["account"].as_str().unwrap().to_owned();
        assert_eq!(h.sync(&json!({"op": "person-remove", "id": id}))["ok"], true);
        let all = msgs(&mut rx);
        for p in ["t1", "t2"] {
            assert!(to(&all, p).iter().any(|m| m["t"] == "bye" && m["code"] == "revoked"), "{p}");
            assert!(!h.peers.contains_key(p));
        }
    }

    #[tokio::test]
    async fn the_owner_sees_everything_and_a_backup_signs_in_but_changes_nothing() {
        let (mut h, mut rx) = host();
        assert_eq!(h.sync(&json!({"op": "people"}))["team"], Value::Null, "no team yet");
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let (_, k, ready) = enrol(&mut h, &mut rx, "t1", "owner");
        invite(&mut h, "client");
        // A client asks from the review link (signed in? no: link only).
        let (rb, _, w) = open(&mut h, &mut rx, "r1", "R1", &[8u8; 32], ("AA", "BB"));
        assert_eq!(w["team"]["name"], "Northwind Films", "a review link says there's a team");
        let req = rb.ask(&mut h, &mut rx, 2, json!({"t": "account-request", "name": "Dana", "email": "dana@example.com"}));
        assert!(req["request"].is_string());
        let v = h.sync(&json!({"op": "people"}));
        assert_eq!(v["people"].as_array().unwrap().len(), 2);
        assert_eq!(v["people"][0]["passkeys"][0]["label"], "Chrome on Mac");
        assert!(v["people"][0]["passkeys"][0].get("spki").is_none());
        assert_eq!(v["invites"].as_array().unwrap().len(), 1);
        assert_eq!(v["requests"][0]["name"], "Dana");
        assert!(v["team"]["link"].as_str().unwrap().starts_with("https://pluck.tools/r/#"));
        // The backup: the main's file through `_accounts`, then sign-in works and changes answer `main`.
        let file = h.sync(&json!({"op": "_accounts"}));
        let (mut b, mut brx) = host();
        b.ident.backup = true;
        assert_eq!(b.sync(&json!({"op": "_accounts-apply", "accounts": {"format": 0}}))["ok"], true, "nothing from the main: ours stays");
        assert!(!b.accounts.on());
        assert_eq!(b.sync(&json!({"op": "_accounts-apply", "accounts": file}))["ok"], true);
        assert_eq!(b.sync(&json!({"op": "_accounts"}))["error"], "scope");
        for op in ["team-set", "person-invite", "person-remove", "request-accept"] {
            assert_eq!(b.sync(&json!({"op": op, "id": "x", "name": "x", "role": "client"}))["error"]["code"], "main", "{op}");
        }
        let (_, r) = sign_in(&mut b, &mut brx, "b1", &k, ("AA", "BB"));
        assert_eq!(r["me"]["account"], ready["me"]["account"], "signed in on the backup");
        let _ = msgs(&mut brx);
        assert_eq!(b.sync(&json!({"op": "_accounts-apply", "accounts": file}))["ok"], true);
        assert!(!msgs(&mut brx).iter().any(|m| m.to_string().contains("account-changed")), "the same file again changes nothing");
        let (bb, _, _) = open_team(&mut b, &mut brx, "b2", ("AA", "BB"));
        assert_eq!(bb.ask(&mut b, &mut brx, 2, json!({"t": "account-begin", "purpose": "create", "invite": accounts::new_code()}))["error"]["code"], "main");
    }

    #[tokio::test]
    async fn review_link_sign_in_and_client_requests() {
        let (mut h, mut rx) = host();
        // 4.0.3 behaviour without accounts.json: no `team` in welcome, account ops unknown.
        let (r0, _, w) = open(&mut h, &mut rx, "r0", "R1", &[8u8; 32], ("AA", "BB"));
        assert!(w.get("team").is_none() && w.get("needAccount").is_none());
        assert_eq!(r0.ask(&mut h, &mut rx, 2, json!({"t": "account-begin", "purpose": "get"}))["error"]["code"], "invalid");
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let (_, k, ready) = enrol(&mut h, &mut rx, "t1", "editor");
        // Sign in on the review link: me with the account's name; typed names are ignored after that.
        let (rb, _, _) = open(&mut h, &mut rx, "r1", "R1", &[8u8; 32], ("AA", "BB"));
        let b = rb.ask(&mut h, &mut rx, 2, json!({"t": "account-begin", "purpose": "get"}));
        h.request("r1", &json!({"id": 3, "t": "account-get", "nonce": b["nonce"], "cred": k.get(&rb.challenge("get", &b["nonce"]), &Value::Null)}));
        let me = to(&msgs(&mut rx), "r1").into_iter().find(|m| m["t"] == "me").unwrap();
        assert_eq!((me["me"]["name"].clone(), me["me"]["account"].clone()), (json!("editor one"), ready["me"]["account"].clone()));
        rb.ask(&mut h, &mut rx, 4, json!({"t": "name", "name": "Someone else"}));
        let c = rb.ask(&mut h, &mut rx, 5, json!({"t": "comment-add", "asset": "A", "version": "V", "frame": 3, "text": "From the link"}));
        assert_eq!(c["comment"]["author"], "editor one");
        assert_eq!(rb.ask(&mut h, &mut rx, 6, json!({"t": "approve", "asset": "A", "version": "V", "decision": "approve"}))["status"], "approved",
            "on a review link the link's rights hold");
        // A client's request: pending until accepted, then a passkey, then signed in.
        let (cb, _, _) = open(&mut h, &mut rx, "r2", "R1", &[8u8; 32], ("AA", "BB"));
        let secret = cb.ask(&mut h, &mut rx, 2, json!({"t": "account-request", "name": "Dana", "email": "dana@example.com"}))["request"].clone();
        assert_eq!(cb.ask(&mut h, &mut rx, 3, json!({"t": "account-request", "name": "Dana"}))["error"]["code"], "limit", "one per peer");
        assert_eq!(cb.ask(&mut h, &mut rx, 4, json!({"t": "account-status", "request": secret}))["state"], "pending");
        assert_eq!(cb.ask(&mut h, &mut rx, 5, json!({"t": "account-begin", "purpose": "create", "request": secret}))["error"]["code"], "pending");
        assert_eq!(cb.ask(&mut h, &mut rx, 6, json!({"t": "account-begin", "purpose": "create", "invite": accounts::new_code()}))["error"]["code"], "auth",
            "invites belong to the team room");
        let rid = h.sync(&json!({"op": "people"}))["requests"][0]["id"].clone();
        assert_eq!(h.sync(&json!({"op": "request-accept", "id": rid}))["ok"], true);
        assert!(to(&msgs(&mut rx), "r2").iter().any(|m| m["t"] == "account-request-changed"));
        let b = cb.ask(&mut h, &mut rx, 7, json!({"t": "account-begin", "purpose": "create", "request": secret}));
        assert_eq!(b["user"]["name"], "Dana · Northwind Films");
        let ck = Key::new();
        h.request("r2", &json!({"id": 8, "t": "account-create", "nonce": b["nonce"], "cred": ck.create(&cb.challenge("create", &b["nonce"])), "label": "Safari on iPhone"}));
        let me = to(&msgs(&mut rx), "r2").into_iter().find(|m| m["t"] == "me").unwrap();
        assert_eq!((me["me"]["name"].clone(), me["me"]["role"].clone()), (json!("Dana"), json!("client")));
        let c = cb.ask(&mut h, &mut rx, 9, json!({"t": "comment-add", "asset": "A", "version": "V", "frame": 4, "text": "Signed in"}));
        assert_eq!(c["comment"]["author"], "Dana");
        // Declined: revoked.
        let (db, _, _) = open(&mut h, &mut rx, "r3", "R1", &[8u8; 32], ("AA", "BB"));
        let s2 = db.ask(&mut h, &mut rx, 2, json!({"t": "account-request", "name": "Eve"}))["request"].clone();
        let rid = h.sync(&json!({"op": "people"}))["requests"][0]["id"].clone();
        h.sync(&json!({"op": "request-decline", "id": rid}));
        assert_eq!(db.ask(&mut h, &mut rx, 3, json!({"t": "account-begin", "purpose": "create", "request": s2}))["error"]["code"], "revoked");
    }

    #[tokio::test]
    async fn rate_limits_and_wrong_codes_close_the_peer() {
        let (mut h, mut rx) = host();
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let (br, _, _) = open_team(&mut h, &mut rx, "t1", ("AA", "BB"));
        for i in 0..10 {
            assert!(br.ask(&mut h, &mut rx, 10 + i, json!({"t": "account-begin", "purpose": "get"}))["nonce"].is_string());
        }
        assert_eq!(br.ask(&mut h, &mut rx, 30, json!({"t": "account-begin", "purpose": "get"}))["error"]["code"], "limit");
        let (b2, _, _) = open_team(&mut h, &mut rx, "t2", ("AA", "BB"));
        for i in 0..4 {
            assert_eq!(b2.ask(&mut h, &mut rx, 10 + i, json!({"t": "account-begin", "purpose": "create", "invite": accounts::new_code()}))["error"]["code"], "auth");
        }
        h.request("t2", &json!({"id": 20, "t": "account-begin", "purpose": "create", "invite": accounts::new_code()}));
        tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
        assert!(msgs(&mut rx).iter().any(|c| c["close"]["peer"] == "t2"), "five wrong codes close the peer");
        // A resume key brings a reconnecting page back without a prompt, on its new session only.
        let (_, k, ready) = enrol(&mut h, &mut rx, "t3", "editor");
        let _ = k;
        let resume = keys::unb64(ready["resume"].as_str().unwrap()).unwrap();
        let (b4, _, _) = open_team(&mut h, &mut rx, "t4", ("GG", "HH"));
        use hmac::Mac;
        let mut m = hmac::Hmac::<sha2::Sha256>::new_from_slice(&resume).unwrap();
        for p in [b"pluck-account/1 resume\n".as_slice(), &b4.mac_nonce, b"GG", b"\n", b"HH"] {
            m.update(p);
        }
        let proof = keys::b64(&m.finalize().into_bytes());
        assert_eq!(b4.ask(&mut h, &mut rx, 2, json!({"t": "account-resume", "proof": proof}))["t"], "ready");
    }
}

#[cfg(test)]
mod upload_tests {
    use std::sync::Arc;

    use serde_json::{Value, json};
    use sha2::Digest;
    use tokio::sync::mpsc;

    use super::super::{Host, uuid};
    use crate::{Ev, accounts::tests::Key, keys, roots::Roots, upload_root::UploadRoot};

    struct T {
        h: Host,
        rx: mpsc::UnboundedReceiver<Ev>,
        back: mpsc::UnboundedReceiver<(String, Value)>,
        root: std::path::PathBuf,
        media: std::path::PathBuf,
    }

    fn cmds(rx: &mut mpsc::UnboundedReceiver<Ev>) -> Vec<Value> {
        std::iter::from_fn(|| rx.try_recv().ok()).filter_map(|e| if let Ev::Cmd(v) = e { Some(v) } else { None }).collect()
    }

    fn reply(all: &[Value], peer: &str, re: u64) -> Value {
        all.iter().find(|c| c["send"]["peer"] == peer && c["send"]["msg"]["re"] == re).map_or(Value::Null, |c| c["send"]["msg"].clone())
    }

    /// A host with media and uploads roots, a team and a signed-in editor on peer `e1` (footage as given).
    fn setup(footage: bool, with_root: bool) -> T {
        let base = std::env::temp_dir().join(format!("pluck-acct-up-{}", uuid()));
        let (root, media) = (base.join("renders"), base.join("media"));
        for d in [&root, &media.join("Day 1")] {
            std::fs::create_dir_all(d).unwrap();
        }
        std::fs::write(media.join("Day 1/A001.mov"), vec![7u8; 1000]).unwrap();
        let mut roots = Roots::parse(&[format!("media={}", media.display())]);
        let u = UploadRoot::parse(&format!("renders={}", root.display()), &["media".into()], Arc::default()).map(Arc::new);
        if with_root {
            roots.add_uploads(u.as_ref().unwrap());
        }
        let (tx, mut rx) = mpsc::unbounded_channel();
        let mut h = Host::new(&base.join("data"), Arc::new(roots), tx, None);
        let (btx, back) = mpsc::unbounded_channel();
        h.back = Some(btx);
        h.upload_root = u.filter(|_| with_root);
        h.sync(&json!({"op": "team-set", "name": "Northwind Films"}));
        let link = h.sync(&json!({"op": "person-invite", "name": "Ed", "role": "editor", "footage": footage}))["link"].as_str().unwrap().to_owned();
        let code = link.rsplit('/').next().unwrap().to_owned();
        let room = h.accounts.room().unwrap().clone();
        h.report(&json!({"peer": {"peer": "e1", "state": "open", "room": room["roomID"], "fpLocal": "AA", "fpRemote": "BB"}}));
        let all = cmds(&mut rx);
        let hello = all.iter().find(|c| c["send"]["peer"] == "e1").unwrap()["send"]["msg"].clone();
        let mn = keys::unb64(hello["nonce"].as_str().unwrap()).unwrap();
        let auth = keys::unb64(room["auth"].as_str().unwrap()).unwrap();
        h.request("e1", &json!({"id": 1, "t": "auth", "v": 2, "nonce": keys::b64(&[2u8; 32]), "proof": keys::proof(&auth, "browser", &mn, &[2u8; 32], "AA", "BB"), "token": keys::b64(&[5u8; 32])}));
        h.request("e1", &json!({"id": 2, "t": "account-begin", "purpose": "create", "invite": code}));
        let b = reply(&cmds(&mut rx), "e1", 2);
        let ch = crate::accounts::challenge("create", &keys::unb64(b["nonce"].as_str().unwrap()).unwrap(), &mn, "AA", "BB");
        h.request("e1", &json!({"id": 3, "t": "account-create", "nonce": b["nonce"], "cred": Key::new().create(&ch), "label": "Chrome on Android"}));
        let ready = reply(&cmds(&mut rx), "e1", 3);
        assert_eq!((ready["t"].clone(), ready["uploads"].clone()), (json!("ready"), json!(with_root)), "{ready}");
        T { h, rx, back, root, media }
    }

    impl T {
        fn ask(&mut self, peer: &str, id: u64, mut m: Value) -> Value {
            m["id"] = json!(id);
            self.h.request(peer, &m);
            reply(&cmds(&mut self.rx), peer, id)
        }

        /// Run the background hash (UploadRoot::end) and hand its result to the host, as run() does.
        async fn settle(&mut self, peer: &str, id: u64) -> Value {
            let (k, v) = tokio::time::timeout(std::time::Duration::from_secs(5), self.back.recv()).await.unwrap().unwrap();
            self.h.copy_progress(k, v);
            reply(&cmds(&mut self.rx), peer, id)
        }

        /// The peer `e1` moved to `peer`: the same session keys (the test signs nothing again).
        fn reconnect(&mut self, peer: &str) {
            let mut p = self.h.drop_peer("e1").unwrap();
            p.fetches.clear();
            self.h.peers.insert(peer.into(), p);
        }
    }

    fn sha_hex(b: &[u8]) -> String {
        sha2::Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
    }

    #[tokio::test]
    async fn uploads_resume_on_a_new_session_and_never_overwrite() {
        let mut t = setup(false, true);
        let body: Vec<u8> = (0..100u8).collect();
        let begin = json!({"t": "root-upload-begin", "path": "renders/Phone", "name": "Clip.mov", "size": 100, "mtime": 1_800_000_000});
        assert_eq!(t.ask("e1", 9, json!({"t": "mkdir", "path": "renders/Phone"}))["ok"], true);
        t.h.request("e1", &{ let mut b = begin.clone(); b["id"] = json!(10); b });
        let all = cmds(&mut t.rx);
        let acc = all.iter().find(|c| c.get("accept").is_some()).unwrap()["accept"].clone();
        assert_eq!((acc["offset"].clone(), acc["size"].clone(), reply(&all, "e1", 10)["have"].clone()), (json!(0), json!(100), json!(0)));
        // 40% arrives, then the phone sleeps: the helper reports a failed upload, the peer goes.
        std::fs::write(acc["path"].as_str().unwrap(), &body[..40]).unwrap();
        t.h.report(&json!({"upload": {"peer": "e1", "upload": 10, "state": "failed", "bytes": 40}}));
        t.reconnect("e2");
        t.h.request("e2", &{ let mut b = begin.clone(); b["id"] = json!(11); b });
        let all = cmds(&mut t.rx);
        let acc2 = all.iter().find(|c| c.get("accept").is_some()).unwrap()["accept"].clone();
        assert_eq!((acc2["path"].clone(), acc2["offset"].clone(), acc2["size"].clone()), (acc["path"].clone(), json!(40), json!(60)), "the same partial, at 40%");
        assert_eq!(reply(&all, "e2", 11)["have"], 40);
        let mut f = std::fs::OpenOptions::new().append(true).open(acc["path"].as_str().unwrap()).unwrap();
        std::io::Write::write_all(&mut f, &body[40..]).unwrap();
        t.h.report(&json!({"upload": {"peer": "e2", "upload": 11, "state": "done", "bytes": 60, "sha256": "x"}}));
        t.h.request("e2", &json!({"id": 12, "t": "root-upload-end", "upload": 11, "sha256": keys::b64(&sha2::Sha256::digest(&body))}));
        let r = t.settle("e2", 12).await;
        assert_eq!(r["uploaded"]["path"], "renders/Phone/Clip.mov", "{r}");
        assert_eq!(std::fs::read(t.root.join("Phone/Clip.mov")).unwrap(), body);
        assert!(t.h.entries.iter().any(|e| e["upload"]["for"] == "root" && e["upload"]["by"] == "Ed"));
        assert!(t.h.entries.iter().any(|e| e["activity"]["kind"] == "uploaded" && e["activity"]["link"] == "team"));
        assert!(t.ask("e2", 13, json!({"t": "uploads"}))["uploads"][0]["for"] == "root");
        // The same name again: " 2", never over the first. A wrong hash: checksum, nothing placed.
        for (id, sha, size) in [(20, sha_hex(b"abc"), 3), (30, sha_hex(b"zzz"), 3)] {
            t.h.request("e2", &json!({"id": id, "t": "root-upload-begin", "path": "renders/Phone", "name": "Clip.mov", "size": size, "mtime": id}));
            let acc = cmds(&mut t.rx).iter().find(|c| c.get("accept").is_some()).unwrap()["accept"].clone();
            std::fs::write(acc["path"].as_str().unwrap(), b"abc").unwrap();
            t.h.report(&json!({"upload": {"peer": "e2", "upload": id, "state": "done", "bytes": 3, "sha256": "x"}}));
            t.h.request("e2", &json!({"id": id + 1, "t": "root-upload-end", "upload": id, "sha256": sha}));
            let r = t.settle("e2", id + 1).await;
            if id == 20 {
                assert_eq!(r["uploaded"]["path"], "renders/Phone/Clip 2.mov");
            } else {
                assert_eq!(r["error"]["code"], "checksum");
            }
        }
        assert!(!t.root.join("Phone/Clip 3.mov").exists());
        assert_eq!(std::fs::read(t.root.join("Phone/Clip.mov")).unwrap(), body, "the first is untouched");
        // Escapes: refused before anything is made.
        std::os::unix::fs::symlink(&t.media, t.root.join("out")).unwrap();
        for (i, (path, name)) in [("renders/../media", "x.mov"), ("renders/out", "x.mov"), ("renders", "../x.mov"), ("renders", ".hidden"), ("media", "x.mov"), ("/etc", "x")]
            .into_iter().enumerate() {
            let r = t.ask("e2", 40 + i as u64, json!({"t": "root-upload-begin", "path": path, "name": name, "size": 1, "mtime": 1}));
            assert_eq!(r["error"]["code"], "invalid", "{path} {name}: {r}");
        }
        assert_eq!(t.ask("e2", 50, json!({"t": "mkdir", "path": "media/x"}))["error"]["code"], "invalid");
        assert!(t.ask("e2", 51, json!({"t": "root-list", "path": "renders/Phone"}))["entries"].as_array().unwrap().len() >= 2);
        // Fix L5: the same upload going on another session is refused (never two writers on one partial) ...
        let b = json!({"t": "root-upload-begin", "path": "renders", "name": "Twice.mov", "size": 10, "mtime": 5});
        assert_eq!(t.ask("e2", 60, b.clone())["have"], 0);
        assert_eq!(t.ask("e2", 61, b)["error"]["code"], "limit");
        // ... and browsers' uploads have slots of their own: four Mac uploads don't block them.
        let u = t.h.upload_root.clone().unwrap();
        for i in 0..2 {
            for d in ["mac1", "mac2"] {
                let r = u.begin(&json!({"path": format!("renders/{d}-{i}.mov"), "size": 1, "sha256": "a".repeat(64)}), d);
                assert!(r["upload"].is_string(), "{r}");
            }
        }
        assert_eq!(u.begin(&json!({"path": "renders/mac3.mov", "size": 1, "sha256": "b".repeat(64)}), "mac3")["error"], "limit");
        assert_eq!(t.ask("e2", 62, json!({"t": "root-upload-begin", "path": "renders", "name": "Own.mov", "size": 10, "mtime": 6}))["have"], 0);
        // mkdir is rate-limited (fix L7).
        let limited = (0..40).map(|i| t.ask("e2", 100 + i, json!({"t": "mkdir", "path": format!("renders/d{i}")}))).filter(|r| r["error"]["code"] == "limit").count();
        assert!(limited >= 9, "{limited}");
    }

    #[tokio::test]
    async fn no_uploads_root_or_a_backup_means_scope_and_footage_needs_its_right() {
        let mut t = setup(false, false);
        assert_eq!(t.ask("e1", 9, json!({"t": "root-upload-begin", "path": "renders", "name": "a.mov", "size": 1}))["error"]["code"], "scope");
        assert_eq!(t.ask("e1", 10, json!({"t": "footage-roots"}))["error"]["code"], "scope", "footage is off by default");
        assert_eq!(t.ask("e1", 11, json!({"t": "fetch", "what": "footage", "path": "media/Day 1/A001.mov"}))["error"]["code"], "scope");
        let mut t = setup(true, true);
        assert_eq!(t.ask("e1", 9, json!({"t": "footage-roots"}))["roots"], json!(["media", "renders"]));
        let b = t.ask("e1", 10, json!({"t": "footage-browse", "path": "media/Day 1"}));
        assert_eq!(b["entries"][0]["name"], "A001.mov");
        for (i, bad) in ["media/../data", "/etc", ".uploads/L1/x.mov", "media/Day 1/../../data"].iter().enumerate() {
            let r = t.ask("e1", 20 + i as u64, json!({"t": "fetch", "what": "footage", "path": bad, "offset": 0, "length": 10}));
            assert_eq!(r["error"]["code"], "invalid", "{bad}");
        }
        t.h.request("e1", &json!({"id": 30, "t": "fetch", "what": "footage", "path": "media/Day 1/A001.mov", "offset": 100, "length": 50}));
        let all = cmds(&mut t.rx);
        assert_eq!(reply(&all, "e1", 30)["size"], 50);
        let serve = all.iter().find(|c| c.get("serve").is_some()).unwrap()["serve"].clone();
        assert_eq!((serve["pieces"][0]["offset"].clone(), serve["pieces"][0]["length"].clone()), (json!(100), json!(50)));
        assert!(t.h.entries.iter().any(|e| e["activity"]["kind"] == "footage" && e["activity"]["name"] == "Ed"), "logged with the account name");
        std::fs::write(t.media.join("Day 1/Big.mov"), vec![0u8; 20 << 20]).unwrap();
        assert_eq!(t.ask("e1", 31, json!({"t": "fetch", "what": "footage", "path": "media/Day 1/Big.mov"}))["error"]["code"], "scope", "a whole file needs the download right");
        // Fix M4: ranges in a row add up per file and session; past the preview budget they're refused too.
        assert_eq!(t.ask("e1", 40, json!({"t": "fetch", "what": "footage", "path": "media/Day 1/Big.mov", "offset": 0, "length": 8 << 20}))["size"], 8 << 20);
        assert_eq!(t.ask("e1", 40, json!({"t": "fetch", "what": "footage", "path": "media/Day 1/Big.mov", "offset": 0, "length": 10}))["error"]["code"], "invalid",
            "a fetch id still in flight (fix L6)");
        t.h.report(&json!({"served": {"peer": "e1", "fetch": 40, "result": "done"}}));
        assert_eq!(t.ask("e1", 41, json!({"t": "fetch", "what": "footage", "path": "media/Day 1/Big.mov", "offset": 8 << 20, "length": 8 << 20}))["error"]["code"], "scope");
        let me = t.ask("e1", 32, json!({"t": "me"}))["me"]["account"].clone();
        t.h.sync(&json!({"op": "person-update", "id": me, "footageDownload": true}));
        assert_eq!(t.ask("e1", 33, json!({"t": "fetch", "what": "footage", "path": "media/Day 1/Big.mov"}))["size"], 20 << 20);
        t.h.sync(&json!({"op": "person-update", "id": me, "footage": false}));
        assert_eq!(t.ask("e1", 34, json!({"t": "footage-roots"}))["error"]["code"], "scope", "switched off: the next request knows");
        // A backup never has an uploads root (main.rs gives it none): team uploads there are `scope`.
        t.h.ident.backup = true;
        t.h.upload_root = None;
        assert_eq!(t.ask("e1", 35, json!({"t": "root-upload-begin", "path": "renders", "name": "a.mov", "size": 1}))["error"]["code"], "scope");
    }
}
