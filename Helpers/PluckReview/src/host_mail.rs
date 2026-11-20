// The host's side of email, @mentions and the webhook (plan 2026-11-20-deliver-notifications-mentions.md, contract in
// the 4.1.0 notes): who can be mentioned, who hears about what, the queue's tick, and the Mac's mail ops. A child module
// of host.rs (as host_accounts.rs), so it works on Host's own fields. Only a main sends: a backup's comments reach the
// main through the replica push, and the main queues them there (no double sends after a takeover).
use std::collections::HashSet;

use serde_json::{Value, json};

use super::{Host, clean, is, now_secs, team, uuid};
use crate::{accounts, log, mail::{self, Mail, mention_id, valid_email}};

const MAX_MENTIONS: usize = 10;
const MAX_MENTIONABLE: usize = 200;
const MAX_ROWS_PER_LINK: usize = 200;
const OLD_SECS: i64 = 86_400; // a comment older than this arriving by sync is history, not news

impl Host {
    /// Mail is set up here and this host sends (a main).
    pub(super) fn mail_on(&self) -> bool {
        !self.ident.backup && self.mail.on()
    }

    /// May a browser on this link ask for mail? The team room: when there's a team link. A link: with "Email updates".
    pub(super) fn mail_link_ok(&self, l: &Value) -> bool {
        self.mail_on() && if l["id"] == "team" { self.accounts.team_link().is_some() } else { Self::mail_code(l).is_some() }
    }

    fn mail_code(l: &Value) -> Option<&str> {
        l["notify"]["mailCode"].as_str().filter(|c| l["notify"]["email"] == true && !c.is_empty() && c.len() < 300 && !c.contains(char::is_whitespace))
    }

    fn team_id(&self) -> String {
        self.accounts.v["team"]["id"].as_str().unwrap_or("").to_owned()
    }

    /// Owners and editors with a name (clients never see each other's names).
    fn mail_team(&self) -> impl Iterator<Item = &Value> {
        self.accounts.v["people"].as_array().into_iter().flatten()
            .filter(|p| (p["role"] == "owner" || p["role"] == "editor") && p["name"].as_str().is_some_and(|n| !n.trim().is_empty()))
    }

    /// `mentionable`: the team's people, then the authors of what this link can see.
    pub(super) fn mentionable(&self, l: &Value) -> Vec<Value> {
        let mut out = vec![];
        let mut seen = HashSet::new();
        let tid = self.team_id();
        let mut team_toks = HashSet::new();
        if self.accounts.on() {
            for p in self.mail_team() {
                let id = p["id"].as_str().unwrap_or("").to_owned();
                team_toks.insert(accounts::account_token(&tid, &id));
                if seen.insert(id.clone()) {
                    out.push(json!({"id": id, "name": clean(p["name"].as_str().unwrap_or(""), 40)}));
                }
            }
        }
        let show_internal = team(l);
        for c in self.comments.iter().filter(|c| Self::visible(l, c) && self.asset_in_scope(l, c["asset"].as_str().unwrap_or("")).is_some()) {
            let rs = c["replies"].as_array().into_iter().flatten().filter(|r| show_internal || !is(r, "internal"));
            for x in std::iter::once(c).chain(rs) {
                let (Some(tok), Some(name)) = (x["authorToken"].as_str(), x["author"].as_str()) else { continue };
                if team_toks.contains(tok) || name.trim().is_empty() {
                    continue;
                }
                let id = mention_id(tok);
                if seen.insert(id.clone()) {
                    out.push(json!({"id": id, "name": name}));
                }
            }
        }
        out.truncate(MAX_MENTIONABLE);
        out
    }

    /// A write's `mentions`: strings this link may mention, at most 10, each once.
    pub(super) fn mention_ids(&self, l: &Value, m: &Value) -> Vec<String> {
        let Some(asked) = m["mentions"].as_array().filter(|a| !a.is_empty()) else { return vec![] };
        let ok: HashSet<String> = self.mentionable(l).into_iter().filter_map(|p| p["id"].as_str().map(str::to_owned)).collect();
        let mut out: Vec<String> = vec![];
        for id in asked.iter().filter_map(Value::as_str) {
            if ok.contains(id) && !out.iter().any(|x| x == id) && out.len() < MAX_MENTIONS {
                out.push(id.to_owned());
            }
        }
        out
    }

