import Foundation

/// Cutting in the Editor: the file split into parts with the blade, parts taken out, and undo.
extension EditorModel {
    struct Part: Identifiable, Hashable {
        var start: Double
        var end: Double
        var removed: Bool
        var id: Double { start }
        var length: Double { end - start }
    }

    /// The parts between the cuts, from the start of the file to the end.
    var parts: [Part] {
        let edges = [0] + cuts + [duration]
        return zip(edges, edges.dropFirst()).compactMap { start, end in
            end > start ? Part(start: start, end: end, removed: removed.contains(start)) : nil
        }
    }

    func part(at seconds: Double) -> Part? {
        parts.last { $0.start <= seconds + 0.0001 } ?? parts.first
    }

    /// Cut or taken out at all.
    var isEdited: Bool { !cuts.isEmpty || !removed.isEmpty }

    /// The parts that stay, within the in and out points.
    var keptParts: [ClosedRange<Double>] {
        parts.filter { !$0.removed }.compactMap { part in
            let start = max(part.start, rangeStart), end = min(part.end, rangeEnd)
            return end - start >= frame ? start...end : nil
        }
    }

    /// How long the edit is.
    var editLength: Double { keptParts.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }

    private func remember() {
        history.append((cuts, removed))
        if history.count > 200 { history.removeFirst() }
        future = []
    }

    /// Cuts the file at a time (the blade, or ⌘B at the playhead).
    func cut(at seconds: Double) {
        let time = snappedToFrame(seconds)
        guard time > frame, time < duration - frame, !cuts.contains(where: { abs($0 - time) < frame }) else { return }
        remember()
        let wasRemoved = part(at: time)?.removed ?? false
        cuts.append(time)
        cuts.sort()
        if wasRemoved { removed.insert(time) }
    }

    /// Takes the selected parts out (they stay visible, crossed out, and are skipped).
    func removeSelected() {
        guard !selected.isEmpty else { return }
        remember()
        let all = Set(parts.map(\.start))
        if selected.isSubset(of: removed) {
            removed.subtract(selected)      // Selected parts already out: put them back.
        } else {
            removed.formUnion(selected.intersection(all))
        }
        selected = []
    }

    /// Cuts out every one of these (pauses, filler words) in one go, as one step to undo.
    func cutOut(_ spans: [ClosedRange<Double>]) {
        guard !spans.isEmpty else { return }
        remember()
        for span in spans {
            let start = snappedToFrame(span.lowerBound), end = snappedToFrame(span.upperBound)
            guard end - start >= frame else { continue }
            for edge in [start, end] where edge > 0 && edge < duration && !cuts.contains(where: { abs($0 - edge) < frame / 2 }) {
                cuts.append(edge)
            }
            cuts.sort()
            if let part = parts.first(where: { abs($0.start - start) < frame / 2 }) { removed.insert(part.start) }
        }
    }

    /// Takes a stretch out (cutting at its edges), or puts it back when it's all out already:
    /// editing by the words. Every part inside it goes, not only the first.
    func toggleOut(_ span: ClosedRange<Double>) {
        let start = snappedToFrame(span.lowerBound), end = snappedToFrame(span.upperBound)
        guard end - start >= frame else { return }
        let inside = parts.filter { $0.start < end - frame / 2 && $0.end > start + frame / 2 }
        remember()
        if !inside.isEmpty, inside.allSatisfy(\.removed) {
            for part in inside { removed.remove(part.start) }
            return
        }
        for edge in [start, end] where edge > 0 && edge < duration && !cuts.contains(where: { abs($0 - edge) < frame / 2 }) {
            cuts.append(edge)
        }
        cuts.sort()
        for part in parts where part.start >= start - frame / 2 && part.end <= end + frame / 2 { removed.insert(part.start) }
    }

    /// Puts everything back: no cuts, nothing taken out.
    func resetEdit() {
        guard isEdited else { return }
        remember()
        cuts = []
        removed = []
        selected = []
    }

