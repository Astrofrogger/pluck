// The `media` channel: one Serve per fetch Swift asked for. Bytes go out as binary frames
// (u32 fetch BE, u32 seq BE, ≤ 65,528 payload bytes), at most 8 MiB beyond the browser's last ack,
// read from the file in 1 MiB blocks only when the previous block has gone out.
use std::{
    io::SeekFrom,
    time::{Duration, Instant},
};

use tokio::{
    io::{AsyncReadExt, AsyncSeekExt},
    sync::mpsc,
};

use crate::Ev;

pub const HEADER: usize = 8;
pub const CHUNK: usize = 65_536 - HEADER;
pub const WINDOW: u64 = 8 << 20;
pub const BLOCK: u64 = 1 << 20;
pub const MAX_BUFFERED: usize = 1 << 20; // per channel (str0m buffered_amount), on a fast link
pub const MIN_BUFFERED: usize = 64 << 10; // on a slow one: what is queued can't be recalled by a cancel
pub const LOW_THRESHOLD: usize = 256 << 10;
pub const PER_PEER: usize = 4;
pub const TOTAL: usize = 32;
pub const WAIT_MAX: usize = 16; // serves a peer may have waiting for a slot (the browser keeps ≤ 4 in flight)

/// A `cancel` for a fetch with no serve yet: its `fetch` reply went by ctl and the serve is still on its way
/// (ctl and media are separate channels), so remember it (the last 64) and drop that serve when it comes.
pub fn cancel_early(list: &mut std::collections::VecDeque<u32>, fetch: u32) {
    if list.len() >= 64 {
        list.pop_front();
    }
    list.push_back(fetch);
}

/// True, once, when `fetch` was cancelled early.
pub fn take_early(list: &mut std::collections::VecDeque<u32>, fetch: u32) -> bool {
    list.iter().position(|&f| f == fetch).and_then(|i| list.remove(i)).is_some()
}

/// Which peers start a waiting serve now, in order: within PER_PEER each and TOTAL in all, always the
/// peer with the fewest running next, so one busy peer can't take the slots the others wait for.
/// `running` and `waiting` are per peer and are updated as serves are taken.
pub fn admit(running: &mut [usize], waiting: &mut [usize]) -> Vec<usize> {
    let mut out = vec![];
    while running.iter().sum::<usize>() < TOTAL {
        let Some(i) = (0..running.len()).filter(|&i| waiting[i] > 0 && running[i] < PER_PEER).min_by_key(|&i| running[i]) else { break };
        running[i] += 1;
        waiting[i] -= 1;
        out.push(i);
    }
    out
}

/// How fast the media channel drains (bytes the browser acknowledged a second), and so how much may be queued in
/// it: about half a second's worth, between MIN_BUFFERED and MAX_BUFFERED, growing at most a quarter a sample. A
/// cancel or a seek waits for whatever is queued, so a fixed 1 MiB cost a 25 KB/s link 40 s (the player's first
/// segment, a step down, a seek); half a second still covers the round trip on fast links (up to 500 ms), so they
/// keep their speed.
pub struct Drain {
    at: Option<Instant>,
    from: u64,
    busy: bool,
    pub rate: f64,
    cap: usize,
}

impl Drain {
    pub fn new() -> Self {
        Drain { at: None, from: 0, busy: false, rate: 0.0, cap: MIN_BUFFERED }
    }

    /// `written` = bytes written to the channel so far, `buffered` = still in it. Sampled every 200 ms; only an
    /// interval that starts with a queue at least half the cap and ends with one counts (a channel that ran dry
    /// says nothing about the link).
    pub fn sample(&mut self, now: Instant, written: u64, buffered: usize) {
        if self.at.is_some_and(|at| now.duration_since(at) < Duration::from_millis(200)) {
            return;
        }
        let drained = written.saturating_sub(buffered as u64);
        if let (Some(at), true) = (self.at, self.busy && buffered > 0) {
            let r = drained.saturating_sub(self.from) as f64 / now.duration_since(at).as_secs_f64();
            self.rate = if self.rate == 0.0 { r } else { 0.6 * self.rate + 0.4 * r };
        }
        // Up by at most a quarter a sample: a cap that jumps lets SCTP's slow start overshoot a router's queue by
        // hundreds of packets, and sctp-proto recovers from that with a timeout and a crawl (S2d: 2 s at 20 Mbit/s).
        self.cap = ((self.rate * 0.5) as usize).clamp(MIN_BUFFERED, MAX_BUFFERED).min(self.cap + self.cap / 4);
        self.from = drained;
        self.busy = buffered >= self.cap / 2;
        self.at = Some(now);
    }

