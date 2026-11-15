// Round 3 end to end on loopback (spec §13.18, R2): the real pluck-review host with two
// pluck-iroh in local mode (office in the host, home in the test or in a backup host) carrying
// sync sessions; pairing, device keys and the stream binding; a backup host pairing, syncing
// and pushing its own comments; a backup standing by while the main holds a room.
use std::{path::PathBuf, process::Stdio, time::Duration};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    process::{Child, Command},
    sync::mpsc,
};
use tokio_tungstenite::tungstenite::Message;

const T: Duration = Duration::from_secs(60);

fn iroh_bin() -> Option<PathBuf> {
    let base = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../PluckIroh/target");
    std::env::var("PLUCK_IROH_BIN").ok().map(PathBuf::from).or_else(|| ["release", "debug"].iter().map(|d| base.join(d).join("pluck-iroh")).find(|p| p.is_file()))
}

fn tmp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("pluck-r3-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

struct Proc {
    _child: Child,
    out: mpsc::UnboundedReceiver<Value>,
}

impl Proc {
    fn start(bin: &std::path::Path, args: &[&str], env: &[(&str, &str)], stdin: Option<Value>) -> Proc {
        let mut c = Command::new(bin);
        c.args(args).stdin(Stdio::piped()).stdout(Stdio::piped()).kill_on_drop(true).env("PLUCK_IROH_LOCAL", "1")
            .env("PLUCK_STANDBY_SECS", "1").env("PLUCK_HEALTH_FILE", std::env::temp_dir().join(format!("pluck-r3-health-{}", std::process::id())));
        for (k, v) in env {
            c.env(k, v);
        }
        let mut child = c.spawn().unwrap();
        let mut sin = child.stdin.take().unwrap();
        if let Some(s) = stdin {
            tokio::spawn(async move {
                sin.write_all(format!("{s}\n").as_bytes()).await.unwrap();
                std::future::pending::<()>().await; // keep stdin open
                drop(sin);
            });
        } else {
            std::mem::forget(sin);
        }
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let (tx, out) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Ok(Some(l)) = lines.next_line().await {
                if std::env::var("PLUCK_REVIEW_TEST_LOG").is_ok() { eprintln!("out: {l}") }
                if let Ok(v) = serde_json::from_str::<Value>(&l) {
                    let _ = tx.send(v);
                }
            }
        });
        Proc { _child: child, out }
    }

    async fn wait(&mut self, what: impl Fn(&Value) -> bool) -> Value {
        loop {
            let v = tokio::time::timeout(T, self.out.recv()).await.expect("silent").expect("exited");
            if what(&v) {
                return v;
            }
        }
    }
}

async fn ctl(data: &std::path::Path, op: Value) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_pluck-review")).arg("--ctl").arg(data).arg(op.to_string()).output().await.unwrap();
    serde_json::from_slice(&out.stdout).unwrap_or(Value::Null)
}

/// A signaling stub that just registers whoever comes (no rooms are needed here).
async fn quiet_signal() -> String {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let a = l.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (tcp, _) = l.accept().await.unwrap();
            tokio::spawn(async move {
                let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { return };
                while let Some(Ok(m)) = ws.next().await {
                    if let Message::Text(t) = m {
                        let v: Value = serde_json::from_str(&t).unwrap_or_default();
                        if v["t"] == "mac-register" {
                            let _ = ws.send(Message::text(json!({"t": "registered", "peers": []}).to_string())).await;
                        }
                    }
                }
            });
        }
    });
    format!("ws://{a}/signal")
}

mod client {
    // A tiny pinned TLS client for the test (the host's own sync::Client isn't a library).
    use super::*;
    use std::sync::Arc;
    use tokio_rustls::rustls;

