import AppKit
import AVFoundation

/// Tests for the Edit page's projects (screenshot mode "edittest"): each check is a line in
/// -PluckScreenshotLog <file>, "PASS name" or "FAIL name: detail", then "done". Media comes from
/// -PluckScreenshotFile <folder>.
@MainActor
enum EditSelfTest {
    private static var lines: [String] = []
    private static var log = ""
    private static var media = ""

    static func run(defaults: UserDefaults, manager: DownloadManager) async {
        guard let logPath = defaults.string(forKey: "PluckScreenshotLog") else { return }
        log = logPath
        media = defaults.string(forKey: "PluckScreenshotFile") ?? ""
        lines = []
        decoding()
        await trims()
        await topAndTail()
        await favourites()
        await assembly()
        await links()
        await ducking()
        await voiceOver()
        await looks(manager)
        await resolveRead()
        await quickExports(manager)
        pacing()
        // The throwaway projects aren't kept.
        for made in ProjectStore.all() where made.name == "Self Test" { try? FileManager.default.removeItem(at: ProjectStore.url(for: made.id)) }
        lines.append("done")
        write()
        NSApp.terminate(nil)
    }

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        lines.append(ok ? "PASS \(name)" : "FAIL \(name): \(detail())")
        write()
    }

    private static func write() { try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8) }

    /// A throwaway project of these files from the media folder, whole, in order.
    static func project(_ names: [String]) async -> ProjectModel {
        let model = ProjectModel(project: Project(name: "Self Test"))
        await model.add(names.map { URL(fileURLWithPath: media).appendingPathComponent($0) })
        return model
    }

    /// Two numbers equal to within a frame's rounding.
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

    // MARK: - Checks

    /// A project as 3.6.2 saved it (paths made up) still opens, whole.
    private static func decoding() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let project = try decoder.decode(Project.self, from: Data(fixture362.utf8))
            check("decodes 3.6.2 project", project.clips.count == 7 && near(project.duration, 127.48, 0.01),
                  "7 clips, 127.48 s; got \(project.clips.count), \(project.duration)")
        } catch {
            check("decodes 3.6.2 project", false, "\(error)")
        }
    }

    /// Two clips of a.mp4 (20 s, 25 fps): 0–10 and 5–15, so both have room either side.
    private static func twoClips() async -> ProjectModel {
        let model = await project(["a.mp4", "a.mp4"])
        let ids = model.project.clips.map(\.id)
        if ids.count == 2 {
            model.trim(ids[0], start: 0, end: 10, record: true)
            model.trim(ids[1], start: 5, end: 15, record: true)
        }
        return model
    }

    /// Roll and slip (Task 1).
    private static func trims() async {
        var model = await twoClips()
        guard model.project.clips.count == 2 else { return check("trims: two clips", false, "got \(model.project.clips.count)") }
        let length = model.duration
        model.roll(cutAfter: 0, from: model.project, by: 2, record: true)
        var c = model.project.clips
        check("roll keeps total length", near(c[0].end, 12) && near(c[1].start, 7) && near(model.duration, length),
              "10→12, 5→7, \(length) s; got \(c[0].end), \(c[1].start), \(model.duration)")

        model.undo()
        c = model.project.clips
        check("roll is one undo step", near(c[0].end, 10) && near(c[1].start, 5), "10 and 5; got \(c[0].end), \(c[1].start)")

        model.set(c[0].id) { clip in var look = clip.look ?? ClipLook(); look.speed = 2; clip.look = look }
        model.roll(cutAfter: 0, from: model.project, by: 1, record: true)
        c = model.project.clips
        check("roll keeps total length with a 2x clip", near(c[0].end, 12) && near(c[1].start, 6),
              "left end +2 file s (12), right start +1 (6); got \(c[0].end), \(c[1].start)")

        model = await twoClips()
        model.roll(cutAfter: 0, from: model.project, by: -8, record: true)
        c = model.project.clips
        check("roll clamps at neighbour's file start", near(c[1].start, 0) && near(c[0].end, 5),
              "right start 0, left end 5; got \(c[1].start), \(c[0].end)")

        model = await twoClips()
        let clip = model.project.clips[1]
        model.slip(clip.id, from: model.project, by: 1.6, record: true)
        c = model.project.clips
        check("slip keeps length", near(c[1].start, 6.6) && near(c[1].end, 16.6) && near(model.duration, length),
              "6.6–16.6; got \(c[1].start)–\(c[1].end)")

        model.slip(clip.id, from: model.project, by: 5, record: true)
        c = model.project.clips
        check("slip clamps at file end", near(c[1].end, 20, 0.05) && near(c[1].length, 10),
              "end 20, length 10; got \(c[1].end), \(c[1].length)")

        model.slip(clip.id, from: model.project, by: 0.013, record: true)
        c = model.project.clips
        check("slip moves whole frames", near(c[1].end, 20, 0.05), "a third of a frame rounds to none; got \(c[1].end)")
    }

    /// Top and tail, and nudging (Task 2).
    /// Favourites are kept on disk and toggle off again.
    static func favourites() async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("favourites-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let source = MediaSource(path: media + "/a.mp4", span: 2...5)
        let first = MediaFavourites(file: file)
        first.toggle(source)
        check("favourite roundtrip", MediaFavourites(file: file).all == [source], "\(MediaFavourites(file: file).all)")
        first.toggle(source)
        check("favourite toggles off", first.all.isEmpty && MediaFavourites(file: file).all.isEmpty)
    }

    private static func topAndTail() async {
        var model = await twoClips()
        guard model.project.clips.count == 2 else { return check("top and tail: two clips", false, "got \(model.project.clips.count)") }
        let length = model.duration

        model.seek(to: 3)
        model.trimStartToPlayhead()
        var c = model.project.clips
        check("trim start to playhead", near(c[0].start, 3) && near(c[0].length, 7) && near(model.duration, length - 3) && near(model.time, 0),
              "start 3, length 7, duration \(length - 3), playhead 0; got \(c[0].start), \(c[0].length), \(model.duration), \(model.time)")

        model = await twoClips()
        model.seek(to: 3)
        model.trimEndToPlayhead()
        c = model.project.clips
        check("trim end to playhead", near(c[0].end, 3) && near(c[0].length, 3) && near(model.time, 3),
              "end 3, length 3, playhead 3; got \(c[0].end), \(c[0].length), \(model.time)")

        model = await twoClips()
        var item = ProjectClip(path: model.project.clips[0].path, start: 0, end: 2)
        item.at = 4
        var track = ProjectTrack(kind: .video)
        track.items = [item]
        model.change { $0.tracks = [track] }
        model.nudge([item.id], frames: 1)
        var at = model.project.tracks?.first?.items.first?.at ?? -1
        check("nudge item one frame", near(at, 4.04), "4.04; got \(at)")

        model.nudge([item.id], frames: -1000)
        at = model.project.tracks?.first?.items.first?.at ?? -1
        check("nudge stops at zero", at >= 0 && near(at, 0), "0; got \(at)")

        // An item linked to its clip moves on its own when nudged.
        var linked = ProjectClip(path: model.project.clips[1].path, start: 0, end: 2)
        linked.at = model.offsets[1]
        let link = UUID()
        linked.link = link
        track.items = [linked]
        model.change { $0.clips[1].link = link; $0.tracks = [track] }
        model.nudge([linked.id], frames: 2)
        let moved = model.project.tracks?.first?.items.first
        check("nudge moves a linked item", near(moved?.at ?? -1, model.offsets[1] + 0.08) && moved?.link == nil,
              "\(model.offsets[1] + 0.08), unlinked; got \(String(describing: moved?.at)), link \(String(describing: moved?.link))")
    }

    /// One-key edits from a chosen source (Task 4). a.mp4 is 20 s; the source is 3 s of b.mp4.
    private static func assembly() async {
        let source = MediaSource(path: URL(fileURLWithPath: media).appendingPathComponent("b.mp4").path, span: 2...5)
        var model = await twoClips()
        guard model.project.clips.count == 2 else { return check("assembly: two clips", false, "got \(model.project.clips.count)") }
        let length = model.duration

        await model.append(source)
        check("append adds at end", near(model.duration, length + 3) && model.project.clips.last?.path == source.path,
              "\(length + 3) s, b last; got \(model.duration)")

        model = await twoClips()
        model.seek(to: 4)
        await model.insert(source)
        var lengths = model.project.clips.map(\.length)
        check("insert splits at playhead", lengths.count == 4 && near(lengths[0], 4) && near(lengths[1], 3) && near(lengths[2], 6),
              "[4, 3, 6, 10]; got \(lengths)")

        model.undo()
        check("edit is one undo step", model.project.clips.count == 2 && near(model.duration, length), "2 clips, \(length) s; got \(model.project.clips.count)")

        model = await twoClips()
        model.seek(to: 8)
        await model.overwrite(source)
        lengths = model.project.clips.map(\.length)
        let offsets = model.offsets
        check("overwrite keeps duration", near(model.duration, length) && model.project.clips.firstIndex { $0.path == source.path }.map { near(offsets[$0], 8) } == true,
              "\(length) s, b at 8; got \(model.duration), \(lengths)")

        model = await twoClips()
        model.seek(to: 12)
        await model.placeOnTop(source)
        let item = model.project.tracks?.first { $0.kind == .video }?.items.first
        check("place on top", near(item?.at ?? -1, 12) && item?.link != nil && item?.link == model.project.clips[1].link,
              "at 12, linked to clip 2; got \(String(describing: item?.at))")

        model.seek(to: 0)
        await model.insert(source)
        let followed = model.project.tracks?.first { $0.kind == .video }?.items.first
        check("insert keeps linked overlay on its clip", near(followed?.at ?? -1, 15), "15 (12 + 3); got \(String(describing: followed?.at))")

        // The clip's sound taken off and put back: the picture on top stays.
        let under = model.project.clips[2].id
        model.detachAudio([under])
        model.attachAudio([under])
        let kept = model.project.tracks?.first { $0.kind == .video }?.items.count ?? 0
        check("attaching sound keeps the picture on top", kept == 1 && model.project.tracks?.contains { $0.kind == .audio } != true,
              "1 picture, no sound track; got \(kept)")

        model = await twoClips()
        model.seek(to: 12)
        await model.replace(source)
        let replaced = model.project.clips[1]
        check("replace swaps clip", replaced.path == source.path && near(replaced.length, 3) && near(model.duration, 13),
              "b, 3 s, 13 s in all; got \(replaced.path), \(replaced.length), \(model.duration)")
    }

    /// Voice-over (Task 8): a take fed in place of the microphone lands on the "Voice-over" track.
    private static func voiceOver() async {
        // 2.5 s of a 440 Hz tone as a 44.1 kHz stereo microphone would give it, in four buffers.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        var buffers: [AVAudioPCMBuffer] = []
        for chunk in 0..<4 {
            let frames = AVAudioFrameCount(44_100 * 2.5 / 4)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<2 {
                for i in 0..<Int(frames) {
                    buffer.floatChannelData![channel][i] = 0.5 * sin(2 * .pi * 440 * Float(Int(frames) * chunk + i) / 44_100)
                }
            }
            buffers.append(buffer)
        }
        VoiceOverRecorder.testInput = buffers
        defer { VoiceOverRecorder.testInput = nil }

        let model = await project(["a.mp4"])
        let before = model.project
        let recorder = VoiceOverRecorder()
        recorder.start(at: 4, in: model, muteTimeline: false)
        await recorder.task?.value
        let url = await recorder.stop()
        let track = model.project.tracks?.first { $0.name == "Voice-over" }
        let item = track?.items.first
        let length = item.map { $0.end - $0.start } ?? -1
        check("voice-over places take", track?.kind == .audio && track?.items.count == 1 && near(item?.at ?? -1, 4) && abs(length - 2.5) <= model.frame,
              "an audio item on \"Voice-over\" at 4 s, 2.5 s long; got \(String(describing: track?.items.count)) at \(String(describing: item?.at)), \(length) s")
        model.undo()
        check("voice-over undo", (model.project.tracks ?? []).isEmpty && model.project.clips.count == before.clips.count,
              "one undo removes the take; got \(model.project.tracks?.count ?? 0) tracks")
        if let url { try? FileManager.default.removeItem(at: url) }

        // Stopped in the countdown: back to idle, no file made, the next take can start.
        VoiceOverRecorder.testInput = buffers
        let folder = (try? VoiceOverRecorder.newTakeURL(for: "Self Test").deletingLastPathComponent())
        func takes() -> Int { folder.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path).count } ?? -1 }
        let filesBefore = takes()
        let stopped = VoiceOverRecorder()
        stopped.start(at: 0, in: model, muteTimeline: false)
        await stopped.stop()
        await stopped.task?.value
        check("voice-over stop while counting", stopped.state == .idle && stopped.task == nil && takes() == filesBefore,
              "idle, no task, no new file; got \(stopped.state), \(takes() - filesBefore) new files")

        // Names: a slash or colon in the project's name stays out, and a taken name isn't reused.
        if let first = try? VoiceOverRecorder.newTakeURL(for: "a/b:c") {
            FileManager.default.createFile(atPath: first.path, contents: Data())
            let second = try? VoiceOverRecorder.newTakeURL(for: "a/b:c")
            check("voice-over unique names", second != nil && second != first && !first.lastPathComponent.contains(":") && first.lastPathComponent.hasPrefix("a-b-c-"),
                  "a-b-c-<time>.wav, then another name; got \(first.lastPathComponent), \(second?.lastPathComponent ?? "nil")")
            try? FileManager.default.removeItem(at: first)
        } else {
            check("voice-over unique names", false, "no take URL")
        }

        // A microphone on the second input of a four-channel interface isn't silent.
        let wide = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | 4)!)
        let loud = AVAudioPCMBuffer(pcmFormat: wide, frameCapacity: 24_000)!
        loud.frameLength = 24_000
        for channel in 0..<4 { for i in 0..<24_000 { loud.floatChannelData![channel][i] = channel == 1 ? 0.5 * sin(2 * .pi * 440 * Float(i) / 48_000) : 0 } }
        if let url = try? VoiceOverRecorder.newTakeURL(for: "Self Test Wide"), let writer = try? VoiceOverWriter(url: url) {
            writer.append(loud)
            let seconds = writer.finish()
            check("voice-over mixes all channels", writer.peak > 0.2 && abs(seconds - 0.5) < 0.05, "peak over 0.2, 0.5 s; got \(writer.peak), \(seconds) s")
            try? FileManager.default.removeItem(at: url)
        } else {
            check("voice-over mixes all channels", false, "no writer")
        }
    }

    /// Auto-duck (Task 7): where speech is, the gain around it, and the export's expression.
    private static func ducking() async {
        func word(_ s: Double, _ e: Double) -> Transcript.Word { Transcript.Word(s: s, e: e, t: " x") }
        func twoClips(speed: Double) -> Project {
            var second = ProjectClip(path: "y", start: 0, end: 5 * speed)
            if speed != 1 { var look = ClipLook(); look.speed = speed; second.look = look }
            return Project(name: "Self Test", clips: [ProjectClip(path: "x", start: 0, end: 10), second])
        }
        let spoken: [Transcript.Word] = [word(1, 2), word(2.5, 3)]
        let plain = Ducking.speech(in: twoClips(speed: 1), words: { $0 == "y" ? spoken : nil }, energy: { _ in nil })
        check("speech spans from words", plain.count == 1 && near(plain[0].lowerBound, 11) && near(plain[0].upperBound, 13),
              "[11…13]; got \(plain)")
        let fast = Ducking.speech(in: twoClips(speed: 2), words: { $0 == "y" ? spoken : nil }, energy: { _ in nil })
        check("speech spans respect speed", fast.count == 1 && near(fast[0].lowerBound, 10.5) && near(fast[0].upperBound, 11.5),
              "[10.5…11.5]; got \(fast)")

        let env = Ducking.envelope([5...7], amountDB: -12)
        let probes = [Ducking.gain(at: 4.84, in: env), Ducking.gain(at: 5, in: env), Ducking.gain(at: 7, in: env), Ducking.gain(at: 7.4, in: env), Ducking.gain(at: 0, in: env)]
        check("envelope ramps", near(probes[0], 1, 0.001) && near(probes[1], 0.251, 0.002) && near(probes[2], 0.251, 0.002) && near(probes[3], 1, 0.001) && near(probes[4], 1, 0.001),
              "1, 0.251, 0.251, 1, 1; got \(probes)")

        // A 1 kHz tone through the expression, level per 100 ms against the envelope's.
        if let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg") {
            let two = Ducking.envelope([2...3.5, 6...7], amountDB: -12)
            let filter = Ducking.smallFrames + "," + Ducking.ffmpegExpression(two.map { ($0.time, $0.gain) })
            let levels = await Task.detached { () -> [Double] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=1000:duration=10:sample_rate=48000", "-af", filter, "-f", "f32le", "-"]
                let pipe = Pipe()
                process.standardOutput = pipe
                guard (try? process.run()) != nil else { return [] }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                return stride(from: 0, to: samples.count - 4800 + 1, by: 4800).map { start in
                    let square = samples[start..<(start + 4800)].reduce(0.0) { $0 + Double($1) * Double($1) }
                    return 10 * log10(max(square / 4800 / 0.5, 1e-12))
                }
            }.value
            var worst = 0.0
            for (window, level) in levels.enumerated() {
                let wanted = (0..<100).map { Ducking.gain(at: Double(window) * 0.1 + (Double($0) + 0.5) * 0.001, in: two) }
                let mean = (wanted.reduce(0) { $0 + $1 * $1 } / 100).squareRoot()
                // The first window is before any ducking: its level is the tone's own.
                worst = max(worst, abs(level - levels[0] - 20 * log10(mean)))
            }
            check("ffmpeg expression matches envelope", levels.count >= 99 && worst <= 0.5, "within 0.5 dB over \(levels.count) windows; worst \(worst)")
        } else {
            check("ffmpeg expression matches envelope", false, "no ffmpeg")
        }

        // The export without ducking has no gain expression; with it, one per ducked song.
        var project = Project(name: "Self Test", clips: [ProjectClip(path: "x", start: 0, end: 10)],
                              music: [ProjectMusic(path: "m", at: 0, start: 0, end: 10)])
        func arguments(_ project: Project, speech: [ClosedRange<Double>]) -> String {
            ProjectExports.arguments(project, streams: ["x": ["audio"], "m": ["audio"]], settings: EditorRenderSettings(), audioOnly: true,
                                    size: CGSize(width: 640, height: 360), fps: 25, titles: nil, subtitles: nil, hardware: false,
                                    output: URL(fileURLWithPath: "/tmp/out.m4a"), speech: speech).joined(separator: " ")
        }
        let off = arguments(project, speech: [2...4])
        project.music[0].duck = -12
        let on = arguments(project, speech: [2...4])
        check("duck off is untouched", !off.contains("eval=frame") && on.contains("eval=frame") && off.contains("afade=t=out"),
              "no eval=frame when off, one when on")

        // Three seconds of nothing, two of a tone, three of nothing.
        let quiet = [Float](repeating: 0, count: 24000)
        let tone = (0..<16000).map { Float(0.1 * sin(2 * Double.pi * 300 * Double($0) / 8000)) }
        let found = Ducking.spans(inSamples: quiet + tone + quiet)
        check("energy finds speech", found.count == 1 && near(found[0].lowerBound, 3, 0.05) && near(found[0].upperBound, 5, 0.05), "[3…5]; got \(found)")
    }

    /// Quick Export (Task 5): the saved settings, a queue, and the project as it was when queued.
    private static func quickExports(_ manager: DownloadManager) async {
        let defaults = UserDefaults.standard
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-quick-export-\(UUID().uuidString)")
        defaults.set(folder.path, forKey: Prefs.downloadPath)
        defaults.set(false, forKey: Prefs.askLocation)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = EditorRenderSettings()
        settings.codec = .h264
        settings.resolution = .p480
        settings.hardware = false
        defaults.set(settings.saved, forKey: "editorRenderSettings")
        defaults.set(false, forKey: "projectExportAudio")

        /// A 3 s project of a.mp4.
        func short() async -> ProjectModel {
            let model = await project(["a.mp4"])
            if let id = model.project.clips.first?.id { model.trim(id, start: 0, end: 3, record: true) }
            return model
        }
        func wait(_ model: ProjectModel, files: Int) async {
            for _ in 0..<480 where model.exports.isRunning || model.exports.queued > 0 || model.exports.finished.count < files {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        /// "codec WxH duration" of a file, from ffprobe.
        func probe(_ file: URL?) -> String {
            guard let file, let ffprobe = manager.tool("ffprobe") else { return "" }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height:format=duration",
                                 "-of", "default=nw=1:nk=1", file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let out = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
            return out.count >= 4 ? "\(out[0]) \(out[1])x\(out[2]) \(out[3])" : ""
        }

        var model = await short()
        quickExport(model, manager: manager)
        await wait(model, files: 1)
        let first = probe(model.exports.output)
        check("quick export uses saved settings", first.hasPrefix("h264 854x480"), "h264 854x480; got \(first) \(model.exports.problem ?? "")")

        model = await short()
        quickExport(model, manager: manager)
        quickExport(model, manager: manager)
        check("two quick exports queue", model.exports.queued == 1, "queued 1; got \(model.exports.queued)")
        await wait(model, files: 2)
        check("two quick exports make two files", model.exports.finished.count == 2 && Set(model.exports.finished).count == 2,
              "2 files; got \(model.exports.finished.count)")

        model = await short()
        quickExport(model, manager: manager)
        model.delete(Set(model.project.clips.map(\.id)))
        await wait(model, files: 1)
        let length = Double(probe(model.exports.output).split(separator: " ").last ?? "") ?? -1
        check("snapshot at queue time", near(length, 3, 0.1), "3 s; got \(length)")
    }

    /// Pacing (Task 6): long shots, very short clips and jump cuts found from the clips alone.
    private static func pacing() {
        func clip(_ path: String, _ start: Double, _ end: Double) -> ProjectClip { ProjectClip(path: path, start: start, end: end) }

        let long = Pacing.flags([clip("x", 0, 12)], frameRate: 25, longAfter: 8, shortUnder: 10)
        check("pacing finds long", long.contains(Pacing.Flag(index: 0, kind: .long)), "long at 0; got \(long)")

        let short = Pacing.flags([clip("x", 0, 0.2)], frameRate: 25, longAfter: 8, shortUnder: 10)
        check("pacing finds short", short.contains(Pacing.Flag(index: 0, kind: .short)), "short at 0; got \(short)")

        let jump = Pacing.flags([clip("x", 0, 5), clip("x", 5.5, 9)], frameRate: 25, longAfter: 8, shortUnder: 10)
        check("pacing finds jump cut", jump.contains(Pacing.Flag(index: 1, kind: .jumpCut)), "jumpCut at 1; got \(jump)")

        let far = Pacing.flags([clip("x", 0, 5), clip("x", 10, 14)], frameRate: 25, longAfter: 8, shortUnder: 10)
        check("pacing ignores far cut", !far.contains { $0.kind == .jumpCut }, "no jump cut; got \(far)")
    }

    /// What's linked to a clip stays with it through cuts, copies, trims and exports of a part
    /// (from the review of the first batch).
    private static func links() async {
        let source = MediaSource(path: URL(fileURLWithPath: media).appendingPathComponent("b.mp4").path, span: 2...5)
        func overlay(_ model: ProjectModel) -> ProjectClip? { model.project.tracks?.first { $0.kind == .video }?.items.first }
        func sounds(_ model: ProjectModel) -> [ProjectClip] { model.project.tracks?.first { $0.kind == .audio }?.items ?? [] }

        // Placed on top at 17 s of the second clip (10–20 s), then cut at 15 s: it stays at 17 s.
        var model = await twoClips()
        model.seek(to: 17)
        await model.placeOnTop(source)
        model.split(at: 15)
        check("split keeps a picture on top in place", near(overlay(model)?.at ?? -1, 17), "17; got \(String(describing: overlay(model)?.at))")

        // An insert before it, inside the same clip: it moves on with its half.
        model.seek(to: 12)
        await model.insert(source)
        check("insert inside a clip keeps a later picture on top over it", near(overlay(model)?.at ?? -1, 20), "20; got \(String(describing: overlay(model)?.at))")

        // The second clip's sound taken off, then the clip cut: the sound is cut with it, in sync.
        model = await twoClips()
        model.detachAudio([model.project.clips[1].id])
        model.split(at: 15)
        let cut = sounds(model).sorted { ($0.at ?? 0) < ($1.at ?? 0) }
        check("split cuts the clip's sound too", cut.count == 2 && near(cut[1].at ?? -1, 15) && near(cut[1].start, model.project.clips[2].start),
              "two sounds, the second at 15 from \(model.project.clips[2].start); got \(cut.map { ($0.at ?? -1, $0.start) })")

        // Overwrite from a clip's start with a shorter source: the rest keeps its sound.
        model = await twoClips()
        model.detachAudio([model.project.clips[1].id])
        model.seek(to: 10)
        await model.overwrite(source)
        let tail = sounds(model)
        check("overwrite keeps the rest of a clip's sound", tail.count == 1 && near(tail[0].at ?? -1, 13),
              "one sound at 13; got \(tail.map { $0.at ?? -1 })")

        // A roll: the right clip's sound starts where its picture now starts.
        model = await twoClips()
        model.detachAudio([model.project.clips[1].id])
        model.roll(cutAfter: 0, from: model.project, by: 1, record: true)
        model.addMarker()
        let rolled = sounds(model).first
        check("roll keeps the clip's sound in sync", near(rolled?.start ?? -1, model.project.clips[1].start) && near(rolled?.at ?? -1, model.offsets[1]),
              "from \(model.project.clips[1].start) at \(model.offsets[1]); got \(String(describing: rolled.map { ($0.start, $0.at ?? -1) }))")

        // Duplicated: the copy gets its own sound, and the first keeps its.
        model = await twoClips()
        model.detachAudio([model.project.clips[0].id])
        model.duplicate([model.project.clips[0].id])
        let pair = sounds(model).map { $0.at ?? -1 }.sorted()
        check("duplicate copies the clip's sound", pair.count == 2 && near(pair[0], 0) && near(pair[1], 10), "at 0 and 10; got \(pair)")

        // An export of 12–18 s: the picture on top at 13 s is at 1 s in it.
        model = await twoClips()
        model.seek(to: 13)
        await model.placeOnTop(source)
        let part = model.project.cut(to: 12...18)
        let moved = part.tracks?.first?.items.first
        check("export of a part moves what's on top with it", near(moved?.at ?? -1, 1) && near(moved?.length ?? -1, 3) && moved?.link == nil,
              "at 1, 3 s, unlinked; got \(String(describing: moved.map { ($0.at ?? -1, $0.length) }))")
    }

    private static let fixture362 = #"""
    {"modified":"2026-10-12T22:58:29Z","titleStyle":{"boxOpacity":0.68,"box":false,"x":0.5,"italic":false,"weight":700,"y":0.5,"font":"Helvetica Neue","outlineColor":"000000","color":"FFFFFF","scale":1.6,"boxColor":"000000","outline":2,"shadow":3,"uppercase":false},"created":"2026-10-12T22:23:47Z","clips":[{"start":124.11,"end":127.33,"fadeOut":0.08,"id":"45C5278E-841B-437A-B79A-53F6490867DE","volume":1,"path":"/tmp/pluck-fixture/clip1.mp4","role":"point","fadeIn":0.05},{"start":137.91,"end":152.83,"fadeOut":0.08,"id":"0C10E8CA-B874-4F7D-BE5A-B7E2F105FF49","volume":1,"path":"/tmp/pluck-fixture/clip1.mp4","role":"emotion","fadeIn":0.05},{"start":180.33,"end":189.43,"fadeOut":0.08,"id":"6A559163-4A81-4FAB-8AA8-745F28412211","volume":1,"path":"/tmp/pluck-fixture/clip1.mp4","role":"emotion","fadeIn":0.05},{"start":314.85,"end":356.59,"fadeOut":0.08,"id":"51BCCC3D-92C6-4056-A20B-14CEC99BC1A6","volume":1,"path":"/tmp/pluck-fixture/clip1.mp4","role":"emotion","fadeIn":0.05},{"start":96.27,"end":116.89,"fadeOut":0.08,"id":"2EB7F25F-2210-403B-8D09-DA43DD8F35EB","volume":1,"path":"/tmp/pluck-fixture/clip2.mp4","role":"emotion","fadeIn":0.05},{"start":139.89,"end":164.29,"fadeOut":0.08,"id":"6DF1AE55-DB99-4BBC-818E-93734C0C9C53","volume":1,"path":"/tmp/pluck-fixture/clip2.mp4","role":"emotion","fadeIn":0.05},{"start":356.19,"end":369.67,"fadeOut":0.08,"id":"CE352643-3C28-4CCD-A4E4-A6BC936DF6AA","volume":1,"path":"/tmp/pluck-fixture/clip1.mp4","role":"ending","fadeIn":0.05}],"id":"83A149DD-7208-4441-AB70-A633D040AB2C","music":[],"media":["/tmp/pluck-fixture/clip1.mp4","/tmp/pluck-fixture/clip2.mp4"],"name":"Fixture","subtitlesOn":true,"titles":[]}
    """#
}