    // ---- subscribers ----

    /// Team rows follow accounts.json (owners and editors with an email); a personal link's recipientEmail is a client row.
    fn sync_rows(&mut self) {
        let mut changed = false;
        let people: Vec<(String, String, String)> = if self.accounts.on() {
            self.accounts.v["people"].as_array().into_iter().flatten()
                .filter(|p| p["role"] == "owner" || p["role"] == "editor")
                .filter_map(|p| Some((p["id"].as_str()?.to_owned(), p["email"].as_str().filter(|e| valid_email(e))?.trim().to_owned(), p["name"].as_str().unwrap_or("").to_owned())))
                .collect()
        } else { vec![] };
        let before = self.mail.subs.len();
        self.mail.subs.retain(|r| r["kind"] != "team" || r["person"].is_null() || people.iter().any(|(id, ..)| r["person"] == id.as_str()));
        changed |= before != self.mail.subs.len();
        for (id, email, name) in people {
            match self.mail.subs.iter_mut().find(|r| r["kind"] == "team" && r["person"] == id.as_str()) {
                Some(r) => {
                    if r["email"] != email.as_str() || r["name"] != name.as_str() {
                        (r["email"], r["name"]) = (json!(email), json!(name));
                        changed = true;
                    }
                }
                None => {
                    let mut r = Mail::new_row("team");
                    (r["person"], r["email"], r["name"]) = (json!(id), json!(email), json!(name));
                    self.mail.subs.push(r);
                    changed = true;
                }
            }
        }
        let recipients: Vec<(Value, String, Value)> = self.links().filter(|l| Self::mail_code(l).is_some())
            .filter_map(|l| Some((l["id"].clone(), l["notify"]["recipientEmail"].as_str().filter(|e| valid_email(e))?.trim().to_owned(), l["recipient"].clone()))).collect();
        for (link, email, name) in recipients {
            if !self.mail.subs.iter().any(|r| r["kind"] == "client" && r["link"] == link && r["author"].is_null() && r["email"] == email.as_str()) {
                let mut r = Mail::new_row("client");
                (r["link"], r["email"], r["name"]) = (link, json!(email), name);
                self.mail.subs.push(r);
                changed = true;
            }
        }
        if changed {
            self.mail.save_subs();
        }
    }

    /// The row a peer's subscribe works on (created when `email` is given).
    fn peer_row(&mut self, peer: &str, l: &Value, email: Option<String>) -> Option<usize> {
        let p = &self.peers[peer];
        let person = p.acct.person.clone().filter(|id| matches!(self.accounts.role(id), Some("owner" | "editor")));
        if let Some(id) = person {
            self.sync_rows();
            return self.mail.subs.iter().position(|r| r["kind"] == "team" && r["person"] == id.as_str());
        }
        let tok = p.acct.token.clone().or(p.token.clone())?;
        let name = p.name.clone();
        if let Some(i) = self.mail.subs.iter().position(|r| r["kind"] == "client" && r["link"] == l["id"] && r["author"] == tok.as_str()) {
            if let Some(e) = email {
                self.mail.subs[i]["email"] = json!(e);
            }
            return Some(i);
        }
        // A cap per link: new browsers can't keep adding rows (each one an address this host would write to).
        if self.mail.subs.iter().filter(|r| r["link"] == l["id"]).count() >= MAX_ROWS_PER_LINK {
            return None;
        }
        let mut r = Mail::new_row("client");
        (r["link"], r["author"], r["email"], r["name"]) = (l["id"].clone(), json!(tok), json!(email?), json!(name));
        self.mail.subs.push(r);
        Some(self.mail.subs.len() - 1)
    }