    #[derive(Debug)]
    struct Any(Arc<rustls::crypto::CryptoProvider>);
    impl rustls::client::danger::ServerCertVerifier for Any {
        fn verify_server_cert(&self, _: &rustls::pki_types::CertificateDer<'_>, _: &[rustls::pki_types::CertificateDer<'_>], _: &rustls::pki_types::ServerName<'_>, _: &[u8], _: rustls::pki_types::UnixTime) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        }
        fn verify_tls12_signature(&self, m: &[u8], c: &rustls::pki_types::CertificateDer<'_>, d: &rustls::DigitallySignedStruct) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(m, c, d, &self.0.signature_verification_algorithms)
        }
        fn verify_tls13_signature(&self, m: &[u8], c: &rustls::pki_types::CertificateDer<'_>, d: &rustls::DigitallySignedStruct) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(m, c, d, &self.0.signature_verification_algorithms)
        }
        fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
            self.0.signature_verification_algorithms.supported_schemes()
        }
    }

    pub struct C(pub BufReader<tokio::io::ReadHalf<tokio_rustls::client::TlsStream<tokio::net::TcpStream>>>, pub tokio::io::WriteHalf<tokio_rustls::client::TlsStream<tokio::net::TcpStream>>);

    impl C {
        pub async fn open(addr: &str) -> std::io::Result<C> {
            let p = Arc::new(rustls::crypto::ring::default_provider());
            let cfg = rustls::ClientConfig::builder_with_provider(p.clone()).with_protocol_versions(&[&rustls::version::TLS13]).unwrap()
                .dangerous().with_custom_certificate_verifier(Arc::new(Any(p))).with_no_client_auth();
            let tcp = tokio::net::TcpStream::connect(addr).await?;
            let tls = tokio_rustls::TlsConnector::from(Arc::new(cfg)).connect(rustls::pki_types::ServerName::try_from("x").unwrap(), tcp).await?;
            let (r, w) = tokio::io::split(tls);
            Ok(C(BufReader::new(r), w))
        }

        /// One line out, one line back (None: closed).
        pub async fn ask(&mut self, v: Value) -> Option<Value> {
            self.1.write_all(format!("{v}\n").as_bytes()).await.ok()?;
            let mut l = String::new();
            match tokio::time::timeout(Duration::from_secs(20), self.0.read_line(&mut l)).await {
                Ok(Ok(n)) if n > 0 => serde_json::from_str(&l).ok(),
                _ => None,
            }
        }
    }
}

fn link_json(link: &str) -> Value {
    use base64::Engine;
    let i = link.split("i=").nth(1).unwrap();
    serde_json::from_slice(&base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(i).unwrap()).unwrap()
}

/// Pairing a Mac over iroh: the code once, then its device key; a connection that didn't come
/// through pluck-iroh is refused; removing the device cuts it.
#[tokio::test(flavor = "multi_thread")]
async fn sync_over_iroh_with_pairing_and_device_keys() {
    let Some(iroh) = iroh_bin() else { return eprintln!("pluck-iroh not built: skipped") };
    let _ = tokio_rustls::rustls::crypto::ring::default_provider().install_default();
    let data = tmp("iroh");
    let sig = quiet_signal().await;
    let bin = std::path::Path::new(env!("CARGO_BIN_EXE_pluck-review"));
    let mut host = Proc::start(bin, &["--host", data.to_str().unwrap(), "--signal", &sig, "--local", "--iroh", "--iroh-bin", iroh.to_str().unwrap(), "--name", "Office NAS"], &[], None);
    let info = host.wait(|v| v["host"]["iroh"]["id"].is_string()).await["host"]["iroh"].clone();
    let loopback = info["listen"].as_str().unwrap().to_owned();
    assert_eq!(std::fs::read_to_string(data.join("iroh-id")).unwrap().trim(), info["id"].as_str().unwrap());

    // Not through pluck-iroh: refused (no stream report for this port).
    let mut direct = client::C::open(&loopback).await;
    if let Ok(c) = direct.as_mut() {
        assert!(c.ask(json!({"key": "x"})).await.is_none(), "closed");
    }

    let inv = ctl(&data, json!({"op": "invite", "role": "mac"})).await;
    let l = link_json(inv["link"].as_str().unwrap());
    assert_eq!((l["k"].clone(), l["o"].clone(), l["n"].clone()), (json!("nas"), info["id"].clone(), json!("Office NAS")));
    // The "Mac": pluck-iroh in home mode towards the host.
    let key = data.join("mac-iroh-key");
    let mut home = Proc::start(&iroh, &[], &[], Some(json!({"mode": "home", "keyFile": key, "port": 1, "office": l["o"], "officeAddrs": l["a"], "local": true})));
    let mac_node = home.wait(|v| v["state"] == "running").await["id"].as_str().unwrap().to_owned();
    let listen = home.wait(|v| v["listen"].is_string()).await["listen"].as_str().unwrap().to_owned();
    let mut c = client::C::open(&listen).await.unwrap();
    let h = c.ask(json!({"pair": inv["code"], "name": "MacBook Pro", "node": mac_node, "role": "mac", "protocol": 3})).await.unwrap();
    assert_eq!((h["ok"].clone(), h["protocol"].clone(), h["host"]["name"].clone()), (json!(true), json!(3), json!("Office NAS")));
    let (dev, dkey) = (h["device"].as_str().unwrap().to_owned(), h["key"].as_str().unwrap().to_owned());
    assert!(c.ask(json!({"op": "roots"})).await.unwrap()["roots"].is_array(), "a sync session over iroh");
    drop(c);
    // The code is single use; the device key works.
    let mut c = client::C::open(&listen).await.unwrap();
    assert!(c.ask(json!({"pair": inv["code"], "name": "Other", "node": mac_node, "role": "mac"})).await.is_none(), "code used up");
    let mut c = client::C::open(&listen).await.unwrap();
    assert_eq!(c.ask(json!({"device": dev, "key": dkey, "protocol": 3})).await.unwrap()["device"], dev.as_str());
    let devs = c.ask(json!({"op": "devices"})).await.unwrap();
    assert_eq!((devs["devices"][0]["node"].clone(), devs["devices"][0]["via"].clone()), (json!(mac_node), json!("iroh")));
    assert!(devs["devices"][0].get("keyHash").is_none());
    // Removed: this session ends, and iroh lets it in no more.
    assert_eq!(ctl(&data, json!({"op": "device-remove", "id": dev})).await["ok"], true);
    assert!(c.ask(json!({"op": "devices"})).await.is_none(), "cut");
    let _ = std::fs::remove_dir_all(data);
}

