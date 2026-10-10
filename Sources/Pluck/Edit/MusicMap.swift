import Foundation

/// The shape of a DJ set, from the mixer recording: its beats and bars, and which bars are a
/// breakdown, a build-up, a drop or a normal groove. The edit cuts slower or faster by this.
struct MusicMap: Sendable {
    enum Section: String, Sendable {
        /// Kick and bass playing, the steady part of a track.
        case groove
        /// Kick and bass gone: pads, vocals, a quieter moment.
        case breakdown
        /// The last bars before a drop, usually with a snare roll and a riser.
        case buildUp
        /// Kick and bass back in, full energy.
        case drop
    }

    struct Bar: Sendable {
        var start: Double
        var end: Double
        var section: Section
        /// Bars into the current section (0 = its first bar).
        var position: Int
    }

    /// Beats per minute (the most common tempo; DJ sets change tempo only slowly).
    var tempo: Double
    var beats: [Double]
    var bars: [Bar]

    /// Finds the beats with dynamic programming (each beat close to one period after the
    /// last, on a strong onset), groups them in bars of four (where new parts tend to come in),
    /// and labels each bar by its kick-and-bass energy.
    init(features: AudioFeatures, tempoRange: ClosedRange<Double> = 100...160) {
        let step = AudioFeatures.step
        // Kick and bass hits carry the beat best in dance music; everything else helps.
        let strength: [Float] = features.bands.count > 1
            ? zip(features.bands[0], features.bands[1]).enumerated().map { index, pair in
                pair.0 + 0.5 * pair.1 + 0.25 * features.onset[index] }
            : features.onset
        // A first pass, then the median beat gap for a precise tempo, and a stricter second pass
        // that keeps the tempo through breakdowns instead of slipping onto the off-beat.
        let rough = Self.period(of: strength, step: step, range: tempoRange)
        let first = Self.track(strength, period: rough, tightness: 100)
        let gaps = zip(first.dropFirst(), first).map { Double($0 - $1) }.filter { abs($0 - rough) < rough * 0.1 }
        let period = gaps.count > 8 ? gaps.reduce(0, +) / Double(gaps.count) : rough
        tempo = 60 / (period * step)
        let tracked = Self.track(strength, period: period, tightness: 600)
        // The kick band's hits: whether a beat has a kick, and whether a bar does.
        let kick = features.bands.first ?? features.onset
        let featureBeats = Self.filled(tracked, kick: kick, period: period).map { Double($0) * step }
        // Bars are worked out on the measurements' own clock, then everything moves to real time.
        let latency = AudioFeatures.latency
        beats = featureBeats.map { $0 + latency }
        bars = Self.bars(from: featureBeats, kick: kick, low: features.low).map { bar in
            var bar = bar
            bar.start += latency
            bar.end += latency
            return bar
        }
    }

    // MARK: - Tempo