    /// `subscribe` and `subscription` (browser ctl).
    pub(super) fn subscribe(&mut self, peer: &str, l: &Value, m: &Value, t: &str) -> Result<Value, &'static str> {
        if !self.mail_link_ok(l) {
            return Err("off");
        }
        if t == "subscription" {
            let i = self.peer_row(peer, l, None);
            return Ok(match i.map(|i| &self.mail.subs[i]) {
                // A team person's row (4.1.0): its muted links and the live links it could mute (team pages only).
                // `delta`: this host merges one link's `muteLink`/`muted` (a page's toggle then can't undo a Mac's mute).
                Some(r) if r["kind"] == "team" => json!({"mode": r["mode"], "email": r["email"], "mute": r["mute"].as_array().cloned().unwrap_or_default(), "delta": true,
                    "links": self.links().filter(|l| self.live(l).is_ok()).map(|l| json!({"id": l["id"], "title": l["title"], "project": l["project"]})).collect::<Vec<_>>()}),
                Some(r) => json!({"mode": r["mode"], "email": r["email"]}),
                None => json!({"mode": null, "email": null}),
            });
        }
        let mode = m["mode"].as_str().filter(|x| mail::MODES.contains(x)).ok_or("invalid")?;
        let signed = self.peers[peer].acct.person.is_some();
        let email = match m["email"].as_str() {
            Some(e) if valid_email(e) => Some(e.trim().to_owned()),
            Some(_) => return Err("invalid"),
            None if signed => self.peers[peer].acct.person.as_deref().and_then(|id| self.accounts.person(id))
                .and_then(|p| p["email"].as_str()).filter(|e| valid_email(e)).map(|e| e.trim().to_owned()),
            None => return Err("invalid"),
        };
        let i = self.peer_row(peer, l, email).ok_or("invalid")?;
        let r = &mut self.mail.subs[i];
        r["mode"] = json!(mode);
        if let (true, Some(l)) = (r["kind"] == "team", m["muteLink"].as_str().filter(|l| !l.is_empty() && l.len() < 100)) {
            // One link's change merged in, as subscriber_set does; `mute` beside it is for hosts older than this.
            let mut list: Vec<Value> = r["mute"].as_array().into_iter().flatten().filter(|x| x.as_str() != Some(l)).cloned().collect();
            if m["muted"] == true {
                list.push(json!(l));
            }
            list.truncate(500);
            r["mute"] = json!(list);
        } else if let (true, Some(m)) = (r["kind"] == "team", m["mute"].as_array()) {
            r["mute"] = json!(m.iter().filter(|x| x.as_str().is_some_and(|x| x.len() < 100)).take(500).cloned().collect::<Vec<_>>());
        }
        if let Some(lang) = m["lang"].as_str() {
            r["lang"] = json!(mail::lang(lang));
        }
        if !self.mail.save_subs() {
            return Err("internal");
        }
        Ok(json!({"ok": true}))
    }

    /// `unsubscribe` by the token in a mail: a client row goes off (this link), a team row goes off (everything).
    pub(super) fn unsubscribe(&mut self, token: &str) -> Value {
        let Some(r) = self.mail.subs.iter_mut().find(|r| !token.is_empty() && r["token"] == token) else { return json!({"ok": true, "scope": "link"}) };
        r["mode"] = json!("off");
        let scope = if r["kind"] == "team" { "all" } else { "link" };
        self.mail.save_subs();
        json!({"ok": true, "scope": scope})
    }

    // ---- events ----

    fn rows(&self) -> Vec<Value> {
        self.mail.subs.iter().filter(|r| r["mode"] != "off").cloned().collect()
    }

    fn item(to: &Value, event: &str, link: &Value, asset: &Value, version: &Value, comment: &Value, reply: &Value) -> Value {
        json!({"id": uuid(), "to": to["id"], "event": event, "link": link, "asset": asset, "version": version, "comment": comment,
            "reply": reply, "at": now_secs()})
    }

    /// A comment written here or pushed by sync: `before` is the comment as it was (None: new). Queues comment, reply
    /// and mention mails, and posts the webhook. Internal ones never reach a client row.
    pub(super) fn mail_comment(&mut self, before: Option<&Value>, c: &Value) {
        if self.ident.backup {
            return;
        }
        let created = |x: &Value| x["created"].as_str().and_then(super::norm_iso).map_or(true, |d| d >= super::iso(now_secs() - OLD_SECS));
        // (id of the reply or Null, author token, internal, mentions, author name, text)
        let mut events: Vec<(Value, Option<String>, bool, Vec<String>, String, String)> = vec![];
        let ments = |x: &Value| x["mentions"].as_array().into_iter().flatten().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>();
        let tok = |x: &Value| x["authorToken"].as_str().map(str::to_owned);
        let s = |x: &Value, k: &str| x[k].as_str().unwrap_or("").to_owned();
        match before {
            None if created(c) => events.push((Value::Null, tok(c), is(c, "internal"), ments(c), s(c, "author"), s(c, "text"))),
            None => {}
            Some(b) => {
                let old: Vec<&Value> = b["replies"].as_array().into_iter().flatten().map(|r| &r["id"]).collect();
                for r in c["replies"].as_array().into_iter().flatten().filter(|r| !old.contains(&&r["id"]) && created(r)) {
                    events.push((r["id"].clone(), tok(r), is(c, "internal") || is(r, "internal"), ments(r), s(r, "author"), s(r, "text")));
                }
            }
        }
        if events.is_empty() {
            return;
        }
        for (reply, _, internal, _, author, text) in &events {
            self.post_hook(if reply.is_null() { "comment" } else { "reply" }, c, *internal, author, text);
        }
        if !self.mail_on() {
            return;
        }
        self.sync_rows();
        let tid = self.team_id();
        let thread: Vec<String> = std::iter::once(c).chain(c["replies"].as_array().into_iter().flatten())
            .filter(|x| !is(x, "internal")).filter_map(|x| x["authorToken"].as_str().map(str::to_owned)).collect();
        let mut items = vec![];
        for (reply, author, internal, mentions, ..) in &events {
            for r in self.rows() {
                if r["mute"].as_array().is_some_and(|m| m.contains(&c["link"])) {
                    continue;
                }
                let client = r["kind"] == "client";
                if client && *internal {
                    continue; // never to a client: not the text, not that it exists
                }
                let me = if client { r["author"].as_str().map(str::to_owned) } else { r["person"].as_str().map(|p| accounts::account_token(&tid, p)) };
                let (link_row, personal) = (client && r["link"] == c["link"], client && r["author"].is_null());
                if author.is_some() && author == &me || personal && link_row && author.is_some() && !thread_by_team(&tid, author, &self.accounts.v) {
                    continue; // their own (a personal link's recipient wrote everything on it that the team didn't)
                }
                let mentioned = if client { me.as_deref().is_some_and(|t| mentions.contains(&mention_id(t))) } else { r["person"].as_str().is_some_and(|p| mentions.iter().any(|m| m == p)) };
                let ev = if mentioned {
                    "mention"
                } else if !client {
                    if reply.is_null() { "comment" } else { "reply" }
                } else if !reply.is_null() && link_row && (personal || me.as_ref().is_some_and(|t| thread.contains(t))) {
                    "reply"
                } else {
                    continue;
                };
                items.push(Self::item(&r, ev, &c["link"], &c["asset"], &c["version"], &c["id"], reply));
            }
        }
        self.mail.push(items);
    }

    /// An approval or "needs changes": the team hears.
    pub(super) fn mail_approval(&mut self, a: &Value) {
        if self.ident.backup {
            return;
        }
        let ev = if a["decision"] == "approve" { "approval" } else { "changes" };
        self.post_hook(ev, a, false, a["author"].as_str().unwrap_or(""), "");
        if !self.mail_on() || a["created"].as_str().and_then(super::norm_iso).is_some_and(|d| d < super::iso(now_secs() - OLD_SECS)) {
            return;
        }
        self.sync_rows();
        let items = self.rows().iter().filter(|r| r["kind"] == "team" && !r["mute"].as_array().is_some_and(|m| m.contains(&a["link"])))
            .map(|r| { let mut q = Self::item(r, ev, &a["link"], &a["asset"], &a["version"], &Value::Null, &Value::Null); q["approval"] = a["id"].clone(); q }).collect();
        self.mail.push(items);
    }

    /// A new version is ready: client rows whose link holds the asset hear.
    pub(super) fn mail_version(&mut self, asset: &str, version: &str) {
        if !self.mail_on() {
            return;
        }
        self.sync_rows();
        let mut items = vec![];
        for r in self.rows().iter().filter(|r| r["kind"] == "client") {
            let Some(l) = self.links().find(|l| l["id"] == r["link"]) else { continue };
            if self.live(l).is_ok() && Self::mail_code(l).is_some() && self.asset_in_scope(l, asset).is_some() {
                let mut q = Self::item(r, "version", &l["id"], &json!(asset), &json!(version), &Value::Null, &Value::Null);
                q["id"] = json!(format!("v:{version}:{}", r["id"].as_str().unwrap_or(""))); // once per version and person
                items.push(q);
            }
        }
        self.mail.push(items);
    }

    /// Every 30 s: deadline reminders 24 h ahead, then what's due goes out (one SMTP session in the background).
    pub(super) fn mail_tick(&mut self) {
        if !self.mail_on() {
            return;
        }
        let now = now_secs();
        let (from, to) = (super::iso(now), super::iso(now + 86_400));
        let soon: Vec<(Value, String)> = self.links().filter(|l| Self::mail_code(l).is_some() && self.live(l).is_ok())
            .filter_map(|l| Some((l["id"].clone(), self.deadline(l).filter(|d| *d > from && *d <= to)?))).collect();
        if !soon.is_empty() {
            self.sync_rows();
            let items: Vec<Value> = soon.iter().flat_map(|(lid, d)| self.rows().into_iter().filter(move |r| r["kind"] == "client" && r["link"] == *lid)
                .map(move |r| { let mut q = Self::item(&r, "deadline", lid, &Value::Null, &Value::Null, &Value::Null, &Value::Null); q["id"] = json!(format!("d:{}:{d}:{}", lid.as_str().unwrap_or(""), r["id"].as_str().unwrap_or(""))); q }))
                .collect();
            self.mail.push(items);
        }
        if self.mail.sending || now < self.mail.retry_at {
            return;
        }
        let mut batches = vec![]; // (queue ids, message)
        for (row, items) in self.mail.due(now) {
            let ids: Vec<String> = items.iter().filter_map(|q| q["id"].as_str().map(str::to_owned)).collect();
            match self.compose(&row, &items) {
                Some(msg) => batches.push((ids, msg)),
                None => self.mail.done(&ids), // nothing left to say (deleted, internal now, link gone)
            }
        }
        let (Some(back), Some(pw), false) = (self.back.clone(), self.mail.password(), batches.is_empty()) else { return };
        self.mail.sending = true;
        let cfg = self.mail.cfg.clone();
        tokio::spawn(async move {
            for (ids, msg) in batches {
                let r = mail::send(&cfg, &pw, std::slice::from_ref(&msg), None).await;
                // A refused address (5xx on RCPT/DATA) is that batch's alone: the next ones still go.
                let stop = r.as_ref().is_err_and(|e| e.code != "rejected");
                let _ = back.send(("mail:sent".into(), json!({"ids": ids, "error": r.err().map(|e| json!({"code": e.code, "detail": e.detail}))})));
                if stop {
                    break; // the rest stays queued for the retry
                }
            }
            let _ = back.send(("mail:done".into(), Value::Null));
        });
    }

    /// A background send's result (copy_progress "mail:…").
    pub(super) fn mail_back(&mut self, k: &str, v: Value) {
        match k {
            "sent" => match v["error"].as_object() {
                None => {
                    let ids: Vec<String> = v["ids"].as_array().into_iter().flatten().filter_map(|x| x.as_str().map(str::to_owned)).collect();
                    self.mail.done(&ids);
                    self.mail.count_sent(1);
                    self.mail.backoff = 0;
                    if !self.mail.cfg["lastError"].is_null() {
                        self.mail.cfg["lastError"] = Value::Null;
                        self.mail.save_cfg();
                    }
                }
                Some(e) if e["code"] == "rejected" => {
                    // This batch's address was refused: it goes (sending it again won't help), the others don't wait.
                    let ids: Vec<String> = v["ids"].as_array().into_iter().flatten().filter_map(|x| x.as_str().map(str::to_owned)).collect();
                    self.mail.done(&ids);
                    self.mail.cfg["lastError"] = json!({"code": e["code"], "detail": e["detail"], "at": super::now_iso()});
                    self.mail.save_cfg();
                    log(format!("host: mail refused, {} dropped: {}", ids.len(), e["detail"]));
                }
                Some(e) => {
                    self.mail.backoff = (self.mail.backoff * 2).clamp(60, 3600);
                    self.mail.retry_at = now_secs() + self.mail.backoff;
                    self.mail.cfg["lastError"] = json!({"code": e["code"], "detail": e["detail"], "at": super::now_iso()});
                    self.mail.save_cfg();
                    log(format!("host: mail not sent ({}): {}; again in {} s", e["code"], e["detail"], self.mail.backoff));
                }
            },
            _ => self.mail.sending = false,
        }
    }

    /// The link a recipient opens, and the stop link.
    fn urls(&self, row: &Value, link: Option<&Value>) -> Option<(String, String)> {
        let base = if row["kind"] == "team" {
            self.accounts.team_link().or_else(|| Some(format!("{}/r/#{}", self.accounts.origin, Self::mail_code(link?)?)))?
        } else {
            format!("{}/r/#{}", self.accounts.origin, Self::mail_code(self.links().find(|l| l["id"] == row["link"])?)?)
        };
        let stop = format!("{base}/u/{}", row["token"].as_str()?);
        Some((base, stop))
    }

    /// One person's mail, from the comments as they are now (edited text, deleted ones left out, internal checked again).
    pub(super) fn compose(&self, row: &Value, items: &[Value]) -> Option<mail::Msg> {
        let client = row["kind"] == "client";
        let lang = row["lang"].as_str().or(self.mail.cfg["lang"].as_str()).unwrap_or("en");
        let asset_name = |a: &Value| self.manifest["projects"].as_array().into_iter().flatten().flat_map(|p| Self::arr(p, "assets"))
            .find(|x| x["id"] == *a).and_then(|x| x["name"].as_str()).unwrap_or("").to_owned();
        let mut lines = vec![];
        let mut first_link = None;
        for q in items {
            let link = self.links().find(|l| l["id"] == q["link"]);
            if client && link.is_none_or(|l| self.live(l).is_err()) {
                continue;
            }
            let ev = q["event"].as_str().unwrap_or("");
            let (name, text) = match ev {
                "comment" | "reply" | "mention" => {
                    let Some(c) = self.comments.iter().find(|c| c["id"] == q["comment"]) else { continue };
                    let x = if q["reply"].is_null() { Some(c) } else { c["replies"].as_array().into_iter().flatten().find(|r| r["id"] == q["reply"]) };
                    let Some(x) = x else { continue };
                    if client && (is(c, "internal") || is(x, "internal")) {
                        continue;
                    }
                    (x["author"].as_str().unwrap_or("").to_owned(), x["text"].as_str().map(str::to_owned))
                }
                "approval" | "changes" => {
                    let Some(a) = self.approvals.iter().find(|a| a["id"] == q["approval"]) else { continue };
                    (a["author"].as_str().unwrap_or("").to_owned(), None)
                }
                _ => (String::new(), None),
            };
            let asset = if ev == "deadline" { link.and_then(|l| l["title"].as_str()).unwrap_or("").to_owned() } else { asset_name(&q["asset"]) };
            let n = self.manifest["projects"].as_array().into_iter().flatten().flat_map(|p| Self::arr(p, "assets")).flat_map(|a| Self::arr(a, "versions"))
                .find(|v| v["id"] == q["version"]).map(|v| v["number"].to_string()).unwrap_or_default();
            first_link = first_link.or(link);
            lines.push(mail::Line { event: ev.to_owned(), name, asset, n, text });
        }
        if lines.is_empty() {
            return None;
        }
        let title = first_link.and_then(|l| self.project(l)).and_then(|p| p["name"].as_str()).unwrap_or("Pluck").to_owned();
        let urls = self.urls(row, first_link);
        if client && urls.is_none() {
            return None; // a client mail without a working link is no use
        }
        let (subject, body) = mail::compose(lang, &title, &lines, urls.as_ref().map(|u| u.0.as_str()), urls.as_ref().map(|u| u.1.as_str()));
        Some(mail::Msg { to: row["email"].as_str()?.to_owned(), subject, body, unsubscribe: true })
    }

    // ---- the webhook ----

    /// The project's webhook, if the owner set one (never for internal comments unless switched on there).
    fn post_hook(&self, event: &str, x: &Value, internal: bool, author: &str, text: &str) {
        let Some(project) = self.manifest["projects"].as_array().into_iter().flatten()
            .find(|p| Self::arr(p, "assets").any(|a| a["id"] == x["asset"])).and_then(|p| p["id"].as_str()) else { return };
        let h = &self.mail.hooks[project];
        let (Some(url), Some(secret)) = (h["url"].as_str(), h["secret"].as_str()) else { return };
        if internal && h["internal"] != true || self.ident.backup {
            return;
        }
        let asset = self.manifest["projects"].as_array().into_iter().flatten().flat_map(|p| Self::arr(p, "assets")).find(|a| a["id"] == x["asset"]);
        let summary = format!("{author}: {text}");
        // `text` first, so a Slack incoming webhook shows it as it is; no link codes (the URL would open the review).
        let body = json!({"text": summary.trim_end_matches(": "), "event": event, "project": project, "asset": asset.map(|a| &a["name"]), "version": x["version"],
            "link": x["link"], "author": author, "comment": text}).to_string();
        let (url, secret) = (url.to_owned(), secret.to_owned());
        tokio::spawn(async move {
            match mail::hook(url, secret, body, None).await {
                Ok(c) if (200..300).contains(&c) => {}
                Ok(c) => log(format!("host: webhook answered {c}")),
                Err(e) => log(format!("host: webhook failed ({}): {}", e.code, e.detail)),
            }
        });
    }

    // ---- the Mac's ops ----

    /// mail-set, mail-state, subscriber-set/-remove, unsubscribe, hook-set. None: not a mail op.
    pub(super) fn mail_sync(&mut self, op: &Value) -> Option<Value> {
        let name = op["op"].as_str().unwrap_or("");
        if !matches!(name, "mail-set" | "mail-state" | "subscriber-set" | "subscriber-remove" | "unsubscribe" | "hook-set" | "mail-remind") {
            return None;
        }
        if self.ident.backup && name != "mail-state" {
            return Some(json!({"error": {"code": "main"}}));
        }
        let admin = op["_mac"]["admin"].as_bool().unwrap_or(true);
        Some(match name {
            "mail-set" => self.mail.set(&op["settings"], op["password"].as_str()),
            "mail-state" => {
                self.sync_rows();
                self.mail.state()
            }
            "unsubscribe" => self.unsubscribe(op["token"].as_str().unwrap_or("")),
            "mail-remind" => self.mail_remind(op),
            "subscriber-remove" => {
                self.mail.subs.retain(|r| r["id"] != op["id"]);
                if self.mail.save_subs() { json!({"ok": true}) } else { json!({"error": {"code": "write"}}) }
            }
            "subscriber-set" => {
                // An editor Mac forwards its browsers' subscribes (client rows); the team's rows are an admin's.
                if !admin && op["kind"] != "client" {
                    return Some(json!({"error": "admin"}));
                }
                self.subscriber_set(op)
            }
            _ => {
                let Some(p) = op["project"].as_str().filter(|p| !p.is_empty()) else { return Some(json!({"error": {"code": "invalid"}})) };
                match op["url"].as_str() {
                    None => { self.mail.hooks.as_object_mut().map(|h| h.remove(p)); }
                    Some(u) if u.starts_with("https://") && u.len() <= 2000 && !u.contains(char::is_whitespace) => {
                        let secret = self.mail.hooks[p]["secret"].as_str().map(str::to_owned).unwrap_or_else(|| crate::keys::b64(&rand::random::<[u8; 32]>()));
                        self.mail.hooks[p] = json!({"url": u, "internal": op["internal"] == true, "secret": secret});
                    }
                    Some(_) => return Some(json!({"error": {"code": "invalid"}})),
                }
                if !self.mail.save_hooks() {
                    return Some(json!({"error": {"code": "write"}}));
                }
                json!({"ok": true, "secret": self.mail.hooks[p]["secret"]})
            }
        })
    }

    /// `mail-remind` {asset, person, overdue}: an assignment due today or overdue, to that teammate's team row only (never a
    /// client: team rows are owners and editors). Once per asset, person and day (in the host's offset), however many Macs ask.
    fn mail_remind(&mut self, op: &Value) -> Value {
        if !self.mail_on() {
            return json!({"error": {"code": "off"}});
        }
        let (Some(asset), Some(person)) = (op["asset"].as_str(), op["person"].as_str()) else { return json!({"error": {"code": "invalid"}}) };
        if !self.manifest["projects"].as_array().into_iter().flatten().flat_map(|p| Self::arr(p, "assets")).any(|a| a["id"] == asset) {
            return json!({"ok": true, "queued": false});
        }
        self.sync_rows();
        let Some(row) = self.rows().into_iter().find(|r| r["kind"] == "team" && r["person"] == person) else { return json!({"ok": true, "queued": false}) };
        let day = (now_secs() + self.mail.cfg["tzOffset"].as_i64().unwrap_or(0) * 60).div_euclid(86_400);
        let ev = if op["overdue"] == true { "overdue" } else { "due" };
        let mut q = Self::item(&row, ev, &Value::Null, &json!(asset), &Value::Null, &Value::Null, &Value::Null);
        q["id"] = json!(format!("r:{asset}:{day}:{}", row["id"].as_str().unwrap_or("")));
        self.mail.push(vec![q]);
        json!({"ok": true, "queued": true})
    }

    fn subscriber_set(&mut self, op: &Value) -> Value {
        let kind = op["kind"].as_str().filter(|k| *k == "team" || *k == "client");
        let mode = op["mode"].as_str().filter(|m| mail::MODES.contains(m));
        let email = op["email"].as_str().filter(|e| valid_email(e)).map(|e| e.trim().to_owned());
        let (Some(kind), Some(mode)) = (kind, mode) else { return json!({"error": {"code": "invalid"}}) };
        let mute: Option<Vec<Value>> = op["mute"].as_array().map(|m| m.iter().filter(|x| x.is_string()).take(500).cloned().collect());
        let author = op["author"].as_str().filter(|a| !a.is_empty() && a.len() <= 64);
        let found = match op["id"].as_str() {
            Some(id) => self.mail.subs.iter().position(|r| r["id"] == id),
            None => self.mail.subs.iter().position(|r| r["kind"] == kind && if let Some(a) = author { r["link"] == op["link"] && r["author"] == a }
                else if op["person"].is_string() { r["person"] == op["person"] } else { r["link"] == op["link"] && email.as_deref().is_some_and(|e| r["email"] == e) }),
        };
        let i = match found {
            Some(i) => i,
            None if op["id"].is_string() => return json!({"error": {"code": "notFound"}}),
            None => {
                let Some(e) = &email else { return json!({"error": {"code": "invalid"}}) };
                let mut r = Mail::new_row(kind);
                (r["email"], r["link"], r["person"]) = (json!(e), op["link"].clone(), op["person"].clone());
                if let Some(a) = author {
                    r["author"] = json!(a);
                }
                self.mail.subs.push(r);
                self.mail.subs.len() - 1
            }
        };
        let r = &mut self.mail.subs[i];
        r["mode"] = json!(mode);
        if let Some(e) = email { r["email"] = json!(e) }
        if let Some(n) = op["name"].as_str() { r["name"] = json!(clean(n, 80)) }
        // `muteLink` + `muted`: one link's change merged into the list (a Mac's toggle must not undo the web page's mutes);
        // the whole `mute` list beside it is only for hosts older than this.
        if let Some(l) = op["muteLink"].as_str().filter(|l| !l.is_empty() && l.len() < 100) {
            let mut m: Vec<Value> = r["mute"].as_array().into_iter().flatten().filter(|x| x.as_str() != Some(l)).cloned().collect();
            if op["muted"] == true {
                m.push(json!(l));
            }
            m.truncate(500);
            r["mute"] = json!(m);
        } else if let Some(m) = mute {
            r["mute"] = json!(m)
        }
        if let Some(l) = op["lang"].as_str() { r["lang"] = json!(mail::lang(l)) }
        let id = r["id"].clone();
        if !self.mail.save_subs() {
            return json!({"error": {"code": "write"}});
        }
        json!({"ok": true, "id": id})
    }

    /// `mail-test` (run() sends it in the background): the settings and password, or the answer at once.
    pub fn mail_test_job(&self, op: &Value) -> Result<(Value, String, mail::Msg), Value> {
        let to = op["to"].as_str().filter(|t| valid_email(t)).ok_or_else(|| json!({"error": {"code": "invalid"}}))?;
        let pw = self.mail.password().filter(|_| self.mail.cfg["server"].is_string()).ok_or_else(|| json!({"error": {"code": "off"}}))?;
        let lang = self.mail.cfg["lang"].as_str().unwrap_or("en");
        let msg = mail::Msg { to: to.trim().to_owned(), subject: mail::text(lang, "test", &[]), body: mail::text(lang, "testBody", &[]), unsubscribe: false };
        Ok((self.mail.cfg.clone(), pw, msg))
    }
}

/// Did a team member (an account token) write it?
fn thread_by_team(team: &str, author: &Option<String>, accounts: &Value) -> bool {
    let Some(a) = author else { return false };
    accounts["people"].as_array().into_iter().flatten().filter_map(|p| p["id"].as_str()).any(|p| accounts::account_token(team, p) == *a)
}
