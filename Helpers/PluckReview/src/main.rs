// pluck-review: Pluck Review's WebRTC end on the owner's Mac (str0m, data channels only).
// Browsers find the Mac through pluck.tools' signaling (signal.rs); media, comments and approvals
// then go peer to peer over DTLS/SCTP. All peers share one UDP socket per local address.
//
// stdin (JSON lines; the first is the settings; it quits when stdin closes):
//   {"signal":"wss://pluck.tools/signal","stun":["host:port",…],"rooms":[{"room","reg","join","expires"?,"turn"?,"ready"?}],"maxPeers":20,"local":false}
//   (+ "neverServe":true: a Mac whose owner has a NAS never serves a browser; "alwaysOn":true with "host": an always-on
//   Mac hosting bundles, ranked below both NAS roles; see signal.rs)
//   {"rooms":[…]}  {"send":{"peer","msg"}}  {"serve":{"peer","fetch","path","offset","length"}}  {"close":{"peer","reason"}}
//   {"serve":{"peer","fetch","pieces":[{"path","offset","length"},…]}}   (one fetch from several pieces: proxy MP4, §6.1)
//   {"accept":{"peer","upload","path","size","offset"?}}  {"cancel":{"peer","upload"}}   (uploads; send accept before the upload-begin reply;
//   offset: resume an existing partial there)
// stdout: {"ready"} {"room"} {"peer"} {"msg"} {"served"} {"upload"} {"log"} {"error"} — see the Pluck Review spec, §5.
// The helper never reads app messages beyond "a JSON object ≤ 64 KiB", and only opens paths
// Swift sends in `serve`.
mod accounts;
mod copies;
mod devices;
mod host;
mod iroh;
mod keys;
mod mail;
mod admin;
mod media;
mod outage;
mod proof;
mod relay;
mod replica;
mod roots;
mod rtc;
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // the supervisor runs on Linux only
mod selfupdate;
mod signal;
mod store;
mod stun;
mod sync;
mod update;
mod uplink;
mod upload_root;

use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use str0m::Candidate;
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    net::UdpSocket,
    sync::mpsc,
};

pub enum Ev {
    Udp { local: SocketAddr, src: SocketAddr, data: Vec<u8> },
    Stdin(Option<String>),
    Cmd(Value), // a Swift-style command from the in-process host
    Signal(signal::Up),
    Srflx { base: SocketAddr, addr: SocketAddr },
    Block { peer: String, fetch: u32, data: std::io::Result<Vec<u8>> },
    Wrote { peer: String, upload: u32, res: std::io::Result<(u64, Option<String>)> },
}

/// In host mode, peer/msg/served reports go to the host task instead of (msg) or as well as stdout.
static TAP: std::sync::OnceLock<mpsc::UnboundedSender<Value>> = std::sync::OnceLock::new();

pub fn report(v: Value) {
    if let Some(tap) = TAP.get() {
        if v.get("msg").is_some() {
            let _ = tap.send(v);
            return;
        }
        if v.get("peer").is_some() || v.get("served").is_some() || v.get("upload").is_some() {
            let _ = tap.send(v.clone());
        }
    }
    println!("{v}"); // println! locks stdout, so lines never interleave
}

pub fn log(s: String) {
    report(json!({ "log": s }));
}

