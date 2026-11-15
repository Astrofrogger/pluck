// A backup host (spec §13.3): a replica of the main (data) host at another site, reached over
// iroh. It pairs once with a role-backup invitation, then every 60 s: `changes` (applied with M),
// `pull` (kept with the main's seq as "main"), `append` of its own entries, `status` (its own
// summary up; an update request down), then copies. It keeps one rendition per version at its
// quality (or byte copies in "same" mode) within --max-storage, evicting the least recently
// viewed; a version it doesn't have is recalled from the main while the main is reachable.
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tokio::sync::{Notify, mpsc, oneshot};

use crate::{host::{self, now_iso}, log, store::PROTOCOL, sync::Client};

/// A round every 60 s; the main counts as unreachable after three missed rounds. PLUCK_REPLICA_ROUND_SECS overrides (tests).
fn round_every() -> Duration {
    Duration::from_secs_f64(std::env::var("PLUCK_REPLICA_ROUND_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(60.0))
}
fn reachable() -> Duration {
    round_every() * 3
}
const RECENT_VIEW: i64 = 600;
/// A failed copy is tried again after 1 s, doubling to 5 min; a success resets it.
const BACKOFF_MAX: Duration = Duration::from_secs(300);

/// Keeps a repeating error from flooding the log: a new message is logged, the same one again
/// only at its 2nd, 4th, 8th, … time, with the count.
#[derive(Default)]
pub struct Repeat {
    last: String,
    n: u64,
}

impl Repeat {
    pub fn note(&mut self, msg: String) -> Option<String> {
        if msg != self.last {
            self.last = msg.clone();
            self.n = 1;
            return Some(msg);
        }
        self.n += 1;
        self.n.is_power_of_two().then(|| format!("{msg} (repeated {} times)", self.n))
    }
}

#[derive(Default)]
struct State {
    v: Value, // replica.json: {"mainSeq","storeSeq","pushed","versions":{V:{state,bytes,lastViewed,quality,error?}}}
    queue: VecDeque<String>, // recalls first
    inflight: HashMap<String, usize>,
    last_ok: Option<Instant>,
    progress: HashMap<String, f64>,
    backoff: HashMap<String, (Instant, Duration)>, // failed copies: not before, current step
    quiet: Repeat,
}

pub struct Shared {
    pub data: PathBuf,
    pub max: u64,
    pub quality: String,
    st: Mutex<State>,
    wake: Notify,
}

/// "50G", "500M", "2T" or plain bytes.
pub fn parse_size(s: &str) -> Option<u64> {
    let s = s.trim();
    let (n, mul) = match s.chars().last()? {
        'G' | 'g' => (&s[..s.len() - 1], 1u64 << 30),
        'M' | 'm' => (&s[..s.len() - 1], 1 << 20),
        'T' | 't' => (&s[..s.len() - 1], 1 << 40),
        _ => (s, 1),
    };
    n.trim().parse::<u64>().ok()?.checked_mul(mul)
}

fn dir_size(p: &Path) -> u64 {
    let mut total = 0;
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            match e.file_type() {
                Ok(t) if t.is_dir() => stack.push(e.path()),
                Ok(t) if t.is_file() => total += e.metadata().map_or(0, |m| m.len()),
                _ => {}
            }
        }
    }
    total
}

fn secs_since(iso: &str) -> i64 {
    let now = now_iso();
    // Both are "YYYY-MM-DDTHH:MM:SSZ": compare by converting through norm_iso's day count.
    let to = |s: &str| -> Option<i64> {
        let n = host::norm_iso(s)?;
        let d: Vec<i64> = n.split(|c: char| !c.is_ascii_digit()).filter(|x| !x.is_empty()).filter_map(|x| x.parse().ok()).collect();
        let (y, m, dd) = (d[0], d[1], d[2]);
        let (y2, m2) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
        let era = y2.div_euclid(400);
        let yoe = y2 - era * 400;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + (153 * m2 + 2) / 5 + dd - 1;
        Some((era * 146_097 + doe - 719_468) * 86_400 + d[3] * 3600 + d[4] * 60 + d[5])
    };
    match (to(&now), to(iso)) {
        (Some(a), Some(b)) => a - b,
        _ => i64::MAX,
    }
}