/// A backup host pairs with its main over iroh, gets the main's projects and comments, and its
/// own comment reaches the main once (a second round adds nothing).
#[tokio::test(flavor = "multi_thread")]
async fn backup_pairs_syncs_and_pushes_its_own_comments() {
    let Some(iroh) = iroh_bin() else { return eprintln!("pluck-iroh not built: skipped") };
    let _ = tokio_rustls::rustls::crypto::ring::default_provider().install_default();
    let (main_dir, backup_dir) = (tmp("main"), tmp("backup"));
    let sig = quiet_signal().await;
    let bin = std::path::Path::new(env!("CARGO_BIN_EXE_pluck-review"));
    let mut main = Proc::start(bin, &["--host", main_dir.to_str().unwrap(), "--signal", &sig, "--local", "--iroh", "--iroh-bin", iroh.to_str().unwrap(), "--name", "Office NAS"], &[], None);
    main.wait(|v| v["host"]["iroh"]["id"].is_string()).await;
    let m = json!({"format": 1, "links": [], "projects": [{"id": "P1", "name": "Spring", "rev": 1, "at": "2026-11-16T10:00:00Z", "by": "mac", "folders": [],
        "assets": [{"id": "A1", "name": "Hero", "kind": "video", "folder": null, "rev": 1, "at": "2026-11-16T10:00:00Z", "by": "mac", "versions": []}]}]});
    assert_eq!(ctl(&main_dir, json!({"op": "publish", "merge": true, "manifest": m})).await["ok"], true);
    ctl(&main_dir, json!({"op": "append", "entries": [{"comment": {"id": "C1", "asset": "A1", "version": "V1", "text": "from the office", "rev": 1, "replies": []}}]})).await;
    let inv = ctl(&main_dir, json!({"op": "invite", "role": "backup"})).await;
    let mut backup = Proc::start(bin, &["--host", backup_dir.to_str().unwrap(), "--signal", &sig, "--local", "--backup", "--iroh-bin", iroh.to_str().unwrap(),
        "--max-storage", "1G", "--quality", "540-low", "--name", "Backup"], &[("PLUCK_MAIN_LINK", inv["link"].as_str().unwrap())], None);
    assert_eq!(backup.wait(|v| v["backup"]["paired"].is_string()).await["backup"]["paired"], "Office NAS");
    let mj: Value = serde_json::from_slice(&std::fs::read(backup_dir.join("main.json")).unwrap()).unwrap();
    assert!(mj["device"].is_string() && mj["key"].is_string() && mj["pin"].is_string());
    // The first round brings the project and the comment.
    let until = tokio::time::Instant::now() + T;
    loop {
        let man = ctl(&backup_dir, json!({"op": "manifest"})).await;
        let pulled = ctl(&backup_dir, json!({"op": "pull", "since": 0})).await;
        let got = man["projects"][0]["assets"][0]["id"] == "A1" && pulled["entries"].as_array().is_some_and(|e| e.iter().any(|e| e["comment"]["id"] == "C1" && e["main"].is_u64()));
        if got { break }
        assert!(tokio::time::Instant::now() < until, "the backup never synced: {man} {pulled}");
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    assert_eq!(std::fs::read_to_string(backup_dir.join("main-protocol")).unwrap().trim(), "3");
    // A comment made on the backup reaches the main (the backup's next round: restart it to skip the 60 s wait).
    ctl(&backup_dir, json!({"op": "append", "entries": [{"comment": {"id": "B1", "asset": "A1", "version": "V1", "text": "from the backup", "rev": 1, "replies": []}}]})).await;
    drop(backup);
    let mut backup = Proc::start(bin, &["--host", backup_dir.to_str().unwrap(), "--signal", &sig, "--local", "--backup", "--iroh-bin", iroh.to_str().unwrap(),
        "--max-storage", "1G", "--quality", "540-low"], &[], None);
    backup.wait(|v| v["ready"].is_object()).await;
    let until = tokio::time::Instant::now() + T;
    loop {
        let pulled = ctl(&main_dir, json!({"op": "pull", "since": 0})).await;
        let n = pulled["entries"].as_array().map_or(0, |e| e.iter().filter(|e| e["comment"]["id"] == "B1").count());
        if n == 1 { break }
        assert!(n == 0 && tokio::time::Instant::now() < until, "B1 on the main {n} times");
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    let st = ctl(&main_dir, json!({"op": "status"})).await;
    assert_eq!(st["backups"][0]["name"], "Backup", "{st}");
    // Restarting again pushes nothing twice.
    drop(backup);
    let mut backup = Proc::start(bin, &["--host", backup_dir.to_str().unwrap(), "--signal", &sig, "--local", "--backup", "--iroh-bin", iroh.to_str().unwrap()], &[], None);
    backup.wait(|v| v["ready"].is_object()).await;
    tokio::time::sleep(Duration::from_secs(5)).await;
    let pulled = ctl(&main_dir, json!({"op": "pull", "since": 0})).await;
    assert_eq!(pulled["entries"].as_array().unwrap().iter().filter(|e| e["comment"]["id"] == "B1").count(), 1, "no duplicates");
    let _ = (std::fs::remove_dir_all(main_dir), std::fs::remove_dir_all(backup_dir));
}

/// A backup refused because the main holds the room stands by (prio backup, retries) and
/// registers once the main is gone.
#[tokio::test]
async fn backup_stands_by_while_the_main_holds_the_room() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let (regs_tx, mut regs) = mpsc::unbounded_channel::<Value>();
    tokio::spawn(async move {
        let mut n = 0;
        loop {
            let (tcp, _) = l.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            let Some(Ok(Message::Text(t))) = ws.next().await else { continue };
            regs_tx.send(serde_json::from_str(&t).unwrap()).unwrap();
            n += 1;
            let reply = if n == 1 { json!({"t": "taken", "by": "host"}) } else { json!({"t": "registered", "peers": [], "relay": "off"}) };
            ws.send(Message::text(reply.to_string())).await.unwrap();
            if n > 1 { tokio::spawn(async move { while ws.next().await.is_some() {} }); }
        }
    });
    let data = tmp("standby");
    let room = "7E1RkYmx_jTN80i5w8xmOg";
    std::fs::create_dir_all(data.join("bundle")).unwrap();
    std::fs::write(data.join("main.json"), json!({"node": "a".repeat(64), "device": "D", "key": "K", "pin": "AA"}).to_string()).unwrap();
    std::fs::write(data.join("bundle/manifest.json"), json!({"format": 1, "projects": [{"id": "P", "name": "P", "folders": [], "assets": []}],
        "links": [{"id": "L", "roomID": room, "reg": "r", "auth": "a", "sign": "R85Juszx1tmPSUJlpjYA3DtFmqHJDUUU0Z1HyoU0Mb4", "join": "DDk_aLVe7_lpSrn2FJsnpy4x8AsymOK8AZOx9K_7OAo", "title": "T", "mode": "review", "revoked": null, "expires": null,
                   "project": "P", "root": {"kind": "project", "id": "P"}}]}).to_string()).unwrap();
    let bin = std::path::Path::new(env!("CARGO_BIN_EXE_pluck-review"));
    let mut h = Proc::start(bin, &["--host", data.to_str().unwrap(), "--signal", &format!("ws://{addr}/signal"), "--local", "--backup", "--iroh-bin", "/nonexistent"],
        &[("PLUCK_RELAY_TOKEN", "tok")], None);
    let s = h.wait(|v| v["room"]["state"] == "standby").await;
    assert_eq!(s["room"]["by"], "host");
    h.wait(|v| v["room"]["state"] == "active").await;
    assert_eq!(h.wait(|v| v.get("relay").is_some()).await["relay"]["state"], "off");
    let (first, second) = (regs.recv().await.unwrap(), regs.recv().await.unwrap());
    assert_eq!((first["prio"].clone(), second["prio"].clone(), first["relay"].clone()), (json!("backup"), json!("backup"), json!("tok")));
    let _ = std::fs::remove_dir_all(data);
}
