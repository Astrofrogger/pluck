// Remote access over iroh (spec §13.2): the host runs Helpers/PluckIroh's `pluck-iroh` as a child
// and plays Pluck's part in it. Office mode: each iroh stream from a paired Mac arrives on a
// loopback listener of the sync endpoint; the connection is bound to its Mac by the local port
// pluck-iroh reports ({"stream":{"peer","port"}}) before any of its bytes. Home mode (a backup):
// a loopback address that leads to the main host.
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{Context, Result};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Command,
    sync::{Notify, mpsc, watch},
};

use crate::{log, report};

const BACKOFF: [u64; 4] = [2, 5, 15, 60];
const BIND_WINDOW: Duration = Duration::from_secs(2);

/// pluck-iroh: --iroh-bin, else next to this executable, else /usr/local/bin.
pub fn binary(flag: Option<String>) -> PathBuf {
    if let Some(b) = flag {
        return b.into();
    }
    let next = std::env::current_exe().ok().and_then(|e| Some(e.parent()?.join("pluck-iroh"))).filter(|p| p.is_file());
    next.unwrap_or_else(|| "/usr/local/bin/pluck-iroh".into())
}

/// Stream reports: local port → (node, when). A loopback connection claims its port once.
#[derive(Clone, Default)]
pub struct Streams(Arc<(Mutex<HashMap<u16, (String, Instant)>>, Notify)>);

impl Streams {
    pub fn report(&self, port: u16, node: String) {
        let mut m = self.0.0.lock().unwrap();
        m.retain(|_, (_, t)| t.elapsed() < BIND_WINDOW * 5);
        m.insert(port, (node, Instant::now()));
        self.0.1.notify_waiters();
    }

    /// The node whose stream this connection (by its remote port) is: waits up to 2 s for the report.
    pub async fn claim(&self, port: u16) -> Option<String> {
        let until = Instant::now() + BIND_WINDOW;
        loop {
            let wait = self.0.1.notified();
            if let Some((node, at)) = self.0.0.lock().unwrap().remove(&port) {
                return (at.elapsed() < BIND_WINDOW).then_some(node);
            }
            let left = until.checked_duration_since(Instant::now())?;
            let _ = tokio::time::timeout(left, wait).await;
        }
    }
}

/// Settings for one child run (office or home).
pub struct Child {
    pub bin: PathBuf,
    pub settings: Value,
}

