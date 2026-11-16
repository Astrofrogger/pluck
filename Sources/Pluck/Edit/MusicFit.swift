import Accelerate
import AVFoundation
import Foundation

/// Fit Music to Length: shortens (or lengthens) a song to an exact length the way an editor would.
/// It only cuts on bar lines of the beat grid (phrase lines preferred), at join pairs where the
/// harmony, the sound, the tempo and the beat on both sides match, keeps the song's ending whole,
/// and joins with an equal-power crossfade that ends on the incoming downbeat, aligned to the
/// sample. Several joins are used when together they sound better than one long jump.
enum MusicFit {
    /// A song read for fitting: its sound at full rate and its bars.
    struct Song: Sendable {
        var channels: [[Float]]
        var rate: Double
        var tempo: Double
        var beats: [Double]
        /// Bar starts: bar k runs from downbeats[k] to downbeats[k + 1].
        var downbeats: [Double]
        /// The bar index where 8-bar phrases start (counted modulo 8).
        var phraseOffset: Int
        /// Bars where a new section starts (the music changes most).
        var sectionStarts: Set<Int>
        /// Where the sound starts and its last decay ends.
        var soundStart: Double
        var soundEnd: Double
        var duration: Double
        var beatLength: Double { 60 / tempo }
        /// Per beat: chroma (12), energies (5), onset strength (1).
        fileprivate var beatFeatures: [[Double]]
        /// Per beat: how much more there is in the vocal band than usual (0 = usual or less).
        fileprivate var vocal: [Double]
        /// The beat index of each downbeat.
        fileprivate var beatOfBar: [Int]
        fileprivate var mono: [Float]
    }

    enum Ending: Sendable { case real, phrase, chosen }

    struct Join: Sendable, Hashable {
        /// Where the song stops playing and where it carries on (seconds in the original).
        var from: Double
        var to: Double
        var fromBar: Int
        var toBar: Int
        var crossfade: Double
        /// Where the join is in the new version (seconds, after the tempo change).
        var output: Double
    }

    struct Plan: Sendable {
        /// The parts of the song to play, in order (seconds).
        var pieces: [ClosedRange<Double>]
        var joins: [Join]
        /// Played this much faster (above 1) or slower to land on the exact length.
        var tempo: Double
        var fadeIn: Double
        var fadeOut: Double
        var ending: Ending
        /// Lower is smoother.
        var score: Double
        var target: Double
        /// Length before the tempo change.
        var length: Double { pieces.reduce(0) { $0 + $1.upperBound - $1.lowerBound } }
    }

    struct Request: Sendable {
        var target: Double
        /// A start or end the user chose (seconds in the original); nil = automatic.
        var start: Double?
        var end: Double?
        /// Parts that must stay.
        var keep: [ClosedRange<Double>] = []
    }

    /// The largest tempo change used to land exactly, when the ending can't absorb it
    /// (3 % is inaudible as tempo; the pitch stays the same).
    static let maximumTempoChange = 0.03
    /// Bars to play after a join before the next one.
    private static let shortestRun = 2

    // MARK: - Reading

    static func analyse(_ url: URL, ffmpeg: String) async throws -> Song {
        let low = try await AudioFeatures.samples(of: url, ffmpeg: ffmpeg)
        let rate = await sampleRate(of: url)
        let interleaved = try await AudioFeatures.samples(of: url, ffmpeg: ffmpeg, channels: 2, rate: rate)
        guard let song = await Task.detached(operation: { Song(low: low, interleaved: interleaved, rate: rate) }).value else { throw Problem.noBeat }
        return song
    }

    private static func sampleRate(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await track.load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           (22_050...96_000).contains(description.mSampleRate) {
            return description.mSampleRate
        }
        return 48_000
    }

    // MARK: - Planning

