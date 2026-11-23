import CoreGraphics
import Foundation

/// A raw clip for tests: an ordinary movie's frames, with the info and sound a raw decoder would give.
private final class StandInRaw: RawSource, @unchecked Sendable {
    let inner: RawSource
    let info: RawClipInfo
    let sound: URL?

    init(_ movie: URL, info: (RawClipInfo) -> RawClipInfo, sound: URL? = nil) throws {
        inner = try MovieSource(url: movie)
        self.info = info(inner.info)
        self.sound = sound
    }

    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage { try inner.frame(index, scale: scale, settings: settings) }
    func displayFrame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage { try inner.displayFrame(index, scale: scale, settings: settings) }
    func close() { inner.close() }
    func audio() throws -> URL? { sound }
}

extension PhotoSelfTest {
    /// Raw clips in proxies and Sync (-PluckScreenshotOnly syncRaw): raw proxies keep every sound channel, the start
    /// timecode and the reel (stand-in decoder; the real Blackmagic sample when it's installed); a raw proxy without sound
    /// (older Macs) still conforms; Sync reads raw recording dates, slates and flashes through the raw decoder; a 23.976
    /// slate filmed at 25p reads as 23.976 (as 24 the place is 36 s off at 10:00:00:00), a long clip tells 24 from 23.976
    /// by itself, and a short one takes the reading its sound or the other slates agree with.
    @MainActor static func syncRawTest() async {
        let fm = FileManager.default
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("sync raw: ffmpeg", false, "no ffmpeg")
        }
        let work = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().appendingPathComponent("syncfix", isDirectory: true)
        let base = (fm.fileExists(atPath: work.deletingLastPathComponent().appendingPathComponent("st410.sh").path) ? work : URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("raw-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let opener = CameraSync.openRaw
        defer { try? fm.removeItem(at: base); CameraSync.openRaw = opener }
        func make(_ name: String, _ arguments: [String]) -> URL? {
            let out = base.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-y", "-v", "error"] + arguments + [out.path]
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            return process.terminationStatus == 0 ? out : nil
        }
        func tone(_ channels: Int) -> URL? {
            make("tone\(channels).wav", ["-f", "lavfi", "-i", "aevalsrc=" + (1...channels).map { "sin(\($0 * 110)*2*PI*t)" }.joined(separator: "|") + ":s=48000:d=2",
                                         "-c:a", "pcm_s24le"])
        }
        guard let picture = make("picture.mov", ["-f", "lavfi", "-i", "testsrc=s=640x360:r=25:d=2", "-c:v", "mpeg4", "-q:v", "4"]),
              let sixteen = tone(16), let two = tone(2) else { return check("sync raw: clips made", false) }

        // 1. Raw proxies: sound (every channel), timecode, reel.
        func rawInfo(_ channels: Int, timecode: String?) -> (RawClipInfo) -> RawClipInfo {
            { movie in
                var info = movie
                info.format = "braw"
                info.timecode = timecode
                info.audioChannels = channels
                info.meta = ["reel_name": "A001"]
                return info
            }
        }
        func proxy(_ name: String, _ format: OfficeProxies.Format, channels: Int, sound: URL?, timecode: String?) -> (made: Bool, facts: (fps: String, timecode: String?, aspect: Double?, audio: [Int]), reel: String?, target: URL) {
            let target = base.appendingPathComponent("Proxies/\(name).mov")
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let made = OfficeProxies.encodeRaw(base.appendingPathComponent("\(name).braw"), to: target, format: format, ffmpeg: ffmpeg, ffprobe: ffprobe,
                                               open: { _ in try StandInRaw(picture, info: rawInfo(channels, timecode: timecode), sound: sound) }, progress: { _ in })
            return (made, OfficeProxies.attachFacts(target, ffprobe: ffprobe), OfficeProxies.probe(target, ffprobe: ffprobe).3, target)
        }
        let many = proxy("Many", .light, channels: 16, sound: sixteen, timecode: "10:00:00:00")
        check("sync raw: a raw proxy has all 16 sound channels, the start timecode and the reel",
              many.made && many.facts.audio == [16] && many.facts.timecode == "10:00:00:00" && many.reel == "A001" && many.facts.fps == "25/1",
              "\(many.made) \(many.facts) \(many.reel ?? "-")")
        let stereo = proxy("Stereo", .stream, channels: 2, sound: two, timecode: "01:00:00:00")
        let prores = proxy("Pro", .prores, channels: 2, sound: two, timecode: "02:00:00:00")
        check("sync raw: stereo kept (stream as AAC, ProRes as PCM)",
              stereo.made && stereo.facts.audio == [2] && stereo.facts.timecode == "01:00:00:00" && prores.made && prores.facts.audio == [2]
              && prores.facts.timecode == "02:00:00:00",
              "\(stereo.facts) \(prores.facts)")
        let silent = proxy("Silent", .light, channels: 0, sound: nil, timecode: nil)
        check("sync raw: a raw clip without sound makes a proxy without sound", silent.made && silent.facts.audio.isEmpty, "\(silent.facts)")
        let wrong = proxy("Wrong", .light, channels: 4, sound: two, timecode: nil)
        check("sync raw: a raw proxy whose channels differ isn't put in place",
              !wrong.made && !fm.fileExists(atPath: wrong.target.path) && OfficeProxies.mismatches.withLock { $0[wrong.target.path] } != nil)
        let sample = URL(fileURLWithPath: "/Applications/Blackmagic RAW/Blackmagic RAW Speed Test.app/Contents/Resources/profile.braw")
        if RawHelperSource.helper != nil, RawHelperSource.formats.contains("braw"), fm.fileExists(atPath: sample.path) {
            let target = base.appendingPathComponent("Proxies/profile.mov")
            let made = OfficeProxies.encodeRaw(sample, to: target, format: .prores, ffmpeg: ffmpeg, ffprobe: ffprobe, progress: { _ in })
            let facts = OfficeProxies.attachFacts(target, ffprobe: ffprobe)
            check("sync raw: the real Blackmagic RAW sample's proxy has its 16 channels and timecode",
                  made && facts.audio == [16] && facts.timecode == "00:00:00:00", "\(made) \(facts)")
        } else {
            note("sync raw: no Blackmagic RAW sample or decoder here, the real-file proxy check skipped")
        }

        // 2. A raw proxy from an older Mac (no sound, no timecode) still conforms; an ordinary proxy's channels still count.
        let old = RemoteResolveProject.Clip(id: "1", name: "A001", file: "/p/A001.mov", audio: 0, timecode: "00:00:00:00")
        let raw = RemoteResolveProject.conform([old], swaps: ["/p/A001.mov": "/o/A001.braw"],
                                               originals: ["/o/A001.braw": .init(duration: nil, audio: 16, timecode: "10:00:00:00")])
        let plain = RemoteResolveProject.conform([old], swaps: ["/p/A001.mov": "/o/A001.mov"],
                                                 originals: ["/o/A001.mov": .init(duration: nil, audio: 16, timecode: "10:00:00:00")])
        check("sync raw: an older Mac's silent raw proxy is accepted, an ordinary proxy short of channels isn't",
              raw.problems.isEmpty && raw.swaps["1"] == "/o/A001.braw" && plain.problems.count == 1, "\(raw.problems) \(plain.problems)")

        // 3. Recording dates from raw metadata.
        let utc = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 5, day: 1, hour: 19, minute: 4, second: 5).date
        let local = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 5, day: 1, hour: 21, minute: 4, second: 5).date
        check("sync raw: RED GMT and local dates, Blackmagic's with a time; a date alone isn't a clock",
              CameraSync.rawDate(["gmt_date": "20260501", "gmt_time": "190405", "local_date": "20260501", "local_time": "210405"]) == utc
              && CameraSync.rawDate(["local_date": "20260501", "local_time": "210405"]) == local
              && CameraSync.rawDate(["date_recorded": "2026:05:01 21:04:05"]) == local
              && CameraSync.rawDate(["date_recorded": "2026:05:01"]) == nil && CameraSync.rawDate(["date_recorded": "Monday"]) == nil)
        CameraSync.openRaw = { _ in try StandInRaw(picture, info: { var i = $0; i.format = "r3d"; i.meta = ["gmt_date": "20260501", "gmt_time": "190405"]; return i }) }
        let probed = CameraSync.probe(base.appendingPathComponent("A001_C001.R3D"), root: base, ffprobe: ffprobe)?.clip
        check("sync raw: a RED clip's recording time from its metadata, not the file's", probed?.created == utc && probed?.clockFromFile == false,
              "\(String(describing: probed?.created)) \(probed?.clockFromFile ?? true)")

