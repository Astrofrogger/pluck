// The manifest as the review data store (spec §13.0, §13.1). Every project meta, folder, asset and
// link carries rev/at/by (the writer's) and seq (this host's storeSeq when it accepted the change);
// tombstones live in "removed". Merge rule M: (rev, at, by) compared left to right, highest wins;
// on a full tie a tombstone beats an object. Comments merge with MC (replies unioned).
use std::{cmp::Ordering, collections::HashSet};

use serde_json::{Value, json};

pub const PROTOCOL: u64 = 3;
pub const TOMBSTONE_DAYS: i64 = 180;
const PAGE_OBJECTS: usize = 500;
const PAGE_BYTES: usize = 768 * 1024;

fn key(v: &Value) -> (u64, &str, &str) {
    (v["rev"].as_u64().unwrap_or(0), v["at"].as_str().unwrap_or(""), v["by"].as_str().unwrap_or(""))
}

/// Rule M: does `incoming` beat `stored`? `*_tomb` says which side is a tombstone.
pub fn wins(incoming: &Value, inc_tomb: bool, stored: &Value, st_tomb: bool) -> bool {
    match key(incoming).cmp(&key(stored)) {
        Ordering::Greater => true,
        Ordering::Less => false,
        Ordering::Equal => inc_tomb && !st_tomb,
    }
}

/// Rule MC: the base is the comment that wins under M; replies are the union of both sides by id,
/// minus the union of both sides' deletedReplies (which is kept, for later merges).
pub fn merge_comment(stored: &Value, incoming: &Value) -> Value {
    // On a full tie the incoming copy is the base (as Pluck does: an edit from before revisions).
    let (mut base, other) = if !wins(stored, false, incoming, false) { (incoming.clone(), stored) } else { (stored.clone(), incoming) };
    let ids = |v: &Value, k: &str| -> Vec<Value> { v[k].as_array().cloned().unwrap_or_default() };
    let deleted: Vec<Value> = {
        let mut d = ids(stored, "deletedReplies");
        for x in ids(incoming, "deletedReplies") {
            if !d.contains(&x) {
                d.push(x);
            }
        }
        d
    };
    let mut replies: Vec<Value> = ids(&base, "replies");
    for r in ids(other, "replies") {
        if !replies.iter().any(|x| x["id"] == r["id"]) {
            replies.push(r);
        }
    }
    replies.retain(|r| !deleted.contains(&r["id"]));
    // Internal stays internal: a copy that doesn't know the flag (Pluck's Reply has no such field) must not reveal it.
    let internal: Vec<Value> = ids(stored, "replies").into_iter().chain(ids(incoming, "replies")).filter(|r| r["internal"] == true).map(|r| r["id"].clone()).collect();
    for r in &mut replies {
        if internal.contains(&r["id"]) {
            r["internal"] = json!(true);
        }
    }
    replies.sort_by(|a, b| (a["created"].as_str(), a["id"].as_str()).cmp(&(b["created"].as_str(), b["id"].as_str())));
    base["replies"] = json!(replies);
    if !deleted.is_empty() {
        base["deletedReplies"] = json!(deleted);
    }
    base
}

fn arr<'a>(v: &'a Value, k: &str) -> impl Iterator<Item = &'a Value> {
    v[k].as_array().into_iter().flatten()
}

/// Every object of the store, flat: (kind, project, object without children).
fn objects(m: &Value) -> Vec<(&'static str, Value, Value)> {
    let mut out = vec![];
    for p in arr(m, "projects") {
        let mut meta = p.clone();
        if let Some(o) = meta.as_object_mut() {
            o.remove("folders");
            o.remove("assets");
        }
        out.push(("project", Value::Null, meta));
        for f in arr(p, "folders") {
            out.push(("folder", p["id"].clone(), f.clone()));
        }
        for a in arr(p, "assets") {
            out.push(("asset", p["id"].clone(), a.clone()));
        }
    }
    for l in arr(m, "links") {
        out.push(("link", Value::Null, l.clone()));
    }
    out
}

fn without_seq(v: &Value) -> Value {
    let mut v = v.clone();
    if let Some(o) = v.as_object_mut() {
        o.remove("seq");
    }
    v
}

