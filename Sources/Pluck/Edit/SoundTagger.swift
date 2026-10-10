import Foundation

/// Marks moments in a recording by its sound, piece by piece as a live stream comes in (or all
/// at once for a file): the crowd cheering, music starting and stopping, and silence. Loud and
/// quiet are measured against the recording itself, so a festival and a conference both work.
final class SoundTagger {
    struct Event: Codable, Identifiable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case cheer, musicStart, musicStop, silence

            var label: String {
                switch self {
                case .cheer: String(localized: "Crowd cheers")
                case .musicStart: String(localized: "Music starts")
                case .musicStop: String(localized: "Music stops")
                case .silence: String(localized: "Silence")
                }
            }

            var symbol: String {
                switch self {
                case .cheer: "hands.clap"
                case .musicStart: "music.note"
                case .musicStop: "music.note.slash" // falls back gracefully where missing
                case .silence: "speaker.slash"
                }
            }

            /// Resolve marker colour.
            var colour: String {
                switch self {
                case .cheer: "Yellow"
                case .musicStart: "Green"
                case .musicStop: "Cyan"
                case .silence: "Purple"
                }
            }
        }

        var kind: Kind
        var time: Double
        var duration: Double
        /// How strong (cheers: decibels above the room).
        var strength: Double
        var id: String { "\(kind.rawValue)@\(Int(time * 10))" }
    }

    struct Highlight: Codable, Identifiable, Hashable, Sendable {
        var start: Double
        var end: Double
        var reason: String
        var score: Double
        var id: Double { start }
    }

    private(set) var events: [Event] = []
    /// Loudness and high-frequency share per tenth of a second, from the start.
    private(set) var loudness: [Float] = []
    private var highShare: [Float] = []
    /// The last few seconds of onset strength (per 10 ms), for finding a beat across pieces.
    private var onsetTail: [Float] = []
    /// Seconds analysed so far (where the next piece starts).
    private(set) var analysed: Double = 0
    private var musical: [Bool] = []
    private var inMusic = false
    private var cheerUntil = -1.0
    private var silenceStart: Double?

    static let bin = 0.1

    /// Adds the next piece of sound. `features` must start at `analysed`.
    func add(_ features: AudioFeatures) {
        let perBin = Int(Self.bin / AudioFeatures.step)
        let bins = features.loudness.count / perBin
        guard bins > 0 else { return }
        let firstBin = loudness.count
        for b in 0..<bins {
            let range = b * perBin..<(b + 1) * perBin
            let loud = features.loudness[range].reduce(0, +) / Float(perBin)
            let high = features.high[range].reduce(0, +) / Float(perBin)
            loudness.append(loud)
            highShare.append(high - loud)
        }
        onsetTail += features.onset.prefix(bins * perBin)
        findCheers(from: firstBin)
        findSilence(from: firstBin)
        findMusic(newSeconds: Double(bins) * Self.bin)
        // Only the last 8 seconds are needed for the beat.
        if onsetTail.count > 800 { onsetTail.removeFirst(onsetTail.count - 800) }
        analysed = Double(loudness.count) * Self.bin
    }

    private func median(_ values: ArraySlice<Float>) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// A cheer: clearly louder than the last 20 seconds, brighter (more high frequencies: voices,
    /// whistles, applause), for at least a second and a half.
    private func findCheers(from first: Int) {
        var index = max(first, 1)
        while index < loudness.count {
            let time = Double(index) * Self.bin
            guard time > cheerUntil else { index += 1; continue }
            let base = median(loudness[max(0, index - 200)..<max(index - 10, 1)])
            let baseHigh = median(highShare[max(0, index - 200)..<max(index - 10, 1)])
            guard index >= 30, loudness[index] - base > 6, highShare[index] - baseHigh > 1.5 else { index += 1; continue }
            // How long it lasts above the room.
            var end = index
            while end + 1 < loudness.count, loudness[end + 1] - base > 3 { end += 1 }
            let length = Double(end - index + 1) * Self.bin
            if length >= 1.5 {
                let peak = loudness[index...end].max() ?? loudness[index]
                events.append(Event(kind: .cheer, time: time, duration: length, strength: Double(peak - base)))
                cheerUntil = Double(end) * Self.bin + 3
                index = end + 1
            } else {
                index += 1
            }
        }
    }

    /// Silence: 25 dB under the last minute, for two seconds or more.
    private func findSilence(from first: Int) {
        for index in first..<loudness.count {
            let base = median(loudness[max(0, index - 600)..<max(index, 1)])
            let quiet = loudness[index] < base - 25 || loudness[index] < -60
            let time = Double(index) * Self.bin
            if quiet {
                if silenceStart == nil { silenceStart = time }
            } else if let start = silenceStart {
                if time - start >= 2 { events.append(Event(kind: .silence, time: start, duration: time - start, strength: 0)) }
                silenceStart = nil
            }
        }
    }

    /// Music: a steady beat between 100 and 160 BPM in the last six seconds (the onset's
    /// autocorrelation). Starting and stopping need a few seconds' agreement.
    private func findMusic(newSeconds: Double) {
        let window = 600, minLag = 37, maxLag = 60
        let seconds = Int(newSeconds.rounded(.down))
        guard seconds > 0 else { return }
        for second in 0..<seconds {
            let end = onsetTail.count - (seconds - second - 1) * 100
            guard end >= window else { musical.append(false); continue }
            let slice = Array(onsetTail[(end - window)..<end])
            let mean = slice.reduce(0, +) / Float(slice.count)
            let centred = slice.map { $0 - mean }
            let energy = centred.reduce(0) { $0 + $1 * $1 }
            guard energy > 0 else { musical.append(false); continue }
            var best: Float = 0
            for lag in minLag...maxLag {
                var sum: Float = 0
                for i in lag..<centred.count { sum += centred[i] * centred[i - lag] }
                best = max(best, sum / energy)
            }
            musical.append(best > 0.3)
            let now = analysed + Double(second + 1)
            let recent = musical.suffix(6)
            if !inMusic, musical.suffix(4).count == 4, musical.suffix(4).allSatisfy({ $0 }) {
                inMusic = true
                // The beat shows once about half the six-second window has it: it began about
                // three seconds before the first of the four agreeing seconds.
                events.append(Event(kind: .musicStart, time: max(0, now - 4), duration: 0, strength: Double(best)))
            } else if inMusic, recent.count == 6, recent.allSatisfy({ !$0 }) {
                inMusic = false
                events.append(Event(kind: .musicStop, time: max(0, now - 9), duration: 0, strength: 0))
            }
        }
    }

    /// At the end of a recording: a silence still going on counts too.
    func finish() {
        if let start = silenceStart, analysed - start >= 2 {
            events.append(Event(kind: .silence, time: start, duration: analysed - start, strength: 0))
        }
        silenceStart = nil
    }

    /// The moments most worth a look, as pieces of about 20 seconds: cheers (with the run-up
    /// before them), music starting, and the loudest stretches, strongest first, none overlapping.
    func highlights(count: Int = 8, length: Double = 20) -> [Highlight] {
        var candidates: [Highlight] = []
        for event in events {
            switch event.kind {
            case .cheer:
                let start = max(0, event.time - length * 0.6)
                candidates.append(Highlight(start: start, end: start + length, reason: String(localized: "Crowd cheers"),
                                            score: 1 + event.strength / 6 + min(event.duration, 10) / 5))
            case .musicStart:
                let start = max(0, event.time - 2)
                candidates.append(Highlight(start: start, end: start + length, reason: String(localized: "Music starts"), score: 1))
            default: break
            }
        }
        // The loudest stretches, for recordings without clear events.
        let perWindow = Int(length / Self.bin)
        if loudness.count > perWindow {
            let overall = median(loudness[...])
            var windows: [(Int, Float)] = []
            var start = 0
            while start + perWindow <= loudness.count {
                let mean = loudness[start..<start + perWindow].reduce(0, +) / Float(perWindow)
                windows.append((start, mean))
                start += perWindow / 2
            }
            for (start, mean) in windows.sorted(by: { $0.1 > $1.1 }).prefix(count) where mean > overall + 2 {
                let time = Double(start) * Self.bin
                candidates.append(Highlight(start: time, end: time + length, reason: String(localized: "Loud moment"),
                                            score: 0.5 + Double(mean - overall) / 10))
            }
        }
        var chosen: [Highlight] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let end = min(candidate.end, analysed)
            guard end - candidate.start > 5 else { continue }
            if chosen.contains(where: { candidate.start < $0.end && end > $0.start }) { continue }
            chosen.append(Highlight(start: candidate.start, end: end, reason: candidate.reason, score: candidate.score))
            if chosen.count == count { break }
        }
        return chosen.sorted { $0.start < $1.start }
    }
}
