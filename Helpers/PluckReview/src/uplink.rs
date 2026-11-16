// The host's upload speed, for fastest-host routing (the Room sends viewers to the host that uploads fastest).
// At start, then every ~6 h (± 20 %): 3 × 4 MB of random bytes POSTed to Cloudflare's speed test endpoint
// (speed.cloudflare.com/__up, what speed.cloudflare.com itself uses), median Mbit/s. Nothing identifying goes out:
// no user agent, no cookie, only random bytes. Cloudflare is already the signaling processor (docs/legal R2).
// Only where routing reads it: a backup always, a main only while a backup is paired (else nobody compares).
// PLUCK_UPLINK_TEST=off turns it off; a failure means "unknown", which the Room takes as no preference.
// PLUCK_UPLINK_MBPS=<n> sets a fixed speed instead (tests, and loopback-only runs, which measure nothing).
use std::{sync::atomic::{AtomicU32, Ordering}, time::{Duration, Instant}};

use anyhow::{Context, Result};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::log;

/// The last measured upload in Mbit/s (rounded, at least 1); 0 = unknown.
pub static MBPS: AtomicU32 = AtomicU32::new(0);

pub fn mbps() -> Option<u32> {
    Some(MBPS.load(Ordering::Relaxed)).filter(|m| *m > 0)
}

const URL: &str = "https://speed.cloudflare.com/__up";
const SAMPLES: usize = 3;
const BYTES: usize = 4 << 20;
const EVERY: Duration = Duration::from_secs(6 * 3600);
const RETRY: Duration = Duration::from_secs(1800);
const IDLE: Duration = Duration::from_secs(600); // a main without a backup looks again this often
const TIMEOUT: Duration = Duration::from_secs(60); // per sample: 4 MB at ~0.5 Mbit/s

pub fn off() -> bool {
    std::env::var("PLUCK_UPLINK_TEST").is_ok_and(|v| matches!(v.trim(), "off" | "0" | "false" | "no"))
}

/// Measures for ever (host mode; not when `local`), while `needed` (a backup, or a main with one paired).
/// PLUCK_UPLINK_URL overrides the endpoint (tests).
pub async fn run(local: bool, needed: impl Fn() -> bool + Send + 'static) {
    if let Some(m) = std::env::var("PLUCK_UPLINK_MBPS").ok().and_then(|v| v.trim().parse::<u32>().ok()) {
        return MBPS.store(m, Ordering::Relaxed);
    }
    if local {
        return;
    }
    if off() {
        return log("uplink: the upload test is off (PLUCK_UPLINK_TEST)".into());
    }
    let url = std::env::var("PLUCK_UPLINK_URL").unwrap_or_else(|_| URL.into());
    loop {
        let wait = round(&url, needed()).await;
        tokio::time::sleep(wait.mul_f64(0.8 + 0.4 * rand::random::<f64>())).await;
    }
}

/// One measurement when `needed`, else none (unknown); how long until the next round.
async fn round(url: &str, needed: bool) -> Duration {
    if !needed {
        MBPS.store(0, Ordering::Relaxed);
        return IDLE;
    }
    match measure(url, SAMPLES, BYTES).await {
        Ok(m) => {
            MBPS.store((m.round() as u32).max(1), Ordering::Relaxed);
            log(format!("uplink: {m:.0} Mbit/s up"));
            EVERY
        }
        Err(e) => {
            MBPS.store(0, Ordering::Relaxed);
            log(format!("uplink: unknown ({e:#})"));
            RETRY
        }
    }
}

/// The median Mbit/s of `n` uploads of `bytes` random bytes; Err when any of them fails.
pub async fn measure(url: &str, n: usize, bytes: usize) -> Result<f64> {
    let mut body = vec![0u8; bytes];
    rand::RngCore::fill_bytes(&mut rand::rng(), &mut body);
    let mut got = vec![];
    for _ in 0..n {
        got.push(tokio::time::timeout(TIMEOUT, sample(url, &body)).await.context("timed out")??);
    }
    median(got).context("no samples")
}

pub fn median(mut v: Vec<f64>) -> Option<f64> {
    v.sort_by(f64::total_cmp);
    let n = v.len();
    (n > 0).then(|| if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 })
}

