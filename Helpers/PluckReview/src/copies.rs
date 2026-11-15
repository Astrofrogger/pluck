// Host mode, publish by reference: the host makes review copies itself from originals on its own
// read-only media mount, with the spec §2 ffmpeg settings, one at a time. Output per version:
//   copies/<versionID>/{1080,540,360}/{init.mp4,media.m4s,index.m3u8,index.json}  (video; "a" for audio)
//   copies/<versionID>/{poster.jpg,strip.jpg}  or  image.jpg                    (images)
//   copies/<versionID>/pages/<n>.jpg + poster.jpg                               (documents: PDF pages)
//   copies/<versionID>/waveform.json  captions.vtt                              (audio peaks; a subtitle sidecar)
//   copies/<versionID>/wm-<linkID>/…   the same picture files with a link's watermark burned in
//   copies/<versionID>/ready.json  {"renditions":[…],"probe":{…}}               (written last)
use std::{
    path::{Path, PathBuf},
    process::Stdio,
};

use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::Command,
    sync::mpsc,
};

pub struct Job {
    pub version: String, // the jobs key: "<versionID>" or "<versionID>/wm-<linkID>"
    pub kind: String,    // video | audio | image | document
    pub src: PathBuf,    // canonical, inside the media root
    pub out: PathBuf,    // copies/<versionID> (or …/wm-<linkID>)
    pub captions: Option<PathBuf>, // a .vtt or .srt next to the source
    pub watermark: Option<(String, Value)>, // burned-in text, and the link's watermark settings
}

/// (versionID, {"state":"making"|"ready"|"failed","progress":0…1,"error"?})
pub type Progress = mpsc::UnboundedSender<(String, Value)>;

use crate::roots::tool;

pub async fn worker(mut jobs: mpsc::UnboundedReceiver<Job>, progress: Progress) {
    while let Some(j) = jobs.recv().await {
        let _ = progress.send((j.version.clone(), json!({"state": "making", "progress": 0.0})));
        let state = match make(&j, &progress).await {
            Ok(()) => json!({"state": "ready", "progress": 1.0}),
            Err(e) => json!({"state": "failed", "progress": 0.0, "error": failure(&j, &e)}),
        };
        let _ = progress.send((j.version, state));
    }
}

/// Why a copy failed, for status: a full disk says so (ffmpeg's own error is often a missing file then).
fn failure(j: &Job, e: &anyhow::Error) -> String {
    let dir = j.out.parent().unwrap_or(&j.out);
    match crate::upload_root::free_space(dir) {
        Some(free) if free < 256 << 20 => format!("the host's disk is full ({} MB free): {e:#}", free >> 20),
        _ => format!("{e:#}"),
    }
}

/// The longer side ≤ `edge`, never upscaled, both sides even.
pub fn fit(w: i64, h: i64, edge: i64) -> (i64, i64) {
    let s = (edge as f64 / w.max(h) as f64).min(1.0);
    let even = |x: i64| ((x as f64 * s / 2.0).round() as i64 * 2).max(2);
    (even(w), even(h))
}

/// ffprobe's JSON → the spec's Probe.
pub fn probe_from(p: &Value) -> Result<Value> {
    let streams = p["streams"].as_array().context("no streams")?;
    let v = streams.iter().find(|s| s["codec_type"] == "video" && s["disposition"]["attached_pic"] != 1);
    let has_audio = streams.iter().any(|s| s["codec_type"] == "audio");
    let duration: f64 = p["format"]["duration"].as_str().and_then(|d| d.parse().ok())
        .or_else(|| v.and_then(|v| v["duration"].as_str()?.parse().ok())).unwrap_or(0.0);
    let (mut num, mut den, mut w, mut h, mut tc) = (25, 1, 0, 0, None);
    if let Some(v) = v {
        if let Some((n, d)) = v["r_frame_rate"].as_str().and_then(|r| r.split_once('/')) {
            (num, den) = (n.parse().unwrap_or(25), d.parse().unwrap_or(1).max(1));
        }
        (w, h) = (v["width"].as_i64().unwrap_or(0), v["height"].as_i64().unwrap_or(0));
        let rot = v["tags"]["rotate"].as_str().and_then(|r| r.parse::<i64>().ok())
            .or_else(|| v["side_data_list"].as_array()?.iter().find_map(|s| s["rotation"].as_i64()))
            .unwrap_or(0);
        if rot.rem_euclid(180) == 90 {
            (w, h) = (h, w);
        }
        tc = v["tags"]["timecode"].as_str().map(str::to_owned);
    }
    let tc = tc.or_else(|| p["format"]["tags"]["timecode"].as_str().map(str::to_owned)).unwrap_or("00:00:00:00".into());
    let fps = num as f64 / den as f64;
    Ok(json!({"duration": duration, "fpsNum": num, "fpsDen": den, "width": w, "height": h,
        "dropFrame": tc.contains(';'), "startTimecode": tc, "hasAudio": has_audio,
        "frames": (duration * fps).round() as i64}))
}

