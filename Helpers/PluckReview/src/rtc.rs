// One browser: a str0m Rtc (the answerer, ICE controlled) on the shared sockets, its `ctl` and
// `media` channels, the ctl rate limits, and its serves. Every str0m mutation is followed by
// `drain` (poll_output until Timeout), as str0m requires.
use std::{
    collections::VecDeque,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use serde_json::{Value, json};
use str0m::{
    Candidate, CandidateKind, Event, Input, Output, Rtc,
    change::SdpOffer,
    channel::{ChannelData, ChannelId},
    net::{Protocol, Receive},
};
use tokio::net::UdpSocket;

use crate::{log, media, report};

pub const MAX_IN: usize = 64 * 1024; // a ctl message from a browser
pub const CTL_RATE: f64 = 50.0;
pub const CTL_BURST: f64 = 200.0;
pub const CTL_FLOOD: u32 = 500;
pub const MAX_OUT: usize = MAX_QUEUED; // a ctl message from Swift (or the host), before splitting
/// The most one SCTP message to a browser may hold: Chrome and Safari take 256 KiB, and an offer
/// without `a=max-message-size` means 64 KiB (RFC 8841). Larger ctl messages go out as `part`s.
pub const MAX_MSG: usize = 256 * 1024;
const MAX_QUEUED: usize = 4 << 20; // ctl bytes waiting for the channel; beyond that the browser isn't reading
pub const IDLE: Duration = Duration::from_secs(30);

pub type Sockets = Vec<(SocketAddr, Arc<UdpSocket>)>;

pub struct Peer {
    pub id: String,
    pub room: String,
    rtc: Rtc,
    ctl: Option<ChannelId>,
    media: Option<ChannelId>,
    pub open: bool,
    pub connected: bool,
    pub kill: bool,
    pub deadline: Instant,
    pub last_rx: Instant,
    last_src: Option<SocketAddr>,
    relays: Vec<SocketAddr>,
    fp_local: String,
    fp_remote: String,
    pub serves: Vec<media::Serve>,
    /// Serves past PER_PEER/TOTAL: the browser was already told the size, so they wait for a slot (media::admit).
    pub waiting: VecDeque<(u32, Vec<media::Part>)>,
    /// Fetch ids cancelled before their serve came (ctl and media race): such a serve is dropped.
    cancelled: VecDeque<u32>,
    ctl_out: VecDeque<String>,
    media_out: VecDeque<String>, // upload acks and cancels, ahead of the frames
    queued: usize,
    max_msg: usize,
    pub uploads: Vec<media::Upload>,
    /// Bytes written to the media channel so far, and how fast it drains (the cap on what is queued in it).
    media_written: u64,
    drain: media::Drain,
    rate_start: Instant,
    rate_n: u32,
    tokens: f64, // ctl requests: a bucket of CTL_BURST, refilled at CTL_RATE a second
    tokens_at: Instant,
    /// UDP payload bytes to and from this peer's relay candidates (§13.10), both ways.
    pub relay: crate::relay::Count,
}

/// The `a=fingerprint:sha-256` value of an SDP, as written (uppercase hex with colons).
pub fn fingerprint(sdp: &str) -> Option<String> {
    sdp.lines()
        .filter_map(|l| l.trim().strip_prefix("a=fingerprint:"))
        .find_map(|l| l.split_once(' ').filter(|(h, _)| h.eq_ignore_ascii_case("sha-256")).map(|(_, v)| v.trim().to_ascii_uppercase()))
}

/// The browser's receive limit per message, from its offer, never above MAX_MSG.
fn max_message_size(sdp: &str) -> usize {
    let n = sdp.lines().find_map(|l| l.trim().strip_prefix("a=max-message-size:")?.trim().parse::<usize>().ok());
    match n {
        None => 64 * 1024,
        Some(0) => MAX_MSG, // "unlimited"
        Some(n) => n.clamp(16 * 1024, MAX_MSG),
    }
}

/// Remote candidates we use: no mDNS `.local` names (they don't parse; the peer-reflexive path
/// covers the LAN), UDP only.
fn parse_candidate(line: &str) -> Option<Candidate> {
    let line = line.trim().trim_start_matches("a=");
    Candidate::from_sdp_string(line).ok().filter(|c| c.proto() == Protocol::Udp)
}

impl Peer {
    /// Accept a browser's offer: returns the peer and the SDP answer.
    pub fn new(id: String, room: String, sdp: &str, locals: &[Candidate], now: Instant) -> anyhow::Result<(Peer, String)> {
        let max_msg = max_message_size(sdp);
        let fp_remote = fingerprint(sdp).ok_or_else(|| anyhow::anyhow!("offer has no sha-256 fingerprint"))?;
        let offer = SdpOffer::from_sdp_string(sdp)?;
        // The media channel keeps ≤ 1 MiB buffered (media::Drain), so 2 MiB leaves ≥ 1 MiB for ctl messages.
        let mut rtc = Rtc::builder().set_sctp_max_buffered_amount(2 * media::MAX_BUFFERED).build(now);
        for c in locals {
            rtc.add_local_candidate(c.clone());
        }
        let relays = sdp.lines().filter(|l| l.contains("candidate:")).filter_map(parse_candidate)
            .filter(|c| c.kind() == CandidateKind::Relayed).map(|c| c.addr()).collect();
        let answer = rtc.sdp_api().accept_offer(offer)?.to_sdp_string();
        let fp_local = fingerprint(&answer).ok_or_else(|| anyhow::anyhow!("answer has no fingerprint"))?;
        let peer = Peer {
            id, room, rtc, ctl: None, media: None, open: false, connected: false, kill: false,
            deadline: now, last_rx: now, last_src: None, relays, fp_local, fp_remote,
            serves: vec![], waiting: VecDeque::new(), cancelled: VecDeque::new(), ctl_out: VecDeque::new(), media_out: VecDeque::new(), queued: 0, max_msg, uploads: vec![],
            media_written: 0, drain: media::Drain::new(),
            rate_start: now, rate_n: 0, tokens: CTL_BURST, tokens_at: now,
            relay: Default::default(),
        };
        Ok((peer, answer))
    }

    pub fn alive(&self, now: Instant) -> bool {
        !self.kill && self.relay.kill_at.is_none_or(|t| now < t) && self.rtc.is_alive() && now.duration_since(self.last_rx) < IDLE
    }

    /// Relay accounting for one turn of the loop (rooms registered with the owner's token only):
    /// a report when one is due; past 20 GB a `bye` with `relayLimit`, and the close a second later.
    pub fn relay_due(&mut self, now: Instant, socks: &Sockets) -> Option<Value> {
        let (report, bye) = self.relay.due(&self.id, now);
        if bye {
            self.send(&json!({"t": "bye", "code": "relayLimit"}), socks);
        }
        report
    }

    pub fn add_remote(&mut self, cand: &Value, socks: &Sockets) {
        let Some(c) = cand["candidate"].as_str().and_then(parse_candidate) else { return };
        if c.kind() == CandidateKind::Relayed {
            self.relays.push(c.addr());
        }
        self.rtc.add_remote_candidate(c);
        self.drain(socks);
    }

    /// Feed a packet if it belongs to this peer.
    pub fn receive(&mut self, local: SocketAddr, src: SocketAddr, data: &[u8], now: Instant, socks: &Sockets) -> bool {
        let Ok(contents) = data.try_into() else { return false };
        let input = Input::Receive(now, Receive { proto: Protocol::Udp, source: src, destination: local, contents });
        if !self.rtc.accepts(&input) {
            return false;
        }
        self.last_rx = now;
        self.last_src = Some(src);
        self.relay.add(self.relays.contains(&src), data.len());
        if let Err(e) = self.rtc.handle_input(input) {
            log(format!("peer {}: {e}", self.id));
        }
        self.drain(socks);
        true
    }

    pub fn tick(&mut self, now: Instant, socks: &Sockets) {
        if self.deadline <= now {
            let _ = self.rtc.handle_input(Input::Timeout(now));
            self.drain(socks);
        }
    }

    pub fn disconnect(&mut self, socks: &Sockets) {
        self.rtc.disconnect();
        self.drain(socks);
    }

    fn drain(&mut self, socks: &Sockets) {
        loop {
            match self.rtc.poll_output() {
                Ok(Output::Timeout(t)) => return self.deadline = t,
                Ok(Output::Transmit(t)) => {
                    // A full socket buffer drops the packet; SCTP resends it.
                    if let Some((_, s)) = socks.iter().find(|(a, _)| *a == t.source) {
                        let _ = s.try_send_to(&t.contents, t.destination);
                    }
                    self.relay.add(self.relays.contains(&t.destination), t.contents.len());
                }
                Ok(Output::Event(e)) => self.event(e),
                Err(e) => {
                    log(format!("peer {}: {e}", self.id));
                    self.kill = true;
                    self.deadline = Instant::now() + IDLE;
                    return;
                }
            }
        }
    }

    fn event(&mut self, e: Event) {
        match e {
            Event::Connected => self.connected = true,
            Event::ChannelOpen(id, label) => {
                match label.as_str() {
                    "ctl" => self.ctl = Some(id),
                    "media" => {
                        self.media = Some(id);
                        if let Some(mut ch) = self.rtc.channel(id) {
                            ch.set_buffered_amount_low_threshold(media::LOW_THRESHOLD);
                        }
                    }
                    _ => {}
                }
                if !self.open && self.ctl.is_some() && self.media.is_some() {
                    self.open = true;
                    let path = if self.last_src.is_some_and(|s| self.relays.contains(&s)) { "relay" } else { "direct" };
                    self.relay.direct = Some(path == "direct");
                    report(json!({"peer": {"peer": self.id, "room": self.room, "state": "open",
                        "fpLocal": self.fp_local, "fpRemote": self.fp_remote, "path": path}}));
                }
            }
            Event::ChannelData(d) if Some(d.id) == self.ctl => self.on_ctl(d),
            Event::ChannelData(d) if Some(d.id) == self.media => self.on_media(d),
            Event::ChannelClose(id) if Some(id) == self.ctl || Some(id) == self.media => self.kill = true,
            _ => {}
        }
    }

    /// Ctl from the browser: a bucket of 200 that refills at 50 a second (a grid of posters or a seek bursts
    /// well past 20 at once). Over the bucket, a request is answered `limit` (never dropped silently: the
    /// page would wait for ever); over 500 in one second closes the peer. Only JSON objects ≤ 64 KiB pass.
    fn on_ctl(&mut self, d: ChannelData) {
        let now = Instant::now();
        if now.duration_since(self.rate_start) >= Duration::from_secs(1) {
            (self.rate_start, self.rate_n) = (now, 0);
        }
        self.rate_n += 1;
        if self.rate_n > CTL_FLOOD {
            log(format!("peer {}: ctl flood, closing", self.id));
            self.kill = true;
        }
        if d.binary || d.data.len() > MAX_IN {
            return;
        }
        let Ok(v @ Value::Object(_)) = serde_json::from_slice::<Value>(&d.data) else { return };
        if !take_token(&mut self.tokens, &mut self.tokens_at, now) {
            if let Some(id) = v.get("id").filter(|id| id.is_u64()) {
                // Counted like any reply, so a peer that doesn't read can't grow this queue past the cap (#17).
                if !queue_ctl(&mut self.ctl_out, &mut self.queued, json!({"re": id, "error": {"code": "limit"}}).to_string()) {
                    log(format!("peer {}: not reading ctl, closing", self.id));
                    self.kill = true;
                }
            }
            return;
        }
        report(json!({"msg": {"peer": self.id, "msg": v}}));
    }

    fn on_media(&mut self, d: ChannelData) {
        if d.binary {
            // An upload frame: u32 upload id, u32 seq, payload. Frames for no accepted upload are dropped.
            if d.data.len() <= media::HEADER {
                return;
            }
            let id = u32::from_be_bytes(d.data[0..4].try_into().unwrap());
            let seq = u32::from_be_bytes(d.data[4..8].try_into().unwrap());
            if let Some(i) = self.uploads.iter().position(|u| u.id == id) {
                if let Err(why) = self.uploads[i].frame(seq, &d.data[media::HEADER..]) {
                    log(format!("peer {}: upload {id}: {why}", self.id));
                    self.end_upload(i, "failed");
                }
            }
            return;
        }
        if d.data.len() > 1024 {
            return;
        }
        let Ok(v) = serde_json::from_slice::<Value>(&d.data) else { return };
        if let (Some("cancel"), Some(up)) = (v["t"].as_str(), v["upload"].as_u64()) {
            if let Some(i) = self.uploads.iter().position(|u| u.id as u64 == up) {
                self.end_upload(i, "cancelled");
            }
            return;
        }
        let Some(fetch) = v["fetch"].as_u64() else { return };
        let Some(i) = self.serves.iter().position(|s| s.fetch as u64 == fetch) else {
            if v["t"] == "cancel" {
                match self.waiting.iter().position(|w| w.0 as u64 == fetch) {
                    Some(w) => { self.waiting.remove(w); served(&self.id, fetch as u32, 0, "cancelled"); }
                    None => media::cancel_early(&mut self.cancelled, fetch as u32),
                }
            }
            return;
        };
        match v["t"].as_str() {
            Some("ack") => self.serves[i].ack(v["bytes"].as_u64().unwrap_or(0)),
            Some("cancel") => {
                let s = self.serves.remove(i);
                served(&self.id, s.fetch, s.sent, "cancelled");
            }
            _ => {}
        }
    }

    pub fn can_serve(&self) -> bool {
        self.open && !self.kill
    }

    /// True (once) when the browser cancelled `fetch` before its serve came.
    pub fn take_cancelled(&mut self, fetch: u32) -> bool {
        media::take_early(&mut self.cancelled, fetch)
    }

    /// Swift (or the host) accepted an upload: its bytes go to `path`, a new file.
    /// `at`: resume an existing partial at that offset (media::spawn_writer_at).
    pub fn accept(&mut self, id: u32, path: &str, size: u64, at: Option<u64>, ev: &tokio::sync::mpsc::UnboundedSender<crate::Ev>) -> bool {
        if !self.can_serve() || self.uploads.len() >= media::UP_PER_PEER || self.uploads.iter().any(|u| u.id == id) {
            return false;
        }
        let tx = media::spawn_writer_at(path.to_owned(), size, at, self.id.clone(), id, ev.clone());
        self.uploads.push(media::Upload::new(id, size, Some(tx)));
        true
    }

    /// The writer moved on: ack (credit) to the browser, and the report when the file is complete.
    pub fn wrote(&mut self, id: u32, res: std::io::Result<(u64, Option<String>)>, socks: &Sockets) {
        let Some(i) = self.uploads.iter().position(|u| u.id == id) else { return };
        match res {
            Ok((total, sha)) => {
                if let Some(bytes) = self.uploads[i].written(total) {
                    self.media_out.push_back(json!({"t": "upload-ack", "upload": id, "bytes": bytes}).to_string());
                }
                if let Some(sha) = sha {
                    self.uploads.remove(i);
                    report(json!({"upload": {"peer": self.id, "upload": id, "state": "done", "bytes": total, "sha256": sha}}));
                }
            }
            Err(e) => {
                log(format!("peer {}: upload {id}: {e}", self.id));
                self.end_upload(i, "failed");
            }
        }
        self.pump(socks);
    }

    /// Stop an upload (its writer deletes the partial file), tell the browser, report it.
    pub fn end_upload(&mut self, i: usize, state: &str) {
        let u = self.uploads.remove(i);
        self.media_out.push_back(json!({"t": "cancel", "upload": u.id}).to_string());
        report(json!({"upload": {"peer": self.id, "upload": u.id, "state": state, "bytes": u.received}}));
    }

    pub fn cancel_upload(&mut self, id: u32, socks: &Sockets) {
        if let Some(i) = self.uploads.iter().position(|u| u.id == id) {
            self.end_upload(i, "cancelled");
            self.pump(socks);
        }
    }

    /// Queue one ctl message from Swift.
    pub fn send(&mut self, msg: &Value, socks: &Sockets) {
        let Some(parts) = fit(msg, self.max_msg) else {
            return log(format!("peer {}: refused a ctl message over {MAX_OUT} bytes", self.id));
        };
        let mut ok = true;
        for t in parts {
            ok &= queue_ctl(&mut self.ctl_out, &mut self.queued, t);
        }
        if !ok {
            log(format!("peer {}: not reading ctl, closing", self.id));
            self.kill = true;
        }
        self.pump(socks);
    }

    /// Write whatever fits: queued ctl first, then one frame per serve in turn (so a slow fetch
    /// doesn't hold up the others), while the media channel holds less than its cap (media::Drain). Then ask for blocks.
    pub fn pump(&mut self, socks: &Sockets) {
        if self.kill {
            return;
        }
        if let Some(ctl) = self.ctl {
            while let Some(m) = self.ctl_out.front() {
                let Some(mut ch) = self.rtc.channel(ctl) else { break };
                match ch.write(false, m.as_bytes()) {
                    Ok(true) => {
                        self.queued = self.queued.saturating_sub(m.len());
                        self.ctl_out.pop_front();
                        self.drain(socks);
                    }
                    Ok(false) => break,
                    Err(e) => {
                        log(format!("peer {}: ctl {e}", self.id));
                        self.kill = true;
                        return;
                    }
                }
            }
        }
        let Some(mid) = self.media else { return };
        while let Some(m) = self.media_out.front() {
            let Some(mut ch) = self.rtc.channel(mid) else { break };
            match ch.write(false, m.as_bytes()) {
                Ok(true) => {
                    self.media_out.pop_front();
                    self.drain(socks);
                }
                Ok(false) => break,
                Err(e) => {
                    log(format!("peer {}: media {e}", self.id));
                    self.kill = true;
                    return;
                }
            }
        }
        'rounds: loop {
            let mut moved = false;
            for i in 0..self.serves.len() {
                let Some(f) = self.serves[i].next_frame() else { continue };
                let Some(mut ch) = self.rtc.channel(mid) else { break 'rounds };
                let buffered = ch.buffered_amount();
                self.drain.sample(Instant::now(), self.media_written, buffered);
                if buffered >= self.drain.cap() {
                    break 'rounds;
                }
                match ch.write(true, &f) {
                    Ok(true) => {
                        self.media_written += f.len() as u64;
                        self.serves[i].wrote(f.len());
                        self.drain(socks);
                        moved = true;
                    }
                    Ok(false) => break 'rounds,
                    Err(e) => {
                        log(format!("peer {}: media {e}", self.id));
                        self.kill = true;
                        return;
                    }
                }
            }
            if !moved {
                break;
            }
        }
        let id = &self.id;
        self.serves.retain_mut(|s| {
            if s.done() {
                served(id, s.fetch, s.sent, "done");
                return false;
            }
            if !s.request_block() {
                served(id, s.fetch, s.sent, "error");
                return false;
            }
            true
        });
    }

    /// Serves still running when the peer goes are cancelled.
    pub fn closed(&mut self) {
        for s in self.serves.drain(..) {
            served(&self.id, s.fetch, s.sent, "cancelled");
        }
        for (fetch, _) in self.waiting.drain(..) {
            served(&self.id, fetch, 0, "cancelled");
        }
        for u in self.uploads.drain(..) {
            report(json!({"upload": {"peer": self.id, "upload": u.id, "state": "cancelled", "bytes": u.received}}));
        }
        report(json!({"peer": {"peer": self.id, "state": "closed"}}));
    }
}

/// A ctl message as sent. Over MAX_OUT it becomes a `limit` error to the request it answers (None:
/// not an answer, dropped). Over the browser's message size it goes as consecutive parts:
///   {"t":"part","re":<the answer's re, if any>,"n":0,"of":3,"data":"<a slice of the message's JSON text>"}
/// The browser joins the `data` of parts 0…of-1 (they arrive in order on the ordered channel) and
/// parses the result as the one message.
fn fit(msg: &Value, max: usize) -> Option<Vec<String>> {
    let t = msg.to_string();
    if t.len() > MAX_OUT {
        return msg.get("re").map(|id| vec![json!({"re": id, "error": {"code": "limit"}}).to_string()]);
    }
    if t.len() <= max {
        return Some(vec![t]);
    }
    // JSON-escaping a slice at most doubles it (quotes and backslashes), so a quarter of the limit fits.
    let step = (max / 4).max(1024);
    let mut slices = vec![];
    let mut rest = t.as_str();
    while !rest.is_empty() {
        let mut cut = step.min(rest.len());
        while !rest.is_char_boundary(cut) {
            cut -= 1;
        }
        slices.push(&rest[..cut]);
        rest = &rest[cut..];
    }
    let of = slices.len();
    Some(slices.into_iter().enumerate().map(|(n, d)| {
        let mut p = json!({"t": "part", "n": n, "of": of, "data": d});
        if let Some(re) = msg.get("re") {
            p["re"] = re.clone();
        }
        p.to_string()
    }).collect())
}

/// The ctl bucket: refill since `at`, then take one token if there is one.
fn take_token(tokens: &mut f64, at: &mut Instant, now: Instant) -> bool {
    *tokens = (*tokens + now.duration_since(*at).as_secs_f64() * CTL_RATE).min(CTL_BURST);
    *at = now;
    let ok = *tokens >= 1.0;
    if ok {
        *tokens -= 1.0;
    }
    ok
}

pub fn served(peer: &str, fetch: u32, bytes: u64, result: &str) {
    report(json!({"served": {"peer": peer, "fetch": fetch, "bytes": bytes, "result": result}}));
}

/// Queue one ctl message and count its bytes; false once the queue is over MAX_QUEUED (close the peer).
fn queue_ctl(out: &mut VecDeque<String>, queued: &mut usize, t: String) -> bool {
    *queued += t.len();
    out.push_back(t);
    *queued <= MAX_QUEUED
}

#[cfg(test)]
mod tests {
    /// #17: over-the-bucket `limit` replies count toward the queued cap, and a write never underflows it.
    #[test]
    fn limit_replies_are_counted() {
        let (mut out, mut queued) = (std::collections::VecDeque::new(), 0usize);
        let reply = json!({"re": 1u64, "error": {"code": "limit"}}).to_string();
        let mut n = 0;
        while queue_ctl(&mut out, &mut queued, reply.clone()) {
            n += 1;
        }
        assert_eq!(queued, out.len() * reply.len());
        assert!(queued > MAX_QUEUED && n < MAX_QUEUED / reply.len() + 1, "a non-reading peer is closed at the cap");
        assert_eq!(0usize.saturating_sub(reply.len()), 0);
    }

    #[test]
    fn ctl_bucket_allows_bursts_then_the_rate() {
        let t0 = std::time::Instant::now();
        let (mut tokens, mut at) = (super::CTL_BURST, t0);
        assert_eq!((0..300).filter(|_| super::take_token(&mut tokens, &mut at, t0)).count(), 200, "a burst of 200");
        let t1 = t0 + std::time::Duration::from_millis(100);
        assert_eq!((0..300).filter(|_| super::take_token(&mut tokens, &mut at, t1)).count(), 5, "then 50 a second");
    }

    use super::*;

    #[test]
    fn too_big_answers_say_limit() {
        let big = "x".repeat(MAX_OUT);
        assert_eq!(fit(&json!({"re": 7, "comments": big}), MAX_MSG), Some(vec![r#"{"error":{"code":"limit"},"re":7}"#.to_owned()]));
        assert_eq!(fit(&json!({"t": "presence", "x": big}), MAX_MSG), None);
        assert_eq!(fit(&json!({"re": 1, "x": "small"}), MAX_MSG).unwrap().len(), 1);
    }

    #[test]
    fn big_messages_go_in_parts_under_the_limit() {
        // Worst case for escaping (every char a quote), multi-byte text, and an event without `re`.
        for (msg, max) in [(json!({"re": 3, "x": "\"".repeat(900 * 1024)}), MAX_MSG), (json!({"t": "presence", "x": "é😀".repeat(100_000)}), 64 * 1024)] {
            let parts = fit(&msg, max).unwrap();
            assert!(parts.len() > 1);
            let mut joined = String::new();
            for (i, p) in parts.iter().enumerate() {
                assert!(p.len() <= max, "part {i}: {} bytes", p.len());
                let v: Value = serde_json::from_str(p).unwrap();
                assert_eq!((v["t"].as_str(), v["n"].as_u64(), v["of"].as_u64()), (Some("part"), Some(i as u64), Some(parts.len() as u64)));
                assert_eq!(v["re"], msg.get("re").cloned().unwrap_or(Value::Null));
                joined.push_str(v["data"].as_str().unwrap());
            }
            assert_eq!(serde_json::from_str::<Value>(&joined).unwrap(), msg);
        }
    }

    #[test]
    fn message_size_from_the_offer() {
        assert_eq!(max_message_size("v=0\r\na=max-message-size:262144\r\n"), MAX_MSG);
        assert_eq!(max_message_size("a=max-message-size:1073741823"), MAX_MSG, "Firefox: capped");
        assert_eq!(max_message_size("a=max-message-size:0"), MAX_MSG);
        assert_eq!(max_message_size("v=0"), 64 * 1024, "RFC 8841 default");
    }

    #[test]
    fn fingerprint_from_sdp() {
        let sdp = "v=0\r\na=fingerprint:sha-1 00:11\r\na=fingerprint:sha-256 ab:cd:EF\r\n";
        assert_eq!(fingerprint(sdp).as_deref(), Some("AB:CD:EF"));
        assert_eq!(fingerprint("v=0\r\n"), None);
    }

    #[test]
    fn candidates() {
        assert!(parse_candidate("candidate:1 1 udp 2113937151 abcd-1234.local 54400 typ host").is_none());
        assert!(parse_candidate("candidate:1 1 tcp 1518280447 192.168.1.2 9 typ host tcptype active").is_none());
        let c = parse_candidate("a=candidate:3 1 udp 41885439 104.30.1.2 50000 typ relay raddr 0.0.0.0 rport 0").unwrap();
        assert_eq!(c.kind(), CandidateKind::Relayed);
    }
}
