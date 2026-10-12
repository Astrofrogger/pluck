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

    /// Puts everything back: no cuts, nothing taken out.
    func resetEdit() {
        guard isEdited else { return }
        remember()
        cuts = []
        removed = []
        selected = []
    }

    var canUndo: Bool { !history.isEmpty }

    func undo() {
        guard let last = history.popLast() else { return }
        cuts = last.cuts
        removed = last.removed
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
                       subtitles: URL? = nil, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let video = wantsVideo && !audioOnly
        guard !parts.isEmpty, video || audio else { return false }
        var graph: [String] = []
        var inputs = ""
        for (index, part) in parts.enumerated() {
            let start = String(format: "%.4f", part.lowerBound), end = String(format: "%.4f", part.upperBound)
            let length = part.upperBound - part.lowerBound
            if video {
                graph.append("[0:v:0]trim=start=\(start):end=\(end),setpts=PTS-STARTPTS[v\(index)]")
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
            var arguments = ["-nostdin", "-y", "-v", "error", "-progress", "pipe:1", "-i", file.path, "-filter_complex", graph.joined(separator: ";")]
            if video {
                arguments += ["-map", "[v]"] + settings.videoArguments(source: source, sourceFPS: sourceFPS, length: total, hardware: hardware)
            }
            if audio { arguments += ["-map", "[a]"] + (audioOnly ? settings.audioOnlyArguments : settings.audioArguments) }
            if ["mp4", "mov", "m4a"].contains(output.pathExtension.lowercased()) { arguments += ["-movflags", "+faststart"] }
            return arguments + [output.path]
        }
        let hardware = video && settings.hardware && !settings.codec.isProRes
        if await run(ffmpeg, arguments(hardware: hardware), total: total, progress: progress) { return true }
        // This Mac's encoder couldn't (an old Mac, an odd size): the same with x264 or x265.
        guard hardware else { return false }
        progress(0)
        return await run(ffmpeg, arguments(hardware: false), total: total, progress: progress)
    }

    private static func run(_ ffmpeg: String, _ arguments: [String], total: Double, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                    if let micro = Double(line.dropFirst("out_time_us=".count)) { progress(min(1, micro / 1_000_000 / max(total, 0.1))) }
                }
            }
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            return process.terminationStatus == 0
        }.value
    }
}
