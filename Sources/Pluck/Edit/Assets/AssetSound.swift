import Accelerate
import Foundation

/// A seeded random source (SplitMix64): the same numbers for the same seed, on every Mac.
struct AssetRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func noise() -> Float { Float(unit() * 2 - 1) }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// A state-variable filter (topology-preserving): low, band and high pass at once, steady while
/// its cutoff moves every sample.
struct AssetFilter {
    private var ic1: Float = 0, ic2: Float = 0

    mutating func run(_ x: Float, _ cutoff: Double, q: Double = 0.707) -> (low: Float, band: Float, high: Float) {
        let g = Float(tan(Double.pi * min(max(cutoff, 10), AssetSound.rate * 0.45) / AssetSound.rate)), k = Float(1 / q)
        let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
        let v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1, x - k * v1 - v2)
    }
}

/// Sound effects and music made by Pluck: offline, deterministic per seed, 48 kHz stereo.
enum AssetSound {
    static let rate = 48_000.0

    struct Sound {
        var left: [Float]
        var right: [Float]
        var loops = false
        var bpm: Int?
        var key: String?
    }

    static func make(_ kind: AssetKind, seed: UInt64) -> Sound {
        var r = AssetRandom(seed)
        var sound: Sound
        switch kind {
        case .whoosh: sound = sweep(&r, length: r.range(1.0...2.2), low: r.range(200...500), high: r.range(1800...4500), q: r.range(0.8...2.2))
        case .swish: sound = sweep(&r, length: r.range(0.35...0.7), low: r.range(1500...3000), high: r.range(6000...10000), q: r.range(1.2...3))
        case .swoosh: sound = swoosh(&r)
        case .riser: sound = riser(&r, falling: false)
        case .downer: sound = riser(&r, falling: true)
        case .impact: sound = impact(&r, deep: false)
        case .boom: sound = impact(&r, deep: true)
        case .glitch: sound = glitch(&r)
        case .click: sound = click(&r)
        case .pop: sound = pop(&r)
        case .reverse: sound = reverse(&r)
        case .tapeStop: sound = tapeStop(&r)
        case .shutter: sound = shutter(&r)
        case .typing: sound = typing(&r)
        case .ambience: sound = ambience(&r)
        case .pad, .pulse, .beat: sound = loop(kind, &r)
        case .stinger: sound = stinger(&r)
        default: sound = Sound(left: [], right: [])
        }
        finish(&sound)
        return sound
    }

    // MARK: - Helpers

    private static func count(_ seconds: Double) -> Int { Int(seconds * rate) }

    /// Equal-power pan, −1 (left) … 1 (right).
    private static func pan(_ value: Double) -> (Float, Float) {
        let angle = (min(max(value, -1), 1) + 1) * .pi / 4
        return (Float(cos(angle)), Float(sin(angle)))
    }

    private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    private static func midi(_ note: Double) -> Double { 440 * pow(2, (note - 69) / 12) }

    /// A naive saw, −1…1 (filtered afterwards, so its aliasing stays inaudible).
    private static func saw(_ phase: Double) -> Float { Float(2 * (phase - floor(phase)) - 1) }

    /// Mixed into `into` at a sample offset (beyond the end grows it).
    private static func mix(_ part: Sound, into sound: inout Sound, at offset: Int, gain: Float = 1) {
        let end = offset + part.left.count
        if end > sound.left.count {
            sound.left += [Float](repeating: 0, count: end - sound.left.count)
            sound.right += [Float](repeating: 0, count: end - sound.right.count)
        }
        for i in 0..<part.left.count {
            sound.left[offset + i] += part.left[i] * gain
            sound.right[offset + i] += part.right[i] * gain
        }
    }

    // MARK: - Sound effects

    /// Filtered noise swept up and down with the loudness, moving across the stereo field.
    private static func sweep(_ r: inout AssetRandom, length: Double, low: Double, high: Double, q: Double) -> Sound {
        let n = count(length), peak = r.range(0.35...0.6), from = r.range(0.3...0.9) * (r.chance(0.5) ? -1 : 1), to = -from
        var left = [Float](repeating: 0, count: n), right = left
        var bandL = AssetFilter(), bandR = AssetFilter(), body = AssetFilter()
        for i in 0..<n {
            let x = Double(i) / Double(n)
            let env = x < peak ? pow(x / peak, 2) : pow((1 - x) / (1 - peak), 1.6)
            let cutoff = low * pow(high / low, env)
            let shared = r.noise(), wide = r.noise()
            let bodySample = body.run(shared, cutoff * 0.4, q: 0.7).low * 0.5
            let l = bandL.run(shared * 0.7 + wide * 0.3, cutoff, q: q).band + bodySample
            let rr = bandR.run(shared * 0.7 - wide * 0.3, cutoff * 1.03, q: q).band + bodySample
            let (gl, gr) = pan(from + (to - from) * smooth(x))
            left[i] = l * Float(env) * gl
            right[i] = rr * Float(env) * gr
        }
        return Sound(left: left, right: right)
    }