/// The HLS playlist ffmpeg wrote → the spec's index.json.
pub fn index_from(m3u8: &str, dir: &Path, codecs: &str, probe: &Value, size: (i64, i64)) -> Result<Value> {
    let range = |s: &str, next: u64| -> Option<(u64, u64)> {
        let (len, off) = s.split_once('@').map_or((s, None), |(l, o)| (l, Some(o)));
        let len: u64 = len.trim().parse().ok()?;
        Some((off.map_or(Some(next), |o| o.trim().parse().ok())?, len))
    };
    let flen = |f: &str| std::fs::metadata(dir.join(f)).map(|m| m.len()).unwrap_or(0);
    let (mut init, mut segs, mut t, mut d, mut br, mut next) = (Value::Null, vec![], 0.0, None, None, 0u64);
    for l in m3u8.lines().map(str::trim) {
        if let Some(m) = l.strip_prefix("#EXT-X-MAP:") {
            let attr = |k: &str| m.split(',').find_map(|a| a.trim().strip_prefix(k)).map(|v| v.trim_matches('"').to_owned());
            let file = attr("URI=").context("map without URI")?;
            let (off, len) = attr("BYTERANGE=").and_then(|b| range(&b, 0)).unwrap_or((0, flen(&file)));
            init = json!({"file": file, "offset": off, "length": len});
        } else if let Some(x) = l.strip_prefix("#EXTINF:") {
            d = x.split(',').next().and_then(|x| x.parse::<f64>().ok());
        } else if let Some(x) = l.strip_prefix("#EXT-X-BYTERANGE:") {
            br = Some(x.to_owned());
        } else if !l.is_empty() && !l.starts_with('#') {
            let dur = d.take().context("segment without EXTINF")?;
            let (off, len) = match br.take() {
                Some(b) => range(&b, next).context("bad BYTERANGE")?,
                None => (0, flen(l)),
            };
            next = off + len;
            segs.push(json!({"t": t, "d": dur, "file": l, "offset": off, "length": len}));
            t += dur;
        }
    }
    ensure!(!init.is_null() && !segs.is_empty(), "playlist has no init or segments");
    Ok(json!({"codecs": codecs, "duration": probe["duration"], "fpsNum": probe["fpsNum"], "fpsDen": probe["fpsDen"],
        "width": size.0, "height": size.1, "init": init, "segments": segs}))
}

async fn run(args: Vec<String>, cwd: &Path, duration: f64, job: &Job, progress: &Progress, share: (f64, f64)) -> Result<()> {
    let mut c = Command::new(tool("ffmpeg"));
    c.current_dir(cwd); // HLS output names stay relative, as in the spec
    c.args(["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1"]).args(&args)
        .stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    let mut child = c.spawn().context("can't run ffmpeg")?;
    let mut out = BufReader::new(child.stdout.take().unwrap()).lines();
    let err = child.stderr.take().unwrap();
    let err_task = tokio::spawn(async move {
        let mut s = String::new();
        let _ = tokio::io::AsyncReadExt::read_to_string(&mut tokio::io::AsyncReadExt::take(err, 8192), &mut s).await;
        s
    });
    while let Ok(Some(l)) = out.next_line().await {
        if let Some(us) = l.strip_prefix("out_time_ms=").and_then(|x| x.parse::<f64>().ok()) {
            let f = (us / 1e6 / duration.max(0.001)).clamp(0.0, 1.0);
            let _ = progress.send((job.version.clone(), json!({"state": "making", "progress": share.0 + f * share.1})));
        }
    }
    let status = child.wait().await?;
    if !status.success() {
        bail!("ffmpeg failed: {}", err_task.await.unwrap_or_default().trim());
    }
    Ok(())
}

