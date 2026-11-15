// The `media` channel: one Serve per fetch Swift asked for. Bytes go out as binary frames
// (u32 fetch BE, u32 seq BE, ≤ 65,528 payload bytes), at most 8 MiB beyond the browser's last ack,
// read from the file in 1 MiB blocks only when the previous block has gone out.
use std::io::SeekFrom;

use tokio::{
    io::{AsyncReadExt, AsyncSeekExt},
    sync::mpsc,
};

use crate::Ev;

pub const HEADER: usize = 8;
pub const CHUNK: usize = 65_536 - HEADER;
pub const WINDOW: u64 = 8 << 20;
pub const BLOCK: u64 = 1 << 20;
pub const MAX_BUFFERED: usize = 1 << 20; // per channel (str0m buffered_amount)
pub const LOW_THRESHOLD: usize = 256 << 10;
pub const PER_PEER: usize = 4;
pub const TOTAL: usize = 32;

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
pub fn spawn_writer(path: String, size: u64, peer: String, upload: u32, ev: mpsc::UnboundedSender<Ev>) -> mpsc::UnboundedSender<Vec<u8>> {
    use sha2::Digest;
    use tokio::io::AsyncWriteExt;
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    tokio::spawn(async move {
        let mut f = match tokio::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).await {
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
                let _ = tokio::fs::remove_file(&path).await;
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