fn find<'a>(list: &'a [(&'static str, Value, Value)], kind: &str, id: &Value) -> Option<&'a Value> {
    list.iter().find(|(k, _, o)| *k == kind && o["id"] == *id).map(|(_, _, o)| o)
}

fn obj_mut<'a>(m: &'a mut Value, kind: &str, project: &Value, id: &Value) -> Option<&'a mut Value> {
    match kind {
        "link" => m["links"].as_array_mut()?.iter_mut().find(|l| l["id"] == *id),
        "project" => m["projects"].as_array_mut()?.iter_mut().find(|p| p["id"] == *id),
        k => {
            let p = m["projects"].as_array_mut()?.iter_mut().find(|p| p["id"] == *project)?;
            p[if k == "folder" { "folders" } else { "assets" }].as_array_mut()?.iter_mut().find(|x| x["id"] == *id)
        }
    }
}

/// Before saving `new` over `old`: everything new or changed gets the next storeSeq (and, when
/// the writer didn't raise its rev, rev+1/now/`by`); everything gone gets a tombstone. Tombstones
/// older than 180 days go. Ensures "storeSeq" and "removed" exist.
pub fn stamp(old: &Value, new: &mut Value, by: &str, now: &str, cutoff: &str) {
    let mut seq = old["storeSeq"].as_u64().unwrap_or(0).max(new["storeSeq"].as_u64().unwrap_or(0));
    let before = objects(old);
    let after = objects(new);
    let mut removed: Vec<Value> = arr(new, "removed").cloned().collect();
    for (kind, project, o) in &after {
        let prev = find(&before, kind, &o["id"]);
        if prev.is_some_and(|p| without_seq(p) == without_seq(o)) {
            if let (Some(p), Some(x)) = (prev, obj_mut(new, kind, project, &o["id"])) {
                x["seq"] = p["seq"].clone(); // unchanged
            }
            continue;
        }
        seq += 1;
        let rev_up = prev.is_some_and(|p| o["rev"].as_u64().unwrap_or(0) <= p["rev"].as_u64().unwrap_or(0));
        let Some(x) = obj_mut(new, kind, project, &o["id"]) else { continue };
        if rev_up || x["rev"].as_u64().is_none() {
            x["rev"] = json!(prev.map_or(0, |p| p["rev"].as_u64().unwrap_or(0)).max(x["rev"].as_u64().unwrap_or(0)) + 1);
            x["at"] = json!(now);
            x["by"] = json!(by);
        }
        x["seq"] = json!(seq);
        removed.retain(|t| !(t["kind"] == *kind && t["id"] == o["id"]));
    }
    for (kind, project, o) in &before {
        if find(&after, kind, &o["id"]).is_some() {
            continue;
        }
        // A project's own folders and assets go with it; one tombstone is enough.
        if *kind != "project" && *kind != "link" && find(&after, "project", project).is_none() {
            continue;
        }
        if removed.iter().any(|t| t["kind"] == *kind && t["id"] == o["id"]) {
            continue;
        }
        seq += 1;
        removed.push(json!({"kind": kind, "id": o["id"], "project": project, "rev": o["rev"].as_u64().unwrap_or(0) + 1,
            "at": now, "by": by, "seq": seq}));
    }
    for t in removed.iter_mut().filter(|t| t["seq"].as_u64().is_none()) {
        seq += 1; // a tombstone that came in with a merge publish
        t["seq"] = json!(seq);
    }
    removed.retain(|t| t["at"].as_str().is_none_or(|a| a >= cutoff));
    new["removed"] = json!(removed);
    new["storeSeq"] = json!(seq);
}

/// What only the Mac holding a link's key can make (registration, auth, room signing, join hash), the level they
/// belong to (§13.24: a level-3 record has no `sign`), and the room they're for: a keyless Mac's copy may still name
/// the room from before "Make a New Link", which must never be paired with the new reg.
const LINK_SECRETS: [&str; 6] = ["roomID", "reg", "auth", "sign", "join", "level"];