async fn make(job: &Job, progress: &Progress) -> Result<()> {
    let src = job.src.to_string_lossy().to_string();
    let out = Command::new(tool("ffprobe"))
        .args(["-v", "error", "-print_format", "json", "-show_streams", "-show_format", &src])
        .kill_on_drop(true).output().await.context("can't run ffprobe")?;
    ensure!(job.kind == "document" || out.status.success(), "ffprobe can't read the file");
    let mut probe = if job.kind == "document" { json!({"duration": 0.0, "frames": 0, "fpsNum": 25, "fpsDen": 1, "width": 0, "height": 0}) } else {
        probe_from(&serde_json::from_slice(&out.stdout)?)?
    };
    let tmp = job.out.with_extension("making");
    let _ = tokio::fs::remove_dir_all(&tmp).await;
    tokio::fs::create_dir_all(&tmp).await?;
    let s = |x: &str| x.to_owned();
    let dur = probe["duration"].as_f64().unwrap_or(0.0);
    // A burned watermark: one more filter at the end of every picture chain, text from a file.
    // ffmpeg runs in the rendition folder (HLS) or in tmp (stills), so the text file is named relative to that.
    let (wm_r, wm) = match &job.watermark {
        Some((text, settings)) => {
            ensure!(has_drawtext().await, "this ffmpeg can't burn in text (no drawtext filter; it needs libfreetype)");
            std::fs::write(tmp.join("wm.txt"), text)?;
            (format!(",{}", drawtext(settings, "../wm.txt")), format!(",{}", drawtext(settings, "wm.txt")))
        }
        None => (String::new(), String::new()),
    };
    let mut renditions = vec![];
    let hls = || -> Vec<String> {
        ["-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4", "-hls_flags", "single_file",
         "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", "media.m4s", "index.m3u8"].map(s).into()
    };
    match job.kind.as_str() {
        "video" => {
            let (w, h) = (probe["width"].as_i64().unwrap_or(0), probe["height"].as_i64().unwrap_or(0));
            ensure!(w > 0 && h > 0, "no picture size");
            let (num, den) = (probe["fpsNum"].as_i64().unwrap_or(25), probe["fpsDen"].as_i64().unwrap_or(1));
            let fast = num as f64 / den as f64 > 30.0;
            let g = (2.0 * num as f64 / den as f64).round().max(1.0).to_string();
            let audio = probe["hasAudio"].as_bool().unwrap_or(false);
            // 360: ≤ 0.4 Mbit/s in all, for slow lossy links (WebRTC goodput there is ~0.2–0.35 Mbit/s).
            let parts: [(&str, i64, &str, [&str; 3], &str, &str); 3] = [
                ("1080", 1920, "4.2", if fast { ["12M", "15M", "24M"] } else { ["8M", "10M", "16M"] }, "160k", "avc1.64002a"),
                ("540", 960, "3.2", if fast { ["3M", "3.75M", "6M"] } else { ["2M", "2.5M", "4M"] }, "128k", "avc1.640020"),
                ("360", 640, "3.1", ["330k", "380k", "660k"], "48k", "avc1.64001f"), // any frame rate, mono
            ];
            for (i, (r, edge, level, [b, max, buf], ab, avc)) in parts.into_iter().enumerate() {
                let dir = tmp.join(r);
                tokio::fs::create_dir_all(&dir).await?;
                let size = fit(w, h, edge);
                let mut a: Vec<String> = vec![s("-i"), src.clone(), s("-map"), s("0:v:0"), s("-map"), s("0:a:0?"), s("-sn"), s("-dn"),
                    s("-map_metadata"), s("-1"), s("-vf"), format!("scale={}:{}:flags=lanczos,format=yuv420p{wm_r}", size.0, size.1),
                    s("-fps_mode"), s("cfr"), s("-r"), format!("{num}/{den}"), s("-c:v"), s("libx264"), s("-preset"), s("medium"),
                    s("-profile:v"), s("high"), s("-level:v"), s(level), s("-b:v"), s(b), s("-maxrate"), s(max), s("-bufsize"), s(buf),
                    s("-g"), g.clone(), s("-keyint_min"), g.clone(), s("-sc_threshold"), s("0"), s("-bf"), s("0"),
                    s("-c:a"), s("aac"), s("-b:a"), s(ab), s("-ac"), s(if r == "360" { "1" } else { "2" }), s("-ar"), s("48000"), s("-avoid_negative_ts"), s("make_zero")];
                a.extend(hls());
                run(a, &dir, dur, job, progress, ([0.0, 0.55, 0.8][i], [0.55, 0.25, 0.1][i])).await?;
                let codecs = if audio { format!("{avc},mp4a.40.2") } else { avc.to_owned() };
                let idx = index_from(&std::fs::read_to_string(dir.join("index.m3u8"))?, &dir, &codecs, &probe, size)?;
                std::fs::write(dir.join("index.json"), idx.to_string())?;
                renditions.push(r);
            }
            let t = format!("{:.3}", dur * 0.1);
            run([s("-ss"), t, s("-i"), src.clone(), s("-frames:v"), s("1"), s("-vf"), format!("scale=640:-2{wm}"), s("-q:v"), s("4"),
                 s("poster.jpg")].into(), &tmp, dur, job, progress, (0.9, 0.0)).await?;
            let tiles = format!("fps=100/{:.3},scale=160:-2{wm},tile=10x10", dur.max(0.04));
            run([s("-i"), src.clone(), s("-vf"), tiles, s("-frames:v"), s("1"), s("-q:v"), s("5"),
                 s("strip.jpg")].into(), &tmp, dur, job, progress, (0.9, 0.1)).await?;
        }
        "audio" => {
            let dir = tmp.join("a");
            tokio::fs::create_dir_all(&dir).await?;
            let mut a = vec![s("-i"), src.clone(), s("-vn"), s("-map"), s("0:a:0"), s("-map_metadata"), s("-1"), s("-c:a"), s("aac"),
                s("-b:a"), s("192k"), s("-ac"), s("2"), s("-ar"), s("48000")];
            a.extend(hls());
            run(a, &dir, dur, job, progress, (0.0, 1.0)).await?;
            let idx = index_from(&std::fs::read_to_string(dir.join("index.m3u8"))?, &dir, "mp4a.40.2", &probe, (0, 0))?;
            std::fs::write(dir.join("index.json"), idx.to_string())?;
            renditions.push("a");
        }
        "image" => {
            let (w, h) = fit(probe["width"].as_i64().unwrap_or(2560), probe["height"].as_i64().unwrap_or(2560), 2560);
            run([s("-i"), src.clone(), s("-frames:v"), s("1"), s("-vf"), format!("scale={w}:{h}{wm}"), s("-q:v"), s("3"),
                 s("image.jpg")].into(), &tmp, 1.0, job, progress, (0.0, 1.0)).await?;
        }
        "document" => {
            let pages = pdf_pages(&job.src, &tmp).await?;
            probe["pages"] = json!(pages);
        }
        k => bail!("no review copy for kind {k}"),
    }
    if job.watermark.is_none() {
        if probe["hasAudio"] == true || job.kind == "audio" {
            let _ = progress.send((job.version.clone(), json!({"state": "making", "progress": 0.99})));
            match waveform(&job.src, dur).await {
                Ok(w) => std::fs::write(tmp.join("waveform.json"), w.to_string())?,
                Err(e) => crate::log(format!("waveform {}: {e:#}", job.version)), // the copy is still usable
            }
        }
        if let Some(c) = &job.captions {
            if let Some(vtt) = std::fs::read(c).ok().filter(|b| b.len() <= 2 << 20).and_then(|b| String::from_utf8(b).ok()) {
                let vtt = if c.extension().is_some_and(|e| e.eq_ignore_ascii_case("srt")) { srt_to_vtt(&vtt) } else { vtt };
                std::fs::write(tmp.join("captions.vtt"), vtt)?;
            }
        }
    }
    let mut ready = json!({"renditions": renditions, "probe": probe});
    if job.watermark.is_none() {
        // The original's SHA-256, for approval proofs (§13.8).
        let src = job.src.clone();
        if let Ok(Ok(h)) = tokio::task::spawn_blocking(move || crate::host::sha256_file(&src)).await {
            ready["sha256"] = json!(h);
        }
    }
    std::fs::write(tmp.join("ready.json"), ready.to_string())?;
    let _ = tokio::fs::remove_dir_all(&job.out).await;
    tokio::fs::rename(&tmp, &job.out).await?;
    Ok(())
}

