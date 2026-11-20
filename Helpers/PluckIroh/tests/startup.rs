// The built helper, as Pluck runs it: home starts listening without waiting on the office, dials it
// in the background, and keeps going through a network change.
use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

use serde_json::{Value, json};

struct Helper {
    child: Child,
    lines: mpsc::Receiver<Value>,
}

impl Helper {
    fn start(settings: Value) -> Helper {
        let mut child = Command::new(env!("CARGO_BIN_EXE_pluck-iroh"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        writeln!(child.stdin.as_mut().unwrap(), "{settings}").unwrap();
        let out = BufReader::new(child.stdout.take().unwrap());
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for l in out.lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str(&l) {
                    let _ = tx.send(v);
                }
            }
        });
        Helper { child, lines }
    }

    fn send(&mut self, v: Value) {
        writeln!(self.child.stdin.as_mut().unwrap(), "{v}").unwrap();
    }

    /// The first report matching `f` within `secs`.
    fn wait(&self, secs: u64, f: impl Fn(&Value) -> bool) -> Option<Value> {
        let end = Instant::now() + Duration::from_secs(secs);
        while let Some(left) = end.checked_duration_since(Instant::now()) {
            match self.lines.recv_timeout(left) {
                Ok(v) if f(&v) => return Some(v),
                Ok(_) => {}
                Err(_) => return None,
            }
        }
        None
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn key_file(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("pluck-iroh-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_file(&dir);
    dir.to_string_lossy().into_owned()
}

#[test]
fn home_listens_at_once_when_the_office_is_unreachable() {
    let office = iroh::SecretKey::generate().public().to_string();
    let started = Instant::now();
    let mut home = Helper::start(json!({"mode": "home", "keyFile": key_file("lonely"), "port": 9, "office": office,
                                        "officeAddrs": ["127.0.0.1:9"], "local": true}));
    let listening = home.wait(10, |v| v["state"] == "listening").expect("listening");
    assert!(listening["listen"].as_str().is_some_and(|a| a.starts_with("127.0.0.1:")));
    assert!(started.elapsed() < Duration::from_secs(5), "listening didn't wait for the office: {:?}", started.elapsed());
    let down = home.wait(40, |v| v["code"] == "unreachable").expect("the office is said to be unreachable");
    assert!(down["error"].as_str().unwrap().starts_with("Can't reach the office Mac"));
    // A network change: still running, and dials again at once.
    home.send(json!({"network": true}));
    assert!(home.wait(10, |v| v["state"] == "networkChecked").is_some());
    assert!(home.child.try_wait().unwrap().is_none(), "still running");
}

#[test]
fn home_links_up_in_the_background_without_a_local_connection() {
    let mut office = Helper::start(json!({"mode": "office", "keyFile": key_file("office"), "port": 9, "local": true, "allow": []}));
    let running = office.wait(10, |v| v["state"] == "running").expect("office running");
    let id = running["id"].as_str().unwrap().to_string();
    let port = running["addrs"].as_array().unwrap().iter().filter_map(|a| a.as_str())
        .find_map(|a| a.strip_prefix("0.0.0.0:")).expect("an IPv4 socket").to_string();
    assert!(office.wait(10, |v| v["state"] == "listening").is_some());
    let home = Helper::start(json!({"mode": "home", "keyFile": key_file("home"), "port": 9, "office": id,
                                    "officeAddrs": [format!("127.0.0.1:{port}")], "local": true}));
    assert!(home.wait(10, |v| v["state"] == "listening").is_some());
    // Not allowed there, so the office turns it away, but only after the background dial reached it.
    assert!(home.wait(20, |v| v.get("conn").is_some() || v.get("refused").is_some()).is_some(), "dialed without being asked");
    office.send(json!({"network": true}));
    assert!(office.wait(10, |v| v["state"] == "networkChecked").is_some());
}
