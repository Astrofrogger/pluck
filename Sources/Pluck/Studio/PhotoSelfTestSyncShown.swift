import Foundation

extension PhotoSelfTest {
    /// Sync Cameras' "Timecode on camera" (-PluckScreenshotOnly syncShown): silent clips made with ffmpeg that burn a
    /// running timecode in (drawtext) at different start timecodes, a phone-like slate held up for the first seconds,
    /// 29.97 drop frame crossing a dropped minute, one clip with none, one showing it in a single frame, one small and
    /// blurred. Checks the start timecode read (exact), the places it gives (exact), the confidence, and the parsing.
    @MainActor static func syncShownTest() async {
        let fm = FileManager.default
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("sync shown: ffmpeg", false, "no ffmpeg")
        }
        syncRatesTest()
        // Parsing and drop frame.
        check("sync shown: timecode text parsed (: ; . and spaces), letters refused",
              CameraSync.parseTimecode("10:00:51:03") == [10, 0, 51, 3] && CameraSync.parseTimecode("01:00:00;02") == [1, 0, 0, 2]
              && CameraSync.parseTimecode("23.59.59.24") == [23, 59, 59, 24] && CameraSync.parseTimecode("10 00 51 03") == [10, 0, 51, 3]
              && CameraSync.parseTimecode("TC 10:00:51:03") == nil && CameraSync.parseTimecode("25:00:00:00") == nil && CameraSync.parseTimecode("10:00:51") == nil)
        let df = CameraSync.shownSeconds([0, 1, 0, 2], drop: true, rate: 30, fractional: true)
        let df10 = CameraSync.shownSeconds([0, 10, 0, 0], drop: true, rate: 30, fractional: true)
        let ndf = CameraSync.shownSeconds([0, 1, 0, 2], drop: false, rate: 30, fractional: true)
        check("sync shown: drop frame counted (00:01:00;02 is frame 1800, 00:10:00;00 frame 17982)",
              abs(df - 1800 * 1001 / 30000.0) < 1e-9 && abs(df10 - 17982 * 1001 / 30000.0) < 1e-9 && abs(ndf - 1802 * 1001 / 30000.0) < 1e-9
              && CameraSync.timecodeText([0, 1, 0, 2], drop: true) == "00:01:00;02", "\(df) \(df10) \(ndf)")