/// A backup's quality (§13.3): "540|720|1080-low|medium|high". (rendition name, long side, level,
/// video kbit/s at ≤ 30 fps, audio). "same" isn't a transcode: None.
pub fn quality(q: &str) -> Option<(&'static str, i64, &'static str, u64, &'static str)> {
    let (b, lvl) = q.split_once('-')?;
    let i = ["low", "medium", "high"].iter().position(|x| *x == lvl)?;
    Some(match b {
        "540" => ("540", 960, "3.2", [800, 1200, 2000][i], "128k"),
        "720" => ("720", 1280, "3.2", [1500, 2500, 4000][i], ["128k", "128k", "160k"][i]),
        "1080" => ("1080", 1920, "4.2", [2500, 4000, 6000][i], ["128k", "128k", "160k"][i]),
        _ => return None,
    })
}

/// The ffmpeg arguments of a backup's one rendition: the §2 command with the quality's bitrate
/// (× 1.5 above 30 fps), -maxrate 1.25 × and -bufsize 2 × it.
pub fn replica_args(src: &str, q: &str, probe: &Value) -> Option<(Vec<String>, String, (i64, i64))> {
    let (_, edge, level, kbps, ab) = quality(q)?;
    let (w, h) = (probe["width"].as_i64().unwrap_or(0), probe["height"].as_i64().unwrap_or(0));
    if w <= 0 || h <= 0 {
        return None;
    }
    let (num, den) = (probe["fpsNum"].as_i64().unwrap_or(25).max(1), probe["fpsDen"].as_i64().unwrap_or(1).max(1));
    let fps = num as f64 / den as f64;
    let k = if fps > 30.0 { kbps * 3 / 2 } else { kbps };
    let g = (2.0 * fps).round().max(1.0).to_string();
    let size = fit(w, h, edge);
    let s = |x: &str| x.to_owned();
    let mut a: Vec<String> = vec![s("-i"), src.into(), s("-map"), s("0:v:0"), s("-map"), s("0:a:0?"), s("-sn"), s("-dn"),
        s("-map_metadata"), s("-1"), s("-vf"), format!("scale={}:{}:flags=lanczos,format=yuv420p", size.0, size.1),
        s("-fps_mode"), s("cfr"), s("-r"), format!("{num}/{den}"), s("-c:v"), s("libx264"), s("-preset"), s("medium"),
        s("-profile:v"), s("high"), s("-level:v"), s(level), s("-b:v"), format!("{k}k"), s("-maxrate"), format!("{}k", k * 5 / 4),
        s("-bufsize"), format!("{}k", k * 2), s("-g"), g.clone(), s("-keyint_min"), g, s("-sc_threshold"), s("0"), s("-bf"), s("0"),
        s("-c:a"), s("aac"), s("-b:a"), s(ab), s("-ac"), s("2"), s("-ar"), s("48000"), s("-avoid_negative_ts"), s("make_zero")];
    a.extend(["-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4", "-hls_flags", "single_file",
        "-hls_fmp4_init_filename", "init.mp4", "-hls_segment_filename", "media.m4s", "index.m3u8"].map(s));
    let avc = if level == "4.2" { "avc1.64002a" } else { "avc1.640020" };
    let codecs = if probe["hasAudio"] == false { avc.to_owned() } else { format!("{avc},mp4a.40.2") };
    Some((a, codecs, size))
}