    /// The beat period in steps: the lag with the strongest autocorrelation in the tempo range,
    /// helped by its multiples (a true beat also repeats every two and four beats).
    private static func period(of strength: [Float], step: Double, range: ClosedRange<Double>) -> Double {
        let shortest = Int(60 / range.upperBound / step), longest = Int(60 / range.lowerBound / step)
        let positive = strength.map { max($0, 0) }
        func correlation(_ lag: Int) -> Double {
            guard lag < positive.count else { return 0 }
            var sum = 0.0
            for i in 0..<(positive.count - lag) { sum += Double(positive[i] * positive[i + lag]) }
            return sum / Double(positive.count - lag)
        }
        var best = shortest, bestScore = -Double.infinity
        var scores: [Int: Double] = [:]
        for lag in shortest...longest {
            let score = correlation(lag) + 0.5 * correlation(lag * 2) + 0.25 * correlation(lag * 4)
            scores[lag] = score
            if score > bestScore { bestScore = score; best = lag }
        }
        // Between whole steps, from the shape of the peak.
        if let a = scores[best - 1], let c = scores[best + 1] {
            let denominator = a - 2 * bestScore + c
            if denominator < 0 { return Double(best) + max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        return Double(best)
    }

    // MARK: - Beats

    /// Ellis's beat tracker: the best chain of beats that sit on strong onsets and keep the
    /// tempo, allowing it to wander a little.
    static func track(_ strength: [Float], period: Double, tightness: Double = 100) -> [Int] {
        let count = strength.count
        guard count > Int(period * 4) else { return [] }
        var score = strength.map(Double.init)
        var previous = [Int](repeating: -1, count: count)
        let lowest = Int((period * 0.5).rounded()), highest = Int((period * 2).rounded())
        for t in 0..<count {
            var best = -Double.infinity, bestFrom = -1
            let from = max(0, t - highest), to = t - lowest
            if to >= from {
                for tau in from...to {
                    let gap = Double(t - tau)
                    let penalty = -tightness * pow(log(gap / period), 2)
                    let candidate = score[tau] + penalty
                    if candidate > best { best = candidate; bestFrom = tau }
                }
            }
            if bestFrom >= 0, best > 0 {
                score[t] += best
                previous[t] = bestFrom
            }
        }
        // Start from the best-scoring beat near the end and walk back.
        let tail = max(0, count - Int(period * 2))
        var t = (tail..<count).max { score[$0] < score[$1] } ?? count - 1
        var beats: [Int] = []
        while t >= 0 {
            beats.append(t)
            t = previous[t]
        }
        return beats.reversed()
    }

    /// Where the beat is too weak to follow (a breakdown with only pads), an even grid between
    /// the last clear beat before it and the first after: DJs keep the tempo through it.
    static func filled(_ beats: [Int], kick: [Float], period: Double) -> [Double] {
        guard beats.count > 8 else { return beats.map(Double.init) }
        // A beat is clear when a kick hits on it, harder than between the beats, and as part of a
        // run of at least two bars: a pad's attack once a bar or a few stray hits don't count.
        let hits = beats.map { Self.peak(kick, at: Double($0)) }
        let between = beats.indices.map { index -> Float in
            let next = index + 1 < beats.count ? Double(beats[index + 1]) : Double(beats[index]) + period
            return Self.peak(kick, at: (Double(beats[index]) + next) / 2)
        }
        let loud = hits.sorted()[hits.count * 3 / 4]
        let hitting = beats.indices.map { hits[$0] > max(2, loud * 0.35) && between[$0] < hits[$0] * 0.5 }
        var clear = [Bool](repeating: false, count: beats.count)
        var runStart = 0
        for index in 0...beats.count {
            if index == beats.count || !hitting[index] {
                if index - runStart >= 8 { for k in runStart..<index { clear[k] = true } }
                runStart = index + 1
            }
        }
        var result: [Double] = []
        var index = 0
        while index < beats.count {
            guard !clear[index], let before = result.last else {
                result.append(Double(beats[index]))
                index += 1
                continue
            }
            // A run of unclear beats: find the next clear one and spread beats evenly up to it.
            var next = index
            while next < beats.count, !clear[next] { next += 1 }
            guard next < beats.count else {
                // Unclear to the end: keep counting at the tempo.
                var time = before + period
                while time < Double(kick.count) { result.append(time); time += period }
                break
            }
            let after = Double(beats[next])
            let count = max(1, Int(((after - before) / period).rounded()))
            for k in 1..<count { result.append(before + (after - before) * Double(k) / Double(count)) }
            index = next
        }
        return result
    }

    // MARK: - Bars and sections

    /// The strongest value within 30 ms of a moment (in steps).
    private static func peak(_ series: [Float], at index: Double) -> Float {
        let center = Int(index.rounded())
        let a = max(0, center - 3), b = min(series.count - 1, center + 3)
        guard a <= b else { return 0 }
        return series[a...b].max() ?? 0
    }

    private static func bars(from beats: [Double], kick: [Float], low: [Float]) -> [Bar] {
        guard beats.count >= 8 else { return [] }
        let step = AudioFeatures.step
        // Kick strength on each beat, and halfway to the next beat.
        let onBeat = beats.map { peak(kick, at: $0 / step) }
        let between = beats.indices.map { index -> Float in
            let next = index + 1 < beats.count ? beats[index + 1] : beats[index] + (beats[index] - beats[max(0, index - 1)])
            return peak(kick, at: (beats[index] + next) / 2 / step)
        }
        // Where bars start: tracks change on the first beat of a bar, so pick the one of the four
        // beat phases where the kick most often comes in or drops out.
        let change: [Double] = beats.indices.dropFirst().map { index in Double(abs(onBeat[index] - onBeat[index - 1])) }
        func totalChange(_ phase: Int) -> Double {
            var total = 0.0
            for index in stride(from: phase, to: change.count, by: 4) { total += change[index] }
            return total
        }
        // change[i] is the change into beat i + 1, so the phase with most change is one beat on.
        let strongest = (0..<4).max { totalChange($0) < totalChange($1) } ?? 0
        let phase = (strongest + 1) % 4

        var bars: [Bar] = []
        var index = phase
        while index + 4 < beats.count {
            bars.append(Bar(start: beats[index], end: beats[index + 4], section: .groove, position: 0))
            index += 4
        }
        guard bars.count >= 4 else { return bars }

        // Kick per bar: how much harder the low end hits on the beats than halfway between them.
        // A kick pulses on the beat; a riser, snare roll or pad doesn't, even when it's loud.
        // The lower middle of the bar's four beats: a kick hits on all of them, a pad's attack or
        // a crash only on one.
        let energy = stride(from: phase, to: phase + bars.count * 4, by: 4).map { first -> Double in
            let range = first..<min(first + 4, beats.count)
            let contrasts = range.map { Double(onBeat[$0] - between[$0]) }.sorted()
            return contrasts.isEmpty ? 0 : contrasts[(contrasts.count - 1) / 2]
        }
        let sorted = energy.sorted()
        let loud = sorted[sorted.count * 9 / 10], quiet = sorted[sorted.count / 10]
        // A kick clearly hits harder on the beat (the measure is in standard deviations). The
        // loudest bars set the scale, but even a drop with a rolling bass between the kicks is
        // well above a breakdown or build-up.
        let threshold = max(1.5, quiet + (loud - quiet) * 0.2)
        // A kick also brings real low end: a snare on every beat pulses too, but it's thin.
        let lowLevel = bars.map { bar -> Double in
            let a = max(0, Int(bar.start / step)), b = min(low.count, max(a + 1, Int(bar.end / step)))
            return a < b ? Double(low[a..<b].reduce(0, +)) / Double(b - a) : 0
        }
        let lowSorted = lowLevel.sorted()
        let lowQuiet = lowSorted[lowSorted.count / 10], lowLoud = lowSorted[lowSorted.count * 9 / 10]
        // A kick that's there for at least two bars (one bar on its own is a fill or a crash).
        var full = bars.indices.map { energy[$0] >= threshold && lowLevel[$0] >= lowQuiet + (lowLoud - lowQuiet) * 0.5 }
        var runStart = 0
        for index in 0...full.count {
            if index == full.count || !full[index] {
                if index - runStart < 2 { for k in runStart..<index { full[k] = false } }
                runStart = index + 1
            }
        }

        // Breakdowns: two bars or more without the low end. The bars just before a breakdown
        // ends are its build-up; the bars after it, while the low end stays, are the drop.
        var sections = full.map { $0 ? Section.groove : Section.breakdown }
        var i = 0
        while i < sections.count {
            guard sections[i] == .breakdown else { i += 1; continue }
            var j = i
            while j < sections.count, sections[j] == .breakdown { j += 1 }
            if j - i < 2 {
                for k in i..<j { sections[k] = .groove }
            } else if j < sections.count {
                // A build-up of up to 8 bars, at most half of the breakdown.
                let build = min(8, (j - i) / 2)
                for k in (j - build)..<j { sections[k] = .buildUp }
                var k = j
                while k < sections.count, sections[k] == .groove, k - j < 32 { sections[k] = .drop; k += 1 }
            }
            i = j
        }
        var position = 0
        for k in bars.indices {
            position = k > 0 && sections[k] == sections[k - 1] ? position + 1 : 0
            bars[k].section = sections[k]
            bars[k].position = position
        }
        return bars
    }
}