/// `publish` with `merge:true` (§13.1): each project meta, folder, asset (with all its versions)
/// and link merged on its own under M; only tombstones delete. Returns the merged manifest (not
/// yet stamped: `stamp` gives the winners their seq) and the ids that lost.
pub fn merge_publish(raw: &Value, m: &Value, tombstones: &Value) -> (Value, Vec<Value>) {
    let mut out = raw.clone();
    if !out["projects"].is_array() {
        out["projects"] = json!([]);
    }
    if !out["links"].is_array() {
        out["links"] = json!([]);
    }
    let mut stale = vec![];
    let tomb_of = |out: &Value, kind: &str, id: &Value| arr(out, "removed").find(|t| t["kind"] == kind && t["id"] == *id).cloned();
    // One object against what's stored (or its tombstone): Some(winner to store) or None (lost).
    let decide = |out: &Value, kind: &str, stored: Option<&Value>, inc: &Value| -> bool {
        if let Some(t) = tomb_of(out, kind, &inc["id"]) {
            if !wins(inc, false, &t, true) {
                return false;
            }
        }
        stored.is_none_or(|s| wins(inc, false, s, false))
    };
    let clean = |v: &Value| without_seq(v);
    for p in arr(m, "projects") {
        let pid = p["id"].clone();
        let mut meta = clean(p);
        if let Some(o) = meta.as_object_mut() {
            o.remove("folders");
            o.remove("assets");
        }
        let exists = arr(&out, "projects").any(|x| x["id"] == pid);
        if !exists {
            if decide(&out, "project", None, &meta) {
                let mut np = meta.clone();
                np["folders"] = json!([]);
                np["assets"] = json!([]);
                out["projects"].as_array_mut().unwrap().push(np);
                out["removed"].as_array_mut().map(|r| r.retain(|t| !(t["kind"] == "project" && t["id"] == pid)));
            } else {
                stale.push(pid.clone());
                continue; // removed for good: its children too
            }
        } else {
            let stored = arr(&out, "projects").find(|x| x["id"] == pid).cloned().unwrap();
            let mut stored_meta = stored.clone();
            if let Some(o) = stored_meta.as_object_mut() {
                o.remove("folders");
                o.remove("assets");
            }
            if meta.get("rev").is_some() || p.get("name").is_some() {
                if decide(&out, "project", Some(&stored_meta), &meta) {
                    let x = obj_mut(&mut out, "project", &Value::Null, &pid).unwrap();
                    let (f, a) = (x["folders"].take(), x["assets"].take());
                    *x = meta.clone();
                    x["folders"] = f;
                    x["assets"] = a;
                } else if without_seq(&stored_meta) != meta {
                    stale.push(pid.clone());
                }
            }
        }
        for (kind, list) in [("folder", "folders"), ("asset", "assets")] {
            for inc in arr(p, list) {
                let inc = clean(inc);
                let stored = arr(&out, "projects").find(|x| x["id"] == pid).and_then(|x| arr(x, list).find(|o| o["id"] == inc["id"]).cloned());
                if decide(&out, kind, stored.as_ref(), &inc) {
                    let px = obj_mut(&mut out, "project", &Value::Null, &pid).unwrap();
                    let l = px[list].as_array_mut().unwrap();
                    match l.iter_mut().find(|o| o["id"] == inc["id"]) {
                        Some(o) => *o = inc.clone(),
                        None => l.push(inc.clone()),
                    }
                    out["removed"].as_array_mut().map(|r| r.retain(|t| !(t["kind"] == kind && t["id"] == inc["id"])));
                } else if stored.as_ref().is_none_or(|s| without_seq(s) != inc) {
                    stale.push(inc["id"].clone());
                }
            }
        }
    }
    for inc in arr(m, "links") {
        let mut inc = clean(inc);
        let stored = arr(&out, "links").find(|x| x["id"] == inc["id"]).cloned();
        // A Mac without the link's keys (made on another Mac) sends it without them: the stored ones stay.
        // A new link without them can't be served, so it isn't taken.
        let has = |v: &Value, k: &str| v[k].as_str().is_some_and(|x| !x.is_empty());
        match &stored {
            // All or nothing: a new key set (a level-2 link made level 3) must not keep the old `sign`.
            Some(s) if !has(&inc, "reg") => {
                for k in LINK_SECRETS {
                    if !s[k].is_null() {
                        inc[k] = s[k].clone();
                    }
                }
            }
            Some(_) => {}
            None if !has(&inc, "reg") || !has(&inc, "join") || !(has(&inc, "sign") || inc["level"] == 3) => {
                stale.push(inc["id"].clone());
                continue;
            }
            None => {}
        }
        if decide(&out, "link", stored.as_ref(), &inc) {
            let l = out["links"].as_array_mut().unwrap();
            match l.iter_mut().find(|o| o["id"] == inc["id"]) {
                Some(o) => *o = inc.clone(),
                None => l.push(inc.clone()),
            }
            out["removed"].as_array_mut().map(|r| r.retain(|t| !(t["kind"] == "link" && t["id"] == inc["id"])));
        } else if stored.as_ref().is_none_or(|s| without_seq(s) != inc) {
            stale.push(inc["id"].clone());
        }
    }
    for t in tombstones.as_array().into_iter().flatten() {
        let (Some(kind), true) = (t["kind"].as_str(), t["id"].is_string()) else { continue };
        if !["project", "folder", "asset", "link"].contains(&kind) {
            continue;
        }
        let t = clean(t);
        let stored = obj_mut(&mut out, kind, &t["project"], &t["id"]).map(|x| x.clone());
        if let Some(s) = &stored {
            if !wins(&t, true, s, false) {
                stale.push(t["id"].clone());
                continue;
            }
        }
        if let Some(old) = tomb_of(&out, kind, &t["id"]) {
            if !wins(&t, true, &old, true) {
                continue; // already removed, by a later tombstone
            }
        }
        match kind {
            "link" => out["links"].as_array_mut().unwrap().retain(|l| l["id"] != t["id"]),
            "project" => out["projects"].as_array_mut().unwrap().retain(|p| p["id"] != t["id"]),
            k => {
                let list = if k == "folder" { "folders" } else { "assets" };
                if let Some(p) = out["projects"].as_array_mut().unwrap().iter_mut().find(|p| p["id"] == t["project"]) {
                    p[list].as_array_mut().map(|l| l.retain(|x| x["id"] != t["id"]));
                }
            }
        }
        if !out["removed"].is_array() {
            out["removed"] = json!([]);
        }
        let r = out["removed"].as_array_mut().unwrap();
        r.retain(|x| !(x["kind"] == kind && x["id"] == t["id"]));
        r.push(t);
    }
    let mut seen = HashSet::new();
    stale.retain(|s| seen.insert(s.to_string()));
    (out, stale)
}