impl Shared {
    pub fn load(data: &Path, max: u64, quality: &str) -> Arc<Shared> {
        let v = std::fs::read(data.join("replica.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .unwrap_or_else(|| json!({"mainSeq": 0, "storeSeq": 0, "pushed": 0, "versions": {}}));
        let mut st = State { v, ..Default::default() };
        // A copy interrupted by a restart starts again.
        for (_, x) in st.v["versions"].as_object_mut().into_iter().flatten() {
            if x["state"] == "making" {
                x["state"] = json!("queued");
            }
        }
        Arc::new(Shared { data: data.into(), max, quality: quality.into(), st: Mutex::new(st), wake: Notify::new() })
    }

    fn copies(&self) -> PathBuf {
        self.data.join("bundle").join("copies")
    }

    fn save(&self, st: &State) {
        let tmp = self.data.join("replica.json.part");
        if std::fs::write(&tmp, st.v.to_string()).and_then(|_| std::fs::rename(&tmp, self.data.join("replica.json"))).is_err() {
            log("replica.json: can't write".into());
        }
    }

    pub fn usage(&self) -> u64 {
        dir_size(&self.copies())
    }

    pub fn lighter(&self) -> bool {
        self.quality != "same"
    }

    pub fn making(&self) -> usize {
        let st = self.st.lock().unwrap();
        st.v["versions"].as_object().into_iter().flatten().filter(|(_, x)| x["state"] == "making").count()
    }

    fn state_of(st: &State, vid: &str) -> String {
        st.v["versions"][vid]["state"].as_str().unwrap_or("missing").to_owned()
    }

    fn set(st: &mut State, vid: &str, f: impl FnOnce(&mut Value)) {
        if !st.v["versions"].is_object() {
            st.v["versions"] = json!({});
        }
        let x = st.v["versions"].as_object_mut().unwrap().entry(vid).or_insert(json!({"state": "queued", "bytes": 0}));
        f(x);
    }

    pub fn summary(&self) -> Value {
        let st = self.st.lock().unwrap();
        let mut counts: BTreeMap<String, usize> = BTreeMap::new();
        let mut failed = vec![];
        for (id, x) in st.v["versions"].as_object().into_iter().flatten() {
            *counts.entry(x["state"].as_str().unwrap_or("").to_owned()).or_default() += 1;
            if x["state"] == "failed" {
                failed.push(json!({"version": id, "error": x["error"]}));
            }
        }
        json!({"usage": self.usage(), "max": self.max, "quality": self.quality, "versions": counts, "failed": failed,
            "mainReachable": st.last_ok.is_some_and(|t| t.elapsed() < reachable())})
    }

    /// Any fetch of a version counts as a view.
    pub fn fetch_start(&self, vid: &str) {
        let mut st = self.st.lock().unwrap();
        *st.inflight.entry(vid.to_owned()).or_default() += 1;
        if st.v["versions"].get(vid).is_some() {
            Self::set(&mut st, vid, |x| x["lastViewed"] = json!(now_iso()));
        }
    }

    pub fn fetch_end(&self, vid: &str) {
        let mut st = self.st.lock().unwrap();
        if let Some(n) = st.inflight.get_mut(vid) {
            *n = n.saturating_sub(1);
        }
    }

    /// A fetch of a version this backup hasn't got: Some(progress) when it's coming (it goes to
    /// the head of the queue), None while the main is offline.
    pub fn recall(&self, vid: &str) -> Option<f64> {
        let mut st = self.st.lock().unwrap();
        if !st.last_ok.is_some_and(|t| t.elapsed() < reachable()) {
            return None;
        }
        let p = st.progress.get(vid).copied().unwrap_or(0.0);
        if Self::state_of(&st, vid) != "making" {
            st.queue.retain(|q| q != vid);
            st.queue.push_front(vid.to_owned());
            Self::set(&mut st, vid, |x| { x["state"] = json!("queued"); x["lastViewed"] = json!(now_iso()); });
        }
        drop(st);
        self.wake.notify_one();
        Some(p)
    }

    /// Over max: drop the least recently viewed ready versions (not viewed in the last 10 min,
    /// no fetch in flight) until it fits. Returns what went.
    #[cfg(test)]
    pub fn evict(&self) -> Vec<String> {
        self.evict_to(self.max, false)
    }

    /// The ready versions eviction may drop (no fetch in flight; with `recent`, also those viewed in the
    /// last 10 min), least recently viewed first.
    fn candidates(st: &State, recent: bool) -> Vec<String> {
        let mut c: Vec<(&String, &str)> = st.v["versions"].as_object().into_iter().flatten()
            .filter(|(id, x)| x["state"] == "ready" && st.inflight.get(*id).copied().unwrap_or(0) == 0
                && (recent || x["lastViewed"].as_str().is_none_or(|t| secs_since(t) > RECENT_VIEW)))
            .map(|(id, x)| (id, x["lastViewed"].as_str().unwrap_or(""))).collect();
        c.sort_by(|a, b| a.1.cmp(b.1));
        c.into_iter().map(|(id, _)| id.clone()).collect()
    }

    fn evict_to(&self, limit: u64, recent: bool) -> Vec<String> {
        let mut gone = vec![];
        let mut usage = self.usage();
        while usage > limit {
            let mut st = self.st.lock().unwrap();
            // Versions not viewed lately go first; recently viewed ones only when `recent` and nothing else is left.
            let Some(vid) = Self::candidates(&st, false).into_iter().next()
                .or_else(|| recent.then(|| Self::candidates(&st, true).into_iter().next()).flatten()) else { break };
            let _ = std::fs::remove_dir_all(self.copies().join(&vid));
            Self::set(&mut st, &vid, |x| { x["state"] = json!("evicted"); x["bytes"] = json!(0); });
            self.save(&st);
            drop(st);
            usage = self.usage();
            gone.push(vid);
        }
        gone
    }

    /// A finished copy in `tmp` (inside copies/) becomes copies/<vid>. Older versions are evicted only
    /// now, and only as far as needed (one being fetched never); when it can't fit even with all of them
    /// gone, the new copy goes instead and what's there stays ("over cap").
    fn place(&self, vid: &str, tmp: &Path) -> Result<u64> {
        let out = self.copies().join(vid);
        let (new, old) = (dir_size(tmp), dir_size(&out));
        let freeable: u64 = {
            let st = self.st.lock().unwrap();
            Self::candidates(&st, true).iter().filter(|id| id.as_str() != vid).map(|id| dir_size(&self.copies().join(id))).sum()
        };
        let kept = self.usage().saturating_sub(new + old + freeable);
        if kept + new > self.max {
            let _ = std::fs::remove_dir_all(tmp);
            anyhow::bail!("over cap: the copy needs {new} bytes, {kept} of the {} allowed are kept", self.max);
        }
        self.evict_to(self.max + old, true); // the old copy of this version goes with the rename
        let _ = std::fs::remove_dir_all(&out);
        std::fs::rename(tmp, &out)?;
        Ok(dir_size(&out))
    }

    /// A copy failed: its temp folder goes, it waits (1 s doubling to 5 min) and is shown as failed.
    /// The line to log, if any (a repeat is logged only now and then).
    fn failed(&self, vid: &str, e: &anyhow::Error) -> Option<String> {
        let _ = std::fs::remove_dir_all(self.copies().join(format!("{vid}.replica")));
        let mut st = self.st.lock().unwrap();
        let step = st.backoff.get(vid).map_or(Duration::from_secs(1), |(_, s)| (*s * 2).min(BACKOFF_MAX));
        st.backoff.insert(vid.to_owned(), (Instant::now() + step, step));
        Self::set(&mut st, vid, |x| { x["state"] = json!("failed"); x["error"] = json!(format!("{e:#}")); });
        self.save(&st);
        st.quiet.note(format!("backup: copy of {vid}: {e:#}"))
    }

    fn waiting(st: &State, vid: &str) -> bool {
        st.backoff.get(vid).is_some_and(|(t, _)| *t > Instant::now())
    }

    /// The next version to make: recalls first, then the plan (newest first) while under 90 %.
    fn next(&self, plan: &[Value]) -> Option<Value> {
        let mut st = self.st.lock().unwrap();
        while let Some(v) = st.queue.pop_front() {
            if Self::waiting(&st, &v) {
                continue; // failed lately: a recall doesn't skip the wait
            }
            if let Some(p) = plan.iter().find(|p| p["id"] == v.as_str()) {
                return Some(p.clone());
            }
            // Not in a live link any more (or not known yet): forget the recall.
            Self::set(&mut st, &v, |x| if x["state"] == "queued" { x["state"] = json!("missing") });
        }
        drop(st);
        if self.usage() as f64 >= self.max as f64 * 0.9 {
            return None;
        }
        let st = self.st.lock().unwrap();
        plan.iter().filter(|p| p["current"] != false).find(|p| {
            let s = Self::state_of(&st, p["id"].as_str().unwrap_or(""));
            (s == "missing" || s == "queued" || s == "failed") && !Self::waiting(&st, p["id"].as_str().unwrap_or(""))
        }).cloned()
    }
}

/// The invitation link → its JSON (k "nas", role backup, not expired).
pub fn parse_link(link: &str) -> Result<Value> {
    let i = link.strip_prefix("pluck://edit-anywhere/join?i=").context("not a Pluck invitation link")?;
    let v: Value = serde_json::from_slice(&crate::keys::unb64(i).context("bad link")?)?;
    anyhow::ensure!(v["k"] == "nas" && v["role"] == "backup", "not a backup host invitation");
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    anyhow::ensure!(v["e"].as_u64().is_some_and(|e| e > now), "the invitation has run out");
    anyhow::ensure!(v["o"].as_str().is_some_and(crate::devices::valid_node) && v["c"].is_string() && v["fp"].is_string(), "incomplete invitation");
    Ok(v)
}

pub struct Setup {
    pub link: Option<String>,
    pub bin: PathBuf,
    pub name: String,
}

async fn host_op(to_host: &mpsc::Sender<host::Sync>, op: Value) -> Result<Value> {
    let (tx, rx) = oneshot::channel();
    to_host.send(host::Sync { op, reply: tx }).await?;
    Ok(rx.await?)
}

async fn wait_some(rx: &mut tokio::sync::watch::Receiver<Option<String>>) -> String {
    loop {
        if let Some(v) = rx.borrow_and_update().clone() {
            return v;
        }
        let _ = rx.changed().await;
    }
}

/// The backup's whole life: pair (once), then sync rounds and copies for ever.
pub async fn run(shared: Arc<Shared>, to_host: mpsc::Sender<host::Sync>, setup: Setup) {
    let main_path = shared.data.join("main.json");
    let stored: Option<Value> = std::fs::read(&main_path).ok().and_then(|b| serde_json::from_slice(&b).ok());
    let invite = match (&stored, &setup.link) {
        (Some(_), _) => None, // paired: the link is used once
        (None, Some(l)) => match parse_link(l) {
            Ok(v) => Some(v),
            Err(e) => return log(format!("backup: {e:#}")),
        },
        (None, None) => return log("backup: not paired and no --main-link".into()),
    };
    let (node, relay, addrs) = match (&stored, &invite) {
        (Some(m), _) => (m["node"].clone(), m["relay"].clone(), m["addrs"].clone()),
        (None, Some(i)) => (i["o"].clone(), i["r"].clone(), i["a"].clone()),
        _ => unreachable!(),
    };
    let (mut listen, mut my_id) = crate::iroh::home(&shared.data, setup.bin.clone(), node.as_str().unwrap_or(""), relay.as_str(), &addrs);
    let mut main = match stored {
        Some(m) => m,
        None => {
            let inv = invite.unwrap();
            let me = wait_some(&mut my_id).await;
            let at = wait_some(&mut listen).await;
            let hello = json!({"pair": inv["c"], "name": setup.name, "node": me, "role": "backup", "protocol": PROTOCOL});
            let c = match Client::connect(&at, inv["fp"].as_str().unwrap_or(""), hello).await {
                Ok(c) => c,
                Err(e) => return log(format!("backup: pairing with the main failed: {e:#}")),
            };
            let m = json!({"host": c.hello["host"]["id"], "name": c.hello["host"]["name"], "node": inv["o"], "relay": inv["r"],
                "device": c.hello["device"], "key": c.hello["key"], "pin": inv["fp"], "addrs": inv["a"]});
            use std::os::unix::fs::OpenOptionsExt;
            let w = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&main_path)
                .and_then(|mut f| std::io::Write::write_all(&mut f, m.to_string().as_bytes()));
            if let Err(e) = w {
                return log(format!("backup: can't write main.json: {e}"));
            }
            crate::report(json!({"backup": {"paired": m["name"]}}));
            m
        }
    };
    let (mut quiet, mut step) = (Repeat::default(), Duration::ZERO);
    loop {
        let at = wait_some(&mut listen).await;
        let mut ok = false;
        let hello = json!({"device": main["device"], "key": main["key"], "protocol": PROTOCOL});
        match Client::connect(&at, main["pin"].as_str().unwrap_or(""), hello).await {
            Ok(mut c) => {
                let _ = std::fs::write(shared.data.join("main-protocol"), format!("{}\n", c.hello["protocol"].as_u64().unwrap_or(0)));
                if let Some(n) = c.hello["host"]["name"].as_str().filter(|n| *n != main["name"]) {
                    main["name"] = json!(n);
                }
                match round(&shared, &to_host, &mut c).await {
                    Ok(()) => ok = true,
                    Err(e) => quiet.note(format!("backup: sync round: {e:#}")).map_or((), log),
                }
            }
            Err(e) => quiet.note(format!("backup: main unreachable: {e:#}")).map_or((), log),
        }
        if ok {
            (quiet, step) = (Repeat::default(), Duration::ZERO);
            let _ = tokio::time::timeout(round_every(), shared.wake.notified()).await;
        } else {
            // Unreachable or a failed round: wait 1 s doubling to a round (recalls don't cut it short).
            step = (step * 2).clamp(Duration::from_secs(1), round_every());
            tokio::time::sleep(step).await;
        }
    }
}

/// One sync round (§13.3 steps 1–4).
pub async fn round(shared: &Shared, to_host: &mpsc::Sender<host::Sync>, c: &mut Client) -> Result<()> {
    let (mut store_seq, mut main_seq, mut pushed) = {
        let st = shared.st.lock().unwrap();
        (st.v["storeSeq"].as_u64().unwrap_or(0), st.v["mainSeq"].as_u64().unwrap_or(0), st.v["pushed"].as_u64().unwrap_or(0))
    };
    // 1. changes since storeSeq, applied with M.
    loop {
        let page = c.ask(&json!({"op": "changes", "since": store_seq, "limit": 500})).await?;
        anyhow::ensure!(page.get("error").is_none(), "changes: {page}");
        let mut op = page.clone();
        op["op"] = json!("_replica-apply");
        host_op(to_host, op).await?;
        store_seq = page["storeSeq"].as_u64().unwrap_or(store_seq);
        if page["more"] != true {
            break;
        }
    }
    // 2. pull since mainSeq: kept with their main seq.
    loop {
        let p = c.ask(&json!({"op": "pull", "since": main_seq})).await?;
        let entries = p["entries"].as_array().cloned().unwrap_or_default();
        if entries.is_empty() {
            break;
        }
        main_seq = entries.iter().filter_map(|e| e["seq"].as_u64()).max().unwrap_or(main_seq);
        let r = host_op(to_host, json!({"op": "_replica-entries", "entries": entries})).await?;
        anyhow::ensure!(r.get("error").is_none(), "keeping the main's entries: {r}"); // retried next round, mainSeq unchanged
    }
    // 3. our own entries (comments made on this backup) up to the main.
    loop {
        let own = host_op(to_host, json!({"op": "_replica-own", "since": pushed})).await?;
        let entries = own["entries"].as_array().cloned().unwrap_or_default();
        if entries.is_empty() {
            break;
        }
        let last = entries.iter().filter_map(|e| e["seq"].as_u64()).max().unwrap_or(pushed);
        let out: Vec<Value> = entries.into_iter().map(|mut e| { e.as_object_mut().map(|o| o.remove("seq")); e }).collect();
        let r = c.ask(&json!({"op": "append", "entries": out})).await?;
        anyhow::ensure!(r["ok"] == true, "append: {r}");
        pushed = last;
    }
    {
        let mut st = shared.st.lock().unwrap();
        (st.v["storeSeq"], st.v["mainSeq"], st.v["pushed"]) = (json!(store_seq), json!(main_seq), json!(pushed));
        st.last_ok = Some(Instant::now());
        shared.save(&st);
    }
    // Our own summary up; an "Update now" for this backup comes back.
    let mut summary = shared.summary();
    // "Serving now" on the main's device list: this backup has viewers of its own.
    summary["serving"] = json!(host_op(to_host, json!({"op": "status"})).await?["viewers"].as_u64().unwrap_or(0) > 0);
    let s = c.ask(&json!({"op": "status", "replica": summary})).await?;
    if let Some(v) = s["update"].as_str() {
        crate::update::request(&shared.data, v);
    }
    // 4. copies.
    let plan: Vec<Value> = host_op(to_host, json!({"op": "_replica-plan"})).await?["versions"].as_array().cloned().unwrap_or_default();
    while let Some(p) = shared.next(&plan) {
        let vid = p["id"].as_str().unwrap_or("").to_owned();
        if !vid.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') || vid.is_empty() {
            continue;
        }
        {
            let mut st = shared.st.lock().unwrap();
            Shared::set(&mut st, &vid, |x| x["state"] = json!("making"));
        }
        let r = match make(shared, c, &p).await {
            Ok(tmp) => shared.place(&vid, &tmp),
            Err(e) => Err(e),
        };
        shared.st.lock().unwrap().progress.remove(&vid);
        match r {
            Ok(bytes) => {
                let mut st = shared.st.lock().unwrap();
                st.backoff.remove(&vid);
                Shared::set(&mut st, &vid, |x| {
                    x["state"] = json!("ready");
                    x["bytes"] = json!(bytes);
                    x["quality"] = json!(shared.quality);
                    if let Some(o) = x.as_object_mut() { o.remove("error"); o.remove("tried"); }
                });
                shared.save(&st);
            }
            Err(e) => {
                if let Some(l) = shared.failed(&vid, &e) {
                    log(l);
                }
                break; // the main may be gone: no more copies this round
            }
        }
        let _ = host_op(to_host, json!({"op": "reload"})).await; // ready.json is there: browsers can play it
    }
    Ok(())
}

