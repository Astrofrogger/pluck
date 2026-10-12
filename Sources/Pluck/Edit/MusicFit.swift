import Foundation

/// Fit Music to Length: shortens (or lengthens) a song to an exact length the way an editor would:
/// it keeps the intro and the real ending and takes out (or repeats) whole phrases in the middle,
/// where the music on both sides of the cut sounds most alike. The cut is a one-beat crossfade
/// on a bar line; what's left over is closed with an inaudible change of tempo.
enum MusicFit {
    struct Edit: Sendable {
        /// The parts of the song to play, in order (seconds).
        var pieces: [ClosedRange<Double>]
        var crossfade: Double
        /// Played this much faster (above 1) or slower to land on the exact length.
        var tempo: Double
        /// Fades out over the last seconds, when the real ending had to go.
        var fadeOut: Double?
        /// Length before the tempo change.
        var length: Double
        /// How alike the music is on both sides of the cut (0 = identical).
        var seam: Double
    }

    /// The largest tempo change used to land exactly (3 % is about half a semitone of speed,
    /// and inaudible as tempo; the pitch stays the same).
    static let maximumTempoChange = 0.03

    static func plan(map: MusicMap, features: AudioFeatures, duration: Double, target: Double) -> Edit? {
        guard map.bars.count >= 4, target > 2 else { return nil }
        let beat = 60 / map.tempo
        let crossfade = beat
        let bars = map.bars
        let starts = bars.map(\.start)
        let profiles = bars.map { profile(features, from: $0.start, to: $0.end) }
        /// How alike the music is around two cut points (bar indexes): the bar before each, and the bar after.
        func seamCost(_ i: Int, _ j: Int) -> Double {
            var cost = distance(profiles[i], profiles[j])
            if i > 0, j > 0 { cost += distance(profiles[i - 1], profiles[j - 1]) }
            return cost / 2
        }
        /// Cutting on a phrase line (every 4 bars) sounds natural; on 2 bars it's fine; any bar costs a little.
        func alignment(_ i: Int) -> Double { i % 4 == 0 ? 0 : (i % 2 == 0 ? 0.08 : 0.18) }
        /// A short intro or ending sounds rushed: about 8 bars is ideal, 2 the least.
        func edgeCost(_ seconds: Double) -> Double {
            let wanted = min(bars[min(7, bars.count - 1)].end, duration / 4)
            return seconds >= wanted ? 0 : (wanted - seconds) / max(wanted, 1) * 0.6
        }
        let shortestEdge = bars[min(1, bars.count - 1)].end   // two bars

        var best: Edit?
        var bestCost = Double.infinity
        func consider(_ pieces: [ClosedRange<Double>], seam: Double, fadeOut: Double? = nil) {
            let length = pieces.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            let tempo = length / target
            guard abs(tempo - 1) <= maximumTempoChange else { return }
            // Exactness first, then a smooth seam; fading out instead of the real ending costs extra.
            let cost = abs(tempo - 1) * 40 + seam + (fadeOut == nil ? 0 : 0.5)
            if cost < bestCost {
                bestCost = cost
                best = Edit(pieces: pieces, crossfade: crossfade, tempo: tempo, fadeOut: fadeOut, length: length, seam: seam)
            }
        }

        if target >= duration * (1 - maximumTempoChange), target <= duration * (1 + maximumTempoChange) {
            consider([0...duration], seam: 0)
        }
        if target < duration {
            // Take out the middle: play up to bar i, carry on from bar j.
            for i in bars.indices where starts[i] >= shortestEdge {
                for j in bars.indices where j > i && duration - starts[j] >= shortestEdge {
                    let kept = starts[i] + duration - starts[j]
                    guard abs(kept / target - 1) <= maximumTempoChange else { continue }
                    consider([0...starts[i], starts[j]...duration],
                             seam: seamCost(i, j) + alignment(i) + alignment(j) + edgeCost(starts[i]) + edgeCost(duration - starts[j]))
                }
            }
            // Too short for an intro and an ending: play from the start and fade out on a bar,
            // or (for a few seconds of music) from the start of a later phrase.
            for i in bars.indices where i > 0 {
                consider([0...starts[i]], seam: alignment(i), fadeOut: min(4 * beat, starts[i] / 4))
            }
            for k in bars.indices where k > 0 && k % 4 == 0 {
                for i in bars.indices where i > k {
                    consider([starts[k]...starts[i]], seam: alignment(i) + 0.4, fadeOut: min(4 * beat, (starts[i] - starts[k]) / 4))
                }
            }
            // A fade can end anywhere: exactly the length asked, at the song's own tempo.
            consider([0...target], seam: 0.3, fadeOut: min(4 * beat, target / 4))
        } else {
            // Longer: after bar j, go back to bar i and play on; a long target repeats that
            // stretch more than once.
            for j in bars.indices where starts[j] >= shortestEdge {
                for i in bars.indices where i < j && starts[i] >= shortestEdge / 2 {
                    let loop = starts[j] - starts[i]
                    guard loop >= 4 * beat else { continue }
                    let times = max(1, Int(((target - duration) / loop).rounded()))
                    guard times <= 20 else { continue }
                    let pieces = [0...starts[j]] + Array(repeating: starts[i]...starts[j], count: times - 1) + [starts[i]...duration]
                    // Shorter loops repeated many times get noticeable.
                    consider(pieces, seam: seamCost(j, i) + alignment(i) + alignment(j) + Double(times - 1) * 0.05)
                }
            }
        }
        return best
    }