#[tokio::main]
async fn main() {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--version") {
        return println!("pluck-review {} protocol {}", update::VERSION, store::PROTOCOL);
    }
    let arg = |k: &str| args.iter().position(|a| a == k).and_then(|i| args.get(i + 1)).cloned();
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
    let all = |k: &str| args.windows(2).filter(|w| w[0] == k).map(|w| w[1].clone()).collect::<Vec<_>>();
    // `pluck-review --ctl <data> '<op>'`: ask the running host (the updater's prepare-update).
    if let Some(i) = args.iter().position(|a| a == "--ctl") {
        let (Some(dir), Some(op)) = (args.get(i + 1), args.get(i + 2)) else {
            eprintln!("usage: pluck-review --ctl <data folder> '<json op>'");
            std::process::exit(2);
        };
        let _ = rustls::crypto::ring::default_provider().install_default();
        std::process::exit(update::ctl(std::path::Path::new(dir), op).await);
    }
    // On Linux (the NAS container, the Proxmox service) `--host` first becomes the supervisor that runs the newest
    // verified program (selfupdate.rs); PLUCK_SELF_UPDATE=0 runs the host directly.
    #[cfg(target_os = "linux")]
    if let (Some(dir), false) = (arg("--host"), selfupdate::active() || env("PLUCK_SELF_UPDATE").as_deref() == Some("0")) {
        let exe = std::env::current_exe().unwrap_or_else(|_| "/usr/local/bin/pluck-review".into());
        std::process::exit(selfupdate::supervise(dir.into(), exe, update::VERSION.into(), args.clone(), selfupdate::Trust::github().key, selfupdate::EARLY).await);
    }
    // `pluck-review --host <data> [--media <id>=<path>]… [--drop <id>[=<path>]]… [--uploads <id>=<path>] [--listen <addr:port>]
    // [--admin <addr:port>] [--signal <url>] [--local] [--iroh] [--iroh-bin <path>] [--iroh-relay <url>]
    // [--backup --main-link <link> --max-storage 50G --quality 1080-low] [--name <name>] [--turn-url <url>]…`:
    // an always-on host (the NAS container), configured by arguments (or the PLUCK_* environment)
    // and running until stopped. Otherwise Pluck's settings line on stdin.
    let cfg: Value = if let Some(dir) = arg("--host") {
        let backup = args.iter().any(|a| a == "--backup") || env("PLUCK_ROLE").as_deref() == Some("backup");
        let mut drop = all("--drop");
        drop.extend(env("PLUCK_DROP").iter().flat_map(|d| d.split(',')).map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()));
        json!({"signal": arg("--signal").unwrap_or("wss://pluck.tools/signal".into()),
               "stun": ["stun.cloudflare.com:3478"], "maxPeers": 50, // the Worker lets 50 wait at once too
               "local": args.iter().any(|a| a == "--local"),
               "host": {"dir": dir, "listen": arg("--listen"), "admin": arg("--admin"), "daemon": true, "media": all("--media"),
                        "uploads": arg("--uploads").or_else(|| env("PLUCK_UPLOADS")),
                        // Media roots clients' uploads may be placed into (a link's uploads.into); "id=path": the same folder mounted writable elsewhere.
                        "drop": drop,
                        "iroh": args.iter().any(|a| a == "--iroh") || env("PLUCK_IROH").as_deref() == Some("1"),
                        "irohBin": arg("--iroh-bin"), "irohRelay": arg("--iroh-relay").or_else(|| env("PLUCK_IROH_RELAY")),
                        "name": arg("--name").or_else(|| env("PLUCK_HOST_NAME")), "backup": backup,
                        "mainLink": arg("--main-link").or_else(|| env("PLUCK_MAIN_LINK")),
                        "maxStorage": arg("--max-storage").or_else(|| env("PLUCK_BACKUP_MAX")).unwrap_or("50G".into()),
                        "quality": arg("--quality").or_else(|| env("PLUCK_BACKUP_QUALITY")).unwrap_or("1080-low".into()),
                        "webauthnOrigin": arg("--webauthn-origin")}})
    } else {
        match lines.next_line().await {
            Ok(Some(l)) => serde_json::from_str(&l).unwrap_or(Value::Null),
            _ => Value::Null,
        }
    };
    relay::set(relay::from(&cfg, &all("--turn-url")));
    if let Err(e) = run(cfg, lines).await {
        report(json!({"error": format!("{e:#}")}));
        std::process::exit(1);
    }
}

/// `--drop <id>` or `--drop <id>=<path>`: a media root (not the uploads root) whose folders clients' uploads may be written
/// into. A path must be the root's own folder mounted again (same device and inode), e.g. writable beside a read-only mount.
fn drops(hc: &Value, media: &[String], roots: &roots::Roots) -> std::collections::HashMap<String, std::path::PathBuf> {
    use std::os::unix::fs::MetadataExt;
    let mut out = std::collections::HashMap::new();
    for spec in hc["drop"].as_array().into_iter().flatten().filter_map(Value::as_str) {
        let (id, path) = spec.split_once('=').map_or((spec, None), |(i, p)| (i, Some(p)));
        let Some((_, root)) = roots.0.iter().find(|(i, _)| i == id).filter(|_| media.iter().any(|m| m == id)) else {
            log(format!("drop {spec}: not a media root"));
            continue;
        };
        let dir = path.map_or_else(|| std::fs::canonicalize(root), std::fs::canonicalize);
        let same = |a: &std::path::Path, b: &std::path::Path| matches!((std::fs::metadata(a), std::fs::metadata(b)), (Ok(x), Ok(y)) if x.dev() == y.dev() && x.ino() == y.ino());
        match dir {
            Ok(d) if same(&d, root) => { out.insert(id.to_owned(), d); }
            _ => log(format!("drop {spec}: not that media root's folder")),
        }
    }
    out
}