/// Make a backup's rendition from `src` (the main's top rendition as one MP4) into `dir`.
pub async fn replica_rendition(src: &Path, dir: &Path, q: &str, probe: &Value) -> Result<()> {
    let (args, codecs, size) = replica_args(&src.to_string_lossy(), q, probe).context("no picture size or bad quality")?;
    tokio::fs::create_dir_all(dir).await?;
    let (tx, _rx) = mpsc::unbounded_channel();
    let job = Job { version: String::new(), kind: "video".into(), src: src.into(), out: dir.into(), captions: None, watermark: None };
    run(args, dir, probe["duration"].as_f64().unwrap_or(0.0), &job, &tx, (0.0, 1.0)).await?;
    let idx = index_from(&std::fs::read_to_string(dir.join("index.m3u8"))?, dir, &codecs, probe, size)?;
    std::fs::write(dir.join("index.json"), idx.to_string())?;
    Ok(())
}

/// The burned-in watermark filter (spec: shared with Swift). The text comes from a file, so
/// nothing in it is parsed by ffmpeg (expansion=none). Position: center | topLeft | topRight |
/// bottomLeft | bottomRight; size = text height as a share of the picture height; opacity 0…1.
pub fn drawtext(wm: &Value, textfile: &str) -> String {
    let opacity = wm["opacity"].as_f64().unwrap_or(0.25).clamp(0.05, 1.0);
    let size = wm["size"].as_f64().unwrap_or(0.03).clamp(0.01, 0.2);
    let m = "h*0.04";
    let (x, y) = match wm["position"].as_str().unwrap_or("") {
        "topLeft" => (m.into(), m.into()),
        "topRight" => (format!("w-text_w-{m}"), m.into()),
        "bottomLeft" => (m.into(), format!("h-text_h-{m}")),
        "bottomRight" => (format!("w-text_w-{m}"), format!("h-text_h-{m}")),
        _ => ("(w-text_w)/2".into(), "(h-text_h)/2".into()),
    };
    // Fixed paths without filter-graph special characters, so nothing needs escaping.
    let font = ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/System/Library/Fonts/Helvetica.ttc"].into_iter()
        .find(|p| Path::new(p).exists()).map_or(String::new(), |p| format!("fontfile={p}:"));
    format!("drawtext={font}textfile={textfile}:expansion=none:fontsize=h*{size:.4}:fontcolor=white@{opacity:.2}:borderw=1:bordercolor=black@{:.2}:x={x}:y={y}",
        opacity * 0.5)
}

pub async fn has_drawtext() -> bool {
    let out = Command::new(tool("ffmpeg")).args(["-hide_banner", "-filters"]).kill_on_drop(true).output().await;
    out.is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains(" drawtext "))
}

/// The watermark text for a burned copy: the link's template with {name} = the recipient (or the
/// link title), {link} = the title, {date} = today, {email} left out (a copy serves everyone on the link).
pub fn burned_text(template: &str, title: &str, recipient: Option<&str>, date: &str) -> String {
    let t = template.replace("{name}", recipient.unwrap_or(title)).replace("{link}", title).replace("{date}", date).replace("{email}", "");
    let parts: Vec<&str> = t.split('·').map(str::trim).filter(|p| !p.is_empty()).collect();
    parts.join(" · ").chars().filter(|c| !c.is_control()).take(200).collect()
}

/// PDF pages to pages/<n>.jpg (≤ 2560 px, poppler's pdftoppm) and a 640 px poster of page 1.
async fn pdf_pages(src: &Path, tmp: &Path) -> Result<usize> {
    let dir = tmp.join("pages");
    tokio::fs::create_dir_all(&dir).await?;
    let out = Command::new(tool("pdftoppm")).args(["-r", "150", "-jpeg", "-scale-to", "2560", "-l", "500"]).arg(src).arg(dir.join("p"))
        .kill_on_drop(true).output().await.context("can't run pdftoppm")?;
    ensure!(out.status.success(), "pdftoppm can't read the file: {}", String::from_utf8_lossy(&out.stderr).trim());
    // pdftoppm names pages p-1.jpg or p-01.jpg (zero-padded to the page count's width).
    let mut n = 0;
    for e in std::fs::read_dir(&dir)?.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let Some(num) = name.strip_prefix("p-").and_then(|x| x.strip_suffix(".jpg")).and_then(|x| x.parse::<usize>().ok()) else { continue };
        std::fs::rename(e.path(), dir.join(format!("{num}.jpg")))?;
        n = n.max(num);
    }
    ensure!(n > 0, "the PDF has no pages");
    let poster = Command::new(tool("pdftoppm")).args(["-jpeg", "-scale-to", "640", "-singlefile", "-f", "1", "-l", "1"]).arg(src).arg(tmp.join("poster"))
        .kill_on_drop(true).output().await.context("can't run pdftoppm")?;
    ensure!(poster.status.success(), "no poster");
    Ok(n)
}