    pub fn cap(&self) -> usize {
        self.cap
    }
}

pub fn frame(fetch: u32, seq: u32, payload: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(HEADER + payload.len());
    f.extend(fetch.to_be_bytes());
    f.extend(seq.to_be_bytes());
    f.extend(payload);
    f
}

pub struct Serve {
    pub fetch: u32,
    pub length: u64,
    pub sent: u64,
    pub acked: u64,
    seq: u32,
    block: Vec<u8>,
    pos: usize,
    read: u64,
    reading: bool,
    reader: Option<mpsc::Sender<u64>>, // None in unit tests
}

impl Serve {
    pub fn new(fetch: u32, length: u64, reader: Option<mpsc::Sender<u64>>) -> Self {
        Serve { fetch, length, sent: 0, acked: 0, seq: 0, block: vec![], pos: 0, read: 0, reading: false, reader }
    }

    /// The next frame, if a block is loaded and the credit window allows it.
    pub fn next_frame(&self) -> Option<Vec<u8>> {
        let credit = WINDOW - (self.sent - self.acked);
        let n = (CHUNK as u64).min(credit).min((self.block.len() - self.pos) as u64) as usize;
        (n > 0).then(|| frame(self.fetch, self.seq, &self.block[self.pos..self.pos + n]))
    }

    /// The frame from `next_frame` was accepted by the channel.
    pub fn wrote(&mut self, frame_len: usize) {
        let n = frame_len - HEADER;
        self.pos += n;
        self.sent += n as u64;
        self.seq += 1;
        if self.pos == self.block.len() {
            self.block = vec![]; // free the block before the next read
            self.pos = 0;
        }
    }

    /// The size of the next block to read, when the current one has gone out.
    pub fn want_block(&self) -> Option<u64> {
        (!self.reading && self.block.is_empty() && self.read < self.length).then(|| BLOCK.min(self.length - self.read))
    }

    /// Ask the reader for the next block (it answers with Ev::Block). False when the reader is gone.
    pub fn request_block(&mut self) -> bool {
        let Some(n) = self.want_block() else { return true };
        self.reading = true;
        self.reader.as_ref().is_some_and(|r| r.try_send(n).is_ok())
    }

    pub fn got_block(&mut self, b: Vec<u8>) {
        self.read += b.len() as u64;
        self.block = b;
        self.pos = 0;
        self.reading = false;
    }

    /// `bytes` = total the browser has consumed; never beyond what was sent.
    pub fn ack(&mut self, bytes: u64) {
        self.acked = self.acked.max(bytes.min(self.sent));
    }

    pub fn done(&self) -> bool {
        self.sent == self.length
    }
}

/// One piece of a fetch: (path, offset, length). A proxy download is the init and the media
/// range of the 1080 copy served back to back as one fetch.
pub type Part = (String, u64, u64);

/// A task that owns the files and reads the blocks a Serve asks for, in order, across the parts.
pub fn spawn_reader(parts: Vec<Part>, peer: String, fetch: u32, ev: mpsc::UnboundedSender<Ev>) -> mpsc::Sender<u64> {
    let (tx, mut rx) = mpsc::channel::<u64>(1);
    tokio::spawn(async move {
        let (mut file, mut i, mut left) = (None::<tokio::fs::File>, 0usize, 0u64);
        while let Some(n) = rx.recv().await {
            let data = async {
                let mut buf = Vec::with_capacity(n as usize);
                while (buf.len() as u64) < n {
                    if file.is_none() {
                        let (path, offset, length) = parts.get(i).ok_or(std::io::ErrorKind::UnexpectedEof)?;
                        let mut f = tokio::fs::File::open(path).await?;
                        f.seek(SeekFrom::Start(*offset)).await?;
                        (file, left) = (Some(f), *length);
                    }
                    if left == 0 {
                        (file, i) = (None, i + 1);
                        continue;
                    }
                    let want = (n - buf.len() as u64).min(left) as usize;
                    let start = buf.len();
                    buf.resize(start + want, 0);
                    file.as_mut().unwrap().read_exact(&mut buf[start..]).await?; // a file cut short is an error
                    left -= want as u64;
                }
                std::io::Result::Ok(buf)
            }
            .await;
            let failed = data.is_err();
            if ev.send(Ev::Block { peer: peer.clone(), fetch, data }).is_err() || failed {
                break;
            }
        }
    });
    tx
}