    /// The best fits, best first: each next one avoids the joins of those before it.
    static func plans(for song: Song, _ request: Request, count: Int = 5) -> [Plan] {
        var banned = Set<Int>()
        var result: [Plan] = []
        for _ in 0..<count {
            guard let plan = bestPlan(song, request, banned: banned), !result.contains(where: { $0.pieces == plan.pieces }) else { break }
            result.append(plan)
            if plan.joins.isEmpty { break }
            for join in plan.joins { banned.insert(join.fromBar * 100_000 + join.toBar) }
        }
        return result
    }

    /// The nearest beat (snapping a start or end handle).
    static func snap(_ time: Double, in song: Song) -> Double {
        song.beats.min { abs($0 - time) < abs($1 - time) } ?? time
    }

    private static func modulo(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

    /// Cutting on a 16- or 8-bar phrase line sounds natural; on 4 bars it's fine; any bar costs more.
    private static func position(_ bar: Int, _ song: Song) -> Double {
        let p = bar - song.phraseOffset
        return modulo(p, 16) == 0 ? 0 : modulo(p, 8) == 0 ? 0.04 : modulo(p, 4) == 0 ? 0.12 : modulo(p, 2) == 0 ? 0.3 : 0.45
    }

    fileprivate static func distance(_ x: [Double], _ y: [Double]) -> Double {
        var chroma = 0.0, energy = 0.0
        for k in 0..<12 { chroma += abs(x[k] - y[k]) }
        for k in 12..<17 { energy += abs(x[k] - y[k]) }
        return chroma / 2 + energy / 5 * 0.6 + abs(x[17] - y[17]) * 0.05
    }

    /// How alike the music is around two bar lines: the two beats before each and the two after.
    private static func similarity(_ i: Int, _ j: Int, _ song: Song) -> Double {
        let a = song.beatOfBar[i], b = song.beatOfBar[j], f = song.beatFeatures
        var cost = 0.0, weight = 0.0
        for (offset, w) in [(-2, 0.5), (-1, 1.0), (0, 1.0), (1, 0.5)] where f.indices.contains(a + offset) && f.indices.contains(b + offset) {
            cost += w * distance(f[a + offset], f[b + offset])
            weight += w
        }
        guard weight > 0 else { return 10 }
        // The beat's length on both sides: a song that speeds up shouldn't jump between tempos.
        func period(_ k: Int) -> Double { k + 1 < song.beats.count ? song.beats[k + 1] - song.beats[k] : song.beatLength }
        let tempo = abs(period(a) - period(b)) / song.beatLength * 10
        // A voice held across the bar line gets cut off (or faded in) mid-word.
        func voice(_ k: Int) -> Double { k > 0 && k < song.vocal.count ? min(song.vocal[k - 1], song.vocal[k]) : 0 }
        return cost / weight + tempo + 0.5 * (voice(a) + voice(b))
    }

    private static func bestPlan(_ song: Song, _ request: Request, banned: Set<Int>) -> Plan? {
        let d = song.downbeats, count = d.count, beat = song.beatLength
        guard count >= 4, request.target > 1 else { return nil }
        let meanBar = (d[count - 1] - d[0]) / Double(count - 1)
        let startTime = request.start ?? song.soundStart
        guard let s = d.firstIndex(where: { $0 >= startTime - 0.002 }) else { return nil }
        let head = max(0, d[s] - startTime)

        struct End { var bar: Int; var tail: ClosedRange<Double>; var cost: Double; var kind: Ending }
        var ends: [End] = []
        let lastBar: Int, endingStart: Int
        if let endTime = request.end {
            guard let e = d.lastIndex(where: { $0 <= endTime - 0.01 }), e >= s else { return nil }
            ends = [End(bar: e, tail: (endTime - d[e])...(endTime - d[e]), cost: 0, kind: .chosen)]
            lastBar = e
            endingStart = e
        } else {
            // The real ending: from the last downbeat with a clear hit (its final chord), ringing out.
            let lastGrid = d.lastIndex(where: { $0 <= song.soundEnd - beat }) ?? count - 1
            let hits = song.beatOfBar.map { song.beatFeatures[$0][17] }
            let typical = hits.sorted()[hits.count / 2]
            let real = max(s, (0...lastGrid).last { hits[$0] > typical } ?? lastGrid)
            let full = max(0, song.soundEnd - d[real])
            ends.append(End(bar: real, tail: min(beat, full)...full, cost: 0, kind: .real))
            // Or a phrase end, with a short fade on the next downbeat.
            for e in (s + 1)..<max(s + 1, real) where modulo(e - song.phraseOffset, 4) == 0 {
                ends.append(End(bar: e, tail: (2 * beat)...(4 * beat), cost: 1.5 + position(e, song), kind: .phrase))
            }
            lastBar = real
            // The song's ending (its last phrase, from its first downbeat) is never cut into.
            endingStart = max(s, (s...real).last { modulo($0 - song.phraseOffset, 8) == 0 && $0 <= real - 2 } ?? s)
        }

        // A part to keep can't come after the end.
        ends.removeAll { end in request.keep.contains { d[end.bar] + end.tail.upperBound < min($0.upperBound, song.soundEnd) - 0.01 } }
        // Join costs; impossible joins stay infinite.
        var joinCost = [Double](repeating: .infinity, count: count * count)
        if endingStart > s {
            for i in s...endingStart {
                for j in s...endingStart where i != j && !banned.contains(i * 100_000 + j) {
                    // Never skip a part that must stay.
                    if j > i, request.keep.contains(where: { d[i] < $0.upperBound && d[j] > $0.lowerBound }) { continue }
                    // Never land on the last bar of a section (its fill or turnaround) out of place.
                    if song.sectionStarts.contains(j + 1), !song.sectionStarts.contains(i + 1) { continue }
                    let gap = abs(j - i)
                    let spacing = gap % 8 == 0 ? 0 : gap % 4 == 0 ? 0.08 : 0.25
                    joinCost[i * count + j] = similarity(i, j, song) + position(i, song) + position(j, song) + spacing
                        + 0.15 + (j < i ? 0.1 : 0)
                }
            }
        }

        // Dynamic programming over (bars played, bar line, bars since the last join).
        let runs = shortestRun + 1
        let most = max(1, Int(((request.target - head) / meanBar).rounded(.up)) + 2)
        let layer = count * runs
        var cost = [Double](repeating: .infinity, count: (most + 1) * layer)
        var back = [Int32](repeating: -1, count: (most + 1) * layer)
        cost[s * runs] = 0
        for k in 0...most {
            let base = k * layer
            for b in 0..<count {
                let from = base + b * runs + shortestRun
                let c = cost[from]
                guard c.isFinite else { continue }
                for j in 0..<count {
                    let step = joinCost[b * count + j]
                    guard step.isFinite else { continue }
                    let to = base + j * runs
                    if c + step < cost[to] { cost[to] = c + step; back[to] = Int32(from) }
                }
            }
            guard k < most else { break }
            for b in 0..<lastBar {
                for f in 0..<runs {
                    let from = base + b * runs + f
                    guard cost[from].isFinite else { continue }
                    let to = base + layer + (b + 1) * runs + min(f + 1, shortestRun)
                    if cost[from] < cost[to] { cost[to] = cost[from]; back[to] = Int32(from) }
                }
            }
        }

        func tailCost(_ end: End, _ tail: Double) -> Double {
            end.kind == .real ? 0.3 * (end.tail.upperBound - tail) / max(end.tail.upperBound, 0.001) : 0
        }
        var best: (cost: Double, state: Int, end: End)?
        for k in 0...most {
            for end in ends {
                for f in 0..<runs {
                    let state = k * layer + end.bar * runs + f
                    guard cost[state].isFinite else { continue }
                    let body = head + Double(k) * meanBar
                    let tail = min(max(request.target - body, end.tail.lowerBound), end.tail.upperBound)
                    let tempo = (body + tail) / request.target
                    guard abs(tempo - 1) <= maximumTempoChange else { continue }
                    let total = cost[state] + end.cost + tailCost(end, tail) + abs(tempo - 1) * 25
                    if total < best?.cost ?? .infinity { best = (total, state, end) }
                }
            }
        }
        guard let best else { return nil }

        // Walk back: the bar lines played, and where it jumped.
        var states: [Int] = []
        var state = best.state
        while state >= 0 { states.append(state); state = Int(back[state]) }
        states.reverse()
        var joins: [(Int, Int)] = []
        for (a, b) in zip(states, states.dropFirst()) where a / layer == b / layer {
            joins.append(((a % layer) / runs, (b % layer) / runs))
        }
        return finish(song, request, start: startTime, joins: joins, end: best.end.bar, tail: best.end.tail, kind: best.end.kind, score: best.cost)
    }

    /// Places each join on the sample, then lands the length exactly with the ending (or the tempo).
    private static func finish(_ song: Song, _ request: Request, start: Double, joins pairs: [(Int, Int)], end: Int,
                               tail range: ClosedRange<Double>, kind: Ending, score: Double) -> Plan {
        let d = song.downbeats
        var joins: [Join] = []
        var pieces: [ClosedRange<Double>] = []
        var pieceStart = start
        for (i, j) in pairs {
            let join = refine(i, j, song)
            pieces.append(pieceStart...max(pieceStart, join.from))
            pieceStart = join.to
            joins.append(join)
        }
        let body = pieces.reduce(0) { $0 + $1.upperBound - $1.lowerBound } + d[end] - pieceStart
        let tail = min(max(request.target - body, range.lowerBound), range.upperBound)
        // (A chosen end just after a bar line can land before the piece's start.)
        pieces.append(pieceStart...max(pieceStart, d[end] + tail))
        var plan = Plan(pieces: pieces, joins: joins, tempo: 1, fadeIn: 0, fadeOut: 0, ending: kind, score: score, target: request.target)
        let length = plan.length
        plan.tempo = abs(length / request.target - 1) < 0.0005 ? 1 : length / request.target
        // A start part-way into the sound gets a few milliseconds of fade so it doesn't click.
        if start > song.soundStart + 0.01 { plan.fadeIn = 0.005 }
        switch kind {
        case .phrase: plan.fadeOut = tail
        case .real: plan.fadeOut = tail < range.upperBound - 0.05 ? min(1.5, max(0.3, tail * 0.6)) : 0
        case .chosen: plan.fadeOut = (pieces.last?.upperBound ?? 0) < song.soundEnd - 0.01 ? 0.01 : 0
        }
        var at = 0.0
        for (index, piece) in pieces.dropLast().enumerated() {
            at += piece.upperBound - piece.lowerBound
            plan.joins[index].output = at / plan.tempo
        }
        return plan
    }

    /// A join on the sample: each side's downbeat moved onto its real attack, the incoming side
    /// shifted (by up to 4 ms) to where its waveform lines up with the outgoing one, and a
    /// crossfade of a beat-related length that ends on the downbeat: short over hits, long over
    /// held sounds.
    private static func refine(_ i: Int, _ j: Int, _ song: Song) -> Join {
        let rate = song.rate, beat = song.beatLength
        let from = attack(near: song.downbeats[i], song), to = attack(near: song.downbeats[j], song)
        func busy(_ bar: Int) -> Double { song.beatFeatures[max(0, song.beatOfBar[bar] - 1)][17] }
        let hits = max(busy(i), busy(j))
        let crossfade = beat * (hits > 0.5 ? 0.125 : hits > -0.3 ? 0.25 : 0.5)
        let length = Int(crossfade * rate), reach = Int(0.004 * rate)
        let a = Int(from * rate) - length, b = Int(to * rate) - length
        var shift = 0
        if a >= 0, b - reach >= 0, b + reach + length < song.mono.count, a + length < song.mono.count {
            var bestScore = -Double.infinity
            song.mono.withUnsafeBufferPointer { m in
                var outgoing: Float = 0
                vDSP_dotpr(m.baseAddress! + a, 1, m.baseAddress! + a, 1, &outgoing, vDSP_Length(length))
                for lag in -reach...reach {
                    var dot: Float = 0, energy: Float = 0
                    vDSP_dotpr(m.baseAddress! + a, 1, m.baseAddress! + b + lag, 1, &dot, vDSP_Length(length))
                    vDSP_dotpr(m.baseAddress! + b + lag, 1, m.baseAddress! + b + lag, 1, &energy, vDSP_Length(length))
                    let score = Double(dot) / max(sqrt(Double(outgoing) * Double(energy)), 1e-9)
                    if score > bestScore { bestScore = score; shift = lag }
                }
            }
        }
        return Join(from: from, to: to + Double(shift) / rate, fromBar: i, toBar: j, crossfade: crossfade, output: 0)
    }

    /// The start of the attack within 30 ms of a beat time (beat times are measured on a 10 ms
    /// grid); the beat time itself where there's no clear attack (a held pad).
    private static func attack(near time: Double, _ song: Song) -> Double {
        let rate = song.rate, hop = max(1, Int(rate / 1000)), window = 10 * hop
        let first = Int((time - 0.03) * rate), last = Int((time + 0.03) * rate)
        guard first - window >= 0, last + window < song.mono.count else { return time }
        func energy(_ at: Int) -> Float {
            var sum: Float = 0
            song.mono.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + at, 1, &sum, vDSP_Length(window)) }
            return sum
        }
        // The 10 ms after against the 10 ms before: at least 6 dB louder.
        var best = time, bestRise: Float = 4
        for at in stride(from: first, through: last, by: hop) {
            let rise = energy(at) / (energy(at - window) + 1e-7)
            if rise > bestRise { bestRise = rise; best = Double(at) / rate }
        }
        return max(0, best - 0.001)
    }

    // MARK: - Writing

    /// The fitted sound before the tempo change, one array per channel.
    static func mix(_ plan: Plan, _ song: Song) -> [[Float]] {
        let rate = song.rate
        func sample(_ t: Double) -> Int { Int((t * rate).rounded()) }
        let spans = plan.pieces.map { (sample($0.lowerBound), sample($0.upperBound)) }
        let total = spans.reduce(0) { $0 + $1.1 - $1.0 }
        var out = song.channels.map { _ in [Float](repeating: 0, count: total) }
        var cursor = 0
        for (index, span) in spans.enumerated() {
            let fadeIn = index > 0 ? sample(plan.joins[index - 1].crossfade) : 0
            let fadeOut = index < plan.joins.count ? sample(plan.joins[index].crossfade) : 0
            let first = span.0 - fadeIn, length = span.1 - first
            var gains = [Float](repeating: 1, count: length)
            for n in 0..<min(fadeIn, length) { gains[n] = sin(.pi / 2 * (Float(n) + 0.5) / Float(fadeIn)) }
            for n in max(0, length - fadeOut)..<length { gains[n] *= cos(.pi / 2 * (Float(n - (length - fadeOut)) + 0.5) / Float(fadeOut)) }
            for channel in out.indices {
                let source = song.channels[channel]
                for n in 0..<length {
                    let at = cursor - fadeIn + n, from = first + n
                    guard at >= 0, at < total, from >= 0, from < source.count else { continue }
                    out[channel][at] += source[from] * gains[n]
                }
            }
            cursor += span.1 - span.0
        }
        let fadeIn = min(sample(plan.fadeIn), total), fadeOut = min(sample(plan.fadeOut), total)
        for channel in out.indices {
            for n in 0..<fadeIn { out[channel][n] *= sin(.pi / 2 * (Float(n) + 0.5) / Float(fadeIn)) }
            for n in 0..<fadeOut { out[channel][total - fadeOut + n] *= cos(.pi / 2 * (Float(n) + 0.5) / Float(fadeOut)) }
        }
        return out
    }

    /// Writes the fitted song, exactly the target length.
    static func render(_ plan: Plan, song: Song, input: URL, output: URL, ffmpeg: String) async throws {
        let mixed = await Task.detached { mix(plan, song) }.value
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-fit-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(mixed, rate: song.rate, to: temporary)
        let samples = Int((plan.target * song.rate).rounded())
        var filter = plan.tempo == 1 ? "" : String(format: "atempo=%.6f,", plan.tempo)
        filter += "apad,atrim=end_sample=\(samples)"
        let lossless = ["wav", "aif", "aiff", "flac"].contains(output.pathExtension.lowercased())
        var args = ["-nostdin", "-y", "-v", "error", "-i", temporary.path, "-i", input.path, "-map", "0:a", "-map_metadata", "1", "-af", filter]
        args += lossless ? ["-c:a", "pcm_s24le"] : ["-c:a", "aac", "-b:a", "256k"]
        try? FileManager.default.removeItem(at: output)
        let log = await ToolOutput.run(ffmpeg, args + [output.path])
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw FrameRewriter.Failure.writing(log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func write(_ channels: [[Float]], rate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels.count), interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, channels.first?.count ?? 0))) else { return }
        buffer.frameLength = AVAudioFrameCount(channels.first?.count ?? 0)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: channel.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
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
    static func problem(song: Song) -> Problem {
        song.downbeats.count >= 4 ? .tooShort(2 * (song.downbeats[1] - song.downbeats[0]) + song.beatLength) : .noBeat
    }
}