    enum Problem: LocalizedError {
        case noBeat, tooShort(Double)
        var errorDescription: String? {
            switch self {
            case .noBeat: String(localized: "Couldn’t find a steady beat in this song, so it can’t be cut on the music.")
            case .tooShort(let shortest):
                String(localized: "That’s too short to cut on the music. Choose at least \(Duration.seconds(shortest.rounded(.up)).formatted(.time(pattern: .minuteSecond))).")
            }
        }
    }

    /// Why there's no plan, in words.
    static func problem(map: MusicMap, target: Double) -> Problem {
        guard map.bars.count >= 4 else { return .noBeat }
        return .tooShort(map.bars[min(1, map.bars.count - 1)].end)
    }

    /// What a bar sounds like: its loudness, low end and top end, and how busy each band is.
    private static func profile(_ features: AudioFeatures, from start: Double, to end: Double) -> [Double] {
        let step = AudioFeatures.step
        let a = max(0, Int((start - AudioFeatures.latency) / step)), b = min(features.onset.count, Int((end - AudioFeatures.latency) / step))
        guard a < b else { return [] }
        func mean(_ series: [Float]) -> Double { Double(series[a..<b].reduce(0, +)) / Double(b - a) }
        func activity(_ series: [Float]) -> Double { Double(series[a..<b].map { max($0, 0) }.reduce(0, +)) / Double(b - a) }
        return [mean(features.loudness) / 10, mean(features.low) / 10, mean(features.high) / 10] + features.bands.map(activity)
    }

    private static func distance(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, !x.isEmpty else { return 10 }
        return sqrt(zip(x, y).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Double(x.count))
    }

    /// Writes the fitted song.
    static func render(_ edit: Edit, input: URL, output: URL, ffmpeg: String) async throws {
        let half = edit.crossfade / 2
        var graph: [String] = []
        for (index, piece) in edit.pieces.enumerated() {
            // Each piece overlaps the next by a crossfade, centred on the cut.
            let start = index == 0 ? piece.lowerBound : piece.lowerBound - half
            let end = index == edit.pieces.count - 1 ? piece.upperBound : piece.upperBound + half
            graph.append(String(format: "[0:a]atrim=%.4f:%.4f,asetpts=PTS-STARTPTS[p%d]", max(start, 0), end, index))
        }
        var last = "p0"
        for index in edit.pieces.indices.dropFirst() {
            graph.append(String(format: "[%@][p%d]acrossfade=d=%.4f:c1=qsin:c2=qsin[m%d]", last, index, edit.crossfade, index))
            last = "m\(index)"
        }
        var tail = String(format: "[%@]atempo=%.5f", last, edit.tempo)
        // Starting part-way into the song: a few milliseconds of fade so it doesn't click.
        if let first = edit.pieces.first, first.lowerBound > 0 { tail += ",afade=t=in:d=0.02" }
        if let fade = edit.fadeOut {
            tail += String(format: ",afade=t=out:st=%.4f:d=%.4f", edit.length / edit.tempo - fade, fade)
        }
        graph.append(tail + "[out]")
        let lossless = ["wav", "aif", "aiff", "flac"].contains(output.pathExtension.lowercased())
        var args = ["-nostdin", "-y", "-v", "error", "-i", input.path, "-filter_complex", graph.joined(separator: ";"),
                    "-map", "[out]", "-map_metadata", "0"]
        args += lossless ? ["-c:a", "pcm_s24le"] : ["-c:a", "aac", "-b:a", "256k"]
        let log = await ToolOutput.run(ffmpeg, args + [output.path])
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw FrameRewriter.Failure.writing(log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