        let work = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().appendingPathComponent("syncfix", isDirectory: true)
        let base = (fm.fileExists(atPath: work.deletingLastPathComponent().appendingPathComponent("st410.sh").path) ? work : URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("shown-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let font = "fontfile=/System/Library/Fonts/Supplemental/Arial.ttf"
        struct Made { var folder: String; var tc: String?; var rate: String; var filter: String; var seconds = 24.0 }
        func burn(_ tc: String, rate: String, size: Int = 72, extra: String = "") -> String {
            "drawtext=\(font):timecode='\(tc.replacingOccurrences(of: ":", with: "\\:"))':rate=\(rate):fontsize=\(size):fontcolor=white:box=1:boxcolor=black@0.6:x=(w-tw)/2:y=(h-th)/2\(extra)"
        }
        let made: [Made] = [
            Made(folder: "Cam1", tc: "10:00:00:00", rate: "25", filter: burn("10:00:00:00", rate: "25")),
            Made(folder: "Cam2", tc: "10:00:07:13", rate: "25", filter: burn("10:00:07:13", rate: "25", size: 96)),
            // A phone held up in a corner for the first four seconds: a dark screen, smaller digits.
            Made(folder: "Phone", tc: "09:59:58:12", rate: "25", filter: "drawbox=x=420:y=40:w=190:h=300:color=0x101010:t=fill:enable='lt(t,4)',drawbox=x=420:y=40:w=190:h=300:color=0xC0C0C0:t=4:enable='lt(t,4)',"
                 + "drawtext=\(font):timecode='09\\:59\\:58\\:12':rate=25:fontsize=30:fontcolor=white:x=428:y=170:enable='lt(t,4)'"),
            // 29.97 drop frame: the last ten seconds cross 00:01:00, whose ;00 and ;01 don't exist.
            Made(folder: "DF", tc: "00:00:45;00", rate: "30000/1001", filter: burn("00:00:45;00", rate: "30000/1001")),
            // A 50p camera filming a 25 fps slate: each slate frame shown twice, never past frame 24.
            Made(folder: "Fifty", tc: "10:00:02:00", rate: "25", filter: burn("10:00:02:00", rate: "25") + ",fps=50"),
            Made(folder: "None", tc: nil, rate: "25", filter: "null"),
            Made(folder: "Once", tc: "10:00:03:00", rate: "25", filter: burn("10:00:03:00", rate: "25", extra: ":enable='eq(n,0)'")),
            Made(folder: "Blur", tc: "10:00:05:00", rate: "25", filter: burn("10:00:05:00", rate: "25", size: 11) + ",gblur=sigma=2.2"),
        ]
        for clip in made {
            let folder = base.appendingPathComponent(clip.folder, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=s=640x360:r=\(clip.rate):d=\(clip.seconds)",
                                 "-vf", clip.filter, "-c:v", "mpeg4", "-q:v", "4", folder.appendingPathComponent("clip.mov").path]
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return check("sync shown: clips made", false, clip.folder) }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return check("sync shown: clips made", false, clip.folder) }
        }
        let probes = CameraSync.files(in: [base]).compactMap { CameraSync.probe($0.file, root: $0.root, ffprobe: ffprobe) }
        let cameras = CameraSync.group(probes)
        func folder(_ clip: SyncClip) -> String { clip.file.deletingLastPathComponent().lastPathComponent }
        let started = Date()
        let synced = await CameraSync.sync(cameras, options: .init(ffmpeg: ffmpeg, sound: { _ in nil }, shownTimecode: true)).flatMap(\.clips)
        note("sync shown: read and synced \(synced.count) clips in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        func clip(_ name: String) -> SyncClip? { synced.first { folder($0) == name } }
        func expected(_ made: Made) -> Double? {
            guard let tc = made.tc, let parts = CameraSync.parseTimecode(tc) else { return nil }
            return CameraSync.shownSeconds(parts, drop: tc.contains(";"), rate: made.rate == "25" ? 25 : 30, fractional: made.rate != "25")
        }
        func rate(_ made: Made) -> Double { made.rate == "25" ? 25 : 30 }
        // The start timecode read: the slate value less the half frame it adds.
        for name in ["Cam1", "Cam2", "Phone", "DF", "Fifty"] {
            guard let made = made.first(where: { $0.folder == name }), let truth = expected(made), let found = clip(name) else { continue }
            let read = found.slate.map { $0 - 0.5 / rate(made) }
            check("sync shown: \(name) start timecode read exactly", read.map { abs($0 - truth) < 1e-6 } ?? false,
                  "\(read ?? -1) vs \(truth); \(found.shown.prefix(4).map { "\($0.frame) \($0.text) \($0.agrees)" })")
            check("sync shown: \(name) by the timecode shown, sure", found.method == .slate && found.quality == .good && found.shown.filter(\.agrees).count >= 2,
                  "\(found.method?.rawValue ?? "-") \(found.confidence) \(found.shown.filter(\.agrees).count) agree")
        }
        let dropped = clip("DF")?.shown ?? []
        check("sync shown: drop frame read past a dropped minute, every reading agreeing", dropped.count >= 3 && dropped.allSatisfy(\.agrees)
              && dropped.contains { $0.text.hasPrefix("00:01:0") && $0.text.contains(";") }, dropped.map { "\($0.frame) \($0.text) \($0.agrees)" }.joined(separator: ", "))
        // The places: exactly the timecodes apart.
        if let one = clip("Cam1")?.start, let truth1 = expected(made[0]) {
            let apart = ["Cam2", "Phone", "DF", "Fifty"].compactMap { name -> String? in
                guard let m = made.first(where: { $0.folder == name }), let truth = expected(m), let start = clip(name)?.start else { return "\(name) not placed" }
                // (The half frame added differs between 25 and 29.97.)
                let wanted = truth - truth1 + 0.5 / rate(m) - 0.5 / 25
                return abs((start - one) - wanted) < 1e-6 ? nil : "\(name) \(start - one) vs \(wanted)"
            }
            check("sync shown: clips placed exactly the shown timecodes apart", apart.isEmpty, apart.joined(separator: "; "))
        } else {
            check("sync shown: Cam1 placed", false)
        }
        let none = clip("None"), once = clip("Once"), blur = clip("Blur")
        let onceTruth = made.first { $0.folder == "Once" }.flatMap(expected) ?? 0, blurTruth = made.first { $0.folder == "Blur" }.flatMap(expected) ?? 0
        check("sync shown: a clip with no timecode has none", none != nil && none?.slate == nil && none?.shown.isEmpty == true && none?.method != .slate, "\(none?.shown.count ?? -1)")
        check("sync shown: read in one frame only: placed, to check", once?.method == .slate && once?.quality == .fair && once?.shown.count == 1
              && once.flatMap { c in c.slate.map { abs($0 - 0.02 - onceTruth) < 1e-6 } } == true,
              "\(once?.method?.rawValue ?? "-") \(once?.confidence ?? -1) \(once?.shown.map(\.text) ?? [])")
        let blurRight = blur?.slate.map { abs($0 - 0.02 - blurTruth) < 0.04 } ?? true
        check("sync shown: small and blurred: not sure, never wrong", blur != nil && (blur?.method != .slate || blur?.quality != .good) && blurRight,
              "\(blur?.quality == .good) \(blur?.shown.map(\.text) ?? [])")
        // Off: only the quick look (first frame and near the end), two readings needed.
        let quick = await CameraSync.sync(cameras, options: .init(ffmpeg: ffmpeg, sound: { _ in nil })).flatMap(\.clips)
        let quickOnce = quick.first { folder($0) == "Once" }, quickCam = quick.first { folder($0) == "Cam1" }
        check("sync shown: off, a single reading isn't used; burned-in timecode still is", quickOnce?.slate == nil && quickCam?.method == .slate,
              "\(quickOnce?.slate ?? -1) \(quickCam?.method?.rawValue ?? "-")")
        // The page's switch reads clips again.
        let model = CameraSyncModel()
        model.cameras = synced.isEmpty ? [] : [SyncCamera(name: "A", key: "a", clips: [synced[0]])]
        model.shownTimecode = true
        check("sync shown: turning it on reads the clips again", model.clips.allSatisfy { !$0.slateChecked })
    }
}