// MARK: - Analysis

extension MusicFit.Song {
    /// Beats from the music map; bars and phrases from where the harmony and the kick change.
    init?(low: [Float], interleaved: [Float], rate: Double) {
        let features = AudioFeatures(samples: low)
        let map = MusicMap(features: features)
        guard map.beats.count >= 16 else { return nil }
        let left = stride(from: 0, to: interleaved.count - 1, by: 2).map { interleaved[$0] }
        let right = stride(from: 1, to: interleaved.count, by: 2).map { interleaved[$0] }
        channels = [left, right]
        mono = zip(left, right).map { ($0 + $1) / 2 }
        self.rate = rate
        duration = Double(left.count) / rate

        // Where the sound starts and ends (50 dB under the peak).
        let peak = mono.reduce(0) { max($0, abs($1)) }
        let floor = max(peak * 0.003, 1e-6)
        soundStart = Double(mono.firstIndex { abs($0) > floor } ?? 0) / rate
        soundEnd = min(duration, Double(mono.lastIndex { abs($0) > floor } ?? left.count) / rate + 0.05)

        let beats = Self.grid(mono, rate: rate, period: 60 / map.tempo, from: soundStart, to: soundEnd)
        guard beats.count >= 16 else { return nil }
        self.beats = beats
        tempo = 60 * Double(beats.count - 1) / (beats[beats.count - 1] - beats[0])

        // Per beat: the average spectrum of the 8 kHz sound.
        let size = 1024, half = size / 2, sr = AudioFeatures.sampleRate
        var chromaBin = [Int](repeating: -1, count: half)
        for bin in 1..<half {
            let f = Double(bin) * sr / Double(size)
            if f >= 100, f <= 2000 { chromaBin[bin] = Self.modulo(Int((12 * log2(f / 440) + 69).rounded()), 12) }
        }
        func bins(_ lo: Double, _ hi: Double) -> Range<Int> { max(1, Int(lo / sr * Double(size)))..<min(half, Int(hi / sr * Double(size))) }
        let energyBands = [bins(20, 150), bins(150, 400), bins(400, 1000), bins(1000, 4000), bins(20, 4000)]
        let vocalBand = bins(300, 3400)
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
        defer { if let fft { vDSP_destroy_fftsetup(fft) } }
        var frame = [Float](repeating: 0, count: size), real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var vectors: [[Double]] = []
        var voices: [Double] = []
        for (index, start) in beats.enumerated() {
            let end = index + 1 < beats.count ? beats[index + 1] : start + 60 / map.tempo
            var sum = [Double](repeating: 0, count: half)
            var frames = 0
            var at = Int(start * sr)
            while at + size <= min(low.count, Int(end * sr) + size / 2), let fft {
                vDSP_vmul(Array(low[at..<(at + size)]), 1, window, 1, &frame, 1, vDSP_Length(size))
                real.withUnsafeMutableBufferPointer { r in
                    imaginary.withUnsafeMutableBufferPointer { i in
                        var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                        frame.withUnsafeBufferPointer { $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) } }
                        vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                for bin in 0..<half { sum[bin] += Double(power[bin]) }
                frames += 1
                at += size / 4
            }
            if frames > 0 { sum = sum.map { $0 / Double(frames) } }
            var chroma = [Double](repeating: 0, count: 12)
            for bin in 0..<half where chromaBin[bin] >= 0 { chroma[chromaBin[bin]] += sqrt(sum[bin]) }
            let total = chroma.reduce(0, +)
            if total > 0 { chroma = chroma.map { $0 / total } }
            let energies = energyBands.map { log10($0.reduce(1e-9) { $0 + sum[$1] }) }
            let a = max(0, Int((start - AudioFeatures.latency) / AudioFeatures.step)), b = min(features.onset.count, max(a + 1, Int((end - AudioFeatures.latency) / AudioFeatures.step)))
            let onset = a < b ? Double(features.onset[a..<b].map { max($0, 0) }.reduce(0, +)) / Double(b - a) : 0
            vectors.append(chroma + energies + [onset])
            voices.append(log10(vocalBand.reduce(1e-9) { $0 + sum[$1] }) - energies[4])
        }
        beatFeatures = vectors
        let usual = voices.sorted()[voices.count / 2]
        vocal = voices.map { max(0, ($0 - usual) * 2) }

        // Bars: the beat phase where the harmony changes most and the kick is strongest.
        func standard(_ values: [Double]) -> [Double] {
            let mean = values.reduce(0, +) / Double(max(values.count, 1))
            let deviation = sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(values.count, 1)))
            return values.map { deviation > 0 ? ($0 - mean) / deviation : 0 }
        }
        let change = standard(vectors.indices.map { k in k == 0 ? 0 : (0..<12).reduce(0) { $0 + abs(vectors[k][$1] - vectors[k - 1][$1]) } / 2 })
        let kick = features.bands.first ?? features.onset
        let accent = standard(beats.map { time -> Double in
            let center = Int(((time - AudioFeatures.latency) / AudioFeatures.step).rounded())
            let range = max(0, center - 3)...min(kick.count - 1, max(0, center + 3))
            return Double(kick[range].max() ?? 0)
        })
        let phase = (0..<4).max { p, q in
            stride(from: p, to: beats.count, by: 4).reduce(0) { $0 + change[$1] + 0.5 * accent[$1] }
                < stride(from: q, to: beats.count, by: 4).reduce(0) { $0 + change[$1] + 0.5 * accent[$1] }
        } ?? 0
        beatOfBar = Array(stride(from: phase, to: beats.count, by: 4))
        downbeats = beatOfBar.map { beats[$0] }

        // Phrases and sections: where two bars sound most unlike the two before.
        let bars = beatOfBar.map { first -> [Double] in
            let range = first..<min(first + 4, vectors.count)
            return (0..<18).map { k in range.reduce(0) { $0 + vectors[$1][k] } / Double(range.count) }
        }
        func mean(_ range: Range<Int>) -> [Double] {
            (0..<18).map { k in range.reduce(0) { $0 + bars[$1][k] } / Double(max(range.count, 1)) }
        }
        let novelty = bars.indices.map { i -> Double in
            guard i >= 1, i + 1 <= bars.count else { return 0 }
            return MusicFit.distance(mean(max(0, i - 2)..<i), mean(i..<min(bars.count, i + 2)))
        }
        let offset = (0..<8).max { p, q in
            stride(from: p, to: novelty.count, by: 8).reduce(0) { $0 + novelty[$1] } < stride(from: q, to: novelty.count, by: 8).reduce(0) { $0 + novelty[$1] }
        } ?? 0
        phraseOffset = offset
        let scores = standard(novelty)
        sectionStarts = Set(novelty.indices.filter { scores[$0] > 1 && Self.modulo($0 - offset, 4) == 0 })
    }

    fileprivate static func modulo(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

    /// The beats to a few milliseconds: the music map's tempo (measured on a 10 ms grid, and
    /// tuned to dance music's kick on every beat) refined against an attack curve at 2.5 ms, as
    /// the period and phase that line up with the most attacks; then each beat follows its own
    /// attack (within 30 ms) where there is a clear one, so a played tempo may drift.
    private static func grid(_ mono: [Float], rate: Double, period rough: Double, from start: Double, to end: Double) -> [Double] {
        let hop = max(1, Int(rate / 400)), step = Double(hop) / rate
        let frames = mono.count / hop
        guard frames > 8, rough > 0.2 else { return [] }
        var level = [Float](repeating: 0, count: frames)
        mono.withUnsafeBufferPointer { m in
            for k in 0..<frames {
                var sum: Float = 0
                vDSP_svesq(m.baseAddress! + k * hop, 1, &sum, vDSP_Length(min(4 * hop, mono.count - k * hop)))
                level[k] = log10(sum + 1e-7)
            }
        }
        // How much louder the 10 ms after a moment are than the 10 ms before (longer than a low
        // note's period, so a held chord doesn't count; silence before the start counts as silence).
        let attack = (0..<frames).map { k in max(0, level[k] - (k >= 4 ? level[k - 4] : -7)) }
        func strength(_ t: Double) -> Float {
            let k = Int((t / step).rounded())
            return k >= 0 && k < frames ? attack[k] : 0
        }
        let first = max(0, start - rough), last = end
        var best = (score: -Float.infinity, period: rough, phase: start)
        var p = rough * 0.97
        while p <= rough * 1.03 {
            var phase = first
            while phase < first + p {
                var score: Float = 0
                var t = phase
                while t < last { score += strength(t); t += p }
                if score > best.score { best = (score, p, phase) }
                phase += step
            }
            p += rough * 0.0005
        }
        // A clear attack: a good part of the song's strongest (the wobble of a held chord isn't one).
        let strong = attack.sorted()[min(frames - 1, frames * 995 / 1000)]
        var beats: [Double] = []
        var expected = best.phase
        while expected < last {
            let a = max(0, Int(((expected - 0.03) / step).rounded())), b = min(frames - 1, Int(((expected + 0.03) / step).rounded()))
            var beat = expected
            // ...that also stands well above the half beat around it (a held chord's wobble doesn't).
            let around = max(0, Int((expected - best.period / 2) / step))..<min(frames, Int((expected + best.period / 2) / step))
            let usual = around.isEmpty ? 0 : around.reduce(0) { $0 + attack[$1] } / Float(around.count)
            if a <= b, let k = (a...b).max(by: { attack[$0] < attack[$1] }), attack[k] > max(0.3, strong * 0.4, usual * 6) {
                beat = Double(k) * step
            }
            if beat >= start - 0.03 { beats.append(max(0, beat)) }
            expected = beat + best.period
        }
        return beats
    }
}
