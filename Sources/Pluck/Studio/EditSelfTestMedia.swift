import AVFoundation
import Foundation

/// Exports and AI jobs (audit fixes): originals never rewritten, half-made files never left,
/// HDR made SDR, ProRes kept deep, stoppable jobs, streamed stems, the live recorder's log.
extension EditSelfTest {
    static func mediaFixes(_ manager: DownloadManager) async {
        guard let ffmpeg = manager.tool("ffmpeg"), let ffprobe = manager.tool("ffprobe") else {
            check("media fixes have ffmpeg", false, "no ffmpeg")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-media-fixes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults.standard
        let savedFolder = defaults.string(forKey: Prefs.downloadPath)
        defaults.set(folder.path, forKey: Prefs.downloadPath)
        defer { defaults.set(savedFolder, forKey: Prefs.downloadPath) }

        func tool(_ path: String, _ args: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func probe(_ file: URL, _ entries: String, _ streams: String = "v:0") -> String {
            tool(ffprobe, ["-v", "error", "-select_streams", streams, "-show_entries", entries, "-of", "csv=p=0", file.path])
        }
        /// The picture's mean luma, 0…1 of the video range.
        func grey(_ file: URL) -> Double {
            let out = tool(ffmpeg, ["-v", "error", "-i", file.path, "-vf", "format=yuv420p,signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-",
                                    "-frames:v", "1", "-f", "null", "-"])
            let value = out.split(separator: "=").last.flatMap { Double($0) } ?? -1
            return (value - 16) / 219
        }
        func parts() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains(".part.") || $0.hasPrefix(".pluck") } }
        let ai = AIStudio(manager: manager)

        // 1. Chapters and subtitles go into a new file next to the original, every stream kept.
        let original = folder.appendingPathComponent("clip.mov")
        _ = tool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc=s=320x180:r=25:d=4", "-f", "lavfi", "-i", "sine=d=4",
                          "-c:v", "libx264", "-c:a", "aac", "-timecode", "01:00:00:00", "-shortest", original.path])
        let before = try? Data(contentsOf: original)
        // (ffprobe 9 also lists stream groups, so count from the container.)
        func count(_ file: URL) -> Int { Int(tool(ffprobe, ["-v", "error", "-show_entries", "format=nb_streams", "-of", "csv=p=0", file.path])) ?? -1 }
        let streams = count(original)
        do {
            try await ai.embed([([Transcript.Cue(start: 0, end: 2, text: "Hello", words: 0..<0)], Locale.Language(identifier: "en"))], into: original)
            try await ai.write([Transcript.Chapter(start: 0, title: "One"), Transcript.Chapter(start: 2, title: "Two")], nextTo: original, duration: 4)
        } catch {
            check("subtitles and chapters into a copy", false, "\(error)")
        }
        let subtitled = folder.appendingPathComponent("clip (subtitled).mov"), chaptered = folder.appendingPathComponent("clip (chapters).mov")
        let subtitledStreams = probe(subtitled, "stream=codec_type", "").split(separator: "\n")
        let subtitledCount = count(subtitled), chapteredCount = count(chaptered)
        let chapters = tool(ffprobe, ["-v", "error", "-show_chapters", "-of", "csv=p=0", chaptered.path]).split(separator: "\n").count
        check("subtitles and chapters into a copy",
              (try? Data(contentsOf: original)) == before && subtitledCount == streams + 1 && subtitledStreams.contains("data")
                && chapters == 2 && chapteredCount >= streams && parts().isEmpty,
              "original unchanged, every stream kept (+1 subtitle; QuickTime adds a chapter track), 2 chapters, no temps; got \(streams) → \(subtitledCount)/\(chapteredCount), \(chapters) chapters, \(parts())")

        // 5. An AI job's ffmpeg: stopped or failed, nothing is left; done, the file gets its name.
        let made = folder.appendingPathComponent("made.mp4")
        try? await ai.ffmpeg(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=s=64x64:d=1", made.path], failure: StemError.emptyAudio)
        var failed = false
        do { try await ai.ffmpeg(["-y", "-v", "error", "-i", folder.appendingPathComponent("none.mp4").path, folder.appendingPathComponent("bad.mp4").path],
                                 failure: StemError.emptyAudio) } catch { failed = true }
        let long = Task { try await ai.ffmpeg(["-y", "-v", "error", "-re", "-f", "lavfi", "-i", "testsrc=s=64x64:d=60",
                                               folder.appendingPathComponent("long.mp4").path], failure: StemError.emptyAudio) }
        try? await Task.sleep(for: .seconds(1))
        long.cancel()
        let stopped = await long.result
        let wasStopped = if case .failure(let error) = stopped { error is CancellationError } else { false }
        check("AI ffmpeg writes a part file, stops", FileManager.default.fileExists(atPath: made.path) && failed && wasStopped && parts().isEmpty
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("long.mp4").path),
              "made, failed, stopped, no part files; got \(FileManager.default.fileExists(atPath: made.path)) \(failed) \(wasStopped) \(parts())")

        // A file that appeared at the output during the job is kept, and the job fails.
        let appeared = folder.appendingPathComponent("appeared.mp4")
        try? Data("theirs".utf8).write(to: appeared)
        var refused = false
        do { try await ai.ffmpeg(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=s=64x64:d=1", appeared.path], failure: StemError.emptyAudio) } catch { refused = true }
        check("AI ffmpeg never replaces a file that appeared", refused && (try? Data(contentsOf: appeared)) == Data("theirs".utf8) && parts().isEmpty,
              "failed \(refused), kept \((try? Data(contentsOf: appeared)) == Data("theirs".utf8)), parts \(parts())")

        // 9. A progress line split across two reads still counts.
        let seen = LockedValue(-1.0)
        _ = await EditorExport.run("/bin/sh", ["-c", "printf 'out_time'; sleep 0.3; printf '_us=500000\\nprogress=end\\n'"], total: 1) { seen.set($0) }
        check("progress line split across reads", near(seen.get(), 0.5), "0.5; got \(seen.get())")
        check("frame rates as fractions", EditorRenderSettings.rate(30000.0 / 1001) == "30000/1001" && EditorRenderSettings.rate(25) == "25"
                && EditorRenderSettings.rate(23.976) == "24000/1001", EditorRenderSettings.rate(30000.0 / 1001))

        // 3. HDR: an HLG clip (18% grey: 38% signal) comes out Rec.709, its grey where SDR's is (0.41).
        let hlg = folder.appendingPathComponent("hlg.mov")
        _ = tool(ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "color=c=0x616161:s=320x180:r=25:d=2",
                          "-vf", "format=yuv422p10le,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc",
                          "-c:v", "prores_ks", "-profile:v", "2", "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", hlg.path])
        var settings = EditorRenderSettings()
        settings.hardware = false
        let editor = EditorModel(file: hlg)
        await editor.load(ffmpeg: ffmpeg, ffprobe: ffprobe)
        editor.exports.run(EditorExportChoice(format: .video, each: false, burn: false, srt: false, settings: settings), model: editor, manager: manager)
        for _ in 0..<240 where editor.exports.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        if let out = editor.exports.output {
            let tags = probe(out, "stream=color_transfer,color_primaries"), level = grey(out)
            check("HDR editor export made SDR", tags == "bt709,bt709" && abs(level - 0.41) < 0.05, "bt709,bt709 grey 0.41±0.05; got \(tags) \(level)")
        } else {
            check("HDR editor export made SDR", false, editor.exports.problem ?? "no output")
        }
        var project = Project(name: "Self Test")
        project.clips = [ProjectClip(path: hlg.path, start: 0, end: 2)]
        let exports = ProjectExports()
        exports.run(project, settings: settings, audioOnly: false, size: CGSize(width: 320, height: 180), fps: 25, manager: manager)
        for _ in 0..<240 where exports.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        if let out = exports.output {
            let tags = probe(out, "stream=color_transfer,color_primaries"), level = grey(out)
            check("HDR project export made SDR", tags == "bt709,bt709" && abs(level - 0.41) < 0.05, "bt709,bt709 grey 0.41±0.05; got \(tags) \(level)")
        } else {
            check("HDR project export made SDR", false, exports.problem ?? "no output")
        }
        // The frame-by-frame jobs read frames as Rec.709 (the reader's colour settings; an unsupported one would crash).
        let rewritten = folder.appendingPathComponent("rewritten.mov")
        do {
            try await FrameRewriter().run(input: hlg, output: rewritten, codec: .hevc, progress: { _ in }) { $0.image }
            let tags = probe(rewritten, "stream=color_transfer,color_primaries"), level = grey(rewritten)
            check("frame rewriter reads HDR as Rec.709", tags == "bt709,bt709" && level > 0.2 && level < 0.7, "bt709,bt709 and a grey; got \(tags) \(level)")
        } catch {
            check("frame rewriter reads HDR as Rec.709", false, error.localizedDescription)
        }

        // 6. ProRes keeps 10 bits; 4444 keeps alpha (a square frame round a wide clip is see-through).
        settings.codec = .prores4444
        settings.tidy()
        project.clips = [ProjectClip(path: original.path, start: 0, end: 2)]
        exports.run(project, settings: settings, audioOnly: false, size: CGSize(width: 320, height: 320), fps: 25, manager: manager)
        for _ in 0..<240 where exports.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        if let out = exports.output {
            let format = probe(out, "stream=pix_fmt")
            // The corner's alpha (ProRes 4444 decodes as 12 bits).
            let alpha = tool(ffmpeg, ["-v", "error", "-i", out.path, "-vf", "alphaextract,format=gray,crop=10:10:0:0,signalstats,metadata=print:key=lavfi.signalstats.YMAX:file=-",
                                      "-frames:v", "1", "-f", "null", "-"]).split(separator: "=").last.flatMap { Int($0) } ?? -1
            check("ProRes 4444 keeps alpha", format.hasPrefix("yuva444p1") && alpha == 0, "yuva444p10le/12le, clear corners; got \(format) corner alpha \(alpha)")
        } else {
            check("ProRes 4444 keeps alpha", false, exports.problem ?? "no output")
        }

        // 9. Two Editor exports of the same name at once get different files.
        settings = EditorRenderSettings()
        settings.hardware = false
        let first = EditorModel(file: original), second = EditorModel(file: original)
        await first.load(ffmpeg: ffmpeg, ffprobe: ffprobe)
        await second.load(ffmpeg: ffmpeg, ffprobe: ffprobe)
        let choice = EditorExportChoice(format: .video, each: false, burn: false, srt: false, settings: settings)
        first.exports.run(choice, model: first, manager: manager)
        second.exports.run(choice, model: second, manager: manager)
        for _ in 0..<240 where first.exports.isRunning || second.exports.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        let names = [first.exports.output, second.exports.output].compactMap { $0?.lastPathComponent }
        check("same-name exports don't collide", Set(names).count == 2 && parts().isEmpty, "two names, no part files; got \(names) \(parts())")

        // 8. Undo keeps the last 100 steps, looks included.
        let model = ProjectModel(project: Project(name: "Self Test"))
        for _ in 0..<150 { model.change { $0.name = "Self Test" } }
        var undos = 0
        while model.canUndo, undos < 500 { model.undo(); undos += 1 }
        check("undo keeps 100 steps", undos == 100, "100; got \(undos)")

        await liveLog(folder: folder, manager: manager)
        await stems(folder: folder)
    }

    /// 2. The recorder's log is read as it comes (a chatty yt-dlp can't block on it), and a
    /// recording that stops growing says so.
    private static func liveLog(folder: URL, manager: DownloadManager) async {
        let session = LiveSession()
        session.manager = manager
        let output = folder.appendingPathComponent("live.ts")
        session.start("/bin/sh", ["-c", "yes x | head -c 300000 >&2; : > '\(output.path)'"], writing: output)
        for _ in 0..<60 where session.state == .recording { try? await Task.sleep(for: .milliseconds(250)) }
        check("live recorder log doesn't block it", session.state != .recording, "ended; still recording after 15 s")
        session.stop()

        LiveSession.stallAfter = 1
        defer { LiveSession.stallAfter = 60 }
        let quiet = LiveSession()
        quiet.manager = manager
        quiet.start("/bin/sh", ["-c", ": > '\(output.path)'; sleep 8"], writing: output)
        for _ in 0..<40 where quiet.transcriptionProblem == nil { try? await Task.sleep(for: .milliseconds(250)) }
        check("stalled recording shows a problem", quiet.transcriptionProblem != nil, "a problem; got none")
        quiet.stop()
    }

    /// 4. Stems come out a chunk at a time: with a stand-in model that hands the mix back as every
    /// stem, each stem is the input again, and the files are written whole.
    private static func stems(folder: URL) async {
        guard #available(macOS 27, *) else { return }
        let minutes = max(UserDefaults.standard.double(forKey: "PluckStemsMinutes"), 0.5)
        let length = Int(minutes * 60 * 44_100)
        let raw = folder.appendingPathComponent("mix.f32")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: raw) else { return }
        func sample(_ i: Int, _ ch: Int) -> Float { Float(sin(Double(i) * (ch == 0 ? 0.01 : 0.013))) * 0.5 + 0.1 }
        for start in stride(from: 0, to: length, by: 1 << 20) {
            var block = [Float]()
            for i in start..<min(start + (1 << 20), length) { block += [sample(i, 0), sample(i, 1)] }
            block.withUnsafeBufferPointer { try? handle.write(contentsOf: Data(buffer: $0)) }
        }
        try? handle.close()
        let echo: ([[Float]]) async throws -> [[[Float]]] = { [$0, $0, $0, $0] }

        // In memory, the streamed sums against the input.
        let short = 1_000_000
        var worst: Float = 0, written = 0
        try? await DemucsSeparator.separateAt44k(length: short, read: { start, count in
            (0..<2).map { ch in (start..<(start + count)).map { sample($0, ch) } }
        }, write: { stems in
            for i in stems[3][0].indices { worst = max(worst, abs(stems[3][0][i] - sample(written + i, 0)), abs(stems[0][1][i] - sample(written + i, 1))) }
            written += stems[3][0].count
        }, model: echo)
        check("stems streamed chunk by chunk", written == short && worst < 1e-3, "\(short) frames within 1e-3; got \(written), \(worst)")

        let out = folder.appendingPathComponent("stems", isDirectory: true)
        let baseline = footprint()
        var peak = baseline
        do {
            try await Stems.separate(raw, into: out, progress: { _ in peak = max(peak, footprint()) }, model: echo)
        } catch {
            check("stems written whole", false, "\(error)")
            return
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).sorted()
        let seconds = (try? AVAudioFile(forReading: out.appendingPathComponent(files.first ?? ""))).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        check("stems written whole", files.count == 5 && !files.contains { $0.contains(".part.") } && abs(seconds - minutes * 60) < 0.5,
              "5 files of \(minutes * 60) s; got \(files) \(seconds) s")
        check("stems memory (\(Int(minutes)) min): +\((peak - baseline) >> 20) MB", true)
    }

    /// This app's memory in use now, in bytes.
    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

/// A value set from another thread.
private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T { lock.withLock { value } }
}
