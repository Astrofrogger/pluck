import Foundation

/// Log in Resolve: what Pluck knows about each shot (what's in it, the shot size, how the camera
/// moves, problems like soft focus), written into the open DaVinci Resolve project, so editors
/// can search the media pool and make smart bins on it. Footage Pluck hasn't looked at yet is
/// analysed first (read only; the results stay in Pluck's own data).
@MainActor
@Observable
final class ResolveLogger {
    static let shared = ResolveLogger()

    enum State: Equatable {
        case idle
        case reading
        case analysing(file: String, done: Int, of: Int, progress: Double)
        case writing
        case finished(clips: Int, markers: Int, project: String)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch state {
        case .reading, .analysing, .writing: true
        default: false
        }
    }

    func start() {
        guard !isRunning else { return }
        state = .reading
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private struct Clip {
        var path: String
        var fps: Double
    }

    private func run() async {
        do {
            let answer = try await ResolveBridge.run(["action": "poolClips"])
            let project = answer["project"] as? String ?? ""
            let clips: [Clip] = (answer["clips"] as? [[String: Any]] ?? []).compactMap {
                guard let path = $0["path"] as? String, FileManager.default.fileExists(atPath: path) else { return nil }
                let fps = ($0["fps"] as? Double) ?? Double("\($0["fps"] ?? "")") ?? 25
                return Clip(path: path, fps: fps > 0 ? fps : 25)
            }
            guard !clips.isEmpty else {
                state = .failed(String(localized: "The open project in DaVinci Resolve has no video clips Pluck can reach."))
                return
            }
            // What hasn't been looked at yet, one file at a time (a file Resolve knows by two
            // paths, like /tmp and /private/tmp, only once).
            var seen = Set<String>()
            let missing = clips.filter {
                let file = URL(fileURLWithPath: $0.path)
                return seen.insert(file.resolvingSymlinksInPath().path).inserted
                    && !VisualIndex.isIndexed(file) && !VisualIndex.isIndexed(file.resolvingSymlinksInPath())
            }
            if !missing.isEmpty {
                guard let ffmpeg = VisualIndexer.shared.manager?.tool("ffmpeg") else { throw Converting.Failure.noFFmpeg }
                for (n, clip) in missing.enumerated() {
                    try Task.checkCancellation()
                    let name = URL(fileURLWithPath: clip.path).lastPathComponent
                    state = .analysing(file: name, done: n, of: missing.count, progress: 0)
                    _ = try? await VisualIndex.index(URL(fileURLWithPath: clip.path), ffmpeg: ffmpeg) { value in
                        Task { @MainActor in
                            if case .analysing(let file, let done, let total, _) = self.state {
                                self.state = .analysing(file: file, done: done, of: total, progress: value)
                            }
                        }
                    }
                }
            }
            try Task.checkCancellation()
            state = .writing
            let entries: [[String: Any]] = clips.compactMap { clip in
                let resolved = URL(fileURLWithPath: clip.path).resolvingSymlinksInPath().path
                guard let index = VisualIndex.load(clip.path) ?? VisualIndex.load(resolved) else { return nil }
                var entry = Self.entry(index, fps: clip.fps)
                entry["path"] = clip.path   // as Resolve knows it
                return entry
            }
            // In batches, so one Resolve call never carries thousands of markers.
            var logged = 0, markers = 0
            for start in stride(from: 0, to: entries.count, by: 40) {
                try Task.checkCancellation()
                let batch = Array(entries[start..<min(start + 40, entries.count)])
                let result = try await ResolveBridge.run(["action": "logClips", "clips": batch])
                logged += result["logged"] as? Int ?? 0
                markers += result["markers"] as? Int ?? 0
            }
            state = .finished(clips: logged, markers: markers, project: project)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
        task = nil
    }

    /// One clip's log, for the Resolve script.
    static func entry(_ index: VisualIndex.FileIndex, fps: Double) -> [String: Any] {
        let shots = index.shots
        // A few different descriptions, the best shots first.
        var seen = Set<String>(), parts: [String] = []
        for shot in shots.sorted(by: { ($0.quality?.score ?? 0.5) > ($1.quality?.score ?? 0.5) }) {
            let text = shot.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            parts.append(text)
            if parts.count == 3 { break }
        }
        var description = parts.joined(separator: " / ")
        if description.count > 400 { description = String(description.prefix(399)) + "…" }

        // Keywords: shot sizes and moves in it, then what's seen most often.
        var keywords: [String] = []
        func add(_ word: String) {
            let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, !keywords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { keywords.append(word) }
        }
        for framing in VisualIndex.Framing.allCases where shots.contains(where: { $0.framing == framing }) { add(framing.label) }
        for movement in VisualIndex.Movement.allCases where movement != .still && shots.contains(where: { $0.movement == movement }) {
            add(movement.label)
        }
        var counts: [String: Int] = [:]
        for shot in shots { for word in shot.keywords { counts[word.lowercased(), default: 0] += 1 } }
        for (word, _) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(10) { add(word) }

        // The shot size most of the clip is in.
        var lengths: [VisualIndex.Framing: Double] = [:]
        for shot in shots { lengths[shot.framing, default: 0] += shot.end - shot.start }
        let main = lengths.max { $0.value < $1.value }?.key

        let markers: [[String: Any]] = shots.map { shot in
            let frame = Int((shot.start * fps).rounded())
            let duration = max(1, Int(((shot.end - shot.start) * fps).rounded()))
            var note = [shot.framing.label, shot.movement.label].joined(separator: " · ")
            if let problems = shot.quality?.problems, !problems.isEmpty {
                note += " · " + problems.map(\.label).joined(separator: ", ")
            }
            note = shot.description + "\n" + note
            return ["frame": frame, "duration": duration, "color": color(shot), "name": title(shot.description), "note": note]
        }
        var entry: [String: Any] = ["path": index.path, "description": description, "keywords": keywords, "markers": markers]
        if let main { entry["shotType"] = main.label }
        return entry
    }

    /// Marker colours by shot size (and red for a shot with a problem).
    private static func color(_ shot: VisualIndex.Shot) -> String {
        if let problems = shot.quality?.problems, !problems.isEmpty { return "Red" }
        switch shot.framing {
        case .wide: return "Blue"
        case .medium: return "Green"
        case .closeUp: return "Yellow"
        case .aerial: return "Cyan"
        }
    }

    /// A marker name: the description's first phrase, short.
    private static func title(_ description: String) -> String {
        let first = description.split(whereSeparator: { ".;\n".contains($0) }).first.map(String.init) ?? description
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
    }
}