// ---- uploads: browser → helper binary frames on `media` (same header; `fetch` = the upload id) ----

pub const UP_CREDIT: u64 = WINDOW; // the browser keeps at most this much unacked
pub const UP_ACK_EVERY: u64 = 1 << 20;
pub const UP_PER_PEER: usize = 4;

pub struct Upload {
    pub id: u32,
    pub size: u64,
    pub received: u64,
    pub acked: u64,
    seq: u32,
    tx: Option<mpsc::UnboundedSender<Vec<u8>>>, // None in unit tests
}

impl Upload {
    pub fn new(id: u32, size: u64, tx: Option<mpsc::UnboundedSender<Vec<u8>>>) -> Self {
        Upload { id, size, received: 0, acked: 0, seq: 0, tx }
    }

    /// One frame's payload. An error fails the upload: out of order, too long, or beyond the credit.
    pub fn frame(&mut self, seq: u32, payload: &[u8]) -> Result<(), &'static str> {
        let n = payload.len() as u64;
        if seq != self.seq {
            return Err("frame out of order");
        }
        if payload.is_empty() || payload.len() > CHUNK || self.received + n > self.size {
            return Err("bad frame");
        }
        if self.received + n - self.acked > UP_CREDIT {
            return Err("beyond the credit");
        }
        self.seq += 1;
        self.received += n;
        match &self.tx {
            Some(tx) => tx.send(payload.to_vec()).map_err(|_| "writer gone"),
            None => Ok(()),
        }
    }

    /// The writer has `total` bytes on disk: Some(bytes) when an ack is due.
    pub fn written(&mut self, total: u64) -> Option<u64> {
        (total - self.acked.min(total) >= UP_ACK_EVERY || total == self.size).then(|| {
            self.acked = total;
            total
        })
    }
}

/// A task that writes an upload to `path` (a new file, 0600; never one that exists) and hashes it.
/// It reports Ev::Wrote after each piece, then once more with the SHA-256 (base64url) when all
/// `size` bytes are on disk. If the upload ends early (cancelled, failed, peer gone), the partial
/// file is deleted.
#[cfg(test)]
pub fn spawn_writer(path: String, size: u64, peer: String, upload: u32, ev: mpsc::UnboundedSender<Ev>) -> mpsc::UnboundedSender<Vec<u8>> {
    spawn_writer_at(path, size, None, peer, upload, ev)
}