    /// Two sweeps and a low tone that rises and falls: a transition.
    private static func swoosh(_ r: inout AssetRandom) -> Sound {
        let length = r.range(1.0...1.6)
        var sound = sweep(&r, length: length, low: r.range(300...600), high: r.range(2500...4000), q: 1.2)
        mix(sweep(&r, length: length * 0.8, low: r.range(1200...2000), high: r.range(6000...9000), q: 2), into: &sound, at: count(length * 0.1), gain: 0.5)
        var phase = 0.0
        let n = count(length), top = r.range(160...240)
        var tone = Sound(left: .init(repeating: 0, count: n), right: .init(repeating: 0, count: n))
        for i in 0..<n {
            let x = Double(i) / Double(n), env = sin(.pi * x)
            phase += (60 + (top - 60) * env) / rate
            let v = Float(sin(2 * .pi * phase) * env * 0.25)
            tone.left[i] = v
            tone.right[i] = v
        }
        mix(tone, into: &sound, at: 0)
        return sound
    }

    /// Noise and detuned saws gliding up as it gets louder (or down as it fades: a downer).
    private static func riser(_ r: inout AssetRandom, falling: Bool) -> Sound {
        let length = falling ? r.range(2.0...3.5) : r.range(3.0...6.0), n = count(length)
        let base = r.range(90...180), climb = r.range(3...6), curve = r.range(1.6...2.6)
        var left = [Float](repeating: 0, count: n), right = left
        var noiseL = AssetFilter(), noiseR = AssetFilter(), toneL = AssetFilter(), toneR = AssetFilter()
        var phases = [0.0, 0.0, 0.0, 0.0]
        let detune = [1.0, 1.006, 0.994, 1.012]
        for i in 0..<n {
            let x = Double(i) / Double(n), up = falling ? 1 - x : x
            let env = falling ? pow(1 - x, 1.5) * min(1, x * length / 0.01) : pow(x, curve)
            let pitch = base * pow(climb, up)
            var l: Float = 0, rr: Float = 0
            for v in 0..<4 {
                phases[v] += pitch * detune[v] / rate
                let s = saw(phases[v])
                if v % 2 == 0 { l += s } else { rr += s }
            }
            let cutoff = 300 * pow(30, up)
            let tl = toneL.run(l * 0.4, pitch * 4, q: 0.9).low, tr = toneR.run(rr * 0.4, pitch * 4, q: 0.9).low
            let nl = falling ? noiseL.run(r.noise(), cutoff, q: 0.8).low : noiseL.run(r.noise(), cutoff, q: 0.8).high
            let nr = falling ? noiseR.run(r.noise(), cutoff, q: 0.8).low : noiseR.run(r.noise(), cutoff, q: 0.8).high
            left[i] = (tl + nl * 0.6) * Float(env)
            right[i] = (tr + nr * 0.6) * Float(env)
        }
        return Sound(left: left, right: right)
    }