/// Runs pluck-iroh for ever, restarting it with backoff 2, 5, 15, 60 s. Lines on `cmds` go to its
/// stdin (and `first` again after each restart); every stdout report goes to `on`.
pub async fn supervise(c: Child, mut cmds: mpsc::UnboundedReceiver<Value>, first: impl Fn() -> Vec<Value>, on: impl Fn(Value)) {
    let mut fails = 0usize;
    loop {
        let started = Instant::now();
        let r: Result<()> = async {
            let mut child = Command::new(&c.bin).stdin(Stdio::piped()).stdout(Stdio::piped()).kill_on_drop(true).spawn()
                .with_context(|| format!("can't run {}", c.bin.display()))?;
            let mut stdin = child.stdin.take().unwrap();
            stdin.write_all(format!("{}\n", c.settings).as_bytes()).await?;
            for v in first() {
                stdin.write_all(format!("{v}\n").as_bytes()).await?;
            }
            let mut out = BufReader::new(child.stdout.take().unwrap()).lines();
            loop {
                tokio::select! {
                    l = out.next_line() => match l? {
                        Some(l) => if let Ok(v) = serde_json::from_str::<Value>(&l) { on(v) },
                        None => break,
                    },
                    Some(v) = cmds.recv() => stdin.write_all(format!("{v}\n").as_bytes()).await?,
                }
            }
            let st = child.wait().await?;
            anyhow::bail!("pluck-iroh exited ({st})")
        }.await;
        if let Err(e) = r {
            log(format!("iroh: {e:#}"));
        }
        if started.elapsed() > Duration::from_secs(300) {
            fails = 0;
        }
        let wait = BACKOFF[fails.min(BACKOFF.len() - 1)];
        fails += 1;
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

/// Tests (PLUCK_IROH_LOCAL): a backup's Macs-only side's addresses, for its status.
pub static OFFICE_ADDRS: Mutex<Value> = Mutex::new(Value::Null);

fn local() -> bool {
    std::env::var("PLUCK_IROH_LOCAL").is_ok_and(|v| v == "1")
}

/// The office side on a main host: starts the loopback listener and the child. Returns the
/// listener (for sync::accept_loop), the stream table and a watch of the node id.
/// `key`: the key file's name in the data folder ("iroh-key"; a backup's second, Macs-only side "iroh-office-key").
pub async fn office(data: &Path, bin: PathBuf, relay: Option<String>, devices: Arc<crate::devices::Devices>, key: &str)
                    -> Result<(tokio::net::TcpListener, Streams, watch::Receiver<Option<String>>)> {
    let main = key == "iroh-key";
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    let streams = Streams::default();
    let (id_tx, id_rx) = watch::channel(None);
    let (tx, rx) = mpsc::unbounded_channel();
    *devices.iroh.lock().unwrap() = Some(tx);
    let mut settings = json!({"mode": "office", "keyFile": data.join(key).to_string_lossy(), "port": port, "allow": devices.allow()});
    if let Some(r) = relay {
        settings["relay"] = json!(r);
    }
    if local() {
        settings["local"] = json!(true);
    }
    let (st, d2, data) = (streams.clone(), devices.clone(), data.to_path_buf());
    tokio::spawn(supervise(Child { bin, settings }, rx, move || vec![json!({"allow": d2.allow()})], move |v| {
        if let Some(s) = v.get("stream") {
            if let (Some(p), Some(n)) = (s["port"].as_u64().and_then(|p| u16::try_from(p).ok()), s["peer"].as_str()) {
                st.report(p, n.to_owned());
            }
        } else if v["state"] == "running" && !main {
            // A backup's Macs-only side: only its id, for its status (tests: no discovery, so its loopback addresses too).
            if local() {
                *OFFICE_ADDRS.lock().unwrap() = json!(v["addrs"].as_array().into_iter().flatten().filter_map(|x| x.as_str())
                    .map(|x| x.replace("0.0.0.0:", "127.0.0.1:").replace("[::]:", "[::1]:")).collect::<Vec<_>>());
            }
            let _ = id_tx.send(v["id"].as_str().map(str::to_owned));
        } else if v["state"] == "running" {
            let id = v["id"].as_str().unwrap_or("").to_owned();
            let _ = std::fs::write(data.join("iroh-id"), format!("{id}\n"));
            let line = format!("pluck-host-iroh:{id}");
            let pairing = std::fs::read_to_string(data.join("pairing.txt")).unwrap_or_default();
            let kept: String = pairing.lines().filter(|l| !l.starts_with("pluck-host-iroh:")).map(|l| format!("{l}\n")).collect();
            let _ = std::fs::write(data.join("pairing.txt"), format!("{kept}{line}\n"));
            report(json!({"host": {"iroh": {"id": id, "relay": v["relay"], "addrs": v["addrs"], "listen": format!("127.0.0.1:{port}")}}}));
            println!("{line}");
            let mut l = devices.link.lock().unwrap();
            l["o"] = json!(id);
            if let Some(r) = v["relay"].as_str() {
                l["r"] = json!(r);
            }
            if local() {
                // Tests: no discovery, so the link carries the (loopback) addresses.
                let a: Vec<String> = v["addrs"].as_array().into_iter().flatten().filter_map(|x| x.as_str())
                    .map(|x| x.replace("0.0.0.0:", "127.0.0.1:").replace("[::]:", "[::1]:")).collect();
                l["a"] = json!(a);
            }
            let _ = id_tx.send(Some(id));
        } else if v.get("error").is_some() || v.get("conn").is_some() || v.get("refused").is_some() {
            log(format!("iroh: {v}"));
        }
    }));
    Ok((listener, streams, id_rx))
}

/// The home side (a backup reaching its main): the loopback address pluck-iroh listens on, and
/// this host's own node id, each as it becomes known (again after a restart).
pub fn home(data: &Path, bin: PathBuf, office: &str, relay: Option<&str>, addrs: &Value)
            -> (watch::Receiver<Option<String>>, watch::Receiver<Option<String>>) {
    let mut settings = json!({"mode": "home", "keyFile": data.join("iroh-key").to_string_lossy(), "port": 1, "office": office});
    if let Some(r) = relay {
        settings["officeRelay"] = json!(r);
    }
    if local() {
        settings["local"] = json!(true);
        settings["officeAddrs"] = addrs.clone();
    }
    let (listen_tx, listen_rx) = watch::channel(None);
    let (id_tx, id_rx) = watch::channel(None);
    let (_keep, rx) = mpsc::unbounded_channel();
    std::mem::forget(_keep); // home mode quits when its stdin closes: keep the sender alive
    let data = data.to_path_buf();
    tokio::spawn(supervise(Child { bin, settings }, rx, Vec::new, move |v| {
        if v["state"] == "running" {
            let id = v["id"].as_str().unwrap_or("").to_owned();
            let _ = std::fs::write(data.join("iroh-id"), format!("{id}\n"));
            let _ = id_tx.send(Some(id));
        } else if let Some(l) = v["listen"].as_str() {
            let _ = listen_tx.send(Some(l.to_owned()));
        } else if v.get("error").is_some() || v.get("refused").is_some() {
            log(format!("iroh: {v}"));
        }
    }));
    (listen_rx, id_rx)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_connection_claims_only_a_fresh_report_for_its_port() {
        let s = Streams::default();
        s.report(5000, "n1".into());
        assert_eq!(s.claim(5000).await.as_deref(), Some("n1"));
        assert_eq!(s.claim(5000).await, None, "once");
        let s2 = s.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            s2.report(5001, "n2".into());
        });
        assert_eq!(s.claim(5001).await.as_deref(), Some("n2"), "a report arriving just after the connection");
        let t = Instant::now();
        assert_eq!(s.claim(5002).await, None, "no report: refused after 2 s");
        assert!(t.elapsed() >= Duration::from_millis(1900));
    }
}
