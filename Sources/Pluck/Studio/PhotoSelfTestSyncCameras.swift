import Foundation

extension PhotoSelfTest {
    /// Sync Cameras (-PluckScreenshotOnly syncCameras): a three-minute "set" (beats, noise, random
    /// hits and notes) made here, filmed by cameras in overlapping clips at random, non-frame
    /// offsets, each with its own level, EQ and noise: B's two cards with the same serial number,
    /// C and E jam-synced timecode (C's second clip nearly silent), F's timecode 3.2 s off, H's
    /// timecode jumping on its third clip, D running 0.1% fast, a silent 30 fps drone, three silent
    /// cameras showing a timecode slate (C's slate 3 frames off), and R with a clock an hour off
    /// whose second clip nothing confirms. Every camera but the slates and R2 sees the same white
    /// flashes. Checks the grouping, every clip's place (a frame; 1 ms by sound) and method, the
    /// drift, the rough place, slate check, sound first, and the FCPXML and Resolve placements and start.
    static func syncCamerasTest() async {
        let fm = FileManager.default
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") else {
            return check("sync: ffmpeg", false, "no ffmpeg")
        }
        await syncProxiesTest(ffmpeg: ffmpeg)
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("SyncCamerasTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        // The set, at 16 kHz.
        var seed: UInt64 = 0x5EED
        func random() -> Double {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double(z ^ (z >> 31)) / Double(UInt64.max)
        }
        let rate = 16000.0, length = 180.0, beat = 60 / 125.0
        var set = [Float](repeating: 0, count: Int(length * rate))
        func add(at time: Double, seconds: Double, _ sound: (Double) -> Double) {
            let from = Int(time * rate)
            for n in 0..<Int(seconds * rate) where from + n < set.count { set[from + n] += Float(sound(Double(n) / rate)) }
        }
        var t = 0.0
        while t < length {
            add(at: t, seconds: 0.25) { 0.6 * sin(2 * .pi * (50 + 60 * exp(-$0 * 30)) * $0) * exp(-$0 * 12) }
            add(at: t + beat / 2, seconds: 0.03) { _ in 0.15 * (random() * 2 - 1) }
            if random() < 0.35 { add(at: t + beat * (random() < 0.5 ? 0.25 : 0.75), seconds: 0.12) { 0.3 * (random() * 2 - 1) * exp(-$0 * 25) } }
            if random() < 0.6 {
                let pitch = 300 + random() * 1200
                add(at: t + random() * beat, seconds: 0.2) { 0.2 * sin(2 * .pi * pitch * $0) * exp(-$0 * 10) }
            }
            t += beat
        }
        for n in set.indices { set[n] += Float(0.02 * (random() * 2 - 1)) }
        let flashes: [Double] = {
            var times: [Double] = [], at = 3.0
            while at < length - 3 { times.append(at + random() * 2); at += 6 + random() * 6 }
            return times
        }()

        struct Shot { var folder: String; var name: String; var s0: Double; var length: Double; var drift = 0.0; var gain = 1.0
            var filter = 0; var noise = 0.0; var silent = false; var serial: String?; var timecode = false; var fps = 25; var audio = true
            /// Timecode written this far from the truth; a slate shown this many frames off (nil: none); a clock this far off (nil: no date).
            var tcShift = 0.0; var slate: Int?; var clock: Double?; var flashes = true }
        let shots = [
            Shot(folder: "CamA", name: "A001.mov", s0: 2.37, length: 92.7),
            Shot(folder: "CamA", name: "A002.mov", s0: 100.53, length: 77.6),
            Shot(folder: "CamB card1", name: "C0001.mov", s0: 10.813, length: 59.6, gain: 0.25, filter: 1, noise: 0.01, serial: "B-1234"),
            Shot(folder: "CamB card2", name: "C0002.mov", s0: 80.137, length: 90.7, gain: 0.25, filter: 1, noise: 0.01, serial: "B-1234"),
            Shot(folder: "CamC", name: "C1.mov", s0: 30.28, length: 90.3, gain: 0.7, filter: 2, noise: 0.03, timecode: true),
            Shot(folder: "CamC", name: "C2.mov", s0: 130.76, length: 29.4, silent: true, timecode: true),
            Shot(folder: "CamE", name: "E1.mov", s0: 20.4, length: 45, gain: 0.8, noise: 0.01, timecode: true),
            Shot(folder: "CamE", name: "E2.mov", s0: 95, length: 40, gain: 0.8, noise: 0.01, timecode: true),
            Shot(folder: "CamF", name: "F1.mov", s0: 45.12, length: 45, gain: 0.6, filter: 2, noise: 0.01, timecode: true, tcShift: 3.2),
            Shot(folder: "CamF", name: "F2.mov", s0: 115, length: 40, gain: 0.6, filter: 2, noise: 0.01, timecode: true, tcShift: 3.2),
            Shot(folder: "CamH", name: "H1.mov", s0: 12, length: 35, gain: 0.9, noise: 0.01, timecode: true),
            Shot(folder: "CamH", name: "H2.mov", s0: 60, length: 35, gain: 0.9, noise: 0.01, timecode: true),
            Shot(folder: "CamH", name: "H3.mov", s0: 120, length: 35, gain: 0.9, noise: 0.01, timecode: true, tcShift: 7),
            Shot(folder: "SlateA", name: "S1.mov", s0: 50.13, length: 20, audio: false, slate: 0, flashes: false),
            Shot(folder: "SlateB", name: "S2.mov", s0: 85.57, length: 20, audio: false, slate: 0, flashes: false),
            Shot(folder: "SlateC", name: "S3.mov", s0: 140, length: 20, timecode: true, audio: false, slate: 3, flashes: false),
            Shot(folder: "CamR", name: "R1.mov", s0: 25, length: 40, gain: 0.8, noise: 0.01, clock: 3600),
            Shot(folder: "CamR", name: "R2.mov", s0: 150, length: 20, audio: false, clock: 3600, flashes: false),
            Shot(folder: "CamD", name: "D1.mov", s0: 5.432, length: 169, drift: 0.001, gain: 1.4, noise: 0.02),
            Shot(folder: "Drone", name: "DJI_0001.mov", s0: 40.171, length: 100.3, fps: 30, audio: false),
        ]

        func run(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        func wav(_ samples: [Float], to url: URL) {
            var data = Data()
            func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples.count * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
            put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
            data.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count * 2))
            for sample in samples { put(Int16(max(-1, min(1, sample)) * 32767)) }
            try? data.write(to: url)
        }
        let made = Date()
        for shot in shots {
            let folder = base.appendingPathComponent(shot.folder, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(shot.name)
            let k = 1 + shot.drift
            // Picture: grey, white while a flash is on (the camera's own clock running k times the set's).
            let on = flashes.map { "between(\(shot.s0)+T*\(k),\($0),\($0 + 0.2))" }.joined(separator: "+")
            func tc(_ frames: Int) -> String {
                let seconds = frames / shot.fps
                return String(format: "%02d:%02d:%02d:%02d", 10 + seconds / 3600, seconds / 60 % 60, seconds % 60, frames % shot.fps)
            }
            let size = shot.slate != nil ? "640x360" : "64x36"
            var arguments = ["-nostdin", "-y", "-f", "lavfi", "-i", "color=c=0x404040:s=\(size):r=\(shot.fps):d=\(shot.length)"]
            if shot.audio {
                var low: Float = 0, sound = [Float](repeating: 0, count: Int(shot.length * rate))
                let alpha: Float = shot.filter == 1 ? 0.4 : 0.1
                for n in sound.indices {
                    let at = (shot.s0 + Double(n) / rate * k) * rate, i = Int(at), f = Float(at - Double(i))
                    var x = i + 1 < set.count ? set[i] * (1 - f) + set[i + 1] * f : 0
                    low += alpha * (x - low)
                    if shot.filter == 1 { x = low } else if shot.filter == 2 { x -= low }
                    let noise = Float((random() * 2 - 1) * (shot.silent ? 0.0002 : shot.noise))
                    sound[n] = (shot.silent ? 0 : x * Float(shot.gain)) + noise
                }
                let audio = folder.appendingPathComponent(shot.name + ".wav")
                wav(sound, to: audio)
                arguments += ["-i", audio.path, "-c:a", "pcm_s16le", "-shortest"]
            }
            if let slate = shot.slate {
                // A slate app's big digits, counting from the frame the clip starts in.
                let digits = tc(Int((shot.s0 * Double(shot.fps)).rounded(.down)) + slate).replacingOccurrences(of: ":", with: "\\:")
                arguments += ["-vf", "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:timecode='\(digits)':rate=\(shot.fps):fontsize=96:fontcolor=white:x=(w-tw)/2:y=(h-th)/2",
                              "-c:v", "mpeg4", "-q:v", "4"]
            } else if shot.flashes {
                arguments += ["-vf", "geq=lum='if(\(on),235,64)':cb=128:cr=128", "-c:v", "mpeg4", "-q:v", "8"]
            } else {
                arguments += ["-c:v", "mpeg4", "-q:v", "8"]
            }
            if let clock = shot.clock {
                let date = Date(timeIntervalSince1970: 1_767_261_600 + shot.s0 + clock)
                arguments += ["-metadata", "creation_time=" + ISO8601DateFormatter().string(from: date)]
            }
            if let serial = shot.serial { arguments += ["-metadata", "serial_number=\(serial)", "-movflags", "use_metadata_tags"] }
            if shot.timecode { arguments += ["-timecode", tc(Int(((shot.s0 + shot.tcShift) * Double(shot.fps)).rounded()))] }
            let ok = run(arguments + [file.path])
            try? fm.removeItem(at: folder.appendingPathComponent(shot.name + ".wav"))
            guard ok else { return check("sync: test clips made", false, shot.name) }
        }
        note("sync: test clips made in \(String(format: "%.1f", Date().timeIntervalSince(made))) s")

        // Grouping.
        let probes = CameraSync.files(in: [base]).compactMap { CameraSync.probe($0.file, root: $0.root, ffprobe: ffprobe) }
        var cameras = CameraSync.group(probes)
        let names = cameras.map { "\($0.name):\($0.clips.count)" }.joined(separator: ", ")
        check("sync: grouped into twelve cameras by serial and folder", cameras.count == 12 && cameras.map(\.clips.count).sorted() == [1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 3]
              && cameras.contains { $0.key == "serial:B-1234" && Set($0.clips.map(\.name)) == ["C0001.mov", "C0002.mov"] }, names)
        check("sync: timecode, sound, clock and rate read", cameras.flatMap(\.clips).filter { $0.timecode != nil }.count == 10
              && Set(cameras.flatMap(\.clips).filter { !$0.hasAudio }.map(\.name)) == ["DJI_0001.mov", "S1.mov", "S2.mov", "S3.mov", "R2.mov"]
              && cameras.flatMap(\.clips).filter { !$0.clockFromFile && $0.created != nil }.count == 2
              && cameras.flatMap(\.clips).first { $0.name == "DJI_0001.mov" }?.fps == 30, names)
        check("sync: the master is the camera with the most sound", CameraSync.master(cameras).map { cameras[$0].name } == "CamA")

        // Sync.
        let started = Date()
        let cache = SyncCache()
        defer { cache.clear() }
        let unsynced = cameras
        let stages = StageClock(), heardLive = CameraSync.Counter(), placedLive = CameraSync.Counter()
        cameras = await CameraSync.sync(cameras, options: .init(ffmpeg: ffmpeg, cache: cache, live: { event in
            switch event {
            case .listening: _ = heardLive.next()
            case .placed: _ = placedLive.next()
            case .heard: break
            }
        })) { _, text in stages.mark(text) }
        let listenedLive = heardLive.next(), foundLive = placedLive.next()
        check("sync: live reports of each clip listened to and each place found", listenedLive == 15 && foundLive >= 12, "\(listenedLive) \(foundLive)")
        note("sync: synced in \(String(format: "%.1f", Date().timeIntervalSince(started))) s (\(stages.summary))")
        // The old way (one clip at a time, every piece read on its own): the same places, within a frame.
        let slowStarted = Date(), slowStages = StageClock()
        let slow = await CameraSync.sync(unsynced, options: .init(ffmpeg: ffmpeg, cache: SyncCache(), width: 1)) { _, text in slowStages.mark(text) }
        note("sync: one at a time (as before) in \(String(format: "%.1f", Date().timeIntervalSince(slowStarted))) s (\(slowStages.summary))")
        let slowClips = slow.flatMap(\.clips)
        let apart = cameras.flatMap(\.clips).map { clip -> String? in
            guard let other = slowClips.first(where: { $0.id == clip.id }) else { return clip.name + " missing" }
            if clip.start == nil, other.start == nil { return nil }
            guard let a = clip.start, let b = other.start, abs(a - b) < 1 / max(clip.fps, 25), clip.method == other.method else {
                return "\(clip.name) \(clip.start ?? -1) \(other.start ?? -1) \(clip.method?.rawValue ?? "-") \(other.method?.rawValue ?? "-")"
            }
            return nil
        }.compactMap { $0 }
        check("sync: quick sync gives the old places within a frame, the same methods", apart.isEmpty, apart.joined(separator: "; "))
        await syncSpeedTest(ffmpeg: ffmpeg, ffprobe: ffprobe)
        let clips = cameras.flatMap(\.clips)
        func shot(_ clip: SyncClip) -> Shot? { shots.first { $0.name == clip.name } }
        guard let anchor = clips.first(where: { $0.name == "A001.mov" }), let anchorStart = anchor.start else {
            return check("sync: A001 placed", false)
        }
        var worst = 0.0, worstSound = 0.0
        for clip in clips where clip.name != "R2.mov" {
            guard let truth = shot(clip) else { continue }
            guard let start = clip.start else { check("sync: \(clip.name) placed", false, "not synced"); continue }
            let error = (start - anchorStart) - (truth.s0 - 2.37)
            let frame = 1 / Double(truth.fps)
            note("sync: \(clip.name) \(clip.method?.rawValue ?? "-") off by \(String(format: "%.2f", error * 1000)) ms, confidence \(String(format: "%.2f", clip.confidence)), drift \(String(format: "%.5f", clip.drift))")
            check("sync: \(clip.name) within a frame (\(clip.method?.rawValue ?? "-"))", abs(error) < frame, String(format: "%.1f ms", error * 1000))
            worst = max(worst, abs(error))
            if clip.method == .audio { worstSound = max(worstSound, abs(error)) }
        }
        check("sync: by sound within 1 ms", worstSound < 0.001, String(format: "%.2f ms", worstSound * 1000))
        note(String(format: "sync: worst %.2f ms, worst by sound %.2f ms", worst * 1000, worstSound * 1000))
        let d1 = clips.first { $0.name == "D1.mov" }
        check("sync: D's 0.1% drift found", abs((d1?.drift ?? 0) - 0.001) < 0.0001, String(d1?.drift ?? 0))
        check("sync: no drift where there's none", clips.filter { $0.name != "D1.mov" && $0.method == .audio }.allSatisfy { abs($0.drift) < 0.00005 },
              clips.map { "\($0.name) \($0.drift)" }.joined(separator: ", "))
        check("sync: the nearly silent clip by timecode", clips.first { $0.name == "C2.mov" }?.method == .timecode)
        check("sync: the drone by its flashes", clips.first { $0.name == "DJI_0001.mov" }?.method == .flashes)
        func named(_ name: String, in list: [SyncClip] = clips) -> SyncClip? { list.first { $0.name == name } }
        func methods(_ names: [String], in list: [SyncClip] = clips) -> String { names.map { "\($0) \(named($0, in: list)?.method?.rawValue ?? "-")" }.joined(separator: ", ") }
        // Timecode first.
        let jam = ["C1.mov", "C2.mov", "E1.mov", "E2.mov", "H1.mov", "H2.mov", "S3.mov"]
        func inTimecode(_ names: [String], in list: [SyncClip]) -> Bool {
            let gaps = names.compactMap { named($0, in: list) }.compactMap { clip in clip.start.flatMap { s in clip.timecode.map { s - $0 } } }
            return gaps.count == names.count && (gaps.max()! - gaps.min()!) < 0.000001
        }
        check("sync: jam-synced timecode lines up exactly by timecode", jam.allSatisfy { named($0)?.method == .timecode } && inTimecode(jam, in: clips), methods(jam))
        let f1 = named("F1.mov"), f2 = named("F2.mov")
        let fOffsets = [f1, f2].compactMap { clip in clip?.start.flatMap { s in clip?.timecode.map { s - $0 } } }
        check("sync: timecode 3.2 s off moved by one offset from sound", f1?.method == .timecodeOffset && f2?.method == .timecodeOffset && fOffsets.count == 2
              && abs(fOffsets[0] - fOffsets[1]) < 0.000001 && abs(fOffsets[0] + 3.2) < 0.04, methods(["F1.mov", "F2.mov"]) + " \(fOffsets)")
        check("sync: a timecode jump goes by sound", named("H3.mov")?.method == .audio, methods(["H1.mov", "H2.mov", "H3.mov"]))
        let noTimecode = ["A001.mov", "A002.mov", "C0001.mov", "C0002.mov", "D1.mov", "R1.mov"]
        check("sync: cameras without timecode by sound", noTimecode.allSatisfy { named($0)?.method == .audio }, methods(noTimecode))
        check("sync: cameras without timecode by the slate they show", named("S1.mov")?.method == .slate && named("S2.mov")?.method == .slate,
              methods(["S1.mov", "S2.mov"]) + " " + ["S1.mov", "S2.mov", "S3.mov"].map { "\(named($0)?.slate ?? -1)" }.joined(separator: ", "))
        check("sync: a slate that doesn't match is found", (2...4).contains(named("S3.mov")?.slateOff ?? 0) && named("S1.mov")?.slateOff == nil && named("S2.mov")?.slateOff == nil,
              ["S1.mov", "S2.mov", "S3.mov"].map { "\($0) \(named($0)?.slateOff ?? 0)" }.joined(separator: ", "))
        let r2 = named("R2.mov")
        check("sync: what nothing confirms stays rough, at its clock time", r2?.start == nil && r2?.quality == .rough
              && abs(((r2?.rough ?? 0) - anchorStart) - (150 - 2.37)) < 1.5, String((r2?.rough ?? 0) - anchorStart))
        let far = CameraSync.Match(start: 100, confidence: 0.9, at: 0, drift: 0), near = CameraSync.Match(start: 5000, confidence: 0.4, at: 0, drift: 0)
        check("sync: the clock narrows the sound search, never decides", CameraSync.narrowed([far, near], hint: 4900).map(\.start) == [5000]
              && CameraSync.narrowed([far, near], hint: nil).count == 2 && CameraSync.narrowed([far, near], hint: 90000).count == 2)
        // Timecode alone, no sound heard at all.
        let deaf = await CameraSync.sync(unsynced, options: .init(ffmpeg: ffmpeg, sound: { _ in nil })).flatMap(\.clips)
        check("sync: timecode alone lines cameras up, no sound used", (jam + ["F1.mov", "F2.mov"]).allSatisfy { named($0, in: deaf)?.method == .timecode }
              && inTimecode(jam + ["F1.mov", "F2.mov", "H3.mov"], in: deaf) && named("S1.mov", in: deaf)?.method == .slate, methods(jam + ["F1.mov", "S1.mov"], in: deaf))
        // Sound first.
        let soundFirst = await CameraSync.sync(unsynced, options: .init(ffmpeg: ffmpeg, cache: cache, audioFirst: true))
        let heardFirst = soundFirst.flatMap(\.clips)
        check("sync: sound first switch", named("F1.mov", in: heardFirst)?.method == .audio && named("E1.mov", in: heardFirst)?.method == .audio
              && !heardFirst.contains { $0.method == .timecodeOffset } && named("C2.mov", in: heardFirst)?.method == .timecode,
              methods(["F1.mov", "E1.mov", "C2.mov"], in: heardFirst))
        check("sync: sound first isn't in timecode", CameraSyncExport.startFrame(soundFirst, rate: 25) == nil)
        check("sync: confidence green by sound", clips.filter { $0.method == .audio }.allSatisfy { $0.quality == .good },
              clips.map { "\($0.name) \($0.confidence)" }.joined(separator: ", "))

        // Out: FCPXML and Resolve.
        let fps = CameraSyncExport.rate(cameras)
        let placements = CameraSyncExport.placements(cameras, rate: fps)
        let xml = CameraSyncExport.fcpxml(cameras, name: "Sync Test")
        let document = try? XMLDocument(xmlString: xml, options: [])
        let assetClips = (try? document?.nodes(forXPath: "//asset-clip")) as? [XMLElement] ?? []
        let firstTruth = shots.map(\.s0).min()!
        let start = CameraSyncExport.startFrame(cameras, rate: fps) ?? 0
        let sequence = (try? document?.nodes(forXPath: "//sequence"))?.first as? XMLElement
        check("sync: the timeline starts at the earliest clip's timecode",
              abs(start - Int(((36000 + firstTruth) * fps).rounded())) <= 1 && CameraSyncExport.timecode(start, rate: fps).hasPrefix("10:00:02:")
              && sequence?.attribute(forName: "tcStart")?.stringValue == CameraSyncExport.time(start, rate: fps),
              "\(CameraSyncExport.timecode(start, rate: fps)) \(sequence?.attribute(forName: "tcStart")?.stringValue ?? "-")")
        func frames(_ text: String?) -> Int? {
            guard let text, text.hasSuffix("s") else { return nil }
            let parts = text.dropLast().split(separator: "/").compactMap { Int($0) }
            return parts.count == 2 ? parts[0] * Int(fps) / parts[1] : parts.first.map { $0 * Int(fps) }
        }
        let fcpRight = assetClips.count == shots.count - 1 && assetClips.allSatisfy { element in
            guard let name = element.attribute(forName: "name")?.stringValue, let truth = shots.first(where: { name.hasSuffix(" · " + $0.name) }),
                  let offset = frames(element.attribute(forName: "offset")?.stringValue) else { return false }
            return abs(offset - Int(((truth.s0 - firstTruth) * fps).rounded())) <= 1
        }
        check("sync: FCPXML reads, every synced clip at its true frame", document != nil && fcpRight && fps == 25,
              assetClips.map { "\($0.attribute(forName: "name")?.stringValue ?? "") \($0.attribute(forName: "offset")?.stringValue ?? "")" }.joined(separator: ", "))
        check("sync: FCPXML lanes, one per camera", Set(assetClips.compactMap { $0.attribute(forName: "lane")?.stringValue }).count == 12)
        let items = CameraSyncExport.resolveItems(placements, rate: fps)
        let video = items.filter { $0["mediaType"] as? Int == 1 }, sound = items.filter { $0["mediaType"] as? Int == 2 }
        check("sync: Resolve gets a picture per clip and sound per sounding clip, a track per camera",
              video.count == 19 && sound.count == 15 && Set(video.compactMap { $0["track"] as? Int }) == Set(1...12)
              && Set(sound.compactMap { $0["track"] as? Int }) == Set(1...8), "\(video.count) \(sound.count)")
        check("sync: Resolve items at the true frames", items.allSatisfy { item in
            guard let path = item["path"] as? String, let truth = shots.first(where: { path.hasSuffix("/" + $0.name) }), let record = item["recordIn"] as? Int else { return false }
            return abs(record - Int(((truth.s0 - firstTruth) * fps).rounded())) <= 1
        })
        let project = CameraSyncExport.project(cameras, name: "Sync Test")
        check("sync: Pluck Edit project, a lane per camera", project.tracks?.count == 12 && project.tracks?.flatMap(\.items).count == 19)

        // A nudge, then syncing again leaves a locked clip where it is.
        var nudged = cameras
        if let c = nudged.firstIndex(where: { $0.clips.contains { $0.name == "C0001.mov" } }), let i = nudged[c].clips.firstIndex(where: { $0.name == "C0001.mov" }) {
            nudged[c].clips[i].start! += 2.0 / 25
            nudged[c].clips[i].method = .manual
            nudged[c].clips[i].locked = true
            let kept = nudged[c].clips[i].start
            let again = await CameraSync.sync(nudged, options: .init(ffmpeg: ffmpeg, cache: cache))
            check("sync: a locked clip stays put when synced again", again[c].clips[i].start == kept && again[c].clips[i].method == .manual)
        }

        // Live on the page: places shown as they're found, the stages, all gone once done.
        let watcher = CameraSyncModel()
        watcher.cameras = unsynced
        watcher.sync()
        var most = 0, seen = Set<Int>(), lines = 0
        for _ in 0..<1200 where watcher.running {
            most = max(most, watcher.live.count)
            if let stage = watcher.stage { seen.insert(stage.rawValue) }
            if watcher.liveLine != nil { lines += 1 }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check("sync live: places appear while syncing, with the stages and a line, then the result", most >= 5 && seen.isSuperset(of: [1, 2]) && lines > 0
              && watcher.live.isEmpty && watcher.stage == nil && watcher.clips.filter { $0.start != nil }.count == cameras.flatMap(\.clips).filter { $0.start != nil }.count,
              "most \(most) stages \(seen.sorted()) lines \(lines)")
        // The viewer's edits: nudges (a frame, ten), a drag (to a frame), Undo; what's sent uses them; none while syncing.
        let editor = CameraSyncModel()
        editor.cameras = cameras
        if let target = cameras.flatMap(\.clips).first(where: { $0.name == "C0001.mov" }), let before = target.start {
            func now() -> Double? { editor.clips.first { $0.id == target.id }?.start }
            editor.nudge(target.id, frames: 1)
            let one = now()
            editor.nudge(target.id, frames: -10)
            let ten = now()
            editor.shift(target.id, by: 0.333)
            let dragged = now()
            let held = editor.clips.first { $0.id == target.id }
            check("sync edit: nudges and a drag move by whole frames, and hold the clip",
                  abs((one ?? 0) - before - 0.04) < 1e-9 && abs((ten ?? 0) - before + 0.36) < 1e-9 && abs((dragged ?? 0) - before + 0.04) < 1e-9
                  && held?.method == .manual && held?.locked == true, "\(one ?? -1) \(ten ?? -1) \(dragged ?? -1) from \(before)")
            editor.undo()
            let undone = now()
            editor.undo(); editor.undo()
            check("sync edit: Undo steps back, to exactly how it was", abs((undone ?? 0) - before + 0.36) < 1e-9 && editor.cameras == cameras && !editor.canUndo)
            editor.redo(); editor.redo()
            let redone = now()
            editor.redo()
            check("sync edit: Redo steps forward again, to the last edit", abs((redone ?? 0) - before + 0.36) < 1e-9 && abs((now() ?? 0) - before + 0.04) < 1e-9
                  && !editor.canRedo && editor.canUndo, "\(redone ?? -1) \(now() ?? -1)")
            editor.undo(); editor.undo(); editor.undo()
            editor.nudge(target.id, frames: 5)
            let was = CameraSyncExport.placements(cameras, rate: 25).first { $0.clip.id == target.id }?.record
            let sent = CameraSyncExport.placements(editor.cameras, rate: 25).first { $0.clip.id == target.id }?.record
            let xml = CameraSyncExport.fcpxml(editor.cameras, name: "Edited")
            check("sync edit: what's sent uses the edit", was != nil && sent == was! + 5 && xml != CameraSyncExport.fcpxml(cameras, name: "Edited"),
                  "\(was ?? -1) → \(sent ?? -1)")
            // While syncing: nothing can be changed, and Undo records nothing.
            let steps = editor.history.count
            editor.sync()
            let during = editor.cameras
            editor.nudge(target.id, frames: 3)
            editor.shift(target.id, by: 1)
            editor.toggleLock(target.id)
            editor.move(target.id, to: nil)
            editor.rename(editor.cameras[0].id, "Changed")
            editor.undo()
            editor.redo()
            editor.clear()
            let refused = editor.running && editor.cameras == during && editor.history.count == steps && !editor.canUndo && !editor.canRedo
            editor.stop()
            editor.nudge(target.id, frames: 1)
            check("sync edit: no changes while syncing, all of them again once stopped", refused && !editor.running && editor.canUndo
                  && abs((now() ?? 0) - before - 0.24) < 1e-9, "running \(refused)")
        }
    }
}

/// When each stage of a sync began (from its progress lines), for the timings.
final class StageClock: @unchecked Sendable {
    private let lock = NSLock()
    private let started = Date()
    private var stages: [(String, Double)] = []

    func mark(_ text: String) {
        let stage = String(text.split(separator: " ").first ?? "")
        lock.withLock { if !stage.isEmpty, stages.last?.0 != stage { stages.append((stage, Date().timeIntervalSince(started))) } }
    }

    var summary: String {
        lock.withLock {
            let total = Date().timeIntervalSince(started)
            // Stages that come back (a second round of matching) add up.
            var spent: [String: Double] = [:], order: [String] = []
            for (k, (stage, at)) in stages.enumerated() {
                let end = k + 1 < stages.count ? stages[k + 1].1 : total
                if spent[stage] == nil { order.append(stage) }
                spent[stage, default: 0] += end - at
            }
            return order.map { "\($0) \(String(format: "%.1f", spent[$0]!)) s" }.joined(separator: ", ")
        }
    }
}
