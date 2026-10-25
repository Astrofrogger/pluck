import Foundation

/// Lowering the music while someone speaks: where speech is on the timeline, the gain the song
/// follows around it, and that gain as an ffmpeg expression for the export. Pure functions.
enum Ducking {
    /// Gaps shorter than this between two stretches of speech don't let the music back up.
    static let mergeGap = 0.8

    // MARK: - Where speech is

    /// Speech on the timeline: from each clip's words (or, without a transcript, its sound), mapped
    /// through the clip's part, speed and place. Items on the extra tracks count too.
    static func speech(in project: Project, words: (String) -> [Transcript.Word]?, energy: (String) -> [Float]?) -> [ClosedRange<Double>] {
        speech(in: project) { path in
            if let found = words(path) { return found.map { $0.s...max($0.e, $0.s) } }
            if let samples = energy(path) { return spans(inSamples: samples) }
            return nil
        }
    }

    /// The same, from speech already found per file (in the file's seconds).
    static func speech(in project: Project, fileSpans: (String) -> [ClosedRange<Double>]?) -> [ClosedRange<Double>] {
        var found: [ClosedRange<Double>] = []
        func add(_ clip: ProjectClip, at place: Double) {
            guard let inFile = fileSpans(clip.path) else { return }
            for span in inFile {
                let from = max(span.lowerBound, clip.start), to = min(span.upperBound, clip.end)
                guard to >= from else { continue }
                found.append((place + (from - clip.start) / clip.speed)...(place + (to - clip.start) / clip.speed))
            }
        }
        var at = 0.0
        for clip in project.clips {
            if clip.ownAudio != false, clip.freeze == nil { add(clip, at: at) }
            at += clip.length
        }
        for lane in project.tracks ?? [] where !lane.muted && !lane.hidden {
            for item in lane.items where item.ownAudio != false && item.freeze == nil { add(item, at: item.at ?? 0) }
        }
        return merged(found)
    }