/// One version's copies from the main, complete, in a temp folder (`place` puts it in copies/<V>).
async fn make(shared: &Shared, c: &mut Client, p: &Value) -> Result<PathBuf> {
    let vid = p["id"].as_str().unwrap_or("");
    let tmp = shared.copies().join(format!("{vid}.replica"));
    let _ = tokio::fs::remove_dir_all(&tmp).await;
    tokio::fs::create_dir_all(&tmp).await?;
    let base = format!("copies/{vid}");
    // The main's own description of its copies: ready.json (made there), else the manifest's (pushed).
    let mut main_ready = Vec::new();
    let mut info = match c.get(&format!("{base}/ready.json"), None, &mut main_ready).await? {
        Some(_) => serde_json::from_slice::<Value>(&main_ready).unwrap_or_default(),
        None => json!({"renditions": p["version"]["renditions"], "probe": p["version"]}),
    };
    let renditions: Vec<String> = info["renditions"].as_array().into_iter().flatten().filter_map(|r| r.as_str().map(str::to_owned))
        .filter(|r| !r.is_empty() && r.bytes().all(|b| b.is_ascii_alphanumeric())).collect();
    if renditions.is_empty() && p["kind"] != "image" && p["kind"] != "document" {
        anyhow::bail!("the main has no copy of it yet");
    }
    let have = copy_dir(c, &base, &tmp, &renditions, &info, &shared.quality, p["kind"].as_str().unwrap_or(""), &shared.data, vid).await?;
    info["renditions"] = json!(have);
    for lid in p["wm"].as_array().into_iter().flatten().filter_map(Value::as_str).filter(|l| l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')) {
        let d = tmp.join(format!("wm-{lid}"));
        tokio::fs::create_dir_all(&d).await?;
        let wm = copy_dir(c, &format!("{base}/wm-{lid}"), &d, &renditions, &info, &shared.quality, p["kind"].as_str().unwrap_or(""), &shared.data, vid).await?;
        std::fs::write(d.join("ready.json"), json!({"renditions": wm, "probe": info["probe"]}).to_string())?;
    }
    if info["sha256"].is_null() {
        info["sha256"] = p["version"]["sha256"].clone();
    }
    std::fs::write(tmp.join("ready.json"), json!({"renditions": info["renditions"], "probe": info["probe"], "sha256": info["sha256"]}).to_string())?;
    Ok(tmp)
}

