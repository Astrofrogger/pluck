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
        guard map.bars.count >= 8, target > 2 else { return nil }
        let beat = 60 / map.tempo
        let crossfade = beat
        // Phrase starts: every 4 bars from the first, plus the start and end of the song.
        let phraseStarts = stride(from: 0, to: map.bars.count, by: 4).map { map.bars[$0].start }
        let bars = map.bars
        let profiles = bars.map { profile(features, from: $0.start, to: $0.end) }
        func barIndex(at time: Double) -> Int? { bars.firstIndex { abs($0.start - time) < 0.05 } }
        /// How alike the music is around two cut points: the bar before each, and the bar after.
        func seamCost(_ a: Double, _ b: Double) -> Double {
            guard let i = barIndex(at: a), let j = barIndex(at: b) else { return 10 }
            var cost = distance(profiles[i], profiles[j])
            if i > 0, j > 0 { cost += distance(profiles[i - 1], profiles[j - 1]) }
            return cost / 2
        }
        let minimumEdge = min(bars[min(7, bars.count - 1)].end, duration / 4)   // keep at least ~8 bars of intro and ending

        var best: Edit?
        var bestCost = Double.infinity
        func consider(_ pieces: [ClosedRange<Double>], seam: Double, fadeOut: Double? = nil) {
            let length = pieces.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            let tempo = length / target
            guard abs(tempo - 1) <= maximumTempoChange else { return }
            // Exactness first, then a smooth seam; fading out instead of the real ending costs extra.
            let cost = abs(tempo - 1) * 20 + seam + (fadeOut == nil ? 0 : 3)
            if cost < bestCost {
                bestCost = cost
                best = Edit(pieces: pieces, crossfade: crossfade, tempo: tempo, fadeOut: fadeOut, length: length, seam: seam)
            }
        }

        if target >= duration * (1 - maximumTempoChange), target <= duration * (1 + maximumTempoChange) {
            consider([0...duration], seam: 0)
        }
        if target < duration {
            // Take out the middle: play up to A, carry on from B.
            for a in phraseStarts where a >= minimumEdge {
                for b in phraseStarts where b > a && duration - b >= minimumEdge {
                    consider([0...a, b...duration], seam: seamCost(a, b))
                }
            }
            // Too short for intro and ending both: end on a phrase and fade out.
            for c in phraseStarts where c > 4 * beat {
                consider([0...c], seam: 0, fadeOut: min(4 * beat, c / 4))
            }
        } else {
            // Longer: after B, go back to A and play on (a phrase or more is repeated).
            for b in phraseStarts where b >= minimumEdge {
                for a in phraseStarts where a < b && a >= minimumEdge / 2 {
                    consider([0...b, a...duration], seam: seamCost(b, a))
                }
            }
        }
        return best
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
