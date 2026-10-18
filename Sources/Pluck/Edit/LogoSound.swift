import Foundation

/// A logo's sound: a short hit on the moment the hero lands, made here (no recordings), its
/// character after the animation's feel; optionally a whoosh that rises into it. Silence by default.
enum LogoSound: String, CaseIterable, Identifiable, Sendable {
    case none, hit, whoosh
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: String(localized: "None")
        case .hit: String(localized: "Hit")
        case .whoosh: String(localized: "Whoosh and Hit")
        }
    }

    var help: String {
        switch self {
        case .none: String(localized: "Silent")
        case .hit: String(localized: "A short sound on the moment the logo lands, in its feel")
        case .whoosh: String(localized: "A rush of air into the moment the logo lands, then the hit")
        }
    }

    static let sampleRate = 48_000

    /// Writes the sound for a video of `length` seconds, the hit at `resolve` seconds, as a
    /// 16-bit stereo WAV.
    func write(to url: URL, length: Double, resolve: Double, feel: LogoProfile.Personality) throws {
        let rate = Double(Self.sampleRate)
        let count = max(Int((length * rate).rounded()), 1)
        var samples = [Double](repeating: 0, count: count)
        let at = Int((resolve * rate).rounded())
        var noise = SeededRandom(seed: 0x5EED)
        func white() -> Double { noise.next() * 2 - 1 }

        if self == .whoosh {
            // Filtered noise, opening up and swelling into the hit, gone at the hit.
            let span = Int(0.7 * rate)
            var low = 0.0
            for n in 0..<span {
                let i = at - span + n
                guard i >= 0, i < count else { continue }
                let x = Double(n) / Double(span)
                let cutoff = 300 * pow(20, x)
                let a = 1 - exp(-2 * .pi * cutoff / rate)
                low += a * (white() - low)
                let envelope = pow(sin(.pi / 2 * x), 2) * (n > span - Int(0.02 * rate) ? Double(span - n) / (0.02 * rate) : 1)
                samples[i] += low * envelope * 0.35
            }
        }
        if self != .none {
            let hit = Self.hit(feel, rate: rate, random: &noise)
            for (n, value) in hit.enumerated() where at + n < count && at + n >= 0 { samples[at + n] += value }
        }

        // 16-bit stereo, a little headroom.
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 4)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(2)); append(UInt32(Self.sampleRate)); append(UInt32(Self.sampleRate * 4))
        append(UInt16(4)); append(UInt16(16)); data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 4))
        for value in samples {
            let v = Int16(max(min(value, 1), -1) * 30_000)
            append(v); append(v)
        }
        try data.write(to: url)
    }

    /// The hit itself, in the feel: a soft bell (calm), a deep thump with air (premium), a pop
    /// (playful), a punchy thump (bold). It starts at its first sample.
    private static func hit(_ feel: LogoProfile.Personality, rate: Double, random: inout SeededRandom) -> [Double] {
        func sweep(from f0: Double, to f1: Double, over seconds: Double, decay: Double, length: Double) -> [Double] {
            var phase = 0.0
            return (0..<Int(length * rate)).map { n in
                let t = Double(n) / rate
                let f = f1 + (f0 - f1) * exp(-t / seconds)
                phase += 2 * .pi * f / rate
                return sin(phase) * exp(-t / decay) * min(t / 0.003, 1)
            }
        }
        switch feel {
        case .calm:
            return (0..<Int(1.2 * rate)).map { n in
                let t = Double(n) / rate
                let tone = sin(2 * .pi * 523.25 * t) + 0.3 * sin(2 * .pi * 1046.5 * t) + 0.12 * sin(2 * .pi * 1568 * t)
                return tone * exp(-t / 0.35) * min(t / 0.004, 1) * 0.28
            }
        case .premium:
            let thump = sweep(from: 90, to: 45, over: 0.12, decay: 0.45, length: 1)
            var air = 0.0
            return thump.enumerated().map { n, value in
                let t = Double(n) / rate
                air += 0.08 * ((random.next() * 2 - 1) - air)
                return value * 0.55 + air * exp(-t / 0.35) * 0.25
            }
        case .playful:
            let pop = sweep(from: 500, to: 1100, over: 0.03, decay: 0.07, length: 0.3)
            return pop.enumerated().map { n, value in value * 0.45 + (n < 90 ? (random.next() * 2 - 1) * 0.15 * Double(90 - n) / 90 : 0) }
        case .bold:
            let thump = sweep(from: 130, to: 48, over: 0.06, decay: 0.28, length: 0.8)
            return thump.enumerated().map { n, value in
                tanh(value * 2.2) * 0.55 + (n < 100 ? (random.next() * 2 - 1) * 0.25 * Double(100 - n) / 100 : 0)
            }
        }
    }
}