async fn fetch_to(c: &mut Client, path: &str, dest: &Path) -> Result<bool> {
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let mut f = tokio::fs::File::create(dest).await?;
    let got = c.get(path, None, &mut f).await?;
    if got.is_none() {
        drop(f);
        let _ = tokio::fs::remove_file(dest).await;
    }
    Ok(got.is_some())
}

/// A rendition folder byte for byte: index.json, index.m3u8 and the files the index names.
async fn copy_rendition(c: &mut Client, from: &str, to: &Path) -> Result<()> {
    anyhow::ensure!(fetch_to(c, &format!("{from}/index.json"), &to.join("index.json")).await?, "no index.json in {from}");
    let idx: Value = serde_json::from_slice(&std::fs::read(to.join("index.json"))?)?;
    let _ = fetch_to(c, &format!("{from}/index.m3u8"), &to.join("index.m3u8")).await;
    let mut files: Vec<String> = vec![];
    for part in std::iter::once(&idx["init"]).chain(idx["segments"].as_array().into_iter().flatten()) {
        if let Some(f) = part["file"].as_str().filter(|f| crate::upload_root::name_ok(f)) {
            if !files.iter().any(|x| x == f) {
                files.push(f.to_owned());
            }
        }
    }
    for f in files {
        anyhow::ensure!(fetch_to(c, &format!("{from}/{f}"), &to.join(&f)).await?, "missing {from}/{f}");
    }
    Ok(())
}

