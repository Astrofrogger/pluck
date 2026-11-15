import Accelerate
import AVFoundation
import Foundation

extension PhotoSelfTest {
    /// Fit Music (-PluckScreenshotOnly musicfit), on a made-up song at 120 BPM (a bar is 2 s): drums
    /// with a chord per bar, 8-bar sections A, B, a sustained pad without drums, A again, then a
    /// final chord ringing out. Joins land on bar lines; the length is the target to the frame; a
    /// join is no more of a jump (sample to sample, or in its spectrum) than the song's own bar
    /// lines, while a hard splice is; a chosen start and end are kept to the sample; the automatic
    /// end is the real ending.
    static func musicFitTest() async {
        guard let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg") else { return check("musicfit: bundled ffmpeg", false, "no ffmpeg") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MusicFitTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rate = 48_000.0
        let source = folder.appendingPathComponent("Song.wav")
        let original = testSong(rate: rate)
        do { try MusicFit.write([original, original], rate: rate, to: source) } catch { return check("musicfit: test song", false, "\(error)") }

        guard let song = try? await MusicFit.analyse(source, ffmpeg: ffmpeg) else { return check("musicfit: analyse", false, "no beat") }
        check("musicfit: tempo", abs(song.tempo - 120) < 1, "\(song.tempo)")
        func offBar(_ t: Double) -> Double { abs(t - (t / 2).rounded() * 2) }
        let grid = song.downbeats.filter { $0 < 64 }.map(offBar).max() ?? 1
        check("musicfit: bar lines found", grid < 0.03 && song.downbeats.count >= 32, "worst \(grid) s off, \(song.downbeats.count) bars")
        check("musicfit: snap to the beat", abs(MusicFit.snap(3.1, in: song) - 3.0) < 0.03)

        /// The largest sample step and spectral rise within 0.1 s of a moment.
        func roughness(_ x: [Float], at time: Double) -> (step: Float, flux: Float) {
            let center = Int(time * rate), reach = Int(0.1 * rate)
            let a = max(1, center - reach), b = min(x.count - 1, center + reach)
            guard a < b else { return (0, 0) }
            var step: Float = 0
            for n in a...b { step = max(step, abs(x[n] - x[n - 1])) }
            return (step, spectralFlux(x, from: a, to: b))
        }
        /// Each join against the song's own bar lines where it leaves and where it lands.
        func smooth(_ plan: MusicFit.Plan, _ name: String) {
            let mixed = MusicFit.mix(plan, song)[0]
            for join in plan.joins {
                let here = roughness(mixed, at: join.output * plan.tempo)
                let a = roughness(original, at: join.from), b = roughness(original, at: join.to)
                check("musicfit: \(name) join \(Int(join.from.rounded()))→\(Int(join.to.rounded())) has no click",
                      here.step <= max(a.step, b.step) * 1.5 + 0.002, "step \(here.step) vs \(max(a.step, b.step))")
                check("musicfit: \(name) join \(Int(join.from.rounded()))→\(Int(join.to.rounded())) no spectral jump",
                      here.flux <= max(a.flux, b.flux) * 1.3 + 1, "flux \(here.flux) vs \(max(a.flux, b.flux))")
            }
        }
        func onBars(_ plan: MusicFit.Plan, _ name: String) {
            let worst = plan.joins.flatMap { [offBar($0.from), offBar($0.to)] }.max() ?? 0
            check("musicfit: \(name) joins on bar lines", worst < 0.03, "worst \(worst) s off")
        }
        func exactLength(_ plan: MusicFit.Plan, _ name: String, fps: Double = 25) async {
            let file = folder.appendingPathComponent("\(name).wav")
            do { try await MusicFit.render(plan, song: song, input: source, output: file, ffmpeg: ffmpeg) } catch { return check("musicfit: \(name) render", false, "\(error)") }
            guard let read = try? AVAudioFile(forReading: file) else { return check("musicfit: \(name) render", false, "unreadable") }
            let seconds = Double(read.length) / read.fileFormat.sampleRate
            check("musicfit: \(name) length is the target", abs(seconds - plan.target) <= 1 / fps, "\(seconds) for \(plan.target)")
        }

        // The automatic fit, shorter: only A and A' sound alike, so the clean way is bar 4 to bar 24.
        let plans = MusicFit.plans(for: song, .init(target: 26))
        guard let auto = plans.first else { return check("musicfit: a 26 s fit", false, "none") }
        check("musicfit: auto starts at the song's start", auto.pieces[0].lowerBound < 0.05, "\(auto.pieces[0].lowerBound)")
        check("musicfit: auto ends on the real ending", auto.ending == .real && (auto.pieces.last?.upperBound ?? 0) > 64.5,
              "\(auto.ending) at \(auto.pieces.last?.upperBound ?? 0)")
        check("musicfit: auto keeps the tempo", auto.tempo == 1, "\(auto.tempo)")
        check("musicfit: auto joins A to A'", auto.joins.count == 1 && auto.joins[0].fromBar == 4 && auto.joins[0].toBar == 24,
              "\(auto.joins.map { "\($0.fromBar)→\($0.toBar)" })")
        check("musicfit: alternatives", plans.count >= 2 && plans[0].pieces != plans[1].pieces, "\(plans.count)")
        onBars(auto, "auto")
        smooth(auto, "auto")
        await exactLength(auto, "auto")

        // A hard splice in the pad shows up on both measures (the checks above can fail).
        let cut = Int(37.31 * rate), resume = Int(41.77 * rate)
        let spliced = Array(original[..<cut] + original[resume...])
        let splice = roughness(spliced, at: 37.31), padA = roughness(original, at: 37.31), padB = roughness(original, at: 41.77)
        check("musicfit: a hard splice clicks", splice.step > max(padA.step, padB.step) * 1.5 + 0.002, "step \(splice.step) vs \(max(padA.step, padB.step))")
        check("musicfit: a hard splice jumps", splice.flux > max(padA.flux, padB.flux) * 1.3 + 1, "flux \(splice.flux) vs \(max(padA.flux, padB.flux))")

        // A chosen start and end, kept to the sample.
        if let chosen = MusicFit.plans(for: song, .init(target: 31.5, start: 3.0, end: 60.5)).first {
            check("musicfit: chosen start and end", chosen.pieces[0].lowerBound == 3.0 && chosen.pieces.last?.upperBound == 60.5 && chosen.ending == .chosen,
                  "\(chosen.pieces[0].lowerBound)–\(chosen.pieces.last?.upperBound ?? 0)")
            let mixed = MusicFit.mix(chosen, song)[0]
            let first = Int(3.0 * rate), last = Int(60.5 * rate)
            let head = (Int(0.01 * rate)..<Int(0.2 * rate)).map { abs(mixed[$0] - original[first + $0]) }.max() ?? 1
            let tail = (Int(0.02 * rate)..<Int(0.2 * rate)).map { abs(mixed[mixed.count - $0] - original[last - $0]) }.max() ?? 1
            check("musicfit: chosen start plays from there", head < 1e-5, "\(head)")
            check("musicfit: chosen end plays up to there", tail < 1e-5, "\(tail)")
            onBars(chosen, "chosen")
            smooth(chosen, "chosen")
            await exactLength(chosen, "chosen", fps: 30)
        } else {
            check("musicfit: chosen start and end", false, "no fit")
        }

        // Longer: repeats on bar lines.
        if let longer = MusicFit.plans(for: song, .init(target: 100)).first {
            check("musicfit: longer repeats", longer.joins.contains { $0.to < $0.from })
            onBars(longer, "longer")
            smooth(longer, "longer")
            await exactLength(longer, "longer")
        } else {
            check("musicfit: a 100 s fit", false, "none")
        }

        // A part that must stay: the pad.
        if let kept = MusicFit.plans(for: song, .init(target: 30, keep: [33...47])).first {
            check("musicfit: keeps a chosen part", kept.pieces.contains { $0.lowerBound <= 33 && $0.upperBound >= 47 }, "\(kept.pieces)")
        } else {
            check("musicfit: keeps a chosen part", false, "no fit")
        }

        // Very short: still exact, and it ends on the ending or a phrase.
        if let short = MusicFit.plans(for: song, .init(target: 12)).first {
            check("musicfit: short ends on an ending", short.ending != .chosen)
            await exactLength(short, "short")
        } else {
            check("musicfit: a 12 s fit", false, "none")
        }
    }