        // 4. Slates and 5. flashes through the raw decoder.
        let font = "fontfile=/System/Library/Fonts/Supplemental/Arial.ttf"
        func burn(_ rate: String, seconds: Int, then: String = "") -> [String] {
            ["-f", "lavfi", "-i", "testsrc=s=640x360:r=\(rate):d=\(seconds)", "-vf",
             "drawtext=\(font):timecode='10\\:00\\:00\\:00':rate=\(rate):fontsize=72:fontcolor=white:box=1:boxcolor=black@0.6:x=(w-tw)/2:y=(h-th)/2" + then,
             "-c:v", "mpeg4", "-q:v", "4"]
        }
        guard let slated = make("slate25.mov", burn("25", seconds: 12)),
              let flashing = make("flash.mov", ["-f", "lavfi", "-i", "color=c=0x202020:s=640x360:r=25:d=4", "-vf",
                                                "drawbox=x=0:y=0:w=640:h=360:color=white:t=fill:enable='eq(n,20)+eq(n,60)'", "-c:v", "mpeg4", "-q:v", "4"]),
              let ntscShort = make("ntsc30.mov", burn("24000/1001", seconds: 30, then: ",fps=25")),
              let ntscLong = make("ntsc120.mov", burn("24000/1001", seconds: 120, then: ",fps=25")),
              let filmLong = make("film120.mov", burn("24", seconds: 120, then: ",fps=25")) else { return check("sync raw: slate clips made", false) }
        // Each stand-in raw clip is the movie of the same name.
        CameraSync.openRaw = { url in try StandInRaw(base.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mov"), info: { var i = $0; i.format = "r3d"; return i }) }
        func clip(_ movie: URL, seconds: Double, raw: Bool = true) -> SyncClip {
            var clip = SyncClip(path: raw ? movie.deletingPathExtension().appendingPathExtension("R3D").path : movie.path)
            (clip.fps, clip.duration, clip.hasVideo) = (25, seconds, true)
            return clip
        }
        let read = await CameraSync.slate(clip(slated, seconds: 12), ffmpeg: ffmpeg)
        check("sync raw: a RED clip's slate read through the raw decoder", read.map { abs($0.value - 0.02 - 36000) < 1e-6 && $0.other == nil } ?? false,
              "\(read.map { "\($0.value) \($0.shown.prefix(3).map(\.text))" } ?? "none")")
        let fromRaw = await CameraSync.flashes(flashing.deletingPathExtension().appendingPathExtension("R3D"), ffmpeg: ffmpeg)
        let fromMovie = await CameraSync.flashes(flashing, ffmpeg: ffmpeg)
        func peaks(_ rises: [Float]?) -> [Int] { (rises ?? []).enumerated().filter { $0.element > 8 }.map(\.offset) }
        check("sync raw: a RED clip's flashes read through the raw decoder, as ffmpeg reads them",
              peaks(fromRaw) == [20, 60] && peaks(fromMovie) == [20, 60], "\(peaks(fromRaw)) \(peaks(fromMovie))")

        // 6. 23.976 or 24 on a 25p camera (10:00:00:00: 36036 s at 23.976, 36000 at 24).
        let short = await CameraSync.slate(clip(ntscShort, seconds: 30, raw: false), ffmpeg: ffmpeg)
        let ntsc = await CameraSync.slate(clip(ntscLong, seconds: 120, raw: false), ffmpeg: ffmpeg, thorough: true)
        let film = await CameraSync.slate(clip(filmLong, seconds: 120, raw: false), ffmpeg: ffmpeg, thorough: true)
        let half = 0.5 / 24
        check("sync raw: a 23.976 slate at 25p reads as 23.976 (not 36 s off), 24 kept as the other reading",
              short.map { abs($0.value - half - 36036) < 0.05 && $0.other.map { abs($0 - half - 36000) < 0.05 } == true && $0.ntsc == true } ?? false,
              "\(short.map { "\($0.value) \($0.other ?? -1) \($0.ntsc ?? false) \($0.shown.map { "\($0.frame) \($0.text)" })" } ?? "none")")
        check("sync raw: over two minutes the slate's own count tells 23.976 from 24",
              ntsc.map { abs($0.value - half - 36036) < 0.05 && $0.other == nil && $0.ntsc == true } ?? false
              && film.map { abs($0.value - half - 36000) < 0.05 && $0.other == nil && $0.ntsc == false } ?? false,
              "\(ntsc.map { "\($0.value) \($0.other ?? -1)" } ?? "none") \(film.map { "\($0.value) \($0.other ?? -1) \($0.shown.map { "\($0.frame) \($0.text) \($0.agrees)" })" } ?? "none")")

        // 7. A short clip's reading by other evidence (synthetic).
        func synced(_ name: String, slate: Double?, other: Double? = nil, ntsc: Bool? = nil, heard: Double? = nil) -> SyncClip {
            var clip = SyncClip(path: "/cards/\(name).mov")
            (clip.fps, clip.duration, clip.hasVideo, clip.slateChecked) = (25, 20, true, true)
            (clip.slate, clip.slateOther, clip.slateNTSC) = (slate, other, ntsc)
            clip.shown = [ShownTimecode(frame: 0, text: "", agrees: true), ShownTimecode(frame: 1, text: "", agrees: true)]
            if let heard { (clip.start, clip.method, clip.confidence, clip.hasAudio) = (heard, .audio, 0.9, true) }
            return clip
        }
        // Its sound puts it 50 s before the slate, as the sure slate's sound does: its second reading.
        var cameras = [SyncCamera(name: "A", key: "a", clips: [synced("a", slate: 100, ntsc: true, heard: 50)]),
                       SyncCamera(name: "B", key: "b", clips: [synced("b", slate: 236.2, other: 200, ntsc: true, heard: 150)])]
        let heardPlaces = cameras
        CameraSync.resolveSlates(&cameras, sound: heardPlaces)
        let bySound = cameras[1].clips[0]
        check("sync raw: the reading its sound agrees with", bySound.slate == 200 && bySound.slateOther == nil && bySound.slateNTSC == false,
              "\(bySound.slate ?? -1) \(bySound.slateOther ?? -1)")
        // No sound: the count the other slate was surely read in (24).
        cameras = [SyncCamera(name: "C", key: "c", clips: [synced("c", slate: 300, ntsc: false), synced("d", slate: 436.4, other: 400, ntsc: true)])]
        CameraSync.resolveSlates(&cameras, sound: cameras)
        check("sync raw: no sound: the count the other slates agree on", cameras[0].clips[1].slate == 400 && cameras[0].clips[1].slateNTSC == false,
              "\(cameras[0].clips[1].slate ?? -1)")
        // Nothing else: the first reading, placed but to check.
        cameras = [SyncCamera(name: "E", key: "e", clips: [synced("e", slate: 536.5, other: 500, ntsc: true)]),
                   SyncCamera(name: "F", key: "f", clips: [synced("f", slate: 600)])]
        CameraSync.resolveSlates(&cameras, sound: cameras)
        let placed = CameraSync.byTimecode(cameras, sound: cameras)
        let alone = placed?[0].clips[0], sure = placed?[1].clips[0]
        check("sync raw: nothing to tell: the 23.976 reading, low confidence", alone?.start == 536.5 && alone?.slateOther == 500 && alone?.quality == .fair && sure?.quality == .good,
              "\(alone?.start ?? -1) \(alone?.confidence ?? -1) \(sure?.confidence ?? -1)")
    }
}