    var canUndo: Bool { !history.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    func undo() {
        guard let last = history.popLast() else { return }
        future.append((cuts, removed))
        cuts = last.cuts
        removed = last.removed
        selected = selected.filter { start in parts.contains { $0.start == start } }
    }

    func redo() {
        guard let next = future.popLast() else { return }
        history.append((cuts, removed))
        cuts = next.cuts
        removed = next.removed
        selected = selected.filter { start in parts.contains { $0.start == start } }
    }

    /// Selects the part at a time; with ⇧ (or ⌘) adds it to the selection.
    func select(at seconds: Double, adding: Bool) {
        guard let part = part(at: seconds) else { return }
        if adding {
            if selected.contains(part.start) { selected.remove(part.start) } else { selected.insert(part.start) }
        } else {
            selected = [part.start]
        }
    }
}

/// Writes the edit: the kept parts joined into one file, re-encoded so every cut is exact.
enum EditorExport {
    /// The kept parts joined into one file, written with the render settings (or only the sound,
    /// as the settings' audio file). The Mac's own encoder is tried first when chosen, then x264/x265.
    static func joined(_ parts: [ClosedRange<Double>], of file: URL, video wantsVideo: Bool, audio: Bool, to output: URL, ffmpeg: String,
                       settings: EditorRenderSettings, audioOnly: Bool = false, source: CGSize, sourceFPS: Double,
                       subtitles: URL? = nil, pictureChain: ((String, Double, Double, Int) -> [String])? = nil, steadied: URL? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async -> Outcome {
        let video = wantsVideo && !audioOnly
        guard !parts.isEmpty, video || audio else { return .failed("") }
        var graph: [String] = []
        var inputs = ""
        for (index, part) in parts.enumerated() {
            let start = String(format: "%.4f", part.lowerBound), end = String(format: "%.4f", part.upperBound)
            let length = part.upperBound - part.lowerBound
            if video {
                if let pictureChain {
                    // The picture's settings (transform, crop, dynamic zoom…), as in a project.
                    graph += pictureChain(steadied == nil ? "[0:v:0]" : "[1:v:0]", part.lowerBound, part.upperBound, index)
                } else {
                    graph.append("[0:v:0]trim=start=\(start):end=\(end),setpts=PTS-STARTPTS[v\(index)]")
                }
                inputs += "[v\(index)]"
            }
            if audio {
                // A few milliseconds of fade at each cut, so it doesn't click.
                graph.append("[0:a:0]atrim=start=\(start):end=\(end),asetpts=PTS-STARTPTS,afade=t=in:d=0.008,afade=t=out:st=\(String(format: "%.4f", max(length - 0.008, 0))):d=0.008[a\(index)]")
                inputs += "[a\(index)]"
            }
        }
        graph.append("\(inputs)concat=n=\(parts.count):v=\(video ? 1 : 0):a=\(audio ? 1 : 0)\(video ? "[joined]" : "")\(audio ? "[a]" : "")")
        if video {
            // Subtitles drawn in at the source's size, then scaled and retimed.
            var chain: [String] = []
            if let subtitles { chain.append("ass=\(EditorSubtitleFiles.filterPath(subtitles))") }
            chain += settings.filters
            graph.append("[joined]" + (chain.isEmpty ? "null" : chain.joined(separator: ",")) + "[v]")
        }
        let total = parts.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        func arguments(hardware: Bool) -> [String] {
            var arguments = ["-nostdin", "-y", "-v", "error", "-progress", "pipe:1", "-i", file.path]
            if let steadied { arguments += ["-i", steadied.path] }
            arguments += ["-filter_complex", graph.joined(separator: ";")]
            if video {
                arguments += ["-map", "[v]"] + settings.videoArguments(source: source, sourceFPS: sourceFPS, length: total, hardware: hardware)
            }
            if audio { arguments += ["-map", "[a]"] + (audioOnly ? settings.audioOnlyArguments : settings.audioArguments) }
            if ["mp4", "mov", "m4a"].contains(output.pathExtension.lowercased()) { arguments += ["-movflags", "+faststart"] }
            return arguments + [output.path]
        }
        let hardware = video && settings.hardware && !settings.codec.isProRes
        let first = await run(ffmpeg, arguments(hardware: hardware), total: total, progress: progress)
        // This Mac's encoder couldn't (an old Mac, an odd size): the same with x264 or x265.
        guard hardware, first.isFailed, !Task.isCancelled else { return first }
        progress(0)
        return await run(ffmpeg, arguments(hardware: false), total: total, progress: progress)
    }

    /// How a run of ffmpeg ended.
    enum Outcome: Sendable {
        case done, stopped
        /// The last lines ffmpeg wrote about what went wrong.
        case failed(String)

        var isDone: Bool { if case .done = self { true } else { false } }
        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    /// Runs ffmpeg, reporting how far it is. Cancelling the task stops ffmpeg.
    static func run(_ ffmpeg: String, _ arguments: [String], total: Double, progress: @escaping @Sendable (Double) -> Void) async -> Outcome {
        let job = FFmpegJob()
        return await withTaskCancellationHandler {
            await Task.detached { job.run(ffmpeg, arguments, total: total, progress: progress) }.value
        } onCancel: {
            job.stop()
        }
    }

    /// What went wrong, in one sentence (from ffmpeg's last lines).
    static func readable(_ outcome: Outcome) -> String? {
        guard case .failed(let tail) = outcome else { return nil }
        let text = tail.lowercased()
        if text.contains("no space left") { return String(localized: "There’s no room left on the disk.") }
        if text.contains("error opening output") || text.contains("permission denied") || text.contains("operation not permitted")
            || text.contains("read-only file system") {
            return String(localized: "Pluck can’t write to the export folder. Is its drive connected?")
        }
        if text.contains("no such file or directory") { return String(localized: "A file the export needs is missing.") }
        if text.contains("invalid data found") || text.contains("moov atom not found") { return String(localized: "One of the files can’t be read.") }
        return String(localized: "The export couldn’t be written.")
    }
}

/// One ffmpeg process: stoppable from any thread, keeping the end of what it wrote to stderr.
private final class FFmpegJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var errors = Data()

    func stop() {
        lock.withLock {
            stopped = true
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func run(_ ffmpeg: String, _ arguments: [String], total: Double, progress: @escaping @Sendable (Double) -> Void) -> EditorExport.Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let micro = Double(line.dropFirst("out_time_us=".count)) { progress(min(1, micro / 1_000_000 / max(total, 0.1))) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock {
                self.errors.append(data)
                // Only the end matters.
                if self.errors.count > 16_384 { self.errors = self.errors.suffix(8_192) }
            }
        }
        let started: Bool = lock.withLock {
            guard !stopped, (try? process.run()) != nil else { return false }
            self.process = process
            return true
        }
        guard started else {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return lock.withLock { stopped } ? .stopped : .failed("")
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let rest = try? err.fileHandleForReading.readToEnd() { lock.withLock { errors.append(rest) } }
        return lock.withLock {
            if stopped { return .stopped }
            if process.terminationStatus == 0 { return .done }
            let lines = String(decoding: errors, as: UTF8.self).split(separator: "\n").suffix(20)
            return .failed(lines.joined(separator: "\n"))
        }
    }
}