pub const WAVE_BUCKETS: usize = 2000;

/// Peaks of 16-bit mono samples in `buckets` buckets, 0…255.
pub fn peaks(samples: &[i16], buckets: usize) -> Vec<u8> {
    let n = samples.len();
    (0..buckets.min(n)).map(|i| {
        let s = &samples[i * n / buckets.min(n)..(i + 1) * n / buckets.min(n)];
        let m = s.iter().map(|x| x.unsigned_abs()).max().unwrap_or(0) as u32;
        (m * 255 / 32768) as u8
    }).collect()
}

/// waveform.json: {"buckets","peaks":[0…255],"channels":1}, from the first audio track at 8 kHz
/// mono. Samples are folded into ≤ 64 k sub-peaks as they arrive, so memory stays flat.
async fn waveform(src: &Path, duration: f64) -> Result<Value> {
    use tokio::io::AsyncReadExt;
    let mut child = Command::new(tool("ffmpeg")).args(["-hide_banner", "-nostdin", "-loglevel", "error", "-i"]).arg(src)
        .args(["-vn", "-map", "0:a:0", "-ac", "1", "-ar", "8000", "-f", "s16le", "pipe:1"])
        .stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true).spawn().context("can't run ffmpeg")?;
    let mut out = child.stdout.take().unwrap();
    let per = ((duration.max(0.1) * 8000.0) as usize / 65_536).max(1);
    let (mut sub, mut cur, mut k, mut buf, mut odd) = (Vec::<i16>::new(), 0i16, 0usize, vec![0u8; 1 << 16], None::<u8>);
    loop {
        let n = out.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        let mut bytes = &buf[..n];
        let joined;
        if let Some(b) = odd.take() {
            joined = [&[b], bytes].concat();
            bytes = &joined;
        }
        for pair in bytes.chunks(2) {
            let [lo, hi] = pair else { odd = Some(pair[0]); break };
            let x = i16::from_le_bytes([*lo, *hi]);
            if x.unsigned_abs() > cur.unsigned_abs() {
                cur = x;
            }
            k += 1;
            if k == per {
                sub.push(cur);
                (cur, k) = (0, 0);
            }
        }
    }
    if k > 0 {
        sub.push(cur);
    }
    ensure!(child.wait().await?.success() && !sub.is_empty(), "no audio");
    let p = peaks(&sub, WAVE_BUCKETS);
    Ok(json!({"buckets": p.len(), "peaks": p, "channels": 1}))
}

/// SubRip to WebVTT: a header, and "," → "." in the cue timings.
pub fn srt_to_vtt(srt: &str) -> String {
    let mut out = String::from("WEBVTT\n\n");
    for l in srt.trim_start_matches('\u{feff}').lines() {
        if l.contains("-->") {
            out.push_str(&l.replace(',', "."));
        } else {
            out.push_str(l);
        }
        out.push('\n');
    }
    out
}