/// <data>/host.json: this host's stable id, and its name (the flag/env wins, else the stored one).
fn ident(data: &std::path::Path, name: Option<&str>, backup: bool) -> host::Ident {
    let path = data.join("host.json");
    let mut v: Value = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| json!({}));
    if !v["id"].is_string() {
        v["id"] = json!(host::uuid());
    }
    if let Some(n) = name.map(|n| host::clean(n, 60)).filter(|n| !n.is_empty()) {
        v["name"] = json!(n);
    }
    if !v["name"].is_string() {
        v["name"] = json!(if backup { "Backup host" } else { "NAS host" });
    }
    let _ = std::fs::write(&path, v.to_string());
    host::Ident { id: v["id"].as_str().unwrap().into(), name: v["name"].as_str().unwrap().into(), backup }
}

/// Every usable local address: non-loopback IPv4 and IPv6 (no link-local), plus loopback for tests.
fn local_ips(local: bool) -> Vec<IpAddr> {
    // Container/VM bridges (a NAS with host networking has many) are never a client's way in; skipped, and private
    // IPv4 first, so the LAN address isn't cut off by the limit of 8 (a browser on the LAN then plays directly).
    const BRIDGES: [&str; 7] = ["docker", "br-", "veth", "virbr", "cni", "flannel", "vnet"];
    let mut ips: Vec<IpAddr> = if_addrs::get_if_addrs().unwrap_or_default().into_iter()
        .filter(|i| !BRIDGES.iter().any(|b| i.name.starts_with(b)))
        .map(|i| i.ip())
        .filter(|ip| !ip.is_loopback() && !ip.is_multicast() && !ip.is_unspecified())
        .filter(|ip| match ip {
            IpAddr::V4(v) => !v.is_link_local(),
            IpAddr::V6(v) => !v.is_unicast_link_local(),
        })
        .collect();
    ips.sort_by_key(|ip| !matches!(ip, IpAddr::V4(v) if v.is_private())); // (stable: interface order otherwise)
    ips.dedup();
    ips.truncate(8);
    if local {
        ips.insert(0, "127.0.0.1".parse().unwrap());
    }
    ips
}

/// A UDP socket with 4 MiB buffers: macOS's default send buffer drops most of a burst of SCTP packets.
pub fn udp(addr: SocketAddr) -> std::io::Result<UdpSocket> {
    use socket2::{Domain, Socket, Type};
    let s = Socket::new(Domain::for_address(addr), Type::DGRAM, None)?;
    let _ = s.set_send_buffer_size(4 << 20);
    let _ = s.set_recv_buffer_size(4 << 20);
    if addr.is_ipv6() {
        s.set_only_v6(true)?;
    }
    s.set_nonblocking(true)?;
    s.bind(&addr.into())?;
    UdpSocket::from_std(s.into())
}