/// `at`: a resumable upload (an uploads-root partial, accounts plan §4.4): the existing file (never made, never followed
/// if a link) is cut to `at` bytes and `size` more go after them. It is kept when the upload ends early, for the resume;
/// the hash reported covers only the new bytes (the host hashes the whole file at the end).
pub fn spawn_writer_at(path: String, size: u64, at: Option<u64>, peer: String, upload: u32, ev: mpsc::UnboundedSender<Ev>) -> mpsc::UnboundedSender<Vec<u8>> {
    use sha2::Digest;
    use tokio::io::{AsyncSeekExt, AsyncWriteExt};
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        let opened = match at {
            None => tokio::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).await,
            Some(off) => async {
                let mut f = tokio::fs::OpenOptions::new().write(true).custom_flags(libc::O_NOFOLLOW).open(&path).await?;
                f.set_len(off).await?;
                f.seek(std::io::SeekFrom::Start(off)).await?;
                Ok(f)
            }.await,
        };
        let mut f = match opened {
            Ok(f) => f,
            Err(e) => return { let _ = ev.send(Ev::Wrote { peer, upload, res: Err(e) }); }, // not ours: never removed
        };
        let r = async {
            let (mut h, mut total) = (sha2::Sha256::new(), 0u64);
            while total < size {
                let Some(b) = rx.recv().await else { return Err(std::io::Error::other("cancelled")) };
                f.write_all(&b).await?;
                h.update(&b);
                total += b.len() as u64;
                let _ = ev.send(Ev::Wrote { peer: peer.clone(), upload, res: Ok((total, None)) });
            }
            f.sync_all().await?;
            std::io::Result::Ok((total, crate::keys::b64(&h.finalize())))
        }
        .await;
        let res = match r {
            Ok((total, sha)) => Ok((total, Some(sha))),
            Err(e) => {
                if at.is_none() {
                    let _ = tokio::fs::remove_file(&path).await;
                }
                Err(e)
            }
        };
        let _ = ev.send(Ev::Wrote { peer, upload, res });
    });
    tx
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pump one serve like rtc.rs does, with the channel accepting everything.
    fn drain(s: &mut Serve) -> u64 {
        let mut out = 0;
        while let Some(f) = s.next_frame() {
            assert!(f.len() <= 65_536);
            out += (f.len() - HEADER) as u64;
            s.wrote(f.len());
            if let Some(n) = s.want_block() {
                s.reading = true;
                s.got_block(vec![7; n as usize]);
            }
        }
        out
    }

    #[test]
    fn the_queue_follows_the_link() {
        let t = Instant::now();
        let ms = |n| t + Duration::from_millis(n);
        let mut d = Drain::new();
        assert_eq!(d.cap(), MIN_BUFFERED, "unknown link: the small queue");
        // 25 KB/s (S2b's lossy 1.5 Mbit/s): the queue stays at the floor, about 2.6 s of data.
        d.sample(ms(0), 64 << 10, 64 << 10);
        d.sample(ms(1000), (64 << 10) + 25_000, 64 << 10);
        assert!((d.rate - 25_000.0).abs() < 1.0, "{}", d.rate);
        assert_eq!(d.cap(), MIN_BUFFERED);
        // 40 MB/s (a LAN): the full queue after a few samples.
        let (mut w, mut at) = ((64 << 10) + 25_000u64, 1000);
        for _ in 0..16 {
            let cap = d.cap();
            at += 200;
            w += 8_000_000;
            d.sample(ms(at), w, cap);
        }
        assert_eq!(d.cap(), MAX_BUFFERED);
        // A channel that runs dry (nothing queued) leaves the estimate alone.
        let r = d.rate;
        d.sample(ms(at + 5000), w, 0);
        d.sample(ms(at + 10000), w, 0);
        assert_eq!(d.rate, r);
    }

    #[test]
    fn waiting_serves_are_admitted_fairly() {
        // A peer at its cap with many waiting gets nothing; the others take turns.
        assert_eq!(admit(&mut [4, 0, 0], &mut [10, 3, 3]), [1, 2, 1, 2, 1, 2]);
        // The total cap holds, spread evenly over everyone waiting.
        let (mut run, mut wait) = ([0; 10], [10; 10]);
        assert_eq!(admit(&mut run, &mut wait).len(), TOTAL);
        assert!(run.iter().max().unwrap() - run.iter().min().unwrap() <= 1, "{run:?}");
        assert!(admit(&mut [1, 1], &mut [0, 0]).is_empty(), "nothing waiting");
    }

    #[test]
    fn a_cancel_before_its_serve_drops_that_serve_once() {
        let mut l = std::collections::VecDeque::new();
        cancel_early(&mut l, 7);
        assert!(!take_early(&mut l, 8));
        assert!(take_early(&mut l, 7));
        assert!(!take_early(&mut l, 7), "only once");
        for f in 0..100 {
            cancel_early(&mut l, f);
        }
        assert_eq!(l.len(), 64, "bounded");
        assert!(take_early(&mut l, 99) && !take_early(&mut l, 0));
    }

    #[test]
    fn header_is_big_endian() {
        assert_eq!(frame(7, 258, b"ab"), [0, 0, 0, 7, 0, 0, 1, 2, b'a', b'b']);
    }

    #[test]
    fn credit_window_stops_at_8_mib_beyond_ack() {
        let mut s = Serve::new(1, 20 << 20, None);
        s.got_block(vec![0; BLOCK as usize]);
        s.reading = false;
        s.read = BLOCK;
        assert_eq!(drain(&mut s), WINDOW, "stops at exactly 8 MiB unacked");
        assert!(s.next_frame().is_none());
        s.ack(3 << 20);
        assert_eq!(drain(&mut s), 3 << 20);
        s.ack(u64::MAX); // can't ack beyond what was sent
        assert_eq!(s.acked, 11 << 20);
        assert_eq!(drain(&mut s), WINDOW, "9 MiB left, window-limited again");
        s.ack(s.sent);
        assert_eq!(drain(&mut s), 1 << 20);
        assert!(s.done());
    }

    #[test]
    fn frames_are_sequential_and_complete() {
        let len = 3 * BLOCK + 12_345;
        let mut s = Serve::new(9, len, None);
        let mut seq = 0u32;
        let mut total = 0u64;
        loop {
            if let Some(n) = s.want_block() {
                s.reading = true;
                s.got_block(vec![1; n as usize]);
            }
            let Some(f) = s.next_frame() else { break };
            assert_eq!(u32::from_be_bytes(f[0..4].try_into().unwrap()), 9);
            assert_eq!(u32::from_be_bytes(f[4..8].try_into().unwrap()), seq);
            seq += 1;
            total += (f.len() - HEADER) as u64;
            s.wrote(f.len());
            s.ack(s.sent);
        }
        assert_eq!(total, len);
        assert!(s.done());
        assert!(s.want_block().is_none());
    }

    #[test]
    fn empty_fetch_is_done_at_once() {
        let s = Serve::new(1, 0, None);
        assert!(s.done());
        assert!(s.want_block().is_none());
    }

    #[test]
    fn one_block_at_a_time() {
        let mut s = Serve::new(1, 5 * BLOCK, None);
        assert_eq!(s.want_block(), Some(BLOCK));
        s.reading = true;
        assert_eq!(s.want_block(), None, "no second read while one is in flight");
        s.got_block(vec![0; BLOCK as usize]);
        assert_eq!(s.want_block(), None, "no read while the block is still going out");
    }

    #[tokio::test]
    async fn reader_reads_the_range_and_reports_short_files() {
        let path = std::env::temp_dir().join(format!("pluck-review-test-{}", std::process::id()));
        std::fs::write(&path, (0..=255u8).cycle().take(5000).collect::<Vec<_>>()).unwrap();
        let (ev, mut rx) = mpsc::unbounded_channel();
        let r = spawn_reader(vec![(path.to_string_lossy().into(), 1000, 5000)], "p".into(), 3, ev);
        r.send(10).await.unwrap();
        let Some(Ev::Block { fetch: 3, data: Ok(b), .. }) = rx.recv().await else { panic!() };
        assert_eq!(b, (0..=255u8).cycle().skip(1000).take(10).collect::<Vec<_>>());
        r.send(10_000).await.unwrap(); // beyond the end
        let Some(Ev::Block { data: Err(_), .. }) = rx.recv().await else { panic!() };
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn reader_joins_parts() {
        let path = std::env::temp_dir().join(format!("pluck-review-parts-{}", std::process::id()));
        std::fs::write(&path, b"0123456789").unwrap();
        let p = path.to_string_lossy().to_string();
        let (ev, mut rx) = mpsc::unbounded_channel();
        let r = spawn_reader(vec![(p.clone(), 0, 2), (p.clone(), 5, 0), (p, 6, 3)], "p".into(), 1, ev);
        r.send(5).await.unwrap();
        let Some(Ev::Block { data: Ok(b), .. }) = rx.recv().await else { panic!() };
        assert_eq!(b, b"01678");
        r.send(1).await.unwrap();
        let Some(Ev::Block { data: Err(_), .. }) = rx.recv().await else { panic!("past the last part") };
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn upload_frames_are_checked() {
        let mut u = Upload::new(4, 3 * CHUNK as u64, None);
        assert_eq!(u.frame(1, &[0; 10]), Err("frame out of order"));
        assert!(u.frame(0, &vec![0; CHUNK]).is_ok());
        assert_eq!(u.frame(1, &vec![0; CHUNK + 1]), Err("bad frame"));
        assert_eq!(u.frame(1, &[]), Err("bad frame"));
        assert!(u.frame(1, &vec![0; CHUNK]).is_ok());
        assert!(u.frame(2, &vec![0; CHUNK]).is_ok());
        assert_eq!(u.frame(3, &[0]), Err("bad frame"), "longer than announced");
        assert_eq!(u.written(100), None);
        assert_eq!(u.written(3 * CHUNK as u64), Some(3 * CHUNK as u64), "the last bytes are always acked");
        let mut big = Upload::new(5, 64 << 20, None);
        let mut seq = 0;
        while big.received + (CHUNK as u64) <= UP_CREDIT {
            big.frame(seq, &vec![0; CHUNK]).unwrap();
            seq += 1;
        }
        assert_eq!(big.frame(seq, &vec![0; CHUNK]), Err("beyond the credit"));
    }

    /// Accounts plan §4.4: a resumed partial is cut to `at`, written after it, and kept when the upload stops early.
    #[tokio::test]
    async fn a_resumed_writer_appends_and_keeps_its_partial() {
        let dir = std::env::temp_dir().join(format!("pluck-review-resume-{}", crate::host::uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("r.part");
        std::fs::write(&path, b"abcXX").unwrap(); // 3 good bytes, then a torn write
        let (ev, mut rx) = mpsc::unbounded_channel();
        let w = spawn_writer_at(path.to_string_lossy().into(), 3, Some(3), "p".into(), 1, ev.clone());
        w.send(b"def".to_vec()).unwrap();
        while let Some(Ev::Wrote { res, .. }) = rx.recv().await {
            if let Ok((3, Some(_))) = res { break }
        }
        assert_eq!(std::fs::read(&path).unwrap(), b"abcdef");
        let w = spawn_writer_at(path.to_string_lossy().into(), 4, Some(6), "p".into(), 2, ev.clone());
        w.send(b"gh".to_vec()).unwrap();
        drop(w); // the peer went
        while let Some(Ev::Wrote { res, .. }) = rx.recv().await {
            if res.is_err() { break }
        }
        assert_eq!(std::fs::read(&path).unwrap(), b"abcdefgh", "kept for the next resume");
        std::os::unix::fs::symlink(&path, dir.join("link.part")).unwrap();
        let _w = spawn_writer_at(dir.join("link.part").to_string_lossy().into(), 1, Some(0), "p".into(), 3, ev.clone());
        let Some(Ev::Wrote { res: Err(_), .. }) = rx.recv().await else { panic!("never through a link") };
        assert!(spawn_writer_at(dir.join("none.part").to_string_lossy().into(), 1, Some(0), "p".into(), 4, ev).is_closed() || !dir.join("none.part").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn writer_hashes_and_removes_partial_files() {
        use sha2::Digest;
        let dir = std::env::temp_dir().join(format!("pluck-review-up-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let (ev, mut rx) = mpsc::unbounded_channel();
        let path = dir.join("a.part").to_string_lossy().to_string();
        let w = spawn_writer(path.clone(), 6, "p".into(), 1, ev.clone());
        w.send(b"abc".to_vec()).unwrap();
        w.send(b"def".to_vec()).unwrap();
        let mut last = None;
        while let Some(Ev::Wrote { res, .. }) = rx.recv().await {
            if let Ok((_, Some(sha))) = res { last = Some(sha); break }
        }
        assert_eq!(last.unwrap(), crate::keys::b64(&sha2::Sha256::digest(b"abcdef")));
        assert_eq!(std::fs::read(&path).unwrap(), b"abcdef");
        let again = spawn_writer(path.clone(), 6, "p".into(), 2, ev.clone());
        drop(again);
        let Some(Ev::Wrote { res: Err(_), .. }) = rx.recv().await else { panic!("never overwrites a file") };
        assert!(std::path::Path::new(&path).exists());
        let p2 = dir.join("b.part").to_string_lossy().to_string();
        let w = spawn_writer(p2.clone(), 6, "p".into(), 3, ev);
        w.send(b"ab".to_vec()).unwrap();
        drop(w);
        loop {
            let Some(Ev::Wrote { res, .. }) = rx.recv().await else { panic!() };
            if res.is_err() { break }
        }
        assert!(!std::path::Path::new(&p2).exists(), "a cancelled upload leaves nothing behind");
        let _ = std::fs::remove_dir_all(dir);
    }
}