/// The pictures of one copies folder (plain or wm-<link>): renditions per quality, stills, extras.
#[allow(clippy::too_many_arguments)]
async fn copy_dir(c: &mut Client, from: &str, to: &Path, renditions: &[String], info: &Value, quality: &str, kind: &str, data: &Path, vid: &str) -> Result<Vec<String>> {
    for f in ["poster.jpg", "strip.jpg", "image.jpg", "waveform.json", "captions.vtt", "transcript.json"] {
        fetch_to(c, &format!("{from}/{f}"), &to.join(f)).await?;
    }
    for n in 1..=info["probe"]["pages"].as_u64().unwrap_or(0).min(500) {
        fetch_to(c, &format!("{from}/pages/{n}.jpg"), &to.join("pages").join(format!("{n}.jpg"))).await?;
    }
    let mut have = vec![];
    if renditions.iter().any(|r| r == "a") && kind == "audio" {
        copy_rendition(c, &format!("{from}/a"), &to.join("a")).await?;
        have.push("a".to_owned());
    }
    let video: Vec<&String> = renditions.iter().filter(|r| r.as_str() != "a").collect();
    if kind != "video" || video.is_empty() {
        return Ok(have);
    }
    if quality == "same" {
        for r in video {
            copy_rendition(c, &format!("{from}/{r}"), &to.join(r)).await?;
            have.push(r.clone());
        }
        return Ok(have);
    }
    // The main's highest video rendition, as one MP4 in /tmp, transcoded to ours, then deleted.
    let top = video.iter().max_by_key(|r| r.parse::<u64>().unwrap_or(0)).unwrap();
    let mut ib = Vec::new();
    c.get(&format!("{from}/{top}/index.json"), None, &mut ib).await?.context("no index.json")?;
    let idx: Value = serde_json::from_slice(&ib)?;
    let src = std::env::temp_dir().join(format!("pluck-replica-{vid}-{}.mp4", host::uuid()));
    let r = async {
        let mut f = tokio::fs::File::create(&src).await?;
        for part in std::iter::once(&idx["init"]).chain(idx["segments"].as_array().into_iter().flatten()) {
            let file = part["file"].as_str().filter(|f| crate::upload_root::name_ok(f)).context("bad index")?;
            let (o, n) = (part["offset"].as_u64().unwrap_or(0), part["length"].as_u64().unwrap_or(0));
            c.get(&format!("{from}/{top}/{file}"), Some((o, n)), &mut f).await?.context("segment missing on the main")?;
        }
        tokio::io::AsyncWriteExt::flush(&mut f).await?;
        let mut probe = info["probe"].clone();
        for k in ["width", "height", "fpsNum", "fpsDen", "duration"] {
            if probe[k].is_null() {
                probe[k] = idx[k].clone();
            }
        }
        if probe["hasAudio"].is_null() {
            probe["hasAudio"] = json!(idx["codecs"].as_str().is_some_and(|c| c.contains("mp4a")));
        }
        let name = crate::copies::quality(quality).context("bad quality")?.0;
        crate::copies::replica_rendition(&src, &to.join(name), quality, &probe).await?;
        anyhow::Ok(name.to_owned())
    }.await;
    let _ = tokio::fs::remove_file(&src).await;
    let _ = data;
    have.push(r?);
    // The main's 360 copy as it is (no transcode, ~0.5 Mbit/s): slow links still play from a backup.
    if video.iter().any(|r| r.as_str() == "360") && !have.iter().any(|r| r == "360") {
        copy_rendition(c, &format!("{from}/360"), &to.join("360")).await?;
        have.push("360".to_owned());
    }
    Ok(have)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared(max: u64) -> Arc<Shared> {
        let d = std::env::temp_dir().join(format!("pluck-replica-{}", host::uuid()));
        std::fs::create_dir_all(d.join("bundle/copies")).unwrap();
        Shared::load(&d, max, "1080-low")
    }

    fn ready(s: &Shared, vid: &str, bytes: usize, viewed: Option<&str>) {
        std::fs::create_dir_all(s.copies().join(vid)).unwrap();
        std::fs::write(s.copies().join(vid).join("media.m4s"), vec![0u8; bytes]).unwrap();
        let mut st = s.st.lock().unwrap();
        Shared::set(&mut st, vid, |x| {
            x["state"] = json!("ready");
            if let Some(v) = viewed { x["lastViewed"] = json!(v) }
        });
    }

    #[test]
    fn eviction_goes_by_last_view_and_spares_busy_and_recent_ones() {
        let s = shared(2500);
        ready(&s, "A", 1000, Some("2026-01-01T00:00:00Z"));
        ready(&s, "B", 1000, Some("2025-01-01T00:00:00Z"));
        ready(&s, "C", 1000, Some(&now_iso())); // viewed just now
        ready(&s, "D", 1000, None);             // never viewed: oldest of all…
        s.fetch_start("D");                     // …but a fetch is in flight
        assert_eq!(s.evict(), ["B", "A"], "least recently viewed first; C (recent) and D (in flight) stay");
        assert_eq!(s.summary()["versions"]["evicted"], 2);
        s.fetch_end("D");
        assert!(s.evict().is_empty(), "fits now");
    }

    fn tmp_copy(s: &Shared, vid: &str, bytes: usize) -> PathBuf {
        let t = s.copies().join(format!("{vid}.replica"));
        std::fs::create_dir_all(&t).unwrap();
        std::fs::write(t.join("media.m4s"), vec![0u8; bytes]).unwrap();
        t
    }

    #[test]
    fn a_new_copy_evicts_only_once_finished_and_never_the_last_one_for_nothing() {
        // A failed copy (its half-made folder included) evicts nothing.
        let s = shared(1500);
        ready(&s, "A", 1000, Some("2026-01-01T00:00:00Z"));
        tmp_copy(&s, "B", 900);
        assert!(s.failed("B", &anyhow::anyhow!("Broken pipe")).is_some());
        assert!(!s.copies().join("B.replica").exists(), "the half-made copy goes");
        assert!(s.evict().is_empty() && s.copies().join("A/media.m4s").exists(), "A stays");
        // Finished: A (old, not viewed lately) makes room for B.
        let t = tmp_copy(&s, "B", 900);
        assert_eq!(s.place("B", &t).unwrap(), 900);
        assert_eq!(s.st.lock().unwrap().v["versions"]["A"]["state"], "evicted");
        Shared::set(&mut s.st.lock().unwrap(), "B", |x| x["state"] = json!("ready"));
        // C doesn't fit next to B while B is being watched: B stays, C is "over cap".
        s.fetch_start("B");
        let t = tmp_copy(&s, "C", 900);
        let e = s.place("C", &t).unwrap_err();
        assert!(format!("{e}").starts_with("over cap"), "{e}");
        assert!(!t.exists() && !s.copies().join("C").exists() && s.copies().join("B/media.m4s").exists());
        assert_eq!(s.st.lock().unwrap().v["versions"]["B"]["state"], "ready");
        s.fetch_end("B");
        // Watched lately but not now: B goes as a last resort for C (a viewer asked for C, say).
        let t = tmp_copy(&s, "C", 900);
        assert_eq!(s.place("C", &t).unwrap(), 900);
        assert_eq!(s.st.lock().unwrap().v["versions"]["B"]["state"], "evicted");
        Shared::set(&mut s.st.lock().unwrap(), "C", |x| x["state"] = json!("ready"));
        // Bigger than the whole cap: over cap even with everything else gone, and B stays.
        let t = tmp_copy(&s, "D", 2000);
        assert!(s.place("D", &t).is_err());
        assert_eq!(s.st.lock().unwrap().v["versions"]["C"]["state"], "ready");
    }

    #[test]
    fn failed_copies_back_off_and_repeats_are_logged_sparingly() {
        let s = shared(1 << 30);
        let plan = vec![json!({"id": "V1"})];
        let e = anyhow::anyhow!("Broken pipe");
        let lines: Vec<Option<String>> = (0..5).map(|_| s.failed("V1", &e)).collect();
        assert_eq!(lines.iter().flatten().count(), 3, "1st, 2nd, 4th: {lines:?}");
        assert!(lines[3].as_deref().unwrap().ends_with("(repeated 4 times)"));
        assert_eq!(s.st.lock().unwrap().backoff["V1"].1, Duration::from_secs(16), "1, 2, 4, 8, 16 s");
        for _ in 0..20 { s.failed("V1", &e); }
        assert_eq!(s.st.lock().unwrap().backoff["V1"].1, BACKOFF_MAX, "at most 5 min");
        assert!(s.next(&plan).is_none(), "waiting");
        s.st.lock().unwrap().last_ok = Some(Instant::now());
        s.recall("V1");
        assert!(s.next(&plan).is_none(), "a recall doesn't skip the wait");
        s.st.lock().unwrap().backoff.get_mut("V1").unwrap().0 = Instant::now();
        assert_eq!(s.next(&plan).unwrap()["id"], "V1", "tried again once the wait is over");
        let mut r = Repeat::default();
        assert!(r.note("a".into()).is_some() && r.note("a".into()).is_some() && r.note("a".into()).is_none() && r.note("b".into()).is_some());
    }

    #[test]
    fn recall_while_the_main_is_reachable_offline_otherwise() {
        let s = shared(1 << 30);
        assert_eq!(s.recall("V1"), None, "no sync yet: offline");
        s.st.lock().unwrap().last_ok = Some(Instant::now());
        assert_eq!(s.recall("V1"), Some(0.0));
        let plan = vec![json!({"id": "V0"}), json!({"id": "V1"})];
        assert_eq!(s.next(&plan).unwrap()["id"], "V1", "a recall jumps the queue");
        assert_eq!(s.next(&plan).unwrap()["id"], "V0", "then the plan, newest first");
        s.st.lock().unwrap().last_ok = Some(Instant::now() - Duration::from_secs(200));
        assert_eq!(s.recall("V0"), None, "last sync over 3 min ago");
    }

    #[test]
    fn an_older_version_is_made_only_when_recalled() {
        let s = shared(1 << 30);
        let plan = vec![json!({"id": "V2", "current": true}), json!({"id": "V1", "current": false})];
        assert_eq!(s.next(&plan).unwrap()["id"], "V2");
        Shared::set(&mut s.st.lock().unwrap(), "V2", |x| x["state"] = json!("ready"));
        assert!(s.next(&plan).is_none(), "older versions don't fill");
        s.st.lock().unwrap().last_ok = Some(Instant::now());
        assert_eq!(s.recall("V1"), Some(0.0));
        assert_eq!(s.next(&plan).unwrap()["id"], "V1", "but a recall makes one");
    }

    #[test]
    fn sizes_and_links() {
        assert_eq!(parse_size("50G"), Some(50 << 30));
        assert_eq!(parse_size("1024"), Some(1024));
        assert!(parse_size("x").is_none());
        let l = |v: Value| format!("pluck://edit-anywhere/join?i={}", crate::keys::b64(v.to_string().as_bytes()));
        let good = json!({"v": 3, "k": "nas", "o": "a".repeat(64), "c": "ABCD-EFGH-JKLM", "e": 4_000_000_000u64, "fp": "AA", "role": "backup"});
        assert!(parse_link(&l(good.clone())).is_ok());
        let mut mac = good.clone();
        mac["role"] = json!("mac");
        assert!(parse_link(&l(mac)).is_err(), "a Mac invitation");
        let mut old = good.clone();
        old["e"] = json!(1);
        assert!(parse_link(&l(old)).is_err(), "expired");
    }
}