    /// The largest rise of the log spectrum between 1024-sample frames, 256 apart.
    private static func spectralFlux(_ x: [Float], from a: Int, to b: Int) -> Float {
        let size = 1024, half = 512
        guard let fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var previous: [Float]?
        var most: Float = 0
        var at = max(0, a - size / 2)
        while at + size <= min(x.count, b + size / 2) {
            var frame = [Float](repeating: 0, count: size), real = [Float](repeating: 0, count: half), imaginary = [Float](repeating: 0, count: half)
            var power = [Float](repeating: 0, count: half)
            vDSP_vmul(Array(x[at..<(at + size)]), 1, window, 1, &frame, 1, vDSP_Length(size))
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer { $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) } }
                    vDSP_fft_zrip(fft, &split, 1, 10, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            let logs = power.map { log1p(1000 * $0) }
            if let previous { most = max(most, zip(logs, previous).reduce(0) { $0 + max(0, $1.0 - $1.1) }) }
            previous = logs
            at += 256
        }
        return most
    }

    /// 120 BPM: sections A (C Am F G), B (E C#m A B), a drumless pad (F Dm Bb C, two bars each),
    /// A again, then a C chord ringing out from 64 s; 68 s in all.
    private static func testSong(rate: Double) -> [Float] {
        let count = Int(68 * rate)
        var out = [Float](repeating: 0, count: count)
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 23) - 1 }
        func add(_ start: Double, _ length: Double, _ value: (Double) -> Float) {
            let a = Int(start * rate), b = min(count, Int((start + length) * rate))
            guard a < b else { return }
            for n in a..<b { out[n] += value(Double(n - a) / rate) }
        }
        func midi(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }
        func tone(_ f: Double, _ t: Double) -> Float { Float(sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t)) }
        let major = [0, 4, 7], minor = [0, 3, 7]
        let a: [(Int, [Int])] = [(60, major), (57, minor), (53, major), (55, major)]
        let b: [(Int, [Int])] = [(64, major), (61, minor), (57, major), (59, major)]
        let pad: [(Int, [Int])] = [(53, major), (53, major), (50, minor), (50, minor), (58, major), (58, major), (60, major), (60, major)]
        for bar in 0..<32 {
            let t0 = Double(bar) * 2
            let section = bar / 8
            if section == 2 {
                let (root, shape) = pad[bar % 8]
                // Held: a slow swell at each chord change, no gaps between bars.
                let swell = bar % 2 == 0
                add(t0, 2, { t in
                    let level = swell ? min(1, t / 0.3) : 1
                    let release = bar % 2 == 1 ? min(1, (2 - t) / 0.3) : 1
                    return Float(0.12 * level * release) * shape.reduce(0) { $0 + tone(midi(root + $1), t0 + t) }
                })
                continue
            }
            let (root, shape) = (section == 1 ? b : a)[bar % 4]
            add(t0, 1.98, { t in
                let envelope = min(1, t / 0.01) * (0.6 + 0.4 * exp(-t / 0.3)) * min(1, (1.98 - t) / 0.03)
                return Float(0.1 * envelope) * (shape.reduce(0) { $0 + tone(midi(root + $1), t0 + t) } + tone(midi(root - 24), t0 + t))
            })
            for beat in 0..<4 {
                let tb = t0 + Double(beat) * 0.5
                if beat % 2 == 0 {
                    let level: Float = beat == 0 ? 0.9 : 0.6
                    add(tb, 0.3, { t in level * Float(sin(2 * .pi * (50 * t + 100 * 0.04 * (1 - exp(-t / 0.04)))) * exp(-t / 0.12)) })
                } else {
                    add(tb, 0.2, { t in 0.3 * noise() * Float(exp(-t / 0.05)) })
                }
                for eighth in 0..<2 { add(tb + Double(eighth) * 0.25, 0.05, { t in 0.08 * noise() * Float(exp(-t / 0.01)) }) }
            }
        }
        // The final chord with its decay.
        add(64, 3.6, { t in
            Float(0.12 * exp(-t / 0.8) * min(1, t / 0.01)) * ([0, 4, 7, 12].reduce(0) { $0 + tone(midi(60 + $1), 64 + t) } + tone(midi(36), 64 + t))
                + 0.9 * Float(sin(2 * .pi * 50 * t) * exp(-t / 0.12))
        })
        return out
    }
}