/// A page of `changes` as a merge-publish manifest: folders and assets back under their projects
/// (a project without a meta in the page is a partial one, which leaves its meta alone).
pub fn fragment(page: &Value) -> Value {
    let mut projects: Vec<Value> = arr(page, "projects").map(|p| {
        let mut p = p.clone();
        p["folders"] = json!([]);
        p["assets"] = json!([]);
        p
    }).collect();
    for (k, list) in [("folders", "folders"), ("assets", "assets")] {
        for x in arr(page, k) {
            let pid = x["project"].clone();
            if !projects.iter().any(|p| p["id"] == pid) {
                projects.push(json!({"id": pid, "folders": [], "assets": []}));
            }
            let mut x = x.clone();
            x.as_object_mut().map(|o| o.remove("project"));
            projects.iter_mut().find(|p| p["id"] == pid).unwrap()[list].as_array_mut().unwrap().push(x);
        }
    }
    json!({"format": 1, "projects": projects, "links": page["links"].clone()})
}

/// `changes since`: objects and tombstones with seq > since, oldest first, at most 500 objects
/// or 768 KiB per page. `storeSeq` is the cursor for the next call when `more` is true.
pub fn changes(m: &Value, since: u64, limit: usize) -> Value {
    let mut all: Vec<(u64, &'static str, Value)> = objects(m).into_iter().filter_map(|(kind, project, mut o)| {
        let s = o["seq"].as_u64().unwrap_or(0);
        if s <= since {
            return None;
        }
        if !project.is_null() {
            o["project"] = project;
        }
        Some((s, kind, o))
    }).collect();
    all.extend(arr(m, "removed").filter(|t| t["seq"].as_u64().unwrap_or(0) > since).map(|t| (t["seq"].as_u64().unwrap_or(0), "removed", t.clone())));
    all.sort_by_key(|(s, _, _)| *s);
    let limit = limit.clamp(1, PAGE_OBJECTS);
    let mut out = json!({"projects": [], "folders": [], "assets": [], "links": [], "removed": []});
    let (mut n, mut bytes, mut last) = (0, 0, since);
    let total = all.len();
    for (s, kind, o) in all {
        let len = o.to_string().len();
        if n >= limit || (n > 0 && bytes + len > PAGE_BYTES) {
            break;
        }
        let k = match kind { "project" => "projects", "folder" => "folders", "asset" => "assets", "link" => "links", _ => "removed" };
        out[k].as_array_mut().unwrap().push(o);
        (n, bytes, last) = (n + 1, bytes + len, s);
    }
    let more = n < total;
    out["more"] = json!(more);
    out["storeSeq"] = json!(if more { last } else { m["storeSeq"].as_u64().unwrap_or(0).max(last) });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A newer copy from a Pluck that drops the reply's `internal` (a Mac marking the thread done) keeps it internal.
    #[test]
    fn an_internal_reply_stays_internal_through_a_merge() {
        let stored = json!({"id": "C", "rev": 1, "at": "2026-11-16T09:00:00Z", "by": "host", "replies": [{"id": "r", "text": "between us", "created": "2026-11-16T09:00:00Z", "internal": true}]});
        let incoming = json!({"id": "C", "rev": 2, "at": "2026-11-16T10:00:00Z", "by": "mac", "completed": true, "replies": [{"id": "r", "text": "between us", "created": "2026-11-16T09:00:00Z"}]});
        let m = merge_comment(&stored, &incoming);
        assert_eq!((m["completed"].clone(), m["replies"][0]["internal"].clone()), (json!(true), json!(true)));
    }

    #[test]
    fn link_merge_keeps_secrets() {
        let full = json!({"id": "L", "roomID": "R", "reg": "r", "auth": "a", "sign": "s", "join": "j", "paused": false, "rev": 1, "at": "2026-11-16T09:00:00Z", "by": "A"});
        let raw = json!({"format": 1, "projects": [], "links": [full]});
        // From another Mac (no keys there): its changes win, the secrets stay.
        let bare = json!({"id": "L", "roomID": "R", "paused": true, "revoked": "2026-11-16T10:00:00Z", "rev": 2, "at": "2026-11-16T10:00:00Z", "by": "B"});
        let (out, stale) = merge_publish(&raw, &json!({"links": [bare]}), &Value::Null);
        let l = &out["links"][0];
        assert!(stale.is_empty());
        assert_eq!((l["paused"].clone(), l["revoked"].clone()), (json!(true), json!("2026-11-16T10:00:00Z")));
        assert_eq!((l["reg"].as_str(), l["auth"].as_str(), l["sign"].as_str(), l["join"].as_str()), (Some("r"), Some("a"), Some("s"), Some("j")));
        // Empty or null ones never overwrite them either.
        let blank = json!({"id": "L", "roomID": "R", "reg": "", "auth": null, "rev": 3, "at": "2026-11-16T11:00:00Z", "by": "B"});
        let (out, _) = merge_publish(&out, &json!({"links": [blank]}), &Value::Null);
        assert_eq!((out["links"][0]["reg"].as_str(), out["links"][0]["auth"].as_str()), (Some("r"), Some("a")));
        // From the Mac with the keys: new secrets replace the old.
        let rekeyed = json!({"id": "L", "roomID": "R", "reg": "r2", "auth": "a2", "sign": "s2", "join": "j2", "rev": 4, "at": "2026-11-16T12:00:00Z", "by": "A"});
        let (out, _) = merge_publish(&out, &json!({"links": [rekeyed]}), &Value::Null);
        assert_eq!((out["links"][0]["reg"].as_str(), out["links"][0]["join"].as_str()), (Some("r2"), Some("j2")));
        // "Make a New Link" (§13.24): level 3 has no `sign`; the old one must not stay, and a keyless Mac keeps the level.
        let v3 = json!({"id": "L", "roomID": "R3", "reg": "r3", "auth": "a3", "join": "j3", "level": 3, "rev": 5, "at": "2026-11-16T13:00:00Z", "by": "A"});
        let (out, _) = merge_publish(&out, &json!({"links": [v3]}), &Value::Null);
        assert!(out["links"][0]["sign"].is_null() && out["links"][0]["level"] == 3);
        let bare = json!({"id": "L", "roomID": "R3", "paused": true, "rev": 6, "at": "2026-11-16T14:00:00Z", "by": "B"});
        let (out, _) = merge_publish(&out, &json!({"links": [bare]}), &Value::Null);
        assert!(out["links"][0]["sign"].is_null() && out["links"][0]["level"] == 3 && out["links"][0]["reg"] == "r3");
        // A keyless Mac that hasn't heard of the new link yet still names the old room: the room stays with its reg.
        let stale_room = json!({"id": "L", "roomID": "R", "paused": false, "rev": 7, "at": "2026-11-16T15:00:00Z", "by": "B"});
        let (out, _) = merge_publish(&out, &json!({"links": [stale_room]}), &Value::Null);
        assert_eq!((out["links"][0]["roomID"].as_str(), out["links"][0]["reg"].as_str(), out["links"][0]["paused"].clone()), (Some("R3"), Some("r3"), json!(false)));
        // A new link without them isn't taken; a new level-3 one is.
        let (out, stale) = merge_publish(&out, &json!({"links": [{"id": "N", "roomID": "R2", "rev": 1, "at": T0, "by": "B"},
            {"id": "N3", "roomID": "R4", "reg": "r", "auth": "a", "join": "j", "level": 3, "rev": 1, "at": T0, "by": "B"}]}), &Value::Null);
        assert_eq!((out["links"].as_array().unwrap().len(), stale), (2, vec![json!("N")]));
    }

    const T0: &str = "2026-11-16T09:00:00Z";
    const T1: &str = "2026-11-16T10:00:00Z";
    const T2: &str = "2026-11-16T11:00:00Z";

    fn o(rev: u64, at: &str, by: &str) -> Value {
        json!({"id": "X", "rev": rev, "at": at, "by": by})
    }

    /// The shared merge vectors of §13.0 (R1 tests the same table).
    #[test]
    fn merge_vectors() {
        assert!(wins(&o(3, T0, "B"), false, &o(2, T1, "A"), false), "1: higher rev");
        assert!(wins(&o(2, T2, "A"), false, &o(2, T1, "A"), false), "2: later at");
        assert!(wins(&o(2, T1, "B"), false, &o(2, T1, "A"), false), "3: B > A");
        assert!(wins(&o(2, T1, "A"), true, &o(2, T1, "A"), false), "4: tombstone on a full tie");
        assert!(!wins(&o(2, T1, "A"), false, &o(3, T1, "A"), true), "5: tombstone rev 3 stays");
        let c = |rev: u64, replies: &[&str], del: &[&str]| json!({"id": "C", "rev": rev, "at": T1, "by": "A",
            "replies": replies.iter().map(|r| json!({"id": r})).collect::<Vec<_>>(), "deletedReplies": del});
        let ids = |v: &Value| v["replies"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap().to_owned()).collect::<Vec<_>>();
        let r6 = merge_comment(&c(2, &["r1", "r2"], &[]), &c(3, &["r1", "r3"], &["r2"]));
        assert_eq!((r6["rev"].as_u64(), ids(&r6)), (Some(3), vec!["r1".to_owned(), "r3".into()]), "6");
        let r7 = merge_comment(&c(3, &["r1", "r4"], &[]), &c(2, &["r1", "r3"], &[]));
        assert_eq!((r7["rev"].as_u64(), ids(&r7)), (Some(3), vec!["r1".to_owned(), "r3".into(), "r4".into()]), "7");
    }

    fn m() -> Value {
        json!({"format": 1, "projects": [{"id": "P", "name": "Spring", "rev": 1, "at": T0, "by": "A",
            "folders": [], "assets": [{"id": "A1", "name": "Hero", "rev": 2, "at": T1, "by": "A", "versions": []}]}], "links": []})
    }

    #[test]
    fn publish_merge_reports_stale_and_tombstones_win() {
        let mut raw = m();
        stamp(&json!({}), &mut raw, "host:h", T0, "2000");
        // An older asset loses (stale), a newer folder and link come in.
        let inc = json!({"format": 1, "projects": [{"id": "P", "folders": [{"id": "F", "name": "Socials", "rev": 1, "at": T1, "by": "B"}],
            "assets": [{"id": "A1", "name": "Old", "rev": 1, "at": T2, "by": "B", "versions": []}]}],
            "links": [{"id": "L", "title": "T", "reg": "r", "sign": "s", "join": "j", "rev": 1, "at": T1, "by": "B"}]});
        let (mut out, stale) = merge_publish(&raw, &inc, &Value::Null);
        assert_eq!(stale, [json!("A1")]);
        assert_eq!(out["projects"][0]["assets"][0]["name"], "Hero");
        assert_eq!(out["projects"][0]["name"], "Spring", "a partial project leaves its meta");
        stamp(&raw, &mut out, "host:h", T1, "2000");
        assert_eq!(out["storeSeq"], 4, "project, asset, then the folder and link");
        // A tombstone removes the asset; a late copy of it is then stale.
        let (mut o2, st) = merge_publish(&out, &json!({}), &json!([{"kind": "asset", "id": "A1", "project": "P", "rev": 3, "at": T2, "by": "B"}]));
        assert!(st.is_empty() && o2["projects"][0]["assets"].as_array().unwrap().is_empty());
        stamp(&out, &mut o2, "host:h", T2, "2000");
        let late = json!({"format": 1, "projects": [{"id": "P", "assets": [{"id": "A1", "name": "Hero", "rev": 2, "at": T2, "by": "Z", "versions": []}]}]});
        let (o3, st) = merge_publish(&o2, &late, &Value::Null);
        assert_eq!(st, [json!("A1")]);
        assert!(o3["projects"][0]["assets"].as_array().unwrap().is_empty());
        // Applying the same publish twice changes nothing.
        let (o4, _) = merge_publish(&o2, &inc, &Value::Null);
        let mut o4 = o4;
        stamp(&o2, &mut o4, "host:h", T2, "2000");
        assert_eq!(o4["storeSeq"], o2["storeSeq"], "idempotent");
    }

    #[test]
    fn changes_pages_and_tombstones() {
        let mut raw = json!({"format": 1, "projects": [{"id": "P", "name": "P", "folders": [],
            "assets": (0..1200).map(|i| json!({"id": format!("A{i}"), "name": "x".repeat(10)})).collect::<Vec<_>>()}], "links": []});
        stamp(&json!({}), &mut raw, "host:h", T0, "2000");
        let mut since = 0;
        let mut got = 0;
        loop {
            let c = changes(&raw, since, 500);
            got += c["assets"].as_array().unwrap().len() + c["projects"].as_array().unwrap().len();
            assert!(c["assets"].as_array().unwrap().iter().all(|a| a["project"] == "P"));
            since = c["storeSeq"].as_u64().unwrap();
            if c["more"] == false { break }
        }
        assert_eq!((got, since), (1201, 1201));
        let mut next = raw.clone();
        next["projects"][0]["assets"].as_array_mut().unwrap().remove(0);
        stamp(&raw, &mut next, "admin", T1, "2000");
        let c = changes(&next, since, 500);
        assert_eq!((c["removed"][0]["id"].clone(), c["removed"][0]["rev"].clone(), c["storeSeq"].clone()), (json!("A0"), json!(2), json!(1202)));
        // Big objects cut a page at 768 KiB.
        let mut big = json!({"format": 1, "projects": [{"id": "P", "name": "P", "folders": [],
            "assets": (0..10).map(|i| json!({"id": format!("B{i}"), "name": "y".repeat(200_000)})).collect::<Vec<_>>()}], "links": []});
        stamp(&json!({}), &mut big, "h", T0, "2000");
        let c = changes(&big, 0, 500);
        assert!(c["more"] == true && c["assets"].as_array().unwrap().len() == 3, "{}", c["assets"].as_array().unwrap().len());
        // Old tombstones go.
        let mut later = next.clone();
        stamp(&next, &mut later, "h", T1, "2027");
        assert!(later["removed"].as_array().unwrap().is_empty());
    }
}