async fn run(cfg: Value, mut lines: tokio::io::Lines<BufReader<tokio::io::Stdin>>) -> Result<()> {
    signal::HOST.store(!cfg["host"].is_null(), std::sync::atomic::Ordering::Relaxed);
    signal::NEVER_SERVE.store(cfg["neverServe"] == true, std::sync::atomic::Ordering::Relaxed);
    signal::ALWAYS_ON.store(cfg["host"].is_object() && cfg["alwaysOn"] == true, std::sync::atomic::Ordering::Relaxed);
    let signal_base = cfg["signal"].as_str().context("settings need \"signal\"")?.to_owned();
    if !(signal_base.starts_with("wss://") || signal_base.starts_with("ws://")) {
        bail!("signal must be a ws:// or wss:// address");
    }
    let local = cfg["local"].as_bool().unwrap_or(false);
    let max_peers = cfg["maxPeers"].as_u64().unwrap_or(20) as usize;
    let stun_servers: Vec<String> = cfg["stun"].as_array().into_iter().flatten().filter_map(|s| s.as_str().map(str::to_owned)).collect();
    str0m::crypto::from_feature_flags().install_process_default();
    let _ = rustls::crypto::ring::default_provider().install_default();

    let (ev_tx, mut ev) = mpsc::unbounded_channel::<Ev>();
    let pending: stun::Pending = Default::default();

    // The sockets, all on one port where the system allows it.
    let mut socks: rtc::Sockets = vec![];
    let mut port = 0;
    for ip in local_ips(local) {
        let s = match udp((ip, port).into()).or_else(|_| udp((ip, 0).into())) {
            Ok(s) => s,
            Err(e) => { log(format!("can't use {ip}: {e}")); continue }
        };
        let addr = s.local_addr()?;
        if port == 0 {
            port = addr.port();
        }
        socks.push((addr, Arc::new(s)));
    }
    if socks.is_empty() {
        bail!("no network address to listen on");
    }
    for (addr, sock) in &socks {
        let (addr, s, tx, pend) = (*addr, sock.clone(), ev_tx.clone(), pending.clone());
        tokio::spawn(async move {
            let mut buf = vec![0u8; 2048];
            loop {
                let Ok((n, src)) = s.recv_from(&mut buf).await else { continue };
                if let Some((txid, mapped)) = stun::parse_response(&buf[..n]) {
                    if let Some(w) = pend.lock().unwrap().remove(&txid) {
                        let _ = w.send(mapped);
                        continue;
                    }
                }
                if tx.send(Ev::Udp { local: addr, src, data: buf[..n].to_vec() }).is_err() {
                    return;
                }
            }
        });
        if !local {
            tokio::spawn(stun_loop(sock.clone(), addr, stun_servers.clone(), pending.clone(), ev_tx.clone()));
        }
    }
    report(json!({"ready": {"version": update::VERSION, "protocol": store::PROTOCOL, "port": port}}));

    // Host mode: the bundle's links are the rooms, and the host answers browsers instead of Swift.
    let daemon = cfg["host"]["daemon"].as_bool().unwrap_or(false);
    let mut to_host = None;
    if let Some(dir) = cfg["host"]["dir"].as_str() {
        let hc = &cfg["host"];
        let data = std::path::PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&data);
        let backup = hc["backup"].as_bool().unwrap_or(false);
        signal::BACKUP.store(backup, std::sync::atomic::Ordering::Relaxed);
        let me = ident(&data, hc["name"].as_str(), backup);
        update::started(&data);
        let busy: Arc<update::Busy> = Default::default();
        let (tap_tx, tap_rx) = mpsc::unbounded_channel();
        let (sync_tx, sync_rx) = mpsc::channel(16);
        let _ = TAP.set(tap_tx);
        // A backup has no media roots or uploads root (§13.3).
        let specs: Vec<String> = if backup { vec![] } else { hc["media"].as_array().into_iter().flatten().filter_map(|m| m.as_str().map(str::to_owned)).collect() };
        let mut roots = roots::Roots::parse(&specs);
        let ids: Vec<String> = roots.0.iter().map(|(i, _)| i.clone()).collect();
        let uploads = hc["uploads"].as_str().filter(|_| !backup).and_then(|u| upload_root::UploadRoot::parse(u, &ids, busy.clone())).map(Arc::new);
        if let Some(u) = &uploads {
            roots.add_uploads(u);
        }
        if !backup {
            roots.add_quarantine(&data); // clients' uploads as sources: a data host's Pluck adds them by reference
        }
        // A backup's own uploads root, for the main's Macs while the main is down (§13.25): never browsed, never a source.
        let uploads = if backup {
            let d = data.join(outage::EDITOR_DIR);
            let _ = std::fs::create_dir_all(&d);
            upload_root::UploadRoot::parse(&format!("outage={}", d.display()), &[], busy.clone()).map(Arc::new)
        } else { uploads };
        let devices = Arc::new(devices::Devices::load(&data));
        let outage = outage::Outage::load(&data, backup, backup.then(|| devices.clone()));
        let roots = Arc::new(roots);
        let (job_tx, job_rx) = mpsc::unbounded_channel();
        let (prog_tx, prog_rx) = mpsc::unbounded_channel();
        let copies_on = !roots.0.is_empty();
        if copies_on {
            tokio::spawn(copies::worker(job_rx, prog_tx.clone()));
        }
        let mut h = host::Host::new(&data, roots.clone(), ev_tx.clone(), copies_on.then_some(job_tx));
        h.upload_root = uploads.clone().filter(|_| !backup); // a main's only (a backup's is for its main's Macs, §13.25)
        h.devices = Some(devices.clone()); // its paired Macs: the last-admin guard (roles)
        if !backup {
            h.drops = drops(hc, &ids, &roots); // (ids: the media roots only)
        }
        (h.ident, h.busy, h.back) = (me.clone(), busy.clone(), Some(prog_tx));
        // Tests only (accounts plan §1.1): a localhost passkey origin, honoured only with a loopback signaling URL.
        if let Some(o) = hc["webauthnOrigin"].as_str() {
            if !h.accounts.set_origin(o, &signal_base) {
                log(format!("host: --webauthn-origin {o} ignored (only http://localhost with a local signaling URL)"));
            }
        }
        let replica = backup.then(|| replica::Shared::load(&data, replica::parse_size(hc["maxStorage"].as_str().unwrap_or("50G")).unwrap_or(50 << 30),
            hc["quality"].as_str().filter(|q| *q == "same" || copies::quality(q).is_some()).unwrap_or("1080-low")));
        signal::SAME.store(replica.as_ref().is_some_and(|r| !r.lighter()), std::sync::atomic::Ordering::Relaxed);
        h.replica = replica.clone();
        if backup {
            h.outage = Some(outage.clone());
        }
        if let Some(r) = &replica {
            let _ = r.outage.set(outage.clone());
        }
        h.reload();
        tokio::spawn(host::run(h, tap_rx, sync_rx, prog_rx));
        let (acceptor, fp) = sync::tls(&data)?;
        let (key, new_key) = sync::host_key(&data)?;
        let paired = devices.clone();
        tokio::spawn(uplink::run(local, move || backup || paired.has_backup())); // the upload speed the Room routes viewers by
        *devices.link.lock().unwrap() = json!({"n": me.name, "fp": fp});
        if let Some(l) = hc["listen"].as_str() {
            devices.link.lock().unwrap()["lan"] = json!(l);
        }
        let shared_key = Arc::new(std::sync::RwLock::new(key));
        let ctx = Arc::new(sync::Ctx { data: data.clone(), key: shared_key.clone(), roots: roots.clone(), to_host: sync_tx.clone(),
            devices: devices.clone(), uploads, outage: Some(outage.clone()), ident: me.clone(), fp: fp.clone(), acceptor: acceptor.clone(), busy: busy.clone() });
        if let Some(listen) = hc["listen"].as_str() {
            let (ctx, listen) = (ctx.clone(), listen.to_owned());
            tokio::spawn(async move {
                if let Err(e) = sync::serve(ctx, listen, new_key).await {
                    report(json!({"error": format!("sync endpoint: {e:#}")}));
                }
            });
        }
        // The loopback control listener (--ctl, the updater): its address in ctl.json.
        let ctl = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let ctl_info = json!({"listen": ctl.local_addr()?.to_string(), "fingerprint": fp});
        {
            use std::os::unix::fs::OpenOptionsExt;
            let p = data.join("ctl.json");
            let _ = std::fs::remove_file(&p);
            let _ = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&p)
                .and_then(|mut f| std::io::Write::write_all(&mut f, ctl_info.to_string().as_bytes()));
        }
        tokio::spawn(sync::accept_loop(ctx.clone(), ctl, None));
        let bin = iroh::binary(hc["irohBin"].as_str().map(str::to_owned));
        if hc["iroh"] == true && !backup {
            let (l, streams, _id) = iroh::office(&data, bin.clone(), hc["irohRelay"].as_str().map(str::to_owned), devices.clone(), "iroh-key").await?;
            tokio::spawn(sync::accept_loop(ctx.clone(), l, Some(streams)));
        }
        // A backup also lets the main's Macs in (only those, on the node each registered there), with a key of its own
        // (its home-mode child dials the main with iroh-key): its route for uploads while the main is down (§13.25).
        if let (true, Some(r)) = (hc["iroh"] == true && backup, &replica) {
            let relay = hc["irohRelay"].as_str().map(str::to_owned);
            let (l, streams, mut id) = iroh::office(&data, bin.clone(), relay.clone(), devices.clone(), "iroh-office-key").await?;
            tokio::spawn(sync::accept_loop(ctx.clone(), l, Some(streams)));
            let (r, fp) = (r.clone(), fp.clone());
            tokio::spawn(async move {
                loop {
                    if let Some(node) = id.borrow_and_update().clone() {
                        let mut o = json!({"node": node, "fp": fp, "relay": relay});
                        let addrs = iroh::OFFICE_ADDRS.lock().unwrap().clone();
                        if !addrs.is_null() {
                            o["addrs"] = addrs;
                        }
                        *r.office.lock().unwrap() = o;
                    }
                    if id.changed().await.is_err() {
                        break;
                    }
                }
            });
        }
        if let Some(r) = replica {
            tokio::spawn(replica::run(r, sync_tx.clone(), replica::Setup { link: hc["mainLink"].as_str().map(str::to_owned), bin, name: me.name.clone() }));
        }
        if let Some(at) = hc["admin"].as_str().filter(|_| !backup) {
            let (data, at, tx, fp, roots, devices, shared_key) = (data.clone(), at.to_owned(), sync_tx.clone(), fp.clone(), roots.clone(), devices.clone(), shared_key.clone());
            tokio::spawn(async move {
                if let Err(e) = admin::serve(data, at, acceptor, fp, shared_key, roots, tx, devices).await {
                    report(json!({"error": format!("admin page: {e:#}")}));
                }
            });
        }
        tokio::spawn(update::health(update::health_path()));
        if selfupdate::active() {
            tokio::spawn(selfupdate::run(data.clone(), selfupdate::Trust::github(), sync_tx.clone()));
        }
        to_host = Some(sync_tx);
    }

    let tx = ev_tx.clone();
    tokio::spawn(async move {
        loop {
            let l = lines.next_line().await.ok().flatten();
            let end = l.is_none();
            let _ = tx.send(Ev::Stdin(l));
            if end {
                return;
            }
        }
    });

    let mut rooms: HashMap<String, signal::Room> = HashMap::new();
    let mut peers: HashMap<String, rtc::Peer> = HashMap::new();
    let mut srflx: Vec<(SocketAddr, SocketAddr)> = vec![];
    let mut finals = relay::Finals::default();
    set_rooms(&cfg["rooms"], &mut rooms, &mut peers, &signal_base, &ev_tx, &socks);

    loop {
        let now = Instant::now();
        let next = peers.values().map(|p| p.deadline).min().unwrap_or(now + Duration::from_secs(1)).min(now + Duration::from_secs(1));
        tokio::select! {
            e = ev.recv() => {
                let Some(e) = e else { return Ok(()) };
                let now = Instant::now();
                match e {
                    Ev::Udp { local, src, data } => {
                        if !peers.values_mut().any(|p| p.receive(local, src, &data, now, &socks)) {
                            // Usually a browser's first checks racing its offer.
                        }
                    }
                    Ev::Stdin(None) if daemon => {}
                    Ev::Stdin(None) => return Ok(()),
                    Ev::Stdin(Some(l)) => {
                        let Ok(v) = serde_json::from_str::<Value>(&l) else { log("stdin: not JSON".into()); continue };
                        match (&to_host, v.get("host")) {
                            (Some(h), Some(op)) => {
                                // The Mac case: Pluck on the always-on Mac syncs over stdin.
                                let (h, op) = (h.clone(), op.clone());
                                tokio::spawn(async move {
                                    let (tx, rx) = tokio::sync::oneshot::channel();
                                    if h.send(host::Sync { op, reply: tx }).await.is_ok() {
                                        if let Ok(r) = rx.await { report(json!({ "host": r })) }
                                    }
                                });
                            }
                            _ => command(v, &mut rooms, &mut peers, &signal_base, &ev_tx, &socks),
                        }
                    }
                    Ev::Cmd(v) => command(v, &mut rooms, &mut peers, &signal_base, &ev_tx, &socks),
                    Ev::Signal(signal::Up::Offer { room, peer, sdp }) => {
                        if signal::NEVER_SERVE.load(std::sync::atomic::Ordering::Relaxed) {
                            log(format!("peer {peer}: offer dropped (never serve)")); // signal.rs drops them first
                        } else if peers.contains_key(&peer) {
                            log(format!("peer {peer}: second offer ignored"));
                        } else if peers.len() >= max_peers {
                            log(format!("peer {peer}: too many peers"));
                            kick(&rooms, &room, &peer, "busy");
                        } else {
                            offer(room, peer, &sdp, &srflx, &rooms, &mut peers, &socks, now);
                        }
                    }
                    Ev::Signal(signal::Up::Candidate { peer, cand }) => {
                        if let Some(p) = peers.get_mut(&peer) {
                            p.add_remote(&cand, &socks);
                        }
                    }
                    Ev::Signal(signal::Up::PeerLeft { room, peer }) => {
                        // A connected browser closes its signaling socket by design.
                        match peers.get_mut(&peer) {
                            Some(p) => if !p.connected { p.kill = true },
                            // Never offered (or already gone): release its relay reserve at the DO, once.
                            None if relay::config().token.is_some() => if let Some(u) = finals.final_zero(&peer) {
                                if let Some(r) = rooms.get(&room) { let _ = r.tx.send(u); }
                            },
                            None => {}
                        }
                    }
                    Ev::Srflx { base, addr } => {
                        // shortcut: only peers that offer later get a new public address; trickle it to open peers if their NAT mapping changes mid-review.
                        srflx.retain(|(b, _)| *b != base);
                        if addr != base {
                            srflx.push((base, addr));
                        }
                    }
                    Ev::Wrote { peer, upload, res } => {
                        if let Some(p) = peers.get_mut(&peer) {
                            p.wrote(upload, res, &socks);
                        }
                    }
                    Ev::Block { peer, fetch, data } => {
                        if let Some(p) = peers.get_mut(&peer) {
                            if let Some(i) = p.serves.iter().position(|s| s.fetch == fetch) {
                                match data {
                                    Ok(b) => p.serves[i].got_block(b),
                                    Err(e) => {
                                        log(format!("serve {peer}/{fetch}: {e}"));
                                        let s = p.serves.remove(i);
                                        rtc::served(&peer, fetch, s.sent, "error");
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ = tokio::time::sleep_until(next.into()) => {}
        }
        let now = Instant::now();
        let counting = relay::config().token.is_some(); // usage goes only to rooms registered with the owner's token
        start_waiting(&mut peers, &ev_tx, &socks);
        for p in peers.values_mut() {
            p.tick(now, &socks);
            p.pump(&socks);
            if counting {
                if let (Some(u), Some(r)) = (p.relay_due(now, &socks), rooms.get(&p.room)) {
                    if u["final"] == true { finals.note(&p.id); }
                    let _ = r.tx.send(u);
                }
            }
        }
        let gone: Vec<String> = peers.values().filter(|p| !p.alive(now)).map(|p| p.id.clone()).collect();
        for id in gone {
            let mut p = peers.remove(&id).unwrap();
            p.disconnect(&socks);
            p.closed();
            if let (true, Some(u), Some(r)) = (counting, p.relay.last(&id), rooms.get(&p.room)) {
                finals.note(&id);
                let _ = r.tx.send(u);
            }
            kick(&rooms, &p.room, &id, "retry");
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn offer(room: String, peer: String, sdp: &str, srflx: &[(SocketAddr, SocketAddr)], rooms: &HashMap<String, signal::Room>,
         peers: &mut HashMap<String, rtc::Peer>, socks: &rtc::Sockets, now: Instant) {
    let mut locals: Vec<Candidate> = socks.iter().filter_map(|(a, _)| Candidate::host(*a, "udp").ok()).collect();
    locals.extend(srflx.iter().filter_map(|(base, a)| Candidate::server_reflexive(*a, *base, "udp").ok()));
    match rtc::Peer::new(peer.clone(), room.clone(), sdp, &locals, now) {
        Ok((p, answer)) => {
            if let Some(r) = rooms.get(&room) {
                let _ = r.tx.send(json!({"t": "answer", "peer": peer, "sdp": answer}));
            }
            peers.insert(peer, p);
        }
        Err(e) => {
            log(format!("peer {peer}: bad offer: {e}"));
            kick(rooms, &room, &peer, "retry");
        }
    }
}

/// Closes a browser's signaling socket. `why`: "busy" (too many peers: it waits and tries again) or "retry" (its
/// connection failed here: it tries again at once). Neither means the link is off; a Worker that predates `why` says it is.
fn kick(rooms: &HashMap<String, signal::Room>, room: &str, peer: &str, why: &str) {
    if let Some(r) = rooms.get(room) {
        let _ = r.tx.send(json!({"t": "kick", "peer": peer, "why": why}));
    }
}

/// Replace the set of rooms: new ones register, missing ones close (with their peers).
fn set_rooms(v: &Value, rooms: &mut HashMap<String, signal::Room>, peers: &mut HashMap<String, rtc::Peer>,
             base: &str, ev: &mpsc::UnboundedSender<Ev>, socks: &rtc::Sockets) {
    let want: HashMap<String, (String, String, Option<String>, bool, bool)> = v.as_array().into_iter().flatten()
        .filter_map(|r| {
            let (room, reg) = (r["room"].as_str()?, r["reg"].as_str()?);
            let Some(join) = r["join"].as_str() else {
                log(format!("room {room}: no join hash (an older link): not registered"));
                return None;
            };
            let expires = r["expires"].as_str().map(str::to_owned);
            Some((room.to_owned(), (reg.to_owned(), join.to_owned(), expires, r["turn"].as_bool().unwrap_or(true), r["ready"] == true)))
        })
        .filter(|(r, _)| signal::valid_room(r))
        .collect();
    // A room whose link's expiry changed registers again, so the Room's tombstone follows it (§13.24).
    rooms.retain(|r, x| want.get(r).is_some_and(|w| w.2 == x.expires));
    for (id, p) in peers.iter_mut() {
        if !want.contains_key(&p.room) {
            p.kill = true;
            log(format!("peer {id}: its room closed"));
        }
    }
    let _ = socks;
    for (room, (reg, join, expires, turn, ready)) in want {
        let r = rooms.entry(room.clone()).or_insert_with(|| signal::spawn(base, room, reg, join, expires, turn, ev.clone()));
        r.turn.store(turn, std::sync::atomic::Ordering::Relaxed);
        r.ready.store(ready, std::sync::atomic::Ordering::Relaxed);
    }
}

fn command(v: Value, rooms: &mut HashMap<String, signal::Room>, peers: &mut HashMap<String, rtc::Peer>,
           base: &str, ev: &mpsc::UnboundedSender<Ev>, socks: &rtc::Sockets) {
    if v.get("rooms").is_some() {
        set_rooms(&v["rooms"], rooms, peers, base, ev, socks);
    } else if let Some(s) = v.get("send") {
        match s["peer"].as_str().and_then(|id| peers.get_mut(id)) {
            Some(p) => p.send(&s["msg"], socks),
            None => log(format!("send: no peer {}", s["peer"])),
        }
    } else if let Some(s) = v.get("serve") {
        serve(s, peers, ev, socks);
    } else if let Some(a) = v.get("accept") {
        let (peer, id) = (a["peer"].as_str().unwrap_or(""), a["upload"].as_u64().and_then(|u| u32::try_from(u).ok()));
        let ok = match (peers.get_mut(peer), id, a["path"].as_str(), a["size"].as_u64()) {
            (Some(p), Some(id), Some(path), Some(size)) => p.accept(id, path, size, a["offset"].as_u64(), ev),
            _ => false,
        };
        if !ok {
            report(json!({"upload": {"peer": peer, "upload": a["upload"], "state": "failed", "bytes": 0}}));
        }
    } else if let Some(c) = v.get("cancel") {
        if let (Some(p), Some(id)) = (c["peer"].as_str().and_then(|id| peers.get_mut(id)), c["upload"].as_u64().and_then(|u| u32::try_from(u).ok())) {
            p.cancel_upload(id, socks);
        }
    } else if let Some(c) = v.get("close") {
        if let Some(p) = c["peer"].as_str().and_then(|id| peers.get_mut(id)) {
            p.kill = true; // closed and kicked at the end of this turn
        }
    } else {
        log(format!("stdin: unknown command {v}"));
    }
}

fn serve(s: &Value, peers: &mut HashMap<String, rtc::Peer>, ev: &mpsc::UnboundedSender<Ev>, socks: &rtc::Sockets) {
    let peer = s["peer"].as_str().unwrap_or("").to_owned();
    let Some(fetch) = s["fetch"].as_u64().and_then(|f| u32::try_from(f).ok()) else {
        return log("serve: bad fetch".into());
    };
    // `pieces` is the §6.1 name; `parts` is still read from older builds.
    let parts: Option<Vec<media::Part>> = match s["pieces"].as_array().or(s["parts"].as_array()) {
        Some(list) => list.iter().map(|p| Some((p["path"].as_str()?.to_owned(), p["offset"].as_u64()?, p["length"].as_u64()?))).collect(),
        None => (|| Some(vec![(s["path"].as_str()?.to_owned(), s["offset"].as_u64()?, s["length"].as_u64()?)]))(),
    };
    let Some(parts) = parts.filter(|p| !p.is_empty() && p.len() <= 4096) else {
        return rtc::served(&peer, fetch, 0, "error");
    };
    let Some(p) = peers.get_mut(&peer) else { return rtc::served(&peer, fetch, 0, "error") };
    if p.take_cancelled(fetch) {
        return rtc::served(&peer, fetch, 0, "cancelled");
    }
    // Past the caps it waits rather than fails: the browser already has the size and would wait for bytes forever.
    if !p.can_serve() || p.waiting.len() >= media::WAIT_MAX || p.serves.iter().any(|x| x.fetch == fetch) || p.waiting.iter().any(|w| w.0 == fetch) {
        return rtc::served(&peer, fetch, 0, "error");
    }
    p.waiting.push_back((fetch, parts));
    start_waiting(peers, ev, socks);
}

/// Starts waiting serves as slots free up, fairly across peers (media::admit). Run after every turn.
fn start_waiting(peers: &mut HashMap<String, rtc::Peer>, ev: &mpsc::UnboundedSender<Ev>, socks: &rtc::Sockets) {
    if peers.values().all(|p| p.waiting.is_empty()) {
        return;
    }
    let ids: Vec<String> = peers.keys().cloned().collect();
    let mut running: Vec<usize> = ids.iter().map(|i| peers[i].serves.len()).collect();
    let mut waiting: Vec<usize> = ids.iter().map(|i| if peers[i].can_serve() { peers[i].waiting.len() } else { 0 }).collect();
    for i in media::admit(&mut running, &mut waiting) {
        let p = peers.get_mut(&ids[i]).unwrap();
        let (fetch, parts) = p.waiting.pop_front().unwrap();
        let length: u64 = parts.iter().map(|p| p.2).sum();
        let reader = (length > 0).then(|| media::spawn_reader(parts, p.id.clone(), fetch, ev.clone()));
        p.serves.push(media::Serve::new(fetch, length, reader));
        p.pump(socks);
    }
}

async fn stun_loop(sock: Arc<UdpSocket>, base: SocketAddr, servers: Vec<String>, pending: stun::Pending, ev: mpsc::UnboundedSender<Ev>) {
    let mut last = None;
    loop {
        for s in &servers {
            let Ok(mut addrs) = tokio::net::lookup_host(s.as_str()).await else { continue };
            let Some(server) = addrs.find(|a| a.is_ipv4() == base.is_ipv4()) else { continue };
            if let Some(mapped) = stun::bind(&sock, server, &pending).await {
                if last != Some(mapped) {
                    last = Some(mapped);
                    let _ = ev.send(Ev::Srflx { base, addr: mapped });
                }
                break;
            }
        }
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}