    /// A sub that drops in pitch, a burst of noise and a transient (deep: a long boom).
    private static func impact(_ r: inout AssetRandom, deep: Bool) -> Sound {
        let length = deep ? r.range(3.0...4.5) : r.range(1.5...2.5), n = count(length)
        let low = deep ? r.range(30...42) : r.range(45...60), high = deep ? r.range(80...110) : r.range(130...180)
        let subDecay = deep ? r.range(1.0...1.6) : r.range(3...5), noiseDecay = deep ? r.range(1.2...2) : r.range(9...14)
        let noiseTop = deep ? r.range(150...260) : r.range(2000...4000)
        var left = [Float](repeating: 0, count: n), right = left
        var nl = AssetFilter(), nr = AssetFilter()
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            phase += (low + (high - low) * exp(-t * 30)) / rate
            let attack = min(1, t / 0.002)
            let sub = Float(sin(2 * .pi * phase) * exp(-t * subDecay) * attack) * 0.9
            let cutoff = noiseTop * exp(-t * 6) + 120
            let noiseEnv = Float(exp(-t * noiseDecay) * attack) * (deep ? 0.6 : 0.5)
            let click = Float(exp(-t * 700)) * 0.4
            left[i] = sub + nl.run(r.noise(), cutoff).low * noiseEnv + r.noise() * click
            right[i] = sub + nr.run(r.noise(), cutoff).low * noiseEnv + r.noise() * click
        }
        return Sound(left: left, right: right)
    }

    /// Short pieces of digital trouble: crushed tones, held noise, stutters and gaps.
    private static func glitch(_ r: inout AssetRandom) -> Sound {
        let n = count(r.range(0.5...1.2))
        var left = [Float](repeating: 0, count: n), right = left
        var i = 0
        var last: [Float] = []
        while i < n {
            let length = min(count(r.range(0.02...0.08)), n - i)
            var piece = [Float](repeating: 0, count: length)
            switch r.int(0...3) {
            case 0:
                let freq = r.range(200...3000), steps = Float(r.int(3...8))
                for k in 0..<length {
                    let s: Float = sin(2 * .pi * freq * Double(k) / rate) > 0 ? 0.6 : -0.6
                    piece[k] = (s * steps).rounded() / steps
                }
            case 1:
                let hold = r.int(4...32)
                var held: Float = 0
                for k in 0..<length { if k % hold == 0 { held = r.noise() * 0.7 }; piece[k] = held }
            case 2:
                if !last.isEmpty { for k in 0..<length { piece[k] = last[k % last.count] } }
            default: break
            }
            // (1 ms fades: no clicks inside.)
            let fade = min(48, length / 2)
            for k in 0..<fade {
                let g = Float(k) / Float(fade)
                piece[k] *= g
                piece[length - 1 - k] *= g
            }
            let (gl, gr) = pan(r.range(-0.7...0.7))
            for k in 0..<length {
                left[i + k] = piece[k] * gl
                right[i + k] = piece[k] * gr
            }
            if piece.contains(where: { $0 != 0 }) { last = piece }
            i += length
        }
        return Sound(left: left, right: right)
    }

    private static func click(_ r: inout AssetRandom) -> Sound {
        let n = count(r.range(0.04...0.09)), freq = r.range(1800...4000), decay = r.range(120...250)
        var left = [Float](repeating: 0, count: n), right = left
        for i in 0..<n {
            let t = Double(i) / rate, attack = min(1, t / 0.0003)
            let v = Float(sin(2 * .pi * freq * t) * exp(-t * decay) * attack) + r.noise() * Float(exp(-t * 600) * attack) * 0.3
            left[i] = v
            right[i] = v
        }
        return Sound(left: left, right: right)
    }

    /// A bubble: a sine whose pitch falls fast.
    private static func pop(_ r: inout AssetRandom) -> Sound {
        let n = count(r.range(0.12...0.22)), start = r.range(700...1100), end = r.range(180...300)
        var left = [Float](repeating: 0, count: n), right = left
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            phase += (end + (start - end) * exp(-t * 40)) / rate
            let v = Float(sin(2 * .pi * phase) * exp(-t * 25) * min(1, t / 0.002))
            left[i] = v
            right[i] = v
        }
        return Sound(left: left, right: right)
    }

    /// A chord's decaying tail, played backwards: it swells up to the cut.
    private static func reverse(_ r: inout AssetRandom) -> Sound {
        let n = count(r.range(1.5...2.5)), root = 48 + Double(r.int(0...11))
        let notes = [root, root + (r.chance(0.5) ? 3 : 4), root + 7, root + 12].map(midi)
        var left = [Float](repeating: 0, count: n), right = left
        var nl = AssetFilter(), nr = AssetFilter()
        for i in 0..<n {
            let t = Double(i) / rate, decay = exp(-t * 2.2), attack = min(1, t / 0.003)
            var v = 0.0
            for (k, f) in notes.enumerated() { v += sin(2 * .pi * f * t + Double(k)) * 0.22 }
            left[i] = Float(v * decay * attack) + nl.run(r.noise(), 2500).low * Float(decay * attack) * 0.4
            right[i] = Float(v * decay * attack) + nr.run(r.noise(), 2500).low * Float(decay * attack) * 0.4
        }
        return Sound(left: left.reversed(), right: right.reversed())
    }

    /// A chord played back slower and slower until it stops.
    private static func tapeStop(_ r: inout AssetRandom) -> Sound {
        let n = count(r.range(1.0...1.6)), root = 45 + Double(r.int(0...11))
        let notes = [root, root + 7, root + 12, root + (r.chance(0.5) ? 15 : 16)].map(midi)
        var left = [Float](repeating: 0, count: n), right = left
        var fl = AssetFilter(), fr = AssetFilter()
        var phases = [Double](repeating: 0, count: notes.count)
        for i in 0..<n {
            let x = Double(i) / Double(n), speed = pow(1 - x, 2)
            var l: Float = 0, rr: Float = 0
            for k in notes.indices {
                phases[k] += notes[k] * speed / rate
                if k % 2 == 0 { l += saw(phases[k]) * 0.3 } else { rr += saw(phases[k]) * 0.3 }
            }
            let cutoff = 300 + 2500 * speed
            left[i] = fl.run(l + rr * 0.5, cutoff).low * Float(0.3 + 0.7 * speed)
            right[i] = fr.run(rr + l * 0.5, cutoff).low * Float(0.3 + 0.7 * speed)
        }
        return Sound(left: left, right: right)
    }

    /// A camera: two mechanical clicks and a soft thump.
    private static func shutter(_ r: inout AssetRandom) -> Sound {
        let n = count(r.range(0.25...0.4)), gap = r.range(0.06...0.14)
        var left = [Float](repeating: 0, count: n), right = left
        for (offset, tone) in [(0.0, r.range(3500...5000)), (gap, r.range(2500...4200))] {
            var fl = AssetFilter(), fr = AssetFilter()
            let start = count(offset)
            for i in start..<min(n, start + count(0.06)) {
                let t = Double(i - start) / rate, env = Float(exp(-t * 300) * min(1, t / 0.0004))
                let thump = Float(sin(2 * .pi * 120 * t) * exp(-t * 60)) * 0.4
                left[i] += fl.run(r.noise(), tone, q: 2).band * env * 1.6 + thump * env
                right[i] += fr.run(r.noise(), tone * 1.05, q: 2).band * env * 1.6 + thump * env
            }
        }
        return Sound(left: left, right: right)
    }

    /// Keys pressed at a typing pace; now and then the space bar.
    private static func typing(_ r: inout AssetRandom) -> Sound {
        let n = count(r.range(3...5))
        var sound = Sound(left: .init(repeating: 0, count: n), right: .init(repeating: 0, count: n))
        var at = r.range(0.05...0.15)
        while count(at + 0.08) < n {
            let space = r.chance(0.12), tone = space ? r.range(700...1100) : r.range(2000...5000)
            let gain = Float(r.range(0.4...1)), (gl, gr) = pan(r.range(-0.25...0.25))
            var f = AssetFilter()
            let length = count(space ? 0.07 : 0.035)
            var key = Sound(left: .init(repeating: 0, count: length), right: .init(repeating: 0, count: length))
            for i in 0..<length {
                let t = Double(i) / rate, env = Float(exp(-t * (space ? 120 : 250)) * min(1, t / 0.0003))
                let v = (f.run(r.noise(), tone, q: 3).band * 1.5 + Float(sin(2 * .pi * 180 * t) * exp(-t * 80)) * 0.3) * env * gain
                key.left[i] = v * gl
                key.right[i] = v * gr
            }
            mix(key, into: &sound, at: count(at))
            at += r.range(0.07...0.22) + (r.chance(0.1) ? r.range(0.2...0.5) : 0)
        }
        return sound
    }

    /// A bed that loops: room tone, air or wind, its slow movement whole cycles of the loop.
    private static func ambience(_ r: inout AssetRandom) -> Sound {
        let length = r.range(20...30), n = count(length), fade = count(1.5)
        let style = r.int(0...2), cycles = Double(r.int(1...3)), phase = r.range(0...(2 * .pi))
        var left = [Float](repeating: 0, count: n + fade), right = left
        var fl = AssetFilter(), fr = AssetFilter(), bl: Float = 0, br: Float = 0
        for i in 0..<(n + fade) {
            let x = Double(i) / Double(n), wave = sin(2 * .pi * cycles * x + phase)
            // (Brown-ish noise underneath: a leaky sum of white noise.)
            bl = bl * 0.995 + r.noise() * 0.05
            br = br * 0.995 + r.noise() * 0.05
            switch style {
            case 0:
                left[i] = fl.run(bl, 400).low * 2
                right[i] = fr.run(br, 400).low * 2
            case 1:
                left[i] = fl.run(r.noise(), 1800 * (1 + 0.2 * wave)).low * 0.4 + bl
                right[i] = fr.run(r.noise(), 1800 * (1 - 0.2 * wave)).low * 0.4 + br
            default:
                let gust = Float(0.6 + 0.4 * wave)
                left[i] = fl.run(r.noise(), 500 * (1 + 0.7 * wave), q: 2.5).band * gust + bl * 0.5
                right[i] = fr.run(r.noise(), 520 * (1 + 0.7 * wave), q: 2.5).band * gust + br * 0.5
            }
        }
        var sound = Sound(left: crossfaded(left, n, fade), right: crossfaded(right, n, fade), loops: true)
        sound.loops = true
        return sound
    }

    /// The `fade` samples past the loop's end faded over its start (equal power, for noise): the end
    /// runs on into the start without a seam.
    private static func crossfaded(_ x: [Float], _ n: Int, _ fade: Int) -> [Float] {
        var out = Array(x[0..<n])
        for i in 0..<fade {
            let a = Double(i) / Double(fade)
            out[i] = x[i] * Float(sin(a * .pi / 2)) + x[n + i] * Float(cos(a * .pi / 2))
        }
        return out
    }

    /// What rings past a loop's end added to its start, as it would sound looping.
    private static func folded(_ sound: Sound, _ n: Int) -> Sound {
        var out = Sound(left: Array(sound.left.prefix(n)), right: Array(sound.right.prefix(n)), loops: true)
        out.left += [Float](repeating: 0, count: max(0, n - out.left.count))
        out.right += [Float](repeating: 0, count: max(0, n - out.right.count))
        for i in n..<sound.left.count {
            out.left[(i - n) % n] += sound.left[i]
            out.right[(i - n) % n] += sound.right[i]
        }
        return out
    }

    // MARK: - Music (generated)

    private static let keyNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// A chord progression's root offsets and whether each chord is minor.
    private static func progression(minor: Bool, _ r: inout AssetRandom) -> [(Int, Bool)] {
        minor ? r.pick([[(0, true), (8, false), (3, false), (10, false)], [(0, true), (5, true), (8, false), (7, false)]])
              : r.pick([[(0, false), (7, false), (9, true), (5, false)], [(0, false), (5, false), (9, true), (7, false)]])
    }

    /// Pads, a pulse or a beat: bars at a tempo, in a key (beats have none), looping.
    private static func loop(_ kind: AssetKind, _ r: inout AssetRandom) -> Sound {
        let minor = r.chance(0.5), tonic = r.int(0...11)
        let bpm = kind == .pad ? r.int(70...96) : r.int(96...124)
        let beat = 60 / Double(bpm), bars = kind == .pad ? 8 : kind == .pulse ? 4 : 2
        let n = count(Double(bars * 4) * beat)
        var sound = Sound(left: .init(repeating: 0, count: n), right: .init(repeating: 0, count: n))
        let chords = progression(minor: minor, &r)
        switch kind {
        case .pad:
            let chordLength = Double(bars * 4) * beat / Double(chords.count), cycles = Double(r.int(1...2))
            for (index, chord) in chords.enumerated() {
                let root = 48 + Double(tonic + chord.0)
                let notes = [root - 12, root, root + (chord.1 ? 3 : 4), root + 7, root + 12].map(midi)
                let length = count(chordLength + 1.2), start = count(Double(index) * chordLength)
                var part = Sound(left: .init(repeating: 0, count: length), right: .init(repeating: 0, count: length))
                var fl = AssetFilter(), fr = AssetFilter()
                for i in 0..<length {
                    let t = Double(i) / rate
                    let env = min(1, t / 0.8) * (t > chordLength ? max(0, 1 - (t - chordLength) / 1.2) : 1)
                    let x = Double(start + i) / Double(n)
                    let cutoff = 900 + 500 * sin(2 * .pi * cycles * x)
                    var l: Float = 0, rr: Float = 0
                    for (k, f) in notes.enumerated() {
                        l += saw(f * 0.997 * t + Double(k) * 0.13) * 0.12
                        rr += saw(f * 1.003 * t + Double(k) * 0.29) * 0.12
                    }
                    part.left[i] = fl.run(l, cutoff).low * Float(env)
                    part.right[i] = fr.run(rr, cutoff).low * Float(env)
                }
                mix(part, into: &sound, at: start)
            }
        case .pulse:
            let step = beat / 2
            for s in 0..<(bars * 8) {
                let chord = chords[(s / 8) % chords.count]
                let root = 57 + Double(tonic + chord.0)
                let tones = [root, root + (chord.1 ? 3 : 4), root + 7, root + 12]
                let f = midi(tones[[0, 2, 1, 3, 2, 1, 3, 2][s % 8]])
                let length = count(step * 1.8)
                var part = Sound(left: .init(repeating: 0, count: length), right: .init(repeating: 0, count: length))
                var filter = AssetFilter()
                let (gl, gr) = pan(s % 2 == 0 ? -0.3 : 0.3)
                for i in 0..<length {
                    let t = Double(i) / rate, env = exp(-t * 7) * min(1, t / 0.003)
                    let v = filter.run(saw(f * t) * 0.5, 300 + 3000 * exp(-t * 14), q: 1.4).low * Float(env)
                    part.left[i] = v * gl
                    part.right[i] = v * gr
                }
                mix(part, into: &sound, at: count(Double(s) * step))
            }
        default:
            let sixteenth = beat / 4, busy = r.unit()
            for s in 0..<(bars * 16) {
                let at = count(Double(s) * sixteenth), inBar = s % 16
                if inBar == 0 || inBar == 8 || (inBar == 10 && busy > 0.5) || (inBar == 7 && busy > 0.75) { mix(drum(.kick, &r), into: &sound, at: at) }
                if inBar == 4 || inBar == 12 { mix(drum(.snare, &r), into: &sound, at: at) }
                if s % 2 == 0 || r.chance(busy * 0.4) { mix(drum(inBar == 14 && busy > 0.3 ? .open : .hat, &r), into: &sound, at: at, gain: s % 4 == 0 ? 0.8 : 0.5) }
            }
            var out = folded(sound, n)
            out.bpm = bpm
            return out
        }
        var out = folded(sound, n)
        out.bpm = bpm
        out.key = keyNames[tonic] + (minor ? String(localized: " minor") : String(localized: " major"))
        return out
    }

    private enum Drum { case kick, snare, hat, open }

    private static func drum(_ drum: Drum, _ r: inout AssetRandom) -> Sound {
        let length = count(drum == .kick ? 0.45 : drum == .open ? 0.35 : drum == .snare ? 0.25 : 0.06)
        var part = Sound(left: .init(repeating: 0, count: length), right: .init(repeating: 0, count: length))
        var fl = AssetFilter(), fr = AssetFilter()
        var phase = 0.0
        for i in 0..<length {
            let t = Double(i) / rate, attack = Float(min(1, t / 0.001))
            switch drum {
            case .kick:
                phase += (50 + 100 * exp(-t * 35)) / rate
                let v = Float(sin(2 * .pi * phase) * exp(-t * 7)) * attack
                part.left[i] = v
                part.right[i] = v
            case .snare:
                let tone = Float(sin(2 * .pi * 190 * t) * exp(-t * 25)) * 0.4, env = Float(exp(-t * 18)) * attack
                part.left[i] = tone + fl.run(r.noise(), 1800, q: 0.8).band * env
                part.right[i] = tone + fr.run(r.noise(), 1900, q: 0.8).band * env
            case .hat, .open:
                let env = Float(exp(-t * (drum == .hat ? 60 : 12))) * attack * 0.6
                part.left[i] = fl.run(r.noise(), 7000).high * env
                part.right[i] = fr.run(r.noise(), 7500).high * env
            }
        }
        return part
    }

    /// A short rise into a chord hit that rings out: a logo's sting.
    private static func stinger(_ r: inout AssetRandom) -> Sound {
        let minor = r.chance(0.5), tonic = r.int(0...11), rise = r.range(0.5...0.8), n = count(rise + r.range(2.0...2.8))
        var sound = Sound(left: .init(repeating: 0, count: n), right: .init(repeating: 0, count: n))
        var nl = AssetFilter(), nr = AssetFilter()
        for i in 0..<count(rise) {
            let x = Double(i) / Double(count(rise)), env = Float(pow(x, 2)) * 0.5
            sound.left[i] = nl.run(r.noise(), 300 * pow(25, x), q: 1.2).band * env
            sound.right[i] = nr.run(r.noise(), 320 * pow(25, x), q: 1.2).band * env
        }
        let root = 48 + Double(tonic)
        let notes = [root - 12, root, root + (minor ? 3 : 4), root + 7, root + 12, root + 19].map(midi)
        var fl = AssetFilter(), fr = AssetFilter()
        let start = count(rise)
        for i in start..<n {
            let t = Double(i - start) / rate, env = exp(-t * 1.5) * min(1, t / 0.003)
            var l: Float = 0, rr: Float = 0
            for (k, f) in notes.enumerated() {
                l += saw(f * 0.998 * t + Double(k) * 0.2) * 0.14
                rr += saw(f * 1.002 * t + Double(k) * 0.31) * 0.14
            }
            let cutoff = 400 + 4000 * exp(-t * 3)
            let sub = Float(sin(2 * .pi * midi(root - 24) * t) * exp(-t * 2.5)) * 0.4
            sound.left[i] += (fl.run(l, cutoff).low + sub) * Float(env)
            sound.right[i] += (fr.run(rr, cutoff).low + sub) * Float(env)
        }
        sound.key = keyNames[tonic] + (minor ? String(localized: " minor") : String(localized: " major"))
        return sound
    }

    // MARK: - Finishing and the file

    /// No DC offset, silence at both ends (a loop runs on into its start instead), and the
    /// loudest true peak at −1 dBTP.
    static func finish(_ sound: inout Sound) {
        let n = sound.left.count
        guard n > 0 else { return }
        for channel in [\Sound.left, \Sound.right] {
            let mean = vDSP.mean(sound[keyPath: channel])
            sound[keyPath: channel] = vDSP.add(-mean, sound[keyPath: channel])
            if !sound.loops {
                let fadeIn = min(96, n / 4), fadeOut = min(480, n / 4)
                for i in 0..<fadeIn { sound[keyPath: channel][i] *= Float(i) / Float(fadeIn) }
                for i in 0..<fadeOut { sound[keyPath: channel][n - 1 - i] *= Float(i) / Float(fadeOut) }
            }
        }
        let peak = max(truePeak(sound.left), truePeak(sound.right))
        guard peak > 0 else { return }
        let gain = Float(pow(10, -1.0 / 20)) / peak
        sound.left = vDSP.multiply(gain, sound.left)
        sound.right = vDSP.multiply(gain, sound.right)
    }

    /// The peak between samples too (4× oversampled with a windowed sinc, as a true-peak meter reads it).
    static func truePeak(_ x: [Float]) -> Float {
        var peak = vDSP.maximumMagnitude(x)
        let taps = 16
        guard x.count > taps * 2 else { return peak }
        for phase in 1..<4 {
            let offset = Double(phase) / 4
            // vDSP_conv correlates: output[i] = Σ x[i + k] · kernel[k].
            let kernel: [Float] = (0..<taps).map { k in
                let d = Double(k - taps / 2 + 1) - offset
                let sinc = d == 0 ? 1 : sin(.pi * d) / (.pi * d)
                let window = 0.5 + 0.5 * cos(.pi * d / Double(taps / 2 + 1))
                return Float(sinc * window)
            }
            var out = [Float](repeating: 0, count: x.count - taps)
            vDSP_conv(x, 1, kernel, 1, &out, 1, vDSP_Length(out.count), vDSP_Length(taps))
            peak = max(peak, vDSP.maximumMagnitude(out))
        }
        return peak
    }

    /// 48 kHz, 24-bit, stereo PCM.
    static func writeWAV(_ sound: Sound, to url: URL) throws {
        let frames = sound.left.count, bytes = frames * 2 * 3
        var data = Data(capacity: 44 + bytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 6); u16(6); u16(24)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        var pcm = [UInt8](repeating: 0, count: bytes)
        for i in 0..<frames {
            for (c, channel) in [sound.left, sound.right].enumerated() {
                let v = Int32((min(max(channel[i], -1), 1) * 8_388_607).rounded())
                let at = (i * 2 + c) * 3
                pcm[at] = UInt8(truncatingIfNeeded: v)
                pcm[at + 1] = UInt8(truncatingIfNeeded: v >> 8)
                pcm[at + 2] = UInt8(truncatingIfNeeded: v >> 16)
            }
        }
        data.append(contentsOf: pcm)
        try data.write(to: url, options: .atomic)
    }
}