/// One POST; timed from the first body byte to the response's status line.
async fn sample(url: &str, body: &[u8]) -> Result<f64> {
    let (tls, rest) = match url.split_once("://") {
        Some(("https", r)) => (true, r),
        Some(("http", r)) => (false, r),
        _ => anyhow::bail!("bad url"),
    };
    let (hostport, path) = rest.split_once('/').map_or((rest, "/".to_owned()), |(h, p)| (h, format!("/{p}")));
    let host = hostport.split(':').next().unwrap_or(hostport).to_owned();
    let addr = if hostport.contains(':') { hostport.to_owned() } else { format!("{hostport}:{}", if tls { 443 } else { 80 }) };
    let tcp = tokio::net::TcpStream::connect(&addr).await?;
    let head = format!("POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
    if !tls {
        return post(tcp, &head, body).await;
    }
    let mut roots = tokio_rustls::rustls::RootCertStore::empty();
    roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
    let provider = std::sync::Arc::new(tokio_rustls::rustls::crypto::ring::default_provider());
    let cfg = tokio_rustls::rustls::ClientConfig::builder_with_provider(provider).with_safe_default_protocol_versions()?
        .with_root_certificates(roots).with_no_client_auth();
    let name = tokio_rustls::rustls::pki_types::ServerName::try_from(host)?;
    post(tokio_rustls::TlsConnector::from(std::sync::Arc::new(cfg)).connect(name, tcp).await?, &head, body).await
}

async fn post<S: AsyncRead + AsyncWrite + Unpin>(mut s: S, head: &str, body: &[u8]) -> Result<f64> {
    s.write_all(head.as_bytes()).await?;
    let start = Instant::now();
    s.write_all(body).await?;
    s.flush().await?;
    let mut status = [0u8; 12]; // "HTTP/1.1 200"
    s.read_exact(&mut status).await?;
    let secs = start.elapsed().as_secs_f64().max(1e-3);
    anyhow::ensure!(&status[9..12] == b"200", "HTTP {}", String::from_utf8_lossy(&status[9..12]));
    Ok(body.len() as f64 * 8.0 / secs / 1e6)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    /// A local endpoint: reads the request and its body, then answers `code`.
    async fn endpoint(code: &'static str) -> String {
        counted(code).await.0
    }

    /// The same, with how many uploads it got.
    async fn counted(code: &'static str) -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let at = l.local_addr().unwrap();
        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = hits.clone();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = l.accept().await {
                counter.fetch_add(1, Ordering::Relaxed);
                tokio::spawn(async move {
                    let mut buf = vec![];
                    let mut chunk = [0u8; 65536];
                    let need = loop {
                        let n = s.read(&mut chunk).await.unwrap();
                        buf.extend_from_slice(&chunk[..n]);
                        let text = String::from_utf8_lossy(&buf).to_string();
                        if let Some(end) = text.find("\r\n\r\n") {
                            let len: usize = text.lines().find_map(|l| l.strip_prefix("Content-Length: ")).unwrap().trim().parse().unwrap();
                            assert!(!text.to_lowercase().contains("user-agent"), "nothing identifying");
                            break end + 4 + len;
                        }
                    };
                    while buf.len() < need {
                        let n = s.read(&mut chunk).await.unwrap();
                        buf.extend_from_slice(&chunk[..n]);
                    }
                    let _ = s.write_all(format!("HTTP/1.1 {code}\r\nContent-Length: 0\r\n\r\n").as_bytes()).await;
                });
            }
        });
        (format!("http://{at}/__up"), hits)
    }

    #[tokio::test]
    async fn only_measures_when_routing_needs_it() {
        let (url, hits) = counted("200 OK").await;
        assert_eq!(round(&url, false).await, IDLE, "a main without a backup waits");
        assert_eq!(hits.load(Ordering::Relaxed), 0, "and uploads nothing");
        assert_eq!(round(&url, true).await, EVERY, "a backup (or a main with one) measures");
        assert_eq!(hits.load(Ordering::Relaxed), SAMPLES);
    }

    #[tokio::test]
    async fn measures_the_median_and_fails_to_unknown() {
        let m = measure(&endpoint("200 OK").await, 3, 256 << 10).await.unwrap();
        assert!(m > 0.0, "{m}");
        assert!(measure(&endpoint("502 Bad Gateway").await, 3, 1024).await.is_err());
        assert!(measure("http://127.0.0.1:1/__up", 1, 1024).await.is_err(), "nothing listening");
        assert_eq!(median(vec![30.0, 10.0, 20.0]), Some(20.0));
        assert_eq!(median(vec![]), None);
    }

    /// The real endpoint (network): `cargo test real_endpoint -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn real_endpoint() {
        let m = measure(URL, 1, 1 << 20).await.unwrap();
        assert!(m > 0.1, "{m}");
        eprintln!("upload: {m:.1} Mbit/s");
    }
}