    /// Sorted, with gaps under `mergeGap` closed.
    static func merged(_ spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, span.lowerBound - last.upperBound < mergeGap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// Speech found from the sound alone (8 kHz mono): frames of 20 ms that are 12 dB above the
    /// file's quietest tenth. In the file's seconds.
    static func spans(inSamples samples: [Float], sampleRate: Double = 8000) -> [ClosedRange<Double>] {
        let size = Int(sampleRate * 0.02)
        let count = samples.count / size
        guard count > 0 else { return [] }
        var levels = [Float](repeating: 0, count: count)
        for frame in 0..<count {
            var sum: Float = 0
            for sample in samples[(frame * size)..<((frame + 1) * size)] { sum += sample * sample }
            levels[frame] = 10 * log10(max(sum / Float(size), 1e-9))
        }
        let floor = levels.sorted()[count / 10]
        var found: [ClosedRange<Double>] = []
        var open: Int?
        for frame in 0...count {
            let loud = frame < count && levels[frame] > floor + 12
            if loud, open == nil { open = frame }
            if !loud, let from = open {
                found.append((Double(from) * 0.02)...(Double(frame) * 0.02))
                open = nil
            }
        }
        // Short blips (a click, a bump) aren't speech.
        return merged(found).filter { $0.upperBound - $0.lowerBound >= 0.1 }
    }

    /// Speech in one file, in its seconds: its transcript's words, or else its sound.
    static func fileSpans(of path: String, ffmpeg: String) async -> [ClosedRange<Double>]? {
        if let transcript = TranscriptStore.find(forFile: path) { return transcript.words.map { $0.s...max($0.e, $0.s) } }
        guard let samples = try? await AudioFeatures.samples(of: URL(fileURLWithPath: path), ffmpeg: ffmpeg) else { return nil }
        return spans(inSamples: samples)
    }

    // MARK: - The gain around it

    /// The song's gain as points to join with straight lines: 1, a ramp down before each span, the
    /// lowered level through it, a slower ramp back up. Before the first and after the last it holds.
    static func envelope(_ spans: [ClosedRange<Double>], amountDB: Double, attack: Double = 0.15, release: Double = 0.4) -> [(time: Double, gain: Double)] {
        let low = pow(10, min(amountDB, 0) / 20)
        var points: [(time: Double, gain: Double)] = []
        func add(_ time: Double, _ gain: Double) {
            if let last = points.last, time < last.time { return }
            points.append((time, gain))
        }
        for span in merged(spans) {
            add(max(span.lowerBound - attack, 0), 1)
            add(span.lowerBound, low)
            add(span.upperBound, low)
            add(span.upperBound + release, 1)
        }
        return points
    }

    /// The envelope's gain at a time (1 with no points).
    static func gain(at time: Double, in env: [(time: Double, gain: Double)]) -> Double {
        guard let first = env.first, let last = env.last else { return 1 }
        if time <= first.time { return first.gain }
        if time >= last.time { return last.gain }
        let index = env.firstIndex { $0.time > time } ?? env.count - 1
        let a = env[index - 1], b = env[index]
        return a.gain + (b.gain - a.gain) * (time - a.time) / (b.time - a.time)
    }

    /// Put before the expression, so it's worked out every 10 ms (a frame is 21 ms or more otherwise).
    static let smallFrames = "asetnsamples=n=480:p=0"

    /// The envelope as a `volume` filter that follows the stream's time: `volume=eval=frame:volume='…'`.
    /// Its pieces nest as a balanced tree of `if(lt(t,…),…,…)`, so a long talk with many pauses stays
    /// shallow for ffmpeg's parser (a flat sum nests one level per piece).
    static func ffmpegExpression(_ env: [(Double, Double)]) -> String {
        func n(_ value: Double) -> String { String(format: "%.4f", value) }
        let points = env.enumerated().filter { $0.offset == 0 || $0.element.0 > env[$0.offset - 1].0 }.map(\.element)
        guard let first = points.first, let last = points.last else { return "volume=eval=frame:volume=1" }
        func line(_ index: Int) -> String {
            let a = points[index], b = points[index + 1]
            return a.1 == b.1 ? n(a.1) : "\(n(a.1))+(\(n(b.1 - a.1)))*(t-\(n(a.0)))/\(n(b.0 - a.0))"
        }
        // The pieces from `low` to `high` (piece i runs from point i to point i + 1).
        func tree(_ low: Int, _ high: Int) -> String {
            guard low < high else { return line(low) }
            let middle = (low + high) / 2
            return "if(lt(t,\(n(points[middle + 1].0))),\(tree(low, middle)),\(tree(middle + 1, high)))"
        }
        let inside = points.count > 1 ? tree(0, points.count - 2) : n(first.1)
        return "volume=eval=frame:volume='if(lt(t,\(n(first.0))),\(n(first.1)),if(gte(t,\(n(last.0))),\(n(last.1)),\(inside)))'"
    }

    /// Speech that matters to a song from `at` for `length` seconds (with room for the ramps).
    static func spans(_ spans: [ClosedRange<Double>], near at: Double, length: Double) -> [ClosedRange<Double>] {
        spans.filter { $0.upperBound > at - 1 && $0.lowerBound < at + length + 1 }
    }
}

/// Speech found in files' sound, shared by the viewer and the export: worked out once per file (as
/// long as it doesn't change), two files at a time.
actor SpeechFinder {
    static let shared = SpeechFinder()
    private var found: [String: (changed: Date?, spans: [ClosedRange<Double>]?)] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func spans(of path: String, ffmpeg: String) async -> [ClosedRange<Double>]? {
        let changed = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let known = found[path], known.changed == changed { return known.spans }
        if running >= 2 { await withCheckedContinuation { waiting.append($0) } }
        running += 1
        defer {
            running -= 1
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }
        // Found by another caller while this one waited.
        if let known = found[path], known.changed == changed { return known.spans }
        let spans = await Ducking.fileSpans(of: path, ffmpeg: ffmpeg)
        if !Task.isCancelled { found[path] = (changed, spans) }
        return spans
    }
}