/// One frame of a review copy as a JPEG ≤ 1920 px wide (the still download).
pub async fn still(input: &Path, t: f64, out: &Path) -> Result<()> {
    let r = Command::new(tool("ffmpeg")).args(["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", &format!("{t:.3}"), "-i"]).arg(input)
        .args(["-frames:v", "1", "-vf", "scale='min(1920,iw)':-2", "-q:v", "3", "-f", "image2", "-c:v", "mjpeg"]).arg(out)
        .kill_on_drop(true).output().await.context("can't run ffmpeg")?;
    ensure!(r.status.success(), "ffmpeg: {}", String::from_utf8_lossy(&r.stderr).trim());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backup_qualities() {
        assert_eq!(quality("1080-low"), Some(("1080", 1920, "4.2", 2500, "128k")));
        assert_eq!(quality("540-high").unwrap().3, 2000);
        assert!(quality("same").is_none() && quality("1080-max").is_none());
        let p = json!({"width": 3840, "height": 2160, "fpsNum": 50, "fpsDen": 1, "duration": 10.0});
        let (a, codecs, size) = replica_args("in.mp4", "720-medium", &p).unwrap();
        let at = |k: &str| a[a.iter().position(|x| x == k).unwrap() + 1].clone();
        assert_eq!((at("-b:v"), at("-maxrate"), at("-bufsize")), ("3750k".into(), "4687k".into(), "7500k".into()), "50 fps: × 1.5");
        assert_eq!((size, at("-level:v"), at("-bf")), ((1280, 720), "3.2".into(), "0".into()));
        assert_eq!(codecs, "avc1.640020,mp4a.40.2");
        let (_, _, small) = replica_args("in.mp4", "1080-low", &json!({"width": 1280, "height": 720})).unwrap();
        assert_eq!(small, (1280, 720), "never upscaled");
    }

    #[test]
    fn sizes() {
        assert_eq!(fit(3840, 2160, 1920), (1920, 1080));
        assert_eq!(fit(1280, 720, 1920), (1280, 720), "never upscales");
        assert_eq!(fit(1080, 1920, 960), (540, 960));
        assert_eq!(fit(1920, 1080, 640), (640, 360), "the 360 copy");
        assert_eq!(fit(1001, 563, 1920), (1002, 564), "even");
    }

    #[test]
    fn probe() {
        let p = json!({"format": {"duration": "10.010000", "tags": {"timecode": "01:00:00;00"}},
            "streams": [{"codec_type": "video", "r_frame_rate": "30000/1001", "width": 1920, "height": 1080,
                         "side_data_list": [{"rotation": -90}]}, {"codec_type": "audio"}]});
        let p = probe_from(&p).unwrap();
        assert_eq!((p["width"].as_i64(), p["height"].as_i64()), (Some(1080), Some(1920)));
        assert_eq!(p["fpsNum"], 30000);
        assert_eq!(p["dropFrame"], true);
        assert_eq!(p["frames"], 300);
        assert_eq!(p["hasAudio"], true);
    }

    #[test]
    fn playlist() {
        let m = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2.000000,\n#EXT-X-BYTERANGE:1987654@0\nmedia.m4s\n\
                 #EXTINF:2.000000,\n#EXT-X-BYTERANGE:2011200\nmedia.m4s\n#EXT-X-ENDLIST\n";
        let i = index_from(m, Path::new("/nonexistent"), "avc1.64002a", &json!({"duration": 4.0, "fpsNum": 25, "fpsDen": 1}), (1920, 1080)).unwrap();
        assert_eq!(i["segments"][1]["offset"], 1987654, "offset continues when left out");
        assert_eq!(i["segments"][1]["t"], 2.0);
        assert_eq!(i["init"]["file"], "init.mp4");
        let m2 = "#EXT-X-MAP:URI=\"media.m4s\",BYTERANGE=\"1403@0\"\n#EXTINF:2,\n#EXT-X-BYTERANGE:100@1403\nmedia.m4s\n";
        let i = index_from(m2, Path::new("/x"), "c", &json!({}), (0, 0)).unwrap();
        assert_eq!(i["init"]["length"], 1403);
        assert_eq!(i["segments"][0]["offset"], 1403);
    }

    #[test]
    fn watermark_text_and_filter() {
        assert_eq!(burned_text("{name} · {email} · {date}", "Cuts", Some("Anna"), "2026-11-16"), "Anna · 2026-11-16");
        assert_eq!(burned_text("{name} · {link}", "Cuts", None, "x"), "Cuts · Cuts");
        let f = drawtext(&json!({"position": "bottomRight", "opacity": 0.5, "size": 0.05}), "../wm.txt");
        assert!(f.starts_with("drawtext=") && f.contains("textfile=../wm.txt:") && f.contains("expansion=none"), "{f}");
        assert!(f.contains("fontcolor=white@0.50") && f.contains("x=w-text_w-h*0.04"), "{f}");
        assert!(!f.contains(','), "one filter, no commas: {f}");
    }

    #[test]
    fn waveform_peaks_and_subtitles() {
        let s: Vec<i16> = (0..10_000).map(|i| if i == 5000 { i16::MIN } else { (i % 100) as i16 }).collect();
        let p = peaks(&s, 2000);
        assert_eq!(p.len(), 2000);
        assert_eq!(p[1000], 255);
        assert_eq!(peaks(&[100, -200], 2000).len(), 2, "fewer samples than buckets");
        let v = srt_to_vtt("\u{feff}1\n00:00:01,000 --> 00:00:02,500\nHello, there\n");
        assert_eq!(v, "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500\nHello, there\n");
    }

    /// A minimal one-page PDF, with a correct xref table.
    fn tiny_pdf() -> Vec<u8> {
        let objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] >>"];
        let mut out = b"%PDF-1.4\n".to_vec();
        let mut offs = vec![];
        for (i, o) in objs.iter().enumerate() {
            offs.push(out.len());
            out.extend(format!("{} 0 obj\n{o}\nendobj\n", i + 1).bytes());
        }
        let xref = out.len();
        out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).bytes());
        for o in offs {
            out.extend(format!("{o:010} 00000 n \n").bytes());
        }
        out.extend(format!("trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).bytes());
        out
    }

    /// The real tools: a clip with a subtitle sidecar (copies, waveform, captions, a still from the
    /// HLS copy), a burned watermark when this ffmpeg can draw text, and a PDF when pdftoppm is here.
    #[tokio::test]
    async fn real_copies_with_extras() {
        if std::process::Command::new(tool("ffmpeg")).arg("-version").output().is_err() {
            return eprintln!("ffmpeg not installed: skipped");
        }
        let base = std::env::temp_dir().join(format!("pluck-copies-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let clip = base.join("clip.mp4");
        assert!(std::process::Command::new(tool("ffmpeg")).args(["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]).arg(&clip).status().unwrap().success());
        std::fs::write(base.join("clip.srt"), "1\n00:00:00,500 --> 00:00:01,500\nHi\n").unwrap();
        let (tx, _rx) = mpsc::unbounded_channel();
        let job = Job { version: "V".into(), kind: "video".into(), src: clip.clone(), out: base.join("copies/V"), captions: Some(base.join("clip.srt")), watermark: None };
        make(&job, &tx).await.unwrap();
        let out = base.join("copies/V");
        let ready: Value = serde_json::from_slice(&std::fs::read(out.join("ready.json")).unwrap()).unwrap();
        assert_eq!(ready["renditions"], json!(["1080", "540", "360"]));
        let low: Value = serde_json::from_slice(&std::fs::read(out.join("360/index.json")).unwrap()).unwrap();
        assert!(low["codecs"] == "avc1.64001f,mp4a.40.2" && low["width"] == 640 && !low["segments"].as_array().unwrap().is_empty(), "{low}");
        let w: Value = serde_json::from_slice(&std::fs::read(out.join("waveform.json")).unwrap()).unwrap();
        assert_eq!(w["buckets"], 2000);
        assert!(w["peaks"].as_array().unwrap().iter().any(|p| p.as_u64().unwrap() > 20), "a sine at ffmpeg's default 1/8 level");
        assert!(std::fs::read_to_string(out.join("captions.vtt")).unwrap().starts_with("WEBVTT\n\n1\n00:00:00.500 -->"));
        let still_path = base.join("still.jpg");
        still(&out.join("1080/index.m3u8"), 1.0, &still_path).await.unwrap();
        assert!(std::fs::read(&still_path).unwrap().starts_with(&[0xFF, 0xD8, 0xFF]));
        let wm = Job { version: "V/wm-L".into(), kind: "video".into(), src: clip, out: out.join("wm-L"), captions: None,
            watermark: Some(("Anna · 2026-11-16".into(), json!({"position": "bottomRight", "opacity": 0.3}))) };
        match make(&wm, &tx).await {
            Ok(()) => assert!(out.join("wm-L/poster.jpg").exists() && out.join("wm-L/1080/index.json").exists() && !out.join("wm-L/waveform.json").exists()),
            Err(e) if !has_drawtext().await => eprintln!("burned watermark skipped: {e:#}"),
            Err(e) => panic!("{e:#}"),
        }
        assert!(out.join("1080/index.json").exists(), "the plain copy survives a watermark job");
        // A backup's rendition, from the 1080 copy as one MP4 (init, then the segments), at 540-low.
        let idx: Value = serde_json::from_slice(&std::fs::read(out.join("1080/index.json")).unwrap()).unwrap();
        let mut one = vec![];
        for p in std::iter::once(&idx["init"]).chain(idx["segments"].as_array().unwrap()) {
            let b = std::fs::read(out.join("1080").join(p["file"].as_str().unwrap())).unwrap();
            let (o, n) = (p["offset"].as_u64().unwrap() as usize, p["length"].as_u64().unwrap() as usize);
            one.extend_from_slice(&b[o..o + n]);
        }
        std::fs::write(base.join("top.mp4"), one).unwrap();
        let probe = json!({"width": 640, "height": 360, "fpsNum": 25, "fpsDen": 1, "duration": 3.0, "hasAudio": true});
        replica_rendition(&base.join("top.mp4"), &base.join("replica/540"), "540-low", &probe).await.unwrap();
        let r: Value = serde_json::from_slice(&std::fs::read(base.join("replica/540/index.json")).unwrap()).unwrap();
        assert!(r["segments"].as_array().unwrap().len() >= 1 && r["codecs"] == "avc1.640020,mp4a.40.2", "{r}");
        if std::process::Command::new(tool("pdftoppm")).arg("-v").output().is_ok() {
            let pdf = base.join("doc.pdf");
            std::fs::write(&pdf, tiny_pdf()).unwrap();
            let doc = Job { version: "D".into(), kind: "document".into(), src: pdf, out: base.join("copies/D"), captions: None, watermark: None };
            make(&doc, &tx).await.unwrap();
            let ready: Value = serde_json::from_slice(&std::fs::read(base.join("copies/D/ready.json")).unwrap()).unwrap();
            assert_eq!(ready["probe"]["pages"], 1);
            assert!(base.join("copies/D/pages/1.jpg").exists() && base.join("copies/D/poster.jpg").exists());
        }
        let _ = std::fs::remove_dir_all(base);
    }
}
